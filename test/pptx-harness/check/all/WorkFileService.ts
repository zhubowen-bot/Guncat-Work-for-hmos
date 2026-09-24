// WorkFileService: 工作模式沙箱工作区 + Agent 工具集
// 所有文件操作都限制在 <filesDir>/workspaces/<convId> 目录内(应用沙箱, 无需任何文件权限);
// 工具路径一律使用相对路径, resolveSafe 会拒绝绝对路径与 '..' 穿越出工作区。
// 打包下载复用 STORE 方式的 ZipWriter + 系统文档保存面板(DocumentViewPicker, 无需权限)。
import { fileIo, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ZipWriter, ZipEntry } from './ZipWriterTs.ts';
import { PickedFile } from './FileService.ts';
import { DiffUtil, FileDiff } from './DiffUtil.ts';
import { OfficeReader } from './OfficeReader.ts';
import { PdfTextExtractor } from './PdfTextExtractor.ts';
import { WorkSkillService } from './WorkSkillService.ts';
import { HarnessTools } from './HarnessTools.ts';
import { arrayBufferToBase64 } from './Utils.ts';
import { ToolRegistry } from './ToolRegistry.ts';
import { Constants } from './Constants.ts';
import { LocalWebSearch, LocalSearchOutcome, LOCAL_SEARCH_TOOL_DESC_WORK, LOCAL_SEARCH_TOOL_DESC_WORK_FALLBACK,
  LOCAL_SEARCH_QUERY_PROP_DESC } from './LocalWebSearch.ts';
import { AbortSignal } from './Types.ts';

const DOMAIN: number = 0x0000;
const TAG: string = 'WorkFileService';

// 工作区条目信息(相对路径)
export class WorkspaceFileInfo {
  path: string = '';
  isDir: boolean = false;
  size: number = 0;
}

// 工具执行结果(ok=false 时 output 为错误说明, 会原样送回模型; imageDataUrl 供 view_image 注入视觉消息)
// meta: 结构化展示数据(JSON), 如 edit 工具的 diff 卡片; 随会话持久化, UI 重放渲染。
// timeout/cancelled: 可观测标记(由执行护栏设置), 供审计日志统计超时率/取消率。
export class ToolExecResult {
  ok: boolean = false;
  output: string = '';
  imageDataUrl: string = '';
  meta: string = '';
  timeout: boolean = false;
  cancelled: boolean = false;
  schemaError: boolean = false;
}

export class WorkFileService {
  // subagent 工具经此钩子执行(由 SubagentService.bind 注入, 规避循环导入)
  // 第五参为产出目录(可选, 工作区相对路径, 用于子代理工作区隔离)
  // 第六参为父级取消信号(可选): 并行派发子代理后, 父任务取消需能同步中止子代理内部循环。
  static subagentHook: ((context: common.UIAbilityContext, convId: string,
    description: string, prompt: string, outputDir?: string,
    abortSignal?: AbortSignal | null) => Promise<ToolExecResult>) | null = null;
  // @deprecated 工具定义查找已迁移到 ToolRegistry(findToolDef 内部实现), 此字段仅保留兼容。
  private static toolDefMap: Record<string, Record<string, Object>> | null = null;

  // 按名称取工具定义(供工具执行层做结构化参数校验); 找不到返回 null
  static findToolDef(name: string): Record<string, Object> | null {
    WorkFileService.ensureToolRegistry();
    return ToolRegistry.findDef(name);
  }

  // 首次访问时把工具定义 + 只读/变更分类同步进注册中心(单例, 后续走 ToolRegistry)
  private static ensureToolRegistry(): void {
    let readOnly: string[] = WorkFileService.workReadOnlyNames();
    readOnly = readOnly.concat(['glob', 'grep', 'web_fetch', 'schedule_list', 'goal_get', 'session_search']);
    let mutating: string[] = WorkFileService.workMutatingNames();
    mutating = mutating.concat(['edit', 'str_replace_editor', 'goal_create', 'goal_update',
      'schedule_create', 'schedule_delete', 'run_js']);
    ToolRegistry.ensure(WorkFileService.toolDefs(false), readOnly, mutating);
    // 并行安全标注(核心工具, 独立于只读/变更分类): subagent 是独立上下文/独立 LLM 循环的
    // 嵌套代理, 可与其他 subagent 并发派发; 由 ToolScheduler 归入并行组。
    let parallelSafe: string[] = WorkFileService.workParallelSafeNames();
    for (let i: number = 0; i < parallelSafe.length; i++) {
      ToolRegistry.setParallelSafe(parallelSafe[i], true);
    }
  }

  // 供外部(SubagentService/插件层)确保注册中心已同步
  static toolRegistrySynced(): void {
    WorkFileService.ensureToolRegistry();
  }

  // 全部工具定义(含已注册插件; 静态核心 + 插件统一走注册中心)
  static toolRegistryDefs(): Record<string, Object>[] {
    WorkFileService.ensureToolRegistry();
    return ToolRegistry.defs('');
  }

  // 工作区文件类只读工具名(与 ToolRegistry 同步用)
  private static workReadOnlyNames(): string[] {
    return ['list_files', 'read_file', 'parse_document', 'search_files', 'search_pdf', 'view_image',
      'read_ppt', 'read_docx', 'read_xlsx', 'list_skills', 'load_skill'];
  }

  // 工作区文件类变更工具名(与 ToolRegistry 同步用)
  private static workMutatingNames(): string[] {
    return ['write_file', 'append_file', 'delete_file', 'create_dir', 'move_file',
      'write_docx', 'edit_docx', 'write_xlsx', 'edit_xlsx', 'write_pptx',
      'edit_ppt', 'write_csv', 'download_file', 'write_svg', 'todo_write', 'record_search',
      'search_web', 'transform_file'];
  }

  // ===== 路径基础 =====

  // 会话工作区根目录
  static workspaceRoot(context: common.UIAbilityContext, convId: string): string {
    return context.filesDir + '/' + Constants.WORKSPACE_ROOT_DIR + '/' +
      WorkFileService.sanitizeConvId(convId);
  }

  // 会话 id 由 generateConversationId 生成, 此处兜底过滤非法字符, 防止路径拼接被注入
  private static sanitizeConvId(convId: string): string {
    let out: string = '';
    for (let i: number = 0; i < convId.length; i++) {
      let ch: string = convId.charAt(i);
      let code: number = convId.charCodeAt(i);
      let isAsciiDigit: boolean = code >= 48 && code <= 57;
      let isAsciiLower: boolean = code >= 97 && code <= 122;
      let isAsciiUpper: boolean = code >= 65 && code <= 90;
      if (isAsciiDigit || isAsciiLower || isAsciiUpper || ch === '_' || ch === '-') {
        out += ch;
      } else {
        out += '_';
      }
    }
    return out === '' ? 'empty' : out;
  }

  // 相对路径安全解析: 返回工作区内的绝对路径; 非法(绝对路径/'..'/盘符)返回 null
  static resolveSafe(root: string, rel: string): string | null {
    let clean: string = rel.trim();
    if (clean === '' || clean === '.' || clean === './') {
      return root;
    }
    if (clean.startsWith('/') || clean.indexOf(':') !== -1) {
      return null;
    }
    let segs: string[] = clean.split('/');
    let out: string = root;
    for (let i: number = 0; i < segs.length; i++) {
      let seg: string = segs[i];
      if (seg === '' || seg === '.') {
        continue;
      }
      if (seg === '..') {
        return null;
      }
      out = out + '/' + seg;
    }
    return out;
  }

  // 公共包装(HarnessTools / 新工具层使用)
  static resolveSafePublic(root: string, rel: string): string | null {
    return WorkFileService.resolveSafe(root, rel);
  }

  // read_file 的公共包装(str_replace_editor 的 view 分支复用行分页逻辑)
  static async toolReadPublic(root: string, rel: string, cacheDir: string,
    offset: number, limit: number): Promise<ToolExecResult> {
    return await WorkFileService.toolRead(root, rel, cacheDir, offset, limit);
  }

  // 逐级创建目录(等价 mkdir -p)
  static ensureDir(dir: string): void {
    if (fileIo.accessSync(dir)) {
      return;
    }
    // recursion=true 自动补齐父目录
    fileIo.mkdirSync(dir, true);
  }

  // 工作区绝对路径 → 工作区内相对路径
  private static toRelative(root: string, abs: string): string {
    if (abs.length > root.length + 1 && abs.startsWith(root + '/')) {
      return abs.substring(root.length + 1);
    }
    return '.';
  }

  // ===== 目录遍历 =====

