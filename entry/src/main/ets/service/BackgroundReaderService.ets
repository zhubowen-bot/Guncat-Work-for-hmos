import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

export class BackgroundReaderService {
  private static session: avSession.AVSession | null = null;
  private static running: boolean = false;
  // 朗读自己的长时任务 id: 停止时只停这一条, 避免把 AI 任务的 dataTransfer 一起停掉
  private static taskId: number = -1;

  static async start(context: common.UIAbilityContext): Promise<void> {
    if (BackgroundReaderService.running) {
      return;
    }
    if (BackgroundReaderService.session === null) {
      BackgroundReaderService.session =
        await avSession.createAVSession(context, 'Guncat Work Reader', 'audio');
      await BackgroundReaderService.session.activate();
    }
    let playbackState: avSession.AVPlaybackState = {
      state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
      speed: 1
    };
    await BackgroundReaderService.session.setAVPlaybackState(playbackState);
    let agentInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    let agent: WantAgent = await wantAgent.getWantAgent(agentInfo);
    const notification: backgroundTaskManager.ContinuousTaskNotification =
      await backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], agent);
    BackgroundReaderService.taskId =
      notification.continuousTaskId !== undefined ? notification.continuousTaskId : -1;
    BackgroundReaderService.running = true;
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (BackgroundReaderService.running) {
      const taskId: number = BackgroundReaderService.taskId;
      BackgroundReaderService.taskId = -1;
      BackgroundReaderService.running = false;
      try {
        if (taskId >= 0) {
          await backgroundTaskManager.stopBackgroundRunning(context, taskId);
        } else {
          await backgroundTaskManager.stopBackgroundRunning(context);
        }
      } catch (e) {
        // 任务可能已被系统/用户取消: 继续释放 AVSession, 不阻塞朗读停止
      }
    }
    if (BackgroundReaderService.session !== null) {
      let playbackState: avSession.AVPlaybackState = {
        state: avSession.PlaybackState.PLAYBACK_STATE_STOP,
        speed: 1
      };
      await BackgroundReaderService.session.setAVPlaybackState(playbackState);
      await BackgroundReaderService.session.deactivate();
      await BackgroundReaderService.session.destroy();
      BackgroundReaderService.session = null;
    }
  }
}
