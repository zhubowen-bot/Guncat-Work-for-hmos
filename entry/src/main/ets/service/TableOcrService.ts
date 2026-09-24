// TableOcrService: 表格识别 (对齐 web 版本 table-ocr.html)
// 流程: 图片 -> VLM 生成 <table> HTML -> 输出原始 HTML
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { arrayBufferToBase64 } from '../common/Utils';

export const TABLE_OCR_PROMPT: string = `你是专业的表格识别引擎。任务：把图片中的表格转换成等价的 HTML <table>，忠实保留合并关系、内容和行高信息。

【输出格式】
- 只输出 <table>...</table>，不要代码块、不要反引号围栏、不要任何解释文字。
- 表头单元格用 <th>，数据单元格用 <td>。
- 空单元格输出 <td></td>，不要省略。
- 单元格内的换行用 <br> 表示。

【合并单元格 - 最重要】
- 合并区域只在左上角单元格写内容，用 rowspan / colspan 表达跨度。
- 被合并覆盖的位置不要再输出 <td>。
- 跨 N 行 M 列的单元格：<td rowspan="N" colspan="M">内容</td>

【行高信息 - 用 data-lines 属性】
表格中有些行在视觉上明显很高，是预留出来给人手写或填写内容的空白区域。请用 data-lines 属性标注这类行：
- 在 <tr> 上加 data-lines="N"，N 表示这行预留的"书写行数"（不是文字行数，而是空白书写空间能写几行字）。
- 判断方法：看这行的空白区域大约能写下几行正常大小的字。
  - 普通单行文本行：不标注（默认 data-lines="1"）。
  - 预留 2 行书写空间：data-lines="2"
  - 预留 4 行书写空间：data-lines="4"
  - 预留 6 行书写空间：data-lines="6"
- 仅由单元格内文字自然换行撑高的行，不要标注 data-lines（那种高度由文字本身决定）。
- 只标注"有大量空白书写区域"的行。

【内容忠实】
- 保留原有数字、小数、百分比、货币符号、千分位、空格。
- 看不清或模糊的字一律留空，宁可空着也不要猜测或补全。
- 不要添加原表中没有的标题、说明或汇总行。

【示例 1：rowspan】
<table>
<tr><th rowspan="2">项目</th><th>2023</th><th>2024</th></tr>
<tr><td>100</td><td>120</td></tr>
</table>

【示例 2：colspan + 空单元格】
<table>
<tr><th>地区</th><th colspan="2">销售额</th></tr>
<tr><th></th><th>Q1</th><th>Q2</th></tr>
<tr><td>华东</td><td>100</td><td>120</td></tr>
</table>

【示例 3：data-lines 标注高行】
<table>
<tr><th>姓名</th><td></td></tr>
<tr data-lines="4"><th>审批意见</th><td></td></tr>
<tr><th>日期</th><td></td></tr>
</table>

【示例 4：单元格内换行】
<table>
<tr><td>第一行<br>第二行</td><td>数据</td></tr>
</table>

现在请转换图片中的表格。先在心中规划好每个单元格的位置和跨度，判断每行是否需要标注 data-lines，再输出 HTML。`;

export interface TableOcrImage {
  bytes: ArrayBuffer;
  mimeType: string;
}

