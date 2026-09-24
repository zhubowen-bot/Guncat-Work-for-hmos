import { ApiConfig } from './ApiConfig';
import { MultimodalConfig } from './MultimodalConfig';

export class ApiProfile {
  id: string = '';
  name: string = '';
  apiConfig: ApiConfig = ApiConfig.default();
  multimodalConfig: MultimodalConfig = MultimodalConfig.default();

  static create(name: string): ApiProfile {
    let profile: ApiProfile = new ApiProfile();
    profile.id = `api-profile-${Date.now()}`;
    profile.name = name;
    return profile;
  }

  static fromLegacy(name: string, apiConfig: ApiConfig, multimodalConfig: MultimodalConfig): ApiProfile {
    let profile: ApiProfile = ApiProfile.create(name);
    profile.apiConfig = apiConfig;
    profile.multimodalConfig = multimodalConfig;
    return profile;
  }

  static fromJson(json: Record<string, Object>): ApiProfile {
    let profile: ApiProfile = new ApiProfile();
    profile.id = (json['id'] as string) ?? '';
    profile.name = (json['name'] as string) ?? '默认配置';
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
      'apiConfig': this.apiConfig.toJson(),
      'multimodalConfig': this.multimodalConfig.toJson()
    };
  }
}
