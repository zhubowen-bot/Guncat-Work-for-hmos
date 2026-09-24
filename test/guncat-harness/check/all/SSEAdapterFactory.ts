// SSEAdapterFactory: 工作模式/聊天模式共用的协议 SSE 适配器工厂
// 把 ChatService 的解析器与 ToolCallStream 的收集器注入统一流水线,
// 避免 AgentLoopService 与 ChatService 各写一套 buildSseAdapter。
import { SSEProtocolAdapter } from './SSEProtocolAdapter.ts';
import { ToolCallAccumulator, collectCompletionsToolDelta, collectResponsesToolItem,
  collectAnthropicToolEvent } from './ToolCallStream.ts';
import {
  extractChatCompletionsDelta, extractChatCompletionsReasoning, extractChatCompletionsUsage,
  extractResponsesDelta, extractResponsesReasoning, extractResponsesUsage, extractResponsesFailure,
  extractAnthropicDelta, extractAnthropicReasoning, extractAnthropicUsage, extractAnthropicFailure,
  extractAnthropicSignature, extractAnthropicRedactedThinking
} from './ChatService.ts';

export class SSEAdapterFactory {
  // 是否支持该协议标识(openai-completions / openai-responses / anthropic-messages)
  static supports(protocol: string): boolean {
    return protocol === 'openai' || protocol === 'responses' || protocol === 'anthropic';
  }

  static build(protocol: string, callAcc: ToolCallAccumulator,
    finishExtractor: ((protocol: string, sseData: string) => string) | null = null): SSEProtocolAdapter {
    let adapter: SSEProtocolAdapter = new SSEProtocolAdapter();
    adapter.protocol = protocol;
    adapter.extractFailure = (sseData: string): string => {
      if (protocol === 'responses') {
        return extractResponsesFailure(sseData);
      }
      if (protocol === 'anthropic') {
        return extractAnthropicFailure(sseData);
      }
      return '';
    };
    adapter.extractDelta = (sseData: string): string => {
      if (protocol === 'responses') {
        return extractResponsesDelta(sseData);
      }
      if (protocol === 'anthropic') {
        return extractAnthropicDelta(sseData);
      }
      return extractChatCompletionsDelta(sseData);
    };
    adapter.extractReasoning = (sseData: string): string => {
      if (protocol === 'responses') {
        return extractResponsesReasoning(sseData);
      }
      if (protocol === 'anthropic') {
        return extractAnthropicReasoning(sseData);
      }
      return extractChatCompletionsReasoning(sseData);
    };
    adapter.extractSignature = (sseData: string): string => {
      if (protocol === 'anthropic') {
        return extractAnthropicSignature(sseData);
      }
      return '';
    };
    adapter.extractRedactedThinking = (sseData: string): string => {
      if (protocol === 'anthropic') {
        return extractAnthropicRedactedThinking(sseData);
      }
      return '';
    };
    adapter.extractUsage = (sseData: string): Record<string, Object> | null => {
      if (protocol === 'responses') {
        return extractResponsesUsage(sseData);
      }
      if (protocol === 'anthropic') {
        return extractAnthropicUsage(sseData);
      }
      return extractChatCompletionsUsage(sseData);
    };
    adapter.collectToolEvent = (sseData: string): void => {
      if (protocol === 'responses') {
        collectResponsesToolItem(sseData, callAcc);
      } else if (protocol === 'anthropic') {
        collectAnthropicToolEvent(sseData, callAcc);
      } else {
        collectCompletionsToolDelta(sseData, callAcc);
      }
    };
    adapter.extractFinishReason = (sseData: string): string => {
      if (finishExtractor !== null) {
        return finishExtractor(protocol, sseData);
      }
      return '';
    };
    return adapter;
  }
}