export class TableOcrService {
  // 调用 VLM 识别表格图片, 返回模型输出的 HTML
  static async recognizeImage(config: MultimodalConfig, imageData: TableOcrImage): Promise<string> {
    if (config.apiKey === '') {
      throw new Error('请先配置 API Key');
    }
    let baseUrl: string = config.baseUrl.replace(/\/+$/, '');
    if (baseUrl === '') {
      baseUrl = 'https://open.bigmodel.cn/api/paas/v4';
    }
    let url: string = baseUrl + '/chat/completions';
    let model: string = config.model;
    if (model === '') {
      model = 'glm-4.6v-flash';
    }

    let dataUrl: string = 'data:' + imageData.mimeType + ';base64,' +
      arrayBufferToBase64(imageData.bytes);
    let systemMsg: Record<string, string> = { role: 'system', content: TABLE_OCR_PROMPT };
    let textPart: Record<string, string> = { type: 'text', text: '请识别图片中的表格，并严格按照系统要求只输出 HTML <table>。' };
    let imagePart: Record<string, Object> = {
      type: 'image_url',
      image_url: { url: dataUrl }
    };
    let userMsg: Record<string, Object> = { role: 'user', content: [textPart, imagePart] };
    let body: Record<string, Object> = {
      model: model,
      messages: [systemMsg, userMsg],
      temperature: 0.1,
      max_tokens: 4096
    };
    // DeepSeek 视觉模型默认可能进入思考模式，导致 content 为空；表格识别不需要深度思考。
    if (model.toLowerCase().indexOf('deepseek') !== -1 || baseUrl.indexOf('deepseek.com') !== -1) {
      body['thinking'] = { type: 'disabled' };
    }
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

      if (resp.responseCode !== 200) {
        let errText: string = (resp.result as string) ?? '';
        throw new Error('API 返回 ' + resp.responseCode.toString() + ': ' + errText);
      }
      let responseStr: string = resp.result as string;
      let json: Object = JSON.parse(responseStr);
      if (typeof json !== 'object' || json === null) {
        throw new Error('API 返回为空');
      }
      let choices: Object = (json as Record<string, Object>)['choices'];
      if (!(choices instanceof Array) || choices.length === 0) {
        throw new Error('API 返回为空');
      }
      let first: Object = choices[0];
      if (typeof first !== 'object' || first === null) {
        throw new Error('API 返回为空');
      }
      let msg: Object = (first as Record<string, Object>)['message'];
      if (typeof msg !== 'object' || msg === null) {
        throw new Error('API 返回为空');
      }
      let content: Object = (msg as Record<string, Object>)['content'];
      if (typeof content !== 'string') {
        throw new Error('API 返回内容为空');
      }
      if (content.trim() === '') {
        let snippet: string = responseStr.length > 500 ? responseStr.substring(0, 500) : responseStr;
        throw new Error('模型返回内容为空，原始响应：' + snippet);
      }
      return content;
    } finally {
      try {
        httpRequest.destroy();
      } catch (e) {
        // ignore
      }
    }
  }

  // 清理 VLM 输出: 去掉 markdown 围栏, 只保留 <table>...</table>
  static cleanHtml(raw: string): string {
    let s: string = raw.trim();
    s = s.replace(/^```(?:html)?\s*\n?/i, '').replace(/\n?```\s*$/i, '');
    // 兼容模型输出全角尖括号（＜ ＞）的情况
    s = s.replace(/＜/g, '<').replace(/＞/g, '>');
    let match: RegExpMatchArray | null = s.match(/<table[\s\S]*<\/table>/i);
    if (match !== null) {
      return match[0].trim();
    }
    // 兼容输出被截断、缺少 </table> 的情况：从 <table 开始尽量保留后续内容
    let openIndex: number = s.search(/<table/i);
    if (openIndex !== -1) {
      return s.substring(openIndex).trim();
    }
    return s.trim();
  }

  // 图片压缩: 最长边超过 2500px 时等比缩小, 统一转 JPEG 质量 0.9 (对齐 web canvas 逻辑)
  static async compressImage(bytes: ArrayBuffer): Promise<TableOcrImage> {
    let src: image.ImageSource | null = null;
    let pixel: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      src = image.createImageSource(bytes);
      let info: image.ImageInfo = await src.getImageInfo();
      const maxSize: number = 2500;
      let w: number = info.size.width;
      let h: number = info.size.height;
      if (w > maxSize || h > maxSize) {
        let scale: number = maxSize / Math.max(w, h);
        w = Math.round(w * scale);
        h = Math.round(h * scale);
      }
      pixel = await src.createPixelMap({
        desiredSize: { width: w, height: h }
      });
      packer = image.createImagePacker();
      let packed: ArrayBuffer = await packer.packToData(pixel, {
        format: 'image/jpeg',
        quality: 90
      });
      return { bytes: packed, mimeType: 'image/jpeg' };
    } finally {
      try {
        if (pixel !== null) {
          pixel.release();
        }
      } catch (e) {
        // ignore
      }
      try {
        if (packer !== null) {
          packer.release();
        }
      } catch (e) {
        // ignore
      }
      try {
        if (src !== null) {
          src.release();
        }
      } catch (e) {
        // ignore
      }
    }
  }
}