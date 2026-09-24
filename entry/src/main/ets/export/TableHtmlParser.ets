// TableHtmlParser: HTML <table> -> 网格结构 (对齐 web 版本 parseTable)
// 保留合并单元格(rowspan/colspan)、行高信息(data-lines / data-h)、caption
export class TableCellInfo {
  text: string = '';
  rowspan: number = 1;
  colspan: number = 1;
  isHeader: boolean = false;
}

export class TableRowInfo {
  cells: TableCellInfo[] = [];
  dataLines: number = 1;
  dataH: string = '';
}

export class DebugCellEntry {
  text: string = '';
  rs: number = 1;
  cs: number = 1;
  h: boolean = false;
}

export class DebugRowEntry {
  cellCount: number = 0;
  dataLines: number = 1;
  dataH: string = '';
  cells: Object[] = [];
}

export class TableGridInfo {
  grid: (TableCellInfo | null)[][] = [];
  maxCols: number = 0;
  rowData: TableRowInfo[] = [];
  totalRows: number = 0;
  html: string = '';
}

export class HtmlTableParser {
  // 解析 HTML 字符串中的 <table>, 构建网格
  static parse(htmlStr: string): TableGridInfo {
    let tableMatch: RegExpMatchArray | null = htmlStr.match(/<table[\s\S]*<\/table>/i);
    let tableBlock: string = '';
    if (tableMatch !== null) {
      tableBlock = tableMatch[0];
    } else {
      // 兼容部分多模态模型直接输出 Markdown 表格的情况
      tableBlock = HtmlTableParser.markdownTableToHtml(htmlStr);
    }
    if (tableBlock === '') {
      throw new Error('未找到 <table> 标签');
    }

    let captionText: string = '';
    let captionMatch: RegExpMatchArray | null = tableBlock.match(/<caption[^>]*>([\s\S]*?)<\/caption>/i);
    if (captionMatch !== null) {
      captionText = HtmlTableParser.decodeText(captionMatch[1].trim());
    }

    let rowData: TableRowInfo[] = [];
    let maxCols: number = 0;
    let rowPattern: RegExp = /<tr([^>]*)>([\s\S]*?)<\/tr>/gi;
    let rowMatches: IterableIterator<string[]> = tableBlock.matchAll(rowPattern);
    for (let rowMatch of rowMatches) {
      let trAttrs: string = rowMatch[1];
      let trInner: string = rowMatch[2];
      let row: TableRowInfo = new TableRowInfo();
      row.dataLines = HtmlTableParser.parseIntAttr(trAttrs, 'data-lines', 1);
      row.dataH = HtmlTableParser.parseStringAttr(trAttrs, 'data-h');

      let cellPattern: RegExp = /<t([dh])([^>]*)>([\s\S]*?)<\/t\1>/gi;
      let cellMatches: IterableIterator<string[]> = trInner.matchAll(cellPattern);
      for (let cellMatch of cellMatches) {
        let tagName: string = cellMatch[1].toUpperCase();
        let tdAttrs: string = cellMatch[2];
        let cell: TableCellInfo = new TableCellInfo();
        cell.text = HtmlTableParser.decodeText(HtmlTableParser.stripTags(cellMatch[3]));
        cell.rowspan = HtmlTableParser.parseIntAttr(tdAttrs, 'rowspan', 1);
        cell.colspan = HtmlTableParser.parseIntAttr(tdAttrs, 'colspan', 1);
        cell.isHeader = tagName === 'TH';
        row.cells.push(cell);
      }

      let cols: number = 0;
      for (let i: number = 0; i < row.cells.length; i++) {
        cols += row.cells[i].colspan;
      }
      if (cols > maxCols) {
        maxCols = cols;
      }
      rowData.push(row);
    }

    // caption 作为首行 (整行合并)
    if (captionText !== '' && maxCols > 0) {
      let captionCell: TableCellInfo = new TableCellInfo();
      captionCell.text = captionText;
      captionCell.rowspan = 1;
      captionCell.colspan = maxCols;
      captionCell.isHeader = true;
      let captionRow: TableRowInfo = new TableRowInfo();
      captionRow.cells.push(captionCell);
      captionRow.dataLines = 1;
      captionRow.dataH = '';
      rowData.unshift(captionRow);
    }

    if (maxCols === 0 || rowData.length === 0) {
      throw new Error('未找到 <table> 标签');
    }

    // 构建网格: occupied 记录被 rowspan 覆盖的位置
    let grid: (TableCellInfo | null)[][] = [];
    let occupied: Map<number, boolean> = new Map<number, boolean>();

    for (let r: number = 0; r < rowData.length; r++) {
      let gridRow: (TableCellInfo | null)[] = [];
      let ci: number = 0;
      let cellIdx: number = 0;
      let cells: TableCellInfo[] = rowData[r].cells;

      while (ci < maxCols) {
        let key: number = r * 10000 + ci;
        if (occupied.has(key)) {
          gridRow.push(null);
          ci++;
          continue;
        }
        if (cellIdx >= cells.length) {
          let empty: TableCellInfo = new TableCellInfo();
          empty.text = '';
          empty.rowspan = 1;
          empty.colspan = 1;
          empty.isHeader = false;
          gridRow.push(empty);
          ci++;
          continue;
        }
        let cell: TableCellInfo = cells[cellIdx];
        cellIdx++;
        gridRow.push(cell);
        for (let dc: number = 1; dc < cell.colspan; dc++) {
          gridRow.push(null);
        }
        for (let dr: number = 1; dr < cell.rowspan; dr++) {
          for (let dc: number = 0; dc < cell.colspan; dc++) {
            occupied.set((r + dr) * 10000 + ci + dc, true);
          }
        }
        ci += cell.colspan;
      }
      grid.push(gridRow);
    }

    let info: TableGridInfo = new TableGridInfo();
    info.grid = grid;
    info.maxCols = maxCols;
    info.rowData = rowData;
    info.totalRows = rowData.length;
    info.html = tableBlock;
    return info;
  }

