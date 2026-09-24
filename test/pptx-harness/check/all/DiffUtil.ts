// DiffUtil: 行级 diff 计算(对齐 DeepSeek Harness tool-fs/diff.ts 的 computeHunkDiffs)
// edit / str_replace_editor 工具把改动 hunks 附在结果 meta 里, UI 据此渲染 dsh 风格的 diff 卡片。
// 纯逻辑模块, 不依赖设备 API, 可在桌面 Node 端验证(test/guncat-harness)。
import { Constants } from './Constants.ts';

// diff 行: same=上下文, del=删除, add=新增
export class DiffLine {
  type: string = 'same'; // 'same' | 'del' | 'add'
  text: string = '';

  static of(type: string, text: string): DiffLine {
    let l: DiffLine = new DiffLine();
    l.type = type;
    l.text = text;
    return l;
  }
}

// 一个改动块: 上下文 + 删/增行
export class DiffHunk {
  lines: DiffLine[] = [];
  header: string = ''; // '@@ -a,b +c,d @@'

  static empty(): DiffHunk {
    return new DiffHunk();
  }
}

// 文件级 diff 结果(挂在工具结果 meta 中持久化, UI 重放渲染)
export class FileDiff {
  path: string = '';
  hunks: DiffHunk[] = [];
  adds: number = 0;
  dels: number = 0;
  truncated: boolean = false; // 展示行数超上限被折叠

  static empty(): FileDiff {
    return new FileDiff();
  }

  // 序列化为可 JSON 持久的普通对象
  toJsonObject(): Record<string, Object> {
    let hunkArr: Object[] = [];
    for (let i: number = 0; i < this.hunks.length; i++) {
      let h: DiffHunk = this.hunks[i];
      let lineArr: Object[] = [];
      for (let j: number = 0; j < h.lines.length; j++) {
        let line: Record<string, Object> = { 't': h.lines[j].type, 'x': h.lines[j].text };
        lineArr.push(line);
      }
      let hunk: Record<string, Object> = { 'header': h.header, 'lines': lineArr };
      hunkArr.push(hunk);
    }
    return {
      'path': this.path,
      'hunks': hunkArr,
      'adds': this.adds,
      'dels': this.dels,
      'truncated': this.truncated
    };
  }

  // 反序列化(UI 重放)
  static fromJson(json: Record<string, Object>): FileDiff {
    let d: FileDiff = new FileDiff();
    d.path = (json['path'] as string) ?? '';
    d.adds = (json['adds'] as number) ?? 0;
    d.dels = (json['dels'] as number) ?? 0;
    d.truncated = (json['truncated'] as boolean) ?? false;
    let rawHunks: Object | undefined = json['hunks'];
    if (rawHunks !== undefined && rawHunks instanceof Array) {
      let arr: Object[] = rawHunks as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        let hr: Record<string, Object> = arr[i] as Record<string, Object>;
        let hunk: DiffHunk = DiffHunk.empty();
        hunk.header = (hr['header'] as string) ?? '';
        let rawLines: Object | undefined = hr['lines'];
        if (rawLines !== undefined && rawLines instanceof Array) {
          let lines: Object[] = rawLines as Object[];
          for (let j: number = 0; j < lines.length; j++) {
            let lr: Record<string, Object> = lines[j] as Record<string, Object>;
            hunk.lines.push(DiffLine.of((lr['t'] as string) ?? 'same', (lr['x'] as string) ?? ''));
          }
        }
        d.hunks.push(hunk);
      }
    }
    return d;
  }
}

// LCS 行级 diff(经典 DP; 行数过大时退化为截断对比, 防止 O(n²) 卡死主线程)
export class DiffUtil {
  private static readonly MAX_LCS_ROWS: number = 2000;
  private static readonly MAX_LCS_COLS: number = 2000;

