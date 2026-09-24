// PptxImporter: .pptx -> Deck(结构化中间层), 供 read_ppt / edit_ppt 使用
// 两级策略:
//   1) 本应用导出的 pptx 内嵌 docProps/deck.json 源文件, 直接还原(无损往返);
//   2) 外来 pptx(无内嵌源)按 slide XML 解析为 custom 版式: 文本框/图片按原位置保留,
//      表格还原数据, 图表转为占位说明。属于近似导入, 保真度有限(edit_ppt 会先备份原文件)。
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Deck, DeckSlide, DeckElement, DeckParser } from './DeckModel';

export class PptxImportResult {
  deck: Deck = new Deck();
  embedded: boolean = false;  // 是否来自内嵌源(无损)
  slideCount: number = 0;
}

export class PptxImporter {
  // 解包并导入; 失败抛 Error(信息面向 AI)
  static async import(absPath: string, cacheDir: string): Promise<PptxImportResult> {
    let tempDir: string = await PptxImporter.unpack(absPath, cacheDir);
    try {
      // 1) 内嵌源优先
      let deckPath: string = tempDir + '/docProps/deck.json';
      if (fileIo.accessSync(deckPath)) {
        let json: string = PptxImporter.readUtf8(deckPath, 4 * 1024 * 1024);
        let result: PptxImportResult = new PptxImportResult();
        try {
          result.deck = DeckParser.parse(json);
        } catch (e) {
          // 内嵌源损坏时降级为 XML 导入
          result.deck = await PptxImporter.importFromXml(tempDir);
        }
        result.embedded = true;
        result.slideCount = result.deck.slides.length;
        return result;
      }
      // 2) 外来文件: XML 近似导入
      let result: PptxImportResult = new PptxImportResult();
      result.deck = await PptxImporter.importFromXml(tempDir);
      result.embedded = false;
      result.slideCount = result.deck.slides.length;
      return result;
    } finally {
      PptxImporter.deleteDirSync(tempDir);
    }
  }

  // 外来 pptx -> Deck
  private static async importFromXml(tempDir: string): Promise<Deck> {
    let slideDir: string = tempDir + '/ppt/slides';
    if (!fileIo.accessSync(slideDir)) {
      throw new Error('该 pptx 中没有幻灯片(文件可能损坏)');
    }
    let names: string[] = fileIo.listFileSync(slideDir);
    names.sort(PptxImporter.compareSlideNames);
    let deck: Deck = new Deck();
    deck.theme = 'brand-blue';
    let first: boolean = true;
    for (let i: number = 0; i < names.length; i++) {
      if (!names[i].endsWith('.xml') || !names[i].startsWith('slide')) {
        continue;
      }
      let xml: string = PptxImporter.readUtf8(slideDir + '/' + names[i], 8 * 1024 * 1024);
      let slide: DeckSlide = PptxImporter.parseSlideXml(xml, first);
      deck.slides.push(slide);
      if (first && slide.title !== '') {
        deck.title = slide.title;
      }
      first = false;
      if (i % 8 === 7) {
        await PptxImporter.yieldNow();
      }
    }
    if (deck.slides.length === 0) {
      throw new Error('该 pptx 中没有可识别的幻灯片');
    }
    return deck;
  }