  // 调试信息 JSON (对齐 web 版本 debugInfo)
  static debugJson(info: TableGridInfo): string {
    let rowsArr: Object[] = [];
    for (let r: number = 0; r < info.rowData.length; r++) {
      let row: TableRowInfo = info.rowData[r];
      let cellsArr: Object[] = [];
      for (let i: number = 0; i < row.cells.length; i++) {
        let c: TableCellInfo = row.cells[i];
        let text: string = c.text;
        if (text.length > 30) {
          text = text.substring(0, 30) + '…';
        }
        let entry: DebugCellEntry = new DebugCellEntry();
        entry.text = text;
        entry.rs = c.rowspan;
        entry.cs = c.colspan;
        entry.h = c.isHeader;
        cellsArr.push(entry);
      }
      let entryRow: DebugRowEntry = new DebugRowEntry();
      entryRow.cellCount = row.cells.length;
      entryRow.dataLines = row.dataLines;
      entryRow.dataH = row.dataH;
      entryRow.cells = cellsArr;
      rowsArr.push(entryRow);
    }
    let obj: Record<string, Object> = {
      'totalRows': info.totalRows,
      'maxCols': info.maxCols,
      'rowData': rowsArr
    };
    return JSON.stringify(obj, null, 2);
  }

  // 单元格内容: <br> -> \n, 去掉其余标签, 解码实体
  private static stripTags(inner: string): string {
    let s: string = inner;
    s = s.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<[^>]+>/g, '');
    s = s.replace(/&nbsp;/g, ' ');
    s = s.replace(/&#160;/g, ' ');
    s = s.replace(/&lt;/g, '<');
    s = s.replace(/&gt;/g, '>');
    s = s.replace(/&quot;/g, '"');
    s = s.replace(/&amp;/g, '&');
    return s.trim();
  }

  private static decodeText(inner: string): string {
    let s: string = inner;
    s = s.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<[^>]+>/g, '');
    s = s.replace(/&nbsp;/g, ' ');
    s = s.replace(/&#160;/g, ' ');
    s = s.replace(/&lt;/g, '<');
    s = s.replace(/&gt;/g, '>');
    s = s.replace(/&quot;/g, '"');
    s = s.replace(/&amp;/g, '&');
    return s.trim();
  }

  // 简单 Markdown 表格 → HTML，作为模型未按 HTML 输出时的兜底
  static markdownTableToHtml(raw: string): string {
    let lines: string[] = raw.split('\n');
    let start: number = -1;
    for (let i: number = 0; i < lines.length - 1; i++) {
      let line: string = lines[i].trim();
      let next: string = lines[i + 1].trim();
      if (line.indexOf('|') !== -1 && next.indexOf('|') !== -1 &&
        /^\s*\|?[\s:|-]+\|?\s*$/.test(next)) {
        start = i;
        break;
      }
    }
    if (start < 0) {
      return '';
    }

    let headerCells: string[] = HtmlTableParser.splitMarkdownRow(lines[start]);
    let html: string = '<table><thead><tr>';
    for (let i: number = 0; i < headerCells.length; i++) {
      html += '<th>' + HtmlTableParser.escapeCell(headerCells[i]) + '</th>';
    }
    html += '</tr></thead><tbody>';

    for (let r: number = start + 2; r < lines.length; r++) {
      let line: string = lines[r].trim();
      if (line.indexOf('|') === -1) {
        break;
      }
      let cells: string[] = HtmlTableParser.splitMarkdownRow(line);
      html += '<tr>';
      for (let i: number = 0; i < cells.length; i++) {
        html += '<td>' + HtmlTableParser.escapeCell(cells[i]) + '</td>';
      }
      html += '</tr>';
    }

    html += '</tbody></table>';
    return html;
  }

  private static splitMarkdownRow(line: string): string[] {
    let s: string = line.trim();
    if (s.startsWith('|')) {
      s = s.substring(1);
    }
    if (s.endsWith('|')) {
      s = s.substring(0, s.length - 1);
    }
    let parts: string[] = s.split('|');
    let cells: string[] = [];
    for (let i: number = 0; i < parts.length; i++) {
      cells.push(parts[i].trim());
    }
    return cells;
  }

  private static escapeCell(s: string): string {
    let r: string = s;
    r = r.replace(/&/g, '&amp;');
    r = r.replace(/</g, '&lt;');
    r = r.replace(/>/g, '&gt;');
    return r;
  }

  private static parseIntAttr(attrs: string, name: string, def: number): number {
    let pattern: RegExp = new RegExp(name + '\\s*=\\s*["\']?(\\d+)["\']?', 'i');
    let match: RegExpMatchArray | null = attrs.match(pattern);
    if (match === null) {
      return def;
    }
    let v: number = parseInt(match[1], 10);
    if (!isNaN(v) && v > 0) {
      return v;
    }
    return def;
  }

  private static parseStringAttr(attrs: string, name: string): string {
    let pattern: RegExp = new RegExp(name + '\\s*=\\s*["\']([^"\']*)["\']', 'i');
    let match: RegExpMatchArray | null = attrs.match(pattern);
    if (match === null) {
      return '';
    }
    return match[1];
  }
}