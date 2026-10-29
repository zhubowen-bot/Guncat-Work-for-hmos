// 同 TerminalPage：AppRunnerAbility 用 loadContent('pages/ClientWindow') 路由本模块页面。
import { ClientWindow as BshClientWindow } from 'bsh_main';

@Entry
@Component
struct ClientWindow {
  build() {
    Column() {
      BshClientWindow()
    }
    .width('100%')
    .height('100%')
  }
}
