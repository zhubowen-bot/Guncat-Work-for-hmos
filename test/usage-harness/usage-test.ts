// 纯逻辑回归: 不依赖 ArkUI/设备, 用 tsc 编译后用 Node 跑。
// 覆盖北京时间切日、DeepSeek 峰谷、DeepSeek 计价、三种协议 + OpenCode 的 usage 归一化。
import { UsageTime } from '../../entry/src/main/ets/common/UsageTime';
import { UsagePricing } from '../../entry/src/main/ets/common/UsagePricing';
import { UsageNormalizer } from '../../entry/src/main/ets/common/UsageNormalizer';
import {
  UsageCounters,
  UsageSnapshot,
  UsageStore,
  USAGE_PROVIDER_DEEPSEEK,
  USAGE_PROVIDER_OPENCODE
} from '../../entry/src/main/ets/model/UsageModels';

function check(name: string, actual: Object, expected: Object): void {
  if (actual !== expected) {
    throw new Error(name + ': expected ' + String(expected) + ', got ' + String(actual));
  }
}

function near(name: string, actual: number, expected: number): void {
  if (Math.abs(actual - expected) > 0.000001) {
    throw new Error(name + ': expected ' + String(expected) + ', got ' + String(actual));
  }
}

// 北京时间 2026-11-05(周四) 09:00 / 08:59 / 12:00 / 14:00 / 18:00
const at0900: number = Date.UTC(2026, 10, 5, 1, 0);
const at0859: number = Date.UTC(2026, 10, 5, 0, 59);
const at1200: number = Date.UTC(2026, 10, 5, 4, 0);
const at1400: number = Date.UTC(2026, 10, 5, 6, 0);
const at1800: number = Date.UTC(2026, 10, 5, 10, 0);
check('weekday 09:00 peak', UsagePricing.isDeepSeekPeak(at0900), true);
check('weekday 08:59 offpeak', UsagePricing.isDeepSeekPeak(at0859), false);
check('weekday 12:00 offpeak', UsagePricing.isDeepSeekPeak(at1200), false);
check('weekday 14:00 peak', UsagePricing.isDeepSeekPeak(at1400), true);
check('weekday 18:00 offpeak', UsagePricing.isDeepSeekPeak(at1800), false);
check('weekend offpeak', UsagePricing.isDeepSeekPeak(Date.UTC(2026, 10, 7, 2, 0)), false);
check('holiday offpeak', UsagePricing.isDeepSeekPeak(Date.UTC(2026, 9, 1, 2, 0)), false);

// 北京时间切日
check('day before midnight', UsageTime.dayKey(Date.UTC(2026, 10, 5, 15, 59)), '2026-11-05');
check('day after midnight', UsageTime.dayKey(Date.UTC(2026, 10, 5, 16, 0)), '2026-11-06');
check('add days', UsageTime.addDays('2026-03-01', -1), '2026-02-28');
check('add hours across midnight', UsageTime.addHours('2026-11-05T23', 1), '2026-11-06T00');

// DeepSeek Flash 峰/谷价
const peak: UsageSnapshot = new UsageSnapshot();
peak.inputHit = 1000000;
peak.inputMiss = 1000000;
peak.output = 1000000;
UsagePricing.applyDeepSeekPrice(peak, 'deepseek-flash', 'peak');
near('flash peak cost', peak.costCny, 10.04);
const off: UsageSnapshot = new UsageSnapshot();
off.inputHit = 1000000;
off.inputMiss = 1000000;
off.output = 1000000;
UsagePricing.applyDeepSeekPrice(off, 'deepseek-flash', 'offPeak');
near('flash offpeak cost', off.costCny, 5.02);

// Anthropic: input_tokens 不含缓存命中
const anthropic: UsageSnapshot = UsageNormalizer.normalize({
  'input_tokens': 1000,
  'cache_read_input_tokens': 4000,
  'cache_creation_input_tokens': 0,
  'output_tokens': 500,
  'server_tool_use': { 'web_search_requests': 2, 'tool_search': 1 }
}, 'anthropic');
check('anthropic hit', anthropic.inputHit, 4000);
check('anthropic miss', anthropic.inputMiss, 1000);
check('anthropic total input', anthropic.totalInput(), 5000);
check('anthropic search', anthropic.search, 2);
check('anthropic fetch', anthropic.fetch, 1);

// Responses: input_tokens 含缓存命中
const responses: UsageSnapshot = UsageNormalizer.normalize({
  'input_tokens': 5000,
  'input_tokens_details': { 'cached_tokens': 4000 },
  'output_tokens': 500
}, 'responses');
check('responses hit', responses.inputHit, 4000);
check('responses miss', responses.inputMiss, 1000);

// Completions(DeepSeek 原生字段)
const completions: UsageSnapshot = UsageNormalizer.normalize({
  'prompt_tokens': 5000,
  'prompt_cache_hit_tokens': 4000,
  'prompt_cache_miss_tokens': 1000,
  'completion_tokens': 500
}, 'completions');
check('completions hit', completions.inputHit, 4000);
check('completions miss', completions.inputMiss, 1000);

// OpenCode 扩展: 优先使用 opencode.tokens, 并保留 allowance/list_cost
const opencode: UsageSnapshot = UsageNormalizer.normalize({
  'input_tokens': 9999,
  'output_tokens': 9999,
  'opencode': {
    'tokens': { 'input': 1000, 'cache_read': 4000, 'output': 500, 'cache_write_5m': 0, 'cache_write_1h': 0 },
    'allowance': 0.01,
    'list_cost': 0.02,
    'cost': 0,
    'billing_source': 'go'
  }
}, 'anthropic');
check('opencode miss', opencode.inputMiss, 1000);
check('opencode hit', opencode.inputHit, 4000);
near('opencode allowance', opencode.allowanceUsd, 0.01);
near('opencode list', opencode.listCostUsd, 0.02);
check('opencode source', opencode.billingSource, 'go');

// 存储聚合与 JSON 往返
const store: UsageStore = new UsageStore();
store.add('2026-11-05', '2026-11-05T09', USAGE_PROVIDER_DEEPSEEK, 'deepseek-flash', 'peak', peak);
store.add('2026-11-05', '2026-11-05T09', USAGE_PROVIDER_OPENCODE, 'deepseek-v4.1-flash', 'standard', opencode);
const dayCounters: UsageCounters = store.days['2026-11-05'].sum('');
check('day calls', dayCounters.calls, 2);
check('day total tokens', dayCounters.totalTokens(), 3005500);
near('day cny', dayCounters.costCny, 10.04);
near('day allowance', dayCounters.allowanceUsd, 0.01);
const roundtrip: UsageStore = UsageStore.fromJson(JSON.parse(JSON.stringify(store.toJson())) as Record<string, Object>);
const roundtripDay: UsageCounters = roundtrip.days['2026-11-05'].sum('');
check('roundtrip calls', roundtripDay.calls, 2);
near('roundtrip cny', roundtripDay.costCny, 10.04);
check('roundtrip hour keys', Object.keys(roundtrip.hours).length, 1);
near('roundtrip total', roundtrip.total(USAGE_PROVIDER_DEEPSEEK).costCny, 10.04);

console.log('usage-harness: all checks passed');
