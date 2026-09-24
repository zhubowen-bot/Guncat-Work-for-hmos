// XlsxExporter: 表格网格 -> .xlsx 文件 (对齐 web 版本 SheetJS generateExcel)
// 保留合并单元格(!merges)、行高(data-lines / data-h / 文字行数)、列宽
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { ZipWriter, ZipEntry } from './ZipWriter';
import { XmlUtil } from './XmlUtil';
import { TableCellInfo, TableRowInfo } from './TableHtmlParser';

const DEFAULT_H: number = 20;
const LINE_H: number = 16;

export class XlsxExporter {
  // 导出网格为 .xlsx, 返回保存的文件名; 用户取消时抛出错误
  static async exportXlsx(context: common.UIAbilityContext,
    grid: (TableCellInfo | null)[][], rowData: TableRowInfo[], maxCols: number): Promise<string> {
    let bytes: Uint8Array = XlsxExporter.buildXlsx(grid, rowData, maxCols);
    return XlsxExporter.saveBytesViaPicker(context, bytes, '表格识别-' + XmlUtil.stamp(), '.xlsx');
  }

  // 简单行数组 -> .xlsx 字节(工作模式 write_xlsx 工具复用); 首行作为表头加粗底色
  static buildXlsxFromRows(rows: string[][]): Uint8Array {
    let maxCols: number = 0;
    for (let r: number = 0; r < rows.length; r++) {
      if (rows[r].length > maxCols) {
        maxCols = rows[r].length;
      }
    }
    if (maxCols === 0) {
      maxCols = 1;
    }
    let grid: (TableCellInfo | null)[][] = [];
    let rowData: TableRowInfo[] = [];
    for (let r: number = 0; r < rows.length; r++) {
      let rowCells: (TableCellInfo | null)[] = [];
      for (let c: number = 0; c < maxCols; c++) {
        if (c < rows[r].length && rows[r][c] !== '') {
          let cell: TableCellInfo = new TableCellInfo();
          cell.text = rows[r][c];
          cell.rowspan = 1;
          cell.colspan = 1;
          cell.isHeader = r === 0;
          rowCells.push(cell);
        } else {
          rowCells.push(null);
        }
      }
      grid.push(rowCells);
      let meta: TableRowInfo = new TableRowInfo();
      meta.cells = [];
      meta.dataLines = 1;
      meta.dataH = '';
      rowData.push(meta);
    }
    // 空表也要有一行占位, 避免 sheetData 为空
    if (grid.length === 0) {
      let emptyRow: (TableCellInfo | null)[] = [];
      for (let c: number = 0; c < maxCols; c++) {
        emptyRow.push(null);
      }
      grid.push(emptyRow);
      let meta: TableRowInfo = new TableRowInfo();
      meta.cells = [];
      meta.dataLines = 1;
      meta.dataH = '';
      rowData.push(meta);
    }
    return XlsxExporter.buildXlsx(grid, rowData, maxCols);
  }

