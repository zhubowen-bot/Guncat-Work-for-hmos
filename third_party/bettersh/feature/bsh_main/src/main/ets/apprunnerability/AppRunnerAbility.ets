// AppRunnerAbility.ets — Wayland 客户端窗口的独立 Ability（multiton）
//
// 独立 Ability 实例，通过 startAbility 的 want.parameters
// 传入 toplevelId/title/尺寸，窗口由 stage.getMainWindowSync() 管理。
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WaymonyService } from '../service/WaymonyService';

const TAG = 'BSH_ARA';

export default class AppRunnerAbility extends UIAbility {
  private toplevelId: number = 0;
  private title: string = '';
  private w: number = 640;
  private h: number = 480;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const params: Record<string, Object> = (want.parameters ?? {}) as Record<string, Object>;
    this.toplevelId = Number(params.toplevelId ?? 0);
    this.title = (params.title as string) ?? '';
    this.w = Number(params.w ?? 640);
    this.h = Number(params.h ?? 480);
    hilog.info(0x0000, TAG, 'onCreate tl=%{public}d title=%{public}s %{public}dx%{public}d',
      this.toplevelId, this.title, this.w, this.h);
  }

  async onWindowStageCreate(stage: window.WindowStage): Promise<void> {
    hilog.info(0x0000, TAG, 'onWindowStageCreate tl=%{public}d', this.toplevelId);
    // 注册 toplevelId（ClientWindow 页面 aboutToAppear 取走；LocalStorage 传参在
    // loadContent 场景不可靠，见黑屏问题）
    WaymonyService.getInstance().setPendingToplevel(this.toplevelId);

    try {
      await stage.loadContent('pages/ClientWindow', null);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      return;
    }

    try {
      const mainWin: window.Window = stage.getMainWindowSync();
      if (this.title) {
        mainWin.setWindowTitle(this.title).catch((): void => { /* ignore */ });
      }
      // 注册到窗口管理器：resize/move/destroy 都由 Ability 窗口执行
      WaymonyService.getInstance().attachAbilityWindow(this.toplevelId, mainWin, this.context);
      hilog.info(0x0000, TAG, 'attached tl=%{public}d win=%{public}d',
        this.toplevelId, mainWin.getWindowProperties().id);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'window attach failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'onWindowStageDestroy tl=%{public}d', this.toplevelId);
    WaymonyService.getInstance().detachAbilityWindow(this.toplevelId);
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy tl=%{public}d', this.toplevelId);
  }
}
