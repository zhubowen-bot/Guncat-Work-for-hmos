# 主要功能

> [← 返回 README](../README.md)


## 原生流式对话

- 基于 `@kit.NetworkKit` 和 `http.requestInStream` 处理 SSE 流式响应。
- 支持三种主流接入方式：OpenAI Completions（`/chat/completions`）、OpenAI Responses（`/responses`，DeepSeek / 火山方舟等兼容服务）、Anthropic Messages（`/messages`）。
- 三种接入方式均支持图片直传；OpenAI Responses 额外支持 Files API 混合上传大图/文档。
- DeepSeek 已统一使用最新 Responses API，支持原生联网搜索与识图版图片直传。
- 支持停止生成、重新生成、对话历史管理和多套 API 配置。
- 流式输出采用节流刷新与自动滚动，减少频繁重绘。

## 深度思考与联网搜索

- 深度思考按钮按接入协议显式控制（对齐 DeepSeek 官方参数）：
  - OpenAI Completions：`thinking.type = enabled / disabled`，开启时另发 `reasoning_effort = high`
  - Anthropic Messages：`thinking.type = enabled / disabled`，开启时另发 `output_config.effort = high`
  - OpenAI Responses：`reasoning.effort = high / none`（`none` 表示关闭思考）
- 按钮状态优先于额外请求参数，避免界面状态与实际请求不一致。
- 联网搜索开启时，多轮对话自动回传上一轮 assistant 的 `reasoning_content`（OpenAI Completions），避免 400。
- OpenAI Completions / Anthropic Messages 也会按各自格式发送联网搜索工具（是否生效取决于服务商支持）。
- 深度思考和联网搜索状态会持久化保存；新建对话（含每次启动自动新建）按智能体名称重置深度思考默认值：效率模式默认关闭、轻简模式默认关闭、专家模式默认开启。

## 维护：智能体深度思考默认值

新建对话 / 每次启动 / 打开空对话时，应用按智能体**名称**重置深度思考开关，配置位于 `entry/src/main/ets/viewmodel/ChatViewModel.ets`：

- `defaultThinkingForAgent()` 方法：按 `agent.name` 返回布尔（`false` = 默认关闭，`true` = 默认开启），返回 `null` 表示不重置（沿用上次状态）
- 当前默认值：效率模式 `false`、轻简模式 `false`、专家模式 `true`
- 调整方式：在该方法中新增/修改 `if (agent.name === '…') return …;` 分支即可；以名称匹配而非 `id`，便于将来改名

## 原生 Markdown

基于 `@luvi/lv-markdown-in` 原生组件渲染，支持：

- CommonMark 与 GFM 常用语法
- 代码块及语法高亮
- 表格、任务列表、引用和链接
- LaTeX 行内与块级公式
- Mermaid 流程图、时序图等图表
- 深色与浅色主题自动适配

## 图片与文件附件

- 支持从系统图片选择器或文件选择器添加附件。
- 支持图片预览、文本提取、Office 文档与 PDF 解析。
- 可选择预解析附件，或通过 OpenAI Responses / Anthropic Messages 直接传递多模态内容。
- OpenAI Responses 附件采用混合策略：小图 Base64 内联，大图/火山方舟文档优先走 Files API 上传 `file_id`。
- 文件解析带状态提示、失败重试和并发节流。
- 图片附件自动生成 256px 缩略图渲染，点击查看原图，降低大图内存占用。

## 快捷拍照

- 输入框麦克风右侧提供拍照按钮，一键调起系统相机（CameraPicker，无需相机权限）。
- 拍摄的照片直接加入待发送附件，与其他附件走相同的解析流程。

## 导出 Word 文档

- AI 回答可一键导出为 `.docx` 文件，通过系统保存面板选择保存位置。
- 完整还原 Markdown 结构：标题、加粗/斜体/删除线、表格（边框与表头底纹）、代码块、引用、有序/无序列表、链接与图片内嵌。
- LaTeX 公式转换为 Word 原生公式（OMML），在 Word 中可编辑、不丢失。
- 图片支持本地 dataUrl 与网络 URL，自动缩放至页宽。

## 局部文本复制

- 回答操作区提供「复制局部」按钮，点击后长按回答内容即可跨段落拖选文本。
- 选择操作栏提供复制、全选、取消，选中内容直接写入剪贴板。

## 接收系统分享

应用已注册为 HarmonyOS 系统分享目标：

