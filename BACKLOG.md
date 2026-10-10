# BACKLOG

## 交互模式（Intelligent UI，6.3.0）本轮完成
- [x] 虚拟智能体与会话模式：`Constants.INTERACTIVE_AGENT_ID` / `MODE_INTERACTIVE`，`buildInteractiveAgent()` 注入列表第二位，`AgentDrawerView`/`DswSidebar` 归入「Agent模式」分组（`ic_interactive.svg` 图标）。
- [x] DSL 单一事实源 `common/GuncatUiSpec.ts`：11 种元素 + 4 种控件 + 图表/动作模型、容错解析（补括号修复 → 逐元素退化 → 骨架）、流式渐进解析、围栏分词、回传载荷构造、系统提示词正文（含反例）。
- [x] 消息体切分 `common/GuncatUiParts.ts`：文本片段 + 界面片段；非法块保留原文交还 Markdown，不丢内容。
- [x] 原生渲染器 `views/GuncatUiView.ets`：指标卡/指标组/进度条/表格/横向柱状图/Shape+Path 折线图/Path 环形占比/提示条/卡片与分栏容器/表单控件（Slider·Toggle·Select·TextInput）/选项按钮；未被 form 引用的控件自动成卡。
- [x] 双向交互闭环：`sendUiInteraction()` 把界面取值打包为中文用户消息回传（空闲即重跑循环、执行中走插 steer），`pendingUiMessageId` 决定置灰，历史界面归档。
- [x] 循环与提示词分叉：`AgentLoopService.buildWorkSystemPromptFor(mode)` + `compactWorkHistoryIfNeeded(messages, force, loopMode)`，交互模式与工作模式共享循环/工具/工作区，仅提示词与渲染不同。
- [x] 回归护栏：`GuncatUiSpec` / `GuncatUiParts` 纳入 `test/guncat-harness`（分词、渐进解析、非法 JSON、未知 kind、限额、回传组装）；`test-core` 328 项全绿；`assembleHap` BUILD SUCCESSFUL。

## 交互模式后续待办
- [x] 快车道（速度优先，R69）：系统提示词不再复用工作模式底座，改走 `PromptBuilder.buildInteractive()` —— **默认零工具、一轮直出界面**，工具只在"界面必须引用真实数据"时破例（一轮 ≤1~2 次、优先只读）；禁 `todo_write`/`goal_*`/`schedule_*`/`subagent`/`session_search`/`ask_user_question`（要问就用界面问）；不写自检报告、不画 mermaid 导图；默认思考强度改「快速(Low)」。提示词 36.7k → 22.8k 字符（行为纪律段 15.6k → 1.7k）。
- [x] 工具面物理裁剪（R74）：交互模式下发前按 `ToolRegistry.INTERACTIVE_TOOL_WHITELIST` 裁到 **27 个**（读素材 / 算真实数字 / 核实外部事实 / 出文件），长程与维护类工具**不在请求里**（提示词纪律之外再加物理保证）；技能段同步降为极小索引（`SkillDirectoryFormatter.interactiveIndex()`，只列 docx/xlsx/ppt/svg/data）。三个消费点（主循环 / 溢出重试 / 上下文压缩）共用 `AgentLoopService.toolDefsForMode()` 的同一份工具面。
- [ ] 速度度量：按 mode 采样"首答 TTFT + 本轮工具调用数"（复用 `LoopMetrics` / `tool_latency` 事件），用数据持续验证快车道效果，并作为回归基线。
- [ ] 交互状态归档：把用户提交过的控件取值随消息持久化（当前仅存于组件内 @State，重启后回到默认值）。
- [ ] 数据集绑定：让界面元素可绑定工作区数据文件（如 `table` 直接引用 `data.csv` 列），改参数由本地管道重算而不必再过模型。
- [ ] 元素扩充：`timeline`（时间轴）、`kanban`（分组看板）、`slider` 双端区间、`date` 控件。
- [ ] 界面块回退：解析失败时在气泡内给出「查看原始 JSON」折叠入口（当前仅按普通代码块渲染）。
- [ ] 工具化渲染：新增 `render_ui` 工具，让模型在长任务中间主动弹界面，而不必等最终回答。

## 核心层待办（按杠杆排序，R1–R12 已完成项见 ITERATION_LOG.md）

### 已完成里程碑
- [x] R1–R5：工具超时/取消护栏、聊天模式统一护栏、Schema 校验、Loop 并发安全、可观测标记。
- [x] R6–R7：ToolRegistry 统一工具元数据 + Subagent 工具面裁剪。
- [x] R8–R9：PromptBuilder 分块 + 动态工具目录注入。
- [x] R10：LoopMetrics 评估指标（随 turn_end 写入，schemaError 端到端）。
- [x] R11：工具 HTTP 深度取消（download_file/web_fetch 注册表 + stopStreaming 销毁）。
- [x] R12：tool_result 请求级 traceId。
- [x] R66：子代理并行派发（parallelSafe + 全局并发闸 + 取消透传）。
- [x] R67：子代理工作区隔离（自动独立 `subagents/sa_<ts>_<n>/` 产出目录 + 可选 `output_dir` + 执行层写入重定向/主工作区保护）。
- [x] R15（产品功能）：文件系统预览不支持时支持“用其他应用打开”（隐式 Want 拉起系统打开方式选择框）。

