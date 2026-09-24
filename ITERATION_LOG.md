# ITERATION_LOG

## 2026-09-16 R1: 工具执行超时/取消护栏

### 目标
补齐 Agent Loop 工具执行器的兜底超时与取消响应能力，避免任一工具调用无限期占住主循环/子代理循环。

### 变更
- 新增 `entry/src/main/ets/common/ToolExecutionGuard.ts`：纯逻辑 Promise 护栏，支持任务完成透传、超时返回兜底、取消信号即时返回兜底，并吞掉超时/取消后底层任务的迟到失败。
- `entry/src/main/ets/common/Constants.ts`：新增 `WORK_TOOL_TIMEOUT_MS = 180000`。
- `entry/src/main/ets/service/WorkToolRunner.ets`：
  - `execute()` 新增可选第 5 参 `abortSignal`，保持旧 4 参调用兼容。
  - 原分发逻辑移入私有 `executeInner()`，所有经 `WorkToolRunner.execute` 的工具调用统一套护栏。
  - 新增 `timeoutResult()` / `abortedResult()` 错误结果封装。
- `entry/src/main/ets/service/SubagentService.ts`：子代理工具执行器类型与 `runTool()` 透传子代理取消信号。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：主工作循环的只读并发池与逐工具执行均传入 `this.abortSignal`；`SubagentService.bind` 回调兼容可选取消信号。
- `test/guncat-harness/setup.mjs` / `check-setup.mjs` / `test-core.mjs`：将 `ToolExecutionGuard`、`Types`、`ToolCallRecord` 纳入 Node 可测/类型检查范围，新增 6 条护栏回归用例。

### 验证
- `node test/guncat-harness/setup.mjs && node test/guncat-harness/test-core.mjs`：passed=64 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- 本机未找到 `hvigorw`/`hvigorw.bat`/全局 hvigorw，无法执行 `assembleHap`；已用项目自带服务层类型检查 harness 作为编译级验证。

### 下一项
- 将同一护栏接入聊天模式 `web_fetch`/`search_web` 执行路径，或启动工具 Schema 结构化校验（见 BACKLOG）。

## 2026-09-16 R2: 聊天模式工具执行接入护栏 + 找到 DevEco Studio 并构建 HAP

### 目标
- 把上一轮的超时/取消护栏扩展到聊天模式的本地搜索与网页抓取路径。
- 找到本机 DevEco Studio，完成真实 `assembleHap` 构建验证。

### 变更
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：
  - `runChatStream` 中 `search_web` 与 `web_fetch` 执行均包 `ToolExecutionGuard`。
  - 新增 `searchOutcomeWithError()` / `toolResultError()` 兜底结果工厂。
- `test/guncat-harness` 不涉及新逻辑变更（护栏单测沿用 R1）。

### 构建探索与结果
- 定位 DevEco Studio：`C:\Program Files\Huawei\DevEco Studio`。
- 首次构建失败原因：
  1. 系统 PATH 的 Node v25 与 hvigor 插件不兼容（`options.recursive` 不再支持）→ 改用 DevEco 自带 Node `tools\node\node.exe`。
  2. `@luvi/lv-markdown-in` 未安装 → 用 DevEco 自带 `ohpm install --all` 安装依赖。
- 最终验证命令：
  - `$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'`
  - `& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' assembleHap --no-daemon --mode module -p product=default`
- 结果：`BUILD SUCCESSFUL in 30 s 914 ms`。
- 产出：`entry/build/default/outputs/default/entry-default-signed.hap`（70,573,535 bytes）。
- 同时 `node test/guncat-harness/test-core.mjs`：passed=64 failed=0。

### 下一项
- 继续 BACKLOG：ToolDefinition / JSON Schema 统一与结构化校验（修正 `list_files` 等 required 与实际可选语义不一致的 schema）。

## 2026-09-16 R3: ToolDefinition / JSON Schema 统一与结构化校验

### 目标
- 建立统一的工具参数 schema 校验入口，降低参数 schema 错误率。
- 修正工具定义中 required 与实际可选语义不一致的问题（`list_files`）。

### 变更
- 新增 `entry/src/main/ets/common/ToolSchemaValidator.ts`：纯逻辑 schema 校验器，校验 required 与宽容类型（string 接受 number、number 接受数字字符串、boolean 接受 'true'/'false'、未知字段不拒绝、数组/对象参数交由具体工具继续解析）。
- `entry/src/main/ets/service/WorkFileService.ts`：
  - 新增 `findToolDef(name)` 与 `toolDefMap` 缓存。
  - 修正 `list_files` 的 `required` 从 `['path']` 改为 `[]`（path 实际可省略）。
- `entry/src/main/ets/service/WorkToolRunner.ets`：`executeInner` 分发前按工具定义执行结构化参数校验，非法参数直接返回 ERROR，不再进入具体工具实现。
- `test/guncat-harness`：纳入 `ToolSchemaValidator`，新增 9 条回归用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=73 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL in 19 s 387 ms`，产出 `entry/build/default/outputs/default/entry-default-signed.hap`（70,589,716 bytes）。

### 下一项
- 继续 BACKLOG：ToolRegistry（命名空间/版本/动态工具目录注入/权限过滤），或先做 AgentLoopService 并发安全修复。

## 2026-09-16 R4: AgentLoopService 活跃请求并发安全

### 目标
- 修复 `AgentLoopService.activeRequest` 单一静态引用在并发请求（主循环 + 子代理/聊天模式）下 `abort()` 可能打错目标的问题。

### 变更
- `entry/src/main/ets/service/AgentLoopService.ts`：
  - `activeRequest` 改为 `activeRequests: http.HttpRequest[]` 注册表。
  - `runTurn` 创建请求时 `push`，`finally` 中按实例移除。
  - `abort()` 遍历销毁所有活跃请求并清空注册表，公开签名保持不变。

### 验证
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`，产出 `entry/build/default/outputs/default/entry-default-signed.hap`。

### 下一项
- 继续 BACKLOG：ToolRegistry（命名空间/版本/动态工具目录注入/权限过滤），或可观测性（tool_result 补充 timeout/cancel 标记与 trace 字段）。

## 2026-09-16 R5: 工具结果可观测标记（timeout/cancelled）

### 目标
- 为审计工具超时率/取消率补充结构化标记：护栏产生的超时/取消结果不再只靠错误文案判断。

### 变更
- `entry/src/main/ets/service/WorkFileService.ts`：`ToolExecResult` 新增 `timeout`/`cancelled` 字段。
- `entry/src/main/ets/model/ToolCallRecord.ts`：新增 `timeout`/`cancelled` 字段并纳入 `toJson`/`fromJson`（兼容旧记录缺字段默认 false）。
- `entry/src/main/ets/service/WorkToolRunner.ets`：`timeoutResult()`/`abortedResult()` 设置对应标记。
- `entry/src/main/ets/service/LocalWebSearch.ts`：`LocalSearchOutcome` 新增 `timeout`/`cancelled`。
- `entry/src/main/ets/service/SubagentService.ts`：子代理工具结果与中断记录复制标记。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：`applyToolResult` 复制标记；`tool_result` 会话事件新增 `timeout`/`cancelled` 字段；聊天模式 `web_fetch`/`search_web` 兜底结果与中断记录也写入标记。
- `test/guncat-harness/test-core.mjs`：新增 `ToolCallRecord` 标记序列化往返回归。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=76 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 继续 BACKLOG：ToolRegistry（命名空间/版本/动态工具目录注入/权限过滤），或 PromptBuilder 分块与评估。

## 2026-09-16 R6: ToolRegistry 工具注册中心（第一版）

### 目标
- 建立统一的工具注册中心，为动态工具目录注入、权限过滤、子代理工具面裁剪提供单一事实源，替代散落的 `findToolDef` 与硬编码分类判断。

### 变更
- 新增 `entry/src/main/ets/common/ToolRegistry.ts`：
  - `ToolMeta`（namespace/version/readOnly/mutating/permissions/category）。
  - `ToolRegistry.sync/ensure/findDef/findMeta/isReadOnly/isMutating/defs/names/defsByPermission/setPermissions/clear`。
  - 权限语义：未设置权限的工具对所有调用方开放；设置权限后按“任一权限命中”过滤。
- `entry/src/main/ets/service/WorkFileService.ts`：
  - `findToolDef` 改走 `ToolRegistry`。
  - `isReadOnlyTool`/`isMutatingTool` 改走 `ToolRegistry`。
  - 原 `toolDefMap` 标记 `@deprecated` 保留兼容。
  - 新增 `ensureToolRegistry()` 与分类名单辅助方法。
- `test/guncat-harness`：纳入 `ToolRegistry`，新增 10 条回归用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=87 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 让 `SubagentService`/动态插件使用 `ToolRegistry` 的权限/命名空间过滤，替代硬编码 `excludedTools()`；随后开始 PromptBuilder 分块与评估。

## 2026-09-16 R7: Subagent 工具面走 ToolRegistry

### 目标
- 让子代理工具面裁剪不再直接遍历 `toolDefs(false)`，改用注册中心统一过滤。

### 变更
- `entry/src/main/ets/service/WorkFileService.ts`：新增公开 `toolRegistrySynced()`。
- `entry/src/main/ets/service/SubagentService.ts`：`filteredToolDefs()` 改走 `ToolRegistry.names(excluded)` + `findDef`，移除对 `toolDefs(false)` 的直接遍历（原排除名单 `excludedTools()` 保留）。

### 验证
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- PromptBuilder 分块与评估：把 `buildWorkSystemPrompt()` 拆成可独立测试的块，并为工具调用正确率/参数 schema 错误率/无效循环步数建立回归指标。

## 2026-09-16 R8: PromptBuilder 分块构建器

### 目标
- 满足提示词优化要求：把 System Prompt 拆成可独立测试的块（身份/工作区/工具目录/方法论/工作流/压缩/输出/Mermaid/反幻觉/安全/能力边界/交付自检），并保留旧实现用于 A/B 对照。

### 变更
- 新增 `entry/src/main/ets/common/PromptBuilder.ts`：12 个分块方法 + `build(skillsSection)` 组装入口。
- `entry/src/main/ets/service/AgentLoopService.ts`：
  - `buildWorkSystemPrompt()` 改为委托 `PromptBuilder.build(WorkSkillService.promptSection())`，缓存语义不变。
  - 旧实现保留为 `buildWorkSystemPromptLegacy()` 并标记 `@deprecated`，供 A/B 回归对照。
- `test/guncat-harness`：纳入 `PromptBuilder`，新增 14 条分块回归用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=101 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- PromptBuilder 动态工具目录：用 `ToolRegistry.defs()` 自动生成/校验工具目录块，与静态手写目录做 A/B；随后加入工具调用正确率/参数 schema 错误率评估埋点。

## 2026-09-16 R9: PromptBuilder 动态工具目录注入

### 目标
- 让新增/插件工具无需改手写清单即可自动进入 System Prompt，保证工具面永远对模型可见。

### 变更
- `entry/src/main/ets/common/PromptBuilder.ts`：
  - 新增 `buildToolDirectory(defs)` / `missingToolNames(staticText, defs)` / `defsByNames(defs, names)`。
  - `build(skillsSection, extraToolsSection?)` 支持注入自动工具目录。
- `entry/src/main/ets/service/AgentLoopService.ts`：`buildWorkSystemPrompt()` 计算静态清单未覆盖的工具并自动追加动态目录。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=104 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LoopMetrics 评估指标：工具调用正确率 / 参数 schema 错误率 / 超时率 / 取消率 / 无效循环步数，随 turn_end 写入会话日志。

## 2026-09-16 R10: LoopMetrics 评估指标 + schemaError 结构化标记

### 目标
- 建立可回归的 Agent Loop 质量指标：工具调用成功率 / schema 错误率 / 超时率 / 取消率 / 无效步率，随 turn_end 写入会话日志。

### 变更
- 新增 `entry/src/main/ets/common/LoopMetrics.ts`：`LoopMetrics` + `LoopMetricsSnapshot`，提供 `recordTurn`/`recordToolCall`/`recordSubagentCall`/`recordSchemaError`/`snapshot`/`reset`。
- `entry/src/main/ets/model/ToolCallRecord.ts`：新增 `schemaError` 字段并纳入 `toJson`/`fromJson`。
- `entry/src/main/ets/service/WorkFileService.ts`：`ToolExecResult` 新增 `schemaError`。
- `entry/src/main/ets/service/WorkToolRunner.ets`：schema 校验失败与 JSON 参数非法统一打 `schemaError=true`。
- `entry/src/main/ets/service/SubagentService.ts`：子代理内部工具调用复制 `schemaError`。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：
  - `executeWorkLoop` 建立 `LoopMetrics`，逐轮记录 turn/工具结果/子代理调用。
  - `tool_result` 会话事件新增 `schemaError` 字段。
  - `turn_end` 事件携带完整 `metrics` 快照（正常/错误路径均写入）。
- `test/guncat-harness`：纳入 `LoopMetrics`，新增 10 条回归用例；`ToolCallRecord` 补 schemaError 往返断言。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=114 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 工具取消深度化：把 abortSignal 透传进 `download_file`/`web_fetch` 的 HTTP 请求与 `subagent` 内部循环，尽量真正中断而不是仅放弃等待。

## 2026-09-16 R11: 工具 HTTP 深度取消

### 目标
- 用户点“停止”时，真正销毁在途的 `download_file` / `web_fetch` HTTP 请求（而不是仅靠护栏放弃等待），释放底层连接。

### 变更
- `entry/src/main/ets/service/WorkToolRunner.ets`：新增静态工具 HTTP 注册表 `toolRequests` + `abortToolRequests()`；`download_file` 的请求注册/注销。
- `entry/src/main/ets/service/WebFetchService.ts`：新增同类注册表 + `abortToolRequests()`；`web_fetch` 请求注册/注销。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：`stopStreaming()` 在 `AgentLoopService.abort()` 之后调用 `WorkToolRunner.abortToolRequests()` 与 `WebFetchService.abortToolRequests()`。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=114 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- tool_result 请求级 trace 字段：为每次工具调用生成 traceId/会话内序号，写入 tool_result 事件，便于跨会话归因统计。

## 2026-09-16 R12: tool_result 请求级 traceId

### 目标
- 为每次工具调用提供跨会话归因标识，完善工具成功率/超时率统计链路。

### 变更
- `entry/src/main/ets/model/ToolCallRecord.ts`：新增 `traceId` 字段并纳入 `toJson`/`fromJson`（兼容旧记录缺省空串）。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：`executeWorkLoop` 内维护 `traceSeq`；每次工具执行后若记录无 traceId 则生成 `call-N`；`tool_result` 会话事件新增 `traceId` 字段。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=115 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- BACKLOG 已清空，按审计维度重新生成：插件/技能动态注册、LLMAdapter 统一、LoopOrchestrator 编排抽象、Prompt A/B 与 token 预算、故障注入测试。

## 2026-09-16 R13: ToolScheduler 调度决策抽取 + ChatViewModel 接入

### 目标
- 为 LoopOrchestrator 铺路：把“连续只读并发池 / 非只读独占”的调度规则抽成纯逻辑模块，并让主循环真正使用它。

### 变更
- 新增 `entry/src/main/ets/common/ToolScheduler.ts`：`ScheduledGroup` + `schedule(readOnlyFlags, maxParallel)` + `poolSize(group, maxParallel)`。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：`executeWorkLoop` 工具轮改为先用 `ToolScheduler.schedule` 计算分组，再按 `group.parallel` 执行只读组（滚动池）或单工具独占；行为与旧实现一致。
- `test/guncat-harness`：纳入 `ToolScheduler`，新增 7 条调度回归用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=122 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LoopOrchestrator 编排抽象：在 ToolScheduler 基础上继续抽取溢出重试/上下文压缩/快照追加的可单测纯决策层。

## 2026-09-16 R14: SessionLogAggregator 会话日志聚合

### 目标
- 为诊断/回归提供纯逻辑的会话日志聚合：按工具聚合成功率/超时/取消/schema 错误，按 turn 汇总状态分布。

### 变更
- 新增 `entry/src/main/ets/common/SessionLogAggregator.ts`：`ToolCallAgg` + `SessionLogSummary` + `SessionLogAggregator.aggregateToolCalls/summarize`。
- `test/guncat-harness`：纳入 `SessionLogAggregator`，新增 5 条聚合回归用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=127 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LLMAdapter 统一：三协议收敛为统一 Adapter 接口（或先做 Prompt token 预算/故障注入夹具）。

## 2026-09-16 R15: PromptBudget token 预算估算

### 目标
- 为 Prompt A/B 提供 token 成本度量：按块估算 System Prompt 字符与 token，随 turn_start 写入会话日志。

### 变更
- 新增 `entry/src/main/ets/common/PromptBudget.ts`：`estimateTokens`（CJK 1 字≈1 token，英文 4 字符≈1 token）+ `fromSections`/`fromPrompt`。
- `entry/src/main/ets/service/AgentLoopService.ts`：新增 `lastPromptBudget` 静态字段，`buildWorkSystemPrompt()` 构建后记录预算。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：`turn_start` 事件在预算可用时附加 `promptBudget`。
- `test/guncat-harness`：纳入 `PromptBudget`，新增 5 条估算用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=132 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- Prompt A/B：静态手写工具目录 vs 动态生成目录的开关 + 质量对比（结合 LoopMetrics/PromptBudget）。

## 2026-09-16 R16: FaultInjector 故障注入回归夹具

### 目标
- 为超时/取消/schema 错误/普通失败建立确定性场景，供执行器/编排器/评估链路做回归矩阵。

### 变更
- 新增 `entry/src/main/ets/common/FaultInjector.ts`：`FaultOutcome`/`FaultSpec` + `execute(specs, index)` + 内置场景 `happy/one_timeout/one_schema_error/one_cancel/all_fail`。
- `test/guncat-harness`：纳入 `FaultInjector`，新增 6 条场景回归用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=138 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 把 FaultInjector 接入 LoopOrchestrator/执行器回归矩阵（纯逻辑层），或继续 LLMAdapter 统一。

## 2026-09-16 R17: Prompt 工具目录 A/B 模式

### 目标
- 提供静态手写目录 + 动态补充 / 纯动态目录的可配置 A/B 开关，配合 PromptBudget 与 LoopMetrics 做质量对比。

### 变更
- `entry/src/main/ets/common/PromptBuilder.ts`：新增 `buildWithToolDirectoryMode(skillsSection, staticDir, extraToolsSection, mode)`；`build()` 委托默认 `static_plus_dynamic`。
- `entry/src/main/ets/common/Constants.ts`：新增 `WORK_PROMPT_TOOL_DIRECTORY_MODE`（默认 `static_plus_dynamic`）。
- `entry/src/main/ets/service/AgentLoopService.ts`：`buildWorkSystemPrompt()` 按模式组装——`dynamic_only` 时用 ToolRegistry 全量自动目录替代静态手写目录。
- `test/guncat-harness`：新增 A/B 模式 2 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=140 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 插件/技能动态注册：ToolRegistry 运行期 register(namespace) 注入插件工具 + 技能作为首类插件。

## 2026-09-16 R18: ToolRegistry 插件工具动态注册

