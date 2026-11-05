// 用量统计的数据模型: 只保存"按日聚合"的轻量账本, 不保存逐请求明细。
// 目的: 热力图/成本估算这类旁路功能不能把会话存档或流式热路径拖慢。

export const USAGE_PROVIDER_DEEPSEEK: string = 'deepseek';
export const USAGE_PROVIDER_OPENCODE: string = 'opencode-go';
export const USAGE_PROVIDER_OTHER: string = 'other';

export const USAGE_BAND_PEAK: string = 'peak';
export const USAGE_BAND_OFFPEAK: string = 'offPeak';
export const USAGE_BAND_STANDARD: string = 'standard';

function readNumber(obj: Record<string, Object>, key: string): number {
  let v: Object | undefined = obj[key];
  if (typeof v === 'number') {
    return v as number;
  }
  return 0;
}

function readString(obj: Record<string, Object>, key: string): string {
  let v: Object | undefined = obj[key];
  if (typeof v === 'string') {
    return v as string;
  }
  return '';
}

// 单条请求归一化后的用量。所有字段都是扁平数字, 记录后不再持有原始 usage 对象。
export class UsageSnapshot {
  inputHit: number = 0;
  inputMiss: number = 0;
  output: number = 0;
  cacheWrite: number = 0;
  search: number = 0;
  fetch: number = 0;
  costCny: number = 0;
  costUsd: number = 0;
  allowanceUsd: number = 0;
  listCostUsd: number = 0;
  missingUsage: number = 0;
  billingSource: string = '';

  totalInput(): number {
    return this.inputHit + this.inputMiss + this.cacheWrite;
  }

  totalTokens(): number {
    return this.totalInput() + this.output;
  }

  mergeFrom(next: UsageSnapshot): void {
    // 流式响应可能先给 message_start(输入), 再给 message_delta(累计输出)。
    // 用 max 合并可以同时兼容"最终块给全量"和"最终块只给增量/只给输出"两种网关。
    this.inputHit = Math.max(this.inputHit, next.inputHit);
    this.inputMiss = Math.max(this.inputMiss, next.inputMiss);
    this.output = Math.max(this.output, next.output);
    this.cacheWrite = Math.max(this.cacheWrite, next.cacheWrite);
    this.search = Math.max(this.search, next.search);
    this.fetch = Math.max(this.fetch, next.fetch);
    this.costCny = Math.max(this.costCny, next.costCny);
    this.costUsd = Math.max(this.costUsd, next.costUsd);
    this.allowanceUsd = Math.max(this.allowanceUsd, next.allowanceUsd);
    this.listCostUsd = Math.max(this.listCostUsd, next.listCostUsd);
    this.missingUsage = Math.min(this.missingUsage, next.missingUsage);
    if (next.billingSource !== '') {
      this.billingSource = next.billingSource;
    }
  }
}

// 聚合计数器。同一天同一服务商同一模型同一计费时段共用一个实例。
export class UsageCounters {
  calls: number = 0;
  inputHit: number = 0;
  inputMiss: number = 0;
  output: number = 0;
  cacheWrite: number = 0;
  search: number = 0;
  fetch: number = 0;
  costCny: number = 0;
  costUsd: number = 0;
  allowanceUsd: number = 0;
  listCostUsd: number = 0;
  missingUsage: number = 0;

  addSnapshot(s: UsageSnapshot): void {
    this.calls += 1;
    this.inputHit += s.inputHit;
    this.inputMiss += s.inputMiss;
    this.output += s.output;
    this.cacheWrite += s.cacheWrite;
    this.search += s.search;
    this.fetch += s.fetch;
    this.costCny += s.costCny;
    this.costUsd += s.costUsd;
    this.allowanceUsd += s.allowanceUsd;
    this.listCostUsd += s.listCostUsd;
    this.missingUsage += s.missingUsage;
  }

