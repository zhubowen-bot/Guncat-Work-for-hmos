
import { deviceInfo } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { bshTermStart, bshTermInput, bshTermResize } from 'libentry.so';
import {
    FunctionKeySequences,
    getVirtualKeyMetrics,
    NormalKeySequences
} from '../utils/TerminalVirtualKeys';
import { ImmersiveButtonModifier, ImmersiveToggleModifier } from '../utils/ImmersiveButton';
import { TerminalWindows } from '../service/TerminalWindows';
import { UIBus, UiHost } from '../service/UIBus';
import { PasteBoardService } from '../service/PasteBoardService';

const VKeyMetrics = getVirtualKeyMetrics(deviceInfo.deviceType)
const VKeyMargin = VKeyMetrics.margin;
const VKeyPadding = VKeyMetrics.padding;
const VKeyHeight = VKeyMetrics.height;
const VKeyWidth = VKeyMetrics.width;
const VKeyFontSize = VKeyMetrics.fontSize;
const VKeyRadius = VKeyMetrics.radius;

@Component
export default struct WebTerminal {
  @Require virtKeyEnabled: boolean = true;
  @State showVirtKey: boolean = deviceInfo.deviceType !== '2in1';
  // 键栏隐藏但留恢复条(界面 ▼ 按钮)；bshutil keys hide 连恢复条一起收掉
  @State keysRecoverBar: boolean = true;
  // 右键模式:'menu' 时盖一层透明宿主接 ArkUI 菜单;'smart' 暂未接入
  @State rightClickMode: string = 'menu';
  webviewController: WebviewController = new webview.WebviewController();
  @State ctrlPressed: boolean = false;
  @State shiftPressed: boolean = false;
  @State fnPressed: boolean = false;
  // 终端外观设置：设置面板(SettingsContent)写 AppStorage，这里监听并应用到 xterm
  @StorageProp('termFontSize') @Watch('applyFontSize') termFontSize: number = 14;
  @StorageProp('termFontFamily') @Watch('applyFontFamily') termFontFamily: string = 'Default';
  @StorageProp('termCursorStyle') @Watch('applyCursorStyle') termCursorShape: string = 'BLOCK';
  @StorageProp('termCursorBlink') @Watch('applyCursorBlink') termCursorBlink: boolean = true;
  applicationMode: boolean = false; // 暂时不清楚？
  immersiveButton: ImmersiveButtonModifier = new ImmersiveButtonModifier();
  immersiveToggle: ImmersiveToggleModifier = new ImmersiveToggleModifier();
  private termReady: boolean = false; // bettersh 是否已就绪，后续deprecate
  private cols: number = 80; // 当前termd 的长宽，但是hish中也没有使用，后续deprecate?
  private rows: number = 24;
  private sid: number = -1;

  aboutToDisappear(): void {
    // 会话号在 onPageEnd 里认领（allocateSessionId），就由这里归还；UI 事件订阅同时摘掉。
    UIBus.getInstance().unregister(this.sid);
    try { TerminalWindows.getInstance().releaseSessionId(this.sid); } catch (e) { /* ignore */ }
    this.sid = -1;
  }
  
  /** 右键菜单(免剪贴板权限)。**只在 menu 模式下存在**(宿主是 build 里那层透明覆盖层,
   *  smart 模式下那个 if 分支不存在,菜单没地方弹)。smart 模式暂未接入。 */
  @Builder
  contextMenu(webController: WebviewController) {
    Flex({ direction: FlexDirection.Column }) {
      MenuItem({ content: '复制' })
        .width('100%')
        .onClick(() => {
          PasteBoardService.getInstance().copySelection(webController);
        })
      PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
        .fontColor(Color.White)
        .backgroundColor('#1A292B2E')
        .align(Alignment.Start)
        .padding({ left: 12, right: 12 })
        .width('100%')
        .onClick(async (event: ClickEvent, result: PasteButtonOnClickResult) => {
          PasteBoardService.getInstance().pasteFromClipboard(result, webController);
        })
    }
    .width('160vp')
  }

