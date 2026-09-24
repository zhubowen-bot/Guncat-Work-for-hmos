// HarnessTools: Guncat Work 6.1 新增工具集(DeepSeek Harness 移植)
// glob/grep(纯 TS 正则搜索, 对齐 tool-fs-search) / edit+str_replace_editor(对齐 tool-fs 与
// str-replace-editor) / web_fetch(对齐 web-fetch-http) / ask_user_question(对齐 ask-user) /
// schedule_*/goal_*(会话级提醒与目标) / subagent(进程内嵌套代理) / session_search(事件日志检索) /
// run_js(JSVM-API 沙箱, 见 JsCodeService —— 无 shell 环境下的"执行代码"能力)。
// 与 WorkFileService 的既有 25 工具并存; dispatch 由 WorkFileService 兜底转发至此。
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { PathMatcher } from './PathMatcher.ts';
import { FileSearchCore, FsAdapter, GrepOptions, GlobHit, GrepHit } from './FileSearchCore.ts';
import { DiffUtil, FileDiff } from './DiffUtil.ts';
import { EditCore, EditOutcome } from './EditCore.ts';
import { AskUserBridge, AskAnswer } from './AskUserBridge.ts';
import { ScheduleService, ScheduleItem } from './ScheduleService.ts';
import { GoalService, GoalItem } from './GoalService.ts';
import { WebFetchService } from './WebFetchService.ts';
import { SessionLogService } from './SessionLogService.ts';
import { JsCodeService } from './JsCodeService.ts';
import { ToolExecResult, WorkFileService } from './WorkFileService.ts';
import { Constants } from './Constants.ts';
import { AbortSignal } from './Types.ts';

// ===== 设备侧 FsAdapter(fileIo 实现) =====

class DeviceFsAdapter implements FsAdapter {
  list(dirPath: string): string[] {
    try {
      if (!fileIo.accessSync(dirPath) || !fileIo.statSync(dirPath).isDirectory()) {
        return [];
      }
      return fileIo.listFileSync(dirPath);
    } catch (e) {
      return [];
    }
  }

  isDir(path: string): boolean {
    try {
      return fileIo.accessSync(path) && fileIo.statSync(path).isDirectory();
    } catch (e) {
      return false;
    }
  }

  readText(path: string, maxBytes: number): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      let stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.isDirectory() || stat.size === 0 || stat.size > maxBytes) {
        return '';
      }
      if (!HarnessTools.isTextFileName(path)) {
        return '';
      }
      let readLen: number = stat.size < maxBytes ? stat.size : maxBytes;
      let buffer: ArrayBuffer = new ArrayBuffer(readLen);
      let file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buffer, { offset: 0 });
      } finally {
        fileIo.closeSync(file.fd);
      }
      let bytes: Uint8Array = new Uint8Array(buffer);
      if (HarnessTools.looksBinary(bytes)) {
        return '';
      }
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(bytes, { stream: false });
    } catch (e) {
      return '';
    }
  }
}

// web_fetch 工具名(工作模式工具表与聊天模式强制注入共用)
export const WEB_FETCH_TOOL_NAME: string = 'web_fetch';

export class HarnessTools {
  // ===== 工具分类(与 WorkFileService 的并发调度联动) =====

  static isReadOnly(name: string): boolean {
    return name === 'glob' || name === 'grep' || name === 'web_fetch' ||
      name === 'schedule_list' || name === 'goal_get' || name === 'session_search';
  }

  static isMutating(name: string): boolean {
    return name === 'edit' || name === 'str_replace_editor' ||
      name === 'goal_create' || name === 'goal_update' ||
      name === 'schedule_create' || name === 'schedule_delete' ||
      name === 'run_js';
  }

  // ===== 分发(由 WorkFileService.dispatchTool 兜底转发) =====

