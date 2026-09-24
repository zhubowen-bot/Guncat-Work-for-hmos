import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

export class BackgroundReaderService {
  private static session: avSession.AVSession | null = null;
  private static running: boolean = false;

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
        bundleName: 'com.bowenapp.guncataibeta',
        abilityName: 'EntryAbility'
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    let agent: WantAgent = await wantAgent.getWantAgent(agentInfo);
    await backgroundTaskManager.startBackgroundRunning(
      context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
    BackgroundReaderService.running = true;
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (BackgroundReaderService.running) {
      await backgroundTaskManager.stopBackgroundRunning(context);
      BackgroundReaderService.running = false;
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
