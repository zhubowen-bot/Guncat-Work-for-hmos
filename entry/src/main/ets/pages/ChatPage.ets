import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ChatBubbleView } from '../views/ChatBubbleView';
import { MessageInputView } from '../views/MessageInputView';
import { ToggleSwitch } from '../components/ToggleSwitch';
import { AgentDrawerView } from '../views/AgentDrawerView';
import { DswSidebar } from '../views/DswSidebar';
import { AskUserCard } from '../views/AskUserCard';
import { FlyInLaunchView } from '../views/FlyInLaunchView';
import { ToastView } from '../views/ToastView';
import { ImageLightbox } from '../views/ImageLightbox';
import { SettingsPanel } from '../views/SettingsPanel';
import { PlayGuidePanel } from '../views/PlayGuidePanel';
import { WorkspaceBar, WorkspaceFileIcons } from '../views/WorkspaceBar';
import { WorkTurnView } from '../views/WorkTurnView';
import { WorkArtifactsCard } from '../views/WorkArtifactsCard';
import { WorkArtifactFile, WorkArtifactSummary, WorkArtifactUtil } from '../common/WorkArtifacts';
import { Message } from '../model/Message';
import { Agent } from '../model/Agent';
import { Conversation } from '../model/Conversation';
import { ConversationListItem } from '../model/ConversationListItem';
import { ApiConfig } from '../model/ApiConfig';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { SearchEngineSettings } from '../service/LocalWebSearch';
import { ApiProfile } from '../model/ApiProfile';
import { FileItem, PreviewData } from '../common/Types';
import { WorkFileService, WorkspaceFileInfo } from '../service/WorkFileService';
import { GoalService, GoalItem } from '../service/GoalService';
import { generateMessageId } from '../common/Utils';
import { VoiceInputService } from '../service/VoiceInputService';
import {
  ReaderCallbacks,
  ReaderProgress,
  ReaderVoiceOption,
  TextReaderService
} from '../service/TextReaderService';
import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { DocxExporter } from '../export/DocxExporter';

// 详情面板统计快照(仅 ChatPage 内部使用): rebuildWorkStats 每次整体重建后赋值,
// 面板统计区只依赖这一个顶层状态 —— 顶层 @State 整体重赋值是与文件预览条 previewItems
// 相同的已验证刷新通道, 避免统计文本因零散属性/getter 缺少观察通道而冻结
class WorkPanelStats {
  elapsedSec: number = 0;
  speedText: string = '—';
  cacheText: string = '—';
  toolCalls: number = 0;
  goalText: string = '';
}

@Entry
@Component
struct ChatPage {
  @State private vm: ChatViewModel = new ChatViewModel();
  @StorageLink('sharedFileUris') @Watch('onSharedFileUrisChanged')
  private sharedFileUris: string = '';
  @State private inputText: string = '';
  @State private drawerOpen: boolean = false;
  @State private settingsOpen: boolean = false;
  @State private playGuideOpen: boolean = false;
  // ===== 桌面宽屏三栏布局(对齐 dsh AppFrame): 侧栏 | 会话 | 详情 =====
  @State private isWide: boolean = false;
  @State private sidebarCollapsed: boolean = false;
  @State private detailsOpen: boolean = false;
  // 宽屏下详情面板只自动打开一次, 之后尊重用户手动开合
  private detailsAutoOpened: boolean = false;
  // 会话列表轻量投影(传给侧栏/抽屉, 避免 @Prop 深拷贝全部消息)
  @State private convListItems: ConversationListItem[] = [];
  // 工作模式计时计数(流式期间每 3 秒兜底刷新一次工作区面板)
  private workTickCounter: number = 0;
  // 页面根 Stack 相对窗口的偏移(状态栏等安全区): 全局坐标 → 页面坐标换算用
  private rootOffsetX: number = 0;
  private rootOffsetY: number = 0;
  // 空状态锚点最近一次上报的窗口全局坐标(-1 表示尚未布局)
  private anchorGlobalX: number = -1;
  private anchorGlobalY: number = -1;

  // 用最新偏移重算英雄图标落点: 根布局与锚点的 onAreaChange 触发顺序不保证,
  // 双方都只存值并调用本方法, 任何一侧后到都能得到正确结果(最大化/还原后自动纠正)。
  // 启动动画已结束时图标常驻空状态, 直接平滑跟随新落点(否则位置停在旧窗口坐标)。
  private recomputeHeroTarget(): void {
    if (this.anchorGlobalX < 0 || this.anchorGlobalY < 0) {
      return;
    }
    this.heroTargetX = this.anchorGlobalX - this.rootOffsetX;
    this.heroTargetY = this.anchorGlobalY - this.rootOffsetY;
    this.heroTargetSize = 96;
    if (!this.launchVisible) {
      animateTo({
        duration: 200,
        curve: Curve.EaseOut
      }, () => {
        this.heroX = this.heroTargetX;
        this.heroY = this.heroTargetY;
        this.heroSize = this.heroTargetSize;
      });
    }
  }
  @State private launchVisible: boolean = true;
  @State private inputAreaVisible: boolean = false;
  // 单一“hero 图标”节点：不依赖共享元素转场，避免交叉淡化导致的发白闪烁
  @State private heroVisible: boolean = true;
  @State private heroX: number = 0;
  @State private heroY: number = 0;
  @State private heroSize: number = 60;
  private heroTargetX: number = 0;
  private heroTargetY: number = 0;
  private heroTargetSize: number = 96;
  private emptyStateBaseX: number = 0;
  private emptyStateBaseY: number = 0;
  private rootW: number = 360;
  private rootH: number = 780;
  @State private lightboxVisible: boolean = false;
  @State private lightboxUrl: string = '';
  @State private toastMessage: string = '';
  @State private toastVisible: boolean = false;
  @State private isListening: boolean = false;
  @State private refreshTick: number = 0;
  // 详情面板统计快照: rebuildWorkStats 整体重建后赋值, 统计区只读这份快照
  @State private workStats: WorkPanelStats = new WorkPanelStats();
  // 工作模式工作区弹层开关(挂在"工作模式"胶囊上方)
  @State private workspacePopupOpen: boolean = false;
  // 模型选择弹层开关(挂在输入区左下角模型胶囊上方)
  @State private modelMenuOpen: boolean = false;
  @State private previewItems: PreviewData[] = [];
  // 工作模式产物汇总卡(对话流末尾 Codex 风格 Changes 卡片)
  @State private workArtifacts: WorkArtifactFile[] = [];
  @State private workArtifactAdds: number = 0;
  @State private workArtifactDels: number = 0;
  @State private readerVisible: boolean = false;
  @State private readerPhase: string = '';
  @State private readerProgress: number = 0;
  @State private readerVoiceIndex: number = 0;
  @State private readerVoices: ReaderVoiceOption[] = [];
  @State private readerSpeed: number = 1;
  @State private readerPaused: boolean = false;
  @State private readerOffsetX: number = 0;
  @State private readerOffsetY: number = 0;
  private readerDragStartX: number = 0;
  private readerDragStartY: number = 0;
  // 消息列表滚动控制器 + 自动置底
  private messageScroller: Scroller = new Scroller();
  private toastTimer: number = -1;
  // 会话工作时间计时: 工作模式任务执行期间每秒累计(秒数存 VM 供工作区面板显示), 切换/新建会话归零
  private workTickTimer: number = -1;
  private lastWorkConvId: string = '';
  // 上一次流式状态: 用于任务结束瞬间自动滚到底部, 让刚生成的产物卡片直接可见
  private lastStreamingState: boolean = false;
  private voiceInputService: VoiceInputService = new VoiceInputService();
  // 用户手指触摸滚动期间暂停自动置底, 松手后恢复
  // (避免 scrollTo 与进行中的手势冲突导致白屏)
  private userScrolling: boolean = false;
  // 流式自动置底定时器句柄(页面销毁时需清理)
  private streamScrollTimer: number = -1;

