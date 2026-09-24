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
  private onCopyPlain: (id: string) => void = (_id: string): void => {};
  private onCopyMarkdown: (id: string) => void = (_id: string): void => {};
  private onExportWord: (id: string) => void = (_id: string): void => {};
  private onRegenerate: (id: string) => void = (_id: string): void => {};
  @State private reasoningExpanded: boolean = false;
  @State private expandedStepId: string = '';
  @State private stepsTick: number = 0;
  @State private visibleText: string = '';
  @State private visibleReasoning: string = '';
  // 上一次工具行状态签名(数量/参数量/执行态): 变化才递增 stepsTick 触发行重建,
  // 避免流式期间每 33ms 无条件重建导致 LoadingProgress 动画永远停在第一帧(观感即"卡住")
  private lastCallsSig: string = '';
  private flushTimer: number = -1;
  // 思考跑马灯: 流式中在思考条右侧空白区滚动呈现最新思考内容
  private marqueeScroller: Scroller = new Scroller();

  onStreamChanged(): void {
    if (!this.isStreaming && this.flushTimer !== -1) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
      this.visibleText = this.message.content;
      this.visibleReasoning = this.message.reasoning;
      this.stepsTick++;
    }
  }

  aboutToAppear(): void {
    this.visibleText = this.message.content;
    this.visibleReasoning = this.message.reasoning;
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
        }
      }, 33);
    }
  }

  aboutToDisappear(): void {
    if (this.flushTimer !== -1) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
    }
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

  build() {
    Column({ space: 8 }) {
      // 思考(折叠条, 默认收起)
      if (this.isStreaming || this.message.reasoning !== '') {
        this.buildThinking()
      }
      // 正文: 本轮叙述/结论, 按发生时序渲染在工具行之前
      if (this.isStreaming || this.message.content !== '') {
        Column() {
          RichTextView({
            content: this.isStreaming ? this.visibleText : this.message.content,
            selectionTrigger: 0
          })
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
      // 工具步骤(dsh 式行内工具行, 点击展开 IO 卡片/diff 卡片)
      if (this.message.toolCalls.length > 0) {
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

  @Builder
  private buildThinking() {
    Column() {
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
