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

  // 本轮已收尾, 且安全插话点上取走了 steerCount 条用户插话: 驱动继续跑一轮而不是结束。
  static steer(steerCount: number, contentLength: number, finishReason: string): WorkLoopTurnInfo {
    let info: WorkLoopTurnInfo = new WorkLoopTurnInfo();
    info.toolCallsCount = 0;
    info.contentLength = contentLength;
    info.finishReason = finishReason;
    info.aborted = false;
    info.steerCount = steerCount;
    return info;
  }
}