  aboutToAppear(): void {
    let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.vm.setContext(context);
    this.initHeroLayout();
    let readerCallbacks: ReaderCallbacks = new ReaderCallbacks();
    readerCallbacks.onChange = (state: ReaderProgress): void => {
      this.readerVisible = state.visible;
      this.readerPhase = state.phase;
      this.readerProgress = state.progress;
      this.readerVoiceIndex = state.voiceIndex;
      this.readerVoices = state.voices;
      this.readerSpeed = state.speed;
      this.readerPaused = state.paused;
    };
    TextReaderService.setCallbacks(readerCallbacks);
    this.vm.onReadText = async (id: string, text: string): Promise<void> => {
      await TextReaderService.read(context, id, text);
    };
    this.vm.onStopReading = async (): Promise<void> => {
      await TextReaderService.stop();
    };
    this.vm.setStateChangeListener(() => {
      // 记录本次回调前的流式状态与产物数量, 用于判断“任务刚结束/产物卡刚出现”时需要置底
      const wasStreaming: boolean = this.lastStreamingState;
      const prevArtifacts: number = this.workArtifacts.length;
      // 切到非工作模式的智能体/会话时收起工作区弹层
      if (!this.vm.workMode && this.workspacePopupOpen) {
        this.workspacePopupOpen = false;
      }
      // 切换/新建会话时工作时间归零
      if (this.vm.currentConversationId !== this.lastWorkConvId) {
        this.lastWorkConvId = this.vm.currentConversationId;
        this.vm.workElapsedSec = 0;
      }
      this.rebuildPreviewItems();
      // 详情面板统计快照随 VM 状态变化重建(工具结果/流式统计到达后立刻反映)
      this.rebuildWorkStats();
      // 产物汇总卡同样随工具结果/工作区刷新即时重建
      this.rebuildWorkArtifacts();
      // 侧栏/抽屉的会话列表轻量投影(新增/删除/改名后同步)
      this.convListItems = this.vm.getConversationListItems();
      this.lastStreamingState = this.vm.isStreaming;
      this.refreshTick++;
      // 流式期间跟随置底(流式中的常态跟随由 100ms 定时器负责)。
      // 任务刚结束或产物卡刚出现时, 也要自动滚到底部, 避免用户手动下翻才能看到产物。
      if (this.vm.isStreaming && !this.userScrolling) {
        this.scrollToBottomDelayed();
      } else if (!this.vm.isStreaming && !this.userScrolling &&
        (wasStreaming || (this.workArtifacts.length > 0 && prevArtifacts === 0))) {
        this.scrollToBottomDelayed();
      }
    });
    this.vm.init().then(() => {
      this.refreshTick++;
      this.convListItems = this.vm.getConversationListItems();
      this.rebuildWorkArtifacts();
      this.consumeSharedFiles();
      setTimeout(() => {
        if (!this.userScrolling) {
          this.messageScroller.scrollTo({ xOffset: 0, yOffset: 999999, animation: { duration: 0 } });
        }
      }, 100);
    });
    // 工作模式工作时间计时: 面板随开随关, 计时必须挂在常驻的 ChatPage 上才不中断
    this.workTickTimer = setInterval((): void => {
      if (!this.vm.workMode) {
        return;
      }
      if (this.vm.currentConversationId !== this.lastWorkConvId) {
        this.lastWorkConvId = this.vm.currentConversationId;
        this.vm.workElapsedSec = 0;
      }
      if (this.vm.isStreaming) {
        this.vm.workElapsedSec++;
      }
      // Guncat Work 6.1: 定时提醒推进 + ask_user 待答同步(秒级轮询足够)
      this.vm.tickSchedules();
      this.vm.syncPendingAsk();
      // 每 3 秒兜底刷新工作区文件列表: 流式期间始终刷新(工具结果已有即时刷新, 这里覆盖其余变化);
      // 非流式但工作区面板/弹层可见时也刷新, 覆盖定时任务等后台写入
      this.workTickCounter++;
      if (this.vm.workMode && this.workTickCounter % 3 === 0 &&
        (this.vm.isStreaming || this.detailsOpen || this.workspacePopupOpen)) {
        this.vm.refreshWorkspace();
      }
      // 详情面板统计快照每秒重建: 顶层 @State 整体重赋值驱动统计区逐秒刷新
      // (任务用时逐秒走字, 流式速度/缓存命中随最新消息更新)
      if (this.vm.workMode && this.detailsOpen) {
        this.rebuildWorkStats();
      }
    }, 1000);
    // 流式期间每 100ms 置底一次 (revealedCount 在 ChatBubbleView 内部定时推进,
    // ChatPage 需要通过此 timer 确保 Scroll 跟随新字符出现)
    this.streamScrollTimer = setInterval(() => {
      if (this.vm.isStreaming && !this.userScrolling) {
        this.messageScroller.scrollTo({ xOffset: 0, yOffset: 999999, animation: { duration: 0 } });
      }
    }, 100);
  }

  private onSharedFileUrisChanged(): void {
    this.consumeSharedFiles();
  }

  private consumeSharedFiles(): void {
    if (this.sharedFileUris === '') {
      return;
    }
    let payload: string = this.sharedFileUris;
    this.sharedFileUris = '';
    try {
      let parsed: Object = JSON.parse(payload);
      if (!(parsed instanceof Array)) {
        return;
      }
      let values: Object[] = parsed as Object[];
      let uris: string[] = [];
      for (let i: number = 0; i < values.length; i++) {
        if (typeof values[i] === 'string') {
          uris.push(values[i] as string);
        }
      }
      this.vm.acceptSharedFiles(uris);
    } catch (error) {
      console.error('Failed to consume shared files');
    }
  }

  aboutToDisappear(): void {
    if (this.isListening) {
      this.voiceInputService.cancel();
    }
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
    if (this.workTickTimer !== -1) {
      clearInterval(this.workTickTimer);
      this.workTickTimer = -1;
    }
    if (this.streamScrollTimer !== -1) {
      clearInterval(this.streamScrollTimer);
      this.streamScrollTimer = -1;
    }
  }

