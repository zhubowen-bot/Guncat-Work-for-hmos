// 设置页（手机/平板路由）：WebTerminal 虚拟键栏的齿轮 pushUrl('pages/SettingsPage') 到这里。
// 内容复用 HAR 的 SettingsContent —— PC 上同一份组件放在 CustomContentDialog 里。
import { SettingsContent } from 'bsh_main';
import { ComposeTitleBar } from '@kit.ArkUI';

@Entry
@Component
struct SettingsPage {
  build() {
    Column() {
      ComposeTitleBar({
        title: $r('app.string.Setting_title')
      })
      Column() {
        SettingsContent()
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
