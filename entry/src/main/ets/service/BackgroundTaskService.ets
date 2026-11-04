// BackgroundTaskService: AI 回复/Agent 循环等长程网络任务的后台保活
//
// 鸿蒙对后台进程的管控分两层：短时任务负责“退后台后的一小段硬保活”，长时任务
// 负责“用户可感知的持续业务”。普通手机应用没有无限期后台常驻的合法通道，所以这里
// 采用分层策略，尽量把长程任务跑完，同时不做系统明确禁止的保活：
//  1. 退后台时先申请短时任务(requestSuspendDelay)，拿到默认约 3 分钟的硬窗口，
//     覆盖“回复马上结束/工具正在收尾”的绝大多数场景；到期前在回调里主动取消，
//     避免超时未取消被系统终止进程，也避免浪费当天的短时任务配额。
//  2. 同时申请长时任务：手机/平板用 dataTransfer(后台确实在持续收发模型流/工具
//     网络)；2in1 优先用 taskKeeping(计算任务，仅 PC/2in1 开放)，失败自动回退
//     dataTransfer。长时任务会显示系统通知，用户可感知。
//  3. 监听 continuousTaskCancel / continuousTaskSuspend：记录系统取消/暂停原因。
//     只在 SYSTEM_CANCEL 且任务仍在跑时重试一次；用户主动取消、删除通知、低速率、
//     违规使用都不重试，避免反复弹通知骚扰用户。
//  4. 短时任务超时回调、长时任务被暂停时各补一次落盘；流式内容本身已按 5s 增量
//     落盘，即使进程最终被系统回收，也不会丢掉整段回复。
// 与朗读用的 BackgroundReaderService(AUDIO_PLAYBACK) 互不影响。
import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { StorageManager } from '../data/StorageManager';

const DOMAIN: number = 0x0000;

export class BackgroundTaskService {
  private static running: boolean = false;
  // 并发去重: onBackground 可能与上次 start 尚未完成的调用重叠
  private static starting: boolean = false;
  // start 是异步的(先取 WantAgent 再 startBackgroundRunning)。若这期间任务已经结束、
  // stop() 先返回, 旧的 start 仍会把长时任务挂上去, 直到下一次前台/结束才释放。
  // 用代次号让过期的 start 在成功后立刻自行撤销。
  private static generation: number = 0;
  // 最近一次申请保活用的 UIAbilityContext: 系统取消回调里需要用它重试一次
  private static backgroundContext: common.UIAbilityContext | undefined = undefined;
  // 短时任务 requestId(-1 表示当前没有持有)
  private static transientRequestId: number = -1;
  // 系统取消/暂停监听只注册一次
  private static listenersRegistered: boolean = false;
  // 系统取消后的一次性重试(每个流式会话最多一次)
  private static retryTimer: number = -1;
  private static retried: boolean = false;
  // 当前长时任务的 id: 用来过滤旧任务的迟到 cancel 回调
  private static runningTaskId: number = -1;

  // 流式任务开始时就预申请短时任务(前台申请也合法, 且只有真正退后台才计时/消耗配额)。
  // 这样即使 onBackground 回调晚到或被系统压缩, 后台窗口也已经提前挂好。
  static prepare(context: common.UIAbilityContext): void {
    BackgroundTaskService.backgroundContext = context;
    BackgroundTaskService.ensureListeners();
    BackgroundTaskService.requestTransientTask(context);
  }

