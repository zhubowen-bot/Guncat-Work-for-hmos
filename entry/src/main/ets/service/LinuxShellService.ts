// LinuxShellService: shell 工具的 Linux 后端(真 Linux, QEMU TCI 解释执行, 无 JIT)
//
// 为什么是这个形状:
//   * 手机拿不到 JIT 所需的受限权限, 所以 QEMU 用 --enable-tcg-interpreter(TCI) 构建,
//     纯字节码解释执行, 不需要可执行内存。
//   * QEMU 与应用同进程(libguncatvm.so dlopen libqemu-system-aarch64-tci.so),
//     不需要 fork/exec, 也就没有额外的系统权限要求。
//   * **工作区一致性**: 宿主把 filesDir/workspaces(所有会话的工作区)用 virtio-9p 注入 VM,
//     客人在执行每条命令前把 /workspace bind-mount 到 /mnt/workspaces/<会话 id> ——
//     也就是 read_file / write_file / edit 操作的那个目录本身(同一批 inode, 不是副本)。
//   * **命令通道也走 9p**: 任务写在 filesDir/linux/ipc/<会话>/in/<id>/, 客人的守护进程
//     (tooling/linux-vm/guest/guncat-agent) 执行后把 stdout/stderr/退出码写回 out/<id>/。
//     串口只用来取内核引导日志排障, 不参与命令协议 —— 没有终端转义/回显解析这类脆弱环节。
import { common } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  isAvailable as vmIsAvailable,
  serialTail as vmSerialTail,
  startVM as vmStart,
  status as vmStatus,
  VmStartResult,
  VmStatus
} from 'libguncatvm.so';
import { Constants } from '../common/Constants';
import { ToolExecResult, WorkFileService } from './WorkFileService';

const DOMAIN: number = 0x0000;
const TAG: string = 'LinuxShell';

// 一次客人侧执行的结果
class GuestRun {
  ok: boolean = false;
  jobId: string = '';
  stdout: string = '';
  stderr: string = '';
  code: number = 0;
  timedOut: boolean = false;
  error: string = '';
  durationMs: number = 0;
  bootMs: number = 0;
  cwdLabel: string = '';
  stdoutSpill: string = '';
  stderrSpill: string = '';
  stdoutBytes: number = 0;
  stderrBytes: number = 0;
}

export class LinuxShellService {
  static readonly TOOL_NAME: string = Constants.WORK_SHELL_TOOL_NAME;

  // 全进程只有一台 VM: 会话切换只换 bind mount 目标, 不重启虚拟机
  private static bootPromise: Promise<string> | null = null;
  private static bootedAt: number = 0;
  // 命令串行执行: TCI 是单核解释, 并发只会互相拖慢, 而且 /workspace 的 bind 目标是全局状态
  private static chain: Promise<void> = Promise.resolve();
  private static jobSeq: number = 0;
  private static idleTimer: number = -1;
  private static lastActivityAt: number = 0;

  // ===== 对外入口 =====

