// DeepSeek 配置指引: 设置 →「模型」→「模型配置」右上角入口。
//
// 目标是把「选内置方案 → 注册开放平台 → 创建 API Key → 粘贴回应用」讲清楚。
// 截图放在 rawfile/guides/deepseek/ 下；01 / 05 已裁成界面区域（去掉手机边框和状态栏），
// 替换时保持相近比例即可；平台截图随官网改版可能需要替换。
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

const DEEPSEEK_PLATFORM_URL: string = 'https://platform.deepseek.com/';

@Entry
@Component
struct DeepSeekGuidePage {
  // 打开 DeepSeek 开放平台: 设备有浏览器时直接跳转, 没有则提示手动访问
  private async openPlatform(): Promise<void> {
    let context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await context.openLink(DEEPSEEK_PLATFORM_URL);
    } catch (e) {
      promptAction.showToast({
        message: '无法打开浏览器，请手动访问 platform.deepseek.com',
        duration: 2500
      });
    }
  }

  build() {
    Column() {
      this.buildHeader()

      Scroll() {
        Column() {
          this.buildHero()

          this.buildSectionLabel('配置步骤')
          this.buildStepCard('01', '选择 Deepseek 方案',
            '打开 设置 → 模型 → 模型配置，在「配置方案」里点选内置的 Deepseek。接入协议、Base URL 和模型都已经填好，不需要修改。',
            'guides/deepseek/01-select-profile.png',
            '在配置方案列表中点选 Deepseek', 1.28)
          this.buildStepCard('02', '注册或登录开放平台',
            '在浏览器打开 platform.deepseek.com，输入手机号，点「发送验证码」，填入收到的验证码后登录。未注册的手机号会自动完成注册。',
            'guides/deepseek/02-sign-in.png',
            '开放平台登录页：手机号 + 验证码，未注册会自动注册', 1.5)
          this.buildStepCard('03', '进入 API keys 页面',
            '登录后进入「API keys」页面（桌面端在左侧菜单，手机上可能在菜单按钮里）。页面会列出已有的密钥，右上角就是创建入口。',
            'guides/deepseek/03-api-keys.png',
            'API keys 页面：右上角「创建 API key」', 1.9)
          this.buildStepCard('04', '创建并复制 API Key',
            '输入一个容易辨认的名称，点「创建」。生成后立即复制以 sk- 开头的完整密钥；弹窗关闭后就无法再次查看。',
            'guides/deepseek/04-create-key.png',
            '填写名称后创建，生成时复制完整密钥', 1.67)
          this.buildStepCard('05', '粘贴回应用并开始对话',
            '回到 设置 → 模型 → 模型配置，把密钥粘贴到「API Key」输入框。返回聊天页，在模型选择器里选中 Deepseek 即可开始对话。',
            'guides/deepseek/05-paste-key.png',
            '把 Key 粘贴到「API Key」输入框', 1.25)

          this.buildSectionLabel('小提示')
          Column() {
            this.buildNoteRow($r('sys.symbol.lock'), '密钥只显示一次',
              '创建后立即复制并保存。如果忘了，只能重新创建一个新的 Key。')
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ left: 46 })
            this.buildNoteRow($r('sys.symbol.info_circle'), '只保存在本机',
              'API Key 只写入本机配置，不会上传到服务器。不要把 Key 发给他人，也不要粘贴到不信任的网站。')
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ left: 46 })
            this.buildNoteRow($r('sys.symbol.arrow_clockwise'), '需要更换密钥时',
              '重新点选 Deepseek 方案，把新的 Key 粘贴到「API Key」输入框即可覆盖旧值。')
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ left: 46 })
            this.buildNoteRow($r('sys.symbol.flag'), '调用前确认账户可用',
              '开放平台可能需要完成实名认证或充值后才能调用，具体以平台页面为准。')
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.divider') })
          .clip(true)

          Button() {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.link'))
                .fontSize(16)
                .fontColor([Color.White])
              Text('打开 DeepSeek 开放平台')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
            }
          }
          .width('100%')
          .height(46)
          .borderRadius(23)
          .backgroundColor($r('app.color.brand'))
          .margin({ top: 16 })
          .onClick((): void => {
            this.openPlatform();
          })

          Text('开放平台页面与账号规则由 DeepSeek 提供，截图可能随官网改版变化。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .textAlign(TextAlign.Center)
            .margin({ top: 14, bottom: 8 })
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.sidebar_fill'))
    // 只把页面底色延伸到屏幕底部导航条安全区；顶部状态栏保持原样
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  private buildHeader() {
    Column() {
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          router.back();
        })

        Text('DeepSeek 配置指引')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })

        Text('5 步')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(999)
          .backgroundColor($r('app.color.surface_secondary'))
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .height(56)
      .padding({ left: 10, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(56)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.surface'))
    .border({ width: { bottom: 0.5 }, color: { bottom: $r('app.color.divider') } })
  }

  @Builder
  private buildHero() {
    Column() {
      Row({ space: 14 }) {
        SymbolGlyph($r('sys.symbol.list_book'))
          .fontSize(34)
          .fontColor([$r('app.color.brand')])
          .flexShrink(0)

        Column({ space: 4 }) {
          Text('用 DeepSeek 开始对话')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('选好内置方案，注册开放平台并创建 API Key，再粘贴回应用即可。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(18)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.link'))
            .fontSize(16)
            .fontColor([Color.White])
          Text('打开 DeepSeek 开放平台')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
        }
      }
      .width('100%')
      .height(44)
      .borderRadius(22)
      .backgroundColor($r('app.color.brand'))
      .margin({ top: 16 })
      .onClick((): void => {
        this.openPlatform();
      })

      Text('已有 API Key？直接选择 Deepseek 方案，把 Key 粘贴到「API Key」即可。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(17)
        .width('100%')
        .margin({ top: 10 })
    }
    .width('100%')
    .padding(18)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(24)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildSectionLabel(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4 })
      .margin({ top: 12, bottom: 8 })
  }

  @Builder
  private buildStepCard(no: string, title: string, body: string, imagePath: string, caption: string,
    imageAspect: number) {
    Column() {
      Row() {
        Text(no)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
          .letterSpacing(1)
          .width(26)
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .margin({ left: 6 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(body)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(21)
        .width('100%')
        .margin({ top: 10 })

      Image($rawfile(imagePath))
        .width('100%')
        .aspectRatio(imageAspect)
        .objectFit(ImageFit.Contain)
        .borderRadius(14)
        .border({ width: 1, color: $r('app.color.divider') })
        .backgroundColor($r('app.color.surface'))
        .margin({ top: 12 })

      Text(caption)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(16)
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(22)
    .border({ width: 1, color: $r('app.color.divider') })
    .margin({ bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildNoteRow(icon: Resource, title: string, body: string) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([$r('app.color.brand')])
        .width(22)

      Column() {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(body)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(17)
          .width('100%')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Top)
  }
}
