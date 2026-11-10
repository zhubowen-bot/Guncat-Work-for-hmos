// 关于弹层 (对齐 web 版本 .about-panel)
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
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
              .margin({ bottom: 12 })

            // AI 生成内容标识说明: 应用不内置模型, 内容由用户配置的模型服务生成。
            Text('本应用不内置、不代理大模型服务；对话与文件由你配置的模型服务生成，界面与导出文件会标注“AI生成”。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(18)
              .textAlign(TextAlign.Center)
              .margin({ bottom: 18 })

            // AI 生成内容标识说明
            Row() {
              SymbolGlyph($r('sys.symbol.info_circle'))
                .fontSize(16)
                .fontColor([$r('app.color.text_primary')])
              Text('AI 生成内容标识说明')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .margin({ left: 8 })
            }
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .borderRadius(16)
            .backgroundColor($r('app.color.raised_surface'))
            .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
            .margin({ bottom: 12 })
            .onClick(() => {
              promptAction.showDialog({
                title: 'AI 生成内容标识',
                message: '本应用不内置、不代理大模型服务。你在设置中自行配置模型 API，请求由设备直接发送到你选择的服务商。\n\n' +
                  '依据《人工智能生成合成内容标识办法》，本应用对 AI 生成内容添加显式标识（界面、复制文本、导出文件中的“AI生成”）' +
                  '和隐式标识（文件元数据中的 AIGC 字段）。请在使用生成内容时注意甄别。',
                buttons: [
                  { text: '知道了', color: '#2E6BE6' }
                ]
              });
            })

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

            // 第三方组件与许可: shell 工具用 IEC 执行核 + mksh/toybox/libarchive/git/
            // dropbear/node, 均以独立 .so 分发; 声明原文随包放在 rawfile/licenses/,
            // 同时给出仓库里的可读链接。
            Row() {
              Text('§')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('第三方组件与许可')
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
              context.openLink(REPO_URL + '/blob/main/THIRD_PARTY_NOTICES.md');
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