  /**
   * @param appCode code used in application mode
   */
  @Builder
  buildVKey(name: string, value: string, appCode?: string) {
    Button(name, { buttonStyle: ButtonStyleMode.TEXTUAL })
      .height(VKeyHeight)
      .width(VKeyWidth)
      .borderRadius(VKeyRadius)
      .fontSize(VKeyFontSize)
      .fontColor($r('sys.color.white'))
      .margin(VKeyMargin)
      .padding({ left: VKeyPadding, right: VKeyPadding })
      .attributeModifier(this.immersiveButton)
      .onClick(() => {
        if (this.applicationMode && appCode) {
          this.input(appCode);
        } else {
          this.input(value)
        }
      })
  }

  @Builder
  toggleCtrlKey(name: string, action: () => void) {
    Toggle({ type: ToggleType.Button, isOn: this.ctrlPressed }) {
      Text(name).fontSize(VKeyFontSize).fontWeight(FontWeight.Medium)
    }
    .height(VKeyHeight)
    .width(VKeyWidth)
    .borderRadius(VKeyRadius)
    .margin(VKeyMargin)
    .backgroundColor($r('sys.color.black'))
    .selectedColor($r('sys.color.interactive_active'))
    .attributeModifier(this.immersiveToggle)
    .onClick(() => action())
  }

  @Builder
  toggleShiftKey(name: string, action: () => void) {
    Toggle({ type: ToggleType.Button, isOn: this.shiftPressed }) {
      Text(name).fontSize(VKeyFontSize).fontWeight(FontWeight.Medium)
    }
    .height(VKeyHeight)
    .width(VKeyWidth)
    .borderRadius(VKeyRadius)
    .margin(VKeyMargin)
    .backgroundColor($r('sys.color.black'))
    .selectedColor($r('sys.color.interactive_active'))
    .attributeModifier(this.immersiveToggle)
    .onClick(() => action())
  }

  @Builder
  toggleFnKey(name: string, action: () => void) {
    Toggle({ type: ToggleType.Button, isOn: this.fnPressed }) {
      Text(name).fontSize(VKeyFontSize).fontWeight(FontWeight.Medium)
    }
    .height(VKeyHeight)
    .width(VKeyWidth)
    .borderRadius(VKeyRadius)
    .margin(VKeyMargin)
    .backgroundColor($r('sys.color.black'))
    .selectedColor($r('sys.color.interactive_active'))
    .attributeModifier(this.immersiveToggle)
    .onClick(() => action())
  }

