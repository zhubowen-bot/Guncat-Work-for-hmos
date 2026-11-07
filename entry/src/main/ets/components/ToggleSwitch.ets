// 工具开关(对齐输入区上方的悬浮胶囊: 圆角药丸样式, 激活态有圆点发光)
// 只负责外观, 开关语义与状态仍由调用方传入; 样式与 ChatPage.buildModelSelector 的模型胶囊保持一致:
// 同高 30、同圆角 15、同字号 12 / 行高 16, 彼此之间由外层 Row({ space: 8 }) 拉开间距。
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
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(this.isOn ? $r('app.color.brand') : $r('app.color.text_tertiary'))
        .opacity(this.isOn ? 1 : 0.45)

      Text(this.label)
        .fontSize(12)
        // 显式行高, 与模型胶囊一致(12fp / 行高 16), 输入区上方胶囊看起来是同一组控件
        .lineHeight(16)
        .fontColor(this.isOn ? $r('app.color.brand') : $r('app.color.text_secondary'))
        .fontWeight(this.isOn ? FontWeight.Medium : FontWeight.Normal)
        .margin({ left: 5 })
    }
    .height(30)
    .padding({ left: 11, right: 11 })
    .borderRadius(15)
    .backgroundColor(this.isOn ? $r('app.color.brand_light') : $r('app.color.raised_surface'))
    .shadow({ radius: 12, color: '#12000000', offsetX: 0, offsetY: 2 })
    .opacity(this.toggleEnabled ? 1 : 0.45)
    .enabled(this.toggleEnabled)
    .onClick(() => {
      if (this.toggleEnabled) {
        this.onChange(!this.isOn);
      }
    })
  }
}
