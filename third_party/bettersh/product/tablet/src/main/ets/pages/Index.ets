// 页面入口（@Entry）必须落在 entry 模块内：loadContent('pages/TerminalPage')
// 只在当前模块解析路由，HAR 里的 TerminalPage 只是普通 @Component。
import { Index as BshIndex } from 'bsh_main';

@Entry
@Component
struct Index {
  build() {
    Column() {
      BshIndex()
    }
    .width('100%')
    .height('100%')
  }
}
