// XlsxModel: Excel(Workbook) JSON 中间层 —— 与 Deck(Doc) 同构: 纯逻辑、无 Kit API、可离线测试。
// "生成 Excel" = 写 Workbook JSON -> XlsxBuilder 渲染; "编辑 Excel" = read_xlsx 还原 -> XlsxOps 应用算子 -> 重建。
// 参考 MiniMax minimax-xlsx skill 的思路: 公式优先(派生值用 '=...' 公式而非硬编码)、
// 数字格式矩阵(money/int/percent/year/date)、编辑完整性(只改目标单元格)。
import { Constants } from './Constants.ts';
import { CsvParser } from './CsvParser.ts';

// 工作表样式预设(表头配色, 与 Doc 三套同风格)
export const XLSX_STYLES: string[] = ['default', 'academic', 'minimal'];

// 数字格式提示(每列一个; 映射到 numFmt 见 XlsxBuilder)
export const XLSX_FORMATS: string[] = ['text', 'plain', 'int', 'money', 'percent', 'year', 'date', 'number'];

// 表头配色(标题/强调/表头底纹), 供 XlsxBuilder 使用
export class XlsxStyleColors {
  headerFill: string = '';   // 表头底纹(不带 #)
  headerText: string = '';   // 表头文字色
  accent: string = '';       // 强调色
}

export class XlsxStylePalette {
  static of(style: string): XlsxStyleColors {
    let c: XlsxStyleColors = new XlsxStyleColors();
    if (style === 'academic') {
      c.headerFill = 'F2F2F2';
      c.headerText = '262626';
      c.accent = '3F3F3F';
    } else if (style === 'minimal') {
      c.headerFill = 'F5F5F5';
      c.headerText = '6B6B6B';
      c.accent = '6B6B6B';
    } else {
      c.headerFill = 'DEEAF6';
      c.headerText = '1F4E79';
      c.accent = '2E74B5';
    }
    return c;
  }
}

// 单元格值: number | string; string 以 '=' 开头表示公式(如 "=SUM(B2:B9)")
export class XlsxCell {
  v: Object = '';
}

// 单个工作表
export class XlsxSheet {
  name: string = '';
  // 可选表头行(有则首行加粗+底纹)
  headers: string[] = [];
  // 数据行(矩形: 每行长度一致; 允许与 headers 长度一致)
  rows: Object[][] = [];
  // 可选列宽(1~255), 长度不超过列数
  colWidths: number[] = [];
  // 可选冻结窗格(如 "A2" 冻结首行)
  freeze: string = '';
  // 可选每列数字格式(XLSX_FORMATS 之一), 长度不超过列数
  formats: string[] = [];
}

// 工作簿
export class XlsxWorkbook {
  name: string = '';
  style: string = 'default';
  sheets: XlsxSheet[] = [];
}

// JSON 取值助手(与 DocJson 同风格)
export class XlsxJson {
  static asStr(v: Object, fallback: string): string {
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return fallback;
  }

  static asNum(v: Object, fallback: number): number {
    if (typeof v === 'number') {
      return v as number;
    }
    return fallback;
  }

  static asArr(v: Object): Object[] | null {
    if (v instanceof Array) {
      return v as Object[];
    }
    return null;
  }

  static asRec(v: Object): Record<string, Object> | null {
    if (typeof v === 'object' && v !== null && !(v instanceof Array)) {
      return v as Record<string, Object>;
    }
    return null;
  }
}

// ===== 解析与校验 =====
export class XlsxParser {
  // 解析 Workbook JSON 文本, 非法抛 Error(报错带 sheet/行/列号, 供 AI 自纠错)
  static parse(jsonText: string): XlsxWorkbook {
    let root: Object;
    try {
      root = JSON.parse(jsonText);
    } catch (e) {
      throw new Error('workbook 不是合法的 JSON, 如 {"name":"预算","sheets":[{"name":"收入","headers":["月份","金额"],"rows":[["1月",100]]}]}');
    }
    return XlsxParser.parseRec(XlsxJson.asRec(root), 'workbook');
  }

