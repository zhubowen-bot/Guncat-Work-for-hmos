// PersonalInstructionStore: 个性化指令的持久化。
//
// 数据量很小(每条最多 8000 字, 通常只有几条), 放在 Preferences 的一条 JSON 里,
// 不进会话存档文件, 也不参与流式热路径 —— 只在启动加载、设置页增删改时读写。
import { common } from '@kit.AbilityKit';
import { StorageManager } from '../data/StorageManager';
import { Constants } from '../common/Constants';
import { PersonalInstruction } from '../model/PersonalInstruction';

export class PersonalInstructionStore {
  static async load(context: common.UIAbilityContext): Promise<PersonalInstruction[]> {
    try {
      let raw: string = await StorageManager.loadString(
        context, Constants.LS_KEY_PERSONAL_INSTRUCTIONS, '');
      return PersonalInstruction.parseList(raw);
    } catch (e) {
      // 读取失败(权限/存储异常)按"没有个性化指令"处理, 不影响正常对话
    }
    return [];
  }

  static async save(context: common.UIAbilityContext,
    items: PersonalInstruction[]): Promise<void> {
    try {
      let values: Object[] = [];
      for (let i: number = 0; i < items.length; i++) {
        values.push(items[i].toJson());
      }
      await StorageManager.saveString(context, Constants.LS_KEY_PERSONAL_INSTRUCTIONS,
        JSON.stringify(values));
    } catch (e) {
      // 保存失败不打断编辑(下次修改或退出页面会再写一次)
    }
  }
}