- 支持接收图片、文本和通用文件，单次最多 5 个。
- 从图库或文件管理器选择“分享”后，可以选择 Guncat Work。
- 分享内容会加入当前聊天的待发送附件区，不会自动发送消息；若当前正处于工作模式，分享文件还会同步写入该会话的沙箱工作区（`<filesDir>/workspaces/<会话ID>`），随下一次任务一起被读取。预览区附件照常保留，切回聊天模式后仍可作为附件发送。
- 基于 HarmonyOS Share Kit 的 UTD 类型匹配和 `systemShare.getSharedData()` 解析。

## CoreSpeechKit 朗读

最终朗读方案采用 HarmonyOS CoreSpeechKit 的 `textToSpeech` 能力，不包含本地 VITS、MeloTTS、sherpa-onnx 等已撤回方案。

- 查询设备实际支持的系统音色，并允许在朗读控制条中切换。
- 默认优先选择女声，默认语速为 `1.5×`。
- 音色和语速使用 Preferences 持久化，重启应用后自动恢复。
- 提供暂停/继续、关闭、倍速切换和可拖动进度。
- 朗读控制条可在页面内拖动位置。
- 使用 AVSession、音频播放长时任务和后台语音参数支持锁屏及退到后台继续播放。
- 朗读完成后控制条仍可用于拖动进度并重新播放。

> 可用音色及某些音色是否需要下载由设备和系统版本决定。

## 语音输入

- 使用 HarmonyOS 原生语音识别能力。
- 支持开始、停止和取消语音输入。
- 识别结果直接进入消息输入框，由用户确认后发送。

## 智能体与持久化

- 内置多个通用、论文、法律检索、学术检索和模型评测智能体。
- 对话、当前智能体、API 配置、功能开关及朗读配置均保存在本地。
- 支持新建、切换和删除对话。
- 跟随系统切换深色/浅色主题，并同步状态栏、导航栏和 Markdown 样式。

## 交互模式（Intelligent UI）

交互模式是 **Agent 循环的第二种交付形态**（侧边栏「Agent模式」分组中排在「工作模式」之上的 ✦「交互模式」项，是该分组的第一项；**应用启动默认就落在交互模式**，空态大标题处的「交互模式 / 工作模式」胶囊可一键换挡）：它与工作模式**共用同一套 Agent Loop 与沙箱工作区**，但**行为纪律相反、下发的工具面也不同**——工作模式是「45 个工具全量 + 多轮工具循环 + 长程交付」，交互模式是「**一句话进来，一张能操作的界面出去**」：只下发 **27 个**工具、默认**零工具调用、一轮直出界面**，工具只在"界面里的数字必须来自真实数据"时破例。回答不再是纯文本，而是一份界面程序——应用把它渲染成原生可操作界面：标题/正文、图表（柱状 / 折线 / 面积 / 横向条 / 饼环 / 径向 / 雷达 / 堆叠条）、表格、指标卡、图片墙、选项卡 / 折叠面板 / 步骤条 / 卡片块、以及整套表单控件（滑块 / 开关 / 单选 / 多选 / 下拉 / 标签选择 / 选项卡 / 输入框 / 文本域）。对齐 GPT-6 的 Intelligent UI：说一句话，拿到一个能拖、能点、能改参数并即时重算的仪表盘。

