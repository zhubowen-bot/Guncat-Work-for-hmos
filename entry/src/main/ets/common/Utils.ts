// 简易 ID 生成器
import { util } from '@kit.ArkTS';

export function generateId(prefix: string): string {
  let timestamp: number = new Date().getTime();
  let random: number = Math.floor(Math.random() * 1000000);
  return `${prefix}_${timestamp}_${random}`;
}

export function generateMessageId(): string {
  return generateId('msg');
}

export function generateConversationId(): string {
  return generateId('conv');
}

export function generateFileId(): string {
  return generateId('file');
}

// 简易 HTML 转义
export function escapeHtml(text: string): string {
  let result: string = text;
  result = result.replace(/&/g, '&amp;');
  result = result.replace(/</g, '&lt;');
  result = result.replace(/>/g, '&gt;');
  result = result.replace(/"/g, '&quot;');
  result = result.replace(/'/g, '&#39;');
  return result;
}

export function escapeAttr(text: string): string {
  return escapeHtml(text);
}

// 简易 Markdown -> 富文本(只覆盖 web 版本 main 用到的子集: 标题/粗体/斜体/行内代码/代码块/链接/列表/引用/表格/段落)
export function renderMarkdown(md: string): RichSegment[] {
  let segments: RichSegment[] = [];
  if (md.length === 0) {
    return segments;
  }

  let lines: string[] = md.split('\n');
  let i: number = 0;

  while (i < lines.length) {
    let line: string = lines[i];

    // 代码块
    if (line.startsWith('```')) {
      let lang: string = line.substring(3).trim();
      let code: string = '';
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) {
        code += lines[i] + '\n';
        i++;
      }
      if (i < lines.length) {
        i++;
      }
      segments.push({ kind: 'code', language: lang, content: code });
      continue;
    }

    // 标题
    let headingMatch: RegExpMatchArray | null = line.match(/^(#{1,6})\s+(.*)$/);
    if (headingMatch !== null) {
      let level: number = headingMatch[1].length;
      segments.push({ kind: 'heading', level: level, content: headingMatch[2] });
      i++;
      continue;
    }

    // 引用
    if (line.startsWith('> ')) {
      let quote: string = line.substring(2);
      while (i + 1 < lines.length && lines[i + 1].startsWith('> ')) {
        i++;
        quote += '\n' + lines[i].substring(2);
      }
      segments.push({ kind: 'quote', content: quote });
      i++;
      continue;
    }

    // 表格
    if (line.indexOf('|') !== -1 && i + 1 < lines.length && /^\s*\|?[\s\-:|]+\|?[\s\-:|\s]*$/.test(lines[i + 1])) {
      let header: string = line;
      i++;
      // 跳过分隔行
      i++;
      let rows: string[] = [];
      while (i < lines.length && lines[i].indexOf('|') !== -1) {
        rows.push(lines[i]);
        i++;
      }
      segments.push({ kind: 'table', header: header, rows: rows });
      continue;
    }

    // 无序列表
    if (/^[\-\*]\s+/.test(line)) {
      let items: string[] = [];
      while (i < lines.length && /^[\-\*]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^[\-\*]\s+/, ''));
        i++;
      }
      segments.push({ kind: 'list', ordered: false, items: items });
      continue;
    }

    // 有序列表
    if (/^\d+\.\s+/.test(line)) {
      let items: string[] = [];
      while (i < lines.length && /^\d+\.\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\d+\.\s+/, ''));
        i++;
      }
      segments.push({ kind: 'list', ordered: true, items: items });
      continue;
    }

    // 空行
    if (line.trim() === '') {
      i++;
      continue;
    }

    // 普通段落 (合并连续非空行)
    let para: string = line;
    while (i + 1 < lines.length && lines[i + 1].trim() !== '' &&
      !lines[i + 1].startsWith('#') && !lines[i + 1].startsWith('> ') &&
      !lines[i + 1].startsWith('```') && !/^[\-\*]\s+/.test(lines[i + 1]) &&
      !/^\d+\.\s+/.test(lines[i + 1]) && lines[i + 1].indexOf('|') === -1) {
      i++;
      para += '\n' + lines[i];
    }
    segments.push({ kind: 'paragraph', content: para });
    i++;
  }

  return segments;
}

