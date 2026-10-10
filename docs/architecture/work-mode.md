# 工作模式架构与维护指南

> [← 返回 README](../../README.md)


工作模式是独立的 Agent 执行环境：一个虚拟智能体 + 一个每会话独立的沙箱工作区 + 一个多轮工具调用循环。本节面向维护者，说明各模块职责、数据流与扩展方法。

> **维护文档地图**（改哪块看哪份）：
> 
> - 本文档——架构、工具/技能/PPT 三套系统的设计与扩展步骤；
> - `ITERATION_LOG.md`——Agent Loop 核心层逐轮改动与验证记录（R1–R64）；
> - `BACKLOG.md`——当前待办与已完成的审计维度；
> - `PORT_NOTES.md`——dsh 移植对照与后续核心层迭代说明；
> - `test/pptx-harness/README.md`——PPT 生成器与 CSV 写入器的离线验证环境（Node 构建 + python-pptx 校验 + PNG 目检），改 `export/` 下任何文件后必跑；
> - `entry/src/main/resources/rawfile/skills/`——**模型看到的**操作指南（5 个主 Skill：`research-intelligence`/`academic-publishing`/`content-writing`/`legal-ip`/`ai-tooling`，各含 `SKILL.md` + `ROUTING.md` + 分支子目录；7 个格式分支顶层直连：`ppt`/`docx`/`xlsx`/`svg`/`data`/`html`/`pdf`；`list_skills` 只暴露这 12 个可见技能，25 个分支由主 Skill 路由后按原 id 加载），是随工具演进同步维护的文档，也是可移植到其他 Agent 框架的复用资产。

## 1. 身份与会话模型

- **虚拟智能体**：`Constants.WORK_AGENT_ID = 'work'`。启动时由 `ChatViewModel.buildWorkAgent()` 注入智能体列表顶部；`AgentDrawerView` 将其拆为独立的「Agent模式」分组展示在「聊天模式」标题上方，与聊天智能体**平行**展示（对 `id === 'work'` 特判渲染 🛠 徽标）。
- **进入/退出**：侧边栏点击「工作模式」= `selectAgent('work')`；点击任意真实智能体即退出（`lastChatAgentId` 记录最近使用的真实智能体，供工具行的工作模式胶囊退出时回切）。
- **会话绑定**：`Conversation.mode = 'chat' | 'work'`；工作会话 `agentId` 固定为 `'work'`，启动时对旧数据自动迁移。删除工作会话会同步清理沙箱工作区目录。
- **开关差异**：进入工作模式强制开启深度思考（工具行不显示该开关）；联网搜索保留（服务端搜索工具与客户端函数工具并存下发）；上传/拍照直接进入工作区而非聊天附件。
- **持久化**：会话 JSON 新增 `mode` 与 `Message.toolCalls`（`ToolCallRecord[]`，含调用参数/结果/耗时，重启后据此还原时间线与 LLM 历史）。会话存档（`filesDir/guncat_conversations.json`）与工作区文件本体都存沙箱 `filesDir`，不进 Preferences。

## 2. Agent Loop（`ChatViewModel.executeWorkLoop`）

```text
for step in 1..WORK_MAX_STEPS(200, 防失控保险):
  1. 新建一条 assistant 消息（本轮的思考/工具/文本都挂在它上面）
  2. 预算检查: 超 85 万 token(1M×0.85, usage 锚定)时先无模型修剪早期工具结果,
     再把早期历史压缩为状态摘要（仅当修剪不够时才调模型）
  3. 追加「运行时上下文」快照(日期+文件树+任务清单)到历史末尾(内容未变则不追加)
  4. AgentLoopService.runTurnWithRetry(三协议流式请求, 含工具定义;
     429/5xx/网络传输/空响应自动指数退避重试)
  5. 无工具调用 → 本轮即最终回答，结束
  6. 有工具调用 → 连续只读调用并发执行、其余逐个执行（WorkToolRunner），结果写回 ToolCallRecord
     - 变更类工具执行后刷新工作区文件列表
     - view_image 成功后注入一条携带图片的多模态 user 消息（仅内存）
  7. 本轮(assistant + 工具结果)进入请求历史，继续下一轮
```

- **循环驱动引擎（默认启用）**：`WORK_USE_DRIVER_LOOP=true`，`executeWorkLoop` 先分派到 `executeWorkLoopDriver`，由 `WorkLoopDriverBridge.runWithStep` + `runDriverStep` 驱动循环级状态机/计划器；旧 `executeWorkLoop` 保留可回退（改回 `false` 即可）。
- **每轮一条消息**是时间线 UI 的数据基础：消息列表天然按「思考→工具→正文」时序排列，不再复用单条大消息。
- **上下文自动压缩（缓存感知，对齐 DeepSeek Harness）**：预算优先用上一请求真实 prompt tokens（usage 锚定）对比 `WORK_CONTEXT_WINDOW_TOKENS`×0.85（1M×0.85=85 万 token），无 usage 数据时按会话实测字符→token 比例估算。超预算时两级处理：先无模型修剪早期过长工具结果（头尾节选 + 精确省略提示），不够再把早期历史交给模型压缩成「状态摘要」（≤2400 字，保留最近 12 条原样）——摘要请求自带完整前缀（静态系统提示词+工具定义+历史），对模型侧 KV 缓存是上一请求的延续而非冷启动，前缀按缓存命中计价。摘要失败或仍超预算才回退为从最旧处整条丢弃；若请求直接报上下文超限，强制压缩后自动重试一次。任务清单与工作区文件不参与压缩，始终可被模型 `read_file` 找回——这是长任务跨上下文存续状态的关键。时间线上会标注「已自动压缩早期历史」。
- **前缀缓存设计**：系统提示词全静态（构建一次不再变）；日期/文件树/任务清单以「运行时上下文」快照 user 消息追加到历史末尾、且仅在内容变化时追加；历史严格追加式增长（压缩是唯一改写历史的操作）——相邻两轮请求共享逐字节相同前缀，模型侧 KV 缓存可跨轮命中，写文件后也只有末尾一小段需要重算。
- **中断**：`stopStreaming()` 同时调用 `ChatService.abort()` 与 `AgentLoopService.abort()`；中断轮若无产出则移除消息，否则追加「⏹ 任务已手动停止」。
- **步数保险**：`WORK_MAX_STEPS(200)` 仅作为失控保护（防止工具调用死循环持续消耗），正常长任务触不到；触发后在最后一条消息标注「发送“继续”可接着执行」。

## 2.1 核心层纯逻辑迭代（R13–R64，维护者看这里）

6.1 之后对 Agent Loop 核心层做了系统性迭代，把“可决策、可测试”的部分抽成 `common/` 纯逻辑模块，运行期只做 IO 注入。改循环逻辑先看这批文件：

