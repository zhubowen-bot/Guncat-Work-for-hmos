// ChatViewModel: 整体状态 + 行为 (对齐 web 版本的 store)
//  - @Observed + 内部 version 计数器, 通过 ChatPage 的 @State vm 触发刷新
import { Agent } from '../model/Agent';
import { Conversation } from '../model/Conversation';
import { ConversationListItem } from '../model/ConversationListItem';
import { Message } from '../model/Message';
import { Attachment } from '../model/Attachment';
import { ApiConfig } from '../model/ApiConfig';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { ApiProfile } from '../model/ApiProfile';
import { FileItem, StreamCallbacks, AbortSignal, ParsedFileResult } from '../common/Types';
import { ToolExecutionGuard } from '../common/ToolExecutionGuard';
import { LoopMetrics } from '../common/LoopMetrics';
import { ToolScheduler, ScheduledGroup } from '../common/ToolScheduler';
import { RepeatDetector } from '../common/RepeatDetector';
import { LoopDecisions } from '../common/LoopDecisions';
import { WorkLoopStateMachine } from '../common/WorkLoopStateMachine';
import { WorkLoopPlanner, WorkLoopTurnInfo, WorkLoopStep } from '../common/WorkLoopPlanner';
import { WorkLoopStepInfoBuilder } from '../common/WorkLoopStepInfoBuilder';
import { SessionLogAggregator } from '../common/SessionLogAggregator';
import { AgentLoader } from '../service/AgentLoader';
import { PluginHotLoader } from '../service/PluginHotLoader';
import { ChatService, ChatStreamResult } from '../service/ChatService';
import { LOCAL_SEARCH_TOOL_NAME, LocalWebSearch, SearchEngineSettings, LocalSearchOutcome } from '../service/LocalWebSearch';
import { AgentLoopService, LoopError, LoopMessage, LoopTurnCallbacks, LoopTurnResult } from '../service/AgentLoopService';
import { WorkFileService, WorkspaceFileInfo, ToolExecResult } from '../service/WorkFileService';
import { WorkToolRunner } from '../service/WorkToolRunner';
import { WorkLoopDriverBridge } from '../service/WorkLoopDriverBridge';
import { WebFetchService } from '../service/WebFetchService';
import { SpillStore } from '../service/SpillStore';
import { AskUserBridge, PendingAsk, AskAnswer } from '../service/AskUserBridge';
import { ScheduleService } from '../service/ScheduleService';
import { GoalService } from '../service/GoalService';
import { SessionLogService } from '../service/SessionLogService';
import { BackgroundTaskService } from '../service/BackgroundTaskService';
import { SubagentService } from '../service/SubagentService';
import { ToolCallRecord } from '../model/ToolCallRecord';
import { FileUploadService } from '../service/FileUploadService';
import { FileService, PickedFile } from '../service/FileService';
import { MultimodalService } from '../service/MultimodalService';
import { HarnessTools, WEB_FETCH_TOOL_NAME } from '../service/HarnessTools';
import { StorageManager } from '../data/StorageManager';
import { Constants } from '../common/Constants';
import { generateMessageId } from '../common/Utils';
import { arrayBufferToBase64 } from '../common/Utils';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { cameraPicker, camera } from '@kit.CameraKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { filePreview } from '@kit.PreviewKit';
import { systemShare } from '@kit.ShareKit';

// executeWorkLoop 单步执行的外部可变状态(驱动接管后由 runWorkStep 读写)
class WorkLoopStepState {
  traceSeq: number = 0;
  turnEndStatus: string = 'complete';
  finalAnswerText: string = '';
}

@Observed
export class ChatViewModel {
  agents: Agent[] = [];
  conversations: Conversation[] = [];
  currentAgent: Agent | null = null;
  currentConversationId: string = '';
  isStreaming: boolean = false;
  thinkingEnabled: boolean = false;
  // 推理强度('max' / 'high' / 'low'), 深度思考开启时作为 reasoning 强度参数下发
  reasoningEffort: string = 'high';
  webSearchEnabled: boolean = true;
  autoReadEnabled: boolean = false;
  pendingFiles: FileItem[] = [];
  drawerOpen: boolean = false;
  apiConfig: ApiConfig = ApiConfig.default();
  multimodalConfig: MultimodalConfig = MultimodalConfig.default();
  // 本地内置联网搜索配置(引擎 + 各引擎 Key/BaseUrl), 与服务端联网搜索开关独立
  localSearchConfig: SearchEngineSettings = new SearchEngineSettings();
  apiProfiles: ApiProfile[] = [];
  currentApiProfileId: string = '';

  // 工作模式(Agent Loop): 当前会话的工作区文件列表 + 刚上传尚未随任务发送的文件名
  workspaceFiles: WorkspaceFileInfo[] = [];
  workspaceLoading: boolean = false;
  // 会话工作时间(秒): 任务执行期间由 ChatPage 每秒累计, 工作区面板显示用
  workElapsedSec: number = 0;
  // 上一工作请求的真实 prompt tokens 与该请求的字符量(usage 锚定,
  // 用于推导本会话的字符→token 比例并做上下文预算判断; 0 表示未知)
  private lastWorkPromptTokens: number = 0;
  private lastWorkPromptChars: number = 0;
  // @deprecated 重复调用防护已迁移到 RepeatDetector, 保留兼容
  private workRepeatKey: string = '';
  private workRepeatCount: number = 0;
  // 重复调用防护状态(连续同工具同参数计数, 每次任务循环开始时重置)
  private workRepeatDetector: RepeatDetector = new RepeatDetector();
  // 工作模式显式状态机(idle/running/paused/awaiting_user/aborting)
  private workStateMachine: WorkLoopStateMachine = new WorkLoopStateMachine();
  private workspaceJustAdded: string[] = [];
  // 最近一次使用的真实智能体(退出工作模式时回切)
  private lastChatAgentId: string = '';
  // ===== Guncat Work 6.1 (dsh 移植) =====
  // 插话队列(对齐 dsh 的 next-step steering): 任务执行中用户发送的消息在本轮结束后注入
  private workSteerQueue: string[] = [];
  // 待回答的 ask_user_question(由 ChatPage 定时同步, 渲染问题卡片)
  pendingAsk: PendingAsk | null = null;
  // 已生成过 LLM 标题的会话(每会话一次, 应用运行期内)
  private titleJobs: Set<string> = new Set();

  // 文件解析内部状态
  private fileBuffers: Map<string, ArrayBuffer> = new Map();
  // 流式更新节流
  private streamTimer: number = -1;
  private pendingUIChange: boolean = false;
  private streamTarget: Message | null = null;
  // 实时 token 速度刷新节流 (500ms, 避免频繁触发 @Observed 重渲染)
  private lastSpeedUpdateTime: number = 0;
  // 取消信号
  private abortSignal: AbortSignal = new AbortSignal();
  // context(公开: 详情面板等 UI 组件读取工作区路径用)
  context: common.UIAbilityContext | null = null;
  // 初始化完成
  ready: boolean = false;
  // 全局文件解析中标志(显式管理, 不依赖每个 FileItem.isParsing)
  private _isParsing: boolean = false;
  get isParsing(): boolean {
    return this._isParsing;
  }
  // UI 状态变化回调(用于在 VM 内部状态变化时通知 ChatPage 触发 refreshTick)
  onStateChange: () => void = (): void => {};
  onReadText: (id: string, text: string) => Promise<void> =
    async (_id: string, _text: string): Promise<void> => {};
  onStopReading: () => Promise<void> = async (): Promise<void> => {};

  setStateChangeListener(cb: () => void): void {
    this.onStateChange = cb;
  }