  // 计算两个文本的 diff hunks; context 为每个 hunk 前后保留的上下文行数
  static computeFileDiff(oldText: string, newText: string, path: string,
    context: number): FileDiff {
    let result: FileDiff = FileDiff.empty();
    result.path = path;
    let oldLines: string[] = oldText.length === 0 ? [] : oldText.split('\n');
    let newLines: string[] = newText.length === 0 ? [] : newText.split('\n');
    // 超大文件: 不做全量 LCS, 用最小可见对比(全部按删除+新增处理)
    if (oldLines.length > DiffUtil.MAX_LCS_ROWS || newLines.length > DiffUtil.MAX_LCS_COLS) {
      for (let i: number = 0; i < oldLines.length; i++) {
        // 大文件 diff 不展示逐行内容, 仅计数
      }
      result.dels = oldLines.length;
      result.adds = newLines.length;
      result.truncated = true;
      let hunk: DiffHunk = DiffHunk.empty();
      hunk.header = '@@ 文件过大, 仅显示统计 @@';
      hunk.lines.push(DiffLine.of('del', '(原文件共 ' + oldLines.length.toString() + ' 行)'));
      hunk.lines.push(DiffLine.of('add', '(新文件共 ' + newLines.length.toString() + ' 行)'));
      result.hunks.push(hunk);
      return result;
    }
    // LCS 长度表(滚动行省内存: 保留全表以便回溯, 2000x2000 = 4M entries 以内可接受)
    let n: number = oldLines.length;
    let m: number = newLines.length;
    let table: Int32Array = new Int32Array((n + 1) * (m + 1));
    let idx: (r: number, c: number) => number = (r: number, c: number): number => {
      return r * (m + 1) + c;
    };
    for (let i: number = n - 1; i >= 0; i--) {
      for (let j: number = m - 1; j >= 0; j--) {
        if (oldLines[i] === newLines[j]) {
          table[idx(i, j)] = table[idx(i + 1, j + 1)] + 1;
        } else {
          let down: number = table[idx(i + 1, j)];
          let right: number = table[idx(i, j + 1)];
          table[idx(i, j)] = down >= right ? down : right;
        }
      }
    }
    // 回溯生成完整行序列
    let seq: DiffLine[] = [];
    let i2: number = 0;
    let j2: number = 0;
    while (i2 < n && j2 < m) {
      if (oldLines[i2] === newLines[j2]) {
        seq.push(DiffLine.of('same', newLines[j2]));
        i2++;
        j2++;
      } else if (table[idx(i2 + 1, j2)] >= table[idx(i2, j2 + 1)]) {
        seq.push(DiffLine.of('del', oldLines[i2]));
        i2++;
      } else {
        seq.push(DiffLine.of('add', newLines[j2]));
        j2++;
      }
    }
    while (i2 < n) {
      seq.push(DiffLine.of('del', oldLines[i2]));
      i2++;
    }
    while (j2 < m) {
      seq.push(DiffLine.of('add', newLines[j2]));
      j2++;
    }
    // 统计 + 分组为 hunks(带上下文)
    let adds: number = 0;
    let dels: number = 0;
    for (let i: number = 0; i < seq.length; i++) {
      if (seq[i].type === 'add') {
        adds++;
      } else if (seq[i].type === 'del') {
        dels++;
      }
    }
    result.adds = adds;
    result.dels = dels;
    let ctx: number = context < 0 ? 0 : context;
    // 标记每个改动行在 seq 中的位置, 扩展 ctx 形成 [start, end) 区间后合并重叠区间
    let ranges: number[][] = [];
    for (let i: number = 0; i < seq.length; i++) {
      if (seq[i].type !== 'same') {
        let start: number = Math.max(0, i - ctx);
        let end: number = Math.min(seq.length, i + ctx + 1);
        ranges.push([start, end]);
      }
    }
    let merged: number[][] = [];
    for (let i: number = 0; i < ranges.length; i++) {
      let last: number[] | null = merged.length > 0 ? merged[merged.length - 1] : null;
      if (last !== null && ranges[i][0] <= last[1]) {
        last[1] = Math.max(last[1], ranges[i][1]);
      } else {
        merged.push([ranges[i][0], ranges[i][1]]);
      }
    }
    // 展示行数上限: 超出则只保留前几个 hunk 并折叠
    let budget: number = Constants.WORK_DIFF_MAX_LINES;
    for (let i: number = 0; i < merged.length; i++) {
      let start: number = merged[i][0];
      let end: number = merged[i][1];
      if (budget <= 0) {
        result.truncated = true;
        break;
      }
      let hunk: DiffHunk = DiffHunk.empty();
      let delInHunk: number = 0;
      let addInHunk: number = 0;
      for (let j: number = start; j < end; j++) {
        if (budget <= 0) {
          result.truncated = true;
          break;
        }
        hunk.lines.push(seq[j]);
        if (seq[j].type === 'add') {
          addInHunk++;
        } else if (seq[j].type === 'del') {
          delInHunk++;
        }
        budget--;
      }
      hunk.header = '@@ -' + delInHunk.toString() + ' +' + addInHunk.toString() + ' @@';
      result.hunks.push(hunk);
    }
    return result;
  }

  // 渲染为 dsh diff 卡片同构的纯文本(工具结果正文用; UI 优先用 meta 结构化渲染)
  static renderPlain(diff: FileDiff): string {
    let lines: string[] = [];
    for (let i: number = 0; i < diff.hunks.length; i++) {
      let h: DiffHunk = diff.hunks[i];
      for (let j: number = 0; j < h.lines.length; j++) {
        let l: DiffLine = h.lines[j];
        if (l.type === 'add') {
          lines.push('+ ' + l.text);
        } else if (l.type === 'del') {
          lines.push('- ' + l.text);
        } else {
          lines.push('  ' + l.text);
        }
      }
    }
    return lines.join('\n');
  }
}
