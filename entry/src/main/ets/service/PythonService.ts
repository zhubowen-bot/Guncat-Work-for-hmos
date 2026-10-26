// PythonService: 原生 CPython 工具(run_python) + shell 跨域桥(npy)的执行后端。
//
// 设计要点:
//   * 解释器是**应用进程内的真 CPython**(libpython3.12.so, 由 libguncatpy.so 动态加载),
//     不经过 QEMU 仿真 —— 同一段脚本比 VM 里的 python3 快 2~3 个数量级。
//   * 工作目录固定为**会话工作区**, 与 shell / read_file / write_file 看到的是同一批文件
//     (原生侧直接走 POSIX 文件 API, 不存在"两套目录"的问题)。
//   * 没有 fork/exec: subprocess / os.system / multiprocessing 不可用, 需要调 Unix 工具的
//     场景请用 shell 工具(或 VM 内的 `npy` 桥反过来调原生 Python)。
//   * 原生侧全局串行(解释器有 GIL, 且只有一个实例), 这里再用 promise 链排队, 保证不并发进解释器。
import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { isAvailable as pyIsAvailable, runPython as pyRunNative, pyState as pyNativeState,
  PyRunResult } from 'libguncatpy.so';
import { Constants } from '../common/Constants';
import { RawAsset } from './RawAsset';
import { SpillStore } from './SpillStore';
import { ToolExecResult, WorkFileService } from './WorkFileService';

const DOMAIN: number = 0x0000;
const TAG: string = 'PythonService';

const RAW_ZIP: string = 'python/python312.zip';
const RAW_CERT: string = 'python/cacert.pem';
const PY_RUNTIME_DIR: string = 'python';
const PY_STDLIB_SUBDIR: string = 'lib/python3.12';

export class PythonService {
  static readonly TOOL_NAME: string = Constants.WORK_PY_TOOL_NAME;

  // 运行库释放只做一次; 失败原因缓存下来, 之后的调用直接复用
  private static prepareTask: Promise<string> | null = null;
  // 解释器串行队列(与原生侧的 g_running 双保险)
  private static chain: Promise<void> = Promise.resolve();

  /** 原生运行库是否可用: 空串=可用, 否则为原因 */
  static unavailableReason(): string {
    try {
      return pyIsAvailable();
    } catch (e) {
      return '原生 Python 模块未加载: ' + (e as Error).message;
    }
  }

  /** 运行库根的绝对路径(filesDir/python) */
  static runtimeDir(context: common.UIAbilityContext): string {
    return context.filesDir + '/' + PY_RUNTIME_DIR;
  }

  private static pythonHome(context: common.UIAbilityContext): string {
    return PythonService.runtimeDir(context);
  }

  private static pythonPath(context: common.UIAbilityContext): string {
    // 只给标准库 zip; C 扩展模块在应用的 lib 目录里(native 侧用 dladdr 自动并进 PYTHONPATH),
    // 因为设备上只有 lib 目录下的 .so 允许 dlopen。
    let stdlib: string = PythonService.runtimeDir(context) + '/' + PY_STDLIB_SUBDIR;
    return stdlib + '/python312.zip';
  }

  /** 首次调用时把 libpython 依赖的标准库/扩展模块释放到沙箱 */
  static ensureRuntime(context: common.UIAbilityContext): Promise<string> {
    if (PythonService.prepareTask !== null) {
      return PythonService.prepareTask;
    }
    PythonService.prepareTask = PythonService.doPrepare(context);
    return PythonService.prepareTask;
  }

