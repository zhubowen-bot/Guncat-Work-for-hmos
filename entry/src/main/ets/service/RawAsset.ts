// RawAsset: 把 rawfile 里的大资源(python312.zip、extras 等)分块释放到沙箱。
// 整个读进内存会顶出峰值, 所以流式拷贝。
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'RawAsset';

export class RawAsset {
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
