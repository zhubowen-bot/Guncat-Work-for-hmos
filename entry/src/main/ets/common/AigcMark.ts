// AigcMark: 人工智能生成合成内容标识(显式 + 隐式)
//
// 显式标识:
//   - 对话/工作模式正文附近、交互界面底部显示 "AI生成";
//   - 复制纯文本 / Markdown 时在末尾追加 "AI生成";
//   - 导出的 Word / PPT / Excel / SVG 内含可见的 "AI生成"。
// 隐式标识:
//   - OOXML(docx/pptx/xlsx) 的 docProps/custom.xml 写入 AIGC 字段;
//   - SVG 的 <metadata id="aigc-mark"> 写入同一份 AIGC 字段。
//
// 字段格式遵循 GB 45438-2025 附录 E:
// {"AIGC":{"Label":"1","ContentProducer":"...","ProduceID":"...",
//  "ReservedCode1":"","ContentPropagator":"...","PropagateID":"...","ReservedCode2":""}}
//
// 说明: 应用本身不内置、不代理任何大模型服务; 用户自行配置模型 API。
// 这里的 "生成合成服务提供者" 取应用名与包名, 用于标明内容由本应用侧的
// AI 能力产出/整理, 不冒充模型服务商。
export class AigcMark {
  static readonly LABEL: string = 'AI生成';
  static readonly NOTICE: string = '本内容由人工智能生成，请仔细甄别。';
  static readonly PRODUCER: string = 'Guncat Work';
  static readonly PRODUCER_CODE: string = 'com.bowenapp.guncataibeta';
  static readonly PROPAGATOR: string = 'Guncat Work';
  static readonly PROPAGATOR_CODE: string = 'com.bowenapp.guncataibeta';
  static readonly CUSTOM_PROPERTY: string = 'AIGC';
  static readonly ZIP_NOTICE_FILE: string = 'AI生成内容标识.txt';
  static readonly SVG_META_ID: string = 'aigc-mark';

