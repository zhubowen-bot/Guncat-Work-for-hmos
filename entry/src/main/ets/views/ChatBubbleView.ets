import { Message } from '../model/Message';
import { Attachment } from '../model/Attachment';
import { ToolCallRecord } from '../model/ToolCallRecord';
import { RichTextView } from './RichTextView';
import { GuncatUiView } from './GuncatUiView';
import { GuncatUiParts, GuncatUiSeg, GuncatUiSegType } from '../common/GuncatUiParts';
import { GuncatUiBlocks, GuncatUiSpec, GuncatUiPayload } from '../common/GuncatUiSpec';

// 工具步骤的文本格式化(静态类, 供 @Builder 内调用; WorkTurnView 复用)
export class WorkStepFormat {
  static capText(text: string, max: number): string {
    if (text.length <= max) {
      return text;
    }
    return text.substring(0, max) + '...';
  }

  // 参数概要: 优先展示 path/from/to/query, content 只取开头
  static summarizeArgs(call: ToolCallRecord): string {
    // 流式生成中的参数不是完整 JSON: 大参数整段解析(失败也要扫到末尾)开销大,
    // 先用结尾字符廉价判断, 未收口直接回退原文展示
    let trimmed: string = call.argsJson.trim();
    if (trimmed !== '' && !trimmed.endsWith('}')) {
      return WorkStepFormat.capText(call.argsJson, 80);
    }
    try {
      let parsed: Object = JSON.parse(call.argsJson);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        let rec: Record<string, Object> = parsed as Record<string, Object>;
        let keys: string[] = ['path', 'from', 'to', 'query', 'url', 'pattern',
          'command', 'objective', 'description', 'message', 'question', 'content'];
        let parts: string[] = [];
        for (let i: number = 0; i < keys.length; i++) {
          let v: Object = rec[keys[i]];
          if (typeof v === 'string' && (v as string) !== '') {
            let val: string = v as string;
            if (keys[i] === 'content') {
              parts.push('content=' + WorkStepFormat.capText(val.replace(/\s+/g, ' '), 48));
            } else {
              parts.push(keys[i] + '=' + WorkStepFormat.capText(val, 80));
            }
          }
        }
        if (parts.length > 0) {
          // 单参数时省略 "path=" 这类键名, 对齐 CLI 工具行 "Edit · 路径" 的观感
          if (parts.length === 1) {
            let eq: number = parts[0].indexOf('=');
            if (eq >= 0) {
              return parts[0].substring(eq + 1);
            }
          }
          return parts.join(', ');
        }
      }
    } catch (e) {
      // 参数不是合法 JSON 时回退原文
    }
    return WorkStepFormat.capText(call.argsJson, 80);
  }

  static formatDuration(ms: number): string {
    if (ms < 1000) {
      return ms.toString() + 'ms';
    }
    return (ms / 1000).toFixed(1) + 's';
  }

  // 工具类别图标: CLI 式行内工具行左端的彩色系单色小图标, 按工具名映射 sys.symbol
  static iconRes(toolName: string): Resource {
    switch (toolName) {
      case 'read_file':
      case 'read_ppt':
      case 'parse_document':
        return $r('sys.symbol.doc_text');
      case 'write_file':
      case 'write_docx':
      case 'write_xlsx':
      case 'write_pptx':
      case 'write_csv':
      case 'write_svg':
        return $r('sys.symbol.doc_plaintext_and_pencil');
      case 'append_file':
      case 'edit_ppt':
      case 'transform_file':
        return $r('sys.symbol.pencil_tip');
      case 'search_files':
      case 'search_pdf':
      case 'record_search':
      case 'glob':
      case 'grep':
      case 'session_search':
        return $r('sys.symbol.magnifyingglass');
      case 'edit':
      case 'str_replace_editor':
        return $r('sys.symbol.pencil_tip');
      case 'web_fetch':
        return $r('sys.symbol.link');
      case 'ask_user_question':
        return $r('sys.symbol.info_circle');
      case 'schedule_create':
      case 'schedule_delete':
      case 'schedule_list':
        return $r('sys.symbol.arrow_clockwise');
      case 'goal_create':
      case 'goal_get':
      case 'goal_update':
        return $r('sys.symbol.flag');
      case 'subagent':
        return $r('sys.symbol.rectangle_stack');
      case 'list_files':
        return $r('sys.symbol.folder');
      case 'create_dir':
        return $r('sys.symbol.folder_badge_plus');
      case 'delete_file':
        return $r('sys.symbol.trash');
      case 'move_file':
        return $r('sys.symbol.move');
      case 'download_file':
        return $r('sys.symbol.arrow_down_to_line');
      case 'view_image':
      case 'pdf_to_images':
        return $r('sys.symbol.picture');
      case 'todo_write':
        return $r('sys.symbol.list_checkmark');
      case 'list_skills':
      case 'load_skill':
        return $r('sys.symbol.list_book');
      case 'bash':
        return $r('sys.symbol.code');
      case 'run_js':
        return $r('sys.symbol.code');
      default:
        return $r('sys.symbol.wrench_and_screwdriver');
    }
  }

  // 工具行的短显示名: 已知工具映射为动宾式短名, 未知工具回退原名
  static displayName(toolName: string): string {
    switch (toolName) {
      case 'read_file':
      case 'read_ppt':
        return 'Read';
      case 'parse_document':
        return 'Parse';
      case 'write_file':
      case 'write_docx':
      case 'write_xlsx':
      case 'write_pptx':
      case 'write_csv':
      case 'write_svg':
        return 'Write';
      case 'append_file':
        return 'Append';
      case 'edit_ppt':
        return 'Edit';
      case 'transform_file':
        return 'Transform';
      case 'search_files':
      case 'search_pdf':
      case 'record_search':
        return 'Search';
      case 'glob':
        return 'Glob';
      case 'grep':
        return 'Grep';
      case 'edit':
      case 'str_replace_editor':
        return 'Edit';
      case 'web_fetch':
        return 'Fetch';
      case 'ask_user_question':
        return 'Ask';
      case 'schedule_create':
      case 'schedule_delete':
      case 'schedule_list':
        return 'Schedule';
      case 'goal_create':
      case 'goal_get':
      case 'goal_update':
        return 'Goal';
      case 'subagent':
        return 'Spawn';
      case 'session_search':
        return 'Log';
      case 'list_files':
        return 'List';
      case 'list_skills':
        return 'Skills';
      case 'load_skill':
        return 'Skill';
      case 'create_dir':
        return 'Mkdir';
      case 'delete_file':
        return 'Delete';
      case 'move_file':
        return 'Move';
      case 'download_file':
        return 'Download';
      case 'view_image':
      case 'pdf_to_images':
        return 'Image';
      case 'todo_write':
        return 'Todo';
      case 'bash':
        return 'Bash';
      case 'run_js':
        return 'JS';
      default:
        return toolName;
    }
  }
}

