// SessionLogService: 工作模式会话事件日志(对齐 DeepSeek Harness 的 append-only session log)
// 每个会话一个 JSONL 文件: <filesDir>/sessions/<convId>.jsonl, 首行 header, 其余为事件。
// "进入模型请求的都要留痕" —— 事件在写盘后才有资格进入后续请求, 崩溃后可据日志恢复/审计;
// session_search 工具据此检索历史。轻量追加写, 与 Preferences 会话存档( UI 状态)互补。
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Constants } from '../common/Constants';
import { OrphanSweep } from '../common/OrphanSweep';

export class SessionLogService {
  private static openFiles: Map<string, fileIo.File> = new Map();

  private static filePath(context: common.UIAbilityContext, convId: string): string {
    let safe: string = SessionLogService.logName(convId);
    return context.filesDir + '/' + Constants.WORK_SESSIONS_DIR + '/' + safe + '.jsonl';
  }

  // 追加一条事件(JSON 对象序列化为单行); 写入失败静默(日志不能拖垮主流程)
  static append(context: common.UIAbilityContext, convId: string,
    type: string, payload: Record<string, Object>): void {
    try {
      let abs: string = SessionLogService.filePath(context, convId);
      let file: fileIo.File | undefined = SessionLogService.openFiles.get(convId);
      if (file === undefined) {
        let dir: string = context.filesDir + '/' + Constants.WORK_SESSIONS_DIR;
        if (!fileIo.accessSync(dir)) {
          fileIo.mkdirSync(dir, true);
        }
        file = fileIo.openSync(abs,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
        SessionLogService.openFiles.set(convId, file);
        // 新文件写 header
        let header: Record<string, Object> = {
          'type': 'session',
          'version': 1,
          'id': convId,
          'createdAt': Date.now()
        };
        SessionLogService.writeLine(file, header);
      }
      let event: Record<string, Object> = { 'type': type, 'ts': Date.now() };
      let keys: string[] = Object.keys(payload);
      for (let i: number = 0; i < keys.length; i++) {
        event[keys[i]] = payload[keys[i]];
      }
      SessionLogService.writeLine(file, event);
    } catch (e) {
      // 日志失败不影响主流程
    }
  }

  private static writeLine(file: fileIo.File, obj: Record<string, Object>): void {
    let encoder: util.TextEncoder = new util.TextEncoder();
    let bytes: Uint8Array = encoder.encode(JSON.stringify(obj) + '\n');
    let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
    if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
      buffer = bytes.slice().buffer as ArrayBuffer;
    }
    fileIo.writeSync(file.fd, buffer);
  }

  // 读取指定会话的日志全文(会话日志检索工具用); 上限 2MB
  static readAll(context: common.UIAbilityContext, convId: string): string {
    try {
      let abs: string = SessionLogService.filePath(context, convId);
      if (!fileIo.accessSync(abs)) {
        return '';
      }
      let stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.size <= 0) {
        return '';
      }
      let readLen: number = stat.size < 2 * 1024 * 1024 ? stat.size : 2 * 1024 * 1024;
      let buffer: ArrayBuffer = new ArrayBuffer(readLen);
      let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buffer, { offset: 0 });
      } finally {
        fileIo.closeSync(file.fd);
      }
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(new Uint8Array(buffer), { stream: false });
    } catch (e) {
      return '';
    }
  }

  // 会话关闭/删除时释放句柄并可选删除日志
  static close(context: common.UIAbilityContext, convId: string, deleteLog: boolean): void {
    let file: fileIo.File | undefined = SessionLogService.openFiles.get(convId);
    if (file !== undefined) {
      try {
        fileIo.closeSync(file);
      } catch (e) {
        // ignore
      }
      SessionLogService.openFiles.delete(convId);
    }
    if (deleteLog) {
      try {
        let abs: string = SessionLogService.filePath(context, convId);
        if (fileIo.accessSync(abs)) {
          fileIo.unlinkSync(abs);
        }
      } catch (e) {
        // ignore
      }
    }
  }

  // 会话 id 在磁盘上的文件名(不含 .jsonl); 启动清扫按同一口径换算存活会话
  static logName(convId: string): string {
    return convId.replace(/[^A-Za-z0-9_-]/g, '_');
  }

  // 启动清扫: 删掉没有对应会话的事件日志(与工作区同一口径, 见 WorkFileService.gcOrphanWorkspaces)。
  // 返回删掉的份数; 单个失败只跳过。
  static gcOrphans(context: common.UIAbilityContext, liveConvIds: string[]): number {
    let dir: string = context.filesDir + '/' + Constants.WORK_SESSIONS_DIR;
    if (!fileIo.accessSync(dir)) {
      return 0;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return 0;
    }
    let ids: string[] = [];
    for (let i: number = 0; i < names.length; i++) {
      let name: string = names[i];
      if (!name.endsWith('.jsonl')) {
        continue;
      }
      ids.push(name.substring(0, name.length - '.jsonl'.length));
    }
    let live: string[] = [];
    for (let i: number = 0; i < liveConvIds.length; i++) {
      live.push(SessionLogService.logName(liveConvIds[i]));
    }
    let orphans: string[] = OrphanSweep.orphans(ids, live);
    let removed: number = 0;
    for (let i: number = 0; i < orphans.length; i++) {
      let abs: string = dir + '/' + orphans[i] + '.jsonl';
      // 先把可能还开着的句柄关掉(孤儿不该有, 但崩溃恢复后可能残留)
      let file: fileIo.File | undefined = SessionLogService.openFiles.get(orphans[i]);
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // ignore
        }
        SessionLogService.openFiles.delete(orphans[i]);
      }
      try {
        if (fileIo.accessSync(abs)) {
          fileIo.unlinkSync(abs);
          removed++;
        }
      } catch (e) {
        // 单个失败不影响其它
      }
    }
    return removed;
  }
}
