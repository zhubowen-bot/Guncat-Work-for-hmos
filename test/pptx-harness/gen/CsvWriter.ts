// CsvWriter: 行数据 -> CSV 字节 (纯逻辑模块, 无 HarmonyOS API 依赖, 仅用 util.TextEncoder)
// 转义规则(RFC 4180): 含逗号/引号/换行的字段加双引号包裹, 字段内引号翻倍; 行尾 CRLF(Excel/WPS 友好)。
// bom=true 时写入 UTF-8 BOM, 避免 Excel/WPS 打开中文乱码。
import { util } from './arkts-shim.ts';

export class CsvWriter {
  static buildCsvBytes(rows: string[][], bom: boolean): Uint8Array {
    let lines: string[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      lines.push(CsvWriter.encodeRow(rows[i]));
    }
    let text: string = lines.join('\r\n') + '\r\n';
    let encoder: util.TextEncoder = new util.TextEncoder();
    let body: Uint8Array = encoder.encode(text);
    if (!bom) {
      return body;
    }
    let out: Uint8Array = new Uint8Array(3 + body.length);
    out[0] = 0xEF;
    out[1] = 0xBB;
    out[2] = 0xBF;
    out.set(body, 3);
    return out;
  }

  static encodeRow(cells: string[]): string {
    let parts: string[] = [];
    for (let i: number = 0; i < cells.length; i++) {
      parts.push(CsvWriter.encodeCell(cells[i]));
    }
    return parts.join(',');
  }

  static encodeCell(value: string): string {
    let v: string = value;
    if (v.indexOf(',') !== -1 || v.indexOf('"') !== -1 ||
      v.indexOf('\n') !== -1 || v.indexOf('\r') !== -1) {
      return '"' + v.split('"').join('""') + '"';
    }
    return v;
  }
}