- **决策/编排层**：`ToolScheduler`（调度分组 + `SchedulerSummary` 统计）、`RepeatDetector`（重复防护）、`LoopDecisions`（快照去重/溢出压缩/max_tokens/无效步判定）、`WorkLoopPlanner`（单轮 TOOL/FINISH/ABORT/COMPACT + `describe` 可读描述）、`WorkLoopSimulator`（全循环回归）、`WorkLoopDriver`（循环主体纯驱动：状态机+计划器+重试/压缩回调）、`WorkLoopDriverBridge` + `LoopTurnInfoMapper` + `WorkLoopStepInfoBuilder`（真实循环接入桥梁/单步信息纯构造）、`WorkLoopStateMachine`（idle/running/paused/awaiting_user/aborting）。
- **协议层**：`LLMProtocol`（协议/端点单一事实源）、`ToolDefAdapter`（三协议工具形态）、`SSEProtocolAdapter` + `SSEAdapterFactory`（SSE 解析统一流水线，工作/聊天共用）。
- **错误/重试**：`RetryPolicy`（指数退避+jitter+retry-after+可重试 kind）、`RetryAfterParser`（Retry-After 头解析）、`ToolRetryPolicy`（工具级重试）、`LoopError`（显式 `retryable`/`userMessage`，纯层可单测）。
- **插件/技能**：`ToolRegistry`（工具+技能元数据单一事实源）、`PluginManifestLoader`（manifest 解析/apply/unload）、`PluginHotLoader`（rawfile 热加载/reloadAll）、`PluginToolExecutor`（插件工具声明式实现注册）、`SkillDirectoryFormatter`（技能目录 full_index/trigger_only A/B）。
- **可观测**：`LoopMetrics`（重试/压缩/max_tokens 计数）、`SessionLogAggregator`（协议维度 + 工具延迟 p50/p90/p99 + 跨会话聚合）、`PromptBudget`（token 预算估算）。
- **测试**：`test/guncat-harness` 纯逻辑用例 **521 项全绿**；改 `common/` 后跑 `node setup.mjs && node test-core.mjs`，再 `node check-setup.mjs && tsc -p check/tsconfig.json`，最后 `assembleHap` 真机构建。

每轮改动与验证记录在 `ITERATION_LOG.md`；当前待办见 `BACKLOG.md`；dsh 移植对照见 `PORT_NOTES.md`。

## 3. 工具系统（45 个）

分发链：`ChatViewModel` → `WorkToolRunner.execute()`（.ets 入口）→ Office 生成/parse_document/PPT/transform_file 就地实现，其余委托 `WorkFileService.executeTool()`（.ts），6.1 新增工具由 `HarnessTools.dispatch()`（.ts）兜底。

| 工具                                                      | 实现位置                                                                        | 说明                                                                                                                                                                                                 |
| ------------------------------------------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `todo_write`                                            | WorkFileService.toolTodoWrite                                               | 任务清单写入 `.todo.json`，支持数组/内嵌 JSON 字符串两种传参                                                                                                                                                           |
| `list_files`                                            | WorkFileService.toolList                                                    | 递归列目录，目录优先排序，含大小                                                                                                                                                                                   |
| `read_file`                                             | WorkFileService.toolRead                                                    | 文本直读；`.docx/.xlsx/.pptx`→OfficeReader，`.pdf`→PdfTextExtractor                                                                                                                                      |
| `write_file` / `append_file`                            | WorkFileService.toolWrite                                                   | 覆盖/追加写文本（512KB 上限，自动建父目录）                                                                                                                                                                          |
| `delete_file` / `create_dir` / `move_file`              | WorkFileService.toolDelete/toolMkdir/toolMove                               | 递归删除/建目录/移动（moveFileSync/moveDirSync）                                                                                                                                                              |
| `search_files`                                          | WorkFileService.toolSearch                                                  | 文本类文件大小写不敏感子串搜索，带行号；`glob` 参数按文件名过滤（`*`/`?`，逗号分隔多模式），目录仍递归                                                                                                                                         |
| `view_image`                                            | WorkFileService.toolViewImage                                               | 图片→dataUrl（≤8MB），由循环注入下一条多模态消息                                                                                                                                                                     |
| `download_file`                                         | WorkToolRunner.toolDownloadFile                                             | http(s) 文件下载进工作区（≤20MB；类型嗅探 + html 告警；自动命名或指定 path）                                                                                                                                                |
| `parse_document`                                        | WorkToolRunner.toolParseDocument                                            | PDF 完整文本（本地，3 倍输出上限）                                                                                                                                                                               |
| `search_pdf` / `pdf_to_images`                          | WorkToolRunner.toolSearchPdf / toolPdfToImages                              | PDF 文字层关键词搜索（页码 + 摘录，≤50 处）；扫描件/纯图片 PDF 按页渲染成图片存入 `pdf_images/<文件名>/`，再交给 `view_image` 逐张查看                                                                                                  |
| `write_docx`                                            | WorkToolRunner.toolWriteDocx → DocxBuilder.buildFromMarkdown/buildDocxBytes | **Doc JSON / doc 文件 / Markdown → Word**（详见下节；可带 title/style；图片走工作区/data URL/http，svg 自动栅格化）                                                                                                        |
| `read_docx`                                             | WorkToolRunner.toolReadDocx → DocxImporter.import                           | .docx → Doc JSON 源（自家文件无损还原，外来近似导入；word/media 图片抽取到 docx_images/）                                                                                                                                  |
| `edit_docx`                                             | WorkToolRunner.toolEditDocx → DocxImporter + DocOps + DocxBuilder           | 读回→应用操作（改标题/改样式/增删改移块/全文替换）→重建（外来文件先备份）                                                                                                                                                            |
| `write_xlsx`                                            | WorkToolRunner.toolWriteXlsx → XlsxBuilder.buildXlsxBytes                   | **Workbook JSON / workbook 文件 / Markdown·CSV·TSV → Excel**（详见下节；多工作表/表头/公式/数字格式/列宽/冻结窗格，可带 name/style）                                                                                             |
| `read_xlsx`                                             | WorkToolRunner.toolReadXlsx → XlsxImporter.import                           | .xlsx → Workbook JSON 源（自家文件无损还原，外来近似导入：数值/文本/公式还原）                                                                                                                                                |
| `edit_xlsx`                                             | WorkToolRunner.toolEditXlsx → XlsxImporter + XlsxOps + XlsxBuilder          | 读回→应用操作（改名/加删移表/增删改行/改单元格/全文替换）→重建（外来文件先备份）                                                                                                                                                        |
| `write_csv`                                             | WorkToolRunner.toolWriteCsv → CsvWriter.buildCsvBytes                       | Markdown 表格/CSV/TSV→CSV（RFC 4180 转义，默认 UTF-8 BOM；输入解析走 CsvParser，引号字段正确处理）                                                                                                                         |
| `transform_file`                                        | WorkToolRunner.toolTransformFile → DataPipeline                             | **本地数据管道**（数据不经模型上下文）：CSV/TSV/MD/JSON/JSONL/文本行 输入，过滤/派生列/正则提取/拆列/去重/排序 + CSV↔TSV↔JSON↔MD↔XLSX 互转；受限 DSL（ops 白名单 + 表达式求值器，无 I/O），先预览后写盘；语法见 `load_skill("data")`；≤2MB/10 万行/30 步                   |
| `write_pptx`                                            | WorkToolRunner.toolWritePptx → PptxBuilder.buildPptxBytes                   | **Deck JSON / deck 文件 / outline 大纲 → PPT**（详见下节）                                                                                                                                                   |
| `read_ppt`                                              | WorkToolRunner.toolReadPpt → PptxImporter.import                            | .pptx → Deck JSON 源（自家文件无损还原，外来近似导入）                                                                                                                                                               |
| `edit_ppt`                                              | WorkToolRunner.toolEditPpt → PptxImporter + DeckOps + PptxBuilder           | 读回→应用操作→重建（外来文件先备份）                                                                                                                                                                                |
| `write_svg`                                             | WorkToolRunner.toolWriteSvg → SvgUtil                                       | SVG 源码→工作区 .svg + 栅格化 PNG 预览；xmlns/禁 script 校验，缺 width/height 自动按 viewBox 补齐（实机引擎必需），解码失败报精确诊断                                                                                                     |
| `list_skills` / `load_skill`                            | WorkFileService.dispatchTool → WorkSkillService                             | 技能清单与技能文档按需加载（rawfile/skills/ 下 5 个主 Skill + 7 个格式分支 = 12 个可见技能；25 个分支技能位于主 Skill 子目录；注册表共 37 项 = 32 原始 + 5 主路由）                                                                                   |
| `glob`                                                  | HarnessTools.toolGlob → FileSearchCore                                      | glob 模式按路径找文件（`**`/`*`/`?`/`{a,b}`/`[...]`，顶层逗号不破坏 `{}` 分支），返回相对路径与大小（≤500 个）                                                                                                                      |
| `grep`                                                  | HarnessTools.toolGrep → FileSearchCore                                      | 正则搜索文本文件内容，返回 `文件:行号: 内容`（≤200 命中；支持 glob 文件名过滤与 ignore_case，非法正则明确报错）                                                                                                                             |
| `edit`                                                  | HarnessTools.toolEdit → DiffUtil                                            | 逐字符唯一匹配替换（多处匹配拒绝，`replace_all` 全替）；结果附行级 diff hunks（meta 随会话持久化，UI 渲染 diff 卡片）                                                                                                                     |
| `str_replace_editor`                                    | HarnessTools.toolEdit                                                       | view/create/str_replace/insert 四命令编辑器（view 复用 read_file 行分页；insert 在指定行后插入）                                                                                                                        |
| `web_fetch`                                             | HarnessTools.toolWebFetch → WebFetchService                                 | GET ≤2MB 抓取网页/接口原文；HTML 剥离为可读文本（去 script/style/注释、块级标签转行、实体解码），JSON/文本原样返回（超长截断标注）                                                                                                                 |
| `local_web_search` / `record_search`                    | WorkFileService.toolSearchWeb → LocalWebSearch / toolRecordSearch           | **本机兜底联网搜索**（手机直连搜索引擎；默认走服务端 `web_search`，仅服务端不可用/无结果/用户要求时调用，旧名 `search_web` 仍可分发）+ 把服务端搜索的结论登记进 `.searches.md` 以便追溯                                                                         |
| `ask_user_question`                                     | HarnessTools.toolAskUser → AskUserBridge                                    | 暂停执行等待用户作答；UI 问题卡片（单选/多选 + 文字补充，统一由「提交」发送）；5 分钟未答按取消收场，循环中断即全部落定                                                                                                                                   |
| `schedule_create` / `schedule_list` / `schedule_delete` | HarnessTools → ScheduleService                                              | 会话内定时提醒（`.schedule.json` 持久化；一次性 `after_seconds` 或循环 `every_seconds`≥300 秒）；到期注入用户消息自动唤醒，任务执行中走插话通道                                                                                                |
| `goal_create` / `goal_get` / `goal_update`              | HarnessTools → GoalService                                                  | 会话自主目标（`.goal.json`），随运行时快照注入；`bump_round` 计轮，达轮次上限自动暂停                                                                                                                                            |
| `subagent`                                              | HarnessTools → SubagentService（经 `WorkFileService.subagentHook` 注入）         | 进程内子代理：与主任务共享工作区、独立上下文（工具面排除 subagent/ask_user/schedule/goal/todo_write），≤40 步；可并行派发（全局上限 4），每个子代理默认获得独立产出目录 `subagents/sa_<时间戳>_<序号>/`（可用 `output_dir` 指定），可读全工作区、写入自动重定向到该目录，最终报告作为工具结果交还并标注产出目录 |
| `session_search`                                        | HarnessTools.toolSessionSearch → SessionLogService                          | 检索会话事件日志（JSONL），找回被上下文压缩掉的历史细节                                                                                                                                                                     |
| `run_js`                                                | HarnessTools → JsCodeService → 原生 `libguncatjs.so`（JSVM-API）                | **设备内 JS 执行沙箱**：任意小程序化处理（计算/正则/JSON 重塑/统计/程序化生成）＋显式文件进出（`files` 只读预载、`write()` 落盘）；详见下节                                                                                                            |