### 目标
- 支持运行期注入/热更新/禁用插件工具，并让 Schema 校验、子代理工具面、PromptBuilder 动态目录自动承接。

### 变更
- `entry/src/main/ets/common/ToolRegistry.ts`：新增 `registerPlugin(namespace, defs, readOnly, mutating, version?, permissions?, category?)`、`unregisterPlugin(namespace)`、`pluginNamespaces()`、`pluginDefs()`。
- `entry/src/main/ets/service/WorkFileService.ts`：新增 `toolRegistryDefs()`（静态核心 + 插件统一返回）。
- `entry/src/main/ets/service/AgentLoopService.ts`：`buildWorkSystemPrompt()` 改用 `toolRegistryDefs()`，插件工具自动进入动态目录（若未在手写静态清单中）。
- `test/guncat-harness`：新增 6 条插件注册/注销/命名空间用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=145 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 技能作为首类插件：把技能元数据（id/description/file）注册进 ToolRegistry（namespace=skill），list_skills/load_skill 自动发现。

## 2026-09-16 R19: 技能作为首类插件注册进 ToolRegistry

### 目标
- 技能元数据进入统一注册中心，list_skills / load_skill 改从注册中心读取，支持运行期增删技能。

### 变更
- `entry/src/main/ets/common/ToolRegistry.ts`：新增 `SkillMeta`/`SkillFileMeta` + `registerSkill`/`unregisterSkill`/`findSkill`/`skillList`/`skillIds`；`clear()` 同步清空技能。
- `entry/src/main/ets/service/WorkSkillService.ts`：`ensureToolSkills()` 将内置技能注册进 ToolRegistry；`listText()`/`promptSection()`/`load()` 改读 `ToolRegistry.skillList()/findSkill()/skillIds()`。
- `test/guncat-harness`：新增 4 条技能注册/注销用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=148 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LLMAdapter 统一：三协议收敛为统一 Adapter 接口。

## 2026-09-16 R20: LLMProtocol 统一协议/端点单一事实源

### 目标
- LLMAdapter 第一步：把 provider→协议映射与端点解析收敛到纯逻辑单一事实源，工作模式与聊天模式共用。

### 变更
- 新增 `entry/src/main/ets/common/LLMProtocol.ts`：`pick(provider)`、`resolveEndpoint(baseUrl, protocol, autoSuffix)`、`displayName(protocol)`。
- `entry/src/main/ets/service/AgentLoopService.ts`：改用 `LLMProtocol.pick/resolveEndpoint`。
- `entry/src/main/ets/service/ChatService.ts`：`getProtocol`/`resolveEndpointUrl` 保留为兼容包装，内部委托 `LLMProtocol`。
- `test/guncat-harness`：纳入 `LLMProtocol`，新增 7 条映射/端点用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=155 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LLMAdapter 继续：请求体构建/SSE 解析按协议适配器接口收敛，收敛 AgentLoopService 内的大 if/switch。

## 2026-09-16 R21: RepeatDetector 重复调用检测纯逻辑化

### 目标
- 把无效循环防护（连续同工具同参数调用提醒）抽成可单测纯模块，ChatViewModel 只做桥接。

### 变更
- 新增 `entry/src/main/ets/common/RepeatDetector.ts`：`RepeatOutcome` + `record(name, argsJson)`（第 3/5/8 次提醒）+ `reset()`。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：新增 `workRepeatDetector` 字段，`executeWorkLoop` 开始时 reset，`noteWorkRepeat()` 改走纯模块；旧 `workRepeatKey/workRepeatCount` 标记 `@deprecated` 保留。
- `test/guncat-harness`：纳入 `RepeatDetector`，新增 5 条重复检测用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=160 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LoopOrchestrator 继续：溢出重试 / 上下文压缩 / 快照追加的纯决策层。

## 2026-09-16 R22: LoopDecisions 循环纯决策层

### 目标
- 把快照去重 / 溢出强制压缩 / max_tokens 收尾 / 无效步判定收敛为纯函数，ChatViewModel 直接使用。

### 变更
- 新增 `entry/src/main/ets/common/LoopDecisions.ts`：`shouldAppendSnapshot` / `shouldForceCompactOnOverflow` / `shouldBreakOnMaxTokens` / `isInvalidStep`。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：
  - `appendRuntimeSnapshotIfNeeded` 用 `shouldAppendSnapshot`
  - `runStepWithOverflowRetry` 用 `shouldForceCompactOnOverflow`
  - `max_tokens` 收尾用 `shouldBreakOnMaxTokens`
- `test/guncat-harness`：纳入 `LoopDecisions`，新增 8 条决策用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=168 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LLMAdapter SSE/请求体 Adapter 化（最后一项核心大项）。

## 2026-09-16 R23: ToolDefAdapter 三协议工具形态单一事实源

### 目标
- LLMAdapter 第二步：把工作模式请求体里的工具形态映射从 AgentLoopService 私有方法收敛为纯逻辑模块。

### 变更
- 新增 `entry/src/main/ets/common/ToolDefAdapter.ts`：`completionsTools` / `responsesTools` / `anthropicTools` / `adapt`。
- `entry/src/main/ets/service/AgentLoopService.ts`：三个请求体构建点改用 `ToolDefAdapter`；原私有方法标记 `@deprecated` 保留。
- `test/guncat-harness`：纳入 `ToolDefAdapter`，新增 3 条三协议形态用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=171 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LLMAdapter SSE 解析器 Adapter 化：把 handleSseLine 内三协议分支收敛为可单测的协议解析器接口。

## 2026-09-16 R24: SSEProtocolAdapter 协议解析器接口

### 目标
- LLMAdapter 最后一块：把 AgentLoopService.handleSseLine 里的三协议大 if/switch 收敛为可单测的统一流水线 + 协议适配器。

### 变更
- 新增 `entry/src/main/ets/common/SSEProtocolAdapter.ts`：`SSEProtocolAdapter` + `SSEParseContext`；`handleLine` 按“失败→文本→思考→签名→redacted→usage→工具→finish”统一派发。
- `entry/src/main/ets/service/AgentLoopService.ts`：
  - 新增 `buildSseAdapter(protocol, callAcc)`，按协议注入 ChatService 解析器与 ToolCallStream 收集器
  - `handleSseLine` 删除大 if/switch，改为 `SSEParseContext` 回调 + `adapter.handleLine`
- `test/guncat-harness`：纳入 `SSEProtocolAdapter`，新增 5 条流水线/失败优先用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=176 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- BACKLOG 已清空：按审计维度重新生成下一批迭代项。

## 2026-09-16 R25: WorkLoopStateMachine 工作模式显式状态机

### 目标
- 第二轮首项：把工作循环生命周期收敛为纯状态机，ChatViewModel 只在入口/收尾桥接。

### 变更
- 新增 `entry/src/main/ets/common/WorkLoopStateMachine.ts`：`WorkLoopState`（idle/running/paused/awaiting_user/aborting）+ `WorkLoopStateMachine`（start/pause/resume/awaitUser/userAnswered/abort/aborted/finish/fail + can/current/reset）。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：新增 `workStateMachine` 字段；`executeWorkLoop` 入口 `reset+start`，finally 中按 `abortSignal.aborted` 走 `abort→aborted` 或 `finish`。
- `test/guncat-harness`：纳入 `WorkLoopStateMachine`，新增 12 条状态/非法转移/abort/fail 用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=188 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopOrchestrator：把 ChatViewModel 循环主体收敛为纯编排器（run→tool→evaluate→finish + FaultInjector 全循环回归）。

## 2026-09-16 R26: WorkLoopPlanner 单轮评估纯决策层

### 目标
- LoopOrchestrator 第一步：把“单轮结果→下一步动作”的评估逻辑收敛为纯决策模块并接入真实循环。

### 变更
- 新增 `entry/src/main/ets/common/WorkLoopPlanner.ts`：`WorkLoopStep`（tool/text/finish/abort/compact）+ `WorkLoopTurnInfo` + `decide()`（优先级：中止→达步数→工具→溢出→文本/结束→无输出收尾）。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：`executeWorkLoop` 里“无工具调用即收尾”分支改为 `WorkLoopPlanner.decide()` 驱动。
- `test/guncat-harness`：纳入 `WorkLoopPlanner`，新增 6 条决策用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=194 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LoopOrchestrator 继续：把循环主体（run→tool→evaluate→finish）收敛为纯 `WorkLoopOrchestrator`，并接 FaultInjector 全循环回归矩阵。

## 2026-09-16 R27: 聊天模式 ChatService 换用统一 SSE 流水线

### 目标
- 让聊天模式与工作模式共用同一套协议 SSE 适配器，彻底消灭 ChatService 内的大 if/switch。

### 变更
- 新增 `entry/src/main/ets/service/SSEAdapterFactory.ts`：工作/聊天共用的 `build(protocol, callAcc, finishExtractor?)`。
- `entry/src/main/ets/service/AgentLoopService.ts`：`buildSseAdapter` 改为委托 `SSEAdapterFactory.build`（标记 `@deprecated` 保留）。
- `entry/src/main/ets/service/ChatService.ts`：`processSseData` 改用 `SSEAdapterFactory.build` + `SSEParseContext`，删除三协议大 if/switch。
- `test/guncat-harness/check-setup.mjs`：纳入 `SSEAdapterFactory` 类型检查。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=194 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- ToolRegistry 插件 manifest 热加载。

## 2026-09-16 R28: PluginManifestLoader 插件 manifest 热加载

### 目标
- 让插件以 JSON manifest 声明式注册工具/技能，支持热更新与卸载，并防工具名冲突覆盖核心。

### 变更
- 新增 `entry/src/main/ets/common/PluginManifestLoader.ts`：
  - `PluginToolManifest` / `PluginManifest` / `PluginManifestResult`
  - `parse(json)`：解析并校验 id/tools/skills
  - `apply(manifest)`：幂等注册插件工具 + 技能；工具名与核心/他插件冲突时跳过并返回 conflicts
  - `unload(manifest)`：移除该插件全部工具与技能
- `test/guncat-harness`：纳入 `PluginManifestLoader`，新增 7 条解析/注册/冲突/卸载用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=201 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- PromptBuilder 技能目录渐进披露 A/B。

## 2026-09-16 R29: 技能目录渐进披露 A/B

### 目标
- 给技能目录提供 full_index（完整清单进提示词）与 trigger_only（只留触发提示，list_skills 自行发现）两种可配置模式，配合 PromptBudget 对比。

### 变更
- 新增 `entry/src/main/ets/common/SkillDirectoryFormatter.ts`：`listText` / `fullIndex` / `triggerOnly` / `format(list, mode)`。
- `entry/src/main/ets/common/Constants.ts`：新增 `WORK_PROMPT_SKILL_DIRECTORY_MODE`（默认 `full_index`）。
- `entry/src/main/ets/service/WorkSkillService.ts`：`listText`/`promptSection` 委托纯模块；新增 `promptSectionWithMode(mode)`；`promptSection` 标记 `@deprecated` 保留。
- `entry/src/main/ets/service/AgentLoopService.ts`：`buildWorkSystemPrompt()` 使用 `promptSectionWithMode(Constants.WORK_PROMPT_SKILL_DIRECTORY_MODE)`。
- `test/guncat-harness`：纳入 `SkillDirectoryFormatter`，新增 3 条目录模式用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=204 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- ToolExecutor per-tool 重试/超时策略。

## 2026-09-16 R30: RetryPolicy 请求级自动重试纯决策

### 目标
- 把 429/5xx/网络/空响应的重试判定与退避收敛为纯逻辑，AgentLoopService 直接使用。

### 变更
- 新增 `entry/src/main/ets/common/RetryPolicy.ts`：`RetryDecision` + `RetryPolicy`（maxRetries/baseDelay/maxDelay/jitterRatio/retryableKinds + `decide(kind, attempt, retryAfterMs, seed)`）。
- `entry/src/main/ets/service/AgentLoopService.ts`：
  - `runTurnWithRetry` 改用 `RetryPolicy.decide` 判定是否重试
  - 新增 `retryBackoffMs(delayMs)` 按策略延迟分片睡眠；旧 `retryBackoff` 标记 `@deprecated` 保留
- `test/guncat-harness`：纳入 `RetryPolicy`，新增 8 条退避/jitter/retry-after/不可重试/上限用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=212 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- ToolExecutor per-tool 重试/超时策略（可配置 maxRetries/backoff/jitter，复用 RetryPolicy）。

## 2026-09-16 R31: 收尾三项——工具级重试、全循环模拟器、延迟分位数

### 目标
- 一次性清空 BACKLOG 第二轮/第三轮剩余项：per-tool 重试、LoopOrchestrator 全循环回归矩阵、SessionLogAggregator 延迟分位数。

### 变更
- 新增 `common/ToolRetryPolicy.ts`：网络类工具（web_fetch/download_file/subagent）瞬时失败/超时少量重试，复用 `RetryPolicy` 退避；schemaError/cancelled/成功不重试。
- `service/WorkToolRunner.ets`：`execute` 改为带重试循环 + `sleep`；`!result.ok || timeout` 时按策略退避。
- 新增 `common/WorkLoopSimulator.ts`：`WorkLoopSimulator.run(turnProvider, maxSteps)` 用 `WorkLoopPlanner` 驱动全循环，产出 steps/toolSteps/textSteps/compactSteps/aborted/finalReason（run→tool→evaluate→finish 步骤机 + 回归矩阵）。
- `common/SessionLogAggregator.ts`：`ToolCallAgg` 增加 `p50Ms/p90Ms/p99Ms`；`aggregateToolCalls` 收集耗时并按 `percentile()` 计算分位数。
- `test/guncat-harness`：纳入 `ToolRetryPolicy`（5 条）与 `WorkLoopSimulator`（4 条），并补 `SessionLogAggregator` 分位用例（3 条）。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=224 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- BACKLOG 已清空：按审计维度生成第三轮待办。

## 2026-09-16 R32: LoopMetrics 增加重试/压缩/max_tokens 计数

### 目标
- 让 turn_end 的指标能反映重试、上下文压缩与 max_tokens 收尾，完善可观测性。

### 变更
- `entry/src/main/ets/common/LoopMetrics.ts`：`LoopMetricsSnapshot` 与内部计数新增 `retries/compactions/maxTokens`；新增 `recordRetry()/recordCompaction()/recordMaxTokens()`。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：
  - `callbacks.onRetry` 记 `recordRetry()`
  - 常规/强制压缩路径记 `recordCompaction()`
  - max_tokens 收尾分支记 `recordMaxTokens()`
- `test/guncat-harness`：LoopMetrics 用例补 1 条综合计数断言。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=225 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 插件 manifest rawfile 热加载入口（读 `plugins/*/manifest.json` → `PluginManifestLoader.apply`）。

## 2026-09-16 R33: per-tool 超时/重试配置并入 ToolMeta

### 目标
- 让插件/核心工具可声明各自的 timeoutMs/maxRetries，执行器按工具级配置运行。

### 变更
- `common/ToolRegistry.ts`：`ToolMeta` 新增 `timeoutMs`（0=全局默认）与 `maxRetries`（-1=策略默认）；新增 `setRuntimeConfig(name, timeoutMs, maxRetries)`。
- `common/PluginManifestLoader.ts`：`PluginToolManifest` 支持 `timeoutMs/maxRetries`，apply 时写入 `ToolRegistry.setRuntimeConfig`。
- `common/ToolRetryPolicy.ts`：新增 `setMaxRetries(name, n)` 与 per-tool override。
- `common/RetryPolicy.ts`：`decide` 增加可选 `maxRetriesOverride` 参数（兼容旧签名）。
- `service/WorkToolRunner.ets`：`execute` 按 `ToolMeta` 读取工具级超时/最大重试，覆盖全局默认。
- `test/guncat-harness`：补 ToolMeta runtime config、ToolRetryPolicy override、PluginManifestLoader 配置解析用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=229 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LoopError Retry-After 解析接入 RetryPolicy。

## 2026-09-16 R34: Retry-After 头解析接入重试策略

### 目标
- 让 429 等限流响应的 `Retry-After` 头被尊重，替代纯退避猜测。

### 变更
- 新增 `common/RetryAfterParser.ts`：解析秒数与 HTTP-date 两种形态，返回建议延迟 ms（无效返回 -1）。
- `service/AgentLoopService.ts`：
  - `LoopError` 新增 `retryAfterMs` 字段与可选构造参数（兼容旧签名）
  - 通过 `httpRequest.on('headersReceive')` 捕获 `retry-after`（平台不支持时降级默认退避）
  - 非 2xx 分支用 `RetryAfterParser.parseMs` 写入 LoopError
  - `runTurnWithRetry` 的 `policy.decide` 传入 `failed.retryAfterMs`
- `test/guncat-harness`：新增 `RetryAfterParser` 5 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=234 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 插件 manifest rawfile 热加载入口。

## 2026-09-16 R35: 插件 manifest rawfile 热加载入口

### 目标
- 让 rawfile 内打包的插件 manifest 能在启动时自动注册进 ToolRegistry，并自动进入 PromptBuilder 动态工具目录。

### 变更
- 新增 `service/PluginHotLoader.ts`：读取 `rawfile/plugins/plugin_list.json` 清单，逐个 `PluginManifestLoader.parse/apply` 注册；`unloadAll()` 幂等卸载；单个插件失败不影响其他。
- `viewmodel/ChatViewModel.ts/.ets`：初始化时 `await PluginHotLoader.loadAll(this.context)`，使插件在进入工作模式前就绪；注册后的插件工具经 `ToolRegistry.defs('')` 自动进入 PromptBuilder 动态目录。
- 新增 rawfile 资源：`plugins/plugin_list.json`（空清单）+ `plugins/README.md`（插件接入说明）。
- `test/guncat-harness`：check-setup 纳入 `PluginHotLoader.ts` 类型检查。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=234 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- BACKLOG 已清空：按审计维度生成第四轮待办。

## 2026-09-16 R36: WorkLoopDriver 循环主体提纯

### 目标
- 把“状态机 + 单轮计划器 + 重试 + 压缩/工具批次回调”收进可单测的纯驱动，真实循环只注入 runTurn(IO)。

### 变更
- 新增 `common/WorkLoopDriver.ts`：
  - `WorkLoopDriver.run(hooks, config)`：用 `WorkLoopStateMachine` + `WorkLoopPlanner` + `RetryPolicy` 驱动全循环
  - hooks：`runTurn`（IO 注入）、`onRetry`、`onCompact`、`onToolBatch`
  - 输出 `steps/toolSteps/textSteps/compactSteps/retries/aborted/finalReason/finalState`
  - runTurn 抛错按 kind 判定重试（纯层以 `err.kind` 读取，缺省 transport）
- `test/guncat-harness`：纳入 `WorkLoopDriver`，新增 happy/重试回调/压缩回调 3 组用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=237 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 插件声明式工具实现注册（`PluginToolExecutor.register`）。

## 2026-09-16 R37: 插件声明式工具实现注册

### 目标
- 插件 manifest 只声明元数据；实现由宿主代码通过 `PluginToolExecutor.register(name, handler)` 注入，未实现插件工具返回明确提示而非“未知工具”。