  static async dispatch(context: common.UIAbilityContext, convId: string,
    name: string, args: Record<string, Object>, root: string,
    abortSignal?: AbortSignal | null): Promise<ToolExecResult> {
    if (name === 'glob') {
      return HarnessTools.toolGlob(root, args);
    }
    if (name === 'grep') {
      return HarnessTools.toolGrep(root, args);
    }
    if (name === 'edit') {
      return HarnessTools.toolEdit(context, convId, root, args, false);
    }
    if (name === 'str_replace_editor') {
      return HarnessTools.toolEdit(context, convId, root, args, true);
    }
    if (name === 'web_fetch') {
      return await HarnessTools.toolWebFetch(args);
    }
    if (name === 'ask_user_question') {
      return await HarnessTools.toolAskUser(args);
    }
    if (name === 'schedule_create') {
      return HarnessTools.toolScheduleCreate(root, args);
    }
    if (name === 'schedule_list') {
      let items: ScheduleItem[] = ScheduleService.list(root);
      return HarnessTools.ok('当前提醒:\n' + ScheduleService.renderList(items));
    }
    if (name === 'schedule_delete') {
      let id: string = HarnessTools.strArg(args, 'id', '');
      if (id === '') {
        return HarnessTools.fail('缺少参数 id(schedule_list 中查看)');
      }
      let removed: boolean = ScheduleService.remove(root, id);
      return removed ? HarnessTools.ok('已取消提醒 ' + id) :
        HarnessTools.fail('未找到该提醒: ' + id);
    }
    if (name === 'goal_create') {
      let objective: string = HarnessTools.strArg(args, 'objective', '');
      if (objective === '') {
        return HarnessTools.fail('缺少参数 objective');
      }
      let maxRounds: number = HarnessTools.intArg(args, 'max_rounds', 40);
      let goal: GoalItem = GoalService.create(root, objective, maxRounds);
      return HarnessTools.ok('目标已建立:\n' + GoalService.render(goal));
    }
    if (name === 'goal_get') {
      let goal: GoalItem | null = GoalService.read(root);
      if (goal === null) {
        return HarnessTools.ok('(当前没有目标)');
      }
      return HarnessTools.ok(GoalService.render(goal));
    }
    if (name === 'goal_update') {
      let status: string = HarnessTools.strArg(args, 'status', '');
      let note: string = HarnessTools.strArg(args, 'note', '');
      let bumpRound: boolean = HarnessTools.boolArg(args, 'bump_round', false);
      let goal: GoalItem | null = GoalService.update(root, status, note, bumpRound);
      if (goal === null) {
        return HarnessTools.fail('当前没有目标, 先用 goal_create 建立');
      }
      return HarnessTools.ok('目标已更新:\n' + GoalService.render(goal));
    }
    if (name === 'subagent') {
      let hook: ((ctx: common.UIAbilityContext, cid: string, desc: string,
        prompt: string, outputDir?: string,
        abortSignal?: AbortSignal | null) => Promise<ToolExecResult>) | null =
        WorkFileService.subagentHook;
      if (hook === null) {
        return HarnessTools.fail('子代理服务尚未初始化');
      }
      let description: string = HarnessTools.strArg(args, 'description', '');
      let prompt: string = HarnessTools.strArg(args, 'prompt', '');
      let outputDir: string = HarnessTools.strArg(args, 'output_dir', '');
      if (description.trim() === '' || prompt.trim() === '') {
        return HarnessTools.fail('缺少参数 description / prompt');
      }
      return await hook(context, convId, description, prompt, outputDir, abortSignal);
    }
    if (name === 'session_search') {
      return HarnessTools.toolSessionSearch(context, convId, args);
    }
    if (name === JsCodeService.TOOL_NAME) {
      return await JsCodeService.run(root, args);
    }
    return HarnessTools.fail('未知工具: ' + name);
  }

  // ===== glob =====

  private static toolGlob(root: string, args: Record<string, Object>): ToolExecResult {
    let pattern: string = HarnessTools.strArg(args, 'pattern', '');
    if (pattern === '') {
      return HarnessTools.fail('缺少参数 pattern, 如 "**/*.csv" 或 "assets/*.svg"');
    }
    let baseRel: string = HarnessTools.strArg(args, 'path', '').replace(/^\/+|\/+$/g, '');
    let adapter: FsAdapter = new DeviceFsAdapter();
    let skip: string[] = [Constants.WORK_SPILL_DIR];
    let hits: GlobHit[] = FileSearchCore.globSearch(adapter, root, pattern, baseRel, skip);
    if (hits.length === 0) {
      return HarnessTools.ok('未找到匹配 "' + pattern + '" 的文件');
    }
    let lines: string[] = [];
    for (let i: number = 0; i < hits.length; i++) {
      let abs: string | null = HarnessTools.resolveSafe(root, hits[i].path);
      let sizeLabel: string = '';
      if (abs !== null && fileIo.accessSync(abs)) {
        try {
          sizeLabel = ' (' + HarnessTools.formatSize(fileIo.statSync(abs).size) + ')';
        } catch (e) {
          sizeLabel = '';
        }
      }
      lines.push(hits[i].path + sizeLabel);
    }
    let out: string = '共 ' + hits.length.toString() + ' 个匹配文件:\n' + lines.join('\n');
    if (hits.length >= Constants.WORK_GLOB_MAX_FILES) {
      out += '\n...(已达单次上限, 请用更精确的 pattern 或 path 收窄范围)';
    }
    return HarnessTools.ok(out);
  }

  // ===== grep =====

  private static toolGrep(root: string, args: Record<string, Object>): ToolExecResult {
    let pattern: string = HarnessTools.strArg(args, 'pattern', '');
    if (pattern === '') {
      return HarnessTools.fail('缺少参数 pattern(正则表达式)');
    }
    // 先验证正则合法, 给模型可读的错误
    try {
      new RegExp(pattern, 'i');
    } catch (e) {
      return HarnessTools.fail('pattern 不是合法的正则表达式: ' + pattern);
    }
    let options: GrepOptions = new GrepOptions();
    options.pattern = pattern;
    options.ignoreCase = HarnessTools.boolArg(args, 'ignore_case', true);
    options.glob = HarnessTools.strArg(args, 'glob', '');
    let maxArg: number = HarnessTools.intArg(args, 'max_matches', 0);
    options.maxMatches = maxArg > 0 ? Math.min(maxArg, Constants.WORK_GREP_MAX_MATCHES) :
      Constants.WORK_GREP_MAX_MATCHES;
    let baseRel: string = HarnessTools.strArg(args, 'path', '').replace(/^\/+|\/+$/g, '');
    let adapter: FsAdapter = new DeviceFsAdapter();
    let skip: string[] = [Constants.WORK_SPILL_DIR];
    let hits: GrepHit[] = FileSearchCore.grepSearch(adapter, root, options, baseRel, skip);
    if (hits.length === 0) {
      return HarnessTools.ok('未找到匹配 /' + pattern + '/ 的内容');
    }
    let header: string = '共 ' + hits.length.toString() + ' 处匹配(正则 /' + pattern + '/):';
    if (options.glob !== '') {
      header += '(文件名过滤: ' + options.glob + ')';
    }
    return HarnessTools.ok(header + '\n' + FileSearchCore.renderHits(hits));
  }