  private notifyUIChange(): void {
    try {
      this.onStateChange();
    } catch (e) {
      // ignore
    }
  }

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  get currentConversation(): Conversation | null {
    if (this.currentConversationId === '') {
      return null;
    }
    for (let i: number = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].id === this.currentConversationId) {
        return this.conversations[i];
      }
    }
    return null;
  }

  get currentMessages(): Message[] {
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      return [];
    }
    return conv.messages;
  }

  // 当前会话是否工作模式(由会话自身 mode 决定, 切换会话自动跟随)
  get workMode(): boolean {
    let conv: Conversation | null = this.currentConversation;
    return conv !== null && conv.mode === 'work';
  }

  async init(): Promise<void> {
    if (this.context === null) {
      return;
    }
    await this.restoreState();
  }

  async restoreState(): Promise<void> {
    if (this.context === null) {
      return;
    }
    // 加载多套 API 配置；旧版单配置会自动迁移为第一套配置。
    this.apiProfiles = await StorageManager.loadApiProfiles(this.context);
    if (this.apiProfiles.length === 0) {
      let cfg: ApiConfig | null = await StorageManager.loadApiConfig(this.context);
      let legacyApi: ApiConfig = cfg !== null ? cfg : ApiConfig.default();
      let legacyMm: MultimodalConfig = await StorageManager.loadMultimodalConfig(this.context);
      this.apiProfiles.push(ApiProfile.fromLegacy('默认配置', legacyApi, legacyMm));
      await StorageManager.saveApiProfiles(this.context, this.apiProfiles);
    }
    let savedProfileId: string = await StorageManager.loadString(
      this.context, Constants.LS_KEY_CURRENT_API_PROFILE_ID, '');
    let selectedProfile: ApiProfile = this.apiProfiles[0];
    for (let i: number = 0; i < this.apiProfiles.length; i++) {
      if (this.apiProfiles[i].id === savedProfileId) {
        selectedProfile = this.apiProfiles[i];
        break;
      }
    }
    this.applyApiProfile(selectedProfile);
    this.thinkingEnabled = await StorageManager.loadBoolean(this.context, Constants.LS_KEY_THINKING_ENABLED, false);
    let savedEffort: string = await StorageManager.loadString(
      this.context, Constants.LS_KEY_REASONING_EFFORT, 'high');
    this.reasoningEffort = (savedEffort === 'max' || savedEffort === 'low') ? savedEffort : 'high';
    this.webSearchEnabled = await StorageManager.loadBoolean(this.context, Constants.LS_KEY_WEB_SEARCH_ENABLED, true);
    this.autoReadEnabled = await StorageManager.loadBoolean(
      this.context, Constants.LS_KEY_AUTO_READ_ENABLED, false);
    // 本地内置联网搜索配置加载并注入运行时快照
    let searchCfgJson: string = await StorageManager.loadString(
      this.context, Constants.LS_KEY_LOCAL_SEARCH_CONFIG, '');
    this.localSearchConfig = SearchEngineSettings.parse(searchCfgJson);
    LocalWebSearch.bind(this.localSearchConfig);

    // 加载智能体; 工作模式作为与智能体平行的固定项注入列表顶部
    this.agents = await AgentLoader.loadAllAgents(this.context);

    // 热加载 rawfile/plugins 插件(注册进 ToolRegistry, 工作模式动态目录自动包含)
    await PluginHotLoader.loadAll(this.context);
    this.agents.unshift(this.buildWorkAgent());
    // 记录第一个真实智能体(退出工作模式时回切)
    for (let i: number = 0; i < this.agents.length; i++) {
      if (this.agents[i].id !== Constants.WORK_AGENT_ID) {
        this.lastChatAgentId = this.agents[i].id;
        break;
      }
    }

    // 加载对话(旧数据迁移: 工作会话统一挂到 work 虚拟智能体下)
    this.conversations = await StorageManager.loadConversations(this.context);
    for (let i: number = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].mode === 'work' &&
        this.conversations[i].agentId !== Constants.WORK_AGENT_ID) {
        this.conversations[i].agentId = Constants.WORK_AGENT_ID;
      }
    }

    // 恢复当前智能体(默认取第一个真实智能体, 跳过 work 虚拟项)
    let agentId: string = await StorageManager.loadString(this.context, Constants.LS_KEY_CURRENT_AGENT_ID, '');
    let firstAgent: Agent | null = null;
    for (let i: number = 0; i < this.agents.length; i++) {
      if (this.agents[i].id !== Constants.WORK_AGENT_ID) {
        firstAgent = this.agents[i];
        break;
      }
    }
    if (agentId !== '') {
      for (let i: number = 0; i < this.agents.length; i++) {
        if (this.agents[i].id === agentId) {
          this.currentAgent = this.agents[i];
          break;
        }
      }
    }
    if (this.currentAgent === null && firstAgent !== null) {
      this.currentAgent = firstAgent;
    }

    // 每次重新打开应用都自动新建对话；若该智能体最后一条对话还是空的则直接复用
    if (this.currentAgent !== null) {
      let latest: Conversation | null = this.findLatestConversationForAgent(this.currentAgent.id);
      if (latest === null || latest.messages.length > 0) {
        await this.startNewConversation();
      } else {
        this.currentConversationId = latest.id;
        if (this.context !== null) {
          await StorageManager.saveString(this.context, Constants.LS_KEY_CURRENT_CONV_ID, latest.id);
        }
      }
    }
    // 每次启动都按当前智能体重置深度思考开关（效率模式关、专家模式开）
    await this.applyAgentThinkingDefault();
    this.ready = true;
  }

  private findLatestConversationForAgent(agentId: string): Conversation | null {
    let latest: Conversation | null = null;
    for (let i: number = 0; i < this.conversations.length; i++) {
      let c: Conversation = this.conversations[i];
      if (c.agentId === agentId) {
        if (latest === null || c.createdAt > latest.createdAt) {
          latest = c;
        }
      }
    }
    return latest;
  }

  // 切换智能体('work' 即工作模式虚拟智能体)
  async selectAgent(agentId: string): Promise<void> {
    let target: Agent | null = null;
    for (let i: number = 0; i < this.agents.length; i++) {
      if (this.agents[i].id === agentId) {
        target = this.agents[i];
        break;
      }
    }
    if (target === null) {
      return;
    }
    this.currentAgent = target;
    if (agentId !== Constants.WORK_AGENT_ID) {
      this.lastChatAgentId = agentId;
    }
    if (this.context !== null) {
      await StorageManager.saveString(this.context, Constants.LS_KEY_CURRENT_AGENT_ID, agentId);
    }
    // 切换到该 agent 的最新对话
    let latest: Conversation | null = this.findLatestConversationForAgent(agentId);
    if (latest !== null) {
      this.openConversation(latest.id);
    } else {
      this.startNewConversation();
    }
  }

  // 打开/切换对话
  async openConversation(convId: string): Promise<void> {
    let conv: Conversation | null = null;
    for (let i: number = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].id === convId) {
        conv = this.conversations[i];
        break;
      }
    }
    if (conv === null) {
      return;
    }
    this.currentConversationId = convId;
    // 立刻通知 UI (scrollTo bottom + rebuildPreviewItems), 不等 storage 落盘
    this.notifyUIChange();
    if (this.context !== null) {
      await StorageManager.saveString(this.context, Constants.LS_KEY_CURRENT_CONV_ID, convId);
    }
    // 同步 agent
    if (this.currentAgent === null || this.currentAgent.id !== conv.agentId) {
      for (let i: number = 0; i < this.agents.length; i++) {
        if (this.agents[i].id === conv.agentId) {
          this.currentAgent = this.agents[i];
          if (this.context !== null) {
            await StorageManager.saveString(this.context, Constants.LS_KEY_CURRENT_AGENT_ID, this.agents[i].id);
          }
          break;
        }
      }
    }
    // 空对话等价于新对话：打开效率/专家模式的空对话时按智能体名称重置深度思考默认值（效率模式关、专家模式开）
    if (conv.messages.length === 0) {
      await this.applyAgentThinkingDefault();
    }
    // 工作会话: 深度思考保持开启并刷新工作区文件列表
    if (conv.mode === 'work') {
      if (!this.thinkingEnabled) {
        await this.setThinkingEnabled(true);
      }
      await this.refreshWorkspace();
    } else {
      this.workspaceFiles = [];
      this.workspaceJustAdded = [];
    }
  }

  // 新建对话(模式由当前智能体决定: work 虚拟智能体 → 工作模式, 其他 → 聊天模式)
  async startNewConversation(): Promise<void> {
    // 清空空对话
    await this.cleanupEmptyConversation();
    if (this.currentAgent === null) {
      return;
    }
    let mode: string = this.currentAgent.id === Constants.WORK_AGENT_ID ? 'work' : 'chat';
    let conv: Conversation = Conversation.create(this.currentAgent.id, '', mode);
    this.conversations.unshift(conv);
    this.currentConversationId = conv.id;
    if (this.context !== null) {
      await StorageManager.saveString(this.context, Constants.LS_KEY_CURRENT_CONV_ID, conv.id);
    }
    this.persistConversations();
    if (mode === 'work') {
      this.workspaceJustAdded = [];
      // 工作模式默认强制开启深度思考(工具行不再显示该开关)
      await this.setThinkingEnabled(true);
      await this.refreshWorkspace();
    } else {
      // 效率模式默认关闭深度思考、专家模式默认开启：新建对话时按当前智能体重置开关
      await this.applyAgentThinkingDefault();
    }
    // 立即刷新侧栏/抽屉的会话列表投影, 新建的会话马上可见
    this.notifyUIChange();
  }

  private async cleanupEmptyConversation(): Promise<void> {
    let conv: Conversation | null = this.currentConversation;
    if (conv !== null && conv.messages.length === 0) {
      // 闭包内不继承可空变量的收窄, 先落成非空局部量
      let emptyConv: Conversation = conv;
      this.conversations = this.conversations.filter((c: Conversation): boolean => c.id !== emptyConv.id);
      this.currentConversationId = '';
      this.persistConversations();
    }
  }

  // 删除对话
  async deleteConversation(convId: string): Promise<void> {
    // 工作会话删除时同步清理沙箱工作区与会话事件日志, 避免孤儿数据堆积
    for (let i: number = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].id === convId && this.conversations[i].mode === 'work' && this.context !== null) {
        WorkFileService.deleteWorkspace(this.context, convId);
        SessionLogService.close(this.context, convId, true);
        break;
      }
    }
    this.conversations = this.conversations.filter((c: Conversation): boolean => c.id !== convId);
    if (this.currentConversationId === convId) {
      this.currentConversationId = '';
      if (this.conversations.length > 0) {
        this.currentConversationId = this.conversations[0].id;
      } else {
        // 创建新对话(模式跟随当前智能体)
        if (this.currentAgent !== null) {
          let newMode: string = this.currentAgent.id === Constants.WORK_AGENT_ID ? 'work' : 'chat';
          let conv: Conversation = Conversation.create(this.currentAgent.id, '', newMode);
          this.conversations.unshift(conv);
          this.currentConversationId = conv.id;
          // 新建对话时按当前智能体重置深度思考开关（效率模式关、专家模式开）
          await this.applyAgentThinkingDefault();
        }
      }
      if (this.context !== null && this.currentConversationId !== '') {
        await StorageManager.saveString(this.context, Constants.LS_KEY_CURRENT_CONV_ID, this.currentConversationId);
      }
    }
    this.persistConversations();
    // 立即通知 UI 重建侧栏/抽屉的会话列表投影, 删除后马上从列表消失
    this.notifyUIChange();
  }

  // 抽屉
  toggleDrawer(): void {
    this.drawerOpen = !this.drawerOpen;
  }
  closeDrawer(): void {
    this.drawerOpen = false;
  }
  openDrawer(): void {
    this.drawerOpen = true;
  }

  // 思考/联网开关
  async setThinkingEnabled(enabled: boolean): Promise<void> {
    this.thinkingEnabled = enabled;
    if (this.context !== null) {
      await StorageManager.saveBoolean(this.context, Constants.LS_KEY_THINKING_ENABLED, enabled);
    }
  }

  // 推理强度选择('max' / 'high' / 'low', 含持久化): 深度思考开启时生效
  async setReasoningEffort(effort: string): Promise<void> {
    if (effort !== 'max' && effort !== 'high' && effort !== 'low') {
      return;
    }
    this.reasoningEffort = effort;
    if (this.context !== null) {
      await StorageManager.saveString(this.context, Constants.LS_KEY_REASONING_EFFORT, effort);
    }
  }

  // 智能体深度思考默认值：按名称匹配（效率模式默认关、轻简模式默认关、专家模式默认开）。
  // 以名称匹配而非 id，便于将来改名；默认值调整也只需改这里。
  private defaultThinkingForAgent(agent: Agent | null): boolean | null {
    if (agent === null) {
      return null;
    }
    if (agent.name === '效率模式') return false;
    if (agent.name === '轻简模式') return false;
    if (agent.name === '专家模式') return true;
    return null;
  }

  // 新建对话/启动时按当前智能体重置深度思考开关（含持久化）
  private async applyAgentThinkingDefault(): Promise<void> {
    let def: boolean | null = this.defaultThinkingForAgent(this.currentAgent);
    if (def !== null) {
      this.thinkingEnabled = def;
      if (this.context !== null) {
        await StorageManager.saveBoolean(this.context, Constants.LS_KEY_THINKING_ENABLED, def);
      }
    }
  }

  async setWebSearchEnabled(enabled: boolean): Promise<void> {
    this.webSearchEnabled = enabled;
    if (this.context !== null) {
      await StorageManager.saveBoolean(this.context, Constants.LS_KEY_WEB_SEARCH_ENABLED, enabled);
    }
  }

  // ===== 工作模式 (Agent Loop + 沙箱工作区) =====

  // 工作模式虚拟智能体(与 agents.json 智能体平行展示)
  private buildWorkAgent(): Agent {
    let agent: Agent = Agent.of(Constants.WORK_AGENT_ID, '工作模式',
      'Agent Loop 工作台: 自动调用工具、读写沙箱工作区文件, 完成复杂长程任务', '系统', '', '');
    agent.shortDescription = 'Guncat Harness「新」';
    agent.icon = '';
    return agent;
  }

  // 进入/退出工作模式: 即切换到/切离 work 虚拟智能体
  async setWorkMode(enabled: boolean): Promise<void> {
    if (enabled === this.workMode) {
      return;
    }
    if (this.isStreaming || this.isParsing) {
      promptAction.showToast({ message: '请等待当前任务完成后再切换模式', duration: 2000 });
      return;
    }
    let targetId: string = enabled ? Constants.WORK_AGENT_ID : this.lastChatAgentId;
    if (targetId === '') {
      return;
    }
    await this.selectAgent(targetId);
    this.notifyUIChange();
  }

  // 刷新当前工作会话的文件列表(非工作会话为空)
  async refreshWorkspace(): Promise<void> {
    if (this.context === null) {
      return;
    }
    let conv: Conversation | null = this.currentConversation;
    if (conv === null || conv.mode !== 'work') {
      return;
    }
    this.workspaceLoading = true;
    let items: WorkspaceFileInfo[] = WorkFileService.listWorkspace(this.context, conv.id);
    this.workspaceFiles = items;
    this.workspaceLoading = false;
    this.notifyUIChange();
  }

  // 会话列表的轻量投影(侧栏/抽屉用, 避免 @Prop 深拷贝全部消息)
  getConversationListItems(): ConversationListItem[] {
    let items: ConversationListItem[] = [];
    for (let i: number = 0; i < this.conversations.length; i++) {
      let c: Conversation = this.conversations[i];
      let item: ConversationListItem = new ConversationListItem();
      item.id = c.id;
      item.title = c.title;
      item.agentId = c.agentId;
      item.mode = c.mode;
      items.push(item);
    }
    return items;
  }

  // 从系统选择器上传文件到工作区根目录(重名自动追加序号)
  async uploadToWorkspace(): Promise<void> {
    if (this.context === null || !this.workMode) {
      return;
    }
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      return;
    }
    promptAction.showToast({ message: '请在选择器中挑选要加入工作区的文件', duration: 1500 });
    let files: PickedFile[] = [];
    try {
      files = await FileService.pickFiles();
    } catch (e) {
      promptAction.showToast({ message: '文件选择失败: ' + (e as Error).message, duration: 2000 });
      return;
    }
    if (files.length === 0) {
      return;
    }
    let saved: string[] = WorkFileService.savePickedFiles(this.context, conv.id, files);
    if (saved.length === 0) {
      promptAction.showToast({ message: '文件保存失败', duration: 2000 });
      return;
    }
    for (let i: number = 0; i < saved.length; i++) {
      this.workspaceJustAdded.push(saved[i]);
    }
    await this.refreshWorkspace();
    promptAction.showToast({ message: saved.length.toString() + ' 个文件已加入工作区', duration: 2000 });
  }

  // 把整个工作区打包为 zip 并通过系统保存面板导出, 返回文件名
  async exportWorkspaceZip(): Promise<string> {
    if (this.context === null) {
      throw new Error('上下文未初始化');
    }
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      throw new Error('当前没有工作会话');
    }
    let bytes: Uint8Array = WorkFileService.zipWorkspace(this.context, conv.id);
    return WorkFileService.saveZipViaPicker(this.context, bytes);
  }

  // 清空工作区(带确认弹窗)
  async clearWorkspace(): Promise<void> {
    if (this.context === null) {
      return;
    }
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      return;
    }
    try {
      let res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '清空工作区',
        message: '将删除工作区中的全部文件, 该操作不可恢复。确定继续吗?',
        buttons: [
          { text: '取消', color: '#6B7280' },
          { text: '清空', color: '#E05252' }
        ]
      });
      if (res.index !== 1) {
        return;
      }
    } catch (e) {
      // 用户取消或弹窗不可用
      return;
    }
    WorkFileService.deleteWorkspace(this.context, conv.id);
    WorkFileService.ensureWorkspace(this.context, conv.id);
    this.workspaceJustAdded = [];
    await this.refreshWorkspace();
    promptAction.showToast({ message: '工作区已清空', duration: 2000 });
  }

  // 删除工作区中的单个文件/目录
  async deleteWorkspaceFile(path: string): Promise<void> {
    if (this.context === null) {
      return;
    }
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      return;
    }
    let removed: boolean = WorkFileService.removePath(this.context, conv.id, path);
    if (removed) {
      this.workspaceJustAdded = this.workspaceJustAdded.filter((n: string): boolean => n !== path);
      await this.refreshWorkspace();
    }
  }

  // 就地预览工作区文件: 使用系统 Preview Kit 的预览弹窗, 不暴露路径/压缩包/格式选择
  async previewWorkspaceFile(rel: string): Promise<void> {
    if (this.context === null) {
      promptAction.showToast({ message: '上下文未初始化', duration: 1500 });
      return;
    }
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      promptAction.showToast({ message: '当前没有工作会话', duration: 1500 });
      return;
    }
    let root: string = WorkFileService.workspaceRoot(this.context, conv.id);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null || !fileIo.accessSync(abs) || fileIo.statSync(abs).isDirectory()) {
      promptAction.showToast({ message: '文件不存在或已被删除', duration: 1500 });
      return;
    }
    let uri: string = fileUri.getUriFromPath(abs);
    let baseName: string = rel.substring(rel.lastIndexOf('/') + 1);
    try {
      let supported: boolean = await filePreview.canPreview(this.context, uri);
      if (!supported) {
        // 系统预览不支持该格式: 直接拉起系统“打开方式”选择框
        await this.openWorkspaceFileWithOtherApp(rel);
        return;
      }
      await filePreview.openPreview(this.context, {
        title: baseName,
        uri: uri,
        mimeType: FileService.guessTypeByName(rel)
      });
    } catch (e) {
      let err: Error = e as Error;
      promptAction.showToast({ message: '预览失败: ' + (err.message !== undefined ? err.message : String(e)), duration: 2000 });
    }
  }

  // 用其他应用打开工作区文件: 通过隐式 Want 强制展示系统“打开方式”选择框
  async openWorkspaceFileWithOtherApp(rel: string): Promise<void> {
    if (this.context === null) {
      promptAction.showToast({ message: '上下文未初始化', duration: 1500 });
      return;
    }
    let ctx: common.UIAbilityContext = this.context;
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      promptAction.showToast({ message: '当前没有工作会话', duration: 1500 });
      return;
    }
    let root: string = WorkFileService.workspaceRoot(ctx, conv.id);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null || !fileIo.accessSync(abs) || fileIo.statSync(abs).isDirectory()) {
      promptAction.showToast({ message: '文件不存在或已被删除', duration: 1500 });
      return;
    }
    let uri: string = fileUri.getUriFromPath(abs);
    // type 推荐使用 UTD 类型，且必须与 uri 文件类型一致，否则系统可能匹配不到应用
    let dot: number = rel.lastIndexOf('.');
    let ext: string = dot >= 0 ? rel.substring(dot) : '';
    let utd: string = ext !== '' ?
      uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(ext) : 'general.file';
    if (utd === '') {
      utd = 'general.file';
    }
    let want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: utd,
      // 授权目标应用读写该文件（与官方示例一致）
      flags: wantConstant.Flags.FLAG_AUTH_WRITE_URI_PERMISSION |
        wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
      parameters: {
        // 携带文件 URI 流，值必须为 string 类型的 URI 数组
        'ability.params.stream': [uri],
        // 强制展示文件打开方式选择弹框，避免直接拉起默认的文件预览应用
        'ohos.ability.params.showDefaultPicker': true
      }
    };
    try {
      await ctx.startAbility(want);
    } catch (e) {
      let err: Error = e as Error;
      promptAction.showToast({ message: '未找到可打开该文件的应用', duration: 2000 });
      console.error(`openWorkspaceFileWithOtherApp failed: ${err.message !== undefined ? err.message : String(e)}`);
    }
  }

  // 一键分享工作区原始文件: 直接拉起系统分享面板, 不要求用户选路径/打包/格式
  async shareWorkspaceFile(rel: string): Promise<void> {
    if (this.context === null) {
      promptAction.showToast({ message: '上下文未初始化', duration: 1500 });
      return;
    }
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      promptAction.showToast({ message: '当前没有工作会话', duration: 1500 });
      return;
    }
    let root: string = WorkFileService.workspaceRoot(this.context, conv.id);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null || !fileIo.accessSync(abs) || fileIo.statSync(abs).isDirectory()) {
      promptAction.showToast({ message: '文件不存在或已被删除', duration: 1500 });
      return;
    }
    let uri: string = fileUri.getUriFromPath(abs);
    let baseName: string = rel.substring(rel.lastIndexOf('/') + 1);
    let dot: number = rel.lastIndexOf('.');
    let ext: string = dot >= 0 ? rel.substring(dot) : '';
    let utd: string = ext !== '' ?
      uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(ext) : 'general.file';
    try {
      let data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd,
        uri: uri,
        title: baseName
      });
      let controller: systemShare.ShareController = new systemShare.ShareController(data);
      await controller.show(this.context, { selectionMode: systemShare.SelectionMode.SINGLE });
    } catch (e) {
      let err: Error = e as Error;
      promptAction.showToast({ message: '分享失败: ' + (err.message !== undefined ? err.message : String(e)), duration: 2000 });
    }
  }

  async setAutoReadEnabled(enabled: boolean): Promise<void> {
    this.autoReadEnabled = enabled;
    if (this.context !== null) {
      await StorageManager.saveBoolean(this.context, Constants.LS_KEY_AUTO_READ_ENABLED, enabled);
    }
    if (!enabled) {
      await this.onStopReading();
    }
    this.notifyUIChange();
  }

  get currentApiProfile(): ApiProfile | null {
    for (let i: number = 0; i < this.apiProfiles.length; i++) {
      if (this.apiProfiles[i].id === this.currentApiProfileId) {
        return this.apiProfiles[i];
      }
    }
    return null;
  }

  get currentApiProfileIndex(): number {
    for (let i: number = 0; i < this.apiProfiles.length; i++) {
      if (this.apiProfiles[i].id === this.currentApiProfileId) {
        return i;
      }
    }
    return 0;
  }

  async selectApiProfile(profileId: string): Promise<void> {
    if (this.isStreaming) {
      return;
    }
    for (let i: number = 0; i < this.apiProfiles.length; i++) {
      if (this.apiProfiles[i].id === profileId) {
        this.applyApiProfile(this.apiProfiles[i]);
        if (this.context !== null) {
          await StorageManager.saveString(
            this.context, Constants.LS_KEY_CURRENT_API_PROFILE_ID, profileId);
        }
        this.notifyUIChange();
        return;
      }
    }
  }

  async addApiProfile(): Promise<void> {
    let profile: ApiProfile = ApiProfile.create(`新配置 ${this.apiProfiles.length + 1}`);
    this.apiProfiles.push(profile);
    this.applyApiProfile(profile);
    await this.persistApiProfiles();
    this.notifyUIChange();
  }

  async saveCurrentApiProfile(
    name: string,
    apiConfig: ApiConfig,
    multimodalConfig: MultimodalConfig
  ): Promise<void> {
    let profile: ApiProfile | null = this.currentApiProfile;
    if (profile === null) {
      return;
    }
    profile.name = name.trim() !== '' ? name.trim() : '未命名配置';
    profile.apiConfig = apiConfig;
    profile.multimodalConfig = multimodalConfig;
    this.applyApiProfile(profile);
    await this.persistApiProfiles();
    // 同时保留旧键，便于降级到旧版本应用。
    if (this.context !== null) {
      await StorageManager.saveApiConfig(this.context, apiConfig);
      await StorageManager.saveMultimodalConfig(this.context, multimodalConfig);
    }
    this.notifyUIChange();
  }

  private applyApiProfile(profile: ApiProfile): void {
    this.currentApiProfileId = profile.id;
    this.apiConfig = profile.apiConfig;
    this.multimodalConfig = profile.multimodalConfig;
  }

  // 保存本地内置联网搜索配置并刷新运行时快照(引擎切换/Key 更新立即生效)
  async saveLocalSearchConfig(cfg: SearchEngineSettings): Promise<void> {
    this.localSearchConfig = cfg;
    LocalWebSearch.bind(cfg);
    if (this.context !== null) {
      await StorageManager.saveString(this.context, Constants.LS_KEY_LOCAL_SEARCH_CONFIG,
        JSON.stringify(cfg.toJson()));
    }
  }

  private async persistApiProfiles(): Promise<void> {
    if (this.context !== null) {
      await StorageManager.saveApiProfiles(this.context, this.apiProfiles);
      await StorageManager.saveString(
        this.context, Constants.LS_KEY_CURRENT_API_PROFILE_ID, this.currentApiProfileId);
    }
  }

  // 应用预设
  applyOpenAICompletionsPreset(): ApiConfig {
    return ApiConfig.openAICompletionsPreset();
  }
  applyOpenAIResponsesPreset(): ApiConfig {
    return ApiConfig.openAIResponsesPreset();
  }
  applyAnthropicMessagesPreset(): ApiConfig {
    return ApiConfig.anthropicMessagesPreset();
  }

  // 混合附件发送策略：
  // - 小图继续用 Base64 内联，避免多余上传
  // - 大图 / OpenAI Responses 文档走 Files API，生成 file_id 后按各协议引用
  private async prepareAttachmentFileIds(attachments: Attachment[], ready: FileItem[]): Promise<void> {
    let provider: string = this.apiConfig.provider;
    if (provider !== 'openai-completions' &&
      provider !== 'openai-responses' &&
      provider !== 'anthropic-messages') {
      return;
    }
    let FILE_API_THRESHOLD_BYTES: number = 4 * 1024 * 1024;
    let uploadCount: number = 0;
    for (let i: number = 0; i < ready.length; i++) {
      let att: Attachment = attachments[i];
      if (att.parsedText !== '' || att.dataUrl === '') {
        continue;
      }
      let buf: ArrayBuffer | undefined = this.fileBuffers.get(ready[i].id);
      if (buf === undefined) {
        continue;
      }
      let shouldUpload: boolean = false;
      if (att.type === 'file') {
        shouldUpload = provider === 'openai-responses';
      } else {
        if (provider === 'anthropic-messages') {
          shouldUpload = buf.byteLength > FILE_API_THRESHOLD_BYTES && this.apiConfig.baseUrl.indexOf('deepseek.com') !== -1;
        } else {
          shouldUpload = buf.byteLength > FILE_API_THRESHOLD_BYTES;
        }
      }
      if (shouldUpload) {
        uploadCount++;
      }
    }
    if (uploadCount === 0) {
      return;
    }
    promptAction.showToast({ message: '正在上传附件...', duration: 2000 });
    for (let i: number = 0; i < ready.length; i++) {
      let att: Attachment = attachments[i];
      if (att.parsedText !== '' || att.dataUrl === '') {
        continue;
      }
      let buf: ArrayBuffer | undefined = this.fileBuffers.get(ready[i].id);
      if (buf === undefined) {
        continue;
      }
      let shouldUpload: boolean = false;
      if (att.type === 'file') {
        shouldUpload = provider === 'openai-responses';
      } else {
        if (provider === 'anthropic-messages') {
          shouldUpload = buf.byteLength > FILE_API_THRESHOLD_BYTES && this.apiConfig.baseUrl.indexOf('deepseek.com') !== -1;
        } else {
          shouldUpload = buf.byteLength > FILE_API_THRESHOLD_BYTES;
        }
      }
      if (!shouldUpload) {
        continue;
      }
      try {
        let mimeType: string = ready[i].type !== '' ? ready[i].type : 'application/octet-stream';
        att.fileId = await FileUploadService.uploadFile(this.apiConfig, att.name, mimeType, buf);
      } catch (e) {
        // 上传失败时保留 dataUrl，回退 Base64 内联发送
        att.fileId = '';
      }
    }
  }

  // 文件选择 + 解析
  async pickAndParseFiles(): Promise<void> {
    if (this.context === null) {
      return;
    }
    if (!this.checkAttachmentSupported()) {
      return;
    }
    // 提前 toast, 避免 picker 返回后到文件读取之间的空白期页面无反馈
    promptAction.showToast({ message: '正在读取文件...', duration: 2000 });
    let files: PickedFile[] = [];
    try {
      // 同时支持图片与文档
      let docs: PickedFile[] = await FileService.pickFiles();
      files = files.concat(docs);
    } catch (e) {
      promptAction.showToast({ message: '文件选择失败: ' + (e as Error).message, duration: 2000 });
      return;
    }
    if (files.length === 0) {
      return;
    }
    await this.enqueueFiles(files);
  }

  // 快捷拍照: 系统相机(CameraPicker, 无需相机权限)拍照后加入附件并解析
  async capturePhoto(): Promise<void> {
    if (this.context === null) {
      return;
    }
    if (!this.checkAttachmentSupported()) {
      return;
    }
    let uri: string = '';
    try {
      // 注意: PickerProfile 字段为只读, 必须用对象字面量初始化(不能 new 后赋值)
      let profile: cameraPicker.PickerProfile = {
        cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
      };
      let result: cameraPicker.PickerResult = await cameraPicker.pick(this.context,
        [cameraPicker.PickerMediaType.PHOTO], profile);
      // resultCode 非 0 表示用户取消或失败
      if (result.resultCode !== 0 || result.resultUri === '') {
        return;
      }
      uri = result.resultUri;
    } catch (e) {
      promptAction.showToast({ message: '拍照失败: ' + (e as Error).message, duration: 2000 });
      return;
    }
    promptAction.showToast({ message: '正在读取照片...', duration: 2000 });
    let stamp: string = new Date().getTime().toString();
    // 工作模式: 照片直接存入工作区, 不作为聊天附件
    if (this.workMode && this.context !== null) {
      let conv: Conversation | null = this.currentConversation;
      if (conv === null) {
        return;
      }
      try {
        let savedName: string = await WorkFileService.saveUriFile(this.context, conv.id, uri, 'IMG_' + stamp + '.jpg');
        this.workspaceJustAdded.push(savedName);
        await this.refreshWorkspace();
        promptAction.showToast({ message: '照片已存入工作区: ' + savedName, duration: 2000 });
      } catch (e) {
        promptAction.showToast({ message: '照片存入工作区失败: ' + (e as Error).message, duration: 2000 });
      }
      return;
    }
    let picked: PickedFile | null = await FileService.readUri(uri, 'IMG_' + stamp + '.jpg');
    if (picked === null) {
      promptAction.showToast({ message: '照片读取失败', duration: 2000 });
      return;
    }
    let files: PickedFile[] = [picked];
    await this.enqueueFiles(files);
    promptAction.showToast({ message: '照片已加入附件', duration: 2000 });
  }

  async acceptSharedFiles(uris: string[]): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    let files: PickedFile[] = await FileService.readSharedFiles(uris);
    if (files.length === 0) {
      promptAction.showToast({ message: '无法读取分享的文件', duration: 2000 });
      return;
    }
    // 工作模式: 分享文件在进入预览区的同时写入沙箱工作区(工作模式发送只消费工作区文件)。
    // 预览区照常保留: 之后切回聊天模式, 分享文件仍可作为附件发送。
    let workspaceSynced: number = -1;
    if (this.workMode && this.context !== null) {
      let conv: Conversation | null = this.currentConversation;
      if (conv !== null) {
        let saved: string[] = WorkFileService.savePickedFiles(this.context, conv.id, files);
        workspaceSynced = saved.length;
        for (let i: number = 0; i < saved.length; i++) {
          this.workspaceJustAdded.push(saved[i]);
        }
        if (saved.length > 0) {
          await this.refreshWorkspace();
        }
      }
    }
    await this.enqueueFiles(files);
    if (workspaceSynced === files.length) {
      promptAction.showToast({
        message: files.length.toString() + ' 个分享文件已加入附件并同步到工作区',
        duration: 2000
      });
    } else if (workspaceSynced > 0) {
      promptAction.showToast({
        message: workspaceSynced.toString() + '/' + files.length.toString() + ' 个分享文件已同步到工作区',
        duration: 2000
      });
    } else if (workspaceSynced === 0) {
      promptAction.showToast({
        message: files.length.toString() + ' 个分享文件已加入附件, 但同步到工作区失败',
        duration: 2000
      });
    } else {
      promptAction.showToast({
        message: files.length.toString() + ' 个分享文件已加入附件',
        duration: 2000
      });
    }
  }

  // 附件能力前置检查
  private checkAttachmentSupported(): boolean {
    if (this.multimodalConfig.preparseEnabled && this.multimodalConfig.apiKey === '') {
      promptAction.showToast({ message: '请先配置多模态解析 API 密钥', duration: 2000 });
      return false;
    }
    if (!this.multimodalConfig.preparseEnabled &&
      this.apiConfig.provider !== 'openai-completions' &&
      this.apiConfig.provider !== 'openai-responses' &&
      this.apiConfig.provider !== 'anthropic-messages') {
      promptAction.showToast({ message: '当前接入方式不支持附件直传', duration: 2000 });
      return false;
    }
    return true;
  }

  // 把已读取的文件加入 pendingFiles 并逐个解析
  private async enqueueFiles(files: PickedFile[]): Promise<void> {
    this._isParsing = true;
    this.notifyUIChange();
    let firstNewIndex: number = this.pendingFiles.length;
    let newPending: FileItem[] = [];
    for (let i: number = 0; i < files.length; i++) {
      let item: FileItem = FileService.createFileItem(files[i]);
      this.fileBuffers.set(item.id, files[i].buffer);
      newPending.push(item);
    }
    // 必须整体重新赋值, 不能 push, 否则 @Observed 检测不到数组变更
    this.pendingFiles = [...this.pendingFiles, ...newPending];
    // 文件列表已经出现在预览条上, 立刻刷新一次, 再开始解析
    this.notifyUIChange();
    for (let index: number = firstNewIndex; index < this.pendingFiles.length; index++) {
      if (index > firstNewIndex) {
        await this.sleep(Constants.FILE_PARSE_INTERLEAVE_MS);
      }
      await this.parseOneFile(index);
    }
    // 所有文件解析完毕
    this._isParsing = false;
    this.notifyUIChange();
  }

  private async parseOneFile(index: number): Promise<void> {
    let item: FileItem = this.pendingFiles[index];
    if (item === undefined || item.error) {
      return;
    }
    let buf: ArrayBuffer | undefined = this.fileBuffers.get(item.id);
    if (buf === undefined) {
      // buffer 不存在 → 创建新对象并替换
      let updated: FileItem[] = [...this.pendingFiles];
      updated[index] = FileItem.withError(item);
      this.pendingFiles = updated;
      this.notifyUIChange();
      return;
    }
    let attempts: number = 0;
    let lastErr: Error | null = null;
    if (!this.multimodalConfig.preparseEnabled) {
      let dataUrl: string = 'data:' + item.type + ';base64,' + arrayBufferToBase64(buf);
      let directItems: FileItem[] = [...this.pendingFiles];
      directItems[index] = FileItem.withParsed(item, '', dataUrl);
      // 生成缩略图, 列表/气泡显示小图, 避免全尺寸原图反复解码撑爆内存
      directItems[index].thumbnail = await this.makeThumbnail(dataUrl);
      this.pendingFiles = directItems;
      this.notifyUIChange();
      return;
    }
    while (attempts < Constants.MAX_FILE_PARSE_RETRY) {
      try {
        let result: ParsedFileResult = await MultimodalService.parseFile(
          this.multimodalConfig, item.name, buf, item.type
        );
        // 创建新 FileItem 实例替换旧对象 → @Prop 能检测到属性变化
        let updated: FileItem[] = [...this.pendingFiles];
        updated[index] = FileItem.withParsed(item, result.content, result.dataUrl);
        // 生成缩略图, 列表/气泡显示小图, 避免全尺寸原图反复解码撑爆内存
        updated[index].thumbnail = await this.makeThumbnail(result.dataUrl);
        this.pendingFiles = updated;
        this.notifyUIChange();
        return;
      } catch (e) {
        lastErr = e as Error;
        attempts++;
        if (attempts < Constants.MAX_FILE_PARSE_RETRY) {
          await this.sleep(Constants.MAX_FILE_PARSE_RETRY_WAIT_MS);
        }
      }
    }
    // 所有重试均失败 → 创建失败状态的新对象
    let updated: FileItem[] = [...this.pendingFiles];
    updated[index] = FileItem.withError(item);
    this.pendingFiles = updated;
    this.notifyUIChange();
    if (lastErr !== null) {
      promptAction.showToast({ message: item.name + ' 解析失败: ' + lastErr.message, duration: 2500 });
    }
  }

  removePendingFile(id: string): void {
    this.pendingFiles = this.pendingFiles.filter((f: FileItem): boolean => f.id !== id);
    this.fileBuffers.delete(id);
    this.notifyUIChange();
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  // ===== Guncat Work 6.1: steering / ask_user / schedule / title =====

  // 任务执行中的用户插话(对齐 dsh 的 steer): 消息进会话历史与插话队列,
  // 本轮工具执行结束后作为"用户补充"注入下一步请求
  private steerWork(text: string): void {
    let conv: Conversation | null = this.currentConversation;
    if (conv === null || conv.mode !== 'work') {
      return;
    }
    let msg: Message = Message.ofUser(generateMessageId(), text, text, []);
    conv.messages.push(msg);
    this.workSteerQueue.push(text);
    this.persistConversations();
    this.notifyUIChange();
  }

  // ChatPage 每秒同步一次待回答提问(工具挂起在等答案, 事件无法主动推送 UI)
  syncPendingAsk(): void {
    let cur: PendingAsk | null = AskUserBridge.current();
    if (cur === null && this.pendingAsk === null) {
      return;
    }
    if (cur !== null && this.pendingAsk !== null && cur.id === this.pendingAsk.id) {
      return;
    }
    this.pendingAsk = cur;
    this.notifyUIChange();
  }

  // 用户回答问题卡片
  answerAsk(askId: string, selections: string[], note: string): void {
    let answer: AskAnswer = new AskAnswer();
    answer.selections = selections;
    answer.note = note;
    AskUserBridge.answer(askId, answer);
    this.pendingAsk = null;
    this.notifyUIChange();
  }

  // 用户取消问题卡片
  cancelAsk(askId: string): void {
    AskUserBridge.cancel(askId);
    this.pendingAsk = null;
    this.notifyUIChange();
  }

  // 定时提醒推进(ChatPage 每秒调用): 到期提醒注入为用户消息; 任务执行中走插话通道
  tickSchedules(): void {
    if (this.context === null || this.currentConversationId === '') {
      return;
    }
    let conv: Conversation | null = this.currentConversation;
    if (conv === null || conv.mode !== 'work') {
      return;
    }
    let curConv: Conversation = conv;
    let root: string = WorkFileService.workspaceRoot(this.context, conv.id);
    ScheduleService.tick(root, (message: string): void => {
      let text: string = '【定时提醒】' + message;
      let userMsg: Message = Message.ofUser(generateMessageId(), text, text, []);
      curConv.messages.push(userMsg);
      if (this.isStreaming) {
        this.workSteerQueue.push(text);
      } else {
        this.executeWorkLoop(curConv);
      }
      this.persistConversations();
      this.notifyUIChange();
    });
  }

  // 首次任务收尾后生成 LLM 会话标题(每会话一次; 失败静默)
  private maybeGenerateTitle(conv: Conversation, userText: string, answerText: string): void {
    if (this.titleJobs.has(conv.id)) {
      return;
    }
    this.titleJobs.add(conv.id);
    let config: ApiConfig = this.apiConfig;
    AgentLoopService.generateSessionTitle(config, userText, answerText).then(
      (title: string): void => {
        if (title !== '' && this.context !== null) {
          conv.title = title;
          this.persistConversations();
          this.notifyUIChange();
        }
      }).catch((_e: Error): void => {
      // 标题生成失败静默
    });
  }

  // 发送消息
  async sendMessage(displayText: string): Promise<void> {
    let userText: string = displayText;
    if (userText.trim() === '') {
      return;
    }
    if (this.isStreaming) {
      // 工作模式任务执行中: 不打断, 转为插话(next-step steering)
      if (this.workMode) {
        this.steerWork(userText);
        return;
      }
      promptAction.showToast({ message: 'AI 正在回复中，请稍候', duration: 2000 });
      return;
    }
    if (this.context === null) {
      return;
    }
    if (this.apiConfig.apiKey === '') {
      promptAction.showToast({ message: '请先配置 API Key', duration: 2000 });
      return;
    }
    if (this.currentAgent === null) {
      promptAction.showToast({ message: '请先选择一个智能体', duration: 2000 });
      return;
    }
    let parsing: FileItem[] = this.pendingFiles.filter((f: FileItem): boolean => f.isParsing);
    if (parsing.length > 0) {
      promptAction.showToast({ message: '文件解析中，请稍候', duration: 2000 });
      return;
    }
    // 确保有对话
    if (this.currentConversationId === '' || this.currentConversation === null) {
      await this.startNewConversation();
    }
    let convOpt: Conversation | null = this.currentConversation;
    if (convOpt === null) {
      return;
    }
    // 闭包内不继承可空变量的收窄, 先落成非空局部量
    let conv: Conversation = convOpt;

    // ===== 工作模式: Agent Loop 任务 =====
    if (conv.mode === 'work') {
      let workFullText: string = userText;
      if (this.workspaceJustAdded.length > 0) {
        let note: string = '【已上传到工作区的文件】' + this.workspaceJustAdded.join(', ');
        workFullText = note + '\n\n' + userText;
        this.workspaceJustAdded = [];
      }
      let workUserMsg: Message = Message.ofUser(generateMessageId(), workFullText, userText, []);
      conv.messages.push(workUserMsg);
      if (conv.title === '') {
        conv.title = userText.length > 24 ? userText.substring(0, 24) + '...' : userText;
      }
      this.persistConversations();
      await this.executeWorkLoop(conv);
      return;
    }

    // 可发送附件包含先行解析结果与直传附件；只有前者需要拼接解析文本。
    let ready: FileItem[] = this.pendingFiles.filter((f: FileItem): boolean =>
      !f.isParsing && !f.error && (f.parsedText !== '' || f.dataUrl !== ''));
    let parsedReady: FileItem[] = ready.filter((f: FileItem): boolean => f.parsedText !== '');
    let fullText: string = userText;
    if (parsedReady.length > 0) {
      let parts: string[] = [];
      for (let i: number = 0; i < parsedReady.length; i++) {
        parts.push('【文件解析：' + parsedReady[i].name + '】\n' + parsedReady[i].parsedText);
      }
      fullText = parts.join('\n\n') + '\n\n' + userText;
    }
    // 构造附件
    let attachments: Attachment[] = [];
    for (let i: number = 0; i < ready.length; i++) {
      let f: FileItem = ready[i];
      let type: string = f.type.startsWith('image/') ? 'image' : 'file';
      attachments.push(Attachment.of(f.name, f.parsedText, type, f.thumbnail, f.dataUrl, ''));
    }
    // 混合发送策略：大图/火山文档优先上传 Files API，上传失败自动回退 Base64
    await this.prepareAttachmentFileIds(attachments, ready);
    // 添加 user 消息
    let userMsg: Message = Message.ofUser(generateMessageId(), fullText, userText, attachments);
    conv.messages.push(userMsg);
    // 自动命名
    if (conv.title === '') {
      conv.title = userText.length > 24 ? userText.substring(0, 24) + '...' : userText;
    }
    this.pendingFiles = [];
    this.fileBuffers.clear();
    this.persistConversations();

    // 添加 assistant 占位
    let assistantMsg: Message = Message.ofAssistant(generateMessageId(), '');
    conv.messages.push(assistantMsg);

    this.abortSignal = new AbortSignal();
    this.markStreamStart();
    this.streamTarget = assistantMsg;
    this.streamTimer = -1;

    // 构造 history(不包含 user 占位 assistant)
    let history: Message[] = conv.messages.slice(0, conv.messages.length - 1);

    // 流式请求 + 本地联网搜索工具循环(search_web 由模型决定, 本地执行后回灌)
    await this.runChatStream(conv, assistantMsg, history, fullText);
  }

  // ===== 工作模式 Agent Loop 主循环 (Codex 式时间线) =====
  // 每轮独立一条 assistant 消息; 模型每轮按 思考 → 叙述文字 → 工具调用 的顺序流式输出,
  // 工具调用在生成参数过程中即以 preparing 态进入时间线(WorkTurnView 按此顺序渲染),
  // 执行期间保持可见, 结果写回后翻转为完成态。有工具调用则执行后继续下一轮, 无则收尾。
  // 缓存设计(对齐 DeepSeek Harness): 系统提示词静态不变; 日期/文件树/任务清单通过
  // 「运行时上下文」快照 user 消息追加到历史末尾且仅在内容变化时追加; 历史严格
  // 追加式增长(压缩是唯一改写历史的操作)。相邻两轮请求因此共享逐字节相同的前缀,
  // 模型侧 KV 缓存可跨轮命中, 每轮只有真正新增的尾部需要重新计算。
  private async executeWorkLoop(conv: Conversation): Promise<void> {
    if (Constants.WORK_USE_DRIVER_LOOP) {
      await this.executeWorkLoopDriver(conv);
      return;
    }
    this.abortSignal = new AbortSignal();
    this.workStateMachine.reset();
    this.workStateMachine.start();
    let metrics: LoopMetrics = new LoopMetrics();
    let traceSeq: number = 0;
    this.markStreamStart();
    this.streamTimer = -1;
    this.lastWorkPromptTokens = 0;
    this.lastWorkPromptChars = 0;
    this.workRepeatKey = '';
    this.workRepeatCount = 0;
    this.workRepeatDetector.reset();
    this.workSteerQueue = [];
    this.pendingAsk = null;
    if (this.context !== null) {
      SubagentService.bind(this.apiConfig, this.thinkingEnabled, this.reasoningEffort,
        (ctx: common.UIAbilityContext, cid: string, name: string, argsJson: string,
          abortSignal?: AbortSignal | null): Promise<ToolExecResult> => {
          let signal: AbortSignal | null =
            abortSignal !== undefined && abortSignal !== null ? abortSignal : null;
          return WorkToolRunner.execute(ctx, cid, name, argsJson, signal);
        });
    }

    let turnToolEvents: Record<string, Object>[] = [];

    try {
      // 组装与协议无关的循环历史(含既有全部消息); 系统提示词为静态文本, 整个循环不重写
      let messages: LoopMessage[] = [];
      messages.push(LoopMessage.system(AgentLoopService.buildWorkSystemPrompt()));
      for (let i: number = 0; i < conv.messages.length; i++) {
        let m: Message = conv.messages[i];
        if (m.role === 'user' && m.content !== '') {
          messages.push(LoopMessage.user(m.content));
        } else if (m.role === 'assistant' && (m.content !== '' || m.toolCalls.length > 0)) {
          // 中断遗留的空结果标记为已中断, 避免模型把空串当成功
          let calls: ToolCallRecord[] = m.toolCalls;
          for (let c: number = 0; c < calls.length; c++) {
            if (calls[c].result === '') {
              calls[c].result = '(执行被中断, 无结果)';
              calls[c].isError = true;
              calls[c].cancelled = true;
              if (calls[c].durationMs < 0) {
                calls[c].durationMs = 0;
              }
            }
          }
          messages.push(LoopMessage.assistant(m.content, calls));
        }
      }

      // 会话事件日志(对齐 dsh append-only session log): turn/start 留痕
      let lastUserText: string = '';
      for (let i: number = conv.messages.length - 1; i >= 0; i--) {
        if (conv.messages[i].role === 'user' && conv.messages[i].content !== '') {
          lastUserText = conv.messages[i].content;
          break;
        }
      }
      if (this.context !== null) {
        let turnStartPayload: Record<string, Object> = { 'user': lastUserText };
        if (AgentLoopService.lastPromptBudget !== null) {
          turnStartPayload['promptBudget'] = AgentLoopService.lastPromptBudget;
        }
        if (AgentLoopService.lastProtocol !== '') {
          turnStartPayload['protocol'] = AgentLoopService.lastProtocol;
        }
        SessionLogService.append(this.context, conv.id, 'turn_start', turnStartPayload);
      }
      let turnEndStatus: string = 'complete';
      let finalAnswerText: string = '';

      let step: number = 0;
      for (step = 0; step < Constants.WORK_MAX_STEPS; step++) {
        if (this.abortSignal.aborted) {
          turnEndStatus = 'aborted';
          break;
        }
        if (this.context === null) {
          break;
        }
        let ctx: common.UIAbilityContext = this.context;
        // 本轮独立消息: 本轮的思考/工具/文本都挂在这一条上
        let turnMsg: Message = Message.ofAssistant(generateMessageId(), '');
        conv.messages.push(turnMsg);
        this.streamTarget = turnMsg;
        this.persistConversations();
        this.notifyUIChange();

        // 上下文预算管理(缓存感知): 超预算先无模型剪枝, 再前缀复用式压缩, 最后整条裁剪。
        // assistant 与其工具结果在同一条消息内, 压缩/裁剪都不会拆散协议对;
        // 任务清单与工作区文件不参与压缩, 始终可由模型 read_file 找回。
        let compactNote: string = await this.compactWorkHistoryIfNeeded(messages, false);
        if (compactNote !== '') {
          metrics.recordCompaction();
        }
        // 运行时快照(取代旧的系统提示词内嵌刷新): 内容与历史末尾快照一致时不追加,
        // 请求前缀保持逐字节稳定——这是跨轮 KV 缓存命中的关键。
        await this.appendRuntimeSnapshotIfNeeded(messages, ctx, conv.id);

        let streamStartMs: number = Date.now();
        let callbacks: LoopTurnCallbacks = new LoopTurnCallbacks();
        callbacks.onToken = (delta: string): void => {
          turnMsg.content += delta;
          this.updateLiveTokenSpeed(turnMsg, streamStartMs);
          this.scheduleStreamUpdate();
        };
        callbacks.onReasoning = (text: string): void => {
          turnMsg.reasoning = text;
          this.updateLiveTokenSpeed(turnMsg, streamStartMs);
          this.scheduleStreamUpdate();
        };
        callbacks.onToolCalls = (calls: ToolCallRecord[]): void => {
          // 模型生成调用参数的过程中即时同步到时间线(preparing 态),
          // 由 WorkTurnView 的流式定时器在 33ms 内上屏, 不等整轮响应结束
          for (let i: number = 0; i < calls.length; i++) {
            let call: ToolCallRecord = calls[i];
            if (call.name === '' || turnMsg.toolCalls.indexOf(call) >= 0) {
              continue;
            }
            turnMsg.toolCalls.push(call);
            call.preparing = true;
          }
        };
        callbacks.onUsage = (speed: number, hit: number): void => {
          if (speed > 0) {
            turnMsg.tokenSpeed = speed;
          }
          if (hit >= 0) {
            turnMsg.cacheHitRate = hit;
          }
          this.scheduleStreamUpdate();
        };

        callbacks.onRetry = (attempt: number, reason: string): void => {
          metrics.recordRetry();
          // 重试会重新流式输出: 先清掉上一次尝试的部分内容避免重复, 保留压缩标注
          turnMsg.content = compactNote + '⚠️ ' + reason + '，自动重试(第 ' +
            attempt.toString() + ' 次)…\n\n';
          turnMsg.reasoning = '';
          turnMsg.toolCalls = [];
          this.scheduleStreamUpdate();
        };

        // 记录请求字符量, 与 usage 的真实 prompt tokens 配对, 推导本会话字符→token 比例
        let requestChars: number = loopMsgChars(messages);
        let turn: LoopTurnResult = await this.runStepWithOverflowRetry(
          messages, turnMsg, compactNote, callbacks, ctx, conv.id, (): void => {
            // 上下文超限强制压缩后重试: 清掉上一次尝试已流出的部分工具行
            metrics.recordCompaction();
            turnMsg.toolCalls = [];
          });
        if (this.abortSignal.aborted) {
          turnEndStatus = 'aborted';
          this.finalizeWorkTurn(turnMsg, true, conv);
          break;
        }
        // 评估指标: 每轮记录是否携带工具调用(无工具调用的轮次计为无效步)
        metrics.recordTurn(turn.toolCalls.length > 0);
        if (turn.promptTokens > 0) {
          this.lastWorkPromptTokens = turn.promptTokens;
          this.lastWorkPromptChars = requestChars;
        }
        // 步骤事件留痕(assistant 内容 + 思考摘要 + 调用清单)
        if (ctx !== null) {
          let callsForLog: Object[] = [];
          for (let i: number = 0; i < turn.toolCalls.length; i++) {
            let callLog: Record<string, Object> = {
              'id': turn.toolCalls[i].id,
              'name': turn.toolCalls[i].name,
              'args': turn.toolCalls[i].argsJson.substring(0, 2000)
            };
            callsForLog.push(callLog);
          }
          let logPayload: Record<string, Object> = {
            'step': step,
            'content': turn.content,
            'reasoning': turn.reasoning.length > Constants.WORK_LOG_REASONING_CHARS ?
              turn.reasoning.substring(0, Constants.WORK_LOG_REASONING_CHARS) +
              '…(已截断)' : turn.reasoning,
            'toolCalls': callsForLog,
            'finishReason': turn.finishReason
          };
          SessionLogService.append(ctx, conv.id, 'assistant_message', logPayload);
        }

        // 单轮评估: 由纯决策层 WorkLoopPlanner 决定下一步(工具/收尾/压缩/中止)
        let planInfo: WorkLoopTurnInfo = new WorkLoopTurnInfo();
        planInfo.toolCallsCount = turn.toolCalls.length;
        planInfo.contentLength = turn.content.length;
        planInfo.finishReason = turn.finishReason;
        planInfo.aborted = this.abortSignal.aborted;
        let plan = WorkLoopPlanner.decide(planInfo);
        if (plan.action === WorkLoopStep.FINISH) {
          finalAnswerText = turn.content;
          this.finalizeWorkTurn(turnMsg, false, conv);
          // 粘性 max-tokens(对齐 dsh): 输出顶到上限即收尾并提示续跑
          if (LoopDecisions.shouldBreakOnMaxTokens(turn.finishReason)) {
            metrics.recordMaxTokens();
            this.appendTurnNote(turnMsg, ' 本轮输出达到模型上限(max tokens), 已自动收尾。发送"继续"接着输出。');
            turnEndStatus = 'max_tokens';
          }
          break;
        }

        // 工具轮: 连续的“只读或并行安全”调用经有界滚动池并发执行(上限 WORK_MAX_PARALLEL_TOOLS,
        // UI 按完成顺序展示, 给模型的 tool_result 仍按模型顺序提交), 其余调用逐个执行(对齐 dsh 的 exclusive/parallel 调度)。
        // subagent 为并行安全工具: 独立上下文/独立 LLM 循环, 多个子代理可并行派发。
        // fromTurn 携带思考文本与签名: Anthropic 思考模式下下一轮请求需回传 thinking 块
        let turnLoopMsg: LoopMessage = LoopMessage.fromTurn(turn);
        let imageDataUrl: string = '';
        let imagePath: string = '';
        let reminders: string[] = [];
        let parallelFlags: boolean[] = [];
        for (let f: number = 0; f < turn.toolCalls.length; f++) {
          let toolName: string = turn.toolCalls[f].name;
          parallelFlags.push(WorkFileService.isReadOnlyTool(toolName) ||
            (Constants.WORK_ALLOW_PARALLEL_SUBAGENTS && WorkFileService.isParallelSafeTool(toolName)));
        }
        let groups: ScheduledGroup[] = ToolScheduler.schedule(
          parallelFlags, Constants.WORK_MAX_PARALLEL_TOOLS, Constants.WORK_ALLOW_PARALLEL_TOOLS);
        for (let g: number = 0; g < groups.length; g++) {
          let group: ScheduledGroup = groups[g];
          let ci: number = group.start;
          let gj: number = ci + group.count;
          if (this.abortSignal.aborted) {
            break;
          }
          let headCall: ToolCallRecord = turn.toolCalls[ci];
          if (group.parallel) {
            // 并行组: 先整体展示“执行中”状态, 再经有界滚动池并发执行;
            // 谁先完成谁先回填结果/刷新 UI(不再按模型顺序等待); 给模型的 tool_result 仍按原顺序保留。
            for (let k: number = ci; k < gj; k++) {
              this.ensureToolRecordOnTimeline(turnMsg, turn.toolCalls[k]);
            }
            for (let k: number = ci; k < gj; k++) {
              // 模型参数已生成完: 未启动的进入“等待中”, 已启动的进入“执行中”
              turn.toolCalls[k].preparing = false;
            }
            this.persistConversations();
            this.notifyUIChange();
            // 先让"执行中"工具行上屏, 再开始可能长时间占用主线程的同步工具执行
            await this.sleep(30);
            let groupCount: number = gj - ci;
            let poolSize: number = ToolScheduler.poolSize(group, Constants.WORK_MAX_PARALLEL_TOOLS);
            let nextIdx: number = poolSize;
            let remaining: number = groupCount;
            await new Promise<void>((resolve: () => void, _reject: (e: Error) => void): void => {
              let finishExec = (cur: ToolCallRecord, exec: ToolExecResult, execStart: number): void => {
                this.applyToolResult(ctx, conv.id, cur, exec, execStart);
                metrics.recordToolCall(!cur.isError, cur.timeout, cur.cancelled, cur.schemaError);
                if (cur.name === 'subagent') {
                  metrics.recordSubagentCall();
                }
                if (cur.traceId === '') {
                  cur.traceId = 'call-' + traceSeq.toString();
                }
                traceSeq++;
                if (exec.imageDataUrl !== '') {
                  imageDataUrl = exec.imageDataUrl;
                  imagePath = parseToolArgPath(cur.argsJson);
                }
                if (ctx !== null) {
                  let toolEvent: Record<string, Object> = {
                    'step': step,
                    'name': cur.name,
                    'ok': !cur.isError,
                    'durationMs': cur.durationMs,
                    'timeout': cur.timeout,
                    'cancelled': cur.cancelled,
                    'schemaError': cur.schemaError,
                    'traceId': cur.traceId,
                    'result': cur.result
                  };
                  turnToolEvents.push(toolEvent);
                  SessionLogService.append(ctx, conv.id, 'tool_result', toolEvent);
                }
                let reminder: string = this.noteWorkRepeat(cur);
                if (reminder !== '') {
                  reminders.push(reminder);
                }
                this.persistConversations();
                this.notifyUIChange();
                remaining--;
                if (remaining === 0) {
                  resolve();
                  return;
                }
                if (nextIdx < groupCount) {
                  let n: number = nextIdx;
                  nextIdx++;
                  launchOne(n);
                }
              };
              let launchOne = (idx: number): void => {
                let cur: ToolCallRecord = turn.toolCalls[ci + idx];
                let execStart: number = Date.now();
                // 每个调用只允许完成一次(成功或失败二选一), 防止 then 处理器内部抛错时
                // 被 catch 再次回填导致计数重复
                let settled: boolean = false;
                let finishOnce = (exec: ToolExecResult): void => {
                  if (settled) {
                    return;
                  }
                  settled = true;
                  finishExec(cur, exec, execStart);
                };
                cur.preparing = false;
                cur.started = true;
                WorkToolRunner.execute(ctx, conv.id, cur.name, cur.argsJson, this.abortSignal)
                  .then((exec: ToolExecResult): void => {
                    finishOnce(exec);
                  })
                  .catch((e: Error): void => {
                    let exec: ToolExecResult = new ToolExecResult();
                    exec.ok = false;
                    let msg: string = e.message !== undefined ? e.message : '并行工具执行失败';
                    exec.output = 'ERROR: ' + msg;
                    finishOnce(exec);
                  });
              };
              for (let k: number = 0; k < poolSize; k++) {
                launchOne(k);
              }
              this.notifyUIChange();
            });
            // 并行组也可能产生 .spill 溢出文件, 组结束后同样刷新面板
            await this.refreshWorkspace();
          } else {
            this.ensureToolRecordOnTimeline(turnMsg, headCall);
            this.persistConversations();
            this.notifyUIChange();
            await this.sleep(30);
            headCall.preparing = false;
            headCall.started = true;
            this.notifyUIChange();
            let execStart: number = Date.now();
            let exec: ToolExecResult = await WorkToolRunner.execute(
              ctx, conv.id, headCall.name, headCall.argsJson, this.abortSignal);
            this.applyToolResult(ctx, conv.id, headCall, exec, execStart);
            metrics.recordToolCall(!headCall.isError, headCall.timeout, headCall.cancelled, headCall.schemaError);
            if (headCall.name === 'subagent') {
              metrics.recordSubagentCall();
            }
            if (headCall.traceId === '') {
              headCall.traceId = 'call-' + traceSeq.toString();
            }
            traceSeq++;
            if (exec.imageDataUrl !== '') {
              imageDataUrl = exec.imageDataUrl;
              imagePath = parseToolArgPath(headCall.argsJson);
            }
            if (WorkFileService.isMutatingTool(headCall.name) || headCall.name === 'subagent') {
              await this.refreshWorkspace();
            }
            if (ctx !== null) {
              let toolEvent: Record<string, Object> = {
                'step': step,
                'name': headCall.name,
                'ok': !headCall.isError,
                'durationMs': headCall.durationMs,
                'timeout': headCall.timeout,
                'cancelled': headCall.cancelled,
                'schemaError': headCall.schemaError,
                'traceId': headCall.traceId,
                'result': headCall.result
              };
              turnToolEvents.push(toolEvent);
              SessionLogService.append(ctx, conv.id, 'tool_result', toolEvent);
            }
            let reminder: string = this.noteWorkRepeat(headCall);
            if (reminder !== '') {
              reminders.push(reminder);
            }
            this.persistConversations();
            this.notifyUIChange();
          }
        }
        if (this.abortSignal.aborted) {
          turnEndStatus = 'aborted';
          this.finalizeWorkTurn(turnMsg, true, conv);
          break;
        }
        this.finalizeWorkTurn(turnMsg, false, conv);
        // 本轮(assistant + 工具结果)进入下一轮请求历史
        messages.push(turnLoopMsg);
        // view_image: 把图片作为下一条多模态用户消息注入, 供模型视觉分析
        if (imageDataUrl !== '') {
          messages.push(LoopMessage.userImage(
            '【工作区图片】' + imagePath + '\n这是你刚才调用 view_image 读取的图片, 请结合当前任务分析图中内容。',
            imageDataUrl));
        }
        // 重复调用提醒在本轮结果之后追加, 时序上紧跟触发它的那轮工具调用
        for (let r: number = 0; r < reminders.length; r++) {
          messages.push(LoopMessage.user(reminders[r]));
        }
        // 用户插话(next-step steering): 本轮结束后注入, 下一步请求可见
        if (this.workSteerQueue.length > 0) {
          let drained: string[] = this.workSteerQueue;
          this.workSteerQueue = [];
          for (let s: number = 0; s < drained.length; s++) {
            messages.push(LoopMessage.user('【用户补充】' + drained[s]));
          }
        }
      }

      // 步数耗尽: 在最后一条消息上标注(防失控保险, 正常长任务触不到)
      if (!this.abortSignal.aborted && step >= Constants.WORK_MAX_STEPS && conv.messages.length > 0) {
        turnEndStatus = 'max_steps';
        let last: Message = conv.messages[conv.messages.length - 1];
        if (last.role === 'assistant') {
          this.appendTurnNote(last, ' 已连续执行 ' + Constants.WORK_MAX_STEPS.toString() +
            ' 轮工具调用(防失控保险), 发送"继续"可接着执行。');
        }
      }
      if (this.context !== null) {
        SessionLogService.append(this.context, conv.id, 'turn_end', {
          'status': turnEndStatus,
          'metrics': metrics.snapshot()
        });
        this.appendToolLatencyEvents(conv, turnToolEvents);
      }
      if (finalAnswerText !== '' && !this.abortSignal.aborted) {
        this.maybeGenerateTitle(conv, lastUserText, finalAnswerText);
      }
    } catch (e) {
      let err: Error = e as Error;
      if (!this.abortSignal.aborted) {
        let userMsg: string = '';
        if (err instanceof LoopError && (err as LoopError).userMessage !== '') {
          userMsg = (err as LoopError).userMessage;
        }
        let msg: string = userMsg !== '' ? userMsg :
          (err.message !== undefined ? err.message : '任务执行失败');
        let last: Message | null = conv.messages.length > 0 ? conv.messages[conv.messages.length - 1] : null;
        if (last !== null && last.role === 'assistant') {
          this.appendTurnNote(last, '⚠️ ' + msg);
        } else {
          let errMsg: Message = Message.ofAssistant(generateMessageId(), '⚠️ ' + msg);
          errMsg.displayContent = errMsg.content;
          conv.messages.push(errMsg);
        }
        if (this.context !== null) {
          SessionLogService.append(this.context, conv.id, 'turn_end',
            { 'status': 'error', 'error': msg, 'metrics': metrics.snapshot() });
          this.appendToolLatencyEvents(conv, turnToolEvents);
        }
      }
    } finally {
      this.markStreamEnd();
      if (this.abortSignal.aborted) {
        this.workStateMachine.abort();
        this.workStateMachine.aborted();
      } else {
        this.workStateMachine.finish();
      }
      this.streamTarget = null;
      this.pendingAsk = null;
      AskUserBridge.cancelAll();
      if (this.streamTimer !== -1) {
        clearTimeout(this.streamTimer);
        this.streamTimer = -1;
      }
      this.persistConversations();
      this.notifyUIChange();
    }
  }


private async executeWorkLoopDriver(conv: Conversation): Promise<void> {
    this.abortSignal = new AbortSignal();
    this.workStateMachine.reset();
    this.workStateMachine.start();
    let metrics: LoopMetrics = new LoopMetrics();
    let traceSeq: number = 0;
    this.markStreamStart();
    this.streamTimer = -1;
    this.lastWorkPromptTokens = 0;
    this.lastWorkPromptChars = 0;
    this.workRepeatKey = '';
    this.workRepeatCount = 0;
    this.workRepeatDetector.reset();
    this.workSteerQueue = [];
    this.pendingAsk = null;
    if (this.context !== null) {
      SubagentService.bind(this.apiConfig, this.thinkingEnabled, this.reasoningEffort,
        (ctx: common.UIAbilityContext, cid: string, name: string, argsJson: string,
          abortSignal?: AbortSignal | null): Promise<ToolExecResult> => {
          let signal: AbortSignal | null =
            abortSignal !== undefined && abortSignal !== null ? abortSignal : null;
          return WorkToolRunner.execute(ctx, cid, name, argsJson, signal);
        });
    }

    let turnToolEvents: Record<string, Object>[] = [];

    try {
      // 组装与协议无关的循环历史(含既有全部消息); 系统提示词为静态文本, 整个循环不重写
      let messages: LoopMessage[] = [];
      messages.push(LoopMessage.system(AgentLoopService.buildWorkSystemPrompt()));
      for (let i: number = 0; i < conv.messages.length; i++) {
        let m: Message = conv.messages[i];
        if (m.role === 'user' && m.content !== '') {
          messages.push(LoopMessage.user(m.content));
        } else if (m.role === 'assistant' && (m.content !== '' || m.toolCalls.length > 0)) {
          // 中断遗留的空结果标记为已中断, 避免模型把空串当成功
          let calls: ToolCallRecord[] = m.toolCalls;
          for (let c: number = 0; c < calls.length; c++) {
            if (calls[c].result === '') {
              calls[c].result = '(执行被中断, 无结果)';
              calls[c].isError = true;
              calls[c].cancelled = true;
              if (calls[c].durationMs < 0) {
                calls[c].durationMs = 0;
              }
            }
          }
          messages.push(LoopMessage.assistant(m.content, calls));
        }
      }

      // 会话事件日志(对齐 dsh append-only session log): turn/start 留痕
      let lastUserText: string = '';
      for (let i: number = conv.messages.length - 1; i >= 0; i--) {
        if (conv.messages[i].role === 'user' && conv.messages[i].content !== '') {
          lastUserText = conv.messages[i].content;
          break;
        }
      }
      if (this.context !== null) {
        let turnStartPayload: Record<string, Object> = { 'user': lastUserText };
        if (AgentLoopService.lastPromptBudget !== null) {
          turnStartPayload['promptBudget'] = AgentLoopService.lastPromptBudget;
        }
        if (AgentLoopService.lastProtocol !== '') {
          turnStartPayload['protocol'] = AgentLoopService.lastProtocol;
        }
        SessionLogService.append(this.context, conv.id, 'turn_start', turnStartPayload);
      }
      let turnEndStatus: string = 'complete';
      let finalAnswerText: string = '';

      let step: number = 0;
      let state: WorkLoopStepState = new WorkLoopStepState();
      let res = await WorkLoopDriverBridge.runWithStep(async (i: number): Promise<WorkLoopTurnInfo> => {
        return await this.runDriverStep(conv, messages, metrics, turnToolEvents, state, i);
      }, Constants.WORK_MAX_STEPS, (s: number, action: string, reason?: string): void => {
        if (this.context !== null) {
          SessionLogService.append(this.context, conv.id, 'driver_step',
            { 'step': s, 'action': action, 'reason': reason !== undefined ? reason : '' });
        }
      });
      if (res.maxStepsReached) {
        step = Constants.WORK_MAX_STEPS;
      }
      turnEndStatus = state.turnEndStatus;
      finalAnswerText = state.finalAnswerText;
      if (this.context !== null) {
        SessionLogService.append(this.context, conv.id, 'driver_summary', {
          'steps': res.steps, 'toolSteps': res.toolSteps, 'textSteps': res.textSteps,
          'compactSteps': res.compactSteps, 'retries': res.retries,
          'aborted': res.aborted, 'maxStepsReached': res.maxStepsReached,
          'finalReason': res.finalReason, 'finalState': res.finalState
        });
      }

      // 步数耗尽: 在最后一条消息上标注(防失控保险, 正常长任务触不到)
      if (!this.abortSignal.aborted && step >= Constants.WORK_MAX_STEPS && conv.messages.length > 0) {
        turnEndStatus = 'max_steps';
        let last: Message = conv.messages[conv.messages.length - 1];
        if (last.role === 'assistant') {
          this.appendTurnNote(last, ' 已连续执行 ' + Constants.WORK_MAX_STEPS.toString() +
            ' 轮工具调用(防失控保险), 发送"继续"可接着执行。');
        }
      }
      if (this.context !== null) {
        SessionLogService.append(this.context, conv.id, 'turn_end', {
          'status': turnEndStatus,
          'metrics': metrics.snapshot()
        });
        this.appendToolLatencyEvents(conv, turnToolEvents);
      }
      if (finalAnswerText !== '' && !this.abortSignal.aborted) {
        this.maybeGenerateTitle(conv, lastUserText, finalAnswerText);
      }
    } catch (e) {
      let err: Error = e as Error;
      if (!this.abortSignal.aborted) {
        let userMsg: string = '';
        if (err instanceof LoopError && (err as LoopError).userMessage !== '') {
          userMsg = (err as LoopError).userMessage;
        }
        let msg: string = userMsg !== '' ? userMsg :
          (err.message !== undefined ? err.message : '任务执行失败');
        let last: Message | null = conv.messages.length > 0 ? conv.messages[conv.messages.length - 1] : null;
        if (last !== null && last.role === 'assistant') {
          this.appendTurnNote(last, '⚠️ ' + msg);
        } else {
          let errMsg: Message = Message.ofAssistant(generateMessageId(), '⚠️ ' + msg);
          errMsg.displayContent = errMsg.content;
          conv.messages.push(errMsg);
        }
        if (this.context !== null) {
          SessionLogService.append(this.context, conv.id, 'turn_end',
            { 'status': 'error', 'error': msg, 'metrics': metrics.snapshot() });
          this.appendToolLatencyEvents(conv, turnToolEvents);
        }
      }
    } finally {
      this.markStreamEnd();
      if (this.abortSignal.aborted) {
        this.workStateMachine.abort();
        this.workStateMachine.aborted();
      } else {
        this.workStateMachine.finish();
      }
      this.streamTarget = null;
      this.pendingAsk = null;
      AskUserBridge.cancelAll();
      if (this.streamTimer !== -1) {
        clearTimeout(this.streamTimer);
        this.streamTimer = -1;
      }
      this.persistConversations();
      this.notifyUIChange();
    }
  }

  // 执行一次步骤请求; 若因上下文窗口超限失败(对齐 DeepSeek Harness 对
  // CONTEXT_WINDOW_EXCEEDED 的响应式压缩), 强制压缩历史后重试一次。
  // onForcedRetry: 重试前清掉上一次尝试已流出的部分工具行


  private async runDriverStep(conv: Conversation, messages: LoopMessage[], metrics: LoopMetrics,
    turnToolEvents: Record<string, Object>[], state: WorkLoopStepState, stepIndex: number): Promise<WorkLoopTurnInfo> {
let info: WorkLoopTurnInfo = new WorkLoopTurnInfo();
        if (this.abortSignal.aborted) {
          state.turnEndStatus = 'aborted';
          return WorkLoopStepInfoBuilder.aborted();
        }
        if (this.context === null) {
          return info;
        }
        let step: number = stepIndex;
        let lastTurn: LoopTurnResult | null = null;
        for (let once: number = 0; once < 1; once++) {
if (this.abortSignal.aborted) {
          state.turnEndStatus = 'aborted';
          break;
        }
        if (this.context === null) {
          break;
        }
        let ctx: common.UIAbilityContext = this.context;
        // 本轮独立消息: 本轮的思考/工具/文本都挂在这一条上
        let turnMsg: Message = Message.ofAssistant(generateMessageId(), '');
        conv.messages.push(turnMsg);
        this.streamTarget = turnMsg;
        this.persistConversations();
        this.notifyUIChange();

        // 上下文预算管理(缓存感知): 超预算先无模型剪枝, 再前缀复用式压缩, 最后整条裁剪。
        // assistant 与其工具结果在同一条消息内, 压缩/裁剪都不会拆散协议对;
        // 任务清单与工作区文件不参与压缩, 始终可由模型 read_file 找回。
        let compactNote: string = await this.compactWorkHistoryIfNeeded(messages, false);
        if (compactNote !== '') {
          metrics.recordCompaction();
        }
        // 运行时快照(取代旧的系统提示词内嵌刷新): 内容与历史末尾快照一致时不追加,
        // 请求前缀保持逐字节稳定——这是跨轮 KV 缓存命中的关键。
        await this.appendRuntimeSnapshotIfNeeded(messages, ctx, conv.id);

        let streamStartMs: number = Date.now();
        let callbacks: LoopTurnCallbacks = new LoopTurnCallbacks();
        callbacks.onToken = (delta: string): void => {
          turnMsg.content += delta;
          this.updateLiveTokenSpeed(turnMsg, streamStartMs);
          this.scheduleStreamUpdate();
        };
        callbacks.onReasoning = (text: string): void => {
          turnMsg.reasoning = text;
          this.updateLiveTokenSpeed(turnMsg, streamStartMs);
          this.scheduleStreamUpdate();
        };
        callbacks.onToolCalls = (calls: ToolCallRecord[]): void => {
          // 模型生成调用参数的过程中即时同步到时间线(preparing 态),
          // 由 WorkTurnView 的流式定时器在 33ms 内上屏, 不等整轮响应结束
          for (let i: number = 0; i < calls.length; i++) {
            let call: ToolCallRecord = calls[i];
            if (call.name === '' || turnMsg.toolCalls.indexOf(call) >= 0) {
              continue;
            }
            turnMsg.toolCalls.push(call);
            call.preparing = true;
          }
        };
        callbacks.onUsage = (speed: number, hit: number): void => {
          if (speed > 0) {
            turnMsg.tokenSpeed = speed;
          }
          if (hit >= 0) {
            turnMsg.cacheHitRate = hit;
          }
          this.scheduleStreamUpdate();
        };

        callbacks.onRetry = (attempt: number, reason: string): void => {
          metrics.recordRetry();
          // 重试会重新流式输出: 先清掉上一次尝试的部分内容避免重复, 保留压缩标注
          turnMsg.content = compactNote + '⚠️ ' + reason + '，自动重试(第 ' +
            attempt.toString() + ' 次)…\n\n';
          turnMsg.reasoning = '';
          turnMsg.toolCalls = [];
          this.scheduleStreamUpdate();
        };

        // 记录请求字符量, 与 usage 的真实 prompt tokens 配对, 推导本会话字符→token 比例
        let requestChars: number = loopMsgChars(messages);
        let turn: LoopTurnResult = await this.runStepWithOverflowRetry(
          messages, turnMsg, compactNote, callbacks, ctx, conv.id, (): void => {
            // 上下文超限强制压缩后重试: 清掉上一次尝试已流出的部分工具行
            metrics.recordCompaction();
            turnMsg.toolCalls = [];
          });
        lastTurn = turn;
        if (this.abortSignal.aborted) {
          state.turnEndStatus = 'aborted';
          this.finalizeWorkTurn(turnMsg, true, conv);
          info = WorkLoopStepInfoBuilder.aborted();
          break;
        }
        // 评估指标: 每轮记录是否携带工具调用(无工具调用的轮次计为无效步)
        metrics.recordTurn(turn.toolCalls.length > 0);
        if (turn.promptTokens > 0) {
          this.lastWorkPromptTokens = turn.promptTokens;
          this.lastWorkPromptChars = requestChars;
        }
        // 步骤事件留痕(assistant 内容 + 思考摘要 + 调用清单)
        if (ctx !== null) {
          let callsForLog: Object[] = [];
          for (let i: number = 0; i < turn.toolCalls.length; i++) {
            let callLog: Record<string, Object> = {
              'id': turn.toolCalls[i].id,
              'name': turn.toolCalls[i].name,
              'args': turn.toolCalls[i].argsJson.substring(0, 2000)
            };
            callsForLog.push(callLog);
          }
          let logPayload: Record<string, Object> = {
            'step': step,
            'content': turn.content,
            'reasoning': turn.reasoning.length > Constants.WORK_LOG_REASONING_CHARS ?
              turn.reasoning.substring(0, Constants.WORK_LOG_REASONING_CHARS) +
              '…(已截断)' : turn.reasoning,
            'toolCalls': callsForLog,
            'finishReason': turn.finishReason
          };
          SessionLogService.append(ctx, conv.id, 'assistant_message', logPayload);
        }

        // 单轮评估: 由纯决策层 WorkLoopPlanner 决定下一步(工具/收尾/压缩/中止)
        let planInfo: WorkLoopTurnInfo = new WorkLoopTurnInfo();
        planInfo.toolCallsCount = turn.toolCalls.length;
        planInfo.contentLength = turn.content.length;
        planInfo.finishReason = turn.finishReason;
        planInfo.aborted = this.abortSignal.aborted;
        let plan = WorkLoopPlanner.decide(planInfo);
        if (plan.action === WorkLoopStep.FINISH) {
          state.finalAnswerText = turn.content;
          this.finalizeWorkTurn(turnMsg, false, conv);
          // 粘性 max-tokens(对齐 dsh): 输出顶到上限即收尾并提示续跑
          if (LoopDecisions.shouldBreakOnMaxTokens(turn.finishReason)) {
            metrics.recordMaxTokens();
            this.appendTurnNote(turnMsg, ' 本轮输出达到模型上限(max tokens), 已自动收尾。发送"继续"接着输出。');
            state.turnEndStatus = 'max_tokens';
          }
          info = WorkLoopStepInfoBuilder.finish(turn.content.length, turn.finishReason);
          break;
        }

        // 工具轮: 连续的“只读或并行安全”调用经有界滚动池并发执行(上限 WORK_MAX_PARALLEL_TOOLS,
        // UI 按完成顺序展示, 给模型的 tool_result 仍按模型顺序提交), 其余调用逐个执行(对齐 dsh 的 exclusive/parallel 调度)。
        // subagent 为并行安全工具: 独立上下文/独立 LLM 循环, 多个子代理可并行派发。
        // fromTurn 携带思考文本与签名: Anthropic 思考模式下下一轮请求需回传 thinking 块
        let turnLoopMsg: LoopMessage = LoopMessage.fromTurn(turn);
        let imageDataUrl: string = '';
        let imagePath: string = '';
        let reminders: string[] = [];
        let parallelFlags: boolean[] = [];
        for (let f: number = 0; f < turn.toolCalls.length; f++) {
          let toolName: string = turn.toolCalls[f].name;
          parallelFlags.push(WorkFileService.isReadOnlyTool(toolName) ||
            (Constants.WORK_ALLOW_PARALLEL_SUBAGENTS && WorkFileService.isParallelSafeTool(toolName)));
        }
        let groups: ScheduledGroup[] = ToolScheduler.schedule(
          parallelFlags, Constants.WORK_MAX_PARALLEL_TOOLS, Constants.WORK_ALLOW_PARALLEL_TOOLS);
        for (let g: number = 0; g < groups.length; g++) {
          let group: ScheduledGroup = groups[g];
          let ci: number = group.start;
          let gj: number = ci + group.count;
          if (this.abortSignal.aborted) {
            break;
          }
          let headCall: ToolCallRecord = turn.toolCalls[ci];
          if (group.parallel) {
            // 并行组: 先整体展示“执行中”状态, 再经有界滚动池并发执行;
            // 谁先完成谁先回填结果/刷新 UI(不再按模型顺序等待); 给模型的 tool_result 仍按原顺序保留。
            for (let k: number = ci; k < gj; k++) {
              this.ensureToolRecordOnTimeline(turnMsg, turn.toolCalls[k]);
            }
            for (let k: number = ci; k < gj; k++) {
              // 模型参数已生成完: 未启动的进入“等待中”, 已启动的进入“执行中”
              turn.toolCalls[k].preparing = false;
            }
            this.persistConversations();
            this.notifyUIChange();
            // 先让"执行中"工具行上屏, 再开始可能长时间占用主线程的同步工具执行
            await this.sleep(30);
            let groupCount: number = gj - ci;
            let poolSize: number = ToolScheduler.poolSize(group, Constants.WORK_MAX_PARALLEL_TOOLS);
            let nextIdx: number = poolSize;
            let remaining: number = groupCount;
            await new Promise<void>((resolve: () => void, _reject: (e: Error) => void): void => {
              let finishExec = (cur: ToolCallRecord, exec: ToolExecResult, execStart: number): void => {
                this.applyToolResult(ctx, conv.id, cur, exec, execStart);
                metrics.recordToolCall(!cur.isError, cur.timeout, cur.cancelled, cur.schemaError);
                if (cur.name === 'subagent') {
                  metrics.recordSubagentCall();
                }
                if (cur.traceId === '') {
                  cur.traceId = 'call-' + state.traceSeq.toString();
                }
                state.traceSeq++;
                if (exec.imageDataUrl !== '') {
                  imageDataUrl = exec.imageDataUrl;
                  imagePath = parseToolArgPath(cur.argsJson);
                }
                if (ctx !== null) {
                  let toolEvent: Record<string, Object> = {
                    'step': step,
                    'name': cur.name,
                    'ok': !cur.isError,
                    'durationMs': cur.durationMs,
                    'timeout': cur.timeout,
                    'cancelled': cur.cancelled,
                    'schemaError': cur.schemaError,
                    'traceId': cur.traceId,
                    'result': cur.result
                  };
                  turnToolEvents.push(toolEvent);
                  SessionLogService.append(ctx, conv.id, 'tool_result', toolEvent);
                }
                let reminder: string = this.noteWorkRepeat(cur);
                if (reminder !== '') {
                  reminders.push(reminder);
                }
                this.persistConversations();
                this.notifyUIChange();
                remaining--;
                if (remaining === 0) {
                  resolve();
                  return;
                }
                if (nextIdx < groupCount) {
                  let n: number = nextIdx;
                  nextIdx++;
                  launchOne(n);
                }
              };
              let launchOne = (idx: number): void => {
                let cur: ToolCallRecord = turn.toolCalls[ci + idx];
                let execStart: number = Date.now();
                // 每个调用只允许完成一次(成功或失败二选一), 防止 then 处理器内部抛错时
                // 被 catch 再次回填导致计数重复
                let settled: boolean = false;
                let finishOnce = (exec: ToolExecResult): void => {
                  if (settled) {
                    return;
                  }
                  settled = true;
                  finishExec(cur, exec, execStart);
                };
                cur.preparing = false;
                cur.started = true;
                WorkToolRunner.execute(ctx, conv.id, cur.name, cur.argsJson, this.abortSignal)
                  .then((exec: ToolExecResult): void => {
                    finishOnce(exec);
                  })
                  .catch((e: Error): void => {
                    let exec: ToolExecResult = new ToolExecResult();
                    exec.ok = false;
                    let msg: string = e.message !== undefined ? e.message : '并行工具执行失败';
                    exec.output = 'ERROR: ' + msg;
                    finishOnce(exec);
                  });
              };
              for (let k: number = 0; k < poolSize; k++) {
                launchOne(k);
              }
              this.notifyUIChange();
            });
            // 并行组也可能产生 .spill 溢出文件, 组结束后同样刷新面板
            await this.refreshWorkspace();
          } else {
            this.ensureToolRecordOnTimeline(turnMsg, headCall);
            this.persistConversations();
            this.notifyUIChange();
            await this.sleep(30);
            headCall.preparing = false;
            headCall.started = true;
            this.notifyUIChange();
            let execStart: number = Date.now();
            let exec: ToolExecResult = await WorkToolRunner.execute(
              ctx, conv.id, headCall.name, headCall.argsJson, this.abortSignal);
            this.applyToolResult(ctx, conv.id, headCall, exec, execStart);
            metrics.recordToolCall(!headCall.isError, headCall.timeout, headCall.cancelled, headCall.schemaError);
            if (headCall.name === 'subagent') {
              metrics.recordSubagentCall();
            }
            if (headCall.traceId === '') {
              headCall.traceId = 'call-' + state.traceSeq.toString();
            }
            state.traceSeq++;
            if (exec.imageDataUrl !== '') {
              imageDataUrl = exec.imageDataUrl;
              imagePath = parseToolArgPath(headCall.argsJson);
            }
            if (WorkFileService.isMutatingTool(headCall.name) || headCall.name === 'subagent') {
              await this.refreshWorkspace();
            }
            if (ctx !== null) {
              let toolEvent: Record<string, Object> = {
                'step': step,
                'name': headCall.name,
                'ok': !headCall.isError,
                'durationMs': headCall.durationMs,
                'timeout': headCall.timeout,
                'cancelled': headCall.cancelled,
                'schemaError': headCall.schemaError,
                'traceId': headCall.traceId,
                'result': headCall.result
              };
              turnToolEvents.push(toolEvent);
              SessionLogService.append(ctx, conv.id, 'tool_result', toolEvent);
            }
            let reminder: string = this.noteWorkRepeat(headCall);
            if (reminder !== '') {
              reminders.push(reminder);
            }
            this.persistConversations();
            this.notifyUIChange();
          }
        }
        if (this.abortSignal.aborted) {
          state.turnEndStatus = 'aborted';
          this.finalizeWorkTurn(turnMsg, true, conv);
          info = WorkLoopStepInfoBuilder.aborted();
          break;
        }
        this.finalizeWorkTurn(turnMsg, false, conv);
        // 本轮(assistant + 工具结果)进入下一轮请求历史
        messages.push(turnLoopMsg);
        // view_image: 把图片作为下一条多模态用户消息注入, 供模型视觉分析
        if (imageDataUrl !== '') {
          messages.push(LoopMessage.userImage(
            '【工作区图片】' + imagePath + '\n这是你刚才调用 view_image 读取的图片, 请结合当前任务分析图中内容。',
            imageDataUrl));
        }
        // 重复调用提醒在本轮结果之后追加, 时序上紧跟触发它的那轮工具调用
        for (let r: number = 0; r < reminders.length; r++) {
          messages.push(LoopMessage.user(reminders[r]));
        }
        // 用户插话(next-step steering): 本轮结束后注入, 下一步请求可见
        if (this.workSteerQueue.length > 0) {
          let drained: string[] = this.workSteerQueue;
          this.workSteerQueue = [];
          for (let s: number = 0; s < drained.length; s++) {
            messages.push(LoopMessage.user('【用户补充】' + drained[s]));
          }
        }
        }
        if (lastTurn !== null) {
          return WorkLoopStepInfoBuilder.tool(lastTurn.toolCalls.length,
            lastTurn.content.length, lastTurn.finishReason);
        }
        return info;

  }  private async runStepWithOverflowRetry(messages: LoopMessage[], turnMsg: Message,
    compactNote: string, callbacks: LoopTurnCallbacks,
    ctx: common.UIAbilityContext, convId: string,
    onForcedRetry: () => void): Promise<LoopTurnResult> {
    try {
      return await AgentLoopService.runTurnWithRetry(
        this.apiConfig, messages, this.thinkingEnabled, this.reasoningEffort, this.webSearchEnabled,
        callbacks, this.abortSignal);
    } catch (e) {
      let err: Error = e as Error;
      if (LoopDecisions.shouldForceCompactOnOverflow(this.abortSignal.aborted,
        err instanceof LoopError && (err as LoopError).isContextOverflow(), false)) {
        let forcedNote: string = await this.compactWorkHistoryIfNeeded(messages, true);
        if (forcedNote !== '') {
          turnMsg.content = forcedNote;
          onForcedRetry();
          this.scheduleStreamUpdate();
          // 压缩改写了历史, 末尾快照可能已随旧历史被移除, 重试前重新补快照
          await this.appendRuntimeSnapshotIfNeeded(messages, ctx, convId);
          return await AgentLoopService.runTurnWithRetry(
            this.apiConfig, messages, this.thinkingEnabled, this.reasoningEffort, this.webSearchEnabled,
            callbacks, this.abortSignal);
        }
      }
      throw err;
    }
  }

  // 把工具调用同步到时间线(若流式阶段已同步过则跳过, 保持一次且仅一次)
  private ensureToolRecordOnTimeline(turnMsg: Message, call: ToolCallRecord): void {
    if (turnMsg.toolCalls.indexOf(call) >= 0) {
      return;
    }
    turnMsg.toolCalls.push(call);
  }

  // 追加运行时快照(日期/文件树/任务清单/目标/提醒): 仅当与历史末尾已有快照内容不一致时追加
  private async appendRuntimeSnapshotIfNeeded(messages: LoopMessage[],
    ctx: common.UIAbilityContext, convId: string): Promise<void> {
    let tree: string = await WorkFileService.listWorkspaceTree(ctx, convId);
    let todoText: string = WorkFileService.readTodo(ctx, convId);
    let goalText: string = '';
    let scheduleText: string = '';
    let root: string = WorkFileService.workspaceRoot(ctx, convId);
    let goal = GoalService.read(root);
    if (goal !== null) {
      goalText = GoalService.render(goal);
    }
    scheduleText = ScheduleService.renderList(ScheduleService.list(root));
    let snapshot: string = AgentLoopService.buildRuntimeSnapshot(tree, todoText, goalText, scheduleText);
    if (LoopDecisions.shouldAppendSnapshot(AgentLoopService.findLastSnapshot(messages), snapshot)) {
      messages.push(LoopMessage.user(snapshot));
    }
  }

  // 缓存感知的上下文压缩(对齐 DeepSeek Harness compaction-basic 的两级策略)。
  // 返回需要展示在时间线上的标注文本(未触发返回空串)。
  // 1) 预算判断: 优先以上一请求真实 prompt tokens(usage 锚定)对比 1M 窗口阈值,
  //    无 usage 数据时用本会话实测字符→token 比例估算。
  // 2) 第一级(无模型参与): 修剪早期过长的工具结果为头尾节选; 已达预算则不再调模型。
  // 3) 第二级(前缀复用): 摘要请求自带完整前缀(静态系统提示词+工具+历史), 仅在末尾
  //    追加固定压缩指令——对模型侧 KV 缓存而言是上一请求的延续, 前缀部分按缓存命中计价。
  // 4) 兜底: 摘要失败或压缩后仍超预算时, 从最旧处整条丢弃。
  // 把本 turn 的 tool_result 聚合成 tool_latency 事件落日志
  private appendToolLatencyEvents(conv: Conversation, turnToolEvents: Record<string, Object>[]): void {
    if (this.context === null) {
      return;
    }
    let evs: Record<string, Object>[] = SessionLogAggregator.buildToolLatencyEvents(turnToolEvents);
    for (let i: number = 0; i < evs.length; i++) {
      SessionLogService.append(this.context, conv.id, 'tool_latency', evs[i]);
    }
  }

  private async compactWorkHistoryIfNeeded(messages: LoopMessage[], force: boolean): Promise<string> {
    if (!force && !this.workHistoryOverBudget(messages)) {
      return '';
    }
    let notes: string = '';
    let oldEnd: number = messages.length -
      Math.min(Constants.WORK_COMPACT_KEEP_MESSAGES, messages.length - 1);
    // 第一级: 修剪早期过长的工具结果(模型无参与, 零成本; 原文可随时用工具重新获取)
    if (oldEnd > 1 && pruneOldToolResults(messages, 1, oldEnd)) {
      notes += '（已自动修剪早期过长的工具结果以释放上下文）\n\n';
    }
    if (!force && !this.workHistoryOverBudget(messages)) {
      return notes;
    }
    // 第二级: 前缀复用式摘要压缩
    let compacted: boolean = false;
    if (oldEnd > 1) {
      let summary: string = '';
      try {
        summary = await AgentLoopService.summarizeHistory(
          this.apiConfig, messages, this.thinkingEnabled, this.reasoningEffort, this.webSearchEnabled,
          this.abortSignal);
      } catch (e) {
        // 压缩失败(网络/中断) → 回退为整条裁剪
        summary = '';
      }
      if (!this.abortSignal.aborted && summary.trim() !== '') {
        if (summary.length > Constants.WORK_SUMMARY_MAX_CHARS) {
          summary = summary.substring(0, Constants.WORK_SUMMARY_MAX_CHARS) + '…';
        }
        let kept: LoopMessage[] = messages.slice(oldEnd);
        let rebuilt: LoopMessage[] = [LoopMessage.system(AgentLoopService.buildWorkSystemPrompt()),
          LoopMessage.user('【上下文压缩】以下为此前 ' + (oldEnd - 1).toString() +
            ' 条执行历史的状态摘要, 请基于它继续任务:\n' + summary)];
        for (let k: number = 0; k < kept.length; k++) {
          rebuilt.push(kept[k]);
        }
        messages.splice(0, messages.length);
        for (let k: number = 0; k < rebuilt.length; k++) {
          messages.push(rebuilt[k]);
        }
        compacted = true;
        notes += '（已自动压缩早期历史: ' + (oldEnd - 1).toString() +
          ' 条已汇总为状态摘要）\n\n';
      }
    }
    // 压缩后(或压缩失败时)仍超预算 → 从最旧处整条丢弃
    let threshold: number = Constants.WORK_CONTEXT_WINDOW_TOKENS * Constants.WORK_COMPACT_TOKEN_RATIO;
    while (this.estimateWorkTokens(loopMsgChars(messages)) >= threshold && messages.length > 2) {
      messages.splice(1, 1);
      compacted = true;
    }
    if (compacted && notes.indexOf('已自动压缩早期历史') < 0) {
      notes += '（已自动裁剪早期历史以释放上下文）\n\n';
    }
    // usage 锚定值已失效(历史被改写), 下一请求重新测量
    this.lastWorkPromptTokens = 0;
    this.lastWorkPromptChars = 0;
    return notes;
  }

  // 上下文是否超预算: 上一请求真实 usage 已达阈值必然超预算(历史只会继续增长);
  // 否则用估算值对比阈值
  private workHistoryOverBudget(messages: LoopMessage[]): boolean {
    let threshold: number = Constants.WORK_CONTEXT_WINDOW_TOKENS * Constants.WORK_COMPACT_TOKEN_RATIO;
    if (this.lastWorkPromptTokens >= threshold) {
      return true;
    }
    return this.estimateWorkTokens(loopMsgChars(messages)) >= threshold;
  }

  // 字符量 → token 估算: 有本会话实测比例时按实测, 否则按 中英混合 ≈ 2 字符/token 的保守值
  private estimateWorkTokens(chars: number): number {
    if (this.lastWorkPromptTokens > 0 && this.lastWorkPromptChars > 0) {
      return chars * this.lastWorkPromptTokens / this.lastWorkPromptChars;
    }
    return chars / 2;
  }

  // 工具结果送回模型前的最后一步处理: 溢出暂存 + 头尾保留式截断(对齐 DeepSeek Harness
  // spill store + output-retention 的 headTail 策略)——超过送回上限的全文先落盘工作区
  // .spill/ 目录(模型可用 read_file 读回), 再以头尾节选 + 定位提示替代中段; 末尾的
  // 汇总/结论往往落在结果尾部, 不能一刀切丢弃。meta(如 diff 卡片)随记录持久化。
  private applyToolResult(ctx: common.UIAbilityContext, convId: string,
    call: ToolCallRecord, exec: ToolExecResult, execStart: number): void {
    call.meta = exec.meta;
    call.timeout = exec.timeout;
    call.cancelled = exec.cancelled;
    call.schemaError = exec.schemaError;
    if (exec.output.length > Constants.WORK_RESULT_MAX_CHARS) {
      let root: string = WorkFileService.workspaceRoot(ctx, convId);
      let spillRel: string = SpillStore.save(root, call.name, exec.output);
      let headLen: number = Constants.WORK_SPILL_HEAD_CHARS;
      let tailLen: number = Math.min(Constants.WORK_SPILL_TAIL_CHARS,
        Math.max(0, exec.output.length - headLen));
      let head: string = exec.output.substring(0, headLen);
      let tail: string = tailLen > 0 ?
        exec.output.substring(exec.output.length - tailLen) : '';
      let omitted: number = exec.output.length - headLen - tailLen;
      let locator: string = spillRel !== '' ?
        '完整结果已保存到工作区 ' + spillRel + ', 需要原文用 read_file 读取' :
        '完整结果暂存失败, 请用 search_files/parse_document 从源文件重新获取';
      call.result = head + '\n\n...(中段省略 ' + omitted.toString() +
        ' 字符；' + locator + ')...\n\n' + tail;
    } else {
      call.result = exec.output;
    }
    call.isError = !exec.ok;
    call.durationMs = Date.now() - execStart;
  }

  // 重复调用防护(对齐 DeepSeek Harness repeat-tool-reminder): 连续同工具同参数调用
  // 计数, 第 3/5/8 次时生成一条系统提醒文本(仅提示不阻断; 新任务开始时重置)。
  // 提醒由调用方在本轮工具结果入史之后追加, 保证时序自然。返回空串表示本次无需提醒。
  private noteWorkRepeat(call: ToolCallRecord): string {
    let outcome = this.workRepeatDetector.record(call.name, call.argsJson);
    if (!outcome.shouldRemind) {
      return '';
    }
    return '【系统提醒】你已连续 ' + outcome.count.toString() +
      ' 次以完全相同的参数调用 ' + call.name + '，相同调用不会产生新结果。请停下分析: 核对参数、' +
      '改用其他工具或调整方法；确有无法逾越的障碍时，如实向用户说明并收口。';
  }

  // 收尾一条本轮消息: 同步展示内容; 中断且无任何产出时直接移除
  private finalizeWorkTurn(turnMsg: Message, aborted: boolean, conv: Conversation): void {
    // 未走完的 preparing 记录在收尾时落定为"被打断"态, 时间线以 ⏹ 呈现而非永远转圈
    for (let i: number = 0; i < turnMsg.toolCalls.length; i++) {
      turnMsg.toolCalls[i].preparing = false;
    }
    if (aborted && turnMsg.content === '' && turnMsg.toolCalls.length === 0) {
      conv.messages = conv.messages.filter((m: Message): boolean => m !== turnMsg);
      return;
    }
    if (aborted) {
      this.appendTurnNote(turnMsg, '任务已手动停止');
    }
    turnMsg.displayContent = turnMsg.content;
  }

  // 在轮次消息末尾追加标注(手动停止/超步/执行失败)
  private appendTurnNote(msg: Message, note: string): void {
    msg.content = msg.content === '' ? note : msg.content + '\n\n' + note;
    msg.displayContent = msg.content;
  }

  private scheduleStreamUpdate(): void {
    // 流式期间仅低频存档(5s, STREAM_THROTTLE_MS): 全量序列化所有会话开销大,
    // 曾经 50ms 一次直接撑爆共享堆(OOM)。常规持久化依赖工具步骤边界与
    // handleStreamDone/handleStreamError; @Observed Message 自身驱动子组件更新
    if (this.streamTimer !== -1) {
      return;
    }
    this.streamTimer = setTimeout(() => {
      this.streamTimer = -1;
      this.persistConversations();
    }, Constants.STREAM_THROTTLE_MS);
  }

  // 流式中按已累积输出字符数实时估算 token 速度 (约 1 字符 ≈ 1 token, 中文场景近似);
  // 流式结束后由 API 返回的 usage 派生的精确值覆盖.
  private updateLiveTokenSpeed(msg: Message, startMs: number): void {
    const now: number = Date.now();
    if (now - this.lastSpeedUpdateTime < 500) {
      return;
    }
    this.lastSpeedUpdateTime = now;
    const elapsedSec: number = (now - startMs) / 1000;
    if (elapsedSec <= 0) {
      return;
    }
    msg.tokenSpeed = (msg.content.length + msg.reasoning.length) / elapsedSec;
  }

  // 聊天模式流式请求(含本地内置联网搜索工具循环):
  // search_web 强制注入请求体(三协议), 是否调用由模型决定; 调用后在手机本地执行并回灌下一轮。
  // 服务端联网搜索开关(webSearchEnabled)完全不动; 引用格式指引随搜索结果回传,
  // 不改写系统提示词与请求前缀(保护跨轮 KV 缓存)。
  private async runChatStream(conv: Conversation, assistantMsg: Message,
    history: Message[], userText: string): Promise<void> {
    let round: number = 0;
    let currentUserText: string = userText;
    let currentHistory: Message[] = history;
    let failed: boolean = false;
    while (true) {
      round++;
      let streamStartMs: number = Date.now();
      let callbacks: StreamCallbacks = new StreamCallbacks();
      callbacks.onToken = (delta: string): void => {
        assistantMsg.content += delta;
        this.updateLiveTokenSpeed(assistantMsg, streamStartMs);
        this.scheduleStreamUpdate();
      };
      callbacks.onReasoning = (text: string): void => {
        assistantMsg.reasoning = text;
        this.updateLiveTokenSpeed(assistantMsg, streamStartMs);
        this.scheduleStreamUpdate();
      };
      callbacks.onUsage = (speed: number, hit: number): void => {
        if (speed > 0) {
          assistantMsg.tokenSpeed = speed;
        }
        if (hit >= 0) {
          assistantMsg.cacheHitRate = hit;
        }
        this.scheduleStreamUpdate();
      };
      callbacks.onToolCalls = (calls: ToolCallRecord[]): void => {
        // 模型生成调用参数过程中即时同步(preparing 态), 与工作模式行为一致
        for (let i: number = 0; i < calls.length; i++) {
          let call: ToolCallRecord = calls[i];
          if (call.name === '' || assistantMsg.toolCalls.indexOf(call) >= 0) {
            continue;
          }
          assistantMsg.toolCalls.push(call);
          call.preparing = true;
        }
      };
      callbacks.onError = (err: string): void => {
        failed = true;
        this.handleStreamError(assistantMsg, err);
      };
      // 多轮循环的收尾由本方法在结束时统一调用 handleStreamDone, 每轮不重复收尾
      callbacks.onDone = (_full: string): void => {};

      let result: ChatStreamResult = await ChatService.streamChat(
        this.apiConfig, this.currentAgent, currentHistory, currentUserText,
        this.thinkingEnabled, this.webSearchEnabled, callbacks, this.abortSignal);
      assistantMsg.thinkingSignature = result.thinkingSignature;
      // 中断: 与旧流程一致, 不做收尾(由 stopStreaming 负责状态)
      if (this.abortSignal.aborted) {
        return;
      }
      // 出错: handleStreamError 已提示, 继续走 handleStreamDone 同步 displayContent(与旧流程一致)
      if (failed) {
        break;
      }
      // 只看本轮是否有新工具调用: assistantMsg.toolCalls 是跨轮累计的(旧调用保留供回灌/展示),
      // 若用它判断, 模型给出最终回答(无新调用)的轮次也永远不满足退出条件
      let roundCalls: ToolCallRecord[] = result.toolCalls;
      if (roundCalls.length === 0) {
        break;
      }
      if (round >= Constants.CHAT_SEARCH_MAX_ROUNDS) {
        assistantMsg.content += '\n\n 已连续搜索 ' + Constants.CHAT_SEARCH_MAX_ROUNDS.toString() +
          ' 轮(防失控保险), 停止继续搜索。';
        break;
      }
      // 执行模型发起的本地工具调用(search_web / web_fetch 均在手机本地执行;
      // 其余未知调用填错误结果送回, 由模型自行纠正)
      for (let i: number = 0; i < roundCalls.length; i++) {
        let call: ToolCallRecord = roundCalls[i];
        call.preparing = false;
        if (call.result !== '') {
          continue;
        }
        let execStart: number = Date.now();
        if (call.name === LOCAL_SEARCH_TOOL_NAME) {
          let query: string = ChatViewModel.parseSearchQuery(call.argsJson);
          let outcome: LocalSearchOutcome = await ToolExecutionGuard.run(
            LocalWebSearch.searchWeb(query, this.abortSignal),
            Constants.WORK_TOOL_TIMEOUT_MS, this.abortSignal,
            (): LocalSearchOutcome => ChatViewModel.searchOutcomeWithError('本机搜索执行超时', true),
            (): LocalSearchOutcome => ChatViewModel.searchOutcomeWithError('本机搜索已取消', false, true));
          call.durationMs = Date.now() - execStart;
          call.timeout = outcome.timeout;
          call.cancelled = outcome.cancelled;
          if (outcome.ok) {
            call.isError = false;
            call.result = outcome.contentForAI;
            assistantMsg.content += '\n\n 进行了一次本机联网搜索(' + outcome.engineLabel + ')：' + query + '\n';
          } else {
            call.isError = true;
            call.result = '搜索失败: ' + outcome.errorMessage;
            assistantMsg.content += '\n\n 本机联网搜索失败：' + outcome.errorMessage + '\n';
          }
        } else if (call.name === WEB_FETCH_TOOL_NAME) {
          let args: Record<string, Object> = ChatViewModel.parseArgsObject(call.argsJson);
          let url: string = ChatViewModel.readArgString(args, 'url');
          let fetchResult: ToolExecResult = await ToolExecutionGuard.run(
            HarnessTools.toolWebFetch(args),
            Constants.WORK_TOOL_TIMEOUT_MS, this.abortSignal,
            (): ToolExecResult => ChatViewModel.toolResultError('web_fetch 执行超时', true),
            (): ToolExecResult => ChatViewModel.toolResultError('web_fetch 执行已取消', false, true));
          call.durationMs = Date.now() - execStart;
          call.timeout = fetchResult.timeout;
          call.cancelled = fetchResult.cancelled;
          call.isError = !fetchResult.ok;
          call.result = fetchResult.output;
          if (fetchResult.ok) {
            assistantMsg.content += '\n\n 读取了一次网页：' + (url === '' ? '(未提供 url)' : url) + '\n';
          } else {
            assistantMsg.content += '\n\n 读取网页失败：' +
              (url === '' ? '(未提供 url)' : url) + '\n';
          }
        } else {
          call.durationMs = 0;
          call.isError = true;
          call.result = '未知工具: ' + call.name +
            '(聊天模式仅支持 ' + LOCAL_SEARCH_TOOL_NAME + ' / ' + WEB_FETCH_TOOL_NAME + ')';
        }
      }
      this.persistConversations();
      this.notifyUIChange();
      // 下一轮: 历史包含带工具结果的 assistant 消息(conv.messages 末条), 不追加用户消息
      currentHistory = conv.messages;
      currentUserText = '';
    }
    this.handleStreamDone(assistantMsg, conv);
  }

  // search_web 参数解析: 取 query 字段, 解析失败回落原始参数文本
  private static parseSearchQuery(argsJson: string): string {
    try {
      let parsed: Object = JSON.parse(argsJson === '' ? '{}' : argsJson);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        let q: Object = (parsed as Record<string, Object>)['query'];
        if (typeof q === 'string' && (q as string).trim() !== '') {
          return q as string;
        }
      }
    } catch (e) {
      // ignore
    }
    return argsJson.trim();
  }

  // 本地搜索的超时/取消兜底结果(与工具护栏一致: ok=false + errorMessage)
  private static searchOutcomeWithError(msg: string,
    timeout: boolean = false, cancelled: boolean = false): LocalSearchOutcome {
    let o: LocalSearchOutcome = new LocalSearchOutcome();
    o.ok = false;
    o.errorMessage = msg;
    o.timeout = timeout;
    o.cancelled = cancelled;
    return o;
  }

  // web_fetch 等工具的超时/取消兜底结果
  private static toolResultError(msg: string,
    timeout: boolean = false, cancelled: boolean = false): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = false;
    r.output = 'ERROR: ' + msg;
    r.timeout = timeout;
    r.cancelled = cancelled;
    return r;
  }

  // 工具调用参数 JSON → 对象(解析失败回落空对象)
  private static parseArgsObject(argsJson: string): Record<string, Object> {
    try {
      let parsed: Object = JSON.parse(argsJson === '' ? '{}' : argsJson);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      // ignore
    }
    let empty: Record<string, Object> = {};
    return empty;
  }

  private static readArgString(args: Record<string, Object>, key: string): string {
    let v: Object | undefined = args[key];
    if (typeof v === 'string') {
      return v as string;
    }
    return '';
  }

  private handleStreamError(msg: Message, err: string): void {
    if (msg.content === '') {
      msg.content = '⚠️ ' + err;
    } else {
      msg.content = msg.content + '\n\n⚠️ ' + err;
    }
    msg.displayContent = msg.content;
    this.markStreamEnd();
    this.streamTarget = null;
    if (this.streamTimer !== -1) {
      clearTimeout(this.streamTimer);
      this.streamTimer = -1;
    }
    this.persistConversations();
  }

  private handleStreamDone(msg: Message, conv: Conversation): void {
    this.markStreamEnd();
    this.streamTarget = null;
    // 流式结束前同步 displayContent, 让 RichTextView 解析最终完整内容
    msg.displayContent = msg.content;
    if (this.streamTimer !== -1) {
      clearTimeout(this.streamTimer);
      this.streamTimer = -1;
    }
    this.pendingUIChange = false;
    if (this.abortSignal.aborted && msg.content === '') {
      // 中断且无内容, 移除 assistant
      conv.messages = conv.messages.filter((m: Message): boolean => m !== msg);
    }
    this.persistConversations();
    if (this.autoReadEnabled && !this.abortSignal.aborted && msg.content !== '') {
      this.readText(msg.id, msg.content);
    }
    // 通知 ChatPage isStreaming 等 VM 字段变化 (与流式内容无关, 走 refreshTick)
    this.notifyUIChange();
  }

  async readMessage(msgId: string): Promise<void> {
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      return;
    }
    for (let i: number = 0; i < conv.messages.length; i++) {
      let msg: Message = conv.messages[i];
      if (msg.id === msgId && msg.role === 'assistant') {
        await this.readText(msg.id, msg.content);
        return;
      }
    }
  }

  async stopReading(): Promise<void> {
    await this.onStopReading();
  }

  private async readText(id: string, markdown: string): Promise<void> {
    if (this.context === null) {
      return;
    }
    let plainText: string = stripMarkdown(markdown).trim();
    if (plainText === '') {
      return;
    }
    try {
      await this.onReadText(id, plainText);
    } catch (e) {
      let err: Error = e as Error;
      let message: string = err.message !== undefined ? err.message : '设备暂不支持朗读';
      promptAction.showToast({ message: '朗读失败：' + message, duration: 2500 });
    }
  }

  // 流式任务开始: 同步 AppStorage 标记, 供 EntryAbility.onBackground 判断是否申请后台保活
  private markStreamStart(): void {
    this.isStreaming = true;
    AppStorage.setOrCreate<boolean>('chatStreamingActive', true);
  }

  // 流式任务结束: 同步标记并释放后台保活(前台期间未申请时为空操作)
  private markStreamEnd(): void {
    this.isStreaming = false;
    AppStorage.set<boolean>('chatStreamingActive', false);
    if (this.context !== null) {
      BackgroundTaskService.stop(this.context);
    }
  }

  // 停止流式(聊天流/工作模式循环通用)
  stopStreaming(): void {
    if (!this.isStreaming) {
      return;
    }
    this.markStreamEnd();
    this.abortSignal.aborted = true;
    ChatService.abort();
    AgentLoopService.abort();
    // 深度取消工具内 HTTP: 真正销毁在途 download_file / web_fetch 请求, 避免底层继续占用
    WorkToolRunner.abortToolRequests();
    WebFetchService.abortToolRequests();
    // 挂起中的 ask_user_question 立即落定(以取消收场), 避免工具永久挂起
    AskUserBridge.cancelAll();
    this.pendingAsk = null;
    if (this.streamTimer !== -1) {
      clearTimeout(this.streamTimer);
      this.streamTimer = -1;
    }
    this.streamTarget = null;
    this.notifyUIChange();
  }

  // 重新回答
  async regenerateMessage(msgId: string): Promise<void> {
    if (this.isStreaming) {
      promptAction.showToast({ message: 'AI 正在回复中，请稍候', duration: 2000 });
      return;
    }
    let convOpt: Conversation | null = this.currentConversation;
    if (convOpt === null) {
      return;
    }
    // 闭包内不继承可空变量的收窄, 先落成非空局部量
    let conv: Conversation = convOpt;
    let aiIdx: number = -1;
    for (let i: number = 0; i < conv.messages.length; i++) {
      if (conv.messages[i].id === msgId) {
        aiIdx = i;
        break;
      }
    }
    if (aiIdx < 0 || conv.messages[aiIdx].role !== 'assistant') {
      return;
    }
    let lastUser: Message | null = null;
    for (let i: number = aiIdx - 1; i >= 0; i--) {
      if (conv.messages[i].role === 'user') {
        lastUser = conv.messages[i];
        break;
      }
    }
    if (lastUser === null) {
      promptAction.showToast({ message: '未找到对应的问题', duration: 2000 });
      return;
    }
    if (this.apiConfig.apiKey === '') {
      promptAction.showToast({ message: '请先配置 API Key', duration: 2000 });
      return;
    }
    // 删除该 assistant 消息
    conv.messages.splice(aiIdx, 1);

    // 复制一份 user 消息(在末尾重新发送, 对齐 web 版 "重新回答" 行为)
    let regenContent: string = '重新回答：' + lastUser.content;
    let regenDisplay: string = '重新回答：' + (lastUser.displayContent === '' ? lastUser.content : lastUser.displayContent);
    let regenAttachments: Attachment[] = lastUser.attachments;
    let regenUserMsg: Message = Message.ofUser(generateMessageId(), regenContent, regenDisplay, regenAttachments);
    conv.messages.push(regenUserMsg);

    // 工作模式: 重新执行任务循环(重走 Agent Loop)
    if (conv.mode === 'work') {
      this.persistConversations();
      await this.executeWorkLoop(conv);
      return;
    }

    let newAssistant: Message = Message.ofAssistant(generateMessageId(), '');
    conv.messages.push(newAssistant);

    this.abortSignal = new AbortSignal();
    this.markStreamStart();
    this.streamTarget = newAssistant;
    this.streamTimer = -1;

    let history: Message[] = conv.messages.slice(0, conv.messages.length - 1);
    // 流式请求 + 本地联网搜索工具循环(与 sendUserMessage 共用)
    await this.runChatStream(conv, newAssistant, history, regenContent);
  }

  // 复制
  async copyText(text: string): Promise<void> {
    try {
      let pb = pasteboard.getSystemPasteboard();
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pb.setData(data);
    } catch (e) {
      // ignore
    }
  }

  async copyMessagePlain(msgId: string): Promise<void> {
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      return;
    }
    for (let i: number = 0; i < conv.messages.length; i++) {
      if (conv.messages[i].id === msgId) {
        let plain: string = stripMarkdown(conv.messages[i].content);
        await this.copyText(plain);
        return;
      }
    }
  }

  async copyMessageMarkdown(msgId: string): Promise<void> {
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      return;
    }
    for (let i: number = 0; i < conv.messages.length; i++) {
      if (conv.messages[i].id === msgId) {
        await this.copyText(conv.messages[i].content);
        return;
      }
    }
  }

  // 生成图片缩略图(最长边 256px JPEG): 消息列表/气泡/预览条显示小图,
  // 点击灯箱才加载原图, 避免全尺寸 PixelMap 反复解码撑爆内存
  private async makeThumbnail(dataUrl: string): Promise<string> {
    if (!dataUrl.startsWith('data:image/')) {
      return '';
    }
    let src: image.ImageSource | null = null;
    let pixel: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      let comma: number = dataUrl.indexOf(',');
      if (comma === -1) {
        return '';
      }
      let helper: util.Base64Helper = new util.Base64Helper();
      let bytes: Uint8Array = helper.decodeSync(dataUrl.substring(comma + 1));
      src = image.createImageSource(bytes.buffer);
      pixel = await src.createPixelMap({
        desiredSize: { width: 256, height: 256 }
      });
      packer = image.createImagePacker();
      let packed: ArrayBuffer = await packer.packToData(pixel, { format: 'image/jpeg', quality: 55 });
      return 'data:image/jpeg;base64,' + helper.encodeToStringSync(new Uint8Array(packed));
    } catch (error) {
      return '';
    } finally {
      try {
        if (pixel !== null) {
          pixel.release();
        }
      } catch (e) {
        // ignore
      }
      try {
        if (packer !== null) {
          packer.release();
        }
      } catch (e) {
        // ignore
      }
      try {
        if (src !== null) {
          src.release();
        }
      } catch (e) {
        // ignore
      }
    }
  }

  // 持久化
  private async persistConversations(): Promise<void> {
    if (this.context === null) {
      return;
    }
    try {
      await StorageManager.saveConversations(this.context, this.conversations);
    } catch (e) {
      // ignore
    }
  }
}