  static async run(context: common.UIAbilityContext, convId: string,
    args: Record<string, Object>): Promise<ToolExecResult> {
    let command: string = LinuxShellService.strArg(args, 'command', '');
    if (command.trim() === '') {
      return LinuxShellService.fail('缺少参数 command(要执行的 shell 命令)');
    }
    let cmdBytes: number = new util.TextEncoder().encodeInto(command).length;
    if (cmdBytes > Constants.WORK_SHELL_MAX_COMMAND_BYTES) {
      return LinuxShellService.fail('命令过长(' + WorkFileService.formatSize(cmdBytes) + '), 上限 ' +
        WorkFileService.formatSize(Constants.WORK_SHELL_MAX_COMMAND_BYTES) + '; 长脚本请先 write_file 再用 shell 执行');
    }

    let cwdRel: string = LinuxShellService.strArg(args, 'cwd', '').trim();
    if (cwdRel !== '' && !LinuxShellService.isSafeRel(cwdRel)) {
      return LinuxShellService.fail('cwd 必须是工作区内的相对路径(不能以 / 开头, 不能含 ..)');
    }
    let stdin: string = LinuxShellService.strArg(args, 'stdin', '');
    if (stdin !== '' && new util.TextEncoder().encodeInto(stdin).length > Constants.WORK_SHELL_MAX_STDIN_BYTES) {
      return LinuxShellService.fail('stdin 过长, 上限 ' +
        WorkFileService.formatSize(Constants.WORK_SHELL_MAX_STDIN_BYTES));
    }
    let timeoutMs: number = LinuxShellService.intArg(args, 'timeout_ms', Constants.WORK_SHELL_DEFAULT_TIMEOUT_MS);
    if (timeoutMs < 1000) {
      timeoutMs = 1000;
    }
    if (timeoutMs > Constants.WORK_SHELL_MAX_TIMEOUT_MS) {
      timeoutMs = Constants.WORK_SHELL_MAX_TIMEOUT_MS;
    }

    // 串行化: 排队等前一条命令执行完(含首次引导)
    let previous: Promise<void> = LinuxShellService.chain;
    let release: () => void = (): void => {};
    LinuxShellService.chain = new Promise<void>((resolve: () => void): void => {
      release = resolve;
    });
    await previous;
    try {
      return await LinuxShellService.runExclusive(context, convId, command, cwdRel, timeoutMs, stdin);
    } finally {
      release();
      LinuxShellService.scheduleIdleShutdown(context);
    }
  }

  // 把一条命令送进客人系统执行(调用方已持有串行锁)
  private static async runExclusive(context: common.UIAbilityContext, convId: string,
    command: string, cwdRel: string, timeoutMs: number, stdin: string): Promise<ToolExecResult> {
    let bootStart: number = Date.now();
    let bootErr: string = await LinuxShellService.ensureBoot(context);
    if (bootErr !== '') {
      return LinuxShellService.fail(bootErr);
    }
    let bootMs: number = Date.now() - bootStart;

    let conv: string = LinuxShellService.sanitizeConv(convId);
    let jobId: string = LinuxShellService.nextJobId();
    let ipcConv: string = LinuxShellService.ipcRoot(context) + '/' + conv;
    let reqDir: string = ipcConv + '/in/' + jobId;
    let outDir: string = ipcConv + '/out/' + jobId;
    try {
      WorkFileService.ensureDir(ipcConv + '/in');
      WorkFileService.ensureDir(ipcConv + '/out');
      WorkFileService.ensureDir(reqDir);
      LinuxShellService.writeText(reqDir + '/cmd', command);
      if (cwdRel !== '') {
        LinuxShellService.writeText(reqDir + '/cwd', cwdRel);
      }
      LinuxShellService.writeText(reqDir + '/timeout', Math.ceil(timeoutMs / 1000).toString());
      if (stdin !== '') {
        LinuxShellService.writeText(reqDir + '/stdin', stdin);
      }
      // ready 必须最后写: 它一出现客人就开始执行
      LinuxShellService.writeText(reqDir + '/ready', '1');
    } catch (e) {
      return LinuxShellService.fail('无法写入命令通道: ' + LinuxShellService.errText(e));
    }

    let run: GuestRun = await LinuxShellService.waitGuest(context, conv, jobId, outDir, timeoutMs);
    run.jobId = jobId;
    run.bootMs = bootMs;
    run.cwdLabel = cwdRel === '' ? '/' : '/' + cwdRel;
    if (run.ok) {
      // 大输出落盘必须在清理任务目录之前做(否则完整内容就没了)
      LinuxShellService.materializeOutputs(context, convId, outDir, jobId, run);
    }
    LinuxShellService.cleanupJob(reqDir, outDir);
    if (!run.ok) {
      return LinuxShellService.fail(run.error);
    }
    return LinuxShellService.formatResult(run);
  }