### 变更
- 新增 `common/PluginToolExecutor.ts`：`PluginToolResult` + `PluginToolHandler` + 注册/注销/查询/执行/清空。
- `service/WorkToolRunner.ets`：
  - 插件工具（namespace ≠ core）未注册 handler 时直接返回 `插件工具未实现: <name>`
  - 已注册 handler 经统一超时/取消/重试护栏执行
  - 新增 `buildTask/runPluginHandler/toToolResult/pluginNotImplementedResult`
- `test/guncat-harness`：纳入 `PluginToolExecutor`，新增注册/执行/注销/未注册 null 6 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=243 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- ToolScheduler 并行配置化开关。

## 2026-09-16 R38: ToolScheduler 并行配置化开关

### 目标
- 让“同批工具全部只读才并行”可配置：关闭并行时全部按单工具顺序执行。

### 变更
- `common/ToolScheduler.ts`：`schedule(readOnlyFlags, maxParallel, allowParallel=true)` 新增开关；`allowParallel=false` 时只读组不再聚合，全部单工具组。
- `common/Constants.ts`：新增 `WORK_ALLOW_PARALLEL_TOOLS`（默认 true）。
- `viewmodel/ChatViewModel.ets`：调度调用传入 `Constants.WORK_ALLOW_PARALLEL_TOOLS`。
- `test/guncat-harness`：ToolScheduler 补禁并行 2 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=245 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- SessionLogService 协议维度与工具延迟分位事件。

## 2026-09-16 R39: 会话日志协议维度 + 工具延迟分位数事件

### 目标
- 让会话日志可按协议维度统计，并输出按工具的 p50/p90/p99 延迟事件。

### 变更
- `service/AgentLoopService.ts`：新增 `lastProtocol` 静态字段，`runTurn` 选协议时记录。
- `viewmodel/ChatViewModel.ets`：
  - `turn_start` payload 写入 `protocol`
  - 收集本 turn 的 `tool_result` 事件
  - `turn_end` 后追加 `tool_latency` 事件（每工具 p50/p90/p99/calls）
- `common/SessionLogAggregator.ts`：
  - `SessionLogSummary` 新增 `protocolCounts`
  - `summarize` 统计 turn_start 的 `protocol`
  - 新增 `buildToolLatencyEvents()` 由 tool_result 生成延迟分位事件
- `test/guncat-harness`：补协议计数 + 延迟事件 2 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=247 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- LoopError 显式 retryable/userMessage。

## 2026-09-16 R40: LoopError 显式 retryable/userMessage（迁移纯层）

### 目标
- “是否重试”从 kind 推断改为显式 `retryable` 字段，并支持面向用户的 `userMessage`；LoopError 迁到纯层可单测。

### 变更
- 新增 `common/LoopError.ts`（纯逻辑）：
  - 字段 `status/kind/retryAfterMs/userMessage/retryable`
  - 构造默认 `retryable` 按 kind 推断（rate_limit/server/transport/empty 可重试），可用第 6 参显式覆盖
  - `isRetryableKind` / `isRetryable` / `isContextOverflow`
- `service/AgentLoopService.ts`：
  - 删除本地类，改 `import { LoopError } from '../common/LoopError'; export { LoopError };`（ChatViewModel 旧导入兼容）
  - `runTurnWithRetry` 先判 `failed.retryable`，不可重试直接上抛，再走 `policy.decide`
- `test/guncat-harness`：纳入 `LoopError`，新增 6 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=253 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- BACKLOG 已清空：按审计维度生成第五轮待办。

## 2026-09-16 R41: 插件 handler 参数校验 + PluginHotLoader 热重载

### 目标
- 让插件工具与核心工具一样先做结构化参数校验；插件支持按需热重载。

### 变更
- `service/WorkToolRunner.ets`：`runPluginHandler` 执行前复用 `parseArgs` + `ToolSchemaValidator.validate`（与 executeInner 一致）。
- `service/PluginHotLoader.ts`：新增 `reloadAll(context)`（unloadAll → loadAll 热重载入口）。
- `test/guncat-harness`：现有 253 用例全绿（插件校验/热重载为 service 层，经类型检查 + 构建验证）。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=253 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 接入 ChatViewModel 真实循环（runTurn 包装 + 逐步替换）。

## 2026-09-16 R42: SessionLogAggregator 跨会话聚合入口

### 目标
- 让日志汇总能跨多个会话合并协议/turn/工具统计与延迟分位。

### 变更
- `common/SessionLogAggregator.ts`：新增 `aggregateAll(eventGroups)`，合并多个会话事件后统一 `summarize`。
- `test/guncat-harness`：新增跨会话协议/工具/延迟分位 3 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=256 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项（用户要求先暂停）
- 剩余：WorkLoopDriver 接入真实循环、LoopError.userMessage 接入错误展示。

## 2026-09-16 R43: LoopError.userMessage 接入错误展示

### 目标
- 把 `LoopError.userMessage` 用于用户可见的错误提示，替代原始 message 直接上屏。

### 变更
- `viewmodel/ChatViewModel.ets`：catch 块优先取 `LoopError.userMessage`，为空时才回退到 `err.message`。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=256 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- 仅剩：WorkLoopDriver 接入 ChatViewModel 真实循环。

## 2026-09-16 R44: WorkLoopDriver 真实循环接入桥梁 + 开关

### 目标
- 为 WorkLoopDriver 接入 ChatViewModel 真实循环铺路：先提供可编译、可测试的桥接层与开关，再逐步替换 executeWorkLoop。

### 变更
- `common/LoopTurnInfoMapper.ts`：纯映射，把真实 `LoopTurnResult` 字段映射为 `WorkLoopTurnInfo`。
- `service/WorkLoopDriverBridge.ts`：把 `AgentLoopService.runTurnWithRetry` 适配为 `WorkLoopDriver.run` 的 `runTurn` 钩子；配置 `maxRetriesPerTurn=0` 避免与请求级重试叠加；`onRetry/onToolBatch` 转接到 `LoopTurnCallbacks`。
- `common/Constants.ts`：新增 `WORK_USE_DRIVER_LOOP=false` 开关（默认保持现有 executeWorkLoop，置 true 后走驱动）。
- `test/guncat-harness`：setup/check 同步新增 mapper 与 bridge；新增 mapper 2 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=258 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 实际接管 ChatViewModel.executeWorkLoop（逐步替换，保留开关回退）。

## 2026-09-16 R45: WorkLoopDriver 增加 onStep 钩子（为真实接管铺路）

### 目标
- 让 WorkLoopDriver 在每轮决策后暴露步骤钩子，便于真实循环接入时做日志/UI/统计。

### 变更
- `common/WorkLoopDriver.ts`：`WorkLoopDriverHooks` 新增 `onStep(step, action)`，在 `WorkLoopPlanner.decide` 之后回调。
- `service/WorkLoopDriverBridge.ts`：`run` 新增可选 `onStep` 参数并透传给驱动。
- `test/guncat-harness`：新增 driver onStep 1 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=259 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 实际接管 ChatViewModel.executeWorkLoop（逐步替换，保留开关回退）。

## 2026-09-16 R46: WorkLoopDriver ↔ WorkLoopSimulator 等价性回归

### 目标
- 为 WorkLoopDriver 实际接管 executeWorkLoop 提供等价性证据：驱动与既有纯模拟器对同一 turn 序列应产生一致步数/收尾/中止。

### 变更
- `test/guncat-harness/test-core.mjs`：新增 driver/simulator 等价性用例（happy 工具→收尾、abort 中止）。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=261 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 实际接管 ChatViewModel.executeWorkLoop（逐步替换，保留开关回退）。

## 2026-09-16 R47: WorkLoopDriverBridge 提供通用 runWithStep 步骤适配

### 目标
- 让 ChatViewModel 接管时可以把“单步实现”直接注入 `runWithStep`，由驱动负责步进/计划器/收尾/中止；同时修掉旧 `onToolBatch` 空转回调。

### 变更
- `service/WorkLoopDriverBridge.ts`：新增 `runWithStep(runStep, maxSteps, onStep?)` 通用适配；原 `run` 改为基于 `runWithStep` 的 AgentLoopService 便捷封装。
- 移除 `onToolBatch` 向 UI 发空 `toolCalls` 的占位调用（真实接管时工具执行在单步内部完成）。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=261 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 实际接管 ChatViewModel.executeWorkLoop（逐步替换，保留开关回退）。

## 2026-09-16 R48: WorkLoopDriverResult 增加 maxStepsReached 标记

### 目标
- 让驱动在步数耗尽时显式标记 `maxStepsReached`，供 ChatViewModel 接管后触发“已连续执行 N 轮”提示。

### 变更
- `common/WorkLoopDriver.ts`：`WorkLoopDriverResult` 新增 `maxStepsReached`；步数耗尽时置 true。
- `test/guncat-harness`：新增 maxStepsReached 1 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=262 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 实际接管 ChatViewModel.executeWorkLoop（逐步替换，保留开关回退）。

## 2026-09-16 R49: PluginHotLoader 插件摘要方法

### 目标
- 给插件热加载增加 `loadedCount/loadedSummary`，供日志/UI 展示已加载插件概览。

### 变更
- `service/PluginHotLoader.ts`：新增 `loadedCount()` 与 `loadedSummary()`（按 manifest.id 汇总）。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=262 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 实际接管 ChatViewModel.executeWorkLoop（逐步替换，保留开关回退）。

## 2026-09-16 R50: WorkLoopDriver 完整序列回归（compact→tool→finish）

### 目标
- 用完整序列压缩→工具→收尾覆盖驱动 onStep 顺序与计数，进一步为实际接管提供信心。

### 变更
- `test/guncat-harness/test-core.mjs`：新增 1 条完整序列用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=263 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 实际接管 ChatViewModel.executeWorkLoop（逐步替换，保留开关回退）。

## 2026-09-16 R51: WorkLoopDriverResult.isFinished 便捷判定

### 目标
- 为 ChatViewModel 接管后判断驱动收尾状态提供便捷方法。

### 变更
- `common/WorkLoopDriver.ts`：`WorkLoopDriverResult.isFinished()` 返回“正常收尾（非中止、非步数耗尽）”。
- `test/guncat-harness`：happy/max 两条用例补充断言。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=264 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`。

### 下一项
- WorkLoopDriver 实际接管 ChatViewModel.executeWorkLoop（逐步替换，保留开关回退）。

## 2026-09-16 R52: WorkLoopDriver 实际接管 executeWorkLoop（开关后）

### 目标
- 在 `WORK_USE_DRIVER_LOOP=true` 时让 WorkLoopDriver 真正驱动 executeWorkLoop 的步进/收尾/中止，默认 false 保持原路径，可随时回退。

### 变更
- `viewmodel/ChatViewModel.ets`：
  - `executeWorkLoop` 顶部按 `Constants.WORK_USE_DRIVER_LOOP` 分派到新增 `executeWorkLoopDriver`。
  - `executeWorkLoopDriver` 复用原单步逻辑，但用 `WorkLoopDriverBridge.runWithStep` 驱动：单步闭包用“单次 for 保留 break 语义”，abort/finish 时给 `WorkLoopTurnInfo` 置位，正常工具轮返回 `toolCallsCount`；步数耗尽用 `res.maxStepsReached` 触发原“已连续执行 N 轮”提示。
- 默认 `WORK_USE_DRIVER_LOOP=false`，原 executeWorkLoop 未改。

### 验证
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble58）。
- `node test/guncat-harness/test-core.mjs`：passed=264 failed=0。
- `node test/guncat-harness/check-setup.mjs && tsc -p check/tsconfig.json`：TYPECHECK_OK。

### 下一项
- BACKLOG 已清空：按审计维度生成第六轮待办。

## 2026-09-16 R53: 驱动路径 onStep 写 SessionLog（driver_step）

### 目标
- 让驱动接管时每步决策（step/action）进入会话日志，便于对比新旧循环。

### 变更
- `viewmodel/ChatViewModel.ets`：`executeWorkLoopDriver` 的 `runWithStep.onStep` 写入 `driver_step` 事件（含 step/action）。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=264 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble59）。

### 下一项
- 第六轮剩余：真机回归、ToolRegistry 统计、单步闭包抽纯方法、驱动错误展示。

## 2026-09-16 R54: ToolRegistry 增加 defCount/listTools 统计方法

### 目标
- 给工具注册中心增加便捷统计：总数与排除式工具定义列表，供日志/摘要/调试。

### 变更
- `common/ToolRegistry.ts`：新增 `defCount()` 与 `listTools(excluded)`。
- `test/guncat-harness`：新增 2 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=266 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble60）。

### 下一项
- 第六轮剩余：真机回归、单步闭包抽纯方法、驱动错误展示。

## 2026-09-16 R55: 驱动路径 driver_summary 日志 + 错误展示确认

### 目标
- 驱动接管后输出整轮驱动摘要（步数/工具/压缩/中止/收尾），并确认 catch 已统一使用 `LoopError.userMessage`。

### 变更
- `viewmodel/ChatViewModel.ets`：`executeWorkLoopDriver` 在 `runWithStep` 后写 `driver_summary` 事件。
- 错误展示：驱动路径的 catch 沿用 R43 的 `LoopError.userMessage` 优先逻辑（已确认）。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=266 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble61）。

### 下一项
- 第六轮剩余：真机回归、单步闭包抽纯方法。

## 2026-09-16 R56: WorkLoopStepInfoBuilder 纯逻辑 + 驱动路径接入

### 目标
- 把驱动路径中构造单步 `WorkLoopTurnInfo` 的逻辑抽成纯逻辑 builder，减少内联字段赋值并提升可测性。

### 变更
- `common/WorkLoopStepInfoBuilder.ts`：新增 `aborted()/finish()/tool()` 三个构造方法。
- `viewmodel/ChatViewModel.ets`：`executeWorkLoopDriver` 的中止/收尾/工具步统一改用 builder。
- `test/guncat-harness`：新增 3 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=269 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble62）。

### 下一项
- 第六轮剩余：真机回归、驱动单步闭包整体抽方法（R56 已先抽纯信息构造）。

## 2026-09-16 R57: 驱动单步闭包整体抽成 runDriverStep 方法

### 目标
- 把 `executeWorkLoopDriver` 里巨大的单步闭包整体抽成独立 `runDriverStep` 方法，减少内联层级，便于后续彻底移除旧循环。

### 变更
- `viewmodel/ChatViewModel.ets`：
  - 新增 `runDriverStep(conv, messages, metrics, turnToolEvents, state, stepIndex)`，承载原单步全部逻辑。
  - 复用 `WorkLoopStepState` 保存 `traceSeq/turnEndStatus/finalAnswerText`，驱动结束后回填本地变量。
  - `executeWorkLoopDriver` 的 `runWithStep` 回调改为一行转发 `this.runDriverStep(...)`。

### 验证
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble63）。
- `node test/guncat-harness/test-core.mjs`：passed=269 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。

### 下一项
- 第六轮剩余：`WORK_USE_DRIVER_LOOP=true` 真机回归（需实机/模拟器）。

## 2026-09-16 R58: onStep 透传 reason（driver_step 日志补决策原因）

### 目标
- 让驱动每步日志带上计划器 reason（tool_calls/context_overflow/max_tokens 等），提升可观测性。

### 变更
- `common/WorkLoopDriver.ts`：`onStep` 回调增加可选第三参 `reason`，调用时传 `d.reason`（向后兼容，旧 2 参回调仍可用）。
- `service/WorkLoopDriverBridge.ts`：`runWithStep/run` 的 `onStep` 类型同步增加 `reason?` 并透传。
- `viewmodel/ChatViewModel.ets`：`driver_step` 事件补 `reason` 字段。
- `test/guncat-harness`：onStep 用例断言 action:reason。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=269 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble64）。

### 下一项
- 第六轮剩余：`WORK_USE_DRIVER_LOOP=true` 真机回归（需实机/模拟器）。

## 2026-09-16 R59: SSEAdapterFactory.supports 协议白名单

### 目标
- 给协议适配器工厂增加协议白名单判定，供配置校验/日志快速判断是否支持。

### 变更
- `service/SSEAdapterFactory.ts`：新增 `supports(protocol)`（openai / responses / anthropic）。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=269 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble65）。

### 下一项
- 第六轮剩余：`WORK_USE_DRIVER_LOOP=true` 真机回归（需实机/模拟器）。

## 2026-09-16 R60: WorkLoopPlanner.describe 人类可读决策描述

### 目标
- 给计划器增加人类可读的决策描述，供日志/调试/未来 UI 提示。

### 变更
- `common/WorkLoopPlanner.ts`：新增 `describe(info)`，覆盖工具调用/中止/压缩/max_tokens/max_steps/无输出。
- `test/guncat-harness`：新增 4 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=273 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble66）。

### 下一项
- 第六轮剩余：`WORK_USE_DRIVER_LOOP=true` 真机回归（需实机/模拟器）。

## 2026-09-16 R61: WORK_USE_DRIVER_LOOP 默认开启（用户指示）

### 目标
- 按用户指示直接把驱动接管设为默认路径，让后续真机使用直接走新循环。

### 变更
- `common/Constants.ts`：`WORK_USE_DRIVER_LOOP` 由 `false` 改为 `true`，注释同步更新；如需回退改回 `false` 即可。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=273 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble67）。

### 下一项
- 真机/日常使用观察驱动路径；如发现行为差异可改回 `false` 并反馈。

## 2026-09-16 R62: 真机实跑确认（用户反馈）

### 目标
- 确认 `WORK_USE_DRIVER_LOOP=true` 在真机跑 Work 无问题。

### 结果
- 用户实际运行后反馈“跑了一下，没问题的”。
- 驱动接管路径通过首轮真机观察，无需回退。

### 下一项
- 第七轮剩余：PromptBudget 预算辅助、ToolScheduler.summary、LoopError 默认提示、驱动路径等价测试。

## 2026-09-16 R63: PromptBudgetSnapshot.overTarget/remaining

### 目标
- 给 Prompt 预算快照增加超预算判定与剩余额度，供压缩/裁剪触发统一使用。

### 变更
- `common/PromptBudget.ts`：`PromptBudgetSnapshot` 新增 `overTarget(maxTokens)` 与 `remaining(maxTokens)`。
- `test/guncat-harness`：新增 2 条用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=275 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble68）。

### 下一项
- 第七轮剩余：ToolScheduler.summary、LoopError 默认提示、驱动路径等价测试。

## 2026-09-16 R64: ToolScheduler.summary + LoopError.contextOverflowMessage

### 目标
- 补齐第七轮剩余两项：调度统计与上下文溢出默认提示。

### 变更
- `common/ToolScheduler.ts`：新增 `SchedulerSummary` 与 `ToolScheduler.summary(groups, maxParallel)`（组数/并行组/只读组/最大并发池）。
- `common/LoopError.ts`：新增 `contextOverflowMessage()` 默认中文提示。
- `test/guncat-harness`：新增 2 条用例（summary 统计、上下文默认提示）。
- 驱动路径等价测试：R46 driver/simulator 等价 + R50 完整序列 compact→tool→finish 已覆盖，本轮确认无需新增重复用例。

### 验证
- `node test/guncat-harness/test-core.mjs`：passed=277 failed=0。
- `node test/guncat-harness/check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- DevEco Studio `assembleHap`：`BUILD SUCCESSFUL`（assemble69）。

