# 工作区与会话数据的生命周期（手机端）

> 回答一个具体问题：**删掉会话，工作区的沙箱目录会不会一起删？**
> 会（会话删除时无条件删目录 + 会话事件日志）。但"会删"不等于"一定不残留"，本文把四类残留
> 场景与对应措施写清楚，避免以后有人把其中一条当成冗余代码删掉。

## 一、磁盘上有什么（应用沙箱内，无存储权限）

| 路径 | 内容 | 生命周期 |
| --- | --- | --- |
| `filesDir/workspaces/<会话ID>/` | **会话工作区**：上传件、模型产出、`.todo.json`、`.goal.json`、`.schedule.json`、`.searches.md`、`.spill/`（工具结果溢出全文）、`subagents/sa_*/`（子代理产出） | 会话删除时整目录删除；崩溃残留由启动清扫回收 |
| `filesDir/sessions/<会话ID>.jsonl` | 会话事件日志（turn/tool/steer/driver_step…），`session_search` 的数据源 | 会话删除时删除；同样参与启动清扫 |
| `filesDir/guncat_conversations.json` | 全部会话（含消息、附件解析文本；图片 base64 超阈值时剥离） | 每次变更原子写（`.tmp` + rename） |
| `filesDir/linux/{vm,ipc}/` | VM 内核/rootfs 镜像、宿主↔客人命令通道 | 全局共享，与单个会话无关；`ipc/<会话>/in|out/<jobId>` 每条命令用完即清，下次引导整体清空 |
| `filesDir/python/` | 原生 CPython 运行时（共享，约 1GB 量级） | 随包版本，与会话无关 |
| `cacheDir/work_office/`、`cacheDir/dim_*` 等 | Office/PDF 解析的临时解包目录 | 每次解析 `finally` 删除；缓存目录由系统按需回收 |

工作区目录名 = 会话 ID 经 `WorkFileService.workspaceDirName()` 净化后的形态（当前 ID 形如
`conv_<时间戳>_<随机数>`，净化是恒等映射；保留净化是为了历史数据与注入防护）。

## 二、删除链路

`ChatViewModel.deleteConversation(convId)`：

1. 若正在跑的就是这个会话 → 先 `stopStreaming()`（否则循环会把工具结果写回去，把目录"复活"）；
2. 工作区里还有文件 → 弹一次确认（写明"会话与工作区文件一起删、不可恢复"）；空工作区不问；
3. `deleteConversationData()` → `WorkFileService.deleteWorkspace()` + `SessionLogService.close(…, true)`；
   **不按会话模式判断**（聊天模式通常是空操作，但模式判断一旦和历史数据对不上就会漏删）；
4. 从会话列表移除并持久化。

`WorkFileService.deleteWorkspace()` 同时清掉 `FileObservation` 的「已读过」登记——目录没了，
登记也就没意义，否则同名文件重建后会被当成"已经读过"，反而绕过编辑守卫。

## 三、四类残留，与各自的对策

| 场景 | 症状 | 对策 |
| --- | --- | --- |
| 任务执行中删会话 | 目录删了，循环随后写入工具结果 → 目录重新出现，界面上再也看不到 | 删除前先 `stopStreaming()`；循环 `finally` 里再 `reapDeletedConversation()` 补删一次 |
| 删除过程中进程被杀（闪退/OOM/强退） | 目录只删了一半，或列表已删、目录还在 | 启动清扫（见下）按会话列表补齐 |
| 旧版本根本没有删工作区 | 升级上来的设备带着一批孤儿目录，永久占空间 | 启动清扫一次回收 |
| 空对话被"自动清理" | `cleanupEmptyConversation` 只从列表移除，不留文件 | 移除时同样调 `deleteConversationData()`（空目录也清） |

### 启动清扫（`ChatViewModel.sweepOrphanData()`）

- 时机：`restoreState()` 读完会话列表之后、自动新建会话之前；
- 判定：`common/OrphanSweep.ts`（纯逻辑）——**存活集合之外的一切**都是孤儿，
  存活集合由会话 ID 按落盘命名规则换算而来（不是猜名字）；
- 防护：只有 `StorageManager.conversationsLoadOk()` 为真（存档确实读到并解析成功）才执行。
  读取失败/文件损坏时列表为空，若照扫就等于把用户所有工作区删光——**宁可不扫**；
- 范围：`workspaces/` 下的目录 + `sessions/*.jsonl`；单个删除失败只记日志，不阻塞启动。

## 四、刻意不做的事

- **不做 TTL 自动过期**：工作区里是用户的交付物，"多久没打开就删"是不可接受的数据丢失。
- **不做容量配额/自动驱逐**：手机上无法判断哪份文件可以牺牲；空间不够时的正确做法是让用户看到
  （工作区面板里列出每个文件的大小），由用户决定清哪一个。
- **不把工作区挪进 `cacheDir`**：系统可以在任何时候回收 cache，那等于静默丢文件。

## 五、验证清单

- [ ] 工作会话里产出若干文件 → 删会话 → `workspaces/<id>` 与 `sessions/<id>.jsonl` 都不存在。
- [ ] 任务执行中删会话 → 任务停止，随后目录不被重建（`finally` 补删）。
- [ ] 手动造一个 `workspaces/conv_old_1/` 再重启 → 被清掉；同时 `conversationsLoadOk=false`（存档损坏）
      时**不**清扫。
- [ ] 浅聊（聊天模式）会话删除 → 不弹确认、不留目录。
- [ ] 工作区有文件的会话删除 → 先弹确认，点"取消"什么都不删。
