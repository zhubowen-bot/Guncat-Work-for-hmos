// Node 运行时 @kit.CoreFileKit/@kit.ArkTS 桩(供移植的 DocxImporter 运行)
// 仅实现 DocxImporter 用到的 API: fileIo 的 access/mkdir/stat/list/rmdir/unlink/open/read/write/close + util.TextDecoder。
import * as nodeFs from 'node:fs';

const fdPaths: Map<number, string> = new Map();
let fdCounter: number = 100;

class StatShim {
  size: number;
  isDir: boolean;
  constructor(size: number, isDir: boolean) {
    this.size = size;
    this.isDir = isDir;
  }
  isDirectory(): boolean {
    return this.isDir;
  }
}

const OpenMode = {
  READ_ONLY: 0,
  READ_WRITE: 1,
  CREATE: 2,
  TRUNC: 4
};

class TextDecoderImpl {
  private dec: any;
  static create(_encoding: string, _opts?: object): TextDecoderImpl {
    return new TextDecoderImpl();
  }
  constructor() {
    // @ts-ignore Node 18+ 全局可用
    this.dec = new TextDecoder('utf-8');
  }
  decodeToString(input: Uint8Array, _opts?: { stream: boolean }): string {
    return this.dec.decode(input);
  }
}

export const util = { TextDecoder: TextDecoderImpl };

export const fileIo = {
  OpenMode,
  accessSync(path: string): boolean {
    try {
      nodeFs.accessSync(path);
      return true;
    } catch (_e) {
      return false;
    }
  },
  mkdirSync(path: string, recursive?: boolean): void {
    nodeFs.mkdirSync(path, { recursive: recursive === true });
  },
  statSync(path: string): StatShim {
    const st = nodeFs.statSync(path);
    return new StatShim(st.size, st.isDirectory());
  },
  listFileSync(path: string): string[] {
    return nodeFs.readdirSync(path);
  },
  rmdirSync(path: string): void {
    nodeFs.rmdirSync(path);
  },
  unlinkSync(path: string): void {
    nodeFs.unlinkSync(path);
  },
  openSync(path: string, _mode: number): { fd: number } {
    const fd = fdCounter++;
    fdPaths.set(fd, path);
    return { fd };
  },
  readSync(fd: number, buffer: ArrayBuffer, _opts: { offset: number }): number {
    const path = fdPaths.get(fd);
    if (path === undefined) {
      throw new Error('bad fd ' + fd);
    }
    const data = nodeFs.readFileSync(path);
    const view = new Uint8Array(buffer);
    view.set(data.subarray(0, view.length));
    return Math.min(data.length, view.length);
  },
  writeSync(fd: number, buffer: ArrayBuffer): number {
    const path = fdPaths.get(fd);
    if (path === undefined) {
      throw new Error('bad fd ' + fd);
    }
    nodeFs.writeFileSync(path, Buffer.from(new Uint8Array(buffer)));
    return buffer.byteLength;
  },
  closeSync(fileOrFd: { fd: number } | number): void {
    const fd = typeof fileOrFd === 'number' ? fileOrFd : fileOrFd.fd;
    fdPaths.delete(fd);
  }
};
