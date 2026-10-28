# 三端功能对齐审计（鸿蒙版 vs 电脑版 / 安卓版）

> 审计日期：2026-10-28
> 审计对象：`Guncat-Work-for-hmos`（6.4.0）对照 `Guncat-Work-for-pc`(0.2.1) 与
> `Guncat-Work-for-android`(0.2.1)
> 口径：静态代码 + 文档比对（`git log` / `CHANGELOG` / 常量表 / 工具定义 / 提示词 / 服务清单），
> 不含真机运行验证。按用户既定口径，**各端 shell / 语音 / 目录权限等平台能力差异不计入**。

## 结论

核心层（Agent Loop、工具面、Office/PDF、技能、交互模式）**确实已基本对齐**：工具名逐一对齐、
交互模式白名单 27 项逐字相同、技能 40 个 `SKILL.md` 全同、`agents.json` 全同，多数核心文件与
电脑版同源。差异集中在**电脑/安卓 0.2.0 之后新增的四项能力**（@引用、项目指令、编辑前读取守卫、
后台任务）与**四处会静默失败的实现缺陷**（答案丢失、图片丢失、大图超时、跨会话串台）。

## 本轮处置（2026-10-28）

| 项 | 状态 |
| --- | --- |
| 3.1 @ 引用工作区文件 | ✅ 已加：`common/MentionQuery.ts` + `service/WorkspaceMentionService.ts` + 输入框候选层 + 提示词契约 |
| 3.2 项目指令 AGENTS.md | ✅ 按用户口径只加提示词（不自动注入） |
| 3.3 编辑前读取守卫 | ✅ 已加：`common/FileObservation.ts` + 分发咽喉点守卫 |
| 2.1 ask 护栏 | ✅ 已修：360s，等待上限提成常量成对维护 |
| 2.2 子代理图片 | ✅ 已修：与主循环同口径逐张追加 |
| 2.3 大图压缩 | ✅ 已改：只做 >8MB 兜底压缩（不做固定压缩） |
| 2.4 跨会话插话串台 | ✅ 已修：`runningConvId` + `streamingHere` + 提问卡归属 |
| **并行 view_image 收不全图片** | ✅ **确认是 bug**（后一次结果覆盖前一次），已改为逐张送达 |
| 3.4 后台任务 | ⏸ 暂缓（内存/闪退风险），方案见 `docs/BACKGROUND_JOBS_PLAN.md` |
| 3.5 凭据加密 | ⏳ 未做（下一轮） |
| 四、1~3 小项 | ✅ 版本号 → 6.4.0；✅ 搜索条数入口 |

---

## 一、已确认对齐（抽样，供对照）

| 维度 | 证据 |
| --- | --- |
| 工具面 | 42 个同名工具（`WorkFileService.toolDefs` + `HarnessTools.toolDefs`）逐一比对一致；鸿蒙侧另有 `shell` / `run_python` 顶替 `run_command`，并有 `web_fetch` / `run_js` / `local_web_search` |
| 交互模式工具面 | `ToolRegistry.INTERACTIVE_TOOL_WHITELIST` 27 项**逐字相同**；三个消费点（主循环/溢出重试/压缩）同走 `toolDefsForMode()` |
| 技能 | 两端 `SKILL.md` 均为 40 份且目录结构一致；`WorkSkillService` 仅"本环境无 Python 脚本"一句不同 |
| 智能体 | 两端 `agents.json` 条目逐条一致 |
| 核心纯逻辑 | `DataPipeline`(1832) / `GuncatUiLang`(2941 vs 2948) / `PptxBuilder`(1181) / `DocxBuilder`(737) / `XlsxBuilder`(355) 等行数与实现同源 |
| 移动端能力 | 后台保活 `BackgroundTaskService`、屏幕常亮 `EntryAbility.keepScreenOn`、拍照、系统分享接收、Preview Kit 预览、CoreSpeechKit 朗读、系统语音输入、表格识别页均在 |
| 已知修复 | "第二轮失忆"不适用（鸿蒙循环历史本来就含 `conv.messages` 全量）；`view_image` 主循环图片注入已有（`ChatViewModel` 2410 / 3093）；裸围栏判定两端同源 |

---

## 二、缺陷（静默失败，建议优先修）

### 2.1 `ask_user_question` 的护栏比卡片等待短 3 分钟 → 用户答案被丢弃

