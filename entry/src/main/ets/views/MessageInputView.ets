// 消息输入区 (对齐 web 版本 .input-wrap + .upload-btn + .send-btn)
// 文件预览条 + 工具开关行由父组件 ChatPage 直接在外部渲染
import { MentionQuery, MentionQueryParser } from '../common/MentionQuery';

// @文件引用候选弹层的最大条数(再多就盖住半个屏幕了)
const MENTION_MAX_ROWS: number = 8;

@Component
export struct MessageInputView {
  @Link inputText: string;
  @Prop isStreaming: boolean = false;
  @Prop @Watch('onParsingChange') isParsing: boolean = false;
  @Prop isListening: boolean = false;
  // 工作模式执行中允许插话(steering): 流式时同时提供 发送(插话) 与 停止 两个按钮
  @Prop allowSteer: boolean = false;
  @Prop placeholder: string = '输入消息...';
  // @文件引用候选的取数回调(工作区里的文件相对路径); 返回空数组表示当前形态没有工作区
  // (聊天模式), 此时输入框完全不认 @, 免得弹出一个永远选不中的空层。
  // 用回调而不是 @Prop 数组: 候选只在用户敲 @ 时才取一次, 不必跟着每次流式刷新深拷贝一遍。
  private getMentionPaths: () => string[] = (): string[] => [];
  private onSend: (text: string) => void = (_t: string): void => {};
  private onStop: () => void = (): void => {};
  private onFileUpload: () => void = (): void => {};
  private onVoiceInput: () => void = (): void => {};
  private onCameraCapture: () => void = (): void => {};

  @State private parsingAngle: number = 0;
  private angleTimer: number = -1;
  // 正在输入的 @引用(null = 当前没有在敲引用)与它的候选列表
  @State private mention: MentionQuery | null = null;
  @State private mentionCandidates: string[] = [];
  private textCtl: TextAreaController = new TextAreaController();

  aboutToAppear(): void {
    if (this.isParsing) {
      this.startRotation();
    }
  }

  aboutToDisappear(): void {
    this.stopRotation();
  }

  onParsingChange(): void {
    if (this.isParsing) {
      this.startRotation();
    } else {
      this.stopRotation();
    }
  }

  private startRotation(): void {
    this.stopRotation();
    this.parsingAngle = 0;
    this.angleTimer = setInterval(() => {
      this.parsingAngle = (this.parsingAngle + 6) % 360;
    }, 16);
  }

  private stopRotation(): void {
    if (this.angleTimer !== -1) {
      clearInterval(this.angleTimer);
      this.angleTimer = -1;
    }
    this.parsingAngle = 0;
  }

  // ===== @文件引用 =====
  // 只认「文本末尾那个没写完的 @」: 手机上没有可靠的光标事件, 而移动端输入几乎总在末尾。
  private refreshMention(text: string): void {
    if (text.indexOf('@') < 0) {
      this.closeMention();
      return;
    }
    let q: MentionQuery | null = MentionQueryParser.detectAtEnd(text);
    if (q === null) {
      this.closeMention();
      return;
    }
    let paths: string[] = this.getMentionPaths();
    if (paths.length === 0) {
      this.closeMention();
      return;
    }
    let candidates: string[] = MentionQueryParser.rank(paths, q.query, MENTION_MAX_ROWS);
    if (candidates.length === 0) {
      this.closeMention();
      return;
    }
    this.mention = q;
    this.mentionCandidates = candidates;
  }

  private closeMention(): void {
    if (this.mention !== null) {
      this.mention = null;
      this.mentionCandidates = [];
    }
  }

  private pickMention(path: string): void {
    let q: MentionQuery | null = this.mention;
    if (q === null) {
      return;
    }
    let next: string = MentionQueryParser.applyPick(this.inputText, q, path);
    this.inputText = next;
    this.closeMention();
    // 光标跟到末尾, 用户接着往下写
    this.textCtl.caretPosition(next.length);
  }