### 新待办（按审计维度重新生成）
- [x] LLMAdapter 统一（R20/R23/R24 完成：`LLMProtocol` 协议/端点、`ToolDefAdapter` 工具形态、`SSEProtocolAdapter` SSE 解析统一流水线，handleSseLine 大 if/switch 已收敛）。
- [x] LoopOrchestrator 核心决策层（R13/R21/R22 完成：`ToolScheduler` 调度、`RepeatDetector` 重复防护、`LoopDecisions` 快照去重/溢出压缩/max_tokens/无效步判定，全部纯逻辑 + ChatViewModel 接入）。
- [x] 插件/技能动态注册（R18/R19 完成：工具插件 registerPlugin/unregisterPlugin；技能 SkillMeta 注册进 ToolRegistry，list_skills/load_skill 自动发现）。
- [x] Prompt A/B 与 token 预算（R15/R17 完成：`PromptBudget` + `WORK_PROMPT_TOOL_DIRECTORY_MODE` 静态/动态工具目录 A/B 开关）。
- [x] 故障注入测试夹具（R16 完成：`FaultInjector` 确定性场景 + 回归用例）。
- [x] 会话日志查询能力（R14 完成：`SessionLogAggregator` 纯逻辑聚合，支持按工具/turn 统计）。

### 第二轮待办（按审计维度重新生成，R25+）
- [x] 状态机（R25 完成：`WorkLoopStateMachine` 纯逻辑 idle/running/paused/awaiting_user/aborting + ChatViewModel 接入）。
- [x] LoopOrchestrator 全循环纯编排器（R26/R31 完成：`WorkLoopPlanner` 单轮评估 + `WorkLoopSimulator` 全循环步骤机 + 回归矩阵）。
- [x] LLMAdapter 聊天模式统一（R27 完成：`SSEAdapterFactory` 共用工厂，ChatService.processSseData 换用统一流水线，AgentLoopService.buildSseAdapter 委托共用工厂）。
- [x] ToolRegistry 插件 manifest 热加载（R28 完成：`PluginManifestLoader` 解析/apply/unload + 工具名冲突保护）。
- [x] PromptBuilder 技能目录渐进披露 A/B（R29 完成：`SkillDirectoryFormatter` full_index/trigger_only + `WORK_PROMPT_SKILL_DIRECTORY_MODE`）。
- [x] ToolExecutor per-tool 重试/超时策略（R31 完成：`ToolRetryPolicy` + WorkToolRunner.execute 重试循环，复用 `RetryPolicy`）。
- [x] 错误/重试 RetryPolicy（R30 完成：`RetryPolicy` 指数退避 + jitter + retry-after + 可重试 kind 判定，AgentLoopService.runTurnWithRetry 已接入）。
- [x] 日志/可观测延迟分位数（R31 完成：`SessionLogAggregator` 增加 `p50Ms/p90Ms/p99Ms` + `percentile()`）。

### 第三轮待办（按审计维度重新生成，R32+）
- [x] 编排器接入（R22/R26/R31 完成：ChatViewModel 快照/溢出/max_tokens/无效步判定走 `LoopDecisions`，单轮评估走 `WorkLoopPlanner`，全循环回归走 `WorkLoopSimulator`）。
- [x] 插件体系（R35 完成：`PluginHotLoader` 读取 rawfile `plugins/plugin_list.json` 热加载，启动时注册进 ToolRegistry，动态工具目录自动纳入）。
- [x] 可观测（R32 完成：`LoopMetrics` 增加 `retries/compactions/maxTokens` 并随 turn_end 输出）。
- [x] 工具面（R33 完成：`ToolMeta.timeoutMs/maxRetries` + `setRuntimeConfig`，PluginManifestLoader 可声明，WorkToolRunner 按工具级执行）。
- [x] 错误面（R34 完成：`RetryAfterParser` 解析秒/HTTP-date，`LoopError.retryAfterMs` + headersReceive 捕获，`runTurnWithRetry` 传入 `policy.decide`）。

