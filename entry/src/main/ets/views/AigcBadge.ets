// AigcBadge: 统一的 "AI生成" 小角标。
// 规范允许在内容附近/界面顶部持续显示提示文字; 这里用 9fp 浅灰胶囊,
// 尽量不打断阅读, 但保证截图与真机上都能明确看到。
@Component
export struct AigcBadge {
  @Prop text: string = 'AI生成';

  build() {
    Text(this.text)
      .fontSize(9)
      .fontColor($r('app.color.text_tertiary'))
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(6)
      .backgroundColor($r('app.color.input_bg'))
      .maxLines(1)
      .copyOption(CopyOptions.None)
  }
}
