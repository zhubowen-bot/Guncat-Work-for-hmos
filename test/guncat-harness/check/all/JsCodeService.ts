// JsCodeService: Guncat Work 的 run_js 工具 —— 在应用内嵌的 JS 引擎(JSVM-API)里执行 JS 代码。
//
// 为什么需要它: 工作模式没有 shell/终端/PTC, 确定性加工只能靠既有工具(transform_file 管道等);
// run_js 补上"任意小程序化处理"这一块 —— 日期与数值计算、单位换算、正则清洗、JSON 重塑、
// 统计与汇总、算法试算、批量生成结构化数据(产出 JSON 再交给 write_docx/write_xlsx/write_pptx)。
//
// 沙箱边界: 纯计算环境, 无网络、无文件系统、无模块加载(JSVM 不支持 ES Module)。
// 文件进出只能由本服务显式桥接:
//   files 参数     -> 预载成脚本里的 inputs / read(path)(只读文本)
//   write(path, c) -> 执行成功后由本服务校验路径并落盘到工作区
//
// 稳定性: JSVM-API 没有"中断执行"的接口, 死循环无法从外部终止, 因此:
//   1) JS 在 native 的异步任务(worker 线程)上执行, 不阻塞 UI 线程;
//   2) ArkTS 侧只做"超时放弃"—— 放弃后那段代码仍在后台跑, 累计到上限即拒绝新执行(见 Constants)。
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { JsRunOptions, JsRunResult, engineStatus, runJs } from './jsvm-shim.ts';
import { Constants } from './Constants.ts';
import { ToolExecResult, WorkFileService } from './WorkFileService.ts';

// 输入文件预载结果
class InputLoad {
  inputs: Record<string, string> = {};
  failed: string = '';
}

// 一次执行的等待结果(区分"超时放弃"与"拿到结果/调用异常")
class RunRace {
  timedOut: boolean = false;
  error: string = '';
  result: JsRunResult | null = null;
}

export class JsCodeService {
  static readonly TOOL_NAME: string = 'run_js';

  // 被超时放弃、但仍在后台线程里占着 CPU 的执行次数(进程内累计, 重启应用归零)
  private static abandoned: number = 0;
  private static engineProbed: boolean = false;
  private static engineError: string = '';

