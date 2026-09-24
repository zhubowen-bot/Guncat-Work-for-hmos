// RetryAfterParser: HTTP Retry-After 响应头解析(纯逻辑, 无 HarmonyOS 依赖)
// 支持两种形态: 秒数("120")与 HTTP-date("Wed, 21 Oct 2015 07:28:00 GMT")。
export class RetryAfterParser {
  // 返回建议的延迟毫秒数; 无法解析返回 -1
  static parseMs(value: string, nowMs: number = Date.now()): number {
    let seconds: number = RetryAfterParser.parseSeconds(value, nowMs);
    if (seconds < 0) {
      return -1;
    }
    return seconds * 1000;
  }

  // 返回建议的延迟秒数; 无法解析返回 -1
  static parseSeconds(value: string, nowMs: number = Date.now()): number {
    if (value === null || value === undefined) {
      return -1;
    }
    let v: string = value.trim();
    if (v === '') {
      return -1;
    }
    // 秒数形态
    if (/^\d+$/.test(v)) {
      let sec: number = parseInt(v, 10);
      return isNaN(sec) ? -1 : sec;
    }
    // HTTP-date 形态: 延迟 = date - now
    let t: number = Date.parse(v);
    if (isNaN(t)) {
      return -1;
    }
    let delta: number = Math.round((t - nowMs) / 1000);
    return delta < 0 ? 0 : delta;
  }
}
