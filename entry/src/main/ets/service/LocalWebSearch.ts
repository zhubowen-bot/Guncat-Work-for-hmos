// LocalWebSearch: 本地内置联网搜索(手机直连搜索引擎/搜索 API, 不经过模型服务商)
// 移植自参考项目 chatcube 的 WebSearchService(外部引擎 + Function Calling 路径):
//   - 引擎注册表: Bing(本地 HTML 爬取, 无 Key)/Brave/Tavily/Exa/Metaso/Firecrawl
//   - 统一 search_web function tool, 由模型决定是否调用; 服务端联网搜索(webSearchEnabled)完全独立并存
//   - 结果统一格式化为带引用格式指引([title](url))的文本回传模型
// 引擎 API Key/BaseUrl 持久化在 Preferences(LS_KEY_LOCAL_SEARCH_CONFIG), 启动与保存后 bind 注入运行时快照
import { http } from '@kit.NetworkKit';
import { AbortSignal } from '../common/Types';

// 引擎 id(持久化值)
export const SEARCH_ENGINE_BING: string = 'bing';
export const SEARCH_ENGINE_BRAVE: string = 'brave';
export const SEARCH_ENGINE_TAVILY: string = 'tavily';
export const SEARCH_ENGINE_EXA: string = 'exa';
export const SEARCH_ENGINE_METASO: string = 'metaso';
export const SEARCH_ENGINE_FIRECRAWL: string = 'firecrawl';

// search_web 工具名(三协议统一); 有意区别于服务端联网搜索的 web_search, 避免同名工具冲突
export const LOCAL_SEARCH_TOOL_NAME: string = 'search_web';

// search_web 的 query 参数描述(与 chatcube 措辞对齐)
export const LOCAL_SEARCH_QUERY_PROP_DESC: string =
  '聚焦搜索关键词。用于搜索外部实时、特定或需要验证的信息, 不要传入整段用户问题。';

// 聊天模式工具描述(强制注入, 由模型自行决定是否调用)
export const LOCAL_SEARCH_TOOL_DESC_CHAT: string =
  'Search the web for up-to-date, specific, or verifiable information. ' +
  'First decide whether web access is truly needed; use your own knowledge for common stable facts ' +
  'and pure generation tasks. Each search has real cost, so generate focused keywords and run multiple ' +
  'searches only when more evidence is needed. Cite used sources as standard Markdown links like ' +
  '[title](url), not bare [1] or [2] numbers.';

// 聊天模式工具描述(服务端联网搜索开启时的兜底版: 引导模型优先走服务端 web_search)
export const LOCAL_SEARCH_TOOL_DESC_CHAT_FALLBACK: string =
  'Fallback web search tool that runs locally on the phone (direct connection to search engines, ' +
  'no server-side execution). PREFER the server-side web_search tool when it is available; ' +
  'use this tool only when server-side search is unavailable, fails, or returns no results. ' +
  'Generate focused keywords. Cite used sources as standard Markdown links like [title](url), ' +
  'not bare [1] or [2] numbers.';

// 工作模式工具描述(说明是手机本地处理; 结果自动登记到 .searches.md)
export const LOCAL_SEARCH_TOOL_DESC_WORK: string =
  '利用手机本地网络直接联网搜索(手机直连搜索引擎/搜索 API, 不经过模型服务商的服务端工具)。' +
  '用于获取实时信息、验证事实、查找资料。每次搜索有真实成本: 先自行判断是否真的需要联网, ' +
  '常见稳定知识直接作答; 需要搜索时生成聚焦的关键词, 证据不足才多次搜索。' +
  '引用来源一律使用标准 Markdown 链接 [title](url), 不要写 [1]、[2] 编号。' +
  '需要阅读某个网页全文时配合 web_fetch 使用。每次搜索的结果清单会自动登记到工作区 .searches.md。';

// 工作模式工具描述(服务端联网搜索开启时的兜底版: 引导模型优先走服务端 web_search)
export const LOCAL_SEARCH_TOOL_DESC_WORK_FALLBACK: string =
  '利用手机本地网络直接联网搜索(手机直连搜索引擎/搜索 API, 不经过模型服务商的服务端工具)。' +
  '【优先级】服务端联网搜索(web_search)可用时必须优先使用服务端搜索; ' +
  '仅当服务端搜索不可用、报错或无结果时才退回本工具。' +
  '每次搜索有真实成本: 生成聚焦的关键词, 证据不足才多次搜索。' +
  '引用来源一律使用标准 Markdown 链接 [title](url), 不要写 [1]、[2] 编号。' +
  '需要阅读某个网页全文时配合 web_fetch 使用。每次搜索的结果清单会自动登记到工作区 .searches.md。';

