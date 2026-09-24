// XlsxImporter: .xlsx -> Workbook JSON
// 优先读内嵌 docProps/workbook.json(自家文件无损还原); 否则解析外来工作簿:
// workbook.xml(表名/顺序) + rels + sharedStrings + 各 sheet(数字/字符串/公式/列宽/冻结窗格)。
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Constants } from '../common/Constants';
import { XlsxWorkbook, XlsxSheet, XlsxParser } from './XlsxModel';

export class XlsxImportResult {
  workbook: XlsxWorkbook = new XlsxWorkbook();
  embedded: boolean = false;
  sheetCount: number = 0;
  rowCount: number = 0;
}

export class XlsxImporter {
  // cacheDir 为解包临时目录的父目录(调用方保证存在), 解包到 cacheDir/xlsx_tmp_<ts>
  static async import(absPath: string, cacheDir: string): Promise<XlsxImportResult> {
    let result: XlsxImportResult = new XlsxImportResult();
    let tempDir: string = cacheDir + '/xlsx_tmp_' + Date.now().toString();
    fileIo.mkdirSync(tempDir, true);
    try {
      let stat: fileIo.Stat = fileIo.statSync(absPath);
      if (stat.size <= 0 || stat.size > Constants.WORK_XLSX_IMPORT_MAX_BYTES) {
        throw new Error('文件大小超出导入上限(' +
          (Constants.WORK_XLSX_IMPORT_MAX_BYTES / (1024 * 1024)).toString() + 'MB)');
      }
      await zlib.decompressFile(absPath, tempDir);
      // 1) 内嵌源无损还原
      let embeddedPath: string = tempDir + '/docProps/workbook.json';
      if (fileIo.accessSync(embeddedPath)) {
        let jsonText: string = XlsxImporter.readUtf8(embeddedPath);
        try {
          let wb: XlsxWorkbook = XlsxParser.parse(jsonText);
          result.workbook = wb;
          result.embedded = true;
          result.sheetCount = wb.sheets.length;
          result.rowCount = XlsxImporter.countRows(wb);
          return result;
        } catch (e) {
          // 内嵌源损坏 -> 退回 XML 解析
        }
      }
      // 2) 外来工作簿近似导入
      result.workbook = XlsxImporter.importFromXml(tempDir);
      result.embedded = false;
      result.sheetCount = result.workbook.sheets.length;
      result.rowCount = XlsxImporter.countRows(result.workbook);
      return result;
    } finally {
      XlsxImporter.deleteDirSync(tempDir);
    }
  }

  private static countRows(wb: XlsxWorkbook): number {
    let n: number = 0;
    for (let i: number = 0; i < wb.sheets.length; i++) {
      n += wb.sheets[i].rows.length;
    }
    return n;
  }

  // ===== 外来工作簿: 表名顺序 + 单元格值 =====

  private static importFromXml(tempDir: string): XlsxWorkbook {
    let wb: XlsxWorkbook = new XlsxWorkbook();
    wb.name = '外来工作簿';
    wb.style = 'default';
    let workbookXml: string = XlsxImporter.readUtf8Safe(tempDir + '/xl/workbook.xml');
    if (workbookXml === '') {
      throw new Error('不是合法的 .xlsx 文件(缺少 xl/workbook.xml)');
    }
    // 表顺序 + r:id
    let sheetRefs: string[] = [];
    let sheetNames: string[] = [];
    let sheetTargets: string[] = [];
    let sheets: string[] = [];
    XlsxImporter.splitTopLevel(workbookXml, '<sheet ', '/>', sheets);
    // 工作表关系 r:id -> 目标
    let rels: Map<string, string> = XlsxImporter.parseRels(tempDir + '/xl/_rels/workbook.xml.rels');
    for (let i: number = 0; i < sheets.length; i++) {
      let gt: number = sheets[i].indexOf('>');
      let tagSeg: string = gt >= 0 ? sheets[i].substring(0, gt) : sheets[i];
      let name: string = XlsxImporter.attrValue(tagSeg, 'name');
      let rid: string = XlsxImporter.attrValue(tagSeg, 'r:id');
      if (name === '' || rid === '') {
        continue;
      }
      sheetRefs.push(rid);
      sheetNames.push(name);
      let target: string | undefined = rels.get(rid);
      sheetTargets.push(target === undefined ? '' : target);
    }
    // 共享字符串
    let shared: string[] = XlsxImporter.parseSharedStrings(tempDir + '/xl/sharedStrings.xml');
    // 逐表解析
    for (let i: number = 0; i < sheetNames.length; i++) {
      let target: string = sheetTargets[i];
      let sheetPath: string = XlsxImporter.sheetAbsPath(tempDir, target);
      if (sheetPath === '') {
        continue;
      }
      let sheetXml: string = XlsxImporter.readUtf8Safe(sheetPath);
      if (sheetXml === '') {
        continue;
      }
      let s: XlsxSheet = XlsxImporter.parseSheet(sheetXml, shared, sheetNames[i]);
      wb.sheets.push(s);
      if (wb.sheets.length >= Constants.WORK_XLSX_MAX_SHEETS) {
        break;
      }
    }
    if (wb.sheets.length === 0) {
      throw new Error('工作簿中没有可读取的工作表');
    }
    return wb;
  }

