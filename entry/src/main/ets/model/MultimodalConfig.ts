// 多模态配置 (默认使用智谱 GLM-4.6V-Flash)
import { Constants } from '../common/Constants';

export class MultimodalConfig {
  baseUrl: string = '';
  apiKey: string = '';
  model: string = '';
  preparseEnabled: boolean = true;

  static default(): MultimodalConfig {
    let cfg: MultimodalConfig = new MultimodalConfig();
    cfg.baseUrl = Constants.DEFAULT_MM_BASE_URL;
    cfg.apiKey = '';
    cfg.model = Constants.DEFAULT_MM_MODEL;
    cfg.preparseEnabled = true;
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
    if (json['preparseEnabled'] !== undefined) {
      cfg.preparseEnabled = json['preparseEnabled'] as boolean;
    }
    return cfg;
  }

  toJson(): Record<string, Object> {
    return {
      'baseUrl': this.baseUrl,
      'apiKey': this.apiKey,
      'model': this.model,
      'preparseEnabled': this.preparseEnabled
    };
  }
}