路径安全：所有工具路径经 `resolveSafe()` 校验——拒绝绝对路径、盘符与 `..` 穿越，只能在 `filesDir/workspaces/<convId>/` 内操作。
`run_js` 的输入/输出同样走 `resolveSafe()`：脚本本身没有文件系统能力，进出只能经由 ArkTS 侧这层校验。

## 3.1 PPT 生成链路（Deck JSON 中间层）

设计对齐 open-kimi-ppt-skill 的 PPTD 思想：**AI 可编辑的中间层与导出器分离**。AI 永远只面向 Deck JSON 这一层——"生成 PPT"= 写 Deck → 渲染；"编辑 PPT"= 还原 Deck → 应用算子 → 重建。导出器不认识 prompt，只认识 Deck 结构，因此行为完全确定、可离线测试。

```text
write_pptx ──┐                                     ┌─ write_pptx(重建 pptx)
deck JSON ───┼→ PptxBuilder(渲染 13 种版式)→ .pptx │
             │    └─ 内嵌 docProps/deck.json 源    │
read_ppt  ───┤                                    └─ edit_ppt(DeckOps 应用操作后重建)
             └─→ PptxImporter(内嵌源无损还原 / 外来 XML 近似导入)
```

### 模块职责与公开 API（entry/src/main/ets/export/）

