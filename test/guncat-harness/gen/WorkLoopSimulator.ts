// WorkLoopSimulator: 全循环纯编排模拟器(无 HarmonyOS 依赖, 可单测)
// 用 WorkLoopPlanner 驱动 run→tool→evaluate→finish/abort/compact 步骤机,
// 配合 FaultInjector 的确定性场景做全循环回归矩阵。
import { WorkLoopPlanner, WorkLoopTurnInfo, WorkLoopStep } from './WorkLoopPlanner.ts';

export class WorkLoopSimResult {
  steps: number = 0;
  toolSteps: number = 0;
  textSteps: number = 0;
  compactSteps: number = 0;
  aborted: boolean = false;
  finalReason: string = '';
  decisions: string[] = [];
}

export class WorkLoopSimulator {
  // turnProvider(index, state) 返回单轮结果; maxSteps 兜底防失控。
  // 返回 null 表示不再有下一轮(强制收尾)。
  static run(turnProvider: (index: number, toolSteps: number) => WorkLoopTurnInfo | null,
    maxSteps: number): WorkLoopSimResult {
    let r: WorkLoopSimResult = new WorkLoopSimResult();
    for (let i: number = 0; i < maxSteps; i++) {
      let info: WorkLoopTurnInfo | null = turnProvider(i, r.toolSteps);
      if (info === null) {
        r.finalReason = 'provider_end';
        break;
      }
      let d = WorkLoopPlanner.decide(info);
      r.decisions.push(d.action);
      r.steps++;
      if (d.action === WorkLoopStep.TOOL) {
        r.toolSteps++;
      } else if (d.action === WorkLoopStep.FINISH || d.action === WorkLoopStep.TEXT) {
        r.textSteps++;
        r.finalReason = d.reason;
        break;
      } else if (d.action === WorkLoopStep.ABORT) {
        r.aborted = true;
        r.finalReason = d.reason;
        break;
      } else if (d.action === WorkLoopStep.COMPACT) {
        r.compactSteps++;
      }
    }
    if (r.steps >= maxSteps && r.finalReason === '') {
      r.finalReason = 'max_steps';
    }
    return r;
  }
}
