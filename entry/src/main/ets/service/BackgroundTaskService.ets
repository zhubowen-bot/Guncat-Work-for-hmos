// BackgroundTaskService: AI 回复/Agent 循环等长程网络任务的后台保活
//  - 切后台时若流式任务仍在进行, 申请 dataTransfer 长时任务, 避免进程被系统挂起导致任务中断
//  - 任务结束或回到前台时立即释放; 与朗读用的 BackgroundReaderService(AUDIO_PLAYBACK) 互不影响
import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

const DOMAIN: number = 0x0000;

export class BackgroundTaskService {
  private static running: boolean = false;
  // 并发去重: onBackground 可能与上次 start 尚未完成的调用重叠
  private static starting: boolean = false;

  static async start(context: common.UIAbilityContext): Promise<void> {
    if (BackgroundTaskService.running || BackgroundTaskService.starting) {
      return;
    }
    BackgroundTaskService.starting = true;
    try {
      let agentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.bowenapp.guncataibeta',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1002,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      let agent: WantAgent = await wantAgent.getWantAgent(agentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      BackgroundTaskService.running = true;
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'Failed to start dataTransfer task. Cause: %{public}s',
        (e as Error).message);
    } finally {
      BackgroundTaskService.starting = false;
    }
  }

  // 释放长时任务; 未持有或系统返回错误时静默兜底, 供同步上下文 fire-and-forget 调用
  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (!BackgroundTaskService.running) {
      return;
    }
    BackgroundTaskService.running = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'Failed to stop dataTransfer task. Cause: %{public}s',
        (e as Error).message);
    }
  }
}
