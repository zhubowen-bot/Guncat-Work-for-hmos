// UsageMeter: 逐请求采集 + 按日聚合的轻量用量账本。
//
// 性能约束(本文件的设计前提):
//  - 只在一次 API 响应结束时记一笔, 不参与 token 流;
//  - 内存里只保留最近 400 天的按日聚合, 不保存逐请求明细;
//  - 写盘 5 秒防抖, 切后台/退出时 flush; 单文件通常几十 KB;
//  - 任何异常静默吞掉, 统计失败不影响聊天主流程。

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ApiConfig } from '../model/ApiConfig';
import {
  USAGE_PROVIDER_DEEPSEEK,
  UsageCounters,
  UsageDay,
  UsageHour,
  UsageModelRow,
  UsageProviderRow,
  UsageSnapshot,
  UsageStore
} from '../model/UsageModels';
import { UsageNormalizer } from '../common/UsageNormalizer';
import { UsagePricing } from '../common/UsagePricing';
import { UsageTime } from '../common/UsageTime';

export class UsageMeter {
  private static readonly FILE_NAME: string = 'guncat_usage.json';
  private static readonly SAVE_DELAY_MS: number = 5000;
  private static readonly KEEP_DAYS: number = 400;

  private static context: common.UIAbilityContext | null = null;
  private static store: UsageStore = new UsageStore();
  private static loaded: boolean = false;
  private static saveTimer: number = -1;
  private static dirty: boolean = false;

  static init(context: common.UIAbilityContext): void {
    UsageMeter.context = context;
  }

  private static filePath(): string {
    if (UsageMeter.context === null) {
      return '';
    }
    return UsageMeter.context.filesDir + '/' + UsageMeter.FILE_NAME;
  }

  static ensureLoaded(): void {
    if (UsageMeter.loaded) {
      return;
    }
    let path: string = UsageMeter.filePath();
    if (path === '') {
      return;
    }
    UsageMeter.loaded = true;
    let readPath: string = path;
    try {
      // .tmp 只有在"准备提交"时才保留; 能解析就是最近一次完整账本, 优先采用,
      // 避免 rename 失败后下次启动回退到旧主文件。
      let tmpPath: string = path + '.tmp';
      if (fileIo.accessSync(tmpPath)) {
        try {
          let tmpText: string = fileIo.readTextSync(tmpPath);
          if (tmpText !== '') {
            let tmpParsed: Object = JSON.parse(tmpText);
            if (typeof tmpParsed === 'object' && tmpParsed !== null && !(tmpParsed instanceof Array)) {
              UsageMeter.store = UsageStore.fromJson(tmpParsed as Record<string, Object>);
              UsageMeter.prune();
              return;
            }
          }
        } catch (tmpError) {
          // 半截/损坏的 .tmp 继续尝试主文件
        }
      }
      if (!fileIo.accessSync(readPath)) {
        return;
      }
      let text: string = fileIo.readTextSync(readPath);
      if (text === '') {
        return;
      }
      let parsed: Object = JSON.parse(text);
      if (typeof parsed !== 'object' || parsed === null || parsed instanceof Array) {
        throw new Error('usage store is not an object');
      }
      UsageMeter.store = UsageStore.fromJson(parsed as Record<string, Object>);
      UsageMeter.prune();
    } catch (e) {
      // 主文件损坏时再试一次 .tmp(上次 rename 失败可能留下完整临时文件)
      if (readPath !== path + '.tmp') {
        try {
          let tmpText: string = fileIo.readTextSync(path + '.tmp');
          if (tmpText !== '') {
            let tmpParsed: Object = JSON.parse(tmpText);
            if (typeof tmpParsed === 'object' && tmpParsed !== null && !(tmpParsed instanceof Array)) {
              UsageMeter.store = UsageStore.fromJson(tmpParsed as Record<string, Object>);
              UsageMeter.prune();
              return;
            }
          }
        } catch (tmpError) {
          // 临时文件也不可用
        }
      }
      // 账本损坏不阻塞启动: 从空账本继续, 下次写盘覆盖
      UsageMeter.store = new UsageStore();
      UsageMeter.dirty = true;
    }
  }