  addCounters(other: UsageCounters): void {
    this.calls += other.calls;
    this.inputHit += other.inputHit;
    this.inputMiss += other.inputMiss;
    this.output += other.output;
    this.cacheWrite += other.cacheWrite;
    this.search += other.search;
    this.fetch += other.fetch;
    this.costCny += other.costCny;
    this.costUsd += other.costUsd;
    this.allowanceUsd += other.allowanceUsd;
    this.listCostUsd += other.listCostUsd;
    this.missingUsage += other.missingUsage;
  }

  totalInput(): number {
    return this.inputHit + this.inputMiss + this.cacheWrite;
  }

  totalTokens(): number {
    return this.totalInput() + this.output;
  }

  // DeepSeek 实付(人民币) + OpenCode 等价按量成本(美元→人民币)。
  // Go 套餐内 costUsd 为 0, 但 listCostUsd 有值, 用它保证两家可以放在同一张热力图比较。
  equivalentCostCny(fxRate: number): number {
    let usd: number = this.costUsd > 0 ? this.costUsd : this.listCostUsd;
    if (usd <= 0 && this.allowanceUsd > 0) {
      // 网关没给 list_cost 时, 用额度消耗作为等价成本的下限近似
      usd = this.allowanceUsd;
    }
    return this.costCny + usd * fxRate;
  }

  clone(): UsageCounters {
    let c: UsageCounters = new UsageCounters();
    c.addCounters(this);
    return c;
  }

  toJson(): Record<string, Object> {
    let out: Record<string, Object> = {};
    if (this.calls > 0) {
      out['calls'] = this.calls;
    }
    if (this.inputHit > 0) {
      out['hit'] = this.inputHit;
    }
    if (this.inputMiss > 0) {
      out['miss'] = this.inputMiss;
    }
    if (this.output > 0) {
      out['out'] = this.output;
    }
    if (this.cacheWrite > 0) {
      out['cw'] = this.cacheWrite;
    }
    if (this.search > 0) {
      out['search'] = this.search;
    }
    if (this.fetch > 0) {
      out['fetch'] = this.fetch;
    }
    if (this.costCny !== 0) {
      out['cny'] = this.costCny;
    }
    if (this.costUsd !== 0) {
      out['usd'] = this.costUsd;
    }
    if (this.allowanceUsd !== 0) {
      out['allow'] = this.allowanceUsd;
    }
    if (this.listCostUsd !== 0) {
      out['list'] = this.listCostUsd;
    }
    if (this.missingUsage !== 0) {
      out['missing'] = this.missingUsage;
    }
    return out;
  }

  static fromJson(json: Record<string, Object>): UsageCounters {
    let c: UsageCounters = new UsageCounters();
    c.calls = readNumber(json, 'calls');
    c.inputHit = readNumber(json, 'hit');
    c.inputMiss = readNumber(json, 'miss');
    c.output = readNumber(json, 'out');
    c.cacheWrite = readNumber(json, 'cw');
    c.search = readNumber(json, 'search');
    c.fetch = readNumber(json, 'fetch');
    c.costCny = readNumber(json, 'cny');
    c.costUsd = readNumber(json, 'usd');
    c.allowanceUsd = readNumber(json, 'allow');
    c.listCostUsd = readNumber(json, 'list');
    c.missingUsage = readNumber(json, 'missing');
    return c;
  }
}

export class UsageModelDay {
  model: string = '';
  bands: Record<string, UsageCounters> = {};
  band(name: string): UsageCounters {
    let c: UsageCounters | undefined = this.bands[name];
    if (c === undefined) {
      c = new UsageCounters();
      this.bands[name] = c;
    }
    return c;
  }

  add(band: string, snapshot: UsageSnapshot): void {
    this.band(band).addSnapshot(snapshot);
  }

  sum(): UsageCounters {
    let out: UsageCounters = new UsageCounters();
    let keys: string[] = Object.keys(this.bands);
    for (let i: number = 0; i < keys.length; i++) {
      out.addCounters(this.bands[keys[i]]);
    }
    return out;
  }