  // 关系目标的绝对路径: "worksheets/sheet1.xml" 或 "/xl/worksheets/sheet1.xml"
  private static sheetAbsPath(tempDir: string, target: string): string {
    let t: string = target.replace(/\\/g, '/');
    if (t.startsWith('/')) {
      t = t.substring(1);
    }
    if (!t.startsWith('xl/')) {
      t = 'xl/' + t;
    }
    return tempDir + '/' + t;
  }

  private static parseSharedStrings(path: string): string[] {
    let shared: string[] = [];
    let xml: string = XlsxImporter.readUtf8Safe(path);
    if (xml === '') {
      return shared;
    }
    let sis: string[] = [];
    XlsxImporter.splitTopLevel(xml, '<si>', '</si>', sis);
    for (let i: number = 0; i < sis.length; i++) {
      let texts: string[] = [];
      XlsxImporter.collectTagTexts(sis[i], 't', texts);
      shared.push(texts.join(''));
    }
    return shared;
  }

  private static parseSheet(sheetXml: string, shared: string[], sheetName: string): XlsxSheet {
    let s: XlsxSheet = new XlsxSheet();
    s.name = sheetName;
    // 列宽
    let cols: string[] = [];
    XlsxImporter.splitTopLevel(sheetXml, '<col ', '/>', cols);
    let widthMap: Map<number, number> = new Map<number, number>();
    let maxColSeen: number = 0;
    for (let i: number = 0; i < cols.length; i++) {
      let gt: number = cols[i].indexOf('>');
      let tagSeg: string = gt >= 0 ? cols[i].substring(0, gt) : cols[i];
      let min: string = XlsxImporter.attrValue(tagSeg, 'min');
      let max: string = XlsxImporter.attrValue(tagSeg, 'max');
      let width: string = XlsxImporter.attrValue(tagSeg, 'width');
      let w: number = parseFloat(width);
      if (min !== '' && isFinite(w)) {
        let mi: number = parseInt(min, 10);
        let ma: number = max !== '' ? parseInt(max, 10) : mi;
        for (let c: number = mi; c <= ma; c++) {
          widthMap.set(c, Math.round(w));
          if (c > maxColSeen) {
            maxColSeen = c;
          }
        }
      }
    }
    // 冻结窗格
    let panes: string[] = [];
    XlsxImporter.splitTopLevel(sheetXml, '<pane ', '/>', panes);
    if (panes.length > 0) {
      let gt: number = panes[0].indexOf('>');
      let tagSeg: string = gt >= 0 ? panes[0].substring(0, gt) : panes[0];
      let x: string = XlsxImporter.attrValue(tagSeg, 'xSplit');
      let y: string = XlsxImporter.attrValue(tagSeg, 'ySplit');
      let xi: number = x !== '' ? parseInt(x, 10) : 0;
      let yi: number = y !== '' ? parseInt(y, 10) : 0;
      let freezeRef: string = XlsxImporter.colName(xi) + (yi + 1).toString();
      if (xi > 0 || yi > 0) {
        s.freeze = freezeRef;
      }
    }
    // 行
    let rowChunks: string[] = [];
    XlsxImporter.splitTopLevel(sheetXml, '<row ', '</row>', rowChunks);
    let maxRow: number = Constants.WORK_XLSX_IMPORT_MAX_ROWS;
    let maxCol: number = Constants.WORK_XLSX_IMPORT_MAX_COLS;
    for (let r: number = 0; r < rowChunks.length && r < maxRow; r++) {
      let cells: string[] = [];
      XlsxImporter.splitTopLevel(rowChunks[r], '<c ', '</c>', cells);
      let maxIdx: number = -1;
      let map: Map<number, Object> = new Map<number, Object>();
      for (let i: number = 0; i < cells.length; i++) {
        let cell: string = cells[i];
        let gt: number = cell.indexOf('>');
        let tagSeg: string = gt >= 0 ? cell.substring(0, gt) : cell;
        let ref: string = XlsxImporter.attrValue(tagSeg, 'r');
        let colIdx: number = XlsxImporter.colIndexOf(ref);
        if (colIdx < 0 || colIdx >= maxCol) {
          continue;
        }
        let value: Object | null = XlsxImporter.cellValue(cell, shared);
        if (value !== null) {
          map.set(colIdx, value);
          if (colIdx > maxIdx) {
            maxIdx = colIdx;
          }
        }
      }
      if (maxIdx < 0) {
        continue;
      }
      let rowOut: Object[] = [];
      for (let c: number = 0; c <= maxIdx; c++) {
        let v: Object | undefined = map.get(c);
        rowOut.push(v === undefined ? '' : v);
      }
      s.rows.push(rowOut);
    }
    // 列宽(只保留覆盖到数据列的)
    if (widthMap.size > 0) {
      let maxDataCol: number = s.rows.length > 0 ? s.rows[0].length : 0;
      for (let c: number = 1; c <= maxDataCol; c++) {
        let w: number | undefined = widthMap.get(c);
        s.colWidths.push(w === undefined ? 14 : w);
      }
    }
    return s;
  }

