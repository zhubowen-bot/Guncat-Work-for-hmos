// IecShellService: shell 工具的原生后端（IEC exec 会话）。
//
// 与 LinuxShellService 的区别只有执行方式：那条路把命令送进 QEMU 里的 Alpine
// （TCI 解释执行），这条路由 IEC 直接 fork + 原生执行，不需要虚拟机、不需要 JIT
// 权限。**对模型暴露的工具协议完全不变**（command / cwd / stdin / timeout_ms），
// 所以 HarnessTools 里只是换一个实现类。
//
// 工作区语义保持不变：cwd 是工作区内的相对路径，绝对路径由 workspaceRoot 拼出来；
// 输出超过上限仍落 .spill/ 供 read_file 读回。
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { Constants } from '../common/Constants';
import { IecRuntime, IecRunResult } from './IecRuntime';
import { PythonService } from './PythonService';
import { ToolExecResult, WorkFileService } from './WorkFileService';

const DOMAIN: number = 0x0000;
const TAG: string = 'IecShell';

export class IecShellService {
  static readonly TOOL_NAME: string = Constants.WORK_SHELL_TOOL_NAME;

  static async run(context: common.UIAbilityContext, convId: string,
    args: Record<string, Object>): Promise<ToolExecResult> {
    const command: string = IecShellService.strArg(args, 'command', '');
    if (command.trim() === '') {
      return IecShellService.fail('缺少参数 command(要执行的 shell 命令)');
    }
    const cmdBytes: number = new util.TextEncoder().encodeInto(command).length;
    if (cmdBytes > Constants.WORK_SHELL_MAX_COMMAND_BYTES) {
      return IecShellService.fail('命令过长(' + WorkFileService.formatSize(cmdBytes) +
        '), 上限 ' + WorkFileService.formatSize(Constants.WORK_SHELL_MAX_COMMAND_BYTES) +
        '; 长脚本请先 write_file 再用 shell 执行');
    }

    const cwdRel: string = IecShellService.strArg(args, 'cwd', '').trim();
    if (cwdRel !== '' && !IecShellService.isSafeRel(cwdRel)) {
      return IecShellService.fail('cwd 必须是工作区内的相对路径(不能以 / 开头, 不能含 ..)');
    }

    const stdin: string = IecShellService.strArg(args, 'stdin', '');
    if (stdin !== '' &&
      new util.TextEncoder().encodeInto(stdin).length > Constants.WORK_SHELL_MAX_STDIN_BYTES) {
      return IecShellService.fail('stdin 过长, 上限 ' +
        WorkFileService.formatSize(Constants.WORK_SHELL_MAX_STDIN_BYTES));
    }

    let timeoutMs: number = IecShellService.intArg(args, 'timeout_ms',
      Constants.WORK_SHELL_DEFAULT_TIMEOUT_MS);
    if (timeoutMs < 1000) {
      timeoutMs = 1000;
    }
    if (timeoutMs > Constants.WORK_SHELL_MAX_TIMEOUT_MS) {
      timeoutMs = Constants.WORK_SHELL_MAX_TIMEOUT_MS;
    }

    const root: string = WorkFileService.workspaceRoot(context, convId);
    WorkFileService.ensureWorkspace(context, convId);
    let cwd: string = root;
    if (cwdRel !== '') {
      const resolved: string | null = WorkFileService.resolveSafe(root, cwdRel);
      if (resolved === null) {
        return IecShellService.fail('cwd 越出工作区: ' + cwdRel);
      }
      cwd = resolved;
    }

    const startedAt: number = Date.now();

    // 子进程环境。PATH 必须显式给：IEC 起进程时不会替我们拼 PATH，而应用进程
    // 自己的环境里没有 <sysroot>/bin（launcher 都在那儿），不给就是 command not found。
    let env: Record<string, string> = {
      'PATH': IecRuntime.binDir() + ':' + IecRuntime.sysroot() + '/usr/bin:/usr/bin:/bin',
      'HOME': IecRuntime.sysroot() + '/home',
      'TMPDIR': IecRuntime.sysroot() + '/tmp'
    };

    // shell 里的 python3 用的是 Guncat 自带的 libpython3.12.so（launcher 已指向它）。
    // 它要 PYTHONHOME/PYTHONPATH 才能找到标准库；C 扩展平铺在 bundle libs 里，
    // 也要进 PYTHONPATH 才 import 得到。解释器自己保持常驻，这里只是把路径传进去。
    try {
      const pyErr: string = await PythonService.ensureRuntime(context);
      if (pyErr === '') {
        env['PYTHONHOME'] = PythonService.pythonHome(context);
        env['PYTHONPATH'] = PythonService.pythonPath(context) +
          ':/data/storage/el1/bundle/libs/arm64';
      } else {
        hilog.warn(DOMAIN, TAG, 'python runtime unavailable: %{public}s', pyErr);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'python env skipped: %{public}s', JSON.stringify(e));
    }

    const run = await IecRuntime.run(context, command, {
      cwd: cwd,
      stdin: stdin,
      timeoutMs: timeoutMs,
      // 留够余量：超过 60KB 的部分要落 .spill，被引擎的 cap 丢掉就写不回去了。
      maxOutputBytes: Math.max(8 * 1024 * 1024, Constants.WORK_SHELL_MAX_OUTPUT_BYTES * 4),
      env: env
    });
    const elapsed: number = Date.now() - startedAt;

    if (run.out === '' && run.err !== '' && run.code < 0) {
      return IecShellService.fail(run.err);
    }

    const spillOut: string = IecShellService.spill(context, convId, run.out, 'stdout');
    const spillErr: string = IecShellService.spill(context, convId, run.err, 'stderr');

    let result: ToolExecResult = new ToolExecResult();
    result.ok = true;
    result.output = IecShellService.format(run, elapsed, cwdRel === '' ? '.' : cwdRel,
      spillOut, spillErr);
    return result;
  }

