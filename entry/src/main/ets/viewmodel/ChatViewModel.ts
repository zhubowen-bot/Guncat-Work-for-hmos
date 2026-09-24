// ChatViewModel: 整体状态 + 行为 (对齐 web 版本的 store)
//  - @Observed + 内部 version 计数器, 通过 ChatPage 的 @State vm 触发刷新
import { Agent } from '../model/Agent';
import { Conversation } from '../model/Conversation';
import { Message } from '../model/Message';
import { Attachment } from '../model/Attachment';
import { ApiConfig } from '../model/ApiConfig';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { ApiProfile } from '../model/ApiProfile';
import { FileItem, StreamCallbacks, AbortSignal } from '../common/Types';
import { AgentLoader } from '../service/AgentLoader';
import { PluginHotLoader } from '../service/PluginHotLoader';
import { ChatService } from '../service/ChatService';
import { FileUploadService } from '../service/FileUploadService';
import { FileService, PickedFile } from '../service/FileService';
import { MultimodalService } from '../service/MultimodalService';
import { StorageManager } from '../data/StorageManager';
import { Constants } from '../common/Constants';
import { generateMessageId } from '../common/Utils';
import { arrayBufferToBase64 } from '../common/Utils';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { cameraPicker, camera } from '@kit.CameraKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';

@Observed
export class ChatViewModel {
  agents: Agent[] = [];
  conversations: Conversation[] = [];
  currentAgent: Agent | null = null;
  currentConversationId: string = '';
  isStreaming: boolean = false;
  thinkingEnabled: boolean = false;
  webSearchEnabled: boolean = false;
  autoReadEnabled: boolean = false;
  pendingFiles: FileItem[] = [];
  drawerOpen: boolean = false;
  apiConfig: ApiConfig = ApiConfig.default();
  multimodalConfig: MultimodalConfig = MultimodalConfig.default();
  apiProfiles: ApiProfile[] = [];
  currentApiProfileId: string = '';

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
  // context
  private context: common.UIAbilityContext | null = null;
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
    this.webSearchEnabled = await StorageManager.loadBoolean(this.context, Constants.LS_KEY_WEB_SEARCH_ENABLED, false);
    this.autoReadEnabled = await StorageManager.loadBoolean(
      this.context, Constants.LS_KEY_AUTO_READ_ENABLED, false);

    // 加载智能体
    this.agents = await AgentLoader.loadAllAgents(this.context);

    // 热加载 rawfile/plugins 插件(注册进 ToolRegistry, 工作模式动态目录自动包含)
    await PluginHotLoader.loadAll(this.context);

    // 加载对话
    this.conversations = await StorageManager.loadConversations(this.context);

    // 恢复当前智能体
    let agentId: string = await StorageManager.loadString(this.context, Constants.LS_KEY_CURRENT_AGENT_ID, '');
    let firstAgent: Agent | null = this.agents.length > 0 ? this.agents[0] : null;
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

