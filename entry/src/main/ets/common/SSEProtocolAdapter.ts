// SSEProtocolAdapter: 三协议 SSE 解析器适配器接口(纯逻辑, 无 HarmonyOS 依赖)
// 每个协议实现把 SSE 行解析为统一回调序列, AgentLoopService 不再在 handleSseLine
// 里写大 if/switch; 各协议的具体提取函数由调用方注入(保持 ChatService 解析器单一事实源)。
export class SSEParseContext {
  onFailure: (message: string) => boolean = () => false;
  onToken: (delta: string) => void = () => {};
  onReasoning: (text: string) => void = () => {};
  onSignature: (signature: string) => void = () => {};
  onRedactedThinking: (data: string) => void = () => {};
  onUsage: (usage: Record<string, Object> | null) => void = () => {};
  onToolEvent: (sseData: string) => void = () => {};
  onFinishReason: (finish: string) => void = () => {};
}

export class SSEProtocolAdapter {
  protocol: string = '';
  extractFailure: (sseData: string) => string = () => '';
  extractDelta: (sseData: string) => string = () => '';
  extractReasoning: (sseData: string) => string = () => '';
  extractSignature: (sseData: string) => string = () => '';
  extractRedactedThinking: (sseData: string) => string = () => '';
  extractUsage: (sseData: string) => Record<string, Object> | null = () => null;
  extractFinishReason: (sseData: string) => string = () => '';
  collectToolEvent: (sseData: string) => void = () => {};

  // 统一流水线: 失败优先(返回 true 表示已处理并停止); 其余按固定顺序派发
  handleLine(sseData: string, ctx: SSEParseContext): void {
    let failure: string = this.extractFailure(sseData);
    if (failure !== '') {
      if (ctx.onFailure(failure)) {
        return;
      }
    }
    let delta: string = this.extractDelta(sseData);
    if (delta !== '') {
      ctx.onToken(delta);
    }
    let reasoning: string = this.extractReasoning(sseData);
    if (reasoning !== '') {
      ctx.onReasoning(reasoning);
    }
    let signature: string = this.extractSignature(sseData);
    if (signature !== '') {
      ctx.onSignature(signature);
    }
    let redacted: string = this.extractRedactedThinking(sseData);
    if (redacted !== '') {
      ctx.onRedactedThinking(redacted);
    }
    let usage: Record<string, Object> | null = this.extractUsage(sseData);
    if (usage !== null) {
      ctx.onUsage(usage);
    }
    this.collectToolEvent(sseData);
    let finish: string = this.extractFinishReason(sseData);
    if (finish !== '') {
      ctx.onFinishReason(finish);
    }
  }
}
