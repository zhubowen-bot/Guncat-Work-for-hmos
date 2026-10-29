// components/UserGuide.ets — 使用指南弹窗内容（参照 HiSH，先只做"基本功能 → Linux Shell"一项）
// 详细文档不塞进应用里：底部一行提示终端里跑 `python readme.py`。
import { BlockTitle, LinkItem, SettingBlockStyle } from './SettingsBase';

@Component
export default struct UserGuide {
  blockStyle: SettingBlockStyle = new SettingBlockStyle()
  @Require openPage: (title: string | Resource, url: string) => void

  build() {
    Column() {
      Scroll() {
        Column() {
          BlockTitle({ content: $r('app.string.guide_basic_title') })
          Column() {
            LinkItem({
              title: $r('app.string.guide_linux_shell_title'),
              subTitle: $r('app.string.guide_linux_shell_desc'),
              click: () => {
                this.openPage($r('app.string.guide_linux_shell_title'), 'guide/01_Linux_Shell.html')
              }
            })
          }
          .attributeModifier(this.blockStyle)

          Text($r('app.string.guide_more_hint'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_tertiary'))
            .margin({ left: 20, top: 4 })
            .width('100%')
        }
        .margin(10)
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .scrollBarWidth(1)
      .layoutWeight(1)
      .align(Alignment.Top)
      .padding({ bottom: 50 })
    }
  }
}