- 卡片等待：`HarnessTools.ts:488` 传 `300000` ms（5 分钟），`AskUserBridge.ask` 到点以取消收场。
- 外层护栏：`WorkToolRunner.ets:53-66` 取 `meta.timeoutMs > 0 ? meta.timeoutMs : WORK_TOOL_TIMEOUT_MS`，
  而 `ask_user_question` 没有单独配置，落到 `Constants.ts:293` 的 `180000`（3 分钟）。
- 结果：第 3~5 分钟作答时，模型早已收到"工具执行超时"结果；`AskUserBridge.resolveWith` 解的是一个
  已经没人等待的 Promise —— **卡片还在界面上，答了等于没答**，且模型会以为用户没回。
- 电脑版已修：`Constants.ts:245/258`（`WORK_ASK_WAIT_TIMEOUT_MS=300000`、
  `WORK_ASK_TOOL_GUARD_TIMEOUT_MS=360000`），并在 `WorkFileService` 里 `setRuntimeConfig`。

修法：`ensureToolRegistry()` 里给 `ask_user_question` 补一条
`setRuntimeConfig('ask_user_question', 360000, 0)`，并把 300000 提成常量。

### 2.2 子代理里的 `view_image` 拿不到像素

- `SubagentService.ts:188-210`：子代理历史只有 `system` + 一条 `user` 子任务，工具回包之后的
  `exec.imageDataUrl` 从不被追加成多模态消息（主循环 `ChatViewModel` 有这段，`SubagentService` 没有）。
- 结果：子代理调用 `view_image` 显示成功，但视觉通道没收到任何像素 —— 最终报告只能**凭空编造**图片内容。
- 电脑版已修（0.1.0-fix 修主循环，0.2.0 补子代理）：`SubagentService` 里维护
  `ToolImageAttachment[]`，在工具结果后追加 `LoopMessage.userImage(...)`。

修法：把主循环的图片注入逻辑抽成 `AgentLoopService.appendToolImageMessages`，子代理复用。

### 2.3 `view_image` 不压大图，配合重试会重复发同一张大图

- `WorkFileService.ts:697-739`：只做 8MB 上限判断，然后**原样 base64 内联**；超 8MB 直接失败并提示
  "请先压缩" —— 但交互模式没有 `run_python` / `shell`，模型无路可走。
- 手机拍照产物 3~8MB 很常见：一次 `view_image` 就是 4~11MB base64 的请求，超时后请求级重试
  （5 次）会把同一张图**重复发 5 次**。
- 安卓版已修：`WorkFileService.ts:961-1020` 的 `compressInlineImage`（>1MB 或最长边 >1600px
  时按 1600/82 → 1280/72 → 1024/62 逐级降档，只压"送给模型的副本"，工作区原图不动），
  提示词里也写明"大图自动压缩"。

修法：用 `@kit.ImageKit` 的 `createImagePacker` 在 `toolViewImage` 内做同样的逐级降档；
解不出图时退回原图并如实标注。

### 2.4 跨会话"插话"串台：B 会话里发的话被 A 会话的任务吃掉

- 现象链（静态可判，建议真机复现确认一次）：
  1. 工作/交互会话 A 正在跑任务 → `isStreaming = true`；
  2. 侧栏切到另一个工作/交互会话 B（`openConversation` 不拦截、不打断 A 的循环）；
  3. 在 B 里发送 → `ChatPage.handleSend` 走 `SendRoute.STEER` → `ChatViewModel.sendMessage`
     见 `isStreaming && agentLoopMode` 直接转 `steerWork`（`ChatViewModel.ets` 私有的插话入口）；
  4. `steerWork` 把消息推进**全局唯一**的 `this.workSteerQueue`，同时追加到 B 的消息列表；
  5. A 的循环在插话点把队列整体取走，作为【用户补充】注入 **A** 的请求并写进 A 的历史。
- 结果：B 里那条消息永远没人回应（用户以为"AI 不理我"），A 的任务凭空收到一句与它无关的指令。
- 电脑版没有这个问题：`SessionManager` 按 `conversationId` 维护运行态与插话队列，B 里发送是**新开
  一个任务**，A 继续在后台跑（桌面端支持多会话并行）。
