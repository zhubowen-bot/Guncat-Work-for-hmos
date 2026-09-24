// LoopTurnInfoMapper: 把真实循环的 turn 结果映射为纯决策层的 WorkLoopTurnInfo
// (纯逻辑, 无 HarmonyOS 依赖; 供 WorkLoopDriver 接入真实循环时使用)
import { WorkLoopTurnInfo } from './WorkLoopPlanner.ts';

export class LoopTurnInfoMapper {
  static map(turn: Record<string, Object>): WorkLoopTurnInfo {
    let info: WorkLoopTurnInfo = new WorkLoopTurnInfo();
    let tc: Object | undefined = turn['toolCallsCount'];
    if (typeof tc === 'number') {
      info.toolCallsCount = tc as number;
    }
    let cl: Object | undefined = turn['contentLength'];
    if (typeof cl === 'number') {
      info.contentLength = cl as number;
    }
    let fr: Object | undefined = turn['finishReason'];
    if (typeof fr === 'string') {
      info.finishReason = fr as string;
    }
    info.aborted = turn['aborted'] === true;
    info.contextOverflow = turn['contextOverflow'] === true;
    info.maxStepsReached = turn['maxStepsReached'] === true;
    return info;
  }
}
