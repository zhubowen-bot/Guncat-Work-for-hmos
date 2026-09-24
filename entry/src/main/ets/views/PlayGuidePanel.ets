// 玩转应用弹层 (复用关于弹层的弹出式非全屏样式, 主体为本地网页 rawfile/玩转应用/index.html)
// 无原生标题栏: 关闭按钮悬浮在网页右上角, 标题由网页自身的 hero 区展示
// 改页面内容: 编辑 rawfile/玩转应用/index.html (卡片可直接复制拼接, 样式在其中的 assets/style.css)
import { webview } from '@kit.ArkWeb';

@Component
export struct PlayGuidePanel {
  @Prop visible: boolean = false;
  // 桌面宽屏(≥700vp, 沿用 ChatPage 的 isWide): 弹层保持 720×680; 手机则拉高到 92%, 上下只留小边距
  @Prop isWide: boolean = false;
  private onClose: () => void = (): void => {};
  private controller: webview.WebviewController = new webview.WebviewController();

  build() {
    if (this.visible) {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.modal_backdrop'))
          .onClick(() => {
            this.onClose();
          })
          .transition(
            TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.EaseOut })
          )

        Stack() {
          // 主体: 本地网页 (随系统深浅色自动切换, 页面内部自行滚动)
          Web({ src: $rawfile('玩转应用/index.html'), controller: this.controller })
            .width('100%')
            .height('100%')
            .zoomAccess(false)
            .darkMode(WebDarkMode.Auto)
            .backgroundColor(Color.Transparent)
            .borderRadius(28)

          // 关闭按钮: 悬浮在网页右上角
          Button() {
            Text('✕')
              .fontSize(16)
              .fontColor($r('app.color.text_secondary'))
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor($r('app.color.raised_surface'))
          .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
          .margin({ top: 14, right: 14 })
          .onClick(() => {
            this.onClose();
          })
        }
        .alignContent(Alignment.TopEnd)
        .width('92%')
        .height(this.isWide ? '76%' : '92%')
        // 手机上宽高均 92%, 上下只留小边距, 提高网页内容利用率; 电脑宽屏放宽到 720×680, 页面随之切两列卡片网格
        .constraintSize({ maxWidth: 720, maxHeight: this.isWide ? 680 : undefined })
        .backgroundColor($r('app.color.surface'))
        .borderRadius(28)
        .clip(true)
        .shadow({ radius: 28, color: '#26000000', offsetX: 0, offsetY: 10 })
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.scale({ x: 0.95, y: 0.95 }).combine(TransitionEffect.opacity(0))
              .animation({ duration: 250, curve: Curve.FastOutLinearIn }),
            TransitionEffect.scale({ x: 0.95, y: 0.95 }).combine(TransitionEffect.opacity(0))
              .animation({ duration: 200, curve: Curve.FastOutLinearIn })
          )
        )
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
    }
  }
}
