// LLMProtocol: 三协议统一元数据与端点解析(纯逻辑, 无 HarmonyOS 依赖)
// 单一事实源: provider → 协议 → 请求端点, 供 AgentLoopService/ChatService 共用。
import { Constants } from './Constants';

export class LLMProtocol {
  static readonly COMPLETIONS: string = 'completions';
  static readonly RESPONSES: string = 'responses';
  static readonly ANTHROPIC: string = 'anthropic';

  // Opencode Go 网关(https://opencode.ai/inference/go/...)要求每个请求都带
  // x-opencode-session: <稳定会话 ID>, 网关据此做路由与 prompt cache;
  // 其他服务商不认识这个头, 所以只在命中该网关时下发。
  static readonly OPENCODE_SESSION_HEADER: string = 'x-opencode-session';
  static readonly OPENCODE_GATEWAY_HOST: string = 'opencode.ai';
  private static sessionSeed: string = '';

  // 绑定当前对话: 同一对话内的所有请求复用同一个会话值(跨重启由对话 ID 保持稳定)
  static bindConversationSession(conversationId: string): void {
    if (conversationId !== '') {
      LLMProtocol.sessionSeed = conversationId;
    }
  }

  // 是否 Opencode 网关(Go 订阅沿用同一域名, 只是 Base URL 带 /go)
  static isOpenCodeGateway(baseUrl: string): boolean {
    return baseUrl.trim().toLowerCase().indexOf(LLMProtocol.OPENCODE_GATEWAY_HOST) !== -1;
  }

  // 会话头取值: 有对话 ID 时用 ses_<对话ID>; 极端情况下还没绑定对话,
  // 生成一次进程内稳定的兜底值, 避免每次请求换 ID 打断缓存。
  static sessionHeaderValue(): string {
    if (LLMProtocol.sessionSeed === '') {
      LLMProtocol.sessionSeed = 'local_' + Date.now().toString();
    }
    return 'ses_' + LLMProtocol.sessionSeed;
  }

  // 补齐服务商要求的特殊请求头(目前只有 Opencode Go 的会话头)
  static applyProviderHeaders(baseUrl: string, headers: Record<string, string>): void {
    if (!LLMProtocol.isOpenCodeGateway(baseUrl)) {
      return;
    }
    headers[LLMProtocol.OPENCODE_SESSION_HEADER] = LLMProtocol.sessionHeaderValue();
  }

  // provider 字符串 → 协议: openai-responses→responses, anthropic-messages→anthropic, 其余→completions
  static pick(provider: string): string {
    if (provider === 'openai-responses') {
      return LLMProtocol.RESPONSES;
    }
    if (provider === 'anthropic-messages') {
      return LLMProtocol.ANTHROPIC;
    }
    return LLMProtocol.COMPLETIONS;
  }

  // 由 Base URL 推导最终请求端点(三协议共用)。
  // autoSuffix=false 时严格使用用户填写的地址(仅去首尾空白), 不做任何协议路径补全——
  // 用于非标准路径的自建网关/代理; 开启时按协议补全标准路径。
  static resolveEndpoint(baseUrl: string, protocol: string, autoSuffix: boolean): string {
    if (!autoSuffix) {
      return baseUrl.trim();
    }
    let base: string = baseUrl.replace(/\/+$/, '');
    if (protocol === LLMProtocol.RESPONSES) {
      return base + Constants.RESPONSES_PATH;
    }
    if (protocol === LLMProtocol.ANTHROPIC) {
      if (base.endsWith('/v1') || base.endsWith('/anthropic/v1')) {
        return base + Constants.MESSAGES_PATH;
      }
      if (base === 'https://api.deepseek.com' || base === 'http://api.deepseek.com') {
        // 兼容用户直接填 DeepSeek 主域名时自动切到 Anthropic 兼容端点
        return base + Constants.ANTHROPIC_DEEPSEEK_MESSAGES_PATH;
      }
      return base + Constants.ANTHROPIC_V1_MESSAGES_PATH;
    }
    return base + Constants.CHAT_COMPLETIONS_PATH;
  }

  static displayName(protocol: string): string {
    if (protocol === LLMProtocol.RESPONSES) {
      return 'OpenAI Responses';
    }
    if (protocol === LLMProtocol.ANTHROPIC) {
      return 'Anthropic Messages';
    }
    return 'OpenAI Chat Completions';
  }
}
