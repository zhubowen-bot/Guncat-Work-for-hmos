// WorkLoopDriver: 可单测的 Agent Loop 循环主体(纯逻辑, 无 HarmonyOS 依赖)
// 把“状态机 + 单轮计划器 + 重试 + 压缩/工具批次回调”收进一个纯驱动:
// 真实循环只需注入 runTurn(IO), 由驱动负责决定 TOOL/FINISH/ABORT/COMPACT。
import { WorkLoopStateMachine, WorkLoopState } from './WorkLoopStateMachine';
import { WorkLoopPlanner, WorkLoopTurnInfo, WorkLoopStep } from './WorkLoopPlanner';
import { RetryPolicy } from './RetryPolicy';

export class WorkLoopDriverConfig {
  maxSteps: number = 200;
  maxRetriesPerTurn: number = 3;
  seed: number = 0.5;
}

export class WorkLoopDriverResult {
  steps: number = 0;
  toolSteps: number = 0;
  textSteps: number = 0;
  compactSteps: number = 0;
  retries: number = 0;
  aborted: boolean = false;
  maxStepsReached: boolean = false;
  finalReason: string = '';
  finalState: string = '';

  // 驱动正常收尾(有 finalReason 且未中止、未步数耗尽)
  isFinished(): boolean {
    return this.finalReason !== '' && !this.aborted && !this.maxStepsReached;
  }
}

export interface WorkLoopDriverHooks {
  runTurn(step: number): Promise<WorkLoopTurnInfo | null>;
  onRetry?(attempt: number, reason: string): void;
  onCompact?(reason: string): void;
  onToolBatch?(count: number): void;
  onStep?(step: number, action: string, reason?: string): void;
}

export class WorkLoopDriver {
  static async run(hooks: WorkLoopDriverHooks, config: WorkLoopDriverConfig = new WorkLoopDriverConfig()): Promise<WorkLoopDriverResult> {
    let r: WorkLoopDriverResult = new WorkLoopDriverResult();
    let sm: WorkLoopStateMachine = new WorkLoopStateMachine();
    sm.start();
    let policy: RetryPolicy = new RetryPolicy(config.maxRetriesPerTurn, 500, 8000, 0.2,
      ['rate_limit', 'server', 'transport', 'empty']);
    for (let i: number = 0; i < config.maxSteps; i++) {
      let info: WorkLoopTurnInfo | null = null;
      let attempt: number = 0;
      while (true) {
        try {
          info = await hooks.runTurn(i);
          break;
        } catch (e) {
          let err: Error = e as Error;
          let kind: string = WorkLoopDriver.extractKind(err);
          let rd = policy.decide(kind, attempt, -1, config.seed);
          if (!rd.shouldRetry) {
            throw err;
          }
          attempt++;
          r.retries++;
          if (hooks.onRetry !== undefined) {
            hooks.onRetry(attempt, err.message !== undefined ? err.message : kind);
          }
          await WorkLoopDriver.sleep(rd.delayMs);
        }
      }
      if (info === null) {
        r.finalReason = 'provider_end';
        sm.finish();
        break;
      }
      let d = WorkLoopPlanner.decide(info);
      r.steps++;
      if (hooks.onStep !== undefined) {
        hooks.onStep(i, d.action, d.reason);
      }
      if (d.action === WorkLoopStep.TOOL) {
        r.toolSteps++;
        if (hooks.onToolBatch !== undefined) {
          hooks.onToolBatch(info.toolCallsCount);
        }
      } else if (d.action === WorkLoopStep.FINISH || d.action === WorkLoopStep.TEXT) {
        r.textSteps++;
        r.finalReason = d.reason;
        sm.finish();
        break;
      } else if (d.action === WorkLoopStep.ABORT) {
        r.aborted = true;
        r.finalReason = d.reason;
        sm.abort();
        break;
      } else if (d.action === WorkLoopStep.COMPACT) {
        r.compactSteps++;
        if (hooks.onCompact !== undefined) {
          hooks.onCompact(d.reason);
        }
      }
    }
    if (r.steps >= config.maxSteps && r.finalReason === '') {
      r.finalReason = 'max_steps';
      r.maxStepsReached = true;
      sm.abort();
    }
    r.finalState = sm.current();
    return r;
  }

  private static extractKind(err: Error): string {
    let rec: Record<string, Object> = err as unknown as Record<string, Object>;
    let k: Object | undefined = rec['kind'];
    if (typeof k === 'string' && (k as string) !== '') {
      return k as string;
    }
    return 'transport';
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
