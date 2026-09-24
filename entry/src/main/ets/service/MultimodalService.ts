// MultimodalService: 文件解析 (对齐 web 版本 parseFileWithMultimodal)
// 默认使用智谱 GLM-4.6V-Flash, 支持图片 / 文本 / PDF / 文档
import { http } from '@kit.NetworkKit';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { Constants } from '../common/Constants';
import { ParsedFileResult } from '../common/Types';
import { arrayBufferToBase64 } from '../common/Utils';

const PARSE_SYSTEM_PROMPT: string = '请仅解析用户上传的文件内容，完整地返回文件中包含的信息。不要回答具体问题，不要执行额外任务，不要对原始信息进行压缩，只返回文件内容的解析结果。';

function isTextFileName(name: string): boolean {
  let lower: string = name.toLowerCase();
  let textExts: string[] = ['.txt', '.md', '.json', '.js', '.ts', '.jsx', '.tsx',
    '.html', '.css', '.xml', '.csv', '.log', '.yaml', '.yml',
    '.py', '.java', '.c', '.cpp', '.h', '.go', '.rs', '.php',
    '.rb', '.swift', '.kt', '.sql'];
  for (let i: number = 0; i < textExts.length; i++) {
    if (lower.endsWith(textExts[i])) {
      return true;
    }
  }
  return false;
}

function isDocumentFileName(name: string): boolean {
  let lower: string = name.toLowerCase();
  let docExts: string[] = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx'];
  for (let i: number = 0; i < docExts.length; i++) {
    if (lower.endsWith(docExts[i])) {
      return true;
    }
  }
  return false;
}

function utf8ArrayBufferToString(buf: ArrayBuffer): string {
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
      result += String.fromCharCode(((b1 & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F));
      i += 3;
    } else {
      // 跳过非 UTF-8 字符
      i++;
    }
  }
  return result;
}

export class MultimodalService {
  static async parseFile(
    config: MultimodalConfig,
    fileName: string,
    fileBuffer: ArrayBuffer,
    fileType: string
  ): Promise<ParsedFileResult> {
    if (config.apiKey === '') {
      throw new Error('请先配置多模态解析 API 的密钥');
    }
    let baseUrl: string = config.baseUrl.replace(/\/+$/, '');
    if (baseUrl === '') {
      baseUrl = Constants.DEFAULT_MM_BASE_URL;
    }
    let url: string = baseUrl + Constants.CHAT_COMPLETIONS_PATH;
    let model: string = config.model;
    if (model === '') {
      model = Constants.DEFAULT_MM_MODEL;
    }

    let dataUrl: string = 'data:' + fileType + ';base64,' + arrayBufferToBase64(fileBuffer);
    let userContent: Record<string, Object>[] = [];

    if (fileType.startsWith('image/')) {
      let imagePart: Record<string, Object> = { type: 'image_url', image_url: { url: dataUrl } };
      userContent.push(imagePart);
    } else if (isTextFileName(fileName)) {
      let text: string = utf8ArrayBufferToString(fileBuffer);
      let textPart: Record<string, string> = { type: 'text', text: '文件名：' + fileName + '\n\n文件内容：\n' + text };
      userContent.push(textPart);
    } else if (isDocumentFileName(fileName)) {
      let textPart: Record<string, string> = { type: 'text', text: '文件名：' + fileName };
      userContent.push(textPart);
      let filePart: Record<string, Object> = { type: 'file_url', file_url: { url: dataUrl } };
      userContent.push(filePart);
    } else {
      throw new Error('不支持的文件类型：' + fileName);
    }

    let systemMsg: Record<string, string> = { role: 'system', content: PARSE_SYSTEM_PROMPT };
    let userMsg: Record<string, Object> = { role: 'user', content: userContent };
    let body: Record<string, Object> = {
      model: model,
      messages: [systemMsg, userMsg]
    };
    let bodyStr: string = JSON.stringify(body);

    let httpRequest: http.HttpRequest = http.createHttp();
    try {
      let resp: http.HttpResponse = await new Promise<http.HttpResponse>(
        (resolve: (v: http.HttpResponse) => void, reject: (e: Error) => void) => {
          httpRequest.request(url, {
            method: http.RequestMethod.POST,
            header: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ' + config.apiKey
            },
            extraData: bodyStr,
            connectTimeout: 15000,
            readTimeout: 30000
          }, (err: Error, data: http.HttpResponse) => {
            if (err !== null && err !== undefined) {
              reject(err);
            } else {
              resolve(data);
            }
          });
        }
      );

      if (resp.responseCode !== 200) {
        let errText: string = (resp.result as string) ?? '';
        throw new Error('多模态解析失败 (' + resp.responseCode + '): ' + errText);
      }
      let responseStr: string = resp.result as string;
      let json: Object = JSON.parse(responseStr);
      if (typeof json !== 'object' || json === null) {
        throw new Error('多模态解析返回为空');
      }
      let choices: Object = (json as Record<string, Object>)['choices'];
      if (!(choices instanceof Array) || choices.length === 0) {
        throw new Error('多模态解析返回为空');
      }
      let first: Object = choices[0];
      if (typeof first !== 'object' || first === null) {
        throw new Error('多模态解析返回为空');
      }
      let msg: Object = (first as Record<string, Object>)['message'];
      if (typeof msg !== 'object' || msg === null) {
        throw new Error('多模态解析返回为空');
      }
      let content: Object = (msg as Record<string, Object>)['content'];
      if (typeof content !== 'string') {
        throw new Error('多模态解析返回内容为空');
      }
      let result: ParsedFileResult = new ParsedFileResult();
      result.content = content as string;
      result.dataUrl = dataUrl;
      return result;
    } finally {
      try {
        httpRequest.destroy();
      } catch (e) {
        // ignore
      }
    }
  }
}
