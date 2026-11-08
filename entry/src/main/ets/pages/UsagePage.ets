// 用量与成本: 本地逐请求 usage → 按日聚合 → 热力图/成本估算。
// 页面只在打开时读取几十 KB 的账本, 不参与聊天流式路径; 所有统计都是本地计算。
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { ApiProfile } from '../model/ApiProfile';
import { StorageManager } from '../data/StorageManager';
import {
  DeepSeekBalanceInfo,
  USAGE_BAND_OFFPEAK,
  USAGE_BAND_PEAK,
  USAGE_PROVIDER_DEEPSEEK,
  USAGE_PROVIDER_OPENCODE,
  UsageCounters,
  UsageHeatCell,
  UsageHeatWeek,
  UsageModelRow,
  UsageProviderRow,
  UsageSettings
} from '../model/UsageModels';
import { UsageMeter } from '../service/UsageMeter';
import { UsageSettingsStore } from '../service/UsageSettingsStore';
import { DeepSeekBalanceService } from '../service/DeepSeekBalanceService';
import { ImmersiveLight } from '../common/ImmersiveLight';
import { UsagePricing } from '../common/UsagePricing';
import { UsageTime } from '../common/UsageTime';

@Entry
@Component
struct UsagePage {
  @State private providerFilter: string = '';
  @State private metric: string = 'cost';
  @State private settings: UsageSettings = new UsageSettings();
  @State private settingsOpen: boolean = false;
  // 回到前台时补一次重建: 后台任务可能刚写入新用量; 不做轮询。
  @StorageLink('appForeground') @Watch('onForegroundChanged')
  private appForeground: boolean = true;

  @State private profiles: ApiProfile[] = [];
  @State private balance: DeepSeekBalanceInfo | null = null;
  @State private balanceLoading: boolean = false;

  @State private heatWeeks: UsageHeatWeek[] = [];
  @State private heatVersion: number = 0;
  @State private legendLow: string = '';
  @State private legendHigh: string = '';
  @State private hasAnyData: boolean = false;

  @State private summaryToday: UsageCounters = new UsageCounters();
  @State private summary7: UsageCounters = new UsageCounters();
  @State private summaryMonth: UsageCounters = new UsageCounters();
  @State private summaryAll: UsageCounters = new UsageCounters();
  @State private allMonth: UsageCounters = new UsageCounters();
  @State private deepSeekMonth: UsageCounters = new UsageCounters();
  @State private openCodeMonth: UsageCounters = new UsageCounters();
  @State private deepSeekToday: UsageCounters = new UsageCounters();
  @State private openCode5h: UsageCounters = new UsageCounters();
  @State private openCodeWeek: UsageCounters = new UsageCounters();

  @State private detailDay: string = '';
  @State private detailTotal: UsageCounters = new UsageCounters();
  @State private detailPeak: UsageCounters = new UsageCounters();
  @State private detailOffPeak: UsageCounters = new UsageCounters();
  @State private detailProviders: UsageProviderRow[] = [];

  @State private fxText: string = '7.2';
  @State private budgetText: string = '0';
  @State private openCodeLimitText: string = '100';