### 下一项
- 第七轮全部完成；按审计维度重新生成第八轮待办。

## 2026-09-16 R65: README 同步 + 第八轮暂停（用户指示）

### 目标
- 按用户指示同步中英文 README，并停止第八轮产品功能迭代。

### 变更
- `README.md` / `README_EN.md`：
  - 维护文档地图 ITERATION_LOG 范围更新至 R1–R64。
  - 工作模式循环说明标注默认由 `WorkLoopDriver` 驱动（`WORK_USE_DRIVER_LOOP=true`，可回退）。
  - 2.1 节标题更新为 R13–R64，补充 `WorkLoopDriverBridge`/`LoopTurnInfoMapper`/`WorkLoopStepInfoBuilder`/`SchedulerSummary`/`describe`，测试数更新为 277。
  - 6.2.0 / Version 6.2.0 通俗语言新增「驱动引擎默认启用、可一键回退」一条。
- `BACKLOG.md`：第八轮改为「产品功能（工具执行体验 + 会话质量/上下文）」，原纯兜底小工具移入「低优先级工程待办（暂缓）」。

### 状态
- 第八轮暂停，等待用户下一步指示。

## 2026-09-16 R66: 子代理并行派发（parallelSafe + 全局并发闸 + 取消透传）

### 目标
- 将主循环“派发多个子代理”从顺序制改为并行制，同时控制并发上限并打通父任务取消链路。

### 变更
- `entry/src/main/ets/common/ToolRegistry.ts`：
  - `ToolMeta` 新增 `parallelSafe` 标记。
  - 新增 `isParallelSafe(name)` / `setParallelSafe(name, flag)`。
- `entry/src/main/ets/service/WorkFileService.ts`：
  - `ensureToolRegistry` 同步后将 `subagent` 标记为并行安全。
  - 新增 `workParallelSafeNames()` / `isParallelSafeTool(name)`。
  - `subagentHook` / `executeTool` / `dispatchTool` 增加可选 `abortSignal`，透传到 `HarnessTools.dispatch`。
- `entry/src/main/ets/service/HarnessTools.ts`：`dispatch` 增加可选 `abortSignal`，`subagent` 分支透传给 `SubagentService.run`。
- `entry/src/main/ets/service/WorkToolRunner.ets`：`buildTask` / `executeInner` 透传 `abortSignal` 到 `WorkFileService.executeTool`。
- `entry/src/main/ets/service/SubagentService.ts`：
  - 新增全局子代理并发闸（信号量），默认 `WORK_MAX_PARALLEL_SUBAGENTS=4`（与只读池上限一致），超出排队等待。
  - `run()` 接收父级 `abortSignal`，通过轮询同步到子代理内部取消信号，父任务取消时真正中止子代理循环。
- `entry/src/main/ets/common/Constants.ts`：新增 `WORK_ALLOW_PARALLEL_SUBAGENTS` / `WORK_MAX_PARALLEL_SUBAGENTS`。
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：
  - 旧 `executeWorkLoop` 与当前 `executeWorkLoopDriver` 两处并行组条件从“只读”扩展为“只读或并行安全”。
  - 并行组改为“谁先完成谁先回填结果/刷新 UI”，不再按模型顺序等待；给模型的 `tool_result` 仍按原顺序保留。
  - `subagent` 单独执行后也刷新工作区面板。
- `entry/src/main/ets/model/ToolCallRecord.ts` / `entry/src/main/ets/views/WorkTurnView.ets`：新增 `started` 运行态；状态文案按“是否真正启动”显示“执行中/等待中”，不再因为模型调用顺序把已并行的后置调用标成“等待中”。
- `test/guncat-harness/test-core.mjs`：新增 `parallelSafe` 标记/查询回归用例。

