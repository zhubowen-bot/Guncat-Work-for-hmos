# Guncat Work 6.1.0 — DeepSeek Harness 移植说明

把 [DeepSeek Harness](https://github.com/deepseek-ai)（dsh）的核心 Agent Loop 能力移植到
HarmonyOS 原生应用（基座为 GuncatAI_HMOS-APP 的「工作模式」），形成运行在鸿蒙 2in1/平板/手机
上的 **Guncat Work 6.1**。无 shell 环境是前提：dsh 依赖进程的工具（bash/terminal/lsp）不移植，
其余整套逻辑以 ArkTS 原生实现；dsh 的 PTC(run_code) 由本机 JS 引擎沙箱 `run_js` 顶替（见第四节）。

## 一、从 DeepSeek Harness 移植了什么

### Agent Loop 内核
| 能力 | dsh 原型 | 本实现 |
|---|---|---|
| 追加式会话事件日志(JSONL) | `core/session` + `session-persistence-jsonl` | `service/SessionLogService.ts`，`<filesDir>/sessions/<convId>.jsonl`，`turn_start / assistant_message / tool_result / turn_end` 留痕，"进入请求的必留痕" |
| 有界并行工具池 + 模型序提交 | `core/agent-loop/tool-calls.ts`（rolling pool / exclusive barriers） | `ChatViewModel.executeWorkLoop`：只读调用段并发，池上限 `WORK_MAX_PARALLEL_TOOLS=4`；改动类调用串行屏障 |
| 粘性 max-tokens | turn 以 max-tokens 收尾 | `AgentLoopService.extractFinishReason`（三协议）+ 循环收尾标注"发送'继续'" |
| 用户插话（steering） | inbox `next-step` 队列 | 任务执行中发送消息 → `workSteerQueue` → 本轮工具结束后注入`【用户补充】`；不打断任务 |
| 工具结果溢出暂存 | `spill` 包 | `service/SpillStore.ts`：全文落盘工作区 `.spill/`，模型收头尾节选+定位提示，可 read_file 读回 |
| 重复调用提醒 | `guard` repeat-tool reminder | `noteWorkRepeat`（沿用基座，3/5/8 次提醒） |
| 前缀复用式上下文压缩 | `compaction-basic` | 沿用基座两级压缩（修剪→前缀复用摘要→整条裁剪），usage 锚定预算 |
| LLM 请求重试 | `llm-retry` | 沿用基座（指数退避+抖动，429/5xx/transport/empty） |
| LLM 会话标题 | `session-title` | `AgentLoopService.generateSessionTitle`，每会话一次，失败静默 |
| 提问/交互 | `ask_user` + `ui-user-questions` | `service/AskUserBridge.ts` + `views/AskUserCard.ets`：单选/多选/文字补充，提交按钮统一发送，超时与中断兜底 |
| 会话提醒 | `schedule` | `service/ScheduleService.ts`（`.schedule.json` 持久化，循环≥300s，到期注入用户消息，运行中走插话通道） |
| 自主目标 | `goal` | `service/GoalService.ts`（`.goal.json`，随运行时快照注入） |
| 子代理（进程内形态） | `subagent` in-process | `service/SubagentService.ts`：共享工作区、独立上下文、≤40 步、排除 subagent/ask_user/todo_write 等的定制工具面，最终报告作为工具结果 |

### 新增工具（对齐 dsh 工具目录，纯本地实现）
- **glob / grep**（dsh tool-fs-search）：`common/PathMatcher.ts`（`**`/`*`/`?`/`{a,b}`/`[...]`，顶层逗号不破坏分支）+ `common/FileSearchCore.ts`（注入式 `FsAdapter`，设备侧接 fileIo，桌面 Node 侧接内存/文件系统，双端同一套逻辑）。
- **edit**（dsh tool-fs）：逐字符唯一匹配替换 + `common/DiffUtil.ts` 行级 LCS diff（hunks、±统计、meta 持久化、UI 重放）。
- **str_replace_editor**（dsh str-replace-editor）：view/create/str_replace/insert 四命令。
- **web_fetch**（dsh web-fetch-http）：GET ≤2MB、HTML 剥离为可读文本、实体解码、截断标注。
- **ask_user_question / schedule_* / goal_* / subagent / session_search**：见上表。
- **run_js**（顶替 dsh 的 PTC/run_code，非移植而是新能力）：`service/JsCodeService.ts` + 原生 `libguncatjs.so`（`entry/src/main/cpp`，JSVM-API）。每次执行新建独立 JS 引擎实例，文件由 ArkTS 侧显式预载/落盘，详见 README「3.4 run_js：设备内 JS 执行沙箱」。

### UI（对齐 dsh web 端视觉）
- 设计令牌：`--dsw-*` 色板整体移植进 `resources/base|dark/element/color.json`（浅色白底 + deepseek-500 强调；深色 `neutral-bluish-950` 底 + deepseek-450）。
- 三栏框架（dsh `AppFrame`）：宽屏（≥700vp）左侧栏 | 会话列 | 右详情列；窄屏保持单列+抽屉。
  - `views/DswSidebar.ets`：品牌行/新建会话(38vp bar r12)/引擎与会话列表/底部设置，可折叠为 56vp 图标栏。
  - `views/DetailsPanelView.ets`：本轮统计（tok/s、缓存命中、工具数）、目标、工作区文件管理，宽屏自动展开 + 手动刷新。
- 工具行（dsh `ToolRow` 24px 规格）：`views/WorkTurnView.ets` 重写——图标+标题+2×2 分隔点+省略摘要+状态；展开为 IO 卡片（radius 12 + 代码底 + IN/OUT 槽位标签，长内容槽内滚动）；edit 渲染 **dsh DiffBlock 风格 diff 卡片**（+绿 −红 + `└ +A -R` 统计）；todo_write 渲染任务清单；最终回复附统计行。
- 插话输入：执行中发送键变为"插话发送 + 停止"双按钮。

### 保留的基座能力（dsh 没有的部分）
原有 25 个工具全部保留并可继续使用：Office 文字层读取、write_docx（含 OMML 公式）、write_xlsx、
write_pptx/read_ppt/edit_ppt（Deck DSL + 8 主题 + 图表）、write_svg（栅格化预览）、CSV/TSV、
transform_file 数据管道、parse_document/search_pdf/pdf_to_images、download_file、view_image、
record_search、技能系统（ppt/svg/data）。沙箱工作区形态不变（`<filesDir>/workspaces/<convId>`，
`resolveSafe` 拒绝越界路径），对外通过系统安全组件（DocumentViewPicker）上传/导出，无存储权限——
便于整体移植到其他鸿蒙设备。

## 二、验证

```bash
# 纯逻辑测试(PathMatcher/DiffUtil/FileSearchCore, 58 项)
cd test/guncat-harness && node setup.mjs && node test-core.mjs

# 服务层类型级检查(扁平化 + @kit stubs + tsc --noEmit; libguncatjs.so 用 jsvm-shim 桩替代)
node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json

# 真机构建(命令行构建需先设置 DEVECO_SDK_HOME, 例如
#   $env:DEVECO_SDK_HOME="C:\Program Files\Huawei\DevEco Studio\sdk")
"C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" `
  "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
  --mode module -p module=entry@default -p product=default assembleHap
# 产物: entry/build/default/outputs/default/entry-default-signed.hap
# run_js 的原生库会编译打包为 libs/{arm64-v8a,x86_64}/libguncatjs.so
```

## 二·补、run_js 的原生部分（JSVM-API 沙箱）

- **为什么用 JSVM-API**：ArkTS 禁止 `eval`/`new Function`（编译期就拒绝），应用内执行动态代码只能靠 JSVM-API 自建 JS 引擎实例（`libjsvm.so`，NDK C 接口，API 11 起，syscap `SystemCapability.ArkCompiler.JSVM`，三方应用可直接链接）。`napi/native_api.h` 负责 ArkTS↔C++，`ark_runtime/jsvm.h` 负责任务内的 JS 执行。
- **文件**：`entry/src/main/cpp/{CMakeLists.txt, jsvm_sandbox.h/.cpp, napi_init.cpp}` + `cpp/types/libguncatjs/{index.d.ts, oh-package.json5}`；`entry/build-profile.json5` 新增 `externalNativeOptions`（CMake 路径 + abiFilters）。
- **线程模型**：执行挂在 Node-API 异步任务（worker 线程）上，绝不占用 UI 线程；每次执行自建 VM + 上下文，执行完按规范逆序销毁。
- **不可中断**：JSVM-API 没有终止执行的接口，死循环只能"放弃等待"——ArkTS 侧超时后把错误交还模型，并累计放弃次数，达到上限（2 次）即在本会话停用 `run_js`，避免持续满核耗电。
- **边界收敛**：堆上限/源码长度/stdout/输出文件数与体积都有上限，且 native 侧对传入上限再做一次夹取；路径校验只在 ArkTS 侧 `resolveSafe()` 一处实现。
- **改 native 后必须实机构建**（`assembleHap` 会跑 CMake/Ninja）；Node 侧测试无法覆盖原生逻辑，只能做类型级检查。

## 三、与 dsh 的刻意差异
- 无 shell/终端/LSP：鸿蒙无法运行子进程，相关工具不移植；grep 用正则引擎实现而非 ripgrep。dsh 的 PTC(run_code) 由 `run_js`（JSVM-API 沙箱，纯计算 + 显式文件桥接）顶替，能力等价但更受限：无网络、无模块加载、不可中断。
- 事件日志为轻量补充，会话 UI 状态仍存 Preferences（带 OOM 防护），二者互补。
- 子代理为前台阻塞式（无后台 job 调度），最多 40 步，报告制收口。
- bundleName 沿用 `com.bowenapp.guncatai`（沿用现有签名材料）；如需独立身份，改 bundleName 后重新生成签名 profile。

## 四、后续核心层迭代（R13–R42）

6.1.0 移植完成后的核心层迭代记录在 `ITERATION_LOG.md`（R1–R42，逐轮验证）；`BACKLOG.md` 维护当前待办。主要技术方向：

- **决策层纯逻辑化**：`ToolScheduler` / `RepeatDetector` / `LoopDecisions` / `WorkLoopPlanner` / `WorkLoopSimulator` / `WorkLoopDriver` / `WorkLoopStateMachine` 全部抽到 `common/`，ChatViewModel 只做 IO 注入。
- **三协议统一**：`LLMProtocol`（协议/端点）、`ToolDefAdapter`（工具形态）、`SSEProtocolAdapter` + `SSEAdapterFactory`（SSE 流水线）成为单一事实源，工作/聊天模式共用。
- **错误/重试**：`RetryPolicy`（指数退避+jitter+retry-after）、`RetryAfterParser`、`ToolRetryPolicy`、`LoopError`（显式 `retryable`/`userMessage`）迁移纯层；`runTurnWithRetry` 先判显式可重试再走策略。
- **插件/技能体系**：`ToolRegistry` 统一工具+技能元数据；`PluginManifestLoader` 解析 manifest；`PluginHotLoader` 从 rawfile 热加载/reloadAll；`PluginToolExecutor` 声明式工具实现注册；`SkillDirectoryFormatter` 提供技能目录渐进披露 A/B。
- **可观测**：`LoopMetrics` 增加重试/压缩/max_tokens 计数；`SessionLogAggregator` 支持协议维度、工具延迟 p50/p90/p99、跨会话聚合；日志新增 `tool_latency` 事件。
- **测试规模**：`test/guncat-harness/test-core.mjs` 从 58 项增长到 **256 项全绿**；每轮均通过类型检查与 DevEco `assembleHap`。

