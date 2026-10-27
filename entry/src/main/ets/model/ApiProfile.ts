import { ApiConfig } from './ApiConfig';
import { MultimodalConfig } from './MultimodalConfig';

export class ApiProfile {
  // 预置方案使用固定 ID: 启动时只补齐缺失项, 已存在(用户改过/填过 Key)的不覆盖。
  static readonly PRESET_DEEPSEEK_ID: string = 'api-profile-preset-deepseek';
  static readonly PRESET_OPENCODE_GO_ID: string = 'api-profile-preset-opencode-go';

  id: string = '';
  name: string = '';
  // 内置方案(默认配置 / 预置方案): 不允许删除; 用户自己新建的配置才可删
  builtin: boolean = false;
  apiConfig: ApiConfig = ApiConfig.default();
  multimodalConfig: MultimodalConfig = MultimodalConfig.default();

  static create(name: string): ApiProfile {
    let profile: ApiProfile = new ApiProfile();
    profile.id = `api-profile-${Date.now()}`;
    profile.name = name;
    return profile;
  }

  // 预置方案一: Deepseek(Anthropic Messages), 只预留 deepseek-flash
  static deepseekPreset(): ApiProfile {
    let profile: ApiProfile = new ApiProfile();
    profile.id = ApiProfile.PRESET_DEEPSEEK_ID;
    profile.name = 'Deepseek';
    profile.builtin = true;
    let cfg: ApiConfig = new ApiConfig();
    cfg.provider = 'anthropic-messages';
    // 主域名, 下发时按 Anthropic 协议自动补 /anthropic/v1/messages
    cfg.baseUrl = 'https://api.deepseek.com';
    cfg.model = 'deepseek-flash';
    cfg.models = ['deepseek-flash'];
    profile.apiConfig = cfg;
    return profile;
  }

  // 预置方案二: Opencode Go(Anthropic Messages), 只预留 deepseek-v4.1-flash
  static openCodeGoPreset(): ApiProfile {
    let profile: ApiProfile = new ApiProfile();
    profile.id = ApiProfile.PRESET_OPENCODE_GO_ID;
    profile.name = 'Opencode Go';
    profile.builtin = true;
    let cfg: ApiConfig = new ApiConfig();
    cfg.provider = 'anthropic-messages';
    // 下发时补 /v1/messages → https://opencode.ai/inference/go/anthropic/v1/messages
    cfg.baseUrl = 'https://opencode.ai/inference/go/anthropic';
    cfg.model = 'deepseek-v4.1-flash';
    cfg.models = ['deepseek-v4.1-flash'];
    profile.apiConfig = cfg;
    return profile;
  }

  static fromLegacy(name: string, apiConfig: ApiConfig, multimodalConfig: MultimodalConfig,
    builtin: boolean): ApiProfile {
    let profile: ApiProfile = ApiProfile.create(name);
    profile.builtin = builtin;
    profile.apiConfig = apiConfig;
    profile.multimodalConfig = multimodalConfig;
    return profile;
  }

  static fromJson(json: Record<string, Object>): ApiProfile {
    let profile: ApiProfile = new ApiProfile();
    profile.id = (json['id'] as string) ?? '';
    profile.name = (json['name'] as string) ?? '默认配置';
    // 存档里有标记就按标记; 老存档里的默认配置/预置方案没有标记, 用名称与固定 ID 兜底
    profile.builtin = (json['builtin'] as boolean) === true || profile.name === '默认配置' ||
      profile.id === ApiProfile.PRESET_DEEPSEEK_ID || profile.id === ApiProfile.PRESET_OPENCODE_GO_ID;
    let api: Object = json['apiConfig'];
    if (api !== undefined && api !== null) {
      profile.apiConfig = ApiConfig.fromJson(api as Record<string, Object>);
    }
    let multimodal: Object = json['multimodalConfig'];
    if (multimodal !== undefined && multimodal !== null) {
      profile.multimodalConfig = MultimodalConfig.fromJson(multimodal as Record<string, Object>);
    }
    if (profile.id === '') {
      profile.id = `api-profile-${Date.now()}`;
    }
    return profile;
  }

  toJson(): Record<string, Object> {
    return {
      'id': this.id,
      'name': this.name,
      'builtin': this.builtin,
      'apiConfig': this.apiConfig.toJson(),
      'multimodalConfig': this.multimodalConfig.toJson()
    };
  }