  // 切换智能体
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
  }

  // 新建对话
  async startNewConversation(): Promise<void> {
    // 清空空对话
    await this.cleanupEmptyConversation();
    if (this.currentAgent === null) {
      return;
    }
    let conv: Conversation = Conversation.create(this.currentAgent.id, '');
    this.conversations.unshift(conv);
    this.currentConversationId = conv.id;
    if (this.context !== null) {
      await StorageManager.saveString(this.context, Constants.LS_KEY_CURRENT_CONV_ID, conv.id);
    }
    this.persistConversations();
    // 效率模式默认关闭深度思考、专家模式默认开启：新建对话时按当前智能体重置开关
    await this.applyAgentThinkingDefault();
    // 立即刷新侧栏/抽屉的会话列表投影, 新建的会话马上可见
    this.notifyUIChange();
  }

  private async cleanupEmptyConversation(): Promise<void> {
    let conv: Conversation | null = this.currentConversation;
    if (conv !== null && conv.messages.length === 0) {
      this.conversations = this.conversations.filter((c: Conversation): boolean => c.id !== conv.id);
      this.currentConversationId = '';
      this.persistConversations();
    }
  }

  // 删除对话
  async deleteConversation(convId: string): Promise<void> {
    this.conversations = this.conversations.filter((c: Conversation): boolean => c.id !== convId);
    if (this.currentConversationId === convId) {
      this.currentConversationId = '';
      if (this.conversations.length > 0) {
        this.currentConversationId = this.conversations[0].id;
      } else {
        // 创建新对话
        if (this.currentAgent !== null) {
          let conv: Conversation = Conversation.create(this.currentAgent.id, '');
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
    await this.enqueueFiles(files);
    promptAction.showToast({
      message: files.length.toString() + ' 个分享文件已加入附件',
      duration: 2000
    });
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
        let result: { content: string; dataUrl: string } = await MultimodalService.parseFile(
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

  // 发送消息
  async sendMessage(displayText: string): Promise<void> {
    let userText: string = displayText;
    if (userText.trim() === '') {
      return;
    }
    if (this.isStreaming) {
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
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
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
    this.isStreaming = true;
    this.streamTarget = assistantMsg;
    this.streamTimer = -1;

    // 构造 history(不包含 user 占位 assistant)
    let history: Message[] = conv.messages.slice(0, conv.messages.length - 1);

    let streamStartMs: number = Date.now();
    let callbacks: StreamCallbacks = new StreamCallbacks();
    callbacks.onToken = (delta: string): void => {
      assistantMsg.content += delta;
      this.updateLiveTokenSpeed(assistantMsg, streamStartMs);
      // displayContent 与 content 同步, 但流式中渲染走纯 Text, 避免每 token 双倍 setter 通知
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
    callbacks.onError = (err: string): void => {
      this.handleStreamError(assistantMsg, err);
    };
    callbacks.onDone = (_full: string): void => {
      this.handleStreamDone(assistantMsg, conv);
    };

    ChatService.streamChat(
      this.apiConfig,
      this.currentAgent,
      history,
      fullText,
      this.thinkingEnabled,
      this.webSearchEnabled,
      callbacks,
      this.abortSignal
    );
  }

  private scheduleStreamUpdate(): void {
    // 50ms 节流(对齐 web 版本的 STREAM_UPDATE_INTERVAL)
    // 仅做持久化, 不触发 UI 刷新 (@Observed Message 自身驱动子组件更新)
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

  private handleStreamError(msg: Message, err: string): void {
    if (msg.content === '') {
      msg.content = '⚠️ ' + err;
    } else {
      msg.content = msg.content + '\n\n⚠️ ' + err;
    }
    msg.displayContent = msg.content;
    this.isStreaming = false;
    this.streamTarget = null;
    if (this.streamTimer !== -1) {
      clearTimeout(this.streamTimer);
      this.streamTimer = -1;
    }
    this.persistConversations();
  }

  private handleStreamDone(msg: Message, conv: Conversation): void {
    this.isStreaming = false;
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

  // 停止流式
  stopStreaming(): void {
    if (!this.isStreaming) {
      return;
    }
    this.isStreaming = false;
    this.abortSignal.aborted = true;
    ChatService.abort();
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
    let conv: Conversation | null = this.currentConversation;
    if (conv === null) {
      return;
    }
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

    let newAssistant: Message = Message.ofAssistant(generateMessageId(), '');
    conv.messages.push(newAssistant);

    this.abortSignal = new AbortSignal();
    this.isStreaming = true;
    this.streamTarget = newAssistant;
    this.streamTimer = -1;

    let history: Message[] = conv.messages.slice(0, conv.messages.length - 1);
    let streamStartMs: number = Date.now();
    let callbacks: StreamCallbacks = new StreamCallbacks();
    callbacks.onToken = (delta: string): void => {
      newAssistant.content += delta;
      this.updateLiveTokenSpeed(newAssistant, streamStartMs);
      this.scheduleStreamUpdate();
    };
    callbacks.onReasoning = (text: string): void => {
      newAssistant.reasoning = text;
      this.updateLiveTokenSpeed(newAssistant, streamStartMs);
      this.scheduleStreamUpdate();
    };
    callbacks.onUsage = (speed: number, hit: number): void => {
      if (speed > 0) {
        newAssistant.tokenSpeed = speed;
      }
      if (hit >= 0) {
        newAssistant.cacheHitRate = hit;
      }
      this.scheduleStreamUpdate();
    };
    callbacks.onError = (err: string): void => {
      this.handleStreamError(newAssistant, err);
    };
    callbacks.onDone = (_full: string): void => {
      this.handleStreamDone(newAssistant, conv);
    };

    ChatService.streamChat(
      this.apiConfig,
      this.currentAgent,
      history,
      regenContent,
      this.thinkingEnabled,
      this.webSearchEnabled,
      callbacks,
      this.abortSignal
    );
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
