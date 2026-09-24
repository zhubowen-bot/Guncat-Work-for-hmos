// OfficeReader: 工作模式本地解析 Office 文档文本 (无需多模态配额)
// 原理: docx/xlsx/pptx 都是 zip 包(OOXML), 用 zlib.decompressFile 解包到缓存临时目录,
//      再扫描其中 XML 的文本节点: docx→w:t, xlsx→sharedStrings+worksheet, pptx→a:t。
// 抽取为全量文本(全部工作表/全部幻灯片, 不截断), 截断与分页由调用方负责
// (read_file 按行分页, search_files 按行匹配, 二者行号一致)。
// 仅支持 OOXML 格式(.docx/.xlsx/.pptx); 老格式(.doc/.xls/.ppt)不支持。
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

export class OfficeReader {
  // 兼容入口: 全量抽取后按 maxChars 截断
  static async extractText(absPath: string, tempRoot: string, maxChars: number): Promise<string> {
    let full: string = await OfficeReader.extractAll(absPath, tempRoot);
    return OfficeReader.capChars(full, maxChars);
  }

  // 全量抽取(不截断, 全部工作表/全部幻灯片); 失败抛 Error(由调用方转为工具错误结果)
  static async extractAll(absPath: string, tempRoot: string): Promise<string> {
    let lower: string = absPath.toLowerCase();
    if (lower.endsWith('.docx')) {
      return OfficeReader.extractDocx(absPath, tempRoot);
    }
    if (lower.endsWith('.xlsx')) {
      return OfficeReader.extractXlsx(absPath, tempRoot);
    }
    if (lower.endsWith('.pptx')) {
      return OfficeReader.extractPptx(absPath, tempRoot);
    }
    throw new Error('该类型不支持本地解析');
  }

  // ===== docx: word/document.xml → w:t =====
  private static async extractDocx(absPath: string, tempRoot: string): Promise<string> {
    let tempDir: string = await OfficeReader.unpack(absPath, tempRoot);
    try {
      let docXml: string = OfficeReader.readUtf8(tempDir + '/word/document.xml');
      // 表格单元格内的段落也被 </w:p> 切分, 单元格之间自然换行
      let paras: string[] = docXml.split('</w:p>');
      let lines: string[] = [];
      for (let i: number = 0; i < paras.length; i++) {
        let texts: string[] = [];
        OfficeReader.collectTagTexts(paras[i], 'w:t', texts);
        let line: string = texts.join('');
        if (line.trim() !== '') {
          lines.push(line.trim());
        }
      }
      if (lines.length === 0) {
        return '(文档为空或无可提取文本)';
      }
      return lines.join('\n');
    } finally {
      OfficeReader.deleteDirSync(tempDir);
    }
  }

  // ===== xlsx: sharedStrings + worksheets → TSV =====
  private static async extractXlsx(absPath: string, tempRoot: string): Promise<string> {
    let tempDir: string = await OfficeReader.unpack(absPath, tempRoot);
    try {
      // 共享字符串表
      let shared: string[] = [];
      let ssPath: string = tempDir + '/xl/sharedStrings.xml';
      if (fileIo.accessSync(ssPath)) {
        let ssXml: string = OfficeReader.readUtf8(ssPath);
        let sis: string[] = [];
        OfficeReader.splitTopLevel(ssXml, '<si>', '</si>', sis);
        for (let i: number = 0; i < sis.length; i++) {
          let texts: string[] = [];
          OfficeReader.collectTagTexts(sis[i], 't', texts);
          shared.push(texts.join(''));
        }
      }
      // 工作表(全部)
      let outParts: string[] = [];
      let sheetDir: string = tempDir + '/xl/worksheets';
      if (!fileIo.accessSync(sheetDir)) {
        return '(工作簿中没有工作表)';
      }
      let names: string[] = fileIo.listFileSync(sheetDir);
      names.sort();
      let sheetCount: number = 0;
      for (let i: number = 0; i < names.length; i++) {
        if (!names[i].endsWith('.xml')) {
          continue;
        }
        sheetCount++;
        let sheetXml: string = OfficeReader.readUtf8(sheetDir + '/' + names[i]);
        if (sheetCount > 1) {
          outParts.push('=== 工作表 ' + names[i].replace('.xml', '') + ' ===');
        }
        outParts.push(OfficeReader.sheetToTsv(sheetXml, shared));
      }
      if (outParts.length === 0) {
        return '(工作簿为空)';
      }
      return outParts.join('\n');
    } finally {
      OfficeReader.deleteDirSync(tempDir);
    }
  }