// 引擎显示名
export function searchEngineLabel(engine: string): string {
  if (engine === SEARCH_ENGINE_BRAVE) {
    return 'Brave Search';
  }
  if (engine === SEARCH_ENGINE_TAVILY) {
    return 'Tavily';
  }
  if (engine === SEARCH_ENGINE_EXA) {
    return 'Exa';
  }
  if (engine === SEARCH_ENGINE_METASO) {
    return 'Metaso';
  }
  if (engine === SEARCH_ENGINE_FIRECRAWL) {
    return 'Firecrawl';
  }
  return 'Bing(local)';
}

// 引擎是否需要 API Key(设置 UI 据此显示输入框; 执行据此判定未配置错误)
export function searchEngineNeedsApiKey(engine: string): boolean {
  return engine !== SEARCH_ENGINE_BING;
}

// 引擎是否支持自定义 Base URL(设置 UI 据此显示输入框)
export function searchEngineSupportsBaseUrl(engine: string): boolean {
  return engine === SEARCH_ENGINE_TAVILY || engine === SEARCH_ENGINE_EXA ||
    engine === SEARCH_ENGINE_FIRECRAWL;
}

// 本地联网搜索配置(整体 JSON 持久化; 按引擎分字段保存, 切换引擎不丢配置)
export class SearchEngineSettings {
  engine: string = SEARCH_ENGINE_BING;
  maxResults: number = 8;
  braveApiKey: string = '';
  tavilyApiKey: string = '';
  tavilyBaseUrl: string = 'https://api.tavily.com';
  exaApiKey: string = '';
  exaBaseUrl: string = 'https://api.exa.ai';
  metasoApiKey: string = '';
  firecrawlApiKey: string = '';
  firecrawlBaseUrl: string = 'https://api.firecrawl.dev';

  static fromJson(json: Record<string, Object>): SearchEngineSettings {
    let cfg: SearchEngineSettings = new SearchEngineSettings();
    cfg.engine = (json['engine'] as string) ?? SEARCH_ENGINE_BING;
    let max: Object = json['maxResults'];
    if (typeof max === 'number') {
      cfg.maxResults = max as number;
    }
    cfg.braveApiKey = (json['braveApiKey'] as string) ?? '';
    cfg.tavilyApiKey = (json['tavilyApiKey'] as string) ?? '';
    cfg.tavilyBaseUrl = (json['tavilyBaseUrl'] as string) ?? 'https://api.tavily.com';
    cfg.exaApiKey = (json['exaApiKey'] as string) ?? '';
    cfg.exaBaseUrl = (json['exaBaseUrl'] as string) ?? 'https://api.exa.ai';
    cfg.metasoApiKey = (json['metasoApiKey'] as string) ?? '';
    cfg.firecrawlApiKey = (json['firecrawlApiKey'] as string) ?? '';
    cfg.firecrawlBaseUrl = (json['firecrawlBaseUrl'] as string) ?? 'https://api.firecrawl.dev';
    return cfg;
  }

  toJson(): Record<string, Object> {
    return {
      'engine': this.engine,
      'maxResults': this.maxResults,
      'braveApiKey': this.braveApiKey,
      'tavilyApiKey': this.tavilyApiKey,
      'tavilyBaseUrl': this.tavilyBaseUrl,
      'exaApiKey': this.exaApiKey,
      'exaBaseUrl': this.exaBaseUrl,
      'metasoApiKey': this.metasoApiKey,
      'firecrawlApiKey': this.firecrawlApiKey,
      'firecrawlBaseUrl': this.firecrawlBaseUrl
    };
  }

  static parse(text: string): SearchEngineSettings {
    if (text.trim() === '') {
      return new SearchEngineSettings();
    }
    try {
      let parsed: Object = JSON.parse(text);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return SearchEngineSettings.fromJson(parsed as Record<string, Object>);
      }
    } catch (e) {
      // 非法 JSON 回落默认配置
    }
    return new SearchEngineSettings();
  }

  // 当前选中引擎的 API Key(执行用)
  apiKeyForEngine(engine: string): string {
    if (engine === SEARCH_ENGINE_BRAVE) {
      return this.braveApiKey.trim();
    }
    if (engine === SEARCH_ENGINE_TAVILY) {
      return this.tavilyApiKey.trim();
    }
    if (engine === SEARCH_ENGINE_EXA) {
      return this.exaApiKey.trim();
    }
    if (engine === SEARCH_ENGINE_METASO) {
      return this.metasoApiKey.trim();
    }
    if (engine === SEARCH_ENGINE_FIRECRAWL) {
      return this.firecrawlApiKey.trim();
    }
    return '';
  }
}