  // ===== edit / str_replace_editor =====

  private static async toolEdit(context: common.UIAbilityContext, convId: string,
    root: string, args: Record<string, Object>, editorStyle: boolean): Promise<ToolExecResult> {
    let command: string = editorStyle ? HarnessTools.strArg(args, 'command', 'str_replace') :
      'str_replace';
    let rel: string = HarnessTools.strArg(args, 'path', '');
    if (rel === '') {
      return HarnessTools.fail('缺少参数 path');
    }
    let abs: string | null = HarnessTools.resolveSafe(root, rel);
    if (abs === null) {
      return HarnessTools.fail('非法路径: ' + rel);
    }
    // str_replace_editor 的 view/create/insert 分支
    if (editorStyle && command === 'view') {
      let offset: number = HarnessTools.intArg(args, 'view_range_offset', 1);
      let limit: number = HarnessTools.intArg(args, 'view_range_lines', 0);
      let cacheDir: string = context.cacheDir + '/work_office';
      return await WorkFileService.toolReadPublic(root, rel, cacheDir, offset, limit);
    }
    if (editorStyle && command === 'create') {
      if (fileIo.accessSync(abs)) {
        return HarnessTools.fail('文件已存在, create 仅用于新建: ' + rel);
      }
      let text: string = HarnessTools.strArg(args, 'file_text', '');
      return HarnessTools.writeTextFile(root, rel, abs, text, false,
        DiffUtil.computeFileDiff('', text, rel, Constants.WORK_EDIT_CONTEXT_LINES),
        context, convId);
    }
    if (!fileIo.accessSync(abs)) {
      return HarnessTools.fail('文件不存在: ' + rel);
    }
    if (fileIo.statSync(abs).isDirectory()) {
      return HarnessTools.fail('路径是目录而非文件: ' + rel);
    }
    let oldText: string = HarnessTools.readTextFile(abs);
    if (oldText === null) {
      return HarnessTools.fail('这是二进制文件或读取失败, 编辑工具只支持文本文件: ' + rel);
    }
    if (editorStyle && command === 'insert') {
      let lineNo: number = HarnessTools.intArg(args, 'insert_line', 0);
      let text: string = HarnessTools.strArg(args, 'insert_text', '');
      let ins: EditOutcome = EditCore.insertLines(oldText, lineNo, text);
      if (ins.status === 'range') {
        return HarnessTools.fail('insert_line=' + lineNo.toString() + ' 超出范围(共 ' +
          ins.lineTotal.toString() + ' 行)');
      }
      return HarnessTools.writeTextFile(root, rel, abs, ins.newText, true,
        DiffUtil.computeFileDiff(oldText, ins.newText, rel, Constants.WORK_EDIT_CONTEXT_LINES),
        context, convId);
    }
    // str_replace 分支(edit 与 str_replace_editor 共用; 匹配/替换/换行自适应在 EditCore)
    let oldStr: string = HarnessTools.strArg(args, 'old_string', '');
    let newStr: string = HarnessTools.strArg(args, 'new_string', '');
    let replaceAll: boolean = HarnessTools.boolArg(args, 'replace_all', false);
    if (oldStr === '') {
      return HarnessTools.fail('缺少参数 old_string(要被替换的原文, 必须与文件内容逐字符一致)');
    }
    if (oldStr === newStr) {
      return HarnessTools.fail('old_string 与 new_string 相同, 无需编辑');
    }
    let outcome: EditOutcome = EditCore.apply(oldText, oldStr, newStr, replaceAll);
    if (outcome.status === 'not_found') {
      return HarnessTools.fail('old_string 在文件中不存在(需逐字符精确匹配, 空白敏感; ' +
        'CRLF/LF 换行会自动对齐; 先用 read_file 核对原文)');
    }
    if (outcome.status === 'multiple') {
      return HarnessTools.fail('old_string 匹配到 ' + outcome.matchCount.toString() +
        ' 处(要求唯一)。补充更多上下文使其唯一, 或传 replace_all=true 全部替换');
    }
    if (outcome.status === 'no_change') {
      return HarnessTools.fail('替换后文件内容无变化(换行风格已与文件一致), 无需编辑');
    }
    if (!outcome.ok) {
      return HarnessTools.fail('编辑失败: ' + outcome.status);
    }
    return HarnessTools.writeTextFile(root, rel, abs, outcome.newText, true,
      DiffUtil.computeFileDiff(oldText, outcome.newText, rel, Constants.WORK_EDIT_CONTEXT_LINES),
      context, convId);
  }

