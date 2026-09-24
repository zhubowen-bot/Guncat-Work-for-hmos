// CsvParser: CSV/TSV/Markdown 表格文本 -> 行数组 (纯逻辑模块, 无 HarmonyOS API 依赖)
// RFC 4180 规则: 双引号包裹的字段可含 逗号/引号/换行, 字段内引号以 "" 转义;
// 行分隔兼容 CRLF / CR / LF, 自动剥离 UTF-8 BOM 字符; 引号未闭合时按读到文件尾处理(宽松)。
// parseSmartTable 按内容自动识别 Markdown 表格(|)/TSV(制表符)/CSV(逗号/分号),
// 供 write_csv / write_xlsx / transform_file 共用, 修复旧实现裸 split(',') 弄坏引号字段的问题。
export class CsvParser {
  // RFC 4180 解析; delimiter 为单字符(如 ',' '\t' ';')
  static parse(text: string, delimiter: string): string[][] {
    if (text.length > 0 && text.charCodeAt(0) === 0xFEFF) {
      text = text.substring(1);
    }
    let n: number = text.length;
    if (n === 0) {
      return [];
    }
    if (text.indexOf('"') === -1) {
      // 快路径: 无引号 -> 直接按行按分隔符切
      let fast: string[][] = [];
      let lines: string[] = text.split('\n');
      for (let i: number = 0; i < lines.length; i++) {
        let line: string = lines[i];
        if (line.length > 0 && line.charAt(line.length - 1) === '\r') {
          line = line.substring(0, line.length - 1);
        }
        let cells: string[] = line.split(delimiter);
        if (cells.length === 1 && cells[0].trim() === '') {
          continue;
        }
        fast.push(cells);
      }
      return fast;
    }
    // 慢路径: 状态机, 遇引号字段逐段累积(cell 非空时才做字符串拼接, 其余用 substring 切片)
    let rows: string[][] = [];
    let row: string[] = [];
    let cell: string = '';
    let cellStart: number = 0;
    let atCellStart: boolean = true;
    let inQuotes: boolean = false;
    let i: number = 0;
    while (i < n) {
      let ch: string = text.charAt(i);
      if (inQuotes) {
        if (ch === '"') {
          if (i + 1 < n && text.charAt(i + 1) === '"') {
            // 转义引号 "" -> 内容里的一个 "
            cell += text.substring(cellStart, i) + '"';
            cellStart = i + 2;
            i += 2;
            continue;
          }
          // 闭引号
          cell += text.substring(cellStart, i);
          cellStart = i + 1;
          inQuotes = false;
          i++;
          continue;
        }
        i++;
        continue;
      }
      if (ch === '"') {
        if (atCellStart) {
          inQuotes = true;
          cellStart = i + 1;
          i++;
          continue;
        }
        // 引号不在字段开头, 按字面量处理(宽松)
        atCellStart = false;
        i++;
        continue;
      }
      if (ch === delimiter) {
        cell += text.substring(cellStart, i);
        row.push(cell);
        cell = '';
        cellStart = i + 1;
        atCellStart = true;
        i++;
        continue;
      }
      if (ch === '\r' || ch === '\n') {
        cell += text.substring(cellStart, i);
        row.push(cell);
        cell = '';
        if (ch === '\r' && i + 1 < n && text.charAt(i + 1) === '\n') {
          i += 2;
        } else {
          i++;
        }
        if (!(row.length === 1 && row[0] === '')) {
          rows.push(row);
        }
        row = [];
        cellStart = i;
        atCellStart = true;
        continue;
      }
      atCellStart = false;
      i++;
    }
    // 收尾: 最后一个字段/行(引号未闭合时 cellStart 可能停在引号后)
    cell += text.substring(cellStart, n);
    if (cell !== '' || row.length > 0) {
      row.push(cell);
    }
    if (!(row.length === 1 && row[0] === '') && row.length > 0) {
      rows.push(row);
    }
    return rows;
  }

  // 从首个非空行推断分隔符: 制表符 / 分号 / 逗号(计数最多者, 平手取逗号, 全 0 取逗号)
  static detectDelimiter(text: string): string {
    let first: string = '';
    let lines: string[] = text.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      if (lines[i].trim() !== '') {
        first = lines[i];
        break;
      }
    }
    if (first === '') {
      return ',';
    }
    let comma: number = first.split(',').length - 1;
    let semi: number = first.split(';').length - 1;
    let tab: number = first.split('\t').length - 1;
    if (tab > 0 && tab >= comma && tab >= semi) {
      return '\t';
    }
    if (semi > comma) {
      return ';';
    }
    return ',';
  }

  // 智能表格识别: Markdown 表格(行含 |) / TSV(行含制表符) / CSV(其余, 自动推断分隔符)
  // 返回纯数据行(Markdown 分隔行 |---| 已剔除, 单元格已去首尾空格)
  static parseSmartTable(text: string): string[][] {
    let first: string = '';
    let lines: string[] = text.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      if (lines[i].trim() !== '') {
        first = lines[i].trim();
        break;
      }
    }
    if (first === '') {
      return [];
    }
    if (first.indexOf('|') !== -1) {
      return CsvParser.parseMarkdownTable(text);
    }
    if (first.indexOf('\t') !== -1) {
      return CsvParser.parse(text, '\t');
    }
    return CsvParser.parse(text, CsvParser.detectDelimiter(text));
  }

  // Markdown 表格: | a | b | 形式, 跳过 |---|---| 分隔行
  static parseMarkdownTable(text: string): string[][] {
    let rows: string[][] = [];
    let rawLines: string[] = text.split('\n');
    for (let i: number = 0; i < rawLines.length; i++) {
      let line: string = rawLines[i].trim();
      if (line === '') {
        continue;
      }
      // Markdown 分隔行 |---|---|
      if (line.indexOf('-') !== -1 && /^\|?[\s\-:|]+\|?$/.test(line)) {
        continue;
      }
      let trimmed: string = line;
      if (trimmed.startsWith('|')) {
        trimmed = trimmed.substring(1);
      }
      if (trimmed.endsWith('|')) {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
      let parts: string[] = trimmed.split('|');
      let cells: string[] = [];
      for (let c: number = 0; c < parts.length; c++) {
        cells.push(parts[c].trim());
      }
      rows.push(cells);
    }
    return rows;
  }
}
