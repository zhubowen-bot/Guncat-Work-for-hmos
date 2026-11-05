// 用量统计统一按北京时间(UTC+8)切日/判峰谷:
// DeepSeek 的计费时段以服务端收到请求的北京时间为准, 不跟随设备时区。
// 这里全部用 UTC 方法手算, 避免 toLocaleString/timeZone 在端侧的实现差异与额外开销。

export const BEIJING_OFFSET_MS: number = 8 * 60 * 60 * 1000;

function pad2(v: number): string {
  return v < 10 ? '0' + v.toString() : v.toString();
}

export class UsageTime {
  static dayKey(ts: number): string {
    let d: Date = new Date(ts + BEIJING_OFFSET_MS);
    return d.getUTCFullYear().toString() + '-' + pad2(d.getUTCMonth() + 1) + '-' + pad2(d.getUTCDate());
  }

  // 北京时间小时键: YYYY-MM-DDTHH, 仅用于最近 5 小时/本周额度窗口
  static hourKey(ts: number): string {
    let d: Date = new Date(ts + BEIJING_OFFSET_MS);
    return UsageTime.dayKey(ts) + 'T' + pad2(d.getUTCHours());
  }

  static addHours(hourKey: string, delta: number): string {
    let day: string = hourKey.substring(0, 10);
    let hour: number = parseInt(hourKey.substring(11, 13), 10);
    let ts: number = UsageTime.dayStartMs(day) + hour * 60 * 60 * 1000 + delta * 60 * 60 * 1000;
    return UsageTime.hourKey(ts);
  }

  static todayKey(): string {
    return UsageTime.dayKey(Date.now());
  }

  static dayKeyFromParts(year: number, month: number, day: number): string {
    return year.toString() + '-' + pad2(month) + '-' + pad2(day);
  }

  static year(dayKey: string): number {
    return parseInt(dayKey.substring(0, 4), 10);
  }

  static month(dayKey: string): number {
    return parseInt(dayKey.substring(5, 7), 10);
  }

  static day(dayKey: string): number {
    return parseInt(dayKey.substring(8, 10), 10);
  }

  // 该日 00:00(北京时间)的毫秒时间戳
  static dayStartMs(dayKey: string): number {
    let y: number = UsageTime.year(dayKey);
    let m: number = UsageTime.month(dayKey);
    let d: number = UsageTime.day(dayKey);
    return Date.UTC(y, m - 1, d) - BEIJING_OFFSET_MS;
  }

  static addDays(dayKey: string, delta: number): string {
    let ms: number = UsageTime.dayStartMs(dayKey) + delta * 24 * 60 * 60 * 1000;
    return UsageTime.dayKey(ms);
  }

  static weekday(dayKey: string): number {
    // 0=周日 ... 6=周六
    return new Date(UsageTime.dayStartMs(dayKey) + BEIJING_OFFSET_MS).getUTCDay();
  }

  // 周一=0 ... 周日=6, 热力图按中国习惯从周一开始
  static mondayIndex(dayKey: string): number {
    return (UsageTime.weekday(dayKey) + 6) % 7;
  }

  static minutesOfDay(ts: number): number {
    let d: Date = new Date(ts + BEIJING_OFFSET_MS);
    return d.getUTCHours() * 60 + d.getUTCMinutes();
  }

  static daysBetween(startKey: string, endKey: string): number {
    let diff: number = UsageTime.dayStartMs(endKey) - UsageTime.dayStartMs(startKey);
    return Math.round(diff / (24 * 60 * 60 * 1000));
  }

  static monthLabel(dayKey: string): string {
    return (UsageTime.month(dayKey)).toString() + '月';
  }

  static shortDay(dayKey: string): string {
    return (UsageTime.month(dayKey)).toString() + '/' + (UsageTime.day(dayKey)).toString();
  }

  static fullDateLabel(dayKey: string): string {
    return UsageTime.year(dayKey).toString() + '年' + UsageTime.month(dayKey).toString() +
      '月' + UsageTime.day(dayKey).toString() + '日';
  }

  // 周一/周二/... 用于日详情
  static weekdayLabel(dayKey: string): string {
    let names: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return names[UsageTime.weekday(dayKey)];
  }
}
