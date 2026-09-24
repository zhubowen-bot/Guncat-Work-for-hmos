// XlsxBuilder: Workbook JSON -> .xlsx 字节(与 DocxBuilder 同构, 无 Kit API, 可离线测试)
// 支持: 多工作表 / 表头加粗底纹(三套主题) / '='公式 / 数字格式(money/int/percent/year/date/number)
//       / 列宽 / 冻结窗格; 内嵌 docProps/workbook.json 源实现无损读回。
import { util } from '@kit.ArkTS';
import { ZipWriter, ZipEntry } from './ZipWriter.ts';
import { XmlUtil } from './XmlUtil.ts';
import { XlsxWorkbook, XlsxSheet, XlsxStylePalette, XlsxStyleColors, XlsxParser, XlsxJson } from './XlsxModel.ts';

// 数字格式 hint -> 自定义 numFmtId(>=164 需在 numFmts 声明; 0=General 内置)
const FMT_GENERAL: number = 0;
const FMT_INT: number = 164;      // #,##0
const FMT_MONEY: number = 165;    // ¥#,##0.00;(¥#,##0.00);"-"
const FMT_PERCENT: number = 166;  // 0.0%
const FMT_YEAR: number = 167;     // 0
const FMT_DATE: number = 168;     // m/d/yyyy
const FMT_NUMBER: number = 169;   // #,##0.00

const XML_HEAD: string = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';

export class XlsxBuilder {
  private wb: XlsxWorkbook = new XlsxWorkbook();
  private colors: XlsxStyleColors = new XlsxStyleColors();
  // 用到的自定义格式 id 集合(去重, 声明 numFmts 用)
  private usedFormats: number[] = [];

  static buildXlsxBytes(workbook: XlsxWorkbook): Uint8Array {
    let b: XlsxBuilder = new XlsxBuilder();
    b.wb = workbook;
    b.colors = XlsxStylePalette.of(workbook.style);
    return b.build();
  }

  // ===== 包结构 =====

  private build(): Uint8Array {
    let entries: ZipEntry[] = [];
    entries.push(XlsxBuilder.entry('[Content_Types].xml', this.contentTypesXml()));
    entries.push(XlsxBuilder.entry('_rels/.rels', this.rootRelsXml()));
    entries.push(XlsxBuilder.entry('xl/workbook.xml', this.workbookXml()));
    entries.push(XlsxBuilder.entry('xl/_rels/workbook.xml.rels', this.workbookRelsXml()));
    for (let i: number = 0; i < this.wb.sheets.length; i++) {
      entries.push(XlsxBuilder.entry('xl/worksheets/sheet' + (i + 1).toString() + '.xml',
        this.sheetXml(this.wb.sheets[i])));
    }
    entries.push(XlsxBuilder.entry('xl/styles.xml', this.stylesXml()));
    entries.push(XlsxBuilder.entryBytes('docProps/workbook.json', XlsxParser.toJson(this.wb)));
    entries.push(XlsxBuilder.entry('docProps/core.xml', this.coreXml()));
    entries.push(XlsxBuilder.entry('docProps/app.xml', this.appXml()));
    return ZipWriter.create(entries);
  }

  private static entry(name: string, xml: string): ZipEntry {
    let e: ZipEntry = new ZipEntry();
    e.name = name;
    e.data = XlsxBuilder.stringToBytes(xml);
    return e;
  }

  private static entryBytes(name: string, text: string): ZipEntry {
    let e: ZipEntry = new ZipEntry();
    e.name = name;
    e.data = XlsxBuilder.stringToBytes(text);
    return e;
  }

  private static stringToBytes(text: string): Uint8Array {
    let encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encode(text);
  }

  private contentTypesXml(): string {
    let ct: string = XML_HEAD +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Default Extension="json" ContentType="application/json"/>' +
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>';
    for (let i: number = 0; i < this.wb.sheets.length; i++) {
      ct += '<Override PartName="/xl/worksheets/sheet' + (i + 1).toString() +
        '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>';
    }
    ct += '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' +
      '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>' +
      '</Types>';
    return ct;
  }

  private rootRelsXml(): string {
    return XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>' +
      '</Relationships>';
  }

  private workbookXml(): string {
    let sheets: string = '';
    for (let i: number = 0; i < this.wb.sheets.length; i++) {
      sheets += '<sheet name="' + XmlUtil.escapeAttr(this.wb.sheets[i].name) +
        '" sheetId="' + (i + 1).toString() + '" r:id="rId' + (i + 1).toString() + '"/>';
    }
    return XML_HEAD +
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
      '<fileVersion appName="xl" lastEdited="4"/>' +
      '<workbookPr defaultThemeVersion="124226"/>' +
      '<sheets>' + sheets + '</sheets>' +
      '</workbook>';
  }

  private workbookRelsXml(): string {
    let rels: string = XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">';
    for (let i: number = 0; i < this.wb.sheets.length; i++) {
      rels += '<Relationship Id="rId' + (i + 1).toString() +
        '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' +
        (i + 1).toString() + '.xml"/>';
    }
    rels += '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>';
    rels += '</Relationships>';
    return rels;
  }