  @Builder
  settingsButton() {
    Button({ buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Image($r('app.media.gearshape')).width(16).height(16).padding(0)
    }
    .height(VKeyHeight)
    .width(VKeyHeight)
    .borderRadius(VKeyRadius)
    .margin(VKeyMargin)
    .attributeModifier(this.immersiveButton)
    .onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' }))
  }

  /* 隐藏虚拟按键的按钮 */
  @Builder
  hideVKeyButton() {
    Button('▼', { buttonStyle: ButtonStyleMode.TEXTUAL })
      .height(VKeyHeight)
      .width(VKeyHeight)
      .borderRadius(VKeyRadius)
      .margin(VKeyMargin)
      .padding({ left: VKeyPadding, right: VKeyPadding })
      .fontColor($r('sys.color.white'))
      .attributeModifier(this.immersiveButton)
      .onClick(() => {
        // 界面按钮隐藏:保留恢复条(与 bshutil keys hide 的区别见 keysRecoverBar)
        this.showVirtKey = false
        this.keysRecoverBar = true
      })
  }

  /* 展示虚拟按键的按钮 */
  @Builder
  buildShowVirtualKeysButton() {
    Column() {
      Button('▲', { buttonStyle: ButtonStyleMode.TEXTUAL })
        .width(120)
        .height(16)
        .fontSize(16)
        .borderRadius(VKeyRadius)
        .fontColor('#444')
        .padding({ left: VKeyPadding, right: VKeyPadding })
        .attributeModifier(this.immersiveButton)
        .onClick(() => {
          this.showVirtKey = true
        })
    }
    .width('100%')
  }

  /* 虚拟按键 */
  @Builder
  buildVirtualKeys() {
    Column() {
      if (this.fnPressed) {
        Row() {
          this.toggleFnKey('FN', () => this.toggleFn());
          this.buildVKey('F1', FunctionKeySequences.F1);
          this.buildVKey('F2', FunctionKeySequences.F2);
          this.buildVKey('F3', FunctionKeySequences.F3);

          Row().layoutWeight(1);

          this.buildVKey('F4', FunctionKeySequences.F4);
          this.buildVKey('F5', FunctionKeySequences.F5);
          this.buildVKey('F6', FunctionKeySequences.F6);
          this.settingsButton();
        }
        .margin({ left: 5, right: 5 })

        Row() {
          this.buildVKey('F7', FunctionKeySequences.F7);
          this.buildVKey('F8', FunctionKeySequences.F8);
          this.buildVKey('F9', FunctionKeySequences.F9);

          Row().layoutWeight(1);

          this.buildVKey('F10', FunctionKeySequences.F10);
          this.buildVKey('F11', FunctionKeySequences.F11);
          this.buildVKey('F12', FunctionKeySequences.F12);
          this.hideVKeyButton();
        }
        .margin({ left: 5, right: 5 })
      } else {
        Row() {
          this.buildVKey('ESC', NormalKeySequences.ESC);
          this.toggleFnKey('FN', () => this.toggleFn());
          this.buildVKey('/', '/', '/');

          Row().layoutWeight(1);

          this.buildVKey('PGUP', NormalKeySequences.PGUP);
          this.buildVKey('HOME', NormalKeySequences.HOME);
          this.buildVKey('↑', NormalKeySequences.UP, NormalKeySequences.UP_APP);
          this.buildVKey('END', NormalKeySequences.END);

          this.settingsButton();
        }
        .margin({ left: 5, right: 5 })

        Row() {
          this.buildVKey('TAB', NormalKeySequences.TAB);
          this.toggleCtrlKey('CTRL', () => this.toggleCtrl());
          this.buildVKey('-', '-', '-');

          Row().layoutWeight(1);

          this.buildVKey('PGDN', NormalKeySequences.PGDN);
          this.buildVKey('←', NormalKeySequences.LEFT, NormalKeySequences.LEFT_APP);
          this.buildVKey('↓', NormalKeySequences.DOWN, NormalKeySequences.DOWN_APP);
          this.buildVKey('→', NormalKeySequences.RIGHT, NormalKeySequences.RIGHT_APP);
          this.hideVKeyButton();
        }
        .margin({ left: 5, right: 5 })
      }
    }
  }

  /* Toggle Keys */
  private toggleCtrl(): void {
    this.ctrlPressed = !this.ctrlPressed;
  }

  private toggleShift(): void {
    this.shiftPressed = !this.shiftPressed;
  }

  private toggleFn(): void {
    this.fnPressed = !this.fnPressed;
  }

  build() {
    Column() {
      // Stack 让"右键菜单宿主"能盖在 Web 之上，而 Web 本身一动不动（同旧 TerminalPage）。
      Stack() {
        Web({
          src: $rawfile('term/index.html'),
          controller: this.webviewController
        })
          .javaScriptProxy({
            object: this,
            name: 'hbridge',
            methodList: ['input', 'resize'],
            controller: this.webviewController,
            asyncMethodList: [],
            permission: `{
          "javascriptProxyPermission": {
            "urlPermissionList": [
              {
                "scheme": "resource",
                "host": "rawfile",
                "port": "",
                "path": ""
              }
            ]
          }
        }`
          })
          .backgroundColor('#000')
          .width('100%')
          .height('100%')
          // 抑制 ArkWeb 自带的右键菜单：返回 true = 走自定义菜单（页面里的 term.js 也会拦一道）
          .onContextMenuShow(() => {
            return true;
          })
          .onPageEnd(() => {
            this.termReady = true;
            try {
              this.sid = TerminalWindows.getInstance().allocateSessionId();
              bshTermStart(this.sid, (data: string): void => {
                if (!this.termReady || !data || data.length === 0) return;
                try {
                  this.webviewController.runJavaScript('window.termWrite(' + JSON.stringify(data) + ')');
                } catch (e) { /* ignore */ }
              });
              // bshutil 的 UI 事件(键栏显隐 / 缩放 / 右键模式 / picker / newtab)交给 UIBus；
              // 那些"只有页面才能做"的动作经 host 回调回来 —— 见 service/UIBus.ets
              UIBus.getInstance().init(getContext(this) as common.UIAbilityContext);
              const host: UiHost = {
                sid: this.sid,
                setKeys: (show: boolean, recoverBar: boolean): void => {
                  this.showVirtKey = show;
                  this.keysRecoverBar = recoverBar;
                },
                setRightClick: (mode: string): void => { this.rightClickMode = mode; },
                runJs: (js: string): void => {
                  try { this.webviewController.runJavaScript(js); } catch (e) { /* ignore */ }
                }
              };
              UIBus.getInstance().register(host);
              // 页面就绪：把当前设置套到 xterm 上（用户此前在设置面板改过的值）
              this.applyFontSize();
              this.applyFontFamily();
              this.applyCursorStyle();
              this.applyCursorBlink();
            } catch (e) {
              // hilog.error(0x0000, TAG, 'term start failed %{public}s', JSON.stringify(e));
            }
          })

        // 右键菜单宿主只在 menu 模式存在(smart 暂未接入)
        if (this.rightClickMode === 'menu') {
          Column() {
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
          .bindContextMenu(this.contextMenu(this.webviewController), ResponseType.RightClick)
        }
      }
      .layoutWeight(1)

      // 键栏的三种状态：显示 / 隐藏但留恢复条(界面 ▼) / 彻底隐藏(bshutil keys hide)
      if (this.virtKeyEnabled) {
        if (this.showVirtKey) {
          this.buildVirtualKeys()
        } else if (this.keysRecoverBar) {
          this.buildShowVirtualKeysButton()
        }
      }
    }
    .height('100%')
  }

  /* WebTerminal functions */
  input(data: string): void {
    try { bshTermInput(this.sid, data); } catch (e) { /* ignore */ }
  }

  resize(cols: number, rows: number): void {
    this.cols = cols;
    this.rows = rows;
    // 同步给 native:vim 等经 TIOCGWINSZ 查询实际网格
    try { bshTermResize(this.sid, cols, rows); } catch (e) { /* ignore */ }
  }

  /* 终端外观：设置面板改了 AppStorage 就跟着改 xterm.js。页面就绪前的改动
   * 由 onPageEnd 里那次统一补上（这里 termReady 为假时直接跳过）。 */
  private applyFontSize(): void {
    if (!this.termReady) return;
    try { this.webviewController.runJavaScript('window.setTermFontSize(' + this.termFontSize + ')'); } catch (e) { /* ignore */ }
  }

  private applyFontFamily(): void {
    if (!this.termReady) return;
    try { this.webviewController.runJavaScript('window.setTermFontFamily(' + JSON.stringify(this.termFontFamily) + ')'); } catch (e) { /* ignore */ }
  }

  private applyCursorStyle(): void {
    if (!this.termReady) return;
    try { this.webviewController.runJavaScript('window.setTermCursorStyle(' + JSON.stringify(this.termCursorShape) + ')'); } catch (e) { /* ignore */ }
  }

  private applyCursorBlink(): void {
    if (!this.termReady) return;
    try { this.webviewController.runJavaScript('window.setTermCursorBlink(' + (this.termCursorBlink ? 'true' : 'false') + ')'); } catch (e) { /* ignore */ }
  }
}