  // 单页 slide XML -> DeckSlide(custom 版式, 按原坐标摆放)
  private static parseSlideXml(xml: string, isFirst: boolean): DeckSlide {
    let slide: DeckSlide = new DeckSlide();
    slide.layout = 'custom';
    slide.title = '';
    // 媒体占位: 图片元素 src 不可还原(外来文件不保留二进制), 标注文本元素说明
    // 文本框
    let spChunks: string[] = [];
    PptxImporter.splitTopLevel(xml, '<p:sp>', '</p:sp>', spChunks);
    let texts: DeckElement[] = [];
    for (let i: number = 0; i < spChunks.length; i++) {
      let el: DeckElement | null = PptxImporter.parseTextSp(spChunks[i]);
      if (el !== null && el.text.trim() !== '') {
        texts.push(el);
      }
    }
    // 图片(pic): 位置保留, 但外来文件图片不导出 → 用占位 shape 表示
    let picChunks: string[] = [];
    PptxImporter.splitTopLevel(xml, '<p:pic>', '</p:pic>', picChunks);
    let imageNotes: string[] = [];
    for (let i: number = 0; i < picChunks.length; i++) {
      let box: Box | null = PptxImporter.boxOf(picChunks[i]);
      if (box !== null) {
        imageNotes.push('[' + Math.round(box.w * 100).toString() + '% 宽图片(原文件图片未导入)]');
      }
    }
    // 表格(graphicFrame 内 a:tbl)
    let tblChunks: string[] = [];
    PptxImporter.splitTopLevel(xml, '<a:tbl>', '</a:tbl>', tblChunks);
    for (let i: number = 0; i < tblChunks.length; i++) {
      let el: DeckElement | null = PptxImporter.parseTable(tblChunks[i]);
      if (el !== null) {
        slide.elements.push(el);
      }
    }
    // 图表(graphicFrame 内 c:chart) → 占位说明
    let chartCount: number = 0;
    let chartChunks: string[] = [];
    PptxImporter.splitTopLevel(xml, '<c:chart ', '</c:chart>', chartChunks);
    chartCount = chartChunks.length;
    if (chartCount > 0) {
      let note: DeckElement = new DeckElement();
      note.type = 'text';
      note.x = 0.1;
      note.y = 0.75;
      note.w = 0.8;
      note.h = 0.12;
      note.text = '(原页含 ' + chartCount.toString() + ' 个图表, 数据未导入; 可用 chart 版式重建)';
      note.size = 12;
      note.color = 'sub';
      slide.elements.push(note);
    }
    // 图片占位说明
    if (imageNotes.length > 0) {
      let note: DeckElement = new DeckElement();
      note.type = 'text';
      note.x = 0.1;
      note.y = 0.88;
      note.w = 0.8;
      note.h = 0.1;
      note.text = imageNotes.join(' ');
      note.size = 11;
      note.color = 'faint';
      slide.elements.push(note);
    }
    // 文本框进入 elements; 首个/大号居中文本提升为标题
    for (let i: number = 0; i < texts.length; i++) {
      let el: DeckElement = texts[i];
      let isBig: boolean = el.size >= 2400;
      if (isFirst && i === 0 && isBig) {
        slide.title = el.text.replace(/\n/g, ' ');
        continue;
      }
      if (i === 0 && isBig && slide.title === '' && el.align === 'center') {
        slide.title = el.text.replace(/\n/g, ' ');
        continue;
      }
      slide.elements.push(el);
    }
    if (slide.elements.length === 0 && slide.title !== '') {
      // 仅有一行大字的页 → 分节页观感
      let onlyTitle: DeckElement = new DeckElement();
      onlyTitle.type = 'text';
      onlyTitle.x = 0.1;
      onlyTitle.y = 0.4;
      onlyTitle.w = 0.8;
      onlyTitle.h = 0.2;
      onlyTitle.text = slide.title;
      onlyTitle.size = 30;
      onlyTitle.bold = true;
      onlyTitle.color = 'title';
      onlyTitle.align = 'center';
      slide.elements.push(onlyTitle);
      slide.title = '';
    }
    if (slide.elements.length === 0 && slide.title === '') {
      let blank: DeckElement = new DeckElement();
      blank.type = 'text';
      blank.x = 0.1;
      blank.y = 0.45;
      blank.w = 0.8;
      blank.h = 0.1;
      blank.text = '(空页)';
      blank.size = 12;
      blank.color = 'faint';
      slide.elements.push(blank);
    }
    return slide;
  }

  // <p:sp> 文本框 -> 定位文本元素
  private static parseTextSp(spXml: string): DeckElement | null {
    // 跳过占位符空文本框由文本判空兜底
    let el: DeckElement = new DeckElement();
    el.type = 'text';
    let box: Box | null = PptxImporter.boxOf(spXml);
    if (box !== null) {
      el.x = box.x;
      el.y = box.y;
      el.w = box.w;
      el.h = box.h;
    }
    // 段落文本 + 第一段的字号/加粗/对齐
    let paras: string[] = spXml.split('</a:p>');
    let lines: string[] = [];
    for (let p: number = 0; p < paras.length; p++) {
      let ts: string[] = [];
      PptxImporter.collectTagTexts(paras[p], 'a:t', ts);
      let line: string = ts.join('');
      if (line.trim() !== '') {
        lines.push(line);
      }
    }
    if (lines.length === 0) {
      return null;
    }
    el.text = lines.join('\n');
    let rPr: number = spXml.indexOf('<a:rPr ');
    if (rPr >= 0) {
      el.size = PptxImporter.attrNum(spXml, rPr, 'sz', 1800) / 100;
      el.bold = PptxImporter.attr(spXml, rPr, 'b') === '1';
    }
    if (spXml.indexOf('algn="ctr"') !== -1) {
      el.align = 'center';
    } else if (spXml.indexOf('algn="r"') !== -1) {
      el.align = 'right';
    }
    return el;
  }

