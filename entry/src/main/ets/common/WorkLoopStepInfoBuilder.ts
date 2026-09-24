// WorkLoopStepInfoBuilder: 构造单步 WorkLoopTurnInfo 的纯逻辑工具
// 让真实循环/驱动路径共用一致的中止/收尾/工具步信息，便于单测与逐步替换。
import { WorkLoopTurnInfo } from './WorkLoopPlanner';

export class WorkLoopStepInfoBuilder {
  static aborted(): WorkLoopTurnInfo {
    let info: WorkLoopTurnInfo = new WorkLoopTurnInfo();
    info.aborted = true;
    return info;
  }

  static finish(contentLength: number, finishReason: string): WorkLoopTurnInfo {
    let info: WorkLoopTurnInfo = new WorkLoopTurnInfo();
    info.toolCallsCount = 0;
    info.contentLength = contentLength;
    info.finishReason = finishReason;
    info.aborted = false;
    return info;
  }

  static tool(toolCallsCount: number, contentLength: number, finishReason: string): WorkLoopTurnInfo {
    let info: WorkLoopTurnInfo = new WorkLoopTurnInfo();
    info.toolCallsCount = toolCallsCount;
    info.contentLength = contentLength;
    info.finishReason = finishReason;
    info.aborted = false;
    return info;
  }
}