  private static pad2(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  private static randomHex(len: number): string {
    let chars: string = '0123456789abcdef';
    let out: string = '';
    for (let i: number = 0; i < len; i++) {
      out += chars.charAt(Math.floor(Math.random() * 16));
    }
    return out;
  }

  // 内容制作编号: 时间 + 随机串, 便于同一文件内保持唯一且可追溯。
  static newProduceId(): string {
    let d: Date = new Date();
    return 'GW-' + d.getFullYear().toString() + AigcMark.pad2(d.getMonth() + 1) +
      AigcMark.pad2(d.getDate()) + AigcMark.pad2(d.getHours()) +
      AigcMark.pad2(d.getMinutes()) + AigcMark.pad2(d.getSeconds()) +
      '-' + AigcMark.randomHex(8);
  }

  private static jsonEscape(text: string): string {
    let out: string = '';
    for (let i: number = 0; i < text.length; i++) {
      let c: string = text.charAt(i);
      if (c === '\\') {
        out += '\\\\';
      } else if (c === '"') {
        out += '\\"';
      } else if (c === '\n') {
        out += '\\n';
      } else if (c === '\r') {
        out += '\\r';
      } else if (c === '\t') {
        out += '\\t';
      } else {
        out += c;
      }
    }
    return out;
  }

  static xmlEscape(text: string): string {
    let out: string = '';
    for (let i: number = 0; i < text.length; i++) {
      let c: string = text.charAt(i);
      if (c === '&') {
        out += '&amp;';
      } else if (c === '<') {
        out += '&lt;';
      } else if (c === '>') {
        out += '&gt;';
      } else if (c === '"') {
        out += '&quot;';
      } else if (c === '\'') {
        out += '&apos;';
      } else {
        out += c;
      }
    }
    return out;
  }

  // 附录 E 规定的字段顺序; 首次写入时传播者与制作者一致。
  static json(produceId: string): string {
    let id: string = AigcMark.jsonEscape(produceId);
    let producer: string = AigcMark.jsonEscape(
      AigcMark.PRODUCER + ' (' + AigcMark.PRODUCER_CODE + ')');
    let propagator: string = AigcMark.jsonEscape(
      AigcMark.PROPAGATOR + ' (' + AigcMark.PROPAGATOR_CODE + ')');
    return '{"AIGC":{"Label":"1","ContentProducer":"' + producer +
      '","ProduceID":"' + id + '","ReservedCode1":"","ContentPropagator":"' + propagator +
      '","PropagateID":"' + id + '","ReservedCode2":""}}';
  }

  static hasTrailingMark(text: string): boolean {
    let tail: string = text.length > 64 ? text.substring(text.length - 64) : text;
    return tail.indexOf('AI生成') >= 0 || tail.indexOf('AI 生成') >= 0;
  }

  // 纯文本末尾追加显式标识(用于复制/纯文本导出)。
  static stampPlainText(text: string): string {
    if (text.trim() === '' || AigcMark.hasTrailingMark(text)) {
      return text;
    }
    return text.replace(/\s+$/, '') + '\n\n' + AigcMark.LABEL;
  }

  // Markdown 末尾追加引用式显式标识(用于复制 MD / Markdown 导出)。
  static stampMarkdown(text: string): string {
    if (text.trim() === '' || AigcMark.hasTrailingMark(text)) {
      return text;
    }
    return text.replace(/\s+$/, '') + '\n\n> ' + AigcMark.LABEL;
  }

  // HTML 末尾追加一个不抢版面的小角标(用于分享/打包导出副本)。
  static stampHtml(text: string): string {
    if (text.trim() === '' || AigcMark.hasTrailingMark(text)) {
      return text;
    }
    let footer: string = '<footer style="margin:16px 0;text-align:right;font:12px/1.5 sans-serif;' +
      'color:#8A94A6;">' + AigcMark.LABEL + '</footer>';
    let lower: string = text.toLowerCase();
    let close: number = lower.lastIndexOf('</body>');
    if (close >= 0) {
      return text.substring(0, close) + footer + text.substring(close);
    }
    return text + '\n' + footer;
  }

  // ===== OOXML 隐式标识 =====

  static customPropertiesXml(produceId: string): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" ' +
      'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
      '<property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="' +
      AigcMark.CUSTOM_PROPERTY + '"><vt:lpwstr>' +
      AigcMark.xmlEscape(AigcMark.json(produceId)) +
      '</vt:lpwstr></property></Properties>';
  }

  static readonly CUSTOM_CONTENT_TYPE: string =
    'application/vnd.openxmlformats-officedocument.custom-properties+xml';

  static readonly CUSTOM_REL_TYPE: string =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties';

  static customContentTypeOverride(): string {
    return '<Override PartName="/docProps/custom.xml" ContentType="' +
      AigcMark.CUSTOM_CONTENT_TYPE + '"/>';
  }

  static customRootRelationship(relId: string): string {
    return '<Relationship Id="' + relId + '" Type="' + AigcMark.CUSTOM_REL_TYPE +
      '" Target="docProps/custom.xml"/>';
  }