  // ===== 引导 =====

  // 返回空串表示 VM 可用(已就绪), 否则为不可用原因
  private static async ensureBoot(context: common.UIAbilityContext): Promise<string> {
    if (LinuxShellService.bootPromise !== null) {
      return await LinuxShellService.bootPromise;
    }
    LinuxShellService.bootPromise = LinuxShellService.bootOnce(context);
    let err: string = await LinuxShellService.bootPromise;
    if (err !== '') {
      // 失败不缓存, 下次调用可以重试(例如用户刚才清理了空间)
      LinuxShellService.bootPromise = null;
    }
    return err;
  }

  private static async bootOnce(context: common.UIAbilityContext): Promise<string> {
    let availability: string = vmIsAvailable();
    if (availability !== '') {
      return '本机无法运行 Linux VM: ' + availability +
        '\n(shell 工具需要 arm64-v8a 的 libqemu-system-aarch64-tci.so, 见 tooling/linux-vm/README.md)';
    }

    let readyMarker: string = LinuxShellService.ipcRoot(context) + '/.ready';
    // 上一次进程留下的标记必须清掉, 否则会误判为已引导
    LinuxShellService.removeIfExists(readyMarker);

    let current: VmStatus = vmStatus();
    if (current.running && LinuxShellService.exists(readyMarker)) {
      // QEMU 还在跑且客人已有就绪标记(同进程复用): 直接用
      return '';
    }
    if (current.running) {
      // 还在跑但标记不在: 可能是刚下发过空闲关机。先给它一个短窗口等标记;
      // 若 VM 在这期间退出, 就继续往下走重新引导, 而不是把超时当成错误抛给模型。
      LinuxShellService.removeIfExists(readyMarker);
      let ready: string = await LinuxShellService.waitReady(context, readyMarker, 8000);
      if (ready === '') {
        return '';
      }
      if (vmStatus().running) {
        return ready;
      }
    }

    let imgErr: string = LinuxShellService.ensureImages(context);
    if (imgErr !== '') {
      return imgErr;
    }
    // 新一次引导: 清掉上一次(可能因崩溃/超时)残留的任务目录, 避免客人开机后重放旧命令
    LinuxShellService.removeTree(LinuxShellService.ipcRoot(context));
    WorkFileService.ensureDir(LinuxShellService.ipcRoot(context));

    let serialSocket: string = context.tempDir + '/guncat-qemu-serial.sock';
    LinuxShellService.removeIfExists(serialSocket);

    let argsLines: string = LinuxShellService.buildQemuArgs(context, serialSocket).join('\n');
    let started: VmStartResult = vmStart({ argsLines: argsLines, serialSocket: serialSocket });
    if (!started.ok) {
      return 'Linux VM 启动失败: ' + started.error;
    }
    hilog.info(DOMAIN, TAG, 'qemu started with %{public}s', started.lib);

    let readyErr: string = await LinuxShellService.waitReady(context, readyMarker,
      Constants.WORK_LINUX_BOOT_TIMEOUT_MS);
    if (readyErr !== '') {
      return readyErr + '\n\n—— 串口日志尾部 ——\n' + vmSerialTail(2500);
    }
    LinuxShellService.bootedAt = Date.now();
    LinuxShellService.lastActivityAt = LinuxShellService.bootedAt;
    hilog.info(DOMAIN, TAG, 'guest ready in %{public}d ms', LinuxShellService.bootedAt);
    return '';
  }