  static async start(context: common.UIAbilityContext): Promise<void> {
    // 先更新 context: 即使当前已有任务在跑, 后续系统回调的重试也要用最新的 Ability。
    BackgroundTaskService.backgroundContext = context;
    if (BackgroundTaskService.running || BackgroundTaskService.starting) {
      return;
    }
    BackgroundTaskService.starting = true;
    const generation: number = ++BackgroundTaskService.generation;

    // 先拿短时任务: 同步接口，不排在 WantAgent/长时任务的异步链路后面。
    // 即使长时任务申请失败，接下来的约 3 分钟也仍能继续跑。
    BackgroundTaskService.prepare(context);

    let startedMode: string = '';
    let startedTaskId: number = -1;
    try {
      let agent: WantAgent = await BackgroundTaskService.buildWantAgent(context);
      const modes: string[] = BackgroundTaskService.preferredModes();
      for (let i: number = 0; i < modes.length; i++) {
        if (generation !== BackgroundTaskService.generation) {
          break;
        }
        try {
          const notification: backgroundTaskManager.ContinuousTaskNotification =
            await backgroundTaskManager.startBackgroundRunning(context, [modes[i]], agent);
          startedMode = modes[i];
          startedTaskId = notification.continuousTaskId !== undefined ? notification.continuousTaskId : -1;
          break;
        } catch (modeError) {
          // 2in1 的 taskKeeping 在部分设备/版本上可能未开放: 记录后回退 dataTransfer
          hilog.warn(DOMAIN, 'testTag', 'start continuous task mode %{public}s failed: %{public}s',
            modes[i], BackgroundTaskService.errorText(modeError));
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'Failed to prepare background task. Cause: %{public}s',
        BackgroundTaskService.errorText(e));
    }

    if (generation !== BackgroundTaskService.generation) {
      // 启动期间任务已结束/已回前台: 不能让这个长时任务泄漏到下一次
      if (startedMode !== '') {
        try {
          await BackgroundTaskService.stopContinuousTask(context, startedTaskId);
        } catch (stopError) {
          hilog.warn(DOMAIN, 'testTag', 'cancel stale continuous task failed: %{public}s',
            BackgroundTaskService.errorText(stopError));
        }
      }
      BackgroundTaskService.starting = false;
      return;
    }

    if (startedMode !== '') {
      BackgroundTaskService.running = true;
      BackgroundTaskService.runningTaskId = startedTaskId;
      hilog.info(DOMAIN, 'testTag', 'Succeeded in starting continuous task: %{public}s id=%{public}d',
        startedMode, startedTaskId);
    } else {
      hilog.error(DOMAIN, 'testTag', 'No continuous task mode started; transient task is the only protection');
      // 申请失败可能只是系统服务瞬时忙; 短时任务仍在线, 2.5s 后再尝试一次长时任务
      BackgroundTaskService.scheduleRetry();
    }
    BackgroundTaskService.starting = false;
  }

  // 释放长时任务 + 短时任务; 未持有或系统返回错误时静默兜底，供同步上下文 fire-and-forget 调用
  static async stop(context: common.UIAbilityContext): Promise<void> {
    // 即使 start 还在飞, 也让它的代次过期; 这样 stop 不会被"starting"吞掉。
    BackgroundTaskService.generation++;
    BackgroundTaskService.retried = false;
    BackgroundTaskService.backgroundContext = undefined;
    if (BackgroundTaskService.retryTimer !== -1) {
      clearTimeout(BackgroundTaskService.retryTimer);
      BackgroundTaskService.retryTimer = -1;
    }
    BackgroundTaskService.cancelTransientTask();
    if (!BackgroundTaskService.running) {
      BackgroundTaskService.runningTaskId = -1;
      return;
    }
    const taskId: number = BackgroundTaskService.runningTaskId;
    BackgroundTaskService.running = false;
    BackgroundTaskService.runningTaskId = -1;
    try {
      await BackgroundTaskService.stopContinuousTask(context, taskId);
      hilog.info(DOMAIN, 'testTag', 'Succeeded in stopping continuous task id=%{public}d', taskId);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'Failed to stop continuous task. Cause: %{public}s',
        BackgroundTaskService.errorText(e));
    }
  }

  // 只停自己这一条长时任务。API 21+ 支持按 id 停止, 避免把同时运行的朗读
  // AUDIO_PLAYBACK 任务一起停掉; 拿不到 id 时才退回按 Ability 全停。
  private static async stopContinuousTask(context: common.UIAbilityContext, taskId: number): Promise<void> {
    if (taskId >= 0) {
      await backgroundTaskManager.stopBackgroundRunning(context, taskId);
    } else {
      await backgroundTaskManager.stopBackgroundRunning(context);
    }
  }

  private static preferredModes(): string[] {
    // TASK_KEEPING 只对 PC/2in1 开放；手机/平板用 DATA_TRANSFER。
    // 这里用字符串数组，兼容 API 12+ 的多模式接口，也方便失败后逐项回退。
    const type: string = deviceInfo.deviceType;
    if (type === '2in1' || type === 'pc') {
      return ['taskKeeping', 'dataTransfer'];
    }
    return ['dataTransfer'];
  }