  // Word 页脚: 8pt 浅灰 "AI生成", 不挤压正文。
  static docxFooterXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
      '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>' +
      '<w:r><w:rPr><w:color w:val="9AA3AF"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>' +
      '<w:t>' + AigcMark.LABEL + '</w:t></w:r></w:p></w:ftr>';
  }

  // Word 正文末尾的一行小字, 与页脚一起保证"文本末尾"也有显式标识。
  static docxEndParagraphXml(): string {
    return '<w:p><w:pPr><w:spacing w:before="240"/><w:jc w:val="center"/></w:pPr>' +
      '<w:r><w:rPr><w:color w:val="9AA3AF"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>' +
      '<w:t>' + AigcMark.LABEL + '</w:t></w:r></w:p>';
  }

  // ===== SVG 显式 + 隐式标识 =====

  private static svgNumber(value: string): number {
    let m: RegExpMatchArray | null = value.match(/-?\d+(\.\d+)?/);
    if (m === null || m.length === 0) {
      return 0;
    }
    return parseFloat(m[0]);
  }

  private static svgDimensions(svg: string): number[] {
    let lower: string = svg.toLowerCase();
    let open: number = lower.indexOf('<svg');
    if (open < 0) {
      return [0, 0];
    }
    let end: number = svg.indexOf('>', open);
    if (end < 0) {
      return [0, 0];
    }
    let tag: string = svg.substring(open, end);
    let w: number = 0;
    let h: number = 0;
    let vb: RegExpMatchArray | null = tag.match(/\sviewBox\s*=\s*"([^"]*)"/i);
    if (vb !== null && vb.length > 1) {
      let parts: string[] = vb[1].trim().split(/\s+/);
      if (parts.length === 4) {
        w = AigcMark.svgNumber(parts[2]);
        h = AigcMark.svgNumber(parts[3]);
      }
    }
    let wm: RegExpMatchArray | null = tag.match(/\swidth\s*=\s*"([^"]*)"/i);
    let hm: RegExpMatchArray | null = tag.match(/\sheight\s*=\s*"([^"]*)"/i);
    if (!(w > 0 && h > 0) && wm !== null && hm !== null) {
      w = AigcMark.svgNumber(wm[1]);
      h = AigcMark.svgNumber(hm[1]);
    }
    return [w, h];
  }

  // 在根元素后插入 AIGC 元数据, 在右下角加一行 "AI生成"。
  // 字号按规范取最短边的 5%, 同时设 12px 下限, 避免小图不可辨。
  static stampSvg(svg: string, produceId: string): string {
    if (svg.indexOf('id="' + AigcMark.SVG_META_ID + '"') >= 0) {
      return svg;
    }
    let lower: string = svg.toLowerCase();
    let open: number = lower.indexOf('<svg');
    let close: number = lower.lastIndexOf('</svg>');
    if (open < 0 || close < 0) {
      return svg;
    }
    let rootEnd: number = svg.indexOf('>', open);
    if (rootEnd < 0 || rootEnd > close) {
      return svg;
    }
    let dims: number[] = AigcMark.svgDimensions(svg);
    let w: number = dims[0] > 0 ? dims[0] : 512;
    let h: number = dims[1] > 0 ? dims[1] : 512;
    let shortest: number = Math.min(w, h);
    let font: number = Math.max(12, shortest * 0.05);
    let x: number = Math.max(font * 0.4, w - font * 0.4);
    let y: number = Math.max(font, h - font * 0.35);
    let metadata: string = '<metadata id="' + AigcMark.SVG_META_ID + '"><![CDATA[' +
      AigcMark.json(produceId) + ']]></metadata>';
    let label: string = '<text x="' + AigcMark.svgNumber(x.toFixed(2)).toString() +
      '" y="' + AigcMark.svgNumber(y.toFixed(2)).toString() +
      '" font-family="sans-serif" font-size="' + AigcMark.svgNumber(font.toFixed(2)).toString() +
      '" fill="#6B7280" fill-opacity="0.75" text-anchor="end" ' +
      'paint-order="stroke" stroke="#FFFFFF" stroke-width="2" stroke-opacity="0.6">' +
      AigcMark.LABEL + '</text>';
    let head: string = svg.substring(0, rootEnd + 1);
    let body: string = svg.substring(rootEnd + 1, close);
    return head + metadata + body + label + svg.substring(close);
  }

  // ===== PNG 隐式标识(用于 SVG 栅格化预览) =====

  private static readU32(data: Uint8Array, offset: number): number {
    return ((data[offset] << 24) | (data[offset + 1] << 16) |
      (data[offset + 2] << 8) | data[offset + 3]) >>> 0;
  }

  private static writeU32(data: Uint8Array, offset: number, value: number): void {
    data[offset] = (value >>> 24) & 0xFF;
    data[offset + 1] = (value >>> 16) & 0xFF;
    data[offset + 2] = (value >>> 8) & 0xFF;
    data[offset + 3] = value & 0xFF;
  }

  private static crc32(data: Uint8Array): number {
    let crc: number = 0xFFFFFFFF;
    for (let i: number = 0; i < data.length; i++) {
      crc = crc ^ data[i];
      for (let k: number = 0; k < 8; k++) {
        crc = (crc & 1) === 1 ? (0xEDB88320 ^ (crc >>> 1)) : (crc >>> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  private static asciiBytes(text: string): Uint8Array {
    let out: Uint8Array = new Uint8Array(text.length);
    for (let i: number = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i) & 0xFF;
    }
    return out;
  }

  private static concatBytes(parts: Uint8Array[]): Uint8Array {
    let total: number = 0;
    for (let i: number = 0; i < parts.length; i++) {
      total += parts[i].length;
    }
    let out: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (let i: number = 0; i < parts.length; i++) {
      out.set(parts[i], offset);
      offset += parts[i].length;
    }
    return out;
  }

  // 在 PNG 的 IHDR 之后插入 tEXt 块(AIGC 关键字 + 附录 E JSON)。
  // 不是 PNG 或已存在 AIGC 块时原样返回, 不破坏图片。
  static stampPng(data: Uint8Array, produceId: string): Uint8Array {
    if (data.length < 33 || data[0] !== 0x89 || data[1] !== 0x50 ||
      data[2] !== 0x4E || data[3] !== 0x47) {
      return data;
    }
    let pos: number = 8;
    while (pos + 12 <= data.length) {
      let len: number = AigcMark.readU32(data, pos);
      let type: string = String.fromCharCode(data[pos + 4], data[pos + 5],
        data[pos + 6], data[pos + 7]);
      if (type === 'tEXt') {
        let end: number = pos + 8 + len;
        if (end <= data.length) {
          let text: string = '';
          for (let i: number = pos + 8; i < end; i++) {
            text += String.fromCharCode(data[i]);
          }
          if (text.indexOf('AIGC\u0000') === 0) {
            return data;
          }
        }
      }
      if (type === 'IEND' || pos + 12 + len > data.length) {
        break;
      }
      pos += 12 + len;
    }
    let ihdrLen: number = AigcMark.readU32(data, 8);
    let insertAt: number = 8 + 12 + ihdrLen;
    if (insertAt > data.length) {
      return data;
    }
    let payload: Uint8Array = AigcMark.asciiBytes('AIGC\u0000' + AigcMark.json(produceId));
    let chunk: Uint8Array = new Uint8Array(12 + payload.length);
    AigcMark.writeU32(chunk, 0, payload.length);
    chunk[4] = 0x74; // t
    chunk[5] = 0x45; // E
    chunk[6] = 0x58; // X
    chunk[7] = 0x74; // t
    chunk.set(payload, 8);
    AigcMark.writeU32(chunk, 8 + payload.length,
      AigcMark.crc32(chunk.subarray(4, 8 + payload.length)));
    return AigcMark.concatBytes([
      data.subarray(0, insertAt),
      chunk,
      data.subarray(insertAt)
    ]);
  }

  // ===== 工作区打包导出说明 =====

  static zipNotice(produceId: string, fileCount: number): string {
    return 'AI生成内容标识\n' +
      '================\n' +
      '本压缩包由 ' + AigcMark.PRODUCER + ' 导出，包含人工智能生成或编辑的内容，请仔细甄别。\n\n' +
      '生成合成标签：1（属于人工智能生成合成内容）\n' +
      '生成合成服务提供者：' + AigcMark.PRODUCER + ' (' + AigcMark.PRODUCER_CODE + ')\n' +
      '内容制作编号：' + produceId + '\n' +
      '文件数量：' + fileCount.toString() + '\n\n' +
      '包内的 Word / PowerPoint / Excel / SVG 文件在文件元数据中带有 AIGC 字段；\n' +
      'Markdown / 纯文本文件末尾带有“AI生成”文字标识。\n' +
      '表格数据(CSV/JSON)为保持可机读，未插入会破坏数据结构的标识行；\n' +
      '其 AI 生成属性以本说明文件和应用内标识为准。\n';
  }
}
