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
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ensureDir,
  execPoll,
  execRelease,
  execStart,
  execTerminate,
  initIecResourceManager,
  probeCaps,
  startIecServer,
  writeSoLauncher
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
  outDropped: number;
  errDropped: number;
  elapsedMs: number;
}

export class IecRuntime {
  private static started: boolean = false;
  private static startError: string = '';

  // 启动 exec/tty 服务并铺好 launcher。返回空串表示可用，否则是原因。
  static ensure(context: common.UIAbilityContext): string {
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

    let fails: number = 0;
    const add = (name: string, so: string, entry: string): void => {
      // primary=0 交给 IEC 按设备能力选 fork / native child process；写死 fork 会在
      // 没有 fork 的渠道上整片失效。
      fails += writeSoLauncher(BIN_DIR + name, BUNDLE_LIBS + so, entry, 2, 0);
    };

    const toybox: string[] = [
      'ls', 'cat', 'echo', 'grep', 'egrep', 'fgrep', 'sed', 'awk', 'cp', 'mv',
      'rm', 'mkdir', 'rmdir', 'touch', 'ln', 'chmod', 'chown', 'head', 'tail',
      'wc', 'sort', 'uniq', 'tr', 'cut', 'tee', 'xargs', 'find', 'which',
      'env', 'printenv', 'pwd', 'true', 'false', 'yes', 'sleep', 'date',
      'uname', 'id', 'whoami', 'ps', 'kill', 'free', 'df', 'du', 'clear',
      'reset', 'stty', 'readlink', 'dirname', 'basename', 'realpath', 'printf',
      'timeout', 'mount', 'umount', 'gzip', 'gunzip', 'zcat', 'wget', 'ping',
      'netstat', 'ifconfig', 'toybox'
    ];
    for (const name of toybox) {
      add(name, 'libtoybox.so', 'bsh_toybox_main');
    }

    // sh 是 shell 工具的唯一入口：没有它，IecShellService 直接报"运行核未就绪"。
    add('sh', 'libmksh.so', 'main');
    add('mksh', 'libmksh.so', 'main');

    for (const name of ['ssh', 'dbclient', 'scp', 'ssh-keygen', 'dropbearkey',
      'dropbearconvert', 'dropbear']) {
      add(name, 'libdropbear.so', 'iec_dropbear_main');
    }
    for (const name of ['git', 'git-upload-pack', 'git-receive-pack', 'git-upload-archive']) {
      add(name, 'libgit.so', 'iec_git_main');
    }
    add('tar', 'libbsdtar.so', 'iec_bsdtar_main');
    add('bsdtar', 'libbsdtar.so', 'iec_bsdtar_main');
    add('unzip', 'libbsdunzip.so', 'iec_bsdunzip_main');
    add('zip', 'libzipcmd.so', 'iec_zip_main');
    add('node', 'libnode.so', 'iec_node_main');
    add('npm', 'libnode.so', 'iec_npm_main');

    // Guncat 自带原生 CPython（libpython3.12.so，导出 Py_BytesMain）。把它接进
    // IEC 后，shell 里也能起同一个解释器 —— 这是"shell 与 Python 不再是两个世界"
    // 的落点。缺失时只是一条失败的命令，不影响其它 launcher。
    add('python3', 'libpython3.12.so', 'Py_BytesMain');
    add('python', 'libpython3.12.so', 'Py_BytesMain');

    hilog.info(DOMAIN, TAG, 'launchers written, failures=%{public}d', fails);
  }

  // 跑一条命令。返回的 out/err 是原始字节（UTF-8 解码由调用方决定）。
  static async run(context: common.UIAbilityContext, command: string,
    options: IecRunOptions): Promise<IecRunResult> {
    const startedAt: number = Date.now();
    let result: IecRunResult = {
      code: -1, out: '', err: '', timedOut: false,
      outDropped: 0, errDropped: 0, elapsedMs: 0
    };

    const ready: string = IecRuntime.ensure(context);
    if (ready !== '') {
      result.err = ready;
      return result;
    }

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
          exited = true;
          result.code = -1;
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
      execRelease(id);
    } catch (e) {
      result.err = IecRuntime.describeFailure(e);
      hilog.error(DOMAIN, TAG, 'exec failed: %{public}s', result.err);
    }

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
