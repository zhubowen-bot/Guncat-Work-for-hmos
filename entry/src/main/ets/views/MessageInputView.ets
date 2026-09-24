// 消息输入区 (对齐 web 版本 .input-wrap + .upload-btn + .send-btn)
// 文件预览条 + 工具开关行由父组件 ChatPage 直接在外部渲染
@Component
export struct MessageInputView {
  @Link inputText: string;
  @Prop isStreaming: boolean = false;
  @Prop @Watch('onParsingChange') isParsing: boolean = false;
  @Prop isListening: boolean = false;
  // 工作模式执行中允许插话(steering): 流式时同时提供 发送(插话) 与 停止 两个按钮
  @Prop allowSteer: boolean = false;
  @Prop placeholder: string = '输入消息...';
  private onSend: (text: string) => void = (_t: string): void => {};
  private onStop: () => void = (): void => {};
  private onFileUpload: () => void = (): void => {};
  private onVoiceInput: () => void = (): void => {};
  private onCameraCapture: () => void = (): void => {};

  @State private parsingAngle: number = 0;
  private angleTimer: number = -1;

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

  build() {
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
        text: this.inputText
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
        this.onSend(this.inputText);
        this.inputText = '';
      })
    }
  }
}