  static parseRec(rec: Record<string, Object> | null, ctx: string): XlsxWorkbook {
    if (rec === null) {
      throw new Error(ctx + ' 需要是 JSON 对象');
    }
    let wb: XlsxWorkbook = new XlsxWorkbook();
    wb.name = XlsxJson.asStr(rec['name'], 'Guncat 工作簿').trim();
    if (wb.name === '') {
      wb.name = 'Guncat 工作簿';
    }
    if (wb.name.length > 64) {
      throw new Error('工作簿 name 过长(≤64 字符)');
    }
    wb.style = XlsxJson.asStr(rec['style'], 'default').toLowerCase();
    if (!XlsxParser.isKnownStyle(wb.style)) {
      throw new Error('未知样式 "' + wb.style + '"(支持 ' + XLSX_STYLES.join('/') + ')');
    }
    let sheetsVal: Object = rec['sheets'];
    let sheetsArr: Object[] | null = XlsxJson.asArr(sheetsVal);
    if (sheetsArr === null || sheetsArr.length === 0) {
      throw new Error('sheets 需要是非空数组');
    }
    if (sheetsArr.length > Constants.WORK_XLSX_MAX_SHEETS) {
      throw new Error('工作表数量(' + sheetsArr.length.toString() +
        ')超过上限 ' + Constants.WORK_XLSX_MAX_SHEETS.toString());
    }
    let seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < sheetsArr.length; i++) {
      let s: XlsxSheet = XlsxParser.parseSheet(XlsxJson.asRec(sheetsArr[i]),
        '第 ' + (i + 1).toString() + ' 个 sheet');
      if (seen.has(s.name)) {
        throw new Error('工作表名重复: "' + s.name + '"');
      }
      seen.add(s.name);
      wb.sheets.push(s);
    }
    return wb;
  }

  static isKnownStyle(style: string): boolean {
    return XLSX_STYLES.indexOf(style) !== -1;
  }

  static isKnownFormat(f: string): boolean {
    return XLSX_FORMATS.indexOf(f) !== -1;
  }

  static parseSheet(rec: Record<string, Object> | null, ctx: string): XlsxSheet {
    if (rec === null) {
      throw new Error(ctx + ' 需要是 JSON 对象');
    }
    let s: XlsxSheet = new XlsxSheet();
    s.name = XlsxJson.asStr(rec['name'], '').trim();
    if (s.name === '') {
      throw new Error(ctx + ' 缺少 name(工作表名)');
    }
    if (s.name.length > 31) {
      throw new Error(ctx + ' 工作表名过长(≤31 字符): "' + s.name + '"');
    }
    // 表头(可选)
    let headersVal: Object = rec['headers'];
    if (headersVal !== undefined && headersVal !== null) {
      let headersArr: Object[] | null = XlsxJson.asArr(headersVal);
      if (headersArr === null) {
        throw new Error(ctx + ' 的 headers 需要是字符串数组');
      }
      for (let i: number = 0; i < headersArr.length; i++) {
        let h: string = XlsxJson.asStr(headersArr[i], '');
        if (h.length > 32767) {
          throw new Error(ctx + ' 表头单元格文本过长');
        }
        s.headers.push(h);
      }
    }
    // 数据行(必填)
    let rowsVal: Object = rec['rows'];
    let rowsArr: Object[] | null = XlsxJson.asArr(rowsVal);
    if (rowsArr === null) {
      throw new Error(ctx + ' 的 rows 需要是二维数组');
    }
    if (rowsArr.length === 0) {
      throw new Error(ctx + ' 的 rows 为空: 至少一行数据(表头不计入)');
    }
    if (rowsArr.length > Constants.WORK_XLSX_MAX_ROWS) {
      throw new Error(ctx + ' 行数(' + rowsArr.length.toString() +
        ')超过上限 ' + Constants.WORK_XLSX_MAX_ROWS.toString());
    }
    let cols: number = -1;
    for (let r: number = 0; r < rowsArr.length; r++) {
      let rowArr: Object[] | null = XlsxJson.asArr(rowsArr[r]);
      if (rowArr === null) {
        throw new Error(ctx + ' 第 ' + (r + 1).toString() + ' 行不是数组');
      }
      if (rowArr.length === 0) {
        throw new Error(ctx + ' 第 ' + (r + 1).toString() + ' 行为空(每行至少 1 个单元格)');
      }
      if (rowArr.length > Constants.WORK_XLSX_MAX_COLS) {
        throw new Error(ctx + ' 第 ' + (r + 1).toString() + ' 行列数(' + rowArr.length.toString() +
          ')超过上限 ' + Constants.WORK_XLSX_MAX_COLS.toString());
      }
      if (cols === -1) {
        cols = rowArr.length;
      } else if (rowArr.length !== cols) {
        throw new Error(ctx + ' 第 ' + (r + 1).toString() + ' 行列数(' + rowArr.length.toString() +
          ')与第 1 行(' + cols.toString() + ')不一致: 数据必须矩形');
      }
      let rowOut: Object[] = [];
      for (let c: number = 0; c < rowArr.length; c++) {
        rowOut.push(XlsxParser.checkCell(rowArr[c], ctx, r + 1, c + 1));
      }
      s.rows.push(rowOut);
    }
    if (s.headers.length > 0 && s.headers.length !== cols) {
      throw new Error(ctx + ' 表头列数(' + s.headers.length.toString() +
        ')与数据列数(' + cols.toString() + ')不一致');
    }
    // 列宽(可选)
    let cwVal: Object = rec['colWidths'];
    if (cwVal !== undefined && cwVal !== null) {
      let cwArr: Object[] | null = XlsxJson.asArr(cwVal);
      if (cwArr === null) {
        throw new Error(ctx + ' 的 colWidths 需要是数字数组');
      }
      if (cwArr.length > cols) {
        throw new Error(ctx + ' 的 colWidths 长度超过列数');
      }
      for (let i: number = 0; i < cwArr.length; i++) {
        let w: number = XlsxJson.asNum(cwArr[i], 0);
        if (!(w >= 1 && w <= 255)) {
          throw new Error(ctx + ' 的 colWidths[' + i.toString() + '] 需在 1~255 之间');
        }
        s.colWidths.push(w);
      }
    }
    // 冻结窗格(可选, 如 "A2")
    let freeze: string = XlsxJson.asStr(rec['freeze'], '').trim().toUpperCase();
    if (freeze !== '') {
      if (!/^[A-Z]{1,3}[1-9][0-9]*$/.test(freeze)) {
        throw new Error(ctx + ' 的 freeze 格式应为单元格地址如 "A2"(冻结首行)或 "B1"(冻结首列)');
      }
      s.freeze = freeze;
    }
    // 每列格式(可选)
    let fmVal: Object = rec['formats'];
    if (fmVal !== undefined && fmVal !== null) {
      let fmArr: Object[] | null = XlsxJson.asArr(fmVal);
      if (fmArr === null) {
        throw new Error(ctx + ' 的 formats 需要是字符串数组');
      }
      if (fmArr.length > cols) {
        throw new Error(ctx + ' 的 formats 长度超过列数');
      }
      for (let i: number = 0; i < fmArr.length; i++) {
        let f: string = XlsxJson.asStr(fmArr[i], 'text').toLowerCase();
        if (!XlsxParser.isKnownFormat(f)) {
          throw new Error(ctx + ' 的 formats[' + i.toString() + '] 未知: "' + f +
            '"(支持 ' + XLSX_FORMATS.join('/') + ')');
        }
        s.formats.push(f);
      }
    }
    return s;
  }

  // 单元格值: number | string(以 '=' 开头为公式); 其余类型报错
  private static checkCell(v: Object, ctx: string, r: number, c: number): Object {
    if (typeof v === 'number') {
      if (!isFinite(v as number)) {
        throw new Error(ctx + ' 第 ' + r.toString() + ' 行第 ' + c.toString() + ' 列不是有限数字');
      }
      return v;
    }
    if (typeof v === 'string') {
      let t: string = v as string;
      if (t.length > 32767) {
        throw new Error(ctx + ' 第 ' + r.toString() + ' 行第 ' + c.toString() + ' 列文本过长(≤32767)');
      }
      return t;
    }
    throw new Error(ctx + ' 第 ' + r.toString() + ' 行第 ' + c.toString() +
      ' 列类型不支持: 单元格值只能是数字或字符串(公式用 "=SUM(...)" 形式)');
  }

  // sheet -> 可序列化 Record
  static sheetToRec(s: XlsxSheet): Record<string, Object> {
    let rec: Record<string, Object> = {};
    rec['name'] = s.name;
    if (s.headers.length > 0) {
      rec['headers'] = s.headers;
    }
    rec['rows'] = s.rows;
    if (s.colWidths.length > 0) {
      rec['colWidths'] = s.colWidths;
    }
    if (s.freeze !== '') {
      rec['freeze'] = s.freeze;
    }
    if (s.formats.length > 0) {
      rec['formats'] = s.formats;
    }
    return rec;
  }

  static toRec(wb: XlsxWorkbook): Record<string, Object> {
    let rec: Record<string, Object> = {};
    rec['name'] = wb.name;
    rec['style'] = wb.style;
    let sheets: Object[] = [];
    for (let i: number = 0; i < wb.sheets.length; i++) {
      sheets.push(XlsxParser.sheetToRec(wb.sheets[i]));
    }
    rec['sheets'] = sheets;
    return rec;
  }

  static toJson(wb: XlsxWorkbook): string {
    return JSON.stringify(XlsxParser.toRec(wb));
  }
}