// 单条搜索结果项
export class LocalSearchItem {
  title: string = '';
  url: string = '';
  snippet: string = '';
}

// 搜索结果(返回给工具执行层)
export class LocalSearchOutcome {
  ok: boolean = false;
  query: string = '';
  engineLabel: string = '';
  items: LocalSearchItem[] = [];
  // 送回模型的文本(含引用格式指引, 头部指令随结果走而非系统提示词, 不破坏前缀缓存)
  contentForAI: string = '';
  errorMessage: string = '';
  // 可观测标记(由护栏兜底结果设置)
  timeout: boolean = false;
  cancelled: boolean = false;
}

// 单次 HTTP 请求结果
class HttpOutcome {
  ok: boolean = false;
  status: number = 0;
  body: string = '';
  error: string = '';
}

export class LocalWebSearch {
  // 运行时配置快照(启动/保存后由宿主 bind 注入, 避免每次搜索读盘)
  private static settings: SearchEngineSettings = new SearchEngineSettings();

  static bind(settings: SearchEngineSettings): void {
    LocalWebSearch.settings = settings;
  }

  static currentSettings(): SearchEngineSettings {
    return LocalWebSearch.settings;
  }

  // 统一搜索入口; 失败信息写入 errorMessage, 请求层失败自动重试一次(搜索全部幂等)
  static async searchWeb(query: string, abortSignal?: AbortSignal): Promise<LocalSearchOutcome> {
    let cfg: SearchEngineSettings = LocalWebSearch.settings;
    let engine: string = cfg.engine;
    let label: string = searchEngineLabel(engine);
    let out: LocalSearchOutcome = new LocalSearchOutcome();
    out.query = query.trim();
    out.engineLabel = label;
    let cleaned: string = LocalWebSearch.cleanQuery(query);
    if (cleaned === '') {
      out.errorMessage = '搜索关键词为空';
      return out;
    }
    let apiKey: string = cfg.apiKeyForEngine(engine);
    if (searchEngineNeedsApiKey(engine) && apiKey === '') {
      out.errorMessage = label + ' API Key 未配置(请在设置的"本地联网搜索"中填写)';
      return out;
    }
    if (abortSignal !== undefined && abortSignal.aborted) {
      out.errorMessage = '请求已取消';
      return out;
    }

    let items: LocalSearchItem[] = [];
    try {
      if (engine === SEARCH_ENGINE_BING) {
        items = await LocalWebSearch.bingSearch(cleaned, cfg);
      } else if (engine === SEARCH_ENGINE_BRAVE) {
        items = await LocalWebSearch.braveSearch(cleaned, cfg);
      } else if (engine === SEARCH_ENGINE_TAVILY) {
        items = await LocalWebSearch.tavilySearch(cleaned, cfg);
      } else if (engine === SEARCH_ENGINE_EXA) {
        items = await LocalWebSearch.exaSearch(cleaned, cfg);
      } else if (engine === SEARCH_ENGINE_METASO) {
        items = await LocalWebSearch.metasoSearch(cleaned, cfg);
      } else if (engine === SEARCH_ENGINE_FIRECRAWL) {
        items = await LocalWebSearch.firecrawlSearch(cleaned, cfg);
      } else {
        items = await LocalWebSearch.bingSearch(cleaned, cfg);
      }
    } catch (e) {
      let err: Error = e as Error;
      out.errorMessage = label + ' 搜索失败: ' + (err.message !== undefined ? err.message : '网络请求失败');
      return out;
    }
    if (abortSignal !== undefined && abortSignal.aborted) {
      out.errorMessage = '请求已取消';
      return out;
    }
    out.ok = true;
    out.items = items;
    out.contentForAI = LocalWebSearch.limitPromptContent(
      LocalWebSearch.buildContentForAI(items), 6000);
    return out;
  }

  // ===== 结果格式化 =====

  // 给 AI 的内容: 引用格式指引贴在搜索结果旁(比塞进 system 更精准, 不调用搜索时 0 token 占用)
  private static buildContentForAI(items: LocalSearchItem[]): string {
    let content: string = '以下是搜索结果。引用搜索结果时请使用标准 Markdown 链接格式 [title](url)，' +
      '不要写成 [1]、[2] 这类编号。\n\n';
    let maxChars: number = 3800;
    for (let i: number = 0; i < items.length; i++) {
      let item: LocalSearchItem = items[i];
      let block: string = (i + 1).toString() + '. ' + item.title + '\n   ' + item.snippet +
        '\n   来源: ' + item.url + '\n\n';
      if ((content + block).length > maxChars) {
        content += '[更多结果已省略]\n';
        break;
      }
      content += block;
    }
    return content;
  }

