/**
 * Guncat Work 原生 Python 运行时(CPython 3.12，dlopen 动态加载 libpython3.12.so)。
 * 实现见 entry/src/main/cpp/python/guncat_py.cpp。
 */

/** 单次执行参数 */
export interface PyRunOptions {
  /** 要执行的 Python 源码 */
  code: string;
  /** 工作目录(就是会话工作区; 脚本里相对路径以它为基准) */
  workDir?: string;
  /** 临时脚本/结果文件目录(应用 tempDir 下的子目录) */
  scratchDir?: string;
  /** CPython 的 PYTHONHOME(标准库根) */
  pythonHome?: string;
  /** CPython 的 PYTHONPATH(标准库 zip + lib-dynload) */
  pythonPath?: string;
  /** sys.argv 的 JSON 数组字符串, 默认 "[]" */
  argvJson?: string;
  /** CA 证书包路径(ssl 用), 缺省用系统默认 */
  certFile?: string;
  /** 超时毫秒数, 默认 60000 */
  timeoutMs?: number;
}

/** 单次执行结果 */
export interface PyRunResult {
  /** 脚本是否正常跑完(语法错误/异常/超时均为 false) */
  ok: boolean;
  /** 是否因超时被中断 */
  timedOut: boolean;
  /** true 表示宿主放弃等待(任务仍在后台跑), 而不是被正常打断 */
  softTimeout: boolean;
  /** SystemExit 的退出码(普通异常为 0) */
  exitCode: number;
  /** 被捕获的 stdout */
  stdout: string;
  /** 被捕获的 stderr */
  stderr: string;
  /** ok=false 时的错误说明(traceback) */
  error: string;
  /** 执行耗时(毫秒) */
  durationMs: number;
}

/** 运行库可用性: 返回空串表示可用, 否则为不可用原因 */
export const isAvailable: () => string;

/** 在常驻解释器里执行一段 Python(同步调用, 调用方应放到异步任务里) */
/** 0=可用 1=忙(超时任务仍在跑, 结束即恢复) 2=已封禁(连续 3 次超时) */
export const pyState: () => number;

export const runPython: (options: PyRunOptions) => PyRunResult;