| 文件                 | 职责                                                                                          | 关键公开成员                                                                                                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DeckModel.ets`    | 中间层模型 + JSON 解析校验 + 编辑算子（**纯逻辑，无 Kit API**）                                                 | `Deck/DeckSlide/DeckBullet/DeckChart/DeckTable/DeckElement/DeckBackground`、`DeckParser.parse`、`DeckOutline.parse`（旧大纲兼容）、`DeckOps.apply`、`DECK_LAYOUTS`、`DECK_MAX_SLIDES`    |
| `PptxThemes.ets`   | 8 套主题预设 + 语义色/十六进制色解析（**纯逻辑**）                                                              | `PptxThemes.resolve`（Deck→ThemeColors）、`resolveColor(colors, spec, fallback)`（primary/accent/bg/surface/title/body/sub/faint/onPrimary/white/dark/light 或 hex）、`ThemeColors` |
| `PptxCharts.ets`   | 图表 part XML（bar/line/area/pie/doughnut，数据内嵌 numCache/strCache，**纯逻辑**）                      | `PptxCharts.buildXml(chart, colors)`                                                                                                                                         |
| `PptxImage.ets`    | 图片引用解析：工作区相对路径 / data URL / http(s)，mime 嗅探 + PNG/JPEG/GIF/BMP 尺寸探测                         | `PptxImage.resolve(src, workspaceRoot)` → `PptxImagePart`                                                                                                                    |
| `PptxBuilder.ets`  | Deck → pptx 全部件渲染（两遍式：先解析图片/图表，再逐页渲染）                                                       | `PptxBuilder.buildPptxBytes(deck, resolveImage)`；另定义 `PptxImagePart`/`ImageResolver`（类型在此，避免 PptxBuilder→PptxImage 的编译期依赖）                                                   |
| `PptxImporter.ets` | pptx → Deck：优先读内嵌 `docProps/deck.json`（无损），否则解析 slide XML 为 custom 版式（文本/表格/图片位置保留，图表转占位说明） | `PptxImporter.import(absPath, cacheDir)` → `PptxImportResult{deck, embedded, slideCount}`                                                                                    |

**依赖方向**（`.ets` 不得被 `.ts` 导入）：`DeckModel ← PptxThemes/PptxCharts/PptxBuilder`；`PptxBuilder ← WorkToolRunner.ets`；`PptxImage → WorkFileService.ts`（仅 `resolveSafe`，方向合法）；无环。新文件加入前先画这张图。

**SVG 自动栅格化**：`WorkToolRunner.imageResolver` 对 `.svg` 源文件按 1024px 宽经设备图片引擎栅格化为 PNG 再进入渲染管线——`write_svg` 的产物可被 `write_pptx` 直接引用（配合 svg 技能的绘制规范），无需手工转格式。

### Deck JSON 契约（改字段必同步的三处）

AI 视角的完整字段文档 = **ppt 技能的 `reference/deck-dsl.md`**。Deck 结构的权威实现在 `DeckModel.ets`。改动任一字段时，以下三处必须同步，否则模型会按旧文档生成、报错率上升：

1. `DeckModel.ets`（解析 + 校验：`parseSlide`/`validateSlide` 的报错文案要带页码、说清缺什么，供 AI 自纠错）；
2. 技能文档 `rawfile/skills/ppt/reference/deck-dsl.md`（字段表）与 `SKILL.md`（速查示例）；
3. `test/pptx-harness/test-build.mjs`（样例覆盖该字段，负例覆盖新校验）。

结构概览：顶层 `{title, theme, themeOverride{8 色槽}, slides[]}`；页上限 `DECK_MAX_SLIDES(80)`；页公共字段 `{layout, title, subtitle, notes, background{color|image, fit, overlay}}`；13 种版式各有专属字段（bullets / columns / image / table / chart / elements / text/author / imageSide…）；limits：表格 ≤20 行、单图 ≤10MB（`WORK_PPT_IMAGE_MAX_BYTES`）、整册 ≤40 图（`WORK_PPT_MAX_IMAGES`）。

### pptx 部件与关系编号约定（改 PptxBuilder 前必读）

- 每页 rels：`rId1` 固定 = slideLayout；其后**按 media → chart 顺序**依次分配 rId2…；`renderChart`/背景图/`renderCustom` 里的 rId 都是按这个规则**算出来的**（`'rId' + (2 + mediaParts.length)`），新增消耗关系的元素时保持同一算法。
- 图表全局编号在**首遍扫描**时分配（`ctx.chartNos`），`[Content_Types].xml` 与 slide rels 共用同一序号——不要在渲染期再数一遍。
- 备注页 `ppt/notesSlides/`：notesMaster **恒定存在**（与是否有备注无关），presentation rels 结构因此稳定；notesSlide 的 rels 反向引用所属 slide 的编号。
- 内嵌源 `docProps/deck.json`（Override application/json）是 `read_ppt`/`edit_ppt` 无损往返的关键，渲染改动不要动它；`renderSlide` 里它由 `JSON.stringify(deck)` 直接生成。
- 备注页 rels 的 `../slides/slideN.xml` 反向引用要传对页码（`notesSlideRelsXml(i + 1)`）。

### 深色背景自动反白（对比度红线）

`isDarkBg(slide, colors)`：背景图 + `overlay ≥ 0.3`，或背景色亮度 < 0.55 → 判定深色底。判定后：

- **页面文字**（标题/要点/图注/页码）走 `TextScheme`（`renderSlide` 计算一次传给各版式渲染器），反白为 FFFFFF / E2E8F0 / A9B6C6 / 7E8CA0；
- **图表**走 `lightened(colors)` 副本：轴刻度、图例、数据标签变浅，**系列色板不变**；
- **表格单元格**永远用主题 `bg`/`surface` 填充 + 主题 `body` 文字——填充跟随主题而非页面底色，任意主题×任意页面底色组合都可读（曾因此返工，勿改回硬编码 FFFFFF）。

新写版式渲染器时，文字颜色**一律取 `ts`（TextScheme）而非 `colors`**，这是上面规则的落地姿势。

### 扩展指南

**加新版式**（4 处）：

1. `DeckModel.DECK_LAYOUTS` 注册名字 → `parseSlide` 加字段解析 → `validateSlide` 加必备字段校验（error 信息含页码）；
2. `PptxBuilder.renderSlide` 的 switch 加分支 → 新写 `renderXxx(slide, …, ts, …)`：几何常量放文件头（EMU，1pt=12700），文字用 `ts`，装饰用 `colors.primary/accent`；
3. `test/pptx-harness/test-build.mjs` 的 fullDeck 加样例页 → 跑完整验证链（下文）；
4. 同步技能文档：`deck-dsl.md` 字段表 + `SKILL.md` 版式速查表。

**加主题**：`PptxThemes.preset()` 加分支（primary/accent/bg/surface/title/body/sub/faint/onPrimary/dark + series 6 色板）→ `themes.md` 加一行。未知主题名回退 brand-blue（勿抛错，模型会自行修正）。

**加图表类型**：`PptxCharts.buildXml` 加分支。注意 OOXML 的 `CT_*Ser` 子元素顺序是 `idx→order→tx→spPr→marker→dLbls→cat→val`，`dLblPos` 仅 bar/line/pie 支持（doughnut 不支持，勿加）→ 同步 `deck-dsl.md`。

### 验证闭环（改完生成器必跑，命令见 test/pptx-harness/README.md）

```bash
node setup.mjs && node test-build.mjs        # 全版式/多主题/编辑算子/负例构建 → gen/out_*.pptx
python validate.py gen\out_all.pptx …        # zip CRC/全部件 XML/关系一致/content-types/python-pptx
python deep-check.py                         # python-pptx 读图表数据 + 内嵌源往返
node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json   # 服务层类型检查
```

视觉自检（装了 PowerPoint 的机器）：`export-png.ps1` 导出 PNG 后逐页目检——重点看文字出界、深色页反白、图表标签可读、表格对比度（历史上 3 个视觉 bug 全是这三类）。

## 3.2 Word 生成链路（Doc JSON 中间层）

与 PPT 同构：**AI 可编辑的中间层与导出器分离**。"生成 Word"= 写 Doc JSON → 渲染；"编辑 Word"= 还原 Doc → 应用算子 → 重建。导出器只认识 Doc 结构，不认 prompt，行为确定、可离线测试。

```text
write_docx ──┐                                   ┌─ write_docx(重建 docx)
doc JSON ────┼→ DocxBuilder(渲染)→ .docx         │
             │    └─ 内嵌 docProps/doc.json 源   │
read_docx ───┤                                  └─ edit_docx(DocOps 应用操作后重建)
             └─→ DocxImporter(内嵌源无损还原 / 外来 XML 近似导入 + word/media 图片抽取)
