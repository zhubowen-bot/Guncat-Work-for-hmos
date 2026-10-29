// PythonService: 原生 CPython 工具(run_python)的执行后端。
//
// 设计要点:
//   * 解释器是**应用进程内的真 CPython**(libpython3.12.so, 由 libguncatpy.so 动态加载),
//     不经过虚拟机 —— 同一段脚本比外部进程快 2~3 个数量级。
//   * 工作目录固定为**会话工作区**, 与 shell / read_file / write_file 看到的是同一批文件
//     (原生侧直接走 POSIX 文件 API, 不存在"两套目录"的问题)。
//   * 没有 shell: subprocess 只能直接 exec 单个程序; multiprocessing 只有 fork 上下文可用
//     (spawn/forkserver 要重新 exec 解释器, 原生侧会明确抛错), Queue/Pool 要 /dev/shm。
//     需要调 Unix 工具请用 shell 工具。
//   * 原生侧全局串行(解释器有 GIL, 且只有一个实例), 这里再用 promise 链排队, 保证不并发进解释器。
//     超时未回收的任务没结束前, 原生侧会直接拒绝新调用(不排队), 任务结束后自动恢复。
import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
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
const RAW_SITE: string = 'python/site-packages.zip';
const RAW_EXTRAS: string = 'python/extras.zip';
const RAW_CERT: string = 'python/cacert.pem';
// 中文字体: 思源黑体 SC(GB2312 子集, OFL-1.1), 让 matplotlib/Pillow 能直接画中文
const RAW_FONT: string = 'python/fonts/SourceHanSansSC-Regular.otf';
const FONT_FILE: string = 'SourceHanSansSC-Regular.otf';
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

  /** 解释器的 PYTHONHOME（shell 里起同一个解释器时要用，见 IecShellService） */
  static pythonHome(context: common.UIAbilityContext): string {
    return PythonService.runtimeDir(context);
  }

  /** 解释器的 PYTHONPATH（标准库 zip + 三方纯 Python 包 + extras） */
  static pythonPath(context: common.UIAbilityContext): string {
    // 只给标准库 zip; C 扩展模块在应用的 lib 目录里(native 侧用 dladdr 自动并进 PYTHONPATH),
    // 因为设备上只有 lib 目录下的 .so 允许 dlopen。
    let stdlib: string = PythonService.runtimeDir(context) + '/' + PY_STDLIB_SUBDIR;
    // 标准库 zip + 纯 Python 三方库 zip + extras(numpy/pandas 的 .py 部分)
    // 注意顺序: extras 必须在应用 lib 目录之前 —— 那边只放 .so, 包本体要在这里先被找到
    return stdlib + '/python312.zip' + ':' + stdlib + '/site-packages.zip' + ':' + stdlib + '/extras';
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
      // 纯 Python 三方库(独立 zip, 与标准库分开升级)
      try {
        RawAsset.extract(context, RAW_SITE, stdlib + '/site-packages.zip');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'extract site-packages failed: %{public}s', (e as Error).message);
      }
      // numpy/pandas/PIL/matplotlib/scipy 的纯 Python 部分。
      // **必须解压成真实目录, 不能只把 zip 放那儿**: docx/pptx 的模板、pandas 的数据文件都用
      // os.path 定位, zip 内路径一律 False(真机实测 PackageNotFoundError)。解压后还能省掉
      // zipimport 的开销。
      try {
        let extrasZip: string = stdlib + '/extras.zip';
        RawAsset.extract(context, RAW_EXTRAS, extrasZip);
        let extrasDir: string = stdlib + '/extras';
        // 旧版本把 extras.zip **原样**放在这个路径(是个文件), 现在要的是目录。
        // 这里不用 statSync().isFile() —— harness 的类型桩里没有该方法(CI 会报 TS2339),
        // 而且"先建目录, 失败就当同名文件清掉重建"本身更省事、更稳。
        try {
          if (!fileIo.accessSync(extrasDir)) {
            fileIo.mkdirSync(extrasDir, true);
          }
        } catch (e) {
          try {
            fileIo.unlinkSync(extrasDir);
          } catch (e2) {
            hilog.warn(DOMAIN, TAG, 'remove stale extras failed: %{public}s', (e2 as Error).message);
          }
          fileIo.mkdirSync(extrasDir, true);
        }
        await zlib.decompressFile(extrasZip, extrasDir);
        try {
          fileIo.unlinkSync(extrasZip);   // 解压完就删, 省 ~77MB 沙箱空间
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'remove extras.zip failed: %{public}s', (e as Error).message);
        }
        hilog.info(DOMAIN, TAG, 'extras unpacked into %{public}s', extrasDir);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'extract extras failed: %{public}s', (e as Error).message);
      }
      // https 用的 CA 证书(应用沙箱里没有系统 CA)
      try {
        RawAsset.extract(context, RAW_CERT, root + '/cacert.pem');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'extract cacert failed: %{public}s', (e as Error).message);
      }
      // 中文字体(思源黑体 GB2312 子集, OFL-1.1): 放在 stdlib 同级 fonts/,
      // guncat_fonts 会在这个位置找它, matplotlib 一 import 就自动注册(画中文不再是方块)
      try {
        let fontDir: string = stdlib + '/fonts';
        // 目录不存在时 fileIo.openSync(CREATE) 会直接失败 —— 之前就是漏了这句 mkdir,
        // 导致字体从未落地、guncat_fonts.path() 在真机上恒为 None(真机实测发现)
        if (!fileIo.accessSync(fontDir)) {
          fileIo.mkdirSync(fontDir, true);
        }
        RawAsset.extract(context, RAW_FONT, fontDir + '/' + FONT_FILE);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'extract cjk font failed: %{public}s', (e as Error).message);
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
   * 直接执行一段 Python(不做工具层包装), 供 run_python 使用。
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
      cacheDir: context.cacheDir,
      timeoutMs: timeoutMs
    };
    // 熔断/忙判定放在入队之前: 上一次超时未结束的任务还在跑, 新调用绝不排队(会把 CPU 烧满)
    let state: number = 0;
    try {
      state = pyNativeState();
    } catch (e) {
      state = 0;
    }
    if (state === 1) {
      return PythonService.failResult('[python 忙] 上一次 Python 调用还在执行(超时后未能中断, 仍在后台运行); ' +
        '它一结束就自动恢复(不会排队)。请稍后再试。');
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
    // 内存吃紧时原生侧会给一条提醒(不是错误): 放在最前面, 别埋在 stderr 里
    if (r.warning !== undefined && r.warning !== '') {
      parts.push(r.warning);
    }
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
  cacheDir: string;
  timeoutMs: number;
}