  // 工具入口(args 为模型传入的参数对象)
  static async run(root: string, args: Record<string, Object>): Promise<ToolExecResult> {
    let code: string = JsCodeService.strArg(args, 'code', '');
    if (code.trim() === '') {
      return JsCodeService.fail('缺少参数 code(要执行的 JS 代码)');
    }
    let encoder: util.TextEncoder = new util.TextEncoder();
    let codeBytes: number = encoder.encode(code).length;
    if (codeBytes > Constants.WORK_JS_MAX_CODE_BYTES) {
      return JsCodeService.fail('代码过长(' + WorkFileService.formatSize(codeBytes) + '), 上限 ' +
        WorkFileService.formatSize(Constants.WORK_JS_MAX_CODE_BYTES) +
        '; 更长的逻辑请拆成多次 run_js, 或把数据放进文件用 files 传入');
    }

    // 引擎可用性(探测一次并缓存): 设备/系统不支持时给出明确原因, 而不是让脚本报怪错
    let engineError: string = JsCodeService.probeEngine();
    if (engineError !== '') {
      return JsCodeService.fail('本机 JS 引擎不可用, run_js 无法执行: ' + engineError);
    }
    if (JsCodeService.abandoned >= Constants.WORK_JS_MAX_ABANDONED) {
      return JsCodeService.fail('已有 ' + JsCodeService.abandoned.toString() +
        ' 次 JS 执行超时后在后台继续运行, 为避免持续占用 CPU, 本会话不再执行 JS。' +
        '请重启应用后重试, 并检查代码里是否存在死循环。');
    }

    // 预载输入文件(只读)
    let load: InputLoad = JsCodeService.loadInputs(root, JsCodeService.fileListArg(args));
    if (load.failed !== '') {
      return JsCodeService.fail(load.failed);
    }

    let timeoutMs: number = Constants.WORK_JS_DEFAULT_TIMEOUT_MS;
    let askedTimeout: number = JsCodeService.intArg(args, 'timeout_ms', 0);
    if (askedTimeout > 0) {
      timeoutMs = askedTimeout < 1000 ? 1000 : askedTimeout;
      if (timeoutMs > Constants.WORK_JS_MAX_TIMEOUT_MS) {
        timeoutMs = Constants.WORK_JS_MAX_TIMEOUT_MS;
      }
    }

    let options: JsRunOptions = {
      inputs: load.inputs,
      resourceName: 'run_js.js',
      heapMb: Constants.WORK_JS_HEAP_MB,
      stdoutLimitKb: Constants.WORK_JS_STDOUT_KB,
      outputFileLimitKb: Math.floor(Constants.WORK_WRITE_MAX_BYTES / 1024),
      outputTotalLimitKb: Constants.WORK_JS_OUTPUT_TOTAL_KB,
      maxOutputFiles: Constants.WORK_JS_MAX_OUTPUT_FILES
    };

    let race: RunRace;
    try {
      race = await JsCodeService.awaitWithTimeout(runJs(code, options), timeoutMs);
    } catch (e) {
      return JsCodeService.fail('调用 JS 引擎失败: ' + JsCodeService.errText(e));
    }

    if (race.timedOut) {
      JsCodeService.abandoned++;
      let tail: string = JsCodeService.abandoned >= Constants.WORK_JS_MAX_ABANDONED ?
        '\n本次已达超时上限(' + Constants.WORK_JS_MAX_ABANDONED.toString() +
          ' 次), 本会话不再执行 JS, 重启应用可恢复。' :
        '\n(已累计 ' + JsCodeService.abandoned.toString() + ' 次未结束的执行)';
      return JsCodeService.fail('执行超时: ' + timeoutMs.toString() +
        'ms 内没有结束, 已放弃等待。\n' +
        'JSVM 引擎没有中断接口, 这段代码仍在后台线程里运行 —— 请检查死循环(while/for 的退出条件)、' +
        '超大循环次数或超大数据量, 缩小范围后重试。' + tail);
    }
    if (race.error !== '') {
      return JsCodeService.fail('执行失败: ' + race.error);
    }
    let result: JsRunResult | null = race.result;
    if (result === null) {
      return JsCodeService.fail('执行失败: 未取得执行结果');
    }
    if (!result.ok) {
      return JsCodeService.fail('JS 执行失败:\n' + (result.error !== '' ? result.error : '未知错误'));
    }

    // 自检: native 回执的输入数量必须与本地预载数量一致 —— 参数被静默丢弃时宁可报错也不静默算错
    let expectedInputs: number = Object.keys(load.inputs).length;
    if (result.inputCount !== expectedInputs) {
      return JsCodeService.fail('内部错误: 输入文件参数未完整送达 JS 引擎(本地预载 ' +
        expectedInputs.toString() + ' 个, 引擎收到 ' + result.inputCount.toString() +
        ' 个), 本次结果已丢弃, 请重试; 若持续出现请改用 read_file/transform_file 处理文件。');
    }

    // 落盘: 只写执行成功时声明的输出(路径一律经 resolveSafe 校验在工作区内)
    // 可选 outputDir(子代理写隔离注入): 输出自动落入该子目录, 脚本声明的路径自动加前缀
    let outputDir: string = JsCodeService.strArg(args, '_output_dir', '');
    let written: string[] = [];
    let failedWrites: string[] = [];
    let outputNames: string[] = Object.keys(result.outputs);
    for (let i: number = 0; i < outputNames.length; i++) {
      let name: string = outputNames[i];
      let content: string = result.outputs[name];
      let problem: string = JsCodeService.writeOutput(root, outputDir, name, content);
      if (problem === '') {
        written.push(name + ' (' + WorkFileService.formatSize(content.length) + ')');
      } else {
        failedWrites.push(name + ': ' + problem);
      }
    }
    return JsCodeService.ok(JsCodeService.renderResult(result, written, failedWrites));
  }

  // ===== 结果渲染 =====

