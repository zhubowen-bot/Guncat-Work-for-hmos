// IecRuntime: 设备内原生执行核（IEC）的接入层。
//
// 为什么有它：
//   * Guncat 原来的 shell 工具是 QEMU TCI 解释执行的完整 Linux（Alpine），
//     一条命令动辄几秒；IEC 把命令编成 HarmonyOS 原生 .so，dlopen 后直接跑，
//     不需要 JIT 权限，也不需要虚拟机。
//   * IEC 的 exec 服务是按"替换调用者"设计的（execve shim）；这个文件把它包成
//     ArkTS 能用的"起一个进程、给三条管道、带超时"的接口。
//
// 生命周期：进程内只启动一次；launcher 只在版本戳变化时重写。
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ensureDir,
  execKillStale,
  execPoll,
  execRelease,
  execStart,
  execTerminate,
  initIecResourceManager,
  installCaBundle,
  probeCaps,
  startIecServer,
  writeSoLauncher,
  writeTxtFile
} from 'iec';

const DOMAIN: number = 0x0000;
const TAG: string = 'IecRuntime';

// 启动器/资源根布局。命令 so 在 bundle libs 的 arm64 目录
// （hvigor 把 entry/libs/<abi> 与 HAR 的 libs/<abi> 都打成 libs/<abi>）。
const SYSROOT: string = '/data/storage/el2/base/files';
const BIN_DIR: string = SYSROOT + '/bin/';
const BUNDLE_LIBS: string = '/data/storage/el1/bundle/libs/arm64/';

export interface IecRunOptions {
  cwd: string;
  stdin: string;
  timeoutMs: number;
  maxOutputBytes: number;
  // 子进程环境（覆盖项）。必须显式给 PATH：不然命令继承的是应用进程的环境，
  // 连 <sysroot>/bin 下的 launcher 都找不到，`sh -c 'ls'` 会直接 command not found。
  env: Record<string, string>;
}

export interface IecRunResult {
  code: number;
  out: string;
  err: string;
  timedOut: boolean;
  // 输出里出现了非法 UTF-8（解码成 U+FFFD）。二进制内容应重定向到文件，
  // 不要当文本用。
  binary: boolean;
  outDropped: number;
  errDropped: number;
  elapsedMs: number;
}

export class IecRuntime {
  private static started: boolean = false;
  private static startError: string = '';

  // 并发上限。每次运行占 4 个读/写线程与最多 8MB 缓冲；没有上限时，模型并行
  // 发十几条命令就能把内存和线程数推上去。超出的排队，不丢请求。
  private static readonly MAX_RUNS: number = 8;
  private static activeRuns: number = 0;
  private static waiters: Array<() => void> = [];