  private static async doPrepare(context: common.UIAbilityContext): Promise<string> {
    let nativeErr: string = PythonService.unavailableReason();
    if (nativeErr !== '') {
      return nativeErr;
    }
    let root: string = PythonService.runtimeDir(context);
    let stdlib: string = root + '/' + PY_STDLIB_SUBDIR;
    let marker: string = root + '/.version';
    let want: string = PythonService.runtimeVersion();
    try {
      if (fileIo.accessSync(marker)) {
        let got: string = PythonService.readText(marker).trim();
        if (got === want) {
          return '';
        }
      }
      hilog.info(DOMAIN, TAG, 'releasing python stdlib (%{public}s)', want);
      if (!fileIo.accessSync(stdlib)) {
        fileIo.mkdirSync(stdlib, true);
      }
      RawAsset.extract(context, RAW_ZIP, stdlib + '/python312.zip');
      // https 用的 CA 证书(应用沙箱里没有系统 CA)
      try {
        RawAsset.extract(context, RAW_CERT, root + '/cacert.pem');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'extract cacert failed: %{public}s', (e as Error).message);
      }
      // C 扩展不打进 rawfile: 它们作为应用原生库随安装释放到 lib 目录, 这里不再解压
      PythonService.writeText(marker, want);
      return '';
    } catch (e) {
      return '释放 Python 运行库失败: ' + (e as Error).message;
    }
  }

  private static runtimeVersion(): string {
    try {
      let info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionCode.toString() + '-' + Constants.WORK_PY_RUNTIME_REV;
    } catch (e) {
      return Constants.WORK_PY_RUNTIME_REV;
    }
  }

  /**
   * 直接执行一段 Python(不做工具层包装), 供 npy 桥与 run_python 共用。
   * cwdRel 为工作区相对路径(空串表示工作区根); argv 会变成 sys.argv。
   */
  static async exec(context: common.UIAbilityContext, convId: string, code: string,
    argv: string[], cwdRel: string, timeoutMs: number, stdinText: string = ''): Promise<PyRunResult> {
    let workDir: string = WorkFileService.workspaceRoot(context, convId);
    let rel: string = cwdRel;
    if (rel !== '') {
      let safe: boolean = rel.indexOf('..') < 0 && rel.charAt(0) !== '/';
      if (!safe) {
        return PythonService.failResult('cwd 必须是工作区内的相对路径');
      }
      workDir = workDir + '/' + rel;
    }
    let scratch: string = context.tempDir + '/guncat-py';
    if (!fileIo.accessSync(scratch)) {
      fileIo.mkdirSync(scratch, true);
    }
    // argv 走"一行一个参数"的纯文本: 启动器不需要 import json 就能拿到参数
    let argvText: string = argv.length > 0 ? argv.join('\n') : '-c';
    let stdinPath: string = '';
    if (stdinText !== '') {
      stdinPath = scratch + '/stdin.txt';
      PythonService.writeText(stdinPath, stdinText);
    }
    let options: PyRunOptionsLike = {
      code: code,
      workDir: workDir,
      scratchDir: scratch,
      pythonHome: PythonService.pythonHome(context),
      pythonPath: PythonService.pythonPath(context),
      argvJson: argvText,
      stdinPath: stdinPath,
      certFile: PythonService.runtimeDir(context) + '/cacert.pem',
      timeoutMs: timeoutMs
    };
    // 熔断/忙判定放在入队之前: 上一次超时未结束的任务还在跑, 新调用绝不排队(会把 CPU 烧满)
    let state: number = 0;
    try {
      state = pyNativeState();
    } catch (e) {
      state = 0;
    }
    if (state === 2) {
      return PythonService.failResult('[python 已停用] 本会话连续 10 次超时且有任务未能中断; ' +
        '为免持续占 CPU, 已停止执行 Python, 请重启应用。');
    }
    if (state === 1) {
      return PythonService.failResult('[python 忙] 上一次 Python 调用超时且未能中断, 仍在后台运行; ' +
        '它结束后会自动恢复(不会排队)。请稍后再试。');
    }
    // 串行化: 前一个调用结束后才开始(无论成功失败)
    await PythonService.chain.catch((): void => {});
    let release: () => void = (): void => {};
    PythonService.chain = new Promise<void>((resolve: () => void): void => {
      release = resolve;
    });
    try {
      return pyRunNative(options);
    } finally {
      release();
    }
  }

  /** run_python 工具入口 */
  static async run(context: common.UIAbilityContext, convId: string,
    args: Record<string, Object>): Promise<ToolExecResult> {
    let code: string = args['code'] !== undefined ? String(args['code']) : '';
    if (code.trim() === '') {
      return PythonService.fail('缺少必填参数 code(要执行的 Python 源码)');
    }
    let codeBytes: number = PythonService.utf8Length(code);
    if (codeBytes > Constants.WORK_PY_MAX_CODE_BYTES) {
      return PythonService.fail('code 过大(' + codeBytes.toString() + ' 字节, 上限 ' +
        Constants.WORK_PY_MAX_CODE_BYTES.toString() + ')');
    }
    let cwdRel: string = args['cwd'] !== undefined ? String(args['cwd']) : '';
    let timeoutMs: number = Constants.WORK_PY_DEFAULT_TIMEOUT_MS;
    if (args['timeout_ms'] !== undefined) {
      let raw: number = Number(args['timeout_ms']);
      if (isFinite(raw) && raw > 0) {
        timeoutMs = Math.min(Math.floor(raw), Constants.WORK_PY_MAX_TIMEOUT_MS);
      }
    }
    let prep: string = await PythonService.ensureRuntime(context);
    if (prep !== '') {
      return PythonService.fail(prep);
    }
    let started: number = Date.now();
    let result: PyRunResult;
    try {
      result = await PythonService.exec(context, convId, code, [], cwdRel, timeoutMs);
    } catch (e) {
      return PythonService.fail('原生 Python 调用失败: ' + (e as Error).message);
    }
    let elapsed: number = Date.now() - started;
    return PythonService.format(context, convId, result, elapsed, timeoutMs);
  }

  private static format(context: common.UIAbilityContext, convId: string, r: PyRunResult,
    elapsedMs: number, timeoutMs: number): ToolExecResult {
    // SystemExit(非零) 属于"脚本主动退出", 不算工具失败
    let systemExit: boolean = r.error.indexOf('SystemExit') === 0;
    let ok: boolean = r.ok || systemExit;
    let header: string;
    if (r.softTimeout === true) {
      header = '[python 超时 · 未中断 · ' + (elapsedMs / 1000).toFixed(2) + 's · 上限 ' +
        (timeoutMs / 1000).toFixed(0) + 's]';
    } else if (r.timedOut) {
      header = '[python 超时 · ' + (elapsedMs / 1000).toFixed(2) + 's · 上限 ' +
        (timeoutMs / 1000).toFixed(0) + 's]';
    } else if (ok) {
      header = r.exitCode !== 0 ? '[python exit ' + r.exitCode.toString() + ' · ' +
        (elapsedMs / 1000).toFixed(2) + 's]' : '[python ok · ' +
        (elapsedMs / 1000).toFixed(2) + 's]';
    } else {
      header = '[python 失败 · ' + (elapsedMs / 1000).toFixed(2) + 's]';
    }
    let parts: string[] = [header];
    let stdout: string = r.stdout !== undefined ? r.stdout : '';
    let stderr: string = r.stderr !== undefined ? r.stderr : '';
    if (stdout !== '') {
      parts.push(stdout.replace(/\s+$/, ''));
    } else if (ok) {
      parts.push('(无输出)');
    }
    if (stderr !== '') {
      parts.push('--- stderr ---');
      parts.push(stderr.replace(/\s+$/, ''));
    }
    if (!ok && r.error !== '') {
      parts.push('--- 错误 ---');
      parts.push(r.error.replace(/\s+$/, ''));
    }
    let body: string = parts.join('\n');
    let spillRel: string = '';
    if (body.length > Constants.WORK_PY_MAX_OUTPUT_CHARS) {
      spillRel = SpillStore.save(WorkFileService.workspaceRoot(context, convId),
        'run_python', body);
      body = SpillStore.truncateWithLocator(body, spillRel);
    }
    let out: ToolExecResult = new ToolExecResult();
    out.ok = ok;
    out.timeout = r.timedOut;
    out.output = body;
    return out;
  }

  private static fail(message: string): ToolExecResult {
    let out: ToolExecResult = new ToolExecResult();
    out.ok = false;
    out.output = message;
    return out;
  }

  private static failResult(message: string): PyRunResult {
    return {
      'ok': false,
      'timedOut': false,
      'exitCode': 0,
      'stdout': '',
      'stderr': '',
      'error': message,
      'durationMs': 0
    } as PyRunResult;
  }

  private static utf8Length(text: string): number {
    return new util.TextEncoder().encodeInto(text).byteLength;
  }

  private static readText(path: string): string {
    try {
      let stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return '';
      }
      let buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      let file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buffer);
      } finally {
        fileIo.closeSync(file);
      }
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
    } catch (e) {
      return '';
    }
  }

  private static writeText(path: string, content: string): void {
    let bytes: Uint8Array = new util.TextEncoder().encodeInto(content);
    let file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      let buffer: ArrayBuffer = bytes.buffer as ArrayBuffer;
      if (bytes.byteOffset !== 0 || bytes.byteLength !== buffer.byteLength) {
        buffer = bytes.slice().buffer as ArrayBuffer;
      }
      fileIo.writeSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file);
    }
  }
}

/** 与 libguncatpy 的 PyRunOptions 对齐(避免在 ArkTS 里 import 原生类型, 保持可测) */
interface PyRunOptionsLike {
  code: string;
  workDir: string;
  scratchDir: string;
  pythonHome: string;
  pythonPath: string;
  argvJson: string;
  stdinPath: string;
  certFile: string;
  timeoutMs: number;
}