  private static renderResult(result: JsRunResult, written: string[], failedWrites: string[]): string {
    let lines: string[] = [];
    lines.push('run_js 执行成功(' + result.durationMs.toString() + 'ms, 独立 JS 引擎实例)');
    if (result.inputKeys.length > 0) {
      // 列出实际键名: 脚本里用 inputs[键] 或 read(键) 取值(键已去掉 ./ 前缀)
      lines.push('—— 已预载输入(' + result.inputKeys.length.toString() + ', 只读) ——');
      lines.push(result.inputKeys.join('\n'));
    }
    if (result.hasResult) {
      lines.push('—— 返回值 ——');
      lines.push(result.result === '' ? '(空字符串)' : result.result);
    } else {
      lines.push('—— 返回值 ——(undefined)');
      lines.push('提示: 脚本最后一条表达式的值就是返回值; 需要显式返回时用 ' +
        '(() => { ...; return 结果; })() 或把结果写在最后一行。');
    }
    if (result.stdout !== '') {
      lines.push('—— 控制台输出 ——');
      lines.push(JsCodeService.trimTrailingNewline(result.stdout));
    }
    if (written.length > 0) {
      lines.push('—— 已写入工作区(' + written.length.toString() + ') ——');
      lines.push(written.join('\n'));
    }
    if (result.notice !== '') {
      lines.push('提示: ' + result.notice);
    }
    if (failedWrites.length > 0) {
      lines.push('部分输出未写入: ' + failedWrites.join('; '));
    }
    return lines.join('\n');
  }

  private static trimTrailingNewline(text: string): string {
    let out: string = text;
    while (out.endsWith('\n')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  // ===== 输入文件预载 =====

  private static loadInputs(root: string, files: string[]): InputLoad {
    let load: InputLoad = new InputLoad();
    if (files.length > Constants.WORK_JS_MAX_INPUT_FILES) {
      load.failed = '输入文件过多(' + files.length.toString() + '), 上限 ' +
        Constants.WORK_JS_MAX_INPUT_FILES.toString() + ' 个';
      return load;
    }
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    let totalBytes: number = 0;
    for (let i: number = 0; i < files.length; i++) {
      // given: 原样(路径校验与报错用, 绝对路径一律拒绝); rel: 归一化后的键名(native 侧同一规则)
      let given: string = files[i].trim();
      if (given === '') {
        continue;
      }
      let abs: string | null = WorkFileService.resolveSafe(root, given);
      if (abs === null) {
        load.failed = '非法输入路径(只能是工作区内相对路径, 不要写绝对路径或 ..): ' + given;
        return load;
      }
      let rel: string = JsCodeService.normalizeRel(given);
      if (rel === '') {
        load.failed = '非法输入路径: ' + given;
        return load;
      }
      if (load.inputs[rel] !== undefined) {
        continue;
      }
      if (!fileIo.accessSync(abs)) {
        load.failed = '输入文件不存在: ' + given + '(先用 list_files / glob 确认路径)';
        return load;
      }
      let stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.isDirectory()) {
        load.failed = '输入只能是文件, 不能是目录: ' + given;
        return load;
      }
      if (stat.size > Constants.WORK_JS_INPUT_FILE_MAX_BYTES) {
        load.failed = '输入文件过大: ' + given + '(' + WorkFileService.formatSize(stat.size) +
          '), 单文件上限 ' + WorkFileService.formatSize(Constants.WORK_JS_INPUT_FILE_MAX_BYTES) +
          '; 大文件请先拆分, 或用 search_files / transform_file 缩小范围';
        return load;
      }
      if (stat.size === 0) {
        load.inputs[rel] = '';
        continue;
      }
      let bytes: Uint8Array = JsCodeService.readBytes(abs);
      if (JsCodeService.looksBinary(bytes)) {
        load.failed = '二进制文件不能作为文本输入: ' + given;
        return load;
      }
      totalBytes += bytes.length;
      if (totalBytes > Constants.WORK_JS_INPUT_TOTAL_MAX_BYTES) {
        load.failed = '输入总量超过上限 ' +
          WorkFileService.formatSize(Constants.WORK_JS_INPUT_TOTAL_MAX_BYTES) + ', 请减少文件数量';
        return load;
      }
      load.inputs[rel] = decoder.decodeToString(bytes, { stream: false });
    }
    return load;
  }

  // 与 native 侧 guncat::NormalizeRelPath 同一规则: 去开头的 '/' 与 './'、折叠重复斜杠、去结尾斜杠。
  // 两侧必须一致, 否则"同一文件写了两种形式"会让输入数量自检误报。
  private static normalizeRel(raw: string): string {
    let body: string = raw.trim();
    while (body.startsWith('/')) {
      body = body.substring(1);
    }
    while (body.startsWith('./')) {
      body = body.substring(2);
    }
    let out: string = '';
    for (let i: number = 0; i < body.length; i++) {
      let ch: string = body.charAt(i);
      if (ch === '/' && (out === '' || out.endsWith('/'))) {
        continue;
      }
      out += ch;
    }
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  private static readBytes(abs: string): Uint8Array {
    let stat: fileIo.Stat = fileIo.statSync(abs);
    let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    let file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0 });
    } finally {
      fileIo.closeSync(file.fd);
    }
    return new Uint8Array(buffer);
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

