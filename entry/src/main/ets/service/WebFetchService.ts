// WebFetchService: web_fetch 工具的本地实现(对齐 DeepSeek Harness web-fetch-http)
// 直接 http GET 拉取页面/文本/JSON, HTML 剥离为可读文本; 数据不落盘, 仅送回模型。
// 不可运行 shell 的平台上这是模型获取网页原文的唯一通道(配合服务端联网搜索使用)。
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { Constants } from '../common/Constants';

export class WebFetchResult {
  ok: boolean = false;
  text: string = '';
  contentType: string = '';
  finalUrl: string = '';
  byteSize: number = 0;
  error: string = '';
}

export class WebFetchService {
  // 深度取消注册表: stopStreaming 时销毁在途 web_fetch HTTP 请求
  private static toolRequests: http.HttpRequest[] = [];

  // 深度取消: 销毁所有在途 web_fetch HTTP 请求
  static abortToolRequests(): void {
    for (let i: number = 0; i < WebFetchService.toolRequests.length; i++) {
      try {
        WebFetchService.toolRequests[i].destroy();
      } catch (e) {
        // 已结束/已销毁的请求忽略
      }
    }
    WebFetchService.toolRequests = [];
  }

  private static registerToolRequest(req: http.HttpRequest): void {
    WebFetchService.toolRequests.push(req);
  }

  private static unregisterToolRequest(req: http.HttpRequest): void {
    let idx: number = WebFetchService.toolRequests.indexOf(req);
    if (idx >= 0) {
      WebFetchService.toolRequests.splice(idx, 1);
    }
  }

  // 拉取并转换为送回模型的文本(不额外限并发: 由主循环只读并行池控制, 默认上限 4)
  static fetch(url: string, maxChars: number): Promise<WebFetchResult> {
    let cap: number = maxChars > 0 ? Math.min(maxChars, Constants.WORK_WEBFETCH_MAX_CHARS) :
      Constants.WORK_WEBFETCH_MAX_CHARS;
    return new Promise<WebFetchResult>((resolve: (r: WebFetchResult) => void) => {
      let out: WebFetchResult = new WebFetchResult();
      let trimmed: string = url.trim();
      if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
        out.error = '仅支持 http(s) 链接: ' + url;
        resolve(out);
        return;
      }
      let httpRequest: http.HttpRequest = http.createHttp();
      WebFetchService.registerToolRequest(httpRequest);
      httpRequest.request(trimmed, {
        method: http.RequestMethod.GET,
        connectTimeout: 20000,
        readTimeout: 45000,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        header: {
          'User-Agent': 'Mozilla/5.0 (HarmonyOS) GuncatWork/6.1',
          'Accept': 'text/html,application/json,text/plain;q=0.9,*/*;q=0.5'
        }
      }).then((resp: http.HttpResponse) => {
        try {
          let status: number = resp.responseCode;
          if (status < 200 || status >= 300) {
            out.error = 'HTTP ' + status.toString() + ' (非 2xx 响应)';
            resolve(out);
            return;
          }
          let raw: Object = resp.result;
          let body: string = '';
          if (typeof raw === 'string') {
            body = raw as string;
          } else if (raw instanceof ArrayBuffer) {
            let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
            body = decoder.decodeToString(new Uint8Array(raw as ArrayBuffer), { stream: false });
          }
          out.byteSize = body.length;
          let ctObj: Object | undefined = resp.header['content-type'];
          let ct: string = typeof ctObj === 'string' ? ctObj as string : '';
          out.contentType = ct;
          out.finalUrl = trimmed;
          let lowerCt: string = ct.toLowerCase();
          let lowerUrl: string = trimmed.toLowerCase();
          let looksHtml: boolean = lowerCt.indexOf('html') !== -1 ||
            (ct === '' && (lowerUrl.endsWith('.html') || lowerUrl.endsWith('.htm') ||
              body.trimStart().startsWith('<')));
          if (looksHtml) {
            out.text = WebFetchService.htmlToText(body);
          } else {
            out.text = body;
          }
          if (out.text.length > cap) {
            out.text = out.text.substring(0, cap) + '\n\n…[内容超过 ' + cap.toString() +
              ' 字符已截断]';
          }
          out.ok = true;
          resolve(out);
        } finally {
          WebFetchService.unregisterToolRequest(httpRequest);
          httpRequest.destroy();
        }
      }).catch((err: Error) => {
        let msg: string = err.message !== undefined ? err.message : '网络请求失败';
        out.error = msg;
        try {
          WebFetchService.unregisterToolRequest(httpRequest);
          httpRequest.destroy();
        } catch (e) {
          // ignore
        }
        resolve(out);
      });
    });
  }

  // HTML → 可读文本: 去脚本/样式/注释, 块级标签转行, 解压空白与基本实体
  static htmlToText(html: string): string {
    let text: string = html;
    text = text.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    text = text.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    text = text.replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ');
    text = text.replace(/<!--[\s\S]*?-->/g, ' ');
    // 常见块级元素转为换行; br 换行; 表格单元格留分隔
    text = text.replace(/<\/(p|div|section|article|header|footer|main|aside|nav|ul|ol|dl|table|tr|blockquote|h[1-6]|li|dd|dt|form)>/gi, '\n');
    text = text.replace(/<br\s*\/?>/gi, '\n');
    text = text.replace(/<\/t[dh]>/gi, ' | ');
    text = text.replace(/<[^>]+>/g, ' ');
    text = WebFetchService.decodeEntities(text);
    // 压缩空白: 行内多空白合一, 连续空行最多两行
    let lines: string[] = text.split('\n');
    let out: string[] = [];
    let blankRun: number = 0;
    for (let i: number = 0; i < lines.length; i++) {
      let line: string = lines[i].replace(/[ \t\r\f\v\u00a0]+/g, ' ').trim();
      if (line === '') {
        blankRun++;
        if (blankRun <= 1) {
          out.push('');
        }
      } else {
        blankRun = 0;
        out.push(line);
      }
    }
    let joined: string = out.join('\n');
    // 去掉首尾空行
    return joined.replace(/^\n+/, '').replace(/\n+$/, '');
  }

  private static decodeEntities(text: string): string {
    let out: string = text;
    out = out.replace(/&amp;/g, '&');
    out = out.replace(/&lt;/g, '<');
    out = out.replace(/&gt;/g, '>');
    out = out.replace(/&quot;/g, '"');
    out = out.replace(/&#39;/g, '\'');
    out = out.replace(/&apos;/g, '\'');
    out = out.replace(/&nbsp;/g, ' ');
    // 数字实体(十进制/十六进制)
    out = out.replace(/&#(\d+);/g, (m: string, p1: string): string => {
      let code: number = parseInt(p1, 10);
      if (isNaN(code) || code < 32) {
        return m;
      }
      return String.fromCharCode(code);
    });
    out = out.replace(/&#x([0-9a-fA-F]+);/g, (m: string, p1: string): string => {
      let code: number = parseInt(p1, 16);
      if (isNaN(code) || code < 32) {
        return m;
      }
      return String.fromCharCode(code);
    });
    return out;
  }
}
