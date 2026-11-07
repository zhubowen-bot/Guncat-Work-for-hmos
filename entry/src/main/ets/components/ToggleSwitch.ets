// 工具开关(对齐输入区上方的悬浮胶囊: 圆角药丸样式, 激活态有圆点发光)
// 只负责外观, 开关语义与状态仍由调用方传入; 样式与 ChatPage.buildModelSelector 的模型胶囊保持一致:
// 同高 34、同圆角 17、同字号 13 / 行高 18, 彼此之间由外层 Row({ space: 8 }) 拉开间距。
@Component
export struct ToggleSwitch {
  @Prop isOn: boolean = false;
  @Prop toggleEnabled: boolean = true;
  private label: string = '';
  private onChange: (value: boolean) => void = (_v: boolean): void => {};

  build() {
    Row() {
      // 圆点
      Stack()
        .width(7)
        .height(7)
        .borderRadius(3.5)
        .backgroundColor(this.isOn ? $r('app.color.brand') : $r('app.color.text_tertiary'))
        .opacity(this.isOn ? 1 : 0.45)

      Text(this.label)
        .fontSize(13)
        // 显式行高, 与模型胶囊一致(13fp / 行高 18), 输入区上方胶囊看起来是同一组控件
        .lineHeight(18)
        .fontColor(this.isOn ? $r('app.color.brand') : $r('app.color.text_secondary'))
        .fontWeight(this.isOn ? FontWeight.Medium : FontWeight.Normal)
        .margin({ left: 6 })
    }
    .height(34)
    .padding({ left: 13, right: 13 })
    .borderRadius(17)
    .backgroundColor(this.isOn ? $r('app.color.brand_light') : $r('app.color.raised_surface'))
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 3 })
    .opacity(this.toggleEnabled ? 1 : 0.45)
    .enabled(this.toggleEnabled)
    .onClick(() => {
      if (this.toggleEnabled) {
        this.onChange(!this.isOn);
      }
    })
  }
}
