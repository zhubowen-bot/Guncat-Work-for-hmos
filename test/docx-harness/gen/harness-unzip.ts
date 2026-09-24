// Node 端最小 ZIP 解包器(替换 DocxImporter 里的 zlib.decompressFile)
// 解析 EOCD + 中央目录: STORE(0) 直拷, DEFLATE(8) 用 node:zlib.inflateRawSync。
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import * as nodeZlib from 'node:zlib';

export async function harnessUnzip(absPath: string, tempDir: string): Promise<void> {
  const bytes = new Uint8Array(readFileSync(absPath));
  // 从尾部找 EOCD
  let eocd = -1;
  for (let i = bytes.length - 22; i >= 0; i--) {
    if (bytes[i] === 0x50 && bytes[i + 1] === 0x4b && bytes[i + 2] === 0x05 && bytes[i + 3] === 0x06) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    throw new Error('不是合法的 zip 文件(找不到 EOCD)');
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const entryCount = dv.getUint16(eocd + 10, true);
  const cdOffset = dv.getUint32(eocd + 16, true);
  let pos = cdOffset;
  for (let i = 0; i < entryCount; i++) {
    if (bytes[pos] !== 0x50 || bytes[pos + 1] !== 0x4b || bytes[pos + 2] !== 0x01 || bytes[pos + 3] !== 0x02) {
      throw new Error('中央目录损坏 @' + pos);
    }
    const method = dv.getUint16(pos + 10, true);
    const compSize = dv.getUint32(pos + 20, true);
    const nameLen = dv.getUint16(pos + 28, true);
    const extraLen = dv.getUint16(pos + 30, true);
    const commentLen = dv.getUint16(pos + 32, true);
    const localOffset = dv.getUint32(pos + 42, true);
    const name = new TextDecoder().decode(bytes.subarray(pos + 46, pos + 46 + nameLen));
    // 本地文件头
    const lhNameLen = dv.getUint16(localOffset + 26, true);
    const lhExtraLen = dv.getUint16(localOffset + 28, true);
    const dataStart = localOffset + 30 + lhNameLen + lhExtraLen;
    const raw = bytes.subarray(dataStart, dataStart + compSize);
    let data: Uint8Array;
    if (method === 0) {
      data = raw;
    } else if (method === 8) {
      data = new Uint8Array(nodeZlib.inflateRawSync(raw));
    } else {
      throw new Error('不支持的压缩方式 ' + method + ' (' + name + ')');
    }
    const outPath = tempDir + '/' + name;
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, data);
    pos += 46 + nameLen + extraLen + commentLen;
  }
}