  private static cellValue(cell: string, shared: string[]): Object | null {
    let gt: number = cell.indexOf('>');
    let tagSeg: string = gt >= 0 ? cell.substring(0, gt) : cell;
    let t: string = XlsxImporter.attrValue(tagSeg, 't');
    // 公式
    let formula: string = XlsxImporter.firstTagText(cell, 'f');
    if (formula !== '') {
      return '=' + formula;
    }
    let v: string = XlsxImporter.firstTagText(cell, 'v');
    if (t === 's') {
      let idx: number = parseInt(v, 10);
      if (isFinite(idx) && idx >= 0 && idx < shared.length) {
        return shared[idx];
      }
      return '';
    }
    if (t === 'inlineStr') {
      let texts: string[] = [];
      XlsxImporter.collectTagTexts(cell, 't', texts);
      return texts.join('');
    }
    if (t === 'str') {
      return v;
    }
    // 无类型: 数字优先
    if (/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(v)) {
      let n: number = parseFloat(v);
      if (isFinite(n)) {
        return n;
      }
    }
    return v;
  }

  // ===== 通用 XML 工具(与 DocxImporter 同风格) =====

  // 按 begin/end 切同级片段(capture 从 begin 开始, 含首尾)
  private static splitTopLevel(xml: string, begin: string, end: string, out: string[]): void {
    let pos: number = 0;
    while (true) {
      let start: number = xml.indexOf(begin, pos);
      if (start < 0) {
        break;
      }
      let stop: string = end === '/>' ? '/>' : end;
      let searchFrom: number = end === '/>' ? start + begin.length : start + begin.length;
      let stopIdx: number = xml.indexOf(stop, searchFrom);
      if (stopIdx < 0) {
        break;
      }
      let seg: string = xml.substring(start, stopIdx + stop.length);
      out.push(seg);
      pos = stopIdx + stop.length;
    }
  }

  private static attrValue(tagSeg: string, name: string): string {
    let key: string = name + '="';
    let at: number = tagSeg.indexOf(key);
    if (at < 0) {
      return '';
    }
    let start: number = at + key.length;
    let end: number = tagSeg.indexOf('"', start);
    if (end < 0) {
      return '';
    }
    return tagSeg.substring(start, end);
  }

