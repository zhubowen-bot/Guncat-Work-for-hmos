// API 配置 (对齐 web 版本的 guncat_api_config 结构)
// 接入方式统一为三种主流协议：
//   openai-completions: OpenAI Chat Completions  /chat/completions
//   openai-responses:   OpenAI Responses         /responses（DeepSeek、火山方舟等兼容服务）
//   anthropic-messages: Anthropic Messages       /messages
export class ApiConfig {
  provider: string = 'openai-completions';
  baseUrl: string = '';
  apiKey: string = '';
  // 当前选中的模型(下发请求用它)
  model: string = '';
  // 同一套配置可填多个模型名称; 模型选择器按这里的顺序逐个列出, model 始终属于其中
  models: string[] = [];
  temperature: number | null = null;
  topP: number | null = null;
  maxTokens: number | null = null;
  extraBody: string = '';
  // 自动补全协议路径后缀(/chat/completions、/responses、/v1/messages 等)。
  // 关闭后严格按填写的 Base URL 发起请求, 适合非标准路径的自建网关/代理; 默认开启。
  autoSuffix: boolean = true;

  static default(): ApiConfig {
    return new ApiConfig();
  }

  static openAICompletionsPreset(): ApiConfig {
    let cfg: ApiConfig = new ApiConfig();
    cfg.provider = 'openai-completions';
    cfg.baseUrl = 'https://api.openai.com/v1';
    cfg.model = '';
    return cfg;
  }

  static openAIResponsesPreset(): ApiConfig {
    let cfg: ApiConfig = new ApiConfig();
    cfg.provider = 'openai-responses';
    cfg.baseUrl = 'https://api.openai.com/v1';
    cfg.model = '';
    return cfg;
  }

  static anthropicMessagesPreset(): ApiConfig {
    let cfg: ApiConfig = new ApiConfig();
    cfg.provider = 'anthropic-messages';
    cfg.baseUrl = 'https://api.anthropic.com/v1';
    cfg.model = '';
    return cfg;
  }

  // 归一化模型名列表: 去首尾空白、去空项、去重且保序;
  // current 非空但不在列表里时补到最前(旧存档只有单个 model 时靠它迁移成列表)。
  static normalizeModels(list: string[], current: string): string[] {
    let out: string[] = [];
    for (let i: number = 0; i < list.length; i++) {
      let name: string = list[i].trim();
      if (name === '' || out.indexOf(name) !== -1) {
        continue;
      }
      out.push(name);
    }
    let cur: string = current.trim();
    if (cur !== '' && out.indexOf(cur) === -1) {
      out.unshift(cur);
    }
    return out;
  }

  // 合并两组模型名(保序去重), 用于兼容合并旧配置
  static mergeModels(a: string[], b: string[]): string[] {
    return ApiConfig.normalizeModels(ApiConfig.normalizeModels(a, '').concat(b), '');
  }

  // 当前配置可选择的模型列表(至少包含 model, 保证选择器不会漏掉当前模型)
  modelList(): string[] {
    return ApiConfig.normalizeModels(this.models, this.model);
  }

  // 旧版本 provider 迁移：custom/deepseek/volcano 统一映射到三种协议。
  static normalizeProvider(provider: string): string {
    if (provider === 'custom' || provider === '') {
      return 'openai-completions';
    }
    if (provider === 'deepseek' || provider === 'volcano') {
      return 'openai-responses';
    }
    return provider;
  }

  static fromJson(json: Record<string, Object>): ApiConfig {
    let cfg: ApiConfig = new ApiConfig();
    cfg.provider = ApiConfig.normalizeProvider((json['provider'] as string) ?? '');
    cfg.baseUrl = (json['baseUrl'] as string) ?? '';
    cfg.apiKey = (json['apiKey'] as string) ?? '';
    cfg.model = (json['model'] as string) ?? '';
    // 旧存档没有 models 字段: 用单个 model 迁移成列表
    let rawModels: Object = json['models'];
    let modelNames: string[] = [];
    if (rawModels instanceof Array) {
      let arr: Object[] = rawModels as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          modelNames.push(arr[i] as string);
        }
      }
    }
    cfg.models = ApiConfig.normalizeModels(modelNames, cfg.model);
    if (cfg.model === '' && cfg.models.length > 0) {
      cfg.model = cfg.models[0];
    }
    cfg.extraBody = (json['extraBody'] as string) ?? '';
    // 旧存档无该字段时保持默认开启
    let suffix: Object = json['autoSuffix'];
    if (suffix !== undefined && suffix !== null) {
      cfg.autoSuffix = (suffix as boolean) === true;
    }
    let t: Object = json['temperature'];
    if (t !== undefined && t !== null) {
      cfg.temperature = t as number;
    }
    let p: Object = json['topP'];
    if (p !== undefined && p !== null) {
      cfg.topP = p as number;
    }
    let m: Object = json['maxTokens'];
    if (m !== undefined && m !== null) {
      cfg.maxTokens = m as number;
    }
    return cfg;
  }

  toJson(): Record<string, Object> {
    let result: Record<string, Object> = {
      'provider': this.provider,
      'baseUrl': this.baseUrl,
      'apiKey': this.apiKey,
      'model': this.model,
      'models': this.modelList(),
      'extraBody': this.extraBody,
      'autoSuffix': this.autoSuffix
    };
    if (this.temperature !== null) {
      result['temperature'] = this.temperature;
    }
    if (this.topP !== null) {
      result['topP'] = this.topP;
    }
    if (this.maxTokens !== null) {
      result['maxTokens'] = this.maxTokens;
    }
    return result;
  }
}