  toJson(): Record<string, Object> {
    let bands: Record<string, Object> = {};
    let keys: string[] = Object.keys(this.bands);
    for (let i: number = 0; i < keys.length; i++) {
      bands[keys[i]] = this.bands[keys[i]].toJson();
    }
    return { 'model': this.model, 'bands': bands };
  }

  static fromJson(json: Record<string, Object>): UsageModelDay {
    let m: UsageModelDay = new UsageModelDay();
    m.model = readString(json, 'model');
    let rawBands: Object | undefined = json['bands'];
    if (rawBands !== undefined && typeof rawBands === 'object' && rawBands !== null) {
      let rec: Record<string, Object> = rawBands as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      for (let i: number = 0; i < keys.length; i++) {
        let raw: Object = rec[keys[i]];
        if (typeof raw === 'object' && raw !== null) {
          m.bands[keys[i]] = UsageCounters.fromJson(raw as Record<string, Object>);
        }
      }
    }
    return m;
  }
}

export class UsageModelRow {
  model: string = '';
  counters: UsageCounters = new UsageCounters();
}

export class UsageProviderDay {
  provider: string = '';
  models: Record<string, UsageModelDay> = {};
  // 单个服务商单日的模型明细上限: 防止用户配置了大量模型时账本按模型数无限膨胀。
  private static readonly MAX_MODELS_PER_DAY: number = 16;

  model(name: string): UsageModelDay {
    let m: UsageModelDay | undefined = this.models[name];
    if (m === undefined) {
      m = new UsageModelDay();
      m.model = name;
      this.models[name] = m;
    }
    return m;
  }

  add(model: string, band: string, snapshot: UsageSnapshot): void {
    let name: string = model;
    if (this.models[name] === undefined && Object.keys(this.models).length >= UsageProviderDay.MAX_MODELS_PER_DAY) {
      name = '其他模型';
    }
    this.model(name).add(band, snapshot);
  }

  sum(): UsageCounters {
    let out: UsageCounters = new UsageCounters();
    let keys: string[] = Object.keys(this.models);
    for (let i: number = 0; i < keys.length; i++) {
      out.addCounters(this.models[keys[i]].sum());
    }
    return out;
  }

  rows(): UsageModelRow[] {
    let out: UsageModelRow[] = [];
    let keys: string[] = Object.keys(this.models);
    for (let i: number = 0; i < keys.length; i++) {
      let row: UsageModelRow = new UsageModelRow();
      row.model = keys[i];
      row.counters = this.models[keys[i]].sum();
      out.push(row);
    }
    return out;
  }

  toJson(): Record<string, Object> {
    let models: Record<string, Object> = {};
    let keys: string[] = Object.keys(this.models);
    for (let i: number = 0; i < keys.length; i++) {
      models[keys[i]] = this.models[keys[i]].toJson();
    }
    return { 'provider': this.provider, 'models': models };
  }

  static fromJson(json: Record<string, Object>): UsageProviderDay {
    let p: UsageProviderDay = new UsageProviderDay();
    p.provider = readString(json, 'provider');
    let rawModels: Object | undefined = json['models'];
    if (rawModels !== undefined && typeof rawModels === 'object' && rawModels !== null) {
      let rec: Record<string, Object> = rawModels as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      for (let i: number = 0; i < keys.length; i++) {
        let raw: Object = rec[keys[i]];
        if (typeof raw === 'object' && raw !== null) {
          p.models[keys[i]] = UsageModelDay.fromJson(raw as Record<string, Object>);
        }
      }
    }
    return p;
  }
}

export class UsageProviderRow {
  provider: string = '';
  counters: UsageCounters = new UsageCounters();
  models: UsageModelRow[] = [];
}

// 最近 8 天的小时桶: 只用于 OpenCode 的"近 5 小时/本周额度"窗口。
// 每天 24 个桶 × 2 个服务商, 内存与文件开销都可以忽略; 更早的小时桶随日账本一起裁剪。
export class UsageHour {
  hour: string = '';
  providers: Record<string, UsageCounters> = {};

