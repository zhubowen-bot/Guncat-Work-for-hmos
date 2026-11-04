# 后台保活策略

> 适用版本：7.1.0 之后的性能专项。相关代码：
> `entry/src/main/ets/service/BackgroundTaskService.ets`、`EntryAbility.onBackground/onForeground/onDestroy`、
> `ChatViewModel.markStreamStart/markStreamEnd`。

## 先说结论

HarmonyOS 不允许普通手机应用在后台无限期常驻。对“AI 回复 / Agent 循环”这类业务，
系统里没有完全匹配的长时任务类型：手机上没有对第三方开放的通用计算保活，`taskKeeping`
仅对 PC/2in1 开放。因此本项目的目标是**尽量提高存活优先级、把大多数任务跑完**，而不是
承诺进程永不被回收：

1. 短时任务提供退后台后的**约 3 分钟硬窗口**；
2. 长时任务在用户可感知的前提下延长运行时间，并接受系统的业务一致性校验；
3. 流式内容每 5 秒增量落盘，超时/暂停时再补一次落盘。即使进程最终被系统回收，
   已生成的内容也不会整段丢失。

## 分层实现

### 1. 短时任务（Transient Task）

- 流式任务开始时（前台）就调用 `backgroundTaskManager.requestSuspendDelay()` 预申请。
  短时任务只有应用真正处于后台时才计时、消耗配额，提前申请可以让 3 分钟窗口不依赖
  `onBackground` 回调的到达时机。
- 退后台时如果还没有短时任务，`BackgroundTaskService.start()` 会再同步申请一次。
- 超时前约 6 秒系统回调，项目在回调里做两件事：
  - 立刻 `cancelSuspendDelay()`，避免“超时不取消”被系统终止进程；
  - 强制 `StorageManager.flushConversations()`，把正在流式写入的内容落盘。
- 任务结束、回前台、Ability 销毁时主动取消，避免占用当天配额。

约束：单次最长约 3 分钟，低电量时约 1 分钟；单日配额约 10 分钟；最多同时 3 个。
本项目只申请 1 个，不通过循环申请来绕过单次上限。

### 2. 长时任务（Continuous Task）

退后台且 `chatStreamingActive === true` 时申请：

| 设备 | 申请类型 | 原因 |
| --- | --- | --- |
| phone / tablet | `dataTransfer` | 后台仍在持续接收模型 SSE / 调用工具网络，属于非托管数据传输；系统通知栏会显示“正在运行数据传输任务”。 |
| 2in1 / pc | `taskKeeping`，失败回退 `dataTransfer` | PC/2in1 对第三方开放计算任务长时任务；失败时按手机同款策略兜底。 |

其他要点：

- `WantAgent` 的 `bundleName` / `abilityName` 从 `context.abilityInfo` 读取，不再硬编码
  beta 包名，避免正式包申请失败。
- 监听 `continuousTaskCancel`：仅当原因为 `SYSTEM_CANCEL` 且流式任务仍在后台运行时，
  2.5 秒后重试一次；用户主动取消、删除通知、低速率、违规使用都不重试。
- 监听 `continuousTaskSuspend`：记录暂停原因，并在暂停瞬间补一次落盘。
- 停止时按 `continuousTaskId` 只停自己这一条长时任务；朗读服务的 `audioPlayback`
  任务也按各自 id 停止，二者同时运行时不会互相误停。
- 任务结束、回前台、Ability 销毁时释放长时任务和短时任务，避免通知残留与配额浪费。

约束（来自 Background Tasks Kit 文档）：

- 长时任务类型必须与实际业务一致；系统会校验，业务停止后继续持有会被挂起/终止。
- `DATA_TRANSFER` 如果长时间没有进度更新（首次超过 10 分钟），任务会被取消；低速率也会
  被取消。手机端没有可用的进度更新接口（API 24），因此这里只做一次性重试，不刷进度
  来绕过系统限制。
- 一个 UIAbility 同时只能申请一个长时任务（API 20 及以前）；本项目只会申请一个。

### 3. 恢复与落盘

- 流式期间 `scheduleStreamUpdate()` 每 5 秒合并写一次会话存档；
- `onBackground`、短时任务超时回调、长时任务暂停、`onDestroy` 各补一次强制 flush；
- 避免在后台做工作区扫描、整页刷新和 100ms 级 UI 轮询（页面侧已按 `appForeground`
  跳过重活），降低后台 CPU 占用触发系统管控的概率。

## 明确不做的保活

- 不申请 `AUDIO_PLAYBACK` 假装播放音频：系统会检测实际音频流，没有播放会被
  静音/冻结，且属于违规使用。
- 不用循环短时任务绕过单次 3 分钟 / 单日 10 分钟配额。
- 不在用户删除长时任务通知后反复弹通知。

## 排障

过滤 hilog tag `testTag`，关键日志包括：

- `Transient task started / cancelled`
- `Succeeded in starting continuous task: <mode> id=<id>`
- `Continuous task cancelled ... reason=<n>`
- `Continuous task suspend changed ...`
- `No continuous task mode started; transient task is the only protection`
