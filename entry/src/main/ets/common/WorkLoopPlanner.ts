// WorkLoopPlanner: 循环单轮“评估(evaluate)”纯决策层(无 HarmonyOS 依赖)
// 根据单轮结果快照决定下一步动作: 继续工具 / 收尾回答 / 压缩 / 中止。
// 供 WorkLoopOrchestrator 与 ChatViewModel 共用的核心判定, 独立可单测。
export class WorkLoopStep {
  static readonly TOOL: string = 'tool';
  static readonly TEXT: string = 'text';
  static readonly FINISH: string = 'finish';
  static readonly ABORT: string = 'abort';
  static readonly COMPACT: string = 'compact';
}

export class WorkLoopTurnInfo {
  toolCallsCount: number = 0;
  contentLength: number = 0;
  finishReason: string = '';
  aborted: boolean = false;
  maxStepsReached: boolean = false;
  contextOverflow: boolean = false;
}

export class WorkLoopDecision {
  action: string = WorkLoopStep.FINISH;
  reason: string = '';
}

export class WorkLoopPlanner {
  static decide(info: WorkLoopTurnInfo): WorkLoopDecision {
    let d: WorkLoopDecision = new WorkLoopDecision();
    if (info.aborted) {
      d.action = WorkLoopStep.ABORT;
      d.reason = 'aborted';
      return d;
    }
    if (info.maxStepsReached) {
      d.action = WorkLoopStep.FINISH;
      d.reason = 'max_steps';
      return d;
    }
    if (info.toolCallsCount > 0) {
      d.action = WorkLoopStep.TOOL;
      d.reason = 'tool_calls';
      return d;
    }
    if (info.contextOverflow) {
      d.action = WorkLoopStep.COMPACT;
      d.reason = 'context_overflow';
      return d;
    }
    if (info.contentLength > 0 || info.finishReason !== '') {
      d.action = WorkLoopStep.FINISH;
      d.reason = info.finishReason === 'max_tokens' ? 'max_tokens' : 'final_answer';
      return d;
    }
    d.action = WorkLoopStep.FINISH;
    d.reason = 'no_output';
    return d;
  }

  // 人类可读的决策描述(供日志/调试/未来 UI 提示)
  static describe(info: WorkLoopTurnInfo): string {
    let d: WorkLoopDecision = WorkLoopPlanner.decide(info);
    if (d.action === WorkLoopStep.ABORT) {
      return '中止';
    }
    if (d.action === WorkLoopStep.COMPACT) {
      return '上下文溢出压缩';
    }
    if (d.action === WorkLoopStep.TOOL) {
      return '工具调用 ' + info.toolCallsCount.toString();
    }
    if (d.reason === 'max_steps') {
      return '步数耗尽';
    }
    if (d.reason === 'max_tokens') {
      return '达到 max_tokens 收尾';
    }
    if (d.reason === 'final_answer') {
      return '模型收尾';
    }
    return '无输出收尾';
  }
}
