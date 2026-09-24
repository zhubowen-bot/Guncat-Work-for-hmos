// LLMProtocol: 三协议统一元数据与端点解析(纯逻辑, 无 HarmonyOS 依赖)
// 单一事实源: provider → 协议 → 请求端点, 供 AgentLoopService/ChatService 共用。
import { Constants } from './Constants.ts';

export class LLMProtocol {
  static readonly COMPLETIONS: string = 'completions';
  static readonly RESPONSES: string = 'responses';
  static readonly ANTHROPIC: string = 'anthropic';

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
