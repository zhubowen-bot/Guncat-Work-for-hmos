// 消息输入区: 悬浮式输入容器(文本在上、操作按钮在下) + @文件引用候选
// 文件预览条与工具开关行由父组件 ChatPage 直接在外部渲染
import { MentionQuery, MentionQueryParser } from '../common/MentionQuery';

// @文件引用候选弹层的最大条数(再多就盖住半个屏幕了)
const MENTION_MAX_ROWS: number = 8;

// 输入框正文字号: 16fp。此前压到 15fp 是为了在两侧小圆按钮夹击下把占位文字塞进一行;
// 现在文本行独占输入容器整行宽度, 不必再为宽度牺牲字号。
const INPUT_FONT_SIZE: number = 16;
// 单行输入框高度: 16fp 一行(约 22) + 上下 padding 9 + 5 + 余量
const INPUT_ONE_LINE_HEIGHT: number = 40;
// 用户输入多行内容时输入框的展开上限
const INPUT_EXPAND_MAX_HEIGHT: number = 140;
// 容器底栏操作按钮的边长: 语音/拍照/附件/发送统一 40, 保证同一基线、同一触控面积
const ACTION_BTN_SIZE: number = 40;

@Component
export struct MessageInputView {
  @Link inputText: string;
  @Prop isStreaming: boolean = false;
  @Prop @Watch('onParsingChange') isParsing: boolean = false;
  @Prop isListening: boolean = false;
  // 工作模式执行中允许插话(steering): 流式时同时提供 发送(插话) 与 停止 两个按钮
  @Prop allowSteer: boolean = false;
  @Prop placeholder: string = '输入消息';
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
    // 40ms(25fps) 与 16ms 在视觉上没有区别, 但输入区重绘次数少 60%
    this.angleTimer = setInterval(() => {
      this.parsingAngle = (this.parsingAngle + 15) % 360;
    }, 40);
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
      // 候选层挂在输入容器正上方(而不是糊在整个屏幕上): 手指还在输入框附近, 选完继续打字
      if (this.mention !== null && this.mentionCandidates.length > 0) {
        this.buildMentionPopup()
      }
      // 输入容器: 文本区独占一行, 操作按钮收进容器底栏。
      // 整块只有一层圆角底板 + 一层柔和阴影, 不再让每个按钮各自带小圆底和阴影。
      Column() {
        TextArea({
          placeholder: this.placeholder,
          text: this.inputText,
          controller: this.textCtl
        })
          .width('100%')
          .backgroundColor(Color.Transparent)
          .fontSize(INPUT_FONT_SIZE)
          // 占位文字默认按 16fp 绘制且不跟随 fontSize, 这里显式对齐正文, 主题切换与缩放时才不会跳字号
          .placeholderFont({ size: INPUT_FONT_SIZE })
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          // 空输入时锁死一行高度: 占位文字再长也不许把输入框撑成两行;
          // 有内容时才放开, 保留多行草稿向上展开的能力。
          .constraintSize({
            minHeight: INPUT_ONE_LINE_HEIGHT,
            maxHeight: this.inputText.length === 0 ? INPUT_ONE_LINE_HEIGHT : INPUT_EXPAND_MAX_HEIGHT
          })
          .padding({ left: 10, right: 10, top: 9, bottom: 5 })
          .onChange((value: string) => {
            this.inputText = value;
            this.refreshMention(value);
          })

        // 容器底栏: 左侧是输入方式(语音/拍照/附件), 右侧是发送或停止
        Row() {
          Row({ space: 2 }) {
            this.buildVoiceButton()
            this.buildCameraButton()
            this.buildUploadButton()
          }
          .alignItems(VerticalAlign.Center)

          Blank()

          this.buildSendButton()
        }
        .width('100%')
        .height(ACTION_BTN_SIZE)
        .alignItems(VerticalAlign.Center)
        .padding({ left: 2 })
      }
      .width('100%')
      .padding({ left: 6, right: 6, top: 6, bottom: 4 })
      .backgroundColor($r('app.color.raised_surface'))
      .borderRadius(26)
      // 浅色模式下页面与容器同为白色, 一圈 10% 黑描边给悬浮层收边; 深色模式是 12% 白
      .border({ width: 1, color: $r('app.color.border') })
      .shadow({ radius: 24, color: '#14000000', offsetX: 0, offsetY: 6 })
    }
    .width('100%')
    // 与上方工具胶囊行使用同一组左右留白, 保证输入容器与胶囊左边对齐
    .padding({ left: 12, right: 12, top: 2, bottom: 10 })
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
    .margin({ bottom: 8 })
    .backgroundColor($r('app.color.raised_surface'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(18)
    .shadow({ radius: 18, color: '#1A000000', offsetX: 0, offsetY: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  // 输入方式按钮(语音/拍照/附件): 只用图标本身, 不再套白色小圆底;
  // 激活态(录音中 / 解析中)才给一层浅色圆底做提示。
  @Builder
  buildVoiceButton() {
    Button() {
      SymbolGlyph($r('sys.symbol.mic_fill'))
        .fontSize(21)
        .fontColor([this.isListening ? $r('app.color.brand') : $r('app.color.text_secondary')])
    }
    .width(ACTION_BTN_SIZE)
    .height(ACTION_BTN_SIZE)
    .borderRadius(ACTION_BTN_SIZE / 2)
    .backgroundColor(this.isListening ? $r('app.color.brand_light') : Color.Transparent)
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
        .fontSize(21)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width(ACTION_BTN_SIZE)
    .height(ACTION_BTN_SIZE)
    .borderRadius(ACTION_BTN_SIZE / 2)
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      if (!this.isStreaming && !this.isParsing && !this.isListening) {
        this.onCameraCapture();
      }
    })
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
          .fontSize(21)
          .fontColor([$r('app.color.text_secondary')])
      }
    }
    .width(ACTION_BTN_SIZE)
    .height(ACTION_BTN_SIZE)
    .borderRadius(ACTION_BTN_SIZE / 2)
    .backgroundColor(this.isParsing ? $r('app.color.brand_light') : Color.Transparent)
    .onClick(() => {
      if (!this.isStreaming && !this.isParsing && !this.isListening) {
        this.onFileUpload();
      }
    })
  }

  // 发送/插话/停止: 唯一保留实心底的主操作键, 其余图标按钮都是透明底
  @Builder
  buildSendButton() {
    if (this.isStreaming) {
      Row({ space: 10 }) {
        if (this.allowSteer) {
          // 插话发送: 任务执行中把输入内容作为"用户补充"注入下一步
          Button() {
            SymbolGlyph($r('sys.symbol.paperplane'))
              .fontSize(19)
              .fontColor([(this.inputText.trim() !== '') ? Color.White : $r('app.color.text_quaternary')])
          }
          .width(ACTION_BTN_SIZE)
          .height(ACTION_BTN_SIZE)
          .borderRadius(ACTION_BTN_SIZE / 2)
          .backgroundColor((this.inputText.trim() !== '') ?
            $r('app.color.brand') : $r('app.color.surface_secondary'))
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
          Stack()
            .width(11)
            .height(11)
            .backgroundColor(Color.White)
            .borderRadius(2.5)
        }
        .width(ACTION_BTN_SIZE)
        .height(ACTION_BTN_SIZE)
        .borderRadius(ACTION_BTN_SIZE / 2)
        .backgroundColor($r('app.color.stop_btn'))
        .onClick(() => {
          this.onStop();
        })
      }
    } else {
      Button() {
        SymbolGlyph($r('sys.symbol.paperplane'))
          .fontSize(19)
          .fontColor([(this.inputText.trim() !== '' && !this.isParsing && !this.isListening) ?
            Color.White : $r('app.color.text_quaternary')])
      }
      .width(ACTION_BTN_SIZE)
      .height(ACTION_BTN_SIZE)
      .borderRadius(ACTION_BTN_SIZE / 2)
      .backgroundColor((this.inputText.trim() !== '' && !this.isParsing && !this.isListening) ?
        $r('app.color.brand') : $r('app.color.surface_secondary'))
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
