// SpillStore: 工具结果溢出暂存(对齐 DeepSeek Harness 的 spill 包)
// 超过送回字符上限的工具结果全文落盘到工作区 .spill/, 模型侧只收头尾节选 + 定位提示,
// 需要原文时用 read_file 读回 —— "截断不丢失" 是 dsh 的核心原则之一。
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Constants } from './Constants.ts';

export class SpillStore {
  private static seq: number = 0;

  // 保存全文, 返回工作区相对路径(如 .spill/turn3_write_file_1712.txt); 失败返回空串
  static save(root: string, label: string, content: string): string {
    try {
      let dir: string = root + '/' + Constants.WORK_SPILL_DIR;
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      let safeLabel: string = label.replace(/[^A-Za-z0-9_-]/g, '_');
      if (safeLabel.length > 40) {
        safeLabel = safeLabel.substring(0, 40);
      }
      let name: string = safeLabel + '_' + Date.now().toString() + '_' +
        (SpillStore.seq++).toString() + '.txt';
      let abs: string = dir + '/' + name;
      let encoder: util.TextEncoder = new util.TextEncoder();
      let bytes: Uint8Array = encoder.encode(content);
      let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
      if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
        buffer = bytes.slice().buffer as ArrayBuffer;
      }
      let file: fileIo.File = fileIo.openSync(abs,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buffer);
      } finally {
        fileIo.closeSync(file.fd);
      }
      return Constants.WORK_SPILL_DIR + '/' + name;
    } catch (e) {
      return '';
    }
  }

  // 头尾截断: 超长文本保留头/尾, 中间标注省略与完整结果定位
  static truncateWithLocator(output: string, spillRel: string): string {
    let head: number = Constants.WORK_SPILL_HEAD_CHARS;
    let tail: number = Constants.WORK_SPILL_TAIL_CHARS;
    if (output.length <= head + tail) {
      return output;
    }
    let omitted: number = output.length - head - tail;
    let headPart: string = output.substring(0, head);
    let tailPart: string = output.substring(output.length - tail);
    let locator: string = spillRel === '' ?
      '(完整结果未能暂存)' :
      '(完整结果已保存到工作区文件 ' + spillRel + ', 可用 read_file 分段读取)';
    return headPart + '\n\n…[中间省略 ' + omitted.toString() + ' 字符, ' + locator + ' …]\n\n' + tailPart;
  }
}
