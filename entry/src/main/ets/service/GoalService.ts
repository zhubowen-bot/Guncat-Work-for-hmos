// GoalService: 会话级自主目标(对齐 DeepSeek Harness goal 包的工具面)
// 目标持久化到工作区 .goal.json, 随运行时快照注入, 供跨轮对齐任务意图。
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

// 目标状态: active(推进中) | paused | done | blocked
export class GoalItem {
  objective: string = '';
  status: string = 'active';
  rounds: number = 0;
  // 轮次上限(超过即暂停, 防失控保险)
  maxRounds: number = 40;
  note: string = '';
  createdAt: number = 0;
  updatedAt: number = 0;

  isActive(): boolean {
    return this.status === 'active' || this.status === 'blocked';
  }
}

export class GoalService {
  private static readonly FILE: string = '.goal.json';

  static read(root: string): GoalItem | null {
    try {
      let abs: string = root + '/' + GoalService.FILE;
      if (!fileIo.accessSync(abs)) {
        return null;
      }
      let stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.size <= 0) {
        return null;
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
      if (typeof parsed !== 'object' || parsed === null || parsed instanceof Array) {
        return null;
      }
      let rec: Record<string, Object> = parsed as Record<string, Object>;
      let goal: GoalItem = new GoalItem();
      goal.objective = (rec['objective'] as string) ?? '';
      goal.status = (rec['status'] as string) ?? 'active';
      goal.rounds = (rec['rounds'] as number) ?? 0;
      goal.maxRounds = (rec['maxRounds'] as number) ?? 40;
      goal.note = (rec['note'] as string) ?? '';
      goal.createdAt = (rec['createdAt'] as number) ?? 0;
      goal.updatedAt = (rec['updatedAt'] as number) ?? 0;
      if (goal.objective === '') {
        return null;
      }
      return goal;
    } catch (e) {
      return null;
    }
  }

  private static write(root: string, goal: GoalItem): void {
    let rec: Record<string, Object> = {
      'objective': goal.objective,
      'status': goal.status,
      'rounds': goal.rounds,
      'maxRounds': goal.maxRounds,
      'note': goal.note,
      'createdAt': goal.createdAt,
      'updatedAt': goal.updatedAt
    };
    let abs: string = root + '/' + GoalService.FILE;
    let encoder: util.TextEncoder = new util.TextEncoder();
    let bytes: Uint8Array = encoder.encode(JSON.stringify(rec));
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

  // 创建目标(已存在时覆盖为新一轮目标)
  static create(root: string, objective: string, maxRounds: number): GoalItem {
    let goal: GoalItem = new GoalItem();
    goal.objective = objective;
    goal.status = 'active';
    goal.rounds = 0;
    goal.maxRounds = maxRounds > 0 ? maxRounds : 40;
    goal.createdAt = Date.now();
    goal.updatedAt = Date.now();
    GoalService.write(root, goal);
    return goal;
  }

  // 更新状态/备注/轮次; 返回更新后的目标, 目标不存在返回 null
  static update(root: string, status: string, note: string, bumpRound: boolean): GoalItem | null {
    let goal: GoalItem | null = GoalService.read(root);
    if (goal === null) {
      return null;
    }
    if (status === 'active' || status === 'paused' || status === 'done' || status === 'blocked') {
      goal.status = status;
    }
    if (note !== '') {
      goal.note = note;
    }
    if (bumpRound) {
      goal.rounds++;
    }
    goal.updatedAt = Date.now();
    if (goal.rounds >= goal.maxRounds && goal.status === 'active') {
      goal.status = 'paused';
      goal.note = goal.note !== '' ? goal.note : '(已达轮次上限, 自动暂停)';
    }
    GoalService.write(root, goal);
    return goal;
  }

  // 渲染注入快照的文本
  static render(goal: GoalItem): string {
    let statusLabel: string = goal.status === 'active' ? '推进中' :
      (goal.status === 'paused' ? '已暂停' :
        (goal.status === 'done' ? '已完成' : '受阻'));
    let lines: string[] = [];
    lines.push('- 目标: ' + goal.objective);
    lines.push('  状态: ' + statusLabel + ' · 轮次 ' + goal.rounds.toString() + '/' +
      goal.maxRounds.toString() + (goal.note !== '' ? ' · 备注: ' + goal.note : ''));
    return lines.join('\n');
  }

  // 删除目标(随工作区清空自动消失; 工具也提供显式清空入口)
  static clear(root: string): void {
    try {
      let abs: string = root + '/' + GoalService.FILE;
      if (fileIo.accessSync(abs)) {
        fileIo.unlinkSync(abs);
      }
    } catch (e) {
      // ignore
    }
  }
}