- 修法（二选一）：
  - 短期：`steerWork` 前校验"插话队列的归属会话 == 当前会话"，不等则按新任务处理或明确提示；
    同时把 `workSteerQueue` 收进"运行中会话"的作用域。
  - 彻底：把循环状态（`isStreaming` / steer 队列 / ask 队列）按 `convId` 分桶，与电脑版对齐，
    顺带支持多会话并行。

---

## 三、功能缺口（电脑版/安卓版有，鸿蒙版没有）

### 3.1 输入框 `@` 引用工作区文件（整条链路缺失）

电脑版：`core/service/WorkspaceMentionService.ts`（279 行）+ `components/MentionPopup.tsx` +
`Composer.tsx` 接线 + `PromptBuilder` 契约段 + `Constants.WORK_MENTION_*` 三重预算
（单文件 24000 字符 / 本轮 60000 / 最多 8 份）+ 越界一个字节都不读 + 邮箱与 URL 里的 `@` 不触发。
鸿蒙版：全仓搜不到 `mentioned_files` / `WorkspaceMention` / `MENTION`，输入框没有任何引用入口。

影响：工作区一大，模型只能靠 `list_files` 摸路；用户明明知道"这次就改这三个文件"却没法告诉它，
多花 2~3 轮往返，还会猜错文件。**这是三端里唯一的"交互形态"级缺口**。

### 3.2 工作区项目指令（`AGENTS.md` / `CLAUDE.md` / `GUNCAT.md`）不注入

电脑版：`core/service/WorkspaceInstructionsService.ts` + `Constants.ts:274`
（`WORK_INSTRUCTION_FILES`，另有体积/总量上限）+ 运行时快照段 + 子代理继承 + 同名闭合标签中和。
鸿蒙版：没有任何指令文件注入；`PromptBuilder` 里也没有"以后都按这个来就写进 AGENTS.md"这条纪律。

影响：用户无法把"这个项目一贯的规矩"长期交给模型（每次都得口头重述）；模型说"好的，记住了"
其实下一轮就忘。子代理更是在"主代理守约定、子代理不守"的分裂状态下工作。

### 3.3 编辑前读取守卫（`FileObservation`）缺失

电脑版：`core/common/FileObservation.ts` + `WorkFileService.guardBeforeTool/recordAfterTool`
挂在工具分发咽喉点；没读过报 `FS_NOT_OBSERVED`，读过之后被改过报 `FS_STALE_VERSION`，
两种都拒绝落盘并回一句可照抄的 `read_file("同一路径")`。版本指纹 = `大小:mtime:开头 8KB 的 FNV-1a`
（同秒等长改动也能发现）。
鸿蒙版：`HarnessTools.toolEdit`（266-340）每次现读现改，**没有任何守卫**；提示词只有一句
"修改文件前先读取确认现状"（`PromptBuilder.ts:48`），属于口头约定。

影响：模型凭文件名想象改文件、`old_string` 侥幸匹配上就覆盖，是"静默改坏"的主要来源；
用户手动改了文件、`shell` 改了文件之后，模型手上的仍是旧内容。

> 3.1 与 3.3 天然配套：@ 附上整份正文时按同一口径登记"已读过"，才不会出现
> "引用了却不让改"的矛盾。

### 3.4 后台任务（`run_in_background` / `job_list` / `job_output` / `job_kill`）缺失

电脑版：`core/service/CommandService.ts` 四件套 + `Constants.ts:239-247`
（默认 30s、上限 300s、`WORK_CMD_MAX_JOBS=8`、增量"读后即弃"游标）。
安卓版：同样四件套（`CommandService.ts:31-33,235-281`），跑在其 JS shell 上。
鸿蒙版：`shell` / `run_python` 只有同步调用（`HarnessTools.ts:661-699`，参数里没有
`run_in_background`），`shell` 最长 240s、`run_python` 最长 180s，护栏 360s/200s。

影响：`apk add`、`pip install`、大一点的项目构建/打包一旦超过 240s，工具直接判超时，
既拿不到增量输出、也无法中途 kill；模型没有"先放后台、下一轮收结果"这条路。

修法：`LinuxShellService` 已经有 `ipc/<会话>/in|out/<jobId>` 的任务目录机制，把"等 done 文件"
拆成"下发即返回 jobId"，再加三个 job 工具与一个会话内任务表即可，改动集中在 shell 服务与
`HarnessTools.toolDefs`。