// 聊天气泡 (对齐 web 版本 .message / .bubble)
@Component
export struct ChatBubbleView {
  @ObjectLink message: Message;
  private onCopyPlain: (id: string) => void = (_id: string): void => {};
  private onCopyMarkdown: (id: string) => void = (_id: string): void => {};
  private onRegenerate: (id: string) => void = (_id: string): void => {};
  private onRead: (id: string) => void = (_id: string): void => {};
  private onExportWord: (id: string) => void = (_id: string): void => {};
  private onImageTap: (url: string) => void = (_url: string): void => {};
  // 用户消息: 把内容原样填回输入框(重新编辑发送)
  private onEditToInput: (id: string) => void = (_id: string): void => {};
  // ===== 交互模式 (Intelligent UI) =====
  // 界面块已回传(置灰防重复提交); 由 ChatPage 依据当前待交互消息判定
  @Prop uiLocked: boolean = false;
  // 用户在交互界面上的操作回传(表单提交/选项点击), 由 ChatPage 转成 user 消息交给 Agent Loop
  private onUiInteract: (messageId: string, payload: GuncatUiPayload) => void =
    (_messageId: string, _payload: GuncatUiPayload): void => {};
  // 复制局部已改为 RichTextView 文本选择常开, 不再需要按钮回调
  // 深度思考条折叠状态 (默认折叠, 点击头部展开)
  @State private reasoningExpanded: boolean = false;
  // 当前展开结果详情的工具步骤(工作模式, 单步展开)
  @State private expandedStepId: string = '';
  // 步骤状态刷新计数(流式中由 flushTimer 推进, 驱动步骤卡片重渲染)
  @State private stepsTick: number = 0;
  // 工作模式上下文: 工作会话中间轮次隐藏操作按钮、思考条改称"思考"
  @Prop isWork: boolean = false;
  @Prop isLastAssistant: boolean = false;
  // 流式也走 RichTextView (库内置流式增量渲染 + Worker 子线程解析)
  // visibleText 保留 33ms 节流, 作为 UI 缓冲, 避免每个 token 都触发整块重渲染
  @State visibleText: string = '';
  @State visibleReasoning: string = '';
  // 交互模式: 消息体内嵌的 guncat-ui 界面块切分结果(普通文本片段 + 交互界面片段)。
  // 必须用**数组型 @State + 整数组重赋值**才能被 ArkUI 观察到: 早前放在类实例
  // (GuncatUiParts) 的字段里, 流式结束后那次赋值不会驱动 ForEach 重跑, 表现为
  // "卡片停在骨架态, 切走再切回会话(组件重建)才正常"。这是本功能的关键坑, 勿改回。
  @State private uiSegs: GuncatUiSeg[] = [];
  private flushTimer: number = -1;
  // 收尾自愈状态: uiBuildFinalized 记录当前 uiSegs 是否按"已结束"语义构建
  private uiSettleTimer: number = -1;
  private uiBuildFinalized: boolean = false;
  private lastUiSeen: string = '';
  // 诊断仪表: 实例号(重建计数) + 内容修订号(收到更新的次数) + 已挂载秒数
  private static uiInstanceSeq: number = 0;
  private uiRenderId: number = 0;
  @State private uiContentRev: number = 0;
  @State private uiMountedSec: number = 0;
  private uiMountTick: number = -1;
  // 界面片段渲染 key 版本: 变化即让 ForEach key 变化 → 强制重建子组件(绕开失效的观察链)
  @State private uiRenderKey: number = 0;
  // 思考跑马灯: 流式中在思考条右侧空白区滚动呈现最新思考内容(对齐工作模式 WorkTurnView)
  private marqueeScroller: Scroller = new Scroller();

