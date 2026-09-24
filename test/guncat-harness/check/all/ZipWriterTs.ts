import { util } from '@kit.ArkTS';

// 极简 ZIP 归档写入器(STORE 方式, 无压缩)
// .docx/.xlsx 本质是 zip 包, HarmonyOS zlib 模块不提供多条目归档 API, 因此手动组装 zip 结构。
// Word/Excel 等办公软件完全兼容 STORE 方式的 zip。
// 注意: 本文件为 .ts(供 viewmodel/service 等 TS 模块复用), 不能导入 .ets, 因此 dosDateTime 在文件内实现。
// 文件名带 Ts 后缀: 同目录已有 ZipWriter.ets, 若本文件也叫 ZipWriter.ts, 无扩展名导入 '../export/ZipWriter'
// 会解析到 .ets, 触发 10605999(TS 文件禁止导入 ArkTS 文件)。

// zip 内条目
export class ZipEntry {
  name: string = '';
  data: Uint8Array = new Uint8Array(0);
}

export class ZipWriter {
  private static crcTable: number[] = [];
  private static inited: boolean = false;

  private static ensureTable(): void {
    if (ZipWriter.inited) {
      return;
    }
    ZipWriter.inited = true;
    for (let n: number = 0; n < 256; n++) {
      let c: number = n;
      for (let k: number = 0; k < 8; k++) {
        c = (c & 1) === 1 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      ZipWriter.crcTable.push(c >>> 0);
    }
  }

  static crc32(data: Uint8Array): number {
    ZipWriter.ensureTable();
    let crc: number = 0xFFFFFFFF;
    for (let i: number = 0; i < data.length; i++) {
      crc = (crc >>> 8) ^ ZipWriter.crcTable[(crc ^ data[i]) & 0xFF];
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  // 将条目列表组装为 zip 文件字节
  static create(entries: ZipEntry[]): Uint8Array {
    let encoder: util.TextEncoder = new util.TextEncoder();
    let localParts: Uint8Array[] = [];
    let centralParts: Uint8Array[] = [];
    let offset: number = 0;
    let dosDt: number = ZipWriter.dosDateTime(new Date());
    for (let i: number = 0; i < entries.length; i++) {
      let entry: ZipEntry = entries[i];
      let nameBytes: Uint8Array = encoder.encode(entry.name);
      let data: Uint8Array = entry.data;
      let crc: number = ZipWriter.crc32(data);

      // 本地文件头
      let lh: DataView = new DataView(new ArrayBuffer(30));
      lh.setUint32(0, 0x04034B50, true);
      lh.setUint16(4, 20, true);          // version needed
      lh.setUint16(6, 0x0800, true);      // UTF-8 文件名
      lh.setUint16(8, 0, true);           // method: store
      lh.setUint32(10, dosDt, true);
      lh.setUint32(14, crc, true);
      lh.setUint32(18, data.length, true);
      lh.setUint32(22, data.length, true);
      lh.setUint16(26, nameBytes.length, true);
      lh.setUint16(28, 0, true);          // extra len
      localParts.push(new Uint8Array(lh.buffer));
      localParts.push(nameBytes);
      localParts.push(data);

      // 中央目录条目
      let ch: DataView = new DataView(new ArrayBuffer(46));
      ch.setUint32(0, 0x02014B50, true);
      ch.setUint16(4, 20, true);          // version made by
      ch.setUint16(6, 20, true);
      ch.setUint16(8, 0x0800, true);
      ch.setUint16(10, 0, true);
      ch.setUint32(12, dosDt, true);
      ch.setUint32(16, crc, true);
      ch.setUint32(20, data.length, true);
      ch.setUint32(24, data.length, true);
      ch.setUint16(28, nameBytes.length, true);
      ch.setUint16(30, 0, true);          // extra len
      ch.setUint16(32, 0, true);          // comment len
      ch.setUint16(34, 0, true);          // disk
      ch.setUint16(36, 0, true);          // internal attrs
      ch.setUint32(38, 0, true);          // external attrs
      ch.setUint32(42, offset, true);     // local header offset
      centralParts.push(new Uint8Array(ch.buffer));
      centralParts.push(nameBytes);

      offset += 30 + nameBytes.length + data.length;
    }

    let cdSize: number = ZipWriter.totalLen(centralParts);
    let cdOffset: number = offset;
    let count: number = entries.length;

    // 中央目录结束记录
    let eocd: DataView = new DataView(new ArrayBuffer(22));
    eocd.setUint32(0, 0x06054B50, true);
    eocd.setUint16(4, 0, true);           // disk number
    eocd.setUint16(6, 0, true);           // cd start disk
    eocd.setUint16(8, count, true);
    eocd.setUint16(10, count, true);
    eocd.setUint32(12, cdSize, true);
    eocd.setUint32(16, cdOffset, true);
    eocd.setUint16(20, 0, true);          // comment len

    let all: Uint8Array[] = [];
    ZipWriter.pushAll(all, localParts);
    ZipWriter.pushAll(all, centralParts);
    all.push(new Uint8Array(eocd.buffer));
    return ZipWriter.concat(all);
  }

  // DOS 日期时间(用于 zip 头), 返回 32 位: 高16位=时间, 低16位=日期 (与 XmlUtil.dosDateTime 同实现)
  private static dosDateTime(d: Date): number {
    let year: number = d.getFullYear();
    if (year < 1980) {
      year = 1980;
    }
    let time: number = (d.getHours() << 11) | (d.getMinutes() << 5) | Math.floor(d.getSeconds() / 2);
    let date: number = ((year - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
    return (time << 16) | date;
  }

  private static totalLen(parts: Uint8Array[]): number {
    let total: number = 0;
    for (let i: number = 0; i < parts.length; i++) {
      total += parts[i].length;
    }
    return total;
  }

  private static pushAll(dest: Uint8Array[], src: Uint8Array[]): void {
    for (let i: number = 0; i < src.length; i++) {
      dest.push(src[i]);
    }
  }

  private static concat(parts: Uint8Array[]): Uint8Array {
    let total: number = ZipWriter.totalLen(parts);
    let out: Uint8Array = new Uint8Array(total);
    let off: number = 0;
    for (let i: number = 0; i < parts.length; i++) {
      out.set(parts[i], off);
      off += parts[i].length;
    }
    return out;
  }
}