### 3.5 凭据明文落盘（电脑版/安卓版已加密）

电脑版/安卓版：`core/platform/kit/ArkData.ts` 的 `enc:v1:` + Electron `safeStorage`
（Windows DPAPI / macOS Keychain / 安卓 Keystore），平台不支持时**明文但如实上报**，
换机器解不开时只剔除那几项并点名。
鸿蒙版：`data/StorageManager.ts:289-292` 直接把 `ApiConfig`（含 API Key）JSON 写进 Preferences。

影响：能被备份/同步盘/其他进程顺手读到；三端里唯一没有凭据保护的一版。
修法：用 Asset Store Kit（或 HUKS 自建 AES-GCM）包一层，保持"旧明文可读、下次写盘转密文、
状态如实上报"的三条边界。

---

## 四、一致性小问题

1. **版本号不一致**：`AppScope/app.json5` 是 `6.4.0`，`common/Constants.ts:4` 的
   `APP_VERSION` 仍是 `6.3.0`（About 面板会显示 6.3.0）。
2. **本地搜索"单次结果条数"未暴露**：`SearchEngineSettings.maxResults` 存在且默认 8，
   电脑版设置里有"单次结果条数"输入项，鸿蒙版 `SettingsPanel` 没有这一项。
3. **子代理不继承项目指令**：与 3.2 同一处改造（`SubagentService.buildSubagentPrompt` 加一段）。
4. **提示词口径**：鸿蒙 `PromptBuilder` 的"能访问范围"段已按 `shell` / `run_python` 改写，
   但 `docs/features.md` 里"45 个工具"与"47 个"两种说法并存（电脑版 README 同病），建议统一。

---

## 五、平台差异 / 有意取舍（不计入缺漏，供确认）

| 项 | 说明 |
| --- | --- |
| `run_command` 四档审批 + `CommandGuard` 163 条规则 + 模型审阅 | 鸿蒙以 VM 隔离替代；按用户口径不做。注意：VM 内 `rm -rf /` 只毁 VM，但如果哪天把工作区外目录挂进 9p，这条边界需要重新评估 |
| 自定义工作区目录、在文件管理器中显示、拖拽导入、剪贴板图片粘贴 | 桌面端独有（无对应系统能力） |
| ASR 服务商配置（`asr_baseUrl/apiKey/model`） | 鸿蒙用系统语音识别，无需 |
| `run_js` 死循环不可中断 | JSVM-API 无终止接口，文档已声明；电脑版 `node:vm` 可硬中断 |
| Mermaid 规范（桌面宽屏 LR/mindmap/gantt vs 手机竖屏只 TDE） | 按渲染宽度分叉，属正确差异 |
| 子代理排除 `shell` / `run_python` | 鸿蒙独有取舍：工作区写入隔离只重定向"路径参数"，约束不住 shell 的任意重定向，代码里已写明理由 |
| 交互模式不下发 `run_python` / `shell` | 与电脑版不下发 `run_command` 同一逻辑；`PromptBuilder.interactiveTools` 的建议（`run_js` / `transform_file`）与白名单一致，无漂移 |

---

## 六、建议顺序与量级

| 优先级 | 项 | 量级 |
| --- | --- | --- |
| P0 | 2.1 `ask_user_question` 护栏（常量 + `setRuntimeConfig`） | ~10 行 |
| P0 | 2.2 子代理图片注入 | 半天（抽公共方法） |
| P0 | 2.3 `view_image` 逐级压缩 | 半天（对齐安卓实现） |
| P0 | 2.4 跨会话插话串台（先加归属校验止血） | 半天；彻底分桶 2~3 天 |
| P1 | 3.3 编辑前读取守卫（含 `fsVersionOf` + 分发咽喉点） | 1 天 |
| P1 | 3.1 @ 引用（服务 + 输入框弹层 + 提示词段 + 常量） | 2 天（与 3.3 一起做最省） |
| P1 | 3.2 项目指令（服务 + 快照段 + 子代理继承） | 1 天 |
| P2 | 3.4 后台任务（shell/python 异步化 + 3 个工具） | 2~3 天 |
| P2 | 3.5 凭据加密（Asset Store Kit） | 1~2 天 |
| P3 | 四、1~3 小项 | 半天 |
