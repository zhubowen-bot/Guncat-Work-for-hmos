// 使用指南页（手机/平板路由）：内容复用 HAR 的 UserGuide，点条目跳到 GuideWebPage。
import { UserGuide } from 'bsh_main';
import { ComposeTitleBar } from '@kit.ArkUI';

@Entry
@Component
struct UserGuidePage {
  build() {
    Column() {
      ComposeTitleBar({
        title: $r('app.string.user_guide_title')
      })
      UserGuide({
        openPage: (title: string | Resource, url: string) => {
          this.getUIContext().getRouter().pushUrl({
            url: 'pages/GuideWebPage',
            params: { page: url, title: title }
          })
        }
      }).layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
