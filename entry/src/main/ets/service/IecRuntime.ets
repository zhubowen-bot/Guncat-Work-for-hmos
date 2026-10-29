// IecRuntime: 设备内原生执行核（IEC）的接入层。
//
// 为什么有它：
//   * Guncat 早期的 shell 工具跑在应用进程内的虚拟机里，
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
import { util } from '@kit.ArkTS';
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
  unpackResource,
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

// `toybox` 无参输出的解析结果。complete=false 表示进程没正常退出（超时/被杀）、
// 或输出可能在退出瞬间被截断，这份清单不能写进缓存长期沿用。
interface IecToyboxApplets {
  names: string[];
  complete: boolean;
}

export class IecRuntime {
  private static started: boolean = false;
  private static startError: string = '';
  // 首调单飞：ensure() 内部有 await（toybox applet 枚举），只用 started 标记挡不住
  // 并发首调 —— 两条命令同时进来会各自清空/重写 launcher、各自调 execKillStale、
  // 各自把 npm.tar.gz 解到同一个目录。这里缓存的是同一个 Promise，后来者只等待。
  private static ensureTask: Promise<string> | undefined = undefined;

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
    // 等待者不在被唤醒后自增：槽位由 releaseSlot() 直接转交。否则 release 先
    // activeRuns-- 再唤醒等待者，中间的空档会被新调用者抢走，上限实际变成 9 条。
    await new Promise<void>((resolve: () => void): void => {
      IecRuntime.waiters.push(resolve);
    });
  }

  private static releaseSlot(): void {
    const next: (() => void) | undefined = IecRuntime.waiters.shift();
    if (next !== undefined) {
      // 槽位原样交给队首，activeRuns 不变。
      next();
      return;
    }
    IecRuntime.activeRuns--;
  }

  // 启动 exec/tty 服务并铺好 launcher。返回空串表示可用，否则是原因。
  static ensure(context: common.UIAbilityContext): Promise<string> {
    if (IecRuntime.started) {
      return Promise.resolve('');
    }
    if (IecRuntime.startError !== '') {
      return Promise.resolve(IecRuntime.startError);
    }
    if (IecRuntime.ensureTask === undefined) {
      IecRuntime.ensureTask = IecRuntime.doEnsure(context);
    }
    return IecRuntime.ensureTask;
  }

  private static async doEnsure(context: common.UIAbilityContext): Promise<string> {
    try {
      initIecResourceManager(context.resourceManager);

      // 能力字由 native 侧探（fork / exec / jit / path）。不 pin：探针就是为
      // "不同设备/不同渠道能力不同"设计的，pin 死一个值等于把设备差异藏起来。
      const caps = probeCaps();
      hilog.info(DOMAIN, TAG,
        'caps packed=0x%{public}s chmod=%{public}d fork=%{public}d exec=%{public}d jit=%{public}d path=%{public}d',
        caps.packed.toString(16), caps.chmod, caps.fork, caps.exec, caps.jit, caps.path);

      const launcherErr: string = IecRuntime.writeLaunchers();
      if (launcherErr !== '') {
        IecRuntime.startError = launcherErr;
        return IecRuntime.startError;
      }

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

      // npm 是纯 JS 树（node 源码里的 deps/npm），随包成 rawfile/tools/npm.tar.gz，
      // 首次启动解到 <sysroot>/npm —— iec_npm_main 拼的命令行就是
      // <sysroot>/npm/bin/npm-cli.js。解包靠 libarchive（HAR 里的 libarchive.so.13）。
      IecRuntime.unpackNpm();

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
  //
  // 返回空串表示最小可用集（toybox + sh/mksh）都写成功了；否则是失败原因。
  // 只检查这三个：缺一个可选命令是 "command not found" 的正常降级，缺 shell
  // 本体却继续启动，只会让之后每条命令都报一个看不出根因的 "cannot start"。
  private static writeLaunchers(): string {
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
    let essentialFails: number = 0;
    const add = (name: string, so: string, entry: string): void => {
      // primary=0 交给 IEC 按设备能力选 fork / native child process；写死 fork 会在
      // 没有 fork 的渠道上整片失效。
      fails += writeSoLauncher(BIN_DIR + name, BUNDLE_LIBS + so, entry, 2, 0);
    };

    // toybox 本体的 launcher；具体 applet 在服务起来后按 `toybox` 的输出枚举。
    essentialFails += writeSoLauncher(BIN_DIR + 'toybox', BUNDLE_LIBS + 'libtoybox.so',
      'bsh_toybox_main', 2, 0);

    // sh 是 shell 工具的唯一入口：没有它，IecShellService 直接报"运行核未就绪"。
    essentialFails += writeSoLauncher(BIN_DIR + 'sh', BUNDLE_LIBS + 'libmksh.so', 'main', 2, 0);
    essentialFails += writeSoLauncher(BIN_DIR + 'mksh', BUNDLE_LIBS + 'libmksh.so', 'main', 2, 0);

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
    // curl 8.22.0 + 静态 OpenSSL/zlib：命令行下载。CA 走 IecShellService 注入的
    // CURL_CA_BUNDLE / SSL_CERT_FILE。
    if (IecRuntime.hasSo('libcurlcmd.so')) {
      add('curl', 'libcurlcmd.so', 'iec_curl_main');
    }
    // GNU bc 1.07.1（--with-readline 未启用）：任意精度计算。
    if (IecRuntime.hasSo('libbccmd.so')) {
      add('bc', 'libbccmd.so', 'iec_bc_main');
    }
    // OpenSSH 9.9p2 的 sftp 客户端（静态 OpenSSL/zlib）。
    if (IecRuntime.hasSo('libsftpcmd.so')) {
      add('sftp', 'libsftpcmd.so', 'iec_sftp_main');
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
    if (essentialFails > 0) {
      return 'IEC launcher 写入失败（toybox/sh/mksh 共 ' + essentialFails.toString() +
        ' 个），检查 ' + BIN_DIR + ' 是否可写';
    }
    return '';
  }

  // 解 npm 的 JS 树。只在 libnode 随包、且目标还不存在时做：npm-cli.js 已经在了
  // 就跳过，避免每次冷启动都重解 2.6MB 的 tar.gz。
  private static unpackNpm(): void {
    if (!IecRuntime.hasSo('libnode.so')) {
      return;
    }
    const cli: string = SYSROOT + '/npm/bin/npm-cli.js';
    try {
      if (fileIo.accessSync(cli)) {
        return;
      }
    } catch (e) {
      // accessSync 在文件不存在时抛异常，等同于"还没有"，继续解包。
    }
    try {
      const rc: number = unpackResource('tools/npm.tar.gz', SYSROOT);
      if (rc !== 0) {
        hilog.warn(DOMAIN, TAG, 'unpack npm.tar.gz failed: rc=%{public}d', rc);
        IecRuntime.dropIncompleteNpm(cli);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'unpack npm.tar.gz failed: %{public}s', JSON.stringify(e));
      IecRuntime.dropIncompleteNpm(cli);
    }
  }

  // 解包失败时删掉入口文件，让下次启动重试。tar 里的顺序不保证 npm-cli.js 最后，
  // 半棵树里只要有它，"cli 存在就跳过"的判断就会永远认为已安装，npm 却缺文件。
  private static dropIncompleteNpm(cli: string): void {
    try {
      if (fileIo.accessSync(cli)) {
        fileIo.unlinkSync(cli);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cannot remove partial npm entry: %{public}s', JSON.stringify(e));
    }
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

  // 缓存头里带上 libtoybox.so 的 size+mtime。升级替换 toybox 之后，旧缓存里的
  // applet 清单会被当成新库的回答，新增的 applet 永远注册不上（不删缓存就一直缺）。
  private static appletCacheHeader(): string {
    try {
      const st = fileIo.statSync(BUNDLE_LIBS + 'libtoybox.so');
      return '#toybox ' + st.size.toString() + ' ' + Math.floor(st.mtime).toString();
    } catch (e) {
      return '#toybox unknown';
    }
  }

  // 按 `toybox` 自己的输出注册 applet。缓存到资源根，重启后不再跑一次。
  private static async writeToyboxApplets(): Promise<void> {
    const header: string = IecRuntime.appletCacheHeader();
    let names: string[] = IecRuntime.readAppletCache(header);
    if (names.length === 0) {
      const listed: IecToyboxApplets = await IecRuntime.listToyboxApplets();
      names = listed.names;
      // 只缓存**完整**的清单：把超时/半截输出写进缓存，之后每次启动都会沿用
      // 这份残缺清单，缺掉的命令看起来就像 toybox 没编进去。
      if (names.length > 0 && listed.complete) {
        try {
          writeTxtFile(IecRuntime.APPLET_CACHE, header + '\n' + names.join('\n'));
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

  private static readAppletCache(header: string): string[] {
    try {
      if (!fileIo.accessSync(IecRuntime.APPLET_CACHE)) {
        return [];
      }
      const lines: string[] = fileIo.readTextSync(IecRuntime.APPLET_CACHE).split('\n');
      if (lines.length === 0 || lines[0].trim() !== header) {
        return [];
      }
      return lines.slice(1)
        .map((s: string): string => s.trim())
        .filter((s: string): boolean => s !== '');
    } catch (e) {
      return [];
    }
  }

  // 跑一次 `toybox`（无参数会打印 applet 清单，多列排版）。
  //
  // complete 表示拿到的是不是完整清单：引擎在**直接子进程**退出时就置 exited，
  // 此时两条管道的读取线程可能还没把最后一批字节交出来；只凭一次 poll 就
  // 返回会把清单截断。这里等到两条管道 EOF（最多 1s，兼顾 continue 后台进程
  // 占着管道的场景）再解析，并且只有正常退出（code 0）才算完整。
  private static async listToyboxApplets(): Promise<IecToyboxApplets> {
    let out: string = '';
    let id: number = -1;
    let exited: boolean = false;
    let code: number = -1;
    // 只有真正读到两条管道 EOF 才算"清单完整"：exited 只说明直接子进程结束，
    // 而 EOF 要到读线程把管道搬空才会置位；没有它，1s 等不到 EOF 时会缓存一份
    // 可能被截断的清单。
    let sawEof: boolean = false;
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
      id = handle.id;
      // 引擎 5s 超时之外再留 3s 余量；到点仍未退出就主动终止，交给
      // releaseSession 回收，绝不把运行中的会话直接 Release。
      const deadline: number = Date.now() + 8000;
      while (Date.now() < deadline) {
        const poll = execPoll(id, 64 * 1024, 64 * 1024);
        out += poll.out;
        if (poll.exited) {
          exited = true;
          code = poll.code;
          break;
        }
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 10);
        });
      }
      if (exited) {
        const eofDeadline: number = Date.now() + 1000;
        while (Date.now() < eofDeadline) {
          const tail = execPoll(id, 64 * 1024, 64 * 1024);
          out += tail.out;
          // 同样要"EOF 且本次没数据"：先见到 EOF 就退出会把缓冲里的清单尾部丢掉。
          if (tail.outEof && tail.errEof && tail.out === '' && tail.err === '') {
            sawEof = true;
            break;
          }
          await new Promise<void>((resolve: () => void): void => {
            setTimeout(resolve, 10);
          });
        }
      } else {
        hilog.warn(DOMAIN, TAG, 'toybox applet probe did not exit in time; terminating');
        try {
          execTerminate(id, 0);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'terminate toybox probe failed: %{public}s', JSON.stringify(e));
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'list toybox applets failed: %{public}s', JSON.stringify(e));
      return { names: [], complete: false };
    } finally {
      if (id >= 0) {
        IecRuntime.releaseSession(id);
      }
    }
    if (!exited || code !== 0) {
      hilog.warn(DOMAIN, TAG, 'toybox applet probe ended abnormally: exited=%{public}d code=%{public}d',
        exited ? 1 : 0, code);
    }
    const cleaned: string = out.replace(/[\[\]]/g, ' ');
    const parts: string[] = cleaned.split(/\s+/);
    const names: string[] = [];
    for (const part of parts) {
      if (part.length > 0 && part.length < 32 && /^[a-z0-9_]+$/.test(part)) {
        names.push(part);
      }
    }
    return { names: names, complete: exited && code === 0 && sawEof };
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
  // 每条命令都会问一次，所以成功结果缓存下来：installCaBundle() 每次都会重写
  // 整份证书，放在这么热的路径上没有必要。
  private static caPath: string = '';

  static installShellCaBundle(): string {
    if (IecRuntime.caPath !== '') {
      return IecRuntime.caPath;
    }
    const dir: string = SYSROOT + '/etc/ssl/certs';
    const dst: string = dir + '/cacert.pem';
    try {
      ensureDir(dir);
      if (!installCaBundle(dir)) {
        return '';
      }
      IecRuntime.caPath = dst;
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

  // 跑一条命令。out/err 是整条流按 UTF-8 解码一次后的文本。
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
      result.elapsedMs = Date.now() - startedAt;
      return result;
    }

    await IecRuntime.acquireSlot();
    const outChunks: Uint8Array[] = [];
    const errChunks: Uint8Array[] = [];
    let handleId: number = -1;
    let code: number = -1;
    let timedOut: boolean = false;
    let outDropped: number = 0;
    let errDropped: number = 0;
    let failure: string = '';
    let graceful: boolean = false;
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
      while (true) {
        const poll = execPoll(id, 64 * 1024, 64 * 1024, 'base64');
        IecRuntime.collect(outChunks, poll.out);
        IecRuntime.collect(errChunks, poll.err);
        outDropped = poll.outDropped;
        errDropped = poll.errDropped;
        if (poll.exited) {
          code = poll.code;
          timedOut = poll.timedOut;
          graceful = true;
          break;
        }
        if (Date.now() > deadline) {
          // 引擎自己的 timeoutMs 应该已经动手了；这里再兜一层，防止
          // "服务还活着但命令卡在不可中断的调用里"。不再阻塞等 3 秒：
          // Release 拒绝运行中的会话，等不到就放弃 = 每次卡死漏一条会话
          // （4 个线程 + 输出缓冲）。立刻按 job 发 SIGKILL，回收交给
          // releaseSession() 在后台重试。
          try {
            execTerminate(id, 0);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'terminate %{public}d failed: %{public}s',
              id, JSON.stringify(e));
          }
          timedOut = true;
          code = -1;
          break;
        }
        await IecRuntime.sleep(10);
      }

      // 子进程退出不等于管道读干净了：把退出瞬间还在管道里的字节收完。
      if (graceful && failure === '') {
        await IecRuntime.drainToEof(id, outChunks, errChunks, 1000);
      }
    } catch (e) {
      failure = IecRuntime.describeFailure(e);
      hilog.error(DOMAIN, TAG, 'exec failed: %{public}s', failure);
    } finally {
      if (handleId >= 0) {
        IecRuntime.releaseSession(handleId);
      }
      IecRuntime.releaseSlot();
    }

    result.code = code;
    result.timedOut = timedOut;
    result.outDropped = outDropped;
    result.errDropped = errDropped;
    result.out = IecRuntime.decodeChunks(outChunks);
    result.err = IecRuntime.decodeChunks(errChunks);
    if (failure !== '') {
      result.err = result.err === '' ? failure : result.err + '\n' + failure;
    }
    // 非 UTF-8 字节在解码时变成 U+FFFD。这里把"输出已损坏"变成显式标记，
    // 而不是让调用方把乱码当内容用（二进制请重定向到文件，或用 base64）。
    result.binary = result.out.indexOf('\uFFFD') !== -1 || result.err.indexOf('\uFFFD') !== -1;
    result.elapsedMs = Date.now() - startedAt;
    return result;
  }

  // 收一次 poll 的字节块。走 base64 而不是让 NAPI 直接把每个 64KB 块解成
  // UTF-8：块边界落在多字节字符中间时两边都会变成 U+FFFD，超过 64KB 的中文
  // 输出会被误判成"二进制"，而且落盘内容也坏了。整条流只在最后解码一次。
  private static collect(chunks: Uint8Array[], encoded: string): void {
    if (encoded === '') {
      return;
    }
    chunks.push(new util.Base64Helper().decodeSync(encoded));
  }

  private static decodeChunks(chunks: Uint8Array[]): string {
    if (chunks.length === 0) {
      return '';
    }
    let total: number = 0;
    for (const chunk of chunks) {
      total += chunk.byteLength;
    }
    const merged: Uint8Array = new Uint8Array(total);
    let off: number = 0;
    for (const chunk of chunks) {
      merged.set(chunk, off);
      off += chunk.byteLength;
    }
    return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(merged);
  }

  // 等到两条管道都 EOF **且会话缓冲取空**。execPoll().exited 只表示**直接
  // 子进程**结束了，管道读线程可能还没交出最后一批字节；只看一次 poll 是否
  // 为空会丢掉输出尾部。
  //
  // 注意 EOF 的语义：读线程把管道的字节整段搬进会话缓冲后立刻置 outEof/errEof，
  // 所以 EOF 只说明"不会再有新字节"，**不代表缓冲已经空了**。退出瞬间缓冲里
  // 可能还压着几 MB（上限 8MB），每次 poll 只取 64KB：若一见到 EOF 就返回，
  // 只能多取一块，其余全部随 release 丢掉。必须"EOF 且本次没取到字节"才算
  // 收完；有字节时连续取（每约 1MB 让出一次事件循环），不再每轮 sleep(10)，
  // 否则 1s 上限内只能搬约 6.4MB。
  // 后台进程继承着管道时 EOF 可能一直不来，所以仍有 waitMs 上限。
  private static async drainToEof(id: number, outChunks: Uint8Array[],
    errChunks: Uint8Array[], waitMs: number): Promise<void> {
    const until: number = Date.now() + waitMs;
    let polls: number = 0;
    while (Date.now() < until) {
      const poll = execPoll(id, 64 * 1024, 64 * 1024, 'base64');
      const gotData: boolean = poll.out !== '' || poll.err !== '';
      IecRuntime.collect(outChunks, poll.out);
      IecRuntime.collect(errChunks, poll.err);
      if (poll.outEof && poll.errEof && !gotData) {
        return;
      }
      polls++;
      if (!gotData) {
        await IecRuntime.sleep(10);
      } else if (polls % 16 === 0) {
        // 有数据就连续取，但不能一直不让出事件循环：命令留下的后台进程持续
        // 输出时，这个循环会整整忙 waitMs（1s），把 JS 线程占住。每 16 块
        // （约 1MB）让一次。
        await IecRuntime.sleep(0);
      }
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  // 释放会话。Release 对运行中的会话会拒绝；拒绝后如果直接放弃，会话的
  // 4 个线程与输出缓冲会永久留下（每次超时/异常漏一条）。先按 job 发
  // SIGKILL，再在后台重试 Release，直到引擎确认会话结束。
  private static releaseSession(id: number): void {
    try {
      if (execRelease(id)) {
        return;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'release %{public}d failed: %{public}s',
        id, JSON.stringify(e));
      return;
    }
    try {
      execTerminate(id, 0);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'terminate %{public}d failed: %{public}s',
        id, JSON.stringify(e));
    }
    IecRuntime.retryRelease(id, 1);
  }

  private static retryRelease(id: number, attempt: number): void {
    if (attempt > 30) {
      hilog.warn(DOMAIN, TAG, 'session %{public}d still running after release retries', id);
      return;
    }
    setTimeout((): void => {
      let released: boolean = false;
      try {
        released = execRelease(id);
      } catch (e) {
        released = false;
      }
      if (released) {
        return;
      }
      try {
        execTerminate(id, 0);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'terminate %{public}d failed: %{public}s',
          id, JSON.stringify(e));
      }
      IecRuntime.retryRelease(id, attempt + 1);
    }, 500);
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
