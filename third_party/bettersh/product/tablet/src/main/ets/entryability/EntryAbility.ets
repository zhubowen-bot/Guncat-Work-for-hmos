// 薄 entry 的入口 Ability：实现在 feature/bsh_main(HAR)，这里只做一层子类 + 身份日志。
// 分包后 tablet/2in1 与 phone 走同一份实现，靠本文件打出包身份，便于真机排查"装的是哪个包"。
import { EntryAbility as BaseEntryAbility } from 'bsh_main';
import { AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'BSH_ENTRY';

export default class EntryAbility extends BaseEntryAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'product module = tablet');
    super.onCreate(want, launchParam);
  }
}
