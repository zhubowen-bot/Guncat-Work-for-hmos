/**
 * Guncat Work run_js 工具的原生接口(JSVM-API 沙箱)。
 * 实现见 entry/src/main/cpp/jsvm_sandbox.cpp 与 napi_init.cpp。
 */

/** 单次执行的沙箱参数(均有默认值与上限, 越界由 native 侧收敛) */
export interface JsRunOptions {
  /** 只读输入文件: 键为文件名(工作区相对路径), 值为文件文本; 脚本内通过 inputs / read() 读取 */
  inputs?: Record<string, string>;
  /** 报错与调用栈里显示的文件名, 默认 run_js.js */
  resourceName?: string;
  /** 单次执行堆上限(MB), 默认 256, 允许范围 16~1024 */
  heapMb?: number;
  /** console 输出上限(KB), 默认 64, 允许范围 1~1024 */
  stdoutLimitKb?: number;
  /** 单个输出文件上限(KB), 默认 1024, 允许范围 1~4096 */
  outputFileLimitKb?: number;
  /** 输出总量上限(KB), 默认 4096, 允许范围 1~8192 */
  outputTotalLimitKb?: number;
  /** 输出文件个数上限, 默认 16, 允许范围 1~64 */
  maxOutputFiles?: number;
}

/** 单次执行结果 */
export interface JsRunResult {
  /** 脚本是否成功执行完(语法错误/运行报错/引擎不可用均为 false) */
  ok: boolean;
  /** 脚本完成值(最后一条表达式的值)是否为 undefined */
  hasResult: boolean;
  /** console.log / print 收集到的输出文本 */
  stdout: string;
  /** 完成值的文本表示(字符串原样, 对象/数组为 JSON) */
  result: string;
  /** ok=false 时的错误说明 */
  error: string;
  /** 截断等提示信息 */
  notice: string;
  /** 执行耗时(毫秒) */
  durationMs: number;
  /** native 实际收到的预载输入文件数(供调用方核对参数是否完整送达) */
  inputCount: number;
  /** native 实际安装到 inputs 上的键名(归一化后的工作区相对路径, 就是脚本里该用的键) */
  inputKeys: string[];
  /** 脚本通过 write(name, content) 声明的输出文件(仅 ok=true 时有效) */
  outputs: Record<string, string>;
}

/**
 * 在独立 JS 引擎实例中执行一段 JS 代码(异步, 不阻塞 UI 线程; 每次执行使用全新实例)。
 * 引擎不可用时不抛异常, 而是返回 ok=false 的结果对象。
 */
export const runJs: (code: string, options?: JsRunOptions) => Promise<JsRunResult>;

/** 探测 JSVM 是否可用: 返回空串表示可用, 否则为不可用原因(结果会在进程内缓存) */
export const engineStatus: () => string;
