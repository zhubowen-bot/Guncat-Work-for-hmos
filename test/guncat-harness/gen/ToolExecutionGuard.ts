// ToolExecutionGuard: 工具执行的统一超时/取消护栏(纯逻辑, 无 HarmonyOS 依赖)
// 对齐 DeepSeek Harness 的 tool-timeout 策略: 任何工具调用都不能无限期占住 Agent Loop;
// 超时或用户取消时返回调用方提供的兜底结果。底层任务在超时/取消后可能仍继续执行
// (同步工具无法安全中断), 但其最终结果会被丢弃, 不会阻塞循环。
import { AbortSignal } from './Types.ts';

export class ToolExecutionGuard {
  // 用超时与取消信号护栏包裹一个工具任务:
  //  - abortSignal.aborted 时立即返回 onAborted() 的兜底结果;
  //  - 超过 timeoutMs 未完成时返回 onTimeout() 的兜底结果;
  //  - 任务先完成则透传其结果(失败同样透传, 由上层按错误处理)。
  static async run<T>(task: Promise<T>, timeoutMs: number,
    abortSignal: AbortSignal | null,
    onTimeout: () => T,
    onAborted: () => T): Promise<T> {
    if (abortSignal !== null && abortSignal.aborted) {
      return onAborted();
    }
    return await new Promise<T>((resolve: (value: T) => void, reject: (e: Error) => void) => {
      let settled: boolean = false;
      let timer: number = -1;
      let poller: number = -1;
      let clearTimer = (): void => {
        if (timer !== -1) {
          clearTimeout(timer);
          timer = -1;
        }
        if (poller !== -1) {
          clearInterval(poller);
          poller = -1;
        }
      };
      let resolveOnce = (value: T): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimer();
        resolve(value);
      };
      let rejectOnce = (e: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimer();
        reject(e);
      };
      task.then((value: T): void => {
        resolveOnce(value);
      }, (e: Error): void => {
        rejectOnce(e);
      });
      timer = setTimeout((): void => {
        resolveOnce(onTimeout());
      }, timeoutMs);
      if (abortSignal !== null) {
        poller = setInterval((): void => {
          if (abortSignal.aborted) {
            resolveOnce(onAborted());
          }
        }, 100);
      }
    });
  }
}