  static hasProfileId(profiles: ApiProfile[], profileId: string): boolean {
    for (let i: number = 0; i < profiles.length; i++) {
      if (profiles[i].id === profileId) {
        return true;
      }
    }
    return false;
  }

  // 旧版直接把 DeepSeek 主域名填成 Base URL 的方案: 合并进预置后按预置的 Anthropic Messages 接入。
  static isLegacyDeepseekProfile(profile: ApiProfile): boolean {
    let base: string = profile.apiConfig.baseUrl.trim().toLowerCase();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base === 'https://api.deepseek.com' || base === 'http://api.deepseek.com' ||
      base === 'https://api.deepseek.com/anthropic' || base === 'http://api.deepseek.com/anthropic';
  }

  // 把旧方案里用户已经填好的 Key / 模型 / 参数并入预置(预置自身已有的值优先)。
  // makeCurrent: 旧方案正是当前选中的那套时, 保留它正在用的模型, 避免升级后悄悄换模型。
  private static mergeInto(preset: ApiProfile, legacy: ApiProfile, makeCurrent: boolean): void {
    let target: ApiConfig = preset.apiConfig;
    let source: ApiConfig = legacy.apiConfig;
    if (target.apiKey.trim() === '') {
      target.apiKey = source.apiKey;
    }
    target.models = ApiConfig.mergeModels(target.modelList(), source.modelList());
    if (makeCurrent && source.model.trim() !== '') {
      target.model = source.model.trim();
    } else if (target.model.trim() === '') {
      target.model = source.model.trim();
    }
    if (target.extraBody === '' && source.extraBody !== '') {
      target.extraBody = source.extraBody;
    }
    if (target.temperature === null) {
      target.temperature = source.temperature;
    }
    if (target.topP === null) {
      target.topP = source.topP;
    }
    if (target.maxTokens === null) {
      target.maxTokens = source.maxTokens;
    }
    // 旧配置显式关掉路径补全时保持关闭(直连自定义路径的网关)
    if (target.autoSuffix && !source.autoSuffix) {
      target.autoSuffix = false;
    }
    if (preset.multimodalConfig.apiKey === '' && legacy.multimodalConfig.apiKey !== '') {
      preset.multimodalConfig = legacy.multimodalConfig;
    }
  }

  // 启动时补齐预置方案, 并把旧的 DeepSeek 主域名方案合并进 Deepseek 预置。
  // currentProfileId: 当前选中的方案 ID(被合并时把它的模型也带过来)。
  // 返回: 本次有改动时返回 Deepseek 预置 ID(调用方据此落盘并修正当前选中项); 无改动返回 ''。
  static ensurePresetProfiles(profiles: ApiProfile[], currentProfileId: string): string {
    let created: boolean = false;
    if (!ApiProfile.hasProfileId(profiles, ApiProfile.PRESET_DEEPSEEK_ID)) {
      profiles.push(ApiProfile.deepseekPreset());
      created = true;
    }
    if (!ApiProfile.hasProfileId(profiles, ApiProfile.PRESET_OPENCODE_GO_ID)) {
      profiles.push(ApiProfile.openCodeGoPreset());
      created = true;
    }
    if (!created) {
      return '';
    }
    let preset: ApiProfile | null = null;
    for (let i: number = 0; i < profiles.length; i++) {
      if (profiles[i].id === ApiProfile.PRESET_DEEPSEEK_ID) {
        preset = profiles[i];
        break;
      }
    }
    if (preset === null) {
      return '';
    }
    let kept: ApiProfile[] = [];
    let merged: boolean = false;
    for (let i: number = 0; i < profiles.length; i++) {
      let profile: ApiProfile = profiles[i];
      if (profile.id !== ApiProfile.PRESET_DEEPSEEK_ID && ApiProfile.isLegacyDeepseekProfile(profile)) {
        ApiProfile.mergeInto(preset, profile, profile.id === currentProfileId);
        merged = true;
      } else {
        kept.push(profile);
      }
    }
    if (merged) {
      profiles.splice(0, profiles.length);
      for (let i: number = 0; i < kept.length; i++) {
        profiles.push(kept[i]);
      }
    }
    return ApiProfile.PRESET_DEEPSEEK_ID;
  }
}