### 验证
- `node test/guncat-harness/setup.mjs && node test/guncat-harness/test-core.mjs`：passed=280 failed=0。
- `node test/guncat-harness/check-setup.mjs && node test/guncat-harness/check/../.npm-cache/_npx/.../tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- 未执行 DevEco Studio `assembleHap`（当前会话未定位 hvigorw），服务层类型检查已通过；建议在 DevEco Studio 中做一次真机构建验证。

### 下一项
- （R67 已在本日完成，见下节）

## 2026-09-16 R67: 子代理工作区隔离（output_dir + 自动独立产出目录）

### 目标
- 多个子代理并行时，避免它们在工作区根目录写同名文件互相覆盖；让每个子代理的产出落进独立子目录，父任务通过报告中的路径取回产物。

### 变更
- `entry/src/main/ets/common/Constants.ts`：新增 `WORK_SUBAGENT_OUTPUT_DIR_PREFIX = 'subagents'`。
- `entry/src/main/ets/service/HarnessTools.ts`：`subagent` 工具定义新增可选参数 `output_dir`（工作区相对路径），工具描述同步说明“可读全工作区、写入自动重定向到产出目录”。
- `entry/src/main/ets/service/WorkFileService.ts`：`subagentHook` 类型增加可选 `outputDir` 参数并透传。
- `entry/src/main/ets/service/SubagentService.ts`：
  - 未传 `output_dir` 时自动分配独立产出目录 `subagents/sa_<时间戳>_<序号>/`。
  - `sanitizeOutputDir` / `ensureOutputDir`：只接受工作区内相对路径，非法路径回退自动目录；执行前确保目录已创建。
  - **执行层写隔离（修正自测发现）**：所有写类工具的目标路径（write/append/delete/create_dir/move/write_csv/download/write_svg/write_docx/write_xlsx/write_pptx/edit/str_replace_editor/edit_docx/edit_xlsx/edit_ppt/transform_file.output）在执行前统一重定向到子代理自己的 `output_dir`——裸路径自动加前缀、已在目录内则原样；`delete_file` 清空整个工作区被拦截；`run_js` 输出通过 `_output_dir` 注入同样落入该目录。读类工具（read_file/glob/grep/search_files/read_docx/read_xlsx/read_ppt/parse_document 等）与输入型路径（write_docx.doc_file / write_xlsx.workbook_file / write_pptx.deck_file / transform_file.input）不重定向，子代理仍可读取主工作区文件。
  - **越界反馈口径统一（修正第二轮自测）**：写入越界自动重定向后，工具结果前附加「【隔离提示】…已自动重定向至…」，不再静默改写；删除/移动主工作区文件直接返回「越界拦截」错误，不再出现“路径不存在: <隔离目录>/…”的费解信息。
  - 子代理系统提示词追加产出目录纪律，并说明“可读主工作区、写入被系统自动限制”。
  - 子代理最终报告头部增加“产出: <目录>”。
- `entry/src/main/ets/common/SubagentIsolation.ts`（新增，纯逻辑可单测）：写路径字段表、路径重定向、清空/越界拦截、args 重写、重定向提示。
- `entry/src/main/ets/service/JsCodeService.ts`：`run` 识别 `_output_dir`，输出落盘自动加前缀。
- `test/guncat-harness/test-core.mjs`：新增 `[SubagentIsolation]` 21 项回归用例（重定向/不重复前缀/输入保留/view 不重定向/清空拦截/越界删除移动拦截/重定向提示等）。

### 验证
- `node test/guncat-harness/setup.mjs && node test/guncat-harness/test-core.mjs`：passed=301 failed=0。
- `node test/guncat-harness/check-setup.mjs && tsc -p test/guncat-harness/check/tsconfig.json`：TYPECHECK_OK。
- 未执行 DevEco Studio `assembleHap`，建议真机构建后重跑“裸路径写主目录/改写主文件/删除主文件”用例确认。

### 下一项
- 待定。
















































## 2026-09-17 S1: 参考 doubao-workbuddy-qwenwork-skills 迭代改进现有技能文档

### 目标
- 以 C:\Users\a1519\Documents\GitHub\doubao-workbuddy-qwenwork-skills 中 ChatGPT presentations/documents、Doubao visualization/data-analysis、QwenWork/WorkBuddy 技能描述为参照，迭代改进现有 10 个技能（不新增技能）。
- 本轮聚焦：Office/数据类技能补强设计纪律与工作流，专家类技能对齐真实工具名。

### 变更
- `rawfile/skills/ppt/SKILL.md` + `ppt/reference/design-guide.md`：
  - 新增「内容纪律（面向观众）」：页面只写给最终观众、来源/口径放演讲备注、信息密度、文字优先缩短再换版式、避免 UI 式堆砌、封面极简。
  - 设计规范新增「听众视角与来源可追溯」「信息密度与字体纪律」两节。
- `rawfile/skills/docx/SKILL.md` + `docx/reference/design-guide.md`：
  - 新增「文档形态选型」表（prose/lead/列表/清单/定义列表/表格/引用）与「表格门禁」：只有行×列可比较数据才用表格，单元格成段即改回 prose/list。
  - 新增「结构复验（read_docx 不是可选项）」交付自检。
- `rawfile/skills/xlsx/SKILL.md` + `xlsx/reference/format-guide.md`：
  - 新增「工作流 C：数据分析与报表交付」：读数据→清洗/转换→定口径→建 Workbook→验证交付。
  - 补充表格可读性（列宽按内容分配、数字右对齐/文本左对齐、不插空行、一表一事）。
- `rawfile/skills/svg/SKILL.md` + `svg/reference/svg-craft.md`：
  - 新增「可视化类型选择」表（趋势/对比/占比/流程/架构/时间线/状态机/因果）与数据纪律（禁止编造数字、一张图一个信息点、节点≤7）。
- `rawfile/skills/research/SKILL.md`、`law/SKILL.md`、`sift/SKILL.md`、`llm-eval/SKILL.md`、`paper/SKILL.md`：
  - 新增「工作模式工具映射」：明确 `web_search` / `web_fetch` / `download_file` / 工作区文件读取工具，替换原来泛化的“联网搜索工具”表述；强调官方原文/榜单原始页必须 `web_fetch` 核对。
- `rawfile/skills/data/SKILL.md`：
  - 新增配方④与能力边界：诚实声明 transform_file 无分组聚合/merge/concat，给出小数据用 write_xlsx+公式、大数据先清洗再交给 xlsx 建模的替代方案。

### 验证
- 脚本校验 10 个技能 SKILL.md frontmatter 与目录名一致。
- 校验所有 `load_skill("...","...")` 引用指向已注册/已存在文件。
- 校验 `WorkSkillService.registry()` 中登记的文件全部存在。
- 无空字节；`ALL_SKILL_CHECKS_OK`。
- 本轮仅改 rawfile 技能文档，不涉及 ArkTS 编译面。

### 下一项
- 继续参考 qwenwork/docx、pptx、xlsx 与 workbuddy/pptx、docx 技能描述，细化各技能 reference（如 docx 模板填充、pptx 自动布局、xlsx 公式/表格设计）。
## 2026-09-17 S2: 技能 reference 细化 + 注册描述同步

### 目标
- 在 S1 基础上继续参考 qwenwork/docx、pptx、xlsx 与 ChatGPT presentations/documents 能力描述，细化各技能 reference。
- 同步更新 `WorkSkillService.registry()` 的技能描述，让模型在 list_skills 时看到新增的能力要点。

### 变更
- `rawfile/skills/ppt/reference/deck-dsl.md`：
  - 新增「拆页与备注规划」：拆页信号（>7 要点/多个主角/custom 元素过多）、一页一个主角、notes 放讲稿与来源、toc 与 section 一致、长 deck 先写 outline。
- `rawfile/skills/docx/SKILL.md` + `docx/reference/doc-dsl.md`：
  - 新增「模板/占位符填充」：read_docx 提取模板结构与风格 → 优先 Doc JSON 重建；`{{字段}}`/`【待填】`/`TODO` 用 edit_docx replace_text 替换；明确不承诺邮件合并/域填充。
  - doc-dsl 补充 Markdown → 正式 Word 快速路径说明。
- `rawfile/skills/xlsx/SKILL.md` + `xlsx/reference/workbook-dsl.md`：
  - workbook-dsl 新增「常用公式速查」（SUM/SUMIF/COUNTIF/IF/AVERAGE/ROUND/跨表引用）和「结构调整替代方案」（无 add_column/delete_column/move_column 时的诚实边界与做法）。
  - SKILL.md 在新建工作流中指向 workbook-dsl §6 公式速查。
- `rawfile/skills/svg/SKILL.md` + `svg/reference/svg-recipes.md`：
  - svg-recipes 新增「柱状对比图」「时间轴/里程碑」两套模板，并强调数据来自工作区、禁止编造。
- `entry/src/main/ets/service/WorkSkillService.ts`：
  - 同步更新 ppt/docx/xlsx/svg/data 技能描述，补充内容纪律、形态选型、数据分析链路、可视化类型选择、能力边界等触发要点；svg-recipes 文件描述补充柱状对比/时间轴。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用、registry 文件引用、无空字节。
- 缓存 TypeScript 编译器 `node test/.npm-cache/_npx/.../tsc -p check/tsconfig.json`：`TYPECHECK_OK`。
- `node test/guncat-harness/test-core.mjs`：passed=277 failed=0。

### 下一项
- 继续挖掘 qwenwork/docx、pptx、xlsx 的模板/修复类工作流，细化各 skill 的 troubleshooting 与场景配方；或把参考仓库中 Doubao sheet/word 的“专业文书/报表”规范吸收进 docx/xlsx reference。
## 2026-09-17 S3: 新增 PPT/Word 蓝图 reference，做结构性增强

### 目标
- 按用户“可以大改大调整”的指示，不只做小修补：为 ppt/docx 两个高频 Office 技能增加“常见交付物蓝图”，让模型拿到任务后能直接套用完整页面/章节结构。

### 变更
- 新增 `rawfile/skills/ppt/reference/deck-blueprints.md`：
  - 通用页面节奏（cover → toc → section → 内容 → end）。
  - 5 套演示文稿蓝图：经营复盘、商业计划、技术分享、培训教学、产品发布/路演；每套给出逐页版式与内容职责。
  - “从蓝图到 Deck”步骤。
- 新增 `rawfile/skills/docx/reference/document-blueprints.md`：
  - 通用文档骨架（封面/目录/H1/H2/表格/图片/来源）。
  - 5 套 Word 文档蓝图：商务报告、方案/提案、会议纪要、论文/学术、操作手册；每套给出 H1/H2 章节结构与格式建议。
  - “从蓝图到 Doc”步骤。
- `entry/src/main/ets/service/WorkSkillService.ts`：
  - ppt/docx 注册表新增 `reference/deck-blueprints.md` / `reference/document-blueprints.md` 文件条目。
- `rawfile/skills/ppt/SKILL.md`、`docx/SKILL.md`、`ppt/reference/design-guide.md`、`docx/reference/design-guide.md`：
  - 增加蓝图加载提示，模型不知道从哪下手时先 load_skill 蓝图。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用、registry 文件引用、无空字节。
- 缓存 TypeScript 编译器 `node .../tsc -p check/tsconfig.json`：`TYPECHECK_OK`。
- `node test/guncat-harness/test-core.mjs`：passed=277 failed=0。

### 下一项
- 继续做结构性增强：可为 xlsx 增加“常见报表蓝图”（经营报表/预算/财务模型/清单），为 svg 增加“信息图蓝图”（对比/流程/时间线/架构组合页），并把 qwenwork/WorkBuddy 的修复类工作流吸收进 troubleshooting。
## 2026-09-17 S4: xlsx 报表蓝图 + svg 信息图蓝图 + Office 修复工作流

### 目标
- 延续“大改大调整”方向：给 xlsx、svg 补上交付物蓝图，并把 qwenwork/WorkBuddy 的“修复已有文件”工作流吸收进三个 Office 技能的 troubleshooting。

### 变更
- 新增 `rawfile/skills/xlsx/reference/report-blueprints.md`：
  - 6 套 Excel 报表蓝图：经营月报/周报、预算 vs 实际、财务模型（简化）、明细+SUMIF 汇总、项目/任务跟踪、数据清单/台账。
  - 每套给出 sheet 结构、公式职责、格式建议；结尾附“从蓝图到 Workbook”步骤。
- 新增 `rawfile/skills/svg/reference/infographic-blueprints.md`：
  - 6 套信息图蓝图：对比/二选一、流程/步骤、时间线/里程碑、架构/层级、KPI 卡、机制/因果。
  - 每套给出视觉结构与信息层级；结尾附“从蓝图到 SVG”步骤。
- `rawfile/skills/ppt/reference/troubleshooting.md`、`docx/reference/troubleshooting.md`、`xlsx/reference/troubleshooting.md`：
  - 各新增「修复已有文件的标准工作流」：先读后改 → 定位问题 → 小改 ops → 结构调整 → 复验 → 大改重导；xlsx 额外给出公式修复时的行号换算提醒。
- `entry/src/main/ets/service/WorkSkillService.ts`：
  - xlsx 注册 `reference/report-blueprints.md`，svg 注册 `reference/infographic-blueprints.md`。
- `rawfile/skills/xlsx/SKILL.md`、`svg/SKILL.md`：
  - 增加蓝图加载提示。
- `README.md` / `README_EN.md`：
  - 技能树、技能系统说明、维护文档地图同步新增报表蓝图/信息图蓝图。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用、registry 文件引用、无空字节。
- 缓存 TypeScript 编译器 `node .../tsc -p check/tsconfig.json`：`TYPECHECK_OK`。
- `node test/guncat-harness/test-core.mjs`：passed=277 failed=0。

### 下一项
- 继续挖掘 Doubao word/sheet/ppt 的专业文书与报表规范，细化 docx/xlsx 的样式与结构；或对 research/sift/llm-eval 做输出模板/自检的结构性增强。
## 2026-09-17 S5: 专家技能交付形态 + data 数据质量检查

### 目标
- 让 research/law/paper/sift/llm-eval 五个专家技能在长输出时不再只“贴聊天”，而是默认把结构化成果写入工作区文件；同时给 data 技能补充数据质量检查与常见字段处理。

### 变更
- `rawfile/skills/research/SKILL.md`、`law/SKILL.md`、`paper/SKILL.md`、`sift/SKILL.md`、`llm-eval/SKILL.md`：
  - 各新增「交付形态（工作模式）」：研究报告/法律意见书/论文成稿/信息核查报告/模型对比分析默认写入工作区（`write_file` 或 `write_docx`，需要 Word 时先 `load_skill("docx")`）。
  - 对话只给「结论摘要 + 文件路径」；强调文件内来源/时效/版本标注纪律。
- `rawfile/skills/data/SKILL.md`：
  - 新增「数据质量检查」6 步（读前 30 行、列名核对、空值、类型、重复、异常值）。
  - 新增「常见字段处理速查」：手机号/身份证/金额/百分比/日期/枚举/空白字符的脏形态与处理写法。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用、registry 文件引用、无空字节。
- 缓存 TypeScript 编译器 `node .../tsc -p check/tsconfig.json`：`TYPECHECK_OK`。
- `node test/guncat-harness/test-core.mjs`：passed=277 failed=0。

### 下一项
- 可继续为 expert 技能增加“文件交付自检”参考文件（如研究/法律/评测报告落盘模板），或把 Doubao word/sheet 的专业文书规范吸收进 docx/xlsx 场景建议。
## 2026-09-17 S6: docx 专业文书规范 + xlsx 分析玩法

### 目标
- 把 Doubao word/sheet 相关专业文书与数据分析规范吸收进 docx/xlsx，让模型面对“公文/合同/报告/新闻稿/技术交底书”和“趋势/对比/构成/异常/敏感性”任务时有结构化参考。

### 变更
- 新增 `rawfile/skills/docx/reference/professional-docs.md`：
  - 5 类专业文书规范：公文（GB/T 9704 简化）、合同/协议、研究报告/咨询报告、新闻稿/宣传稿、技术交底书/专利初稿。
  - 每种给出结构骨架、Doc JSON 建议、能力边界（红头/页码/签章等需外部套版）。
- 新增 `rawfile/skills/xlsx/reference/analysis-playbook.md`：
  - 6 类数据分析玩法：趋势、对比、构成、异常归因、敏感性、口径与审计。
  - 每种给出 sheet 结构、公式示例、验证与交付要求。
- `entry/src/main/ets/service/WorkSkillService.ts`：
  - docx 注册 `reference/professional-docs.md`，xlsx 注册 `reference/analysis-playbook.md`。
- `rawfile/skills/docx/SKILL.md`、`xlsx/SKILL.md`：
  - 增加专业文书/分析玩法加载提示。
- `README.md` / `README_EN.md`：
  - 技能树、技能系统说明、维护文档地图同步新增专业文书规范与数据分析玩法。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用、registry 文件引用、无空字节。
- 缓存 TypeScript 编译器 `node .../tsc -p check/tsconfig.json`：`TYPECHECK_OK`。
- `node test/guncat-harness/test-core.mjs`：passed=277 failed=0。

### 下一项
- 可继续为 expert 技能增加“文件交付模板”reference，或为 ppt 增加“内容大纲/讲稿辅助”参考；也可把 qwenwork/WorkBuddy 的 docx/pptx/xlsx 修复能力继续细化到 troubleshooting。
## 2026-09-17 S7: 基于四平台实际参考做内容校准（重点吸收 ChatGPT 模板/规范）

### 背景
- 收到反馈：不能只按自己想法写，要多参考四个平台（doubao / qwenwork / workbuddy / chatgpt）的 skill。
- 本轮先补读四个平台的 README 索引，并用 Python 解析 ChatGPT artifact-template 系列的实际参考文件（reference.docx / .pptx / .xlsx），提取真实结构后回灌到现有技能文档。

### 参考动作
- 阅读 `README-doubao.md` / `README-qwenwork.md` / `README-workbuddy.md` / `README-chatgpt.md` 的 Skills/Experts 索引与描述。
- 重点解析 ChatGPT openai-templates 的实际文件：
  - Business Review、Market Trends Report、Project Kickoff（PPTX）
  - Legal Memorandum、Strategy Memorandum、System Design（DOCX）
  - Financial Budget、Three-Statement Forecast（XLSX）

### 变更
- `rawfile/skills/ppt/reference/design-guide.md`：
  - 新增 §14 字号下限与硬性视觉检查（deck 标题 ≥50pt / 页标题 ≥35pt / 副标题 ≥24pt / 正文 ≥16pt；重叠必须修复；单行标题不换行）。
  - 新增 §15 模板跟随（用户给模板时保留结构/版式/字号，最小改动，不套通用 theme 覆盖）。
- `rawfile/skills/ppt/reference/deck-blueprints.md`：
  - 新增蓝图 6「行业趋势报告」、蓝图 7「项目启动会」；新增「模板保真原则」（参考文件是设计权威，槽位不硬填）。
- `rawfile/skills/docx/reference/design-guide.md`：
  - 新增 §11 编辑纪律（已有文档最小改动、保留原稿、不推倒重写）。
- `rawfile/skills/docx/reference/professional-docs.md`：
  - 新增 §6 法律备忘录、§7 战略备忘录、§8 系统设计文档（结构来自 ChatGPT 实际模板）。
- `rawfile/skills/xlsx/reference/report-blueprints.md`：
  - 新增蓝图 7「财务预算与预测」（Summary/Assumptions/Op Build/Checks + Model Status）、蓝图 8「三表预测」（Read Me/Assumptions/Outputs/Statements/Builds）。
- `ppt/SKILL.md`、`docx/SKILL.md`、`xlsx/SKILL.md` 同步更新蓝图加载提示。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用、registry 文件引用、无空字节。
- 本轮未改 ArkTS；临时提取脚本已删除。

### 下一项
- 继续用同样方法吸收 qwenwork/doubao/workbuddy 的描述型能力（如 doubao-data-analysis 的证据分级、qwenwork docx 模板填充、WorkBuddy 文档生成质量门），进一步校准各技能 reference。
## 2026-09-17 S8: 结合完整四平台参考做核准与移植（Doubao/QwenWork/WorkBuddy/ChatGPT）

### 背景
- 用户指出此前 reference 多是自创，质量未经验证；要求以四个平台真实 skill 为来源移植，而不是按自己想法改。
- 已确认完整参考地址 `C:\Users\a1519\Documents\doubao-workbuddy-qwenwork-skills-skill\doubao-workbuddy-qwenwork-skills-skill`，其中 doubao/qwenwork/workbuddy/chatgpt 四个平台目录齐全。

### 核准/移植动作
- 阅读 Doubao word/sheet/ppt SKILL.md 与 style 参考、QwenWork docx/pptx/xlsx SKILL.md 与 authoring/visual-directions/layouts/components、ChatGPT documents/presentations/spreadsheets SKILL.md、Doubao doubao-visualization/doubao-data-analysis 参考。
- 对之前的自创 reference 做了校准，把真实平台的硬规则移植进现有技能。

### 变更
- `rawfile/skills/ppt/reference/design-guide.md`：
  - 新增 §0「设计系统与场景路由」：Doubao 七场景 + fallback、卡片禁用、≤3 色、原生表格、来源标注、模板处理、QwenWork 安全区（13.333×7.5，边距 0.6/0.55）。
- 新增 `rawfile/skills/ppt/reference/visual-components.md`：
  - 移植 QwenWork 12 类视觉组件（指标区/quote/对比/SWOT/雷达/漏斗/甘特/时间线/分配条/飞轮/分层/架构矩阵）到我们的原生版式 + SVG 实现路径；已注册进 WorkSkillService。
- `rawfile/skills/ppt/reference/deck-blueprints.md`：
  - 增加"关于卡片的说明"（匹配七场景时禁止圆角卡片，仅 fallback 可用）；模板保真区分"风格参考"与"严格模板"。
- `rawfile/skills/docx/reference/design-guide.md`：
  - 新增 §12「权威排版参数」：Doubao Word 字体/字号（Title 18pt 黑体、H1 16pt、H2 14pt、H3 12pt、正文 12pt 宋体 1.5 倍行距、题注 10.5pt）、编号体系、A4 页边距 2.5cm、页码、目录规则、表格表头灰底/对齐、脚注/参考文献/附录规范。
- `rawfile/skills/docx/SKILL.md`：
  - 新增「载体路由」表（学术/公文/合同/专业文书 → Word；媒体/创意/营销/攻略 → 在线文档）。
- `rawfile/skills/xlsx/reference/format-guide.md`：
  - 新增 §8「工作簿分层与视觉规范」：说明/原始数据/计算/结论分层、财务模型 Assumptions→报表→Builds→Check、表头浅灰底/对齐/冻结、颜色纪律、勾稽 Model Status=PASS。
- `rawfile/skills/xlsx/reference/report-blueprints.md`：
  - 通用规范补充四层分层与 Check 勾稽要求。
- `rawfile/skills/svg/reference/svg-craft.md`：
  - 新增「信息图硬规则」：不默认"标题+等大卡片"、静态优先、初始可读、证据保真、数据可复核、降级、地图禁用。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用、registry 文件引用、无空字节。
- 缓存 TypeScript 编译器 `node .../tsc -p check/tsconfig.json`：`TYPECHECK_OK`。
- `node test/guncat-harness/test-core.mjs`：passed=277 failed=0。

### 下一项
- 继续按四个平台真实内容核准：PPT 场景风格文件逐份吸收、Doubao word 各文体指南吸收、ChatGPT documents/presentations 的 preset/task 文档吸收；把仍在 self-invented 的 reference 尽量替换为有出处的规则。
## 2026-09-17 S9: 继续核准，替换自创参考为 Doubao 权威规则

### 背景
- 用户强调：GPT 来源内容可保留；自己靠想法写的 reference 要结合参考项目修改一致或直接废弃。
- 本轮针对仍偏自创的 xlsx/svg/docx 参考做替换/校准。

### 变更
- `rawfile/skills/xlsx/reference/format-guide.md`：
  - 新增标识符列（身份证/电话/邮编/编号）按文本写入并 `text`/`@` 格式。
  - 冻结表头改为"长明细才启用，普通报表不默认冻结"。
  - §8 视觉规范改为参考 doubao sheet ref-excel-visual-standards：美化非默认、数据区默认无斑马纹、边框只在表头底/分组/汇总行用连续实线、修改源文件延续原样式。
- `rawfile/skills/xlsx/reference/report-blueprints.md`：通用规范同步"长明细才冻结表头"。
- `rawfile/skills/svg/reference/infographic-blueprints.md`：
  - 整份重写为 doubao-visualization mode-html-svg 的移植：主模式路由、常用信息图形态表、静态/交互选择、硬规则、落地步骤；废弃原来自创的 6 个蓝图。
- `rawfile/skills/docx/reference/professional-docs.md`：
  - 新增 §0 来源与优先级（Doubao 各文体指南 > 本文件补充 > writing-taxonomy 一般格式）。
  - 公文/红头改为 Doubao government-and-party-documents 权威规则：A4 37/28mm、版心 156×225mm、2号小标宋标题/3号仿宋正文/3号黑体一级/3号楷体二级/加粗3号仿宋三级、行距 28-30 磅、首行缩进、抬头顶格/落款居右、落款同页、红头单行公式、禁止英文标点/无序列表。
  - 合同/协议改为 Doubao business-agreements 规则：合同/协议/普通约定分流、模板优先级（用户模板 > 市场监管总局示范文本库 > 无模板起草）、原位填写、法律条文核验、条款编号"第一条"、签署区只文字留白。
  - 研究报告改为 Doubao strategy-and-analysis 规则：报告目的落点表、证据呈现（图题在下/表题在上/来源格式）、图表选型、藏青色阶配色、编号 1->1.1。
  - 技术交底书增加 professional-domain-documents 原则说明。

### 验证
- `ALL_SKILL_CHECKS_OK`
- `TYPECHECK_OK`
- `passed=277 failed=0`

### 下一项
- 继续将 docx document-blueprints、xlsx report-blueprints 中仍属自创的部分对照 Doubao 模板/报告模板校准；吸收 ChatGPT documents/presentations 的 preset/task 文档中尚可移植的规则。
### S9 补充
- `docx/reference/document-blueprints.md` 增加来源说明：蓝图 6–8 为 ChatGPT 官方模板可保留；蓝图 1–5 标注为工作模式落地骨架，正式文体先读 `professional-docs.md`（Doubao 校准）。
- `xlsx/reference/report-blueprints.md` 增加来源说明：蓝图 7–10 为 ChatGPT 官方模板；蓝图 1–6 标注为落地骨架，正式分析报告结构参照 Doubao data-analysis 模板。
## 2026-09-17 S10: 移植 ChatGPT 官方 design_presets 与 style_guidelines

### 背景
- 用户允许保留 GPT 来源内容；本轮把 ChatGPT 官方文档设计预设和演示文稿风格指南原样移植为独立 reference，替代/补充自创排版建议。

### 变更
- 新增 `rawfile/skills/docx/reference/chatgpt-design-presets.md`（移植 ChatGPT documents design_presets.md）：
  - google_docs_default / standard_business_brief / compact_reference_guide / narrative_proposal + 6 个别名（rfi_response/decision_memo/launch_messaging_guide/contract_negotiation_brief/neighborhood_business_proposal/grant_proposal）
  - token 级关键值：US Letter 1.0in 边距、版心 6.5in/9360 DXA、Calibri 11pt、H1 16pt #2E74B5、表头 #F2F4F7/#E8EEF5/#F4F6F9、列表真实 numbering、表格列宽模式
  - 中文场景注意：中文正式文档仍以 Doubao 字体体系优先；西式 memo 才用本预设
- 新增 `rawfile/skills/ppt/reference/style-guidelines.md`（移植 ChatGPT presentations style_guidelines.md）：
  - 沟通任务一句话（到结束时受众应…因为…）、叙事弧选型、每页一个叙事任务、takeaway 式标题、证据变意义、开头结尾设计、自然文案、构图纪律（禁卡片网格/pills/徽章/按钮框）、字号下限（deck 50pt/页标题 35pt/副标题 24pt/正文 16pt）、单行标题不折行
  - 与 Doubao 场景系统的关系与优先级
- 已注册进 WorkSkillService.ts（ppt 新增 f7，docx 新增 d6），并在对应 SKILL.md 加 load_skill 指针；README 树同步。

### 验证
- `ALL_SKILL_CHECKS_OK`（新增文件、load_skill 引用、registry 引用均通过）
- `TYPECHECK_OK`
- `passed=277 failed=0`

### 下一项
- 继续吸收 ChatGPT documents `template-create.md`/`template-distill.md`、ooxml 任务文档与 pptx `editing.md`/`from_scratch.md` 中可移植到我们的工具边界内的规则；把仍为落地骨架的蓝图逐步换为有出处的结构。

## 2026-09-17 S11 / V2: 10 个现有 Skill 全量版本迭代（四平台来源移植）

### 目标
- 按用户要求做 Skill 版本迭代（V2）：只改进已有 Skill，不新增/删除 Skill，不改 Skill 名称与对外触发方式，保持输入/输出契约向后兼容。
- 所有改动必须能指回参考平台实际来源，而不是凭个人偏好自由发挥。

### 变更
- 并行重写 `rawfile/skills/` 下全部 10 个 `SKILL.md`（data / docx / law / llm-eval / paper / ppt / research / sift / svg / xlsx）。
- 每个 SKILL.md 均保留原 frontmatter `name`/`description` 逐字不变；保留既有工具名、参数、触发关键词与 `load_skill` 引用路径；无破坏性变更。
- 每个 SKILL.md 末尾新增 `## V2 变更来源（Source Map）`，逐条标注：变更点 | 来源文件（参考平台相对路径） | 移植内容/出处要点。
- 主要移植来源：
  - data：Doubao data-analysis / sheet / QwenWork xlsx 的口径核验、异常归因、交付审计。
  - docx：QwenWork docx / Doubao word / ChatGPT documents 的场景路由、模板填充、形态选型、渲染/回读 QA。
  - law：Doubao contract-reviewer / contract-drafting / compliance-assessment 的立场判断、分层审查、可审阅报告与风险分级。
  - llm-eval：Doubao academic-evaluator / WorkBuddy paper-reviewer / verifier-hub / ChatGPT review-agent 的评分置信度、证据锚定、defect-first 自审。
  - paper：Doubao academic-polish 系列 / WorkBuddy paper-reviewer 的三态路由、证据驱动写作、章节规范、评审视角。
  - ppt：Doubao ppt / QwenWork pptx / ChatGPT presentations 的场景路由、模板保真、安全区/视觉组件、叙事弧。
  - research：WorkBuddy deep-research / Doubao academic-researcher 的 outline 确认、并行深挖、证据分级、主题聚类、报告编译。
  - sift：Doubao critical-reading-companion / verifier-hub / WorkBuddy paper-quick-reader 的论证重建、evidence.quote、页码级 provenance。
  - svg：Doubao visualization / creative-design 的路由、硬规则、风格一致性、交付校验。
  - xlsx：Doubao sheet / QwenWork xlsx / ChatGPT spreadsheets / Doubao data-analysis 的编辑守恒、公式可审计、口径与对账。

### 验证
- 技能目录仍为 10 个；源文件总数仍为 35，无新增/删除 Skill 文件。
- `ALL_FRONTMATTER_OK`：每个 `SKILL.md` frontmatter `name` 与所在目录一致。
- `ALL_LOAD_SKILL_OK`：全部 `load_skill("skill","reference/...")` 指向的 reference 文件存在。
- `ALL_CITED_REF_PATHS_OK`：Source Map 中引用的参考平台文件存在（个别单元格含多个路径的合并文本，已人工确认路径有效）。
- 本轮未改 ArkTS/registry（未新增 reference 文件，无需改白名单）；未改 `entry/build/` 下的构建产物副本。

### 下一项
- 按需继续把 V2 中新增强规则反向沉淀到各 `reference/` 文档，进一步控制 SKILL.md 长度；或在真机工作模式中实跑验证各技能新流程。

## 2026-09-17 S11.1 / V2.1: 保守校准（仅处理已确认的内部一致性与实现对齐）

### 背景
- 用户对 fresh-agent 验证报告中“工具不存在”“输出丰富性原则”等意见不予采纳，明确要求不要按这些意见处理。
- 本轮只做保守校准：对照当前工具实现与已有 SKILL.md 契约，修正文档内部矛盾，不触碰工具可用性说明、不触碰详尽输出/丰富性输出原则。

### 变更
- `docx/SKILL.md`：
  - 目录描述由“静态目录文本”统一为“Word TOC 域，打开后右键‘更新域’生成”（对照 `DocxBuilder.ets` 实际实现）。
  - Source Map 追加 V2.1 两行：目录实现对齐、模板处理与 `doc-dsl.md` 工作流 C 对齐。
- `docx/reference/troubleshooting.md`：
  - “目录是静态的，页码不对”改为“目录打开后没显示页码/页码不对”，说明生成的是 Word TOC 域，需更新域生成/刷新页码。
- `docx/reference/doc-dsl.md`：
  - 模板/仿制/占位符填充改写为“可编辑模板原位填充优先，仅格式参考/仿制才重建”，与 SKILL.md 工作流 C 一致。
  - `title` 注释由“必填（空则用默认名）”改为“建议填写（留空用默认名）”。
- `ppt/reference/deck-dsl.md`：
  - 新增 `write_pptx` outline 参数语法（`#`→content、`##`→section、`-`→bullet、缩进→二级要点）。
  - 新增 `edit_ppt` 算子表（add_slide/delete_slide/move_slide/update_slide/replace_text/set_theme/set_title/set_notes，含必填字段与 JSON 示例），对齐 `DeckModel.ets` 实际实现。
- `xlsx/reference/workbook-dsl.md`：
  - 新增 §0 `write_xlsx` 三种输入约定：`workbook` 为 JSON 文本、`workbook_file` 为工作区 JSON 文件相对路径、`table` 为表格文本；`name`/`style` 顶层参数覆盖 workbook 内同名值。
  - 修正重复的 `## 7` 编号为 §9。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续按四平台参考做保守增强：优先把 QwenWork pptx / ChatGPT presentations 的 editing/from_scratch 规则继续沉淀到 `ppt/reference/`，把 Doubao sheet / ChatGPT spreadsheets 的表格设计规则继续沉淀到 `xlsx/reference/`。