- **快车道：默认零工具、一轮直出、思考也要短（速度优先）**：交互模式**不复用工作模式的行为纪律**——"先建清单、先加载技能、反复核验、落盘成文"那套规则放进这个模式，会原样变成一串无用工具调用（`todo_write` / `list_files` / `load_skill` / 交付前自检…），用户干等的是本该直接渲染出来的卡片。因此 `AgentLoopService.buildInteractiveSystemPrompt()` 改用 `PromptBuilder.buildInteractive()`（快车道底座：身份"快" + 工作区=素材区 + 思考纪律 + 工具名索引 + 真实数据纪律），纪律写明：**默认一次回答直接给界面、不调用任何工具**；工具是**破例**、一轮最多 1~2 次且优先只读，拿到结果立刻出界面；不要 `todo_write` / `goal_*` / `schedule_*` / `subagent` / `session_search`；不要 `ask_user_question`（要问就用界面问：`Form` / `OptionCards` / `Chips`）；不写自检报告、不画 mermaid 导图。**思考也有预算**：交付物是界面，思考是纯延迟，所以它只做"定界面骨架 → 定数据来源 → 定标题与结论"三件事，被明确禁止复述界面语法与组件清单、先草拟正文、逐位心算数字、反复权衡"要不要再画一个图"，长度目标几句话或几个短条目。只有用户**明确**要导出文件时才 `load_skill` + `write_*`（且走简化流程：不做技能里的前置提问、不写自检报告）。**工具面本身也按模式裁剪**：交互模式下发的不是工作模式那 45 个工具，而是 `ToolRegistry.INTERACTIVE_TOOL_WHITELIST` 筛出的 **27 个**（读素材 / 算真实数字 / 核实外部事实 / 出文件），`todo_write`、`goal_*`、`schedule_*`、`subagent`、`session_search`、`ask_user_question`、`edit`、`delete_file` 这些长程与维护类工具**根本不出现在请求里**——提示词里的"默认零工具"是纪律，工具面裁剪是物理保证（详见[架构文档 2.1](architecture/interactive-mode.md#21-工具面物理裁剪45--27)）；技能段也同步降为**极小索引**（`SkillDirectoryFormatter.interactiveIndex()`，只列 `docx` / `xlsx` / `ppt` / `svg` / `data` 五行，替代原来几十支技能的整段目录）。于是交互模式每一轮请求里，**工具定义少 18 份 schema、技能目录只剩五行**，提示词那 36.7k → 22.8k 的降幅之外又多省下这两块固定前缀。
- **交付形态**：模型输出 **guncat-ui lang**（参考 [open-intelligent-ui](https://github.com/thesysdev/openui) 的 OpenUI Lang 设计）——一种按行书写的声明式界面语言：`root = Card([...])` 是入口、参数按位置传递、可前向引用。**一轮回答就是这份程序本身**：提示词明确要求程序之外不写任何文字（不要开场白 / 过渡句 / 总结），要说的内容全部用 `CardHeader` / `TextContent` / `Callout` 等组件放进界面里；只有纯提问（"这是什么意思"）或确实给不出界面时才用文字回答。程序写进 ` ```guncat-ui ` 围栏也照样接受。
- **结构先行、边生成边成形**：程序按行输出，客户端**边收边渲染**——第一行的 `root = Card([...])` 就让外壳出现，后面的语句一条条把内容补齐。因为每条语句独立，**输出被截断时只有最后一条没写完的语句会丢**，已写完的全部保留（这是相对"输出一大段 JSON"最根本的改进：JSON 一旦截断就整块作废）。
- **双向绑定的交互**：程序里的 `$变量` 是响应式绑定。把控件绑到它（`Slider("amount", "discrete", 0, 200, 5, [30], "金额", $amount)`），用户拖动/输入/勾选后**界面立即用新值重算**（`"金额 " + $amount + " 万"` 这类表达式会重新求值）——不发请求、不等模型。
- **回传闭环**：需要模型换数据/换算法时用 `Action([@ToAssistant("按 30 天口径重算")])`；**不写 action 的按钮**等价于把按钮文字发给助手。表单提交会把全部字段值 + 提交按钮的诉求一起打包成一条用户消息（形如「【交互界面回传】季度销售复盘 / - 口径 = customers / 换口径重算」），模型据此**产出更新后的完整界面**。历史界面会置灰（只允许操作最新一轮）。
- **状态随消息持久化**：用户调过的参数以 `]]>guncat-ui:state` 尾标记保存在该条消息里，滚动、切会话、重启后仍在；下一轮请求前这段标记会被翻译成一句人话（"(用户在当前交互界面上的设置: 金额=45; 口径=customers。)"）交给模型，因此模型始终知道界面当前的状态。
- **容错优先**：未闭合的括号/字符串会自动补齐，所以流式中间态也能解析；未定义的引用只是暂时为空（等定义流进来再出现）；**未知组件名会被丢弃并给出诊断**，但必需参数缺失或类型不符**不会丢弃组件**（用安全默认值渲染）——聊天场景里"少一个字段"远好于"整块消失"。
- **输出形态: 只要程序, 不要正文**：提示词的第一条硬性要求就是"程序之外不写任何文字"。早期版本允许模型在程序前写 1~2 句引导语，实际效果是界面旁边多出一段又重复又松散的聊天气泡（"我是…，下面这张卡片说明…"）。现在开场白 / 过渡句 / 总结一律禁止，文字必须用组件承载（`CardHeader` 当标题、`TextContent` 当正文、`Callout` 当提示、`Buttons`/`FollowUpBlock` 当下一步入口）；提示词里给了 ❌/✅ 对照示例。*（客户端不会替模型删除已经写出来的文字——那等于丢内容；这条靠提示词约束。）*
- **宽度与正文对齐**：界面的文字左右各留 16vp 内边距，与同一条消息里的正文（RichTextView 的 16vp 内边距）左右对齐，行宽一致。**表格与图表都与文字同宽**（刻意不做通栏：表头底色会让整块看起来偏左；图表自带刻度/图例文字，属于"要跟正文对齐"的一类，而顶层图表通栏、嵌在 SectionBlock 里的图表不通栏，会让同一屏里图表左边缘忽左忽右）。只有图片 / 图片墙 / 轮播这类纯视觉组件在顶层时用负外边距（`bleed()`）拿到通栏宽度，嵌套在卡片里的同款组件不动（否则会溢出容器）。另外折线/面积图**不画 y 轴刻度文字**（极值在下方单独一行展示），所以绘图区左内边距只留 12vp（原来按"有轴标签"留了 34vp，真机上就是一整块空白、绘图区被推到右边）。
- **思考强度按模式分档**：工作模式与交互模式都**强制开启深度思考**（Agent Loop 里不显示深度思考开关），强度在模型弹层的「能力预设」里选；但两档集合不同、各自持久化、互不影响：  - **工作模式**：极高(Max) / 均衡(High) / 快速(Low) —— 长程工具任务，保留 `max`；
  - **交互模式**：均衡(High) / 快速(Low) / **关闭(Off)**，**默认落在「快速(Low)」** —— 交付物是界面、追求响应快，去掉 `max`、多了关闭，且首答速度比多思考两秒更重要（用户仍可在能力预设里手动切回均衡）。
  「关闭」不是改全局 `thinkingEnabled`（那会把工作/聊天模式的深度思考一起关掉），而是由 `ChatViewModel` 的三个模式感知取值器在**下发请求时**生效：`loopEffort`（弹层高亮哪一档）、`loopEffortForRequest`（选关闭时强度退回 `low`，避免服务端校验 `reasoning_effort` 合法性失败）、`loopThinkingEnabled`（选关闭时为 `false`）。服务层无需改动：`thinkingEnabled=false` 时三种协议分别下发 `thinking:{type:'disabled'}`（OpenAI 兼容）/ `reasoning:{effort:'none'}`（Responses）/ `thinking:{type:'disabled'}` 且不带 `output_config`（Anthropic）。交互模式下的**子代理**与**上下文压缩**同样沿用该模式的档位。（存储键：`guncat_reasoning_effort` / `guncat_interactive_effort`）
- **与工作模式的关系**：两者共用 `executeWorkLoop` 主循环，但**下发的工具面按模式不同**（工作模式 45 个全量，交互模式 27 个；`AgentLoopService.toolDefsForMode()` 是唯一入口），系统提示词也按会话模式选择（`AgentLoopService.buildWorkSystemPromptFor(mode)`），压缩重建历史时同样按模式重建提示词**并沿用该模式的工具面**。差别在提示词、工具面与渲染三处；提示词这一侧的差别是**纪律分叉**（工作模式=工具循环，交互模式=快车道），不只是"交付格式"不同。完整维护说明见[交互模式架构（Intelligent UI）](architecture/interactive-mode.md)。
- **活动折叠栏（思考 + 工具调用）：交互模式独有，且按「回合」合并**。交互模式的产出是界面，过程信息不该和界面抢版面。Agent Loop 一轮一条 assistant 消息（这是**不能动**的结构：下一轮请求的历史由 `conv.messages` 重建，assistant 与它的 `toolCalls` 必须同进同出，合并数据会让模型看到"一条 assistant 同时调了所有工具"、时序错乱），所以合并只做在**渲染层**：一个用户任务之后的连续若干条 assistant 消息视为一个**回合**，只有回合**最后一条**渲染活动折叠栏，前面几轮只出正文（没有正文就整条不渲染，它的思考与工具已经收进折叠栏）。
  - **正文之前**保持展开，实时显示思考跑马灯与工具行；**正文一开始输出就自动收起**成一条「✓ 已完成 · 思考 ×4 · 5 个工具 · 12.4s」，点一下重新展开；
  - 展开后能看到**整个回合**的活动：每一轮的思考各自是一条**默认收起的**「💡 思考 ⌄」行（同一时刻只展开一条，点哪轮看哪轮；跑动中的那轮在标题行里给最新一句跑马灯，不算展开），下面跟着该轮的工具行 —— 历史轮是只读摘要（工具名/耗时），本轮是完整形态（可展开 IO/diff 卡片）。历史轮不做工具 IO 展开是因为 **ArkUI 不允许组件递归**（`WorkTurnView` 里没法再套 `WorkTurnView` 去复用完整工具行），为此复制一份完整实现不值当；
  - 开合状态是**纯派生**的（`activityOpenNow()`，依据 `isStreaming` + `message.content`），不在 `build()` 里改 `@State`；`message.content` 变化本就会让 `@ObjectLink` 重渲染，所以正文一出现就自然收起。用户点过后 `activityTouched` 置位，之后完全听用户的。
  - 标题与转圈由 `activityRunning()` 决定（流式中且「正文未出现」或「还有工具在跑」），保证**"已完成"不会出现在还没跑完的时候**；被手动停止的回合显示「已停止」（靠 `Constants.WORK_STOPPED_NOTE` 判定，生产者在 `finalizeWorkTurn`、消费者在折叠栏，共用同一常量）。刻意不因"又有新工具在跑"而自动重新展开，避免多轮之间来回开合晃眼。
  - 工作模式**不受影响**（`section='full'`，仍是思考条在上、工具行在正文之后、各自独立开合）。`WorkTurnView` 的 `section` 取 `'full' | 'grouped' | 'content'`，由 `ChatPage.turnSection()` / `shouldRenderTurn()` / `priorRunMessages()` 决定。

## 工作模式（Agent Loop）

工作模式是**与聊天智能体平行的独立身份**（侧边栏「聊天模式」标题上方的「Agent模式」分组中的 🛠「工作模式」项），进入后进入一个具备本地沙箱工作区与工具调用能力的 Agent 循环，可自主完成多步骤长程任务。完整架构见[工作模式架构与维护指南](architecture/work-mode.md)。

- **沙箱工作区**：每个工作会话对应 `filesDir/workspaces/<convId>/` 目录，支持上传文件、导出 `.zip` 打包、清空；全程应用沙箱内读写 + 系统安全组件选/存文件，无新增权限。
- **45 个本地工具**：文件 CRUD（list/read/write/append/delete/create_dir/move/search，search_files 支持 glob 文件名过滤）、任务清单（todo_write）、图片查看（view_image，走主模型多模态）、网络下载（download_file，把链接文件拉进工作区）、PDF 解析（parse_document + read_file 自动路由）、Office 生成（write_docx / write_xlsx / write_csv）、数据管道（transform_file，大文件本地清洗/转换/互转，数据不经模型上下文）、PPT 读写编辑（write_pptx / read_ppt / edit_ppt，基于 Deck JSON 中间层）、Word 读写编辑（write_docx / read_docx / edit_docx，基于 Doc JSON 中间层）、Excel 读写编辑（write_xlsx / read_xlsx / edit_xlsx，基于 Workbook JSON 中间层）、SVG 生图（write_svg，矢量出图 + PNG 预览）、技能系统（list_skills / load_skill，按需加载领域操作指南）。6.1 新增（DeepSeek Harness 移植）：glob / grep（模式找文件与正则搜索）、edit / str_replace_editor（逐字符精确编辑 + diff 卡片）、web_fetch（抓取网页/接口原文）、ask_user_question（向用户提问并等待作答）、schedule_create/list/delete（会话内定时提醒）、goal_create/get/update（会话自主目标）、subagent（子代理委派）、session_search（会话事件日志检索）。**run_js（JSVM-API 沙箱）**：无 shell 环境下唯一的"执行代码"能力，详见下文"run_js：设备内 JS 执行沙箱"。
- **技能系统**：领域操作指南打包在 `rawfile/skills/`（主 Skill 在顶层、分支 Skill 位于主 Skill 子目录；SKILL.md + reference/*.md），系统提示词技能库默认 full_index 并注入「技能使用铁律」（命中第一步必须 `load_skill`、不确定先 `list_skills`、技能正文优先），模型通过 `list_skills`/`load_skill` 渐进式加载。内置 `ppt` 技能（Deck JSON 语法、设计规范、内容纪律、主题、常见演示文稿蓝图、自检清单）、`docx` 技能（Doc JSON 语法、排版规范、文档形态选型、常见 Word 文档蓝图、专业文书规范）、`xlsx` 技能（Workbook JSON 语法、公式优先、数字格式规范、数据分析链路、常见报表蓝图、数据分析玩法）、`svg` 技能（SVG 绘制规范、"生成→预览→修正"工作流、可视化类型选择、信息图蓝图、图标/流程图/柱状图/时间轴配方）与 `data` 技能（transform_file 管道 ops 与表达式完整语法、数据质量检查、清洗/提取/互转配方、能力边界）。**当前共 32 个技能**：除上述 10 个核心技能（另含 `paper`/`law`/`research`/`sift`/`llm-eval`）外，新增 22 个从四大主流 AI 工作平台移植并适配的领域技能——`humanizer`（去 AI 味/可读性）、`prompt-engineering`（提示词工程）、`pdf`（PDF 读取/搜索/扫描件阅读）、`translation`（法律/医学翻译与术语一致性）、`questionnaire`（问卷/深访/原声打标/定量分析）、`content-rewrite`（多平台内容改写分发）、`html`（单页 HTML 开发）、`paper-reviewer`（学术论文审稿）、`review-agent`（代码评审）、`paper-rebuttal`（审稿意见 rebuttal 回复）、`research-lineage-map`（研究谱系演进图）、`marketing-plan`（营销策划方案）、`reference-audit`（参考文献审计）、`paper-close-reading`（论文精读）、`khazix-writer`（公众号长文写作）、`newmedia-writing`（小红书/公众号/短视频新媒体写作）、`marketing-material-review`（营销素材审核）、`patent-drafting`（专利申请文件撰写）、`sentiment-tracker`（舆情追踪与溯源）、`journal-format`（学术论文 DOCX 格式排版）、`research-proposal`（学术立项书/基金申请撰写）、`industry-analysis`（行业深度研究）。**结构重组（6.2.0）**：25 个内容/学术/法律/AI 类分支技能已物理归入 5 个主 Skill 子目录（`research-intelligence` 7 个 / `academic-publishing` 7 个 / `content-writing` 5 个 / `legal-ip` 4 个 / `ai-tooling` 2 个），7 个格式分支（`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`）保持顶层直连；`list_skills` 只暴露 12 个可见技能，分支由主 Skill 路由后按原 id 加载（物理路径经 `WorkSkillService.skillPath()` 映射）。
- **本地解析引擎**：`.docx/.xlsx/.pptx/.pdf` 全部在设备本地抽取文本，不依赖多模态解析 API、不消耗配额。
- **任务清单纪律**：复杂任务先 `todo_write` 建清单，清单与工作区状态经「运行时上下文」快照注入对话尾部，逐项推进、完成后更新。
- **Codex 式时间线**：每轮独立消息按「思考 → 工具步骤 → 正文」时序排列，单容器时间线 UI，工具步骤可展开查看参数与结果。
- **Codex 式产物卡片**：任务结束后，生成/改动的文件会在对话流末尾以「产物」卡片汇总，默认展开；每个文件的行级 diff 缩略默认折叠、可单独展开；任务结束自动滚到底部，卡片无需手动下翻。
- **文件就地预览与一键分享**：产物卡片、工作区弹层和右侧详情面板中的文件均可点击通过 HarmonyOS Preview Kit 就地预览，并一键通过系统分享面板分享原始文件；全程不暴露路径、不打包、不选择格式。系统预览不支持的格式（如 `.md`）会自动拉起系统“打开方式”选择框，用手机里已安装的对应应用打开。
- **三协议工具调用**：OpenAI Completions / OpenAI Responses / Anthropic Messages 均支持流式 function-calling；联网搜索开关在工具行保留（服务端搜索工具与客户端工具并存）。

## UI 与动效（5.1.0）

- 深度思考条 UI 重做：独立卡片置于气泡上方，四角统一圆角、中性浅灰配色，与整体灰调协调；「深度思考」文字右侧显示流式转圈动画，不再单独显示「思考中…」文字。
- 更新了应用图标资源（文件名不变，沿用原有资源引用，直接替换图标图片即可生效）。
- 全新柔和现代 UI：低饱和配色、大圆角、白色轻立体按钮、柔和阴影，去除复杂描边与发光装饰。
- 开屏飞入动效：启动页图标从中心向外依次弹性飞入，全程清晰，无模糊渐变或交叉淡化闪烁。
- 一镜到底中央图标：启动页中央图标使用单一 hero 节点平滑移动、放大到页面空状态中央，无“变白再清晰”的闪变。
- 底部输入区从屏幕下方外侧平滑滑入，无回弹、无从上掉落的生硬感。
- 侧边栏、设置弹层、关于弹层等浮层自然遮盖底层 hero 图标，不会出现图标悬浮在浮层之上的问题。