function stripMarkdown(md: string): string {
  let text: string = md;
  text = text.replace(/```[\s\S]*?```/g, '');
  text = text.replace(/`([^`]+)`/g, '$1');
  text = text.replace(/!\[[^\]]*\]\([^)]*\)/g, '');
  text = text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
  text = text.replace(/^#{1,6}\s+/gm, '');
  text = text.replace(/\*\*([^*]+)\*\*/g, '$1');
  text = text.replace(/\*([^*]+)\*/g, '$1');
  text = text.replace(/^>\s?/gm, '');
  text = text.replace(/\|/g, '');
  text = text.replace(/^-{3,}$/gm, '');
  return text.trim();
}

// 从工具参数 JSON 中提取 path 字段(view_image 图片注入用)
function parseToolArgPath(argsJson: string): string {
  try {
    let parsed: Object = JSON.parse(argsJson);
    if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
      let rec: Record<string, Object> = parsed as Record<string, Object>;
      let v: Object = rec['path'];
      if (typeof v === 'string') {
        return v as string;
      }
    }
  } catch (e) {
    // ignore
  }
  return '';
}

// 整个循环历史消息数组的字符量(正文 + 工具参数与结果), 用于上下文预算
function loopMsgChars(messages: LoopMessage[]): number {
  let n: number = 0;
  for (let i: number = 0; i < messages.length; i++) {
    n += msgChars(messages[i]);
  }
  return n;
}

// 单条循环消息的字符量
function msgChars(m: LoopMessage): number {
  let n: number = m.content.length;
  for (let c: number = 0; c < m.toolCalls.length; c++) {
    n += m.toolCalls[c].argsJson.length + m.toolCalls[c].result.length;
  }
  return n;
}

// 第一级压缩(无模型参与): 把 [from, to) 范围内过长的工具结果替换为头尾节选 +
// 精确省略提示(原文可随时用 read_file/search_files/parse_document 重新获取)。
// 返回是否有任何修剪发生。assistant 与其工具结果同在一条消息内, 不会拆散协议对。
function pruneOldToolResults(messages: LoopMessage[], from: number, to: number): boolean {
  let pruned: boolean = false;
  let end: number = Math.min(to, messages.length);
  for (let i: number = from; i < end; i++) {
    let m: LoopMessage = messages[i];
    if (m.role !== 'assistant') {
      continue;
    }
    for (let c: number = 0; c < m.toolCalls.length; c++) {
      let call: ToolCallRecord = m.toolCalls[c];
      if (call.result.length <= Constants.WORK_PRUNE_RESULT_MAX_CHARS) {
        continue;
      }
      let omitted: number = call.result.length -
        Constants.WORK_PRUNE_KEEP_HEAD - Constants.WORK_PRUNE_KEEP_TAIL;
      call.result = call.result.substring(0, Constants.WORK_PRUNE_KEEP_HEAD) +
        '\n[...早期工具结果已修剪, 省略 ' + omitted.toString() +
        ' 字符; 需要原文时用 read_file/search_files/parse_document 重新获取...]\n' +
        call.result.substring(call.result.length - Constants.WORK_PRUNE_KEEP_TAIL);
      pruned = true;
    }
  }
  return pruned;
}