  // 列出工作区全部条目(先序遍历, 目录后缀 '/'; 超出上限提前停止)
  static listWorkspace(context: common.UIAbilityContext, convId: string): WorkspaceFileInfo[] {
    let result: WorkspaceFileInfo[] = [];
    try {
      let root: string = WorkFileService.workspaceRoot(context, convId);
      if (!fileIo.accessSync(root)) {
        return result;
      }
      WorkFileService.walk(root, root, 0, result);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'listWorkspace failed: %{public}s', JSON.stringify(e));
    }
    return result;
  }

  private static walk(root: string, dir: string, depth: number, out: WorkspaceFileInfo[]): void {
    if (depth > Constants.WORK_LIST_MAX_DEPTH || out.length >= Constants.WORK_LIST_MAX_ENTRIES) {
      return;
    }
    let names: string[] = fileIo.listFileSync(dir);
    // 目录优先、按名称排序, 输出稳定便于模型与用户对照
    let dirs: string[] = [];
    let files: string[] = [];
    for (let i: number = 0; i < names.length; i++) {
      let abs: string = dir + '/' + names[i];
      let isDir: boolean = false;
      try {
        isDir = fileIo.statSync(abs).isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        dirs.push(names[i]);
      } else {
        files.push(names[i]);
      }
    }
    dirs.sort();
    files.sort();
    for (let i: number = 0; i < dirs.length; i++) {
      let absDir: string = dir + '/' + dirs[i];
      let info: WorkspaceFileInfo = new WorkspaceFileInfo();
      info.path = WorkFileService.toRelative(root, absDir) + '/';
      info.isDir = true;
      info.size = 0;
      out.push(info);
      if (out.length >= Constants.WORK_LIST_MAX_ENTRIES) {
        return;
      }
      WorkFileService.walk(root, absDir, depth + 1, out);
    }
    for (let i: number = 0; i < files.length; i++) {
      if (out.length >= Constants.WORK_LIST_MAX_ENTRIES) {
        return;
      }
      let absFile: string = dir + '/' + files[i];
      let size: number = 0;
      try {
        size = fileIo.statSync(absFile).size;
      } catch (e) {
        continue;
      }
      let info: WorkspaceFileInfo = new WorkspaceFileInfo();
      info.path = WorkFileService.toRelative(root, absFile);
      info.isDir = false;
      info.size = size;
      out.push(info);
    }
  }

  // 工作区文件树文本(注入运行时快照, 每轮工具调用后刷新); .spill/ 溢出暂存目录不进入快照
  static listWorkspaceTree(context: common.UIAbilityContext, convId: string): string {
    WorkFileService.ensureWorkspace(context, convId);
    let items: WorkspaceFileInfo[] = WorkFileService.listWorkspace(context, convId);
    if (items.length === 0) {
      return '(工作区为空)';
    }
    let lines: string[] = [];
    let shownCount: number = 0;
    for (let i: number = 0; i < items.length; i++) {
      let item: WorkspaceFileInfo = items[i];
      if (item.path === Constants.WORK_SPILL_DIR + '/' ||
        item.path.startsWith(Constants.WORK_SPILL_DIR + '/')) {
        continue;
      }
      shownCount++;
      if (item.isDir) {
        lines.push(item.path);
      } else {
        lines.push(item.path + ' (' + WorkFileService.formatSize(item.size) + ')');
      }
    }
    if (shownCount === 0) {
      return '(工作区为空)';
    }
    if (items.length >= Constants.WORK_LIST_MAX_ENTRIES) {
      lines.push('...(条目已达上限, 仅展示部分)');
    }
    return lines.join('\n');
  }

  static ensureWorkspace(context: common.UIAbilityContext, convId: string): void {
    WorkFileService.ensureDir(WorkFileService.workspaceRoot(context, convId));
  }

  // ===== 上传 / 导出 / 清理 =====

  // 把系统选择器选出的文件写入工作区根目录, 返回实际写入的文件名(重名自动追加序号)
  static savePickedFiles(context: common.UIAbilityContext, convId: string,
    files: PickedFile[]): string[] {
    WorkFileService.ensureWorkspace(context, convId);
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let saved: string[] = [];
    for (let i: number = 0; i < files.length; i++) {
      try {
        let name: string = WorkFileService.sanitizeFileName(files[i].name);
        name = WorkFileService.uniqueName(root, name);
        WorkFileService.writeBytes(root + '/' + name, new Uint8Array(files[i].buffer));
        saved.push(name);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'savePickedFiles failed: %{public}s', JSON.stringify(e));
      }
    }
    return saved;
  }

  // 把相机照片(uri)写入工作区, 返回文件名; 失败返回空串
  static async saveUriFile(context: common.UIAbilityContext, convId: string,
    uri: string, fallbackName: string): Promise<string> {
    let stat: fileIo.Stat = fileIo.statSync(uri);
    let file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    fileIo.readSync(file.fd, buffer, { offset: 0 });
    fileIo.closeSync(file.fd);
    WorkFileService.ensureWorkspace(context, convId);
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let name: string = WorkFileService.sanitizeFileName(fallbackName);
    name = WorkFileService.uniqueName(root, name);
    WorkFileService.writeBytes(root + '/' + name, new Uint8Array(buffer));
    return name;
  }

  // 打包整个工作区为 zip 字节(STORE 方式, 复用导出模块的 ZipWriter)
  static zipWorkspace(context: common.UIAbilityContext, convId: string): Uint8Array {
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let items: WorkspaceFileInfo[] = WorkFileService.listWorkspace(context, convId);
    let hasFile: boolean = false;
    let entries: ZipEntry[] = [];
    for (let i = 0; i < items.length; i++) {
      let item: WorkspaceFileInfo = items[i];
      if (item.isDir) {
        continue;
      }
      let abs: string = WorkFileService.resolveSafe(root, item.path);
      if (abs === null) {
        continue;
      }
      let data: Uint8Array = WorkFileService.readBytes(abs);
      let entry: ZipEntry = new ZipEntry();
      entry.name = item.path;
      entry.data = data;
      entries.push(entry);
      hasFile = true;
    }
    if (!hasFile) {
      throw new Error('工作区为空');
    }
    return ZipWriter.create(entries);
  }

  // 系统文档保存面板导出 zip 字节, 返回最终文件名; 用户取消时抛错
  static async saveZipViaPicker(context: common.UIAbilityContext, bytes: Uint8Array): Promise<string> {
    let now: Date = new Date();
    let pad = (n: number): string => {
      return n < 10 ? '0' + n : '' + n;
    };
    let baseName: string = '工作区导出_' + now.getFullYear() + pad(now.getMonth() + 1) +
      pad(now.getDate()) + '_' + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
    let options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [baseName];
    options.fileSuffixChoices = ['.zip'];
    let viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    let uris: string[] = await viewPicker.save(options);
    if (uris.length === 0) {
      throw new Error('已取消导出');
    }
    let uri: string = uris[0];
    let file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
      if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
        buffer = bytes.slice().buffer as ArrayBuffer;
      }
      fileIo.writeSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file);
    }
    return baseName + '.zip';
  }

  // 删除整个工作区目录(会话删除时清理孤儿数据)
  static deleteWorkspace(context: common.UIAbilityContext, convId: string): void {
    try {
      let root: string = WorkFileService.workspaceRoot(context, convId);
      if (fileIo.accessSync(root)) {
        WorkFileService.deleteRecursive(root);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'deleteWorkspace failed: %{public}s', JSON.stringify(e));
    }
  }

  // 删除工作区内指定相对路径(工作区面板使用); 非法路径或根目录返回 false
  static removePath(context: common.UIAbilityContext, convId: string, rel: string): boolean {
    try {
      let root: string = WorkFileService.workspaceRoot(context, convId);
      let abs: string | null = WorkFileService.resolveSafe(root, rel);
      if (abs === null || abs === root || !fileIo.accessSync(abs)) {
        return false;
      }
      WorkFileService.deleteRecursive(abs);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'removePath failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  // 把字节写入工作区相对路径(工作模式 Office 生成工具使用); 失败返回错误结果
  static writeBytesAt(context: common.UIAbilityContext, convId: string, rel: string,
    bytes: Uint8Array): ToolExecResult {
    try {
      let root: string = WorkFileService.workspaceRoot(context, convId);
      WorkFileService.ensureDir(root);
      let abs: string | null = WorkFileService.resolveSafe(root, rel);
      if (abs === null || abs === root) {
        return WorkFileService.fail('非法路径: ' + rel);
      }
      if (fileIo.accessSync(abs) && fileIo.statSync(abs).isDirectory()) {
        return WorkFileService.fail('路径是已存在的目录, 不能写入: ' + rel);
      }
      // 文本类写入(CSV/SVG/转换输出等)记录旧文本, 用于产物卡片的行级 diff 缩略
      let oldText: string | null = null;
      const TEXT_DIFF_MAX_BYTES: number = 512 * 1024;
      if (WorkFileService.isTextFile(rel) && bytes.length <= TEXT_DIFF_MAX_BYTES) {
        if (fileIo.accessSync(abs)) {
          let oldSize: number = fileIo.statSync(abs).size;
          if (oldSize <= TEXT_DIFF_MAX_BYTES) {
            let oldBytes: Uint8Array = WorkFileService.readBytes(abs, oldSize);
            if (!WorkFileService.looksBinary(oldBytes)) {
              let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
              oldText = decoder.decodeToString(oldBytes, { stream: false });
            }
          }
        } else {
          oldText = '';
        }
      }
      let parentDir: string = abs.substring(0, abs.lastIndexOf('/'));
      if (parentDir !== root) {
        WorkFileService.ensureDir(parentDir);
      }
      WorkFileService.writeBytes(abs, bytes);
      let result: ToolExecResult = WorkFileService.ok(
        '已写入 ' + rel + ' (' + WorkFileService.formatSize(bytes.length) + ')');
      if (oldText !== null && !WorkFileService.looksBinary(bytes)) {
        let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        let newText: string = decoder.decodeToString(bytes, { stream: false });
        let diff: FileDiff = DiffUtil.computeFileDiff(oldText, newText, rel,
          Constants.WORK_EDIT_CONTEXT_LINES);
        result.meta = JSON.stringify(diff.toJsonObject());
      }
      return result;
    } catch (e) {
      let msg: string = '';
      if (e instanceof Error) {
        let err: Error = e as Error;
        msg = err.message !== undefined ? err.message : String(e);
      } else {
        msg = String(e);
      }
      return WorkFileService.fail('写入失败: ' + msg);
    }
  }

  // ===== Agent 工具实现 =====

  // 工具是否只读(无任何工作区写入): 连续只读调用可安全并发执行
  static isReadOnlyTool(name: string): boolean {
    WorkFileService.ensureToolRegistry();
    return ToolRegistry.isReadOnly(name);
  }

  // 工具是否改变工作区内容(用于执行后刷新文件列表)
  static isMutatingTool(name: string): boolean {
    WorkFileService.ensureToolRegistry();
    return ToolRegistry.isMutating(name);
  }

  // 并行安全工具名单: 这类工具虽然可能写工作区, 但每次执行上下文独立,
  // 可在有界并发池中与其他并行安全工具同时执行。
  private static workParallelSafeNames(): string[] {
    return ['subagent'];
  }

  // 工具是否允许并行派发(供 ToolScheduler 分组使用)
  static isParallelSafeTool(name: string): boolean {
    WorkFileService.ensureToolRegistry();
    return ToolRegistry.isParallelSafe(name);
  }

  // 工具统一入口: 解析参数 JSON 并分发; 任何异常都转为 ERROR 结果送回模型
  static async executeTool(context: common.UIAbilityContext, convId: string,
    name: string, argsJson: string,
    abortSignal?: AbortSignal | null): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = null;
    let trimmed: string = argsJson.trim();
    if (trimmed === '') {
      trimmed = '{}';
    }
    try {
      let parsed: Object = JSON.parse(trimmed);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        args = parsed as Record<string, Object>;
      }
    } catch (e) {
      args = null;
    }
    if (args === null) {
      return WorkFileService.fail('参数不是合法的 JSON 对象: ' + WorkFileService.capChars(trimmed, 200));
    }
    try {
      return await WorkFileService.dispatchTool(context, convId, name, args, argsJson, abortSignal);
    } catch (e) {
      let msg: string = '';
      if (e instanceof Error) {
        let err: Error = e as Error;
        msg = err.message !== undefined ? err.message : String(e);
      } else {
        msg = String(e);
      }
      return WorkFileService.fail(msg);
    }
  }

  private static async dispatchTool(context: common.UIAbilityContext, convId: string,
    name: string, args: Record<string, Object>, argsJson: string,
    abortSignal?: AbortSignal | null): Promise<ToolExecResult> {
    let root: string = WorkFileService.workspaceRoot(context, convId);
    WorkFileService.ensureDir(root);
    if (name === 'list_files') {
      let rel: string = WorkFileService.strArg(args, 'path', '');
      return WorkFileService.toolList(root, rel);
    }
    if (name === 'read_file') {
      let rel: string = WorkFileService.strArg(args, 'path', '');
      let cacheDir: string = context.cacheDir + '/work_office';
      let offset: number = WorkFileService.intArg(args, 'offset', 1);
      let limit: number = WorkFileService.intArg(args, 'limit', 0);
      return await WorkFileService.toolRead(root, rel, cacheDir, offset, limit);
    }
    if (name === 'write_file' || name === 'append_file') {
      let rel: string = WorkFileService.strArg(args, 'path', '');
      let content: string = WorkFileService.strArg(args, 'content', '');
      return WorkFileService.toolWrite(root, rel, content, name === 'append_file');
    }
    if (name === 'delete_file') {
      let rel: string = WorkFileService.strArg(args, 'path', '');
      return WorkFileService.toolDelete(root, rel);
    }
    if (name === 'create_dir') {
      let rel: string = WorkFileService.strArg(args, 'path', '');
      return WorkFileService.toolMkdir(root, rel);
    }
    if (name === 'move_file') {
      let fromRel: string = WorkFileService.strArg(args, 'from', '');
      let toRel: string = WorkFileService.strArg(args, 'to', '');
      return WorkFileService.toolMove(root, fromRel, toRel);
    }
    if (name === 'search_files') {
      let query: string = WorkFileService.strArg(args, 'query', '');
      let rel: string = WorkFileService.strArg(args, 'path', '');
      let glob: string = WorkFileService.strArg(args, 'glob', '');
      let cacheDir: string = context.cacheDir + '/work_office';
      return await WorkFileService.toolSearch(root, rel, query, cacheDir, glob);
    }
    if (name === 'view_image') {
      let rel: string = WorkFileService.strArg(args, 'path', '');
      return WorkFileService.toolViewImage(context, convId, rel);
    }
    if (name === 'todo_write') {
      // 直接传原始参数 JSON: todos 可能是数组或内嵌 JSON 字符串, strArg 无法取数组
      return WorkFileService.toolTodoWrite(context, convId, argsJson);
    }
    if (name === 'record_search') {
      let query: string = WorkFileService.strArg(args, 'query', '');
      let summary: string = WorkFileService.strArg(args, 'summary', '');
      let sources: string = WorkFileService.strArg(args, 'sources', '');
      return WorkFileService.toolRecordSearch(root, query, summary, sources);
    }
    if (name === 'search_web') {
      let query: string = WorkFileService.strArg(args, 'query', '');
      return await WorkFileService.toolSearchWeb(root, query);
    }
    if (name === 'list_skills') {
      return WorkFileService.ok(WorkSkillService.listText());
    }
    if (name === 'load_skill') {
      let skillName: string = WorkFileService.strArg(args, 'name', '');
      let file: string = WorkFileService.strArg(args, 'file', '');
      if (skillName === '') {
        return WorkFileService.fail('缺少参数 name(技能 id, 见 list_skills)');
      }
      let loaded: string = await WorkSkillService.load(context, skillName, file);
      if (loaded.startsWith('ERROR:')) {
        return WorkFileService.fail(loaded.substring(6).trim());
      }
      return WorkFileService.ok(loaded);
    }
    // Guncat Work 6.1 新增工具(glob/grep/edit/str_replace_editor/web_fetch/
    // ask_user_question/schedule_*/goal_*/subagent/session_search)由 HarnessTools 兜底
    return await HarnessTools.dispatch(context, convId, name, args, root, abortSignal);
  }

  // record_search: 把服务端联网搜索的结论落盘为 .searches.md, 留下可追溯记录
  // (服务端搜索不产生本地工具调用, 对话历史里查不到; 该文件不参与上下文压缩, 永远可查)
  private static toolRecordSearch(root: string, query: string, summary: string,
    sources: string): ToolExecResult {
    if (query.trim() === '') {
      return WorkFileService.fail('缺少参数 query');
    }
    if (summary.trim() === '') {
      return WorkFileService.fail('缺少参数 summary');
    }
    let abs: string | null = WorkFileService.resolveSafe(root, '.searches.md');
    if (abs === null) {
      return WorkFileService.fail('非法路径');
    }
    let block: string = '\n## ' + WorkFileService.formatStamp(new Date().getTime()) +
      ' · ' + query.trim() + '\n' + summary.trim() + '\n';
    if (sources.trim() !== '') {
      block = block + '来源:\n' + sources.trim() + '\n';
    }
    return WorkFileService.toolWrite(root, '.searches.md', block, true);
  }

  // search_web: 手机本地直连搜索引擎(不经过模型服务商服务端)。
  // 结果清单送回模型的同时自动登记到 .searches.md —— 本地搜索虽然会在对话历史留下
  // 工具调用, 但旧轮次的结果会被上下文压缩/修剪, 落盘记录永远可由 read_file 找回。
  private static async toolSearchWeb(root: string, query: string): Promise<ToolExecResult> {
    if (query.trim() === '') {
      return WorkFileService.fail('缺少参数 query');
    }
    let outcome: LocalSearchOutcome = await LocalWebSearch.searchWeb(query);
    if (!outcome.ok) {
      return WorkFileService.fail(outcome.errorMessage === '' ? '搜索失败' : outcome.errorMessage);
    }
    let block: string = '\n## ' + WorkFileService.formatStamp(new Date().getTime()) +
      ' · ' + query.trim() + '（本地内置搜索 · ' + outcome.engineLabel + '）\n来源:\n';
    let maxUrls: number = outcome.items.length > 8 ? 8 : outcome.items.length;
    for (let i: number = 0; i < maxUrls; i++) {
      block = block + '- [' + outcome.items[i].title + '](' + outcome.items[i].url + ')\n';
    }
    WorkFileService.toolWrite(root, '.searches.md', block, true);
    let head: string = '【本地内置联网搜索】(手机直连 · ' + outcome.engineLabel +
      ' · 结果已自动登记到 .searches.md)\n\n';
    return WorkFileService.ok(head + outcome.contentForAI);
  }

  private static formatStamp(ts: number): string {
    let d: Date = new Date(ts);
    let month: string = d.getMonth() + 1 < 10 ?
      '0' + (d.getMonth() + 1).toString() : (d.getMonth() + 1).toString();
    let day: string = d.getDate() < 10 ? '0' + d.getDate().toString() : d.getDate().toString();
    let h: string = d.getHours() < 10 ? '0' + d.getHours().toString() : d.getHours().toString();
    let m: string = d.getMinutes() < 10 ? '0' + d.getMinutes().toString() : d.getMinutes().toString();
    let s: string = d.getSeconds() < 10 ? '0' + d.getSeconds().toString() : d.getSeconds().toString();
    return d.getFullYear().toString() + '-' + month + '-' + day + ' ' + h + ':' + m + ':' + s;
  }

  // view_image: 读取工作区图片并编码为 dataUrl(由循环注入下一条多模态消息)
  private static toolViewImage(context: common.UIAbilityContext, convId: string,
    rel: string): ToolExecResult {
    if (rel === '') {
      return WorkFileService.fail('缺少参数 path');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkFileService.fail('非法路径: ' + rel);
    }
    if (!fileIo.accessSync(abs)) {
      return WorkFileService.fail('文件不存在: ' + rel);
    }
    if (fileIo.statSync(abs).isDirectory()) {
      return WorkFileService.fail('路径是目录而非文件: ' + rel);
    }
    let lower: string = rel.toLowerCase();
    let mime: string = '';
    if (lower.endsWith('.png')) {
      mime = 'image/png';
    } else if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      mime = 'image/jpeg';
    } else if (lower.endsWith('.webp')) {
      mime = 'image/webp';
    } else if (lower.endsWith('.gif')) {
      mime = 'image/gif';
    } else if (lower.endsWith('.bmp')) {
      mime = 'image/bmp';
    } else {
      return WorkFileService.fail('view_image 仅支持图片文件(png/jpg/jpeg/webp/gif/bmp): ' + rel);
    }
    let stat: fileIo.Stat = fileIo.statSync(abs);
    if (stat.size > Constants.WORK_VIEW_IMAGE_MAX_BYTES) {
      return WorkFileService.fail('图片超过 ' +
        WorkFileService.formatSize(Constants.WORK_VIEW_IMAGE_MAX_BYTES) + ' 上限, 请先压缩');
    }
    let buffer: ArrayBuffer = WorkFileService.readBytesPublic(abs, Constants.WORK_VIEW_IMAGE_MAX_BYTES);
    let r: ToolExecResult = new ToolExecResult();
    r.ok = true;
    r.output = '图片已加载并作为下一条消息发送给你, 请结合当前任务分析图中内容。';
    r.imageDataUrl = 'data:' + mime + ';base64,' + arrayBufferToBase64(buffer);
    return r;
  }

  // todo_write: 校验并保存任务清单到工作区 .todo.json, 返回渲染后的清单文本
  // 兼容三种传参: {"todos":[...]} / {"todos":"[...]"} / 直接的数组
  private static toolTodoWrite(context: common.UIAbilityContext, convId: string,
    argsJson: string): ToolExecResult {
    let arrText: string = '';
    let trimmed: string = argsJson.trim();
    if (trimmed === '') {
      return WorkFileService.fail('缺少 todos 参数');
    }
    let head: string = trimmed.charAt(0);
    if (head === '[') {
      // 整个参数就是数组
      arrText = trimmed;
    } else {
      // 外层是参数对象, 取出 todos 字段(数组或内嵌 JSON 字符串)
      let parsedArgs: Object;
      try {
        parsedArgs = JSON.parse(trimmed);
      } catch (e) {
        return WorkFileService.fail('参数不是合法的 JSON 对象');
      }
      if (typeof parsedArgs !== 'object' || parsedArgs === null ||
        parsedArgs instanceof Array) {
        return WorkFileService.fail('参数不是合法的 JSON 对象');
      }
      let todosVal: Object = (parsedArgs as Record<string, Object>)['todos'];
      if (typeof todosVal === 'string') {
        arrText = (todosVal as string).trim();
      } else if (todosVal !== undefined && todosVal !== null && todosVal instanceof Array) {
        arrText = JSON.stringify(todosVal);
      } else {
        return WorkFileService.fail('缺少 todos 参数(JSON 数组), 如 {"todos":[{"content":"步骤","status":"pending"}]}');
      }
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(arrText);
    } catch (e) {
      return WorkFileService.fail('todos 不是合法的 JSON 数组: ' +
        WorkFileService.capChars(arrText, 120));
    }
    if (!(parsed instanceof Array)) {
      return WorkFileService.fail('todos 需要是 JSON 数组, 如 [{"content":"步骤","status":"pending"}]');
    }
    let arr: Object[] = parsed as Object[];
    if (arr.length === 0) {
      return WorkFileService.fail('任务清单不能为空');
    }
    if (arr.length > 50) {
      return WorkFileService.fail('任务清单最多 50 项');
    }
    let lines: string[] = [];
    let records: Object[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      let item: Object = arr[i];
      if (typeof item !== 'object' || item === null || item instanceof Array) {
        return WorkFileService.fail('第 ' + (i + 1).toString() + ' 项不是对象');
      }
      let rec: Record<string, Object> = item as Record<string, Object>;
      let content: Object = rec['content'];
      let status: Object = rec['status'];
      if (typeof content !== 'string' || (content as string).trim() === '') {
        return WorkFileService.fail('第 ' + (i + 1).toString() + ' 项缺少 content');
      }
      let contentStr: string = (content as string).trim();
      if (contentStr.length > 200) {
        contentStr = contentStr.substring(0, 200);
      }
      let statusStr: string = typeof status === 'string' ? status as string : 'pending';
      if (statusStr === 'done') {
        // 旧词表兼容: 历史清单与模型惯性都可能写 done, 统一归一为 completed 再落盘
        statusStr = 'completed';
      }
      if (statusStr !== 'pending' && statusStr !== 'in_progress' && statusStr !== 'completed') {
        statusStr = 'pending';
      }
      let record: Record<string, Object> = { 'content': contentStr, 'status': statusStr };
      records.push(record);
      let mark: string = statusStr === 'completed' ? '[已完成]' :
        (statusStr === 'in_progress' ? '[进行中]' : '[待开始]');
      lines.push(mark + ' ' + (i + 1).toString() + '. ' + contentStr);
    }
    try {
      let root: string = WorkFileService.workspaceRoot(context, convId);
      WorkFileService.ensureDir(root);
      let encoder: util.TextEncoder = new util.TextEncoder();
      let bytes: Uint8Array = encoder.encode(JSON.stringify(records));
      WorkFileService.writeBytes(root + '/' + Constants.WORK_TODO_FILE, bytes);
    } catch (e) {
      let msg: string = '';
      if (e instanceof Error) {
        let err: Error = e as Error;
        msg = err.message !== undefined ? err.message : String(e);
      } else {
        msg = String(e);
      }
      return WorkFileService.fail('任务清单保存失败: ' + msg);
    }
    return WorkFileService.ok('任务清单已更新(' + records.length.toString() + ' 项):\n' + lines.join('\n'));
  }

  // 读取当前任务清单(注入系统提示; 无清单返回空串)
  static readTodo(context: common.UIAbilityContext, convId: string): string {
    try {
      let root: string = WorkFileService.workspaceRoot(context, convId);
      let todoPath: string = root + '/' + Constants.WORK_TODO_FILE;
      if (!fileIo.accessSync(todoPath)) {
        return '';
      }
      let bytes: Uint8Array = WorkFileService.readBytes(todoPath, 64 * 1024);
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      let json: string = decoder.decodeToString(bytes, { stream: false });
      let parsed: Object = JSON.parse(json);
      if (!(parsed instanceof Array)) {
        return '';
      }
      let arr: Object[] = parsed as Object[];
      let lines: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        let rec: Record<string, Object> = arr[i] as Record<string, Object>;
        let content: Object = rec['content'];
        let status: Object = rec['status'];
        let contentStr: string = typeof content === 'string' ? content as string : '';
        let statusStr: string = typeof status === 'string' ? status as string : 'pending';
        if (contentStr === '') {
          continue;
        }
        // done 是旧词表: 兼容升级前已落盘的清单文件
        let mark: string = (statusStr === 'completed' || statusStr === 'done') ? '[x]' :
          (statusStr === 'in_progress' ? '[~]' : '[ ]');
        lines.push(mark + ' ' + contentStr);
      }
      return lines.join('\n');
    } catch (e) {
      return '';
    }
  }

  private static toolList(root: string, rel: string): ToolExecResult {
    if (rel === '') {
      let items: WorkspaceFileInfo[] = [];
      if (fileIo.accessSync(root)) {
        WorkFileService.walk(root, root, 0, items);
      }
      if (items.length === 0) {
        return WorkFileService.ok('工作区为空');
      }
      let lines: string[] = [];
      for (let i: number = 0; i < items.length; i++) {
        let item: WorkspaceFileInfo = items[i];
        lines.push(item.isDir ? item.path : item.path + ' (' + WorkFileService.formatSize(item.size) + ')');
      }
      if (items.length >= Constants.WORK_LIST_MAX_ENTRIES) {
        lines.push('...(条目已达上限)');
      }
      return WorkFileService.ok(lines.join('\n'));
    }
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkFileService.fail('非法路径: ' + rel);
    }
    if (!fileIo.accessSync(abs)) {
      return WorkFileService.fail('路径不存在: ' + rel);
    }
    if (!fileIo.statSync(abs).isDirectory()) {
      return WorkFileService.fail('不是目录: ' + rel);
    }
    let items: WorkspaceFileInfo[] = [];
    WorkFileService.walk(abs, abs, 0, items);
    if (items.length === 0) {
      return WorkFileService.ok('目录为空: ' + rel);
    }
    let lines: string[] = [];
    for (let i: number = 0; i < items.length; i++) {
      let item: WorkspaceFileInfo = items[i];
      let shown: string = rel.replace(/\/+$/, '') + '/' + item.path;
      lines.push(item.isDir ? shown : shown + ' (' + WorkFileService.formatSize(item.size) + ')');
    }
    return WorkFileService.ok(lines.join('\n'));
  }

  // read_file: 文本/Office 按行分页读取(offset 1-based; limit<=0 用默认行数)
  private static async toolRead(root: string, rel: string, cacheDir: string,
    offset: number, limit: number): Promise<ToolExecResult> {
    if (rel === '') {
      return WorkFileService.fail('缺少参数 path');
    }
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkFileService.fail('非法路径: ' + rel);
    }
    if (!fileIo.accessSync(abs)) {
      return WorkFileService.fail('文件不存在: ' + rel);
    }
    let stat: fileIo.Stat = fileIo.statSync(abs);
    if (stat.isDirectory()) {
      return WorkFileService.fail('路径是目录而非文件: ' + rel);
    }
    if (stat.size === 0) {
      return WorkFileService.ok('(空文件)');
    }
    let lower: string = rel.toLowerCase();
    // PDF: 系统 PDF Kit 整文快捷读取(超长文档由 extractText 附分页提示)
    if (lower.endsWith('.pdf')) {
      try {
        let text: string = await PdfTextExtractor.extractText(abs, Constants.WORK_RESULT_MAX_CHARS);
        return WorkFileService.ok(text);
      } catch (e) {
        let msg: string = '';
        if (e instanceof Error) {
          let err: Error = e as Error;
          msg = err.message !== undefined ? err.message : String(e);
        } else {
          msg = String(e);
        }
        return WorkFileService.fail('PDF 解析失败(' + msg + ')');
      }
    }
    let fullText: string = '';
    // Office: 全量抽取(带缓存), 行号与 search_files 一致
    if (WorkFileService.isOfficeFile(rel)) {
      try {
        fullText = await WorkFileService.officeFullText(abs, cacheDir);
      } catch (e) {
        let msg: string = '';
        if (e instanceof Error) {
          let err: Error = e as Error;
          msg = err.message !== undefined ? err.message : String(e);
        } else {
          msg = String(e);
        }
        return WorkFileService.fail('本地解析失败(' + msg + ')');
      }
    } else {
      // 纯文本: 全量读取(上限 1MB)后按行分页
      let cap: number = Constants.WORK_READ_FULL_MAX_BYTES;
      let readLen: number = stat.size < cap ? stat.size : cap;
      let bytes: Uint8Array = WorkFileService.readBytes(abs, readLen);
      if (WorkFileService.looksBinary(bytes)) {
        return WorkFileService.fail('这是二进制文件, 无法按文本读取; PDF 可用 parse_document 解析, PDF 内搜索用 search_pdf');
      }
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      fullText = decoder.decodeToString(bytes, { stream: false });
      if (stat.size > cap) {
        fullText += '\n...(文件过大, 仅前 ' + WorkFileService.formatSize(cap) + ' 参与读取)';
      }
    }
    return WorkFileService.pagedTextResult(fullText, rel, offset, limit);
  }

  // 按行分页组装返回: 字符预算 WORK_RESULT_MAX_CHARS, 行数上限 WORK_READ_MAX_LINES;
  // 未读完时末尾附继续读取提示(offset 与 search_files 的行号一致)
  private static pagedTextResult(fullText: string, rel: string,
    offset: number, limit: number): ToolExecResult {
    if (fullText.trim() === '') {
      return WorkFileService.ok('(空文件)');
    }
    let lines: string[] = fullText.split('\n');
    let total: number = lines.length;
    let start: number = offset < 1 ? 1 : offset;
    if (start > total) {
      return WorkFileService.fail('offset=' + start.toString() + ' 超出范围(全文共 ' +
        total.toString() + ' 行)');
    }
    let wantLines: number = limit > 0 ? Math.min(limit, Constants.WORK_READ_MAX_LINES)
      : Constants.WORK_READ_MAX_LINES;
    let out: string[] = [];
    let produced: number = 0;
    let i: number = start - 1;
    for (; i < total && out.length < wantLines; i++) {
      let line: string = lines[i];
      if (line.length > Constants.WORK_RESULT_MAX_CHARS) {
        line = line.substring(0, Constants.WORK_RESULT_MAX_CHARS) + '...(超长行已截断)';
      }
      // 超字符预算时整行停下(已有内容才停, 保证至少返回一行)
      if (produced + line.length + 1 > Constants.WORK_RESULT_MAX_CHARS && out.length > 0) {
        break;
      }
      out.push(line);
      produced += line.length + 1;
    }
    let text: string = out.join('\n');
    if (i < total) {
      text += '\n\n—— 未读完(全文共 ' + total.toString() + ' 行)。继续读取: read_file 传 {"path":"' +
        rel + '","offset":' + (start + out.length).toString() + '}(行号与 search_files 结果一致)';
    } else if (start > 1) {
      text += '\n\n—— 已到文件末尾(全文共 ' + total.toString() + ' 行)。';
    }
    return WorkFileService.ok(text);
  }

  private static toolWrite(root: string, rel: string, content: string, append: boolean): ToolExecResult {
    if (rel === '') {
      return WorkFileService.fail('缺少参数 path');
    }
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkFileService.fail('非法路径: ' + rel);
    }
    if (fileIo.accessSync(abs) && fileIo.statSync(abs).isDirectory()) {
      return WorkFileService.fail('路径是已存在的目录, 不能写入: ' + rel);
    }
    // 写入前旧文本: 新文件为 '', 文本文件读旧内容用于生成行级 diff; 二进制/Office 不生成
    let oldText: string | null = null;
    if (!fileIo.accessSync(abs)) {
      oldText = '';
    } else if (WorkFileService.isTextFile(rel)) {
      let oldSize: number = fileIo.statSync(abs).size;
      let oldBytes: Uint8Array = WorkFileService.readBytes(abs, oldSize);
      if (!WorkFileService.looksBinary(oldBytes)) {
        let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        oldText = decoder.decodeToString(oldBytes, { stream: false });
      }
    }
    let encoder: util.TextEncoder = new util.TextEncoder();
    let bytes: Uint8Array = encoder.encode(content);
    if (bytes.length > Constants.WORK_WRITE_MAX_BYTES) {
      return WorkFileService.fail('内容超出单次写入上限 ' + WorkFileService.formatSize(Constants.WORK_WRITE_MAX_BYTES) +
        '(实际 ' + WorkFileService.formatSize(bytes.length) + '), 请分多次 append_file 写入');
    }
    if (append && fileIo.accessSync(abs)) {
      // 简化追加语义: 读旧内容拼接后整体重写(避免依赖写指针定位的版本差异)
      let oldSize: number = fileIo.statSync(abs).size;
      let oldBytes: Uint8Array = WorkFileService.readBytes(abs, oldSize);
      let merged: Uint8Array = new Uint8Array(oldBytes.length + bytes.length);
      merged.set(oldBytes, 0);
      merged.set(bytes, oldBytes.length);
      bytes = merged;
      if (bytes.length > Constants.WORK_WRITE_MAX_BYTES) {
        return WorkFileService.fail('追加后文件超出上限 ' + WorkFileService.formatSize(Constants.WORK_WRITE_MAX_BYTES) + ', 写入被拒绝');
      }
    }
    let parentDir: string = abs.substring(0, abs.lastIndexOf('/'));
    if (parentDir !== root) {
      WorkFileService.ensureDir(parentDir);
    }
    WorkFileService.writeBytes(abs, bytes);
    let verb: string = append ? '追加写入' : '写入';
    let result: ToolExecResult = WorkFileService.ok(
      '已' + verb + ' ' + rel + ' (' + WorkFileService.formatSize(bytes.length) + ')');
    if (oldText !== null) {
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      let newText: string = decoder.decodeToString(bytes, { stream: false });
      let diff: FileDiff = DiffUtil.computeFileDiff(oldText, newText, rel,
        Constants.WORK_EDIT_CONTEXT_LINES);
      result.meta = JSON.stringify(diff.toJsonObject());
    }
    return result;
  }

  private static toolDelete(root: string, rel: string): ToolExecResult {
    if (rel === '') {
      // 空路径表示清空整个工作区
      let items: WorkspaceFileInfo[] = [];
      if (fileIo.accessSync(root)) {
        WorkFileService.walk(root, root, 0, items);
      }
      if (items.length === 0) {
        return WorkFileService.ok('工作区已为空');
      }
      WorkFileService.deleteRecursive(root);
      WorkFileService.ensureDir(root);
      return WorkFileService.ok('已清空工作区(' + items.length.toString() + ' 项)');
    }
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkFileService.fail('非法路径: ' + rel);
    }
    if (abs === root) {
      return WorkFileService.fail('不能删除工作区根目录, 如需清空请传 path 为空字符串');
    }
    if (!fileIo.accessSync(abs)) {
      return WorkFileService.fail('路径不存在: ' + rel);
    }
    WorkFileService.deleteRecursive(abs);
    return WorkFileService.ok('已删除 ' + rel);
  }

  private static toolMkdir(root: string, rel: string): ToolExecResult {
    if (rel === '') {
      return WorkFileService.fail('缺少参数 path');
    }
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkFileService.fail('非法路径: ' + rel);
    }
    if (fileIo.accessSync(abs)) {
      let isDir: boolean = fileIo.statSync(abs).isDirectory();
      return isDir ? WorkFileService.ok('目录已存在: ' + rel)
        : WorkFileService.fail('同名文件已存在, 无法创建目录: ' + rel);
    }
    WorkFileService.ensureDir(abs);
    return WorkFileService.ok('已创建目录 ' + rel);
  }

  private static toolMove(root: string, fromRel: string, toRel: string): ToolExecResult {
    if (fromRel === '' || toRel === '') {
      return WorkFileService.fail('缺少参数 from/to');
    }
    let src: string | null = WorkFileService.resolveSafe(root, fromRel);
    let dst: string | null = WorkFileService.resolveSafe(root, toRel);
    if (src === null || dst === null) {
      return WorkFileService.fail('非法路径: ' + fromRel + ' / ' + toRel);
    }
    if (src === root) {
      return WorkFileService.fail('不能移动工作区根目录');
    }
    if (!fileIo.accessSync(src)) {
      return WorkFileService.fail('源路径不存在: ' + fromRel);
    }
    if (dst === root) {
      return WorkFileService.fail('目标不能是工作区根目录: ' + toRel);
    }
    if (fileIo.accessSync(dst)) {
      return WorkFileService.fail('目标路径已存在: ' + toRel);
    }
    let parentDir: string = dst.substring(0, dst.lastIndexOf('/'));
    if (parentDir !== root) {
      WorkFileService.ensureDir(parentDir);
    }
    let srcIsDir: boolean = fileIo.statSync(src).isDirectory();
    if (srcIsDir) {
      fileIo.moveDirSync(src, dst);
    } else {
      fileIo.moveFileSync(src, dst);
    }
    return WorkFileService.ok('已移动 ' + fromRel + ' → ' + toRel);
  }

  private static async toolSearch(root: string, rel: string, query: string,
    cacheDir: string, glob: string): Promise<ToolExecResult> {
    if (query === '') {
      return WorkFileService.fail('缺少参数 query');
    }
    let base: string = root;
    let basePrefix: string = '';
    if (rel !== '') {
      let abs: string | null = WorkFileService.resolveSafe(root, rel);
      if (abs === null) {
        return WorkFileService.fail('非法路径: ' + rel);
      }
      if (!fileIo.accessSync(abs)) {
        return WorkFileService.fail('路径不存在: ' + rel);
      }
      if (!fileIo.statSync(abs).isDirectory()) {
        return WorkFileService.fail('search_files 的 path 需要是目录: ' + rel);
      }
      base = abs;
      basePrefix = rel.replace(/\/+$/, '') + '/';
    }
    let qLower: string = query.toLowerCase();
    let globs: RegExp[] = WorkFileService.globToRegexes(glob);
    let matches: string[] = [];
    await WorkFileService.searchWalk(base, basePrefix, qLower, matches, cacheDir, globs);
    if (matches.length === 0) {
      let msg: string = '未找到匹配 "' + query + '" 的内容';
      if (globs.length > 0) {
        msg += '(文件名过滤: ' + glob + ')';
      }
      return WorkFileService.ok(msg);
    }
    let header: string = '共 ' + matches.length.toString() + ' 处匹配:';
    if (globs.length > 0) {
      header += '(文件名过滤: ' + glob + ')';
    }
    return WorkFileService.ok(header + '\n' + matches.join('\n'));
  }

  // glob 模式 -> 正则(整串匹配, 大小写不敏感); 支持逗号分隔多个模式; 目录遍历不受 glob 限制(仅过滤文件名)
  private static globToRegexes(glob: string): RegExp[] {
    let regs: RegExp[] = [];
    let patterns: string[] = glob.split(',');
    for (let i: number = 0; i < patterns.length; i++) {
      let pattern: string = patterns[i].trim();
      if (pattern === '') {
        continue;
      }
      regs.push(WorkFileService.globRegexOne(pattern));
    }
    return regs;
  }

  private static globRegexOne(pattern: string): RegExp {
    let re: string = '';
    for (let i: number = 0; i < pattern.length; i++) {
      let ch: string = pattern.charAt(i);
      if (ch === '*') {
        re += '.*';
      } else if (ch === '?') {
        re += '.';
      } else if ('.+^${}()|[]\\'.indexOf(ch) !== -1) {
        re += '\\' + ch;
      } else {
        re += ch;
      }
    }
    return new RegExp('^' + re + '$', 'i');
  }

  private static matchGlob(name: string, globs: RegExp[]): boolean {
    if (globs.length === 0) {
      return true;
    }
    for (let i: number = 0; i < globs.length; i++) {
      if (globs[i].test(name)) {
        return true;
      }
    }
    return false;
  }

  private static async searchWalk(dir: string, prefix: string, qLower: string,
    matches: string[], cacheDir: string, globs: RegExp[]): Promise<void> {
    if (matches.length >= Constants.WORK_SEARCH_MAX_MATCHES) {
      return;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return;
    }
    names.sort();
    for (let i: number = 0; i < names.length; i++) {
      if (matches.length >= Constants.WORK_SEARCH_MAX_MATCHES) {
        return;
      }
      let abs: string = dir + '/' + names[i];
      let size: number = 0;
      let isDir: boolean = false;
      try {
        let st: fileIo.Stat = fileIo.statSync(abs);
        size = st.size;
        isDir = st.isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        await WorkFileService.searchWalk(abs, prefix + names[i] + '/', qLower, matches, cacheDir, globs);
        continue;
      }
      // glob 文件名过滤(仅作用于文件, 目录仍递归进入)
      if (!WorkFileService.matchGlob(names[i], globs)) {
        continue;
      }
      // Office 文档(zip 容器): 抽取文字层后按行匹配(行号与 read_file 分页一致)
      if (WorkFileService.isOfficeFile(names[i])) {
        if (size === 0 || size > Constants.WORK_SEARCH_OFFICE_MAX_BYTES) {
          continue;
        }
        try {
          let officeText: string = await WorkFileService.officeFullText(abs, cacheDir);
          WorkFileService.matchLines(officeText.split('\n'), qLower, prefix + names[i], matches);
        } catch (e) {
          // 抽取失败跳过该文件
        }
        continue;
      }
      if (!WorkFileService.isTextFile(names[i])) {
        continue;
      }
      try {
        if (size === 0 || size > Constants.WORK_SEARCH_FILE_MAX_BYTES) {
          continue;
        }
        let bytes: Uint8Array = WorkFileService.readBytes(abs, size);
        if (WorkFileService.looksBinary(bytes)) {
          continue;
        }
        let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        let text: string = decoder.decodeToString(bytes, { stream: false });
        WorkFileService.matchLines(text.split('\n'), qLower, prefix + names[i], matches);
      } catch (e) {
        // 单文件失败跳过
      }
      if (matches.length >= Constants.WORK_SEARCH_MAX_MATCHES) {
        return;
      }
    }
  }

  // 行级子串匹配: 命中追加 "文件:行号: 内容"(单行展示上限 200 字符)
  private static matchLines(lines: string[], qLower: string, fileLabel: string,
    matches: string[]): void {
    for (let ln: number = 0; ln < lines.length; ln++) {
      if (matches.length >= Constants.WORK_SEARCH_MAX_MATCHES) {
        return;
      }
      if (lines[ln].toLowerCase().indexOf(qLower) !== -1) {
        let shown: string = lines[ln].trim();
        if (shown.length > 200) {
          shown = shown.substring(0, 200) + '...';
        }
        matches.push(fileLabel + ':' + (ln + 1).toString() + ': ' + shown);
      }
    }
  }

  // ===== 工具定义(送入模型的 JSON Schema, 协议无关的中间表示) =====

  // webSearchEnabled: 服务端联网搜索是否开启 —— 开启时 search_web 描述切换为"兜底版",
  // 引导模型优先走服务端 web_search(描述跟随托管工具同步增删, 不引入额外的前缀缓存失效)
  static toolDefs(webSearchEnabled: boolean): Record<string, Object>[] {
    let defs: Record<string, Object>[] = [];
    defs.push(WorkFileService.makeTool('list_files',
      '列出工作区中的文件与目录。path 为空时列出整个工作区(含子目录), 否则列出指定目录。返回每项的相对路径与大小。',
      WorkFileService.props1('path', WorkFileService.strProp('要列出的目录相对路径, 留空表示工作区根目录')),
      []));
    defs.push(WorkFileService.makeTool('read_file',
      '读取工作区文件内容, 按行分页(默认从第 1 行返回约 1.2 万字符, 末尾附"未读完"提示与下一次 offset)。.docx/.xlsx/.pptx 自动抽取文字层, 行号与 search_files 一致; .pdf 自动解析文本, 超长请用 parse_document 分页; 二进制文件拒绝读取。修改文件前应先读取确认现状。',
      WorkFileService.props3(
        'path', WorkFileService.strProp('要读取的文件相对路径'),
        'offset', WorkFileService.strProp('起始行号(从 1 起), 默认 1; 续读用上次提示中的 offset'),
        'limit', WorkFileService.strProp('本次返回行数, 默认按字符预算自动截取, 最大 600')),
      ['path']));
    defs.push(WorkFileService.makeTool('write_file',
      '把文本内容写入工作区文件(覆盖已有内容), 自动创建缺失的父目录。长内容请分多次 write_file/append_file。',
      WorkFileService.props2(
        'path', WorkFileService.strProp('目标文件相对路径'),
        'content', WorkFileService.strProp('要写入的完整文本内容')),
      ['path', 'content']));
    defs.push(WorkFileService.makeTool('append_file',
      '把文本内容追加到工作区文件末尾(文件不存在则创建)。',
      WorkFileService.props2(
        'path', WorkFileService.strProp('目标文件相对路径'),
        'content', WorkFileService.strProp('要追加的文本内容')),
      ['path', 'content']));
    defs.push(WorkFileService.makeTool('delete_file',
      '删除工作区中的文件或目录(目录递归删除)。path 为空字符串表示清空整个工作区。',
      WorkFileService.props1('path', WorkFileService.strProp('要删除的文件或目录相对路径, 空字符串表示清空整个工作区')),
      ['path']));
    defs.push(WorkFileService.makeTool('create_dir',
      '在工作区创建目录(自动创建父目录)。',
      WorkFileService.props1('path', WorkFileService.strProp('要创建的目录相对路径')),
      ['path']));
    defs.push(WorkFileService.makeTool('move_file',
      '移动或重命名工作区中的文件或目录(目标路径不能已存在)。',
      WorkFileService.props2(
        'from', WorkFileService.strProp('源文件或目录相对路径'),
        'to', WorkFileService.strProp('目标相对路径(可改名, 自动创建父目录)')),
      ['from', 'to']));
    defs.push(WorkFileService.makeTool('search_files',
      '在工作区文本文件与 Office 文档(.docx/.xlsx/.pptx 自动抽取文字层)中按大小写不敏感的子串搜索, 返回 文件:行号: 内容 列表(最多 50 处)。glob 可选, 按文件名过滤(支持 * 与 ?, 多个模式用逗号分隔, 如 "*.md" 或 "*.png,*.jpg"), 目录仍会递归进入。Office 的行号对应 read_file 抽取文本的行, 定位后用 read_file 传 offset 精读该段。',
      WorkFileService.props3(
        'query', WorkFileService.strProp('搜索关键词(子串匹配)'),
        'path', WorkFileService.strProp('搜索的目录相对路径, 留空表示整个工作区'),
        'glob', WorkFileService.strProp('可选: 文件名 glob 过滤, 如 "*.md" 或 "*.png,*.jpg"')),
      ['query']));
    defs.push(WorkFileService.makeTool('write_csv',
      '把表格数据生成 CSV 文件写入工作区(UTF-8, 默认带 BOM, Excel/WPS 打开中文不乱码; 字段按 RFC 4180 转义)。table 支持 Markdown 表格(| 分隔)、CSV 或 TSV, 与 write_xlsx 相同的解析。轻量结构化数据、后续还要程序化处理或再加工时选 CSV; 需要样式/多工作表/数字格式时用 write_xlsx。',
      WorkFileService.props3(
        'path', WorkFileService.strProp('目标文件相对路径(建议以 .csv 结尾)'),
        'table', WorkFileService.strProp('表格数据文本: Markdown 表格、CSV 或 TSV, 首行为表头'),
        'bom', WorkFileService.strProp('可选: 是否写 UTF-8 BOM, 默认 true; 供程序严格读取时可传 false')),
      ['path', 'table']));
    defs.push(WorkFileService.makeTool('download_file',
      '把 http(s) 链接的文件下载到工作区(单文件 ≤20MB, 自动创建父目录)。联网搜索或资料中发现可用的图片/素材/数据文件时, 用它把原件拿到本地再用——write_pptx/write_docx 只能引用工作区里真实存在的图片, 不要编造路径。path 省略时按 URL 文件名自动命名(重名自动加序号)。返回会报告实际类型与大小; 若下载到的是网页(text/html)说明直链失效, 换链接重试。',
      WorkFileService.props2(
        'url', WorkFileService.strProp('要下载的 http(s) 链接'),
        'path', WorkFileService.strProp('可选: 保存的相对路径(含文件名, 如 assets/logo.png); 省略按 URL 命名')),
      ['url']));
    defs.push(WorkFileService.makeTool('write_svg',
      '把 SVG 源码保存为矢量文件并自动栅格化出 PNG 预览(<name>_preview.png)。生成图片的主要手段: 图标、示意图、流程图、信息图、插画都由你手写 SVG 完成。使用前先 load_skill("svg") 获取绘制规范与配方: 根元素必须带 xmlns 与 viewBox, 图形优先 path+fill 描边风格(少用依赖系统字体的 text 元素)。生成后必须 view_image 预览确认再交付; write_pptx 可直接引用 .svg(自动栅格化), write_docx 引用预览 PNG。',
      WorkFileService.props3(
        'path', WorkFileService.strProp('目标文件相对路径(以 .svg 结尾, 如 assets/icon.svg)'),
        'svg', WorkFileService.strProp('完整的 SVG 源码文本'),
        'width', WorkFileService.strProp('可选: 预览 PNG 的宽度(px), 默认 512, 高度按 viewBox 比例自动计算')),
      ['path', 'svg']));
    defs.push(WorkFileService.makeTool('write_docx',
      '把结构化 Doc JSON 或 Markdown 生成 Word 文档(.docx)写入工作区。正式文档用 doc(Doc JSON 结构化源: 封面/目录/分级标题/正文/列表/表格/图片/引用/代码块, 图片 src 支持工作区相对路径, 排版规范)或 doc_file(工作区中 Doc JSON 文件路径, 长文档先 write_file/append_file 分块写好再导出); 简单内容可直接传 markdown(与旧版一致, 图片同样支持工作区路径)。title 可选文档标题, style 可选样式预设 default/academic/minimal。做正式 Word 文档前必须先 load_skill("docx") 全量加载；新建前 ask_user_question 前置提问；交付前写 docx_qa_report.md。',
      WorkFileService.props6(
        'path', WorkFileService.strProp('目标文件相对路径(建议以 .docx 结尾)'),
        'doc', WorkFileService.strProp('可选: Doc JSON 结构化源(与 doc_file/markdown 三选一)'),
        'doc_file', WorkFileService.strProp('可选: 工作区中 Doc JSON 文件的相对路径(三选一)'),
        'markdown', WorkFileService.strProp('可选: Markdown 内容(三选一; 标题/列表/表格/引用/图片均支持)'),
        'title', WorkFileService.strProp('可选: 文档标题(默认取 doc.title 或文件名)'),
        'style', WorkFileService.strProp('可选: 样式预设 default/academic/minimal')),
      ['path']));
    defs.push(WorkFileService.makeTool('read_docx',
      '读回 Word 文档的 Doc JSON 源。本应用生成的 .docx 无损还原(含内嵌源); 外来 docx 为近似导入(标题/正文/列表/表格还原, 图片抽取到 docx_images/<文件名>/ 供查看与再次引用, 版式细节不保留)。编辑或仿制 Word 文档前先读它。',
      WorkFileService.props1(
        'path', WorkFileService.strProp('要读取的 .docx 文件相对路径')),
      ['path']));
    defs.push(WorkFileService.makeTool('edit_docx',
      '对已有 .docx 应用结构化操作后保存(外来 docx 会先自动备份原文件为 *_原版备份.docx)。ops 为 JSON 数组: set_title{title}/set_subtitle/set_author/set_style{style}/set_cover{cover}/set_toc{toc}/add_block{index?,block}/delete_block{index}/update_block{index,block 部分字段}/move_block{from,to}/replace_text{find,replace}；index 从 1 起。改单块用 update_block, 全局改词用 replace_text, 换样式用 set_style。',
      WorkFileService.props2(
        'path', WorkFileService.strProp('要编辑的 .docx 文件相对路径'),
        'ops', WorkFileService.strProp('操作 JSON 数组, 如 [{"op":"update_block","index":2,"block":{"text":"新标题"}}]')),
      ['path', 'ops']));
    defs.push(WorkFileService.makeTool('write_xlsx',
      '把结构化 Workbook JSON 或表格文本生成 Excel 文件(.xlsx)写入工作区。正式表格用 workbook(Workbook JSON 结构化源: 多工作表/表头加粗/公式(单元格值以 = 开头, 如 "=SUM(B2:B9)")/数字格式(formats 列格式: money/int/percent/year/date/number/text)/列宽(colWidths)/冻结窗格(freeze))或 workbook_file(工作区中 Workbook JSON 文件路径, 长表先 write_file/append_file 分块写好再导出); 简单表格直接传 table(Markdown 表格/CSV/TSV, 首行作表头)。name 可选工作簿名, style 可选样式预设 default/academic/minimal。做正式 Excel 前必须先 load_skill("xlsx") 全量加载；新建前 ask_user_question 前置提问；交付前写 xlsx_qa_report.md。',
      WorkFileService.props6(
        'path', WorkFileService.strProp('目标文件相对路径(建议以 .xlsx 结尾)'),
        'workbook', WorkFileService.strProp('可选: Workbook JSON 结构化源(与 workbook_file/table 三选一)'),
        'workbook_file', WorkFileService.strProp('可选: 工作区中 Workbook JSON 文件的相对路径(三选一)'),
        'table', WorkFileService.strProp('可选: Markdown 表格/CSV/TSV 文本(三选一; 首行作表头)'),
        'name', WorkFileService.strProp('可选: 工作簿名(默认取 workbook.name 或"Guncat 工作簿")'),
        'style', WorkFileService.strProp('可选: 样式预设 default/academic/minimal')),
      ['path']));
    defs.push(WorkFileService.makeTool('read_xlsx',
      '读回 Excel 工作簿的 Workbook JSON 源。本应用生成的 .xlsx 无损还原(含内嵌源); 外来 xlsx 为近似导入(各工作表数值/文本/公式还原, 样式/合并等细节不保留)。编辑或仿制 Excel 文件前先读它。',
      WorkFileService.props1(
        'path', WorkFileService.strProp('要读取的 .xlsx 文件相对路径')),
      ['path']));
    defs.push(WorkFileService.makeTool('edit_xlsx',
      '对已有 .xlsx 应用结构化操作后保存(外来 xlsx 会先自动备份原文件为 *_原版备份.xlsx)。ops 为 JSON 数组: set_name{name}/set_style{style}/set_sheet_name{sheet,name}/add_sheet{sheet,index?}/delete_sheet{sheet}/move_sheet{sheet,to}/add_row{sheet,row,index?}/delete_row{sheet,index}/update_row{sheet,index,row}/set_cell{sheet,row,col,value}/set_header{sheet,col,value}/replace_text{find,replace}；sheet 用工作表名, row/index 按数据行从 1 起算(不含表头, 与 read_xlsx 的 rows 一一对应), col 从 1 起(1=A)；改表头单元格用 set_header。改单元格用 set_cell, 加行用 add_row, 全局改词用 replace_text。',
      WorkFileService.props2(
        'path', WorkFileService.strProp('要编辑的 .xlsx 文件相对路径'),
        'ops', WorkFileService.strProp('操作 JSON 数组, 如 [{"op":"set_cell","sheet":"收入","row":2,"col":2,"value":999}]')),
      ['path', 'ops']));
    let tfProps: Record<string, Object> = {};
    tfProps['input'] = WorkFileService.strProp('要转换的工作区数据文件相对路径(csv/tsv/markdown 表格/json/jsonl/纯文本行)');
    tfProps['steps'] = WorkFileService.strProp('转换步骤 JSON 数组, 如 [{"op":"filter","expr":"col(\'年龄\') >= 18"},{"op":"derive","name":"全名","expr":"trim(col(\'姓\')) + \' \' + col(\'名\')}"]; 完整语法先 load_skill("data")');
    tfProps['output'] = WorkFileService.strProp('可选: 结果写盘路径(.csv/.tsv/.json/.md/.xlsx/.txt); 省略则只预览前 3 行, 确认后再带 output 写盘');
    tfProps['format'] = WorkFileService.strProp('可选: 输入格式 csv/tsv/md/json/jsonl/lines, 留空按内容自动识别');
    tfProps['json_path'] = WorkFileService.strProp('可选: JSON 输入时定位数组的点分路径, 如 data.items(数组下标用 0 起数字段)');
    tfProps['has_header'] = WorkFileService.strProp('可选: csv/tsv 首行是否为表头, 默认 true');
    tfProps['delimiter'] = WorkFileService.strProp('可选: 输入分隔符单字符, 默认自动推断(逗号/分号/制表符)');
    tfProps['bom'] = WorkFileService.strProp('可选: csv 输出是否带 UTF-8 BOM, 默认 true');
    tfProps['preview'] = WorkFileService.strProp('可选: true 时即使给了 output 也只预览不写盘');
    defs.push(WorkFileService.makeTool('transform_file',
      '对工作区文本数据文件执行本地转换管道(数据不经过模型上下文, 是处理大文件与非标格式的专用工具): 过滤/派生列/重算列/正则提取/拆列/去重/排序/替换/数值化, 以及 CSV↔TSV↔JSON↔Markdown表格↔XLSX 互转。流程: 先省略 output 预览前 3 行 → 修改 steps → 带 output 写盘 → read_file 抽查。全部操作与表达式语法见 load_skill("data")。限制: 输入 ≤2MB 文本、≤10 万行、steps ≤30 步。小表格直接 write_file/write_csv 更快, 不要滥用。',
      tfProps, ['input', 'steps']));
    defs.push(WorkFileService.makeTool('write_pptx',
      '生成/重建 PowerPoint 演示文稿(.pptx, 16:9), 三种输入二选一: (1) deck: Deck JSON 结构化源, 支持 cover/toc/section/content/two-col/image-text/image/image-full/table/chart/quote/end/custom 13 种版式、主题、图表、表格、图片、演讲备注、背景装饰——正式 PPT 用它, 完整语法先 load_skill("ppt") 全量加载; (2) deck_file: 工作区中 Deck JSON 文件的路径(长 deck 先 write_file/append_file 分块写好再导出, 改内容后可重复导出); (3) outline: 简易大纲("# 页标题"开新页, "## 标题"开分节页, "- 要点"一级要点, 缩进"- 要点"二级要点)。theme 可选主题预设, title 为演示文稿标题。新建 PPT 前按 ppt 技能要求 ask_user_question 前置提问; 默认 20 页以上; 每页需装饰性 SVG。',
      WorkFileService.props3(
        'path', WorkFileService.strProp('目标文件相对路径(以 .pptx 结尾)'),
        'deck', WorkFileService.strProp('Deck JSON 字符串(结构化源, 与 deck_file/outline 三选一)'),
        'deck_file', WorkFileService.strProp('工作区中 Deck JSON 文件路径(与 deck/outline 三选一)')),
      ['path']));
    defs.push(WorkFileService.makeTool('read_ppt',
      '读回演示文稿的 Deck JSON 源。本应用生成的 .pptx 无损还原; 外来 pptx 为近似导入(文本/表格/版面保留, 图片与图表数据不保留)。编辑或仿制前先读它。',
      WorkFileService.props1('path', WorkFileService.strProp('要读取的 .pptx 相对路径')),
      ['path']));
    defs.push(WorkFileService.makeTool('edit_ppt',
      '对工作区已有的 .pptx 应用结构化操作后保存(外来 pptx 会先自动备份原文件)。ops 为 JSON 数组, 支持: add_slide{slide,插入位置 index?}/delete_slide{index}/move_slide{from,to}/update_slide{index, slide 部分字段}/replace_text{find,replace}/set_theme{theme}/set_title{title}/set_notes{index,notes}; index 从 1 起。改单页内容用 update_slide, 全局改词用 replace_text。',
      WorkFileService.props2(
        'path', WorkFileService.strProp('要编辑的 .pptx 相对路径'),
        'ops', WorkFileService.strProp('操作 JSON 数组, 如 [{"op":"update_slide","index":2,"slide":{"title":"新标题"}}]')),
      ['path', 'ops']));
    defs.push(WorkFileService.makeTool('parse_document',
      '解析 PDF 的文本内容(本地解析, 按页分批返回)。返回 总页数 与 [第 N 页] 标注的文本; 超长 PDF 单次只返回一部分, 末尾附"未读完"提示, 按提示传 page 逐批读完即可, 不要重复调用同一页。加密 PDF 与扫描件无法解析。.docx/.xlsx/.pptx 优先用 read_file。',
      WorkFileService.props3(
        'path', WorkFileService.strProp('要解析的 PDF 文件相对路径'),
        'page', WorkFileService.strProp('起始页码(从 1 起), 默认 1; 续读时用上次返回提示中的页码'),
        'page_count', WorkFileService.strProp('本次提取的页数, 默认 30, 最大 200')),
      ['path']));
    defs.push(WorkFileService.makeTool('search_pdf',
      '在 PDF 文字层中搜索关键词(大小写不敏感), 返回 页码+上下文摘录 命中列表, 最多 50 处。搜索 PDF 内容必须用它(文本搜索工具无法读 PDF); 命中后用 parse_document 传 page=N 精读对应页。',
      WorkFileService.props2(
        'path', WorkFileService.strProp('要搜索的 PDF 文件相对路径'),
        'query', WorkFileService.strProp('搜索关键词')),
      ['path', 'query']));
    defs.push(WorkFileService.makeTool('pdf_to_images',
      '把 PDF 按页渲染成图片存入工作区 pdf_images/<文件名>/ 目录(每页一个 p001.jpg)。扫描件/纯图片 PDF 的专用入口: parse_document 提示是扫描件或读不出文字时, 先转图片再用 view_image 逐张查看(图片可反复查看, 不必重复转)。',
      WorkFileService.props3(
        'path', WorkFileService.strProp('要渲染的 PDF 文件相对路径'),
        'page', WorkFileService.strProp('起始页码(从 1 起), 默认 1'),
        'page_count', WorkFileService.strProp('本次渲染页数, 默认 10, 最大 50')),
      ['path']));
    defs.push(WorkFileService.makeTool('view_image',
      '查看工作区中的图片, 图片会作为多模态消息发送给你的视觉能力。调用前明确你要从图中提取什么(全部文字/表格数据/布局/图表含义), 并说明输出格式。',
      WorkFileService.props1('path', WorkFileService.strProp('图片文件相对路径(png/jpg/jpeg/webp/gif/bmp)')),
      ['path']));
    defs.push(WorkFileService.makeTool('todo_write',
      '创建/更新当前任务的任务清单。复杂任务开始时先建立清单, 每完成一项立即更新状态; 简单任务(1-2步)不必建清单。todos 为 JSON 数组, status 取 pending/in_progress/completed。',
      WorkFileService.props1('todos', WorkFileService.strProp('任务清单 JSON 数组, 如 [{"content":"解析数据","status":"in_progress"},{"content":"生成报告","status":"pending"}]')),
      ['todos']));
    defs.push(WorkFileService.makeTool('search_web',
      webSearchEnabled ? LOCAL_SEARCH_TOOL_DESC_WORK_FALLBACK : LOCAL_SEARCH_TOOL_DESC_WORK,
      WorkFileService.props1('query', WorkFileService.strProp(LOCAL_SEARCH_QUERY_PROP_DESC)),
      ['query']));
    defs.push(WorkFileService.makeTool('record_search',
      '保存一次服务端联网搜索的记录到工作区 .searches.md。服务端联网搜索由模型服务商在请求内完成, 不会在对话历史中留下任何工具调用记录, 因此每次你借助服务端联网搜索获得信息后, 必须立即调用本工具登记: 查询词 + 关键结论摘要(可选主要来源 URL, 多个用换行分隔)。注意: 本地内置搜索工具(search_web)的结果已自动登记到 .searches.md, 不要对它重复调用本工具。否则后续轮次(包括你自己)都无法追溯这次搜索。',
      WorkFileService.props3(
        'query', WorkFileService.strProp('本次联网搜索使用的关键词/查询'),
        'summary', WorkFileService.strProp('本次搜索获得的关键结论或信息要点(简明扼要)'),
        'sources', WorkFileService.strProp('主要来源 URL, 多个用换行分隔, 可省略')),
      ['query', 'summary']));
    defs.push(WorkFileService.makeTool('list_skills',
      '列出当前可用的技能(领域操作指南)。接到 PPT/演示文稿等对应任务时, 先加载对应技能再动手。',
      WorkFileService.props0(),
      []));
    defs.push(WorkFileService.makeTool('load_skill',
      '加载技能文档全文。name 为技能 id(见 list_skills); file 可选, 传技能的参考文件名(如 reference/deck-dsl.md)加载深入资料, 省略时返回技能正文 SKILL.md(ppt/docx/xlsx 技能为全量 bundle: SKILL.md + 全部 reference, 必须一次加载完)。',
      WorkFileService.props2(
        'name', WorkFileService.strProp('技能 id, 如 ppt'),
        'file', WorkFileService.strProp('可选: 技能内的参考文件相对路径, 省略返回 SKILL.md 或全量 bundle')),
      ['name']));
    let harnessDefs: Record<string, Object>[] = HarnessTools.toolDefs();
    for (let i: number = 0; i < harnessDefs.length; i++) {
      defs.push(harnessDefs[i]);
    }
    return defs;
  }

  // 无参数工具的 properties(空对象)
  private static props0(): Record<string, Object> {
    return {};
  }

  // 单参数 properties 构造
  private static props1(name1: string, p1: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    return properties;
  }

  // 双参数 properties 构造
  private static props2(name1: string, p1: Record<string, Object>,
    name2: string, p2: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    properties[name2] = p2;
    return properties;
  }

  // 三参数 properties 构造
  private static props3(name1: string, p1: Record<string, Object>,
    name2: string, p2: Record<string, Object>,
    name3: string, p3: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    properties[name2] = p2;
    properties[name3] = p3;
    return properties;
  }

  // 四参数 properties 构造
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

  // 五参数 properties 构造
  private static props5(name1: string, p1: Record<string, Object>,
    name2: string, p2: Record<string, Object>,
    name3: string, p3: Record<string, Object>,
    name4: string, p4: Record<string, Object>,
    name5: string, p5: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    properties[name2] = p2;
    properties[name3] = p3;
    properties[name4] = p4;
    properties[name5] = p5;
    return properties;
  }

  // 六参数 properties 构造
  private static props6(name1: string, p1: Record<string, Object>,
    name2: string, p2: Record<string, Object>,
    name3: string, p3: Record<string, Object>,
    name4: string, p4: Record<string, Object>,
    name5: string, p5: Record<string, Object>,
    name6: string, p6: Record<string, Object>): Record<string, Object> {
    let properties: Record<string, Object> = {};
    properties[name1] = p1;
    properties[name2] = p2;
    properties[name3] = p3;
    properties[name4] = p4;
    properties[name5] = p5;
    properties[name6] = p6;
    return properties;
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

  // ===== 底层工具函数 =====

  // 路径是否存在(公开给 WorkToolRunner)
  static accessPath(abs: string): boolean {
    return fileIo.accessSync(abs);
  }

  // 路径是否为目录(公开给 WorkToolRunner)
  static isDirPath(abs: string): boolean {
    return fileIo.statSync(abs).isDirectory();
  }

  // 读取文件字节(公开给 WorkToolRunner); 超过 maxLen 抛错
  static readBytesPublic(abs: string, maxLen: number): ArrayBuffer {
    let stat: fileIo.Stat = fileIo.statSync(abs);
    if (stat.size > maxLen) {
      throw new Error('文件超过 ' + WorkFileService.formatSize(maxLen) + ' 上限');
    }
    let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0 });
    } finally {
      fileIo.closeSync(file.fd);
    }
    return buffer;
  }

  // 复制文件(edit_ppt 备份外来 pptx 用); 目标存在则覆盖
  static copyFileSync(src: string, dst: string): void {
    let buffer: ArrayBuffer = WorkFileService.readBytesPublic(src, 64 * 1024 * 1024);
    let file: fileIo.File = fileIo.openSync(dst,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file.fd);
    }
  }

  private static strArg(args: Record<string, Object>, key: string, defVal: string): string {
    let v: Object = args[key];
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      let n: string = (v as number).toString();
      return n;
    }
    return defVal;
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

  private static capChars(text: string, max: number): string {
    if (text.length <= max) {
      return text;
    }
    return text.substring(0, max) + '...';
  }

  private static isTextFile(name: string): boolean {
    let dot: number = name.lastIndexOf('.');
    if (dot < 0 || dot === name.length - 1) {
      return false;
    }
    let ext: string = name.substring(dot + 1).toLowerCase();
    let textExts: string[] = ['txt', 'md', 'markdown', 'json', 'csv', 'tsv', 'xml', 'html', 'htm',
      'css', 'js', 'mjs', 'ts', 'tsx', 'jsx', 'yaml', 'yml', 'ini', 'cfg', 'conf', 'toml',
      'log', 'py', 'java', 'kt', 'kts', 'c', 'h', 'cpp', 'hpp', 'cs', 'go', 'rs', 'rb', 'php',
      'sh', 'bash', 'bat', 'sql', 'svg', 'properties', 'gradle', 'plist', 'swift', 'dart', 'r'];
    return textExts.indexOf(ext) !== -1;
  }

  private static looksBinary(bytes: Uint8Array): boolean {
    let scan: number = bytes.length < 4096 ? bytes.length : 4096;
    for (let i: number = 0; i < scan; i++) {
      if (bytes[i] === 0) {
        return true;
      }
    }
    return false;
  }

  // 读取文件前 maxLen 字节; maxLen <= 0 或超出时读全文件
  private static readBytes(abs: string, maxLen: number = 0): Uint8Array {
    let stat: fileIo.Stat = fileIo.statSync(abs);
    let size: number = stat.size;
    let readLen: number = size;
    if (maxLen > 0 && maxLen < size) {
      readLen = maxLen;
    }
    let buffer: ArrayBuffer = new ArrayBuffer(readLen);
    let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0 });
    } finally {
      fileIo.closeSync(file.fd);
    }
    return new Uint8Array(buffer);
  }

  // 写入字节(公开给 WorkToolRunner: SVG 栅格化临时文件等); 防御 Uint8Array 与底层 ArrayBuffer 不对齐的情况(与 DocxExporter 同策略)
  static writeBytes(abs: string, bytes: Uint8Array): void {
    let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
    if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
      buffer = bytes.slice().buffer as ArrayBuffer;
    }
    let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file.fd);
    }
  }

  private static deleteRecursive(abs: string): void {
    let stat: fileIo.Stat = fileIo.statSync(abs);
    if (stat.isDirectory()) {
      let names: string[] = fileIo.listFileSync(abs);
      for (let i: number = 0; i < names.length; i++) {
        WorkFileService.deleteRecursive(abs + '/' + names[i]);
      }
      fileIo.rmdirSync(abs);
    } else {
      fileIo.unlinkSync(abs);
    }
  }

  // 文件名净化(公开给 WorkToolRunner: download_file 自动命名等)
  static sanitizeFileName(name: string): string {
    let out: string = name.replace(/\//g, '_').replace(/\\/g, '_').trim();
    if (out === '' || out === '.' || out === '..') {
      out = '未命名文件';
    }
    return out;
  }

  // 重名自动追加序号: a.csv → a_1.csv(公开给 WorkToolRunner)
  static uniqueName(root: string, name: string): string {
    let candidate: string = name;
    let n: number = 1;
    while (fileIo.accessSync(root + '/' + candidate)) {
      let dot: number = name.lastIndexOf('.');
      if (dot > 0) {
        candidate = name.substring(0, dot) + '_' + n.toString() + name.substring(dot);
      } else {
        candidate = name + '_' + n.toString();
      }
      n++;
      if (n > 99) {
        candidate = name + '_' + new Date().getTime().toString();
        break;
      }
    }
    return candidate;
  }

  static formatSize(bytes: number): string {
    if (bytes < 1024) {
      return bytes.toString() + ' B';
    }
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  // ===== Office 全文抽取缓存(search 与 read_file 共用, 按大小+修改时间失效) =====

  private static officeCache: Map<string, OfficeCacheEntry> = new Map();

  private static isOfficeFile(name: string): boolean {
    let lower: string = name.toLowerCase();
    return lower.endsWith('.docx') || lower.endsWith('.xlsx') || lower.endsWith('.pptx');
  }

  // 取 Office 全量抽取文本: 缓存命中直接返回, 否则解包抽取并缓存(单条上限 WORK_OFFICE_CACHE_MAX_CHARS)
  private static async officeFullText(abs: string, cacheDir: string): Promise<string> {
    let stat: fileIo.Stat = fileIo.statSync(abs);
    let cached: OfficeCacheEntry | undefined = WorkFileService.officeCache.get(abs);
    if (cached !== undefined && cached.size === stat.size && cached.mtime === stat.mtime) {
      return cached.text;
    }
    let text: string = await OfficeReader.extractAll(abs, cacheDir);
    if (text.length > Constants.WORK_OFFICE_CACHE_MAX_CHARS) {
      text = text.substring(0, Constants.WORK_OFFICE_CACHE_MAX_CHARS);
    }
    let entry: OfficeCacheEntry = new OfficeCacheEntry();
    entry.size = stat.size;
    entry.mtime = stat.mtime;
    entry.text = text;
    if (WorkFileService.officeCache.size >= 6) {
      // 淘汰最早插入的一条(Map 保持插入序)
      let oldest: string = '';
      WorkFileService.officeCache.forEach((v: OfficeCacheEntry, k: string): void => {
        if (oldest === '') {
          oldest = k;
        }
      });
      if (oldest !== '') {
        WorkFileService.officeCache.delete(oldest);
      }
    }
    WorkFileService.officeCache.set(abs, entry);
    return text;
  }

  // 整数参数: 兼容 number 与数字字符串, 非法时用默认值
  private static intArg(args: Record<string, Object>, key: string, defVal: number): number {
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
}

// Office 抽取缓存条目
class OfficeCacheEntry {
  size: number = 0;
  mtime: number = 0;
  text: string = '';
}
