// components/SettingsContent.ets — 设置弹窗内容（参照 HiSH，先只做两块：显示 / 终端）
//
// 变更直接写 AppStorage（键见下），WebTerminal 用 @StorageProp 监听并应用到 xterm.js；
// "保持屏幕常亮"则由 EntryAbility 存进 AppStorage 的主窗口来生效。
import { window } from '@kit.ArkUI';
import { BlockTitle, SettingBlockStyle, SettingItem } from './SettingsBase';

// AppStorage 键 —— WebTerminal 读同一批键，改名要两边一起改
const KEEP_SCREEN_ON = 'keepScreenOn';
const TERM_FONT_SIZE = 'termFontSize';
const TERM_FONT_FAMILY = 'termFontFamily';
const TERM_CURSOR_STYLE = 'termCursorStyle';
const TERM_CURSOR_BLINK = 'termCursorBlink';

const FONT_SIZE_OPTIONS: SelectOption[] = [
  { value: '12' }, { value: '14' }, { value: '16' }, { value: '18' }, { value: '20' }
]
const FONT_FAMILY_OPTIONS: SelectOption[] = [
  { value: 'Default' }, { value: 'JetBrains Mono' }, { value: 'Fira Code' },
  { value: 'Source Code Pro' }, { value: 'monospace' }
]
const CURSOR_STYLE_OPTIONS: SelectOption[] = [
  { value: 'BLOCK' }, { value: 'BEAM' }, { value: 'UNDERLINE' }
]

@Component
export default struct SettingsContent {
  @StorageProp('keepScreenOn') keepScreenOn: boolean = false
  @StorageProp('termFontSize') terminalFontSize: number = 14
  @StorageProp('termFontFamily') terminalFontFamily: string = 'Default'
  @StorageProp('termCursorStyle') termCursorShape: string = 'BLOCK'
  @StorageProp('termCursorBlink') termCursorBlink: boolean = true
  blockStyle: SettingBlockStyle = new SettingBlockStyle()

  private setKeepScreenOn(value: boolean): void {
    AppStorage.setOrCreate(KEEP_SCREEN_ON, value)
    const mainWindow = AppStorage.get<window.Window>('mainWindow')
    if (mainWindow) {
      try { mainWindow.setWindowKeepScreenOn(value); } catch (e) { /* ignore */ }
    }
  }

  @Builder
  private keepScreenCheckbox() {
    Checkbox()
      .select(this.keepScreenOn)
      .onChange((value: boolean) => { this.setKeepScreenOn(value) })
  }

  @Builder
  private fontSizeSelect() {
    Select(FONT_SIZE_OPTIONS)
      .width(80)
      .value(this.terminalFontSize.toString())
      .onSelect((_i: number, value: string) => {
        AppStorage.setOrCreate(TERM_FONT_SIZE, parseInt(value))
      })
  }

  @Builder
  private fontFamilySelect() {
    Select(FONT_FAMILY_OPTIONS)
      .width(180)
      .value(this.terminalFontFamily)
      .onSelect((_i: number, value: string) => {
        AppStorage.setOrCreate(TERM_FONT_FAMILY, value)
      })
  }

  @Builder
  private cursorStyleSelect() {
    Select(CURSOR_STYLE_OPTIONS)
      .width(120)
      .value(this.termCursorShape)
      .onSelect((_i: number, value: string) => {
        AppStorage.setOrCreate(TERM_CURSOR_STYLE, value)
      })
  }

  @Builder
  private cursorBlinkCheckbox() {
    Checkbox()
      .select(this.termCursorBlink)
      .onChange((value: boolean) => {
        AppStorage.setOrCreate(TERM_CURSOR_BLINK, value)
      })
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          BlockTitle({ content: $r('app.string.setting_block_display') })
          Column() {
            SettingItem({
              title: $r('app.string.setting_keep_screen_on'),
              subTitle: $r('app.string.setting_keep_screen_on_desc'),
              content: () => { this.keepScreenCheckbox() }
            }).onClick(() => { this.setKeepScreenOn(!this.keepScreenOn) })
          }
          .attributeModifier(this.blockStyle)

          BlockTitle({ content: $r('app.string.setting_terminal') })
          Column() {
            SettingItem({
              title: $r('app.string.setting_font_size'),
              subTitle: $r('app.string.setting_font_size_desc'),
              content: () => { this.fontSizeSelect() }
            })

            SettingItem({
              title: $r('app.string.setting_font_family'),
              subTitle: $r('app.string.setting_font_family_desc'),
              content: () => { this.fontFamilySelect() }
            })

            SettingItem({
              title: $r('app.string.setting_cursor_style'),
              subTitle: $r('app.string.setting_cursor_style_desc'),
              content: () => { this.cursorStyleSelect() }
            })

            SettingItem({
              title: $r('app.string.setting_cursor_blink'),
              subTitle: $r('app.string.setting_cursor_blink_desc'),
              content: () => { this.cursorBlinkCheckbox() }
            }).onClick(() => { AppStorage.setOrCreate(TERM_CURSOR_BLINK, !this.termCursorBlink) })
          }
          .attributeModifier(this.blockStyle)
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
