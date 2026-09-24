// WorkLoopDriverBridge: 把真实 AgentLoopService.runTurnWithRetry 适配为 WorkLoopDriver 的 runTurn 钩子
// 这是 WorkLoopDriver 接入 ChatViewModel 真实循环的“桥梁”:
//   - 运行期仍由 AgentLoopService 做单轮三协议流式请求/请求级重试;
//   - WorkLoopDriver 负责循环级状态机/计划器/统计, 配置 maxRetriesPerTurn=0 避免双重重试;
//   - 待 ChatViewModel 切到 WORK_USE_DRIVER_LOOP 后, 循环主体由本桥驱动。
import { ApiConfig } from './ApiConfig.ts';
import { AbortSignal } from './Types.ts';
import { LoopTurnInfoMapper } from './LoopTurnInfoMapper.ts';
import { WorkLoopDriver, WorkLoopDriverConfig, WorkLoopDriverHooks, WorkLoopDriverResult } from './WorkLoopDriver.ts';
import { WorkLoopTurnInfo } from './WorkLoopPlanner.ts';
import { AgentLoopService, LoopMessage, LoopTurnCallbacks } from './AgentLoopService.ts';

export class WorkLoopDriverBridge {
  // 通用步骤适配: ChatViewModel 接管时把自己的单步实现注入 runStep 即可,
  // 驱动负责步进/计划器/收尾/中止; maxRetriesPerTurn=0 表示单步内部已自行处理重试。
  static async runWithStep(runStep: (step: number) => Promise<WorkLoopTurnInfo | null>,
    maxSteps: number, onStep?: (step: number, action: string, reason?: string) => void): Promise<WorkLoopDriverResult> {
    let hooks: WorkLoopDriverHooks = {
      runTurn: runStep,
      onStep: (step: number, action: string, reason?: string): void => {
        if (onStep !== undefined) {
          onStep(step, action, reason);
        }
      }
    };
    let cfg: WorkLoopDriverConfig = new WorkLoopDriverConfig();
    cfg.maxSteps = maxSteps;
    cfg.maxRetriesPerTurn = 0;
    return await WorkLoopDriver.run(hooks, cfg);
  }

  // 现有便捷入口: 用 AgentLoopService.runTurnWithRetry 作为单步实现
  static async run(config: ApiConfig, messages: LoopMessage[], thinkingEnabled: boolean,
    reasoningEffort: string, webSearchEnabled: boolean, callbacks: LoopTurnCallbacks,
    abortSignal: AbortSignal, includeTools: boolean, toolOverrides: Record<string, Object>[] | null,
    maxSteps: number, onStep?: (step: number, action: string, reason?: string) => void): Promise<WorkLoopDriverResult> {
    return await WorkLoopDriverBridge.runWithStep(async (_step: number): Promise<WorkLoopTurnInfo | null> => {
      if (abortSignal.aborted) {
        return LoopTurnInfoMapper.map({
          'toolCallsCount': 0, 'contentLength': 0, 'finishReason': '',
          'aborted': true, 'contextOverflow': false, 'maxStepsReached': false
        });
      }
      let turn = await AgentLoopService.runTurnWithRetry(config, messages,
        thinkingEnabled, reasoningEffort, webSearchEnabled, callbacks, abortSignal,
        includeTools, 0, toolOverrides);
      if (abortSignal.aborted) {
        return LoopTurnInfoMapper.map({
          'toolCallsCount': 0, 'contentLength': turn.content.length,
          'finishReason': turn.finishReason, 'aborted': true,
          'contextOverflow': false, 'maxStepsReached': false
        });
      }
      return LoopTurnInfoMapper.map({
        'toolCallsCount': turn.toolCalls.length, 'contentLength': turn.content.length,
        'finishReason': turn.finishReason, 'aborted': false,
        'contextOverflow': false, 'maxStepsReached': false
      });
    }, maxSteps, onStep);
  }
}
