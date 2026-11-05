// 把三种协议 + OpenCode 扩展的 usage 统一成扁平 UsageSnapshot。
// 关键点: Anthropic 的 input_tokens 不含缓存命中, Responses/Completions 的输入可能含缓存命中,
// 不能混用同一套减法; OpenCode 则直接给 billed tokens, 优先使用。

import { UsageSnapshot } from '../model/UsageModels';

function asRecord(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || typeof value !== 'object' || value instanceof Array) {
    return null;
  }
  return value as Record<string, Object>;
}

function num(obj: Record<string, Object> | null, key: string): number {
  if (obj === null) {
    return 0;
  }
  let v: Object | undefined = obj[key];
  if (typeof v === 'number') {
    return v as number;
  }
  return 0;
}

function str(obj: Record<string, Object> | null, key: string): string {
  if (obj === null) {
    return '';
  }
  let v: Object | undefined = obj[key];
  if (typeof v === 'string') {
    return v as string;
  }
  return '';
}

function clean(v: number): number {
  if (!isFinite(v) || v < 0) {
    return 0;
  }
  return Math.round(v);
}

export class UsageNormalizer {
  static normalize(raw: Record<string, Object> | null, protocol: string): UsageSnapshot {
    let s: UsageSnapshot = new UsageSnapshot();
    if (raw === null) {
      s.missingUsage = 1;
      return s;
    }

    // OpenCode Go/余额: 网关在标准 usage 之外额外给出 opencode 对象。
    // 优先用它, 因为 tokens.input 已经排除了 cache_read/write, 与 DeepSeek 的口径一致。
    let open: Record<string, Object> | null = asRecord(raw['opencode']);
    let usedOpenTokens: boolean = false;
    if (open !== null) {
      let tokens: Record<string, Object> | null = asRecord(open['tokens']);
      if (tokens !== null) {
        s.inputMiss = clean(num(tokens, 'input'));
        s.inputHit = clean(num(tokens, 'cache_read'));
        s.cacheWrite = clean(num(tokens, 'cache_write_5m')) + clean(num(tokens, 'cache_write_1h'));
        s.output = clean(num(tokens, 'output'));
        usedOpenTokens = true;
      }
      s.allowanceUsd = num(open, 'allowance');
      s.listCostUsd = num(open, 'list_cost');
      s.costUsd = num(open, 'cost');
      s.billingSource = str(open, 'billing_source');
    }

    if (!usedOpenTokens) {
      if (protocol === 'anthropic') {
        // DeepSeek/Anthropic: input_tokens 是未命中缓存的输入, cache_read 才是命中。
        s.inputMiss = clean(num(raw, 'input_tokens'));
        s.inputHit = clean(num(raw, 'cache_read_input_tokens'));
        s.cacheWrite = clean(num(raw, 'cache_creation_input_tokens'));
        s.output = clean(num(raw, 'output_tokens'));
      } else if (protocol === 'responses') {
        // Responses: input_tokens 含缓存命中, cached_tokens 是其中的子集。
        let inputTotal: number = clean(num(raw, 'input_tokens'));
        let details: Record<string, Object> | null = asRecord(raw['input_tokens_details']);
        let cached: number = clean(num(details, 'cached_tokens'));
        s.inputHit = Math.min(cached, inputTotal);
        s.inputMiss = Math.max(0, inputTotal - s.inputHit);
        s.output = clean(num(raw, 'output_tokens'));
      } else {
        // Chat Completions: DeepSeek 原生字段最准; 否则用 prompt_tokens_details.cached_tokens。
        let hitExplicit: number = num(raw, 'prompt_cache_hit_tokens');
        let missExplicit: number = num(raw, 'prompt_cache_miss_tokens');
        let promptTotal: number = clean(num(raw, 'prompt_tokens'));
        if (hitExplicit > 0 || missExplicit > 0) {
          s.inputHit = clean(hitExplicit);
          s.inputMiss = missExplicit > 0 ? clean(missExplicit) :
            Math.max(0, promptTotal - s.inputHit);
        } else {
          let promptDetails: Record<string, Object> | null = asRecord(raw['prompt_tokens_details']);
          let cached: number = clean(num(promptDetails, 'cached_tokens'));
          s.inputHit = Math.min(cached, promptTotal);
          s.inputMiss = Math.max(0, promptTotal - s.inputHit);
        }
        s.output = clean(num(raw, 'completion_tokens'));
      }
    }

    // 服务端搜索/抓取(DeepSeek/Anthropic): 最终 message_delta 里是累计值。
    let serverTools: Record<string, Object> | null = asRecord(raw['server_tool_use']);
    if (serverTools !== null) {
      s.search = clean(num(serverTools, 'web_search_requests'));
      s.fetch = clean(num(serverTools, 'tool_search'));
    }

    let hasTokenData: boolean = s.inputHit > 0 || s.inputMiss > 0 || s.output > 0 ||
      s.cacheWrite > 0 || s.allowanceUsd > 0 || s.costUsd > 0 || s.listCostUsd > 0;
    if (!hasTokenData) {
      s.missingUsage = 1;
    }
    return s;
  }
}
