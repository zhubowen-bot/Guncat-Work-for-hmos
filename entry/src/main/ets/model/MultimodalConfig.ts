// 多模态配置 (默认使用智谱 GLM-4.6V-Flash)
import { Constants } from '../common/Constants';

export class MultimodalConfig {
  baseUrl: string = '';
  apiKey: string = '';
  model: string = '';
  // 附件先行解析: 现在模型普遍原生支持多模态, 该选项默认关闭
  preparseEnabled: boolean = false;
  // 用户是否在设置里显式切换过该开关. 旧存档没有此字段, 读取时忽略历史值,
  // 统一回落为关闭 (清除"上次打开过"的记忆), 除非用户再次手动打开.
  preparseUserSet: boolean = false;

  static default(): MultimodalConfig {
    let cfg: MultimodalConfig = new MultimodalConfig();
    cfg.baseUrl = Constants.DEFAULT_MM_BASE_URL;
    cfg.apiKey = '';
    cfg.model = Constants.DEFAULT_MM_MODEL;
    cfg.preparseEnabled = false;
    cfg.preparseUserSet = false;
    return cfg;
  }

  static fromJson(json: Record<string, Object>): MultimodalConfig {
    let cfg: MultimodalConfig = MultimodalConfig.default();
    if (json['baseUrl'] !== undefined) {
      cfg.baseUrl = json['baseUrl'] as string;
    }
    if (json['apiKey'] !== undefined) {
      cfg.apiKey = json['apiKey'] as string;
    }
    if (json['model'] !== undefined) {
      cfg.model = json['model'] as string;
    }
    if (json['preparseUserSet'] !== undefined) {
      cfg.preparseUserSet = json['preparseUserSet'] as boolean;
    }
    // 只有用户显式设置过开关才恢复其选择; 旧存档里的 preparseEnabled 一律忽略
    if (cfg.preparseUserSet && json['preparseEnabled'] !== undefined) {
      cfg.preparseEnabled = json['preparseEnabled'] as boolean;
    }
    return cfg;
  }

  toJson(): Record<string, Object> {
    return {
      'baseUrl': this.baseUrl,
      'apiKey': this.apiKey,
      'model': this.model,
      'preparseEnabled': this.preparseEnabled,
      'preparseUserSet': this.preparseUserSet
    };
  }
}