  // 临时文件自增序号(配合时间戳保证 .spill 下不重名)
  private static tmpSeq: number = 0;

  // 写回文本 + 组装带 diff meta 的结果(原子写: 先写 .spill 临时文件再改名, 避免半截写入)
  private static writeTextFile(root: string, rel: string, abs: string, text: string,
    hadBefore: boolean, diff: FileDiff | null, context: common.UIAbilityContext,
    convId: string): ToolExecResult {
    try {
      let encoder: util.TextEncoder = new util.TextEncoder();
      let bytes: Uint8Array = encoder.encode(text);
      if (bytes.length > Constants.WORK_WRITE_MAX_BYTES) {
        return HarnessTools.fail('编辑后的文件超出单次写入上限 ' +
          HarnessTools.formatSize(Constants.WORK_WRITE_MAX_BYTES));
      }
      let parentDir: string = abs.substring(0, abs.lastIndexOf('/'));
      if (parentDir !== root && !fileIo.accessSync(parentDir)) {
        fileIo.mkdirSync(parentDir, true);
      }
      let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
      if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
        buffer = bytes.slice().buffer as ArrayBuffer;
      }
      // 临时文件放 .spill(glob/grep 已跳过): 即使进程中途被杀也不污染工作区列表。
      // mkdirSync 对已存在目录会抛 File exists, 必须先判存在(同 SpillStore/ensureDir 的守卫)
      let spillDir: string = root + '/' + Constants.WORK_SPILL_DIR;
      if (!fileIo.accessSync(spillDir)) {
        fileIo.mkdirSync(spillDir, true);
      }
      HarnessTools.tmpSeq = HarnessTools.tmpSeq + 1;
      let tmpPath: string = spillDir + '/edit-tmp-' + Date.now().toString() + '-' +
        HarnessTools.tmpSeq.toString();
      let renamed: boolean = false;
      try {
        let tmp: fileIo.File = fileIo.openSync(tmpPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(tmp.fd, buffer);
        } finally {
          fileIo.closeSync(tmp.fd);
        }
        try {
          fileIo.renameSync(tmpPath, abs);
        } catch (e2) {
          // 部分系统版本 rename 不覆盖已存在目标: 先删旧文件腾出路径再改名
          if (fileIo.accessSync(abs)) {
            fileIo.unlinkSync(abs);
          }
          fileIo.renameSync(tmpPath, abs);
        }
        renamed = true;
      } catch (e3) {
        try {
          fileIo.unlinkSync(tmpPath);
        } catch (e4) {
          // 临时文件可能尚未创建成功
        }
      }
      if (!renamed) {
        // 改名仍失败时退回原地截断重写(该路径即旧实现, 设备上已验证可用)
        let file: fileIo.File = fileIo.openSync(abs,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(file.fd, buffer);
        } finally {
          fileIo.closeSync(file.fd);
        }
      }
      let result: ToolExecResult = new ToolExecResult();
      result.ok = true;
      let addsStr: string = diff !== null ? ', +' + diff.adds.toString() + ' -' + diff.dels.toString() : '';
      result.output = '已编辑 ' + rel + addsStr + '(' +
        HarnessTools.formatSize(bytes.length) + ')';
      if (diff !== null) {
        result.meta = JSON.stringify(diff.toJsonObject());
        result.output += '\n' + DiffUtil.renderPlain(diff);
      }
      return result;
    } catch (e) {
      return HarnessTools.fail('写入失败: ' + HarnessTools.errText(e));
    }
  }

  private static readTextFile(abs: string): string | null {
    try {
      let stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.size === 0) {
        return '';
      }
      if (stat.size > Constants.WORK_READ_FULL_MAX_BYTES) {
        return null;
      }
      let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buffer, { offset: 0 });
      } finally {
        fileIo.closeSync(file.fd);
      }
      let bytes: Uint8Array = new Uint8Array(buffer);
      if (HarnessTools.looksBinary(bytes)) {
        return null;
      }
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(bytes, { stream: false });
    } catch (e) {
      return null;
    }
  }

  // ===== web_fetch =====

  // 公开给聊天模式工具循环复用(自包含: 只依赖 args, 不触碰工作区)
  static async toolWebFetch(args: Record<string, Object>): Promise<ToolExecResult> {
    let url: string = HarnessTools.strArg(args, 'url', '');
    if (url === '') {
      return HarnessTools.fail('缺少参数 url');
    }
    let maxChars: number = HarnessTools.intArg(args, 'max_chars', 0);
    let r: ToolExecResult = new ToolExecResult();
    let result = await WebFetchService.fetch(url, maxChars);
    if (!result.ok) {
      r.ok = false;
      r.output = 'ERROR: web_fetch 失败: ' + result.error;
      return r;
    }
    r.ok = true;
    r.output = '[web_fetch] ' + result.finalUrl + '\n类型: ' + result.contentType + ' · ' +
      HarnessTools.formatSize(result.byteSize) + '\n\n' + result.text;
    return r;
  }

  // ===== ask_user_question =====

  private static async toolAskUser(args: Record<string, Object>): Promise<ToolExecResult> {
    let question: string = HarnessTools.strArg(args, 'question', '');
    if (question === '') {
      return HarnessTools.fail('缺少参数 question');
    }
    let options: string[] = HarnessTools.strListArg(args, 'options');
    let multiSelect: boolean = HarnessTools.boolArg(args, 'multi_select', false);
    let noteAllowed: boolean = HarnessTools.boolArg(args, 'allow_note', true);
    // 5 分钟未回答按取消处理, 避免工具永久挂起
    let answer: AskAnswer | null = await AskUserBridge.ask(question, options, multiSelect, 300000);
    if (answer === null) {
      return HarnessTools.fail('用户未回答(已取消), 请基于合理假设继续, 并在总结中标注该假设');
    }
    let lines: string[] = [];
    lines.push('[ask_user_question] 用户已回答:');
    lines.push('问题: ' + question);
    if (answer.selections.length > 0) {
      lines.push('选择: ' + answer.selections.join(' | '));
    }
    if (noteAllowed && answer.note !== '') {
      lines.push('补充: ' + answer.note);
    }
    let r: ToolExecResult = new ToolExecResult();
    r.ok = true;
    r.output = lines.join('\n');
    return r;
  }

  // ===== schedule =====

  private static toolScheduleCreate(root: string, args: Record<string, Object>): ToolExecResult {
    let message: string = HarnessTools.strArg(args, 'message', '');
    if (message === '') {
      return HarnessTools.fail('缺少参数 message(提醒内容)');
    }
    let afterSeconds: number = HarnessTools.intArg(args, 'after_seconds', 0);
    let everySeconds: number = HarnessTools.intArg(args, 'every_seconds', 0);
    if (afterSeconds <= 0 && everySeconds <= 0) {
      return HarnessTools.fail('缺少 after_seconds(多少秒后提醒)或 every_seconds(循环间隔秒)');
    }
    let item: ScheduleItem | null = ScheduleService.create(root, message,
      Date.now() + afterSeconds * 1000, everySeconds);
    if (item === null) {
      return HarnessTools.fail('提醒数量已达上限(' + Constants.WORK_SCHEDULE_MAX.toString() + ' 条)');
    }
    let kind: string = item.everySeconds > 0 ?
      '每 ' + item.everySeconds.toString() + ' 秒循环' : '一次性';
    return HarnessTools.ok('已创建提醒 [' + item.id + '] ' + kind + ': ' + message);
  }

  // ===== session_search =====

  private static toolSessionSearch(context: common.UIAbilityContext, convId: string,
    args: Record<string, Object>): ToolExecResult {
    let query: string = HarnessTools.strArg(args, 'query', '');
    if (query === '') {
      return HarnessTools.fail('缺少参数 query');
    }
    let all: string = SessionLogService.readAll(context, convId);
    if (all === '') {
      return HarnessTools.ok('(本会话还没有事件日志)');
    }
    let qLower: string = query.toLowerCase();
    let lines: string[] = all.split('\n');
    let maxResults: number = HarnessTools.intArg(args, 'max_results', 40);
    let found: string[] = [];
    for (let i: number = 0; i < lines.length && found.length < maxResults; i++) {
      if (lines[i].toLowerCase().indexOf(qLower) !== -1) {
        let shown: string = lines[i].length > 500 ?
          lines[i].substring(0, 500) + '…' : lines[i];
        found.push('L' + (i + 1).toString() + ': ' + shown);
      }
    }
    if (found.length === 0) {
      return HarnessTools.ok('会话日志中未找到 "' + query + '"');
    }
    return HarnessTools.ok('会话日志中找到 ' + found.length.toString() + ' 条(JSONL 事件行):\n' +
      found.join('\n'));
  }

  // ===== 工具定义 =====

  static toolDefs(): Record<string, Object>[] {
    let defs: Record<string, Object>[] = [];
    defs.push(HarnessTools.makeTool('glob',
      '按 glob 模式在沙箱工作区查找文件路径, 返回相对路径与大小。支持 **(跨目录)、*(段内任意)、?(单字符)、{a,b} 分支与 [abc] 字符类, 如 "**/*.csv"、"assets/*.svg"、"output/{docx,xlsx}/*"。只匹配路径不读内容; 按内容搜索用 grep/search_files。',
      HarnessTools.props2(
        'pattern', HarnessTools.strProp('glob 模式(相对工作区根), 如 **/*.md'),
        'path', HarnessTools.strProp('可选: 限定搜索的目录相对路径, 留空为整个工作区')),
      ['pattern']));
    defs.push(HarnessTools.makeTool('grep',
      '在沙箱工作区的文本文件中按正则表达式搜索内容, 返回 文件:行号: 内容 命中列表(最多 200 处)。比子串搜索(search_files)更强: 支持 \\d、^、$、单词边界等正则。glob 可选按文件名过滤(如 "*.ts")。ignore_case 默认 true。长文档定位后用 read_file 传 offset 精读该段。',
      HarnessTools.props4(
        'pattern', HarnessTools.strProp('正则表达式, 如 "订单\\d{4}"'),
        'path', HarnessTools.strProp('可选: 限定目录相对路径, 留空为整个工作区'),
        'glob', HarnessTools.strProp('可选: 文件名 glob 过滤, 如 "*.md,*.csv"'),
        'ignore_case', HarnessTools.strProp('可选: 忽略大小写, 默认 true')),
      ['pattern']));
    defs.push(HarnessTools.makeTool('edit',
      '对工作区文本文件做精确编辑: old_string 必须与文件内容逐字符一致(含空白; CRLF/LF 换行与文件风格不一致时自动对齐重试), 默认要求唯一匹配(多处匹配会被拒绝, 补充上下文或传 replace_all=true)。返回 diff(+新增 -删除)。对已有文件的小改动优先用它(比 write_file 全量重写更安全); 新建文件用 write_file。',
      HarnessTools.props4(
        'path', HarnessTools.strProp('目标文件相对路径'),
        'old_string', HarnessTools.strProp('要被替换的原文(逐字符精确匹配)'),
        'new_string', HarnessTools.strProp('替换后的新文本'),
        'replace_all', HarnessTools.strProp('可选: true 时替换全部匹配, 默认 false(要求唯一)')),
      ['path', 'old_string', 'new_string']));
    defs.push(HarnessTools.makeTool('str_replace_editor',
      '多命令文本编辑器(view/create/str_replace/insert)。view: 分页查看(offset+limit); create: 新建文件(file_text); str_replace: 唯一匹配替换(old_string/new_string); insert: 在第 insert_line 行后插入 insert_text。普通编辑用 edit 更简单; 需要"查看"或在指定行插入时用本工具。',
      HarnessTools.props3(
        'command', HarnessTools.strProp('view / create / str_replace / insert 之一'),
        'path', HarnessTools.strProp('目标文件相对路径'),
        'file_text', HarnessTools.strProp('create 时的完整文件内容; str_replace 时改传 old_string/new_string; insert 时传 insert_line/insert_text')),
      ['command', 'path']));
    defs.push(HarnessTools.makeTool(WEB_FETCH_TOOL_NAME,
      '抓取 http(s) 网页/接口原文: GET 请求(≤2MB), HTML 自动剥离为可读文本, JSON/文本原样返回(超长截断)。用于读服务端联网搜索给出的具体来源、抓公开文档/接口数据。不可达或非 2xx 会明确报错; 需要下载文件到工作区用 download_file。',
      HarnessTools.props2(
        'url', HarnessTools.strProp('要抓取的 http(s) 链接'),
        'max_chars', HarnessTools.strProp('可选: 返回文本字符上限, 默认 24000')),
      ['url']));
    defs.push(HarnessTools.makeTool('ask_user_question',
      '向用户提问并等待回答(会暂停执行)。仅当存在影响整体方向的关键缺口(目标格式/范围/口径/确认删除等)且无法用合理默认值时使用; 问题要一次问全(支持多个选项)。**技能强制前置提问(如 ppt/docx/xlsx 新建)优先于本默认**。options 为选项字符串数组(可空=自由回答); multi_select=true 允许多选; 用户也可补充文字。用户回答会作为本工具结果返回。',
      HarnessTools.props3(
        'question', HarnessTools.strProp('问题文本(把背景与影响一次说清)'),
        'options', HarnessTools.strProp('可选: 选项 JSON 字符串数组, 如 ["方案A","方案B"]'),
        'multi_select', HarnessTools.strProp('可选: 是否允许多选, 默认 false')),
      ['question']));
    defs.push(HarnessTools.makeTool('schedule_create',
      '创建会话内定时提醒: after_seconds 秒后触发一次性提醒, 或 every_seconds 秒循环提醒(最小 300 秒)。到期时提醒会作为用户消息注入对话(自动唤醒执行)。适合"10 分钟后提醒我汇总进度"类诉求; 数量上限 10 条。',
      HarnessTools.props3(
        'message', HarnessTools.strProp('提醒内容(到期后你会看到这句话)'),
        'after_seconds', HarnessTools.strProp('多少秒后提醒(一次性, 二选一)'),
        'every_seconds', HarnessTools.strProp('循环间隔秒数(≥300, 与 after_seconds 二选一)')),
      ['message']));
    defs.push(HarnessTools.makeTool('schedule_list',
      '列出当前会话的全部定时提醒(id/类型/剩余时间/内容)。',
      HarnessTools.props0(),
      []));
    defs.push(HarnessTools.makeTool('schedule_delete',
      '取消一条定时提醒(id 见 schedule_list)。',
      HarnessTools.props1('id', HarnessTools.strProp('要取消的提醒 id')),
      ['id']));
    defs.push(HarnessTools.makeTool('goal_create',
      '建立/重置当前会话的自主目标(objective)。目标随运行时快照注入每一轮, 用于长程任务中锚定总意图、防止执行漂移。复杂任务开工前可先立目标; 状态默认 active, 达到轮次上限自动暂停。',
      HarnessTools.props2(
        'objective', HarnessTools.strProp('目标描述(一句话说清要达成什么)'),
        'max_rounds', HarnessTools.strProp('可选: 轮次上限, 默认 40')),
      ['objective']));
    defs.push(HarnessTools.makeTool('goal_get',
      '读取当前会话目标(objective/状态/轮次/备注)。',
      HarnessTools.props0(),
      []));
    defs.push(HarnessTools.makeTool('goal_update',
      '更新当前目标: status 取 active/paused/done/blocked; note 记录关键进展或受阻原因; bump_round=true 时轮次+1。',
      HarnessTools.props3(
        'status', HarnessTools.strProp('可选: active/paused/done/blocked'),
        'note', HarnessTools.strProp('可选: 备注(进展/受阻原因)'),
        'bump_round', HarnessTools.strProp('可选: true 时轮次+1')),
      []));
    defs.push(HarnessTools.makeTool('subagent',
      '派生一个子代理独立完成子任务(共享同一工作区, 独立上下文, 最多 40 步)。适合把可并行的独立调研/批量产出/大块检索外包出去, 主任务保持轻上下文。description 一句话概括子任务; prompt 是给子代理的完整执行指令(自包含, 含验收标准); output_dir 可选——指定产出目录(工作区相对路径), 不传则自动分配独立子目录(默认 subagents/<n>/)以隔离并行子代理的产出, 避免互相覆盖。子代理仍可读取/搜索主工作区全部文件, 但所有写入/新建/移动/删除都会被自动限制到其产出目录内。返回子代理的最终报告; 其产出文件通过工作区路径交接。不要在子代理指令里要求向用户提问(没有交互通道)。',
      HarnessTools.props3(
        'description', HarnessTools.strProp('子任务一句话概括(展示用)'),
        'prompt', HarnessTools.strProp('子代理的完整执行指令(自包含)'),
        'output_dir', HarnessTools.strProp('可选: 产出目录(工作区相对路径, 默认自动分配 subagents/<n>/, 并行隔离用)')),
      ['description', 'prompt']));
    defs.push(HarnessTools.makeTool('session_search',
      '在当前会话的事件日志(JSONL, 含历史用户消息/思考摘要/工具调用与结果)中检索, 返回命中事件行。用于找回早期轮次的关键信息(上下文压缩后历史细节可能已丢), 或核对"之前到底执行过什么"。按子串匹配, 最多返回 40 行。',
      HarnessTools.props2(
        'query', HarnessTools.strProp('检索关键词(子串匹配)'),
        'max_results', HarnessTools.strProp('可选: 返回行数上限, 默认 40')),
      ['query']));
    defs.push(HarnessTools.makeTool(JsCodeService.TOOL_NAME,
      '在本机的独立 JS 引擎沙箱里执行一段 JavaScript, 用于"写几行代码算一下"的活: 日期/数值/单位换算、正则清洗、JSON 重塑与合并、统计汇总、算法试算与验证, 以及批量生成结构化数据(先用 JS 拼出完整 JSON 写出文件, 再交给 write_docx/write_xlsx/write_pptx 成文)。' +
      '沙箱是纯计算环境: 无网络、无文件系统、无模块加载(不支持 import/require), 文件必须显式进出 —— files 里列出的工作区文件会预载为只读的 inputs(键=去掉 "./" 前缀的相对路径, 结果里会列出实际键名), 脚本里用 inputs["路径"] 或 read("路径") 读取(read 对写法宽容: "./a/b.txt"、"a//b.txt" 都会归一化; 未传 files 时调用 read 会直接报错提示补 files); 脚本内 write(path, content) 声明的输出会在执行成功后写入工作区。' +
      '返回值取脚本最后一条表达式的值(要显式返回就写 (() => { ...; return 结果; })()); console.log/print 的输出随结果一并返回。' +
      '限制: 代码 ≤128KB, 默认执行上限 10 秒(timeout_ms 可放宽到 30 秒), 死循环无法中断(超时会放弃等待并计入上限), 单次输出 ≤16 个文件且单文件 ≤512KB。' +
      '常规表格转换仍优先用 transform_file; 大文件读取仍用 read_file/search_files。',
      HarnessTools.props3(
        'code', HarnessTools.strProp('要执行的 JS 代码; 文件内容用 inputs["路径"] 或 read("路径") 读取, 产出用 write("路径", 内容) 写出'),
        'files', HarnessTools.strProp('可选: 要预载为只读输入的工作区文件相对路径(如 "data/in.csv"), 多个用逗号或 JSON 数组分隔(最多 6 个, 单个 ≤512KB); 不传则脚本里没有可读输入, 需要文件内容时必须传'),
        'timeout_ms', HarnessTools.strProp('可选: 执行超时毫秒数, 默认 10000, 范围 1000~30000')),
      ['code']));
    return defs;
  }

  // web_fetch 的协议无关定义(聊天模式强制注入时复用, 保持描述单点维护)
  static webFetchDef(): Record<string, Object> {
    return HarnessTools.makeTool(WEB_FETCH_TOOL_NAME,
      '抓取 http(s) 网页/接口原文: GET 请求(≤2MB), HTML 自动剥离为可读文本, JSON/文本原样返回(超长截断)。用于读取联网搜索结果中的具体来源、用户给出的链接、公开文档与接口数据。不可达或非 2xx 会明确报错。',
      HarnessTools.props2(
        'url', HarnessTools.strProp('要抓取的 http(s) 链接'),
        'max_chars', HarnessTools.strProp('可选: 返回文本字符上限, 默认 24000')),
      ['url']);
  }

  // ===== 底层小工具 =====

  static resolveSafe(root: string, rel: string): string | null {
    return WorkFileService.resolveSafePublic(root, rel);
  }

  static isTextFileName(name: string): boolean {
    let dot: number = name.lastIndexOf('.');
    if (dot < 0 || dot === name.length - 1) {
      return name.endsWith('Dockerfile') || name.endsWith('Makefile');
    }
    let ext: string = name.substring(dot + 1).toLowerCase();
    let textExts: string[] = ['txt', 'md', 'markdown', 'json', 'jsonl', 'csv', 'tsv', 'xml',
      'html', 'htm', 'css', 'scss', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'yaml', 'yml',
      'ini', 'cfg', 'conf', 'toml', 'log', 'py', 'java', 'kt', 'kts', 'c', 'h', 'cpp', 'hpp',
      'cs', 'go', 'rs', 'rb', 'php', 'sh', 'bash', 'bat', 'sql', 'svg', 'properties',
      'gradle', 'plist', 'swift', 'dart', 'r', 'vue', 'svelte', 'proto', 'graphql', 'env'];
    return textExts.indexOf(ext) !== -1;
  }

  static looksBinary(bytes: Uint8Array): boolean {
    let scan: number = bytes.length < 4096 ? bytes.length : 4096;
    for (let i: number = 0; i < scan; i++) {
      if (bytes[i] === 0) {
        return true;
      }
    }
    return false;
  }

  static formatSize(bytes: number): string {
    return WorkFileService.formatSize(bytes);
  }

  static errText(e: Object): string {
    if (e instanceof Error) {
      let err: Error = e as Error;
      return err.message !== undefined ? err.message : String(e);
    }
    return String(e);
  }

  private static strArg(args: Record<string, Object>, key: string, defVal: string): string {
    let v: Object = args[key];
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return defVal;
  }

  static intArg(args: Record<string, Object>, key: string, defVal: number): number {
    let v: Object = args[key];
    if (typeof v === 'number' && !isNaN(v as number)) {
      return Math.floor(v as number);
    }
    if (typeof v === 'string') {
      let n: number = parseInt(v as string, 10);
      if (!isNaN(n)) {
        return n;
      }
    }
    return defVal;
  }

  private static boolArg(args: Record<string, Object>, key: string, defVal: boolean): boolean {
    let v: Object = args[key];
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'string') {
      let s: string = (v as string).toLowerCase();
      if (s === 'true' || s === '1' || s === 'yes') {
        return true;
      }
      if (s === 'false' || s === '0' || s === 'no') {
        return false;
      }
    }
    return defVal;
  }

  // 字符串数组参数: 兼容 JSON 数组字符串 / 实际数组 / 逗号分隔
  private static strListArg(args: Record<string, Object>, key: string): string[] {
    let out: string[] = [];
    let v: Object = args[key];
    if (v === undefined || v === null) {
      return out;
    }
    if (v instanceof Array) {
      let arr: Object[] = v as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          out.push(arr[i] as string);
        }
      }
      return out;
    }
    if (typeof v === 'string') {
      let text: string = v as string;
      let trimmed: string = text.trim();
      if (trimmed.startsWith('[')) {
        try {
          let parsed: Object = JSON.parse(trimmed);
          if (parsed instanceof Array) {
            let arr2: Object[] = parsed as Object[];
            for (let i: number = 0; i < arr2.length; i++) {
              if (typeof arr2[i] === 'string') {
                out.push(arr2[i] as string);
              }
            }
            return out;
          }
        } catch (e) {
          // 退化为逗号分隔
        }
      }
      let parts: string[] = trimmed.split(',');
      for (let i: number = 0; i < parts.length; i++) {
        if (parts[i].trim() !== '') {
          out.push(parts[i].trim());
        }
      }
    }
    return out;
  }

  private static ok(output: string): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = true;
    r.output = output;
    return r;
  }

  private static fail(output: string): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = false;
    r.output = 'ERROR: ' + output;
    return r;
  }

  private static makeTool(name: string, description: string,
    properties: Record<string, Object>, required: string[]): Record<string, Object> {
    let schema: Record<string, Object> = {
      'type': 'object',
      'properties': properties,
      'required': required
    };
    return {
      'name': name,
      'description': description,
      'parameters': schema
    };
  }

  private static strProp(description: string): Record<string, Object> {
    return {
      'type': 'string',
      'description': description
    };
  }

  private static props0(): Record<string, Object> {
    return {};
  }

  private static props1(name1: string, p1: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    return properties;
  }

  private static props2(name1: string, p1: Record<string, Object>,
    name2: string, p2: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    properties[name2] = p2;
    return properties;
  }

  private static props3(name1: string, p1: Record<string, Object>,
    name2: string, p2: Record<string, Object>,
    name3: string, p3: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    properties[name2] = p2;
    properties[name3] = p3;
    return properties;
  }

  private static props4(name1: string, p1: Record<string, Object>,
    name2: string, p2: Record<string, Object>,
    name3: string, p3: Record<string, Object>,
    name4: string, p4: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    properties[name2] = p2;
    properties[name3] = p3;
    properties[name4] = p4;
    return properties;
  }
}
