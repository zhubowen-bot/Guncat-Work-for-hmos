// AgentLoopService: 工作模式 Agent Loop 的单轮 LLM 调用
// 在 ChatService 的三种 SSE 协议基础上扩展 function-calling:
//   openai-completions → delta.tool_calls 增量累积 + role:'tool' 结果回传
//   openai-responses   → response.output_item.done(function_call) + function_call_output 回传
//   anthropic-messages → content_block tool_use / input_json_delta + tool_result 回传
// 循环驱动(执行工具/步数控制/历史裁剪)在 ChatViewModel.executeWorkLoop 中。
import { http } from '@kit.NetworkKit';
import { StreamAccumulator,
  extractChatCompletionsDelta, extractChatCompletionsReasoning, extractChatCompletionsUsage,
  extractResponsesDelta, extractResponsesReasoning, extractResponsesUsage, extractResponsesFailure,
  extractAnthropicDelta, extractAnthropicReasoning, extractAnthropicUsage, extractAnthropicFailure,
  extractAnthropicSignature, extractAnthropicRedactedThinking,
  deriveStreamStats } from './ChatService';
import { ToolCallAccumulator, collectCompletionsToolDelta, collectResponsesToolItem,
  collectAnthropicToolEvent, genToolCallId } from './ToolCallStream';
import { SSEAdapterFactory } from './SSEAdapterFactory';
import { WorkFileService } from './WorkFileService';
import { WorkSkillService } from './WorkSkillService';
import { ApiConfig } from '../model/ApiConfig';
import { ToolCallRecord } from '../model/ToolCallRecord';
import { AbortSignal } from '../common/Types';
import { Constants } from '../common/Constants';
import { PromptBuilder } from '../common/PromptBuilder';
import { PromptBudget, PromptBudgetSnapshot } from '../common/PromptBudget';
import { LLMProtocol } from '../common/LLMProtocol';
import { ToolDefAdapter } from '../common/ToolDefAdapter';
import { SSEProtocolAdapter, SSEParseContext } from '../common/SSEProtocolAdapter';
import { RetryPolicy } from '../common/RetryPolicy';
import { RetryAfterParser } from '../common/RetryAfterParser';
import { LoopError } from '../common/LoopError';
export { LoopError };

// 带分类的循环层错误已迁移到 common/LoopError(纯逻辑, 可单测);
// service 层 re-export 保持 ChatViewModel 旧导入兼容。
// 与协议无关的循环消息: assistant 消息的工具调用与执行结果都挂在 toolCalls 上
// (构建协议请求体时再拆分为 assistant(tool_calls) + tool/function_call_output/tool_result 消息)
// imageDataUrl 仅用于 user 消息携带工作区图片(view_image 工具注入), 不持久化。
// reasoning/thinkingSignature/redactedThinking 仅在内存循环内使用: Anthropic 协议思考模式下
// 工具循环的 assistant 消息必须把思考块原样回传(置于消息首位), 否则服务端 400。
export class LoopMessage {
  role: string = 'user'; // 'system' | 'user' | 'assistant'
  content: string = '';
  toolCalls: ToolCallRecord[] = [];
  imageDataUrl: string = '';
  reasoning: string = '';
  thinkingSignature: string = '';
  redactedThinking: string = '';

  static system(content: string): LoopMessage {
    let m: LoopMessage = new LoopMessage();
    m.role = 'system';
    m.content = content;
    return m;
  }

  static user(content: string): LoopMessage {
    let m: LoopMessage = new LoopMessage();
    m.role = 'user';
    m.content = content;
    return m;
  }

  // 携带图片的用户消息(view_image 注入)
  static userImage(content: string, imageDataUrl: string): LoopMessage {
    let m: LoopMessage = new LoopMessage();
    m.role = 'user';
    m.content = content;
    m.imageDataUrl = imageDataUrl;
    return m;
  }

  // assistant 消息(可能带文字与工具调用); 结果字段由调用方在执行后填入同一实例
  static assistant(content: string, calls: ToolCallRecord[]): LoopMessage {
    let m: LoopMessage = new LoopMessage();
    m.role = 'assistant';
    m.content = content;
    m.toolCalls = calls;
    return m;
  }

  // 由单轮结果构造 assistant 循环消息: 同时携带思考文本与签名,
  // 供 Anthropic 协议在下一轮请求中回传 thinking 块(思考模式下必传)
  static fromTurn(turn: LoopTurnResult): LoopMessage {
    let m: LoopMessage = LoopMessage.assistant(turn.content, turn.toolCalls);
    m.reasoning = turn.reasoning;
    m.thinkingSignature = turn.thinkingSignature;
    m.redactedThinking = turn.redactedThinking;
    return m;
  }
}

// 单轮模型返回
export class LoopTurnResult {
  content: string = '';
  reasoning: string = '';
  // Anthropic 协议: 思考块的签名(signature_delta)与加密思考块(redacted_thinking.data),
  // 回传 thinking 块时随块携带, 供服务端校验
  thinkingSignature: string = '';
  redactedThinking: string = '';
  toolCalls: ToolCallRecord[] = [];
  tokenSpeed: number = -1;
  cacheHitRate: number = -1;
  // 本请求真实 prompt tokens(usage 锚定, 未知为 0); 用于上下文预算判断
  promptTokens: number = 0;
  // 结束原因('stop' | 'tool-calls' | 'max_tokens' | ''); max_tokens 触发粘性收尾
  // (对齐 DeepSeek Harness: 一旦某步顶到输出上限, 本轮立即收尾并提示用户续跑)
  finishReason: string = '';
}

// 单轮流式回调(与 StreamCallbacks 同构; onReasoning 传入本轮已累积的完整思考文本)
export class LoopTurnCallbacks {
  onToken: (text: string) => void = (_text: string): void => {};
  onReasoning: (text: string) => void = (_text: string): void => {};
  // 工具调用流式生成过程中上抛(调用数或累计参数量变化时):
  // 记录实例与最终返回的 toolCalls 是同一批对象, 调用方可据此即时展示"生成调用中"的工具行
  onToolCalls: (calls: ToolCallRecord[]) => void = (_calls: ToolCallRecord[]): void => {};
  onUsage: (tokenSpeed: number, cacheHitRate: number) => void =
    (_speed: number, _hit: number): void => {};
  // 请求级自动重试开始(attempt 从 1 起); 上一次尝试的部分流式内容应被调用方清除
  onRetry: (attempt: number, reason: string) => void =
    (_attempt: number, _reason: string): void => {};
}

// 流式工具调用累积器: 三种协议统一汇入(共享实现见 ToolCallStream.ts)
export class AgentLoopService {
  // 活跃请求注册表: 支持多实例并发请求(主循环 + 子代理/聊天模式可能同时存在),
  // abort() 统一中断所有活跃请求, 避免单一静态引用在并发时打错目标。
  private static activeRequests: http.HttpRequest[] = [];
  private static cachedToolDefs: Record<string, Object>[] = [];
  private static cachedToolDefsFlag: boolean = false;

  // 工具表缓存(按服务端联网搜索开关区分: 开关变化时 search_web 描述在"标准/兜底"间切换)
  private static getToolDefs(webSearchEnabled: boolean): Record<string, Object>[] {
    if (AgentLoopService.cachedToolDefs.length === 0 ||
      AgentLoopService.cachedToolDefsFlag !== webSearchEnabled) {
      AgentLoopService.cachedToolDefs = WorkFileService.toolDefs(webSearchEnabled);
      AgentLoopService.cachedToolDefsFlag = webSearchEnabled;
    }
    return AgentLoopService.cachedToolDefs;
  }