## 2026-09-17 S11.2 / V2.2: PPT 模板编辑原则 + XLSX 可移植规范补充

### 目标
- 继续按用户认可的方向做保守增强：从 QwenWork pptx / ChatGPT spreadsheets 参考中移植与当前工具边界兼容的规则，不碰工具可用性说明，不碰输出丰富性原则。

### 变更
- `ppt/reference/design-guide.md`：
  - 新增 §16「QwenWork 模板编辑与从零构建原则（适配 Deck JSON / edit_ppt）」：模板先 QA 再复用、品牌身份 ≠ 执行债务、少项模板槽位整体删除、加长文本先验证放不放得下、从零先锁定视觉指纹、硬形状优先用组件/蓝图、不确定项一次问清。
  - 新增 §17「真实图片与无图兜底原则（参考 QwenWork from_scratch）」：锚点页优先真实照片、主题型 deck 至少一张真实照片、无图时用完整无图版式、logo 用真实素材不拼假 logo。
- `xlsx/reference/format-guide.md`：
  - 新增 §10「ChatGPT spreadsheets 可移植规则（适配 Workbook JSON / edit_xlsx）」：指令优先级、编辑前研究原文件约定、公式可审计（辅助单元格/不写死 magic number）、跨表引用推荐总是单引号、公式错误扫描、百分比精度、不用字符串伪装类型、来源内嵌、只读问题不改文件。
- `xlsx/reference/workbook-dsl.md`：
  - 跨表引用示例改为推荐总是用单引号包表名，避免空格/特殊字符导致引用错误。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 QwenWork visual-directions/authoring 中不依赖 python-pptx 的规则沉淀到 `ppt/reference/visual-components.md`，把 Doubao sheet 的更多表格设计规则沉淀到 `xlsx/reference/report-blueprints.md`。

## 2026-09-17 S11.3 / V2.3: PPT 视觉方向 + XLSX 分析报告蓝图

### 目标
- 继续按用户认可的方向做保守增强，从 QwenWork visual-directions 与 Doubao data-analysis 报告结构中移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/design-guide.md`：
  - 新增 §18「视觉方向与指纹（参考 QwenWork visual-directions）」：
    - 四个可复用方向：Institutional restraint / Editorial story / Culture texture / Signal system，每个给出适用场景、色系/图像、封面轮廓、内容轮廓、Motif、Forbid。
    - 跨方向硬规则：先定 5 轴指纹（palette / image_style / cover silhouette / content silhouettes / motif）、另一个版本不能只换颜色、模板编辑不选方向。
- `xlsx/reference/report-blueprints.md`：
  - 新增「蓝图 11：数据分析 / 诊断报告式工作簿（参考 Doubao doubao-data-analysis 报告结构）」：
    - 执行摘要 → 数据说明 → 分析方法 → 数据探索 → 分析结果 → 结论建议 → 附录。
    - 要点：每条结论能指回依据、口径先定后算、缺失值不编造、异常入附录台账。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 QwenWork authoring.md 中与文字/图片/形状相关的通用纪律沉淀到 `ppt/reference/visual-components.md` 或 `svg/reference/svg-craft.md`；把 Doubao sheet 的更多表格设计规则沉淀到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.4 / V2.4: PPT Authoring 陷阱校准 + XLSX 编辑准则补充

### 目标
- 继续按用户认可的方向做保守增强，从 QwenWork authoring.md 与 Doubao sheet 编辑准则中移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/visual-components.md`：
  - 新增「Authoring 陷阱校准（参考 QwenWork authoring.md，适配 Deck JSON / write_svg）」：
    - 坐标与版式：元素不越界、模板内部安全区不压内容。
    - 文字：引号统一、原子文本不换行、不用自动缩放掩盖溢出、正文不居中。
    - 形状：默认方角、去阴影渐变、组件不共享可变样式状态。
    - 图片：真实图片不拼形状、不拉伸、内嵌图留白均匀、构图槽位不缩进、标题下不加装饰细线。
    - 可读性与层级：避免低对比、每页有视觉落点但不过度装饰、跨页节奏由信息架构决定。
- `xlsx/reference/format-guide.md`：
  - 新增 §11「Doubao sheet 编辑准则补充（适配 Workbook JSON / edit_xlsx）」：
    - 补齐只写空单元格、新增计算列/汇总行必须显式给格式、聚合公式先确认区间边界、公式先判空、日期列转换先扫全列锁月/日、元信息另置、新增内容要能看懂、批量替换后做残留复查。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 QwenWork from_scratch 的“真实照片获取/图片风格”规则细化到 `svg/reference/svg-craft.md` 或 `ppt/reference/design-guide.md`；把 ChatGPT spreadsheets 的 `features/charts.md` 图表规则沉淀到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.5 / V2.5: PPT 真实图片执行细则 + 图表设计细则

### 目标
- 继续按用户认可的方向做保守增强，从 QwenWork from_scratch 与 ChatGPT spreadsheets charts.md 移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/design-guide.md`：
  - §17 扩充「具体执行（QwenWork from_scratch § Fetching real photos 翻译到当前工具链）」：
    - 一个 deck 一个 `image_style`、按版式定纵横比（16:9 / 1:1 / 9:16）、先落盘再引用（不留临时 URL）、每个图片槽位预想完整无图兜底、禁止拿手绘/形状冒充图片、返回图尺寸不符时先适配再放弃。
  - 新增 §19「图表设计细则（参考 ChatGPT spreadsheets features/charts.md，适配 PPT chart / SVG 可视化）」：
    - 何时用图、选型示例、可审计数据、干净放置、标题/轴/标签、克制的设计、编辑已有图表。
    - 适配到当前工具：PPT chart 字段 / SVG 可视化，而不是 Excel 原生图表。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 QwenWork visual-directions/authoring 中尚未覆盖的“组件使用阈值/组件目录边界”细化到 `ppt/reference/visual-components.md`；把 ChatGPT spreadsheets style_guidelines.md 的表格格式规则沉淀到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.6 / V2.6: PPT 组件边界阈值 + XLSX 格式风格规则

### 目标
- 继续按用户认可的方向做保守增强，从 QwenWork components.md 与 ChatGPT spreadsheets style_guidelines.md 移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/visual-components.md`：
  - 新增「组件使用边界与阈值（参考 QwenWork components.md）」：
    - 什么情况不要用组件（纯文本/标题/要点/单图/双栏/简单表格/基础图表直接原生版式；强行套用不匹配组件更糟）。
    - 阈值速查表：KPI strip 2~4、comparison 2~4、swot 每象限 3~5、radar 4~6 维单系列、timeline 3~6、allocation 2~6、flywheel 3~6 节点、layered 2~6 层、flow 每行 2~4（最多 5）。
    - House style 例外：allocation_bars/进度条本体保持胶囊圆角，仍扁平无阴影。
- `xlsx/reference/format-guide.md`：
  - 新增 §12「ChatGPT spreadsheets style_guidelines 可移植规则（适配 Workbook JSON / edit_xlsx）」：
    - 编辑带格式工作簿先摸清样式、表头与数据/派生区视觉可区分、边框只用于结构、只给已填充/有意预留范围设样式、对齐按数据类型整列设置、重要合计放可见摘要区、布局紧凑可扫读、加粗克制。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao ppt / ChatGPT presentations 的“开场与结尾页结构”细化到 `ppt/reference/deck-blueprints.md`；把 Doubao sheet 的分组汇总/透视原则沉淀到 `xlsx/reference/analysis-playbook.md`。

## 2026-09-17 S11.7 / V2.7: PPT 开场结尾叙事 + XLSX 分组汇总/透视原则

### 目标
- 继续按用户认可的方向做保守增强，从 ChatGPT presentations style_guidelines 与 Doubao sheet 编辑准则中移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/deck-blueprints.md`：
  - 新增「开场与结尾页通用结构（参考 ChatGPT presentations style_guidelines + Doubao ppt）」：
    - 先写 communication job 一句话；选一条叙事弧；Agenda 不是叙事；开场要“值得听”；结尾要“回应开场”；每页推进故事；每页 notes 给 3~5 句可读讲稿。
- `xlsx/reference/analysis-playbook.md`：
  - 新增 §7「分组汇总与透视（参考 Doubao sheet）」：
    - 分组汇总优先用原生透视/汇总能力；用 SUMIF/COUNTIF 汇总表时保证维度唯一、公式可审计、不伪装成原生透视表。
    - 数据源干净、汇总前定口径、汇总结果可对账、维度列保持唯一词。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao ppt 的“每页闭环/讲稿备注/素材兜底”原则细化到 `ppt/reference/troubleshooting.md` 或 `ppt/SKILL.md`；把 Doubao sheet 的“续写继承样式”细化到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.8 / V2.8: PPT 讲稿备注入契约 + XLSX 续写继承样式

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao ppt 与 Doubao sheet 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/SKILL.md`：
  - 内容纪律新增“每页 notes 给 3~5 句可直接照读的讲稿（参考 Doubao ppt Step 7）”。
  - 交付前自检清单新增对应项。
  - Source Map 新增 V2.8 行。
- `xlsx/reference/format-guide.md`：
  - 新增 §13「续写/扩展继承样式（参考 Doubao sheet）」：
    - 新区域与相邻原始区域视觉一致、新增列/行先对齐结构再填值、延续公式与汇总、不要整簿重套样式。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao ppt 的“素材兜底/图片不重复/缺图降级”细化到 `ppt/reference/design-guide.md` 或 `ppt/SKILL.md`；把 Doubao sheet 的“真实写回+回读校验”细化到 `xlsx/SKILL.md` 或 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.9 / V2.9: PPT 素材纪律 + XLSX 公式真实落格校验

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao ppt 与 Doubao sheet 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/SKILL.md`：
  - 工作流 A「收集素材」补充：附件中提取的图片/表格可缩放但**不做裁剪**（参考 Doubao ppt）。
  - 设计规范新增：数据类可视化缺真实数据时不编造数字，优先换结构图/要点/定性对比；确需图表占位才标注「模拟数据，仅占位，待替换真实数据」。
  - Source Map 新增 V2.9 行。
- `xlsx/SKILL.md`：
  - 工作流 B 编辑后回读补充：关键公式要核对“真实落格”，只看到显示值不能证明联动。
  - 交付前自检清单新增：关键公式 read_xlsx 回读为“真实公式”（不是静态值）。
  - Source Map 新增 V2.9 行。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao ppt 的“素材兜底优先级”细化到 `ppt/reference/design-guide.md`；把 Doubao sheet 的“批量替换残留复查”细化到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.10 / V2.10: PPT 素材兜底优先级 + XLSX 残留复查确认

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao ppt 与 Doubao sheet 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/design-guide.md`：
  - §17 新增「素材兜底优先级（参考 Doubao ppt Step 7）」：
    1. 主视觉优先真实素材，绝不留空白图框；
    2. 缺图先搜图/生图补，补不到用近似/抽象图；
    3. 生图也不可用才用结构图表达；
    4. 数据可视化缺真实数据不编造，优先换不依赖数据的表达，确需占位标注「模拟数据，仅占位」；
    5. 附件提取的图片/表格可缩放但不做裁剪。
- `xlsx/SKILL.md` + `xlsx/reference/format-guide.md`：
  - 核对确认：Doubao sheet 的“批量替换/删除后残留复查（搜索→替换→再搜索、采样前中尾）”已在两处覆盖，无需重复新增。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao ppt 的“每页一页一页校验/写入闭环”翻译为“生成后逐页回读校验”的更强流程细化到 `ppt/SKILL.md`；把 Doubao sheet 的“写聚合公式前确认区间首尾”已覆盖的结论写进 `xlsx/reference/format-guide.md` 检查清单。

## 2026-09-17 S11.11 / V2.11: PPT 逐页回读校验 + XLSX 聚合区间检查清单

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao ppt 与 Doubao sheet 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/SKILL.md`：
  - 工作流 A Step 7 补充：长 deck 不要只看生成成功，用 `read_ppt` 按页序逐页回读（页序/标题/要点/图片/notes）；对应 Doubao ppt 的“逐页完成/写入后回读核对”。
  - 交付前自检清单改为：read_ppt 或 read_file 抽查过最终文件内容？（长 deck 按页序逐页回读过）
  - Source Map 新增 V2.11 行。
- `xlsx/reference/format-guide.md`：
  - §9 自检清单新增：写聚合公式前确认过区间首尾（起点跳过表头、终点覆盖真实末行）？

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao ppt 的“回读后按页修复/补页定位”细化到 `ppt/reference/troubleshooting.md`；把 Doubao sheet 的“全量处理前置断言条数”细化到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.12 / V2.12: PPT 回读按页修复 + XLSX 全量断言

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao ppt 与 Doubao sheet 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/troubleshooting.md`：
  - 新增「长 deck 回读后按页修复（参考 Doubao ppt 回读定位）」：
    - 回读先对页序；不要凭记忆改 index；补页/插页先定位锚点；修复后复验受影响页与相邻页。
- `xlsx/reference/format-guide.md`：
  - §11 新增「全量处理前置断言条数（参考 Doubao sheet 规则 10）」：
    - 翻译/打标/批量公式等逐条任务先把预期条数写进计划/脚本，再 `assert actual == expected`；断言不过优先补齐；补不了先落地主体产物并在交付说明声明未完成项。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao ppt 的“每页 notes 3~5 句讲稿/回读定位”已在多处覆盖后，转回四平台通用规则的未覆盖点；可把 Doubao sheet 的“中间结果放右侧或新建空白 Sheet”细化到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.13 / V2.13: XLSX 中间结果与 Sheet 结构保护

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao sheet 编辑准则中移植与当前工具边界兼容的规则。

### 变更
- `xlsx/reference/format-guide.md`：
  - §11 新增两条：
    - 中间结果放右侧或新建空白 Sheet，不覆盖原始区域；原表其它单元格、行列结构、Sheet 名、合并区、格式保持 1:1。
    - 禁止删/改名/隐藏/移动已存在 Sheet（用户明示要求除外）；确认影响后执行，交付说明记录结构变化。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao sheet 的“筛选/排序后核对前几行、删除后确认已空”细化到 `xlsx/reference/format-guide.md`；可把 Doubao ppt 的“图片去底色/背景透明”规则评估后适配到 `ppt/reference/design-guide.md`。

## 2026-09-17 S11.14 / V2.14: XLSX 筛选/删除回读 + PPT 背景透明

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao sheet 与 Doubao ppt 中移植与当前工具边界兼容的规则。

### 变更
- `xlsx/reference/format-guide.md`：
  - §11 新增：筛选/排序后核对前几行和表尾顺序，删除后确认已空、相邻行未被误删；不要只凭操作返回结果声称完成。
- `ppt/reference/design-guide.md`：
  - §6 新增「透明背景处理（参考 Doubao ppt 图片去底色经验）」：
    - 图片放深色/彩色背景时优先透明背景素材（PNG/SVG）；带白/黑底素材不要直接压在不匹配背景上，选与背景一致的素材或用 image-full/整块色板承接，避免明显矩形底块。
    - 黑白灰底图最影响观感；渐变底/复杂背景不建议硬抠。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao sheet 的“全篇禁止 emoji/图标用 IconPark”规则评估后适配到 `xlsx/reference/format-guide.md` 或 `ppt/SKILL.md`；可把 Doubao ppt 的“生图/搜图用于背景时不应带文字”细化到 `ppt/reference/design-guide.md`。

## 2026-09-17 S11.15 / V2.15: PPT 背景无文字 + emoji 禁令

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao ppt 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/design-guide.md`：
  - §6 新增：背景/封面图不应带文字（参考 Doubao ppt Step 3）——生成/检索后检查，出现文字就换图或重做。
  - §0 硬性规则新增：全篇禁止 emoji（参考 Doubao ppt Step 7）——任何位置不用 emoji 当图标/正文，需要图标用 write_svg 生成语义图标或版式元素。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao ppt 的“静态校验/写入确认才算该页完成”进一步对应到 `ppt/SKILL.md` 自检；可把 Doubao sheet 的“公式优先级（AI 公式例外）”评估后适配到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.16 / V2.16: PPT 写入确认 + XLSX 公式结果核验

### 目标
- 继续按用户认可的方向做保守增强，从 Doubao ppt 与 Doubao sheet 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/SKILL.md`：
  - 工作流 A Step 6 补充：必须拿到成功返回才算生成完成，返回失败/异常按提示修复后重新导出。
  - 自检清单新增：write_pptx 已返回成功且 read_ppt 能读回最终文件？
  - Source Map 新增 V2.16 行。
- `xlsx/reference/format-guide.md`：
  - §11 新增：「“生成成功”不等于“计算结果正确”」（参考 Doubao sheet AI 公式例外）：批量/AI 生成公式后必须 read_xlsx 抽样核验真实落格与关键值；语义判断类不要用固定偏移/正则硬套，逐行独立语义任务显式说明或逐行处理。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 Doubao sheet 的“表外数据要交代依据”已在多处覆盖后，继续评估 QwenWork xlsx 的“样式继承/格式套用”未覆盖点；可把 QwenWork pptx 的“模板容量判定”细化到 `ppt/SKILL.md`。

## 2026-09-17 S11.17 / V2.17: PPT 模板容量判定 + XLSX 可填写模板/已有文件编辑