```

### 模块职责与公开 API（entry/src/main/ets/export/）

| 文件                 | 职责                                                                                                  | 关键公开成员                                                                                                                         |
| ------------------ | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `DocModel.ets`     | 中间层模型 + JSON 解析校验 + Markdown 转换 + 编辑算子（**纯逻辑，无 Kit API**）                                           | `Doc/DocBlock/DocListItem`、`DOC_STYLES`、`DocStylePalette.of(style)`、`DocParser.parse`、`MdToDoc.convert`、`DocOps.apply`         |
| `DocxBuilder.ets`  | Doc → docx 全部件渲染（两遍式：先解析图片，再逐块渲染；内嵌 doc.json 源）                                                     | `DocxBuilder.buildDocxBytes(doc, resolveImage)`、`buildFromMarkdown(md, title, resolveImage)`、`DocxImagePart`                   |
| `DocxImporter.ets` | docx → Doc：优先读内嵌 `docProps/doc.json`（无损），否则解析 document.xml（标题/列表/表格/图片，图片抽取到 `docx_images/<base>/`） | `DocxImporter.import(absPath, cacheDir, imageOutDir, imageOutRelBase)` → `DocxImportResult{doc, embedded, blockCount, images}` |

**依赖方向**：`DocModel ← DocxBuilder`；`DocxBuilder/DocxImporter ← WorkToolRunner.ets`；与 PPT 管线互不依赖（共用 MarkdownParser/OmmlConverter/XmlUtil/ZipWriter）。新文件加入前先画这张图。

**排版与图片**：styles.xml 里 H1→H6 为 22→12pt 黑体加粗、按主题配色（default/academic/minimal 三套），正文默认 12pt 宋体、1.5 倍行距；图片块与行内图片都支持工作区路径/data URL/http，svg 自动栅格化，单图 ≤10MB、整篇 ≤40 图（`WORK_DOC_*` 常量）；表格带题注与表头底纹。

### Doc JSON 契约（改字段必同步的三处）

AI 视角的完整字段文档 = **docx 技能的 `reference/doc-dsl.md`**。Doc 结构的权威实现在 `DocModel.ets`。改动任一字段时，以下三处必须同步：

1. `DocModel.ets`（解析 + 校验：报错文案带块序号、说清缺什么，供 AI 自纠错）；
2. 技能文档 `rawfile/skills/docx/reference/doc-dsl.md`（字段表）与 `SKILL.md`（速查示例）；
3. `test/docx-harness/test-build.mjs`（样例覆盖该字段，负例覆盖新校验）。

结构概览：顶层 `{title, subtitle, author, date, style, cover, toc, blocks[]}`；块上限 `WORK_DOC_MAX_BLOCKS(400)`；块类型 `heading(1~6)/paragraph/list(有序无序)/table/image/quote/code/divider/pagebreak`；行内支持 `**加粗** *斜体* \`代码\` [链接](url) $公式$ ![](内联图)`；limits：表格 ≤20 列/500 行、单图 ≤10MB、整篇 ≤40 图。

### 验证闭环（改完生成器必跑，命令见 test/docx-harness/README.md）

```bash
python makepng.py > png.b64
node setup.mjs && node test-build.mjs          # 全块类型/封面目录/markdown 路径/编辑算子/外来导入/负例
python validate.py gen\out_all.docx …          # zip CRC/全部件 XML/关系一致/样式字号分级/python-docx/图片嵌入
python deep-check.py gen\out_all.docx …        # 内嵌 doc.json 往返 + 正文/表格/图片/H1 顺序核验
node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json   # 服务层类型检查(pptx-harness)
```

视觉自检（装了 Word/WPS 的机器）：打开 `gen/out_all.docx` 检查封面、标题分级、图片与表格排版。

### Excel 管线（Workbook JSON 中间层，与 PPT/Word 同构）

设计对齐 PPT/Word：**AI 可编辑的中间层与导出器分离**。AI 永远只面向 Workbook JSON 这一层——"生成 Excel"= 写 Workbook → 渲染；"编辑 Excel"= 还原 Workbook → 应用算子 → 重建。导出器不认识 prompt，只认识 Workbook 结构，行为确定、可离线测试。

```text
write_xlsx ──┐                                   ┌─ write_xlsx(重建 xlsx)
workbook JSON ┼→ XlsxBuilder(渲染)→ .xlsx        │
             │    └─ 内嵌 docProps/workbook.json │
read_xlsx ───┤                                  └─ edit_xlsx(XlsxOps 应用操作后重建)
             └─→ XlsxImporter(内嵌源无损还原 / 外来 XML 近似导入)
```

### 模块职责与公开 API（entry/src/main/ets/export/）

| 文件                 | 职责                                                                                                                | 关键公开成员                                                                                                                             |
| ------------------ | ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `XlsxModel.ets`    | 中间层模型 + Workbook JSON 解析校验 + Markdown/CSV/TSV 转换 + 编辑算子（**纯逻辑，无 Kit API**）                                        | `XlsxWorkbook/XlsxSheet/XlsxCell`、`XLSX_STYLES`、`XlsxStylePalette.of(style)`、`XlsxParser.parse`、`MdToXlsx.convert`、`XlsxOps.apply` |
| `XlsxBuilder.ets`  | Workbook → xlsx 全部件渲染（多工作表/表头加粗底纹三主题/`=公式`/数字格式/列宽/冻结窗格；内嵌 workbook.json 源）                                       | `XlsxBuilder.buildXlsxBytes(workbook)`                                                                                             |
| `XlsxImporter.ets` | xlsx → Workbook：优先读内嵌 `docProps/workbook.json`（无损），否则解析 workbook.xml+rels+sharedStrings+各 sheet（数字/文本/公式/列宽/冻结窗格） | `XlsxImporter.import(absPath, cacheDir)` → `XlsxImportResult{workbook, embedded, sheetCount, rowCount}`                            |

**依赖方向**：`XlsxModel ← XlsxBuilder`；`XlsxBuilder/XlsxImporter ← WorkToolRunner.ets`；与 PPT/Word 管线互不依赖（共用 XmlUtil/ZipWriter；XlsxModel 复用 CsvParser 做 table 文本解析）。`XlsxExporter.buildXlsxFromRows` 仍由 transform_file 的 XLSX 输出使用，保持单表无格式语义。

**表格能力**：`workbook` 源支持多工作表（≤20）、表头加粗底纹（default/academic/minimal）、公式（单元格值以 `=` 开头，如 `"=SUM(B2:B9)"`，跨表 `"=假设!B2"`）、每列数字格式（`money` ¥千分位两位小数 / `int` / `percent` 0.0% / `year` / `date` / `number` / `text`）、列宽 1~255、冻结窗格（`freeze: "A2"`）；数据行矩形约束（≤1000 行/60 列，`WORK_XLSX_*` 常量）。**公式优先**：派生值（合计/同比/占比）必须写成公式而非硬编码数字——数字格式与负数/零值显示约定（金额负数括号 `(¥1,234.00)`、零值 `-`）吸收自 MiniMax 的 xlsx 参考技能，模型操作指南见 `load_skill("xlsx")`。

### Workbook JSON 契约（改字段必同步的三处）

AI 视角的完整字段文档 = **xlsx 技能的 `reference/workbook-dsl.md`**。Workbook 结构的权威实现在 `XlsxModel.ets`。改动任一字段时，以下三处必须同步：

1. `XlsxModel.ets`（解析 + 校验：报错文案带表名/行/列号，供 AI 自纠错）；
2. 技能文档 `rawfile/skills/xlsx/reference/workbook-dsl.md`（字段表）与 `SKILL.md`（速查示例）；
3. `test/xlsx-harness/test-build.mjs`（样例覆盖该字段，负例覆盖新校验）。

