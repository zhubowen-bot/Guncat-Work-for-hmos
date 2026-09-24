// Markdown 解析器: 将消息文本解析为块级结构 + 行内 token
// 支持: 标题/段落/代码块/引用/无序有序列表/GFM表格/分隔线/行内与块级LaTeX公式/加粗斜体删除线/行内代码/链接/图片
// 行内 token 带格式标志, 由 OoxmlBuilder 渲染为 Word XML

// 块级结构
export class MdBlock {
  type: string = 'paragraph'; // heading|paragraph|codeblock|quote|ul|ol|table|hr|math
  level: number = 0;          // heading 级别 1-6
  inline: string = '';        // heading/paragraph/quote 的原始行内文本
  code: string = '';          // codeblock 原始代码
  lang: string = '';          // codeblock 语言标注
  items: string[] = [];       // ul/ol 的条目文本
  itemLevels: number[] = [];  // 每条目的缩进级别 0/1
  tableHeaders: string[] = [];
  tableRows: string[][] = [];
  math: string = '';          // math 块的 latex 源码
}

// 行内 token
export class InlineToken {
  type: string = 'text';      // text|math|link|image
  text: string = '';
  bold: boolean = false;
  italic: boolean = false;
  strike: boolean = false;
  code: boolean = false;
  href: string = '';
  alt: string = '';
  displayMath: boolean = false;
}