  // 记录一笔请求。rawUsage 为 null 表示请求正常结束但网关没有返回 usage:
  // 只累计一次 missingUsage, 提醒用户统计可能偏低。
  static record(config: ApiConfig, protocol: string, rawUsage: Record<string, Object> | null,
    startedAt: number): UsageSnapshot {
    let snapshot: UsageSnapshot = UsageNormalizer.normalize(rawUsage, protocol);
    return UsageMeter.recordSnapshot(config, startedAt, snapshot);
  }

  // 已经归一化的快照直接入账(服务层流结束后调用, 避免重复解析原始 usage)。
  static recordSnapshot(config: ApiConfig, startedAt: number, snapshot: UsageSnapshot): UsageSnapshot {
    try {
      UsageMeter.ensureLoaded();
      let provider: string = UsagePricing.classifyProvider(config.baseUrl, config.model);
      let band: string = UsagePricing.bandFor(provider, startedAt);
      let model: string = config.model.trim() !== '' ? config.model.trim() : 'unknown';
      if (provider === USAGE_PROVIDER_DEEPSEEK) {
        UsagePricing.applyDeepSeekPrice(snapshot, model, band);
      }
      let dayKey: string = UsageTime.dayKey(startedAt);
      let hourKey: string = UsageTime.hourKey(startedAt);
      UsageMeter.store.add(dayKey, hourKey, provider, model, band, snapshot);
      UsageMeter.dirty = true;
      UsageMeter.scheduleSave();
    } catch (e) {
      // 统计是旁路, 失败不影响主流程
    }
    return snapshot;
  }

  static total(providerFilter: string): UsageCounters {
    UsageMeter.ensureLoaded();
    return UsageMeter.store.total(providerFilter);
  }

  static day(dayKey: string): UsageDay | null {
    UsageMeter.ensureLoaded();
    let d: UsageDay | undefined = UsageMeter.store.days[dayKey];
    return d !== undefined ? d : null;
  }

  static dayCounters(dayKey: string, providerFilter: string): UsageCounters {
    UsageMeter.ensureLoaded();
    let d: UsageDay | undefined = UsageMeter.store.days[dayKey];
    if (d === undefined) {
      return new UsageCounters();
    }
    return d.sum(providerFilter);
  }

  static providerRows(dayKey: string, providerFilter: string): UsageProviderRow[] {
    UsageMeter.ensureLoaded();
    let d: UsageDay | undefined = UsageMeter.store.days[dayKey];
    if (d === undefined) {
      return [];
    }
    return d.providerRows(providerFilter);
  }

  static dayBandCounters(dayKey: string, providerFilter: string, band: string): UsageCounters {
    UsageMeter.ensureLoaded();
    let d: UsageDay | undefined = UsageMeter.store.days[dayKey];
    if (d === undefined) {
      return new UsageCounters();
    }
    return d.sumBand(providerFilter, band);
  }

  static dayKeys(): string[] {
    UsageMeter.ensureLoaded();
    let keys: string[] = Object.keys(UsageMeter.store.days);
    keys.sort();
    return keys;
  }

  static modelRows(dayKey: string, provider: string): UsageModelRow[] {
    UsageMeter.ensureLoaded();
    let d: UsageDay | undefined = UsageMeter.store.days[dayKey];
    if (d === undefined) {
      return [];
    }
    let p = d.providers[provider];
    return p !== undefined ? p.rows() : [];
  }