结构概览：顶层 `{name, style, sheets[]}`；每 sheet `{name, headers?, rows, colWidths?, freeze?, formats?}`；单元格值 = 数字 | 字符串 | `"=公式"`。`read_xlsx` 读回：自家文件无损（内嵌源）；外来 xlsx 近似导入（表顺序/数值/文本/公式还原，样式与合并细节丢失），`edit_xlsx` 对外来文件重建前自动备份 `*_原版备份.xlsx`。

### 验证闭环（改完生成器必跑，命令见 test/xlsx-harness/README.md）

```bash
node setup.mjs && node test-build.mjs          # 多表/公式/格式/列宽/冻结 + markdown 路径 + 编辑算子 + 外来导入 + 负例
python validate.py gen\out_all.xlsx …          # zip CRC/全部件 XML/关系一致/openpyxl/表头加粗/公式/数字格式/冻结窗格/列宽
python deep-check.py gen\out_all.xlsx …        # 内嵌 workbook.json 往返 + 逐格核验(含公式)
node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json   # 服务层类型检查(pptx-harness)
```

视觉自检（装了 Excel/WPS 的机器）：打开 `gen/out_all.xlsx` 检查表头底纹、金额格式、公式联动（改 B2 看 D2 重算）与冻结窗格。

## 3.3 技能系统（可复用的领域操作指南）

技能 = 按 id 组织的**纯 Markdown 领域操作指南**（无代码）。模型接到对应任务时自行加载。解决的核心问题：领域知识（Deck JSON 语法、设计规范……）不能写进系统提示词——系统提示词必须逐字节静态（KV 缓存红线），而技能文档可以随时增改、按需加载、按文件分层，**不动一行提示词代码**。

### 结构约定

```text
entry/src/main/resources/rawfile/skills/
├── ROUTE_INDEX.md               ← 全局路由总索引（【新增】，不属于任何原始技能正文）
├── research-intelligence/       ← 主 Skill：情报调研与分析（路由入口）
│   ├── SKILL.md                 ← 主 Skill 正文：命中即先加载、意图分流
│   ├── ROUTING.md               ← 分支路由清单
│   └── research/ sift/ llm-eval/ sentiment-tracker/
│       industry-analysis/ research-lineage-map/ questionnaire/
│                                ← 7 个分支 Skill 子目录（原 id 仍可直接 load_skill）
├── academic-publishing/         ← 主 Skill：学术写作与论文全流程（路由入口）
│   ├── SKILL.md / ROUTING.md
│   └── paper/ paper-close-reading/ paper-reviewer/ paper-rebuttal/
│       research-proposal/ reference-audit/ journal-format/   ← 7 个分支
├── content-writing/             ← 主 Skill：内容创作与营销文案（5 个分支）
│   ├── SKILL.md / ROUTING.md
│   └── khazix-writer/ newmedia-writing/ content-rewrite/ humanizer/ marketing-plan/
├── legal-ip/                    ← 主 Skill：法律/IP/合规（4 个分支）
│   ├── SKILL.md / ROUTING.md
│   └── law/ patent-drafting/ translation/ marketing-material-review/
├── ai-tooling/                  ← 主 Skill：AI 工程与提示词（2 个分支）
│   ├── SKILL.md / ROUTING.md
│   └── prompt-engineering/ review-agent/
├── ppt/                         ← 格式分支（保持顶层直连）
│   ├── SKILL.md                 ← 技能正文（必备）：何时用 / 工具链 / 工作流 / 速查 / 自检清单
│   └── reference/              ← 深入资料，按需逐文件加载（可选）
│       ├── deck-dsl.md         # 字段级语法
│       ├── design-guide.md     # 设计规范
│       ├── themes.md           # 主题清单
│       └── troubleshooting.md  # 症状→修复排查表
├── docx/ xlsx/ data/ svg/ html/ pdf/
│                                ← 其余 6 个格式分支同样保持顶层直连
└── …/
```

注册表在 `WorkSkillService.registry()`（**代码即注册表，无配置文件**）。每个 `SkillInfo = { id, name, description, files: SkillFileInfo[] }`；`files` 是 `load_skill` 允许的文件白名单（`SKILL.md` 恒可用），防路径探测。**没有登记的技能对模型不存在**——文档放了对目录里也不会被加载。

**物理嵌套 + 原 id 加载**：分支 Skill 已从 `skills/` 顶层移入主 Skill 子目录，但 `load_skill` 仍按原 id 使用——`WorkSkillService.skillPath()` 把 id 映射到嵌套目录（如 `research` → `research-intelligence/research`），模型无需关心文件物理位置。**对外可见性**：`list_skills` 只返回 12 个可见技能（5 个主 Skill + 7 个格式分支），25 个分支 Skill 不在清单中，由主 Skill 的 `ROUTING.md` 路由后按原 id 加载。注册表共 37 项 = 32 个原始 Skill + 5 个主 Skill 路由入口。

### 加载链路（渐进披露）

```text
系统提示词「技能库」段(默认 full_index: 技能清单 + 技能使用铁律, 静态)
  → 模型 list_skills()                        → WorkSkillService.listText()
      返回: 12 个可见技能(5 主 Skill + 7 格式分支) id + name + 触发语义 + 文件索引
  → 命中主 Skill 领域 → load_skill("<主 Skill>")   → 读 SKILL.md/ROUTING.md, 路由到分支
  → load_skill("research")                    → skillPath() 映射到 research-intelligence/research, 读 SKILL.md 全文
  → load_skill("ppt", "reference/deck-dsl.md") → 按文件加载深入资料
分发: WorkFileService.dispatchTool()（纯 TS, 无需 .ets）; 二者登记在 isReadOnlyTool() 可并发。
结果与普通工具一致: 超 1.2 万字符被头尾保留式截断(WORK_SKILL_MAX_CHARS 是加载侧硬上限)。
```

### SKILL.md 写作约定（可复用骨架）

```markdown
---
name: <id>
description: <一句话触发语义, 写法见下>
---
# <技能名>

## 何时用          ← 触发场景清单（模型据此决定是否加载）
## 工具链          ← 涉及哪些工具、参数怎么传、图片来源等硬约束
## 工作流 A/B      ← 分场景编号步骤, 每步一个动作; 附最小可用示例
## 速查            ← 表格/JSON 样例（放最常用的 20%, 长尾放 reference）
## 交付前自检清单   ← checkbox 列表, 模型交付前逐项自查
```

- `reference/` 文件按主题内聚拆分，**单文件 < 1.2 万字符**（超出会被截断、中段丢失，等于白写）；
- 示例代码块必须是**可原样跑通的最小样例**，与当前工具实现一致；
- 长度预算：SKILL.md 控制在 4~6k 字符，把细节留给 reference。

### description 触发语义怎么写

description 同时承担两个职责：系统提示词触发提示的展开、`list_skills` 的展示文本。写法 = **枚举任务关键词 + 指明涉及的工具 + 声明先加载**：

- ✅ `制作/修改/美化演示文稿(.pptx)时加载: Deck JSON 完整语法(13 种版式/图表/表格/图片/备注)、8 套主题、设计规范与自检清单。任何 write_pptx / read_ppt / edit_ppt 任务开始前先加载。`
- ❌ `PPT 技能`（模型无法判断何时该加载，等于没写）

### 新增一个技能的步骤（写文档 + 1~2 处代码）

