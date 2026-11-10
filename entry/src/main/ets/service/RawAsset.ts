// RawAsset: 把 rawfile 里的大资源(python312.zip、extras 等)分块释放到沙箱。
// 整个读进内存会顶出峰值, 所以流式拷贝。
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'RawAsset';

export class RawAsset {
  /**
   * 异步版释放: 首次调用 run_python 时要在沙箱里落地标准库/三方库 zip,
   * 同步拷贝十几 MB 会把 UI 线程卡住(实机主线程阻塞 6s 会被系统杀掉)。
   * 大文件走 fs 的 Promise 接口, 每块之间让出事件循环。
   */
  static async extractAsync(context: common.UIAbilityContext, rawPath: string,
    dstPath: string): Promise<number> {
    let desc: resourceManager.RawFileDescriptor = await context.resourceManager.getRawFd(rawPath);
    let dst: fileIo.File | null = null;
    try {
      dst = await fileIo.open(dstPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      let chunk: number = 1024 * 1024;
      let buffer: ArrayBuffer = new ArrayBuffer(chunk);
      let pos: number = 0;
      while (pos < desc.length) {
        let want: number = Math.min(chunk, desc.length - pos);
        let readLen: number = await fileIo.read(desc.fd, buffer,
          { offset: desc.offset + pos, length: want });
        if (readLen <= 0) {
          break;
        }
        await fileIo.write(dst.fd, buffer, { offset: pos, length: readLen });
        pos += readLen;
      }
      if (pos !== desc.length) {
        throw new Error('rawfile 释放不完整: ' + rawPath + ' 期望 ' + desc.length.toString() +
          ' 字节, 实际 ' + pos.toString());
      }
      hilog.info(DOMAIN, TAG, 'extracted %{public}s (%{public}d bytes)', rawPath, pos);
      return pos;
    } finally {
      if (dst !== null) {
        await fileIo.close(dst);
      }
      await context.resourceManager.closeRawFd(rawPath);
    }
  }

  // 返回写入字节数; 失败抛异常(调用方转成可读错误)
  static extract(context: common.UIAbilityContext, rawPath: string, dstPath: string): number {
    let desc: resourceManager.RawFileDescriptor = context.resourceManager.getRawFdSync(rawPath);
    let dst: fileIo.File | null = null;
    try {
      dst = fileIo.openSync(dstPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      let chunk: number = 1024 * 1024;
      let buffer: ArrayBuffer = new ArrayBuffer(chunk);
      let pos: number = 0;
      while (pos < desc.length) {
        let want: number = Math.min(chunk, desc.length - pos);
        let readLen: number = fileIo.readSync(desc.fd, buffer, { offset: desc.offset + pos, length: want });
        if (readLen <= 0) {
          break;
        }
        fileIo.writeSync(dst.fd, buffer, { offset: pos, length: readLen });
        pos += readLen;
      }
      if (pos !== desc.length) {
        throw new Error('rawfile 释放不完整: ' + rawPath + ' 期望 ' + desc.length.toString() +
          ' 字节, 实际 ' + pos.toString());
      }
      hilog.info(DOMAIN, TAG, 'extracted %{public}s (%{public}d bytes)', rawPath, pos);
      return pos;
    } finally {
      if (dst !== null) {
        fileIo.closeSync(dst);
      }
      context.resourceManager.closeRawFdSync(rawPath);
    }
  }
}
