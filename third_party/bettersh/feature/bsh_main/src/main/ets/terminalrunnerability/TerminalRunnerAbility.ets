// TerminalRunnerAbility.ets — 新终端窗口的独立 Ability（multiton）
//
// 与 AppRunnerAbility（Wayland 客户端窗口）完全同构：每个 `bshutil newtab` 开出来的
// 终端窗口就是一个实例，加载**同一个** pages/Index，靠 want.parameters 里的
// sessionId 区分自己是谁、该在哪个会话上收发字节。
//
// 为什么不做成"主窗口里多开几个 Tab"：HarmonyOS 的 multiton Ability 是现成机制，
// 而应用内 Tab 要在同一个页面塞多份 ArkWeb/xterm，成本更高、还拿不到窗口级操作
// （拖动、最大化）。
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TerminalWindows } from '../service/TerminalWindows';

const TAG = 'BSH_TRA';

export default class TerminalRunnerAbility extends UIAbility {
  private sid: number = 0;
  private exec: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const params: Record<string, Object> = (want.parameters ?? {}) as Record<string, Object>;
    this.sid = Number(params.sessionId ?? 0);
    this.exec = (params.exec as string) ?? '';
    hilog.info(0x0000, TAG, 'onCreate sid=%{public}d exec=%{public}s',
      this.sid, this.exec ? 'yes' : 'no');
    // 登记给页面（aboutToAppear 取走即清）。与 WaymonyService.setPendingToplevel 同款：
    // loadContent 的 LocalStorage 传参在页面里读不可靠。
    TerminalWindows.getInstance().setPendingSession(this.sid, this.exec);
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    hilog.info(0x0000, TAG, 'onWindowStageCreate sid=%{public}d', this.sid);
    try {
      await stage.loadContent('pages/Index', null);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      return;
    }
    try {
      const mainWin: window.Window = stage.getMainWindowSync();
      mainWin.setWindowTitle(`BetterSH — Session ${this.sid}`).catch((): void => { /* ignore */ });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'set title failed: %{public}s', JSON.stringify(e));
    }

    // 临时，后续会调整为普通窗口。
    // const mainWindow = windowStage.getMainWindowSync();
    // const uiContext = mainWindow.getUIContext();
    // uiContext.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    // if (canIUse('SystemCapability.Window.SessionManager')
    //   && deviceInfo.deviceType === '2in1') {
    //   mainWindow.setWindowDecorVisible(false);
    //   mainWindow.setWindowDecorHeight(48);
    // }
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'onWindowStageDestroy sid=%{public}d', this.sid);
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy sid=%{public}d', this.sid);
  }
}