  // 通用保存: 字节 -> 系统保存面板写入 (docx/xlsx/html 共用)
  static async saveBytesViaPicker(context: common.UIAbilityContext, bytes: Uint8Array,
    baseName: string, suffix: string): Promise<string> {    let fileName: string = baseName + suffix;
    let options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [baseName];
    options.fileSuffixChoices = [suffix];
    let viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    let uris: string[] = await viewPicker.save(options);
    if (uris.length === 0) {
      throw new Error('已取消导出');
    }
    let uri: string = uris[0];
    let file: fs.File = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
      if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
        buffer = bytes.slice().buffer as ArrayBuffer;
      }
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    return fileName;
  }

  private static buildXlsx(grid: (TableCellInfo | null)[][],
    rowData: TableRowInfo[], maxCols: number): Uint8Array {
    let sheetXml: string = XlsxExporter.buildSheetXml(grid, rowData, maxCols);
    let entries: ZipEntry[] = [];
    entries.push(XlsxExporter.entry('[Content_Types].xml', XlsxExporter.contentTypesXml()));
    entries.push(XlsxExporter.entry('_rels/.rels', XlsxExporter.rootRelsXml()));
    entries.push(XlsxExporter.entry('xl/workbook.xml', XlsxExporter.workbookXml()));
    entries.push(XlsxExporter.entry('xl/_rels/workbook.xml.rels', XlsxExporter.workbookRelsXml()));
    entries.push(XlsxExporter.entry('xl/worksheets/sheet1.xml', sheetXml));
    entries.push(XlsxExporter.entry('xl/styles.xml', XlsxExporter.stylesXml()));
    entries.push(XlsxExporter.entry('docProps/core.xml', XlsxExporter.coreXml()));
    entries.push(XlsxExporter.entry('docProps/app.xml', XlsxExporter.appXml()));
    return ZipWriter.create(entries);
  }

  private static entry(name: string, xml: string): ZipEntry {
    let e: ZipEntry = new ZipEntry();
    e.name = name;
    e.data = XlsxExporter.stringToBytes(xml);
    return e;
  }

  private static stringToBytes(text: string): Uint8Array {
    let bytes: Uint8Array = new Uint8Array(text.length * 3);
    let count: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      let code: number = text.charCodeAt(i);
      if (code < 0x80) {
        bytes[count] = code;
        count++;
      } else if (code < 0x800) {
        bytes[count] = 0xC0 | (code >> 6);
        bytes[count + 1] = 0x80 | (code & 0x3F);
        count += 2;
      } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        let low: number = text.charCodeAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          let cp: number = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
          bytes[count] = 0xF0 | (cp >> 18);
          bytes[count + 1] = 0x80 | ((cp >> 12) & 0x3F);
          bytes[count + 2] = 0x80 | ((cp >> 6) & 0x3F);
          bytes[count + 3] = 0x80 | (cp & 0x3F);
          count += 4;
          i++;
        } else {
          bytes[count] = 0xEF;
          bytes[count + 1] = 0xBF;
          bytes[count + 2] = 0xBD;
          count += 3;
        }
      } else {
        bytes[count] = 0xE0 | (code >> 12);
        bytes[count + 1] = 0x80 | ((code >> 6) & 0x3F);
        bytes[count + 2] = 0x80 | (code & 0x3F);
        count += 3;
      }
    }
    let result: Uint8Array = new Uint8Array(count);
    result.set(bytes.subarray(0, count));
    return result;
  }

  // sheet1.xml: 数据行 + 合并 + 行高
  private static buildSheetXml(grid: (TableCellInfo | null)[][],
    rowData: TableRowInfo[], maxCols: number): string {
    let totalRows: number = grid.length;
    let sb: string = '';
    sb += '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
    sb += '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">';
    // 列宽
    sb += '<cols><col min="1" max="' + maxCols.toString() + '" width="18" customWidth="1"/></cols>';
    // 行数据
    sb += '<sheetData>';
    for (let r: number = 0; r < totalRows; r++) {
      let meta: TableRowInfo = rowData[r];
      let height: number = XlsxExporter.rowHeight(meta, grid[r], maxCols);
      let rowXml: string = '<row r="' + (r + 1).toString() + '" ht="' + height.toFixed(1) +
        '" customHeight="1">';
      for (let c: number = 0; c < maxCols; c++) {
        let cell: TableCellInfo | null = grid[r][c];
        if (cell === null) {
          continue;
        }
        let ref: string = XlsxExporter.colName(c) + (r + 1).toString();
        let text: string = cell.text;
        let safe: string = XmlUtil.escape(text).replace(/\n/g, '&#10;');
        let wraps: boolean = text.indexOf('\n') !== -1;
        rowXml += '<c r="' + ref + '" t="inlineStr" s="' + (wraps ? '1' : '0') +
          '"><is><t xml:space="preserve">' + safe + '</t></is></c>';
      }
      rowXml += '</row>';
      sb += rowXml;
    }
    sb += '</sheetData>';
    // 合并单元格
    let merges: string[] = [];
    for (let r: number = 0; r < totalRows; r++) {
      for (let c: number = 0; c < maxCols; c++) {
        let cell: TableCellInfo | null = grid[r][c];
        if (cell !== null && (cell.rowspan > 1 || cell.colspan > 1)) {
          let ref: string = XlsxExporter.colName(c) + (r + 1).toString() + ':' +
            XlsxExporter.colName(c + cell.colspan - 1) + (r + cell.rowspan).toString();
          merges.push(ref);
        }
      }
    }
    if (merges.length > 0) {
      sb += '<mergeCells count="' + merges.length.toString() + '">';
      for (let i: number = 0; i < merges.length; i++) {
        sb += '<mergeCell ref="' + merges[i] + '"/>';
      }
      sb += '</mergeCells>';
    }
    sb += '</worksheet>';
    return sb;
  }

  // 行高: data-lines -> data-h -> 文字行数 -> 默认 (对齐 web)
  private static rowHeight(meta: TableRowInfo, grid: (TableCellInfo | null)[],
    maxCols: number): number {
    let height: number = DEFAULT_H;
    if (meta.dataLines > 1) {
      height = meta.dataLines * LINE_H;
    }
    if (meta.dataH !== '') {
      let h: number = parseFloat(meta.dataH);
      if (!isNaN(h)) {
        height = DEFAULT_H * h;
      }
    }
    let maxTextLines: number = 1;
    for (let c: number = 0; c < maxCols; c++) {
      let cell: TableCellInfo | null = grid[c];
      if (cell !== null && cell.text !== '') {
        let lines: number = cell.text.split('\n').length;
        if (lines > maxTextLines) {
          maxTextLines = lines;
        }
      }
    }
    height = Math.max(height, maxTextLines * LINE_H, DEFAULT_H);
    return height;
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

  private static contentTypesXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' +
      '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>' +
      '</Types>';
  }

  private static rootRelsXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>' +
      '</Relationships>';
  }

  private static workbookXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
      '<fileVersion appName="xl" lastEdited="4"/>' +
      '<workbookPr defaultThemeVersion="124226"/>' +
      '<sheets><sheet name="表格" sheetId="1" r:id="rId1"/></sheets>' +
      '</workbook>';
  }

  private static workbookRelsXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
      '</Relationships>';
  }

  private static stylesXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
      '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>' +
      '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>' +
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
      '<cellXfs count="2">' +
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" applyAlignment="1"><alignment vertical="top"/></xf>' +
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>' +
      '</cellXfs>' +
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>' +
      '</styleSheet>';
  }

  private static coreXml(): string {
    let iso: string = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ' +
      'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
      '<dc:creator>Guncat Work</dc:creator><cp:lastModifiedBy>Guncat Work</cp:lastModifiedBy>' +
      '<dcterms:created xsi:type="dcterms:W3CDTF">' + iso + '</dcterms:created>' +
      '<dcterms:modified xsi:type="dcterms:W3CDTF">' + iso + '</dcterms:modified>' +
      '</cp:coreProperties>';
  }

  private static appXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" ' +
      'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
      '<Application>Guncat Work</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop>' +
      '<HeadingPairs/><TitlesOfParts/><LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc>' +
      '<HyperlinksChanged>false</HyperlinksChanged><AppVersion>1.0</AppVersion></Properties>';
  }
}