// ===== Markdown 表格 / CSV / TSV -> 工作簿 =====
export class MdToXlsx {
  // 首行作为表头; 纯数字字符串转数字(公式保留原样)
  static convert(tableText: string, name: string): XlsxWorkbook {
    let rows: string[][] = CsvParser.parseSmartTable(tableText);
    if (rows.length === 0) {
      throw new Error('表格数据为空, 请提供 Markdown 表格、CSV 或 TSV 文本');
    }
    let wb: XlsxWorkbook = new XlsxWorkbook();
    wb.name = name !== '' ? name : 'Guncat 工作簿';
    let s: XlsxSheet = new XlsxSheet();
    s.name = 'Sheet1';
    if (rows.length > 0) {
      let headers: string[] = rows[0];
      for (let i: number = 0; i < headers.length; i++) {
        s.headers.push(headers[i].trim());
      }
      for (let r: number = 1; r < rows.length; r++) {
        let rowOut: Object[] = [];
        for (let c: number = 0; c < rows[r].length; c++) {
          rowOut.push(MdToXlsx.toValue(rows[r][c].trim()));
        }
        s.rows.push(rowOut);
      }
    }
    wb.sheets.push(s);
    return wb;
  }

  private static toValue(text: string): Object {
    if (/^-?\d+(\.\d+)?$/.test(text)) {
      let n: number = parseFloat(text);
      if (isFinite(n)) {
        return n;
      }
    }
    return text;
  }
}

