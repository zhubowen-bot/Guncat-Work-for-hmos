// OOXML 生成公共工具: XML 转义 / 时间格式化 / 数字补零
export class XmlUtil {
  // 转义文本节点内容
  static escape(text: string): string {
    let out: string = '';
    for (let i: number = 0; i < text.length; i++) {
      let c: string = text.charAt(i);
      if (c === '&') {
        out += '&amp;';
      } else if (c === '<') {
        out += '&lt;';
      } else if (c === '>') {
        out += '&gt;';
      } else if (c === '"') {
        out += '&quot;';
      } else if (c === '\'') {
        out += '&apos;';
      } else {
        out += c;
      }
    }
    return out;
  }

  // 转义 XML 属性值
  static escapeAttr(value: string): string {
    return XmlUtil.escape(value);
  }

  // 时间戳: 20260807-143025
  static stamp(): string {
    let d: Date = new Date();
    let p: (n: number) => string = (n: number): string => {
      return n < 10 ? '0' + n.toString() : n.toString();
    };
    return d.getFullYear().toString() +
      p(d.getMonth() + 1) + p(d.getDate()) + '-' +
      p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
  }

  // 生成 docx 文件名: Guncat-导出-20260807-143025.docx
  static makeFileName(prefix: string): string {
    return prefix + '-' + XmlUtil.stamp() + '.docx';
  }

  // ISO8601 (UTC) 时间, 用于 docProps/core.xml
  static isoDateTime(): string {
    return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  }

  // DOS 日期时间(用于 zip 头), 返回 32 位: 高16位=时间, 低16位=日期
  static dosDateTime(d: Date): number {
    let year: number = d.getFullYear();
    if (year < 1980) {
      year = 1980;
    }
    let time: number = (d.getHours() << 11) | (d.getMinutes() << 5) | Math.floor(d.getSeconds() / 2);
    let date: number = ((year - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
    return (time << 16) | date;
  }
}
