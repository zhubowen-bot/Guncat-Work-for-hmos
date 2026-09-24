// DataPipeline: 工作模式 transform_file 的受限数据管道解释器 (纯逻辑模块, 无 HarmonyOS API 依赖)
// 安全模型: 表达式求值没有任何 I/O, 只能引用行数据与白名单函数; ops 走白名单分发;
// 管道步数与输入规模由工具壳限定且 ops 不会增加行数 => 结构上必然终止, 无需看门狗。
// 输入: csv/tsv/md/json/jsonl/lines -> 统一的 表头+字符串行 模型; 输出由工具壳按扩展名编码落盘。
import { CsvParser } from './CsvParser';

// 表格模型: header 为空数组表示无表头(hasHeader=false), 此时列引用只能用数字列号 col(1)
export class DpTable {
  header: string[] = [];
  hasHeader: boolean = false;
  rows: string[][] = [];
}

// 管道执行结果: table 为最终数据, applied 为每个 op 的一行效果摘要(送回模型)
export class DpOutcome {
  table: DpTable = new DpTable();
  applied: string[] = [];
}

// 表达式 AST 节点(单类多用途): kind 标记节点类型
class DpNode {
  static readonly NUM: number = 0;
  static readonly STR: number = 1;
  static readonly BOOL: number = 2;
  static readonly NULL: number = 3;
  static readonly BIN: number = 6;
  static readonly UN: number = 7;
  static readonly CALL: number = 8;
  kind: number = 0;
  num: number = 0;
  str: string = '';
  op: string = '';
  kids: DpNode[] = [];
}

// 词元: 0 数字 / 1 字符串 / 2 标识符 / 3 运算符或括号 / 4 结束
class DpTok {
  kind: number = 0;
  text: string = '';
  num: number = 0;
  pos: number = 0;
}

// 求值上下文: 当前行(下标与 header 对齐)与 1 起的行号
class DpCtx {
  header: string[] = [];
  row: string[] = [];
  rowNum: number = 0;
}

export class DataPipeline {
  // 列数硬上限(防止 split_col/derive 无限扩列)
  static readonly MAX_COLS: number = 512;
  // 表达式解析递归深度上限(括号/嵌套调用)
  static readonly MAX_DEPTH: number = 64;
  // 可用函数清单(错误提示用, 与 evalCall 的白名单保持一致)
  private static readonly FN_LIST: string = 'trim, upper, lower, len, substr, replace, regex_replace, ' +
    'matches, extract, split, join, num, round, abs, floor, ceil, min, max, if, coalesce, ' +
    'is_empty, starts_with, ends_with, contains, str, rownum, col';

  // ===== 入口 =====

  static run(text: string, format: string, delimiter: string, jsonPath: string, hasHeader: boolean,
    stepsJson: string, maxRows: number, maxSteps: number): DpOutcome {
    let table: DpTable = DataPipeline.parseInput(text, format, delimiter, jsonPath, hasHeader, maxRows);
    let applied: string[] = DataPipeline.applySteps(table, stepsJson, maxSteps);
    let out: DpOutcome = new DpOutcome();
    out.table = table;
    out.applied = applied;
    return out;
  }

  // ===== 输入解析 =====

