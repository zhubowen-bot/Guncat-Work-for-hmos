// AskUserCard: ask_user_question 工具的问题卡片(对齐 DeepSeek Harness 的 AskQuestionCard)
// 工具执行挂起等待用户作答时, 由 ChatPage 在时间线末尾渲染本卡片;
// 单选直接回传, 多选勾选后确认, 均可附带文字补充。
import { PendingAsk } from '../service/AskUserBridge';

@Component
export struct AskUserCard {
  @Prop ask: PendingAsk | null = null;
  private onAnswer: (askId: string, selections: string[], note: string) => void =
    (_id: string, _s: string[], _n: string): void => {};
  private onCancel: (askId: string) => void = (_id: string): void => {};
  @State private selected: string[] = [];
  @State private noteText: string = '';

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.info_circle'))
          .fontSize(17)
          .fontColor([$r('app.color.brand')])
        Text('需要你的决定')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text((this.ask !== null && (this.ask as PendingAsk).multiSelect) ? '可多选' : '单选')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')

      if (this.ask !== null) {
        Text((this.ask as PendingAsk).question)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(21)
          .width('100%')
      }

      // 选项 chips(单选=单选钮, 多选=勾选; 都只做选择, 由下方"提交"统一发送)
      if (this.ask !== null && (this.ask as PendingAsk).options.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach((this.ask as PendingAsk).options, (opt: string) => {
            Row({ space: 6 }) {
              // 选中指示: 单选圆点 / 多选方框
              Stack()
                .width(14)
                .height(14)
                .borderRadius(this.ask !== null && (this.ask as PendingAsk).multiSelect ? 4 : 7)
                .backgroundColor(this.isSelected(opt) ? $r('app.color.brand') : Color.Transparent)
                .border({ width: 1.5, color: this.isSelected(opt) ?
                  $r('app.color.brand') : $r('app.color.text_tertiary') })
              Text(opt)
                .fontSize(13)
                .fontColor(this.isSelected(opt) ? $r('app.color.brand') : $r('app.color.text_primary'))
            }
            .padding({ left: 12, right: 14, top: 8, bottom: 8 })
            .borderRadius(10)
            .backgroundColor(this.isSelected(opt) ? $r('app.color.brand_light') :
              $r('app.color.raised_surface'))
            .border({ width: 1, color: this.isSelected(opt) ? $r('app.color.brand') :
              $r('app.color.divider') })
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.toggleOption(opt);
            })
          }, (opt: string) => opt)
        }
        .width('100%')
      }

      // 文字补充
      TextArea({
        placeholder: '补充说明(可空)',
        text: this.noteText
      })
        .width('100%')
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(10)
        .constraintSize({ minHeight: 36, maxHeight: 90 })
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onChange((value: string) => {
          this.noteText = value;
        })

      // 操作行: 跳过为幽灵按钮, 提交为主题按钮(统一从这里发送, 选项只做选择)
      Row({ space: 10 }) {
        Button('跳过，由智能体自行决定')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .height(36)
          .padding({ left: 14, right: 14 })
          .borderRadius(10)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: $r('app.color.border') })
          .onClick(() => {
            if (this.ask !== null) {
              this.onCancel((this.ask as PendingAsk).id);
            }
          })

        Button(this.confirmLabel())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .height(36)
          .padding({ left: 20, right: 20 })
          .borderRadius(10)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.submit();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 2 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .border({ width: 1.5, color: $r('app.color.brand') })
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 16, color: '#14000000', offsetX: 0, offsetY: 4 })
  }

  private isSelected(opt: string): boolean {
    for (let i: number = 0; i < this.selected.length; i++) {
      if (this.selected[i] === opt) {
        return true;
      }
    }
    return false;
  }

  // 单选=替换选中项, 多选=切换勾选; 都不直接发送, 等待"提交"
  private toggleOption(opt: string): void {
    let ask: PendingAsk | null = this.ask;
    if (ask === null) {
      return;
    }
    if (this.isSelected(opt)) {
      this.selected = this.selected.filter((s: string): boolean => s !== opt);
      return;
    }
    if (ask.multiSelect) {
      let next: string[] = this.selected.slice();
      next.push(opt);
      this.selected = next;
    } else {
      this.selected = [opt];
    }
  }

  private confirmLabel(): string {
    let ask: PendingAsk | null = this.ask;
    if (ask !== null && ask.multiSelect && this.selected.length > 0) {
      return '提交(' + this.selected.length.toString() + ' 项)';
    }
    return '提交';
  }

  private submit(): void {
    let ask: PendingAsk | null = this.ask;
    if (ask === null) {
      return;
    }
    this.onAnswer(ask.id, this.selected, this.noteText);
    this.resetState();
  }

  private resetState(): void {
    this.selected = [];
    this.noteText = '';
  }
}