  private context: common.UIAbilityContext | null = null;
  private appeared: boolean = false;
  private settingsLoaded: boolean = false;
  private saveTimer: number = -1;
  private rebuildTimer: number = -1;
  private heatScroller: Scroller = new Scroller();
  private heatAutoScrolled: boolean = false;
  private heatScrollTimer1: number = -1;
  private heatScrollTimer2: number = -1;
  private heatScrollTimer3: number = -1;
  private readonly cellSize: number = 10;
  private readonly cellGap: number = 3;
  private readonly weekdays: number[] = [0, 1, 2, 3, 4, 5, 6];

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    UsageMeter.init(this.context);
    UsageMeter.ensureLoaded();
    this.rebuild();
    this.reloadAsync();
  }

  onPageShow(): void {
    if (!this.appeared) {
      this.appeared = true;
      return;
    }
    // 设置弹层打开时(例如从分享面板返回)不重读配置, 避免覆盖尚未落盘的输入
    if (this.settingsOpen) {
      this.rebuild();
      return;
    }
    this.reloadAsync();
  }

  private onForegroundChanged(): void {
    if (!this.appForeground) {
      // 切后台时把本页草稿与用量账本落盘, 避免进程被回收丢最后一批
      if (this.rebuildTimer !== -1) {
        clearTimeout(this.rebuildTimer);
        this.rebuildTimer = -1;
      }
      if (this.saveTimer !== -1) {
        clearTimeout(this.saveTimer);
        this.saveTimer = -1;
      }
      this.persistSettings();
      UsageMeter.flush();
      return;
    }
    if (this.context !== null) {
      this.rebuild();
    }
  }

  aboutToDisappear(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    if (this.rebuildTimer !== -1) {
      clearTimeout(this.rebuildTimer);
      this.rebuildTimer = -1;
    }
    if (this.heatScrollTimer1 !== -1) {
      clearTimeout(this.heatScrollTimer1);
      this.heatScrollTimer1 = -1;
    }
    if (this.heatScrollTimer2 !== -1) {
      clearTimeout(this.heatScrollTimer2);
      this.heatScrollTimer2 = -1;
    }
    if (this.heatScrollTimer3 !== -1) {
      clearTimeout(this.heatScrollTimer3);
      this.heatScrollTimer3 = -1;
    }
    this.persistSettings();
    UsageMeter.flush();
  }

  private async reloadAsync(): Promise<void> {
    let ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      return;
    }
    try {
      let list: ApiProfile[] = await StorageManager.loadApiProfiles(ctx);
      this.profiles = list;
    } catch (e) {
      this.profiles = [];
    }
    try {
      let loaded: UsageSettings = await UsageSettingsStore.loadSettings(ctx);
      this.settings = loaded;
      this.settingsLoaded = true;
      this.fxText = UsagePage.editableNumber(loaded.fxRate);
      this.budgetText = UsagePage.editableNumber(loaded.monthlyBudgetCny);
      this.openCodeLimitText = UsagePage.editableNumber(loaded.openCodeMonthlyLimitUsd);
    } catch (e) {
      // 读取失败时仍允许在本页修改参数(下一次保存会覆盖坏值)
      this.settingsLoaded = true;
      this.fxText = UsagePage.editableNumber(this.settings.fxRate);
      this.budgetText = UsagePage.editableNumber(this.settings.monthlyBudgetCny);
      this.openCodeLimitText = UsagePage.editableNumber(this.settings.openCodeMonthlyLimitUsd);
    }
    try {
      this.balance = await UsageSettingsStore.loadBalance(ctx);
    } catch (e) {
      this.balance = null;
    }
    this.rebuild();
  }

  // ===== 数据整理 =====

  private rebuild(): void {
    let today: string = UsageTime.todayKey();
    let monthPrefix: string = today.substring(0, 7);
    this.summaryToday = UsageMeter.dayCounters(today, this.providerFilter);
    this.summary7 = UsageMeter.sumRecentDays(7, this.providerFilter);
    this.summaryMonth = UsageMeter.sumMonth(monthPrefix, this.providerFilter);
    this.summaryAll = UsageMeter.total(this.providerFilter);
    this.allMonth = UsageMeter.sumMonth(monthPrefix, '');
    this.deepSeekMonth = UsageMeter.sumMonth(monthPrefix, USAGE_PROVIDER_DEEPSEEK);
    this.openCodeMonth = UsageMeter.sumMonth(monthPrefix, USAGE_PROVIDER_OPENCODE);
    this.deepSeekToday = UsageMeter.dayCounters(today, USAGE_PROVIDER_DEEPSEEK);
    this.openCode5h = UsageMeter.sumRecentHours(5, USAGE_PROVIDER_OPENCODE);
    this.openCodeWeek = UsageMeter.sumRecentDays(7, USAGE_PROVIDER_OPENCODE);
    this.hasAnyData = this.summaryAll.calls > 0;
    this.buildHeatmap();
    if (this.detailDay !== '') {
      this.loadDetail();
    }
  }

  private buildHeatmap(): void {
    let weeksCount: number = 53;
    let today: string = UsageTime.todayKey();
    let monday: string = UsageTime.addDays(today, -UsageTime.mondayIndex(today));
    let start: string = UsageTime.addDays(monday, -(weeksCount - 1) * 7);
    let weeks: UsageHeatWeek[] = [];
    let values: number[] = [];

    for (let w: number = 0; w < weeksCount; w++) {
      let week: UsageHeatWeek = new UsageHeatWeek();
      let label: string = '';
      for (let d: number = 0; d < 7; d++) {
        let key: string = UsageTime.addDays(start, w * 7 + d);
        let cell: UsageHeatCell = new UsageHeatCell();
        cell.dayKey = key;
        cell.dayOfMonth = UsageTime.day(key);
        cell.month = UsageTime.month(key);
        cell.weekIndex = w;
        cell.weekday = d;
        cell.future = key > today;
        if (!cell.future) {
          let c: UsageCounters = UsageMeter.dayCounters(key, this.providerFilter);
          cell.tokens = c.totalTokens();
          cell.calls = c.calls;
          cell.value = this.metricValue(c);
          if (cell.value > 0) {
            values.push(cell.value);
          }
        }
        if (label === '' && cell.dayOfMonth === 1) {
          label = cell.month.toString();
        }
        week.days.push(cell);
      }
      week.label = label;
      weeks.push(week);
    }

    let thresholds: number[] = this.computeThresholds(values);
    for (let i: number = 0; i < weeks.length; i++) {
      let week: UsageHeatWeek = weeks[i];
      for (let j: number = 0; j < week.days.length; j++) {
        week.days[j].level = this.levelFor(week.days[j].value, thresholds);
      }
    }
    this.heatWeeks = weeks;
    this.heatVersion++;
    this.legendLow = this.formatMetric(thresholds[0]);
    this.legendHigh = this.formatMetric(thresholds[3]);
    if (!this.heatAutoScrolled) {
      this.scheduleInitialHeatScroll();
    }
  }

  // 热力图横向滚动: 最近的在最右边, 首次打开自动滚到最右;
  // 之后用户手动滚到哪就停在哪, 切换指标/服务商不强行拉回。
  private scheduleInitialHeatScroll(): void {
    this.heatAutoScrolled = true;
    this.heatScrollTimer1 = setTimeout((): void => {
      this.heatScrollTimer1 = -1;
      this.scrollHeatToLatest();
    }, 60);
    this.heatScrollTimer2 = setTimeout((): void => {
      this.heatScrollTimer2 = -1;
      this.scrollHeatToLatest();
    }, 220);
    this.heatScrollTimer3 = setTimeout((): void => {
      this.heatScrollTimer3 = -1;
      this.scrollHeatToLatest();
    }, 600);
  }

  private scrollHeatToLatest(): void {
    try {
      this.heatScroller.scrollTo({
        xOffset: 999999,
        yOffset: 0,
        animation: { duration: 0 }
      });
    } catch (e) {
      // Scroller 尚未绑定(首帧)时忽略, 第二个定时器会补一次
    }
  }

  private computeThresholds(values: number[]): number[] {
    let sorted: number[] = values.slice();
    sorted.sort((a: number, b: number): number => a - b);
    let out: number[] = [0, 0, 0, 0];
    if (sorted.length === 0) {
      return out;
    }
    // 用 90 分位作上限, 避免某一天异常高把其余日期全部压成最浅色。
    let capIndex: number = Math.floor((sorted.length - 1) * 0.9);
    let cap: number = sorted[capIndex];
    if (cap <= 0) {
      cap = sorted[sorted.length - 1];
    }
    if (cap <= 0) {
      return out;
    }
    out[0] = cap * 0.15;
    out[1] = cap * 0.35;
    out[2] = cap * 0.60;
    out[3] = cap * 0.80;
    return out;
  }

  private levelFor(value: number, thresholds: number[]): number {
    if (value <= 0) {
      return 0;
    }
    if (value <= thresholds[0]) {
      return 1;
    }
    if (value <= thresholds[1]) {
      return 2;
    }
    if (value <= thresholds[2]) {
      return 3;
    }
    return 4;
  }

  private metricValue(c: UsageCounters): number {
    if (this.metric === 'tokens') {
      return c.totalTokens();
    }
    if (this.metric === 'calls') {
      return c.calls;
    }
    return c.equivalentCostCny(this.settings.fxRate);
  }

  private loadDetail(): void {
    this.detailTotal = UsageMeter.dayCounters(this.detailDay, this.providerFilter);
    this.detailPeak = UsageMeter.dayBandCounters(this.detailDay, this.providerFilter, USAGE_BAND_PEAK);
    this.detailOffPeak = UsageMeter.dayBandCounters(this.detailDay, this.providerFilter, USAGE_BAND_OFFPEAK);
    this.detailProviders = UsageMeter.providerRows(this.detailDay, this.providerFilter);
  }

  private selectDay(dayKey: string): void {
    this.detailDay = dayKey;
    this.loadDetail();
  }

  private changeProvider(value: string): void {
    this.providerFilter = value;
    this.detailDay = '';
    this.rebuild();
  }

  private changeMetric(value: string): void {
    this.metric = value;
    this.rebuild();
  }

  // ===== 配置 =====

  private scheduleSettingsSave(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      this.persistSettings();
    }, 500);
  }

  private persistSettings(): void {
    let ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null || !this.settingsLoaded) {
      return;
    }
    UsageSettingsStore.saveSettings(ctx, this.settings).catch((): void => {});
  }

  private scheduleRebuild(): void {
    if (this.rebuildTimer !== -1) {
      clearTimeout(this.rebuildTimer);
    }
    this.rebuildTimer = setTimeout((): void => {
      this.rebuildTimer = -1;
      this.rebuild();
    }, 220);
  }

  private updateFx(value: string): void {
    this.fxText = value;
    let n: number = parseFloat(value);
    if (!isNaN(n) && isFinite(n) && n > 0) {
      let s: UsageSettings = new UsageSettings();
      s.fxRate = n;
      s.monthlyBudgetCny = this.settings.monthlyBudgetCny;
      s.openCodeMonthlyLimitUsd = this.settings.openCodeMonthlyLimitUsd;
      this.settings = s;
      this.scheduleSettingsSave();
      this.scheduleRebuild();
    }
  }

  private updateBudget(value: string): void {
    this.budgetText = value;
    let n: number = parseInt(value, 10);
    if (!isNaN(n) && isFinite(n) && n >= 0) {
      let s: UsageSettings = new UsageSettings();
      s.fxRate = this.settings.fxRate;
      s.monthlyBudgetCny = n;
      s.openCodeMonthlyLimitUsd = this.settings.openCodeMonthlyLimitUsd;
      this.settings = s;
      this.scheduleSettingsSave();
      this.scheduleRebuild();
    }
  }

  private updateOpenCodeLimit(value: string): void {
    this.openCodeLimitText = value;
    let n: number = parseInt(value, 10);
    if (!isNaN(n) && isFinite(n) && n >= 0) {
      let s: UsageSettings = new UsageSettings();
      s.fxRate = this.settings.fxRate;
      s.monthlyBudgetCny = this.settings.monthlyBudgetCny;
      s.openCodeMonthlyLimitUsd = n;
      this.settings = s;
      this.scheduleSettingsSave();
      this.scheduleRebuild();
    }
  }

  // ===== 服务商状态 =====

  private matchesProvider(profile: ApiProfile, provider: string): boolean {
    if (provider === USAGE_PROVIDER_DEEPSEEK) {
      return profile.id === ApiProfile.PRESET_DEEPSEEK_ID ||
        profile.apiConfig.baseUrl.toLowerCase().indexOf('api.deepseek.com') >= 0;
    }
    if (provider === USAGE_PROVIDER_OPENCODE) {
      let base: string = profile.apiConfig.baseUrl.toLowerCase();
      return profile.id === ApiProfile.PRESET_OPENCODE_GO_ID ||
        (base.indexOf('opencode.ai') >= 0 && base.indexOf('/go') >= 0);
    }
    return false;
  }

  private configuredProfile(provider: string): ApiProfile | null {
    for (let i: number = 0; i < this.profiles.length; i++) {
      if (this.matchesProvider(this.profiles[i], provider) &&
        this.profiles[i].apiConfig.apiKey.trim() !== '') {
        return this.profiles[i];
      }
    }
    return null;
  }

  private isConfigured(provider: string): boolean {
    return this.configuredProfile(provider) !== null;
  }

  private async refreshBalance(): Promise<void> {
    if (this.balanceLoading) {
      return;
    }
    let profile: ApiProfile | null = this.configuredProfile(USAGE_PROVIDER_DEEPSEEK);
    if (profile === null) {
      promptAction.showToast({ message: '请先在设置中启用 DeepSeek', duration: 2000 });
      return;
    }
    this.balanceLoading = true;
    let info: DeepSeekBalanceInfo | null = null;
    try {
      info = await DeepSeekBalanceService.fetch(profile.apiConfig);
    } catch (e) {
      info = null;
    }
    this.balanceLoading = false;
    if (info === null) {
      promptAction.showToast({ message: '余额刷新失败，请检查网络与密钥', duration: 2200 });
      return;
    }
    this.balance = info;
    let ctx: common.UIAbilityContext | null = this.context;
    if (ctx !== null) {
      UsageSettingsStore.saveBalance(ctx, info).catch((): void => {});
    }
    promptAction.showToast({ message: '余额已更新', duration: 1600 });
  }

  // ===== 导出 / 清空 =====

  private async exportCsv(): Promise<void> {
    let ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      return;
    }
    try {
      let lines: string[] = [
        'date,provider,model,calls,input_hit,input_miss,output,cost_cny,cost_usd,allowance_usd,list_cost_usd,missing_usage'
      ];
      let keys: string[] = UsageMeter.dayKeys();
      for (let i: number = 0; i < keys.length; i++) {
        let providers: UsageProviderRow[] = UsageMeter.providerRows(keys[i], '');
        for (let p: number = 0; p < providers.length; p++) {
          let models: UsageModelRow[] = providers[p].models;
          for (let m: number = 0; m < models.length; m++) {
            let c: UsageCounters = models[m].counters;
            lines.push(keys[i] + ',' + providers[p].provider + ',' + models[m].model + ',' +
              c.calls.toString() + ',' + c.inputHit.toString() + ',' + c.inputMiss.toString() + ',' +
              c.output.toString() + ',' + c.costCny.toFixed(6) + ',' + c.costUsd.toFixed(6) + ',' +
              c.allowanceUsd.toFixed(6) + ',' + c.listCostUsd.toFixed(6) + ',' +
              c.missingUsage.toString());
          }
        }
      }
      let name: string = 'guncat-usage-' + UsageTime.todayKey() + '.csv';
      let path: string = ctx.filesDir + '/' + name;
      let file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, lines.join('\n'));
      } finally {
        fileIo.closeSync(file.fd);
      }
      let uri: string = fileUri.getUriFromPath(path);
      let utd: string = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.csv');
      let data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd !== '' ? utd : 'general.file',
        uri: uri,
        title: name
      });
      let controller: systemShare.ShareController = new systemShare.ShareController(data);
      await controller.show(ctx, { selectionMode: systemShare.SelectionMode.SINGLE });
    } catch (e) {
      promptAction.showToast({ message: '导出失败', duration: 2000 });
    }
  }

  private async clearData(): Promise<void> {
    try {
      let res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '清空用量统计',
        message: '将删除本机保存的全部用量账本，不可恢复。聊天记录与配置不受影响。',
        buttons: [
          { text: '取消', color: '#6B7280' },
          { text: '清空', color: '#E05252' }
        ],
        // API 26+ 沉浸光感: 弹窗背板改用系统弹窗材质; 低版本返回 undefined, 即保持系统默认样式
        systemMaterial: ImmersiveLight.dialogMaterial()
      });
      if (res.index !== 1) {
        return;
      }
      UsageMeter.clear();
      this.detailDay = '';
      this.rebuild();
      promptAction.showToast({ message: '用量统计已清空', duration: 1600 });
    } catch (e) {
      // 弹窗取消/不可用时不做任何事
    }
  }

  // ===== 格式化 =====

  private static editableNumber(v: number): string {
    if (Math.abs(v - Math.round(v)) < 0.000001) {
      return Math.round(v).toString();
    }
    return v.toFixed(2);
  }

  private formatMoneyCny(v: number): string {
    if (v <= 0) {
      return '¥0';
    }
    if (v < 0.01) {
      return '¥' + v.toFixed(4);
    }
    if (v < 1) {
      return '¥' + v.toFixed(3);
    }
    if (v < 1000) {
      return '¥' + v.toFixed(2);
    }
    return '¥' + v.toFixed(1);
  }

  private formatMoneyUsd(v: number): string {
    if (v <= 0) {
      return '$0';
    }
    if (v < 0.01) {
      return '$' + v.toFixed(4);
    }
    if (v < 1) {
      return '$' + v.toFixed(3);
    }
    return '$' + v.toFixed(2);
  }

  private formatTokens(v: number): string {
    if (v >= 1000000000) {
      return (v / 1000000000).toFixed(1) + 'B';
    }
    if (v >= 1000000) {
      return (v / 1000000).toFixed(1) + 'M';
    }
    if (v >= 1000) {
      return (v / 1000).toFixed(1) + 'K';
    }
    return Math.round(v).toString();
  }

  private formatMetric(v: number): string {
    if (this.metric === 'tokens') {
      return v > 0 ? this.formatTokens(Math.ceil(v)) : '0';
    }
    if (this.metric === 'calls') {
      return v > 0 ? Math.max(1, Math.ceil(v)).toString() : '0';
    }
    return this.formatMoneyCny(v);
  }

  private formatPercent(hit: number, total: number): string {
    if (total <= 0) {
      return '—';
    }
    return Math.round(hit / total * 100).toString() + '%';
  }

  private formatBalanceTime(ts: number): string {
    if (ts <= 0) {
      return '尚未刷新';
    }
    let d: Date = new Date(ts);
    let h: number = d.getHours();
    let m: number = d.getMinutes();
    let hh: string = h < 10 ? '0' + h.toString() : h.toString();
    let mm: string = m < 10 ? '0' + m.toString() : m.toString();
    return d.getMonth() + 1 + '/' + d.getDate() + ' ' + hh + ':' + mm;
  }

  private heroTitle(): string {
    let prefix: string = this.providerFilter === '' ? '' : this.providerName(this.providerFilter) + ' ';
    if (this.metric === 'tokens') {
      return prefix + '本月 Token';
    }
    if (this.metric === 'calls') {
      return prefix + '本月请求';
    }
    return prefix + '本月等价成本';
  }

  private heroSubtitle(): string {
    if (this.metric === 'cost') {
      return '按 1 USD = ' + UsagePage.editableNumber(this.settings.fxRate) + ' CNY 折算';
    }
    return '按每次响应返回的 usage 累计';
  }

  private metricPrimary(c: UsageCounters): string {
    if (this.metric === 'tokens') {
      return this.formatTokens(c.totalTokens());
    }
    if (this.metric === 'calls') {
      return c.calls.toString();
    }
    return this.formatMoneyCny(c.equivalentCostCny(this.settings.fxRate));
  }

  private metricSecondary(c: UsageCounters): string {
    if (this.metric === 'cost') {
      return this.formatTokens(c.totalTokens()) + ' tokens';
    }
    return this.formatMoneyCny(c.equivalentCostCny(this.settings.fxRate));
  }

  private deepSeekMainLabel(): string {
    if (this.metric === 'tokens') {
      return '本月 Token';
    }
    if (this.metric === 'calls') {
      return '本月请求';
    }
    return '本月实付';
  }

  private deepSeekMainValue(): string {
    if (this.metric === 'tokens') {
      return this.formatTokens(this.deepSeekMonth.totalTokens());
    }
    if (this.metric === 'calls') {
      return this.deepSeekMonth.calls.toString();
    }
    return this.formatMoneyCny(this.deepSeekMonth.costCny);
  }

  private deepSeekSideLabel(): string {
    if (this.metric === 'tokens') {
      return '今日 Token';
    }
    if (this.metric === 'calls') {
      return '今日请求';
    }
    return '今日';
  }

  private deepSeekSideValue(): string {
    if (this.metric === 'tokens') {
      return this.formatTokens(this.deepSeekToday.totalTokens());
    }
    if (this.metric === 'calls') {
      return this.deepSeekToday.calls.toString();
    }
    return this.formatMoneyCny(this.deepSeekToday.costCny);
  }

  private deepSeekSideSub(): string {
    if (this.metric === 'cost') {
      return this.formatTokens(this.deepSeekMonth.totalTokens()) + ' tokens / 月';
    }
    return this.formatMoneyCny(this.deepSeekMonth.costCny) + ' / 月';
  }

  private openCodeMainLabel(): string {
    if (this.metric === 'tokens') {
      return '本月 Token';
    }
    if (this.metric === 'calls') {
      return '本月请求';
    }
    return this.openCodePrimaryLabel();
  }

  private openCodeMainValue(): string {
    if (this.metric === 'tokens') {
      return this.formatTokens(this.openCodeMonth.totalTokens());
    }
    if (this.metric === 'calls') {
      return this.openCodeMonth.calls.toString();
    }
    return this.formatMoneyUsd(this.openCodePrimaryUsd());
  }

  private openCodeSideSub(): string {
    if (this.metric === 'cost') {
      return this.formatTokens(this.openCodeMonth.totalTokens()) + ' tokens / 月';
    }
    if (this.openCodeMonth.allowanceUsd > 0) {
      return '额度 ' + this.formatMoneyUsd(this.openCodeMonth.allowanceUsd);
    }
    return this.formatTokens(this.openCodeMonth.totalTokens()) + ' tokens / 月';
  }

  private allMonthEquivalent(): number {
    return this.allMonth.equivalentCostCny(this.settings.fxRate);
  }

  private budgetRatio(): number {
    if (this.settings.monthlyBudgetCny <= 0) {
      return 0;
    }
    let ratio: number = this.allMonthEquivalent() / this.settings.monthlyBudgetCny;
    return ratio > 1 ? 1 : ratio;
  }

  private budgetPercentText(): string {
    if (this.settings.monthlyBudgetCny <= 0) {
      return '';
    }
    let pct: number = Math.round(this.allMonthEquivalent() / this.settings.monthlyBudgetCny * 100);
    return pct.toString() + '%';
  }

  private providerName(provider: string): string {
    return UsagePricing.providerLabel(provider);
  }

  private openCodeEquivalentUsd(): number {
    let usd: number = this.openCodeMonth.costUsd > 0 ? this.openCodeMonth.costUsd : this.openCodeMonth.listCostUsd;
    return usd > 0 ? usd : this.openCodeMonth.allowanceUsd;
  }

  private openCodePrimaryUsd(): number {
    if (this.openCodeMonth.allowanceUsd > 0) {
      return this.openCodeMonth.allowanceUsd;
    }
    if (this.openCodeMonth.costUsd > 0) {
      return this.openCodeMonth.costUsd;
    }
    return this.openCodeMonth.listCostUsd;
  }

  private openCodePrimaryLabel(): string {
    return this.openCodeMonth.allowanceUsd > 0 ? '本月套餐额度消耗' : '本月 OpenCode 成本';
  }

  private openCodeWindowUsd(c: UsageCounters): number {
    if (c.allowanceUsd > 0) {
      return c.allowanceUsd;
    }
    if (c.costUsd > 0) {
      return c.costUsd;
    }
    return c.listCostUsd;
  }

  private openCodeLimitRatio(): number {
    if (this.settings.openCodeMonthlyLimitUsd <= 0) {
      return 0;
    }
    let ratio: number = this.openCodeMonth.allowanceUsd / this.settings.openCodeMonthlyLimitUsd;
    return ratio > 1 ? 1 : ratio;
  }

  private openCode5hLimitUsd(): number {
    return this.settings.openCodeMonthlyLimitUsd * 0.2;
  }

  private openCodeWeekLimitUsd(): number {
    return this.settings.openCodeMonthlyLimitUsd * 0.5;
  }

  private heatColor(level: number): Resource {
    if (level <= 0) {
      return $r('app.color.heat_0');
    }
    if (level === 1) {
      return $r('app.color.heat_1');
    }
    if (level === 2) {
      return $r('app.color.heat_2');
    }
    if (level === 3) {
      return $r('app.color.heat_3');
    }
    return $r('app.color.heat_4');
  }

  private weekdayLabel(index: number): string {
    if (index === 0) {
      return '一';
    }
    if (index === 2) {
      return '三';
    }
    if (index === 4) {
      return '五';
    }
    if (index === 6) {
      return '日';
    }
    return '';
  }

  private selectedDayLabel(): string {
    if (this.detailDay === '') {
      return '';
    }
    return UsageTime.fullDateLabel(this.detailDay) + ' · ' + UsageTime.weekdayLabel(this.detailDay);
  }

  private detailCacheText(): string {
    return this.formatPercent(this.detailTotal.inputHit, this.detailTotal.totalInput());
  }

  private detailCostText(): string {
    return this.formatMoneyCny(this.detailTotal.equivalentCostCny(this.settings.fxRate));
  }

  private closeSettings(): void {
    this.settingsOpen = false;
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    this.persistSettings();
  }

  // ===== 页面 =====

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.buildHeader()
        Scroll() {
          Column({ space: 16 }) {
            this.buildHero()
            this.buildFilterRow()
            this.buildDeepSeekCard()
            this.buildOpenCodeCard()
            this.buildHeatmapCard()
            if (this.detailDay !== '') {
              this.buildDayDetail()
            }
            this.buildFooter()
          }
          .width('100%')
          .constraintSize({ maxWidth: 720 })
          .padding({ left: 16, right: 16, top: 16, bottom: 36 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')

      // 设置弹层: 以前是页面底部插入一张卡, 用户点右上角齿轮后看不到任何变化。
      // 这里改成明确的底部弹层 + 遮罩 + 关闭按钮, 点开即有反馈。
      if (this.settingsOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .hitTestBehavior(HitTestMode.Block)
          .onClick((): void => {
            this.closeSettings();
          })

        Column() {
          Row()
            .width(36)
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.divider'))
            .margin({ top: 8, bottom: 6 })

          Row() {
            Column({ space: 2 }) {
              Text('统计参数')
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('修改后自动保存，仅保存在本机')
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button() {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(18)
                .fontColor([$r('app.color.text_secondary')])
            }
            .width(34)
            .height(34)
            .borderRadius(17)
            .backgroundColor($r('app.color.surface_secondary'))
            .onClick((): void => {
              this.closeSettings();
            })
          }
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 10 })
          .alignItems(VerticalAlign.Center)

          Scroll() {
            this.buildSettingsCard()
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .height('76%')
        .padding({ left: 16, right: 16, bottom: 24 })
        .backgroundColor($r('app.color.background'))
        .borderRadius({ topLeft: 24, topRight: 24, bottomLeft: 0, bottomRight: 0 })
        .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: -4 })
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.sidebar_fill'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  onBackPress(): boolean {
    if (this.settingsOpen) {
      this.closeSettings();
      return true;
    }
    return false;
  }

  @Builder
  private buildHeader() {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        router.back();
      })

      Text('用量与成本')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .margin({ left: 8 })

      Button() {
        SymbolGlyph($r('sys.symbol.arrow_down_to_line'))
          .fontSize(19)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.exportCsv();
      })

      Button() {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(19)
          .fontColor([this.settingsOpen ? $r('app.color.brand') : $r('app.color.text_secondary')])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.settingsOpen ? $r('app.color.brand_light') : Color.Transparent)
      .onClick((): void => {
        if (this.settingsOpen) {
          this.closeSettings();
        } else {
          this.settingsOpen = true;
        }
      })
    }
    .width('100%')
    .height(56)
    .padding({ left: 10, right: 10 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.surface'))
    .border({ width: { bottom: 0.5 }, color: { bottom: $r('app.color.divider') } })
  }

  @Builder
  private buildHero() {
    Column({ space: 14 }) {
      Row() {
        Text(this.heroTitle())
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.heroSubtitle())
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')

      Text(this.metricPrimary(this.summaryMonth))
        .fontSize(36)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Row() {
        Column({ space: 3 }) {
          Text('今日')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.metricPrimary(this.summaryToday))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.metricSecondary(this.summaryToday))
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 3 }) {
          Text('近 7 天')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.metricPrimary(this.summary7))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.metricSecondary(this.summary7))
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 3 }) {
          Text('全部')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.metricPrimary(this.summaryAll))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.metricSecondary(this.summaryAll))
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      if (this.metric === 'cost' && this.settings.monthlyBudgetCny > 0) {
        Column({ space: 6 }) {
          Row() {
            Text('月预算（等价成本）')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
            Text(this.formatMoneyCny(this.allMonthEquivalent()) + ' / ' +
              this.formatMoneyCny(this.settings.monthlyBudgetCny) + ' · ' + this.budgetPercentText())
              .fontSize(11)
              .fontColor(this.allMonthEquivalent() > this.settings.monthlyBudgetCny ?
                $r('app.color.danger') : $r('app.color.text_secondary'))
          }
          .width('100%')
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(6)
              .borderRadius(3)
              .backgroundColor($r('app.color.surface_secondary'))
            Row()
              .width((this.budgetRatio() * 100).toFixed(1) + '%')
              .height(6)
              .borderRadius(3)
              .backgroundColor(this.allMonthEquivalent() > this.settings.monthlyBudgetCny ?
                $r('app.color.danger') : $r('app.color.brand'))
          }
          .width('100%')
          .height(6)
        }
        .width('100%')
      }

      if (this.summaryMonth.missingUsage > 0) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(13)
            .fontColor([$r('app.color.warning')])
          Text(this.summaryMonth.missingUsage.toString() + ' 次请求未返回 usage，统计可能偏低')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(24)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildFilterRow() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('全部')
          .fontSize(13)
          .fontColor(this.providerFilter === '' ? $r('app.color.brand') : $r('app.color.text_secondary'))
          .backgroundColor(this.providerFilter === '' ? $r('app.color.brand_light') : $r('app.color.surface'))
          .borderRadius(16)
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .border({ width: 1, color: this.providerFilter === '' ? $r('app.color.brand') : $r('app.color.divider') })
          .onClick((): void => this.changeProvider(''))
        Text('DeepSeek')
          .fontSize(13)
          .fontColor(this.providerFilter === USAGE_PROVIDER_DEEPSEEK ?
            $r('app.color.brand') : $r('app.color.text_secondary'))
          .backgroundColor(this.providerFilter === USAGE_PROVIDER_DEEPSEEK ?
            $r('app.color.brand_light') : $r('app.color.surface'))
          .borderRadius(16)
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .border({ width: 1, color: this.providerFilter === USAGE_PROVIDER_DEEPSEEK ?
            $r('app.color.brand') : $r('app.color.divider') })
          .onClick((): void => this.changeProvider(USAGE_PROVIDER_DEEPSEEK))
        Text('OpenCode Go')
          .fontSize(13)
          .fontColor(this.providerFilter === USAGE_PROVIDER_OPENCODE ?
            $r('app.color.brand') : $r('app.color.text_secondary'))
          .backgroundColor(this.providerFilter === USAGE_PROVIDER_OPENCODE ?
            $r('app.color.brand_light') : $r('app.color.surface'))
          .borderRadius(16)
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .border({ width: 1, color: this.providerFilter === USAGE_PROVIDER_OPENCODE ?
            $r('app.color.brand') : $r('app.color.divider') })
          .onClick((): void => this.changeProvider(USAGE_PROVIDER_OPENCODE))
        Blank()
      }
      .width('100%')

      Row({ space: 2 }) {
        Text('费用')
          .fontSize(12)
          .fontColor(this.metric === 'cost' ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
          .backgroundColor(this.metric === 'cost' ? $r('app.color.surface') : Color.Transparent)
          .borderRadius(12)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .onClick((): void => this.changeMetric('cost'))
        Text('Tokens')
          .fontSize(12)
          .fontColor(this.metric === 'tokens' ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
          .backgroundColor(this.metric === 'tokens' ? $r('app.color.surface') : Color.Transparent)
          .borderRadius(12)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .onClick((): void => this.changeMetric('tokens'))
        Text('请求')
          .fontSize(12)
          .fontColor(this.metric === 'calls' ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
          .backgroundColor(this.metric === 'calls' ? $r('app.color.surface') : Color.Transparent)
          .borderRadius(12)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .onClick((): void => this.changeMetric('calls'))
      }
      .padding(3)
      .backgroundColor($r('app.color.surface_secondary'))
      .borderRadius(15)
      .alignSelf(ItemAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildDeepSeekCard() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text('DeepSeek')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.isConfigured(USAGE_PROVIDER_DEEPSEEK) ? '按请求 usage 与峰谷价目表估算' : '在设置中填入 API Key 后开始统计')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({ space: 4 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(this.isConfigured(USAGE_PROVIDER_DEEPSEEK) ?
              $r('app.color.success') : $r('app.color.text_quaternary'))
          Text(this.isConfigured(USAGE_PROVIDER_DEEPSEEK) ? '已启用' : '未启用')
            .fontSize(10)
            .fontColor(this.isConfigured(USAGE_PROVIDER_DEEPSEEK) ?
              $r('app.color.success') : $r('app.color.text_tertiary'))
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor($r('app.color.surface_secondary'))
      }
      .width('100%')

      Row() {
        Column({ space: 3 }) {
          Text(this.deepSeekMainLabel())
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.deepSeekMainValue())
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 3 }) {
          Text(this.deepSeekSideLabel())
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.deepSeekSideValue())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.deepSeekSideSub())
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')

      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.divider'))

      Row({ space: 8 }) {
        Text('余额')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.balance === null ? '未刷新' :
          (this.balance.currency === 'USD' ? this.formatMoneyUsd(this.balance.total) :
            this.formatMoneyCny(this.balance.total)))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(this.balance === null ? '仅作对账，不参与热力图' : this.formatBalanceTime(this.balance.updatedAt))
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
        if (this.balanceLoading) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.brand'))
        } else {
          Button() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(14)
              .fontColor([$r('app.color.text_secondary')])
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .backgroundColor(Color.Transparent)
          .onClick((): void => {
            this.refreshBalance();
          })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)
    .border({ width: 1, color: this.providerFilter === USAGE_PROVIDER_DEEPSEEK ?
      $r('app.color.brand') : $r('app.color.divider') })
    .opacity(this.isConfigured(USAGE_PROVIDER_DEEPSEEK) ? 1 : 0.72)
  }

  @Builder
  private buildOpenCodeCard() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text('OpenCode Go')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.isConfigured(USAGE_PROVIDER_OPENCODE) ? '按网关返回 allowance / list_cost 累计' : '在设置中填入 API Key 后开始统计')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({ space: 4 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(this.isConfigured(USAGE_PROVIDER_OPENCODE) ?
              $r('app.color.success') : $r('app.color.text_quaternary'))
          Text(this.isConfigured(USAGE_PROVIDER_OPENCODE) ? '已启用' : '未启用')
            .fontSize(10)
            .fontColor(this.isConfigured(USAGE_PROVIDER_OPENCODE) ?
              $r('app.color.success') : $r('app.color.text_tertiary'))
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor($r('app.color.surface_secondary'))
      }
      .width('100%')

      Row() {
        Column({ space: 3 }) {
          Text(this.openCodeMainLabel())
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.openCodeMainValue())
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 3 }) {
          Text('等价成本')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.formatMoneyUsd(this.openCodeEquivalentUsd()))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.openCodeSideSub())
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')

      if (this.settings.openCodeMonthlyLimitUsd > 0) {
        Column({ space: 6 }) {
          Row() {
            Text('月度额度进度')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
            Text(this.formatMoneyUsd(this.openCodeMonth.allowanceUsd) + ' / ' +
              this.formatMoneyUsd(this.settings.openCodeMonthlyLimitUsd))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(6)
              .borderRadius(3)
              .backgroundColor($r('app.color.surface_secondary'))
            Row()
              .width((this.openCodeLimitRatio() * 100).toFixed(1) + '%')
              .height(6)
              .borderRadius(3)
              .backgroundColor($r('app.color.brand'))
          }
          .width('100%')
          .height(6)

          Row() {
            Text('近 5 小时')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
            Text(this.formatMoneyUsd(this.openCodeWindowUsd(this.openCode5h)) + ' / ' +
              this.formatMoneyUsd(this.openCode5hLimitUsd()))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')

          Row() {
            Text('近 7 天')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
            Text(this.formatMoneyUsd(this.openCodeWindowUsd(this.openCodeWeek)) + ' / ' +
              this.formatMoneyUsd(this.openCodeWeekLimitUsd()))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)
    .border({ width: 1, color: this.providerFilter === USAGE_PROVIDER_OPENCODE ?
      $r('app.color.brand') : $r('app.color.divider') })
    .opacity(this.isConfigured(USAGE_PROVIDER_OPENCODE) ? 1 : 0.72)
  }

  @Builder
  private buildHeatmapCard() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 2 }) {
          Text('每日用量')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('最近 53 周 · 按北京时间切日')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 2 }) {
          Text(this.metric === 'cost' ? '每日等价成本' : (this.metric === 'tokens' ? '每日 Token' : '每日请求数'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Text(this.legendLow + ' — ' + this.legendHigh)
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')

      Row({ space: 8 }) {
        Column() {
          Blank()
            .height(14)
          Column({ space: this.cellGap }) {
            ForEach(this.weekdays, (d: number) => {
              Text(this.weekdayLabel(d))
                .fontSize(8)
                .fontColor($r('app.color.text_tertiary'))
                .width(12)
                .height(this.cellSize)
                .textAlign(TextAlign.Center)
            }, (d: number) => d.toString())
          }
        }
        .width(14)

        Scroll(this.heatScroller) {
          Column({ space: 4 }) {
            Row({ space: this.cellGap }) {
              ForEach(this.heatWeeks, (week: UsageHeatWeek) => {
                Text(week.label)
                  .fontSize(8)
                  .fontColor($r('app.color.text_tertiary'))
                  .width(this.cellSize)
                  .height(10)
                  .textAlign(TextAlign.Center)
              }, (week: UsageHeatWeek) => this.heatVersion.toString() + ':' + week.days[0].dayKey)
            }

            Row({ space: this.cellGap }) {
              ForEach(this.heatWeeks, (week: UsageHeatWeek) => {
                Column({ space: this.cellGap }) {
                  ForEach(week.days, (cell: UsageHeatCell) => {
                    this.buildHeatCell(cell)
                  }, (cell: UsageHeatCell) => cell.dayKey + ':' + cell.level.toString() + ':' +
                    (cell.dayKey === this.detailDay ? '1' : '0'))
                }
              }, (week: UsageHeatWeek) => this.heatVersion.toString() + ':' + week.days[0].dayKey)
            }
          }
          .alignItems(HorizontalAlign.Start)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .height(104)
        .layoutWeight(1)
        .onAppear((): void => {
          this.scrollHeatToLatest();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 6 }) {
        Text('少')
          .fontSize(9)
          .fontColor($r('app.color.text_tertiary'))
        ForEach([0, 1, 2, 3, 4], (level: number) => {
          Column()
            .width(10)
            .height(10)
            .borderRadius(3)
            .backgroundColor(this.heatColor(level))
        }, (level: number) => level.toString())
        Text('多')
          .fontSize(9)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        Text(this.hasAnyData ? '点格子查看当天明细' : '还没有用量记录')
          .fontSize(9)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildHeatCell(cell: UsageHeatCell) {
    Column()
      .width(this.cellSize)
      .height(this.cellSize)
      .borderRadius(3)
      .backgroundColor(cell.future ? $r('app.color.heat_0') : this.heatColor(cell.level))
      .opacity(cell.future ? 0.25 : 1)
      .border({
        width: cell.dayKey === this.detailDay ? 2 : 0,
        color: cell.dayKey === this.detailDay ? $r('app.color.heat_selected') : Color.Transparent
      })
      .onClick((): void => {
        if (!cell.future) {
          this.selectDay(cell.dayKey);
        }
      })
  }

  @Builder
  private buildDayDetail() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 2 }) {
          Text(this.selectedDayLabel())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('当天明细')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('收起')
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .padding({ left: 10, right: 4, top: 4, bottom: 4 })
          .onClick((): void => {
            this.detailDay = '';
          })
      }
      .width('100%')

      Row() {
        Column({ space: 3 }) {
          Text('等价成本')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.detailCostText())
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 3 }) {
          Text('Tokens')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text(this.formatTokens(this.detailTotal.totalTokens()))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.detailTotal.calls.toString() + ' 次请求 · 缓存 ' + this.detailCacheText())
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')

      if (this.detailTotal.search > 0 || this.detailTotal.fetch > 0) {
        Text('服务端搜索 ' + this.detailTotal.search.toString() + ' 次 · 抓取 ' +
          this.detailTotal.fetch.toString() + ' 次')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }

      if (this.detailPeak.calls > 0 || this.detailOffPeak.calls > 0) {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text('峰时')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.formatMoneyCny(this.detailPeak.costCny))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column({ space: 2 }) {
            Text('谷时')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.formatMoneyCny(this.detailOffPeak.costCny))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column({ space: 2 }) {
            Text('全错峰可省')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.formatMoneyCny(this.detailPeak.costCny * 0.5))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.success'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
      }

      if (this.detailProviders.length === 0) {
        Text('这一天没有用量记录')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      } else {
        ForEach(this.detailProviders, (row: UsageProviderRow) => {
          Column({ space: 10 }) {
            Row() {
              Text(this.providerName(row.provider))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Text(this.formatMoneyCny(row.counters.equivalentCostCny(this.settings.fxRate)))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')

            Row({ space: 12 }) {
              Text(this.formatTokens(row.counters.totalTokens()) + ' tokens')
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
              Text(row.counters.calls.toString() + ' 次请求')
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
              if (row.counters.allowanceUsd > 0) {
                Text('额度 ' + this.formatMoneyUsd(row.counters.allowanceUsd))
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
              }
            }
            .width('100%')

            Text('命中 ' + this.formatTokens(row.counters.inputHit) +
              ' · 未命中 ' + this.formatTokens(row.counters.inputMiss) +
              ' · 输出 ' + this.formatTokens(row.counters.output))
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')

            ForEach(row.models, (model: UsageModelRow) => {
              Row() {
                Text(model.model)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.formatTokens(model.counters.totalTokens()) + ' · ' +
                  this.formatMoneyCny(model.counters.equivalentCostCny(this.settings.fxRate)))
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 10 })
            }, (model: UsageModelRow) => this.detailDay + ':' + model.model + ':' +
              model.counters.calls.toString() + ':' + model.counters.totalTokens().toString() + ':' +
              model.counters.equivalentCostCny(this.settings.fxRate).toFixed(6))
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.surface_secondary'))
          .borderRadius(14)
        }, (row: UsageProviderRow) => this.detailDay + ':' + row.provider + ':' +
          row.counters.calls.toString() + ':' + row.counters.totalTokens().toString() + ':' +
          row.counters.equivalentCostCny(this.settings.fxRate).toFixed(6))
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildSettingsCard() {
    Column({ space: 14 }) {
      Column({ space: 6 }) {
        Text('美元汇率')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ placeholder: '7.2', text: this.fxText })
          .type(InputType.Normal)
          .width('100%')
          .height(42)
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))
          .padding({ left: 12, right: 12 })
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .onChange((value: string): void => {
            this.updateFx(value);
          })
        Text('OpenCode 的美元额度按此汇率折算成人民币，参与"全部"热力图与汇总。')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .lineHeight(15)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 6 }) {
        Text('月预算（人民币，按等价成本，0 表示关闭）')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ placeholder: '例如 20', text: this.budgetText })
          .type(InputType.Number)
          .width('100%')
          .height(42)
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))
          .padding({ left: 12, right: 12 })
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .onChange((value: string): void => {
            this.updateBudget(value);
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 6 }) {
        Text('OpenCode 月额度（美元，仅用于进度条；0 表示不显示）')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ placeholder: '例如 100', text: this.openCodeLimitText })
          .type(InputType.Number)
          .width('100%')
          .height(42)
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))
          .padding({ left: 12, right: 12 })
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .onChange((value: string): void => {
            this.updateOpenCodeLimit(value);
          })
        Text('以网关返回的 opencode.allowance 累计；额度数字只影响进度条，不参与成本计算。')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .lineHeight(15)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.divider'))

      Row({ space: 10 }) {
        Button() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.arrow_down_to_line'))
              .fontSize(15)
              .fontColor([$r('app.color.text_secondary')])
            Text('导出 CSV')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .layoutWeight(1)
        .height(38)
        .borderRadius(12)
        .backgroundColor($r('app.color.surface_secondary'))
        .onClick((): void => {
          this.exportCsv();
        })

        Button() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(15)
              .fontColor([$r('app.color.danger')])
            Text('清空统计')
              .fontSize(12)
              .fontColor($r('app.color.danger'))
          }
        }
        .layoutWeight(1)
        .height(38)
        .borderRadius(12)
        .backgroundColor($r('app.color.danger_light'))
        .onClick((): void => {
          this.clearData();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildFooter() {
    Column({ space: 6 }) {
      Text('价目表 ' + UsagePricing.PRICE_VERSION + ' · DeepSeek 峰时为北京时间工作日 9:00–12:00、14:00–18:00，其余时段及法定节假日按谷时价。')
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .lineHeight(15)
      Text('统计来自每次模型响应返回的 usage；DeepSeek 成本按官方价目表估算，OpenCode Go 额度以网关返回 allowance 为准，套餐内实际现金成本为固定月费。')
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .lineHeight(15)
      Text('未内置价目表的自定义服务只计入 Token 与请求数，不估算成本；DeepSeek 余额仅作对账，不参与热力图。')
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .lineHeight(15)
      Text('数据只保存在本机，不上传；账本保留最近 400 天，热力图展示最近 53 周，更早数据只保留累计值。')
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .lineHeight(15)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4 })
    .alignItems(HorizontalAlign.Start)
  }
}