  provider(name: string): UsageCounters {
    let c: UsageCounters | undefined = this.providers[name];
    if (c === undefined) {
      c = new UsageCounters();
      this.providers[name] = c;
    }
    return c;
  }

  add(provider: string, snapshot: UsageSnapshot): void {
    this.provider(provider).addSnapshot(snapshot);
  }

  total(providerFilter: string): UsageCounters {
    let out: UsageCounters = new UsageCounters();
    let keys: string[] = Object.keys(this.providers);
    for (let i: number = 0; i < keys.length; i++) {
      if (providerFilter !== '' && keys[i] !== providerFilter) {
        continue;
      }
      out.addCounters(this.providers[keys[i]]);
    }
    return out;
  }

  toJson(): Record<string, Object> {
    let providers: Record<string, Object> = {};
    let keys: string[] = Object.keys(this.providers);
    for (let i: number = 0; i < keys.length; i++) {
      providers[keys[i]] = this.providers[keys[i]].toJson();
    }
    return { 'hour': this.hour, 'providers': providers };
  }

  static fromJson(json: Record<string, Object>): UsageHour {
    let h: UsageHour = new UsageHour();
    h.hour = readString(json, 'hour');
    let raw: Object | undefined = json['providers'];
    if (raw !== undefined && typeof raw === 'object' && raw !== null) {
      let rec: Record<string, Object> = raw as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      for (let i: number = 0; i < keys.length; i++) {
        let one: Object = rec[keys[i]];
        if (typeof one === 'object' && one !== null) {
          h.providers[keys[i]] = UsageCounters.fromJson(one as Record<string, Object>);
        }
      }
    }
    return h;
  }
}

export class UsageDay {
  day: string = '';
  providers: Record<string, UsageProviderDay> = {};

  provider(name: string): UsageProviderDay {
    let p: UsageProviderDay | undefined = this.providers[name];
    if (p === undefined) {
      p = new UsageProviderDay();
      p.provider = name;
      this.providers[name] = p;
    }
    return p;
  }

  add(provider: string, model: string, band: string, snapshot: UsageSnapshot): void {
    this.provider(provider).add(model, band, snapshot);
  }

  // providerFilter 为空串表示全部
  sum(providerFilter: string): UsageCounters {
    let out: UsageCounters = new UsageCounters();
    let keys: string[] = Object.keys(this.providers);
    for (let i: number = 0; i < keys.length; i++) {
      if (providerFilter !== '' && keys[i] !== providerFilter) {
        continue;
      }
      out.addCounters(this.providers[keys[i]].sum());
    }
    return out;
  }

  providerRows(providerFilter: string): UsageProviderRow[] {
    let out: UsageProviderRow[] = [];
    let keys: string[] = Object.keys(this.providers);
    for (let i: number = 0; i < keys.length; i++) {
      if (providerFilter !== '' && keys[i] !== providerFilter) {
        continue;
      }
      let row: UsageProviderRow = new UsageProviderRow();
      row.provider = keys[i];
      row.counters = this.providers[keys[i]].sum();
      row.models = this.providers[keys[i]].rows();
      out.push(row);
    }
    return out;
  }

  // 按计费时段汇总(DeepSeek 峰/谷、OpenCode standard)
  sumBand(providerFilter: string, band: string): UsageCounters {
    let out: UsageCounters = new UsageCounters();
    let pkeys: string[] = Object.keys(this.providers);
    for (let i: number = 0; i < pkeys.length; i++) {
      if (providerFilter !== '' && pkeys[i] !== providerFilter) {
        continue;
      }
      let p: UsageProviderDay = this.providers[pkeys[i]];
      let mkeys: string[] = Object.keys(p.models);
      for (let j: number = 0; j < mkeys.length; j++) {
        let model: UsageModelDay = p.models[mkeys[j]];
        let c: UsageCounters | undefined = model.bands[band];
        if (c !== undefined) {
          out.addCounters(c);
        }
      }
    }
    return out;
  }

