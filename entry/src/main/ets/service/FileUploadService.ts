// FileUploadService: 通过 Files API 上传图片/文档，返回 file_id
// 兼容 DeepSeek / 火山方舟的 OpenAI Responses 体系：
//   POST {baseUrl}/files
//   multipart/form-data: purpose=user_data, file=<原始文件>
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ApiConfig } from '../model/ApiConfig';

function sanitizeFileName(name: string): string {
  return name.replace(/["\r\n]/g, '_');
}

function stringToBuffer(text: string): ArrayBuffer {
  let encoder: util.TextEncoder = new util.TextEncoder();
  let bytes: Uint8Array = encoder.encodeInto(text);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

function concatBuffers(parts: ArrayBuffer[]): ArrayBuffer {
  let total: number = 0;
  for (let i: number = 0; i < parts.length; i++) {
    total += parts[i].byteLength;
  }
  let result: ArrayBuffer = new ArrayBuffer(total);
  let dst: Uint8Array = new Uint8Array(result);
  let offset: number = 0;
  for (let i: number = 0; i < parts.length; i++) {
    let src: Uint8Array = new Uint8Array(parts[i]);
    dst.set(src, offset);
    offset += src.byteLength;
  }
  return result;
}

function buildMultipartBody(fileName: string, mimeType: string, data: ArrayBuffer): { body: ArrayBuffer; boundary: string } {
  let boundary: string = '----GuncatBoundary' + Date.now().toString() + Math.floor(Math.random() * 1000000).toString();
  let preamble: string =
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="purpose"\r\n\r\n' +
    'user_data\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="file"; filename="' + sanitizeFileName(fileName) + '"\r\n' +
    'Content-Type: ' + mimeType + '\r\n\r\n';
  let suffix: string = '\r\n--' + boundary + '--\r\n';
  let body: ArrayBuffer = concatBuffers([stringToBuffer(preamble), data, stringToBuffer(suffix)]);
  return { body: body, boundary: boundary };
}

export class FileUploadService {
  static async uploadFile(
    config: ApiConfig,
    fileName: string,
    mimeType: string,
    data: ArrayBuffer
  ): Promise<string> {
    if (config.apiKey === '') {
      throw new Error('请先配置 API Key');
    }
    let baseUrl: string = config.baseUrl.replace(/\/+$/, '');
    if (baseUrl === '') {
      throw new Error('Base URL 不能为空');
    }
    let isAnthropic: boolean = config.provider === 'anthropic-messages';
    let url: string;
    if (isAnthropic) {
      if (baseUrl.endsWith('/v1') || baseUrl.endsWith('/anthropic/v1')) {
        url = baseUrl + '/files';
      } else if (baseUrl === 'https://api.deepseek.com' || baseUrl === 'http://api.deepseek.com') {
        url = baseUrl + '/anthropic/v1/files';
      } else {
        url = baseUrl + '/v1/files';
      }
    } else {
      url = baseUrl + '/files';
    }
    let multipart: { body: ArrayBuffer; boundary: string } = buildMultipartBody(fileName, mimeType, data);

    let httpRequest: http.HttpRequest = http.createHttp();
    try {
      let resp: http.HttpResponse = await new Promise<http.HttpResponse>(
        (resolve: (v: http.HttpResponse) => void, reject: (e: Error) => void) => {
          let headers: Record<string, string> = {
            'Content-Type': 'multipart/form-data; boundary=' + multipart.boundary
          };
          if (isAnthropic) {
            headers['x-api-key'] = config.apiKey;
            headers['anthropic-version'] = '2023-06-01';
            headers['anthropic-beta'] = 'files-api-2025-04-14';
          } else {
            headers['Authorization'] = 'Bearer ' + config.apiKey;
          }
          httpRequest.request(url, {
            method: http.RequestMethod.POST,
            header: headers,
            extraData: multipart.body,
            connectTimeout: 30000,
            readTimeout: 120000
          }, (err: Error, data: http.HttpResponse) => {
            if (err !== null && err !== undefined) {
              reject(err);
            } else {
              resolve(data);
            }
          });
        }
      );

      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        let errText: string = (resp.result as string) ?? '';
        throw new Error('文件上传失败 (' + resp.responseCode.toString() + '): ' + errText);
      }
      let responseStr: string = resp.result as string;
      let json: Object = JSON.parse(responseStr);
      if (typeof json !== 'object' || json === null) {
        throw new Error('文件上传返回为空');
      }
      let id: Object = (json as Record<string, Object>)['id'];
      if (typeof id === 'string' && id !== '') {
        return id;
      }
      let fileId: Object = (json as Record<string, Object>)['file_id'];
      if (typeof fileId === 'string' && fileId !== '') {
        return fileId;
      }
      throw new Error('文件上传响应缺少 file_id');
    } finally {
      try {
        httpRequest.destroy();
      } catch (e) {
        // ignore
      }
    }
  }
}