// ===== 编辑算子 =====
export class XlsxOps {
  // 对工作簿应用操作数组, 返回可读执行摘要; 非法操作抛 Error(整批不生效)
  static apply(wb: XlsxWorkbook, opsJson: string): string {
    let root: Object;
    try {
      root = JSON.parse(opsJson);
    } catch (e) {
      throw new Error('ops 不是合法的 JSON 数组, 如 [{"op":"set_cell","sheet":"收入","row":2,"col":2,"value":999}]');
    }
    if (!(root instanceof Array)) {
      throw new Error('ops 需要是 JSON 数组');
    }
    let arr: Object[] = root as Object[];
    if (arr.length === 0) {
      throw new Error('ops 为空');
    }
    if (arr.length > 50) {
      throw new Error('ops 单次最多 50 个操作');
    }
    let summary: string[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      let rec: Record<string, Object> | null = XlsxJson.asRec(arr[i]);
      if (rec === null) {
        throw new Error('第 ' + (i + 1).toString() + ' 个 op 必须是 JSON 对象');
      }
      let op: string = XlsxJson.asStr(rec['op'], '');
      if (op === 'set_name') {
        let n: string = XlsxJson.asStr(rec['name'], '').trim();
        if (n === '') {
          throw new Error('set_name 缺少 name');
        }
        wb.name = n;
        summary.push('工作簿名 → ' + n);
      } else if (op === 'set_style') {
        let st: string = XlsxJson.asStr(rec['style'], '').toLowerCase();
        if (!XlsxParser.isKnownStyle(st)) {
          throw new Error('set_style 未知样式 "' + st + '"(支持 ' + XLSX_STYLES.join('/') + ')');
        }
        wb.style = st;
        summary.push('样式 → ' + st);
      } else if (op === 'set_sheet_name') {
        let s: XlsxSheet = XlsxOps.findSheet(wb, rec);
        let n: string = XlsxJson.asStr(rec['name'], '').trim();
        if (n === '') {
          throw new Error('set_sheet_name 缺少 name');
        }
        s.name = n;
        summary.push('工作表 ' + s.name + ' 已重命名');
      } else if (op === 'add_sheet') {
        let sheetRec: Record<string, Object> | null = XlsxJson.asRec(rec['sheet']);
        if (sheetRec === null) {
          throw new Error('add_sheet 缺少 sheet 对象');
        }
        if (wb.sheets.length + 1 > Constants.WORK_XLSX_MAX_SHEETS) {
          throw new Error('add_sheet 超过工作表数量上限 ' + Constants.WORK_XLSX_MAX_SHEETS.toString());
        }
        let s: XlsxSheet = XlsxParser.parseSheet(sheetRec, 'add_sheet 的 sheet');
        XlsxOps.ensureUniqueName(wb, s.name);
        let idx: number = XlsxOps.indexArg(rec['index'], -1);
        if (idx < 1 || idx > wb.sheets.length) {
          wb.sheets.push(s);
          summary.push('追加工作表 "' + s.name + '"');
        } else {
          wb.sheets.splice(idx - 1, 0, s);
          summary.push('在第 ' + idx.toString() + ' 位插入工作表 "' + s.name + '"');
        }
      } else if (op === 'delete_sheet') {
        let s: XlsxSheet = XlsxOps.findSheet(wb, rec);
        if (wb.sheets.length <= 1) {
          throw new Error('delete_sheet 不能删除最后一个工作表');
        }
        let idx: number = wb.sheets.indexOf(s);
        wb.sheets.splice(idx, 1);
        summary.push('删除工作表 "' + s.name + '"');
      } else if (op === 'move_sheet') {
        let s: XlsxSheet = XlsxOps.findSheet(wb, rec);
        let to: number = XlsxOps.indexArg(rec['to'], -1);
        if (to < 1 || to > wb.sheets.length) {
          throw new Error('move_sheet 的 to 越界(1~' + wb.sheets.length.toString() + ')');
        }
        let from: number = wb.sheets.indexOf(s);
        wb.sheets.splice(from, 1);
        wb.sheets.splice(to - 1, 0, s);
        summary.push('移动工作表 "' + s.name + '" 到第 ' + to.toString() + ' 位');
      } else if (op === 'add_row') {
        let s: XlsxSheet = XlsxOps.findSheet(wb, rec);
        let rowArr: Object[] | null = XlsxJson.asArr(rec['row']);
        if (rowArr === null || rowArr.length === 0) {
          throw new Error('add_row 缺少 row(数组)');
        }
        XlsxOps.checkRowLen(s, rowArr, 'add_row');
        let rowOut: Object[] = XlsxOps.checkRowValues(s, rowArr, 'add_row');
        let idx: number = XlsxOps.indexArg(rec['index'], -1);
        if (idx < 1 || idx > s.rows.length) {
          s.rows.push(rowOut);
          summary.push('向 "' + s.name + '" 追加第 ' + s.rows.length.toString() + ' 行');
        } else {
          s.rows.splice(idx - 1, 0, rowOut);
          summary.push('向 "' + s.name + '" 第 ' + idx.toString() + ' 位插入一行');
        }
        XlsxOps.checkRowCap(s, 'add_row');
      } else if (op === 'delete_row') {
        let s: XlsxSheet = XlsxOps.findSheet(wb, rec);
        let idx: number = XlsxOps.indexArg(rec['index'], -1);
        if (idx < 1 || idx > s.rows.length) {
          throw new Error('delete_row 的 index(' + idx.toString() + ')越界(数据行从 1 起, 不含表头), "' + s.name +
            '" 当前共 ' + s.rows.length.toString() + ' 行数据');
        }
        s.rows.splice(idx - 1, 1);
        summary.push('删除 "' + s.name + '" 第 ' + idx.toString() + ' 行数据');
      } else if (op === 'update_row') {
        let s: XlsxSheet = XlsxOps.findSheet(wb, rec);
        let idx: number = XlsxOps.indexArg(rec['index'], -1);
        if (idx < 1 || idx > s.rows.length) {
          throw new Error('update_row 的 index(' + idx.toString() + ')越界(数据行从 1 起, 不含表头), "' + s.name +
            '" 当前共 ' + s.rows.length.toString() + ' 行数据');
        }
        let rowArr: Object[] | null = XlsxJson.asArr(rec['row']);
        if (rowArr === null || rowArr.length === 0) {
          throw new Error('update_row 缺少 row(数组)');
        }
        XlsxOps.checkRowLen(s, rowArr, 'update_row');
        s.rows[idx - 1] = XlsxOps.checkRowValues(s, rowArr, 'update_row');
        summary.push('更新 "' + s.name + '" 第 ' + idx.toString() + ' 行');
      } else if (op === 'set_cell') {
        let s: XlsxSheet = XlsxOps.findSheet(wb, rec);
        let row: number = XlsxOps.indexArg(rec['row'], -1);
        let col: number = XlsxOps.indexArg(rec['col'], -1);
        if (row < 1 || row > s.rows.length) {
          throw new Error('set_cell 的 row(' + row.toString() + ')越界(数据行从 1 起, 不含表头), "' + s.name +
            '" 当前共 ' + s.rows.length.toString() + ' 行数据');
        }
        if (col < 1 || col > s.rows[row - 1].length) {
          throw new Error('set_cell 的 col(' + col.toString() + ')越界, "' + s.name +
            '" 第 ' + row.toString() + ' 行共 ' + s.rows[row - 1].length.toString() + ' 列');
        }
        let v: Object = XlsxOps.checkCellValue(rec['value'], s.name, row, col);
        s.rows[row - 1][col - 1] = v;
        summary.push('设置 "' + s.name + '" ' + XlsxOps.colName(col - 1) + (row + 1).toString() + '(数据行 ' +
          row.toString() + ') = ' + XlsxJson.asStr(v, ''));
      } else if (op === 'set_header') {
        let s: XlsxSheet = XlsxOps.findSheet(wb, rec);
        if (s.headers.length === 0) {
          throw new Error('set_header 失败: "' + s.name + '" 没有表头(建表时用 headers 字段, 或用 add_sheet 带 headers)');
        }
        let col: number = XlsxOps.indexArg(rec['col'], -1);
        if (col < 1 || col > s.headers.length) {
          throw new Error('set_header 的 col(' + col.toString() + ')越界, "' + s.name +
            '" 表头共 ' + s.headers.length.toString() + ' 列');
        }
        let v: Object = rec['value'];
        if (typeof v === 'number') {
          s.headers[col - 1] = (v as number).toString();
          summary.push('设置 "' + s.name + '" 表头第 ' + col.toString() + ' 列 → ' + s.headers[col - 1]);
        } else if (typeof v === 'string') {
          let text: string = v as string;
          if (text.length > 32767) {
            throw new Error('set_header 的 value 过长');
          }
          s.headers[col - 1] = text;
          summary.push('设置 "' + s.name + '" 表头第 ' + col.toString() + ' 列 → ' + text);
        } else {
          throw new Error('set_header 的 value 需要是字符串(表头只能放文本)');
        }
      } else if (op === 'replace_text') {
        let find: string = XlsxJson.asStr(rec['find'], '');
        let replace: string = XlsxJson.asStr(rec['replace'], '');
        if (find === '') {
          throw new Error('replace_text 缺少 find');
        }
        let count: number = XlsxOps.replaceText(wb, find, replace);
        summary.push('全文替换 "' + find + '" → "' + replace + '"(' + count.toString() + ' 处)');
      } else {
        throw new Error('未知操作: "' + op +
          '"(支持 set_name/set_style/set_sheet_name/add_sheet/delete_sheet/move_sheet/' +
          'add_row/delete_row/update_row/set_cell/set_header/replace_text)');
      }
    }
    return summary.join('\n');
  }