  toJson(): Record<string, Object> {
    let providers: Record<string, Object> = {};
    let keys: string[] = Object.keys(this.providers);
    for (let i: number = 0; i < keys.length; i++) {
      providers[keys[i]] = this.providers[keys[i]].toJson();
    }
    return { 'day': this.day, 'providers': providers };
  }

  static fromJson(json: Record<string, Object>): UsageDay {
    let d: UsageDay = new UsageDay();
    d.day = readString(json, 'day');
    let rawProviders: Object | undefined = json['providers'];
    if (rawProviders !== undefined && typeof rawProviders === 'object' && rawProviders !== null) {
      let rec: Record<string, Object> = rawProviders as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      for (let i: number = 0; i < keys.length; i++) {
        let raw: Object = rec[keys[i]];
        if (typeof raw === 'object' && raw !== null) {
          d.providers[keys[i]] = UsageProviderDay.fromJson(raw as Record<string, Object>);
        }
      }
    }
    return d;
  }
}

// 按日聚合账本。allTime 与 days 分离: days 只保留最近 400 天用于热力图,
// 更早的数据被裁剪后仍保留"全部"累计值, 文件不会无限增长。
export class UsageStore {
  version: number = 1;
  updatedAt: number = 0;
  days: Record<string, UsageDay> = {};
  hours: Record<string, UsageHour> = {};
  allTime: Record<string, UsageCounters> = {};

  day(key: string): UsageDay {
    let d: UsageDay | undefined = this.days[key];
    if (d === undefined) {
      d = new UsageDay();
      d.day = key;
      this.days[key] = d;
    }
    return d;
  }

  hour(key: string): UsageHour {
    let h: UsageHour | undefined = this.hours[key];
    if (h === undefined) {
      h = new UsageHour();
      h.hour = key;
      this.hours[key] = h;
    }
    return h;
  }

  add(dayKey: string, hourKey: string, provider: string, model: string, band: string,
    snapshot: UsageSnapshot): void {
    this.day(dayKey).add(provider, model, band, snapshot);
    this.hour(hourKey).add(provider, snapshot);
    let total: UsageCounters | undefined = this.allTime[provider];
    if (total === undefined) {
      total = new UsageCounters();
      this.allTime[provider] = total;
    }
    total.addSnapshot(snapshot);
    this.updatedAt = Date.now();
  }

  total(providerFilter: string): UsageCounters {
    let out: UsageCounters = new UsageCounters();
    if (providerFilter !== '') {
      let one: UsageCounters | undefined = this.allTime[providerFilter];
      if (one !== undefined) {
        out.addCounters(one);
      }
      return out;
    }
    let keys: string[] = Object.keys(this.allTime);
    for (let i: number = 0; i < keys.length; i++) {
      out.addCounters(this.allTime[keys[i]]);
    }
    return out;
  }

  toJson(): Record<string, Object> {
    let days: Record<string, Object> = {};
    let keys: string[] = Object.keys(this.days);
    for (let i: number = 0; i < keys.length; i++) {
      days[keys[i]] = this.days[keys[i]].toJson();
    }
    let hours: Record<string, Object> = {};
    let hkeys: string[] = Object.keys(this.hours);
    for (let i: number = 0; i < hkeys.length; i++) {
      hours[hkeys[i]] = this.hours[hkeys[i]].toJson();
    }
    let totals: Record<string, Object> = {};
    let tkeys: string[] = Object.keys(this.allTime);
    for (let i: number = 0; i < tkeys.length; i++) {
      totals[tkeys[i]] = this.allTime[tkeys[i]].toJson();
    }
    return {
      'version': this.version,
      'updatedAt': this.updatedAt,
      'days': days,
      'hours': hours,
      'allTime': totals
    };
  }

