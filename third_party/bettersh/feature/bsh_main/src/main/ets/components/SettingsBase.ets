// components/SettingsBase.ets — 设置 / 使用指南弹窗的公共积木（参照 HiSH，精简版）
//   BlockTitle        —— 分组标题
//   SettingBlockStyle —— 分组卡片（圆角 + 半透明底）
//   SettingItem       —— "标题 + 副标题 + 右侧控件" 的一行
//   LinkItem          —— "标题 + 副标题 + 右箭头" 的可点击行（指南列表用）

@Component
export struct BlockTitle {
  content?: string | Resource

  build() {
    Text(this.content)
      .fontSize($r('sys.float.Body_M'))
      .fontColor($r('sys.color.font_tertiary'))
      .margin({ bottom: 10, left: 20 })
      .width('100%')
  }
}

export class SettingBlockStyle implements AttributeModifier<ColumnAttribute> {
  applyNormalAttribute(instance: ColumnAttribute): void {
    instance.borderRadius(20)
      .backgroundColor($r('app.color.setting_block_background'))
      .margin({ bottom: 20 })
  }
}

@Component
export struct SettingItem {
  @Prop title: string | Resource
  @Prop subTitle: string | Resource
  @BuilderParam content?: () => void

  build() {
    Row() {
      Column() {
        Text(this.title).fontSize($r('sys.float.Body_L')).fontColor($r('sys.color.font_primary'))
        Text(this.subTitle).fontSize($r('sys.float.Body_M')).fontColor($r('sys.color.font_tertiary'))
      }
      .flexGrow(1)
      .alignItems(HorizontalAlign.Start)

      if (this.content) {
        this.content()
      }
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height(56)
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
  }
}

@Component
export struct LinkItem {
  @Prop title: string | Resource
  @Prop subTitle: string | Resource
  click?: () => void

  build() {
    Row() {
      Column() {
        Text(this.title).fontSize($r('sys.float.Body_L')).fontColor($r('sys.color.font_primary'))
        Text(this.subTitle).fontSize($r('sys.float.Body_M')).fontColor($r('sys.color.font_tertiary'))
      }
      .flexGrow(1)
      .alignItems(HorizontalAlign.Start)

      if (this.click) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontColor([$r('sys.color.icon_secondary')])
          .fontSize('24vp')
      }
    }
    .onClick(() => {
      if (this.click) {
        this.click()
      }
    })
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height(56)
    .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
  }
}
