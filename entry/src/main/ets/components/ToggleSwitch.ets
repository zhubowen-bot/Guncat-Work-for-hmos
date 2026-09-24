// 工具开关(对齐 web 版本的 .tool-toggle: 圆角药丸样式, 激活态有圆点发光)
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
        .fontSize(12)
        // 显式行高, 与模型选择胶囊一致(上下 padding 7 + 行高 16 = 30), 保证输入区各按钮等高
        .lineHeight(16)
        .fontColor(this.isOn ? $r('app.color.brand') : $r('app.color.text_secondary'))
        .fontWeight(this.isOn ? FontWeight.Medium : FontWeight.Normal)
        .margin({ left: 5 })
    }
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .borderRadius(15)
    .backgroundColor(this.isOn ? $r('app.color.brand_light') : $r('app.color.raised_surface'))
    .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
    .opacity(this.toggleEnabled ? 1 : 0.45)
    .enabled(this.toggleEnabled)
    .onClick(() => {
      if (this.toggleEnabled) {
        this.onChange(!this.isOn);
      }
    })
  }
}