  private static async acquireSlot(): Promise<void> {
    if (IecRuntime.activeRuns < IecRuntime.MAX_RUNS) {
      IecRuntime.activeRuns++;
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      IecRuntime.waiters.push(resolve);
    });
    IecRuntime.activeRuns++;
  }

  private static releaseSlot(): void {
    IecRuntime.activeRuns--;
    const next: (() => void) | undefined = IecRuntime.waiters.shift();
    if (next !== undefined) {
      next();
    }
  }

  // 启动 exec/tty 服务并铺好 launcher。返回空串表示可用，否则是原因。
  static async ensure(context: common.UIAbilityContext): Promise<string> {
    if (IecRuntime.started) {
      return '';
    }
    if (IecRuntime.startError !== '') {
      return IecRuntime.startError;
    }
    try {
      initIecResourceManager(context.resourceManager);

      // 能力字由 native 侧探（fork / exec / jit / path）。不 pin：探针就是为
      // "不同设备/不同渠道能力不同"设计的，pin 死一个值等于把设备差异藏起来。
      const caps = probeCaps();
      hilog.info(DOMAIN, TAG,
        'caps packed=0x%{public}s chmod=%{public}d fork=%{public}d exec=%{public}d jit=%{public}d path=%{public}d',
        caps.packed.toString(16), caps.chmod, caps.fork, caps.exec, caps.jit, caps.path);

      IecRuntime.writeLaunchers();

      if (!startIecServer()) {
        IecRuntime.startError = 'IEC 服务启动失败（socket 建不出来）';
        return IecRuntime.startError;
      }
      // 上一次运行（崩溃/被强停）留下的命令进程会被 init 收养，继续占内存。
      // 每个命令都带 IEC_JOB，启动时按这个标记清一遍。
      try {
        const killed = execKillStale();
        if (killed > 0) {
          hilog.warn(DOMAIN, TAG, 'killed %{public}d stale command processes', killed);
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'stale sweep failed: %{public}s', JSON.stringify(e));
      }

      // toybox 到底有哪些 applet，以**这个库自己的回答**为准，不抄静态清单：
      // 抄清单的后果是 diff/bc/hexdump 这类没编进去的 applet 也留一个 launcher，
      // 执行时报 "Unknown command"；反过来 dd/md5sum/od 这些编进去的又没注册。
      await IecRuntime.writeToyboxApplets();

      IecRuntime.started = true;
      hilog.info(DOMAIN, TAG, 'IEC runtime ready');
      return '';
    } catch (e) {
      IecRuntime.startError = 'IEC 运行核加载失败: ' + JSON.stringify(e);
      hilog.error(DOMAIN, TAG, '%{public}s', IecRuntime.startError);
      return IecRuntime.startError;
    }
  }

  // 命令 so 的 launcher。写不存在的 so 不会报错（执行到它才失败），这样
  // "构建了哪些命令"不必和这里耦合。
  private static writeLaunchers(): void {
    ensureDir(BIN_DIR);
    ensureDir(SYSROOT + '/home');
    ensureDir(SYSROOT + '/tmp');
    ensureDir(SYSROOT + '/usr/bin');
    ensureDir(SYSROOT + '/etc/ssl/certs');

    // `id`/`whoami` 读 /etc/passwd；沙箱根里没有，补一份真实的 uid 记录。
    const ids: string[] = IecRuntime.readUidGid();
    if (ids.length === 2) {
      writeTxtFile(SYSROOT + '/etc/passwd',
        'guncat:x:' + ids[0] + ':' + ids[1] + ':Guncat:/home:/bin/sh\n');
      writeTxtFile(SYSROOT + '/etc/group', 'guncat:x:' + ids[1] + ':\n');
    }

    // 先清空再重建。launcher 是**持久文件**：上一次安装写下的 tar→libbsdtar 不会
    // 因为这次不写而消失，结果就是"命令在、库不在"的假故障。这个目录只放我们的
    // launcher，清掉是安全的。
    IecRuntime.clearLaunchers();

    let fails: number = 0;
    const add = (name: string, so: string, entry: string): void => {
      // primary=0 交给 IEC 按设备能力选 fork / native child process；写死 fork 会在
      // 没有 fork 的渠道上整片失效。
      fails += writeSoLauncher(BIN_DIR + name, BUNDLE_LIBS + so, entry, 2, 0);
    };

    // toybox 本体的 launcher；具体 applet 在服务起来后按 `toybox` 的输出枚举。
    add('toybox', 'libtoybox.so', 'bsh_toybox_main');

    // sh 是 shell 工具的唯一入口：没有它，IecShellService 直接报"运行核未就绪"。
    add('sh', 'libmksh.so', 'main');
    add('mksh', 'libmksh.so', 'main');

    // 可选命令按 **实际随包的 so** 注册。指向一个没打进来的 so，报错会是
    // "dlopen /libbsdtar.so: No such file"，看起来像工具坏了；不注册则是干净的
    // "command not found"。
    if (IecRuntime.hasSo('libdropbear.so')) {
      for (const name of ['ssh', 'dbclient', 'scp', 'ssh-keygen', 'dropbearkey',
        'dropbearconvert', 'dropbear']) {
        add(name, 'libdropbear.so', 'iec_dropbear_main');
      }
    }
    if (IecRuntime.hasSo('libgit.so')) {
      for (const name of ['git', 'git-upload-pack', 'git-receive-pack', 'git-upload-archive']) {
        add(name, 'libgit.so', 'iec_git_main');
      }
    }
    // git 的 https 传输是第二个程序（remote-curl），单独一个 so。
    if (IecRuntime.hasSo('libgit-remote-http.so')) {
      add('git-remote-http', 'libgit-remote-http.so', 'iec_git_remote_http_main');
      add('git-remote-https', 'libgit-remote-http.so', 'iec_git_remote_http_main');
    }
    // tar 优先 libarchive（能读 zip/更多压缩），没有就保留上面 toybox 的 tar。
    if (IecRuntime.hasSo('libbsdtar.so')) {
      add('tar', 'libbsdtar.so', 'iec_bsdtar_main');
      add('bsdtar', 'libbsdtar.so', 'iec_bsdtar_main');
    }
    if (IecRuntime.hasSo('libbsdunzip.so')) {
      add('unzip', 'libbsdunzip.so', 'iec_bsdunzip_main');
    }
    if (IecRuntime.hasSo('libbsdcpio.so')) {
      add('cpio', 'libbsdcpio.so', 'iec_bsdcpio_main');
      add('bsdcpio', 'libbsdcpio.so', 'iec_bsdcpio_main');
    }
    if (IecRuntime.hasSo('libzipcmd.so')) {
      add('zip', 'libzipcmd.so', 'iec_zip_main');
    }
    // 自己编的补充命令：nc / hexdump / diff（diff 后端是随包的 git）。
    if (IecRuntime.hasSo('libnc.so')) {
      add('nc', 'libnc.so', 'iec_nc_main');
    }
    if (IecRuntime.hasSo('libhexdump.so')) {
      add('hexdump', 'libhexdump.so', 'iec_hexdump_main');
      add('hd', 'libhexdump.so', 'iec_hexdump_main');
    }
    if (IecRuntime.hasSo('libdiff.so')) {
      add('diff', 'libdiff.so', 'iec_diff_main');
    }
    // jq 1.7.1 + 静态 oniguruma：JSON 处理。
    if (IecRuntime.hasSo('libjqcmd.so')) {
      add('jq', 'libjqcmd.so', 'iec_jq_main');
    }
    if (IecRuntime.hasSo('libnode.so')) {
      add('node', 'libnode.so', 'iec_node_main');
      add('nodejs', 'libnode.so', 'iec_node_main');
      add('npm', 'libnode.so', 'iec_npm_main');
      add('npx', 'libnode.so', 'iec_npx_main');
    }

    // Guncat 自带原生 CPython（libpython3.12.so，导出 Py_BytesMain）。把它接进
    // IEC 后，shell 里也能起同一个解释器 —— 这是"shell 与 Python 不再是两个世界"
    // 的落点。缺失时只是一条失败的命令，不影响其它 launcher。
    // shell 里的 python3 走 libpycmd.so 而不是直接指向 libpython3.12.so：命令是
    // fork 出来的，子进程会继承应用进程里已经初始化过的 CPython（run_python 的），
    // 直接再调 Py_BytesMain 会在 pyinit_core_reconfigure 崩溃。libpycmd 会先在
    // 子进程里 PyOS_AfterFork_Child + Py_FinalizeEx 把运行时归零，再正常初始化。
    if (IecRuntime.hasSo('libpycmd.so')) {
      add('python3', 'libpycmd.so', 'iec_python_main');
      add('python', 'libpycmd.so', 'iec_python_main');
    }

    hilog.info(DOMAIN, TAG, 'launchers written, failures=%{public}d', fails);
  }

  // 清空 launcher 目录。只删文件，不递归；这里的每一项都是 writeSoLauncher 写的。
  private static clearLaunchers(): void {
    try {
      const names: string[] = fileIo.listFileSync(BIN_DIR);
      for (const name of names) {
        try {
          fileIo.unlinkSync(BIN_DIR + name);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'cannot remove launcher %{public}s', name);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cannot list launchers: %{public}s', JSON.stringify(e));
    }
  }

  private static readonly APPLET_CACHE: string = SYSROOT + '/.toybox-applets';

  // 按 `toybox` 自己的输出注册 applet。缓存到资源根，重启后不再跑一次。
  private static async writeToyboxApplets(): Promise<void> {
    let names: string[] = IecRuntime.readAppletCache();
    if (names.length === 0) {
      names = await IecRuntime.listToyboxApplets();
      if (names.length > 0) {
        try {
          writeTxtFile(IecRuntime.APPLET_CACHE, names.join('\n'));
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'cannot cache applet list: %{public}s', JSON.stringify(e));
        }
      }
    }
    if (names.length === 0) {
      hilog.warn(DOMAIN, TAG, 'toybox applet list unavailable');
      return;
    }
    let wrote: number = 0;
    for (const name of names) {
      if (name === '' || name === 'toybox') {
        continue;
      }
      wrote += writeSoLauncher(BIN_DIR + name, BUNDLE_LIBS + 'libtoybox.so',
        'bsh_toybox_main', 2, 0);
    }
    hilog.info(DOMAIN, TAG, 'toybox applets: %{public}d registered', wrote);
  }

  private static readAppletCache(): string[] {
    try {
      if (!fileIo.accessSync(IecRuntime.APPLET_CACHE)) {
        return [];
      }
      const text: string = fileIo.readTextSync(IecRuntime.APPLET_CACHE);
      return text.split('\n')
        .map((s: string): string => s.trim())
        .filter((s: string): boolean => s !== '');
    } catch (e) {
      return [];
    }
  }

  // 跑一次 `toybox`（无参数会打印 applet 清单，多列排版）。
  private static async listToyboxApplets(): Promise<string[]> {
    let out: string = '';
    try {
      const handle = execStart({
        cmd: 'toybox',
        args: [],
        cwd: SYSROOT,
        env: { 'PATH': BIN_DIR },
        stdin: '',
        timeoutMs: 5000,
        maxOutputBytes: 512 * 1024
      });
      const id: number = handle.id;
      for (let i: number = 0; i < 500; i++) {
        const poll = execPoll(id, 64 * 1024, 64 * 1024);
        out += poll.out;
        if (poll.exited) {
          break;
        }
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 10);
        });
      }
      execRelease(id);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'list toybox applets failed: %{public}s', JSON.stringify(e));
      return [];
    }
    const cleaned: string = out.replace(/[\[\]]/g, ' ');
    const parts: string[] = cleaned.split(/\s+/);
    const names: string[] = [];
    for (const part of parts) {
      if (part.length > 0 && part.length < 32 && /^[a-z0-9_]+$/.test(part)) {
        names.push(part);
      }
    }
    return names;
  }

  private static readUidGid(): string[] {
    try {
      const text: string = fileIo.readTextSync('/proc/self/status');
      let uid: string = '';
      let gid: string = '';
      for (const line of text.split('\n')) {
        if (line.startsWith('Uid:')) {
          uid = line.substring(4).trim().split(/\s+/)[0];
        } else if (line.startsWith('Gid:')) {
          gid = line.substring(4).trim().split(/\s+/)[0];
        }
      }
      if (uid !== '' && gid !== '') {
        return [uid, gid];
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cannot read uid: %{public}s', JSON.stringify(e));
    }
    return [];
  }

  // 把 IEC 内置的 CA 证书铺到 <sysroot>/etc/ssl/certs，git/openssl 系工具就能
  // 按标准路径找到 CA，不依赖 Python 是否已经解包、也不用每次手写 GIT_SSL_CAINFO。
  static installShellCaBundle(): string {
    const dir: string = SYSROOT + '/etc/ssl/certs';
    const dst: string = dir + '/cacert.pem';
    try {
      ensureDir(dir);
      if (!installCaBundle(dir)) {
        return '';
      }
      return dst;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'ca bundle install failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  // bundle libs 里有没有这个 so。launcher 只在存在时写，避免"命令在、库不在"
  // 这种最误导人的失败形态。
  private static hasSo(name: string): boolean {
    try {
      return fileIo.accessSync(BUNDLE_LIBS + name);
    } catch (e) {
      return false;
    }
  }

  // 跑一条命令。返回的 out/err 是原始字节（UTF-8 解码由调用方决定）。
  static async run(context: common.UIAbilityContext, command: string,
    options: IecRunOptions): Promise<IecRunResult> {
    const startedAt: number = Date.now();
    let result: IecRunResult = {
      code: -1, out: '', err: '', timedOut: false, binary: false,
      outDropped: 0, errDropped: 0, elapsedMs: 0
    };

    const ready: string = await IecRuntime.ensure(context);
    if (ready !== '') {
      result.err = ready;
      return result;
    }

    await IecRuntime.acquireSlot();
    let handleId: number = -1;
    try {
      const handle = execStart({
        cmd: 'sh',
        args: ['-c', command],
        cwd: options.cwd,
        env: options.env,
        stdin: options.stdin,
        timeoutMs: options.timeoutMs,
        maxOutputBytes: options.maxOutputBytes
      });
      handleId = handle.id;

      const id: number = handleId;
      const deadline: number = Date.now() + options.timeoutMs + 5000;
      let exited: boolean = false;

      while (!exited) {
        const poll = execPoll(id, 64 * 1024, 64 * 1024);
        result.out += poll.out;
        result.err += poll.err;
        result.outDropped = poll.outDropped;
        result.errDropped = poll.errDropped;
        if (poll.exited) {
          result.code = poll.code;
          result.timedOut = poll.timedOut;
          exited = true;
          break;
        }
        if (Date.now() > deadline) {
          // 引擎自己的 timeoutMs 应该已经动手了；这里再兜一层，防止
          // "服务还活着但命令卡在不可中断的调用里"。
          execTerminate(id, 200);
          result.timedOut = true;
          result.code = -1;
          // 必须等它真的退出再 release：Release 对运行中的会话会拒绝，
          // 那一次拒绝就是一条泄漏的会话（4 个线程 + 输出缓冲）。
          const until: number = Date.now() + 3000;
          while (Date.now() < until) {
            const p = execPoll(id, 64 * 1024, 64 * 1024);
            result.out += p.out;
            result.err += p.err;
            if (p.exited) {
              result.code = p.code;
              break;
            }
            await new Promise<void>((resolve: () => void): void => {
              setTimeout(resolve, 20);
            });
          }
          exited = true;
          break;
        }
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 10);
        });
      }

      // 收尾：把退出瞬间还在管道里的字节读干净。
      for (let i: number = 0; i < 20; i++) {
        const tail = execPoll(id, 64 * 1024, 64 * 1024);
        if (tail.out === '' && tail.err === '') {
          break;
        }
        result.out += tail.out;
        result.err += tail.err;
      }
    } catch (e) {
      result.err = IecRuntime.describeFailure(e);
      hilog.error(DOMAIN, TAG, 'exec failed: %{public}s', result.err);
    } finally {
      if (handleId >= 0) {
        try {
          execRelease(handleId);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'release %{public}d failed: %{public}s',
            handleId, JSON.stringify(e));
        }
      }
      IecRuntime.releaseSlot();
    }

    // 非 UTF-8 字节在解码时变成 U+FFFD。这里把"输出已损坏"变成显式标记，
    // 而不是让调用方把乱码当内容用（二进制请重定向到文件，或用 base64）。
    result.binary = result.out.indexOf('\uFFFD') !== -1 || result.err.indexOf('\uFFFD') !== -1;
    result.elapsedMs = Date.now() - startedAt;
    return result;
  }

  // 资源根 / 命令目录：给需要拼 PATH 的调用方（IecShellService）用。
  static sysroot(): string {
    return SYSROOT;
  }

  static binDir(): string {
    return BIN_DIR;
  }

  // execStart 抛出来的错误在 ArkTS 里是 Error；缺命令 so 时的原始信息是
  // "cannot start /data/.../bin/sh"，对使用者没有指导意义，这里翻译一下。
  private static describeFailure(e: Object): string {
    let text: string = e instanceof Error ? (e as Error).message : JSON.stringify(e);
    if (text.indexOf('cannot start') !== -1) {
      return '运行核无法启动命令：' + text + '\n' +
        'libmksh.so / libtoybox.so 应随 HAR 打进 libs/arm64-v8a/；' +
        '若缺，按 docs/architecture/iec-runtime.md 重新构建。';
    }
    return '命令启动失败: ' + text;
  }

  // 给状态面板/排障用：当前设备类型与是否已就绪。
  static status(): string {
    return 'iec=' + (IecRuntime.started ? 'ready' : 'not-started') +
      ' device=' + deviceInfo.deviceType;
  }
}