  private static limitPromptContent(content: string, maxChars: number): string {
    if (content.length <= maxChars) {
      return content;
    }
    return content.substring(0, maxChars) + '\n\n[搜索上下文已截断]';
  }

  // 查询词清洗: 截断超长查询并去掉换行(搜索引擎对超长/带换行查询表现差)
  private static cleanQuery(raw: string): string {
    let cleaned: string = raw.replace(/\s+/g, ' ').trim();
    if (cleaned.length > 200) {
      cleaned = cleaned.substring(0, 200);
    }
    return cleaned;
  }

  private static clampMaxResults(): number {
    let n: number = LocalWebSearch.settings.maxResults;
    if (n <= 0) {
      return 8;
    }
    if (n > 20) {
      return 20;
    }
    return n;
  }

  // ===== HTTP(NetworkKit http, 20s 读超时, 幂等失败自动重试一次) =====

  private static async requestOnce(method: string, url: string, body: string,
    headers: Record<string, string>): Promise<HttpOutcome> {
    let out: HttpOutcome = new HttpOutcome();
    let httpRequest: http.HttpRequest = http.createHttp();
    try {
      let opts: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 20000,
        // 境外搜索 API(api.tavily.com/api.exa.ai 等)国内连通性偏差, 20s 覆盖握手抖动
        usingProtocol: http.HttpProtocol.HTTP1_1
      };
      if (method === 'POST' && body !== '') {
        opts.extraData = body;
      }
      let resp: http.HttpResponse = await httpRequest.request(url, opts);
      out.status = resp.responseCode;
      let result: Object = resp.result;
      if (typeof result === 'string') {
        out.body = result as string;
      } else if (result instanceof ArrayBuffer) {
        out.body = LocalWebSearch.arrayBufferToString(result as ArrayBuffer);
      }
      out.ok = resp.responseCode >= 200 && resp.responseCode < 300;
      if (!out.ok) {
        out.error = 'HTTP ' + resp.responseCode.toString();
      }
      return out;
    } catch (e) {
      let err: Error = e as Error;
      out.error = err.message !== undefined ? err.message : '网络请求失败';
      return out;
    } finally {
      try {
        httpRequest.destroy();
      } catch (e) {
        // ignore
      }
    }
  }

  private static arrayBufferToString(buf: ArrayBuffer): string {
    let bytes: Uint8Array = new Uint8Array(buf);
    let result: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      let b1: number = bytes[i];
      if (b1 < 0x80) {
        result += String.fromCharCode(b1);
        i++;
      } else if ((b1 & 0xE0) === 0xC0) {
        let b2: number = bytes[i + 1];
        result += String.fromCharCode(((b1 & 0x1F) << 6) | (b2 & 0x3F));
        i += 2;
      } else if ((b1 & 0xF0) === 0xE0) {
        let b2: number = bytes[i + 1];
        let b3: number = bytes[i + 2];
        result += String.fromCharCode(((b1 & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x0F));
        i += 3;
      } else if ((b1 & 0xF8) === 0xF0) {
        let b2: number = bytes[i + 1];
        let b3: number = bytes[i + 2];
        let b4: number = bytes[i + 3];
        result += String.fromCharCode(((b1 & 0x07) << 18) | ((b2 & 0x3F) << 12) |
          ((b3 & 0x3F) << 6) | (b4 & 0x3F));
        i += 4;
      } else {
        i++;
      }
    }
    return result;
  }

  // 幂等请求: 传输失败/5xx 自动重试一次(对齐 chatcube HttpService 的 idempotent 语义)
  private static async requestWithRetry(method: string, url: string, body: string,
    headers: Record<string, string>): Promise<HttpOutcome> {
    let first: HttpOutcome = await LocalWebSearch.requestOnce(method, url, body, headers);
    if (first.ok) {
      return first;
    }
    let retryable: boolean = !first.ok && (first.status === 0 || first.status >= 500 ||
      first.status === 408 || first.status === 429);
    if (!retryable) {
      return first;
    }
    let second: HttpOutcome = await LocalWebSearch.requestOnce(method, url, body, headers);
    return second;
  }

  // ===== Bing(本地 HTML 爬取, 无 Key; www 失败回落 cn) =====

  private static async bingSearch(query: string, cfg: SearchEngineSettings): Promise<LocalSearchItem[]> {
    let encoded: string = encodeURIComponent(query);
    let primary: HttpOutcome = await LocalWebSearch.requestWithRetry('GET',
      'https://www.bing.com/search?q=' + encoded + '&setlang=zh-hans',
      '', LocalWebSearch.bingHeaders());
    let primaryItems: LocalSearchItem[] = [];
    if (primary.ok) {
      primaryItems = LocalWebSearch.parseBingSearchResults(primary.body, LocalWebSearch.clampMaxResults());
    }
    if (primary.ok && primaryItems.length > 0) {
      return primaryItems;
    }
    // 主域解析失败或结果为空, 至少重试一次备用入口
    let fallback: HttpOutcome = await LocalWebSearch.requestWithRetry('GET',
      'https://cn.bing.com/search?q=' + encoded, '', LocalWebSearch.bingHeaders());
    if (fallback.ok) {
      let fallbackItems: LocalSearchItem[] =
        LocalWebSearch.parseBingSearchResults(fallback.body, LocalWebSearch.clampMaxResults());
      if (fallbackItems.length > 0) {
        return fallbackItems;
      }
    }
    if (primaryItems.length > 0) {
      return primaryItems;
    }
    if (!primary.ok && !fallback.ok) {
      throw new Error('Bing 搜索请求失败(' + primary.error + ' / ' + fallback.error + ')');
    }
    return primaryItems.length > 0 ? primaryItems : [];
  }

  private static bingHeaders(): Record<string, string> {
    // 反指纹: 带 Referer + 搜索 cookie, 覆盖默认 brotli 编码(http kit 对 br 解码不稳)
    let headers: Record<string, string> = {
      'Referer': 'https://www.bing.com/',
      'Cookie': 'SRCHHPGUSR=ULSR=1',
      'Accept-Encoding': 'gzip, deflate',
      'Accept-Charset': 'utf-8'
    };
    return headers;
  }

  // 解析 Bing 搜索结果页 HTML(双策略: b_algo 块 → h2>a 兜底)
  private static parseBingSearchResults(html: string, maxCount: number): LocalSearchItem[] {
    let results: LocalSearchItem[] = [];
    let seenUrls: string[] = [];
    LocalWebSearch.collectBAlgoBlocks(html, maxCount, results, seenUrls);
    if (results.length < maxCount) {
      LocalWebSearch.collectHeadingLinks(html, maxCount, results, seenUrls);
    }
    return results;
  }

  private static collectBAlgoBlocks(html: string, maxCount: number,
    output: LocalSearchItem[], seenUrls: string[]): void {
    let algoRegex: RegExp = /<li[^>]*class=["'][^"']*b_algo[^"']*["'][^>]*>([\s\S]*?)<\/li>/gi;
    let match: RegExpExecArray | null = algoRegex.exec(html);
    while (match !== null && output.length < maxCount) {
      let block: string = match[1];
      let parsed: LocalSearchItem | null = LocalWebSearch.parseResultFromBlock(block);
      if (parsed !== null) {
        let normalizedUrl: string = parsed.url.trim();
        if (seenUrls.indexOf(normalizedUrl) === -1) {
          seenUrls.push(normalizedUrl);
          output.push(parsed);
        }
      }
      match = algoRegex.exec(html);
    }
  }

  private static collectHeadingLinks(html: string, maxCount: number,
    output: LocalSearchItem[], seenUrls: string[]): void {
    let headingRegex: RegExp = /<h2[^>]*>[\s\S]*?<a[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>[\s\S]*?<\/h2>/gi;
    let match: RegExpExecArray | null = headingRegex.exec(html);
    while (match !== null && output.length < maxCount) {
      let url: string = match[1];
      let title: string = LocalWebSearch.stripHtmlTags(match[2]).trim();
      if (title !== '' && !LocalWebSearch.isBingInternalUrl(url)) {
        let normalizedUrl: string = url.trim();
        if (seenUrls.indexOf(normalizedUrl) === -1) {
          seenUrls.push(normalizedUrl);
          let item: LocalSearchItem = new LocalSearchItem();
          item.title = title;
          item.url = normalizedUrl;
          item.snippet = LocalWebSearch.extractSnippetNearMatch(html, match.index);
          output.push(item);
        }
      }
      match = headingRegex.exec(html);
    }
  }

  private static parseResultFromBlock(block: string): LocalSearchItem | null {
    let titleMatch: RegExpExecArray | null = /<h2[^>]*>([\s\S]*?)<\/h2>/i.exec(block);
    if (titleMatch === null) {
      return null;
    }
    let titleBlock: string = titleMatch[1];
    let linkMatch: RegExpExecArray | null =
      /<a[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/i.exec(titleBlock);
    if (linkMatch === null) {
      return null;
    }
    let url: string = linkMatch[1];
    let title: string = LocalWebSearch.stripHtmlTags(linkMatch[2]).trim();
    if (title === '' || LocalWebSearch.isBingInternalUrl(url)) {
      return null;
    }
    let snippetMatch: RegExpExecArray | null =
      /<div[^>]*class=["'][^"']*b_caption[^"']*["'][^>]*>[\s\S]*?<p[^>]*>([\s\S]*?)<\/p>/i.exec(block);
    if (snippetMatch === null) {
      snippetMatch = /<p[^>]*>([\s\S]*?)<\/p>/i.exec(block);
    }
    let item: LocalSearchItem = new LocalSearchItem();
    item.title = title;
    item.url = url.trim();
    item.snippet = snippetMatch !== null ? LocalWebSearch.stripHtmlTags(snippetMatch[1]).trim() : '';
    return item;
  }

  private static extractSnippetNearMatch(html: string, startIndex: number): string {
    let safeStart: number = startIndex >= 0 ? startIndex : 0;
    let safeEnd: number = Math.min(html.length, safeStart + 1000);
    let segment: string = html.substring(safeStart, safeEnd);
    let snippetMatch: RegExpExecArray | null = /<p[^>]*>([\s\S]*?)<\/p>/i.exec(segment);
    if (snippetMatch === null) {
      return '';
    }
    return LocalWebSearch.normalizeSnippet(LocalWebSearch.stripHtmlTags(snippetMatch[1]).trim());
  }

  private static isBingInternalUrl(url: string): boolean {
    let lower: string = url.toLowerCase();
    return lower.indexOf('bing.com') !== -1 || lower.startsWith('/search') || lower.startsWith('/?');
  }

  private static stripHtmlTags(text: string): string {
    return text
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/\s+/g, ' ')
      .trim();
  }

  // ===== Brave =====

  private static async braveSearch(query: string, cfg: SearchEngineSettings): Promise<LocalSearchItem[]> {
    let url: string = 'https://api.search.brave.com/res/v1/web/search?q=' +
      encodeURIComponent(query) + '&count=' + LocalWebSearch.clampMaxResults().toString();
    let headers: Record<string, string> = {
      'Accept': 'application/json',
      'X-Subscription-Token': cfg.braveApiKey.trim()
    };
    let resp: HttpOutcome = await LocalWebSearch.requestWithRetry('GET', url, '', headers);
    if (!resp.ok) {
      throw new Error('Brave 搜索请求失败(' + resp.error + ')');
    }
    let errMsg: string = LocalWebSearch.extractErrorField(resp.body, ['error']);
    if (errMsg !== '') {
      throw new Error('Brave 搜索失败: ' + errMsg);
    }
    let items: LocalSearchItem[] = [];
    let parsed: Object | null = LocalWebSearch.parseJsonObject(resp.body);
    if (parsed === null) {
      return items;
    }
    let web: Object = (parsed as Record<string, Object>)['web'];
    if (typeof web !== 'object' || web === null || web instanceof Array) {
      return items;
    }
    let list: Object | undefined = (web as Record<string, Object>)['results'];
    if (!(list instanceof Array)) {
      return items;
    }
    LocalWebSearch.collectJsonItems(list as Object[], items, LocalWebSearch.clampMaxResults(),
      'title', 'url', 'description');
    return items;
  }

  // ===== Tavily =====

  private static async tavilySearch(query: string, cfg: SearchEngineSettings): Promise<LocalSearchItem[]> {
    let base: string = LocalWebSearch.normalizeBaseUrl(cfg.tavilyBaseUrl, 'https://api.tavily.com',
      ['/search', '/extract', '/map', '/crawl', '/research', '/usage']);
    let payload: Record<string, Object> = {
      'query': query,
      'topic': 'general',
      'search_depth': 'basic',
      'max_results': LocalWebSearch.clampMaxResults(),
      'include_answer': false,
      'include_images': false,
      'include_raw_content': false
    };
    let body: string = JSON.stringify(payload);
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer ' + cfg.tavilyApiKey.trim()
    };
    let resp: HttpOutcome = await LocalWebSearch.requestWithRetry('POST', base + '/search', body, headers);
    if (!resp.ok) {
      throw new Error('Tavily 搜索请求失败(' + resp.error + ')');
    }
    let errMsg: string = LocalWebSearch.extractTavilyError(resp.body);
    if (errMsg !== '') {
      throw new Error('Tavily 搜索失败: ' + errMsg);
    }
    let items: LocalSearchItem[] = [];
    let parsed: Object | null = LocalWebSearch.parseJsonObject(resp.body);
    if (parsed === null) {
      return items;
    }
    let list: Object | undefined = (parsed as Record<string, Object>)['results'];
    if (!(list instanceof Array)) {
      return items;
    }
    LocalWebSearch.collectJsonItems(list as Object[], items, LocalWebSearch.clampMaxResults(),
      'title', 'url', 'content');
    return items;
  }

  // ===== Exa =====

  private static async exaSearch(query: string, cfg: SearchEngineSettings): Promise<LocalSearchItem[]> {
    let base: string = LocalWebSearch.normalizeBaseUrl(cfg.exaBaseUrl, 'https://api.exa.ai',
      ['/search', '/contents']);
    let textCfg: Record<string, Object> = { 'maxCharacters': 2500 };
    let contents: Record<string, Object> = { 'text': textCfg };
    let payload: Record<string, Object> = {
      'query': query,
      'type': 'auto',
      'numResults': LocalWebSearch.clampMaxResults(),
      'contents': contents
    };
    let body: string = JSON.stringify(payload);
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'x-api-key': cfg.exaApiKey.trim()
    };
    let resp: HttpOutcome = await LocalWebSearch.requestWithRetry('POST', base + '/search', body, headers);
    if (!resp.ok) {
      throw new Error('Exa 搜索请求失败(' + resp.error + ')');
    }
    let errMsg: string = LocalWebSearch.extractErrorField(resp.body, ['error']);
    if (errMsg !== '') {
      throw new Error('Exa 搜索失败: ' + errMsg);
    }
    let items: LocalSearchItem[] = [];
    let parsed: Object | null = LocalWebSearch.parseJsonObject(resp.body);
    if (parsed === null) {
      return items;
    }
    let list: Object | undefined = (parsed as Record<string, Object>)['results'];
    if (!(list instanceof Array)) {
      return items;
    }
    let arr: Object[] = list as Object[];
    for (let i: number = 0; i < arr.length && items.length < LocalWebSearch.clampMaxResults(); i++) {
      let item: Object = arr[i];
      if (typeof item !== 'object' || item === null || item instanceof Array) {
        continue;
      }
      let rec: Record<string, Object> = item as Record<string, Object>;
      let title: string = LocalWebSearch.readString(rec, 'title').trim();
      let url: string = LocalWebSearch.readString(rec, 'url').trim();
      if (title === '' || url === '') {
        continue;
      }
      let out: LocalSearchItem = new LocalSearchItem();
      out.title = title;
      out.url = url;
      out.snippet = LocalWebSearch.normalizeSnippet(LocalWebSearch.exaSnippet(rec));
      items.push(out);
    }
    return items;
  }

  private static exaSnippet(rec: Record<string, Object>): string {
    let summary: string = LocalWebSearch.readString(rec, 'summary');
    if (summary !== '') {
      return summary;
    }
    let text: string = LocalWebSearch.readString(rec, 'text');
    if (text !== '') {
      return text;
    }
    let highlights: Object | undefined = rec['highlights'];
    if (highlights instanceof Array) {
      let arr: Object[] = highlights as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          return arr[i] as string;
        }
      }
    }
    return '';
  }

  // ===== Metaso =====

  private static async metasoSearch(query: string, cfg: SearchEngineSettings): Promise<LocalSearchItem[]> {
    let payload: Record<string, Object> = {
      'q': query,
      'scope': 'webpage',
      'size': LocalWebSearch.clampMaxResults(),
      'includeSummary': false
    };
    let body: string = JSON.stringify(payload);
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer ' + cfg.metasoApiKey.trim()
    };
    let resp: HttpOutcome = await LocalWebSearch.requestWithRetry('POST',
      'https://metaso.cn/api/v1/search', body, headers);
    if (!resp.ok) {
      throw new Error('Metaso 搜索请求失败(' + resp.error + ')');
    }
    let items: LocalSearchItem[] = [];
    let parsed: Object | null = LocalWebSearch.parseJsonObject(resp.body);
    if (parsed === null) {
      return items;
    }
    let list: Object | undefined = (parsed as Record<string, Object>)['webpages'];
    if (!(list instanceof Array)) {
      return items;
    }
    LocalWebSearch.collectJsonItems(list as Object[], items, LocalWebSearch.clampMaxResults(),
      'title', 'link', 'snippet');
    return items;
  }

  // ===== Firecrawl =====

  private static async firecrawlSearch(query: string, cfg: SearchEngineSettings): Promise<LocalSearchItem[]> {
    let base: string = LocalWebSearch.normalizeBaseUrl(cfg.firecrawlBaseUrl, 'https://api.firecrawl.dev',
      ['/v2/search', '/v2/scrape', '/search', '/scrape']);
    let payload: Record<string, Object> = {
      'query': query,
      'limit': LocalWebSearch.clampMaxResults()
    };
    let body: string = JSON.stringify(payload);
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + cfg.firecrawlApiKey.trim()
    };
    let resp: HttpOutcome = await LocalWebSearch.requestWithRetry('POST', base + '/v2/search', body, headers);
    if (!resp.ok) {
      throw new Error('Firecrawl 搜索请求失败(' + resp.error + ')');
    }
    let items: LocalSearchItem[] = [];
    let parsed: Object | null = LocalWebSearch.parseJsonObject(resp.body);
    if (parsed === null) {
      return items;
    }
    let data: Object | undefined = (parsed as Record<string, Object>)['data'];
    if (typeof data !== 'object' || data === null || data instanceof Array) {
      return items;
    }
    let dataRec: Record<string, Object> = data as Record<string, Object>;
    let max: number = LocalWebSearch.clampMaxResults();
    let web: Object | undefined = dataRec['web'];
    if (web instanceof Array) {
      LocalWebSearch.collectJsonItems(web as Object[], items, max, 'title', 'url', 'description');
    }
    let news: Object | undefined = dataRec['news'];
    if (news instanceof Array && items.length < max) {
      LocalWebSearch.collectJsonItems(news as Object[], items, max, 'title', 'url', 'snippet');
    }
    return items;
  }

  // ===== JSON 解析通用辅助 =====

  private static parseJsonObject(text: string): Object | null {
    if (text.trim() === '') {
      return null;
    }
    try {
      let parsed: Object = JSON.parse(text);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return parsed;
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  // 从对象数组收集 title/url/snippet 三字段名可配的结果(title/url 空则跳过)
  private static collectJsonItems(arr: Object[], output: LocalSearchItem[], maxCount: number,
    titleKey: string, urlKey: string, snippetKey: string): void {
    for (let i: number = 0; i < arr.length && output.length < maxCount; i++) {
      let item: Object = arr[i];
      if (typeof item !== 'object' || item === null || item instanceof Array) {
        continue;
      }
      let rec: Record<string, Object> = item as Record<string, Object>;
      let title: string = LocalWebSearch.readString(rec, titleKey).trim();
      let url: string = LocalWebSearch.readString(rec, urlKey).trim();
      if (title === '' || url === '') {
        continue;
      }
      let out: LocalSearchItem = new LocalSearchItem();
      out.title = title;
      out.url = url;
      out.snippet = LocalWebSearch.normalizeSnippet(LocalWebSearch.readString(rec, snippetKey));
      output.push(out);
    }
  }

  private static readString(obj: Record<string, Object>, key: string): string {
    let value: Object | undefined = obj[key];
    if (typeof value === 'string') {
      return value as string;
    }
    return '';
  }

  private static normalizeSnippet(raw: string): string {
    let trimmed: string = raw.replace(/\s+/g, ' ').trim();
    if (trimmed.length <= 220) {
      return trimmed;
    }
    return trimmed.substring(0, 220) + '...';
  }

  private static extractErrorField(json: string, keys: string[]): string {
    let parsed: Object | null = LocalWebSearch.parseJsonObject(json);
    if (parsed === null) {
      return '';
    }
    for (let i: number = 0; i < keys.length; i++) {
      let value: Object | undefined = (parsed as Record<string, Object>)[keys[i]];
      if (value === undefined || value === null) {
        continue;
      }
      if (typeof value === 'string' && (value as string) !== '') {
        return value as string;
      }
      if (typeof value === 'object') {
        let msg: string = LocalWebSearch.readString(value as Record<string, Object>, 'message');
        if (msg !== '') {
          return msg;
        }
        return JSON.stringify(value);
      }
    }
    return '';
  }

  private static extractTavilyError(json: string): string {
    let parsed: Object | null = LocalWebSearch.parseJsonObject(json);
    if (parsed === null) {
      return '';
    }
    let rec: Record<string, Object> = parsed as Record<string, Object>;
    let detail: Object | undefined = rec['detail'];
    if (detail !== undefined && detail !== null) {
      if (typeof detail === 'string' && (detail as string) !== '') {
        return detail as string;
      }
      return JSON.stringify(detail);
    }
    let message: string = LocalWebSearch.readString(rec, 'message');
    if (message !== '') {
      return message;
    }
    return LocalWebSearch.extractErrorField(json, ['error']);
  }

  private static normalizeBaseUrl(raw: string, fallback: string, knownEndpoints: string[]): string {
    let trimmed: string = raw.trim();
    if (trimmed === '') {
      trimmed = fallback;
    }
    for (let i: number = 0; i < knownEndpoints.length; i++) {
      if (trimmed.endsWith(knownEndpoints[i])) {
        trimmed = trimmed.substring(0, trimmed.length - knownEndpoints[i].length);
        break;
      }
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }
}
