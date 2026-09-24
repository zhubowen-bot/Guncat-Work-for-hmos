// ScheduleService: 会话级定时提醒(对齐 DeepSeek Harness schedule 包的工具面)
// 提醒持久化到工作区 .schedule.json; 到期后由 ChatViewModel 的调度回调注入为下一条用户消息。
// 每秒由宿主调用 tick()(工作模式计时器复用), 到期项触发 onFire 回调并按规则移除/续期。
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Constants } from '../common/Constants';

// 一条提醒
export class ScheduleItem {
  id: string = '';
  message: string = '';
  // 绝对到期时间戳(毫秒); 循环提醒每次触发后向后滚动
  dueAt: number = 0;
  // 循环间隔秒(0 表示一次性)
  everySeconds: number = 0;
  createdAt: number = 0;
}

export class ScheduleService {
  private static readonly FILE: string = '.schedule.json';

  // 读取全部提醒(文件损坏/不存在返回空数组)
  static list(root: string): ScheduleItem[] {
    try {
      let abs: string = root + '/' + ScheduleService.FILE;
      if (!fileIo.accessSync(abs)) {
        return [];
      }
      let stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.size <= 0) {
        return [];
      }
      let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buffer, { offset: 0 });
      } finally {
        fileIo.closeSync(file.fd);
      }
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      let json: string = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
      let parsed: Object = JSON.parse(json);
      if (!(parsed instanceof Array)) {
        return [];
      }
      let arr: Object[] = parsed as Object[];
      let out: ScheduleItem[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        let rec: Record<string, Object> = arr[i] as Record<string, Object>;
        let item: ScheduleItem = new ScheduleItem();
        item.id = (rec['id'] as string) ?? '';
        item.message = (rec['message'] as string) ?? '';
        item.dueAt = (rec['dueAt'] as number) ?? 0;
        item.everySeconds = (rec['everySeconds'] as number) ?? 0;
        item.createdAt = (rec['createdAt'] as number) ?? 0;
        if (item.id !== '' && item.message !== '') {
          out.push(item);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private static save(root: string, items: ScheduleItem[]): void {
    let arr: Object[] = [];
    for (let i: number = 0; i < items.length; i++) {
      let it: ScheduleItem = items[i];
      let rec: Record<string, Object> = {
        'id': it.id,
        'message': it.message,
        'dueAt': it.dueAt,
        'everySeconds': it.everySeconds,
        'createdAt': it.createdAt
      };
      arr.push(rec);
    }
    let abs: string = root + '/' + ScheduleService.FILE;
    let encoder: util.TextEncoder = new util.TextEncoder();
    let bytes: Uint8Array = encoder.encode(JSON.stringify(arr));
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
  }

  // 新建提醒: atMs(绝对到期) 或 everySeconds(相对 + 循环, 有最小间隔)
  static create(root: string, message: string, atMs: number,
    everySeconds: number): ScheduleItem | null {
    let items: ScheduleItem[] = ScheduleService.list(root);
    if (items.length >= Constants.WORK_SCHEDULE_MAX) {
      return null;
    }
    let item: ScheduleItem = new ScheduleItem();
    item.id = 'sch_' + Date.now().toString() + '_' + Math.floor(Math.random() * 100000).toString();
    item.message = message;
    item.createdAt = Date.now();
    if (everySeconds > 0) {
      let interval: number = Math.max(everySeconds, Constants.WORK_SCHEDULE_MIN_EVERY_SEC);
      item.everySeconds = interval;
      item.dueAt = Date.now() + interval * 1000;
    } else {
      item.everySeconds = 0;
      item.dueAt = atMs > 0 ? atMs : Date.now();
    }
    items.push(item);
    ScheduleService.save(root, items);
    return item;
  }

  // 取消提醒; 返回是否删除成功
  static remove(root: string, id: string): boolean {
    let items: ScheduleItem[] = ScheduleService.list(root);
    let kept: ScheduleItem[] = [];
    let removed: boolean = false;
    for (let i: number = 0; i < items.length; i++) {
      if (items[i].id === id) {
        removed = true;
      } else {
        kept.push(items[i]);
      }
    }
    if (removed) {
      ScheduleService.save(root, kept);
    }
    return removed;
  }

  // 渲染清单文本(schedule_list / 运行时快照共用)
  static renderList(items: ScheduleItem[]): string {
    if (items.length === 0) {
      return '(无提醒)';
    }
    let lines: string[] = [];
    for (let i: number = 0; i < items.length; i++) {
      let it: ScheduleItem = items[i];
      let remainMs: number = it.dueAt - Date.now();
      let remainMin: number = Math.max(0, Math.round(remainMs / 60000));
      let kind: string = it.everySeconds > 0 ?
        '每 ' + it.everySeconds.toString() + ' 秒' : '一次性';
      lines.push((i + 1).toString() + '. [' + it.id + '] ' + kind +
        ' · ' + remainMin.toString() + ' 分钟后到期 · ' + it.message);
    }
    return lines.join('\n');
  }

  // 推进到期检查: 到期项经 onFire 上抛, 一次性移除, 循环项滚动到下一周期
  static tick(root: string, onFire: (message: string) => void): void {
    let items: ScheduleItem[] = ScheduleService.list(root);
    if (items.length === 0) {
      return;
    }
    let now: number = Date.now();
    let kept: ScheduleItem[] = [];
    let changed: boolean = false;
    for (let i: number = 0; i < items.length; i++) {
      let it: ScheduleItem = items[i];
      if (it.dueAt > now) {
        kept.push(it);
        continue;
      }
      onFire(it.message);
      changed = true;
      if (it.everySeconds > 0) {
        // 循环提醒滚动到下一周期(追平欠账, 防止休眠后连发)
        let interval: number = it.everySeconds * 1000;
        while (it.dueAt <= now) {
          it.dueAt += interval;
        }
        kept.push(it);
      }
    }
    if (changed) {
      ScheduleService.save(root, kept);
    }
  }
}