  private static findSheet(wb: XlsxWorkbook, rec: Record<string, Object>): XlsxSheet {
    let name: string = XlsxJson.asStr(rec['sheet'], '').trim();
    for (let i: number = 0; i < wb.sheets.length; i++) {
      if (wb.sheets[i].name === name) {
        return wb.sheets[i];
      }
    }
    throw new Error('找不到工作表 "' + name + '"(现有: ' + XlsxOps.sheetNames(wb).join('、') + ')');
  }

  private static ensureUniqueName(wb: XlsxWorkbook, name: string): void {
    for (let i: number = 0; i < wb.sheets.length; i++) {
      if (wb.sheets[i].name === name) {
        throw new Error('工作表名重复: "' + name + '"');
      }
    }
  }

  private static sheetNames(wb: XlsxWorkbook): string[] {
    let names: string[] = [];
    for (let i: number = 0; i < wb.sheets.length; i++) {
      names.push(wb.sheets[i].name);
    }
    return names;
  }

  private static checkRowLen(s: XlsxSheet, row: Object[], op: string): void {
    let cols: number = s.headers.length > 0 ? s.headers.length : s.rows[0].length;
    if (row.length !== cols) {
      throw new Error(op + ' 的 row 列数(' + row.length.toString() + ')与 "' + s.name +
        '" 现有列数(' + cols.toString() + ')不一致');
    }
    if (row.length > Constants.WORK_XLSX_MAX_COLS) {
      throw new Error(op + ' 超过列数上限 ' + Constants.WORK_XLSX_MAX_COLS.toString());
    }
  }

