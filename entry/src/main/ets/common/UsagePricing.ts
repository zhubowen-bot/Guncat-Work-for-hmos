// 用量计价的纯逻辑: 价目表、DeepSeek 峰谷、中国法定节假日、服务商归类。
// 所有价格都是"估算"用途, 集中在这里方便随官方调价更新。

import {
  USAGE_BAND_OFFPEAK,
  USAGE_BAND_PEAK,
  USAGE_BAND_STANDARD,
  USAGE_PROVIDER_DEEPSEEK,
  USAGE_PROVIDER_OPENCODE,
  USAGE_PROVIDER_OTHER,
  UsageSnapshot
} from '../model/UsageModels';
import { UsageTime } from './UsageTime';

export class DeepSeekRate {
  hitCny: number = 0;
  missCny: number = 0;
  outputCny: number = 0;

  constructor(hitCny: number, missCny: number, outputCny: number) {
    this.hitCny = hitCny;
    this.missCny = missCny;
    this.outputCny = outputCny;
  }
}

export class UsagePricing {
  // 官方价格版本(仅用于界面标注, 不参与计算)
  static readonly PRICE_VERSION: string = '2026-11-05';
  // DeepSeek 服务端搜索/抓取: 5 元 / 1000 次成功请求
  static readonly DEEPSEEK_SEARCH_CNY: number = 0.005;

  // 2026/2027 中国法定节假日(只用于"工作日高峰时段"排除; 周末本来就按空闲时段)。
  // 来源: 国务院办公厅 2026/2027 年部分节假日安排通知。
  private static readonly CN_HOLIDAY_RANGES: string[][] = [
    ['2026-01-01', '2026-01-03'],
    ['2026-02-15', '2026-02-23'],
    ['2026-04-04', '2026-04-06'],
    ['2026-05-01', '2026-05-05'],
    ['2026-06-19', '2026-06-21'],
    ['2026-09-25', '2026-09-27'],
    ['2026-10-01', '2026-10-07'],
    ['2027-01-01', '2027-01-03'],
    ['2027-02-05', '2027-02-13'],
    ['2027-04-03', '2027-04-05'],
    ['2027-04-30', '2027-05-04'],
    ['2027-06-09', '2027-06-09'],
    ['2027-09-15', '2027-09-15'],
    ['2027-10-01', '2027-10-07']
  ];

  static classifyProvider(baseUrl: string, model: string): string {
    let base: string = baseUrl.trim().toLowerCase();
    if (base.indexOf('api.deepseek.com') >= 0) {
      return USAGE_PROVIDER_DEEPSEEK;
    }
    if (base.indexOf('opencode.ai') >= 0 && base.indexOf('/go') >= 0) {
      return USAGE_PROVIDER_OPENCODE;
    }
    // 自定义代理下如果模型名明确是 DeepSeek, 仍按 DeepSeek 计价;
    // Base URL 不是官方域名时价格可能不同, 界面会标注为估算。
    let m: string = model.trim().toLowerCase();
    if (m.indexOf('deepseek') >= 0 && base.indexOf('deepseek') >= 0) {
      return USAGE_PROVIDER_DEEPSEEK;
    }
    return USAGE_PROVIDER_OTHER;
  }

  static isCnHoliday(dayKey: string): boolean {
    for (let i: number = 0; i < UsagePricing.CN_HOLIDAY_RANGES.length; i++) {
      let range: string[] = UsagePricing.CN_HOLIDAY_RANGES[i];
      if (dayKey >= range[0] && dayKey <= range[1]) {
        return true;
      }
    }
    return false;
  }

  // DeepSeek 当前规则: 北京时间周一至周五 09:00-12:00、14:00-18:00 为高峰,
  // 其余时段(含周末、法定节假日全天)为空闲; 空闲价 = 高峰价的一半。
  // 计费时段以服务端收到请求的时间为准, 这里用请求开始时间近似。
  static isDeepSeekPeak(startedAt: number): boolean {
    let dayKey: string = UsageTime.dayKey(startedAt);
    let weekday: number = UsageTime.weekday(dayKey);
    if (weekday === 0 || weekday === 6) {
      return false;
    }
    if (UsagePricing.isCnHoliday(dayKey)) {
      return false;
    }
    let minutes: number = UsageTime.minutesOfDay(startedAt);
    let morning: boolean = minutes >= 9 * 60 && minutes < 12 * 60;
    let afternoon: boolean = minutes >= 14 * 60 && minutes < 18 * 60;
    return morning || afternoon;
  }

  static bandFor(provider: string, startedAt: number): string {
    if (provider === USAGE_PROVIDER_DEEPSEEK) {
      return UsagePricing.isDeepSeekPeak(startedAt) ? USAGE_BAND_PEAK : USAGE_BAND_OFFPEAK;
    }
    if (provider === USAGE_PROVIDER_OPENCODE) {
      return USAGE_BAND_STANDARD;
    }
    return USAGE_BAND_STANDARD;
  }

  static deepSeekRate(model: string, band: string): DeepSeekRate {
    let m: string = model.trim().toLowerCase();
    let pro: boolean = m.indexOf('pro') >= 0;
    let offPeak: boolean = band === USAGE_BAND_OFFPEAK;
    if (pro) {
      return offPeak ? new DeepSeekRate(0.15, 4.5, 13.5) : new DeepSeekRate(0.30, 9, 27);
    }
    // deepseek-flash / deepseek-v4.1-flash / 旧别名都按 Flash 价
    return offPeak ? new DeepSeekRate(0.02, 1, 4) : new DeepSeekRate(0.04, 2, 8);
  }

  // 在归一化后的快照上写入 DeepSeek 人民币成本。
  static applyDeepSeekPrice(snapshot: UsageSnapshot, model: string, band: string): void {
    let rate: DeepSeekRate = UsagePricing.deepSeekRate(model, band);
    let tokenCost: number = (snapshot.inputHit * rate.hitCny +
      snapshot.inputMiss * rate.missCny +
      snapshot.cacheWrite * rate.missCny +
      snapshot.output * rate.outputCny) / 1000000;
    // 只对明确的 web_search_requests 计费; tool_search 是服务端工具计数,
    // 官方未把它和 Fetch 计费一一对应, 避免一次搜索被重复计两次。
    let searchCost: number = snapshot.search * UsagePricing.DEEPSEEK_SEARCH_CNY;
    snapshot.costCny = tokenCost + searchCost;
  }

  static providerLabel(provider: string): string {
    if (provider === USAGE_PROVIDER_DEEPSEEK) {
      return 'DeepSeek';
    }
    if (provider === USAGE_PROVIDER_OPENCODE) {
      return 'OpenCode Go';
    }
    return '其他服务';
  }
}
