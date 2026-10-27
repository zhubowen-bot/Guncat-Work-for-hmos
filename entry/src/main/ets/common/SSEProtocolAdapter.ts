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
  // 协议级终止事件(finish_reason / message_stop / response.completed / [DONE])。
  // 没有它 = 流被网络/代理截断, 调用方不能把半截回答当成正常结束(安卓版踩过的坑:
  // 200 + dataEnd 就当成功, 半截正文被当成最终回答, 任务"安静地停住")。
  onComplete: () => void = () => {};
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
  extractComplete: (sseData: string) => boolean = () => false;
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
    if (this.extractComplete(sseData)) {
      ctx.onComplete();
    }
  }

  // ===== 协议终止事件解析(纯逻辑, 三协议共用) =====
  // 流式请求只有收到它才算完整结束; 缺了它 = 连接被网络/代理掐断,
  // 调用方必须按 transport 错误重试, 不能把半截正文当成最终回答。
  //   openai-completions: choices[0].finish_reason 非空(或 [DONE], 由读流方判定)
  //   anthropic-messages: message_stop, 或 message_delta.delta.stop_reason 非空
  //   openai-responses:   response.completed / response.incomplete
  static detectComplete(protocol: string, sseData: string): boolean {
    try {
      if (protocol === 'responses') {
        return sseData.indexOf('"response.completed"') >= 0 ||
          sseData.indexOf('"response.incomplete"') >= 0;
      }
      if (protocol === 'anthropic') {
        if (sseData.indexOf('"message_stop"') >= 0) {
          return true;
        }
        // 部分兼容网关不发 message_stop, 只发带 stop_reason 的 message_delta
        if (sseData.indexOf('"stop_reason"') < 0) {
          return false;
        }
        let json: Object = JSON.parse(sseData);
        if (typeof json !== 'object' || json === null) {
          return false;
        }
        let delta: Object = (json as Record<string, Object>)['delta'];
        if (typeof delta !== 'object' || delta === null) {
          return false;
        }
        let stop: Object = (delta as Record<string, Object>)['stop_reason'];
        return typeof stop === 'string' && (stop as string) !== '';
      }
      // completions: 最后一块带非空 finish_reason
      if (sseData.indexOf('finish_reason') < 0) {
        return false;
      }
      let json2: Object = JSON.parse(sseData);
      if (typeof json2 !== 'object' || json2 === null) {
        return false;
      }
      let choices: Object = (json2 as Record<string, Object>)['choices'];
      if (choices === undefined || !(choices instanceof Array)) {
        return false;
      }
      let list: Object[] = choices as Object[];
      if (list.length === 0) {
        return false;
      }
      let first: Object = list[0];
      if (typeof first !== 'object' || first === null) {
        return false;
      }
      let finish: Object = (first as Record<string, Object>)['finish_reason'];
      return typeof finish === 'string' && (finish as string) !== '';
    } catch (e) {
      return false;
    }
  }
}