  private static checkRowValues(s: XlsxSheet, row: Object[], op: string): Object[] {
    let out: Object[] = [];
    for (let c: number = 0; c < row.length; c++) {
      out.push(XlsxOps.checkCellValue(row[c], s.name, s.rows.length + 1, c + 1));
    }
    return out;
  }

  private static checkCellValue(v: Object, sheetName: string, row: number, col: number): Object {
    if (typeof v === 'number') {
      if (!isFinite(v as number)) {
        throw new Error('"' + sheetName + '" ' + XlsxOps.colName(col - 1) + row.toString() + ' 不是有限数字');
      }
      return v;
    }
    if (typeof v === 'string') {
      let t: string = v as string;
      if (t.length > 32767) {
        throw new Error('"' + sheetName + '" ' + XlsxOps.colName(col - 1) + row.toString() + ' 文本过长');
      }
      return t;
    }
    throw new Error('"' + sheetName + '" ' + XlsxOps.colName(col - 1) + row.toString() +
      ' 单元格值只能是数字或字符串(公式用 "=SUM(...)" 形式)');
  }

  private static checkRowCap(s: XlsxSheet, op: string): void {
    if (s.rows.length > Constants.WORK_XLSX_MAX_ROWS) {
      throw new Error(op + ' 超过行数上限 ' + Constants.WORK_XLSX_MAX_ROWS.toString() +
        '("' + s.name + '" 当前 ' + s.rows.length.toString() + ' 行)');
    }
  }

  // 全文文本替换(跳过公式与数字): 覆盖 headers/rows
  private static replaceText(wb: XlsxWorkbook, find: string, replace: string): number {
    let count: number = 0;
    for (let si: number = 0; si < wb.sheets.length; si++) {
      let s: XlsxSheet = wb.sheets[si];
      for (let h: number = 0; h < s.headers.length; h++) {
        let t: string = s.headers[h];
        if (t.indexOf(find) !== -1) {
          s.headers[h] = t.split(find).join(replace);
          count++;
        }
      }
      for (let r: number = 0; r < s.rows.length; r++) {
        for (let c: number = 0; c < s.rows[r].length; c++) {
          let v: Object = s.rows[r][c];
          if (typeof v === 'string') {
            let t: string = v as string;
            if (t.startsWith('=')) {
              continue; // 公式不替换(易破坏引用)
            }
            if (t.indexOf(find) !== -1) {
              s.rows[r][c] = t.split(find).join(replace);
              count++;
            }
          }
        }
      }
    }
    return count;
  }

  private static indexArg(v: Object, fallback: number): number {
    let n: number = XlsxJson.asNum(v, fallback);
    if (!Number.isInteger(n)) {
      return fallback;
    }
    return n;
  }

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
