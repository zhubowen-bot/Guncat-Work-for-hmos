// HttpTimeouts: 与大请求体相关的 HTTP 超时口径(纯逻辑, 无 HarmonyOS 依赖, 可单测)。
//
// 为什么需要它(用户报障, 与安卓版同一个坑):
//   view_image 之后图片会以 base64 内联进下一条请求, 请求体可以到 10MB+。
//   端口代码里 `connectTimeout` 不是纯 TCP 建连超时 —— 它从请求开始计时, 到拿到响应头才撤销,
//   上传请求体也算在这段时间里。固定 30s 一到, 底层会在上传途中把请求掐断;
//   而请求级重试又会带着同一张图重发, 每次都卡在同一个 30s 上, 表现就是
//   「用了 view_image 之后一直重连不上」。
//
// 这里按请求体大小给上传留预算, 并把各种底层传输错误翻译成人话。
export class HttpTimeouts {
  // 请求体超过该大小时才增加上传预算; 小请求维持原来的 30s
  private static readonly BODY_SLOW_PATH_BYTES: number = 256 * 1024;
  // 上传预算按这个保守速率折算(手机上行常见 100KB/s 左右)
  private static readonly ASSUMED_UPLOAD_BYTES_PER_SECOND: number = 100 * 1024;
  // 上限: 再慢也不把一次请求拖过 3 分钟
  static readonly MAX_CONNECT_TIMEOUT_MS: number = 180000;
  static readonly BASE_CONNECT_TIMEOUT_MS: number = 30000;

  // 按请求体大小计算 connectTimeout: 基础 30s + 保守上传耗时, 封顶 180s; 小请求不受影响。
  static connectTimeoutForBody(body: string, baseMs: number = HttpTimeouts.BASE_CONNECT_TIMEOUT_MS): number {
    let bytes: number = body.length;
    if (bytes <= HttpTimeouts.BODY_SLOW_PATH_BYTES) {
      return baseMs;
    }
    let uploadMs: number = Math.ceil(
      (bytes / HttpTimeouts.ASSUMED_UPLOAD_BYTES_PER_SECOND) * 1000);
    return Math.min(HttpTimeouts.MAX_CONNECT_TIMEOUT_MS, baseMs + uploadMs);
  }

  // 把底层传输错误翻译成可读说明。
  // 用户主动停止走 abortSignal, 不会进到这里; 能到这里的 abort 基本都是本机超时。
  static describeTransportError(error: Error): string {
    let name: string = error.name !== undefined ? error.name : '';
    let message: string = error.message !== undefined ? error.message : '';
    let lower: string = message.toLowerCase();
    if (name === 'AbortError' || lower.indexOf('abort') >= 0 ||
      lower.indexOf('canceled') >= 0 || lower.indexOf('cancelled') >= 0) {
      return '请求在传输阶段被中止（网络慢或请求体过大）';
    }
    if (lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0 ||
      lower.indexOf('2300028') >= 0) {
      return '网络请求超时（网络慢或请求体过大）';
    }
    if (lower.indexOf('reset') >= 0 || lower.indexOf('broken pipe') >= 0 ||
      lower.indexOf('econnreset') >= 0 || lower.indexOf('unreachable') >= 0 ||
      lower.indexOf('dns') >= 0 || lower.indexOf('network') >= 0 ||
      lower.indexOf('socket') >= 0) {
      return '网络连接中断：' + message;
    }
    return message !== '' ? message : '网络请求失败';
  }

  // 该错误是否值得自动重试(纯文本判定, 供日志/兜底; 正常路径由 LoopError.kind 决定)
  static looksTransient(error: Error): boolean {
    let message: string = error.message !== undefined ? error.message : '';
    let lower: string = message.toLowerCase();
    return lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0 ||
      lower.indexOf('reset') >= 0 || lower.indexOf('broken pipe') >= 0 ||
      lower.indexOf('econnreset') >= 0 || lower.indexOf('unreachable') >= 0 ||
      lower.indexOf('network') >= 0 || lower.indexOf('socket') >= 0 ||
      (error.name !== undefined && error.name === 'AbortError');
  }
}
