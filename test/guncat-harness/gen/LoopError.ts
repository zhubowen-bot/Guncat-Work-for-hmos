// LoopError: Agent Loop 带分类错误(纯逻辑, 无 HarmonyOS 依赖)
// kind 用于请求级重试分类; retryable 为显式可重试声明(默认按 kind 推断)。
//   rate_limit/server/transport/empty → 默认可重试; auth/http/protocol → 默认不可重试。
export class LoopError extends Error {
  status: number = 0;
  kind: string = 'http';
  retryAfterMs: number = -1;
  userMessage: string = '';
  retryable: boolean = false;

  constructor(message: string, status: number, kind: string, retryAfterMs: number = -1,
    userMessage: string = '', retryable?: boolean) {
    super(message);
    this.name = 'LoopError';
    this.message = message;
    this.status = status;
    this.kind = kind;
    this.retryAfterMs = retryAfterMs;
    this.userMessage = userMessage !== '' ? userMessage : message;
    this.retryable = retryable === undefined ? LoopError.isRetryableKind(kind) : retryable;
  }

  static isRetryableKind(kind: string): boolean {
    return kind === 'rate_limit' || kind === 'server' ||
      kind === 'transport' || kind === 'empty';
  }

  static isRetryable(e: Error): boolean {
    if (e instanceof LoopError) {
      let le: LoopError = e as LoopError;
      return le.retryable;
    }
    return false;
  }

  // 上下文窗口超限(历史+工具放不进模型上下文): 由调用方压缩历史后重试
  isContextOverflow(): boolean {
    if (this.kind !== 'http' && this.kind !== 'protocol') {
      return false;
    }
    let msg: string = this.message !== undefined ? this.message : '';
    return /context|maximum|length|token|上下文|长度|太长/i.test(msg);
  }

  // 上下文溢出时的默认中文提示(供 UI/日志统一使用)
  contextOverflowMessage(): string {
    return '上下文窗口超限，已自动压缩历史后重试；若仍失败请缩小任务范围或清理历史消息。';
  }
}