  private static format(run: IecRunResult, elapsedMs: number, cwdLabel: string,
    spillOut: string, spillErr: string): string {
    const seconds: string = (elapsedMs / 1000).toFixed(2);
    const parts: string[] = [];
    parts.push('[exit ' + run.code.toString() + ' · ' + seconds + 's · cwd ' + cwdLabel +
      (run.timedOut ? ' · 超时终止' : '') + ']');
    parts.push(IecShellService.body(run.out, spillOut));

    if (run.err.trim() !== '') {
      parts.push('--- stderr ---');
      parts.push(IecShellService.body(run.err, spillErr));
    }
    if (run.outDropped > 0 || run.errDropped > 0) {
      parts.push('[...引擎输出上限丢弃 ' + (run.outDropped + run.errDropped).toString() +
        ' 字节; 需要完整输出请重定向到文件后用 read_file 读回]');
    }
    return parts.join('\n');
  }

  private static body(text: string, spillRel: string): string {
    let head: string = text;
    let truncated: boolean = spillRel !== '';
    if (head.length > Constants.WORK_SHELL_HEAD_CHARS) {
      head = head.substring(0, Constants.WORK_SHELL_HEAD_CHARS);
      truncated = true;
    }
    if (!truncated) {
      return head;
    }
    if (spillRel !== '') {
      return head + '\n\n[...输出已截断: 完整内容在工作区 ' + spillRel +
        ', 需要时用 read_file 读回]';
    }
    return head + '\n\n[...输出已截断; 落盘失败, 建议把输出重定向到文件后用 read_file 读]';
  }

  // 超过工具单次返回上限的内容落盘到工作区 .spill/，返回相对路径；不需要时返回空串。
  private static spill(context: common.UIAbilityContext, convId: string,
    text: string, kind: string): string {
    if (text === '' ||
      new util.TextEncoder().encodeInto(text).length <= Constants.WORK_SHELL_MAX_OUTPUT_BYTES) {
      return '';
    }
    try {
      const root: string = WorkFileService.workspaceRoot(context, convId);
      const relDir: string = Constants.WORK_SPILL_DIR;
      const name: string = 'iec-' + Date.now().toString() + '-' + kind + '.log';
      const absDir: string = root + '/' + relDir;
      WorkFileService.ensureDir(absDir);
      const abs: string = absDir + '/' + name;
      const file = fileIo.openSync(abs, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
        fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, text);
      } finally {
        fileIo.closeSync(file);
      }
      return relDir + '/' + name;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'spill failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private static isSafeRel(rel: string): boolean {
    if (rel.startsWith('/') || rel.indexOf('..') !== -1 || rel.indexOf(':') !== -1) {
      return false;
    }
    return true;
  }

  private static strArg(args: Record<string, Object>, name: string, fallback: string): string {
    const value: Object | undefined = args[name];
    if (typeof value === 'string') {
      return value as string;
    }
    if (typeof value === 'number') {
      return (value as number).toString();
    }
    return fallback;
  }

  private static intArg(args: Record<string, Object>, name: string, fallback: number): number {
    const value: Object | undefined = args[name];
    if (typeof value === 'number') {
      return Math.round(value as number);
    }
    if (typeof value === 'string') {
      const n: number = Number.parseInt(value as string, 10);
      if (!Number.isNaN(n)) {
        return n;
      }
    }
    return fallback;
  }

  private static fail(text: string): ToolExecResult {
    let result: ToolExecResult = new ToolExecResult();
    result.ok = false;
    result.output = text;
    return result;
  }

  // 真机自检：`aa start ... --ps iecSelfTest 1` 时由 EntryAbility 调一次，结果进 hilog。
  // 只用于验收/排障，正常使用不会走到这里。
  static async selfTest(context: common.UIAbilityContext): Promise<string> {
    const command: string = 'echo IEC_OK; echo "--- uname"; uname -a; ' +
      'echo "--- ls"; ls /; echo "--- python"; python3 -c "import sys; print(sys.version.split()[0])"';
    let args: Record<string, Object> = { 'command': command };
    const result: ToolExecResult = await IecShellService.run(context, '__iec_selftest', args);
    return result.output;
  }
}
