// LoopMetrics: Agent Loop 评估指标(纯逻辑, 无 HarmonyOS 依赖)
// 跟踪: 轮数/工具调用/成功/失败/schema 错误/超时/取消/无效步(无工具调用轮)/
// 子代理调用; 计算比率便于随 turn_end 写入会话日志做质量回归。
export class LoopMetricsSnapshot {
  steps: number = 0;
  toolCalls: number = 0;
  toolSuccesses: number = 0;
  toolFailures: number = 0;
  schemaErrors: number = 0;
  timeouts: number = 0;
  cancellations: number = 0;
  invalidSteps: number = 0;
  subagentCalls: number = 0;
  retries: number = 0;
  compactions: number = 0;
  maxTokens: number = 0;
  successRate: number = 0;
  schemaErrorRate: number = 0;
  timeoutRate: number = 0;
  cancelRate: number = 0;
  invalidStepRate: number = 0;
}

export class LoopMetrics {
  private steps: number = 0;
  private toolCalls: number = 0;
  private toolSuccesses: number = 0;
  private toolFailures: number = 0;
  private schemaErrors: number = 0;
  private timeouts: number = 0;
  private cancellations: number = 0;
  private invalidSteps: number = 0;
  private subagentCalls: number = 0;
  private retries: number = 0;
  private compactions: number = 0;
  private maxTokens: number = 0;

  // 每轮结束时记录; hadToolCall=false 表示该轮无工具调用(无效步)
  recordTurn(hadToolCall: boolean): void {
    this.steps++;
    if (!hadToolCall) {
      this.invalidSteps++;
    }
  }

  // 每个工具执行完记录一次
  recordToolCall(ok: boolean, timeout: boolean, cancelled: boolean, schemaError: boolean): void {
    this.toolCalls++;
    if (ok) {
      this.toolSuccesses++;
    } else {
      this.toolFailures++;
    }
    if (timeout) {
      this.timeouts++;
    }
    if (cancelled) {
      this.cancellations++;
    }
    if (schemaError) {
      this.schemaErrors++;
    }
  }

  recordSubagentCall(): void {
    this.subagentCalls++;
  }

  // 请求级自动重试一次
  recordRetry(): void {
    this.retries++;
  }

  // 上下文压缩执行一次(含强制压缩)
  recordCompaction(): void {
    this.compactions++;
  }

  // 单轮以 max_tokens 收尾一次
  recordMaxTokens(): void {
    this.maxTokens++;
  }

  // 兜底记录 schema 错误(如 chat 模式本地工具校验失败)
  recordSchemaError(): void {
    this.schemaErrors++;
  }

  snapshot(): LoopMetricsSnapshot {
    let s: LoopMetricsSnapshot = new LoopMetricsSnapshot();
    s.steps = this.steps;
    s.toolCalls = this.toolCalls;
    s.toolSuccesses = this.toolSuccesses;
    s.toolFailures = this.toolFailures;
    s.schemaErrors = this.schemaErrors;
    s.timeouts = this.timeouts;
    s.cancellations = this.cancellations;
    s.invalidSteps = this.invalidSteps;
    s.subagentCalls = this.subagentCalls;
    s.retries = this.retries;
    s.compactions = this.compactions;
    s.maxTokens = this.maxTokens;
    s.successRate = LoopMetrics.rate(this.toolSuccesses, this.toolCalls);
    s.schemaErrorRate = LoopMetrics.rate(this.schemaErrors, this.toolCalls);
    s.timeoutRate = LoopMetrics.rate(this.timeouts, this.toolCalls);
    s.cancelRate = LoopMetrics.rate(this.cancellations, this.toolCalls);
    s.invalidStepRate = LoopMetrics.rate(this.invalidSteps, this.steps);
    return s;
  }

  reset(): void {
    this.steps = 0;
    this.toolCalls = 0;
    this.toolSuccesses = 0;
    this.toolFailures = 0;
    this.schemaErrors = 0;
    this.timeouts = 0;
    this.cancellations = 0;
    this.invalidSteps = 0;
    this.subagentCalls = 0;
    this.retries = 0;
    this.compactions = 0;
    this.maxTokens = 0;
  }

  private static rate(part: number, total: number): number {
    if (total <= 0) {
      return 0;
    }
    return Math.round(part * 10000 / total) / 100;
  }
}
