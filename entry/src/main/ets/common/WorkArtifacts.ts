// WorkArtifacts: 从工作模式消息的工具调用记录中汇总“生成/改动的文件”。
// 该模块只做纯数据推导, 不依赖设备 API; 结果用于对话流末尾的 Codex 风格产物卡片。
import { Message } from '../model/Message';
import { ToolCallRecord } from '../model/ToolCallRecord';
import { FileDiff, DiffHunk, DiffLine } from './DiffUtil';

// 单个产物/改动文件
export class WorkArtifactFile {
  path: string = '';
  // 结构化 diff(可能为 null: 二进制/Office 产物或旧消息没有 meta)
  diff: FileDiff | null = null;
  // 是否有可用于缩略展示的行级 diff
  hasDiff: boolean = false;
  // 总新增/删除行数(无 diff 时为 0)
  adds: number = 0;
  dels: number = 0;

  static empty(): WorkArtifactFile {
    return new WorkArtifactFile();
  }
}

// 汇总结果
export class WorkArtifactSummary {
  files: WorkArtifactFile[] = [];
  totalAdds: number = 0;
  totalDels: number = 0;

  static empty(): WorkArtifactSummary {
    return new WorkArtifactSummary();
  }
}

// 会改动工作区文件的工具名
const MUTATING_TOOLS: string[] = [
  'write_file', 'append_file', 'delete_file', 'move_file',
  'write_docx', 'edit_docx', 'write_xlsx', 'edit_xlsx',
  'write_pptx', 'edit_ppt', 'write_csv', 'write_svg',
  'download_file', 'transform_file', 'edit', 'str_replace_editor'
];

export class WorkArtifactUtil {
  // 从会话消息中提取全部改动文件, 同一文件多次改动时按顺序合并 hunks 与统计
  static collect(messages: Message[]): WorkArtifactSummary {
    let summary: WorkArtifactSummary = WorkArtifactSummary.empty();
    let map: Map<string, WorkArtifactFile> = new Map<string, WorkArtifactFile>();
    for (let i: number = 0; i < messages.length; i++) {
      let msg: Message = messages[i];
      if (msg.role !== 'assistant') {
        continue;
      }
      let calls: ToolCallRecord[] = msg.toolCalls;
      for (let j: number = 0; j < calls.length; j++) {
        let call: ToolCallRecord = calls[j];
        if (call.durationMs < 0 || call.isError) {
          continue;
        }
        if (MUTATING_TOOLS.indexOf(call.name) < 0) {
          continue;
        }
        let path: string = WorkArtifactUtil.pathFromCall(call);
        if (path === '' || path === '.') {
          continue;
        }
        // 删除文件/目录不在“可预览产物”中展示
        if (call.name === 'delete_file') {
          continue;
        }
        let existing: WorkArtifactFile | undefined = map.get(path);
        if (existing === undefined) {
          existing = WorkArtifactFile.empty();
          existing.path = path;
          map.set(path, existing);
          summary.files.push(existing);
        }
        let diff: FileDiff | null = WorkArtifactUtil.parseDiffMeta(call);
        if (diff !== null) {
          existing.hasDiff = true;
          if (existing.diff === null) {
            existing.diff = diff;
          } else {
            WorkArtifactUtil.mergeDiff(existing.diff, diff);
          }
          existing.adds = existing.diff.adds;
          existing.dels = existing.diff.dels;
        }
      }
    }
    for (let k: number = 0; k < summary.files.length; k++) {
      summary.totalAdds += summary.files[k].adds;
      summary.totalDels += summary.files[k].dels;
    }
    return summary;
  }

  // 解析工具调用里代表输出文件的相对路径
  static pathFromCall(call: ToolCallRecord): string {
    let args: Record<string, Object> | null = WorkArtifactUtil.parseArgs(call.argsJson);
    if (args === null) {
      return '';
    }
    if (call.name === 'move_file') {
      return WorkArtifactUtil.strArg(args, 'to');
    }
    if (call.name === 'transform_file') {
      let out: string = WorkArtifactUtil.strArg(args, 'output');
      return out !== '' ? out : '';
    }
    return WorkArtifactUtil.strArg(args, 'path');
  }

  // 解析 tool call meta 中的 FileDiff JSON
  static parseDiffMeta(call: ToolCallRecord): FileDiff | null {
    if (call.meta === '') {
      return null;
    }
    try {
      let parsed: Object = JSON.parse(call.meta);
      if (typeof parsed === 'object' && parsed !== null) {
        return FileDiff.fromJson(parsed as Record<string, Object>);
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  // 把同一文件的后续 diff 合并到已有 diff 中(按时间顺序追加 hunks, 累计统计)
  private static mergeDiff(target: FileDiff, incoming: FileDiff): void {
    for (let i: number = 0; i < incoming.hunks.length; i++) {
      let hunk: DiffHunk = DiffHunk.empty();
      hunk.header = incoming.hunks[i].header;
      let lines = incoming.hunks[i].lines;
      for (let j: number = 0; j < lines.length; j++) {
        hunk.lines.push(DiffLine.of(lines[j].type, lines[j].text));
      }
      target.hunks.push(hunk);
    }
    target.adds += incoming.adds;
    target.dels += incoming.dels;
    target.truncated = target.truncated || incoming.truncated;
  }

  private static parseArgs(argsJson: string): Record<string, Object> | null {
    if (argsJson.trim() === '') {
      return null;
    }
    try {
      let parsed: Object = JSON.parse(argsJson);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  private static strArg(args: Record<string, Object>, key: string): string {
    let v: Object = args[key];
    if (typeof v === 'string') {
      return v as string;
    }
    return '';
  }
}