  build() {
    Column() {
      // 候选层挂在输入区正上方(而不是糊在整个屏幕上): 手指还在输入框附近, 选完继续打字
      if (this.mention !== null && this.mentionCandidates.length > 0) {
        this.buildMentionPopup()
      }
      Row() {
        this.buildVoiceButton()
        this.buildCameraButton()
        this.buildInputWrap()
        this.buildUploadButton()
        this.buildSendButton()
      }
      .width('100%')
      .padding({ left: 14, right: 10, top: 2, bottom: 10 })
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
  }

  @Builder
  buildMentionPopup() {
    Column() {
      Row() {
        Text('引用工作区文件')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text('@' + ((this.mention !== null) ? (this.mention as MentionQuery).query : ''))
          .fontSize(11)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 4 })

      Scroll() {
        Column() {
          ForEach(this.mentionCandidates, (path: string) => {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.doc_text'))
                .fontSize(14)
                .fontColor([$r('app.color.text_secondary')])
              Text(path)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .onClick(() => {
              this.pickMention(path);
            })
          }, (path: string) => path)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 232 })
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({ bottom: 6 })
    }
    .width('100%')
    .margin({ left: 14, right: 10, bottom: 6 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
    .shadow({ radius: 18, color: '#1F000000', offsetX: 0, offsetY: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildVoiceButton() {
    Button() {
      SymbolGlyph($r('sys.symbol.mic_fill'))
        .fontSize(19)
        .fontColor([this.isListening ? Color.White : $r('app.color.text_secondary')])
    }
    .width(38)
    .height(38)
    .borderRadius(19)
    .backgroundColor(this.isListening ? $r('app.color.brand') : $r('app.color.raised_surface'))
    .shadow({ radius: 12, color: '#14000000', offsetX: 0, offsetY: 3 })
    // 底部对齐的 Row 中 38 高按钮中心偏低 4vp, 用 bottom margin 上移与 42 高的右侧按钮对齐
    .margin({ right: 6, bottom: 2 })
    .onClick(() => {
      if (!this.isStreaming && !this.isParsing) {
        this.onVoiceInput();
      }
    })
  }

  @Builder
  buildCameraButton() {
    Button() {
      SymbolGlyph($r('sys.symbol.camera_fill'))
        .fontSize(19)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width(38)
    .height(38)
    .borderRadius(19)
    .backgroundColor($r('app.color.raised_surface'))
    .shadow({ radius: 12, color: '#14000000', offsetX: 0, offsetY: 3 })
    .margin({ left: 0, right: 8, bottom: 2 })
    .onClick(() => {
      if (!this.isStreaming && !this.isParsing && !this.isListening) {
        this.onCameraCapture();
      }
    })
  }

  @Builder
  buildInputWrap() {
    Row() {
      TextArea({
        placeholder: this.placeholder,
        text: this.inputText,
        controller: this.textCtl
      })
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .constraintSize({ minHeight: 36, maxHeight: 120 })
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .onChange((value: string) => {
          this.inputText = value;
          this.refreshMention(value);
        })
    }
    .layoutWeight(1)
    .backgroundColor($r('app.color.input_bg'))
    .borderRadius(20)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildUploadButton() {
    Button() {
      if (this.isParsing) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(20)
          .fontColor([$r('app.color.brand')])
          .rotate({ angle: this.parsingAngle })
      } else {
        SymbolGlyph($r('sys.symbol.paperclip'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
      }
    }
    .width(42)
    .height(42)
    .borderRadius(21)
    .backgroundColor(this.isParsing ? $r('app.color.brand_light') : $r('app.color.raised_surface'))
    .shadow({ radius: 12, color: '#14000000', offsetX: 0, offsetY: 3 })
    .margin({ left: 8 })
    .onClick(() => {
      if (!this.isStreaming && !this.isParsing && !this.isListening) {
        this.onFileUpload();
      }
    })
  }

  @Builder
  buildSendButton() {
    if (this.isStreaming) {
      Row({ space: 8 }) {
        if (this.allowSteer) {
          // 插话发送: 任务执行中把输入内容作为"用户补充"注入下一步
          Button() {
            SymbolGlyph($r('sys.symbol.paperplane'))
              .fontSize(18)
              .fontColor([Color.White])
          }
          .width(42)
          .height(42)
          .borderRadius(21)
          .backgroundColor((this.inputText.trim() !== '') ?
            $r('app.color.brand') : $r('app.color.text_tertiary'))
          .onClick(() => {
            if (this.inputText.trim() === '') {
              return;
            }
            this.closeMention();
            this.onSend(this.inputText);
            this.inputText = '';
          })
        }
        Button() {
          Stack() {
            Stack()
              .width(12)
              .height(12)
              .backgroundColor(Color.White)
              .borderRadius(2)
          }
          .width(20)
          .height(20)
        }
        .width(42)
        .height(42)
        .borderRadius(21)
        .backgroundColor($r('app.color.stop_btn'))
        .onClick(() => {
          this.onStop();
        })
      }
    } else {
      Button() {
        SymbolGlyph($r('sys.symbol.paperplane'))
          .fontSize(18)
          .fontColor([Color.White])
      }
      .width(42)
      .height(42)
      .borderRadius(21)
      .backgroundColor((this.inputText.trim() !== '' && !this.isParsing && !this.isListening) ?
        $r('app.color.brand') : $r('app.color.text_tertiary'))
      .margin({ left: 8 })
      .onClick(() => {
        // 只有在非解析中且有文本时,才真正发送并清空
        if (this.isParsing || this.isListening) {
          return;
        }
        if (this.inputText.trim() === '') {
          return;
        }
        this.closeMention();
        this.onSend(this.inputText);
        this.inputText = '';
      })
    }
  }
}