  // 最近 N 天(含今天)的按日合计, 用于摘要卡
  static sumRecentDays(days: number, providerFilter: string): UsageCounters {
    UsageMeter.ensureLoaded();
    let out: UsageCounters = new UsageCounters();
    let today: string = UsageTime.todayKey();
    for (let i: number = 0; i < days; i++) {
      let key: string = UsageTime.addDays(today, -i);
      let d: UsageDay | undefined = UsageMeter.store.days[key];
      if (d !== undefined) {
        out.addCounters(d.sum(providerFilter));
      }
    }
    return out;
  }

  static sumMonth(monthPrefix: string, providerFilter: string): UsageCounters {
    UsageMeter.ensureLoaded();
    let out: UsageCounters = new UsageCounters();
    let keys: string[] = Object.keys(UsageMeter.store.days);
    for (let i: number = 0; i < keys.length; i++) {
      if (keys[i].substring(0, 7) !== monthPrefix) {
        continue;
      }
      out.addCounters(UsageMeter.store.days[keys[i]].sum(providerFilter));
    }
    return out;
  }

  // 最近 N 个自然小时(含当前小时)的额度, 用于 OpenCode 的 5 小时窗口。
  static sumRecentHours(hours: number, providerFilter: string): UsageCounters {
    UsageMeter.ensureLoaded();
    let out: UsageCounters = new UsageCounters();
    let current: string = UsageTime.hourKey(Date.now());
    for (let i: number = 0; i < hours; i++) {
      let key: string = UsageTime.addHours(current, -i);
      let h: UsageHour | undefined = UsageMeter.store.hours[key];
      if (h !== undefined) {
        out.addCounters(h.total(providerFilter));
      }
    }
    return out;
  }

  static clear(): void {
    UsageMeter.ensureLoaded();
    UsageMeter.store = new UsageStore();
    UsageMeter.dirty = true;
    UsageMeter.flush();
  }

  static flush(): void {
    if (UsageMeter.saveTimer !== -1) {
      clearTimeout(UsageMeter.saveTimer);
      UsageMeter.saveTimer = -1;
    }
    let path: string = UsageMeter.filePath();
    if (path === '' || !UsageMeter.loaded || !UsageMeter.dirty) {
      return;
    }
    try {
      UsageMeter.prune();
      let text: string = JSON.stringify(UsageMeter.store.toJson());
      let tmp: string = path + '.tmp';
      let file: fileIo.File = fileIo.openSync(tmp,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, text);
      } finally {
        fileIo.closeSync(file.fd);
      }
      UsageMeter.dirty = false;
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
        }
        fileIo.renameSync(tmp, path);
      } catch (e) {
        // rename 失败时把临时文件保留给下次启动恢复; 不过账本不是关键数据,
        // 下次启动若 .tmp 还在也可以直接读主文件, 这里只做尽力而为。
      }
    } catch (e) {
      // 写盘失败不影响聊天
    }
  }

  private static scheduleSave(): void {
    if (UsageMeter.saveTimer !== -1) {
      return;
    }
    UsageMeter.saveTimer = setTimeout((): void => {
      UsageMeter.saveTimer = -1;
      UsageMeter.flush();
    }, UsageMeter.SAVE_DELAY_MS);
  }

  private static prune(): void {
    let today: string = UsageTime.todayKey();
    let cutoff: string = UsageTime.addDays(today, -(UsageMeter.KEEP_DAYS - 1));
    let keys: string[] = Object.keys(UsageMeter.store.days);
    for (let i: number = 0; i < keys.length; i++) {
      if (keys[i] < cutoff) {
        delete UsageMeter.store.days[keys[i]];
      }
    }
    // 小时桶只服务最近 5 小时/本周窗口, 保留 8 天足够
    let hourCutoff: string = UsageTime.addDays(today, -8) + 'T00';
    let hkeys: string[] = Object.keys(UsageMeter.store.hours);
    for (let i: number = 0; i < hkeys.length; i++) {
      if (hkeys[i] < hourCutoff) {
        delete UsageMeter.store.hours[hkeys[i]];
      }
    }
  }
}
