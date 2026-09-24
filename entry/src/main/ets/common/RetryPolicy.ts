// RetryPolicy: 请求级自动重试纯决策(无 HarmonyOS 依赖, 可单测)
// 对齐 DeepSeek Harness llm-retry: rate_limit/server/transport/empty 可重试,
// auth/http/protocol 直接上抛; 指数退避 + jitter + retry-after 尊重。
export class RetryDecision {
  shouldRetry: boolean = false;
  delayMs: number = 0;
  reason: string = '';
}

export class RetryPolicy {
  maxRetries: number = 3;
  baseDelayMs: number = 500;
  maxDelayMs: number = 8000;
  jitterRatio: number = 0.2;
  retryableKinds: string[] = ['rate_limit', 'server', 'transport', 'empty'];

  constructor(maxRetries: number = 3, baseDelayMs: number = 500,
    maxDelayMs: number = 8000, jitterRatio: number = 0.2,
    retryableKinds: string[] = ['rate_limit', 'server', 'transport', 'empty']) {
    this.maxRetries = maxRetries;
    this.baseDelayMs = baseDelayMs;
    this.maxDelayMs = maxDelayMs;
    this.jitterRatio = jitterRatio;
    this.retryableKinds = retryableKinds.slice();
  }

  isRetryable(kind: string): boolean {
    return this.retryableKinds.indexOf(kind) !== -1;
  }

  // attempt 为已发生的重试次数(0 起); retryAfterMs >=0 时尊重服务端建议(封顶 maxDelayMs);
  // seed ∈ [0,1) 控制抖动(测试传固定值, 运行期用 Math.random)。
  // maxRetriesOverride 允许单次调用覆盖实例 maxRetries(供工具级策略复用)。
  decide(kind: string, attempt: number, retryAfterMs: number = -1, seed: number = 0.5,
    maxRetriesOverride: number = -1): RetryDecision {
    let d: RetryDecision = new RetryDecision();
    let max: number = maxRetriesOverride >= 0 ? maxRetriesOverride : this.maxRetries;
    if (attempt >= max) {
      d.reason = 'max_retries';
      return d;
    }
    if (!this.isRetryable(kind)) {
      d.reason = 'kind_not_retryable:' + kind;
      return d;
    }
    d.shouldRetry = true;
    if (retryAfterMs >= 0) {
      d.delayMs = Math.min(retryAfterMs, this.maxDelayMs);
      d.reason = 'retry_after';
      return d;
    }
    let base: number = this.baseDelayMs * Math.pow(2, attempt);
    base = Math.min(base, this.maxDelayMs);
    let jitter: number = base * this.jitterRatio * (seed * 2 - 1);
    d.delayMs = Math.max(0, Math.round(base + jitter));
    d.reason = 'backoff';
    return d;
  }
}
