// ToolRetryPolicy: 工具级重试策略(纯逻辑, 无 HarmonyOS 依赖)
// 网络相关工具(web_fetch/download_file/subagent)允许对瞬时失败做少量重试;
// 复用 RetryPolicy 的退避算法; schemaError/cancelled 一律不重试。
import { RetryPolicy } from './RetryPolicy';

export class ToolRetryDecision {
  shouldRetry: boolean = false;
  delayMs: number = 0;
  reason: string = '';
}

export class ToolRetryPolicy {
  private retryable: string[] = ['web_fetch', 'download_file', 'subagent'];
  private policy: RetryPolicy = new RetryPolicy(1, 600, 4000, 0.3,
    ['transport', 'server', 'timeout', 'empty']);
  private overrides: Record<string, number> = {};

  setMaxRetries(name: string, maxRetries: number): void {
    this.overrides[name] = maxRetries;
  }

  isRetryable(name: string): boolean {
    return this.retryable.indexOf(name) !== -1;
  }

  maxRetriesFor(name: string): number {
    let v: number | undefined = this.overrides[name];
    if (v !== undefined) {
      return v;
    }
    return this.policy.maxRetries;
  }

  // attempt 为已发生重试次数; retryAfterMs 尊重服务端; seed 控抖动(测试固定值)
  decide(name: string, attempt: number, timeoutHappened: boolean, isError: boolean,
    cancelled: boolean, schemaError: boolean,
    retryAfterMs: number = -1, seed: number = 0.5): ToolRetryDecision {
    let d: ToolRetryDecision = new ToolRetryDecision();
    if (!this.isRetryable(name) || cancelled || schemaError) {
      d.reason = cancelled ? 'cancelled' : (schemaError ? 'schema_error' : 'not_retryable');
      return d;
    }
    if (attempt >= this.maxRetriesFor(name)) {
      d.reason = 'max_retries';
      return d;
    }
    if (!timeoutHappened && !isError) {
      d.reason = 'ok';
      return d;
    }
    let kind: string = timeoutHappened ? 'timeout' : 'transport';
    let rd = this.policy.decide(kind, attempt, retryAfterMs, seed, this.maxRetriesFor(name));
    d.shouldRetry = rd.shouldRetry;
    d.delayMs = rd.delayMs;
    d.reason = rd.reason;
    return d;
  }
}