  // ===== 工作表 =====

  private sheetXml(s: XlsxSheet): string {
    let cols: number = s.headers.length > 0 ? s.headers.length : (s.rows.length > 0 ? s.rows[0].length : 1);
    let sb: string = XML_HEAD +
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">';
    // 冻结窗格
    if (s.freeze !== '') {
      sb += this.freezePaneXml(s.freeze);
    } else {
      sb += '<sheetViews><sheetView workbookViewId="0"/></sheetViews>';
    }
    // 列宽
    sb += '<cols>';
    for (let c: number = 0; c < cols; c++) {
      let w: number = c < s.colWidths.length ? s.colWidths[c] : 14;
      sb += '<col min="' + (c + 1).toString() + '" max="' + (c + 1).toString() +
        '" width="' + w.toFixed(1) + '" customWidth="1"/>';
    }
    sb += '</cols>';
    // 数据
    sb += '<sheetData>';
    let r: number = 1;
    if (s.headers.length > 0) {
      sb += this.rowXml(r, s.headers, true, s);
      r++;
    }
    for (let i: number = 0; i < s.rows.length; i++) {
      sb += this.rowXml(r, s.rows[i], false, s);
      r++;
    }
    sb += '</sheetData>';
    sb += '</worksheet>';
    return sb;
  }

  // "A2" -> 冻结窗格(xSplit=列前移, ySplit=行前移)
  private freezePaneXml(ref: string): string {
    let letters: string = '';
    let digits: string = '';
    for (let i: number = 0; i < ref.length; i++) {
      let ch: string = ref.charAt(i);
      if (ch >= 'A' && ch <= 'Z') {
        letters += ch;
      } else {
        digits += ch;
      }
    }
    let xSplit: number = XlsxBuilder.colIndexOf(letters);
    let ySplit: number = parseInt(digits, 10) - 1;
    if (ySplit < 0) {
      ySplit = 0;
    }
    let pane: string = '';
    let selection: string = '';
    if (xSplit > 0 && ySplit > 0) {
      pane = '<pane xSplit="' + xSplit.toString() + '" ySplit="' + ySplit.toString() +
        '" topLeftCell="' + ref + '" activePane="bottomRight" state="frozen"/>';
      selection = '<selection pane="bottomRight" activeCell="' + ref + '" sqref="' + ref + '"/>';
    } else if (ySplit > 0) {
      pane = '<pane ySplit="' + ySplit.toString() + '" topLeftCell="' + ref +
        '" activePane="bottomLeft" state="frozen"/>';
      selection = '<selection pane="bottomLeft" activeCell="' + ref + '" sqref="' + ref + '"/>';
    } else {
      pane = '<pane xSplit="' + xSplit.toString() + '" topLeftCell="' + ref +
        '" activePane="topRight" state="frozen"/>';
      selection = '<selection pane="topRight" activeCell="' + ref + '" sqref="' + ref + '"/>';
    }
    return '<sheetViews><sheetView workbookViewId="0">' + pane + selection + '</sheetView></sheetViews>';
  }

  private static colIndexOf(letters: string): number {
    let n: number = 0;
    for (let i: number = 0; i < letters.length; i++) {
      n = n * 26 + (letters.charCodeAt(i) - 64);
    }
    return n - 1;
  }

  private rowXml(r: number, cells: Object[], isHeader: boolean, s: XlsxSheet): string {
    let sb: string = '<row r="' + r.toString() + '">';
    let cols: number = s.headers.length > 0 ? s.headers.length : s.rows[0].length;
    for (let c: number = 0; c < cells.length && c < cols; c++) {
      let ref: string = XlsxOpsColName.colName(c) + r.toString();
      let style: number = isHeader ? 1 : this.cellStyle(c, s);
      let v: Object = cells[c];
      sb += this.cellXml(ref, style, v);
    }
    sb += '</row>';
    return sb;
  }

  private cellStyle(col: number, s: XlsxSheet): number {
    let f: string = col < s.formats.length ? s.formats[col] : '';
    if (f === 'text' || f === 'plain' || f === '') {
      return 0;
    }
    let id: number = XlsxBuilder.formatIdOf(f);
    if (id === FMT_GENERAL) {
      return 0;
    }
    let idx: number = this.usedFormats.indexOf(id);
    if (idx === -1) {
      this.usedFormats.push(id);
      idx = this.usedFormats.length - 1;
    }
    return 2 + idx;
  }

  private static formatIdOf(f: string): number {
    if (f === 'int') {
      return FMT_INT;
    }
    if (f === 'money') {
      return FMT_MONEY;
    }
    if (f === 'percent') {
      return FMT_PERCENT;
    }
    if (f === 'year') {
      return FMT_YEAR;
    }
    if (f === 'date') {
      return FMT_DATE;
    }
    if (f === 'number') {
      return FMT_NUMBER;
    }
    return FMT_GENERAL;
  }