  private static async buildWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    let agentInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1002,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(agentInfo);
  }

  // 短时任务: 退后台后的约 3 分钟硬窗口。必须在超时回调里主动取消，否则系统会
  // 对应用做挂起/终止处理。回调里再补一次落盘，尽量减少被挂起时的内容损失。
  private static requestTransientTask(context: common.UIAbilityContext): void {
    if (BackgroundTaskService.transientRequestId !== -1) {
      return;
    }
    try {
      let info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay('AI 任务执行中', (): void => {
          BackgroundTaskService.cancelTransientTask();
          hilog.warn(DOMAIN, 'testTag', 'Transient task is about to time out; flushing conversations');
          StorageManager.flushConversations(context).catch((): void => {});
        });
      BackgroundTaskService.transientRequestId = info.requestId;
      hilog.info(DOMAIN, 'testTag', 'Transient task started, requestId=%{public}d, delay=%{public}dms',
        info.requestId, info.actualDelayTime);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'Failed to request transient task. Cause: %{public}s',
        BackgroundTaskService.errorText(e));
    }
  }

  private static cancelTransientTask(): void {
    const requestId: number = BackgroundTaskService.transientRequestId;
    if (requestId === -1) {
      return;
    }
    BackgroundTaskService.transientRequestId = -1;
    try {
      backgroundTaskManager.cancelSuspendDelay(requestId);
      hilog.info(DOMAIN, 'testTag', 'Transient task cancelled, requestId=%{public}d', requestId);
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to cancel transient task. Cause: %{public}s',
        BackgroundTaskService.errorText(e));
    }
  }

  private static ensureListeners(): void {
    if (BackgroundTaskService.listenersRegistered) {
      return;
    }
    BackgroundTaskService.listenersRegistered = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          BackgroundTaskService.onContinuousTaskCancel(info);
        });
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to listen continuousTaskCancel. Cause: %{public}s',
        BackgroundTaskService.errorText(e));
    }
    try {
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          BackgroundTaskService.onContinuousTaskSuspend(info);
        });
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to listen continuousTaskSuspend. Cause: %{public}s',
        BackgroundTaskService.errorText(e));
    }
  }

  private static onContinuousTaskCancel(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
    // 只处理自己这条任务。朗读服务也注册了长时任务, 它的 cancel 不应影响 AI 保活状态。
    if (!BackgroundTaskService.running) {
      return;
    }
    // 重试后旧任务的迟到 cancel 不能把新任务的状态清掉
    if (BackgroundTaskService.runningTaskId !== -1 && info.id !== BackgroundTaskService.runningTaskId) {
      hilog.info(DOMAIN, 'testTag', 'Ignore stale continuous task cancel, id=%{public}d', info.id);
      return;
    }
    BackgroundTaskService.running = false;
    BackgroundTaskService.runningTaskId = -1;
    hilog.warn(DOMAIN, 'testTag', 'Continuous task cancelled, id=%{public}d reason=%{public}d',
      info.id, info.reason);
    // 只有系统侧取消且任务仍在跑时才重试一次。用户主动取消/删除通知(1、3)、
    // 低速率(4)、违规使用(11)都属于明确的停止信号，不能反复申请。
    if (info.reason === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL) {
      BackgroundTaskService.scheduleRetry();
    }
  }

  private static onContinuousTaskSuspend(info: backgroundTaskManager.ContinuousTaskSuspendInfo): void {
    // 只关心自己这条任务, 避免朗读任务的暂停触发 AI 侧的落盘/状态变化
    if (!BackgroundTaskService.running) {
      return;
    }
    if (BackgroundTaskService.runningTaskId !== -1 &&
      info.continuousTaskId !== BackgroundTaskService.runningTaskId) {
      return;
    }
    hilog.warn(DOMAIN, 'testTag', 'Continuous task suspend changed, id=%{public}d state=%{public}s reason=%{public}d',
      info.continuousTaskId, info.suspendState ? 'true' : 'false', info.suspendReason);
    if (!info.suspendState) {
      return;
    }
    // 系统暂停长时任务往往紧接着挂起进程，先把当前流式内容落盘。
    const context: common.UIAbilityContext | undefined = BackgroundTaskService.backgroundContext;
    if (context !== undefined) {
      StorageManager.flushConversations(context).catch((): void => {});
    }
  }

  private static scheduleRetry(): void {
    if (BackgroundTaskService.retried || BackgroundTaskService.retryTimer !== -1) {
      return;
    }
    if (AppStorage.get<boolean>('chatStreamingActive') !== true) {
      return;
    }
    if (AppStorage.get<boolean>('appForeground') !== false) {
      return;
    }
    const context: common.UIAbilityContext | undefined = BackgroundTaskService.backgroundContext;
    if (context === undefined) {
      return;
    }
    BackgroundTaskService.retried = true;
    BackgroundTaskService.retryTimer = setTimeout((): void => {
      BackgroundTaskService.retryTimer = -1;
      if (AppStorage.get<boolean>('chatStreamingActive') === true &&
        AppStorage.get<boolean>('appForeground') === false) {
        BackgroundTaskService.start(context);
      }
    }, 2500);
  }

  private static errorText(error: Object): string {
    const e: BusinessError = error as BusinessError;
    if (e !== undefined && e.message !== undefined) {
      return e.code !== undefined ? (e.code + ': ' + e.message) : e.message;
    }
    return String(error);
  }
}
