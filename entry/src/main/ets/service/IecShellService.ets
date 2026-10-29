// IecShellService: shell 工具的原生后端（IEC exec 会话）。
//
// 与早期虚拟机后端（已删除）的区别只有执行方式：那条路把命令
// 送进应用进程内的 Linux 虚拟机，这条路由 IEC 直接 fork + 原生执行，不需要虚拟机、
// 不需要 JIT 权限。**对模型暴露的工具协议完全不变**（command / cwd / stdin /
// timeout_ms），所以 HarnessTools 里只是换一个实现类。
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
import {
  composeShellResult,
  formatBinaryCaveat,
  formatBinaryNote,
  formatDropped,
  formatStatusLine,
  formatStreamBody
} from './ShellResultFormat';
import { ToolExecResult, WorkFileService } from './WorkFileService';

const DOMAIN: number = 0x0000;
const TAG: string = 'IecShell';

export class IecShellService {
  // .spill 文件名里的进程内序号，避免同毫秒并发落盘互相覆盖。
  private static spillSeq: number = 0;

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
      'TMPDIR': IecRuntime.sysroot() + '/tmp',
      // 沙箱不支持硬链接，但 link() 被 fs shim 用"复制"兜底，git clone 看到
      // inode 不一致会 fatal。打开 strict 后 link() 如实失败，git 自己回退到复制。
      'IEC_SHIM_LINK_STRICT': '1'
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

    // CA：IEC 内置证书铺到 <sysroot>/etc/ssl/certs，git/openssl 按标准路径找。
    const ca: string = IecRuntime.installShellCaBundle();
    if (ca !== '') {
      env['GIT_SSL_CAINFO'] = ca;
      env['SSL_CERT_FILE'] = ca;
      env['CURL_CA_BUNDLE'] = ca;
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

    // 只有"命令压根没起来"才算工具失败。超时后主动终止时 code 也是负的，
    // 但它有输出、有退出状态行（超时终止），当成失败会把超时文案吞掉。
    if (run.startFailed) {
      const failed: ToolExecResult = IecShellService.fail(run.err);
      failed.timeout = run.timedOut;
      return failed;
    }

    const spillOut: string = IecShellService.spill(context, convId, run.out, 'stdout');
    const spillErr: string = IecShellService.spill(context, convId, run.err, 'stderr');

    let result: ToolExecResult = new ToolExecResult();
    result.ok = true;
    // 超时是可观测标记（审计日志统计超时率用），不是只写在正文里的一句话。
    result.timeout = run.timedOut;
    result.output = IecShellService.format(run, elapsed, cwdRel === '' ? '.' : cwdRel,
      spillOut, spillErr);
    return result;
  }