  // 等客人写就绪标记(客人挂载完 9p 之后才会写)
  private static async waitReady(context: common.UIAbilityContext, marker: string,
    timeoutMs: number): Promise<string> {
    let deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (LinuxShellService.exists(marker)) {
        return '';
      }
      let st: VmStatus = vmStatus();
      if (!st.running) {
        return 'Linux VM 在引导完成前退出了(exit=' + st.exitCode.toString() + ')' +
          '\n\n—— 串口日志尾部 ——\n' + vmSerialTail(3000);
      }
      await LinuxShellService.sleep(150);
    }
    return 'Linux VM 引导超时(' + Math.round(timeoutMs / 1000) + 's 内未就绪)';
  }

  // ===== 镜像准备 =====

  // 首启把 rawfile 里的内核/根文件系统/ROM 释放到沙箱; 版本变化时重新释放
  private static ensureImages(context: common.UIAbilityContext): string {
    let vmDir: string = LinuxShellService.vmDir(context);
    try {
      WorkFileService.ensureDir(vmDir);
      WorkFileService.ensureDir(vmDir + '/keymaps');
      let version: string = LinuxShellService.appVersion(context);
      let marker: string = vmDir + '/.version';
      let need: boolean = true;
      if (LinuxShellService.exists(marker) && LinuxShellService.readText(marker) === version &&
        LinuxShellService.exists(LinuxShellService.kernelPath(context)) &&
        LinuxShellService.exists(LinuxShellService.rootfsPath(context))) {
        need = false;
      }
      if (!need) {
        return '';
      }
      LinuxShellService.extractRaw(context, 'vm/kernel_aarch64', LinuxShellService.kernelPath(context));
      LinuxShellService.extractRaw(context, 'vm/rootfs_guncat.qcow2', LinuxShellService.rootfsPath(context));
      // -L 目录里的固件/键盘映射(缺了 QEMU 会告警, 不影响引导, 但一起带上干净)
      try {
        LinuxShellService.extractRaw(context, 'vm/efi-virtio.rom', vmDir + '/efi-virtio.rom');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'efi-virtio.rom 缺失, 继续: %{public}s', LinuxShellService.errText(e));
      }
      try {
        LinuxShellService.extractRaw(context, 'vm/keymaps/en-us', vmDir + '/keymaps/en-us');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'keymap 缺失, 继续: %{public}s', LinuxShellService.errText(e));
      }
      LinuxShellService.writeText(marker, version);
      return '';
    } catch (e) {
      return '释放 Linux 镜像失败: ' + LinuxShellService.errText(e) +
        '(请确认应用有可用存储空间, 镜像约 60MB)';
    }
  }

  // rawfile → 沙箱, 分块读写(避免把 35MB 镜像整个读进内存)
  private static extractRaw(context: common.UIAbilityContext, rawPath: string, dstPath: string): void {
    let desc: resourceManager.RawFileDescriptor = context.resourceManager.getRawFdSync(rawPath);
    let dst: fileIo.File | null = null;
    try {
      dst = fileIo.openSync(dstPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      let chunk: number = 1024 * 1024;
      let buffer: ArrayBuffer = new ArrayBuffer(chunk);
      let pos: number = 0;
      while (pos < desc.length) {
        let want: number = Math.min(chunk, desc.length - pos);
        let readLen: number = fileIo.readSync(desc.fd, buffer, { offset: desc.offset + pos, length: want });
        if (readLen <= 0) {
          break;
        }
        fileIo.writeSync(dst.fd, buffer, { offset: pos, length: readLen });
        pos += readLen;
      }
      if (pos !== desc.length) {
        throw new Error('rawfile 释放不完整: ' + rawPath + ' 期望 ' + desc.length.toString() +
          ' 字节, 实际 ' + pos.toString());
      }
      hilog.info(DOMAIN, TAG, 'extracted %{public}s -> %{public}s (%{public}d bytes)',
        rawPath, dstPath, pos);
    } finally {
      if (dst !== null) {
        fileIo.closeSync(dst);
      }
      context.resourceManager.closeRawFdSync(rawPath);
    }
  }

  // ===== QEMU 命令行 =====

  private static buildQemuArgs(context: common.UIAbilityContext, serialSocket: string): string[] {
    let vmDir: string = LinuxShellService.vmDir(context);
    let workspaces: string = context.filesDir + '/' + Constants.WORKSPACE_ROOT_DIR;
    let ipc: string = LinuxShellService.ipcRoot(context);
    WorkFileService.ensureDir(workspaces);
    WorkFileService.ensureDir(ipc);

    let append: string = [
      'root=/dev/sda', 'rw', 'rootfstype=ext4', 'rootwait',
      'console=ttyAMA0', 'consoleblank=0', 'loglevel=5',
      'init=/init', 'mitigations=off', 'audit=0', 'random.trust_cpu=on',
      'elevator=noop', 'skew_tick=1', 'nmi_watchdog=0', 'panic=1'
    ].join(' ');

    let args: string[] = [
      'qemu-system-aarch64',
      '-machine', 'virt,acpi=on,gic-version=max,iommu=none,its=off,usb=off,virtualization=off',
      '-cpu', 'max,pauth-impdef=on,sve=off,pmu=off',
      // TCI 只支持单线程 TCG: 这里不能写 thread=multi
      '-accel', 'tcg,thread=single',
      '-smp', '1',
      '-m', Constants.WORK_LINUX_MEMORY_MB.toString(),
      '-kernel', LinuxShellService.kernelPath(context),
      '-append', append,
      '-rtc', 'base=utc,clock=host',
      '-L', vmDir,
      '-drive', 'if=none,format=qcow2,file=' + LinuxShellService.rootfsPath(context) +
        ',id=hd0,cache=writeback,aio=threads,discard=unmap',
      '-device', 'virtio-scsi-pci-non-transitional,id=scsi0,num_queues=1',
      '-device', 'scsi-hd,drive=hd0,bus=scsi0.0,logical_block_size=4096,physical_block_size=4096,' +
        'rotation_rate=1,bootindex=1',
      // 工作区: 与 read_file/write_file 同一个目录。
      // security_model=none: 不要 mapped-file —— 后者会在每个目录里塞 .virtfs_metadata,
      // 工作区会被元数据目录污染(list_files/运行时快照都会看到)。共享目录本来就是应用私有,
      // 客人一律以应用进程身份落盘, 不需要保留 guest uid/gid。
      '-fsdev', 'local,security_model=none,id=fsdev0,path=' + workspaces,
      '-device', 'virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=workspaces',
      // 命令通道: 任务下发与结果回传
      '-fsdev', 'local,security_model=none,id=fsdev1,path=' + ipc,
      '-device', 'virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=guncatipc',
      '-netdev', 'user,id=eth0',
      '-device', 'virtio-net-pci-non-transitional,netdev=eth0',
      '-object', 'rng-random,filename=/dev/urandom,id=rng0',
      '-device', 'virtio-rng-pci-non-transitional,rng=rng0',
      '-serial', 'unix:' + serialSocket + ',server=on,wait=off',
      '-display', 'none',
      '-monitor', 'none',
      '-no-reboot'
    ];
    return args;
  }

  // ===== 执行与结果 =====

  private static async waitGuest(context: common.UIAbilityContext, conv: string, jobId: string,
    outDir: string, timeoutMs: number): Promise<GuestRun> {
    let run: GuestRun = new GuestRun();
    let start: number = Date.now();
    // 客人侧自己用 busybox timeout 兜命令; 这里再留 20s 余量给 9p 往返与结果落盘
    let deadline: number = start + timeoutMs + 20000;
    let donePath: string = outDir + '/done';
    while (Date.now() < deadline) {
      if (LinuxShellService.exists(donePath)) {
        break;
      }
      let st: VmStatus = vmStatus();
      if (!st.running) {
        run.error = 'Linux VM 在命令执行期间退出(exit=' + st.exitCode.toString() + ')' +
          '\n\n—— 串口日志尾部 ——\n' + vmSerialTail(3000);
        return run;
      }
      await LinuxShellService.sleep(Constants.WORK_LINUX_JOB_POLL_MS);
    }
    run.durationMs = Date.now() - start;
    if (!LinuxShellService.exists(donePath)) {
      run.error = '命令执行超时(' + Math.round((timeoutMs + 20000) / 1000) + 's 内没有结果)。' +
        '如果这是很慢的 TCI 任务, 拆小一点或用 timeout_ms 提高上限; 上次输出: ' +
        LinuxShellService.capChars(LinuxShellService.readTail(outDir + '/stdout', 2000), 2000);
      return run;
    }
    run.code = LinuxShellService.parseInt(LinuxShellService.readText(outDir + '/code').trim(), -1);
    run.timedOut = run.code === 137 || run.code === 124;
    run.stdout = LinuxShellService.readText(outDir + '/stdout', Constants.WORK_SHELL_MAX_OUTPUT_BYTES);
    run.stderr = LinuxShellService.readText(outDir + '/stderr', Constants.WORK_SHELL_MAX_OUTPUT_BYTES);
    run.stdoutBytes = LinuxShellService.fileSize(outDir + '/stdout');
    run.stderrBytes = LinuxShellService.fileSize(outDir + '/stderr');
    run.ok = true;
    return run;
  }

  // 输出超出"送回模型"的上限时, 把完整文件拷进工作区 .spill/, 模型可 read_file 读回
  private static materializeOutputs(context: common.UIAbilityContext, convId: string,
    outDir: string, jobId: string, run: GuestRun): void {
    if (run.stdoutBytes > Constants.WORK_SHELL_MAX_OUTPUT_BYTES) {
      run.stdoutSpill = LinuxShellService.spillCopy(context, convId, outDir + '/stdout',
        'shell-' + jobId + '.stdout.log');
    }
    if (run.stderrBytes > Constants.WORK_SHELL_MAX_OUTPUT_BYTES) {
      run.stderrSpill = LinuxShellService.spillCopy(context, convId, outDir + '/stderr',
        'shell-' + jobId + '.stderr.log');
    }
  }

  // 返回落盘后的工作区相对路径; 失败返回空串
  private static spillCopy(context: common.UIAbilityContext, convId: string,
    srcAbs: string, relName: string): string {
    try {
      let root: string = WorkFileService.workspaceRoot(context, convId);
      WorkFileService.ensureDir(root + '/' + Constants.WORK_SPILL_DIR);
      let rel: string = Constants.WORK_SPILL_DIR + '/' + relName;
      let dst: string | null = WorkFileService.resolveSafe(root, rel);
      if (dst === null) {
        return '';
      }
      fileIo.copyFileSync(srcAbs, dst);
      return rel;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'spill 拷贝失败: %{public}s', LinuxShellService.errText(e));
      return '';
    }
  }

  private static formatResult(run: GuestRun): ToolExecResult {
    let seconds: string = (run.durationMs / 1000).toFixed(1);
    let header: string = '[exit ' + run.code.toString() + ' · ' + seconds + 's · cwd ' +
      run.cwdLabel + (run.bootMs >= 500 ? ' · VM 首次引导 ' + (run.bootMs / 1000).toFixed(1) + 's' : '') + ']';
    let parts: string[] = [header];
    parts.push(LinuxShellService.bodyOrNote(run.stdout, run.stdoutSpill));
    if (run.stderr.trim() !== '' || run.stderrBytes > 0) {
      parts.push('--- stderr ---');
      parts.push(LinuxShellService.bodyOrNote(run.stderr, run.stderrSpill));
    }
    if (run.timedOut) {
      parts.push('--- 注意: 命令被超时终止(exit ' + run.code.toString() + '), 可能只执行了一半 ---');
    }
    let result: ToolExecResult = new ToolExecResult();
    // 命令跑完就是成功: 退出码非 0 是命令自身的语义(如 grep 无匹配返回 1), 交给模型判断
    result.ok = true;
    result.output = parts.join('\n');
    return result;
  }

  // 正文 + 截断说明(有 .spill 落盘时给出可读回的路径)
  private static bodyOrNote(text: string, spillRel: string): string {
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
      return head + '\n\n[...输出已截断: 完整内容在工作区 ' + spillRel + ', 需要时用 read_file 读回]';
    }
    return head + '\n\n[...输出已截断; 落盘失败, 建议把命令输出重定向到文件后用 read_file 读]';
  }

  // ===== 清理 / 空闲回收 =====

  private static cleanupJob(reqDir: string, outDir: string): void {
    LinuxShellService.removeTree(reqDir);
    LinuxShellService.removeTree(outDir);
  }

  // 空闲一段时间后让客人自己关机, 避免 512MB 的 VM 长期占着手机内存
  private static scheduleIdleShutdown(context: common.UIAbilityContext): void {
    LinuxShellService.lastActivityAt = Date.now();
    if (LinuxShellService.idleTimer !== -1) {
      clearTimeout(LinuxShellService.idleTimer);
      LinuxShellService.idleTimer = -1;
    }
    LinuxShellService.idleTimer = setTimeout((): void => {
      LinuxShellService.idleTimer = -1;
      if (Date.now() - LinuxShellService.lastActivityAt < Constants.WORK_SHELL_IDLE_SHUTDOWN_MS) {
        return;
      }
      if (!vmStatus().running) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'idle shutdown');
      LinuxShellService.poweroff(context);
    }, Constants.WORK_SHELL_IDLE_SHUTDOWN_MS);
  }

  // 通过同一条命令通道让客人 poweroff(QEMU 带 -no-reboot, 会随之退出)
  private static poweroff(context: common.UIAbilityContext): void {
    try {
      let conv: string = '.idle';
      let ipcConv: string = LinuxShellService.ipcRoot(context) + '/' + conv;
      let jobId: string = 'poweroff-' + Date.now().toString();
      let reqDir: string = ipcConv + '/in/' + jobId;
      WorkFileService.ensureDir(reqDir);
      LinuxShellService.writeText(reqDir + '/cmd', 'sync; poweroff -f');
      LinuxShellService.writeText(reqDir + '/timeout', '20');
      LinuxShellService.writeText(reqDir + '/ready', '1');
      LinuxShellService.bootPromise = null;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'poweroff 下发失败: %{public}s', LinuxShellService.errText(e));
    }
  }

  // ===== 小工具 =====

  private static ipcRoot(context: common.UIAbilityContext): string {
    return context.filesDir + '/' + Constants.WORK_LINUX_DIR + '/ipc';
  }

  private static vmDir(context: common.UIAbilityContext): string {
    return context.filesDir + '/' + Constants.WORK_LINUX_DIR + '/vm';
  }

  private static kernelPath(context: common.UIAbilityContext): string {
    return LinuxShellService.vmDir(context) + '/kernel_aarch64';
  }

  private static rootfsPath(context: common.UIAbilityContext): string {
    return LinuxShellService.vmDir(context) + '/rootfs_guncat.qcow2';
  }

  private static appVersion(context: common.UIAbilityContext): string {
    try {
      let info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      // 镜像版本单独进 marker: 同一 app 版本内换了镜像(见 WORK_LINUX_IMAGE_REV)也要重新释放
      return info.versionCode.toString() + '-' + info.versionName + '-' +
        Constants.WORK_LINUX_IMAGE_REV;
    } catch (e) {
      return 'unknown';
    }
  }

  private static nextJobId(): string {
    LinuxShellService.jobSeq = LinuxShellService.jobSeq + 1;
    return 'j' + Date.now().toString() + '-' + LinuxShellService.jobSeq.toString();
  }

  private static sanitizeConv(convId: string): string {
    let out: string = '';
    for (let i: number = 0; i < convId.length; i++) {
      let ch: string = convId.charAt(i);
      let code: number = convId.charCodeAt(i);
      let ok: boolean = (code >= 48 && code <= 57) || (code >= 97 && code <= 122) ||
        (code >= 65 && code <= 90) || ch === '_' || ch === '-';
      out += ok ? ch : '_';
    }
    return out === '' ? 'empty' : out;
  }

  private static isSafeRel(rel: string): boolean {
    if (rel.startsWith('/') || rel.indexOf(':') !== -1) {
      return false;
    }
    let segs: string[] = rel.split('/');
    for (let i: number = 0; i < segs.length; i++) {
      if (segs[i] === '..') {
        return false;
      }
    }
    return true;
  }

  private static exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private static fileSize(path: string): number {
    try {
      if (!fileIo.accessSync(path)) {
        return 0;
      }
      let st: fileIo.Stat = fileIo.statSync(path);
      return st.isDirectory() ? 0 : st.size;
    } catch (e) {
      return 0;
    }
  }

  private static removeIfExists(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // 忽略
    }
  }

  private static removeTree(path: string): void {
    try {
      if (!fileIo.accessSync(path)) {
        return;
      }
      let st: fileIo.Stat = fileIo.statSync(path);
      if (st.isDirectory()) {
        let names: string[] = fileIo.listFileSync(path);
        for (let i: number = 0; i < names.length; i++) {
          LinuxShellService.removeTree(path + '/' + names[i]);
        }
        fileIo.rmdirSync(path);
      } else {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // 忽略: 清理失败不影响命令结果
    }
  }

  private static writeText(path: string, text: string): void {
    let file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }

  // 读取文本文件; 超过 capBytes 只读前 capBytes(尾部读取见 readTail)
  private static readText(path: string, capBytes: number = Constants.WORK_SHELL_MAX_OUTPUT_BYTES * 4): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      let st: fileIo.Stat = fileIo.statSync(path);
      if (st.isDirectory() || st.size === 0) {
        return '';
      }
      let len: number = st.size < capBytes ? st.size : capBytes;
      let buffer: ArrayBuffer = new ArrayBuffer(len);
      let file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buffer, { offset: 0, length: len });
      } finally {
        fileIo.closeSync(file);
      }
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      let text: string = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
      return text;
    } catch (e) {
      return '';
    }
  }

  // 读文件尾部(用于超时等场景给一点现场)
  private static readTail(path: string, maxBytes: number): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      let st: fileIo.Stat = fileIo.statSync(path);
      if (st.size === 0) {
        return '';
      }
      let len: number = st.size < maxBytes ? st.size : maxBytes;
      let start: number = st.size - len;
      let buffer: ArrayBuffer = new ArrayBuffer(len);
      let file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buffer, { offset: start, length: len });
      } finally {
        fileIo.closeSync(file);
      }
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(new Uint8Array(buffer), { stream: false });
    } catch (e) {
      return '';
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private static capChars(text: string, max: number): string {
    if (text.length <= max) {
      return text;
    }
    return text.substring(0, max);
  }

  private static parseInt(text: string, defVal: number): number {
    let v: number = Number.parseInt(text, 10);
    return Number.isNaN(v) ? defVal : v;
  }

  private static strArg(args: Record<string, Object>, key: string, defVal: string): string {
    let v: Object | undefined = args[key];
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return defVal;
  }

  private static intArg(args: Record<string, Object>, key: string, defVal: number): number {
    let v: Object | undefined = args[key];
    if (typeof v === 'number') {
      return Math.round(v as number);
    }
    if (typeof v === 'string') {
      let n: number = Number.parseInt(v as string, 10);
      if (!Number.isNaN(n)) {
        return n;
      }
    }
    return defVal;
  }

  private static errText(e: Object): string {
    if (e instanceof Error) {
      let err: Error = e as Error;
      return err.message !== undefined ? err.message : String(e);
    }
    return String(e);
  }

  private static fail(output: string): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = false;
    r.output = output;
    return r;
  }
}