1. 建 `rawfile/skills/<id>/SKILL.md`（+ 按需 `reference/*.md`），按上面的骨架写；
2. `WorkSkillService.registry()` 登记条目：id / name / description / files 白名单（每个 reference 文件都要登记，否则 load 不到）；
3. 需要主动触发时，在 `AgentLoopService.buildWorkSystemPrompt()` 的「技能系统」段补一句（追加行不改历史行，静态红线不破坏）；
4. **不用改 toolDefs / dispatchTool**：`list_skills`/`load_skill` 是通用工具，自动覆盖新技能；
5. 自测：工作模式里 `list_skills` → 逐文件 `load_skill` 确认完整无截断 → 实跑一个对应任务看模型是否按技能执行。
6. 若新技能是**分支 Skill**：物理目录放在对应主 Skill 子目录下，在 `WorkSkillService.skillPath()` 增加 id→子目录映射，并同步登记到对应主 Skill 的 `ROUTING.md`；若新增**主 Skill**：建 `SKILL.md` + `ROUTING.md`，在 `ROUTE_INDEX.md` 登记，并在 `registry()` 注册。

### 维护红线与可移植性

- 技能文档与工具实现**同步演进**：改 Deck 字段/工具参数 → 同步对应技能文档 → 再改系统提示词（若有涉及）；
- description 措辞 = 触发行为，改动要当回事（建议在 git 提交说明里单独标注）；
- 技能文档是**跨 Agent 可复用资产**：frontmatter（name/description）刻意对齐标准 Agent Skills 约定（同 open-kimi-ppt-skill 的 SKILL.md 结构），整目录拷入其他 Agent 框架的技能目录（如 `~/.claude/skills/<id>/`）即可被支持 SKILL.md 的框架识别，无需改写。

## 3.4 run_js：设备内 JS 执行沙箱（JSVM-API）

工作模式没有 shell/终端/PTC，确定性加工只能靠固定工具；`run_js` 用 **JSVM-API**（`libjsvm.so`，NDK C 接口，API 11 起可用，syscap `SystemCapability.ArkCompiler.JSVM`）在应用内嵌一个标准 JS 引擎，补上"写几行代码算一下"的通用能力——日期/数值/单位换算、正则清洗、JSON 重塑与合并、统计汇总、算法试算，以及程序化批量生成结构化数据（产出 JSON 再交给 `write_docx`/`write_xlsx`/`write_pptx` 成文）。

**链路**：`HarnessTools.dispatch('run_js')` → `JsCodeService.run()`（.ts）→ 原生 `libguncatjs.so`（`entry/src/main/cpp`）→ JSVM 引擎实例。

- ArkTS 侧（`JsCodeService.ts`）：参数校验、输入文件预载（`resolveSafe` + 文本/二进制判定）、输出落盘、超时放弃、结果渲染。
- Native 侧（`jsvm_sandbox.cpp` + `napi_init.cpp`）：每次执行新建 VM + 上下文 → 注入沙箱 → 编译执行 → 取完成值 → 逆序销毁；执行跑在 Node-API 异步任务（worker 线程）上。

**沙箱能力**（每次执行都是全新引擎实例，脚本之间无状态残留）：

| JS 侧                                              | 说明                                                                                                    |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `inputs["路径"]` / `read("路径")`                     | 只读输入（`files` 参数预载：≤6 个、单个 ≤512KB、合计 ≤1MB）；键名去掉 `./` 前缀并折叠重复斜杠，结果里会列出实际键名；没传 `files` 时 `read()` 直接报错提示 |
| `write("路径", 内容)`                                 | 声明输出；**执行成功才落盘**，且路径再经 `resolveSafe()` 校验                                                             |
| `console.log/info/warn/error/debug`、`print`、`log` | 收集为 stdout（≤64KB，单行 ≤8KB）                                                                             |
| 返回值                                               | 脚本最后一条表达式的完成值（同 eval 语义）；对象/数组以 JSON 返回，字符串原样输出                                                       |
| 其他内建                                              | 标准 V8 内建（JSON/Math/Date/RegExp/Map/Set/Intl…）；**无网络、无文件系统、无模块加载**（JSVM 不支持 ES Module）                 |

**设计要点**：

- **文件进出必须显式**：原生侧不做任何路径判断，所有路径一律由 ArkTS 侧 `resolveSafe()` 校验后再读写——工作区边界只有一处实现，JS 本身拿不到逃逸能力。
- **每次新建引擎实例**：脚本之间无状态残留，单个脚本写坏引擎也不影响下一次。
- **执行放异步任务**：JS 是同步阻塞的，放 UI 线程会直接卡死界面（官方文档明确 `execute` 不可中断、不支持异步）。
- **超时只能"放弃等待"**：JSVM-API 没有 `TerminateExecution` 一类接口，`while(true)` 无法从外部终止。ArkTS 侧用 `Promise.race` 式等待：超时先把错误交还模型，那段代码仍在后台线程里跑；累计 `WORK_JS_MAX_ABANDONED`(2) 次后本会话停用 `run_js`（宁可在这一步降级，也不能让应用持续满核耗电）。**排查超时先看死循环与循环规模。**
- **资源上限**：VM 堆 256MB（`JSVM_CreateVMOptions.maxOldGenerationSize`）、源码 ≤128KB、单文件输出 ≤512KB（对齐 `WORK_WRITE_MAX_BYTES`）、输出总量 ≤4MB、≤16 个文件；所有上限在 native 侧再做一次收敛（越界取边界值），参数被滥用也不会突破边界。**堆是硬边界**：一次性生成超大数组/字符串触顶会直接终止进程，脚本要按块处理而不是把整份数据展开成一个巨大结构。

**维护注意（native 部分）**：

- 官方规范必须照做，否则会崩：`OH_JSVM_Init` 全进程只成功一次（重复调用返回 `JSVM_GENERIC_FAILURE`＝"已初始化"，属正常）；Scope 必须逆序关闭（HandleScope → EnvScope → VMScope → DestroyEnv → DestroyVM）；`JSVM_Value` 只能在 HandleScope 内创建、Scope 关闭后不可再用；`JSVM_CallbackStruct` 生命周期必须长于 `JSVM_Env`（本实现用文件级静态对象）；每次 JSVM-API 失败都要清理挂起异常，否则污染后续调用。
- `JSVM_CreateVMOptions` 的堆参数不被接受时会自动退回默认配置（不让工具因堆设置失败而完全不可用）。
- 新增 ABI 需同步 `entry/build-profile.json5` 的 `externalNativeOptions.abiFilters`（当前 `arm64-v8a` / `x86_64`，与项目其它原生依赖一致）。
- `libguncatjs.so` 依赖系统库 `libjsvm.so`（API 11 起随系统提供，不随 HAP 打包）。ArkTS 侧用的是静态 `import`（与官方样例一致），因此**若目标设备缺这个系统库，原生模块加载失败会连带影响工作模式启动**；要彻底隔离可改为在调用点用动态 `import()`。
- 改动 native 后**必须走实机构建**：`hvigor assembleHap` 会驱动 CMake/Ninja 编译并打包 `libs/<abi>/libguncatjs.so`；Node 侧 `test/guncat-harness` 只能做类型级检查（`libguncatjs.so` 由 `jsvm-shim.ts` 桩替代）。
- 真机自检：`run_js` 返回 `1+1 → 2`；`write()` 的产出能在工作区看到；语法错误/运行时异常返回可读报错（带 `run_js.js:行号`）；`while(true){}` 在超时后正常报错且界面不卡；`engineStatus()` 返回空串表示引擎可用（不可用时工具会直接给出原因）。