  private static format(run: IecRunResult, elapsedMs: number, cwdLabel: string,
    spillOut: string, spillErr: string): string {
    // 正文拼装全部走纯函数（ShellResultFormat），这里只负责把 run 的字段和
    // spill 结果喂进去。顺序/文案/空行规则见该模块。
    const caveat: string = formatBinaryCaveat(run.binary);
    return composeShellResult({
      head: formatStatusLine(run.code, run.signal, run.timedOut, run.startFailed,
        elapsedMs, cwdLabel),
      body: formatStreamBody(run.out, spillOut, Constants.WORK_SHELL_HEAD_CHARS, caveat),
      // 与拆分前一致：空 stderr 不进入拼装（spillErr 只可能来自非空 err）。
      err: run.err === ''
        ? ''
        : formatStreamBody(run.err, spillErr, Constants.WORK_SHELL_HEAD_CHARS, caveat),
      notes: {
        binary: formatBinaryNote(run.binary),
        dropped: formatDropped(run.outDropped, run.errDropped)
      }
    });
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
      // 同一毫秒里两条并发命令（上限 8）各自落盘时，只用 Date.now() 会撞名：
      // 后者 TRUNC 覆盖前者，两条工具结果指向同一份内容。序号是进程内单调的。
      IecShellService.spillSeq++;
      const name: string = 'iec-' + Date.now().toString() + '-' +
        IecShellService.spillSeq.toString() + '-' + kind + '.log';
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
  //
  // 设计：所有段互不阻断——每段先 `echo '--- 名称'`，失败只追加 `[FAIL] ...`，后面照跑；
  // 每个可能卡住的命令套 `timeout 10`，整体由 60s 工具超时兜底。最后一行固定
  // `SELFTEST DONE`：看到它就说明整组命令确实跑完了（是否有 [FAIL] 再逐行看）。
  // 覆盖清单与期望值见 docs/architecture/iec-runtime.md 的"验收"一节。
  static async selfTest(context: common.UIAbilityContext): Promise<string> {
    const tools: string = 'dd md5sum od nproc jq curl bc nc hexdump diff sftp node npm ' +
      'tar unzip zip git ssh python3';
    const lines: string[] = [
      'echo IEC_OK',
      'uname -s',
      'pwd',
      // 1. PATH：launcher 是否真的注册进了 <sysroot>/bin（缺一个就单独报一行）。
      "echo '--- PATH'",
      'for c in ' + tools + '; do ' +
        'if command -v "$c" >/dev/null 2>&1; then echo "ok   $c"; ' +
        'else echo "[FAIL] $c not found"; fi; done',
      // 2. mksh 的算术是 64 位还是 32 位：后者会溢出成负数。
      "echo '--- mksh 64-bit arithmetic'",
      'v=$((2000000000+2000000000)); echo "2000000000+2000000000=$v"; ' +
        '[ "$v" = 4000000000 ] || echo "[FAIL] arithmetic (expect 4000000000)"',
      // 3. /tmp 真可写；id 能读到 /etc/passwd 里的真实 uid。
      "echo '--- /tmp + id'",
      'echo x > /tmp/_t && cat /tmp/_t && rm -f /tmp/_t || echo "[FAIL] /tmp write"',
      'id; id 2>/dev/null | grep -q "uid=" || echo "[FAIL] id (no uid)"',
      // 4. CA 注入；git 走 https。网络失败只记录 rc，不算自检失败。
      "echo '--- CA + git remote'",
      'echo "GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-<empty>}"',
      '[ -n "$GIT_SSL_CAINFO" ] && [ -f "$GIT_SSL_CAINFO" ] || echo "[FAIL] CA bundle"',
      'out=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote ' +
        'https://github.com/git/git.git HEAD 2>&1); rc=$?; ' +
        'echo "$out" | head -3; echo "git ls-remote rc=$rc (网络失败不算自检失败)"',
      // 5. python3：退出码要原样透传（7），标准库也要能 import。
      "echo '--- python3'",
      'timeout 10 python3 -c "import sys; sys.exit(7)"; echo "rc=$? (expect 7)"',
      'timeout 10 python3 -c "print(1+1)"',
      // 6. 各补充命令的最小可用性用例。
      "echo '--- jq'",
      "printf '{\"a\":1}\\n' | timeout 10 jq -r .a",
      "echo '--- curl'",
      'timeout 10 curl --version 2>&1 | head -1',
      "echo '--- bc'",
      "echo '1+1' | timeout 10 bc",
      "echo '--- nc'",
      // 自编 nc 没有 -h 时走 usage；无参也打印 usage，两条都试，取第一行。
      "timeout 10 sh -c '{ nc -h 2>&1; nc 2>&1; } | head -1'",
      "echo '--- hexdump'",
      'printf AB | timeout 10 hexdump -C',
      "echo '--- diff'",
      "printf 'a\\n' > /tmp/_d1; printf 'b\\n' > /tmp/_d2; " +
        'timeout 10 diff -u /tmp/_d1 /tmp/_d2; echo "diff rc=$? (expect 1)"',
      "echo '--- sftp'",
      // OpenSSH 的 sftp 没有 -V：-h / 无参至少能打出 usage 首行。
      "timeout 10 sh -c '{ sftp -V 2>&1; sftp -h 2>&1; sftp 2>&1; } | head -1'",
      // 7. node/npm（npm 是解出来的 JS 树，验证 npm-cli.js 路径没拼错）。
      "echo '--- node/npm'",
      'timeout 10 node -v',
      'timeout 10 npm -v',
      // 8. 清理临时文件，别把验收垃圾留在资源根/工作区。
      'rm -f /tmp/_t /tmp/_d1 /tmp/_d2 t.txt t.tar',
      "echo 'SELFTEST DONE'"
    ];
    let args: Record<string, Object> = {
      'command': lines.join('\n'),
      'timeout_ms': 60000
    };
    const result: ToolExecResult = await IecShellService.run(context, '__iec_selftest', args);
    return result.output;
  }
}
