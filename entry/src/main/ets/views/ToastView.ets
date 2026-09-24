// Toast 提示 (对齐 web 版本 .toast)
@Component
export struct ToastView {
  @Prop message: string = '';

  build() {
    Column() {
      Text(this.message)
        .fontSize(13)
        .fontColor(Color.White)
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    }
    .backgroundColor($r('app.color.toast_bg'))
    .borderRadius(24)
    .shadow({ radius: 18, color: '#22000000', offsetX: 0, offsetY: 6 })
  }
}