## 4. 新增工具的步骤（6 处）

1. `WorkFileService.toolDefs()`：登记工具 Schema（名称/描述/参数），这是模型看到的定义；`props0`/`props1`/`props2`/`props3` 构造属性表。
2. `WorkFileService.dispatchTool()`：加入分发分支（需要 `.ets` 能力时改在 `WorkToolRunner.execute()` 分发）。
3. 实现执行函数：返回 `ToolExecResult`（`ok`/`output`；`imageDataUrl` 仅供 view_image 类工具注入视觉消息）。
4. `AgentLoopService.buildWorkSystemPrompt()`：补充工具说明与使用纪律（保持逐字节静态；大段领域知识不要写这里——做成技能，见 3.3）。
5. 若会改变工作区内容，登记 `WorkFileService.isMutatingTool()`；纯只读工具登记 `isReadOnlyTool()`（可参与只读并发）。委托给 `HarnessTools` 的工具在 `HarnessTools.isMutating()/isReadOnly()` 登记。
6. `ChatBubbleView`：补 `toolIcon()` 与 `displayName()` 的 case（不补则回退通用扳手图标 + 原名）。
7. 需要原生能力时（如 `run_js`）：新建 `entry/src/main/cpp/{CMakeLists.txt,*.cpp}` + `types/lib<name>/index.d.ts`（+ `oh-package.json5`），在 `entry/build-profile.json5` 的 `externalNativeOptions` 里声明 CMake 路径与 `abiFilters`，ArkTS 侧 `import { … } from 'lib<name>.so'`。

> 涉及"教模型怎么用新工具"的内容（DSL 语法、格式规范、工作流），优先做成技能文档而不是堆进工具 description 或系统提示词——description 一句话说明用途即可，细节让模型 `load_skill` 自取。

## 5. 本地解析引擎与内存/主线程红线

**解析链**：`OfficeReader`（zlib.decompressFile 解包 OOXML → XML 文本节点抽取）、`PdfTextExtractor`（字节层对象表扫描 → ObjStm 顺序值展开 → 页面树资源继承 → ToUnicode CMap 映射 CJK → 内容流 `Tj/TJ` 解析 → 全流扫描兜底 + 诊断信息）、`Flate`（纯 TS DEFLATE/zlib 解压，SDK zlib 只有文件级 API）。

维护时必须守住三条红线（每条都有过线上事故）：

1. **禁止大字符串逐字符拼接**（`s += x` 循环 O(n²)）——曾把共享堆打爆（OOM）。大片段统一走 `bytesToString()`：字节拷入 UTF-16LE 缓冲后用 `util.TextDecoder` 一次性原生解码；`arrayBufferToBase64` 同样是全数值化生成 + 原生解码。
2. **重 CPU 解析必须分阶段让出主线程**——曾在兜底扫描全量解析字体流时触发 THREAD_BLOCK_6S appfreeze。`PdfTextExtractor` 用 `yieldNow()`（setTimeout 0）在对象表构建后、每页之间、兜底每个流之间让出；兜底扫描跳过字体/图片/超大流并做内容预检。
3. **所有片段转换必须设上限**：字典 64KB、ObjStm 2MB、CMap 1MB、内容流 4MB、单条文本解码 128KB、单行缓冲 100K 字符、整文件 16MB——防止异常/恶意文件打爆内存。

## 6. ArkTS 落地约束（踩过的坑）

- **`.ts` 不得 import `.ets`**（编译错误 10605999）。选扩展名前先画依赖方向：`ChatViewModel.ets` 需要引用 Office 生成/多模态等 `.ets` 模块，因此 ViewModel 本身必须是 `.ets`；`WorkFileService.ts` 只能依赖 `.ts`（ZipWriter 因此从 .ets 改成了 .ts）。
- **`.ets` 禁止匿名对象字面量类型**（arkts-no-obj-literals-as-types）。跨模块返回结构用命名类（如 `ParsedFileResult`、`ToolExecResult`）。
- **闭包不继承可空变量的收窄**：`let conv: X | null` 判空后，在 lambda 里仍可能报 possibly null——先落成非空局部量（如 `let emptyConv: Conversation = conv`）再进闭包。
- **目录列举 API 是 `listFileSync`**（该 SDK 无 `readdirSync`）；`mkdirSync(path, true)` 支持递归建目录。
- **import 必须置于文件最前**（注释除外），且所有 import 语句先于其他语句。
- **同一模块内标识符不得重名**（`CompileArkTS` 阶段报 `Cannot redeclare block-scoped variable`，`tsc` 却不报）：纯逻辑模块里多个函数各写一个 `let out` 就会编译失败——各函数用各自语义化的变量名。
- **`@State` 的观察是浅层的**：不要用 `@State` 持有一个自定义类实例并指望其**内部字段/嵌套数组**的变化触发刷新（`ForEach(this.x.items, ...)` 不会被观察到）。组件内派生的渲染数据一律用**数组/基本类型 `@State` + 整体重赋值**。真机事故：交互界面卡片因此停在骨架态，切走再切回会话（组件重建）才正常。
- **超长单行文本要显式换行**：JSON 等单行长文本必须 `WordBreak.BREAK_ALL` + 足够的 `maxHeight` + 可见滚动条，否则用户只能看到开头几行，误判"模型只写了这么多"。
- **不要在自动高度的容器里用 `height('100%')`**：交互界面的 `note`（提示条）早期用 `Row().height('100%')` 当左侧竖条，真机上被解析成几百 vp，把整条撑成一大片空白（文字只占两行）。**竖条改用 `border({ width: { left: 3 }, … })`**，高度完全由文字决定。只有父容器有显式高度时（进度条/柱状条的轨道）才可以用 `height('100%')`。
- PowerShell 管道改文件内容会把 UTF-8 按 GBK 重写导致中文乱码——修改源码一律用编辑工具，不用 shell 重写。

## 7. UI（Codex 式时间线）

- `ChatPage.buildWorkTimeline`：工作模式下整个会话渲染为**单容器时间线**——顶部唯一 🛠「工作模式」标识（含执行状态），下方按消息顺序排列：用户任务卡（品牌色）与 `WorkTurnView`。
- `WorkTurnView`（`@ObjectLink Message`）：CLI 式行内思考条（`图标 + 思考`，流式转圈 + 跑马灯，完成后标题缀「· 持续了几秒」占位文案，无底色）→ CLI 式行内工具行（`工具图标 + 短名 · 参数摘要 + 状态/耗时`，无底色块，点击展开参数与结果，展开区以左侧细竖线挂载）→ 正文（RichTextView）；思考/工具行带 16vp 水平边距，宽度与正文对齐；仅最终轮显示复制/导出/重新执行按钮；流式期间 33ms flush 定时器同步文本与步骤状态。
- 聊天模式完全沿用 `ChatBubbleView`（深度思考条同样为无底色行内样式），两条渲染路径互不影响。
- `WorkspaceBar`：工作区弹层（文件列表 + 上传/导出 zip/删除）；文件行按扩展名映射类别图标（`sys.symbol`：图片/表格/演示文稿/PDF/压缩包/代码/音视频等），未知类型回退通用文档图标。