  static fromJson(json: Record<string, Object>): UsageStore {
    let store: UsageStore = new UsageStore();
    store.version = readNumber(json, 'version');
    if (store.version <= 0) {
      store.version = 1;
    }
    store.updatedAt = readNumber(json, 'updatedAt');
    let rawDays: Object | undefined = json['days'];
    if (rawDays !== undefined && typeof rawDays === 'object' && rawDays !== null) {
      let rec: Record<string, Object> = rawDays as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      for (let i: number = 0; i < keys.length; i++) {
        let raw: Object = rec[keys[i]];
        if (typeof raw === 'object' && raw !== null) {
          store.days[keys[i]] = UsageDay.fromJson(raw as Record<string, Object>);
        }
      }
    }
    let rawHours: Object | undefined = json['hours'];
    if (rawHours !== undefined && typeof rawHours === 'object' && rawHours !== null) {
      let rec: Record<string, Object> = rawHours as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      for (let i: number = 0; i < keys.length; i++) {
        let raw: Object = rec[keys[i]];
        if (typeof raw === 'object' && raw !== null) {
          store.hours[keys[i]] = UsageHour.fromJson(raw as Record<string, Object>);
        }
      }
    }
    let rawTotals: Object | undefined = json['allTime'];
    if (rawTotals !== undefined && typeof rawTotals === 'object' && rawTotals !== null) {
      let rec: Record<string, Object> = rawTotals as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      for (let i: number = 0; i < keys.length; i++) {
        let raw: Object = rec[keys[i]];
        if (typeof raw === 'object' && raw !== null) {
          store.allTime[keys[i]] = UsageCounters.fromJson(raw as Record<string, Object>);
        }
      }
    }
    return store;
  }
}

export class UsageSettings {
  fxRate: number = 7.2;
  monthlyBudgetCny: number = 0;
  openCodeMonthlyLimitUsd: number = 100;

  toJson(): Record<string, Object> {
    return {
      'fxRate': this.fxRate,
      'monthlyBudgetCny': this.monthlyBudgetCny,
      'openCodeMonthlyLimitUsd': this.openCodeMonthlyLimitUsd
    };
  }

  static fromJson(json: Record<string, Object>): UsageSettings {
    let s: UsageSettings = new UsageSettings();
    let fx: number = readNumber(json, 'fxRate');
    if (fx > 0) {
      s.fxRate = fx;
    }
    s.monthlyBudgetCny = readNumber(json, 'monthlyBudgetCny');
    let limObj: Object | undefined = json['openCodeMonthlyLimitUsd'];
    if (typeof limObj === 'number') {
      s.openCodeMonthlyLimitUsd = limObj as number;
    }
    return s;
  }
}

export class DeepSeekBalanceInfo {
  available: boolean = false;
  currency: string = 'CNY';
  total: number = 0;
  granted: number = 0;
  toppedUp: number = 0;
  updatedAt: number = 0;

  toJson(): Record<string, Object> {
    return {
      'available': this.available,
      'currency': this.currency,
      'total': this.total,
      'granted': this.granted,
      'toppedUp': this.toppedUp,
      'updatedAt': this.updatedAt
    };
  }

  static fromJson(json: Record<string, Object>): DeepSeekBalanceInfo {
    let b: DeepSeekBalanceInfo = new DeepSeekBalanceInfo();
    let av: Object | undefined = json['available'];
    b.available = av === true;
    b.currency = readString(json, 'currency');
    if (b.currency === '') {
      b.currency = 'CNY';
    }
    b.total = readNumber(json, 'total');
    b.granted = readNumber(json, 'granted');
    b.toppedUp = readNumber(json, 'toppedUp');
    b.updatedAt = readNumber(json, 'updatedAt');
    return b;
  }
}

// 热力图单格(仅 UI 使用, 不落盘)
export class UsageHeatCell {
  dayKey: string = '';
  dayOfMonth: number = 0;
  month: number = 0;
  weekIndex: number = 0;
  weekday: number = 0;
  value: number = 0;
  tokens: number = 0;
  calls: number = 0;
  future: boolean = false;
  level: number = 0;
}

export class UsageHeatWeek {
  days: UsageHeatCell[] = [];
  label: string = '';
}