const RE_HEADING: RegExp = /^#{1,6}\s*(.*)$/;
const RE_HEADING_ONLY: RegExp = /^#{1,6}\s*$/;
const RE_HR: RegExp = /^\s*([-*_])(\s*\1){2,}\s*$/;
const RE_UL_ITEM: RegExp = /^(\s*)([-*+])\s+(.*)$/;
const RE_OL_ITEM: RegExp = /^(\s*)(\d{1,3})[.)]\s+(.*)$/;
const RE_QUOTE: RegExp = /^>\s?(.*)$/;
const RE_FENCE: RegExp = /^\s*(`{3,}|~{3,})\s*([\w+#.-]*)\s*$/;
const RE_EMPTY: RegExp = /^\s*$/;

export class MarkdownParser {
  // 块级解析
  static parseBlocks(md: string): MdBlock[] {
    let blocks: MdBlock[] = [];
    let text: string = md.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    let lines: string[] = text.split('\n');
    let i: number = 0;
    let n: number = lines.length;
    while (i < n) {
      let line: string = lines[i];
      // 空行
      if (RE_EMPTY.test(line)) {
        i++;
        continue;
      }
      // 围栏代码块
      let fenceMatch: RegExpExecArray | null = RE_FENCE.exec(line);
      if (fenceMatch !== null) {
        let fence: string = fenceMatch[1];
        let lang: string = fenceMatch[2];
        i++;
        let codeLines: string[] = [];
        while (i < n) {
          let inner: string = lines[i];
          let m: RegExpExecArray | null = RE_FENCE.exec(inner);
          if (m !== null && m[1].charAt(0) === fence.charAt(0) && m[1].length >= fence.length) {
            i++;
            break;
          }
          codeLines.push(inner);
          i++;
        }
        let block: MdBlock = new MdBlock();
        block.type = 'codeblock';
        block.lang = lang;
        block.code = codeLines.join('\n');
        blocks.push(block);
        continue;
      }
      // 标题
      if (RE_HEADING.test(line) && !RE_HEADING_ONLY.test(line)) {
        let level: number = 0;
        let content: string = '';
        let hMatch: RegExpExecArray | null = RE_HEADING.exec(line);
        if (hMatch !== null) {
          // 统计行首连续 # 数量
          while (level < line.length && line.charAt(level) === '#') {
            level++;
          }
          if (level < 1) {
            level = 1;
          }
          if (level > 6) {
            level = 6;
          }
          content = hMatch[1].trim();
        }
        let block: MdBlock = new MdBlock();
        block.type = 'heading';
        block.level = level;
        block.inline = content;
        blocks.push(block);
        i++;
        continue;
      }
      // 表格: 当前行是表头, 下一行是分隔行
      if (i + 1 < n && MarkdownParser.isTableDelimiter(lines[i + 1]) && line.indexOf('|') !== -1) {
        let headerCells: string[] = MarkdownParser.splitTableRow(line);
        i += 2;
        let rows: string[][] = [];
        while (i < n && !RE_EMPTY.test(lines[i]) && lines[i].indexOf('|') !== -1) {
          rows.push(MarkdownParser.splitTableRow(lines[i]));
          i++;
        }
        let block: MdBlock = new MdBlock();
        block.type = 'table';
        block.tableHeaders = headerCells;
        block.tableRows = rows;
        blocks.push(block);
        continue;
      }
      // 分隔线
      if (RE_HR.test(line)) {
        let block: MdBlock = new MdBlock();
        block.type = 'hr';
        blocks.push(block);
        i++;
        continue;
      }
      // 引用
      if (RE_QUOTE.test(line)) {
        let quoteLines: string[] = [];
        while (i < n && RE_QUOTE.test(lines[i])) {
          let qMatch: RegExpExecArray | null = RE_QUOTE.exec(lines[i]);
          if (qMatch !== null) {
            quoteLines.push(qMatch[1]);
          }
          i++;
        }
        let block: MdBlock = new MdBlock();
        block.type = 'quote';
        block.inline = quoteLines.join('\n');
        blocks.push(block);
        continue;
      }
      // 列表
      if (RE_UL_ITEM.test(line) || RE_OL_ITEM.test(line)) {
        let isOl: boolean = RE_OL_ITEM.test(line);
        let items: string[] = [];
        let levels: number[] = [];
        while (i < n && !RE_EMPTY.test(lines[i])) {
          let cur: string = lines[i];
          let ulMatch: RegExpExecArray | null = RE_UL_ITEM.exec(cur);
          let olMatch: RegExpExecArray | null = null;
          if (isOl) {
            olMatch = RE_OL_ITEM.exec(cur);
          } else {
            olMatch = null;
          }
          let isItem: boolean = (ulMatch !== null) || (olMatch !== null);
          if (isItem) {
            let indent: string = '';
            let content: string = '';
            if (ulMatch !== null) {
              indent = ulMatch[1];
              content = ulMatch[3];
            } else if (olMatch !== null) {
              indent = olMatch[1];
              content = olMatch[3];
            }
            items.push(content);
            levels.push(indent.length >= 2 ? 1 : 0);
            i++;
            continue;
          }
          // 列表项的续行(非空且不是新块起点): 附加到前一项
          if (items.length > 0 && !MarkdownParser.isBlockStart(cur)) {
            items[items.length - 1] = items[items.length - 1] + '\n' + cur;
            i++;
            continue;
          }
          break;
        }
        let block: MdBlock = new MdBlock();
        block.type = isOl ? 'ol' : 'ul';
        block.items = items;
        block.itemLevels = levels;
        blocks.push(block);
        continue;
      }
      // 块级公式 $$ ... $$
      if (line.startsWith('$$') && line.length > 2 && line.trim().endsWith('$$')) {
        let math: string = line.trim();
        let inner: string = math.substring(2, math.length - 2).trim();
        let block: MdBlock = new MdBlock();
        block.type = 'math';
        block.math = inner;
        blocks.push(block);
        i++;
        continue;
      }
      if (line.trim() === '$$') {
        i++;
        let mathLines: string[] = [];
        let closed: boolean = false;
        while (i < n) {
          if (lines[i].trim() === '$$') {
            closed = true;
            i++;
            break;
          }
          mathLines.push(lines[i]);
          i++;
        }
        let block: MdBlock = new MdBlock();
        block.type = 'math';
        block.math = closed ? mathLines.join('\n').trim() : ('$$' + mathLines.join('\n'));
        blocks.push(block);
        continue;
      }
      // 段落: 连续非空行
      let paraLines: string[] = [];
      while (i < n && !RE_EMPTY.test(lines[i])) {
        // 以新的块级标记开头的行提前结束段落
        if (paraLines.length > 0 && MarkdownParser.isBlockStart(lines[i])) {
          break;
        }
        paraLines.push(lines[i]);
        i++;
      }
      let block: MdBlock = new MdBlock();
      block.type = 'paragraph';
      block.inline = paraLines.join('\n');
      blocks.push(block);
    }
    return blocks;
  }

  // 判断某行是否可能开启新块
  private static isBlockStart(line: string): boolean {
    if (RE_EMPTY.test(line)) {
      return true;
    }
    if (RE_HEADING.test(line)) {
      return true;
    }
    if (RE_FENCE.test(line)) {
      return true;
    }
    if (RE_UL_ITEM.test(line) || RE_OL_ITEM.test(line)) {
      return true;
    }
    if (RE_QUOTE.test(line)) {
      return true;
    }
    if (RE_HR.test(line)) {
      return true;
    }
    if (line.trim() === '$$') {
      return true;
    }
    return false;
  }

  // 表格分隔行判断: |---|---| / |:--:|:--|
  private static isTableDelimiter(line: string): boolean {
    let trimmed: string = line.trim();
    if (trimmed === '') {
      return false;
    }
    let cells: string[] = trimmed.split('|');
    if (cells.length < 2) {
      return false;
    }
    for (let i: number = 0; i < cells.length; i++) {
      let cell: string = cells[i].trim();
      if (cell === '') {
        // 首尾空 cell 允许(由 | 开头/结尾产生)
        if (i === 0 || i === cells.length - 1) {
          continue;
        }
        return false;
      }
      if (!/^:?-+:?$/.test(cell)) {
        return false;
      }
    }
    return true;
  }

  // 拆分表格行(忽略首尾空 cell, 保留中间空 cell)
  private static splitTableRow(line: string): string[] {
    let cells: string[] = [];
    let trimmed: string = line.trim();
    let parts: string[] = trimmed.split('|');
    let start: number = 0;
    let end: number = parts.length;
    if (parts.length > 0 && parts[0].trim() === '') {
      start = 1;
    }
    if (end > start && parts[end - 1].trim() === '') {
      end = end - 1;
    }
    for (let i: number = start; i < end; i++) {
      cells.push(parts[i].trim());
    }
    return cells;
  }
}

// 行内解析器: 将行内文本转为 token 列表(嵌套格式递归解析, 标志叠加)
export class InlineParser {
  private src: string = '';
  private len: number = 0;

  static parse(text: string): InlineToken[] {
    let p: InlineParser = new InlineParser();
    p.src = text;
    p.len = text.length;
    let out: InlineToken[] = [];
    p.parseRange(0, p.len, false, false, false, false, out);
    return out;
  }

  // 解析 [start, end) 区间, 格式标志传入叠加
  private parseRange(start: number, end: number, bold: boolean, italic: boolean,
    strike: boolean, code: boolean, out: InlineToken[]): void {
    let i: number = start;
    let textBuf: string = '';
    while (i < end) {
      let c: string = this.src.charAt(i);
      // 转义
      if (c === '\\' && i + 1 < end) {
        textBuf += this.src.charAt(i + 1);
        i += 2;
        continue;
      }
      // 行内代码 `...`
      if (c === '`' && !code) {
        let tickCount: number = 0;
        while (i + tickCount < end && this.src.charAt(i + tickCount) === '`') {
          tickCount++;
        }
        let closeIdx: number = this.findSequence(i + tickCount, '`'.repeat(tickCount), end);
        if (closeIdx !== -1) {
          this.flushText(textBuf, bold, italic, strike, code, out);
          textBuf = '';
          let inner: string = this.src.substring(i + tickCount, closeIdx);
          let tok: InlineToken = new InlineToken();
          tok.type = 'text';
          tok.text = inner;
          tok.code = true;
          out.push(tok);
          i = closeIdx + tickCount;
          continue;
        }
        textBuf += c;
        i++;
        continue;
      }
      // 数学 $..$ / $$..$$
      if (c === '$') {
        let display: boolean = i + 1 < end && this.src.charAt(i + 1) === '$';
        let term: string = display ? '$$' : '$';
        let closeIdx: number = this.findMathClose(i + (display ? 2 : 1), term, end);
        if (closeIdx !== -1) {
          this.flushText(textBuf, bold, italic, strike, code, out);
          textBuf = '';
          let inner: string = this.src.substring(i + (display ? 2 : 1), closeIdx);
          let tok: InlineToken = new InlineToken();
          tok.type = 'math';
          tok.text = inner.trim();
          tok.displayMath = display;
          out.push(tok);
          i = closeIdx + term.length;
          continue;
        }
        textBuf += c;
        i++;
        continue;
      }
      // 图片 ![alt](url)
      if (c === '!' && i + 1 < end && this.src.charAt(i + 1) === '[') {
        let linkEnd: number = this.findLinkEnd(i + 2, end);
        if (linkEnd !== -1) {
          let textEnd: number = this.findSequence(i + 2, '](', linkEnd);
          if (textEnd !== -1) {
            this.flushText(textBuf, bold, italic, strike, code, out);
            textBuf = '';
            let alt: string = this.src.substring(i + 2, textEnd);
            let url: string = this.src.substring(textEnd + 2, linkEnd);
            let tok: InlineToken = new InlineToken();
            tok.type = 'image';
            tok.alt = alt;
            tok.text = url.trim();
            out.push(tok);
            i = linkEnd + 1;
            continue;
          }
        }
        textBuf += c;
        i++;
        continue;
      }
      // 链接 [text](url)
      if (c === '[' && !code) {
        let linkEnd: number = this.findLinkEnd(i + 1, end);
        if (linkEnd !== -1) {
          let textEnd: number = this.findSequence(i + 1, '](', linkEnd);
          if (textEnd !== -1) {
            this.flushText(textBuf, bold, italic, strike, code, out);
            textBuf = '';
            let text: string = this.src.substring(i + 1, textEnd);
            let url: string = this.src.substring(textEnd + 2, linkEnd);
            let tok: InlineToken = new InlineToken();
            tok.type = 'link';
            tok.text = text;
            tok.href = url.trim();
            out.push(tok);
            i = linkEnd + 1;
            continue;
          }
        }
        textBuf += c;
        i++;
        continue;
      }
      // 加粗/斜体/删除线
      if (c === '*' && !code) {
        let starCount: number = 0;
        while (i + starCount < end && this.src.charAt(i + starCount) === '*') {
          starCount++;
        }
        if (starCount >= 3) {
          let closeIdx: number = this.findSequence(i + 3, '***', end);
          if (closeIdx !== -1) {
            this.flushText(textBuf, bold, italic, strike, code, out);
            textBuf = '';
            let inner: InlineToken[] = [];
            this.parseRange(i + 3, closeIdx, true, true, strike, code, inner);
            this.appendAll(out, inner);
            i = closeIdx + 3;
            continue;
          }
        }
        if (starCount >= 2) {
          let closeIdx: number = this.findSequence(i + 2, '**', end);
          if (closeIdx !== -1) {
            this.flushText(textBuf, bold, italic, strike, code, out);
            textBuf = '';
            let inner: InlineToken[] = [];
            this.parseRange(i + 2, closeIdx, true, italic, strike, code, inner);
            this.appendAll(out, inner);
            i = closeIdx + 2;
            continue;
          }
        }
        if (starCount === 1) {
          let closeIdx: number = this.findSequence(i + 1, '*', end);
          if (closeIdx !== -1) {
            this.flushText(textBuf, bold, italic, strike, code, out);
            textBuf = '';
            let inner: InlineToken[] = [];
            this.parseRange(i + 1, closeIdx, bold, true, strike, code, inner);
            this.appendAll(out, inner);
            i = closeIdx + 1;
            continue;
          }
        }
        textBuf += '*';
        i++;
        continue;
      }
      if (c === '_' && !code) {
        // 下划线边界规则: 前一个字符非字母数字时才作为格式标记
        let prev: string = i > 0 ? this.src.charAt(i - 1) : '';
        let isBoundary: boolean = i === 0 || !InlineParser.isWordChar(prev);
        if (i + 1 < end && this.src.charAt(i + 1) === '_' && isBoundary) {
          let closeIdx: number = this.findSequence(i + 2, '__', end);
          if (closeIdx !== -1) {
            this.flushText(textBuf, bold, italic, strike, code, out);
            textBuf = '';
            let inner: InlineToken[] = [];
            this.parseRange(i + 2, closeIdx, true, italic, strike, code, inner);
            this.appendAll(out, inner);
            i = closeIdx + 2;
            continue;
          }
        }
        if (isBoundary && i + 1 < end && this.src.charAt(i + 1) !== '_' && !this.isSpace(this.src.charAt(i + 1))) {
          let closeIdx: number = this.findSequence(i + 1, '_', end);
          let closeBoundary: boolean = closeIdx !== -1 &&
            (closeIdx + 1 >= end || !InlineParser.isWordChar(this.src.charAt(closeIdx + 1)));
          if (closeIdx !== -1 && closeBoundary) {
            this.flushText(textBuf, bold, italic, strike, code, out);
            textBuf = '';
            let inner: InlineToken[] = [];
            this.parseRange(i + 1, closeIdx, bold, true, strike, code, inner);
            this.appendAll(out, inner);
            i = closeIdx + 1;
            continue;
          }
        }
        textBuf += c;
        i++;
        continue;
      }
      if (c === '~' && !code && i + 1 < end && this.src.charAt(i + 1) === '~') {
        let closeIdx: number = this.findSequence(i + 2, '~~', end);
        if (closeIdx !== -1) {
          this.flushText(textBuf, bold, italic, strike, code, out);
          textBuf = '';
          let inner: InlineToken[] = [];
          this.parseRange(i + 2, closeIdx, bold, italic, true, code, inner);
          this.appendAll(out, inner);
          i = closeIdx + 2;
          continue;
        }
        textBuf += c;
        i++;
        continue;
      }
      textBuf += c;
      i++;
    }
    this.flushText(textBuf, bold, italic, strike, code, out);
  }

  private flushText(buf: string, bold: boolean, italic: boolean, strike: boolean,
    code: boolean, out: InlineToken[]): void {
    if (buf === '') {
      return;
    }
    // 按换行拆分: 换行由渲染层转为 <w:br/>
    let parts: string[] = buf.split('\n');
    for (let k: number = 0; k < parts.length; k++) {
      if (k > 0) {
        let brTok: InlineToken = new InlineToken();
        brTok.type = 'br';
        out.push(brTok);
      }
      if (parts[k] !== '') {
        let tok: InlineToken = new InlineToken();
        tok.type = 'text';
        tok.text = parts[k];
        tok.bold = bold;
        tok.italic = italic;
        tok.strike = strike;
        tok.code = code;
        out.push(tok);
      }
    }
  }

  private appendAll(dest: InlineToken[], src: InlineToken[]): void {
    for (let i: number = 0; i < src.length; i++) {
      dest.push(src[i]);
    }
  }

  // 查找从 start 开始的序列 seq 的下一次出现(跳过转义), 返回下标或 -1
  private findSequence(start: number, seq: string, end: number): number {
    let i: number = start;
    while (i < end) {
      if (this.src.charAt(i) === '\\') {
        i += 2;
        continue;
      }
      if (this.src.startsWith(seq, i)) {
        return i;
      }
      i++;
    }
    return -1;
  }

  // 查找数学结束符(跳过 \$ 与 ` 包裹)
  private findMathClose(start: number, term: string, end: number): number {
    let i: number = start;
    while (i < end) {
      if (this.src.charAt(i) === '\\') {
        i += 2;
        continue;
      }
      if (this.src.startsWith(term, i)) {
        return i;
      }
      i++;
    }
    return -1;
  }

  // 查找链接结束位置(找第一个未转义的 ')'), 括号内可包含更多内容
  private findLinkEnd(start: number, end: number): number {
    let i: number = start;
    while (i < end) {
      let c: string = this.src.charAt(i);
      if (c === '\\') {
        i += 2;
        continue;
      }
      if (c === ')') {
        return i;
      }
      i++;
    }
    return -1;
  }

  private isSpace(c: string): boolean {
    return c === ' ' || c === '\t' || c === '\n';
  }

  static isWordChar(c: string): boolean {
    if (c === '') {
      return false;
    }
    let code: number = c.charCodeAt(0);
    return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }
}