  // 取 <tag> 下第一个 <child> 的文本(公式 <f>, 数值 <v>)
  private static firstTagText(xml: string, tag: string): string {
    let open: string = '<' + tag + '>';
    let start: number = xml.indexOf(open);
    if (start < 0) {
      // 带属性的 <f ...>
      let startAttr: number = xml.indexOf('<' + tag + ' ');
      if (startAttr < 0) {
        return '';
      }
      let gt: number = xml.indexOf('>', startAttr);
      if (gt < 0) {
        return '';
      }
      start = gt + 1;
    } else {
      start = start + open.length;
    }
    let close: string = '</' + tag + '>';
    let end: number = xml.indexOf(close, start);
    if (end < 0) {
      return '';
    }
    return xml.substring(start, end);
  }

  private static collectTagTexts(xml: string, tag: string, out: string[]): void {
    let open: string = '<' + tag + '>';
    let pos: number = 0;
    while (true) {
      let start: number = xml.indexOf(open, pos);
      if (start < 0) {
        break;
      }
      let from: number = start + open.length;
      let close: string = '</' + tag + '>';
      let end: number = xml.indexOf(close, from);
      if (end < 0) {
        break;
      }
      out.push(xml.substring(from, end));
      pos = end + close.length;
    }
  }

  private static parseRels(path: string): Map<string, string> {
    let map: Map<string, string> = new Map<string, string>();
    let xml: string = XlsxImporter.readUtf8Safe(path);
    if (xml === '') {
      return map;
    }
    let rels: string[] = [];
    XlsxImporter.splitTopLevel(xml, '<Relationship ', '/>', rels);
    for (let i: number = 0; i < rels.length; i++) {
      let gt: number = rels[i].indexOf('>');
      let tagSeg: string = gt >= 0 ? rels[i].substring(0, gt) : rels[i];
      let rid: string = XlsxImporter.attrValue(tagSeg, 'Id');
      let target: string = XlsxImporter.attrValue(tagSeg, 'Target');
      if (rid !== '' && target !== '') {
        map.set(rid, target);
      }
    }
    return map;
  }

  // "B2" -> 列下标(0-based); 非法返回 -1
  private static colIndexOf(ref: string): number {
    let letters: string = '';
    let digits: string = '';
    for (let i: number = 0; i < ref.length; i++) {
      let ch: string = ref.charAt(i);
      if (ch >= 'A' && ch <= 'Z') {
        letters += ch;
      } else if (ch >= '0' && ch <= '9') {
        digits += ch;
      } else {
        return -1;
      }
    }
    if (letters === '' || digits === '' || letters.length > 3) {
      return -1;
    }
    let n: number = 0;
    for (let i: number = 0; i < letters.length; i++) {
      n = n * 26 + (letters.charCodeAt(i) - 64);
    }
    return n - 1;
  }

  private static colName(index: number): string {
    let s: string = '';
    let n: number = index + 1;
    while (n > 0) {
      let rem: number = (n - 1) % 26;
      s = String.fromCharCode(65 + rem) + s;
      n = Math.floor((n - 1) / 26);
    }
    return s;
  }

  private static readUtf8Safe(path: string): string {
    if (!fileIo.accessSync(path)) {
      return '';
    }
    return XlsxImporter.readUtf8(path);
  }

  private static readUtf8(path: string): string {
    let data: Uint8Array = XlsxImporter.readBytes(path);
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(data, { stream: false });
  }

  private static readBytes(path: string): Uint8Array {
    let stat: fileIo.Stat = fileIo.statSync(path);
    let file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer, { offset: 0 });
      return new Uint8Array(buffer);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static deleteDirSync(dir: string): void {
    if (!fileIo.accessSync(dir)) {
      return;
    }
    let names: string[] = fileIo.listFileSync(dir);
    for (let i: number = 0; i < names.length; i++) {
      let p: string = dir + '/' + names[i];
      let st: fileIo.Stat = fileIo.statSync(p);
      if (st.isDirectory()) {
        XlsxImporter.deleteDirSync(p);
      } else {
        fileIo.unlinkSync(p);
      }
    }
    fileIo.rmdirSync(dir);
  }
}
