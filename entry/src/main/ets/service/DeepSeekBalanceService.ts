// DeepSeek 余额查询。仅用于用量页的"对账"卡片, 不参与逐请求统计,
// 也绝不在聊天链路里调用: 余额接口是账户级快照, 有延迟且不区分请求。
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ApiConfig } from '../model/ApiConfig';
import { DeepSeekBalanceInfo } from '../model/UsageModels';

export class DeepSeekBalanceService {
  private static balanceUrl(baseUrl: string): string {
    let b: string = baseUrl.trim();
    let lower: string = b.toLowerCase();
    if (lower.indexOf('api.deepseek.com') >= 0) {
      return 'https://api.deepseek.com/user/balance';
    }
    // 兼容自建代理: 去掉常见的协议后缀后补 /user/balance
    let cut: number = lower.indexOf('/anthropic');
    if (cut >= 0) {
      b = b.substring(0, cut);
    }
    cut = b.toLowerCase().indexOf('/v1');
    if (cut >= 0) {
      b = b.substring(0, cut);
    }
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b + '/user/balance';
  }

  static async fetch(config: ApiConfig): Promise<DeepSeekBalanceInfo | null> {
    if (config.apiKey.trim() === '' || config.baseUrl.trim() === '') {
      return null;
    }
    let request: http.HttpRequest = http.createHttp();
    try {
      let headers: Record<string, string> = {
        'Authorization': 'Bearer ' + config.apiKey,
        'Accept': 'application/json'
      };
      let resp: http.HttpResponse = await request.request(DeepSeekBalanceService.balanceUrl(config.baseUrl), {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 20000,
        usingProtocol: http.HttpProtocol.HTTP1_1
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return null;
      }
      let body: string = '';
      let result: Object = resp.result;
      if (typeof result === 'string') {
        body = result as string;
      } else if (result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8', { ignoreBOM: true })
          .decodeToString(new Uint8Array(result as ArrayBuffer));
      } else if (typeof result === 'object' && result !== null) {
        body = JSON.stringify(result);
      }
      if (body === '') {
        return null;
      }
      let parsed: Object = JSON.parse(body);
      if (typeof parsed !== 'object' || parsed === null) {
        return null;
      }
      let root: Record<string, Object> = parsed as Record<string, Object>;
      let info: DeepSeekBalanceInfo = new DeepSeekBalanceInfo();
      info.updatedAt = Date.now();
      let available: Object | undefined = root['is_available'];
      info.available = available === true;
      let rawInfos: Object | undefined = root['balance_infos'];
      if (rawInfos !== undefined && rawInfos instanceof Array) {
        let list: Object[] = rawInfos as Object[];
        let chosen: Record<string, Object> | null = null;
        for (let i: number = 0; i < list.length; i++) {
          if (typeof list[i] !== 'object' || list[i] === null) {
            continue;
          }
          let rec: Record<string, Object> = list[i] as Record<string, Object>;
          if (chosen === null) {
            chosen = rec;
          }
          let currency: Object | undefined = rec['currency'];
          if (typeof currency === 'string' && (currency as string) === 'CNY') {
            chosen = rec;
            break;
          }
        }
        if (chosen !== null) {
          let currency: Object | undefined = chosen['currency'];
          if (typeof currency === 'string') {
            info.currency = currency as string;
          }
          info.total = DeepSeekBalanceService.readMoney(chosen, 'total_balance');
          info.granted = DeepSeekBalanceService.readMoney(chosen, 'granted_balance');
          info.toppedUp = DeepSeekBalanceService.readMoney(chosen, 'topped_up_balance');
        }
      }
      return info;
    } catch (e) {
      return null;
    } finally {
      try {
        request.destroy();
      } catch (e) {
        // ignore
      }
    }
  }

  private static readMoney(obj: Record<string, Object>, key: string): number {
    let raw: Object | undefined = obj[key];
    if (typeof raw === 'string') {
      let n: number = parseFloat(raw as string);
      return isNaN(n) ? 0 : n;
    }
    if (typeof raw === 'number') {
      return raw as number;
    }
    return 0;
  }
}