  // 单个 worksheet → TSV 文本
  private static sheetToTsv(sheetXml: string, shared: string[]): string {
    let rows: string[] = [];
    OfficeReader.splitTopLevel(sheetXml, '<row ', '</row>', rows);
    let lines: string[] = [];
    for (let r: number = 0; r < rows.length; r++) {
      // 每行内按 <c 属性切分单元格
      let cells: OfficeCell[] = [];
      let cellChunks: string[] = [];
      OfficeReader.splitTopLevel(rows[r], '<c ', '</c>', cellChunks);
      for (let c: number = 0; c < cellChunks.length; c++) {
        let chunk: string = cellChunks[c];
        let colIdx: number = OfficeReader.colIndexOf(chunk);
        let text: string = OfficeReader.cellText(chunk, shared);
        if (text !== '') {
          let cell: OfficeCell = new OfficeCell();
          cell.col = colIdx;
          cell.text = text;
          cells.push(cell);
        }
      }
      cells.sort(OfficeReader.compareCell);
      let cols: string[] = [];
      for (let c: number = 0; c < cells.length; c++) {
        cols.push(cells[c].text);
      }
      if (cols.length > 0) {
        lines.push(cols.join('\t'));
      }
    }
    if (lines.length === 0) {
      return '(空工作表)';
    }
    return lines.join('\n');
  }

  // ===== pptx: ppt/slides/slideN.xml → a:t =====
  private static async extractPptx(absPath: string, tempRoot: string): Promise<string> {
    let tempDir: string = await OfficeReader.unpack(absPath, tempRoot);
    try {
      let slideDir: string = tempDir + '/ppt/slides';
      if (!fileIo.accessSync(slideDir)) {
        return '(演示文稿中没有幻灯片)';
      }
      let names: string[] = fileIo.listFileSync(slideDir);
      names.sort(OfficeReader.compareSlideNames);
      let outParts: string[] = [];
      let shown: number = 0;
      for (let i: number = 0; i < names.length; i++) {
        if (!names[i].endsWith('.xml') || !names[i].startsWith('slide')) {
          continue;
        }
        shown++;
        let slideXml: string = OfficeReader.readUtf8(slideDir + '/' + names[i]);
        let paras: string[] = slideXml.split('</a:p>');
        let lines: string[] = [];
        for (let p: number = 0; p < paras.length; p++) {
          let texts: string[] = [];
          OfficeReader.collectTagTexts(paras[p], 'a:t', texts);
          let line: string = texts.join('').trim();
          if (line !== '') {
            lines.push(line);
          }
        }
        outParts.push('--- 第 ' + shown.toString() + ' 页 ---');
        if (lines.length === 0) {
          outParts.push('(空白页)');
        } else {
          for (let p: number = 0; p < lines.length; p++) {
            outParts.push(lines[p]);
          }
        }
      }
      return outParts.join('\n');
    } finally {
      OfficeReader.deleteDirSync(tempDir);
    }
  }

  // ===== 基础工具 =====

  // 解包到临时目录并返回目录路径; 失败抛错
  private static async unpack(absPath: string, tempRoot: string): Promise<string> {
    let tempDir: string = tempRoot + '/ofr_' + Date.now().toString() + '_' +
      Math.floor(Math.random() * 10000).toString();
    if (!fileIo.accessSync(tempRoot)) {
      fileIo.mkdirSync(tempRoot, true);
    }
    if (fileIo.accessSync(tempDir)) {
      OfficeReader.deleteDirSync(tempDir);
    }
    fileIo.mkdirSync(tempDir, true);
    // 解压 zip 包内全部条目到 tempDir(非 zip 或损坏时抛错)
    await zlib.decompressFile(absPath, tempDir);
    return tempDir;
  }