### 目标
- 继续按用户认可的方向做保守增强，从 QwenWork pptx 与 QwenWork xlsx 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/SKILL.md`：
  - 工作流 B 模板保真新增「模板容量判定（参考 QwenWork editing.md 的 strict/mixed/coarse/none）」：模板内容版式数量撑不起计划页数时，保留品牌身份，在模板视觉体系内重建内容页。
  - Source Map 新增 V2.17 行。
- `xlsx/reference/format-guide.md`：
  - 新增 §14「供人填写的工作簿与已有文件编辑（参考 QwenWork xlsx）」：
    - 创建“给人填的模板”时给图例 + 一行真实示例，示例行只用于新建模板，不加入已有文件；
    - 编辑已有文件先找设计输入区，只写那里，已有公式不动；
    - 财务模型颜色约定适配：工具不支持单元格颜色时用说明 sheet 文字标注输入/公式/跨表引用；
    - 公式“能求值”≠“算对”，交付前仍要对账。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 QwenWork xlsx 的“专业字体/零公式错误/公式兼容函数”已在多处覆盖后，继续找 QwenWork pptx 的“authoring/editing”未覆盖点；可把 ChatGPT spreadsheets 的“数据验证/条件格式”以替代说明沉淀到 `xlsx/reference/format-guide.md`。

## 2026-09-17 S11.18 / V2.18: PPT CJK 字体纪律 + XLSX 验证/条件格式替代

### 目标
- 继续按用户认可的方向做保守增强，从 QwenWork pptx 与 ChatGPT spreadsheets 中移植与当前工具边界兼容的规则。

### 变更
- `ppt/reference/visual-components.md`：
  - Authoring 文字部分新增：CJK 字体不要预置（避免闪动/豆腐块），只有用户报告豆腐块并给出确认字体名时才处理（参考 QwenWork authoring.md）。
- `xlsx/reference/format-guide.md`：
  - 新增 §15「数据验证/条件格式的替代方案（参考 ChatGPT spreadsheets）」：
    - 状态/优先级/风险/差异字段用说明 sheet 写明允许值列表与填写规范，状态列统一词表；
    - 需要随未来变化自动反应的字段保持公式驱动，不一次性静态填色/填结果；
    - 扫描型列先保证值统一、公式可复核，颜色/图标只是加分项。

### 验证
- `ALL_SKILL_CHECKS_OK`：frontmatter、load_skill 引用均通过。
- `passed=277 failed=0`。
- 未新增/删除文件；未改 ArkTS/registry；未改 `entry/build/` 副本。

### 下一项
- 继续保守增强：可把 QwenWork pptx 的“模板容量判定”已覆盖后，评估 QwenWork pptx 的“布局 slot 表/安全区”是否需再细化；可把 ChatGPT spreadsheets 的“只读问题不改文件”已在多处覆盖后，寻找其他未覆盖规则。

## 2026-09-17 T1: 四平台参考移植新增 4 个通用技能（humanizer/prompt-engineering/pdf/translation）

### 目标
- 扫描 `doubao-workbuddy-qwenwork-skills-skill` 参考目录，筛选高频、通用、可复用且与现有 10 个技能不重复的能力，按本项目规范移植到 `rawfile/skills/` 并登记进 `WorkSkillService.registry()`。

### 筛选结果
- 产出 `SKILL_PORTING_REPORT.md`：记录四平台扫描范围、现有技能覆盖、筛选维度、落选候选、移植清单与 Source Map。
- 本轮新增 4 个技能：
  - `humanizer`：去 AI 味/拟人化/可读性改写（来源 workbuddy humanizer + social-content-team de-ai-writing/output-readability）；
  - `prompt-engineering`：提示词工程（来源 workbuddy prompt-engineering-expert）；
  - `pdf`：PDF 读取/搜索/扫描件阅读（来源 qwenwork pdf + doubao pdf，适配当前 parse_document/search_pdf/pdf_to_images）；
  - `translation`：通用翻译/术语一致性/双语交付（来源 legal-translation 通用化 + medical-literature-translation）。

### 变更
- 新增 `rawfile/skills/humanizer/SKILL.md` + `reference/general-patterns.md`（24 项模式上半，完整 before/after）+ `general-patterns-2.md`（下半 + 完整示例）+ `social-media.md`（de-AI writing 全文）+ `readability.md`（output-readability 全文）；
- 新增 `rawfile/skills/prompt-engineering/SKILL.md` + `reference/original-skill.md`、`BEST_PRACTICES.md`、`TECHNIQUES.md`、`TROUBLESHOOTING.md`、`EXAMPLES.md`、`START_HERE.md`、`GETTING_STARTED.md`、`SUMMARY.md`、`INDEX.md`、`CLAUDE.md`（原技能全部文档原文）；
- 新增 `rawfile/skills/pdf/SKILL.md` + `reference/original-prompt-1..4.md`（qwenwork/pdf 原始 SKILL.md 全文拆段）、`troubleshooting.md`、`extraction-guide.md`、`forms-guide.md`、`generation-guide.md`、`security-guide.md`、`advanced-libraries.md`；
- 新增 `rawfile/skills/translation/SKILL.md` + `reference/translation-playbook.md`、`legal-full.md`（法律翻译完整原文）、`medical-1..5.md`（医学翻译完整原文拆段）；
- `entry/src/main/ets/service/WorkSkillService.ts`：`registry()` 新增上述 4 个 SkillInfo（id/name/description/files 全量登记）；
- `test/pptx-harness/check-docs.py`：新增全部新技能文档到体量/围栏检查；
- `SKILL_PORTING_REPORT.md`：新增分析报告并记录“不简化原则”。

### 验证
- `python test/pptx-harness/check-docs.py`：新技能文档全部 OK（仅既有 `ppt/SKILL.md` 13026 字符超限为历史遗留，未在本轮改动）；
- frontmatter 检查：14 个技能目录名与 `name` 均一致；
- `node check-setup.mjs && npx tsc -p check/tsconfig.json`：类型检查通过；
- 未删除原文件；未覆盖既有技能 SKILL.md/reference；未改 `entry/build/` 副本。

### 下一项
- 可继续评估候选：`questionnaire`（问卷/访谈提纲）、`html`（单页 HTML）、`content-rewrite`（一稿多发），确认工具边界后按同样流程移植。

## 2026-09-17 R2（双数轮）：上一轮 4 个技能全面复查与纠正

### 目标
- 双数轮全面复查 T1 移植的 humanizer / prompt-engineering / pdf / translation，纠正简化、缩略、自编摘要行为，确保内容来自参考项目原文。

### 修正动作
- **SKILL.md 直接移植原提示词，不再用自编摘要**：
  - `humanizer/SKILL.md`：原 `workbuddy/skills/humanizer/SKILL.md` 正文前半（CONTENT PATTERNS 完整 before/after）；后半保留在 `reference/general-patterns-2.md`；
  - `prompt-engineering/SKILL.md`：原 `prompt-engineering-expert/SKILL.md` 全文（仅 frontmatter 名改为 prompt-engineering）；
  - `pdf/SKILL.md`：原 `qwenwork/skills/pdf/SKILL.md` 前半；后半在 `reference/original-prompt-2..4.md`；
  - `translation/SKILL.md`：原 `legal-translation/SKILL.md` 全文（仅 frontmatter 名改为 translation）；医学翻译全文保留在 `reference/medical-1..5.md`。
- **删除自编速查文件（R2 纠正）**：`prompt-engineering/reference/best-practices.md`、`translation/reference/translation-playbook.md` 已删除，并从 registry/check-docs 移除。
- **删除与 SKILL.md 重复的引用（R2 去重）**：`humanizer/reference/general-patterns.md`、`prompt-engineering/reference/original-skill.md`、`pdf/reference/original-prompt-1.md`、`translation/reference/legal-full.md` 已删除（内容已由对应 SKILL.md 承载）。
- **新增适配层**：`pdf/reference/tool-notes.md`（本项目工具映射/工作流/能力边界），登记进 registry。
- `SKILL_PORTING_REPORT.md`：新增「双数轮复查（R2）」章节记录以上修正。

### 验证
- frontmatter：14 个技能目录名与 `name` 全部一致；
- 文档体量：新技能全部 <1.2 万字符（仅既有 `ppt/SKILL.md` 13026 字符为历史遗留）；
- `node check-setup.mjs && npx tsc -p check/tsconfig.json`：类型检查通过；
- 未删除参考原文件；未覆盖既有技能内容；未改 `entry/build/` 副本。

## 2026-09-17 R3（单数轮）：新增 questionnaire（用户研究）技能

### 目标
- 单数轮新增 1 个高频、通用、可复用、与现有技能不重复的技能。本轮选择 `questionnaire`（Doubao 问卷/用户研究，文档型非重大 skill，无需额外代码）。

### 变更
- 完整复制 `doubao/skills/doubao-questionnaire-designer/` 全部内容到 `rawfile/skills/questionnaire/`：`SKILL.md`、`CHANGELOG.md`、`references/m1-questionnaire-design.md`、`m2-interview-outline.md`、`m3-verbatim-tagging.md`、`m4-quantitative-analysis.md`（全文，未简化/未合并）；
- 仅将 frontmatter `name` 改为 `questionnaire`，并在 SKILL.md 末尾加本项目适配说明（飞书交付改 `write_docx`/`write_xlsx`，M4 用 `transform_file` 清洗）；
- `WorkSkillService.registry()` 登记 questionnaire（files 全量登记）；
- `test/pptx-harness/check-docs.py` 加入 questionnaire 全部文档；
- `SKILL_PORTING_REPORT.md` 更新为 5 个新技能并记录 R3。

### 验证
- frontmatter：15 个技能目录名与 `name` 全部一致；
- 文档体量：questionnaire 全部 <1.2 万字符，代码围栏平衡（唯一告警仍为历史遗留 `ppt/SKILL.md`）；
- `node check-setup.mjs && npx tsc -p check/tsconfig.json`：类型检查通过；
- 未删除参考原文件；未覆盖既有技能内容；未改 `entry/build/` 副本。

### 下一项
- 下一双数轮（R4）全面复查 questionnaire（尤其确认无简化/无自编、与 docx/xlsx 交付衔接）；后续单数轮候选：`html`（单页 HTML）、`content-rewrite`（一稿多发）等。

## 2026-09-17 R4（双数轮）：复查 questionnaire

### 复查内容
- **逐文件核对**：对 `questionnaire/references/m1..m4` 与 `CHANGELOG.md` 做 MD5 哈希比对，与参考源完全一致（IDENTICAL）；
- **SKILL.md 体量比对**：去除 frontmatter `name` 差异与末尾适配说明后，与 `doubao-questionnaire-designer/SKILL.md` 正文逐字符一致（2579 字符 = 2579 字符）；
- **适配说明核验**：SKILL.md 末尾新增的适配说明提到的 `write_docx` / `write_xlsx` / `transform_file` / `edit_xlsx` 均为本项目真实存在的工具（已在 `AgentLoopService`/`WorkToolRunner` 中核实），无幻觉工具名；
- **引用路径核验**：SKILL.md 内 `references/m1..m4` 与注册表、实际文件一一对应，未断裂；
- **登记核验**：`questionnaire` 全部文件均在 `WorkSkillService.registry()` 白名单内；`check-docs.py` 已覆盖。

### 结论
- 未发现简化、缩略或自编行为；未改动任何内容（本轮为纯复查）；
- 15 个技能 frontmatter 全部一致；`tsc` 通过。

### 下一项
- 下一单数轮（R5）候选：`html`（单页 HTML）、`content-rewrite`（一稿多发）；若选择需代码的重大 skill，则单轮只做一个并走 DevEco Studio 验证清单。

## 2026-09-17 R5（单数轮）：新增 content-rewrite（多平台内容改写分发）

### 目标
- 单数轮新增 1 个高频、通用、可复用、与现有技能不重复的技能。本轮选择 `content-rewrite`（Doubao 一稿多发，文档型非重大 skill，无需额外 app 代码）。

### 变更
- 完整复制 `doubao/skills/doubao-multiplatform-rewrite/` 全部内容到 `rawfile/skills/content-rewrite/`：
  - `SKILL.md`（8870 字符，<1.2 万无需拆段）；
  - `references/common/`：cover-design-methodology / distribution-package-format / fact-check-and-compliance / image-generation / internet-search / output-standard / source-analysis（7 个全文）；
  - `references/platforms/`：short-video / wechat / weibo / xhs（4 个全文）；
- 仅将 frontmatter `name` 改为 `content-rewrite`，并在 SKILL.md 末尾加本项目适配说明（飞书交付改 `write_file`/`write_docx`；配图用 `svg` 或用户供图；`internet-search` 对应 `search_web`）；
- `WorkSkillService.registry()` 登记 content-rewrite（11 个 reference 文件全量登记）；
- `test/pptx-harness/check-docs.py` 加入 content-rewrite 全部文档；
- `SKILL_PORTING_REPORT.md` 更新为 6 个新技能并记录 R5。

### 验证
- frontmatter：16 个技能目录名与 `name` 全部一致；
- 文档体量：content-rewrite 全部 <1.2 万字符，代码围栏平衡（唯一告警仍为历史遗留 `ppt/SKILL.md`）；
- `node check-setup.mjs && npx tsc -p check/tsconfig.json`：类型检查通过；
- 未删除参考原文件；未覆盖既有技能内容；未改 `entry/build/` 副本。

### 下一项
- R6（下一双数轮）全面复查 content-rewrite（确认无简化/无自编、与 write_docx/svg/search_web 衔接）；后续单数轮候选：`html`（单页 HTML）等。

## 2026-09-17 R6（双数轮）：复查 content-rewrite

### 复查内容
- **逐文件核对**：对 `content-rewrite/references/common/*.md`（7 个）与 `references/platforms/*.md`（4 个）做 MD5 哈希比对，与参考源完全一致（IDENTICAL）；
- **SKILL.md 体量比对**：去除 frontmatter `name` 差异与末尾适配说明（并忽略末尾空行）后，与 `doubao-multiplatform-rewrite/SKILL.md` 正文逐字符一致（8857 = 8858，仅差一个结尾空行，trim 后完全一致）；
- **适配说明核验**：SKILL.md 末尾适配说明提到的 `write_file` / `write_docx` / `svg` / `search_web` 均为本项目真实存在的工具/技能，无幻觉工具名；
- **引用路径核验**：SKILL.md 内 `references/common/*.md`、`references/platforms/*.md` 与注册表、实际文件一一对应，未断裂；
- **登记核验**：`content-rewrite` 全部 12 个文件均在 `WorkSkillService.registry()` 白名单内，`check-docs.py` 已覆盖。

### 结论
- 未发现简化、缩略或自编行为；未改动任何内容（本轮为纯复查）；
- 16 个技能 frontmatter 全部一致；`tsc` 通过。

### 下一项
- R7（下一单数轮）候选：`html`（单页 HTML）；非重大移植可一轮移植多个。

## 2026-09-17 R7（单数轮）：新增 html（单页 HTML 开发）

### 目标
- 单数轮新增 1 个高频、通用、可复用、与现有技能不重复的技能。本轮选择 `html`（Doubao 单页 HTML，文档型 + 参考脚本，非重大 app 代码移植）。

### 变更
- 完整复制 `doubao/skills/html/` 到 `rawfile/skills/html/`：
  - `SKILL.md`（10141 字符，<1.2 万无需拆段）；
  - `references/`：frontend-design / visual-techniques / 3d-design / chart-atlas / lark-apps-publish / windows-compat（6 个全文）；
  - `scripts/`：embed.py / shot.py（参考代码，全文保留）；
- frontmatter 原已是 `html`，未改名；仅在 SKILL.md 末尾加本项目适配说明（脚本不可执行、present_files/妙搭发布不可用、交付用 `write_file`、素材用 `download_file`、配图用 `write_svg`）；
- `WorkSkillService.registry()` 登记 html（6 个 references + 2 个 scripts 全量登记）；
- `test/pptx-harness/check-docs.py` 加入 html 的 SKILL.md + 6 个 reference 文档；
- `SKILL_PORTING_REPORT.md` 更新为 7 个新技能并记录 R7。

### 验证
- references 与 scripts MD5 哈希与参考源完全一致（IDENTICAL）；
- SKILL.md 正文（去掉适配说明，忽略结尾空行）与参考源逐字符一致（9857 = 9859，trim 后完全一致）；
- frontmatter：17 个技能目录名与 `name` 全部一致；
- 文档体量：html 全部 <1.2 万字符，代码围栏平衡（唯一告警仍为历史遗留 `ppt/SKILL.md`）；
- `node check-setup.mjs && npx tsc -p check/tsconfig.json`：类型检查通过；
- 未删除参考原文件；未覆盖既有技能内容；未改 `entry/build/` 副本。

### 下一项
- R8（下一双数轮）全面复查 html（确认无简化/无自编、与 write_file/download_file/write_svg 衔接正确）；后续单数轮候选：`paper-reviewer`、`skill-creator` 等。

## 2026-09-17 R8（双数轮）：复查 html

### 复查内容
- **逐文件核对**：`html/references/*.md`（6 个）与 `html/scripts/*.py`（2 个）MD5 哈希与参考源完全一致（IDENTICAL）；
- **SKILL.md 体量比对**：去除末尾适配说明（并忽略结尾空行）后，与 `doubao/skills/html/SKILL.md` 正文逐字符一致（9857 = 9859，trim 后完全一致）；
- **适配说明核验**：适配说明提到的 `write_file` / `download_file` / `write_svg` 均为本项目真实存在的工具；`present_files`、妙搭发布、Python 脚本执行均如实标注为不可用，无幻觉工具名；
- **引用路径核验**：SKILL.md 内 `references/*.md`、`scripts/*.py` 与注册表、实际文件一一对应，未断裂；
- **登记核验**：`html` 全部 9 个文件均在 `WorkSkillService.registry()` 白名单内，全部 md 文件已纳入 `check-docs.py`。

### 结论
- 未发现简化、缩略或自编行为；未改动任何内容（本轮为纯复查）；
- 17 个技能 frontmatter 全部一致；`tsc` 通过。

### 下一项
- R9（下一单数轮）候选：`paper-reviewer`、`skill-creator` 等；非重大移植可一轮移植多个。

## 2026-09-17 R9（单数轮）：新增 paper-reviewer + review-agent

### 目标
- 非重大文档型移植，本轮新增 2 个技能（上限 5 个以内）。

### 变更
- **paper-reviewer**（workbuddy 学术审稿）：完整复制 `SKILL.md` + `references/review-criteria.md` + `references/review-template.md`；仅在 SKILL.md 末尾加适配说明（PDF 用 parse_document/pdf_to_images，arXiv 用 download_file/web_fetch，搜索用 search_web）；
- **review-agent**（ChatGPT 代码评审）：完整复制 `SKILL.md` + `agents/openai.yaml`；仅在 SKILL.md 末尾加适配说明（无 git/终端，依赖用户提供 diff，用 read_file/search_files 读取）；
- `WorkSkillService.registry()` 登记 2 个技能（全部文件登记）；
- `test/pptx-harness/check-docs.py` 加入 paper-reviewer 3 个 md + review-agent SKILL.md；
- `SKILL_PORTING_REPORT.md` 更新为 9 个新技能并记录 R9。

### 验证
- references/yaml 哈希与参考源完全一致（IDENTICAL）；
- 两个 SKILL.md 正文（去掉适配说明，忽略结尾空行）与参考源逐字符一致（paper-reviewer 2912=2913、review-agent 2659=2660）；
- frontmatter：19 个技能目录名与 `name` 全部一致；
- 文档体量：新技能全部 <1.2 万字符，代码围栏平衡（唯一告警仍为历史遗留 `ppt/SKILL.md`）；
- `node check-setup.mjs && npx tsc -p check/tsconfig.json`：类型检查通过；
- 未删除参考原文件；未覆盖既有技能内容；未改 `entry/build/` 副本。

### 用户反馈修正（同轮 cleanup）：清理不可用工具/平台
- 用户指出原样复制保留太多不可用工具/平台，要求删除/改写不匹配项；
- **html**：删除 lark-apps-publish/windows-compat/embed.py/shot.py；SKILL.md 移除云电脑判定、妙搭发布、present_files、截图脚本自检，改为 write_file 交付 + 人工自检；
- **pdf**：重写 SKILL.md 为读取/搜索/扫描件阅读版；删除 original-prompt-2..4、advanced-libraries、forms-guide、generation-guide、security-guide、troubleshooting、extraction-guide（原内容以不可用脚本/库为主）；
- **translation**：移除 python-docx/pip/脚本与悬空 references；双语 Word 改 write_docx；medical-2/3/4/5 改为人工校验/文档交付，medical-5 移除不存在的豆包相邻技能路由；
- **review-agent**：正文 git merge-base/git diff 改为“用户提供 diff + read_file”；
- **questionnaire/content-rewrite**：飞书云文档/表格/Block 全局替换为 Markdown/Word/Excel/文档结构；
- **paper-reviewer**：WebSearch 已替换 search_web；
- 注册表与 check-docs 同步移除被删除文件；全部剩余文件仍登记；frontmatter 19 个、check-docs、tsc 均通过。

### 下一项
- R10（下一双数轮）全面复查 paper-reviewer + review-agent，并复查本轮不可用工具清理是否有遗漏；后续单数轮候选：`skill-creator`（meta，较大需拆段）等。

## 2026-09-17 R10（目标第 1 轮，单数轮）：新增 5 个高优先级技能

### 目标
- 按“先移植高优先级，分 2-3 轮完成”目标第 1 轮，非重大文档型移植 5 个技能：paper-rebuttal / research-lineage-map / marketing-plan / reference-audit / paper-close-reading。

### 变更
- **paper-rebuttal**（workbuddy 学术审稿回复）：完整复制 SKILL.md + 3 个 references；末尾加适配说明（parse_document/read_file 读取、edit/write_file 修改、write_docx 交付）；
- **research-lineage-map**（workbuddy 研究谱系演进图）：完整复制 SKILL.md + 2 个 references；删除不可用 `scripts/validate_mermaid.py`，第 6 步校验改为人工核对 Mermaid、交付用 write_file；WebSearch/WebFetch→search_web/web_fetch，present_files→write_file；
- **marketing-plan**（doubao 营销策划方案）：完整复制 SKILL.md + 4 个 references；飞书/Lark Doc 交付改写为 write_file（Markdown）/write_docx（Word）；output-format.md 中 `<grid>/<column>` 飞书分栏改为表格/分栏并排说明；
- **reference-audit**（doubao 参考文献审计）：完整复制 SKILL.md + assets/report-template.md；删除不可用 `scripts/lookup_metadata.py`，工具段改写为 search_web/web_fetch 核验 Crossref/PubMed/arXiv/DOI；飞书交付改为文件交付；
- **paper-close-reading**（doubao 论文精读）：完整复制 SKILL.md + assets/report-template.md；飞书交付改为 write_file/write_docx；“不适用”段豆包相邻技能改为本项目技能映射（research/reference-audit/paper/llm-eval/paper-reviewer）；
- 顺带清理：content-rewrite 参考资料残留的飞书 `<grid>/<column>`/Block 描述改为 Markdown/Word 排版规则；
- `WorkSkillService.registry()` 登记 5 个技能（全部文件登记），技能总数 19 → 24；
- `test/pptx-harness/check-docs.py` 加入 5 个技能全部 md；
- README.md / README_EN.md 技能系统、项目树、工具表、维护地图与 6.2.0 底部条目同步为 24 个技能（10 核心 + 14 移植）；
- SKILL_PORTING_REPORT.md 更新为 14 个新技能并记录本轮的 10h 段。

### 验证
- 新增文件全部为原提示词全文复制（仅删不可用脚本、改交付/检索工具描述，无简化）；各文件字符数 <1.2 万，无需拆段；
- frontmatter：24 个技能目录名与 `name` 全部一致；
- registry vs disk：24 个技能全部登记，无缺失、无未登记文件；
- `python test/pptx-harness/check-docs.py`：通过；
- `node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json`：通过；
- 未删除参考原文件；未覆盖既有技能内容；未改 `entry/build/` 副本。

### 下一项
- R11（下一单数轮）继续移植其余高优先级候选：khazix-writer / doubao-newmedia-writing / doubao-marketing-material-review / doubao-patent-drafting / doubao-journal-format / doubao-research-proposal / doubao-industry-analysis / doubao-sentiment-tracker 等（注意大文件拆段）。

## 2026-09-17 R11（目标第 2 轮，单数轮）：新增 khazix-writer + newmedia-writing + marketing-material-review + patent-drafting + sentiment-tracker

### 目标
- 按“先移植高优先级，分 2-3 轮完成”目标第 2 轮，非重大文档型移植 5 个技能。

### 变更
- **khazix-writer**（workbuddy 公众号长文写作）：完整复制 SKILL.md + references/content_methodology.md + references/style_examples.md；SKILL.md 原长 11914 字符接近 1.2 万上限，适配说明追加到 references/content_methodology.md 末尾，避免 SKILL.md 超长；交付用 write_file/write_docx，搜索用 search_web/web_fetch。
- **newmedia-writing**（doubao 新媒体写作）：完整复制 SKILL.md + 23 个 references；`references/genre-guide/lark-doc.writing-guide.md` 由 lark-cli 命令改写为 Markdown/Word 文档创建/写入/校验规则；`references/xhs.samples/xhs-note-proposal.samples.image-design-methods.md`（16324 字符）拆为 `image-design-methods.md`（上）+ `image-design-methods-2.md`（下），上篇末尾给出续读指引；SKILL.md 路由/自检与其余 guides/samples 全文保留。
- **marketing-material-review**（doubao 营销素材审核）：完整复制 SKILL.md；飞书报告交付改为 write_file/write_docx；法规检索改为 search_web/web_fetch。
- **patent-drafting**（doubao 专利申请文件撰写）：完整复制 SKILL.md + README.md + references/writing-style.md + sub-skills/{claims,intake-audit,specification}/SKILL.md；`scripts/patent_build.py` 本环境不可用已删除，“交付合同”改为「9 项人工自检清单（C1/C2/C3/C5/C7/C13/C14/格式一致性/事实分级）+ load_skill("docx") + write_docx 生成 Word」；降级路径改为 write_docx 失败时交付 draft.md + 手工自检；子 skill 中对脚本/C14 的引用同步改写。
- **sentiment-tracker**（doubao 舆情追踪）：完整复制 SKILL.md + references/{evaluation-set,twitter-guide,weibo-guide}.md + agents/openai.yaml；浏览器自动化（interaction.request_action/browserControl/gui-browser-task-skill/browser-task）改为 search_web/web_fetch + 用户提供原帖链接/截图；“豆包文档”交付改为 write_file/write_docx；“网页端/手机端”触发限制改为“公开可读页面/登录墙”限制。
- `WorkSkillService.registry()` 登记 5 个技能（khazix 2 + newmedia 23 + marketing 0 + patent 5 + sentiment 4 个 reference 文件），技能总数 24 → 29。
- `test/pptx-harness/check-docs.py` 加入 5 个技能全部 md。
- README.md / README_EN.md 技能系统、目录树、工具表、维护地图与 6.2.0 底部条目同步为 29 个技能（10 核心 + 19 移植）。
- SKILL_PORTING_REPORT.md 更新为 19 个新技能并记录本轮的 10i 段。

### 验证
- 新增文件保持原文提示词全文复制（仅删不可用脚本/平台、改交付/检索工具描述，无简化）；
- 各文件字符数 <1.2 万（唯一超长仍为历史遗留 `ppt/SKILL.md` 13026 字符）；`image-design-methods.md` 已拆分为上下篇；
- frontmatter：29 个技能目录名与 `name` 全部一致；
- registry vs disk：29 个技能全部登记，无缺失、无未登记文件；
- `python test/pptx-harness/check-docs.py`：通过；
- `node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json`：通过；
- 未删除参考源文件；未覆盖已有技能内容；未改 `entry/build/` 副本。

### 下一项
- R12（双数轮）全面复查本轮 5 个技能（重点核对 newmedia-writing 的 lark-doc.writing-guide.md 改写是否完整、patent-drafting 的脚本引用是否清干净、sentiment-tracker 的平台限制改写是否一致），并复查上一轮 5 个技能；
- R13（下一单数轮）移植剩余高优先级候选：doubao-journal-format / doubao-research-proposal / doubao-industry-analysis；其中 doubao-journal-format 体量最大，需拆分多个 >1.2 万字符文件并删除大量 py 脚本；doubao-research-proposal 的 assets/templates/*.doc/.docx 为二进制模板，需决定排除或改写。

## 2026-09-17 R13（目标第 3 轮，单数轮）：新增 journal-format + research-proposal + industry-analysis

### 目标
- 按“先移植高优先级，分 2-3 轮完成”目标第 3 轮（收尾），非重大文档型移植 3 个技能，完成全部 13 个高优先级候选。

### 变更
- **journal-format**（doubao 学术论文 DOCX 格式排版）：完整复制全部 .md；SKILL.md（11683 字符）与 6 个 references 均超 1.2 万字符上限，用 `test/pptx-harness/_split_jf.py` 拆分为 `SKILL.md`+`SKILL-2..5.md` 与 `references/*（含 -2/-3 片段）`，全部 <1.2 万字符；未复制 `scripts/*.py`、`render_docx.py`、`fallback_ooxml_spec.json`；`SKILL-5.md` 的 Command 整节改写为「本项目 `docx` 技能 + 人工自检执行说明」；references 中 soffice/PyMuPDF/pdfplumber/pdftotext/mutool/脚本命令统一改写为非可执行说明并加适配批注；拆分片段尾部统一加续读指引。
- **research-proposal**（doubao 学术立项书/基金申请）：完整复制 SKILL.md + 7 个 references；二进制 `assets/templates/*.doc/.docx` 未移植，模板章节与 `academic-grant-guide.md` 改写为“官方最新模板/用户模板优先 + 结构要点表 + `【待补充：官方模板字段】` 占位”；飞书/lark-cli 交付改为 `write_file`/`write_docx`；相邻豆包技能（academic-researcher/polish/evaluator）改为本项目 research/paper/humanizer/paper-reviewer 映射；`literature-review-guide.md` 的 doubao-academic-researcher/scholar_search 改为本项目 research 技能 + search_web/web_fetch。
- **industry-analysis**（doubao 行业深度研究）：完整复制 SKILL.md + 8 个 references + agents/openai.yaml；未复制 `scripts/{assemble_report,renumber_references,validate_report,upload_report,report_pipeline_common}.py`；`references/lark-doc-report-standard.md`（174 行）全文改写为 Markdown 拼接与文件交付标准（人工合并/整篇人工校验替代原脚本与 lark-cli）；OrganizerAgent/subagent 统筹改为同一执行者（可按需 `subagent` 并行取证）+ `write_file`/`write_docx` 交付；`general_search`/`seed_finance_search` 映射 `search_web`/`web_fetch` 定向检索；`agents/openai.yaml` 去飞书字样；report-finalization/data-grading/insight-spine/task-router 中零散飞书/脚本残留同步改写。
- `WorkSkillService.registry()` 登记 3 个技能（journal-format 21 + research-proposal 7 + industry-analysis 9 个 reference 文件），技能总数 29 → 32。
- `test/pptx-harness/check-docs.py` 加入 3 个技能全部 md（含拆分片段）。
- README.md / README_EN.md 技能系统、目录树、工具表、维护地图与 6.2.0 底部条目同步为 32 个技能（10 核心 + 22 移植）。
- SKILL_PORTING_REPORT.md 更新为 22 个新技能并记录本轮的 10j 段。
- 清理：`test/pptx-harness/_split_jf.py`、`_cleanup_jf.py` 为临时工具，后续删除。

### 验证
- 新增文件保持原文提示词全文复制（仅删不可用脚本/平台、改交付/检索工具描述、拆分超大文件，无简化）；
- 各文件字符数 <1.2 万（唯一超长仍为历史遗留 `ppt/SKILL.md` 13026 字符）；journal-format 拆分后全部片段 <1.2 万；
- frontmatter：32 个技能目录名与 `name` 全部一致；
- registry vs disk：32 个技能全部登记，无缺失、无未登记文件；
- `python test/pptx-harness/check-docs.py`：通过（仅历史遗留 ppt/SKILL.md TOO LONG，且 fences 平衡）；
- `node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json`：通过；
- 未删除参考源文件；未覆盖已有技能内容；未改 `entry/build/` 副本。

### 下一项
- R14（双数轮）全面复查本轮 3 个技能（重点核对 journal-format 拆分链与脚本改写是否一致、research-proposal 模板占位是否合理、industry-analysis 的 lark-doc-report-standard.md 改写是否完整），并复查 R11 的 5 个技能；
- 全部 13 个高优先级候选已移植完毕，后续偶数轮进入系统性复查/迭代阶段。

## 2026-09-17 R14（双数轮）：22 个移植技能结合本应用工具的定制化适配

### 目标
- 结合本应用真实工具（docx / xlsx / ppt / svg / data 核心技能 + read/write/edit 系列 + pdf/search_pdf/pdf_to_images + search_web/web_fetch + write_file + subagent），对全部 22 个移植技能做定制化适配，把「泛泛的写文件/上传文档」改写为可执行的「`load_skill(核心技能)` + 具体工具调用」指令。

### 变更（按批次）
- **批次 A（Office/方案类）**：
  - `research-proposal`：Word 正式提案用 `load_skill("docx")` + `write_docx`；事实台账/参考文献清单可另交付 `load_skill("xlsx")` + `write_xlsx`。
  - `industry-analysis`：数据台账与关键对比表用 `load_skill("xlsx")` + `write_xlsx`/`edit_xlsx`；报告 Markdown 或 `load_skill("docx")` + `write_docx`；可选执行摘要 `load_skill("ppt")` + `write_pptx`。
  - `patent-drafting`：保持 docx 深度绑定；用户要求权利要求对照表时用 `load_skill("xlsx")` + `write_xlsx`（不暴露内部编码）。
  - `marketing-plan`：Word 用 `load_skill("docx")` + `write_docx`；预算/排期/效果预估表用 `load_skill("xlsx")` + `write_xlsx`；配图用 `write_svg`。
  - `newmedia-writing`：Word 用 `load_skill("docx")` + `write_docx`；分镜脚本表/内容日历用 `load_skill("xlsx")` + `write_xlsx`；封面/配图用 `write_svg`。
  - `khazix-writer`：交付说明写入 `references/content_methodology.md`（长文 `write_file` / Word `load_skill("docx")` + `write_docx`；配图位 `write_svg`）。
- **批次 B（学术/审计类）**：
  - `questionnaire`：加深 M3/M4——标签体系+全量标注、清洗后数据+统计表用 `load_skill("xlsx")` + `write_xlsx`，M4 用 `transform_file`/`edit_xlsx` 清洗。
  - `sentiment-tracker`：报告 `write_file` 或 `load_skill("docx")` + `write_docx`；舆情台账用 `load_skill("xlsx")` + `write_xlsx`（链接保持可点击）。
  - `reference-audit`：Word 审查书用 `load_skill("docx")` + `write_docx`；待核验条目/核验结果台账用 `load_skill("xlsx")` + `write_xlsx`。
  - `paper-rebuttal`：rebuttal 主交付 docx/Markdown；意见清单表/修改日志用 `load_skill("xlsx")` + `write_xlsx`；DOCX 论文修改用 `read_docx`/`edit_docx`。
  - `paper-reviewer`：review 输出 docx/Markdown；修改清单用 `load_skill("xlsx")` + `write_xlsx`。
  - `paper-close-reading`：Word 报告用 `load_skill("docx")` + `write_docx`；关键图表/数字核对表可选 `load_skill("xlsx")` + `write_xlsx`。
- **批次 C（写作/通用类）**：
  - `translation`：术语表用 `load_skill("xlsx")` + `write_xlsx`（保留 docx 双语交付）。
  - `humanizer`：改写稿 Word 用 `load_skill("docx")` + `write_docx`；前后对照表可选 `load_skill("xlsx")` + `write_xlsx`。
  - `prompt-engineering`：Prompt 清单/评估用例表用 `load_skill("xlsx")` + `write_xlsx`。
  - `content-rewrite`：Word 分发包 `load_skill("docx")` + `write_docx`；平台分发对照表/发布检查表用 `load_skill("xlsx")` + `write_xlsx`。
  - `marketing-material-review`：审核报告 docx/Markdown；逐条审核表用 `load_skill("xlsx")` + `write_xlsx`。
  - `research-lineage-map`：节点明细表用 `load_skill("xlsx")` + `write_xlsx`；可选 SVG 版演进图用 `write_svg`。
  - `html`/`pdf`/`journal-format`：移植期已深度接入，无需大改。
- 新增 `ADAPTATION_PLAN.md` 记录 22 个技能的定制适配计划与状态（含已完成标记）。

### 验证
- 全文保持原文提示词体量不简化；适配均以「适配说明/定制段落」追加，未删原文规则；
- `python test/pptx-harness/check-docs.py`：通过（仅历史遗留 ppt/SKILL.md TOO LONG，fences 平衡）；
- frontmatter：32/32 目录名与 `name` 一致；
- registry vs disk：无缺失、无未登记文件；
- `node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json`：通过；
- README/README_EN 计数不变（仍 32 个 / 22 个移植），无需改动。

### 下一项
- 继续维护：若有新增候选技能移植，按奇数轮进行；偶数轮继续复查/迭代已适配技能与文档同步。

## 2026-09-20 R15：文件预览不支持时支持“用其他应用打开”

### 目标
- 工作区文件点击“预览”时，如果系统 Preview Kit 不支持该格式（如 `.md`），不再只提示“暂不支持”，而是提供“用其他应用打开”入口，拉起系统“打开方式”选择框，让用户选择手机上已安装的对应应用打开文件。

### 变更
- `entry/src/main/ets/viewmodel/ChatViewModel.ets`：
  - `previewWorkspaceFile()`：`filePreview.canPreview()` 返回不支持时，直接调用 `openWorkspaceFileWithOtherApp()`，不再弹中间确认框。
  - 新增 `openWorkspaceFileWithOtherApp()`：构造隐式 `Want`（`action: 'ohos.want.action.viewData'` + `uri` + UTD `type` + 读写 `flags` + `ability.params.stream` 数组 + `ohos.ability.params.showDefaultPicker=true`）并调用 `startAbility()`，强制系统展示“打开方式”选择弹框；无可用应用时 toast 提示“未找到可打开该文件的应用”。
  - 从 `@kit.AbilityKit` 增加导入 `Want`、`wantConstant`。
- 该入口自动覆盖 `WorkspaceBar`、`WorkArtifactsCard`、`ChatPage` 工作区列表等所有调用 `previewWorkspaceFile` 的位置。

### 验证
- 真机反馈：初版 `.md` 选择“用其他应用打开”时直接拉起系统“文件预览”应用并显示预览失败，而不是应用列表。
- 已对照官方文档修正：`type` 改用 UTD（与文件后缀一致）、增加 `flags` URI 读写授权、`ability.params.stream` 改为 string 数组、并设置 `ohos.ability.params.showDefaultPicker=true` 强制展示打开方式弹框。
- 本机尝试 `assembleHap` 构建验证时遇到环境问题：`~/.hvigor/project_caches/.../workspace/node_modules/@ohos/hvigor` 工程缓存已损坏（首次构建即报 `ENOENT ... hvigor.js`），且 DevEco Studio 正在运行导致缓存目录被占用，无法按提示重建。
- 建议在 DevEco Studio 中关闭工程/退出 IDE 后清理 `~/.hvigor` 重建缓存，再执行 `assembleHap` 做最终编译验证。

### 下一项
- 在真机/模拟器验证 `.md` 等不支持系统预览的文件：点击预览 → 系统直接弹出“打开方式”选择应用并成功打开；无可用应用时提示友好。
- 如产品需要，可再为支持预览的文件增加“更多”菜单里的“用其他应用打开”快捷入口。