  // format 留空时按内容嗅探: JSON / Markdown 表格 / TSV / CSV
  static sniffFormat(text: string): string {
    let first: string = '';
    let lines: string[] = text.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      if (lines[i].trim() !== '') {
        first = lines[i].trim();
        break;
      }
    }
    if (first === '') {
      return 'csv';
    }
    if (first.startsWith('{') || first.startsWith('[')) {
      return 'json';
    }
    if (first.indexOf('|') !== -1) {
      return 'md';
    }
    if (first.indexOf('\t') !== -1) {
      return 'tsv';
    }
    return 'csv';
  }

  static parseInput(text: string, format: string, delimiter: string, jsonPath: string,
    hasHeader: boolean, maxRows: number): DpTable {
    let t: string = text;
    if (t.length > 0 && t.charCodeAt(0) === 0xFEFF) {
      t = t.substring(1);
    }
    let f: string = format.trim().toLowerCase();
    if (f === '') {
      f = DataPipeline.sniffFormat(t);
    }
    let table: DpTable = new DpTable();
    if (f === 'csv' || f === 'tsv') {
      let delim: string = delimiter;
      if (delim === '') {
        delim = f === 'tsv' ? '\t' : CsvParser.detectDelimiter(t);
      }
      if (delim.length !== 1) {
        throw new Error('delimiter 需为单个分隔字符(如 "," 或 "\\t"), 得到: "' + delim + '"');
      }
      let rows: string[][] = CsvParser.parse(t, delim);
      if (hasHeader && rows.length > 0) {
        table.header = rows.shift() as string[];
        table.hasHeader = true;
      }
      table.rows = rows;
    } else if (f === 'md') {
      let rows: string[][] = CsvParser.parseMarkdownTable(t);
      if (rows.length > 0) {
        table.header = rows.shift() as string[];
        table.hasHeader = true;
      }
      table.rows = rows;
    } else if (f === 'json') {
      DataPipeline.parseJsonRecords(t, jsonPath, table);
    } else if (f === 'jsonl') {
      DataPipeline.parseJsonl(t, table);
    } else if (f === 'lines') {
      let rows: string[][] = [];
      let lines: string[] = t.split('\n');
      for (let i: number = 0; i < lines.length; i++) {
        let line: string = lines[i];
        if (line.length > 0 && line.charAt(line.length - 1) === '\r') {
          line = line.substring(0, line.length - 1);
        }
        if (line.trim() === '') {
          continue;
        }
        let row: string[] = [line];
        rows.push(row);
      }
      table.header = ['line'];
      table.hasHeader = true;
      table.rows = rows;
    } else {
      throw new Error('未知输入格式: "' + format + '"(支持 csv / tsv / md / json / jsonl / lines, 留空自动识别)');
    }
    DataPipeline.normalize(table);
    if (table.rows.length > maxRows) {
      throw new Error('输入数据 ' + table.rows.length.toString() + ' 行, 超过单次转换上限 ' +
        maxRows.toString() + ' 行。请先用 read_file/parse_document 分段定位需要的数据范围, ' +
        '或把大文件拆分后分批转换');
    }
    return table;
  }

  // 列数与行宽归一: 补齐短行、报错超宽, 保证求值时行宽一致
  private static normalize(table: DpTable): void {
    let width: number = table.header.length;
    for (let i: number = 0; i < table.rows.length; i++) {
      if (table.rows[i].length > width) {
        width = table.rows[i].length;
      }
    }
    if (width > DataPipeline.MAX_COLS) {
      throw new Error('数据有 ' + width.toString() + ' 列, 超过上限 ' + DataPipeline.MAX_COLS.toString() + ' 列');
    }
    while (table.header.length < width) {
      table.header.push('');
    }
    for (let i: number = 0; i < table.rows.length; i++) {
      while (table.rows[i].length < width) {
        table.rows[i].push('');
      }
    }
    // 空表头单元格补默认列名, 避免 col('') 之类歧义
    for (let i: number = 0; i < table.header.length; i++) {
      if (table.header[i].trim() === '') {
        table.header[i] = '列' + (i + 1).toString();
      }
    }
  }

  // JSON / JSON 数组定位: json_path 形如 "data.items", 段为对象键; 数组下标用 0 起数字段
  private static parseJsonRecords(text: string, jsonPath: string, table: DpTable): void {
    let data: Object | null = null;
    try {
      data = JSON.parse(text) as Object;
    } catch (e) {
      let msg: string = e instanceof Error ? (e as Error).message : String(e);
      throw new Error('JSON 解析失败: ' + msg + '。检查逗号/引号/括号是否配对, 或确认该文件确为 JSON');
    }
    let path: string = jsonPath.trim();
    if (path !== '') {
      let segs: string[] = path.split('.');
      for (let i: number = 0; i < segs.length; i++) {
        let seg: string = segs[i].trim();
        if (seg === '') {
          continue;
        }
        if (data instanceof Array) {
          let idx: number = parseInt(seg, 10);
          if (isNaN(idx) || idx < 0 || idx >= data.length) {
            throw new Error('json_path 在段 "' + seg + '" 失败: 当前是数组(长度 ' + data.length.toString() +
              '), 数字段按 0 起下标取元素');
          }
          data = data[idx] as Object;
        } else if (typeof data === 'object' && data !== null) {
          let rec: Record<string, Object> = data as Record<string, Object>;
          let next: Object = rec[seg];
          if (typeof next === 'undefined') {
            throw new Error('json_path 在段 "' + seg + '" 失败: 对象没有该键。当前键: ' +
              DataPipeline.keyList(rec));
          }
          data = next;
        } else {
          throw new Error('json_path 在段 "' + seg + '" 失败: 当前位置不是对象或数组');
        }
      }
    }
    let records: Object[] = [];
    if (data instanceof Array) {
      records = data;
    } else if (typeof data === 'object' && data !== null) {
      records.push(data);
    } else {
      throw new Error('JSON 顶层(或 json_path 定位结果)需为数组或对象, 得到: ' + DataPipeline.typeName(data));
    }
    // 表头 = 前 50 条记录的键并集(保持出现顺序)
    let header: string[] = [];
    let probe: number = records.length < 50 ? records.length : 50;
    for (let i: number = 0; i < probe; i++) {
      let item: Object | null = records[i];
      if (typeof item === 'object' && item !== null && !(item instanceof Array)) {
        let keys: string[] = Object.keys(item as Record<string, Object>);
        for (let k: number = 0; k < keys.length; k++) {
          if (header.indexOf(keys[k]) === -1) {
            header.push(keys[k]);
            if (header.length > DataPipeline.MAX_COLS) {
              throw new Error('JSON 记录的键超过 ' + DataPipeline.MAX_COLS.toString() + ' 个, 无法转为表格');
            }
          }
        }
      }
    }
    if (header.length === 0) {
      header.push('value');
    }
    table.header = header;
    table.hasHeader = true;
    for (let i: number = 0; i < records.length; i++) {
      let item: Object | null = records[i];
      let row: string[] = [];
      if (typeof item === 'object' && item !== null && !(item instanceof Array)) {
        let rec: Record<string, Object> = item as Record<string, Object>;
        for (let k: number = 0; k < header.length; k++) {
          let v: Object = rec[header[k]];
          row.push(DataPipeline.jsonCell(v));
        }
      } else {
        row.push(DataPipeline.jsonCell(item));
      }
      table.rows.push(row);
    }
  }

  private static parseJsonl(text: string, table: DpTable): void {
    let lines: string[] = text.split('\n');
    let records: Object[] = [];
    for (let i: number = 0; i < lines.length; i++) {
      let line: string = lines[i].trim();
      if (line === '') {
        continue;
      }
      try {
        records.push(JSON.parse(line) as Object);
      } catch (e) {
        let msg: string = e instanceof Error ? (e as Error).message : String(e);
        throw new Error('JSONL 第 ' + (i + 1).toString() + ' 行解析失败: ' + msg);
      }
    }
    let arrText: string = JSON.stringify(records);
    DataPipeline.parseJsonRecords(arrText, '', table);
  }

  // JSON 值 -> 单元格文本: 标量直转, 容器 JSON 压缩序列化
  private static jsonCell(v: Object | undefined): string {
    if (typeof v === 'undefined' || v === null) {
      return '';
    }
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number' || typeof v === 'boolean') {
      return String(v);
    }
    return JSON.stringify(v);
  }

  private static keyList(rec: Record<string, Object>): string {
    let keys: string[] = Object.keys(rec);
    let out: string = '';
    for (let i: number = 0; i < keys.length && i < 15; i++) {
      out += (i > 0 ? ', ' : '') + keys[i];
    }
    if (keys.length > 15) {
      out += ', ...';
    }
    return out === '' ? '(无键)' : out;
  }

  // ===== 管道 ops =====

  static applySteps(table: DpTable, stepsJson: string, maxSteps: number): string[] {
    let trimmed: string = stepsJson.trim();
    if (trimmed === '') {
      throw new Error('缺少 steps(转换步骤 JSON 数组), 语法见 load_skill("data")');
    }
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(trimmed) as Object;
    } catch (e) {
      let msg: string = e instanceof Error ? (e as Error).message : String(e);
      throw new Error('steps 不是合法 JSON: ' + msg);
    }
    if (!(parsed instanceof Array)) {
      throw new Error('steps 需为 JSON 数组, 如 [{"op":"filter","expr":"col(\'年龄\') >= 18"}]');
    }
    let steps: Object[] = parsed;
    if (steps.length === 0) {
      throw new Error('steps 为空数组, 至少需要一个操作');
    }
    if (steps.length > maxSteps) {
      throw new Error('steps 有 ' + steps.length.toString() + ' 步, 超过上限 ' + maxSteps.toString() +
        ' 步。复杂管道请拆成多次 transform_file, 每次落盘一个中间文件');
    }
    let applied: string[] = [];
    for (let i: number = 0; i < steps.length; i++) {
      let step: Object | null = steps[i];
      if (typeof step !== 'object' || step === null || step instanceof Array) {
        throw new Error('steps[' + i.toString() + '] 需为对象 {"op":"..."}');
      }
      let rec: Record<string, Object> = step as Record<string, Object>;
      let op: string = DataPipeline.sStr(rec, 'op', '');
      if (op === '') {
        throw new Error('steps[' + i.toString() + '] 缺少 op 字段');
      }
      let label: string = DataPipeline.applyOp(table, i, op, rec);
      applied.push((i + 1).toString() + '. ' + label);
    }
    return applied;
  }

  private static applyOp(table: DpTable, stepIdx: number, op: string, rec: Record<string, Object>): string {
    let where: string = 'steps[' + stepIdx.toString() + '](' + op + '): ';
    if (op === 'filter') {
      let node: DpNode = DataPipeline.exprArg(rec, 'expr', where);
      let kept: string[][] = [];
      for (let i: number = 0; i < table.rows.length; i++) {
        let ctx: DpCtx = DataPipeline.ctxFor(table, i);
        if (DataPipeline.truthy(DataPipeline.evalNode(node, ctx))) {
          kept.push(table.rows[i]);
        }
      }
      let removed: number = table.rows.length - kept.length;
      table.rows = kept;
      return 'filter 条件过滤: 保留 ' + kept.length.toString() + ' 行(剔除 ' + removed.toString() + ' 行)';
    }
    if (op === 'derive') {
      let name: string = DataPipeline.sStr(rec, 'name', '');
      if (name.trim() === '') {
        throw new Error(where + '缺少新列名 name');
      }
      let node: DpNode = DataPipeline.exprArg(rec, 'expr', where);
      for (let i: number = 0; i < table.rows.length; i++) {
        let ctx: DpCtx = DataPipeline.ctxFor(table, i);
        table.rows[i].push(DataPipeline.valueToCell(DataPipeline.evalNode(node, ctx)));
      }
      if (table.hasHeader) {
        table.header.push(name.trim());
      } else {
        // 无表头时补占位, 维持 header 长度与行宽一致(后续 set_header 需要按列数校验)
        table.header.push('');
      }
      return 'derive 添加列 "' + name.trim() + '"';
    }
    if (op === 'map') {
      let idx: number = DataPipeline.colSpec(table, DataPipeline.sGet(rec, 'col'), where + '缺少 col');
      let node: DpNode = DataPipeline.exprArg(rec, 'expr', where);
      for (let i: number = 0; i < table.rows.length; i++) {
        let ctx: DpCtx = DataPipeline.ctxFor(table, i);
        table.rows[i][idx] = DataPipeline.valueToCell(DataPipeline.evalNode(node, ctx));
      }
      return 'map 重算列 ' + DataPipeline.colLabel(table, idx);
    }
    if (op === 'select') {
      let specs: Object[] = DataPipeline.specsArg(rec, 'cols', where);
      let optional: boolean = DataPipeline.sBool(rec, 'optional', false);
      let idxs: number[] = [];
      for (let i: number = 0; i < specs.length; i++) {
        let idx: number | null = DataPipeline.colSpecOpt(table, specs[i], optional);
        if (idx !== null) {
          idxs.push(idx);
        }
      }
      if (idxs.length === 0) {
        throw new Error(where + 'select 的 cols 没有命中任何列');
      }
      let origCols: number = table.header.length;
      let rows: string[][] = [];
      for (let i: number = 0; i < table.rows.length; i++) {
        let row: string[] = [];
        for (let k: number = 0; k < idxs.length; k++) {
          row.push(table.rows[i][idxs[k]]);
        }
        rows.push(row);
      }
      let header: string[] = [];
      for (let k: number = 0; k < idxs.length; k++) {
        header.push(table.header[idxs[k]]);
      }
      table.rows = rows;
      table.header = header;
      return 'select 保留 ' + idxs.length.toString() + ' 列(原 ' + origCols.toString() + ' 列)';
    }
    if (op === 'drop') {
      let specs: Object[] = DataPipeline.specsArg(rec, 'cols', where);
      let dropped: number[] = [];
      for (let i: number = 0; i < specs.length; i++) {
        let idx: number | null = DataPipeline.colSpecOpt(table, specs[i], true);
        if (idx !== null && dropped.indexOf(idx) === -1) {
          dropped.push(idx);
        }
      }
      if (dropped.length === 0) {
        throw new Error(where + 'drop 的 cols 没有命中任何列');
      }
      let keep: number[] = [];
      for (let c: number = 0; c < table.header.length; c++) {
        if (dropped.indexOf(c) === -1) {
          keep.push(c);
        }
      }
      let rows: string[][] = [];
      for (let i: number = 0; i < table.rows.length; i++) {
        let row: string[] = [];
        for (let k: number = 0; k < keep.length; k++) {
          row.push(table.rows[i][keep[k]]);
        }
        rows.push(row);
      }
      let header: string[] = [];
      for (let k: number = 0; k < keep.length; k++) {
        header.push(table.header[keep[k]]);
      }
      table.rows = rows;
      table.header = header;
      return 'drop 删除 ' + dropped.length.toString() + ' 列, 剩余 ' + keep.length.toString() + ' 列';
    }
    if (op === 'rename') {
      if (!table.hasHeader) {
        throw new Error(where + '当前无表头, rename 需要列名; 先用 set_header/promote_header 定义列名');
      }
      let fromSpec: Object | null = DataPipeline.sGet(rec, 'from');
      if (fromSpec === null) {
        throw new Error(where + '缺少 from(原列名)');
      }
      let idx: number = DataPipeline.colSpec(table, fromSpec, where);
      let to: string = DataPipeline.sStr(rec, 'to', '');
      if (to.trim() === '') {
        throw new Error(where + '缺少 to(新列名)');
      }
      table.header[idx] = to.trim();
      return 'rename 列 ' + DataPipeline.colLabel(table, idx) + ' 已更名';
    }
    if (op === 'set_header') {
      let names: Object[] | null = DataPipeline.arrArg(rec, 'names', where);
      if (names.length !== table.header.length) {
        throw new Error(where + 'names 需要 ' + table.header.length.toString() + ' 个列名(当前列数), 得到 ' +
          names.length.toString() + ' 个');
      }
      let header: string[] = [];
      for (let i: number = 0; i < names.length; i++) {
        header.push(DataPipeline.valueToCell(names[i]));
      }
      table.header = header;
      table.hasHeader = true;
      return 'set_header 定义 ' + header.length.toString() + ' 个列名';
    }
    if (op === 'promote_header') {
      if (table.hasHeader) {
        throw new Error(where + '当前已有表头。若首行数据被误当成表头, 请重新调用 transform_file 并传 ' +
          '"has_header": false');
      }
      if (table.rows.length === 0) {
        throw new Error(where + '没有数据行可作为表头');
      }
      table.header = table.rows.shift() as string[];
      table.hasHeader = true;
      DataPipeline.normalize(table);
      return 'promote_header 首行提升为表头, 剩余 ' + table.rows.length.toString() + ' 行数据';
    }
    if (op === 'sort') {
      let node: DpNode = DataPipeline.exprArg(rec, 'expr', where);
      let desc: boolean = DataPipeline.sBool(rec, 'desc', false);
      // 预计算排序键(每行一次表达式求值), 避免比较器里反复求值
      let keys: (Object | null)[] = [];
      for (let i: number = 0; i < table.rows.length; i++) {
        let ctx: DpCtx = DataPipeline.ctxFor(table, i);
        keys.push(DataPipeline.evalNode(node, ctx));
      }
      let idxs: number[] = [];
      for (let i: number = 0; i < table.rows.length; i++) {
        idxs.push(i);
      }
      idxs.sort((a: number, b: number): number => {
        let ka: Object | null = keys[a];
        let kb: Object | null = keys[b];
        if (ka === null && kb === null) {
          return 0;
        }
        if (ka === null) {
          return 1;
        }
        if (kb === null) {
          return -1;
        }
        let cmp: number = DataPipeline.compareValues(ka, kb);
        return desc ? -cmp : cmp;
      });
      let rows: string[][] = [];
      for (let i: number = 0; i < idxs.length; i++) {
        rows.push(table.rows[idxs[i]]);
      }
      table.rows = rows;
      return 'sort 按 ' + DataPipeline.exprText(rec) + (desc ? ' 降序' : ' 升序') + '排序 ' +
        rows.length.toString() + ' 行(空值排最后)';
    }
    if (op === 'limit' || op === 'skip') {
      let n: number = DataPipeline.sInt(rec, 'n', -1);
      if (n < 0) {
        throw new Error(where + '缺少非负整数 n');
      }
      if (op === 'limit') {
        table.rows = table.rows.slice(0, n);
        return 'limit 取前 ' + table.rows.length.toString() + ' 行';
      }
      table.rows = n >= table.rows.length ? [] : table.rows.slice(n);
      return 'skip 跳过前 ' + n.toString() + ' 行, 剩余 ' + table.rows.length.toString() + ' 行';
    }
    if (op === 'dedupe') {
      let specs: Object[] | null = null;
      let raw: Object | null = DataPipeline.sGet(rec, 'keys');
      if (raw !== null) {
        if (!(raw instanceof Array)) {
          throw new Error(where + 'keys 需为列名/列号数组');
        }
        specs = raw as Object[];
      }
      let idxs: number[] = [];
      if (specs !== null) {
        for (let i: number = 0; i < specs.length; i++) {
          idxs.push(DataPipeline.colSpec(table, specs[i], where));
        }
      } else {
        for (let c: number = 0; c < table.header.length; c++) {
          idxs.push(c);
        }
      }
      let seen: Record<string, boolean> = {};
      let kept: string[][] = [];
      for (let i: number = 0; i < table.rows.length; i++) {
        let key: string = '';
        for (let k: number = 0; k < idxs.length; k++) {
          key += '\u0001' + table.rows[i][idxs[k]];
        }
        if (seen[key] === true) {
          continue;
        }
        seen[key] = true;
        kept.push(table.rows[i]);
      }
      let removed: number = table.rows.length - kept.length;
      table.rows = kept;
      return 'dedupe 按整行去重' + (specs !== null ? '(指定列)' : '') + ': 保留 ' + kept.length.toString() +
        ' 行(去除 ' + removed.toString() + ' 行重复)';
    }
    if (op === 'drop_empty') {
      let kept: string[][] = [];
      for (let i: number = 0; i < table.rows.length; i++) {
        let allEmpty: boolean = true;
        for (let c: number = 0; c < table.rows[i].length; c++) {
          if (table.rows[i][c].trim() !== '') {
            allEmpty = false;
            break;
          }
        }
        if (!allEmpty) {
          kept.push(table.rows[i]);
        }
      }
      let removed: number = table.rows.length - kept.length;
      table.rows = kept;
      return 'drop_empty 剔除全空行 ' + removed.toString() + ' 行, 剩余 ' + kept.length.toString() + ' 行';
    }
    if (op === 'fill') {
      let value: string = DataPipeline.sStr(rec, 'value', '');
      let raw: Object | null = DataPipeline.sGet(rec, 'col');
      let idxs: number[] = [];
      if (raw !== null) {
        idxs.push(DataPipeline.colSpec(table, raw, where));
      } else {
        for (let c: number = 0; c < table.header.length; c++) {
          idxs.push(c);
        }
      }
      let filled: number = 0;
      for (let i: number = 0; i < table.rows.length; i++) {
        for (let k: number = 0; k < idxs.length; k++) {
          if (table.rows[i][idxs[k]].trim() === '') {
            table.rows[i][idxs[k]] = value;
            filled++;
          }
        }
      }
      return 'fill 填充空单元格 ' + filled.toString() + ' 个(值: ' + value + ')';
    }
    if (op === 'trim') {
      let idxs: number[] = DataPipeline.colsOrDefault(table, rec, where);
      for (let i: number = 0; i < table.rows.length; i++) {
        for (let k: number = 0; k < idxs.length; k++) {
          table.rows[i][idxs[k]] = table.rows[i][idxs[k]].trim();
        }
      }
      return 'trim 去除首尾空白(' + (DataPipeline.sGet(rec, 'cols') !== null ? '指定列' : '全部列') + ')';
    }
    if (op === 'replace') {
      let find: string = DataPipeline.sStr(rec, 'find', '');
      if (find === '') {
        throw new Error(where + '缺少 find(要替换的内容)');
      }
      let repl: string = DataPipeline.sStr(rec, 'replace', '');
      let useRegex: boolean = DataPipeline.sBool(rec, 'regex', false);
      let idxs: number[] = DataPipeline.colsOrDefault(table, rec, where);
      let re: RegExp | null = null;
      if (useRegex) {
        try {
          re = new RegExp(find, 'g');
        } catch (e) {
          let msg: string = e instanceof Error ? (e as Error).message : String(e);
          throw new Error(where + '正则表达式无效: ' + find + '(' + msg + ')');
        }
      }
      let hits: number = 0;
      for (let i: number = 0; i < table.rows.length; i++) {
        for (let k: number = 0; k < idxs.length; k++) {
          let cell: string = table.rows[i][idxs[k]];
          let next: string = cell;
          if (re !== null) {
            re.lastIndex = 0;
            next = cell.replace(re, repl);
          } else if (cell.indexOf(find) !== -1) {
            next = cell.split(find).join(repl);
          }
          if (next !== cell) {
            hits++;
          }
          table.rows[i][idxs[k]] = next;
        }
      }
      return 'replace 替换命中 ' + hits.toString() + ' 个单元格' + (useRegex ? '(正则)' : '');
    }
    if (op === 'extract') {
      let idx: number = DataPipeline.colSpec(table, DataPipeline.sGet(rec, 'col'), where + '缺少 col');
      let pattern: string = DataPipeline.sStr(rec, 'pattern', '');
      if (pattern === '') {
        throw new Error(where + '缺少 pattern(正则表达式)');
      }
      let group: number = DataPipeline.sInt(rec, 'group', 0);
      if (group < 0) {
        group = 0;
      }
      let re: RegExp;
      try {
        re = new RegExp(pattern, 'g');
      } catch (e) {
        let msg: string = e instanceof Error ? (e as Error).message : String(e);
        throw new Error(where + '正则表达式无效: ' + pattern + '(' + msg + ')');
      }
      let srcLabel: string = DataPipeline.colLabel(table, idx);
      let name: string = DataPipeline.sStr(rec, 'name', srcLabel + '_提取');
      let matched: number = 0;
      for (let i: number = 0; i < table.rows.length; i++) {
        re.lastIndex = 0;
        let m: RegExpExecArray | null = re.exec(table.rows[i][idx]);
        let cell: string = '';
        if (m !== null) {
          matched++;
          if (group < m.length) {
            let g: string | undefined = m[group];
            cell = typeof g === 'undefined' || g === null ? '' : g;
          }
        }
        table.rows[i].push(cell);
      }
      if (table.hasHeader) {
        table.header.push(name.trim());
      } else {
        table.header.push('');
      }
      return 'extract 正则提取 "' + pattern + '"(第 ' + group.toString() + ' 组) -> 新列 "' +
        name.trim() + '", 命中 ' + matched.toString() + '/' + table.rows.length.toString() + ' 行';
    }
    if (op === 'split_col') {
      let idx: number = DataPipeline.colSpec(table, DataPipeline.sGet(rec, 'col'), where + '缺少 col');
      let sep: string = DataPipeline.sStr(rec, 'sep', '');
      if (sep === '') {
        throw new Error(where + '缺少 sep(拆分分隔符, 字面量文本)');
      }
      let names: Object[] | null = DataPipeline.arrArg(rec, 'names', where);
      if (names.length === 0) {
        throw new Error(where + '缺少 names(拆分后的新列名数组)');
      }
      let srcLabel: string = DataPipeline.colLabel(table, idx);
      for (let i: number = 0; i < table.rows.length; i++) {
        let parts: string[] = table.rows[i][idx].split(sep);
        if (parts.length > names.length) {
          throw new Error(where + '第 ' + (i + 1).toString() + ' 行在列 "' + srcLabel + '" 拆出 ' +
            parts.length.toString() + ' 段, 超过 names 的 ' + names.length.toString() +
            ' 个。先清理数据(如 replace 合并多余分隔符)或增加 names');
        }
        for (let k: number = 0; k < names.length; k++) {
          table.rows[i].push(k < parts.length ? parts[k] : '');
        }
      }
      if (table.hasHeader) {
        for (let k: number = 0; k < names.length; k++) {
          table.header.push(DataPipeline.valueToCell(names[k]));
        }
      } else {
        for (let k: number = 0; k < names.length; k++) {
          table.header.push('');
        }
      }
      return 'split_col 列 "' + srcLabel + '" 按 "' + sep + '" 拆为 ' + names.length.toString() + ' 列';
    }
    if (op === 'to_num') {
      let idxs: number[] = DataPipeline.colsOrDefault(table, rec, where);
      let converted: number = 0;
      for (let i: number = 0; i < table.rows.length; i++) {
        for (let k: number = 0; k < idxs.length; k++) {
          let n: number = DataPipeline.toNum(table.rows[i][idxs[k]]);
          if (!isNaN(n)) {
            converted++;
          }
          table.rows[i][idxs[k]] = isNaN(n) ? '' : String(n);
        }
      }
      return 'to_num 数值化 ' + converted.toString() + ' 个单元格(无法解析的置空)';
    }
    throw new Error(where + '未知操作 "' + op + '"。可用操作: filter, derive, map, select, drop, rename, ' +
      'set_header, promote_header, sort, limit, skip, dedupe, drop_empty, fill, trim, replace, extract, ' +
      'split_col, to_num');
  }

  // ===== op 参数与列引用辅助 =====

  private static sGet(rec: Record<string, Object>, key: string): Object | null {
    let v: Object = rec[key];
    if (typeof v === 'undefined' || v === null) {
      return null;
    }
    return v;
  }

  private static sStr(rec: Record<string, Object>, key: string, defVal: string): string {
    let v: Object = rec[key];
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return defVal;
  }

  private static sInt(rec: Record<string, Object>, key: string, defVal: number): number {
    let v: Object = rec[key];
    if (typeof v === 'number' && !isNaN(v as number)) {
      return Math.floor(v as number);
    }
    if (typeof v === 'string') {
      let n: number = parseInt(v as string, 10);
      if (!isNaN(n)) {
        return n;
      }
    }
    return defVal;
  }

  private static sBool(rec: Record<string, Object>, key: string, defVal: boolean): boolean {
    let v: Object = rec[key];
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'string') {
      return (v as string).toLowerCase() === 'true';
    }
    return defVal;
  }

  private static arrArg(rec: Record<string, Object>, key: string, where: string): Object[] {
    let v: Object | null = DataPipeline.sGet(rec, key);
    if (v === null || !(v instanceof Array)) {
      throw new Error(where + '缺少数组参数 ' + key + ', 如 ["a", "b"]');
    }
    return v as Object[];
  }

  private static specsArg(rec: Record<string, Object>, key: string, where: string): Object[] {
    let v: Object[] = DataPipeline.arrArg(rec, key, where);
    if (v.length === 0) {
      throw new Error(where + key + ' 为空数组');
    }
    return v;
  }

  private static exprArg(rec: Record<string, Object>, key: string, where: string): DpNode {
    let expr: string = DataPipeline.sStr(rec, key, '');
    if (expr.trim() === '') {
      throw new Error(where + '缺少表达式 ' + key + ', 如 "trim(col(\'姓名\')) != \'\'"');
    }
    return DataPipeline.parseExpr(expr);
  }

  private static exprText(rec: Record<string, Object>): string {
    return DataPipeline.sStr(rec, 'expr', '(表达式)');
  }

  // 列引用: 字符串列名(需表头)或 1 起数字列号; 解析失败抛带可用列清单的错误
  private static colSpec(table: DpTable, spec: Object | null, where: string): number {
    let idx: number | null = DataPipeline.colSpecOpt(table, spec, false);
    if (idx === null) {
      throw new Error(where + '列引用无效');
    }
    return idx;
  }

  private static colSpecOpt(table: DpTable, spec: Object | null, optional: boolean): number | null {
    if (spec === null) {
      if (optional) {
        return null;
      }
      throw new Error('缺少列引用');
    }
    if (typeof spec === 'number') {
      let idx: number = Math.floor(spec as number) - 1;
      if (idx < 0 || idx >= table.header.length) {
        throw new Error('列号 ' + (idx + 1).toString() + ' 超出范围(共 ' +
          table.header.length.toString() + ' 列)');
      }
      return idx;
    }
    if (typeof spec === 'string') {
      let name: string = (spec as string).trim();
      if (table.hasHeader) {
        let idx: number = table.header.indexOf(name);
        if (idx !== -1) {
          return idx;
        }
        if (optional) {
          return null;
        }
        throw new Error('列不存在: "' + name + '"(可用列: ' + DataPipeline.headerList(table) + ')');
      }
      let num: number = parseInt(name, 10);
      if (!isNaN(num)) {
        return DataPipeline.colSpecOpt(table, num, optional);
      }
      if (optional) {
        return null;
      }
      throw new Error('当前无表头: 需用数字列号(如 1)引用列, 或先用 set_header/promote_header 定义列名');
    }
    throw new Error('列引用需为列名字符串或 1 起数字列号, 得到: ' + DataPipeline.typeName(spec));
  }

  // replace/trim/fill/to_num 的 cols: 缺省为全部列
  private static colsOrDefault(table: DpTable, rec: Record<string, Object>, where: string): number[] {
    let raw: Object | null = DataPipeline.sGet(rec, 'cols');
    let idxs: number[] = [];
    if (raw === null) {
      for (let c: number = 0; c < table.header.length; c++) {
        idxs.push(c);
      }
      return idxs;
    }
    if (!(raw instanceof Array)) {
      throw new Error(where + 'cols 需为列名/列号数组');
    }
    let specs: Object[] = raw as Object[];
    for (let i: number = 0; i < specs.length; i++) {
      idxs.push(DataPipeline.colSpec(table, specs[i], where));
    }
    if (idxs.length === 0) {
      throw new Error(where + 'cols 为空数组');
    }
    return idxs;
  }

  private static headerList(table: DpTable): string {
    let out: string = '';
    for (let i: number = 0; i < table.header.length && i < 15; i++) {
      out += (i > 0 ? ', ' : '') + table.header[i];
    }
    if (table.header.length > 15) {
      out += ', ...(共 ' + table.header.length.toString() + ' 列)';
    }
    return out === '' ? '(无列)' : out;
  }

  private static colLabel(table: DpTable, idx: number): string {
    if (table.hasHeader) {
      return '"' + table.header[idx] + '"';
    }
    return '第 ' + (idx + 1).toString() + ' 列';
  }

  private static ctxFor(table: DpTable, rowIdx: number): DpCtx {
    let ctx: DpCtx = new DpCtx();
    ctx.header = table.header;
    ctx.row = table.rows[rowIdx];
    ctx.rowNum = rowIdx + 1;
    return ctx;
  }

  // ===== 表达式: 词法 =====

  static parseExpr(expr: string): DpNode {
    let toks: DpTok[] = DataPipeline.tokenize(expr);
    let pos: number[] = [0];
    let node: DpNode = DataPipeline.parseOr(toks, pos, expr, 0);
    let cur: DpTok = toks[pos[0]];
    if (cur.kind !== 4) {
      throw new Error('表达式错误: "' + cur.text + '" 出现在意外位置(' + DataPipeline.snip(expr, cur.pos) + ')');
    }
    return node;
  }

  private static tokenize(expr: string): DpTok[] {
    let toks: DpTok[] = [];
    let i: number = 0;
    let n: number = expr.length;
    while (i < n) {
      let ch: string = expr.charAt(i);
      if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n') {
        i++;
        continue;
      }
      let code: number = expr.charCodeAt(i);
      if (code >= 48 && code <= 57) {
        let start: number = i;
        while (i < n && expr.charCodeAt(i) >= 48 && expr.charCodeAt(i) <= 57) {
          i++;
        }
        if (i + 1 < n && expr.charAt(i) === '.' && expr.charCodeAt(i + 1) >= 48 &&
          expr.charCodeAt(i + 1) <= 57) {
          i++;
          while (i < n && expr.charCodeAt(i) >= 48 && expr.charCodeAt(i) <= 57) {
            i++;
          }
        }
        let tok: DpTok = new DpTok();
        tok.kind = 0;
        tok.text = expr.substring(start, i);
        tok.num = parseFloat(tok.text);
        tok.pos = start;
        toks.push(tok);
        continue;
      }
      if (ch === '\'' || ch === '"') {
        let start: number = i;
        let quote: string = ch;
        i++;
        let text: string = '';
        let closed: boolean = false;
        while (i < n) {
          let c: string = expr.charAt(i);
          if (c === '\\' && i + 1 < n) {
            let esc: string = expr.charAt(i + 1);
            if (esc === 'n') {
              text += '\n';
            } else if (esc === 't') {
              text += '\t';
            } else if (esc === 'r') {
              text += '\r';
            } else {
              text += esc;
            }
            i += 2;
            continue;
          }
          if (c === quote) {
            closed = true;
            i++;
            break;
          }
          text += c;
          i++;
        }
        if (!closed) {
          throw new Error('表达式错误: 字符串引号未闭合(' + DataPipeline.snip(expr, start) + ')');
        }
        let tok: DpTok = new DpTok();
        tok.kind = 1;
        tok.text = text;
        tok.pos = start;
        toks.push(tok);
        continue;
      }
      if (DataPipeline.isIdentStart(code)) {
        let start: number = i;
        i++;
        while (i < n && DataPipeline.isIdentPart(expr.charCodeAt(i))) {
          i++;
        }
        let tok: DpTok = new DpTok();
        tok.kind = 2;
        tok.text = expr.substring(start, i);
        tok.pos = start;
        toks.push(tok);
        continue;
      }
      // 多字符运算符优先
      let two: string = i + 1 < n ? expr.substring(i, i + 2) : '';
      let opText: string = '';
      if (two === '<=' || two === '>=' || two === '==' || two === '!=' || two === '&&' || two === '||') {
        opText = two;
        i += 2;
      } else if ('+-*/%<>(),!'.indexOf(ch) !== -1) {
        opText = ch;
        i++;
      } else if (ch === '=') {
        // 单个 = 宽松按相等处理
        opText = '==';
        i++;
      } else {
        throw new Error('表达式错误: 无法识别的字符 "' + ch + '"(' + DataPipeline.snip(expr, i) + ')');
      }
      let tok: DpTok = new DpTok();
      tok.kind = 3;
      tok.text = opText;
      tok.pos = i - opText.length;
      toks.push(tok);
    }
    let eof: DpTok = new DpTok();
    eof.kind = 4;
    eof.text = '';
    eof.pos = n;
    toks.push(eof);
    return toks;
  }

  private static isIdentStart(code: number): boolean {
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code === 95 ||
      (code >= 0x4E00 && code <= 0x9FFF);
  }

  private static isIdentPart(code: number): boolean {
    return DataPipeline.isIdentStart(code) || (code >= 48 && code <= 57);
  }

  private static snip(expr: string, pos: number): string {
    let start: number = pos - 10;
    if (start < 0) {
      start = 0;
    }
    let end: number = pos + 10;
    if (end > expr.length) {
      end = expr.length;
    }
    return '…' + expr.substring(start, end) + '…';
  }

  // ===== 表达式: 语法(递归下降) =====

  private static peek(toks: DpTok[], pos: number[]): DpTok {
    return toks[pos[0]];
  }

  private static expectOp(toks: DpTok[], pos: number[], op: string): boolean {
    let t: DpTok = toks[pos[0]];
    if (t.kind === 3 && t.text === op) {
      pos[0]++;
      return true;
    }
    return false;
  }

  private static parseOr(toks: DpTok[], pos: number[], expr: string, depth: number): DpNode {
    if (depth > DataPipeline.MAX_DEPTH) {
      throw new Error('表达式错误: 嵌套过深(上限 ' + DataPipeline.MAX_DEPTH.toString() + ' 层)');
    }
    let left: DpNode = DataPipeline.parseAnd(toks, pos, expr, depth + 1);
    while (DataPipeline.expectOp(toks, pos, '||')) {
      let right: DpNode = DataPipeline.parseAnd(toks, pos, expr, depth + 1);
      let node: DpNode = new DpNode();
      node.kind = DpNode.BIN;
      node.op = '||';
      node.kids.push(left);
      node.kids.push(right);
      left = node;
    }
    return left;
  }

  private static parseAnd(toks: DpTok[], pos: number[], expr: string, depth: number): DpNode {
    let left: DpNode = DataPipeline.parseCompare(toks, pos, expr, depth + 1);
    while (DataPipeline.expectOp(toks, pos, '&&')) {
      let right: DpNode = DataPipeline.parseCompare(toks, pos, expr, depth + 1);
      let node: DpNode = new DpNode();
      node.kind = DpNode.BIN;
      node.op = '&&';
      node.kids.push(left);
      node.kids.push(right);
      left = node;
    }
    return left;
  }

  private static parseCompare(toks: DpTok[], pos: number[], expr: string, depth: number): DpNode {
    let left: DpNode = DataPipeline.parseAdd(toks, pos, expr, depth + 1);
    let t: DpTok = DataPipeline.peek(toks, pos);
    if (t.kind === 3 && (t.text === '==' || t.text === '!=' || t.text === '<' ||
      t.text === '<=' || t.text === '>' || t.text === '>=')) {
      pos[0]++;
      let right: DpNode = DataPipeline.parseAdd(toks, pos, expr, depth + 1);
      let node: DpNode = new DpNode();
      node.kind = DpNode.BIN;
      node.op = t.text;
      node.kids.push(left);
      node.kids.push(right);
      return node;
    }
    return left;
  }

  private static parseAdd(toks: DpTok[], pos: number[], expr: string, depth: number): DpNode {
    let left: DpNode = DataPipeline.parseMul(toks, pos, expr, depth + 1);
    for (; ;) {
      let t: DpTok = DataPipeline.peek(toks, pos);
      if (t.kind === 3 && (t.text === '+' || t.text === '-')) {
        pos[0]++;
        let right: DpNode = DataPipeline.parseMul(toks, pos, expr, depth + 1);
        let node: DpNode = new DpNode();
        node.kind = DpNode.BIN;
        node.op = t.text;
        node.kids.push(left);
        node.kids.push(right);
        left = node;
      } else {
        return left;
      }
    }
  }

  private static parseMul(toks: DpTok[], pos: number[], expr: string, depth: number): DpNode {
    let left: DpNode = DataPipeline.parseUnary(toks, pos, expr, depth + 1);
    for (; ;) {
      let t: DpTok = DataPipeline.peek(toks, pos);
      if (t.kind === 3 && (t.text === '*' || t.text === '/' || t.text === '%')) {
        pos[0]++;
        let right: DpNode = DataPipeline.parseUnary(toks, pos, expr, depth + 1);
        let node: DpNode = new DpNode();
        node.kind = DpNode.BIN;
        node.op = t.text;
        node.kids.push(left);
        node.kids.push(right);
        left = node;
      } else {
        return left;
      }
    }
  }

  private static parseUnary(toks: DpTok[], pos: number[], expr: string, depth: number): DpNode {
    if (depth > DataPipeline.MAX_DEPTH) {
      throw new Error('表达式错误: 嵌套过深(上限 ' + DataPipeline.MAX_DEPTH.toString() + ' 层)');
    }
    let t: DpTok = DataPipeline.peek(toks, pos);
    if (t.kind === 3 && (t.text === '!' || t.text === '-')) {
      pos[0]++;
      let kid: DpNode = DataPipeline.parseUnary(toks, pos, expr, depth + 1);
      let node: DpNode = new DpNode();
      node.kind = DpNode.UN;
      node.op = t.text;
      node.kids.push(kid);
      return node;
    }
    return DataPipeline.parsePrimary(toks, pos, expr, depth + 1);
  }

  private static parsePrimary(toks: DpTok[], pos: number[], expr: string, depth: number): DpNode {
    if (depth > DataPipeline.MAX_DEPTH) {
      throw new Error('表达式错误: 嵌套过深(上限 ' + DataPipeline.MAX_DEPTH.toString() + ' 层)');
    }
    let t: DpTok = DataPipeline.peek(toks, pos);
    if (t.kind === 0) {
      pos[0]++;
      let node: DpNode = new DpNode();
      node.kind = DpNode.NUM;
      node.num = t.num;
      return node;
    }
    if (t.kind === 1) {
      pos[0]++;
      let node: DpNode = new DpNode();
      node.kind = DpNode.STR;
      node.str = t.text;
      return node;
    }
    if (t.kind === 2) {
      pos[0]++;
      let word: string = t.text.toLowerCase();
      if (word === 'true' || word === 'false') {
        let node: DpNode = new DpNode();
        node.kind = DpNode.BOOL;
        node.op = word;
        return node;
      }
      if (word === 'null') {
        let node: DpNode = new DpNode();
        node.kind = DpNode.NULL;
        return node;
      }
      if (DataPipeline.peek(toks, pos).kind === 3 && DataPipeline.peek(toks, pos).text === '(') {
        pos[0]++;
        let kids: DpNode[] = [];
        if (!DataPipeline.expectOp(toks, pos, ')')) {
          for (; ;) {
            kids.push(DataPipeline.parseOr(toks, pos, expr, depth + 1));
            if (DataPipeline.expectOp(toks, pos, ',')) {
              continue;
            }
            if (DataPipeline.expectOp(toks, pos, ')')) {
              break;
            }
            let bad: DpTok = DataPipeline.peek(toks, pos);
            throw new Error('表达式错误: 函数 ' + t.text + ' 的参数表缺少 ) (' +
              DataPipeline.snip(expr, bad.pos) + ')');
          }
        }
        let node: DpNode = new DpNode();
        node.kind = DpNode.CALL;
        node.str = t.text.toLowerCase();
        node.kids = kids;
        return node;
      }
      // 裸标识符 -> 列引用
      let node: DpNode = new DpNode();
      node.kind = DpNode.CALL;
      node.str = 'col';
      let kid: DpNode = new DpNode();
      kid.kind = DpNode.STR;
      kid.str = t.text;
      node.kids.push(kid);
      return node;
    }
    if (t.kind === 3 && t.text === '(') {
      pos[0]++;
      let inner: DpNode = DataPipeline.parseOr(toks, pos, expr, depth + 1);
      if (!DataPipeline.expectOp(toks, pos, ')')) {
        throw new Error('表达式错误: 缺少右括号 (' + DataPipeline.snip(expr, t.pos) + ')');
      }
      return inner;
    }
    throw new Error('表达式错误: 意外的 "' + (t.kind === 4 ? '结尾' : t.text) + '"(' +
      DataPipeline.snip(expr, t.pos) + ')');
  }

  // ===== 表达式: 求值 =====

  private static evalNode(node: DpNode, ctx: DpCtx): Object | null {
    if (node.kind === DpNode.NUM) {
      return node.num;
    }
    if (node.kind === DpNode.STR) {
      return node.str;
    }
    if (node.kind === DpNode.BOOL) {
      return node.op === 'true';
    }
    if (node.kind === DpNode.NULL) {
      return null;
    }
    if (node.kind === DpNode.UN) {
      let v: Object | null = DataPipeline.evalNode(node.kids[0], ctx);
      if (node.op === '!') {
        return !DataPipeline.truthy(v);
      }
      return -DataPipeline.toNum(v);
    }
    if (node.kind === DpNode.BIN) {
      return DataPipeline.evalBin(node, ctx);
    }
    return DataPipeline.evalCall(node, ctx);
  }

  private static evalBin(node: DpNode, ctx: DpCtx): Object | null {
    let op: string = node.op;
    if (op === '&&') {
      if (!DataPipeline.truthy(DataPipeline.evalNode(node.kids[0], ctx))) {
        return false;
      }
      return DataPipeline.truthy(DataPipeline.evalNode(node.kids[1], ctx));
    }
    if (op === '||') {
      if (DataPipeline.truthy(DataPipeline.evalNode(node.kids[0], ctx))) {
        return true;
      }
      return DataPipeline.truthy(DataPipeline.evalNode(node.kids[1], ctx));
    }
    let a: Object | null = DataPipeline.evalNode(node.kids[0], ctx);
    let b: Object | null = DataPipeline.evalNode(node.kids[1], ctx);
    if (op === '+') {
      if (typeof a === 'string' || typeof b === 'string') {
        return DataPipeline.asString(a) + DataPipeline.asString(b);
      }
      return DataPipeline.toNum(a) + DataPipeline.toNum(b);
    }
    if (op === '-') {
      return DataPipeline.toNum(a) - DataPipeline.toNum(b);
    }
    if (op === '*') {
      return DataPipeline.toNum(a) * DataPipeline.toNum(b);
    }
    if (op === '/') {
      return DataPipeline.toNum(a) / DataPipeline.toNum(b);
    }
    if (op === '%') {
      return DataPipeline.toNum(a) % DataPipeline.toNum(b);
    }
    return DataPipeline.compareOp(op, a, b);
  }

  private static compareOp(op: string, a: Object | null, b: Object | null): Object | null {
    let na: number = DataPipeline.toNum(a);
    let nb: number = DataPipeline.toNum(b);
    let numeric: boolean = !isNaN(na) && !isNaN(nb);
    if (op === '==') {
      return numeric ? na === nb : DataPipeline.asString(a) === DataPipeline.asString(b);
    }
    if (op === '!=') {
      return numeric ? na !== nb : DataPipeline.asString(a) !== DataPipeline.asString(b);
    }
    if (numeric) {
      if (op === '<') {
        return na < nb;
      }
      if (op === '<=') {
        return na <= nb;
      }
      if (op === '>') {
        return na > nb;
      }
      return na >= nb;
    }
    let sa: string = DataPipeline.asString(a);
    let sb: string = DataPipeline.asString(b);
    if (op === '<') {
      return sa < sb;
    }
    if (op === '<=') {
      return sa <= sb;
    }
    if (op === '>') {
      return sa > sb;
    }
    return sa >= sb;
  }

  private static evalCall(node: DpNode, ctx: DpCtx): Object | null {
    let fn: string = node.str;
    if (fn === 'col') {
      if (node.kids.length !== 1) {
        throw new Error('col() 需要 1 个参数(列名或 1 起列号), 得到 ' + node.kids.length.toString() + ' 个');
      }
      let key: Object | null = DataPipeline.evalNode(node.kids[0], ctx);
      let idx: number = -1;
      if (typeof key === 'number') {
        idx = Math.floor(key as number) - 1;
      } else if (typeof key === 'string') {
        let name: string = (key as string).trim();
        idx = ctx.header.indexOf(name);
        if (idx === -1) {
          let num: number = parseInt(name, 10);
          if (!isNaN(num)) {
            idx = num - 1;
          }
        }
      } else {
        throw new Error('col() 的参数需为列名字符串或数字列号, 得到: ' + DataPipeline.typeName(key));
      }
      if (idx < 0 || idx >= ctx.row.length) {
        let hint: string = ctx.header.length > 0 ? '可用列: ' + DataPipeline.colHint(ctx) :
          '当前无表头, 用 col(数字列号)';
        throw new Error('列不存在或列号越界: ' + DataPipeline.describeKey(key) + '(' + hint + ')');
      }
      return ctx.row[idx];
    }
    if (fn === 'rownum') {
      if (node.kids.length !== 0) {
        throw new Error('rownum(): 不需要参数, 得到 ' + node.kids.length.toString() + ' 个');
      }
      return ctx.rowNum;
    }
    if (fn === 'if') {
      if (node.kids.length !== 3) {
        throw new Error('if(条件, 值1, 值2) 需要 3 个参数, 得到 ' + node.kids.length.toString() + ' 个');
      }
      if (DataPipeline.truthy(DataPipeline.evalNode(node.kids[0], ctx))) {
        return DataPipeline.evalNode(node.kids[1], ctx);
      }
      return DataPipeline.evalNode(node.kids[2], ctx);
    }
    if (fn === 'coalesce') {
      for (let i: number = 0; i < node.kids.length; i++) {
        let v: Object | null = DataPipeline.evalNode(node.kids[i], ctx);
        if (v !== null && !(typeof v === 'string' && (v as string) === '') &&
          !(typeof v === 'number' && isNaN(v as number))) {
          return v;
        }
      }
      return null;
    }
    let args: (Object | null)[] = [];
    for (let i: number = 0; i < node.kids.length; i++) {
      args.push(DataPipeline.evalNode(node.kids[i], ctx));
    }
    return DataPipeline.callFn(fn, args, ctx);
  }

  // 白名单函数实现; args 为已求值参数
  private static callFn(fn: string, args: (Object | null)[], ctx: DpCtx): Object | null {
    let arity: string = fn + '(): 参数个数不符';
    if (fn === 'trim' || fn === 'upper' || fn === 'lower' || fn === 'len' || fn === 'str' ||
      fn === 'num' || fn === 'abs' || fn === 'floor' || fn === 'ceil' || fn === 'is_empty') {
      if (args.length !== 1) {
        throw new Error(arity + '(需要 1 个, 得到 ' + args.length.toString() + ')');
      }
      let v: Object | null = args[0];
      if (fn === 'trim') {
        return DataPipeline.asString(v).trim();
      }
      if (fn === 'upper') {
        return DataPipeline.asString(v).toUpperCase();
      }
      if (fn === 'lower') {
        return DataPipeline.asString(v).toLowerCase();
      }
      if (fn === 'len') {
        return DataPipeline.asString(v).length;
      }
      if (fn === 'str') {
        return DataPipeline.asString(v);
      }
      if (fn === 'num') {
        return DataPipeline.toNum(v);
      }
      if (fn === 'abs') {
        return Math.abs(DataPipeline.fnNumber(fn, 0, v));
      }
      if (fn === 'floor') {
        return Math.floor(DataPipeline.fnNumber(fn, 0, v));
      }
      if (fn === 'ceil') {
        return Math.ceil(DataPipeline.fnNumber(fn, 0, v));
      }
      let s: string = DataPipeline.asString(v);
      return s === '' || s.trim() === '';
    }
    if (fn === 'substr') {
      if (args.length < 2 || args.length > 3) {
        throw new Error('substr(s, start, end?): 需要 2-3 个参数, 得到 ' + args.length.toString() + ' 个');
      }
      let s: string = DataPipeline.asString(args[0]);
      let start: number = DataPipeline.fnNumber(fn, 1, args[1]);
      if (start < 0) {
        start = 0;
      }
      let end: number = s.length;
      if (args.length === 3) {
        end = DataPipeline.fnNumber(fn, 2, args[2]);
      }
      if (end > s.length) {
        end = s.length;
      }
      if (start >= end) {
        return '';
      }
      return s.substring(start, end);
    }
    if (fn === 'replace') {
      if (args.length !== 3) {
        throw new Error(arity + '(需要 3 个, 得到 ' + args.length.toString() + ')');
      }
      let s: string = DataPipeline.asString(args[0]);
      let from: string = DataPipeline.asString(args[1]);
      if (from === '') {
        throw new Error('replace 的第 2 个参数(被替换内容)不能为空字符串');
      }
      return s.split(from).join(DataPipeline.asString(args[2]));
    }
    if (fn === 'regex_replace') {
      if (args.length !== 3) {
        throw new Error(arity + '(需要 3 个, 得到 ' + args.length.toString() + ')');
      }
      let s: string = DataPipeline.asString(args[0]);
      let pattern: string = DataPipeline.asString(args[1]);
      let re: RegExp = DataPipeline.compileRegex(fn, pattern, 'g');
      return s.replace(re, DataPipeline.asString(args[2]));
    }
    if (fn === 'matches') {
      if (args.length !== 2) {
        throw new Error(arity + '(需要 2 个, 得到 ' + args.length.toString() + ')');
      }
      let re: RegExp = DataPipeline.compileRegex(fn, DataPipeline.asString(args[1]), '');
      return re.test(DataPipeline.asString(args[0]));
    }
    if (fn === 'extract') {
      if (args.length < 2 || args.length > 3) {
        throw new Error('extract(s, pattern, group?): 需要 2-3 个参数, 得到 ' + args.length.toString() + ' 个');
      }
      let re: RegExp = DataPipeline.compileRegex(fn, DataPipeline.asString(args[1]), '');
      let m: RegExpExecArray | null = re.exec(DataPipeline.asString(args[0]));
      if (m === null) {
        return '';
      }
      let group: number = 0;
      if (args.length === 3) {
        group = Math.floor(DataPipeline.fnNumber(fn, 2, args[2]));
      }
      if (group < 0) {
        group = 0;
      }
      if (group >= m.length) {
        return '';
      }
      let g: string | undefined = m[group];
      return typeof g === 'undefined' || g === null ? '' : g;
    }
    if (fn === 'split') {
      if (args.length !== 2) {
        throw new Error(arity + '(需要 2 个, 得到 ' + args.length.toString() + ')');
      }
      let sep: string = DataPipeline.asString(args[1]);
      if (sep === '') {
        throw new Error('split 的分隔符不能为空字符串');
      }
      let parts: string[] = DataPipeline.asString(args[0]).split(sep);
      let out: Object[] = [];
      for (let i: number = 0; i < parts.length; i++) {
        out.push(parts[i]);
      }
      return out;
    }
    if (fn === 'join') {
      if (args.length !== 2) {
        throw new Error(arity + '(需要 2 个, 得到 ' + args.length.toString() + ')');
      }
      let arr: Object | null = args[0];
      if (!(arr instanceof Array)) {
        throw new Error('join 的第 1 个参数需为数组(通常来自 split), 得到: ' + DataPipeline.typeName(arr));
      }
      let sep: string = DataPipeline.asString(args[1]);
      let parts: string[] = arr as string[];
      let out: string = '';
      for (let i: number = 0; i < parts.length; i++) {
        out += (i > 0 ? sep : '') + DataPipeline.asString(parts[i]);
      }
      return out;
    }
    if (fn === 'round') {
      if (args.length < 1 || args.length > 2) {
        throw new Error('round(n, digits?): 需要 1-2 个参数, 得到 ' + args.length.toString() + ' 个');
      }
      let n: number = DataPipeline.fnNumber(fn, 0, args[0]);
      let digits: number = 0;
      if (args.length === 2) {
        digits = Math.floor(DataPipeline.fnNumber(fn, 1, args[1]));
      }
      if (digits < 0) {
        digits = 0;
      }
      if (digits > 10) {
        digits = 10;
      }
      let fixed: string = n.toFixed(digits);
      return parseFloat(fixed);
    }
    if (fn === 'min' || fn === 'max') {
      if (args.length < 2) {
        throw new Error(fn + '(a, b, ...): 至少 2 个参数, 得到 ' + args.length.toString() + ' 个');
      }
      let best: number = DataPipeline.fnNumber(fn, 0, args[0]);
      for (let i: number = 1; i < args.length; i++) {
        let cur: number = DataPipeline.fnNumber(fn, i, args[i]);
        if (fn === 'min') {
          best = cur < best ? cur : best;
        } else {
          best = cur > best ? cur : best;
        }
      }
      return best;
    }
    if (fn === 'starts_with' || fn === 'ends_with' || fn === 'contains') {
      if (args.length !== 2) {
        throw new Error(arity + '(需要 2 个, 得到 ' + args.length.toString() + ')');
      }
      let s: string = DataPipeline.asString(args[0]);
      let p: string = DataPipeline.asString(args[1]);
      if (fn === 'starts_with') {
        return s.startsWith(p);
      }
      if (fn === 'ends_with') {
        return s.endsWith(p);
      }
      return s.indexOf(p) !== -1;
    }
    throw new Error('未知函数: ' + fn + '(可用: ' + DataPipeline.FN_LIST + ')');
  }

  private static compileRegex(fn: string, pattern: string, flags: string): RegExp {
    try {
      return new RegExp(pattern, flags);
    } catch (e) {
      let msg: string = e instanceof Error ? (e as Error).message : String(e);
      throw new Error(fn + ' 的正则表达式无效: "' + pattern + '"(' + msg + ')');
    }
  }

  private static fnNumber(fn: string, argIdx: number, v: Object | null): number {
    let n: number = DataPipeline.toNum(v);
    if (isNaN(n)) {
      throw new Error('函数 ' + fn + ' 的第 ' + (argIdx + 1).toString() + ' 个参数需要数字, 得到: ' +
        DataPipeline.describeKey(v));
    }
    return n;
  }

  // ===== 值辅助 =====

  // 宽松真值: 布尔取自身; 数字非 0 且非 NaN; 文本非空串; 数组非空
  private static truthy(v: Object | null): boolean {
    if (v === null) {
      return false;
    }
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'number') {
      return !isNaN(v as number) && (v as number) !== 0;
    }
    if (typeof v === 'string') {
      return (v as string) !== '';
    }
    if (v instanceof Array) {
      return (v as Object[]).length > 0;
    }
    return true;
  }

  // 数值化: 数字原样; 布尔 1/0; 文本去首尾空白、剥离千分位逗号与 ￥$€£¥ 前缀后前缀解析;
  // 解析失败返回 NaN(比较按文本, 算术随 NaN 传播, filter 中视为假)
  private static toNum(v: Object | null): number {
    if (v === null) {
      return NaN;
    }
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'boolean') {
      return (v as boolean) ? 1 : 0;
    }
    if (typeof v !== 'string') {
      return NaN;
    }
    let t: string = (v as string).trim();
    if (t === '') {
      return NaN;
    }
    t = t.replace(/^[￥$€£¥\s]+/, '');
    if (/^-?\d{1,3}(,\d{3})+(\.\d+)?$/.test(t)) {
      t = t.split(',').join('');
    }
    return parseFloat(t);
  }

  private static asString(v: Object | null): string {
    if (v === null) {
      return '';
    }
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return isNaN(v as number) ? '' : String(v);
    }
    if (typeof v === 'boolean') {
      return (v as boolean) ? 'true' : 'false';
    }
    throw new Error('此处需要文本值, 得到数组(如需拼接请用 join(数组, 连接符))');
  }

  // 表达式结果 -> 单元格: 标量转文本; 数组是模型常见笔误, 给出可操作的报错
  private static valueToCell(v: Object | null): string {
    if (v !== null && v instanceof Array) {
      throw new Error('表达式结果不能是数组, 如需拼接请用 join(数组, 连接符)');
    }
    return DataPipeline.asString(v);
  }

  // 排序键比较: 双方可数值化则按数值, 否则按文本(码元序)
  private static compareValues(a: Object | null, b: Object | null): number {
    let na: number = DataPipeline.toNum(a);
    let nb: number = DataPipeline.toNum(b);
    if (!isNaN(na) && !isNaN(nb)) {
      return na < nb ? -1 : (na > nb ? 1 : 0);
    }
    let sa: string = DataPipeline.asString(a);
    let sb: string = DataPipeline.asString(b);
    return sa < sb ? -1 : (sa > sb ? 1 : 0);
  }

  private static typeName(v: Object | null): string {
    if (v === null) {
      return '空值';
    }
    if (typeof v === 'string') {
      return '文本';
    }
    if (typeof v === 'number') {
      return '数字';
    }
    if (typeof v === 'boolean') {
      return '布尔值';
    }
    if (v instanceof Array) {
      return '数组';
    }
    return '对象';
  }

  private static describeKey(v: Object | null): string {
    if (v === null) {
      return '空值';
    }
    if (typeof v === 'string') {
      return '"' + (v as string) + '"';
    }
    if (typeof v === 'number' || typeof v === 'boolean') {
      return String(v);
    }
    return DataPipeline.typeName(v);
  }

  private static colHint(ctx: DpCtx): string {
    let out: string = '';
    for (let i: number = 0; i < ctx.header.length && i < 15; i++) {
      out += (i > 0 ? ', ' : '') + ctx.header[i];
    }
    if (ctx.header.length > 15) {
      out += ', ...(共 ' + ctx.header.length.toString() + ' 列)';
    }
    return out === '' ? '(无列名)' : out;
  }

  // ===== 输出构建 =====

  // 供 CsvWriter 落盘的行数组(含表头行与否由 includeHeader 决定)
  static toCsvRows(table: DpTable, includeHeader: boolean): string[][] {
    let rows: string[][] = [];
    if (includeHeader && table.hasHeader) {
      rows.push(table.header.slice());
    }
    for (let i: number = 0; i < table.rows.length; i++) {
      rows.push(table.rows[i]);
    }
    return rows;
  }

  static toTsvText(table: DpTable): string {
    let lines: string[] = [];
    if (table.hasHeader) {
      lines.push(DataPipeline.tsvRow(table.header));
    }
    for (let i: number = 0; i < table.rows.length; i++) {
      lines.push(DataPipeline.tsvRow(table.rows[i]));
    }
    return lines.join('\n');
  }

  private static tsvRow(cells: string[]): string {
    let out: string[] = [];
    for (let i: number = 0; i < cells.length; i++) {
      out.push(cells[i].replace(/[\t\r\n]+/g, ' '));
    }
    return out.join('\t');
  }

  // JSON: 有表头 -> 对象数组; 无表头 -> 二维数组
  static toJsonText(table: DpTable): string {
    if (!table.hasHeader) {
      return JSON.stringify(table.rows);
    }
    let objs: Record<string, Object>[] = [];
    for (let i: number = 0; i < table.rows.length; i++) {
      let obj: Record<string, Object> = {};
      for (let k: number = 0; k < table.header.length; k++) {
        obj[table.header[k]] = table.rows[i][k];
      }
      objs.push(obj);
    }
    return JSON.stringify(objs);
  }

  static toMdText(table: DpTable): string {
    let lines: string[] = [];
    let width: number = table.header.length;
    if (table.hasHeader) {
      let head: string[] = [];
      for (let k: number = 0; k < width; k++) {
        head.push(table.header[k].replace(/\|/g, '\\|').replace(/[\r\n]+/g, ' '));
      }
      lines.push('| ' + head.join(' | ') + ' |');
      let sep: string[] = [];
      for (let k: number = 0; k < width; k++) {
        sep.push('---');
      }
      lines.push('| ' + sep.join(' | ') + ' |');
    }
    for (let i: number = 0; i < table.rows.length; i++) {
      let cells: string[] = [];
      for (let k: number = 0; k < width; k++) {
        cells.push(table.rows[i][k].replace(/\|/g, '\\|').replace(/[\r\n]+/g, ' '));
      }
      lines.push('| ' + cells.join(' | ') + ' |');
    }
    return lines.join('\n');
  }

  // 逐行文本: 取每行第 1 列(需要多列输出时先 select)
  static toLinesText(table: DpTable): string {
    let lines: string[] = [];
    for (let i: number = 0; i < table.rows.length; i++) {
      lines.push(table.rows[i].length > 0 ? table.rows[i][0] : '');
    }
    return lines.join('\n');
  }

  // 预览: 前 maxRows 行的 Markdown 表格(单元格与列数封顶), 供模型写盘前确认
  static previewMarkdown(table: DpTable, maxRows: number, cellCap: number, maxCols: number): string {
    let width: number = table.header.length < maxCols ? table.header.length : maxCols;
    let colNote: string = table.header.length > maxCols ?
      '(仅展示前 ' + maxCols.toString() + ' 列, 共 ' + table.header.length.toString() + ' 列)\n' : '';
    let lines: string[] = [];
    let head: string[] = [];
    for (let k: number = 0; k < width; k++) {
      head.push(DataPipeline.previewCell(table.hasHeader ? table.header[k] : '第' + (k + 1).toString() + '列',
        cellCap));
    }
    lines.push('| ' + head.join(' | ') + ' |');
    let sep: string[] = [];
    for (let k: number = 0; k < width; k++) {
      sep.push('---');
    }
    lines.push('| ' + sep.join(' | ') + ' |');
    let shown: number = table.rows.length < maxRows ? table.rows.length : maxRows;
    for (let i: number = 0; i < shown; i++) {
      let cells: string[] = [];
      for (let k: number = 0; k < width; k++) {
        cells.push(DataPipeline.previewCell(table.rows[i][k], cellCap));
      }
      lines.push('| ' + cells.join(' | ') + ' |');
    }
    let note: string = shown < table.rows.length ?
      '\n…(预览仅前 ' + shown.toString() + ' 行, 共 ' + table.rows.length.toString() + ' 行)' : '';
    return colNote + lines.join('\n') + note;
  }

  private static previewCell(cell: string, cap: number): string {
    let t: string = cell.replace(/[\r\n]+/g, ' ');
    if (t.length > cap) {
      return t.substring(0, cap) + '…';
    }
    return t === '' ? '(空)' : t;
  }

  // 概况: N 行 × M 列 + 列名(有表头时)
  static statsText(table: DpTable): string {
    let out: string = table.rows.length.toString() + ' 行 × ' + table.header.length.toString() + ' 列';
    if (table.hasHeader) {
      out += ', 列: ' + DataPipeline.headerList(table);
    } else {
      out += '(无表头, 用 col(1) 等列号引用)';
    }
    return out;
  }
}
