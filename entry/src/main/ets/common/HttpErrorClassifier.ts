// HttpErrorClassifier: HTTP 状态码 → 错误分类/文案(纯逻辑, 无 HarmonyOS 依赖, 可单测)。
//
// 分类直接决定"能不能自动重试": LoopError.isRetryableKind 只认
// rate_limit / server / transport / empty。所以 408/425(网关超时)必须归到 transport、
// 409(并发冲突)归到 server, 否则一次瞬时抖动就会被判成不可重试, 整个任务当场断掉。
// 这段映射以前分别写在 AgentLoopService 与 ChatService 里, 两处口径容易漂移;
// 现在统一在这里, 由 test-core 断言守着。
export class HttpErrorClassifier {
  static readonly KIND_AUTH: string = 'auth';
  static readonly KIND_RATE_LIMIT: string = 'rate_limit';
  static readonly KIND_TRANSPORT: string = 'transport';
  static readonly KIND_SERVER: string = 'server';
  static readonly KIND_HTTP: string = 'http';

  static kindForStatus(code: number): string {
    if (code === 401 || code === 403) {
      return HttpErrorClassifier.KIND_AUTH;
    }
    if (code === 429) {
      return HttpErrorClassifier.KIND_RATE_LIMIT;
    }
    // 408 请求超时 / 425 Too Early: 网关与连接层的瞬时问题, 和网络中断一样值得重试
    if (code === 408 || code === 425) {
      return HttpErrorClassifier.KIND_TRANSPORT;
    }
    // 409 冲突(网关并发/去重): 稍后重发通常就过
    if (code === 409) {
      return HttpErrorClassifier.KIND_SERVER;
    }
    if (code >= 500) {
      return HttpErrorClassifier.KIND_SERVER;
    }
    return HttpErrorClassifier.KIND_HTTP;
  }

  // 默认中文文案; 4xx 的细节由调用方补(响应体里通常有服务端说明)
  static messageForStatus(code: number): string {
    if (code === 401 || code === 403) {
      return 'API Key 无效或无权限，请检查设置';
    }
    if (code === 429) {
      return '请求过于频繁，请稍后再试';
    }
    if (code === 408 || code === 425) {
      return '请求超时 (' + code.toString() + ')';
    }
    if (code === 409) {
      return '请求冲突 (' + code.toString() + ')';
    }
    if (code >= 400 && code < 500) {
      return 'API 请求错误 (' + code.toString() + ')';
    }
    if (code >= 500) {
      return '服务器错误 (' + code.toString() + ')';
    }
    return '请求失败，状态码: ' + code.toString();
  }

  // 该状态码是否值得自动重试
  static isRetryableStatus(code: number): boolean {
    let kind: string = HttpErrorClassifier.kindForStatus(code);
    return kind === HttpErrorClassifier.KIND_RATE_LIMIT ||
      kind === HttpErrorClassifier.KIND_TRANSPORT ||
      kind === HttpErrorClassifier.KIND_SERVER;
  }
}
