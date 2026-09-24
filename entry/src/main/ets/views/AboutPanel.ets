// 关于弹层 (对齐 web 版本 .about-panel)
import { common } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';

const REPO_URL: string = 'https://github.com/zhubowen-bot/Guncat-AI';

@Component
export struct AboutPanel {
  @Prop visible: boolean = false;
  private onClose: () => void = (): void => {};

  build() {
    if (this.visible) {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.modal_backdrop'))
          .onClick(() => {
            this.onClose();
          })
          .transition(
            TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.EaseOut })
          )

        Column() {
          // 标题
          Row() {
            Text('关于')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Button() {
              Text('✕')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
            }
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor($r('app.color.raised_surface'))
            .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
            .onClick(() => {
              this.onClose();
            })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 18, bottom: 14 })

          // 主体
          Column() {
            Image($r('app.media.cat_avatar'))
              .width(64)
              .height(64)
              .borderRadius(32)
              .objectFit(ImageFit.Cover)
              .backgroundColor($r('app.color.brand_light'))
              .margin({ top: 8, bottom: 12 })
            Text('Guncat Work')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .margin({ bottom: 4 })
            Text(`version ${Constants.APP_VERSION}`)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 20 })

            // 开源仓库
            Row() {
              Image($r('app.media.github'))
                .width(16)
                .height(16)
                .fillColor($r('app.color.text_primary'))
              Text('开源仓库')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .margin({ left: 8 })
            }
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .borderRadius(16)
            .backgroundColor($r('app.color.raised_surface'))
            .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
            .margin({ bottom: 24 })
            .onClick(() => {
              let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
              context.openLink(REPO_URL);
            })

            Text('© 2026 Guncat Work (formerly Guncat AI)')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 16 })
          }
          .width('100%')
          .padding({ left: 20, right: 20 })
          .alignItems(HorizontalAlign.Center)
        }
        .width('90%')
        .constraintSize({ maxWidth: 380 })
        .backgroundColor($r('app.color.surface'))
        .borderRadius(28)
        .shadow({ radius: 28, color: '#26000000', offsetX: 0, offsetY: 10 })
        .alignItems(HorizontalAlign.Center)
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.scale({ x: 0.95, y: 0.95 }).combine(TransitionEffect.opacity(0))
              .animation({ duration: 250, curve: Curve.FastOutLinearIn }),
            TransitionEffect.scale({ x: 0.95, y: 0.95 }).combine(TransitionEffect.opacity(0))
              .animation({ duration: 200, curve: Curve.FastOutLinearIn })
          )
        )
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
    }
  }
}