### 第四轮待办（按审计维度重新生成，R36+）
- [x] 编排器（R36 完成：`WorkLoopDriver` 纯驱动——状态机+计划器+重试/压缩/工具批次回调，真实循环只注入 runTurn IO）。
- [x] 插件面（R37 完成：`PluginToolExecutor.register` 声明式注入，未实现插件工具返回“插件工具未实现”）。
- [x] 工具面（R38 完成：`ToolScheduler.schedule` 增加 `allowParallel` 开关，`WORK_ALLOW_PARALLEL_TOOLS` 配置，ChatViewModel 接入）。
- [x] 日志面（R39 完成：turn_start 写协议维度，`SessionLogAggregator.protocolCounts` + `buildToolLatencyEvents`，turn_end 追加 tool_latency 事件）。
- [x] 错误面（R40 完成：`LoopError` 迁纯层，新增 `userMessage/retryable` 显式字段，`runTurnWithRetry` 先判 retryable 再走 RetryPolicy）。

### 第五轮待办（按审计维度重新生成，R41+）
- [x] 编排器（R44/R45 完成接入桥梁：`LoopTurnInfoMapper` + `WorkLoopDriverBridge` + `WORK_USE_DRIVER_LOOP` 开关 + `onStep` 钩子，驱动已具备接管能力）。
- [x] 编排器·接管（R52 完成：`WORK_USE_DRIVER_LOOP=true` 时 `executeWorkLoop` 分派到 `executeWorkLoopDriver`，由 `WorkLoopDriverBridge.runWithStep` 驱动步进/收尾/中止；默认 false 保留旧路径，可回退）。
- [x] 插件面（R41 完成：`PluginHotLoader.reloadAll` 热重载；`WorkToolRunner` 插件 handler 先走 ToolSchemaValidator 参数校验）。
- [x] 日志面（R42 完成：`SessionLogAggregator.aggregateAll` 跨会话合并协议/turn/工具统计与延迟分位）。
- [x] 错误面（R43 完成：ChatViewModel 错误展示优先使用 `LoopError.userMessage`）。

### 第六轮待办（按审计维度重新生成，R53+）
- [x] 编排器·开启（R61 完成：按用户指示 `WORK_USE_DRIVER_LOOP` 默认开启；真机日常观察，如异常改回 `false` 反馈）。
- [x] 日志面（R53 完成：驱动路径 `onStep` 写入 `driver_step` 会话事件）。
- [x] 编排器/日志面（R58 完成：`onStep` 透传 `reason`，`driver_step` 带决策原因）。
- [x] LLMAdapter（R59 完成：`SSEAdapterFactory.supports` 协议白名单）。
- [x] 编排器（R60 完成：`WorkLoopPlanner.describe` 人类可读决策描述）。
- [x] 工具面（R54 完成：`ToolRegistry.defCount()` / `listTools(excluded)` 便捷统计）。
- [x] 可测试性（R57 完成：驱动单步闭包整体抽成 `runDriverStep` 方法，使用 `WorkLoopStepState` 传递状态；R56 的 `WorkLoopStepInfoBuilder` 已纯化信息构造）。
- [x] 错误面（R55 完成：驱动路径沿用 `LoopError.userMessage` 展示，并新增 `driver_summary` 会话事件）。

### 第七轮待办（按审计维度重新生成，R62+）
- [x] 编排器（R62 完成：用户真机实跑 `WORK_USE_DRIVER_LOOP=true` 确认无问题）。
- [x] PromptBuilder（R63 完成：`PromptBudgetSnapshot.overTarget/remaining` 预算辅助）。
- [x] 工具面（R64 完成：`ToolScheduler.summary` + `SchedulerSummary` 并行组统计）。
- [x] 错误/重试（R64 完成：`LoopError.contextOverflowMessage` 默认中文提示）。
- [x] 可测试性（R64 确认：R46/R50 已覆盖驱动路径 compact→tool→finish 等价测试）。

### 第八轮待办（产品功能，R65+，用户指定：工具执行体验 + 会话质量/上下文）
- [ ] 会话质量：上下文超预算时，除剪枝/压缩外，增加“自动摘要历史”模式（保留任务清单与工作区，摘要旧消息）。
- [ ] 会话质量：工具链收尾无最终答案时，自动追加一条“执行结果摘要”请求，避免模型只跑工具不说人话。
- [ ] 工具体验：工具返回 isError 时，自动附加“失败原因 + 建议修正方向”的上下文提示，让模型能自动修复重试。
- [ ] 工具体验：工具结果太长时按协议折叠/截断并提示，避免模型被海量工具输出冲昏头。
- [ ] 会话质量：长任务自动生成阶段性进度摘要（每 N 步写一次 turn_note）。

### 低优先级工程待办（暂缓，不再做纯兜底小工具）
- [ ] 插件/技能：`PluginManifestLoader.validate` 纯校验（之前 R65 计划，暂缓）。
- [ ] 执行器：`WorkToolRunner.isPluginTool` 判定（暂缓）。
- [ ] 日志面：`SessionLogAggregator.driverSummary`（暂缓）。
- [ ] 编排器：`WorkLoopDriver.resultSummary`（暂缓）。
- [ ] 错误/重试：`RetryAfterParser.parseHeader`（暂缓）。


