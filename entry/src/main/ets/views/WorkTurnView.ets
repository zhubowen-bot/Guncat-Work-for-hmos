// WorkTurnView: 工作模式时间线中的单轮渲染(思考 → 正文 → 工具步骤)
// 6.1 起视觉对齐 DeepSeek Harness web UI:
//  - 工具行采用 dsh 24px 单行规格: [16 图标] · [标题 13/24] · [2x2 分隔点] · [摘要省略] · 状态/耗时
//  - 执行中的工具行带"流光扫过"动效(dsh ToolRow running sweep)
//  - 展开详情为 IO 卡片(radius 12 + 代码底色 + IN/OUT 槽位标签)
//  - edit/str_replace_editor 的 meta 渲染为 dsh DiffBlock 风格卡片(+增 -删)
//  - todo_write 渲染为任务清单, 最终回复下附统计行(tok/s / 缓存命中 / 工具数)
import { Message } from '../model/Message';
import { ToolCallRecord } from '../model/ToolCallRecord';
import { RichTextView } from './RichTextView';
import { WorkStepFormat } from './ChatBubbleView';
import { FileDiff } from '../common/DiffUtil';
import { GuncatUiView } from './GuncatUiView';
import { GuncatUiParts, GuncatUiSeg, GuncatUiSegType } from '../common/GuncatUiParts';
import { GuncatUiEvent } from '../common/GuncatUiRuntime';
import { Constants } from '../common/Constants';

// diff 卡片行模型
class DiffRow {
  type: string = 'same';
  text: string = '';
}

@Component
export struct WorkTurnView {
  @ObjectLink message: Message;
  @Prop @Watch('onStreamChanged') isStreaming: boolean = false;
  @Prop isLastAssistant: boolean = false;
  // 本轮是否会产出思考内容: 交互模式选「关闭」思考时为 false,
  // 用于避免流式期间挂一条永远不填内容的"思考中"条
  @Prop thinkingExpected: boolean = true;
  // 渲染段: 'full'(工作模式, 思考条 + 正文 + 工具行) / 'grouped'(交互模式本回合最后一轮:
  // 聚合活动折叠栏 + 正文) / 'content'(交互模式本回合的历史轮: 只出正文, 不出活动)
  @Prop section: string = 'full';
  // 'grouped' 时: 本回合中位于本条之前的若干轮消息 —— 它们的思考与工具调用要一并收进折叠栏。
  // 这些轮次已经跑完(冻结), 所以按值传进来即可, 不需要被观察。
  @Prop priorMessages: Message[] = [];
  // 用户是否手动开合过活动栏; 没动过时按"是否还在跑"自动决定开合
  @State private activityTouched: boolean = false;
  @State private activityOpen: boolean = false;
  private onCopyPlain: (id: string) => void = (_id: string): void => {};
  private onCopyMarkdown: (id: string) => void = (_id: string): void => {};
  private onExportWord: (id: string) => void = (_id: string): void => {};
  private onRegenerate: (id: string) => void = (_id: string): void => {};
  @State private reasoningExpanded: boolean = false;
  @State private expandedStepId: string = '';
  @State private stepsTick: number = 0;
  @State private visibleText: string = '';
  @State private visibleReasoning: string = '';
  // 交互模式: 本轮正文里内嵌的 guncat-ui 界面块(工作模式下恒为空)。
  // 与 ChatBubbleView 同理: 必须用数组型 @State + 整数组重赋值才能被 ArkUI 观察到,
  // 否则流式结束后界面卡片不会刷新(切走再切回会话才正常)。勿改回类实例字段。
  @State private uiSegs: GuncatUiSeg[] = [];
  // 该轮界面是否已回传(仅最新一轮可交互)
  @Prop uiLocked: boolean = false;
  private onUiInteract: (messageId: string, ev: GuncatUiEvent) => void =
    (_messageId: string, _ev: GuncatUiEvent): void => {};
  // 上一次工具行状态签名(数量/参数量/执行态): 变化才递增 stepsTick 触发行重建,
  // 避免流式期间每 33ms 无条件重建导致 LoadingProgress 动画永远停在第一帧(观感即"卡住")
  private lastCallsSig: string = '';
  private flushTimer: number = -1;
  // 收尾自愈状态: uiBuildFinalized 记录当前 uiSegs 是否按"已结束"语义构建
  private uiSettleTimer: number = -1;
  private uiBuildFinalized: boolean = false;
  private lastUiSeen: string = '';
  private lastUiFinalized: boolean = false;
  // 界面片段的渲染 key 版本: 变化即让 ForEach key 变化, 强制重建子组件
  @State private uiRenderKey: number = 0;
  // 文本片段的历史 renderKey(按下标记账): 文案变化时递增, 迫使尾部 RichTextView 重建
  private textKeySeq: Map<number, number> = new Map<number, number>();
  // 思考跑马灯: 流式中在思考条右侧空白区滚动呈现最新思考内容
  private marqueeScroller: Scroller = new Scroller();

