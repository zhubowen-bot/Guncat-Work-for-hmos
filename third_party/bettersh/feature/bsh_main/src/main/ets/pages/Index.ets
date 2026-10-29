// pages/Index.ets — BetterSH 主终端
// 前端 xterm.js(term/index.html) ↔ native 软 pty + shell:
//   - 输出:master 读线程回调(bshTermStart 的 cb)→ termWrite 上屏
//   - 输入:xterm onData → hbridge.input → bshTermInput 写入 master;
//          虚拟键栏同样经 bshTermInput 写字节(CTRL 组合 a-z 转 \x01..\x1a)
//   - 尺寸:xterm fit → hbridge.resize → bshTermResize(供 vim 的 TIOCGWINSZ)
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { VKeyMetrics, getVKeyMetrics } from '../utils/bshKeys';
import { TerminalWindows } from '../service/TerminalWindows';
import { ImmersiveButtonModifier } from '../utils/ImmersiveButton';
import WebTerminal from '../components/WebTerminal'
import SettingsContent from '../components/SettingsContent';
import UserGuide from '../components/UserGuide';
import { CustomContentDialog } from '@kit.ArkUI';

/** bshutil 从 native 推来的设置事件(见 bshutil/ui_bus.h) */
interface UiEvent {
  op: string;
  show?: boolean;   // op=keys
  value?: number;   // op=scale
  name?: string;    // op=picker
  mode?: string;    // op=rightclick:"menu" | "smart"
  exec?: string;    // op=newtab:新窗口起来后要跑的命令(bshutil newtab -e)
  req?: number;     // 有值时表示这是"要回结果"的请求,处理完用 bshUiResolve(req, …) 回执
}

const TAG = 'BSH_Index';

@Component
export struct PcIndex {
  isPc: boolean = deviceInfo.deviceType === '2in1'
  private controller: webview.WebviewController = new webview.WebviewController();
  private cols: number = 80;
  private rows: number = 24;
  private termReady: boolean = false;
  private vkm: VKeyMetrics = getVKeyMetrics(deviceInfo.deviceType);
  private fontChoices: number[] = [12, 14, 16, 18, 20];
  @State rightClickMode: string = 'menu';

  @State showKeys: boolean = deviceInfo.deviceType !== '2in1';
  @State keysRecoverBar: boolean = true;
  @State fnPressed: boolean = false;
  @State ctrlPressed: boolean = false;
  @State termFontSize: number = 14;
  @State cursorBlinkOn: boolean = true;

  settingController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.Setting_title'),
      contentBuilder: () => {
        this.buildSettings();
      }
    }),
    // 2in1 窗口较宽，弹窗默认最大 400vp 过窄，按窗口比例放宽
    width: '60%'
  });
  userGuideController: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: $r('app.string.user_guide_title'),
      contentBuilder: () => {
        this.buildGuideList();
      }
    })
  });
  webController = new webview.WebviewController();
  immersiveButton: ImmersiveButtonModifier = new ImmersiveButtonModifier();

  aboutToAppear(): void {
    // 会话号的认领/归还在 WebTerminal（真正收发字节的那层，见它的 onPageEnd /
    // aboutToDisappear）。这里只做一件页面级的事：让"新开终端窗口"用**本窗口所属
    // Ability 的** context（startAbility 要一个活着的 context；主窗口关掉之后那个
    // 就没了，所以每次进来都刷一遍）。
    try {
      TerminalWindows.getInstance().init(getContext(this) as common.UIAbilityContext);
    } catch (e) { /* ignore */ }
    hilog.info(0x0000, TAG, 'terminal page ready');
  }

  build() {
    Column() {
      Row() {
        Row() {
          Image($r('app.media.startIcon'))
            .width(20)
          Text($r('app.string.EntryAbility_label'))
            .fontColor($r('sys.color.white'))
            .margin({ left: 10 })
        }

        Blank()

        Row() {
          Button({
            type: ButtonType.Normal,
            buttonStyle: ButtonStyleMode.TEXTUAL,
            controlSize: ControlSize.SMALL
          }) {
            Image($r('app.media.gearshape')).width(20)
          }
          .borderRadius(4)
          .padding(4)
          .margin({ right: 10 })
          .attributeModifier(this.immersiveButton)
          .onClick((event: ClickEvent) => {
            this.settingController.open();
          })

          Button({
            type: ButtonType.Normal,
            buttonStyle: ButtonStyleMode.TEXTUAL,
            controlSize: ControlSize.SMALL
          }) {
            SymbolGlyph($r('sys.symbol.book_pages'))
              .fontSize('20vp')
              .width(20)
              .height(20)
              .fontColor(['#ffffff'])
          }
          .borderRadius(4)
          .padding(4)
          .attributeModifier(this.immersiveButton)
          .onClick((event: ClickEvent) => {
            this.userGuideController.open();
          })
        }
      }
      .width('100%')
      .height(48)
      .padding({
        left: 15,
        right: 150,
      })

      WebTerminal({ virtKeyEnabled: false })
        .layoutWeight(1)
    }
    .width("100%")
    .height('100%')
  }

  @Builder
  buildGuideList() {
    UserGuide({
      openPage: (title: string | Resource, url: string) => {
        const controller = new CustomDialogController({
          builder: CustomContentDialog({
            primaryTitle: title,
            contentBuilder: () => {
              this.buildGuideWebView(url);
            }
          })
        })
        controller.open()
      }
    })
  }

  @Builder
  private buildGuideWebView(url: string) {
    Web({
      src: $rawfile(url),
      controller: this.webController
    }).javaScriptProxy({
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
        }`,
      object: this,
      name: 'native',
      methodList: [],
      controller: this.webController
    })
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.black'));
  }

  @Builder
  buildSettings() {
    SettingsContent()
  }
}

@Component
struct PhoneOrTablet {
  build() {
    Column() {
      WebTerminal({ virtKeyEnabled: true })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}

@Component
export struct Index {
  isPc: boolean = deviceInfo.deviceType === '2in1'

  aboutToAppear(): void {
    // webview.WebviewController.setWebDebuggingAccess(true)
  }

  build() {
    Column() {
      if (this.isPc) {
        PcIndex()
      } else {
        PhoneOrTablet()
      }
    }
    .width('100%')
    .height('100%')
  }
}
