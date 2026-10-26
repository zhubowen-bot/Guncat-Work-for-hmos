/**
 * Guncat Work Linux VM(QEMU TCI)原生接口。
 * 实现见 entry/src/main/cpp/vm/guncat_vm.cpp。
 */

/** 启动参数 */
export interface VmStartOptions {
  /** QEMU 命令行: 一行一个 argv(含 argv[0], 惯例写 qemu-system-aarch64) */
  argsLines: string;
  /** 串口日志用的 unix socket 路径; 传空串表示不需要串口日志 */
  serialSocket: string;
}

/** 启动结果 */
export interface VmStartResult {
  /** 是否已成功把 QEMU 线程拉起来(不等于引导完成, 引导完成看 9p 通道里的就绪标记) */
  ok: boolean;
  /** ok=false 时的原因 */
  error: string;
  /** 实际加载到的运行库文件名(空=未加载) */
  lib: string;
}

/** 运行状态 */
export interface VmStatus {
  /** QEMU 线程是否还在跑 */
  running: boolean;
  /** 是否正在启动过程中 */
  starting: boolean;
  /** 实际加载到的运行库文件名 */
  lib: string;
  /** 运行库不可用的原因 */
  loadError: string;
  /** QEMU 线程退出码(QEMU 尚未退出时为 0) */
  exitCode: number;
}

/** 运行库可用性: 返回空串表示可用, 否则是不可用原因 */
export const isAvailable: () => string;

/** 启动 VM(同进程内运行 QEMU, 不做 fork) */
export const startVM: (options: VmStartOptions) => VmStartResult;

/** 读取 VM 运行状态 */
export const status: () => VmStatus;

/** 最近 maxChars 个字符的串口日志(已去 ANSI 转义, 便于直接进错误信息) */
export const serialTail: (maxChars: number) => string;

/** 订阅串口增量数据(原始字节, ArrayBuffer) */
export const onData: (callback: (data: ArrayBuffer) => void) => void;

/** 订阅 QEMU 线程退出事件 */
export const onExit: (callback: () => void) => void;

/** 往串口写字节(终端/中断用); 返回是否写入成功 */
export const sendInput: (data: ArrayBuffer) => boolean;

/** 标记 VM 已停止(进程退出即销毁, 这里只翻转状态让上层停止等待) */
export const requestShutdown: () => boolean;
