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
import { isSafeRelPath } from './IecParsing';
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
    if (cwdRel !== '' && !isSafeRelPath(cwdRel)) {
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

    // 先确保运行核与资源根就绪：下面按会话建 HOME/TMPDIR 时目录必须已经存在。
    // ensure() 内部单飞并缓存结果，IecRuntime.run 随后再调一次不会重复初始化。
    const ready: string = await IecRuntime.ensure(context);
    if (ready !== '') {
      return IecShellService.fail(ready);
    }

    // 子进程环境。PATH 必须显式给：IEC 起进程时不会替我们拼 PATH，而应用进程
    // 自己的环境里没有 <sysroot>/bin（launcher 都在那儿），不给就是 command not found。
    //
    // HOME / TMPDIR 按会话分目录：固定在 <sysroot>/home 时所有会话共用一份
    // ~/.gitconfig / ~/.ssh，A 会话的配置会串到 B 会话；TMPDIR 同理，A 会话的
    // 临时文件会留在 B 会话能看到的同一个目录里。会话目录在工作区外，故
    // read_file 仍然看不见，需要回读的临时文件用 `mktemp ./x.XXXXXX`。
    const home: string = IecRuntime.sessionHome(convId);
    IecShellService.seedGitConfig(home);
    let env: Record<string, string> = {
      'PATH': IecRuntime.binDir() + ':' + IecRuntime.sysroot() + '/usr/bin:/usr/bin:/bin',
      'HOME': home,
      'TMPDIR': IecRuntime.sessionTmp(convId),
      // /etc/passwd 里补的是 guncat；把 USER/LOGNAME 也对上，脚本里读 $USER 时
      // 不会拿到空串。toybox 的 whoami/logname 本质都是 `id -un`，也走这份 passwd。
      'USER': 'guncat',
      'LOGNAME': 'guncat',
      'SHELL': '/bin/sh',
      // 非交互环境里分页器只会挂到超时；git 也走同一条。
      'PAGER': 'cat',
      'GIT_PAGER': 'cat',
      // 沙箱不支持硬链接，但 link() 被 fs shim 用"复制"兜底，git clone 看到
      // inode 不一致会 fatal。打开 strict 后 link() 如实失败，git 自己回退到复制。
      'IEC_SHIM_LINK_STRICT': '1',
      // 空模板目录，见 seedGitConfig()：避免每次 init/clone 打 templates 警告。
      'GIT_TEMPLATE_DIR': IecRuntime.sysroot() + '/etc/git-templates',
      // 非交互环境里没有终端可问账号密码；误连私有仓库时直接失败比挂到工具超时好。
      'GIT_TERMINAL_PROMPT': '0',
      // git over ssh 同理：BatchMode 关掉密码/口令交互，host key 不弹确认，
      // 否则一次误连会一直挂到工具超时（真机实测 10s 仍未返回）。
      'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes -o StrictHostKeyChecking=no'
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
    // 完整输出已经落盘（可能是 stdout 或 stderr）。上层再做"截断 + 暂存"时
    // 必须指向这个文件，否则会把这里已截断的头段当成"完整结果"再存一份。
    result.spillRel = spillOut !== '' ? spillOut : spillErr;
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
  //
  // 阈值取"模型可见上限"而不是引擎 cap：20k~60k 字符的输出不会触发引擎 cap，
  // 但正文同样只回前 20k 字符。如果只在 >60KB 时落盘，这段尾巴既没送给模型、
  // 也不在 .spill 里，还会被标成"落盘失败"——等于静默丢数据。
  private static spill(context: common.UIAbilityContext, convId: string,
    text: string, kind: string): string {
    if (text === '' || text.length <= Constants.WORK_SHELL_HEAD_CHARS) {
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

  // 每会话的 HOME 是新建的空目录，git 会因为没有 user.name/user.email 拒绝提交。
  // 只在缺失时写一份默认身份；用户/模型自己 `git config --global` 改过就不再覆盖。
  // 旧会话已有的 .gitconfig 只补缺失的 core.quotepath（不覆盖用户设置）：不加它时
  // `git status`/`log` 会把中文文件名输出成 "\344\270\255.txt"。
  private static seedGitConfig(home: string): void {
    try {
      // git init/clone 会找 /usr/share/git-core/templates；沙箱里没有，于是每次都打
      // "templates not found" 警告。建一个空的模板目录并让 git 指向它（环境变量在
      // run() 里设置），stderr 就干净了。放在最前面：旧会话也会走过这里。
      try {
        const tpl: string = IecRuntime.sysroot() + '/etc/git-templates';
        if (!fileIo.accessSync(tpl)) {
          fileIo.mkdirSync(tpl);
        }
        // git 只在模板里有 hooks/ 时才创建 .git/hooks；空模板会让仓库缺这个目录，
        // 依赖 hooks 的脚本（AI 常见的 pre-commit/commit-msg）就无法写入。补一个空的。
        const hooks: string = tpl + '/hooks';
        if (!fileIo.accessSync(hooks)) {
          fileIo.mkdirSync(hooks);
        }
        // 同理，空模板也不会生成 .git/info/exclude；依赖它写忽略规则的脚本会失败。
        const info: string = tpl + '/info';
        if (!fileIo.accessSync(info)) {
          fileIo.mkdirSync(info);
        }
        const exclude: string = info + '/exclude';
        if (!fileIo.accessSync(exclude)) {
          const ef = fileIo.openSync(exclude, fileIo.OpenMode.CREATE |
            fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          fileIo.closeSync(ef);
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'git template dir failed: %{public}s', JSON.stringify(e));
      }
      const path: string = home + '/.gitconfig';
      if (fileIo.accessSync(path)) {
        let old: string = '';
        try {
          const st = fileIo.statSync(path);
          if (st.size > 0) {
            const buf: ArrayBuffer = new ArrayBuffer(st.size);
            const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
            try {
              fileIo.readSync(f.fd, buf);
            } finally {
              fileIo.closeSync(f);
            }
            old = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
          }
        } catch (e) {
          old = '';
        }
        if (old.indexOf('quotepath') < 0) {
          const f = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
          try {
            fileIo.writeSync(f.fd, '\n[core]\n\tquotepath = false\n');
          } finally {
            fileIo.closeSync(f);
          }
        }
        // 慢速/挂起的 HTTP 传输让 git 自己放弃，而不是把整个工具调用拖到超时。
        if (old.indexOf('lowSpeedTime') < 0) {
          const f = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
          try {
            fileIo.writeSync(f.fd,
              '\n[http]\n\tlowSpeedLimit = 1000\n\tlowSpeedTime = 30\n');
          } finally {
            fileIo.closeSync(f);
          }
        }
        return;
      }
      const text: string = '[user]\n\tname = Guncat\n\temail = guncat@local\n' +
        '[init]\n\tdefaultBranch = main\n[core]\n\tpager = cat\n\tquotepath = false\n' +
        '[http]\n\tlowSpeedLimit = 1000\n\tlowSpeedTime = 30\n';
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
        fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, text);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'seed gitconfig failed: %{public}s', JSON.stringify(e));
    }
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
      // 1b. 工作目录本身：pwd/getcwd 与相对路径写入。IEC 的 cwd 是会话工作区，
      //     这里失败通常意味着工作区没建出来，或 getcwd 被沙箱拦了。
      "echo '--- cwd'",
      'echo "PWD=$PWD"; pwd; echo "pwd rc=$?"; /bin/pwd 2>&1; ' +
        'ls -ld . 2>&1; echo "ls rc=$?"; ' +
        'echo rel > _rel.txt && cat _rel.txt && rm -f _rel.txt; echo "rel rc=$?"',
      // 2. mksh 的算术是 64 位还是 32 位：后者会溢出成负数。
      "echo '--- mksh 64-bit arithmetic'",
      'v=$((2000000000+2000000000)); echo "2000000000+2000000000=$v"; ' +
        '[ "$v" = 4000000000 ] || echo "[FAIL] arithmetic (expect 4000000000)"',
      // 3. TMPDIR 真可写；/tmp 必须彻底不存在（半挂载比不存在更危险）；
      //    id 能读到 /etc/passwd 里的真实 uid；UTF-8 在工具层、sh -c、脚本层一致。
      "echo '--- TMPDIR + id'",
      'echo x > "$TMPDIR/_t" && cat "$TMPDIR/_t" && rm -f "$TMPDIR/_t" || ' +
        'echo "[FAIL] TMPDIR write"',
      'id; id 2>/dev/null | grep -q "uid=" || echo "[FAIL] id (no uid)"',
      'id -un 2>/dev/null; [ "$(id -un 2>/dev/null)" = guncat ] || ' +
        'echo "[FAIL] id -un (expect guncat)"',
      "echo '--- /tmp absent'",
      'if [ -e /tmp ]; then echo "[FAIL] /tmp should be absent"; ' +
        'else echo "ok /tmp absent"; fi',
      "echo '--- utf8-mode'",
      'x=中文; n=${#x}; echo "len(中文)=$n (expect 2)"; ' +
        '[ "$n" = 2 ] || echo "[FAIL] utf8-mode (expect 2)"',
      'v=$(sh -c \'x=中文; echo ${#x}\'); echo "sh -c len=$v (expect 2)"; ' +
        '[ "$v" = 2 ] || echo "[FAIL] sh -c utf8 (expect 2)"',
      'printf \'%s\\n\' \'#!/bin/sh\' \'x=中文; echo ${#x}\' > "$TMPDIR/_u.sh"; ' +
        'chmod +x "$TMPDIR/_u.sh"; v=$("$TMPDIR/_u.sh"); ' +
        'echo "shebang len=$v (expect 2)"; [ "$v" = 2 ] || ' +
        'echo "[FAIL] shebang utf8 (expect 2)"; rm -f "$TMPDIR/_u.sh"',
      "echo '--- HOME/TMPDIR'",
      'echo "HOME=$HOME"; echo "TMPDIR=$TMPDIR"; ' +
        '[ -d "$TMPDIR" ] || echo "[FAIL] TMPDIR missing"',
      // 4. CA 注入；git 走 https。网络失败只记录 rc，不算自检失败。
      "echo '--- CA + git remote'",
      'echo "GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-<empty>}"',
      '[ -n "$GIT_SSL_CAINFO" ] && [ -f "$GIT_SSL_CAINFO" ] || echo "[FAIL] CA bundle"',
      'out=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote ' +
        'https://github.com/git/git.git HEAD 2>&1); rc=$?; ' +
        'echo "$out" | head -3; echo "git ls-remote rc=$rc (网络失败不算自检失败)"',
      // 4b. timeout 必须能收掉整棵命令树：只杀直接子进程时，孙进程会继续握着
      //     调用方的 stdout，$(...) 会卡到工具级超时（真机回归过）。
      "echo '--- timeout tree'",
      'st=$(date +%s); out=$(timeout 1 sh -c \'sleep 4 & wait\' 2>&1); rc=$?; ' +
        'en=$(date +%s); echo "timeout rc=$rc elapsed=$((en-st))"; ' +
        '[ "$rc" = 124 ] || echo "[FAIL] timeout rc (expect 124)"; ' +
        '[ $((en-st)) -le 3 ] || echo "[FAIL] timeout tree (expect <= 3s)"',
      // 嵌套 timeout：内层会为自己的子进程 setpgid，外层必须按 ppid 级联收树，
      // 只按 pgrp 会漏掉内层 sleep，$(...) 等它自然结束。
      'st=$(date +%s); out=$(timeout 1 timeout 5 sleep 4 2>&1); rc=$?; ' +
        'en=$(date +%s); echo "nested timeout rc=$rc elapsed=$((en-st))"; ' +
        '[ $((en-st)) -le 3 ] || echo "[FAIL] nested timeout (expect <= 3s)"',
      // 反过来由内层先到点：内层也必须能收掉自己的子命令，不杀外层。
      'st=$(date +%s); out=$(timeout 5 timeout 1 sleep 4 2>&1); rc=$?; ' +
        'en=$(date +%s); echo "nested inner rc=$rc elapsed=$((en-st))"; ' +
        '[ $((en-st)) -le 3 ] || echo "[FAIL] nested inner (expect <= 3s)"',
      // GNU 负字节数与 rm -d 是常见的输出裁剪/清理写法。
      "echo '--- head/rm'",
      'out=$(printf abcdef | head -c -2); echo "head -c -2=$out"; ' +
        '[ "$out" = abcd ] || echo "[FAIL] head -c -2"',
      'mkdir -p _rd; rm -d _rd; [ -d _rd ] && echo "[FAIL] rm -d empty" || echo "ok rm -d"; ' +
        'mkdir -p _rd/f; rm -d _rd 2>/dev/null; [ -d _rd ] && echo "ok rm -d nonempty" || ' +
        'echo "[FAIL] rm -d nonempty"; rm -rf _rd',
      // find -delete 是动作，GNU 不会隐式 -print；打印每个被删路径会误导调用方。
      "echo '--- find -delete'",
      'rm -rf _fd; mkdir -p _fd; touch _fd/a _fd/b; ' +
        'out=$(find _fd -type f -delete 2>&1); n=$(printf "%s" "$out" | wc -l); ' +
        'left=$(ls _fd | wc -l); echo "find -delete lines=$n left=$left"; ' +
        '[ "$n" = 0 ] && [ "$left" = 0 ] || echo "[FAIL] find -delete"; rm -rf _fd',
      // rename 覆盖软件（sed -i/mv）：普通文件必须落到可见名，不能把内容写成链接目标。
      "echo '--- rename over symlink'",
      'rm -rf _rl; mkdir _rl; echo target > _rl/t; ln -s t _rl/l; ' +
        'sed -i "s/target/changed/" _rl/l; ' +
        'echo "link=$(cat _rl/t) file=$(cat _rl/l)"; ' +
        '[ "$(cat _rl/t)" = target ] && [ "$(cat _rl/l)" = changed ] || ' +
        'echo "[FAIL] rename over symlink"; rm -rf _rl',
      // git 默认把非 ASCII 路径转义成 \344…；会话 gitconfig 已设 quotepath=false。
      "echo '--- git quotepath'",
      'rm -rf _gr; git init -q _gr; (cd _gr; git config user.email a@b; git config user.name a; ' +
        'echo u > "中.txt"; git add "中.txt"; git commit -qm u; echo v >> "中.txt"; ' +
        'out=$(git status --short); echo "git status=$out"; ' +
        'echo "$out" | grep -q "中.txt" || echo "[FAIL] git quotepath"); rm -rf _gr',
      // 5. python3：退出码要原样透传（7），标准库也要能 import。
      "echo '--- python3'",
      'timeout 10 python3 -c "import sys; sys.exit(7)"; echo "rc=$? (expect 7)"',
      // 报告里出现过 python3 退出码被吞成 0 的现象，用 3 再钉一遍（外层不能是管道）。
      'timeout 10 python3 -c "import sys; sys.exit(3)"; echo "rc=$? (expect 3)"',
      'timeout 10 python3 -c "print(1+1)"',
      // 没有 stdin 的工具调用必须读到 EOF，而不是等一个不会关的管道写端。
      // cat 无参读 fd0：正常应立即退出 0；挂起则 5 秒后 rc=124，能直接看出回归。
      "echo '--- stdin EOF'",
      'timeout 5 cat; echo "cat rc=$? (expect 0, 不能是 124)"',
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
      // 二进制结果提示让模型用 base64；这个命令必须在 PATH 里，否则提示是空头支票。
      "echo '--- base64'",
      'out=$(printf AB | timeout 10 base64 2>&1); echo "base64=$out rc=$?"; ' +
        '[ "$out" = "QUI=" ] || echo "[FAIL] base64 (expect QUI=)"',
      "echo '--- diff'",
      "printf 'a\\n' > \"$TMPDIR/_d1\"; printf 'b\\n' > \"$TMPDIR/_d2\"; " +
        'timeout 10 diff -u "$TMPDIR/_d1" "$TMPDIR/_d2"; echo "diff rc=$? (expect 1)"',
      // 目录比较：git diff --no-index 本身就递归，但没有 -r 开关；包装器接受
      // GNU 的 -r 并忽略，否则会以 `unknown switch 'r'` 失败。
      'mkdir -p _r1 _r2; echo a > _r1/f; echo b > _r2/f; ' +
        'timeout 10 diff -r _r1 _r2 >/dev/null 2>&1; rc=$?; echo "diff -r rc=$rc (expect 1)"; ' +
        '[ "$rc" = 1 ] || echo "[FAIL] diff -r"; rm -rf _r1 _r2',
      // exec 请求曾经写死 32KiB 栈缓冲，长参数（`sh -c "$big"`、`python3 -c`、
      // xargs 追加的大参数）会 E2BIG；现在超出栈缓冲时按需分配。
      "echo '--- big argv'",
      's=$(python3 -c "print(\'x\'*40000)"); out=$(/bin/echo "$s" | wc -c); ' +
        'echo "big argv bytes=$out (expect 40001)"; ' +
        '[ "$out" = 40001 ] || echo "[FAIL] big argv (expect 40001)"',
      // GNU 的负行数（除最后 N 行）常见于裁掉输出的末尾摘要。
      'out=$(printf "a\\nb\\nc\\n" | head -n -1 | tr "\\n" ","); ' +
        'echo "head -n -1=$out"; [ "$out" = "a,b," ] || echo "[FAIL] head -n -1"',
      // awk 的 system()/popen() 走 libc 内部 execl，会绕过 exec shim 被沙箱拒绝；
      // shim 里用 fork + 同一条 exec 服务路径实现，下面两条钉住它。
      "echo '--- awk exec'",
      'out=$(awk \'BEGIN{print system("echo hi")}\' 2>&1 | tr "\\n" ","); ' +
        'echo "awk system=$out (expect hi,0,)"; ' +
        '[ "$out" = "hi,0," ] || echo "[FAIL] awk system"',
      'out=$(awk \'BEGIN{"echo hi" | getline l; print l}\' 2>&1); ' +
        'echo "awk popen=$out"; [ "$out" = "hi" ] || echo "[FAIL] awk popen"',
      "echo '--- sftp/scp'",
      // OpenSSH 的 sftp 没有 -V：-h / 无参至少能打出 usage 首行。
      "timeout 10 sh -c '{ sftp -V 2>&1; sftp -h 2>&1; sftp 2>&1; } | head -1'",
      'p=$(command -v scp 2>/dev/null); echo "scp=$p"; ' +
        '[ -n "$p" ] || echo "[FAIL] scp missing"',
      // 6a. xargs -I：GNU/BSD 常见写法，toybox 原版没有；AI 常用它做逐项替换。
      //     同时钉住不带 -I 的普通模式，避免新增选项解析影响原路径。
      "echo '--- xargs'",
      'printf "a\\n" | xargs -n1 echo base 2>&1; echo "xargs base rc=$?"',
      'exp=$(printf "[a b]\\n[c]"); ' +
        'out=$(printf "a b\\nc\\n" | timeout 10 xargs -I{} echo "[{}]" 2>&1); ' +
        'echo "xargs bundled rc=$?"; echo "$out"; ' +
        '[ "$out" = "$exp" ] || echo "[FAIL] xargs -I{}"',
      'out=$(printf "a b\\nc\\n" | timeout 10 xargs -I {} echo "[{}]" 2>&1); ' +
        'echo "xargs spaced rc=$?"; echo "$out"; ' +
        '[ "$out" = "$exp" ] || echo "[FAIL] xargs -I {}"',
      'out=$(printf "a\\n" | timeout 10 xargs -I{} echo base 2>&1); ' +
        'echo "xargs append=$out"; ' +
        '[ "$out" = "base a" ] || echo "[FAIL] xargs append"',
      // -P 是 -I 的常见组合；并行仍逐行替换。
      'out=$(printf "1\\n2\\n3\\n" | timeout 10 xargs -P3 -I{} sh -c \'echo {}\' 2>&1 | ' +
        'sort | tr "\\n" ","); echo "xargs -P: $out"; ' +
        '[ "$out" = "1,2,3," ] || echo "[FAIL] xargs -P -I"',
      // -0/-a：toybox 原版在设备上曾只处理第一项。printf 的 \\0 是给 mksh 的转义，
      //     到 xargs 手里才是真正的 NUL 分隔。
      'out=$(printf "a b\\0c\\0" | timeout 10 xargs -0 -n1 echo base 2>&1 | ' +
        'tr "\\n" ","); echo "xargs -0 -n1: $out"; ' +
        '[ "$out" = "base a b,base c," ] || echo "[FAIL] xargs -0 -n1"',
      'exp=$(printf "[a b]\\n[c]"); ' +
        'out=$(printf "a b\\0c\\0" | timeout 10 xargs -0 -I{} echo "[{}]" 2>&1); ' +
        'echo "xargs -0 -I: $out"; ' +
        '[ "$out" = "$exp" ] || echo "[FAIL] xargs -0 -I{}"',
      'printf "x\\ny\\nz\\n" > "$TMPDIR/_a.txt"; ' +
        'out=$(timeout 10 xargs -a "$TMPDIR/_a.txt" -n1 echo base 2>&1 | tr "\\n" ","); ' +
        'echo "xargs -a: $out"; ' +
        '[ "$out" = "base x,base y,base z," ] || echo "[FAIL] xargs -a"; ' +
        'rm -f "$TMPDIR/_a.txt"',
      // 命令自身带选项（`xargs -n1 sh -c '...'`、`xargs echo -n`）时，xargs 必须在
      // 第一个非选项参数处停止解析。见 NEWTOY 选项串开头的 `^`：它曾经被 -I 挤到
      // 第二位，导致 `-c`/`-n` 被当成 xargs 自己的选项。
      'out=$(printf "x\\n" | timeout 10 xargs -n1 sh -c \'echo A\' 2>&1); ' +
        'echo "xargs sh -c=$out"; [ "$out" = "A" ] || echo "[FAIL] xargs sh -c"',
      'out=$(printf "x\\n" | timeout 10 xargs -n1 echo -n 2>&1); ' +
        'echo "xargs echo -n=$out"; [ "$out" = "x" ] || echo "[FAIL] xargs operand option"',
      // 255 是 POSIX 约定的"停止后续批次"，toybox 以 124 退出。
      'printf "x\\n" | timeout 10 xargs -n1 sh -c \'exit 255\' >/dev/null 2>&1; ' +
        'echo "xargs 255 rc=$? (expect 124)"',
      // 6b. zip 的合并短选项（AI 常用 `zip -qr out.zip dir`）；自编解析器曾只认整词。
      "echo '--- zip'",
      'rm -rf _za _z.zip; mkdir -p _za; echo z > _za/f.txt; ' +
        'zip -qr _z.zip _za; echo "zip rc=$?"; ' +
        'unzip -l _z.zip 2>/dev/null | grep -q "_za/f.txt" && echo "ok zip -qr" || ' +
        'echo "[FAIL] zip -qr"; rm -rf _za _z.zip',
      // -x 排除：`-x` 在路径之后，必须先收集模式再遍历目录；曾经把模式当输入文件，
      // 排除失效且被排除的文件还会重复入包。
      'rm -rf _zx _zx.zip; mkdir -p _zx/keep _zx/skip; echo a > _zx/keep/a; ' +
        'echo b > _zx/skip/b; zip -qr _zx.zip _zx -x "_zx/skip/*"; ' +
        'out=$(unzip -l _zx.zip 2>/dev/null | grep -c "_zx/skip/b"); ' +
        'echo "zip -x excluded=$out (expect 0)"; ' +
        '[ "$out" = 0 ] || echo "[FAIL] zip -x"; rm -rf _zx _zx.zip',
      // .tar.bz2/.tar.xz：bsdtar 走外部过滤器，libarchive 的 posix_spawnp 会绕过
      // exec shim；改为 fork+execvp 并补 xz/bzip2 过滤器后解包可用。
      "echo '--- tar xz/bz2'",
      'mkdir -p _tsrc; echo hi > _tsrc/f; ' +
        'python3 -c "import tarfile; t=tarfile.open(\'_t.tar.bz2\',\'w:bz2\'); t.add(\'_tsrc\'); t.close()"; ' +
        'python3 -c "import tarfile; t=tarfile.open(\'_t.tar.xz\',\'w:xz\'); t.add(\'_tsrc\'); t.close()"; ' +
        'mkdir -p _to1 _to2; tar xjf _t.tar.bz2 -C _to1 2>/dev/null; ' +
        'tar xJf _t.tar.xz -C _to2 2>/dev/null; ' +
        'echo "tar bz2=$(cat _to1/_tsrc/f 2>&1) xz=$(cat _to2/_tsrc/f 2>&1)"; ' +
        '[ "$(cat _to1/_tsrc/f 2>/dev/null)" = hi ] && ' +
        '[ "$(cat _to2/_tsrc/f 2>/dev/null)" = hi ] || echo "[FAIL] tar xz/bz2"; ' +
        'rm -rf _tsrc _to1 _to2 _t.tar.bz2 _t.tar.xz',
      // 7. node/npm（npm 是解出来的 JS 树，验证 npm-cli.js 路径没拼错）。
      "echo '--- node/npm'",
      'timeout 10 node -v',
      'timeout 10 npm -v',
      // 8. 清理临时文件，别把验收垃圾留在资源根/工作区。
      'rm -f "$TMPDIR/_t" "$TMPDIR/_d1" "$TMPDIR/_d2" "$TMPDIR/_u.sh" t.txt t.tar',
      "echo 'SELFTEST DONE'"
    ];
    let args: Record<string, Object> = {
      'command': lines.join('\n'),
      'timeout_ms': 60000
    };
    const result: ToolExecResult = await IecShellService.run(context, '__iec_selftest', args);
    // 带 stdin 的独立调用：`cat` 必须读完 4 行后看到 EOF 正常退出。设备上会话
    // stdin 管道曾经在数据写完后不关写端，cat/wc/read 会挂到超时；这条能把
    // 回归直接暴露成 rc=124 或超时。
    let stdinArgs: Record<string, Object> = {
      'command': 'cat',
      'stdin': 'L1\nL2\nL3\nL4\n',
      'timeout_ms': 15000
    };
    const stdinProbe: ToolExecResult = await IecShellService.run(context, '__iec_selftest',
      stdinArgs);
    // 20k~60k 字符的输出不在引擎 cap 内，但正文仍只回前 20k 字符；必须落 .spill，
    // 否则尾巴静默丢失。seq 1 8000 约 38KB，正好落在这个区间。
    let bigArgs: Record<string, Object> = {
      'command': 'seq 1 8000',
      'timeout_ms': 15000
    };
    const bigProbe: ToolExecResult = await IecShellService.run(context, '__iec_selftest',
      bigArgs);
    const bigSpill: string = bigProbe.spillRel === undefined ? '' : bigProbe.spillRel as string;
    let bigOk: boolean = false;
    const bigAbs: string = WorkFileService.workspaceRoot(context, '__iec_selftest') + '/' + bigSpill;
    if (bigSpill.indexOf(Constants.WORK_SPILL_DIR + '/') === 0) {
      try {
        bigOk = fileIo.accessSync(bigAbs);
      } catch (e) {
        bigOk = false;
      }
    }
    if (bigOk) {
      try {
        fileIo.unlinkSync(bigAbs);
      } catch (e) {
      }
    }
    return result.output + '\n--- stdin data\n' + stdinProbe.output +
      '\n--- big output\n' + (bigOk ? 'ok big-output spill ' + bigSpill : '[FAIL] big-output spill');
  }
}