  private cellXml(ref: string, style: number, v: Object): string {
    if (typeof v === 'number') {
      let num: number = v as number;
      return '<c r="' + ref + '" s="' + style.toString() + '"><v>' +
        XlsxBuilder.numberText(num) + '</v></c>';
    }
    let text: string = XlsxJson.asStr(v, '');
    if (text.startsWith('=')) {
      // 公式: <f> 内不带 '='
      return '<c r="' + ref + '" s="' + style.toString() + '"><f>' +
        XmlUtil.escape(text.substring(1)) + '</f><v></v></c>';
    }
    let safe: string = XmlUtil.escape(text).replace(/\n/g, '&#10;');
    return '<c r="' + ref + '" t="inlineStr" s="' + style.toString() +
      '"><is><t xml:space="preserve">' + safe + '</t></is></c>';
  }

  private static numberText(num: number): string {
    if (Number.isInteger(num)) {
      return num.toString();
    }
    return num.toString();
  }

  // ===== 样式 =====

  private stylesXml(): string {
    // 字体: 0=常规 Calibri 11, 1=表头粗体(主题色)
    let fonts: string = '<fonts count="2">' +
      '<font><sz val="11"/><name val="Calibri"/></font>' +
      '<font><b/><sz val="11"/><name val="Calibri"/><color rgb="00' + this.colors.headerText + '"/></font>' +
      '</fonts>';
    // 填充: 0=none, 1=gray125(规范保留), 2=表头底纹
    let fills: string = '<fills count="3">' +
      '<fill><patternFill patternType="none"/></fill>' +
      '<fill><patternFill patternType="gray125"/></fill>' +
      '<fill><patternFill patternType="solid"><fgColor rgb="00' + this.colors.headerFill +
      '"/><bgColor indexed="64"/></patternFill></fill>' +
      '</fills>';
    let borders: string = '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>';
    // 数字格式(仅声明用到的自定义 id)
    let numFmts: string = '';
    if (this.usedFormats.length > 0) {
      numFmts = '<numFmts count="' + this.usedFormats.length.toString() + '">';
      for (let i: number = 0; i < this.usedFormats.length; i++) {
        numFmts += '<numFmt numFmtId="' + this.usedFormats[i].toString() +
          '" formatCode="' + XmlUtil.escapeAttr(XlsxBuilder.formatCode(this.usedFormats[i])) + '"/>';
      }
      numFmts += '</numFmts>';
    }
    // cellXfs: 0=默认, 1=表头, 2+ = 各格式单元格
    let xfs: string = '<cellXfs count="' + (2 + this.usedFormats.length).toString() + '">' +
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center"/></xf>' +
      '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1">' +
      '<alignment vertical="center" horizontal="center" wrapText="1"/></xf>';
    for (let i: number = 0; i < this.usedFormats.length; i++) {
      xfs += '<xf numFmtId="' + this.usedFormats[i].toString() +
        '" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1">' +
        '<alignment vertical="center"/></xf>';
    }
    xfs += '</cellXfs>';
    return XML_HEAD +
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
      numFmts + fonts + fills + borders +
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
      xfs +
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>' +
      '</styleSheet>';
  }

  private static formatCode(id: number): string {
    if (id === FMT_INT) {
      return '#,##0';
    }
    if (id === FMT_MONEY) {
      return '\u00A5#,##0.00;(\u00A5#,##0.00);"-"';
    }
    if (id === FMT_PERCENT) {
      return '0.0%';
    }
    if (id === FMT_YEAR) {
      return '0';
    }
    if (id === FMT_DATE) {
      return 'm/d/yyyy';
    }
    if (id === FMT_NUMBER) {
      return '#,##0.00';
    }
    return 'General';
  }

  // ===== 文档属性 =====

  private coreXml(): string {
    let iso: string = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    return XML_HEAD +
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ' +
      'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
      '<dc:creator>Guncat Work</dc:creator><cp:lastModifiedBy>Guncat Work</cp:lastModifiedBy>' +
      '<dcterms:created xsi:type="dcterms:W3CDTF">' + iso + '</dcterms:created>' +
      '<dcterms:modified xsi:type="dcterms:W3CDTF">' + iso + '</dcterms:modified>' +
      '</cp:coreProperties>';
  }

  private appXml(): string {
    return XML_HEAD +
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" ' +
      'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
      '<Application>Guncat Work</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop>' +
      '<HeadingPairs/><TitlesOfParts/><LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc>' +
      '<HyperlinksChanged>false</HyperlinksChanged><AppVersion>1.0</AppVersion></Properties>';
  }
}

// 与 XlsxOps.colName 同实现的列名工具(避免 XlsxBuilder -> XlsxOps 依赖)
export class XlsxOpsColName {
  static colName(index: number): string {
    let s: string = '';
    let n: number = index + 1;
    while (n > 0) {
      let rem: number = (n - 1) % 26;
      s = String.fromCharCode(65 + rem) + s;
      n = Math.floor((n - 1) / 26);
    }
    return s;
  }
}