  // <a:tbl> -> 表格元素
  private static parseTable(tblXml: string): DeckElement | null {
    let el: DeckElement = new DeckElement();
    el.type = 'table';
    el.x = 0.1;
    el.y = 0.25;
    el.w = 0.8;
    el.h = 0.5;
    let trs: string[] = [];
    PptxImporter.splitTopLevel(tblXml, '<a:tr', '</a:tr>', trs);
    for (let r: number = 0; r < trs.length; r++) {
      let tcs: string[] = [];
      PptxImporter.splitTopLevel(trs[r], '<a:tc>', '</a:tc>', tcs);
      let row: string[] = [];
      for (let c: number = 0; c < tcs.length; c++) {
        let ts: string[] = [];
        PptxImporter.collectTagTexts(tcs[c], 'a:t', ts);
        row.push(ts.join('').trim());
      }
      if (row.length > 0) {
        if (r === 0) {
          el.headers = row;
        } else {
          el.rows.push(row);
        }
      }
    }
    if (el.headers.length === 0 && el.rows.length === 0) {
      return null;
    }
    return el;
  }

  // ===== 基础工具 =====

  private static async unpack(absPath: string, tempRoot: string): Promise<string> {
    let tempDir: string = tempRoot + '/pim_' + Date.now().toString() + '_' +
      Math.floor(Math.random() * 10000).toString();
    if (!fileIo.accessSync(tempRoot)) {
      fileIo.mkdirSync(tempRoot, true);
    }
    if (fileIo.accessSync(tempDir)) {
      PptxImporter.deleteDirSync(tempDir);
    }
    fileIo.mkdirSync(tempDir, true);
    await zlib.decompressFile(absPath, tempDir);
    return tempDir;
  }

  private static readUtf8(absPath: string, maxBytes: number): string {
    let stat: fileIo.Stat = fileIo.statSync(absPath);
    let size: number = stat.size;
    if (size > maxBytes) {
      size = maxBytes;
    }
    let buffer: ArrayBuffer = new ArrayBuffer(size);
    let file: fileIo.File = fileIo.openSync(absPath, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0 });
    } finally {
      fileIo.closeSync(file.fd);
    }
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(buffer), { stream: false });
  }

  // xfrm 的 off/ext -> 0~1 画布比例
  private static boxOf(xml: string): Box | null {
    let xfrm: number = xml.indexOf('<a:xfrm>');
    if (xfrm < 0) {
      return null;
    }
    let end: number = xml.indexOf('</a:xfrm>', xfrm);
    if (end < 0) {
      return null;
    }
    let seg: string = xml.substring(xfrm, end);
    let off: number = seg.indexOf('<a:off ');
    let ext: number = seg.indexOf('<a:ext ');
    if (off < 0 || ext < 0) {
      return null;
    }
    let box: Box = new Box();
    box.x = PptxImporter.attrNum(seg, off, 'x', 0) / 12192000;
    box.y = PptxImporter.attrNum(seg, off, 'y', 0) / 6858000;
    box.w = PptxImporter.attrNum(seg, ext, 'cx', 0) / 12192000;
    box.h = PptxImporter.attrNum(seg, ext, 'cy', 0) / 6858000;
    if (box.w <= 0 || box.h <= 0) {
      return null;
    }
    return box;
  }

  private static attr(xml: string, from: number, name: string): string {
    let key: number = xml.indexOf(name + '="', from);
    if (key < 0) {
      return '';
    }
    let start: number = key + name.length + 2;
    let end: number = xml.indexOf('"', start);
    if (end < 0) {
      return '';
    }
    return xml.substring(start, end);
  }

  private static attrNum(xml: string, from: number, name: string, def: number): number {
    let s: string = PptxImporter.attr(xml, from, name);
    let n: number = parseInt(s, 10);
    return isNaN(n) ? def : n;
  }

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
      if (!(after === '>' || after === '/' || after === ' ')) {
        pos = start + open.length;
        continue;
      }
      let gt: number = xml.indexOf('>', start);
      if (gt < 0) {
        break;
      }
      if (xml.charAt(gt - 1) === '/') {
        pos = gt + 1;
        continue;
      }
      let end: number = xml.indexOf(close, gt + 1);
      if (end < 0) {
        break;
      }
      out.push(PptxImporter.decodeEntities(xml.substring(gt + 1, end)));
      pos = end + close.length;
    }
  }

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

  private static compareSlideNames(a: string, b: string): number {
    return PptxImporter.slideNum(a) - PptxImporter.slideNum(b);
  }

  private static slideNum(name: string): number {
    let digits: string = '';
    for (let i: number = 0; i < name.length; i++) {
      let ch: string = name.charAt(i);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
      } else if (digits !== '') {
        break;
      }
    }
    let n: number = parseInt(digits, 10);
    return isNaN(n) ? 0 : n;
  }

  private static yieldNow(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 0);
    });
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
          PptxImporter.deleteDirSync(abs + '/' + names[i]);
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

// EMU 矩形(0~1 比例)
class Box {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}