  // 执行循环中的一轮: 流式返回文本/思考, 并累积工具调用; 结束后由调用方检查 toolCalls 决定继续或收尾。
  // includeTools=false 时请求不带工具定义(用于上下文压缩等纯文本辅助调用);
  // toolOverrides 非空时使用定制工具表(子代理等受限工具面)。
  static async runTurn(config: ApiConfig, messages: LoopMessage[],
    thinkingEnabled: boolean, reasoningEffort: string, webSearchEnabled: boolean,
    callbacks: LoopTurnCallbacks, abortSignal: AbortSignal,
    includeTools: boolean = true,
    toolOverrides: Record<string, Object>[] | null = null): Promise<LoopTurnResult> {
    let protocol: string = LLMProtocol.pick(config.provider);
    AgentLoopService.lastProtocol = protocol;
    let url: string = LLMProtocol.resolveEndpoint(config.baseUrl, protocol, config.autoSuffix);

    let tools: Record<string, Object>[] = includeTools ?
      (toolOverrides !== null ? toolOverrides : AgentLoopService.getToolDefs(webSearchEnabled)) : [];
    let body: Record<string, Object>;
    if (protocol === 'responses') {
      body = AgentLoopService.buildResponsesBody(config, messages, tools, thinkingEnabled, reasoningEffort, webSearchEnabled);
    } else if (protocol === 'anthropic') {
      body = AgentLoopService.buildAnthropicBody(config, messages, tools, thinkingEnabled, reasoningEffort, webSearchEnabled);
    } else {
      body = AgentLoopService.buildCompletionsBody(config, messages, tools, thinkingEnabled, reasoningEffort, webSearchEnabled);
    }
    let bodyStr: string = JSON.stringify(body);

    let httpRequest: http.HttpRequest = http.createHttp();
    AgentLoopService.activeRequests.push(httpRequest);
    let acc: StreamAccumulator = new StreamAccumulator();
    let lineBuffer: string = '';
    let settled: boolean = false;
    let statusCode: number = 0;
    let dataEnded: boolean = false;
    let failedMsg: string = '';
    let startTime: number = Date.now();
    let result: LoopTurnResult = new LoopTurnResult();
    let callAcc: ToolCallAccumulator = new ToolCallAccumulator();
    let sseAdapter: SSEProtocolAdapter = AgentLoopService.buildSseAdapter(protocol, callAcc);
    // 上一次 onToolCalls 通知的签名(调用数:累计参数量), 变化时才再次上抛
    let lastToolSig: string = '';
    // 非成功响应时累积响应体(仅前 8KB), 用于提取服务端错误详情(如上下文超限)
    let errorBody: string = '';

    // 单条 SSE 数据分发: 协议适配器统一回调文本/思考/工具调用/usage; 协议失败抛错由外层 reject
    let handleSseLine = (sseData: string): void => {
      let ctx: SSEParseContext = new SSEParseContext();
      ctx.onFailure = (msg: string): boolean => {
        failedMsg = msg;
        throw new Error(msg);
      };
      ctx.onToken = (delta: string): void => {
        result.content += delta;
        callbacks.onToken(delta);
      };
      ctx.onReasoning = (text: string): void => {
        result.reasoning += text;
        callbacks.onReasoning(result.reasoning);
      };
      ctx.onSignature = (signature: string): void => {
        result.thinkingSignature += signature;
      };
      ctx.onRedactedThinking = (data: string): void => {
        result.redactedThinking = data;
      };
      ctx.onUsage = (usageObj: Record<string, Object> | null): void => {
        let stats: number[] = deriveStreamStats(usageObj, Date.now() - startTime);
        result.tokenSpeed = stats[0];
        result.cacheHitRate = stats[1];
        result.promptTokens = AgentLoopService.extractPromptTokens(usageObj);
        callbacks.onUsage(stats[0], stats[1]);
      };
      ctx.onFinishReason = (finish: string): void => {
        if (result.finishReason === '') {
          result.finishReason = finish;
        }
      };
      sseAdapter.handleLine(sseData, ctx);
      // 三种协议统一收口: 工具调用在流式生成过程中即时上抛(调用数或参数量变化时)
      if (callAcc.calls.length > 0) {
        let argsLen: number = 0;
        for (let i: number = 0; i < callAcc.calls.length; i++) {
          argsLen += callAcc.calls[i].argsJson.length;
        }
        let sig: string = callAcc.calls.length.toString() + ':' + argsLen.toString();
        if (sig !== lastToolSig) {
          lastToolSig = sig;
          callbacks.onToolCalls(callAcc.calls);
        }
      }
    };

    try {
      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        httpRequest.on('dataReceive', (data: ArrayBuffer) => {
          if (abortSignal.aborted) {
            return;
          }
          try {
            let chunk: string = acc.append(data);
            if (errorBody.length < 8192) {
              errorBody += chunk;
            }
            lineBuffer += chunk;
            let lines: string[] = lineBuffer.split('\n');
            if (lineBuffer.endsWith('\n')) {
              lineBuffer = '';
            } else {
              lineBuffer = lines.pop() as string;
            }
            for (let i: number = 0; i < lines.length; i++) {
              let line: string = lines[i];
              let trimmed: string = line.trim();
              if (trimmed === '' || trimmed === Constants.SSE_DONE_TOKEN) {
                continue;
              }
              if (!trimmed.startsWith(Constants.SSE_DATA_PREFIX)) {
                continue;
              }
              let sseData: string = trimmed.substring(Constants.SSE_DATA_PREFIX.length);
              handleSseLine(sseData);
            }
          } catch (e) {
            let err: Error = e as Error;
            reject(err);
          }
        });

        httpRequest.on('dataEnd', () => {
          if (lineBuffer !== '') {
            let trimmed: string = lineBuffer.trim();
            if (trimmed.startsWith(Constants.SSE_DATA_PREFIX) && trimmed !== Constants.SSE_DONE_TOKEN) {
              try {
                handleSseLine(trimmed.substring(Constants.SSE_DATA_PREFIX.length));
              } catch (e) {
                let err: Error = e as Error;
                if (!settled) {
                  settled = true;
                  reject(err);
                }
                return;
              }
            }
            lineBuffer = '';
          }
          dataEnded = true;
          if (statusCode >= 200 && statusCode < 300 && !settled) {
            settled = true;
            resolve();
          }
        });

        let headers: Record<string, string> = {
          'Content-Type': 'application/json'
        };
        if (protocol === 'anthropic') {
          headers['x-api-key'] = config.apiKey;
          headers['anthropic-version'] = '2023-06-01';
          headers['Accept'] = 'text/event-stream';
        } else {
          headers['Authorization'] = 'Bearer ' + config.apiKey;
        }
        let retryAfterHeader: string = '';
        try {
          httpRequest.on('headersReceive', (header: Object) => {
            let h: Record<string, Object> = header as Record<string, Object>;
            let ra: Object | undefined = h['retry-after'];
            if (typeof ra === 'string') {
              retryAfterHeader = ra as string;
            }
          });
        } catch (e) {
          // 个别平台不支持 headersReceive 时忽略, Retry-After 降级为默认退避
        }
        httpRequest.requestInStream(url, {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: bodyStr,
          connectTimeout: 30000,
          readTimeout: 300000,
          usingProtocol: http.HttpProtocol.HTTP1_1
        }).then((code: number) => {
          statusCode = code;
          if (abortSignal.aborted) {
            return;
          }
          if (code < 200 || code >= 300) {
            if (!settled) {
              settled = true;
              let msg: string = '';
              let kind: string = 'http';
              if (code === 401) {
                msg = 'API Key 无效，请检查设置';
                kind = 'auth';
              } else if (code === 429) {
                msg = '请求过于频繁，请稍后再试';
                kind = 'rate_limit';
              } else if (code >= 400 && code < 500) {
                msg = 'API 请求错误 (' + code + ')';
                let detail: string = AgentLoopService.extractHttpErrorDetail(errorBody);
                if (detail !== '') {
                  msg += ': ' + detail;
                }
              } else if (code >= 500) {
                msg = '服务器错误 (' + code + ')，请稍后再试';
                kind = 'server';
              } else {
                msg = '请求失败，状态码: ' + code;
              }
              let retryAfterMs: number = RetryAfterParser.parseMs(retryAfterHeader);
              reject(new LoopError(msg, code, kind, retryAfterMs));
            }
            return;
          }
          if (dataEnded && !settled) {
            settled = true;
            resolve();
          }
        }).catch((err: Error) => {
          if (abortSignal.aborted) {
            if (!settled) {
              settled = true;
              resolve();
            }
            return;
          }
          if (!settled) {
            settled = true;
            // 网络层异常(连接失败/超时/DNS 等)归类为 transport, 可自动重试
            let msg: string = err.message !== undefined ? err.message : '网络请求失败';
            reject(new LoopError(msg, 0, 'transport'));
          }
        });
      });
    } catch (e) {
      let err: Error = e as Error;
      if (!abortSignal.aborted) {
        if (failedMsg === '' && err.message !== undefined) {
          failedMsg = err.message;
        }
        if (failedMsg === '') {
          failedMsg = '请求失败';
        }
        // 流式过程中由协议层报出的失败(内容审查/服务端事件错误等), 重试同样请求无意义
        throw new LoopError(failedMsg, 0, 'protocol');
      }
    } finally {
      let idx: number = AgentLoopService.activeRequests.indexOf(httpRequest);
      if (idx >= 0) {
        AgentLoopService.activeRequests.splice(idx, 1);
      }
      try {
        httpRequest.off('dataReceive');
        httpRequest.off('dataEnd');
        httpRequest.destroy();
      } catch (e) {
        // ignore
      }
    }
    result.toolCalls = AgentLoopService.normalizeCalls(callAcc.calls);
    return result;
  }

  // 中断所有活跃请求(与 ChatService.abort 语义对齐; 多请求并存时统一中止)
  static abort(): void {
    let reqs: http.HttpRequest[] = AgentLoopService.activeRequests;
    for (let i: number = 0; i < reqs.length; i++) {
      let req: http.HttpRequest = reqs[i];
      try {
        req.destroy();
      } catch (e) {
        // ignore
      }
    }
    AgentLoopService.activeRequests = [];
  }

  // 带自动重试的请求执行(对齐 DeepSeek Harness 的 llm-retry):
  // 429/5xx/网络传输/空响应按指数退避自动重试; 鉴权/协议/参数错误直接上抛。
  // maxRetries 为重试次数上限(不含首次), 退避 500ms 起步、封顶 8s, 附 ±20% 抖动。
  static async runTurnWithRetry(config: ApiConfig, messages: LoopMessage[],
    thinkingEnabled: boolean, reasoningEffort: string, webSearchEnabled: boolean,
    callbacks: LoopTurnCallbacks, abortSignal: AbortSignal,
    includeTools: boolean = true,
    maxRetries: number = Constants.WORK_LLM_RETRY_MAX,
    toolOverrides: Record<string, Object>[] | null = null): Promise<LoopTurnResult> {
    let attempt: number = 0;
    let policy: RetryPolicy = new RetryPolicy(maxRetries, 500, 8000, 0.2,
      ['rate_limit', 'server', 'transport', 'empty']);
    while (true) {
      let turn: LoopTurnResult | null = null;
      let failed: LoopError | null = null;
      try {
        turn = await AgentLoopService.runTurn(config, messages, thinkingEnabled,
          reasoningEffort, webSearchEnabled, callbacks, abortSignal, includeTools,
          toolOverrides);
      } catch (e) {
        let err: Error = e as Error;
        if (err instanceof LoopError) {
          failed = err as LoopError;
        } else {
          let msg: string = err.message !== undefined ? err.message : '请求失败';
          failed = new LoopError(msg, 0, 'transport');
        }
      }
      // 空响应(无文本也无工具调用且非用户中断): 按可重试错误处理, 避免整轮循环因此报废
      if (failed === null && turn !== null && turn.content === '' &&
        turn.toolCalls.length === 0 && !abortSignal.aborted) {
        failed = new LoopError('模型返回了空响应', 0, 'empty');
      }
      if (failed === null && turn !== null) {
        return turn;
      }
      if (failed === null) {
        continue;
      }
      if (abortSignal.aborted || !failed.retryable) {
        throw failed;
      }
      let rd = policy.decide(failed.kind, attempt, failed.retryAfterMs, Math.random());
      if (!rd.shouldRetry) {
        throw failed;
      }
      attempt++;
      callbacks.onRetry(attempt, failed.message);
      await AgentLoopService.retryBackoffMs(rd.delayMs, abortSignal);
      if (abortSignal.aborted) {
        throw failed;
      }
    }
  }

  // @deprecated 退避已迁移到 RetryPolicy + retryBackoffMs, 保留兼容
  private static async retryBackoff(attempt: number, abortSignal: AbortSignal): Promise<void> {
    let base: number = Math.min(500 * Math.pow(2, attempt - 1), 8000);
    await AgentLoopService.retryBackoffMs(base * (0.8 + 0.4 * Math.random()), abortSignal);
  }

  // 按给定毫秒数分片睡眠以便及时感知中断
  private static async retryBackoffMs(delayMs: number, abortSignal: AbortSignal): Promise<void> {
    let deadline: number = Date.now() + delayMs;
    while (Date.now() < deadline) {
      if (abortSignal.aborted) {
        return;
      }
      let slice: number = Math.min(200, deadline - Date.now());
      if (slice <= 0) {
        break;
      }
      await AgentLoopService.sleep(slice);
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  // 从 usage 中提取真实 prompt tokens(completions 用 prompt_tokens, responses/anthropic 用 input_tokens)
  private static extractPromptTokens(usage: Record<string, Object>): number {
    let pt: Object = usage['prompt_tokens'];
    if (typeof pt === 'number') {
      return pt as number;
    }
    let it: Object = usage['input_tokens'];
    if (typeof it === 'number') {
      return it as number;
    }
    return 0;
  }

  // 提取结束原因(统一词表: 'max_tokens' 需要粘性收尾; 其余返回空串/非关键值):
  //   completions: choices[0].finish_reason ('length' → max_tokens)
  //   responses:   response.completed/incomplete 事件(response.status)
  //   anthropic:   message_delta.delta.stop_reason ('max_tokens')
  // @deprecated 已迁移到 SSEAdapterFactory, 保留兼容
  private static buildSseAdapter(protocol: string, callAcc: ToolCallAccumulator): SSEProtocolAdapter {
    return SSEAdapterFactory.build(protocol, callAcc, AgentLoopService.extractFinishReason);
  }

  private static extractFinishReason(protocol: string, sseData: string): string {
    try {
      if (protocol === 'anthropic') {
        if (sseData.indexOf('"stop_reason"') === -1) {
          return '';
        }
        let json: Object = JSON.parse(sseData);
        if (typeof json !== 'object' || json === null) {
          return '';
        }
        let rec: Record<string, Object> = json as Record<string, Object>;
        let type: Object = rec['type'];
        if (typeof type !== 'string' || (type as string) !== 'message_delta') {
          return '';
        }
        let delta: Object | undefined = rec['delta'];
        if (typeof delta !== 'object' || delta === null) {
          return '';
        }
        let stop: Object = (delta as Record<string, Object>)['stop_reason'];
        if (typeof stop === 'string' && (stop as string) === 'max_tokens') {
          return 'max_tokens';
        }
        return '';
      }
      if (protocol === 'responses') {
        if (sseData.indexOf('response.completed') === -1 &&
          sseData.indexOf('response.incomplete') === -1) {
          return '';
        }
        let json: Object = JSON.parse(sseData);
        if (typeof json !== 'object' || json === null) {
          return '';
        }
        let rec: Record<string, Object> = json as Record<string, Object>;
        let type: Object = rec['type'];
        let typeStr: string = typeof type === 'string' ? type as string : '';
        if (typeStr === 'response.incomplete') {
          return 'max_tokens';
        }
        if (typeStr !== 'response.completed') {
          return '';
        }
        let resp: Object | undefined = rec['response'];
        if (typeof resp !== 'object' || resp === null) {
          return '';
        }
        // status 为 'incomplete' 且 reason 含 max_output_tokens 也按 max_tokens 处理
        let status: Object = (resp as Record<string, Object>)['status'];
        if (typeof status === 'string' && (status as string) === 'incomplete') {
          return 'max_tokens';
        }
        return '';
      }
      // completions
      if (sseData.indexOf('finish_reason') === -1) {
        return '';
      }
      let json2: Object = JSON.parse(sseData);
      if (typeof json2 !== 'object' || json2 === null) {
        return '';
      }
      let choices: Object = (json2 as Record<string, Object>)['choices'];
      if (!(choices instanceof Array) || choices.length === 0) {
        return '';
      }
      let first: Object = choices[0];
      if (typeof first !== 'object' || first === null) {
        return '';
      }
      let finish: Object = (first as Record<string, Object>)['finish_reason'];
      if (typeof finish === 'string') {
        let fr: string = finish as string;
        if (fr === 'length') {
          return 'max_tokens';
        }
        return fr;
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  // 从非 2xx 响应体提取服务端错误详情(兼容 {error:{message}} 与 {error:"..."} 两种形态)
  private static extractHttpErrorDetail(body: string): string {
    let trimmed: string = body.trim();
    if (trimmed === '') {
      return '';
    }
    try {
      let parsed: Object = JSON.parse(trimmed);
      if (typeof parsed !== 'object' || parsed === null) {
        return '';
      }
      let errField: Object = (parsed as Record<string, Object>)['error'];
      let detail: string = '';
      if (typeof errField === 'string') {
        detail = errField as string;
      } else if (typeof errField === 'object' && errField !== null) {
        let msg: Object = (errField as Record<string, Object>)['message'];
        if (typeof msg === 'string') {
          detail = msg as string;
        }
      }
      if (detail.length > 300) {
        detail = detail.substring(0, 300) + '…';
      }
      return detail;
    } catch (e) {
      return '';
    }
  }

  // 上下文压缩指令(固定文本, 不含任何时间戳等易变内容, 保证请求前缀可复用)
  private static readonly COMPACTION_INSTRUCTION: string =
    '【上下文压缩指令】以上是本任务的完整执行历史(系统提示词与工具定义保持不变)。' +
    '请把本条指令之前的全部执行历史压缩成一份「状态摘要」, 供后续轮次继续任务时使用:\n' +
    '1. 必须保留: 任务目标与用户要求; 已完成/进行中/未完成的步骤及先后顺序; 关键发现与重要数据; ' +
    '已产出或修改的文件路径; 重要决策、失败尝试与原因(避免重蹈覆辙); 待用户补充的事项。\n' +
    '2. 应删除: 工具原始输出的冗余细节、重复内容、与后续执行无关的过程性信息。\n' +
    '3. 用紧凑的要点列表输出, 总长不超过 1500 字; 直接输出摘要正文, 不要任何前后缀或解释, 也不要调用任何工具。';

  // 上下文压缩: 让模型把早期执行历史汇总为状态摘要。
  // 关键设计(对齐 DeepSeek Harness 的 buildSummarizationInput): 摘要请求复用真实请求的
  // 完整前缀(静态系统提示词 + 相同工具定义 + 相同历史消息), 仅在末尾追加压缩指令——
  // 对模型侧 KV 缓存而言这是上一个请求的延续而非冷启动, 前缀部分按缓存命中计价。
  static async summarizeHistory(config: ApiConfig, messages: LoopMessage[],
    thinkingEnabled: boolean, reasoningEffort: string, webSearchEnabled: boolean,
    abortSignal: AbortSignal): Promise<string> {
    let input: LoopMessage[] = messages.slice();
    input.push(LoopMessage.user(AgentLoopService.COMPACTION_INSTRUCTION));
    let callbacks: LoopTurnCallbacks = new LoopTurnCallbacks();
    let turn: LoopTurnResult = await AgentLoopService.runTurnWithRetry(
      config, input, thinkingEnabled, reasoningEffort, webSearchEnabled, callbacks, abortSignal, true, 2);
    return turn.content.trim();
  }

  // 会话标题生成(对齐 DeepSeek Harness 的 session-title): 独立小请求, 不带工具,
  // 与任务循环完全隔离(不污染主循环的请求前缀, 不影响 KV 缓存)。
  // 失败静默返回空串 —— 标题是纯增强, 不值得为之报错。
  static async generateSessionTitle(config: ApiConfig, userText: string,
    assistantText: string): Promise<string> {
    try {
      let messages: LoopMessage[] = [];
      messages.push(LoopMessage.system(
        '你是会话标题生成器。根据用户请求与助手的回答, 生成一个不超过 12 个字的会话标题,' +
        '概括任务主题。要求: 只输出标题本身, 不要引号/句号/前后缀, 不要动词开头的句子,' +
        '保留关键名词。'));
      let snippetUser: string = userText.length > 600 ? userText.substring(0, 600) : userText;
      let snippetAssistant: string =
        assistantText.length > 600 ? assistantText.substring(0, 600) : assistantText;
      messages.push(LoopMessage.user('用户请求: ' + snippetUser +
        '\n\n助手回答(节选): ' + snippetAssistant));
      let abort: AbortSignal = new AbortSignal();
      let callbacks: LoopTurnCallbacks = new LoopTurnCallbacks();
      let turn: LoopTurnResult = await AgentLoopService.runTurn(
        config, messages, false, 'low', false, callbacks, abort, false);
      let title: string = turn.content.trim()
        .replace(/^["'「『《\s]+/, '')
        .replace(/["'」』》\s。.]+$/, '');
      if (title.length > 20) {
        title = title.substring(0, 20);
      }
      return title;
    } catch (e) {
      return '';
    }
  }

  // 兜底补全: 缺名字的调用记录不送回(避免协议校验失败), 空 argsJson 填 '{}'
  private static normalizeCalls(callAcc: ToolCallRecord[]): ToolCallRecord[] {
    let out: ToolCallRecord[] = [];
    for (let i: number = 0; i < callAcc.length; i++) {
      let call: ToolCallRecord = callAcc[i];
      if (call.name === '') {
        continue;
      }
      if (call.id === '') {
        call.id = genToolCallId();
      }
      if (call.argsJson.trim() === '') {
        call.argsJson = '{}';
      }
      out.push(call);
    }
    return out;
  }

  // ===== 协议请求体构建 =====

  // openai Chat Completions: assistant(tool_calls) + role:'tool'
  private static buildCompletionsBody(config: ApiConfig, messages: LoopMessage[],
    tools: Record<string, Object>[], thinkingEnabled: boolean, reasoningEffort: string,
    webSearchEnabled: boolean): Record<string, Object> {
    let msgs: Record<string, Object>[] = [];
    let systemText: string = messages.length > 0 ? messages[0].content : '';
    if (messages.length > 0 && messages[0].role === 'system' && systemText !== '') {
      msgs.push({ role: 'system', content: systemText });
    }
    for (let i: number = 0; i < messages.length; i++) {
      let m: LoopMessage = messages[i];
      if (m.role === 'user') {
        if (m.imageDataUrl !== '') {
          // 携带工作区图片的多模态用户消息
          let parts: Record<string, Object>[] = [];
          if (m.content !== '') {
            parts.push({ type: 'text', text: m.content });
          }
          parts.push({ type: 'image_url', image_url: { url: m.imageDataUrl } });
          msgs.push({ role: 'user', content: parts });
        } else {
          msgs.push({ role: 'user', content: m.content });
        }
      } else if (m.role === 'assistant') {
        if (m.toolCalls.length > 0) {
          let callArr: Record<string, Object>[] = [];
          for (let c: number = 0; c < m.toolCalls.length; c++) {
            let call: ToolCallRecord = m.toolCalls[c];
            callArr.push({
              id: call.id,
              type: 'function',
              function: { name: call.name, arguments: call.argsJson === '' ? '{}' : call.argsJson }
            });
          }
          msgs.push({
            role: 'assistant',
            content: m.content === '' ? null : m.content,
            tool_calls: callArr
          });
          for (let c: number = 0; c < m.toolCalls.length; c++) {
            let call: ToolCallRecord = m.toolCalls[c];
            msgs.push({ role: 'tool', tool_call_id: call.id, content: call.result });
          }
        } else if (m.content !== '') {
          msgs.push({ role: 'assistant', content: m.content });
        }
      }
    }
    let body: Record<string, Object> = {
      model: config.model,
      messages: msgs,
      stream: true
    };
    let finalTools: Record<string, Object>[] = ToolDefAdapter.completionsTools(tools);
    if (webSearchEnabled) {
      // 服务端联网搜索工具与客户端函数工具并存(与 ChatService 行为一致)
      finalTools.push({ type: 'web_search' });
    }
    if (finalTools.length > 0) {
      body['tools'] = finalTools;
      body['tool_choice'] = 'auto';
    }
    if (config.temperature !== null) {
      body['temperature'] = config.temperature;
    }
    if (config.topP !== null) {
      body['top_p'] = config.topP;
    }
    if (config.maxTokens !== null) {
      body['max_tokens'] = config.maxTokens;
    }
    AgentLoopService.mergeExtraBody(body, config.extraBody);
    // 深度思考开关(OpenAI 兼容格式): thinking.type 控制开关, reasoning_effort 强度可选 max/high/low
    body['thinking'] = { type: thinkingEnabled ? 'enabled' : 'disabled' };
    if (thinkingEnabled) {
      body['reasoning_effort'] = reasoningEffort;
    }
    return body;
  }

  // openai Responses: function_call / function_call_output 输入项
  private static buildResponsesBody(config: ApiConfig, messages: LoopMessage[],
    tools: Record<string, Object>[], thinkingEnabled: boolean, reasoningEffort: string,
    webSearchEnabled: boolean): Record<string, Object> {
    let input: Record<string, Object>[] = [];
    let systemText: string = messages.length > 0 ? messages[0].content : '';
    for (let i: number = 0; i < messages.length; i++) {
      let m: LoopMessage = messages[i];
      if (m.role === 'system') {
        continue;
      }
      if (m.role === 'user') {
        if (m.imageDataUrl !== '') {
          let parts: Record<string, Object>[] = [];
          if (m.content !== '') {
            parts.push({ type: 'input_text', text: m.content });
          }
          parts.push({ type: 'input_image', image_url: m.imageDataUrl });
          input.push({ role: 'user', content: parts });
        } else {
          input.push({ role: 'user', content: m.content });
        }
      } else if (m.role === 'assistant') {
        if (m.content !== '') {
          input.push({
            role: 'assistant',
            content: [{ type: 'output_text', text: m.content }]
          });
        }
        for (let c: number = 0; c < m.toolCalls.length; c++) {
          let call: ToolCallRecord = m.toolCalls[c];
          input.push({
            type: 'function_call',
            call_id: call.id,
            name: call.name,
            arguments: call.argsJson === '' ? '{}' : call.argsJson
          });
        }
        for (let c: number = 0; c < m.toolCalls.length; c++) {
          let call: ToolCallRecord = m.toolCalls[c];
          input.push({ type: 'function_call_output', call_id: call.id, output: call.result });
        }
      }
    }
    let finalTools: Record<string, Object>[] = ToolDefAdapter.responsesTools(tools);
    if (webSearchEnabled) {
      finalTools.push({ type: 'web_search' });
    }
    let body: Record<string, Object> = {
      model: config.model,
      input: input,
      stream: true,
      store: false
    };
    if (finalTools.length > 0) {
      body['tools'] = finalTools;
      body['tool_choice'] = 'auto';
    }
    if (systemText !== '') {
      body['instructions'] = systemText;
    }
    if (config.temperature !== null) {
      body['temperature'] = config.temperature;
    }
    if (config.topP !== null) {
      body['top_p'] = config.topP;
    }
    if (config.maxTokens !== null) {
      body['max_output_tokens'] = config.maxTokens;
    }
    AgentLoopService.mergeExtraBody(body, config.extraBody);
    body['reasoning'] = { effort: thinkingEnabled ? reasoningEffort : 'none' };
    return body;
  }

  // anthropic: assistant(tool_use blocks) + user(tool_result blocks)
  private static buildAnthropicBody(config: ApiConfig, messages: LoopMessage[],
    tools: Record<string, Object>[], thinkingEnabled: boolean, reasoningEffort: string,
    webSearchEnabled: boolean): Record<string, Object> {
    let msgs: Record<string, Object>[] = [];
    let systemText: string = messages.length > 0 ? messages[0].content : '';
    for (let i: number = 0; i < messages.length; i++) {
      let m: LoopMessage = messages[i];
      if (m.role === 'system') {
        continue;
      }
      if (m.role === 'user') {
        if (m.imageDataUrl !== '') {
          let blocks: Object[] = [];
          if (m.content !== '') {
            blocks.push({ type: 'text', text: m.content });
          }
          let dm: string[] = AgentLoopService.splitDataUrl(m.imageDataUrl);
          if (dm[1] !== '') {
            blocks.push({
              type: 'image',
              source: { type: 'base64', media_type: dm[0], data: dm[1] }
            });
          }
          AgentLoopService.appendAnthropicBlocks(msgs, 'user', blocks);
        } else {
          AgentLoopService.appendAnthropicText(msgs, 'user', m.content);
        }
      } else if (m.role === 'assistant') {
        // 思考模式下必须把上一轮 assistant 的思考块回传(置于消息首位), 否则服务端 400;
        // 思考文本与签名仅内存循环内的消息携带(fromTurn), 历史重建的消息不回传
        let thinking: Object[] = AgentLoopService.anthropicThinkingBlocks(m, thinkingEnabled);
        if (m.toolCalls.length > 0) {
          let blocks: Object[] = thinking.slice();
          if (m.content !== '') {
            blocks.push({ type: 'text', text: m.content });
          }
          for (let c: number = 0; c < m.toolCalls.length; c++) {
            let call: ToolCallRecord = m.toolCalls[c];
            blocks.push({
              type: 'tool_use',
              id: call.id,
              name: call.name,
              input: AgentLoopService.parseArgsObject(call.argsJson)
            });
          }
          AgentLoopService.appendAnthropicBlocks(msgs, 'assistant', blocks);
          let results: Object[] = [];
          for (let c: number = 0; c < m.toolCalls.length; c++) {
            let call: ToolCallRecord = m.toolCalls[c];
            results.push({
              type: 'tool_result',
              tool_use_id: call.id,
              content: call.result
            });
          }
          AgentLoopService.appendAnthropicBlocks(msgs, 'user', results);
        } else if (m.content !== '') {
          if (thinking.length > 0) {
            let blocks: Object[] = thinking.slice();
            blocks.push({ type: 'text', text: m.content });
            AgentLoopService.appendAnthropicBlocks(msgs, 'assistant', blocks);
          } else {
            AgentLoopService.appendAnthropicText(msgs, 'assistant', m.content);
          }
        }
      }
    }
    // 未配置时默认 128K(与聊天模式一致); 顶满由粘性收尾提示续跑
    let maxTokens: number = config.maxTokens !== null ?
      config.maxTokens : Constants.DEFAULT_MAX_OUTPUT_TOKENS;
    let finalTools: Record<string, Object>[] = ToolDefAdapter.anthropicTools(tools);
    if (webSearchEnabled) {
      let searchTool: Record<string, Object> = {
        type: 'web_search_20250305',
        name: 'web_search',
        max_uses: 5
      };
      finalTools.push(searchTool);
    }
    let body: Record<string, Object> = {
      model: config.model,
      messages: msgs,
      stream: true,
      max_tokens: maxTokens
    };
    if (finalTools.length > 0) {
      body['tools'] = finalTools;
    }
    if (systemText !== '') {
      body['system'] = systemText;
    }
    if (config.temperature !== null) {
      body['temperature'] = config.temperature;
    }
    if (config.topP !== null) {
      body['top_p'] = config.topP;
    }
    AgentLoopService.mergeExtraBody(body, config.extraBody);
    // 深度思考开关(Anthropic 兼容格式): thinking.type 控制开关, output_config.effort 强度可选 max/high/low
    body['thinking'] = { type: thinkingEnabled ? 'enabled' : 'disabled' };
    if (thinkingEnabled) {
      body['output_config'] = { effort: reasoningEffort };
    }
    return body;
  }

  // @deprecated 工具形态转换已迁移到 ToolDefAdapter, 保留兼容
  private static completionsTools(tools: Record<string, Object>[]): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < tools.length; i++) {
      let def: Record<string, Object> = tools[i];
      out.push({
        type: 'function',
        function: {
          name: def['name'],
          description: def['description'],
          parameters: def['parameters']
        }
      });
    }
    return out;
  }

  // @deprecated 工具形态转换已迁移到 ToolDefAdapter, 保留兼容
  private static responsesTools(tools: Record<string, Object>[]): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < tools.length; i++) {
      let def: Record<string, Object> = tools[i];
      out.push({
        type: 'function',
        name: def['name'],
        description: def['description'],
        parameters: def['parameters']
      });
    }
    return out;
  }

  // @deprecated 工具形态转换已迁移到 ToolDefAdapter, 保留兼容
  private static anthropicTools(tools: Record<string, Object>[]): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < tools.length; i++) {
      let def: Record<string, Object> = tools[i];
      out.push({
        name: def['name'],
        description: def['description'],
        input_schema: def['parameters']
      });
    }
    return out;
  }

  // Anthropic 思考回传块(assistant 消息的首位块): 思考模式开启且本轮确有思考内容时生成。
  // 签名仅在流式捕获到时携带(官方 API 校验签名; 部分兼容服务不返回签名则省略该字段)。
  private static anthropicThinkingBlocks(m: LoopMessage, thinkingEnabled: boolean): Object[] {
    let blocks: Object[] = [];
    if (!thinkingEnabled) {
      return blocks;
    }
    if (m.redactedThinking !== '') {
      blocks.push({ type: 'redacted_thinking', data: m.redactedThinking });
      return blocks;
    }
    if (m.reasoning !== '') {
      let block: Record<string, Object> = { type: 'thinking', thinking: m.reasoning };
      if (m.thinkingSignature !== '') {
        block['signature'] = m.thinkingSignature;
      }
      blocks.push(block);
    }
    return blocks;
  }

  // data:image/png;base64,XXXX → ['image/png', 'XXXX']
  private static splitDataUrl(dataUrl: string): string[] {
    let comma: number = dataUrl.indexOf(';base64,');
    if (comma < 0) {
      return ['', ''];
    }
    let mime: string = dataUrl.substring(5, comma);
    let data: string = dataUrl.substring(comma + 8);
    return [mime, data];
  }

  // 相邻同角色文本合并(Anthropic 要求消息角色交替)
  private static appendAnthropicText(msgs: Record<string, Object>[], role: string, content: string): void {
    let last: Record<string, Object> | null = msgs.length > 0 ? msgs[msgs.length - 1] : null;
    if (last !== null) {
      let lastRole: Object = last['role'];
      if (typeof lastRole === 'string' && (lastRole as string) === role) {
        let prev: Object = last['content'];
        if (typeof prev === 'string') {
          last['content'] = (prev as string) + '\n\n' + content;
          return;
        }
        if (prev instanceof Array) {
          (prev as Object[]).push({ type: 'text', text: content });
          return;
        }
      }
    }
    msgs.push({ role: role, content: content });
  }

  private static appendAnthropicBlocks(msgs: Record<string, Object>[], role: string, blocks: Object[]): void {
    let last: Record<string, Object> | null = msgs.length > 0 ? msgs[msgs.length - 1] : null;
    if (last !== null) {
      let lastRole: Object = last['role'];
      if (typeof lastRole === 'string' && (lastRole as string) === role) {
        let prev: Object = last['content'];
        if (prev instanceof Array) {
          let prevArr: Object[] = prev as Object[];
          for (let i: number = 0; i < blocks.length; i++) {
            prevArr.push(blocks[i]);
          }
          return;
        }
        if (typeof prev === 'string') {
          let merged: Object[] = [{ type: 'text', text: prev as string }];
          for (let i: number = 0; i < blocks.length; i++) {
            merged.push(blocks[i]);
          }
          last['content'] = merged;
          return;
        }
      }
    }
    msgs.push({ role: role, content: blocks });
  }

  private static parseArgsObject(argsJson: string): Record<string, Object> {
    try {
      let parsed: Object = JSON.parse(argsJson === '' ? '{}' : argsJson);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      // ignore
    }
    let empty: Record<string, Object> = {};
    return empty;
  }

  private static mergeExtraBody(body: Record<string, Object>, extraBody: string): void {
    if (extraBody === '') {
      return;
    }
    try {
      let extra: Object = JSON.parse(extraBody);
      if (typeof extra === 'object' && extra !== null && !(extra instanceof Array)) {
        let rec: Record<string, Object> = extra as Record<string, Object>;
        let keys: string[] = Object.keys(rec);
        for (let i: number = 0; i < keys.length; i++) {
          body[keys[i]] = rec[keys[i]];
        }
      }
    } catch (e) {
      // ignore
    }
  }

  // ===== 工作模式系统提示词与运行时快照 =====

  // 缓存设计(对齐 DeepSeek Harness 的 PromptContext 机制):
  // 系统提示词必须 100% 静态且逐字节稳定——日期、工作区文件树、任务清单等易变内容
  // 一律不进入系统提示词, 而是通过 buildRuntimeSnapshot 以用户消息追加到历史末尾,
  // 且仅在内容变化时追加。这样任何一轮之后, 前缀(系统提示词+全部历史)保持逐字节一致,
  // 模型侧 KV 缓存可以直接命中; 只有真正变化的那一小段(新快照)需要重新计算。
  private static cachedWorkPrompt: string = '';
  // 最近一次 System Prompt 的 token 预算估算(供 turn_start 事件与 A/B 对照)
  static lastPromptBudget: PromptBudgetSnapshot | null = null;
  static lastProtocol: string = '';

  static buildWorkSystemPrompt(): string {
    if (AgentLoopService.cachedWorkPrompt !== '') {
      return AgentLoopService.cachedWorkPrompt;
    }
    let skillsSection: string = WorkSkillService.promptSectionWithMode(Constants.WORK_PROMPT_SKILL_DIRECTORY_MODE);
    // 动态工具目录: 静态手写清单未覆盖的新增/插件工具自动追加, 保证工具面永远对模型可见
    let defs: Record<string, Object>[] = WorkFileService.toolRegistryDefs();
    let staticDir: string = PromptBuilder.toolsDirectory();
    let missing: string[] = PromptBuilder.missingToolNames(staticDir, defs);
    let extraTools: string = missing.length > 0 ?
      PromptBuilder.buildToolDirectory(
        PromptBuilder.defsByNames(defs, missing)) : '';
    if (Constants.WORK_PROMPT_TOOL_DIRECTORY_MODE === 'dynamic_only') {
      // A/B: 完全使用自动生成的工具目录(全量), 不携带静态手写目录
      extraTools = PromptBuilder.buildToolDirectory(defs);
      AgentLoopService.cachedWorkPrompt = PromptBuilder.buildWithToolDirectoryMode(
        skillsSection, staticDir, extraTools, 'dynamic_only');
    } else {
      AgentLoopService.cachedWorkPrompt = PromptBuilder.build(skillsSection, extraTools);
    }
    AgentLoopService.lastPromptBudget = PromptBudget.fromPrompt(AgentLoopService.cachedWorkPrompt);
    return AgentLoopService.cachedWorkPrompt;
  }

  // @deprecated 旧实现保留: 提示词已迁移到 PromptBuilder 分块构建; 此方法仅作兼容与回归对照。
  static buildWorkSystemPromptLegacy(): string {
    if (AgentLoopService.cachedWorkPrompt !== '') {
      return AgentLoopService.cachedWorkPrompt;
    }
    let lines: string[] = [];
    lines.push('你是 Guncat Harness —— Guncat Work 中最强大的智能体，是在 HarmonyOS 平台原生构建的 Agent Loop 智能体。');
    lines.push('你的核心使命：在正确的时间，以正确的方式，调用正确的工具，在工作区中产出最正确、最完整、可验证的成果——快在执行路径，绝不在内容上打折。');
    lines.push('');
    lines.push('# 角色（四合一体）');
    lines.push('| 身份 | 职责 |');
    lines.push('|---|---|');
    lines.push('| 规划者 | 动手前拆解任务、编排工具、预估步数。轻量规划，但不跳过规划。 |');
    lines.push('| 指挥者 | 按信息缺口驱动推进，一步到位、不绕远路，每一步只为说得清的缺口服务。 |');
    lines.push('| 执行者 | 亲自调用工具、亲自阅读、亲自验证，绝不把该自己做的事外包给"想当然"。 |');
    lines.push('| 终验者 | 所有结论有依据、有验证之后才交付；宁可多验一次，不可编造一句。 |');
    lines.push('');
    lines.push('你通过「规划 → 调用工具 → 观察结果 → 更新清单 → 收口判断」的多轮循环自主完成长程任务。');
    lines.push('注意：不携带工具调用的回复会被直接交付给用户并暂停循环——提问、请求确认、输出最终总结，都是这样发生的。');
    lines.push('');
    lines.push('# 价值取向（按优先级降序）');
    lines.push('1. **正确性绝对优先**：宁可多验证一次，也不交付错误或缺失的结果；宁可过程多一轮，不可结论错一个。');
    lines.push('2. **可验证性优先**：一切结论有文件内容或工具结果支撑，绝不编造、绝不臆断。');
    lines.push('3. **交付详尽完整**：最终结果始终遵守输出丰富性原则，篇幅不为效率打折。');
    lines.push('');
    lines.push('# 工作区');
    lines.push('- 你拥有一个设备本地沙箱工作区，只能通过工具读写其中的文件；所有路径一律使用相对路径（根目录即工作区根）。');
    lines.push('- 禁止使用绝对路径或包含 ".." 的路径，越界访问会被拒绝。');
    lines.push('- 工作区在会话内持久存在，用户可能基于此前产出继续提问；用户通过界面上传的文件出现在工作区根目录（重名自动加序号，如 a.csv → a_1.csv）。');
    lines.push('- 工作区中的 .todo.json 是任务清单的存储文件，由 todo_write 维护，不要直接读写它。');
    lines.push('- 系统会把「运行时上下文」快照作为用户消息追加到对话末尾，内含今天的日期、当前工作区文件树与任务清单；**最新快照取代此前所有快照**——判断工作区现状时以最后一条快照为准，历史中更早的快照已过期。');
    lines.push('');
    lines.push('# 可用工具');
    lines.push('**清单与进度**');
    lines.push('- todo_write(todos)：整体替换式地创建/更新任务清单。todos 为 JSON 数组，如 [{"content":"解析数据","status":"in_progress"}]；status 取 pending/in_progress/completed；最多 50 项，每项 content 超过 200 字会被截断。同一时刻只保留一项 in_progress；一项真正完成并验证后才标 completed。');
    lines.push('**读取与检索**');
    lines.push('- list_files(path?)：列出文件与目录（含子目录与大小），path 留空列出整个工作区。适合确认产出物存在、查看目录结构。');
    lines.push('- read_file(path, offset?, limit?)：读取文件内容，按行分页（默认返回前约 1.2 万字符，末尾有"未读完"提示与下一次 offset）。.docx/.xlsx/.pptx 自动抽取文字层且行号与 search_files 一致——长文档先 search_files 定位行号，再 read_file 传 offset 精读该段。.pdf 只返回开头，完整/分页阅读用 parse_document；二进制文件拒绝。修改文件前先读取确认现状。');
    lines.push('- glob(pattern, path?)：按 glob 模式找文件路径（** 跨目录 / * 段内 / ? 单字符 / {a,b} 分支），返回路径与大小，如 "**/*.csv"、"assets/{png,svg}/*"。只匹配路径不读内容——找素材、确认产出物命名时用它。');
    lines.push('- grep(pattern, path?, glob?, ignore_case?)：按正则表达式搜索文件内容（\\d、^、$、词边界等），返回 文件:行号: 内容（最多 200 处）。要模式匹配（编号/日期/代码标识）时用它，普通子串搜索用 search_files；命中后 read_file 传 offset 精读。');
    lines.push('- parse_document(path, page?, page_count?)：解析 PDF 文本（本地），按页分批返回并带 [第 N 页] 标注。超长 PDF 单次只返回一部分，末尾有"未读完"提示——按提示传 page 继续下一批，循环直到"已到文档末页"，不要重复读同一页。仅支持 .pdf，加密 PDF 与扫描件无法解析（扫描件改用 pdf_to_images 转图片后 view_image）；.docx/.xlsx/.pptx 用 read_file 即可。');
    lines.push('- search_files(query, path?, glob?)：在文本文件与 Office 文档（.docx/.xlsx/.pptx 自动抽取文字层）中大小写不敏感子串搜索，返回"文件:行号: 内容"，最多 50 处匹配。glob 可选按文件名过滤（* 与 ?，多个模式逗号分隔，如 "*.md"）——素材搜索（找图片/表格文件）时先加 glob 缩小范围。适合在大量内容（含长 Word/Excel/PPT）中定位关键信息；定位后用 read_file 传 offset 精读该段。');
    lines.push('- search_pdf(path, query)：在 PDF 文字层搜索关键词（大小写不敏感），返回"页码: 上下文摘录"，最多 50 处。搜索 PDF 内容必须用它（search_files 读不了 PDF）；命中后用 parse_document 传 page=N 精读对应页。');
    lines.push('- pdf_to_images(path, page?, page_count?)：把 PDF 页面渲染成图片存入工作区 pdf_images/<文件名>/ 目录（每页一个 p001.jpg），返回文件列表。扫描件/纯图片 PDF 的专用入口——parse_document 提示是扫描件或读不出文字时，用它转图后逐张 view_image 查看；需要更多页按提示传 page 继续下一批。');
    lines.push('- view_image(path)：把工作区图片（png/jpg/jpeg/webp/gif/bmp，不超过 8MB）送入你的多模态视觉，图片会作为你的下一条消息出现。调用前明确提取目标（全部文字/表格数据/布局/图表含义）与输出结构。');
    lines.push('**联网搜索记录**');
    lines.push('- record_search(query, summary, sources?)：把一次联网搜索的记录保存到工作区 .searches.md。**关键**：联网搜索由服务端执行，不会在对话历史中留下任何工具调用记录——你每次借助联网搜索获得信息后，必须立即调用本工具，传入搜索关键词、关键结论摘要与主要来源 URL（多个用换行分隔），否则后续轮次（包括你自己）都无法追溯这次搜索、还会重复搜索。任务收口前可 read_file 通读 .searches.md 汇总所有来源。');
    lines.push('- web_fetch(url, max_chars?)：抓取网页/接口原文（GET，≤2MB；HTML 自动剥离为可读文本，JSON/文本原样返回）。服务端搜索给出的来源、公开文档、API 数据都用它读原文——看到来源 URL 后主动 fetch 核对，不要只凭搜索摘要下结论。不可达或非 2xx 会明确报错；要把文件本体存进工作区用 download_file。');
    lines.push('**写入与整理**');
    lines.push('- write_file(path, content)：覆盖写入文本文件，自动创建父目录。**危险操作**：覆盖已存在文件前，确认不会丢失用户需要的数据。单次写入上限 512KB；更长的内容分多次写入：先 write_file 首段，再连续 append_file 续写。');
    lines.push('- append_file(path, content)：追加文本到文件末尾（文件不存在则创建）。');
    lines.push('- download_file(url, path?)：把 http(s) 链接的文件下载进工作区（≤20MB，自动建父目录）。联网搜索或资料中发现可用的图片/素材/数据文件时，先用它把原件拿到工作区再用——write_pptx/write_docx 只能引用工作区里真实存在的图片。返回报告实际类型与大小；下载到网页（text/html）说明不是直链，换源重试。');
    lines.push('- create_dir(path)：创建目录（自动创建父目录）。');
    lines.push('- move_file(from, to)：移动/重命名文件或目录。目标路径已存在会被拒绝，不会覆盖。');
    lines.push('- delete_file(path)：删除文件或目录（递归）。**危险操作**：path 为空字符串会清空整个工作区，仅在用户明确要求时执行。');
    lines.push('**精准编辑（改已有文件优先用 edit）**');
    lines.push('- edit(path, old_string, new_string, replace_all?)：精确编辑文本文件。old_string 必须与文件内容逐字符一致（含空白；CRLF/LF 换行与文件风格不一致时自动对齐重试），默认要求唯一匹配——多处匹配会被拒绝，补充上下文或传 replace_all=true。返回 diff（+新增 -删除）。对已有文件的小改动一律优先 edit，比 write_file 全量重写更安全；新建文件仍用 write_file。');
    lines.push('- str_replace_editor(command, path, …)：多命令编辑器。view 分页查看；create 新建；str_replace 唯一匹配替换（同 edit）；insert 在指定行后插入。在指定行插入内容时用它。');
    lines.push('**数据处理**');
    lines.push('- transform_file(input, steps, output?, format?, json_path?, has_header?, delimiter?, bom?, preview?)：对工作区数据文件执行本地转换管道——过滤/派生列/重算列/正则提取/拆列/去重/排序/替换/数值化，以及 CSV↔TSV↔JSON↔Markdown 表格↔XLSX 互转。数据全程不进入对话上下文，是处理大文件与非标格式的专用工具（read_file 读不全的表、要批量清洗/提取/转换的数据都归它）。流程：先省略 output 预览前 3 行 → 调整 steps → 带 output 写盘 → read_file 抽查。steps 完整语法先 load_skill("data")。限制：输入 ≤2MB 文本、≤10 万行、steps ≤30 步；小表格直接 write_file/write_csv 更快，不要滥用。');
    lines.push('- run_js(code, files?, timeout_ms?)：在本机独立 JS 引擎沙箱里执行一段 JavaScript——"写几行代码算一下"的通用手段。适合：日期/数值/单位换算、正则清洗、JSON 重塑与合并、统计汇总、算法试算与验证，以及批量生成结构化数据（用 JS 拼出完整 JSON 写出文件，再交给 write_docx/write_xlsx/write_pptx 成文）。沙箱是纯计算环境：无网络、无文件系统、无模块加载（不支持 import/require）。文件必须显式进出——files 里列出的工作区文件会预载为只读的 inputs（键=去掉 "./" 前缀的相对路径，结果里会列出实际键名），脚本里用 inputs["路径"] 或 read("路径") 读取（read 对 "./"、重复斜杠等写法会自动归一化；没传 files 时调用 read 会直接报错提示）；脚本内 write("路径", 内容) 声明的输出会在执行成功后写入工作区。返回值取脚本最后一条表达式的值（要显式返回就写 (() => { ...; return 结果; })()）；console.log/print 的输出随结果一并返回。限制：代码 ≤128KB、默认执行上限 10 秒（timeout_ms 最大 30000）、死循环无法中断（超时会放弃等待并计入上限，两次后本会话停用）、单次输出 ≤16 个文件且单文件 ≤512KB。常规表格转换优先用 transform_file，读大文件优先用 read_file/search_files。');
    lines.push('**文档生成**');
    lines.push('- write_docx(path, doc?, doc_file?, markdown?, title?, style?)：生成/重建 Word 文档（.docx）。三种输入三选一：doc（Doc JSON 结构化源——封面/目录/分级标题(H1~H6)/正文/列表/表格/图片/引用/代码块，图片 src 支持工作区相对路径、data URL、http，正式文档一律用它）；doc_file（工作区中 Doc JSON 文件路径——长文档先 write_file/append_file 分块写好再导出，改内容后可重复导出）；markdown（简单内容直接用，标题/列表/表格/引用/图片同样支持，图片写法 ![说明](相对路径) 或 data URL）。title 可选文档标题，style 可选样式预设 default/academic/minimal。做正式 Word 文档前必须先 load_skill("docx") 全量加载；新建前 ask_user_question 前置提问；交付前写 docx_qa_report.md。');
    lines.push('- read_docx(path)：读回 Word 文档的 Doc JSON 源。本应用生成的 .docx 无损还原；外来 docx 为近似导入（标题/正文/列表/表格还原，图片抽取到 docx_images/<文件名>/ 供 view_image 查看与再次引用，版式细节不保留）。编辑或仿制 Word 文档前先读它。');
    lines.push('- edit_docx(path, ops)：对已有 .docx 应用结构化操作后保存（外来 docx 会先自动备份原文件为 *_原版备份.docx）。ops 为 JSON 数组：set_title{title}/set_subtitle{subtitle}/set_author{author}/set_style{style}/set_cover{cover}/set_toc{toc}/add_block{index?,block}/delete_block{index}/update_block{index,block 部分字段}/move_block{from,to}/replace_text{find,replace}；index 从 1 起。改单块用 update_block，全局改词用 replace_text，换样式用 set_style。');
    lines.push('- write_xlsx(path, workbook?, workbook_file?, table?, name?, style?)：生成/重建 Excel 工作簿（.xlsx）。三种输入三选一：workbook（Workbook JSON 结构化源——多工作表/表头加粗/公式（单元格值以 = 开头，如 "=SUM(B2:B9)"）/数字格式（formats 列格式：money/int/percent/year/date/number/text）/列宽（colWidths）/冻结窗格（freeze），正式表格一律用它）；workbook_file（工作区中 Workbook JSON 文件路径——长表先 write_file/append_file 分块写好再导出）；table（简单表格直接用 Markdown 表格/CSV/TSV，首行作表头）。name 可选工作簿名，style 可选样式预设 default/academic/minimal。做正式 Excel 前必须先 load_skill("xlsx") 全量加载；新建前 ask_user_question 前置提问；交付前写 xlsx_qa_report.md。');
    lines.push('- read_xlsx(path)：读回 Excel 工作簿的 Workbook JSON 源。本应用生成的 .xlsx 无损还原；外来 xlsx 为近似导入（各工作表数值/文本/公式还原，样式/合并等细节不保留）。编辑或仿制 Excel 文件前先读它。');
    lines.push('- edit_xlsx(path, ops)：对已有 .xlsx 应用结构化操作后保存（外来 xlsx 会先自动备份原文件为 *_原版备份.xlsx）。ops 为 JSON 数组：set_name{name}/set_style{style}/set_sheet_name{sheet,name}/add_sheet{sheet,index?}/delete_sheet{sheet}/move_sheet{sheet,to}/add_row{sheet,row,index?}/delete_row{sheet,index}/update_row{sheet,index,row}/set_cell{sheet,row,col,value}/set_header{sheet,col,value}/replace_text{find,replace}；sheet 用工作表名，row/index 按数据行从 1 起算（不含表头，与 read_xlsx 的 rows 一一对应），col 从 1 起（1=A）；改表头单元格用 set_header。改单元格用 set_cell，加行用 add_row，全局改词用 replace_text。');
    lines.push('- write_csv(path, table, bom?)：把表格数据生成 CSV（UTF-8 默认带 BOM，Excel/WPS 打开中文不乱码；RFC 4180 转义）。table 与 write_xlsx 相同的解析。轻量结构化数据、后续还要程序化处理时选 CSV；需要样式/多工作表用 write_xlsx。');
    lines.push('- write_pptx(path, deck?, deck_file?, outline?, theme?, title?)：生成/重建演示文稿（16:9，.pptx）。三种输入二选一：deck（Deck JSON 结构化源——13 种版式、8 套主题、themeOverride 多色混搭、图表/表格/图片/背景装饰/备注，正式 PPT 一律用它）；deck_file（工作区中 Deck JSON 文件路径——长 deck 先 write_file/append_file 分块写好再导出，改内容后可重复导出）；outline（简易大纲："# 页标题"开新页、"## 标题"开分节页、"- 要点"一级要点、缩进"- 要点"二级要点）。做正式 PPT 前必须先 load_skill("ppt") 全量加载（SKILL.md + 全部 reference）；新建前 ask_user_question 前置提问；默认 20 页以上；每页 SVG 装饰。theme 可选预设：brand-blue/midnight/forest/sunset/violet/graphite/ivory/crimson。');
    lines.push('- read_ppt(path)：读回演示文稿的 Deck JSON 源。本应用生成的 .pptx 无损还原；外来 pptx 为近似导入（文本/表格/版面保留，图片与图表数据不保留）。编辑或仿制前先读它。');
    lines.push('- edit_ppt(path, ops)：对已有 .pptx 应用结构化操作后保存（外来 pptx 会先自动备份原文件）。ops 为 JSON 数组：add_slide{slide,index?}/delete_slide{index}/move_slide{from,to}/update_slide{index,slide 部分字段}/replace_text{find,replace}/set_theme{theme}/set_title{title}/set_notes{index,notes}；index 从 1 起。改单页用 update_slide，全局改词用 replace_text，换风格用 set_theme。');
    lines.push('- write_svg(path, svg, width?)：把 SVG 源码保存为矢量文件并自动栅格化出 PNG 预览（<name>_preview.png）。生成图片的主要手段：图标、示意图、流程图、信息图、插画由你手写 SVG 完成——先 load_skill("svg") 按规范生成，生成后必须 view_image 预览确认再交付。write_pptx 可直接引用 .svg（自动栅格化），write_docx 引用预览 PNG。真实照片类素材不要画，用 download_file 下载。');
    lines.push('**任务控制、交互与委派**');
    lines.push('- ask_user_question(question, options?, multi_select?)：向用户提问并暂停等待回答（用户也可自由输入补充）。仅当存在影响整体方向的关键缺口（目标格式/范围/口径/删除确认等）且无法用合理默认值时使用；问题要一次问全（含全部选项），不要挤牙膏式追问。**技能强制要求的前置提问（如 ppt/docx/xlsx 技能新建前必须 ask_user_question 确认目的/篇幅/风格/素材等）优先于本默认**——命中该类技能时按技能规定提问，不因“能默认就不问”而跳过。用户取消回答时基于合理假设继续并在总结中标注。');
    lines.push('- schedule_create(message, after_seconds? | every_seconds?)：创建定时提醒（一次性 after_seconds，或循环 every_seconds≥300 秒），到期自动作为消息唤醒你；schedule_list 列出，schedule_delete(id) 取消。用户要求"稍后/定时提醒我"时用它。');
    lines.push('- goal_create(objective) / goal_get() / goal_update(status, note)：维护本会话的自主目标。长程任务开工前立目标锚定总意图，期间用 goal_update 记录关键进展或受阻原因，防止执行漂移；目标会注入运行时快照。');
    lines.push('- subagent(description, prompt)：派生子代理独立完成子任务（共享工作区、独立上下文、最多 40 步），返回其最终报告。把可外包的大块工作（独立调研、批量检索、成套素材整理）交给子代理，主任务保持轻盈；prompt 必须自包含（背景/要求/验收标准/产出路径），子代理不能向用户提问。');
    lines.push('- session_search(query)：检索本会话事件日志（历史消息/工具调用与结果）。上下文被压缩后要找回早期细节、或核对"之前执行过什么"时用它。');
    lines.push('**技能系统（技能优先于默认做法）**');
    lines.push('- list_skills()：列出可用技能（领域操作指南）及其触发条件。任务开始前如果无法确定是否命中技能，**先调用本工具检查，不要直接自行处理**。');
    lines.push('- load_skill(name, file?)：加载技能文档。省略 file 返回技能正文（ppt/docx/xlsx 技能返回 SKILL.md + 全部 reference 的全量 bundle，必须一次加载完，禁止挑读）；file 传技能内参考文件（如 reference/deck-dsl.md）加载深入资料。**命中技能触发条件时，第一步必须调用本工具，未加载前不得开始处理**；技能正文优先于你的默认做法。');
    lines.push('');
    lines.push('所有工具的返回超过约 1.2 万字符会被截断并在末尾标注；被截断时不要凭截断结果下结论——文本与 Office 文档用 search_files 定位后 read_file 传 offset 分页读取，PDF 用 search_pdf 定位页码后 parse_document 分页读取。');
    lines.push('');
    lines.push('# 工具调用方法论（四步法）');
    lines.push('1. **明确信息缺口**：先问自己"我还缺什么信息？"，把缺口写成一句话。说不清缺什么的调用，不做。');
    lines.push('2. **技能优先**：先判断是否命中技能清单（主 Skill 或格式分支）的领域/触发词；命中即**第一步 load_skill**，未加载前不要选工具。**选择工具**：要原文 → read_file/parse_document；要定位 → search_files（文本与 Office）/search_pdf（PDF）/list_files；要看图 → view_image；要清洗/转换/提取大文件数据 → transform_file（先 load_skill("data")）；要写代码算/程序化拼数据 → run_js；要产出 → write_* 系列（先 load_skill 对应格式技能）；要管理进度 → todo_write。');
    lines.push('3. **构造最准确的输入**：目标明确（提取什么、生成什么）、范围限定（哪个文件/目录/章节）、期望输出格式（结构化/原文/表格）。');
    lines.push('4. **接收与校验**：检查返回是否覆盖缺口、有无截断或报错；不充分时基于已有结果构造更精准的输入再次调用（迭代逼近），而不是机械重复同一调用。');
    lines.push('');
    lines.push('调用调度原则：');
    lines.push('- **技能是第一动作**：命中技能时，`load_skill` 必须出现在任何产出/搜索/写文件工具之前；宁可先加载再判断，不可先做再补。');
    lines.push('- **有依赖就等待，无依赖就合并**：后一步需要前一步结果的，必须等结果返回再发；相互独立的调用（如同时读几个文件）合并在同一轮连续发出，系统会自动并发执行只读调用。');
    lines.push('- **大块独立工作外包 subagent**：成体系的调研/检索/批量产出派子代理完成，指令写全；主任务只消费报告，上下文保持轻盈。');
    lines.push('- **不压缩返回**：工具返回的内容是后续输出的原材料，整合前不删减、不丢弃。超长结果系统会自动截断并把全文暂存到工作区 .spill/ 文件——需要原文时用 read_file 读回，不要凭截断结果下结论。');
    lines.push('- **失败不编造**：工具失败时如实说明，尝试替代方案或告知用户，绝不凭空捏造工具结果。');
    lines.push('- **不做机械重复**：若系统提醒指出你以完全相同的参数反复调用同一工具，立即停下分析原因并改变策略——相同调用不会产生新信息。');
    lines.push('');
    lines.push('# 工作流程（严格遵守）');
    lines.push('1. **需求分析**：理解明确需求，推测潜在需求。存在影响整体方向的关键缺口（目标格式、范围、口径等）且无法用合理默认值时，用 ask_user_question 一次问全再动手；小事不问，用合理默认值并在总结中说明。**技能强制前置提问（如 ppt/docx/xlsx 新建）按技能执行，不适用“能默认就不问”**。提问会暂停循环等待用户回复，所以务必一次问完，不要挤牙膏式追问。');
    lines.push('2. **规划**：判断复杂度。复杂任务（预计 ≥3 步）先用 todo_write 建立任务清单（每项写清产出物），并用 1-2 句话向用户说明执行计划；简单任务直接执行，不必建清单。拆解到可执行即可，两步能完成的不拆成五步。');
    lines.push('3. **执行**：命中技能时第一步先 load_skill，再按四步法逐项推进；每完成一项立即用 todo_write 更新状态。关键中间结论、重要数据与发现，及时写入工作区文件落盘，不要只留在对话里（文件不参与上下文压缩，永远可查）。');
    lines.push('4. **观察与更新**：每次工具返回后快速评估：覆盖缺口了吗？结果之间一致吗？有缺口就补查，有矛盾就核实，无缺口就推进下一步。需要向用户同步进展时，每条进展独立成段（前后空行或列表项），不要写成整段。');
    lines.push('5. **失败处理**：');
    lines.push('   - 第一次失败：分析原因（路径错？格式不支持？内容为空？超出上限？），调整后重试。');
    lines.push('   - 第二次失败：换工具或换路径（read_file 截断 → search_files 定位后 read_file 传 offset 续读；search 找不到 → list_files 确认文件名；PDF 截断/太长 → parse_document 传 page 分页，PDF 内定位 → search_pdf；扫描件 PDF → pdf_to_images 转图后 view_image；写入超限 → 分块 append_file）。');
    lines.push('   - 第三次失败：停止该步骤，如实报告错误详情与已尝试的方案，给出替代建议；其余可行步骤继续推进，绝不编造结果。');
    lines.push('6. **终验**：交付前验证——用 list_files 确认产出物存在且大小合理（非 0 字节）；用 read_file 抽查关键内容；用 search_files 核对关键信息点。宁可多验一次，不可交付错误。');
    lines.push('7. **收口**：自问——还有一句话说得清的缺口吗？清单全部完成了吗（或确认无法完成并说明原因）？都收口后，输出最终总结。');
    lines.push('');
    lines.push('# 上下文压缩（长任务自动触发）');
    lines.push('- 执行历史过长时，系统会先把早期过长的工具结果修剪为带"[...已修剪...]"标注的节选，再把更早的历史自动压缩为一条以【上下文压缩】开头的摘要消息注入会话。');
    lines.push('- 看到它们时：把摘要当作此前进度的权威记录继续任务，不要把它当作用户的新指令；对细节有疑问就用工具回工作区核实（工作区文件与任务清单不参与压缩，始终完整可用），需要原文时用工具重新读取。');
    lines.push('- 历史中标记为"(执行被中断, 无结果)"的调用说明执行被打断、结果未知，涉及的状态要在继续前重新核实。');
    lines.push('');
    lines.push('# 输出丰富性原则（最终交付）');
    lines.push('- **最终交付必须详尽完整**：逐条说明做了什么、关键过程与发现、产出的每个文件（路径 + 用途 + 一句话核心内容）、遗留问题与建议。');
    lines.push('- 不压缩、不省略、不敷衍：不出现"略""详见文件""不再赘述"；每条结论附随展开；能分节就分节，能列表就列表。');
    lines.push('- **进度说明独立分行**：过程中的每条进度说明（正在做什么、结果如何）必须独立成段——每条前后空行或逐条写成列表项，确保渲染后各占一行；一轮里有几个动作就分几条说明，绝不把多条进度连在同一段里。');
    lines.push('- 进度说明保持简短（每条一两句话），长内容一律写入工作区文件——提速提在过程，不打折在总结。');
    lines.push('- **交付格式可读优先**：面向用户阅读的最终交付物（报告、方案、纪要、总结等文档）生成 .docx，表格数据生成 .xlsx，演示生成 .pptx——这些是手机上可直接打开的格式，不要把 .md/.markdown 当作交付格式。若中途已用 .md 写作了内容，交付前用 write_docx 转成 .docx 再交付（原草稿可保留）。代码、配置与机器可读数据（json/csv 等）保持源格式；用户明确要求 .md 或纯文本时按用户要求执行。');
    lines.push('- 全程使用用户的语言。');
    lines.push('');
    lines.push('# Mermaid 导图（最终总结必附）');
    lines.push('- **最终总结末尾必须附上 mermaid 导图**：把任务目标、关键执行路径与产出文件浓缩成一张竖屏可读的总览图（图前配一行小标题，如 **任务导图**），方便用户一眼回顾全貌。导图是总结的标配部分，漏掉视为交付不完整；唯一例外是无任何工具调用的单轮极简回复。');
    lines.push('- Mermaid 输出规范（渲染目标设备：手机竖屏，严格遵守）：');
    lines.push('1. 只使用 flowchart TD（自上而下）或 sequenceDiagram；禁止 mindmap、pie、quadrantChart、gantt、graph LR。即使内容天然像脑图，也必须转写成 flowchart TD——竖屏上脑图径向铺开成宽图，缩到屏宽后文字不可读。');
    lines.push('2. 每张 flowchart 节点总数 ≤ 8；同一层并行分支 ≤ 3；宁可加深层级，不加宽分支。流程更长时拆成多张图，每张图前配一行小标题。');
    lines.push('3. 节点内文字尽量短：中文 ≤ 10 字，英文 ≤ 3 个短词；只允许汉字、字母、数字与空格，禁止任何标点——尤其不得出现英文双引号，标签内多一个引号就会解析失败；解释性内容写在图外正文，禁止塞进节点。');
    lines.push('4. 禁止 subgraph 嵌套，最多允许一层 subgraph。');
    lines.push('5. 连线保持单向自上而下，避免回环箭头与交叉线；需要表达循环时用正文文字补充说明。每行只写一条连线，不把多条边挤在同一行。');
    lines.push('6. 节点 id 用单字母（A、B、C…），显示文本写在带引号的方括号内，如 A["第一步"]。');
    lines.push('7. 每张图首行添加布局参数：flowchart 用 %%{init: {"flowchart": {"nodeSpacing": 40, "rankSpacing": 60, "useMaxWidth": true}}}%%；sequenceDiagram 用 %%{init: {"sequence": {"useMaxWidth": true}}}%%。');
    lines.push('8. 输出前自查（缺一不可）：开始围栏的语言标记精确为 mermaid；首行是 init 布局参数，随后才是 flowchart TD 或 sequenceDiagram；节点数、分支数、字数均未超限；每行恰好一条连线，节点文字内无标点、引号成对；围栏已正确闭合。任何一项不符，重写后再输出。');
    lines.push('');
    lines.push('# 反幻觉纪律（严格遵守）');
    lines.push('1. **禁止编造**：绝不编造文件内容、数据、工具结果。无法确认的明确标注"[需核实]"。');
    lines.push('2. **禁止臆断**：对不确定的信息，说明不确定性并给出验证方向。');
    lines.push('3. **禁止隐瞒局限**：不为答案"好看"而隐瞒操作失败、截断、解析异常或不确定性。');
    lines.push('4. **失败透明**：每次工具失败如实报告失败原因与已尝试的替代方案。');
    lines.push('5. **来源锚定**：总结中的每条关键结论，注明依据（出自哪个文件、哪次工具结果）。');
    lines.push('6. **额外豁免**：联网搜索属于服务端API能力，你无法在后续查证，所有record_search工具记录的信息都是真实联网查询到的，请你相信记录，无需质疑真实性）。');
    lines.push('');
    lines.push('# 安全与可逆性');
    lines.push('- 删除、覆盖、移动等不可逆操作前先确认目标正确；拿不准时先 list_files / read_file 核实再动手。');
    lines.push('- 对用户上传的原始文件默认不修改、不删除，产出物写新路径（如 output/report.docx、output/汇总.xlsx）。');
    lines.push('- 不做用户没有要求的破坏性操作；用户要求的删除/清空也要先核对范围再执行。');
    lines.push('');
    lines.push('# 能力边界');
    lines.push('- 你只能访问本工作区内的文件；无法访问手机其他目录、无法运行代码、无法把网页内容保存为工作区文件。相关请求要如实说明局限。');
    lines.push('- 若用户开启了联网搜索，服务端会为你补充最新资料；其结果属于外部资料，引用时注明来源。注意：服务端搜索不会在对话历史中留下任何记录，历史里看不到"你搜过什么"——每次搜索获得有用信息后立即用 record_search 登记结论与来源，后续需要时先查工作区 .searches.md 再决定是否重新搜索。');
    lines.push('- 老格式 Office（.doc/.xls/.ppt）无法本地解析，请用户转存为新格式（.docx/.xlsx/.pptx）。');
    lines.push('- 加密 PDF 与扫描件（图片型 PDF）无法提取文本，请如实告知用户。');
    lines.push('');
    lines.push('# 交付前自检清单（必须执行，结果必须在最终总结输出为「自检报告」逐项 PASS/FAIL，不能只在内部执行）');
    lines.push('- [ ] 产出物全部存在且非空（list_files 验证过）？');
    lines.push('- [ ] 最终总结已包含「自检报告」逐项 PASS/FAIL（含发现与修复记录）？');
    lines.push('- [ ] 面向用户阅读的交付物已是手机可读格式（docx/xlsx/pptx，除非用户另有要求）？');
    lines.push('- [ ] 关键内容抽查核对过（read_file / search_files）？');
    lines.push('- [ ] 所有失败的工具调用都已如实报告？');
    lines.push('- [ ] 总结覆盖了每个产出文件的路径与用途？没有"等""略"类省略？');
    lines.push('- [ ] 最终总结已按规范附上 mermaid 导图（flowchart TD / sequenceDiagram，节点≤8，节点文字无标点无引号，首行 init 参数，围栏闭合）？');
    lines.push('- [ ] 结论都有工作区内容或工具结果支撑？不确定处已标注？');
    lines.push('- [ ] 全程使用用户的语言？');
    lines.push('');
    // 技能清单注入在提示词末尾: 静态注册表生成, 逐字节稳定, 不破坏前缀缓存(设计见本文件缓存说明)
    let skillsSection: string = WorkSkillService.promptSection();
    if (skillsSection !== '') {
      lines.push(skillsSection);
      lines.push('');
    }
    lines.push('现在开始：收到任务后，先分析复杂度，再按上述流程执行。');
    AgentLoopService.cachedWorkPrompt = lines.join('\n');
    return AgentLoopService.cachedWorkPrompt;
  }

  // 运行时快照消息的识别前缀(尾部状态快照: 日期/文件树/任务清单)
  static readonly RUNTIME_SNAPSHOT_PREFIX: string = '【运行时上下文】';

  // 构建运行时快照内容: 易变状态作为 user 消息追加到历史末尾(取代系统提示词内嵌),
  // 内容逐字节确定(无时间戳), 仅在工作区/清单/目标真正变化时才会变化。
  static buildRuntimeSnapshot(tree: string, todoText: string,
    goalText: string = '', scheduleText: string = ''): string {
    let lines: string[] = [];
    lines.push(AgentLoopService.RUNTIME_SNAPSHOT_PREFIX +
      '本消息为最新状态快照，取代此前所有运行时上下文快照；与旧快照冲突时以本条为准。');
    lines.push('');
    lines.push('- 今天的日期: ' + AgentLoopService.formatToday());
    lines.push('- 当前工作区文件树（随文件操作与上传自动刷新）:');
    lines.push('<workspace_files>');
    lines.push(tree);
    lines.push('</workspace_files>');
    if (todoText !== '') {
      lines.push('- 当前任务清单（随 todo_write 更新）:');
      lines.push('<task_todo>');
      lines.push(todoText);
      lines.push('</task_todo>');
    }
    if (goalText !== '') {
      lines.push('- 当前自主目标（随 goal_* 工具更新）:');
      lines.push('<session_goal>');
      lines.push(goalText);
      lines.push('</session_goal>');
    }
    if (scheduleText !== '') {
      lines.push('- 当前定时提醒（随 schedule_* 工具更新）:');
      lines.push('<session_schedules>');
      lines.push(scheduleText);
      lines.push('</session_schedules>');
    }
    return lines.join('\n');
  }

  // 从历史末尾向前找最近一条运行时快照的内容(没有则返回空串);
  // 新快照与它逐字节一致时不再追加, 这是保持请求前缀稳定的关键判定。
  static findLastSnapshot(messages: LoopMessage[]): string {
    for (let i: number = messages.length - 1; i >= 0; i--) {
      if (messages[i].content.startsWith(AgentLoopService.RUNTIME_SNAPSHOT_PREFIX)) {
        return messages[i].content;
      }
    }
    return '';
  }

  // 今天的日期(本地时区, 含星期), 格式固定: 2026年08月30日 星期六
  private static formatToday(): string {
    let now: Date = new Date();
    let y: number = now.getFullYear();
    let m: string = (now.getMonth() + 1).toString().padStart(2, '0');
    let d: string = now.getDate().toString().padStart(2, '0');
    let weekdays: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    let w: string = weekdays[now.getDay()];
    return y.toString() + '年' + m + '月' + d + '日 星期' + w;
  }
}