  private async initHeroLayout(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(context);
      const rect = win.getWindowProperties().windowRect;
      const w: number = this.getUIContext().px2vp(rect.width);
      const h: number = this.getUIContext().px2vp(rect.height);
      const startSize: number = 60;
      const targetSize: number = 96;
      const headerH: number = 64;
      const inputH: number = 108;
      this.heroSize = startSize;
      this.heroX = w / 2 - startSize / 2;
      this.heroY = h / 2 - startSize / 2;
      this.heroTargetX = w / 2 - targetSize / 2;
      const msgH: number = h - headerH - inputH;
      this.heroTargetY = headerH + msgH / 2 - targetSize / 2;
      this.heroTargetSize = targetSize;
    } catch (error) {
      const w: number = 360;
      const h: number = 780;
      this.heroSize = 60;
      this.heroX = w / 2 - 30;
      this.heroY = h / 2 - 30;
      this.heroTargetX = w / 2 - 48;
      this.heroTargetY = h / 2 - 48 - 22;
      this.heroTargetSize = 96;
    }
  }

  private updateHeroStart(): void {
    const startSize: number = 60;
    this.heroSize = startSize;
    this.heroX = this.rootW / 2 - startSize / 2;
    this.heroY = this.rootH / 2 - startSize / 2;
  }

  private startHeroTransition(): void {
    animateTo({
      duration: 360,
      curve: Curve.EaseOut
    }, () => {
      this.heroX = this.heroTargetX;
      this.heroY = this.heroTargetY;
      this.heroSize = this.heroTargetSize;
    });
    // 等 hero 到位后再关闭启动层、显示底部输入区
    setTimeout(() => {
      this.launchVisible = false;
      this.inputAreaVisible = true;
    }, 380);
  }

  private showToast(msg: string): void {
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
    }
    this.toastMessage = msg;
    this.toastVisible = true;
    this.toastTimer = setTimeout(() => {
      this.toastVisible = false;
      this.toastTimer = -1;
    }, 1000);
  }

  // 滚动到消息底部(延迟到布局更新后执行)。
  // 仅在用户主动动作后调用: 发送消息 / 切换·新建会话; 空闲期状态变化一律不动滚动位置
  private scrollToBottomDelayed(): void {
    setTimeout((): void => {
      this.messageScroller.scrollTo({ xOffset: 0, yOffset: 999999, animation: { duration: 0 } });
    }, 100);
  }

  // 把某条消息内容原样填回输入框(用户消息下方的"重新编辑"入口, 对齐主流 Agent)
  private fillInputFromMessage(msg: Message): void {
    this.inputText = msg.displayContent !== '' ? msg.displayContent : msg.content;
    this.showToast('已填入输入框');
  }

  build() {
    Stack() {
      // 三栏框架(对齐 dsh AppFrame): 左侧栏 | 会话列 | 右详情列; 窄屏时只有会话列
      Row() {
        if (this.isWide) {
          DswSidebar({
            agents: this.vm.agents,
            conversations: this.convListItems,
            currentAgentId: this.vm.currentAgent !== null ? this.vm.currentAgent.id : '',
            currentConversationId: this.vm.currentConversationId,
            collapsed: this.sidebarCollapsed,
            onToggleCollapse: () => {
              this.sidebarCollapsed = !this.sidebarCollapsed;
            },
            onSelectAgent: (id: string) => {
              this.vm.selectAgent(id).then(() => {
                this.refreshTick++;
                this.scrollToBottomDelayed();
              });
            },
            onSelectConversation: (id: string) => {
              this.vm.openConversation(id).then(() => {
                this.refreshTick++;
                this.scrollToBottomDelayed();
              });
            },
            onDeleteConversation: (id: string) => {
              this.vm.deleteConversation(id).then(() => {
                this.refreshTick++;
                this.scrollToBottomDelayed();
              });
            },
            onNewConversation: () => {
              this.vm.startNewConversation().then(() => {
                this.refreshTick++;
                this.scrollToBottomDelayed();
              });
            },
            onSettings: () => {
              this.settingsOpen = true;
            },
            onPlayGuide: () => {
              this.playGuideOpen = true;
            },
            onOpenDetails: () => {
              this.detailsOpen = !this.detailsOpen;
              if (this.detailsOpen) {
                this.vm.refreshWorkspace().then(() => {
                  this.refreshTick++;
                });
              }
            }
          })
            .width(this.sidebarCollapsed ? 56 : 240)
            .height('100%')
            .border({ width: { right: 1 }, color: { right: $r('app.color.divider') } })
        }

      // 主聊天布局
      Column() {
        // 顶部 Header
        this.buildHeader()

        // 消息区
        if (this.vm.currentMessages.length === 0) {
          // 空状态始终渲染以测量 hero 图标终点；启动期间被启动层遮挡，不会露出
          this.buildEmptyState();
        } else {
          this.buildMessageList();
        }

        // 输入区(工具开关行 + 文件预览 + 输入行, 由 ChatPage 直接组合避免 @Prop 深拷)
        if (this.inputAreaVisible) {
          Column() {
            // 工具开关行
            Row() {
              this.buildModelSelector()
              if (this.vm.workMode) {
                // 工作模式: 联网搜索摆在原深度思考的位置; 深度思考默认开启不再显示开关
                ToggleSwitch({
                  isOn: this.vm.webSearchEnabled,
                  label: '联网搜索',
                  toggleEnabled: true,
                  onChange: (v: boolean) => {
                    this.vm.setWebSearchEnabled(v);
                    this.refreshTick++;
                  }
                })
                  .margin({ left: 10 })
                ToggleSwitch({
                  isOn: true,
                  label: '工作区',
                  // 点击不再直接退出工作模式, 而是在胶囊上方弹出工作区面板(退出入口在面板里)
                  onChange: (_v: boolean) => {
                    this.workspacePopupOpen = !this.workspacePopupOpen;
                    if (this.workspacePopupOpen) {
                      this.vm.refreshWorkspace().then(() => {
                        this.refreshTick++;
                      });
                    }
                  }
                })
                  .margin({ left: 10 })
                  .bindPopup(this.workspacePopupOpen, {
                    builder: this.buildWorkspacePopup,
                    placement: Placement.Top,
                    // 透明遮罩: 点击面板外任意区域即收起, 且不压暗页面
                    mask: { color: Color.Transparent },
                    showInSubWindow: false,
                    onStateChange: (e: PopupStateChangeParam) => {
                      if (this.workspacePopupOpen !== e.isVisible) {
                        this.workspacePopupOpen = e.isVisible;
                      }
                    }
                  })
              } else {
                ToggleSwitch({
                  isOn: this.vm.thinkingEnabled,
                  label: '深度思考',
                  onChange: (v: boolean) => {
                    this.vm.setThinkingEnabled(v);
                    this.refreshTick++;
                  }
                })
                ToggleSwitch({
                  isOn: this.vm.webSearchEnabled,
                  label: '联网搜索',
                  toggleEnabled: true,
                  onChange: (v: boolean) => {
                    this.vm.setWebSearchEnabled(v);
                    this.refreshTick++;
                  }
                })
                  // 联网搜索胶囊左侧加 10vp 间距, 避免两个胶囊贴在一起
                  .margin({ left: 10 })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 4 })
            // 文件预览条
            if (this.vm.pendingFiles.length > 0) {
              this.buildFilePreview();
            }
            // 输入行 + 按钮
            MessageInputView({
              inputText: $inputText,
              isStreaming: this.vm.isStreaming,
              isParsing: this.vm.isParsing,
              isListening: this.isListening,
              allowSteer: this.vm.workMode,
              placeholder: this.vm.workMode ? '描述任务...' : '输入消息...',
              onSend: (text: string) => {
                this.handleSend(text);
              },
              onStop: () => {
                this.handleStop();
              },
              onFileUpload: () => {
                this.handleFileUpload();
              },
              onVoiceInput: () => {
                this.handleVoiceInput();
              },
              onCameraCapture: () => {
                this.handleCameraCapture();
              }
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .shadow({ radius: 18, color: '#0D000000', offsetX: 0, offsetY: -2 })
          // 从屏幕底部外滑入
          .transition(TransitionEffect.translate({ y: '100%' })
            .combine(TransitionEffect.OPACITY)
            .animation({ duration: 360, curve: Curve.EaseOut }))
          // 底部 surface 色延伸到导航条安全区
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        } else {
          // 输入区出现前先用等高的占位保住消息区布局，
          // 避免空状态头像在 geometryTransition 过程中因布局变化而闪烁。
          Column()
            .width('100%')
            .height(105)
            .backgroundColor(Color.Transparent)
        }
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor($r('app.color.background'))

      // 右详情列(宽屏 + 开关开启): 内联渲染, 不经过任何子组件/@ObjectLink/@Prop 观察链路,
      // 随页面每秒重建逐秒刷新(机制与消息时间线/文件预览条相同), 见 buildDetailsPanel
      if (this.isWide && this.detailsOpen) {
        this.buildDetailsPanel()
      }
      }

      // 单一 hero 图标：启动时在屏幕中心，随后移动到空状态中心，全程清晰无交叉淡化。
      // 保持常驻渲染，但层级低于抽屉/设置浮层，让浮层自然遮盖它，避免主动消失感。
      if (this.heroVisible && (this.launchVisible || this.vm.currentMessages.length === 0)) {
        this.buildHeroIcon()
      }

      if (this.readerVisible) {
        this.buildReaderControl()
      }

      // 抽屉 - 从左侧滑入/滑出；全屏 scrim 固定覆盖，滑动过程中右侧始终有阴影
      if (this.drawerOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.modal_backdrop'))
          .onClick(() => {
            this.drawerOpen = false;
          })
          .transition(
            TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.EaseOut })
          )
        AgentDrawerView({
          agents: this.vm.agents,
          conversations: this.convListItems,
          currentAgentId: this.vm.currentAgent !== null ? this.vm.currentAgent.id : '',
          currentConversationId: this.vm.currentConversationId,
          onSelectAgent: (id: string) => {
            this.vm.selectAgent(id).then(() => {
              this.drawerOpen = false;
              this.refreshTick++;
              this.scrollToBottomDelayed();
            });
          },
          onSelectConversation: (id: string) => {
            this.vm.openConversation(id).then(() => {
              this.drawerOpen = false;
              this.refreshTick++;
              this.scrollToBottomDelayed();
            });
          },
          onDeleteConversation: (id: string) => {
            this.vm.deleteConversation(id).then(() => {
              this.refreshTick++;
              this.scrollToBottomDelayed();
            });
          },
          onNewConversation: () => {
            this.vm.startNewConversation().then(() => {
              this.drawerOpen = false;
              this.refreshTick++;
              this.scrollToBottomDelayed();
            });
          },
          onPlayGuide: () => {
            this.playGuideOpen = true;
          },
          onClose: () => {
            this.drawerOpen = false;
          }
        })
          .transition(
            TransitionEffect.asymmetric(
              TransitionEffect.translate({ x: '-100%' }).animation({ duration: 300, curve: Curve.FastOutSlowIn }),
              TransitionEffect.translate({ x: '-100%' }).animation({ duration: 250, curve: Curve.FastOutSlowIn })
            )
          )
        // 右侧透明点击层：视觉阴影由全屏 scrim 提供，这里只保证点击右侧空白能关闭
        Column()
          .width('18%')
          .height('100%')
          .position({ x: '82%', y: 0 })
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.drawerOpen = false;
          })
          .transition(
            TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.EaseOut })
          )
      }

      // 设置
      SettingsPanel({
        visible: this.settingsOpen,
        initProfileId: this.vm.currentApiProfileId,
        initProfileName: this.vm.currentApiProfile !== null ? this.vm.currentApiProfile.name : '默认配置',
        profileNames: this.getApiProfileNames(),
        selectedProfileIndex: this.vm.currentApiProfileIndex,
        initProvider: this.vm.apiConfig.provider,
        initBaseUrl: this.vm.apiConfig.baseUrl,
        initApiKey: this.vm.apiConfig.apiKey,
        initModel: this.vm.apiConfig.model,
        initTemperature: this.vm.apiConfig.temperature !== null ? this.vm.apiConfig.temperature.toString() : '',
        initTopP: this.vm.apiConfig.topP !== null ? this.vm.apiConfig.topP.toString() : '',
        initMaxTokens: this.vm.apiConfig.maxTokens !== null ? this.vm.apiConfig.maxTokens.toString() : '',
        initExtraBody: this.vm.apiConfig.extraBody,
        initAutoSuffix: this.vm.apiConfig.autoSuffix,
        initLocalSearchJson: JSON.stringify(this.vm.localSearchConfig.toJson()),
        initMmBaseUrl: this.vm.multimodalConfig.baseUrl,
        initMmApiKey: this.vm.multimodalConfig.apiKey,
        initMmModel: this.vm.multimodalConfig.model,
        initMmPreparseEnabled: this.vm.multimodalConfig.preparseEnabled,
        onClose: () => {
          this.settingsOpen = false;
        },
        onAddProfile: () => {
          this.vm.addApiProfile().then(() => {
            this.refreshTick++;
          });
        },
        onSelectProfile: (index: number) => {
          if (index >= 0 && index < this.vm.apiProfiles.length) {
            this.vm.selectApiProfile(this.vm.apiProfiles[index].id);
            this.refreshTick++;
          }
        },
        onSave: (name: string, api: ApiConfig, mm: MultimodalConfig, search: SearchEngineSettings) => {
          this.vm.saveLocalSearchConfig(search);
          this.vm.saveCurrentApiProfile(name, api, mm).then(() => {
            this.settingsOpen = false;
            this.showToast('配置已保存');
            this.refreshTick++;
          });
        },
      })

      // 玩转应用
      PlayGuidePanel({
        visible: this.playGuideOpen,
        isWide: this.isWide,
        onClose: () => {
          this.playGuideOpen = false;
        }
      })

      // 灯箱
      ImageLightbox({
        visible: this.lightboxVisible,
        imageUrl: this.lightboxUrl,
        onClose: () => {
          this.lightboxVisible = false;
          this.lightboxUrl = '';
        }
      })

      // Toast
      if (this.toastVisible) {
        Stack() {
          ToastView({ message: this.toastMessage })
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.Top)
        .padding({ top: 76 })
        .hitTestBehavior(HitTestMode.None)
      }

      // 开屏飞入动效
      if (this.launchVisible) {
        FlyInLaunchView({
          showCenter: false,
          onFinish: () => {
            this.startHeroTransition();
          }
        })
      }

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
    .onAreaChange((_old: Area, newArea: Area) => {
      const wValue = newArea.width;
      const hValue = newArea.height;
      this.rootW = wValue === undefined ? this.rootW :
        (typeof wValue === 'string' ? parseFloat(wValue) : (typeof wValue === 'number' ? wValue : this.rootW));
      this.rootH = hValue === undefined ? this.rootH :
        (typeof hValue === 'string' ? parseFloat(hValue) : (typeof hValue === 'number' ? hValue : this.rootH));
      // 根 Stack 的窗口偏移(状态栏等), 供英雄图标全局坐标换算
      const gx = newArea.globalPosition.x;
      const gy = newArea.globalPosition.y;
      this.rootOffsetX = gx === undefined ? this.rootOffsetX :
        (typeof gx === 'string' ? parseFloat(gx) : (typeof gx === 'number' ? gx : this.rootOffsetX));
      this.rootOffsetY = gy === undefined ? this.rootOffsetY :
        (typeof gy === 'string' ? parseFloat(gy) : (typeof gy === 'number' ? gy : this.rootOffsetY));
      // 桌面宽屏阈值: 2in1/平板分屏窗口 ≥700vp 启用三栏布局
      this.isWide = this.rootW >= 700;
      // 首次进入宽屏时自动展开右侧工作区详情面板
      if (this.isWide && !this.detailsAutoOpened) {
        this.detailsAutoOpened = true;
        this.detailsOpen = true;
        this.vm.refreshWorkspace().then(() => {
          this.refreshTick++;
        });
      }
      // 启动动画期间窗口变化才重置"起点"; 动画已结束后窗口变化只重算落点,
      // 否则最大化/还原会把已落位的图标拽回屏幕中心(启动起点)
      if (this.launchVisible) {
        this.updateHeroStart();
      } else {
        this.recomputeHeroTarget();
      }
    })
  }

  @Builder
  buildReaderControl() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(16)
          .fontColor([$r('app.color.brand')])
        Text(this.readerPhase)
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        Button() {
          Text('×')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        }
        .width(32)
        .height(32)
        .padding(0)
        .borderRadius(16)
        .backgroundColor($r('app.color.raised_surface'))
        .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
        .onClick(() => {
          this.vm.stopReading();
        })
      }
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 4 })
          .onActionStart((_event: GestureEvent): void => {
            this.readerDragStartX = this.readerOffsetX;
            this.readerDragStartY = this.readerOffsetY;
          })
          .onActionUpdate((event: GestureEvent): void => {
            this.readerOffsetX = Math.max(-34,
              Math.min(34, this.readerDragStartX + event.offsetX));
            this.readerOffsetY = Math.max(-55,
              Math.min(620, this.readerDragStartY + event.offsetY));
          })
      )

      Row({ space: 6 }) {
        Slider({
          value: this.readerProgress * 100,
          min: 0,
          max: 100,
          step: 1,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .trackThickness(3)
          .selectedColor($r('app.color.brand'))
          .blockColor($r('app.color.brand'))
          .onChange((value: number, mode: SliderChangeMode): void => {
            this.readerProgress = value / 100;
            if (mode === SliderChangeMode.End) {
              TextReaderService.seek(this.readerProgress);
            }
          })
        Text(Math.round(this.readerProgress * 100).toString() + '%')
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
          .width(30)
      }
      .height(20)

      Row({ space: 8 }) {
        Button(this.readerPaused ? '▶' : 'Ⅱ')
          .fontSize(11)
          .fontColor($r('app.color.text_primary'))
          .height(32)
          .width(36)
          .padding(0)
          .borderRadius(16)
          .backgroundColor($r('app.color.raised_surface'))
          .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
          .onClick((): void => {
            if (this.readerPaused) {
              TextReaderService.resume();
            } else {
              TextReaderService.pause();
            }
          })

        Button(this.getReaderSpeedLabel())
          .fontSize(11)
          .fontColor($r('app.color.text_primary'))
          .height(32)
          .width(48)
          .padding(0)
          .borderRadius(16)
          .backgroundColor($r('app.color.raised_surface'))
          .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
          .onClick((): void => {
            let nextSpeed: number = this.readerSpeed >= 1.75 ? 0.75 : this.readerSpeed + 0.25;
            TextReaderService.setSpeed(nextSpeed);
          })

        Button(this.getReaderVoiceLabel())
          .fontSize(11)
          .fontColor($r('app.color.text_primary'))
          .width(128)
          .height(32)
          .padding({ left: 10, right: 10 })
          .borderRadius(16)
          .backgroundColor($r('app.color.raised_surface'))
          .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
          .bindMenu(this.buildReaderVoiceMenu(), { placement: Placement.Bottom })
      }
      .width('100%')
    }
    .width('82%')
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(24)
    .shadow({ radius: 18, color: '#1F000000', offsetX: 0, offsetY: 6 })
    .position({ x: '9%', y: 72 })
    .translate({ x: this.readerOffsetX, y: this.readerOffsetY })
    .zIndex(20)
  }

  private getReaderVoiceOptions(): SelectOption[] {
    let options: SelectOption[] = [];
    for (let index: number = 0; index < this.readerVoices.length; index++) {
      options.push({ value: this.readerVoices[index].label });
    }
    if (options.length === 0) {
      options.push({ value: '正在查询音色…' });
    }
    return options;
  }

  @Builder
  private buildReaderVoiceMenu() {
    Column() {
      ForEach(this.readerVoices, (voice: ReaderVoiceOption, index: number) => {
        MenuItem({ content: voice.label })
          .selected(index === this.readerVoiceIndex)
          .onChange((): void => {
            TextReaderService.selectVoice(index).catch((error: Error): void => {
              this.readerPhase = '切换音色失败：' + error.message;
            });
          })
      }, (voice: ReaderVoiceOption) =>
        voice.language + voice.person.toString() + voice.style)
    }
  }

  private getReaderVoiceLabel(): string {
    if (this.readerVoiceIndex >= 0 && this.readerVoiceIndex < this.readerVoices.length) {
      return this.readerVoices[this.readerVoiceIndex].label;
    }
    return '正在查询音色…';
  }

  private getReaderSpeedLabel(): string {
    return this.readerSpeed.toFixed(1) + '×';
  }

  // 文件预览条(由 ChatPage 直接渲染, 避免子组件 @Prop 深拷不更新)
  @Builder
  buildFilePreview() {
    Column() {
      Scroll() {
        Row() {
          ForEach(this.previewItems, (item: PreviewData) => {
            this.buildPreviewItem(item)
          }, (item: PreviewData) => item.renderKey)
        }
        .padding({ left: 12, right: 12 })
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding({ top: 4, bottom: 2 })
  }

  @Builder
  buildPreviewItem(item: PreviewData) {
    Row() {
      if (item.type.startsWith('image/') && item.thumbnail !== '') {
        Image(item.thumbnail)
          .width(42)
          .height(42)
          .borderRadius(12)
          .objectFit(ImageFit.Cover)
          .backgroundColor(Color.White)
      } else {
        Text('FILE')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
          .width(40)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)
      }
      Column() {
        Text(item.name)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (item.status === 'parsing') {
          Text('解析中...')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 })
        } else if (item.status === 'error') {
          Text('解析失败')
            .fontSize(11)
            .fontColor($r('app.color.danger'))
            .margin({ top: 2 })
        } else {
          Text('已就绪')
            .fontSize(11)
            .fontColor($r('app.color.success'))
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .margin({ left: 8 })
      .alignItems(HorizontalAlign.Start)
      if (item.status !== 'parsing') {
        Text('✕')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 6, right: 2, top: 2, bottom: 2 })
          .onClick(() => {
            this.vm.removePendingFile(item.fileId);
            // rebuildPreviewItems 已由 VM 的 onStateChange 自动调用
          })
      }
    }
    .padding({ left: 12, right: 10, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.raised_surface'))
    .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
    .borderRadius(18)
    .margin({ right: 10 })
    .constraintSize({ maxWidth: 250 })
  }

  @Builder
  buildHeader() {
    Row() {
      // 菜单(窄屏抽屉入口; 宽屏由常驻侧栏接管, 不渲染)
      if (!this.isWide) {
        Button() {
          Text('☰')
            .fontSize(22)
            .fontColor($r('app.color.text_secondary'))
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.drawerOpen = true;
        })

        // 与右侧两个按钮保持等宽，让标题仍处于屏幕正中。
        Blank()
          .width(44)
      }

      // 标题 (智能体名, 居中显示)
      Row() {
        if (this.vm.currentAgent !== null) {
          Text(this.vm.currentAgent.name)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 200 })
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      // 自动朗读
      Button() {
        if (this.vm.autoReadEnabled) {
          SymbolGlyph($r('sys.symbol.speaker_wave_3'))
            .fontSize(21)
            .fontColor([$r('app.color.brand')])
        } else {
          SymbolGlyph($r('sys.symbol.speaker_wave_3_slash'))
            .fontSize(21)
            .fontColor([$r('app.color.text_secondary')])
        }
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .backgroundColor(this.vm.autoReadEnabled ? $r('app.color.brand_light') : Color.Transparent)
      .margin({ right: 3 })
      .onClick(() => {
        let enabled: boolean = !this.vm.autoReadEnabled;
        this.vm.setAutoReadEnabled(enabled);
        this.showToast(enabled ? '已开启自动朗读' : '已关闭自动朗读');
        this.refreshTick++;
      })

      // 设置
      Button() {
        SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.settingsOpen = true;
      })
    }
    .width('100%')
    .height(64)
    .padding({ left: 8, right: 8 })
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 18, color: '#0D000000', offsetX: 0, offsetY: 2 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildHeroIcon() {
    Column() {
      Image($r('app.media.cat_avatar'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
    }
    .width(this.heroSize)
    .height(this.heroSize)
    .borderRadius(this.heroSize / 2)
    .backgroundColor($r('app.color.brand_light'))
    .shadow({ radius: 24, color: '#1A000000', offsetX: 0, offsetY: 8 })
    .clip(true)
    .position({ x: this.heroX, y: this.heroY })
    .hitTestBehavior(HitTestMode.None)
    .zIndex(this.launchVisible ? 101 : 0)
  }

  @Builder
  buildEmptyState() {
    Column() {
      Blank()
      // 图标由 ChatPage 根部的 heroIcon 单节点负责，这里只留等高空位，避免重复渲染
      Column()
        .width(96)
        .height(96)
        .margin({ bottom: 12 })
        .id('emptyStateIconAnchor')
        .onAreaChange((_old: Area, newArea: Area) => {
          // 用窗口全局坐标定位英雄图标落点: 三栏布局下相对坐标会漏加侧栏宽度导致图标偏左
          const px = newArea.globalPosition.x;
          const py = newArea.globalPosition.y;
          this.anchorGlobalX = px === undefined ? this.anchorGlobalX :
            (typeof px === 'string' ? parseFloat(px) : (typeof px === 'number' ? px : this.anchorGlobalX));
          this.anchorGlobalY = py === undefined ? this.anchorGlobalY :
            (typeof py === 'string' ? parseFloat(py) : (typeof py === 'number' ? py : this.anchorGlobalY));
          this.recomputeHeroTarget();
        })
      Text(this.vm.currentAgent !== null ? this.vm.currentAgent.name : 'Guncat Work')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 12 })
      Text(this.vm.workMode ?
        'Guncat Harness：自主调度数十种工具，直接读写工作区文件，单次任务可连续运行上百轮会话，独立完成编程级复杂度的长程任务。' :
        (this.vm.currentAgent !== null ? this.vm.currentAgent.description : '选择一个智能体开始对话'))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(22)
        .padding({ left: 32, right: 32 })
      Blank()
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .onAreaChange((_old: Area, newArea: Area) => {
      // 同样记录窗口全局坐标(仅作 hero 初始落点兜底, 锚点自身已上报全局坐标)
      const bx = newArea.globalPosition.x;
      const by = newArea.globalPosition.y;
      this.emptyStateBaseX = bx === undefined ? 0 :
        (typeof bx === 'string' ? parseFloat(bx) : (typeof bx === 'number' ? bx : 0));
      this.emptyStateBaseY = by === undefined ? 0 :
        (typeof by === 'string' ? parseFloat(by) : (typeof by === 'number' ? by : 0));
    })
  }

  @Builder
  buildMessageList() {
    Scroll(this.messageScroller) {
      Column() {
        if (this.vm.workMode) {
          this.buildWorkTimeline()
        } else {
          ForEach(this.vm.currentMessages, (msg: Message) => {
            ChatBubbleView({
              message: msg,
              isStreaming: this.vm.isStreaming &&
                msg === this.vm.currentMessages[this.vm.currentMessages.length - 1] &&
                msg.role === 'assistant',
              isWork: this.vm.workMode,
              isLastAssistant: this.vm.currentMessages.length > 0 &&
                msg === this.vm.currentMessages[this.vm.currentMessages.length - 1] &&
                msg.role === 'assistant',
              onCopyPlain: (id: string) => {
                this.vm.copyMessagePlain(id);
                this.showToast('已复制');
              },
              onCopyMarkdown: (id: string) => {
                this.vm.copyMessageMarkdown(id);
                this.showToast('已复制 Markdown');
              },
              onRegenerate: (id: string) => {
                this.vm.regenerateMessage(id);
                this.refreshTick++;
              },
              onRead: (id: string) => {
                this.vm.readMessage(id);
              },
              onExportWord: (id: string) => {
                this.handleExportWord(id);
              },
              onImageTap: (url: string) => {
                this.lightboxUrl = url;
                this.lightboxVisible = true;
              },
              onEditToInput: (id: string) => {
                let msg: Message | null = this.findMessage(id);
                if (msg !== null) {
                  this.fillInputFromMessage(msg);
                }
              }
            })
          }, (msg: Message) => msg.id)
        }

        // ask_user_question 问题卡片(工具挂起等待作答时渲染在时间线末尾)
        if (this.vm.pendingAsk !== null) {
          AskUserCard({
            ask: this.vm.pendingAsk,
            onAnswer: (askId: string, selections: string[], note: string) => {
              this.vm.answerAsk(askId, selections, note);
            },
            onCancel: (askId: string) => {
              this.vm.cancelAsk(askId);
            }
          })
            .margin({ top: 4 })
        }

        Blank().height(8)
      }
      .width('100%')
      .padding({ top: 16, bottom: 16, left: 12, right: 12 })
    }
    .layoutWeight(1)
    .width('100%')
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    // 单击消息区(含气泡内点击冒泡至此): 广播复位信号, 让发生过拖选的回答取消文本选区
    .onClick(() => {
      AppStorage.setOrCreate('richSelectionResetTick',
        ((AppStorage.get<number>('richSelectionResetTick') ?? 0) + 1));
    })
    // 触摸期间标记 userScrolling, 暂停自动置底; 松手后恢复自动置底
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down || event.type === TouchType.Move) {
        this.userScrolling = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.userScrolling = false;
      }
    })
    // 宽屏三栏时加宽留白, 会话内容保持舒适阅读宽度
    .padding({ left: this.isWide ? 28 : 0, right: this.isWide ? 28 : 0 })
  }

  // 工作模式时间线: 单容器 + 单一标识, 用户任务与各轮 思考→工具→正文 按发生顺序排列
  @Builder
  buildWorkTimeline() {
    Column({ space: 14 }) {
      // 时间线头(全时间线唯一的标识, 不再逐轮出现头像)
      Row({ space: 10 }) {
        // 机器人标识: 无背景底色, 放大显示
        Image($r('app.media.ic_work'))
          .width(32)
          .height(32)
          .fillColor($r('app.color.brand'))

        Column() {
          Text('工作模式')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.vm.isStreaming ? '任务执行中...' : 'Agent 就绪, 描述任务或上传文件')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      ForEach(this.vm.currentMessages, (msg: Message) => {
        if (msg.role === 'user') {
          this.buildWorkTaskCard(msg)
        } else {
          WorkTurnView({
            message: msg,
            isStreaming: this.vm.isStreaming &&
              msg === this.vm.currentMessages[this.vm.currentMessages.length - 1],
            isLastAssistant: msg === this.vm.currentMessages[this.vm.currentMessages.length - 1] &&
              msg.role === 'assistant',
            onCopyPlain: (id: string) => {
              this.vm.copyMessagePlain(id);
              this.showToast('已复制');
            },
            onCopyMarkdown: (id: string) => {
              this.vm.copyMessageMarkdown(id);
              this.showToast('已复制 Markdown');
            },
            onExportWord: (id: string) => {
              this.handleExportWord(id);
            },
            onRegenerate: (id: string) => {
              this.vm.regenerateMessage(id);
              this.refreshTick++;
            }
          })
        }
      }, (msg: Message) => msg.id)

      // 工作模式产物汇总卡: 放在对话流末尾, 默认折叠(Codex 风格 Changes)
      if (!this.vm.isStreaming && this.workArtifacts.length > 0) {
        WorkArtifactsCard({
          files: this.workArtifacts,
          totalAdds: this.workArtifactAdds,
          totalDels: this.workArtifactDels,
          onPreview: (path: string) => {
            this.vm.previewWorkspaceFile(path);
          },
          onShare: (path: string) => {
            this.vm.shareWorkspaceFile(path);
          }
        })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)
    .shadow({ radius: 16, color: '#14000000', offsetX: 0, offsetY: 4 })
  }

  @Builder
  buildWorkTaskCard(msg: Message) {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Text('任务')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(8)
          .backgroundColor($r('app.color.raised_surface'))
        Text(msg.displayContent !== '' ? msg.displayContent : msg.content)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(21)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 操作行: 填入输入框(重新编辑) + 复制原文。
      // 左侧缩进 46vp(任务标签宽 36 + 间距 10), 使图标与任务文本起始位置对齐
      Row({ space: 8 }) {
        Button() {
          Image($r('sys.media.ohos_ic_public_edit'))
            .width(14)
            .height(14)
            .fillColor($r('app.color.text_secondary'))
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.fillInputFromMessage(msg);
        })
        Button() {
          Image($r('sys.media.ohos_ic_public_copy'))
            .width(14)
            .height(14)
            .fillColor($r('app.color.text_secondary'))
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.vm.copyMessagePlain(msg.id).then((): void => {
            this.showToast('已复制');
          });
        })
      }
      .width('100%')
      .padding({ left: 46 })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .padding(12)
    .borderRadius(14)
    .backgroundColor($r('app.color.brand_light'))
    .alignItems(HorizontalAlign.Start)
  }

  // 导出消息为 Word 文档
  private handleExportWord(msgId: string): void {
    let msg: Message | null = this.findMessage(msgId);
    if (msg === null || msg.role !== 'assistant') {
      this.showToast('消息不存在');
      return;
    }
    if (msg.content.trim() === '') {
      this.showToast('消息内容为空');
      return;
    }
    this.showToast('正在导出…');
    let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    DocxExporter.exportToDocx(context, msg.content, 'Guncat Work 对话导出').then((fileName: string) => {
      this.showToast('已导出 ' + fileName);
    }).catch((error: Error) => {
      this.showToast('导出失败: ' + error.message);
    });
  }

  private findMessage(id: string): Message | null {
    let msgs: Message[] = this.vm.currentMessages;
    for (let i: number = 0; i < msgs.length; i++) {
      if (msgs[i].id === id) {
        return msgs[i];
      }
    }
    return null;
  }

  private handleSend(text: string): void {
    if (text.trim() === '') {
      return;
    }
    if (this.vm.isStreaming) {
      return;
    }
    if (this.vm.apiConfig.apiKey === '') {
      this.showToast('请先配置 API Key');
      this.settingsOpen = true;
      return;
    }
    if (this.vm.currentAgent === null) {
      this.showToast('请先选择一个智能体');
      return;
    }
    // 注意: inputText 的清空由 MessageInputView 内部 onClick 在确认真正发送后才执行
    this.vm.sendMessage(text);
    this.refreshTick++;
    this.scrollToBottomDelayed();
  }

  @Builder
  private buildModelSelector() {
    Row() {
      Text(this.vm.currentApiProfile !== null ? this.vm.currentApiProfile.name : '模型')
        // 字号固定 12, 与右侧 ToggleSwitch 完全一致(此前 13 且带 6~13 自适应缩放, 造成大小不一)
        .fontSize(12)
        .lineHeight(16)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    // 手机: 继续占满剩余宽度; 桌面宽屏: 按内容自适应(108~200), 避免胶囊吞掉整行
    .layoutWeight(this.isWide ? 0 : 1)
    .constraintSize(this.isWide ? { minWidth: 108, maxWidth: 200 } : { minWidth: 108 })
    // 显式锁定与 ToggleSwitch 等高(上下 padding 7 + 行高 16 = 30): 宽屏下胶囊改为内容自适应宽度,
    // Text 的 min/max 自适应字号测量会把行框撑得略高于 lineHeight, 固定高度保证两个平台都等高
    .height(30)
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .borderRadius(15)
    .backgroundColor($r('app.color.raised_surface'))
    .shadow({ radius: 12, color: '#14000000', offsetX: 0, offsetY: 3 })
    .margin({ right: 8 })
    .enabled(!this.vm.isStreaming && !this.vm.isParsing && !this.isListening)
    // bindPopup 是纯状态驱动(不像 bindMenu 点击自动弹出), 需自行点击置位开关
    .onClick(() => {
      this.modelMenuOpen = !this.modelMenuOpen;
    })
    .bindPopup(this.modelMenuOpen, {
      builder: this.buildModelProfilePopup,
      placement: Placement.Top,
      // 透明遮罩: 点击弹层外任意区域即收起, 且不压暗页面
      mask: { color: Color.Transparent },
      showInSubWindow: false,
      onStateChange: (e: PopupStateChangeParam) => {
        if (this.modelMenuOpen !== e.isVisible) {
          this.modelMenuOpen = e.isVisible;
        }
      }
    })
  }

  // 模型选择弹层: 上半部分为 API 配置(模型)列表; 工作模式下横线分隔后额外显示能力预设(推理强度)选择
  @Builder
  private buildModelProfilePopup() {
    Column() {
      Scroll() {
        Column() {
          ForEach(this.vm.apiProfiles, (profile: ApiProfile) => {
            Row() {
              Text(profile.name)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (profile.id === this.vm.currentApiProfileId) {
                Text('✓')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.brand'))
              }
            }
            .width('100%')
            .height(42)
            .padding({ left: 12, right: 12 })
            .borderRadius(12)
            .backgroundColor(profile.id === this.vm.currentApiProfileId ?
              $r('app.color.brand_light') : Color.Transparent)
            .onClick(() => {
              this.vm.selectApiProfile(profile.id);
              this.modelMenuOpen = false;
              this.refreshTick++;
            })
          }, (profile: ApiProfile) => profile.id)
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 240 })
      .scrollBar(BarState.Off)

      if (this.vm.workMode) {
        // 推理强度区仅工作模式显示: 分隔横线 + 档位选择(聊天模式弹层保持只有模型列表)
        Divider()
          .strokeWidth(1)
          .color($r('app.color.divider'))
          .margin({ top: 6, bottom: 8 })

        Text('能力预设')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 12 })
          .margin({ bottom: 8 })

        Row({ space: 6 }) {
          // 档位胶囊直接内联(选中高亮随 vm.reasoningEffort 实时变化);
          // 勿改回带参 @Builder: 按值传参的 @Builder 子树不随状态刷新
          Text('极高(Max)')
            .fontSize(12)
            .fontWeight(this.vm.reasoningEffort === 'max' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.vm.reasoningEffort === 'max' ?
              $r('app.color.brand') : $r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .height(30)
            .layoutWeight(1)
            .borderRadius(15)
            .backgroundColor(this.vm.reasoningEffort === 'max' ?
              $r('app.color.brand_light') : $r('app.color.raised_surface'))
            .onClick(() => {
              this.vm.setReasoningEffort('max');
              this.refreshTick++;
            })
          Text('均衡(High)')
            .fontSize(12)
            .fontWeight(this.vm.reasoningEffort === 'high' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.vm.reasoningEffort === 'high' ?
              $r('app.color.brand') : $r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .height(30)
            .layoutWeight(1)
            .borderRadius(15)
            .backgroundColor(this.vm.reasoningEffort === 'high' ?
              $r('app.color.brand_light') : $r('app.color.raised_surface'))
            .onClick(() => {
              this.vm.setReasoningEffort('high');
              this.refreshTick++;
            })
          Text('快速(Low)')
            .fontSize(12)
            .fontWeight(this.vm.reasoningEffort === 'low' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.vm.reasoningEffort === 'low' ?
              $r('app.color.brand') : $r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .height(30)
            .layoutWeight(1)
            .borderRadius(15)
            .backgroundColor(this.vm.reasoningEffort === 'low' ?
              $r('app.color.brand_light') : $r('app.color.raised_surface'))
            .onClick(() => {
              this.vm.setReasoningEffort('low');
              this.refreshTick++;
            })
        }
        .width('100%')
        .padding({ left: 6, right: 6, bottom: 2 })
      }
    }
    .width(240)
    .padding(6)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(18)
    .shadow({ radius: 16, color: '#1A000000', offsetX: 0, offsetY: 6 })
  }

  private getApiProfileOptions(): SelectOption[] {
    let options: SelectOption[] = [];
    for (let i: number = 0; i < this.vm.apiProfiles.length; i++) {
      let profile: ApiProfile = this.vm.apiProfiles[i];
      options.push({ value: profile.name });
    }
    return options;
  }

  private getApiProfileNames(): string[] {
    let names: string[] = [];
    for (let i: number = 0; i < this.vm.apiProfiles.length; i++) {
      names.push(this.vm.apiProfiles[i].name);
    }
    return names;
  }

  private handleStop(): void {
    this.vm.stopStreaming();
    this.refreshTick++;
  }

  private async handleVoiceInput(): Promise<void> {
    if (this.voiceInputService.isListening()) {
      await this.voiceInputService.stop();
      return;
    }
    if (!canIUse('SystemCapability.AI.SpeechRecognizer')) {
      this.showToast('当前设备不支持语音输入');
      return;
    }
    let granted: boolean = await this.requestMicrophonePermission();
    if (!granted) {
      this.showToast('请允许麦克风权限后再使用语音输入');
      return;
    }
    await this.voiceInputService.start(
      this.inputText,
      (text: string): void => {
        this.inputText = text;
      },
      (listening: boolean): void => {
        this.isListening = listening;
      },
      (message: string): void => {
        this.isListening = false;
        this.showToast(message);
      }
    );
  }

  private async requestMicrophonePermission(): Promise<boolean> {
    try {
      let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      let manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      let result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      if (result.authResults.length === 0) {
        return false;
      }
      return result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      let businessError: BusinessError = error as BusinessError;
      console.error(`Request microphone permission failed: ${businessError.code}, ${businessError.message}`);
      return false;
    }
  }

  private async handleFileUpload(): Promise<void> {
    // 工作模式: 上传直接进入沙箱工作区, 不作为聊天附件
    if (this.vm.workMode) {
      await this.vm.uploadToWorkspace();
      this.refreshTick++;
      return;
    }
    await this.vm.pickAndParseFiles();
    this.rebuildPreviewItems();
    this.refreshTick++;
  }

  // "工作模式"胶囊上方的工作区弹层
  @Builder
  buildWorkspacePopup() {
    WorkspaceBar({
      vm: this.vm,
      onUpload: () => {
        this.handleWorkspaceUpload();
      },
      onExport: () => {
        this.handleWorkspaceExport();
      }
    })
  }

  // 工作区面板: 上传
  private handleWorkspaceUpload(): void {
    this.vm.uploadToWorkspace().then(() => {
      this.refreshTick++;
    });
  }

  // ===== 右侧工作区详情面板(宽屏常驻, 内联渲染) =====
  // 不再使用独立子组件: 子组件的 @ObjectLink/@Prop 观察链路在该常驻面板上不生效(弹层正常、侧栏冻结)。
  // 这里直接内联在页面 build 里, 数据每次页面重建时现读 vm —— 与消息时间线/文件预览条同一条
  // 已验证的刷新路径; 秒级定时器每秒递增 refreshTick, 面板头部绿点即本版本的可见标识。

  private detailLastAssistant(): Message | null {
    let msgs: Message[] = this.vm.currentMessages;
    for (let i: number = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role === 'assistant') {
        return msgs[i];
      }
    }
    return null;
  }

  // 工具调用总轮数: 汇总当前会话所有 assistant 轮的工具调用次数。
  // 工作循环每轮各有一条 assistant 消息、工具记录挂在各自轮次上,
  // 而收尾轮通常是纯文本回答 —— 只看最后一条会恒为 0
  private detailToolCallTotal(): number {
    let msgs: Message[] = this.vm.currentMessages;
    let total: number = 0;
    for (let i: number = 0; i < msgs.length; i++) {
      if (msgs[i].role === 'assistant') {
        total += msgs[i].toolCalls.length;
      }
    }
    return total;
  }

  // 重建统计快照并整体赋值: 面板统计区只依赖 workStats 这一个顶层状态
  private rebuildWorkStats(): void {
    let s: WorkPanelStats = new WorkPanelStats();
    s.elapsedSec = this.vm.workElapsedSec;
    let last: Message | null = this.detailLastAssistant();
    s.speedText = last !== null && last.tokenSpeed > 0 ?
      Math.round(last.tokenSpeed).toString() + ' 字符/秒' : '—';
    s.cacheText = last !== null && last.cacheHitRate >= 0 ?
      Math.round(last.cacheHitRate * 100).toString() + '%' : '—';
    s.toolCalls = this.detailToolCallTotal();
    s.goalText = this.detailGoalText();
    this.workStats = s;
  }

  // 重建工作模式产物汇总卡: 从消息工具调用中聚合改动文件, 并只保留工作区仍存在的文件
  private rebuildWorkArtifacts(): void {
    if (!this.vm.workMode) {
      this.workArtifacts = [];
      this.workArtifactAdds = 0;
      this.workArtifactDels = 0;
      return;
    }
    let summary: WorkArtifactSummary = WorkArtifactUtil.collect(this.vm.currentMessages);
    let existing: Map<string, boolean> = new Map<string, boolean>();
    let files: WorkspaceFileInfo[] = this.vm.workspaceFiles;
    for (let i: number = 0; i < files.length; i++) {
      if (!files[i].isDir) {
        existing.set(files[i].path, true);
      }
    }
    let kept: WorkArtifactFile[] = [];
    let adds: number = 0;
    let dels: number = 0;
    for (let i: number = 0; i < summary.files.length; i++) {
      let f: WorkArtifactFile = summary.files[i];
      if (existing.has(f.path)) {
        kept.push(f);
        adds += f.adds;
        dels += f.dels;
      }
    }
    this.workArtifacts = kept;
    this.workArtifactAdds = adds;
    this.workArtifactDels = dels;
  }

  // 目标文本需读文件, 加 3 秒缓存避免每秒渲染都做 IO
  private goalCacheConvId: string = '';
  private goalCacheAt: number = 0;
  private goalCacheText: string = '';

  private detailGoalText(): string {
    let now: number = Date.now();
    if (this.goalCacheConvId === this.vm.currentConversationId &&
      now - this.goalCacheAt < 3000) {
      return this.goalCacheText;
    }
    let text: string = '';
    if (this.vm.context !== null && this.vm.currentConversationId !== '') {
      let ctx: common.UIAbilityContext = this.vm.context;
      let root: string = WorkFileService.workspaceRoot(ctx, this.vm.currentConversationId);
      let goal: GoalItem | null = GoalService.read(root);
      text = goal !== null ? goal.objective : '';
    }
    this.goalCacheConvId = this.vm.currentConversationId;
    this.goalCacheAt = now;
    this.goalCacheText = text;
    return text;
  }

  @Builder
  private buildDetailsPanel() {
    Column() {
      // 面板头: 标题 + 实时标记(绿点) + 刷新 + 收起
      Row({ space: 8 }) {
        Text('工作区详情')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('●')
          .fontSize(9)
          .fontColor($r('app.color.success'))
        Text('实时')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Button() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.vm.refreshWorkspace().then(() => {
            this.refreshTick++;
          });
        })
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.detailsOpen = false;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 12 })

      Scroll() {
        Column({ space: 16 }) {
          // 统计卡: 行内容直接内联读快照状态。切勿改回带参 @Builder ——
          // @Builder 按值传参时整块子树不随状态刷新(此前统计区冻结的根因)
          Column({ space: 10 }) {
            Text('本轮统计')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .letterSpacing(1.5)
            Row() {
              Text('任务用时')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Text(this.workStats.elapsedSec.toString() + ' 秒')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
            Row() {
              Text('输出速度')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Text(this.workStats.speedText)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
            Row() {
              Text('缓存命中')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Text(this.workStats.cacheText)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
            Row() {
              Text('工具调用轮数')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Text(this.workStats.toolCalls.toString())
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .borderRadius(14)
          .border({ width: 1, color: $r('app.color.divider') })
          .alignItems(HorizontalAlign.Start)

          // 目标卡
          if (this.workStats.goalText !== '') {
            Column({ space: 10 }) {
              Text('当前目标')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .letterSpacing(1.5)
              Text(this.workStats.goalText)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(20)
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .borderRadius(14)
            .border({ width: 1, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)
          }

          // 文件卡
          Column({ space: 10 }) {
            Row() {
              Text('文件 (' + this.vm.workspaceFiles.length.toString() + ')')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .letterSpacing(1.5)
                .layoutWeight(1)
              Text('上传')
                .fontSize(13)
                .fontColor($r('app.color.brand'))
                .padding({ left: 10, right: 4, top: 3, bottom: 3 })
                .onClick(() => {
                  this.handleWorkspaceUpload();
                })
              Text('导出')
                .fontSize(13)
                .fontColor($r('app.color.brand'))
                .padding({ left: 4, right: 4, top: 3, bottom: 3 })
                .onClick(() => {
                  this.handleWorkspaceExport();
                })
            }
            .width('100%')

            if (this.vm.workspaceFiles.length === 0) {
              Text('(工作区为空)')
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .padding({ top: 12, bottom: 12 })
            } else {
              ForEach(this.vm.workspaceFiles, (item: WorkspaceFileInfo) => {
                Row({ space: 8 }) {
                  Row({ space: 8 }) {
                    if (item.isDir) {
                      SymbolGlyph($r('sys.symbol.folder'))
                        .fontSize(16)
                        .fontColor([$r('app.color.text_tertiary')])
                    } else {
                      SymbolGlyph(WorkspaceFileIcons.iconFor(item.path))
                        .fontSize(16)
                        .fontColor([$r('app.color.text_tertiary')])
                    }
                    Text(item.path)
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .layoutWeight(1)
                  .onClick(() => {
                    if (this.vm.isStreaming || item.isDir) {
                      return;
                    }
                    this.vm.previewWorkspaceFile(item.path);
                  })
                  if (!item.isDir) {
                    Text(WorkFileService.formatSize(item.size))
                      .fontSize(11)
                      .fontColor($r('app.color.text_tertiary'))
                    Text('分享')
                      .fontSize(11)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                      .borderRadius(8)
                      .backgroundColor($r('app.color.brand_light'))
                      .onClick(() => {
                        if (this.vm.isStreaming) {
                          return;
                        }
                        this.vm.shareWorkspaceFile(item.path);
                      })
                    SymbolGlyph($r('sys.symbol.trash'))
                      .fontSize(14)
                      .fontColor([$r('app.color.text_tertiary')])
                      .padding(4)
                      .onClick(() => {
                        this.vm.deleteWorkspaceFile(item.path).then(() => {
                          this.refreshTick++;
                        });
                      })
                  }
                }
                .width('100%')
                .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                .borderRadius(10)
                .backgroundColor($r('app.color.input_bg'))
              }, (item: WorkspaceFileInfo) => item.path + '#' + item.size.toString())
            }
          }
          .width('100%')
          .padding(16)
          .borderRadius(14)
          .border({ width: 1, color: $r('app.color.divider') })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 16 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      // 内容不足一屏时顶对齐(Scroll 默认把不满屏的内容垂直居中, 导致统计卡悬在半空)
      .align(Alignment.Top)
    }
    .width(300)
    .height('100%')
    .backgroundColor($r('app.color.background'))
    .border({ width: { left: 1 }, color: { left: $r('app.color.divider') } })
  }

  // 工作区面板: 打包导出 zip
  private handleWorkspaceExport(): void {
    if (this.vm.workspaceFiles.length === 0) {
      this.showToast('工作区为空, 无可导出内容');
      return;
    }
    this.showToast('正在打包工作区...');
    this.vm.exportWorkspaceZip().then((fileName: string) => {
      this.showToast('已导出 ' + fileName);
    }).catch((error: Error) => {
      this.showToast('导出失败: ' + error.message);
    });
  }

  // 快捷拍照: 系统相机拍照后加入附件
  private async handleCameraCapture(): Promise<void> {
    if (this.vm.isStreaming || this.vm.isParsing || this.isListening) {
      return;
    }
    try {
      await this.vm.capturePhoto();
    } catch (error) {
      let err: Error = error as Error;
      this.showToast('拍照失败: ' + err.message);
    }
    this.refreshTick++;
  }

  // 从 VM.pendingFiles 重建预览数据(每次状态变更时调用)
  private rebuildPreviewItems(): void {
    let items: PreviewData[] = [];
    let files: FileItem[] = this.vm.pendingFiles;
    for (let i: number = 0; i < files.length; i++) {
      items.push(PreviewData.fromFileItem(files[i]));
    }
    this.previewItems = items;
  }

  // 从预览数组中移除已删除的项
  private removePreviewItem(id: string): void {
    let remaining: PreviewData[] = [];
    for (let i: number = 0; i < this.previewItems.length; i++) {
      if (this.previewItems[i].fileId !== id) {
        remaining.push(this.previewItems[i]);
      }
    }
    this.previewItems = remaining;
  }
}