  @Watch('onStreamPropChanged')
  @Prop isStreaming: boolean = false;

  onStreamPropChanged(): void {
    if (!this.isStreaming && this.flushTimer !== -1) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
      this.visibleText = this.message.content;
      this.visibleReasoning = this.message.reasoning;
      this.stepsTick++;
      this.refreshUiParts();
    }
  }

  // 交互界面块切分(仅在消息体含 guncat-ui 标记时才重建, 普通消息零开销)。
  // finalized = 该条消息产出已结束: 未闭合的界面块据此从"生成中"转为"未完成"静态展示。
  private refreshUiParts(): void {
    let content: string = this.isStreaming ? this.visibleText : this.message.content;
    this.lastUiSeen = content;
    this.uiBuildFinalized = !this.isStreaming;
    if (content.indexOf(GuncatUiBlocks.OPEN) < 0) {
      if (this.uiSegs.length > 0) {
        this.uiSegs = [];
      }
      return;
    }
    let parts: GuncatUiParts = GuncatUiParts.build(content, this.uiBuildFinalized);
    // 重新赋值整个数组(而不是改内部字段), 保证 UI 一定刷新
    let next: GuncatUiSeg[] = [];
    for (let i: number = 0; i < parts.segments.length; i++) {
      next.push(parts.segments[i]);
    }
    this.uiSegs = next;
    this.uiContentRev++;
    this.uiRenderKey++;
  }

  // 按"已结束"语义重建一次界面片段
  private refreshUiPartsFinal(): void {
    let content: string = this.message.content;
    this.lastUiSeen = content;
    this.uiBuildFinalized = true;
    let parts: GuncatUiParts = GuncatUiParts.build(content, true);
    let next: GuncatUiSeg[] = [];
    for (let i: number = 0; i < parts.segments.length; i++) {
      next.push(parts.segments[i]);
    }
    this.uiSegs = next;
    this.uiContentRev++;
    this.uiRenderKey++;
  }

  // 收尾自愈: 正文稳定后自己按"已结束"重建一次, 不依赖 @Watch/父组件通知(真机上不可靠,
  // 曾表现为"卡片停在骨架态, 切走再切回会话才正常")。每 250ms 采样, 连续两次一致即重建。
  private startUiSettleTimer(): void {
    if (this.uiSettleTimer !== -1) {
      return;
    }
    let waited: number = 0;
    let stableSamples: number = 0;
    let lastSample: string = this.message.content;
    this.uiSettleTimer = setInterval((): void => {
      waited += 250;
      let content: string = this.message.content;
      if (content.indexOf(GuncatUiBlocks.OPEN) < 0) {
        if (waited >= 8000) {
          this.stopUiSettleTimer();
        }
        return;
      }
      if (content !== lastSample) {
        lastSample = content;
        stableSamples = 0;
      } else {
        stableSamples++;
      }
      if (this.uiBuildFinalized && stableSamples >= 2) {
        this.stopUiSettleTimer();
        return;
      }
      if (stableSamples >= 2) {
        this.refreshUiPartsFinal();
        this.stopUiSettleTimer();
        return;
      }
      if (waited >= 8000) {
        this.refreshUiPartsFinal();
        this.stopUiSettleTimer();
      }
    }, 250);
  }

  private stopUiSettleTimer(): void {
    if (this.uiSettleTimer !== -1) {
      clearInterval(this.uiSettleTimer);
      this.uiSettleTimer = -1;
    }
  }

  aboutToAppear(): void {
    this.visibleText = this.message.content;
    this.visibleReasoning = this.message.reasoning;
    ChatBubbleView.uiInstanceSeq++;
    this.uiRenderId = ChatBubbleView.uiInstanceSeq;
    this.uiContentRev = 0;
    this.uiMountedSec = 0;
    if (this.uiMountTick === -1) {
      this.uiMountTick = setInterval((): void => {
        this.uiMountedSec++;
      }, 1000);
    }
    this.refreshUiParts();
    this.startUiSettleTimer();
    if (this.isStreaming && this.flushTimer === -1) {
      this.flushTimer = setInterval(() => {
        if (this.isStreaming) {
          const current: string = this.message.content;
          if (current !== this.visibleText) {
            this.visibleText = current;
          }
          const currentReasoning: string = this.message.reasoning;
          if (currentReasoning !== this.visibleReasoning) {
            this.visibleReasoning = currentReasoning;
          }
          // 思考跑马灯跟随最新思考内容滚到末端 (延迟一拍让 Text 先完成布局)
          if (currentReasoning !== '' && !this.reasoningExpanded) {
            setTimeout((): void => {
              this.marqueeScroller.scrollTo({
                xOffset: 999999,
                yOffset: 0,
                animation: { duration: 150, curve: Curve.EaseOut }
              });
            }, 0);
          }
          // 工具步骤状态(执行中→完成)由 VM 原地更新, 用 tick 驱动卡片重渲染
          if (this.message.toolCalls.length > 0) {
            this.stepsTick++;
          }
          // 交互界面块随流式文本渐进成形(未闭合时按中间态渲染并禁用交互)
          this.refreshUiParts();
        }
      }, 33);
    }
  }

  aboutToDisappear(): void {
    if (this.flushTimer !== -1) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
    }
    if (this.uiMountTick !== -1) {
      clearInterval(this.uiMountTick);
      this.uiMountTick = -1;
    }
    this.stopUiSettleTimer();
  }

  build() {
    if (this.message.role === 'user') {
      this.buildUserMessage();
    } else {
      this.buildAIMessage();
    }
  }

  @Builder
  buildUserMessage() {
    Column() {
      Row() {
        Blank()
        Column() {
          // 文本
          Text(this.message.displayContent !== '' ? this.message.displayContent : this.message.content)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .lineHeight(22)
            .padding({ left: 18, right: 18, top: 12, bottom: 12 })

          // 附件
          if (this.message.attachments.length > 0) {
            this.buildUserAttachments();
          }
        }
        // 显式声明 HorizontalAlign.Start, 确保附件区与文字左对齐,
        // 避免默认行为在某些场景下把子项推到边线
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.raised_surface'))
        .borderRadius({ topLeft: 22, topRight: 22, bottomLeft: 22, bottomRight: 8 })
        .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 4 })
        .constraintSize({ maxWidth: '82%' })
      }
      .width('100%')
      .padding({ left: 60, right: 16, top: 8, bottom: 8 })

      // 操作行: 填入输入框(重新编辑) + 复制原文(对齐主流 Agent 的用户消息操作)
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
        .backgroundColor($r('app.color.raised_surface'))
        .shadow({ radius: 10, color: '#10000000', offsetX: 0, offsetY: 2 })
        .onClick(() => {
          this.onEditToInput(this.message.id);
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
        .backgroundColor($r('app.color.raised_surface'))
        .shadow({ radius: 10, color: '#10000000', offsetX: 0, offsetY: 2 })
        .onClick(() => {
          this.onCopyPlain(this.message.id);
        })
      }
      .padding({ top: 2, right: 16, bottom: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
  }

  @Builder
  buildUserAttachments() {
    // 用 Column 显式包裹 + padding, 不依赖 Flex 自身 width('100%') 的隐式尺寸.
    // 附件 padding-left 与上面 Text 的 18 一致, 图片不再设 left margin.
    Column() {
      Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
        ForEach(this.message.attachments, (att: Attachment) => {
          if (att.type === 'image' && att.thumbnail !== '') {
            Image(att.thumbnail !== '' ? att.thumbnail : att.dataUrl)
              .width(72)
              .height(72)
              .objectFit(ImageFit.Cover)
              .borderRadius(14)
              .margin({ top: 8, right: 6 })
              .onClick(() => {
                this.onImageTap(att.dataUrl !== '' ? att.dataUrl : att.thumbnail);
              })
          } else {
            Row() {
              Text('FILE')
                .fontSize(9)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.brand'))
              Text(att.name)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 4 })
            }
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor($r('app.color.input_bg'))
            .borderRadius(14)
            .margin({ top: 8, right: 6 })
            .constraintSize({ maxWidth: 200 })
          }
        }, (att: Attachment) => att.name)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 18, right: 18, top: 4, bottom: 16 })
  }

  // 消息内容渲染: 把消息体切成「Markdown 文本片段 + guncat-ui 交互界面块」。
  // - 命中界面块(交互模式)时: 文本片段仍走 RichTextView, 界面块走 GuncatUiView 原生渲染,
  //   整个气泡的底色由父级 ai_msg 提供, 界面卡片自身为白色 raised 卡;
  // - 未命中时: 与旧实现完全一致(单个 RichTextView), 聊天/工作模式行为不变。
  @Builder
  buildAIContent() {
    Column({ space: 8 }) {
      ForEach(this.uiSegs, (seg: GuncatUiSeg, index: number) => {
        if (seg.type === GuncatUiSegType.UI) {
          if (seg.spec !== null) {
            GuncatUiView({
              spec: seg.spec as GuncatUiSpec,
              complete: seg.complete,
              truncated: seg.truncated,
              locked: this.uiLocked,
              rawFallback: seg.raw,
              renderId: this.uiRenderId,
              contentRev: this.uiContentRev,
              mountedSec: this.uiMountedSec,
              seenLen: this.message.content.length,
              onInteract: (payload: GuncatUiPayload): void => {
                this.onUiInteract(this.message.id, payload);
              }
            })
          } else {
            // 尚未成形: 极简骨架, 避免整块空白闪烁
            Column({ space: 8 }) {
              Row()
                .width('60%')
                .height(12)
                .borderRadius(6)
                .backgroundColor($r('app.color.surface_secondary'))
              Row()
                .width('35%')
                .height(12)
                .borderRadius(6)
                .backgroundColor($r('app.color.surface_secondary'))
            }
            .width('100%')
            .padding(14)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(18)
            .alignItems(HorizontalAlign.Start)
          }
        } else if (seg.text.trim() !== '') {
          RichTextView({ content: seg.text })
        }
      }, (seg: GuncatUiSeg, index: number) => 'seg' + index + '_' +
        (seg.type === GuncatUiSegType.UI ? 'ui' : 'tx') + '_k' + this.uiRenderKey.toString())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildAIMessage() {
    Row() {
      // 头像
      Image($r('app.media.cat_avatar'))
        .width(38)
        .height(38)
        .borderRadius(19)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.brand_light'))
        .margin({ top: 4 })

      Column() {
        // 思考条(Codex 式时间线: 思考在最前)
        if (this.isStreaming || this.message.reasoning !== '') {
          this.buildReasoningBar()
        }

        // 工具调用步骤(工作模式, CLI 式行内工具行, 单步点击展开参数与结果)
        if (this.message.toolCalls.length > 0) {
          this.buildToolSteps()
        }

        // 气泡本体
        Column() {
          // 消息内容: 普通文本片段走 Markdown, guncat-ui 块走原生交互渲染
          this.buildAIContent()

          // 流式光标
          if (this.isStreaming && this.message.content !== '') {
            Row() {
              Stack()
                .width(2)
                .height(14)
                .backgroundColor($r('app.color.brand'))
                .borderRadius(1)
            }
            .width('100%')
            .padding({ left: 12 })
            .margin({ bottom: 6 })
          }

          // 操作按钮(工作模式仅最终消息显示, 中间轮次保持时间线干净)
          if (!this.isStreaming && this.message.content !== '' &&
            (!this.isWork || this.isLastAssistant)) {
            this.buildAIActions();
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.ai_msg'))
        .borderRadius({ topLeft: 8, topRight: 22, bottomLeft: 22, bottomRight: 22 })
        .shadow({ radius: 14, color: '#12000000', offsetX: 0, offsetY: 4 })

        // 统计行(对齐工作模式 buildStatsLine): 回答结束后在气泡下方显示输出速度与缓存命中
        if (!this.isStreaming && (this.message.tokenSpeed > 0 || this.message.cacheHitRate >= 0)) {
          Row({ space: 10 }) {
            if (this.message.tokenSpeed > 0) {
              Text('⌘ ' + Math.round(this.message.tokenSpeed).toString() + ' 字符/秒')
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
            }
            if (this.message.cacheHitRate >= 0) {
              Text('缓存命中 ' + Math.round(this.message.cacheHitRate * 100).toString() + '%')
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
            }
          }
          .width('100%')
          .margin({ top: 6 })
          .padding({ left: 16, top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
      .constraintSize({ maxWidth: '80%' })

      Blank()
    }
    .width('100%')
    .padding({ left: 4, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
  }

  // 工具调用步骤(CLI 式行内样式): [图标] 工具名 · 参数摘要, 无底色块, 右端为耗时与展开箭头,
  // 点击展开参数与结果详情(左侧细竖线挂载, 同样无底色)
  @Builder
  buildToolSteps() {
    Column({ space: 2 }) {
      ForEach(this.message.toolCalls, (call: ToolCallRecord) => {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            // 状态图标位: 完成显示工具类别图标(错误时红色), 执行中转圈
            if (call.durationMs >= 0) {
              SymbolGlyph(WorkStepFormat.iconRes(call.name))
                .fontSize(13)
                .fontColor([call.isError ? $r('app.color.danger') : $r('app.color.text_secondary')])
            } else {
              LoadingProgress()
                .width(11)
                .height(11)
                .color($r('app.color.brand'))
            }
            Text(WorkStepFormat.displayName(call.name))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
            Text('·')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
            Text(WorkStepFormat.summarizeArgs(call))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (call.durationMs >= 0) {
              if (call.isError) {
                Text('失败')
                  .fontSize(10)
                  .fontColor($r('app.color.danger'))
              } else {
                Text(WorkStepFormat.formatDuration(call.durationMs))
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
              }
            }
            SymbolGlyph(this.expandedStepId === call.id ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(10)
              .fontColor([$r('app.color.text_tertiary')])
          }
          .width('100%')
          // 水平 16 边距与正文(RichTextView 内边距)对齐, 工具行宽度即正文宽度
          .padding({ left: 16, right: 16, top: 3, bottom: 3 })
          .onClick(() => {
            this.expandedStepId = this.expandedStepId === call.id ? '' : call.id;
          })

          if (this.expandedStepId === call.id) {
            // 外层定位到行内文字起点(16 边距 + 图标约 20), 细竖线挂在文字下方, 详情随正文宽度收窄
            Column() {
              Column({ space: 4 }) {
                Text('参数')
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
                Text(WorkStepFormat.capText(call.argsJson, 600))
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                Text(call.isError ? '错误' : '结果')
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
                Text(WorkStepFormat.capText(call.result === '' ? '(执行中...)' : call.result, 800))
                  .fontSize(11)
                  .fontColor(call.isError ? $r('app.color.danger') : $r('app.color.text_secondary'))
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 10, right: 0, top: 6, bottom: 6 })
              .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
            }
            .width('100%')
            .padding({ left: 36, right: 16 })
          }
        }
        .width('100%')
      }, (call: ToolCallRecord) => call.id + '#' + call.durationMs.toString() + '#' +
        call.result.length.toString() + '#' + this.stepsTick.toString())
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  // 深度思考条(CLI 式行内样式): [图标] 思考标题, 无底色卡片, 与工具行同一套观感.
  // 流式中在标题右侧显示转圈动画; 标题右侧空白区以跑马灯单行滚动最新思考内容
  // (对齐工作模式; 速度与缓存命中不再显示在此处, 回答结束后展示在气泡下方统计行).
  @Builder
  buildReasoningBar() {
    Column() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.lightbulb'))
          .fontSize(13)
          .fontColor([$r('app.color.text_secondary')])
        // 思考完成后在标题后固定缀一段"· 持续了几秒"(占位文案, 不接真实计时)
        Text((this.isWork ? '思考' : '深度思考') + (this.isStreaming ? '' : ' · 持续了几秒'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
        if (this.isStreaming) {
          LoadingProgress()
            .width(11)
            .height(11)
            .color($r('app.color.brand'))
        }
        // 思考跑马灯: 占据标签右侧空白区, 单行滚动呈现最新思考内容
        if (this.isStreaming && !this.reasoningExpanded && this.getMarqueeText() !== '') {
          Scroll(this.marqueeScroller) {
            Text(this.getMarqueeText())
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
          .align(Alignment.Start)
          .height(16)
          .layoutWeight(1)
        } else {
          Blank()
        }
        SymbolGlyph(this.reasoningExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(10)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      // 水平 16 边距与正文(RichTextView 内边距)对齐
      .padding({ left: 16, right: 16, top: 3, bottom: 3 })
      .onClick(() => {
        this.reasoningExpanded = !this.reasoningExpanded;
      })

      if (this.reasoningExpanded) {
        // 展开正文: 外层定位到标题文字起点, 细竖线挂载, 无底色
        Column() {
          Text(this.isStreaming ? this.visibleReasoning : this.message.reasoning)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(19)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 36, right: 16 })
      }
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  private getMarqueeText(): string {
    let raw: string = this.isStreaming ? this.visibleReasoning : this.message.reasoning;
    let tail: string = raw;
    if (raw.length > 400) {
      tail = '…' + raw.slice(raw.length - 400);
    }
    return tail.replace(/[\r\n\t]+/g, ' ').trim();
  }

  // 操作按钮行(28×28 图标+文字胶囊): 文本 / MD / 朗读 / Word / 重答。
  // 复制局部已改为文本选择常开(RichTextView 初始化即启用), 不再提供按钮
  // Flex 自动换行: 手机窄屏放不下时后半部分折到第二行, 宽屏仍单行排列
  @Builder
  buildAIActions() {
    Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
      Button() {
        Row({ space: 4 }) {
          Image($r('sys.media.ohos_ic_public_copy'))
            .width(14)
            .height(14)
            .fillColor($r('app.color.text_secondary'))
          Text('文本')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(28)
      .borderRadius(14)
      .padding({ left: 10, right: 10 })
      .backgroundColor($r('app.color.raised_surface'))
      .shadow({ radius: 10, color: '#10000000', offsetX: 0, offsetY: 2 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onCopyPlain(this.message.id);
      })

      // 复制 MD: 复制图标 + 大写 MD 标识
      Button() {
        Row({ space: 4 }) {
          Image($r('sys.media.ohos_ic_public_copy'))
            .width(13)
            .height(13)
            .fillColor($r('app.color.text_secondary'))
          Text('MD')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(28)
      .borderRadius(14)
      .padding({ left: 10, right: 10 })
      .backgroundColor($r('app.color.raised_surface'))
      .shadow({ radius: 10, color: '#10000000', offsetX: 0, offsetY: 2 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onCopyMarkdown(this.message.id);
      })

      // 朗读
      Button() {
        Row({ space: 4 }) {
          Image($r('sys.media.ohos_ic_public_sound'))
            .width(14)
            .height(14)
            .fillColor($r('app.color.text_secondary'))
          Text('朗读')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(28)
      .borderRadius(14)
      .padding({ left: 10, right: 10 })
      .backgroundColor($r('app.color.raised_surface'))
      .shadow({ radius: 10, color: '#10000000', offsetX: 0, offsetY: 2 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onRead(this.message.id);
      })

      // 导出 word
      Button() {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_down_to_line'))
            .fontSize(14)
            .fontColor([$r('app.color.text_secondary')])
          Text('Word')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(28)
      .borderRadius(14)
      .padding({ left: 10, right: 10 })
      .backgroundColor($r('app.color.raised_surface'))
      .shadow({ radius: 10, color: '#10000000', offsetX: 0, offsetY: 2 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onExportWord(this.message.id);
      })

      // 重新回答(重答)
      Button() {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
            .fontSize(14)
            .fontColor([$r('app.color.text_secondary')])
          Text('重答')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(28)
      .borderRadius(14)
      .padding({ left: 10, right: 10 })
      .backgroundColor($r('app.color.raised_surface'))
      .shadow({ radius: 10, color: '#10000000', offsetX: 0, offsetY: 2 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onRegenerate(this.message.id);
      })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 2 })
  }
}