  onStreamChanged(): void {
    if (!this.isStreaming && this.flushTimer !== -1) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
      this.visibleText = this.message.content;
      this.visibleReasoning = this.message.reasoning;
      this.stepsTick++;
      this.refreshUiParts();
    }
  }

  // 正文切分(文本片段 + 界面程序片段)。
  // 注意: 这里**不能**再用"正文里有没有 guncat-ui 围栏"当开关 —— 交互模式的主形态是
  // 非围栏的整段界面程序, 而且普通回答也必须照样走文本片段渲染。
  // finalized = 本轮产出已结束(不再流式): 未写完的界面据此从"生成中"转为"未完成"静态展示。
  private refreshUiParts(): void {
    let content: string = this.isStreaming ? this.visibleText : this.message.content;
    if (content === this.lastUiSeen && this.lastUiFinalized === !this.isStreaming) {
      return;
    }
    this.lastUiSeen = content;
    this.lastUiFinalized = !this.isStreaming;
    this.uiBuildFinalized = this.lastUiFinalized;
    let parts: GuncatUiParts = GuncatUiParts.build(content, this.lastUiFinalized);
    let next: GuncatUiSeg[] = [];
    for (let i: number = 0; i < parts.segments.length; i++) {
      next.push(parts.segments[i]);
    }
    this.applyUiSegs(next);
  }

  // 按"已结束"语义重建一次正文片段
  private refreshUiPartsFinal(): void {
    let content: string = this.message.content;
    this.lastUiSeen = content;
    this.lastUiFinalized = true;
    this.uiBuildFinalized = true;
    let parts: GuncatUiParts = GuncatUiParts.build(content, true);
    let next: GuncatUiSeg[] = [];
    for (let i: number = 0; i < parts.segments.length; i++) {
      next.push(parts.segments[i]);
    }
    this.applyUiSegs(next);
  }

  // 应用新的片段数组。
  // 两条关键的刷新规则(真机教训):
  //  1) 文本片段的内容变化时要递增其 renderKey —— 否则卡片后面的正文只显示一两个字,
  //     刷新后才完整(渲染库复用了同一实例, 没有按新内容重新排版);
  //  2) 界面片段的渲染 key 只在语义变化时递增 —— 否则流式期间每 33ms 销毁重建整张卡片, 疯狂闪烁。
  private applyUiSegs(next: GuncatUiSeg[]): void {
    let oldShape: string = this.uiSegsShape();
    // 按片段下标记账: 每次 build 都会产出全新的 GuncatUiSeg 对象, 不能用对象字段当历史
    for (let i: number = 0; i < next.length; i++) {
      let seg: GuncatUiSeg = next[i];
      if (seg.type === GuncatUiSegType.UI) {
        continue;
      }
      let previous: number = this.textKeySeq.get(i) !== undefined ? this.textKeySeq.get(i) as number : 0;
      let wasSame: boolean = i < this.uiSegs.length && this.uiSegs[i].text === seg.text;
      if (wasSame && previous > 0) {
        seg.renderKey = previous;
      } else {
        seg.renderKey = previous + 1;
      }
      this.textKeySeq.set(i, seg.renderKey);
    }
    this.uiSegs = next;
    let newShape: string = this.uiSegsShape();
    if (oldShape !== newShape) {
      this.uiRenderKey++;
    }
  }

  // 片段数组的"语义指纹": 每段类型 + 是否闭合 + 是否未完成
  private uiSegsShape(): string {
    let shape: string = '';
    for (let i: number = 0; i < this.uiSegs.length; i++) {
      let seg: GuncatUiSeg = this.uiSegs[i];
      if (seg.type !== GuncatUiSegType.UI) {
        shape = shape + 't';
        continue;
      }
      shape = shape + 'u' + (seg.complete ? 'C' : 'c') + (seg.truncated ? 'T' : 'n');
    }
    return shape;
  }

  // 收尾自愈: 一旦正文不再变化(本轮产出结束)且界面块还是按"流式中"构建的,
  // 就地按 finalized 重建一次。不依赖 @Watch/父组件通知——真机上那些回调不可靠,
  // 曾表现为"卡片停在骨架态, 切走再切回会话才正常"。
  // 每 250ms 检查一次: 内容还在变就继续等, 连续两次采样一致即视为稳定, 立刻重建并停止。
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
      if (!GuncatUiParts.hasProgram(content)) {
        // 正文里没有界面程序: 无需自愈, 或等超时后收工
        if (waited >= 8000) {
          this.stopUiSettleTimer();
        }
        return;
      }
      if (content !== lastSample) {
        // 内容仍在增长(仍在流式/工具轮仍在追加)
        lastSample = content;
        stableSamples = 0;
      } else {
        stableSamples++;
      }
      // 已经按"结束态"构建过且内容稳定 → 无需再动
      if (this.uiBuildFinalized && stableSamples >= 2) {
        this.stopUiSettleTimer();
        return;
      }
      // 内容稳定且尚未按结束态构建 → 就地重建
      if (stableSamples >= 2) {
        this.refreshUiPartsFinal();
        this.stopUiSettleTimer();
        return;
      }
      if (waited >= 8000) {
        // 超时保护: 无论如何按结束态构建一次, 避免永久骨架
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
    this.refreshUiParts();
    // 无论父组件是否通知"流式结束", 组件自己兜底完成收尾重建
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
          // 跑马灯跟随最新思考内容滚到末端 (延迟一拍让 Text 先完成布局)
          if (currentReasoning !== '' && !this.reasoningExpanded) {
            setTimeout((): void => {
              this.marqueeScroller.scrollTo({
                xOffset: 999999,
                yOffset: 0,
                animation: { duration: 150, curve: Curve.EaseOut }
              });
            }, 0);
          }
          // 工具行状态签名变化时才重建行(转圈动画得以连续播放)
          const sig: string = this.callsSignature();
          if (sig !== this.lastCallsSig) {
            this.lastCallsSig = sig;
            this.stepsTick++;
          }
          // 交互界面块随流式文本渐进成形
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
    this.stopUiSettleTimer();
  }

  // 工具行状态签名: 调用数 + 每个调用的参数量/准备态/启动态/耗时/结果量, 任一变化才触发行重建
  private callsSignature(): string {
    let calls: ToolCallRecord[] = this.message.toolCalls;
    let parts: string[] = [calls.length.toString()];
    for (let i: number = 0; i < calls.length; i++) {
      parts.push(calls[i].argsJson.length.toString() + ':' +
        (calls[i].preparing ? 'p' : 'r') + ':' +
        (calls[i].started ? 's' : '-') + ':' +
        calls[i].durationMs.toString() + ':' +
        calls[i].result.length.toString());
    }
    return parts.join('|');
  }

  // 进行中工具行的状态文案:
  //  - started=true → 已真正开始执行, 显示“执行中…”（无论它在模型调用顺序里排第几）
  //  - 否则 preparing=true → 模型还在生成调用参数
  //  - 否则 → 已生成完但还没轮到(排队等待)
  private stepStatusLabel(call: ToolCallRecord): string {
    if (call.started) {
      return '执行中…';
    }
    return call.preparing ? '生成调用中…' : '等待中…';
  }

  // 正文渲染: 文本片段走 Markdown; 界面程序片段走原生交互渲染。
  // 界面片段的 key **不含程序文本**: 流式期间每来一段新文本只更新 @Prop, 由 GuncatUiView
  // 自己重新解析并重绘; 若把文本放进 key, 每 33ms 就会销毁重建整块界面(闪烁 + 掉交互状态)。
  @Builder
  buildTurnContent() {
    if (this.uiSegs.length === 0) {
      RichTextView({
        content: this.isStreaming ? this.visibleText : this.message.content,
        selectionTrigger: 0
      })
    } else {
      Column({ space: 8 }) {
        ForEach(this.uiSegs, (seg: GuncatUiSeg, index: number) => {
          if (seg.type === GuncatUiSegType.UI) {
            GuncatUiView({
              programText: seg.raw,
              complete: seg.complete,
              truncated: seg.truncated,
              locked: this.uiLocked,
              stateJson: seg.stateJson,
              title: seg.title,
              onInteract: (ev: GuncatUiEvent): void => {
                this.onUiInteract(this.message.id, ev);
              }
            })
          } else if (seg.text.trim() !== '') {
            RichTextView({ content: seg.text, selectionTrigger: 0 })
          }
        }, (seg: GuncatUiSeg, index: number) => 'tseg' + index + '_' +
          (seg.type === GuncatUiSegType.UI ? 'ui' : 'tx' + seg.renderKey.toString()) +
          '_k' + this.uiRenderKey.toString())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  build() {
    Column({ space: 8 }) {
      // 活动区(思考 + 工具调用)。
      //   full    = 工作模式: 思考条在上, 工具行在正文之后(各自独立开合)
      //   grouped = 交互模式本回合最后一轮: 思考与整个回合的工具**合并成一个**折叠栏
      //   content = 交互模式本回合的历史轮: 不出活动(已收进折叠栏), 只出正文
      if (this.section === 'full') {
        // thinkingExpected: 交互模式选「关闭」思考时为 false。
        // 之前只看 isStreaming, 关掉思考后仍会挂一条永远不填内容的"思考中"条, 看起来像卡住。
        if (this.message.reasoning !== '' ||
          (this.isStreaming && this.thinkingExpected)) {
          this.buildThinking()
        }
      } else if (this.section === 'grouped') {
        if (this.hasActivity()) {
          this.buildActivityGroup()
        }
      }
      // 正文: 本轮叙述/结论, 按发生时序渲染在工具行之前
      if (this.isStreaming || this.message.content !== '') {
        Column() {
          this.buildTurnContent()
          // 流式光标: 仅在模型仍在输出文本(尚无工具调用)时显示;
          // 工具执行阶段正文已停, 挂着光标反而像多出一个空行
          if (this.isStreaming && this.message.content !== '' &&
            this.message.toolCalls.length === 0) {
            Row() {
              Stack()
                .width(2)
                .height(14)
                .backgroundColor($r('app.color.brand'))
                .borderRadius(1)
            }
            .width('100%')
            .padding({ left: 12 })
            .margin({ top: 4 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      // 工具步骤(dsh 式行内工具行, 点击展开 IO 卡片/diff 卡片)。
      // grouped 模式下工具行已经进了活动栏(位于正文之前), 这里不再重复渲染。
      if (this.section === 'full' && this.message.toolCalls.length > 0) {
        this.buildSteps()
      }
      // 统计行(dsh StatsLine): 仅最终回复且数据可用时展示
      if (!this.isStreaming && this.isLastAssistant && this.hasStats()) {
        this.buildStatsLine()
      }
      // 操作按钮(仅最终回复, 置于轮次末尾): 与聊天模式同款 图标+文字 胶囊钮
      // Flex 自动换行: 手机窄屏放不下时折到第二行, 宽屏仍单行排列
      if (!this.isStreaming && this.message.content !== '' && this.isLastAssistant) {
        Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
          // 复制(纯文本)
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

          // 重新执行(重答)
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
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private hasStats(): boolean {
    return this.message.toolCalls.length > 0 || this.message.tokenSpeed > 0 ||
      this.message.cacheHitRate >= 0;
  }

  @Builder
  private buildStatsLine() {
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
      if (this.message.toolCalls.length > 0) {
        Text('工具 ' + this.message.toolCalls.length.toString() + ' 项 · ' +
          WorkStepFormat.formatDuration(this.toolTotalMs()))
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .padding({ left: 16, top: 2 })
  }

  private toolTotalMs(): number {
    let totalMs: number = 0;
    for (let i: number = 0; i < this.message.toolCalls.length; i++) {
      let d: number = this.message.toolCalls[i].durationMs;
      if (d > 0) {
        totalMs += d;
      }
    }
    return totalMs;
  }

  // ===== 交互模式: 活动折叠栏(整个回合的思考 + 工具调用) =====
  //
  // 一轮一条 assistant 消息是 Agent Loop 的既定结构(assistant 与其工具结果必须同进同出,
  // 否则压缩/裁剪会拆散协议对), 所以**不动数据**, 只在渲染层合并:
  //   本回合**最后一条**消息渲染这个折叠栏, 前面几轮的思考与工具作为"历史活动"一并收进来。
  //
  // 其它要点:
  //   1. 开合状态是**纯派生**的(activityOpenNow), 不在 build 里改 @State ——
  //      ArkUI 构建期改状态会触发重渲染告警/抖动, 而这里每次 message.content 变化
  //      (ObjectLink 会触发重渲染)都会自然重算, 正文一出现就自动收起;
  //   2. 用户点过之后(activityTouched)完全听用户的, 不再自动开合;
  //   3. 只有"还在跑"的时候默认展开, 跑完(含没有正文的轮次)一律收成一条已完成栏。
  private priorReasoningRounds(): number {
    let n: number = 0;
    for (let i: number = 0; i < this.priorMessages.length; i++) {
      if (this.priorMessages[i].reasoning !== '') {
        n++;
      }
    }
    return n;
  }

  private priorToolCount(): number {
    let n: number = 0;
    for (let i: number = 0; i < this.priorMessages.length; i++) {
      n += this.priorMessages[i].toolCalls.length;
    }
    return n;
  }

  private priorToolMs(): number {
    let totalMs: number = 0;
    for (let i: number = 0; i < this.priorMessages.length; i++) {
      let calls: ToolCallRecord[] = this.priorMessages[i].toolCalls;
      for (let k: number = 0; k < calls.length; k++) {
        if (calls[k].durationMs > 0) {
          totalMs += calls[k].durationMs;
        }
      }
    }
    return totalMs;
  }

  // 本回合是否出现过活动(含前面几轮)
  private hasActivity(): boolean {
    return this.priorMessages.length > 0 || this.message.toolCalls.length > 0 ||
      this.message.reasoning !== '' || (this.isStreaming && this.thinkingExpected);
  }

  private activityOpenNow(): boolean {
    if (this.activityTouched) {
      return this.activityOpen;
    }
    // 需求: 正文开始输出后默认收起。正文之前保持展开, 让用户实时看到在思考/调什么工具。
    // 刻意**不**因为"又有新工具在跑"而自动重新展开 —— 那会在多轮之间来回开合, 很晃眼;
    // 那种情况下由 activityRunning() 把标题改成"正在处理…", 不会误导。
    return this.isStreaming && this.message.content === '';
  }

  // 是否还有活在做: 流式中且(正文还没出现 或 还有工具在跑)。
  // 用于标题与转圈图标 —— 保证"已完成"只在真的做完时才出现。
  // 前面几轮已经跑完, 只看本轮即可。
  private activityRunning(): boolean {
    if (!this.isStreaming) {
      return false;
    }
    if (this.message.content === '') {
      return true;
    }
    for (let i: number = 0; i < this.message.toolCalls.length; i++) {
      let call: ToolCallRecord = this.message.toolCalls[i];
      if (call.durationMs < 0 && (this.isStreaming || call.preparing || call.started)) {
        return true;
      }
    }
    return false;
  }

  private activityTitle(): string {
    if (this.activityRunning()) {
      return '正在处理…';
    }
    return this.isStopped() ? '已停止' : '已完成';
  }

  // 被手动停止的轮次: finalizeWorkTurn 会往正文末尾追加这句标注。
  // 折叠栏据此把"已完成"改成"已停止", 避免明明被打断却写着完成。
  private isStopped(): boolean {
    return this.message.content.indexOf(Constants.WORK_STOPPED_NOTE) >= 0;
  }

  // 折叠态摘要, 覆盖整个回合: "思考 ×4 · 5 个工具 · 12.4s"
  private activitySummary(): string {
    let thinkingRounds: number = this.priorReasoningRounds() +
      (this.message.reasoning !== '' ? 1 : 0);
    let tools: number = this.priorToolCount() + this.message.toolCalls.length;
    let parts: string[] = [];
    if (thinkingRounds > 0) {
      parts.push(thinkingRounds > 1 ? '思考 ×' + thinkingRounds.toString() : '思考');
    }
    if (tools > 0) {
      parts.push(tools.toString() + ' 个工具');
    }
    let text: string = parts.join(' + ');
    let ms: number = this.priorToolMs() + this.toolTotalMs();
    if (ms > 0) {
      text = text === '' ? WorkStepFormat.formatDuration(ms)
        : text + ' · ' + WorkStepFormat.formatDuration(ms);
    }
    return text;
  }

  @Builder
  private buildActivityGroup() {
    Column({ space: 6 }) {
      // 折叠头(整行可点): 跑动中转圈 + "正在处理…", 完成后对勾 + "已完成" + 摘要
      Row({ space: 6 }) {
        if (this.activityRunning()) {
          LoadingProgress()
            .width(12)
            .height(12)
            .color($r('app.color.brand'))
            .flexShrink(0)
        } else {
          Text('✓')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            // 被停止的轮次: 对勾保留但转成弱色, 表示"结束了"而不是"成功完成了"
            .fontColor(this.isStopped() ? $r('app.color.text_tertiary') : $r('app.color.brand'))
            .width(12)
            .textAlign(TextAlign.Center)
            .flexShrink(0)
        }
        Text(this.activityTitle())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .flexShrink(0)
        if (this.activitySummary() !== '') {
          Text(this.activitySummary())
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          Blank()
        }
        SymbolGlyph(this.activityOpenNow() ? $r('sys.symbol.chevron_up')
          : $r('sys.symbol.chevron_down'))
          .fontSize(11)
          .fontColor([$r('app.color.text_tertiary')])
          .flexShrink(0)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(12)
      .backgroundColor($r('app.color.raised_surface'))
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        // 先按当前**派生**状态取反, 再标记"用户已接管"
        this.activityOpen = !this.activityOpenNow();
        this.activityTouched = true;
      })

      // 展开体: 历史轮的思考与工具(只读摘要) + 本轮思考(跑动中显示最新一句跑马灯,
      // 结束后显示完整思考) + 本轮工具行(带 IO/diff 卡片)
      if (this.activityOpenNow()) {
        Column({ space: 6 }) {
          if (this.priorMessages.length > 0) {
            this.buildPriorActivity()
          }
          if (this.message.reasoning !== '' || (this.isStreaming && this.thinkingExpected)) {
            this.buildActivityThinking()
          }
          if (this.message.toolCalls.length > 0) {
            this.buildSteps()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
  }

  // 历史轮的活动(只读摘要): 思考文字 + 工具行。
  // 这些轮次已经跑完, 按值传进来即可; 这里不做 IO/diff 展开 —— ArkUI 不允许组件递归
  // (WorkTurnView 里没法再套 WorkTurnView 去复用完整工具行), 反复制一份完整实现不值当,
  // 摘要已经能回答"当时在做什么"。
  @Builder
  private buildPriorActivity() {
    Column({ space: 6 }) {
      ForEach(this.priorMessages, (m: Message, i: number) => {
        Column({ space: 4 }) {
          if (m.reasoning !== '') {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.lightbulb'))
                .fontSize(12)
                .fontColor([$r('app.color.text_tertiary')])
                .flexShrink(0)
              Text('思考')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .flexShrink(0)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            Text(m.reasoning)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(19)
              .width('100%')
          }
          ForEach(m.toolCalls, (call: ToolCallRecord, k: number) => {
            Row({ space: 6 }) {
              SymbolGlyph(WorkStepFormat.iconRes(call.name))
                .fontSize(13)
                .fontColor([call.isError ? $r('app.color.danger') : $r('app.color.text_tertiary')])
                .flexShrink(0)
              Text(WorkStepFormat.displayName(call.name))
                .fontSize(12)
                .fontColor(call.isError ? $r('app.color.danger') : $r('app.color.text_secondary'))
                .flexShrink(0)
              if (call.durationMs > 0) {
                Text(WorkStepFormat.formatDuration(call.durationMs))
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .flexShrink(0)
              }
              Blank()
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }, (call: ToolCallRecord, k: number) => 'pt' + i.toString() + '_' + k.toString() + call.id)
        }
        .width('100%')
        .padding({ left: 12, right: 2 })
        .alignItems(HorizontalAlign.Start)
      }, (m: Message, i: number) => 'pm' + m.id)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildActivityThinking() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.lightbulb'))
          .fontSize(12)
          .fontColor([$r('app.color.text_tertiary')])
          .flexShrink(0)
        Text('思考')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .flexShrink(0)
        if (this.isStreaming && this.getMarqueeText() !== '') {
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
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (!this.isStreaming && this.message.reasoning !== '') {
        Text(this.message.reasoning)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(19)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 2 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildThinking() {    Column() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.lightbulb'))
          .fontSize(13)
          .fontColor([$r('app.color.text_secondary')])
        Text(this.isStreaming ? '思考中...' : '思考 · 持续了几秒')
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
      .padding({ left: 16, right: 16, top: 3, bottom: 3 })
      .onClick(() => {
        this.reasoningExpanded = !this.reasoningExpanded;
      })

      if (this.reasoningExpanded) {
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
  }

  private getMarqueeText(): string {
    let raw: string = this.isStreaming ? this.visibleReasoning : this.message.reasoning;
    let tail: string = raw;
    if (raw.length > 400) {
      tail = '…' + raw.slice(raw.length - 400);
    }
    return tail.replace(/[\r\n\t]+/g, ' ').trim();
  }

  // 工具步骤(dsh ToolRow 规格): [图标] 标题 · 摘要(省略) [状态/耗时] [箭头]
  // 执行中带流光扫过; 点击展开 IO 卡片 / diff 卡片 / 任务清单
  @Builder
  private buildSteps() {
    Column({ space: 2 }) {
      ForEach(this.message.toolCalls, (call: ToolCallRecord) => {
        Column({ space: 2 }) {
          Stack({ alignContent: Alignment.Start }) {
            Row({ space: 6 }) {
              // 状态图标位: 完成显示工具类别图标(错误红色), 执行中转圈, 被打断则图标置灰
              if (call.durationMs >= 0) {
                SymbolGlyph(WorkStepFormat.iconRes(call.name))
                  .fontSize(14)
                  .fontColor([call.isError ? $r('app.color.danger') : $r('app.color.text_secondary')])
              } else if (this.isStreaming || call.preparing || call.started) {
                LoadingProgress()
                  .width(12)
                  .height(12)
                  .color($r('app.color.brand'))
              } else {
                SymbolGlyph(WorkStepFormat.iconRes(call.name))
                  .fontSize(14)
                  .fontColor([$r('app.color.text_tertiary')])
              }
              Text(WorkStepFormat.displayName(call.name))
                .fontSize(13)
                .fontWeight(FontWeight.Normal)
                .fontColor(call.isError && call.durationMs >= 0 ?
                  $r('app.color.danger') : $r('app.color.text_primary'))
              // 2x2 分隔点(dsh sep)
              Stack()
                .width(2)
                .height(2)
                .borderRadius(1)
                .backgroundColor($r('app.color.text_quaternary'))
              Text(call.isError && call.durationMs >= 0 ?
                this.firstLineOf(call.result) : WorkStepFormat.summarizeArgs(call))
                .fontSize(12)
                .fontColor(call.isError && call.durationMs >= 0 ?
                  $r('app.color.danger') : $r('app.color.text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (call.durationMs < 0 && (this.isStreaming || call.preparing || call.started)) {
                Text(this.stepStatusLabel(call))
                  .fontSize(10)
                  .fontColor($r('app.color.brand'))
              } else if (call.durationMs < 0) {
                Text('已中断')
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
              } else if (call.isError) {
                Text('失败')
                  .fontSize(10)
                  .fontColor($r('app.color.danger'))
              } else {
                Text(WorkStepFormat.formatDuration(call.durationMs))
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
              }
              SymbolGlyph(this.expandedStepId === call.id ?
                $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                .fontSize(10)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 3, bottom: 3 })
            .onClick(() => {
              this.expandedStepId = this.expandedStepId === call.id ? '' : call.id;
            })
          }
          .width('100%')
          .borderRadius(6)

          if (this.expandedStepId === call.id) {
            Column() {
              // todo_write → 任务清单; edit/str_replace_editor → diff 卡片; 其余 → IO 卡片
              if (call.name === 'todo_write' && !call.isError && call.result !== '') {
                this.buildTodoChecklist(call)
              } else if (this.parseDiff(call) !== null) {
                this.buildDiffCard(this.parseDiff(call) as FileDiff, call)
              } else {
                this.buildIoCard(call)
              }
            }
            .width('100%')
            .padding({ left: 36, right: 16 })
            .margin({ top: 2 })
          }
        }
        .width('100%')
      }, (call: ToolCallRecord) => call.id + '#' + call.durationMs.toString() + '#' +
        call.result.length.toString() + '#' + this.stepsTick.toString())
    }
    .width('100%')
  }

  private firstLineOf(text: string): string {
    let line: string = text.split('\n')[0];
    return line.length > 80 ? line.substring(0, 80) + '…' : line;
  }

  // 解析 edit 工具的 diff meta(损坏/缺失返回 null, 回退 IO 卡片)
  private parseDiff(call: ToolCallRecord): FileDiff | null {
    if (call.meta === '') {
      return null;
    }
    try {
      let parsed: Object = JSON.parse(call.meta);
      if (typeof parsed === 'object' && parsed !== null) {
        return FileDiff.fromJson(parsed as Record<string, Object>);
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  // dsh DiffBlock 卡片: 代码底色 + radius 12, - 删除 / + 新增, 底部统计
  @Builder
  private buildDiffCard(diff: FileDiff, call: ToolCallRecord) {
    Column() {
      Column() {
        Text(call.isError ? 'ERROR' : diff.path)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(call.isError ? $r('app.color.danger') : $r('app.color.text_primary'))
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 4 })
        Scroll() {
          Column({ space: 1 }) {
            ForEach(this.diffRows(diff), (row: DiffRow) => {
              Text((row.type === 'add' ? '+ ' : row.type === 'del' ? '- ' : '  ') + row.text)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor(row.type === 'add' ? $r('app.color.diff_add') :
                  row.type === 'del' ? $r('app.color.diff_del') : $r('app.color.text_tertiary'))
                .width('100%')
            }, (row: DiffRow, idx: number) => idx.toString() + row.type + row.text)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 10 })
        }
        .constraintSize({ maxHeight: 220 })
        .scrollBar(BarState.Auto)
      }
      .backgroundColor($r('app.color.code_bg'))
      .borderRadius(12)
      .border({ width: 1, color: $r('app.color.divider') })
      .width('100%')

      Text('└ +' + diff.adds.toString() + ' -' + diff.dels.toString() +
        (diff.truncated ? ' · 已折叠' : ''))
        .fontSize(10)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_tertiary'))
        .padding({ left: 4, top: 4 })
        .width('100%')
    }
    .width('100%')
  }

  private diffRows(diff: FileDiff): DiffRow[] {
    let rows: DiffRow[] = [];
    for (let i: number = 0; i < diff.hunks.length; i++) {
      let lines = diff.hunks[i].lines;
      for (let j: number = 0; j < lines.length; j++) {
        let row: DiffRow = new DiffRow();
        row.type = lines[j].type;
        row.text = lines[j].text;
        rows.push(row);
      }
    }
    return rows;
  }

  // todo_write 结果 → 任务清单
  @Builder
  private buildTodoChecklist(call: ToolCallRecord) {
    Column() {
      ForEach(this.todoRows(call.result), (item: TodoRow) => {
        Row({ space: 8 }) {
          SymbolGlyph(item.status === 'completed' ?
            $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
            .fontSize(14)
            .fontColor([item.status === 'completed' ? $r('app.color.success') :
              item.status === 'in_progress' ? $r('app.color.brand') : $r('app.color.text_tertiary')])
          Text(item.content)
            .fontSize(12)
            .fontColor(item.status === 'completed' ? $r('app.color.text_tertiary') :
              $r('app.color.text_primary'))
            .decoration({
              type: item.status === 'completed' ? TextDecorationType.LineThrough : TextDecorationType.None
            })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 3, bottom: 3 })
      }, (item: TodoRow) => item.idx.toString() + item.content)
    }
    .width('100%')
    .padding(10)
    .borderRadius(12)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  private todoRows(result: string): TodoRow[] {
    let rows: TodoRow[] = [];
    let lines: string[] = result.split('\n');
    let idx: number = 0;
    for (let i: number = 0; i < lines.length; i++) {
      let line: string = lines[i].trim();
      let status: string = '';
      let content: string = '';
      if (line.indexOf('[已完成]') === 0) {
        status = 'completed';
        content = line.substring(5).trim();
      } else if (line.indexOf('[进行中]') === 0) {
        status = 'in_progress';
        content = line.substring(5).trim();
      } else if (line.indexOf('[待开始]') === 0) {
        status = 'pending';
        content = line.substring(5).trim();
      } else if (line.indexOf('[x]') === 0 || line.indexOf('[X]') === 0) {
        status = 'completed';
        content = line.substring(3).trim();
      } else if (line.indexOf('[~]') === 0) {
        status = 'in_progress';
        content = line.substring(3).trim();
      } else if (line.indexOf('[ ]') === 0) {
        status = 'pending';
        content = line.substring(3).trim();
      }
      if (status !== '' && content !== '') {
        // 去掉清单序号前缀("1. ")
        let dot: number = content.indexOf('. ');
        if (dot > 0 && dot <= 3) {
          let numPart: string = content.substring(0, dot);
          if (!isNaN(parseInt(numPart, 10))) {
            content = content.substring(dot + 2);
          }
        }
        let row: TodoRow = new TodoRow();
        row.idx = idx++;
        row.status = status;
        row.content = content;
        rows.push(row);
      }
    }
    return rows;
  }

  // 通用 IO 卡片(dsh ioCard): 代码底色 radius 12, IN/OUT 槽位标签
  // 长内容在各自槽位内滚动(dsh ioSection 同款), 绝不溢出卡片外覆盖其他内容
  @Builder
  private buildIoCard(call: ToolCallRecord) {
    Column() {
      Column() {
        Row() {
          Text('IN')
            .fontSize(9)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_tertiary'))
            .width(28)
          Scroll() {
            Text(WorkStepFormat.capText(call.argsJson, 600))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .constraintSize({ maxHeight: 120 })
          .scrollBar(BarState.Off)
        }
        .alignItems(VerticalAlign.Top)
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })

        Divider()
          .strokeWidth(1)
          .color($r('app.color.divider'))

        Row() {
          Text(call.isError ? 'ERR' : 'OUT')
            .fontSize(9)
            .fontFamily('monospace')
            .fontColor(call.isError ? $r('app.color.danger') : $r('app.color.text_tertiary'))
            .width(28)
          Scroll() {
            Text(call.result === '' ? '(执行中...)' : WorkStepFormat.capText(call.result, 1200))
              .fontSize(11)
              .fontColor(call.isError ? $r('app.color.danger') : $r('app.color.text_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .constraintSize({ maxHeight: 150 })
          .scrollBar(BarState.Off)
        }
        .alignItems(VerticalAlign.Top)
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      }
      .backgroundColor($r('app.color.code_bg'))
      .borderRadius(12)
      .border({ width: 1, color: $r('app.color.divider') })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .clip(true)
    }
    .width('100%')
  }

}

// 任务清单行模型
class TodoRow {
  idx: number = 0;
  status: string = 'pending';
  content: string = '';
}