// 内联格式解析(返回富文本子段)
export function parseInline(text: string): InlineSegment[] {
  let result: InlineSegment[] = [];
  let i: number = 0;
  let buf: string = '';

  let flushBuf = (): void => {
    if (buf.length > 0) {
      result.push({ kind: 'text', content: buf });
      buf = '';
    }
  };

  while (i < text.length) {
    let ch: string = text[i];

    // 行内代码
    if (ch === '`') {
      let end: number = text.indexOf('`', i + 1);
      if (end !== -1) {
        flushBuf();
        result.push({ kind: 'code', content: text.substring(i + 1, end) });
        i = end + 1;
        continue;
      }
    }

    // 粗体 ** **
    if (ch === '*' && i + 1 < text.length && text[i + 1] === '*') {
      let end: number = text.indexOf('**', i + 2);
      if (end !== -1) {
        flushBuf();
        result.push({ kind: 'bold', content: text.substring(i + 2, end) });
        i = end + 2;
        continue;
      }
    }

    // 斜体 * *
    if (ch === '*') {
      let end: number = text.indexOf('*', i + 1);
      if (end !== -1 && end !== i + 1) {
        flushBuf();
        result.push({ kind: 'italic', content: text.substring(i + 1, end) });
        i = end + 1;
        continue;
      }
    }

    // 链接 [text](url)
    if (ch === '[') {
      let closeBracket: number = text.indexOf(']', i + 1);
      if (closeBracket !== -1 && closeBracket + 1 < text.length && text[closeBracket + 1] === '(') {
        let closeParen: number = text.indexOf(')', closeBracket + 2);
        if (closeParen !== -1) {
          flushBuf();
          let linkText: string = text.substring(i + 1, closeBracket);
          let linkUrl: string = text.substring(closeBracket + 2, closeParen);
          result.push({ kind: 'link', content: linkText, href: linkUrl });
          i = closeParen + 1;
          continue;
        }
      }
    }

    buf += ch;
    i++;
  }

  flushBuf();
  return result;
}

export interface RichSegment {
  kind: 'heading' | 'paragraph' | 'code' | 'list' | 'quote' | 'table';
  content?: string;
  level?: number;
  language?: string;
  ordered?: boolean;
  items?: string[];
  header?: string;
  rows?: string[];
}

export interface InlineSegment {
  kind: 'text' | 'bold' | 'italic' | 'code' | 'link';
  content: string;
  href?: string;
}

// 时间格式
export function formatDate(timestamp: number): string {
  let date: Date = new Date(timestamp);
  let month: number = date.getMonth() + 1;
  let day: number = date.getDate();
  let hours: number = date.getHours();
  let minutes: number = date.getMinutes();
  let pad: (n: number) => string = (n: number): string => {
    return n < 10 ? '0' + n : '' + n;
  };
  return `${month}/${day} ${pad(hours)}:${pad(minutes)}`;
}

// 截断
export function truncateText(text: string, maxLen: number): string {
  if (text.length <= maxLen) {
    return text;
  }
  return text.substring(0, maxLen) + '...';
}

// 延迟
export function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

// 字符串是否已 http(s) 开头
export function isHttpUrl(url: string): boolean {
  return url.startsWith('http://') || url.startsWith('https://');
}

// 简单的 base64 编码(用于文件上传)
// 实现: 全数值化填入 ASCII 字节缓冲, 最后经 utf-16le 解码一次性转字符串。
// 禁止逐字符拼接大字符串(曾引发 SharedHeap OOM 级别的内存放大)。
const B64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
let b64Codes: Uint8Array | null = null;
let b64Decoder: util.TextDecoder = util.TextDecoder.create('utf-16le', { ignoreBOM: true });

export function arrayBufferToBase64(buf: ArrayBuffer): string {
  let bytes: Uint8Array = new Uint8Array(buf);
  if (b64Codes === null) {
    b64Codes = new Uint8Array(64);
    for (let i: number = 0; i < 64; i++) {
      b64Codes[i] = B64_ALPHABET.charCodeAt(i);
    }
  }
  let table: Uint8Array = b64Codes as Uint8Array;
  let outLen: number = Math.floor((bytes.length + 2) / 3) * 4;
  let out: Uint8Array = new Uint8Array(outLen);
  let o: number = 0;
  let i: number = 0;
  for (; i + 2 < bytes.length; i += 3) {
    let b1: number = bytes[i];
    let b2: number = bytes[i + 1];
    let b3: number = bytes[i + 2];
    out[o] = table[b1 >> 2];
    o++;
    out[o] = table[((b1 & 0x3) << 4) | (b2 >> 4)];
    o++;
    out[o] = table[((b2 & 0xf) << 2) | (b3 >> 6)];
    o++;
    out[o] = table[b3 & 0x3f];
    o++;
  }
  let rem: number = bytes.length - i;
  if (rem === 1) {
    let b1: number = bytes[i];
    out[o] = table[b1 >> 2];
    o++;
    out[o] = table[(b1 & 0x3) << 4];
    o++;
    out[o] = 0x3D;
    o++;
    out[o] = 0x3D;
    o++;
  } else if (rem === 2) {
    let b1: number = bytes[i];
    let b2: number = bytes[i + 1];
    out[o] = table[b1 >> 2];
    o++;
    out[o] = table[((b1 & 0x3) << 4) | (b2 >> 4)];
    o++;
    out[o] = table[(b2 & 0xf) << 2];
    o++;
    out[o] = 0x3D;
    o++;
  }
  // ASCII 字节 → 字符串: 每字节扩为 utf-16le 码元后原生解码(零字符串拼接)
  let u16: Uint8Array = new Uint8Array(o * 2);
  for (let k: number = 0; k < o; k++) {
    u16[k * 2] = out[k];
    u16[k * 2 + 1] = 0;
  }
  return b64Decoder.decodeToString(u16);
}