  private static readUtf8(absPath: string): string {
    let stat: fileIo.Stat = fileIo.statSync(absPath);
    // 单 XML 部件读取上限 8MB, 超出截断(保护极端大文档的内存)
    const maxBytes: number = 8 * 1024 * 1024;
    let size: number = stat.size;
    let truncated: boolean = false;
    if (size > maxBytes) {
      size = maxBytes;
      truncated = true;
    }
    let buffer: ArrayBuffer = new ArrayBuffer(size);
    let file: fileIo.File = fileIo.openSync(absPath, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0 });
    } finally {
      fileIo.closeSync(file.fd);
    }
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    let text: string = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
    if (truncated) {
      text += '\n...(文件过大已截断)';
    }
    return text;
  }

  // 在 xml 片段中收集 <tag ...>text</tag> 的文本(跳过自闭合), 顺序拼接
  // 边界校验: 开标签名后必须紧跟 '>'、'/' 或空白, 避免 <w:t 误匹配 <w:tc>/<w:tab>/<w:tbl> 等前缀
  private static collectTagTexts(xml: string, tag: string, out: string[]): void {
    let open: string = '<' + tag;
    let close: string = '</' + tag + '>';
    let pos: number = 0;
    while (true) {
      let start: number = xml.indexOf(open, pos);
      if (start < 0) {
        break;
      }
      let after: string = xml.charAt(start + open.length);
      if (!(after === '>' || after === '/' || after === ' ' || after === '\t' ||
        after === '\n' || after === '\r')) {
        pos = start + open.length;
        continue;
      }
      let gt: number = xml.indexOf('>', start);
      if (gt < 0) {
        break;
      }
      // 自闭合 <tag/>
      if (xml.charAt(gt - 1) === '/') {
        pos = gt + 1;
        continue;
      }
      let end: number = xml.indexOf(close, gt + 1);
      if (end < 0) {
        break;
      }
      out.push(OfficeReader.decodeEntities(xml.substring(gt + 1, end)));
      pos = end + close.length;
    }
  }

  // 按 begin/end 标记切分出顶层片段(片段含 begin..end 完整内容)
  private static splitTopLevel(xml: string, begin: string, end: string, out: string[]): void {
    let pos: number = 0;
    while (true) {
      let start: number = xml.indexOf(begin, pos);
      if (start < 0) {
        break;
      }
      let stop: number = xml.indexOf(end, start);
      if (stop < 0) {
        break;
      }
      out.push(xml.substring(start, stop + end.length));
      pos = stop + end.length;
    }
  }

  // 单元格文本: t="s" → 共享字符串; inlineStr → <is><t>; 否则 <v> 原文
  private static cellText(cellXml: string, shared: string[]): string {
    let isShared: boolean = cellXml.indexOf('t="s"') !== -1;
    let isInline: boolean = cellXml.indexOf('t="inlineStr"') !== -1;
    if (isShared) {
      let vs: string[] = [];
      OfficeReader.collectTagTexts(cellXml, 'v', vs);
      if (vs.length > 0) {
        let idx: number = parseInt(vs[0], 10);
        if (!isNaN(idx) && idx >= 0 && idx < shared.length) {
          return shared[idx];
        }
      }
      return '';
    }
    if (isInline) {
      let ts: string[] = [];
      OfficeReader.collectTagTexts(cellXml, 't', ts);
      return ts.join('');
    }
    let vals: string[] = [];
    OfficeReader.collectTagTexts(cellXml, 'v', vals);
    return vals.length > 0 ? vals[0] : '';
  }

  // 从 <c r="B3" ...> 中解析列号(0 基)
  private static colIndexOf(cellXml: string): number {
    let rIdx: number = cellXml.indexOf('r="');
    if (rIdx < 0) {
      return 0;
    }
    let start: number = rIdx + 3;
    let col: number = 0;
    let i: number = start;
    while (i < cellXml.length) {
      let code: number = cellXml.charCodeAt(i);
      if (code >= 65 && code <= 90) {
        col = col * 26 + (code - 64);
        i++;
      } else if (code >= 97 && code <= 122) {
        col = col * 26 + (code - 96);
        i++;
      } else {
        break;
      }
    }
    return col > 0 ? col - 1 : 0;
  }

  private static compareCell(a: OfficeCell, b: OfficeCell): number {
    return a.col - b.col;
  }

  // slide1.xml < slide2.xml < slide10.xml(数值排序)
  private static compareSlideNames(a: string, b: string): number {
    return OfficeReader.slideNum(a) - OfficeReader.slideNum(b);
  }

  private static slideNum(name: string): number {
    let digitStart: number = 0;
    for (let i: number = 0; i < name.length; i++) {
      let code: number = name.charCodeAt(i);
      if (code >= 48 && code <= 57) {
        digitStart = i;
        break;
      }
    }
    let digits: string = '';
    for (let i: number = digitStart; i < name.length; i++) {
      let ch: string = name.charAt(i);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
      } else {
        break;
      }
    }
    let n: number = parseInt(digits, 10);
    return isNaN(n) ? 0 : n;
  }

  private static decodeEntities(text: string): string {
    let out: string = text;
    if (out.indexOf('&') === -1) {
      return out;
    }
    out = out.replace(/&lt;/g, '<');
    out = out.replace(/&gt;/g, '>');
    out = out.replace(/&quot;/g, '"');
    out = out.replace(/&apos;/g, '\'');
    out = out.replace(/&#x([0-9A-Fa-f]+);/g, (_m: string, hex: string): string => {
      return String.fromCharCode(parseInt(hex, 16));
    });
    out = out.replace(/&#(\d+);/g, (_m: string, dec: string): string => {
      return String.fromCharCode(parseInt(dec, 10));
    });
    out = out.replace(/&amp;/g, '&');
    return out;
  }

  private static capChars(text: string, max: number): string {
    if (text.length <= max) {
      return text;
    }
    return text.substring(0, max) + '\n...(内容过长已截断)';
  }

  private static deleteDirSync(abs: string): void {
    try {
      if (!fileIo.accessSync(abs)) {
        return;
      }
      let stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.isDirectory()) {
        let names: string[] = fileIo.listFileSync(abs);
        for (let i: number = 0; i < names.length; i++) {
          OfficeReader.deleteDirSync(abs + '/' + names[i]);
        }
        fileIo.rmdirSync(abs);
      } else {
        fileIo.unlinkSync(abs);
      }
    } catch (e) {
      // 清理失败不阻断主流程
    }
  }
}

// xlsx 单元格中间结构
class OfficeCell {
  col: number = 0;
  text: string = '';
}
