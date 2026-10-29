// 薄 entry 的终端窗口 Ability：实现在 feature/bsh_main(HAR)，这里只做一层子类 +
// 身份日志（便于真机分辨装的是哪个包，与 AppRunnerAbility 同一个做法）。
import { TerminalRunnerAbility as BaseTerminalRunnerAbility } from 'bsh_main';
import { AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'BSH_TRA';

export default class TerminalRunnerAbility extends BaseTerminalRunnerAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'product module = tablet');
    super.onCreate(want, launchParam);
  }
}
