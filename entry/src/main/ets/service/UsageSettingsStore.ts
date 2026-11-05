import { common } from '@kit.AbilityKit';
import { StorageManager } from '../data/StorageManager';
import { Constants } from '../common/Constants';
import { DeepSeekBalanceInfo, UsageSettings } from '../model/UsageModels';

// 用量页的小配置与余额快照都走 Preferences; 数据量很小, 不占用会话存档文件。
export class UsageSettingsStore {
  static async loadSettings(context: common.UIAbilityContext): Promise<UsageSettings> {
    try {
      let raw: string = await StorageManager.loadString(context, Constants.LS_KEY_USAGE_SETTINGS, '');
      if (raw === '') {
        return new UsageSettings();
      }
      let parsed: Object = JSON.parse(raw);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return UsageSettings.fromJson(parsed as Record<string, Object>);
      }
    } catch (e) {
      // 配置损坏回落默认值
    }
    return new UsageSettings();
  }

  static async saveSettings(context: common.UIAbilityContext, settings: UsageSettings): Promise<void> {
    try {
      await StorageManager.saveString(context, Constants.LS_KEY_USAGE_SETTINGS,
        JSON.stringify(settings.toJson()));
    } catch (e) {
      // 保存失败不影响统计
    }
  }

  static async loadBalance(context: common.UIAbilityContext): Promise<DeepSeekBalanceInfo | null> {
    try {
      let raw: string = await StorageManager.loadString(context, Constants.LS_KEY_USAGE_BALANCE, '');
      if (raw === '') {
        return null;
      }
      let parsed: Object = JSON.parse(raw);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return DeepSeekBalanceInfo.fromJson(parsed as Record<string, Object>);
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  static async saveBalance(context: common.UIAbilityContext, balance: DeepSeekBalanceInfo): Promise<void> {
    try {
      await StorageManager.saveString(context, Constants.LS_KEY_USAGE_BALANCE,
        JSON.stringify(balance.toJson()));
    } catch (e) {
      // ignore
    }
  }
}
