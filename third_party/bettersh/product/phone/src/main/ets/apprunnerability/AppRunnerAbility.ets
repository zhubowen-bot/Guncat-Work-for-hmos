import { AppRunnerAbility as BaseAppRunnerAbility } from 'bsh_main';
import { AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'BSH_ARA';

export default class AppRunnerAbility extends BaseAppRunnerAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'product module = phone');
    super.onCreate(want, launchParam);
  }
}