  // ===== 输出落盘 =====

  // 返回空串表示写入成功, 否则为失败原因
  // outputDir 非空时(子代理写隔离), 脚本声明的输出路径自动落入该子目录
  private static writeOutput(root: string, outputDir: string, name: string, content: string): string {
    let rel: string = name;
    if (outputDir !== '') {
      let p: string = name.trim().replace(/\\/g, '/');
      while (p.startsWith('./')) {
        p = p.substring(2);
      }
      while (p.startsWith('/')) {
        p = p.substring(1);
      }
      p = p.replace(/\/+/g, '/');
      if (p !== '' && p !== '.' && p !== outputDir && !p.startsWith(outputDir + '/')) {
        p = outputDir + '/' + p;
      }
      rel = p;
    }
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return '非法路径(只能是工作区内相对路径)';
    }
    if (abs === root) {
      return '不能写入工作区根目录';
    }
    try {
      if (fileIo.accessSync(abs) && fileIo.statSync(abs).isDirectory()) {
        return '目标是已存在的目录';
      }
      let encoder: util.TextEncoder = new util.TextEncoder();
      let bytes: Uint8Array = encoder.encode(content);
      if (bytes.length > Constants.WORK_WRITE_MAX_BYTES) {
        return '内容超出上限 ' + WorkFileService.formatSize(Constants.WORK_WRITE_MAX_BYTES);
      }
      let parentDir: string = abs.substring(0, abs.lastIndexOf('/'));
      if (parentDir !== root && parentDir !== '') {
        WorkFileService.ensureDir(parentDir);
      }
      WorkFileService.writeBytes(abs, bytes);
      return '';
    } catch (e) {
      return JsCodeService.errText(e);
    }
  }

  // ===== 超时等待 =====

  // JSVM 没有中断接口: 超时只能"放弃等待", 被放弃的执行会继续占用后台线程直到应用退出
  private static awaitWithTimeout(promise: Promise<JsRunResult>, timeoutMs: number): Promise<RunRace> {
    return new Promise<RunRace>((resolve: (value: RunRace) => void) => {
      let settled: boolean = false;
      let timer: number = setTimeout(() => {
        if (!settled) {
          settled = true;
          let race: RunRace = new RunRace();
          race.timedOut = true;
          resolve(race);
        }
      }, timeoutMs);
      promise.then((value: JsRunResult) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        let race: RunRace = new RunRace();
        race.result = value;
        resolve(race);
      }).catch((e: Object) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        let race: RunRace = new RunRace();
        race.error = JsCodeService.errText(e);
        resolve(race);
      });
    });
  }

  // ===== 引擎探测 =====

  private static probeEngine(): string {
    if (!JsCodeService.engineProbed) {
      JsCodeService.engineProbed = true;
      try {
        JsCodeService.engineError = engineStatus();
      } catch (e) {
        JsCodeService.engineError = '原生模块加载失败: ' + JsCodeService.errText(e);
      }
    }
    return JsCodeService.engineError;
  }

  // ===== 参数解析 =====

  private static strArg(args: Record<string, Object>, key: string, defVal: string): string {
    let v: Object = args[key];
    if (typeof v === 'string') {
      return v as string;
    }
    return defVal;
  }

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

  // files 参数: 兼容 JSON 数组 / 实际数组 / 逗号或换行分隔
  private static fileListArg(args: Record<string, Object>): string[] {
    let out: string[] = [];
    let v: Object = args['files'];
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
      let text: string = (v as string).trim();
      if (text.startsWith('[')) {
        try {
          let parsed: Object = JSON.parse(text);
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
          // 解析失败则退化为分隔符切分
        }
      }
      let parts: string[] = text.split(',');
      for (let i: number = 0; i < parts.length; i++) {
        let one: string = parts[i].trim();
        if (one !== '') {
          out.push(one);
        }
      }
    }
    return out;
  }

  private static errText(e: Object): string {
    if (e instanceof Error) {
      let err: Error = e as Error;
      return err.message !== undefined ? err.message : String(e);
    }
    return String(e);
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
}
