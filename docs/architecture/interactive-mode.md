# 交互模式架构（Intelligent UI）

> [← 返回 README](../../README.md)


交互模式不是第二套循环，而是**同一套 Agent Loop 的第二种交付形态**。维护时先记住这条边界：**循环、工具、沙箱工作区、上下文压缩全部复用；只有「系统提示词」与「正文渲染」两处按模式分叉。** 而提示词这一侧的分叉是**纪律分叉**（不是措辞微调）：工作模式的提示词是「多轮工具循环 + 长程交付」，交互模式的是「默认零工具、一轮直出界面」。

## 1. 身份与会话模型

- **虚拟智能体**：`Constants.INTERACTIVE_AGENT_ID = 'interactive'`，由 `ChatViewModel.buildInteractiveAgent()` 注入 `agents` 列表**第二位**（`work` 之后），`AgentDrawerView` / `DswSidebar` 把它和工作模式一起归入「Agent模式」分组（`workAgents()` 判定两个 id）。
- **会话绑定**：`Conversation.mode = 'chat' | 'work' | 'interactive'`，`agentId` 固定为 `'interactive'`；`startNewConversation()` / `selectAgent()` / `deleteConversation()` 三处的模式推导统一走 `Constants.MODE_*`。
- **界面跟随**：`ChatPage` 用 `vm.agentLoopMode`（work 或 interactive）代替原来的 `vm.workMode` 选择时间线、工作区面板、上传落盘路径等共享能力；只有文案类差异走 `loopModeTitle` / `loopModeHint` / `loopModeInputPlaceholder` / `loopModeEmptyDescription` / `loopToolLabel` 五个 getter。
- **深度思考**：与工作模式一致，进入即强制开启（工具行不显示该开关）；档位默认「**快速(Low)**」（`ChatViewModel.interactiveEffort`，存储键 `guncat_interactive_effort`），可在能力预设里切到均衡或关闭。

## 2. 提示词分叉

```text
ChatViewModel.executeWorkLoop(conv)
  → AgentLoopService.buildWorkSystemPromptFor(conv.mode)
      mode === 'interactive' → buildInteractiveSystemPrompt()   // 缓存于 cachedInteractivePrompt
      mode === 'work'        → buildWorkSystemPrompt()
```

`buildInteractiveSystemPrompt()` = `GuncatUiPrompt.promptSection()`（guncat-ui lang 语法 + 组件清单 + **丰富度/组件选择优先级** + 交互闭环 + 输出顺序纪律 + 示例 + 反例）+ **快车道底座** `PromptBuilder.buildInteractive()`（身份"快" + 工作区=素材区 + 工具名索引 + 真实数据纪律 + 技能库"只在明确要文件时才用"）+ `GuncatUiPrompt.INTERACTIVE_DUTY`（交付形态职责，收尾并拥有最终解释权）。三段拼接后**整体静态**、进程内缓存一次，KV 缓存前缀与工作模式同样逐字节稳定。

**为什么不复用工作模式的提示词底座**（这是本节最需要维护者记住的一条）：`PromptBuilder.build()` 里的身份/四步法/工作流程/输出丰富性/Mermaid/交付前自检清单，全都是为「多轮工具循环 + 长程交付」写的——"复杂任务先用 `todo_write` 建清单""命中技能第一步必须 `load_skill`""交付前用 `list_files` 核验""最终总结必附 mermaid 导图"。这些规则放在工作模式里是对的，放在交互模式里就变成模型**先跑一串和界面无关的工具调用**，用户干等一个本可以直接渲染的卡片。所以交互模式只保留四块底座：**身份（快）＋工作区（素材区，文件树已在运行时快照里）＋工具名索引（`PromptBuilder.buildToolNameIndex`，与请求里真正下发的工具定义同源，只列名字不写用法规则）＋真实数据纪律**；行为约束集中成一句"默认零工具，工具是破例"。界面的语言契约、丰富度、示例、反例仍全部来自 `GuncatUiPrompt`，两处不重复。实测提示词从 **36.7k 字符降到 22.8k 字符**（其中行为纪律段 15.6k → 1.7k），首答 TTFT 与输入 token 同步下降。

**工具面刻意不动**：交互模式下发的工具定义与工作模式**逐字相同**（同一份 `WorkFileService.toolDefs()`），45 个工具一个不少 —— 只是提示词不再推着模型去用它们。这样"用户明确要 Word/Excel/PPT"这类请求在交互模式里照样能落盘，而"给我看看这个数据"会直接得到界面。`test/guncat-harness/test-core.mjs` 里的"快车道底座不复用工作模式的行为纪律"一组断言就是这条边界的守门员：谁把 `# 工作流程` / `四步法` / `交付前自检清单` / `# 输出丰富性原则` 拼回交互模式，测试立刻变红。

**「丰富度」一节（`GuncatUiPrompt.RICHNESS`，约 3.3k 字符）是引导模型产出复杂界面的主要抓手**：只写"一段文字 + 一张表格"在语法上完全合法、但在体验上等于退回普通聊天，而这是模型最容易偷懒的地方，所以单独成段并给了强对照。它包含四块：

1. **组件选择优先级表**：每行「要表达的内容 → 优先用 → 不要退化成」。例如关键数字与同比用 `OverviewCardBlock` + `MetricIndicatorInline` 而不是写进句子；构成用 `PieChart`/`SingleStackedBarChart`、趋势用 `LineChart`/`AreaChart`、排名用 `HorizontalBarChart`、达成率用 `RadialChart`、多维对比用 `BarChart`/`RadarChart`，表格只用于"需要逐行精确核对"的场合且必须有看得懂的上层。
2. **分层配方**：抬头（`CardHeader`）→ 结论（指标卡/`Callout`）→ 可视化（图表/图片墙/`Steps`/`TagBlock`）→ 明细（`Table`/`EntityList`/`ListBlock`）→ 操作（`Form`/`OptionCards`/`Buttons`），**典型 8~14 个组件是常态**。
3. **防堆砌**：同一份数据不要原样说三遍——指标卡给总量与同比、图表给趋势与分布、表格给逐行明细，三者必须互补（这一条是为了避免"为了丰富而重复"走向另一个极端）。
4. **同一份数据的「不合格 vs 合格」对照**：❌ 只有 `TextContent` + `Table`；✅ 抬头/指标卡/折线/环形/明细表/表单分层组织。

**末尾的「入口」也改成按需给（同日第十五次）**：追问块组件下架后，模型仍然在每轮末尾挂一组按钮 —— 问它原因，它说是因为有一条硬性约定「每轮回答都要给下一步入口，且入口必须和当前数据直接相关」，于是它把这条当默认动作执行（给一个读文件的任务配「再读一次 / 追加一行再读」）。**问题出在规则本身，不是在组件**。所以把"每轮都要给"这条要求整体删掉，改成**按需给**：
- 语法段：`想引导下一步` → `只有确实存在「和当前数据直接相关、点一下就推进」的动作时才给入口`；
- 分层配方第 5 层 `操作层` → **`操作层(可选)`**（"大多数回答在明细层结束就够了，每轮硬塞收尾按钮 = 模板感"）；
- 丰富度优先级表：`| 下一步入口 |` → `| 需要用户操作时 |`，右列明写"每轮都硬塞一组收尾按钮"是反例；
- 反例清单：点名为"每轮都在末尾塞一组收尾按钮/入口"，并给出**判定标准**——不是"和内容相关"，而是"**用户大概率真会点它**"（"再读一次文件""把刚才的再跑一遍"这类一律不加）；
- `INTERACTIVE_DUTY` 第 4 条：`每轮都要给"下一步的入口"` → **`入口按需给，不按轮给`**；
- 示例 1 末尾补一句说明：示例里的 `tune*`（表单/按钮）是"确实存在换口径重算这个动作"才有的，**不是格式要求，不要照抄成每轮挂一组**；示例 2 标题改成"…+ 用户确实要推进时的动作按钮"。
- 断言：新增"全篇不再有'每轮都要给入口'的硬性要求"（同时在位的还有"追问块全篇不出现""组件清单里没有" "仍注册仍能解析"）。单测 500 → 501。

**追问块组件彻底下架（同日第十四次）**：`FollowUpBlock` / `FollowUpItem` 从提示词里连名字都不出现（`UiComp.promptHidden`，`promptSection()` 过滤），模型看不到就不会再生成；**组件本身照旧注册、照旧能解析与渲染**（历史消息与外部程序里的追问块仍然兼容 = 接口兜底）。

配套改动：`STREAMING` 里原来的"不要 6 个元素写成 20 个元素"改成"组件数量不是越少越好，8~14 个分层清晰是目标"；`ANTI_PATTERNS` 增加三条（偷懒的文字+表格组合、把结构化指标塞进正文、为丰富而重复数据）；`INTERACTIVE_DUTY` 增加"默认往丰富那一侧靠"；`REPAIR_SYSTEM`/`REPAIR_INSTRUCTION`（主回答没产出程序时的补救）也从"3~5 个元素"改为要求分层与图表。**共 17 条提示词断言**在 `test/guncat-harness/test-core.mjs` 里守住这些内容，避免以后改提示词时被无声删掉。

上下文压缩（`compactWorkHistoryIfNeeded`）在重建历史时会用**同一个 `loopMode`** 重新取系统提示词，因此压缩后不会串模式。

## 3. 语言：guncat-ui lang（模型看到的契约 = 我们解析的契约）

`common/GuncatUiLang.ts` 是**语言核心**（词法 → 语法 → 求值 → 围栏切分），`common/GuncatUiLibrary.ts` 是**组件库单一事实源**（组件名 / 分组 / 描述 / **位置参数表**）。同一张组件表同时驱动三件事：**系统提示词里的组件清单**、**解析阶段的参数映射与类型转换**、**渲染阶段的合法性判断**。三者共用一张表，「模型看到的」才等于「我们解析的」也等于「我们能画的」。

设计对齐参考项目 [open-intelligent-ui](https://github.com/thesysdev/openui) 的 OpenUI Lang（见 `docs/reference/openui-lang-spec.md`）：**按行语句 + 位置参数 + 可前向引用**。

```text
root = Card([header, lead, kpis, chart, detail, tune])      ← 第 1 行: 外壳先出现
header = CardHeader("季度销售复盘", "2024 Q1–Q4")
$metric = "revenue"                                          ← $变量 = 响应式绑定
lead = TextContent("全年营收 **1,284 万**, 同比增长 18.6%。")
kpis = OverviewCardBlock([kpi1, kpi2])                       ← 可前向引用: kpi1 下面才定义
chart = BarChart(["Q1","Q2"], [s1, s2], "grouped", "季度")
s1 = Series("2023", [241, 268])
tune = Form("tune", tuneBtn, [tuneField])
tuneField = FormControl("按哪个口径看?", RadioGroup("metric", [RadioItem("营收","","revenue")], "revenue", $metric))
tuneBtn = Buttons([Button("换口径重算", Action([@ToAssistant("按客户数口径重新分析")]), "primary")])
```

**语法规则**（提示词里逐条给出，模型照抄）

| 规则 | 说明 |
| --- | --- |
| 语句 | 每行 `标识符 = 表达式`；`root = Card([...])` 必须存在且写在第一行 |
| 参数 | **位置参数**（顺序即签名顺序）。写 `CardHeader("标题")`，**不能**写 `CardHeader(title: "标题")` |
| 表达式 | 字符串 / 数字 / `true`·`false` / `null` / 数组 `[...]` / 对象 `{键: 值}` / 组件调用 / 引用 |
| 引用 | 可前向引用（hoisting）；**每个定义出的标识符都必须被引用**，否则不会渲染 |
| 运算 | `+ - * / %`、`== != > < >= <=`、`&& \|\| !`、三元 `a ? b : c`、成员 `obj.f`、下标 `arr[0]` |
| 绑定 | `$变量 = 默认值`；把 `$变量` 传给控件的绑定参数即可双向绑定 |
| 内置函数 | `@Count @Sum @Avg @Min @Max @Round @Abs @Floor @Ceil @Len @Join @Upper @Lower @Pct @Coalesce @Filter @Sort`，以及 `@Each(arr, "item", 模板)` 逐项展开 |
| 动作 | `Action([@ToAssistant("文本"), @Set($x, 值), @Reset($x), @OpenUrl("https://…")])` |
| 注释 | `//` 或 `#` 行注释（会被剔除） |

组件库共 **70 个组件**，分 9 组：根与内容 / 布局 / 表格与数据 / 图表 / 指标与文本 / 卡片块 / 列表 / 表单 / 按钮与图标。渲染器为每个组件都给出原生 ArkUI 实现：

| 组 | 组件 |
| --- | --- |
| 根与内容 | `Card` `CardHeader` `TextContent` `MarkDownRenderer` `Callout` `TextCallout` `Image` `ImageBlock` `ImageGallery` `CodeBlock` `Separator` `InlineHeader` `TagBlock` `Tag` `EntityList` |
| 布局 | `SectionBlock` `SectionItem` `Tabs` `TabItem` `Accordion` `AccordionItem` `Carousel` `Steps` `StepsItem` |
| 表格与数据 | `Table` `Col`（列式：每列自带一列数据） |
| 图表 | `BarChart` `LineChart` `AreaChart` `HorizontalBarChart` `PieChart` `RadialChart` `SingleStackedBarChart` `Series` `RadarChart` |
| 指标与文本 | `Text` `BoldText` `IconText` `ImageText` `MetricIndicatorInline` `MetricIndicatorWithStrikethrough` |
| 卡片块 | `SnippetCardBlock` `OverviewCardBlock` `ContextCardBlock` `CompositeCardBlock` `VisualCardBlock`（及各自 Item） |
| 列表 | `ListBlock` `ListItem` |
| 表单 | `Form` `FormControl` `Input` `TextArea` `Select` `SelectItem` `DatePicker` `Slider` `RadioGroup` `RadioItem` `CheckBoxGroup` `CheckBoxItem` `SwitchGroup` `SwitchItem` `Chips` `ChipItem` `OptionCards` `OptionCard` |
| 按钮与图标 | `Button` `Buttons` `IconButton` `Icon` |

**容错与限额**（`UiLimits`）：源码 ≤200k 字符、语句 ≤400、表达式嵌套 ≤24、数组 ≤600、子元素 ≤200、文案 ≤4000 字符、绑定 ≤64 个。

刻意"迁就"模型的写法（都是实践中真实出现的，曾导致卡片空壳或整块消失）：

| 模型写法 | 处理 |
| --- | --- |
| 输出被截断（最后一行没写完） | 未闭合的括号/字符串**自动补齐**（`UiAutoClose`），未写完的那条语句丢弃，**已写完的全部保留** |
| 引用了还没定义的变量 | 该值暂时为空，等定义流进来再出现（不报错、不中断） |
| 忘了写 `root` | 退回"第一个组件语句"当入口；**一个组件语句都没有**才判定为"界面残缺"并触发一次重新生成 |
| 参数写成键值 `CardHeader(title: "x")` | 位置参数才是契约；键值写法不被支持，模型会被提示词与反例清单纠正 |
| 用了没登记的组件名（`Chart` / `markdown` / `Card2`） | **丢弃该组件并记录诊断**（保留会渲染成莫名空卡片，更难排查）；界面底部可展开「诊断」看到具体名字 |
| 必需参数缺失 / 类型不符 | **不丢弃组件**：数字串转数字、单值包成数组、缺必需参数用安全默认值，并在诊断里记录（聊天场景里"少一个字段"远好于"整块消失"） |
| 语句里混入散文或垃圾行 | 不是 `标识符 = 表达式` 形态的行被静默跳过，其余语句照常渲染 |
| 同名语句写了两遍 | 后者覆盖前者（对齐参考实现） |
| 把程序写在 ` ```guncat-ui ` 或 ` ```openui-lang ` 围栏里 | 同样接受；其它语言的围栏（` ```json ` / ` ```python `）按普通 Markdown 代码块渲染 |

> 与参考实现的一处**有意偏离**：参考实现在必需参数缺失时**丢弃整个组件**（借 validation error 逼模型写对）。聊天场景里这会让用户直接看不到内容，所以这里改成"用安全默认值渲染 + 记录诊断"。

## 4. 渲染与流式成形

```text
assistant Message.content（整段界面程序，或 ```guncat-ui 围栏 + 前后正文）
  → GuncatUiParts.build(content, finalized)        // common/GuncatUiParts.ts
      ├─ TEXT 片段 → RichTextView（Markdown 渲染）
      └─ UI 片段   → GuncatUiView（@Prop programText + complete + truncated + locked + stateJson + onInteract）
```

- **从「一个 JSON 块」到「一段程序」**：旧实现用 ` ```guncat-ui ` + 严格 JSON 交付，一旦被输出上限截断就**整块作废**（只能靠额外的 JSON Output 请求重做）。改成按行语句后，截断只损失最后一条没写完的语句，**界面主体照常渲染**——"自动续写/重做"从主路径降级成兜底。
- **宽度约定**：`GuncatUiView` 的根容器左右各留 `edge()=16vp` 内边距，使界面里的**文字**与同一条消息的正文（RichTextView 的 16vp）左右对齐 —— 否则界面文字行宽会比正文更宽，观感像"溢出到气泡边缘"。**表格刻意不做通栏**（表头底色与每列文字都从最左侧开始，比正文宽出去就会显得"整块偏左/歪了"）；只有图表 / 图片 / 图片墙 / 轮播这类"本身没有左对齐文字"的组件在**顶层**时用 `bleed(topLevel)` 抵消这层内边距拿到通栏宽度，`renderNode(el, topLevel)` 的 `topLevel` 只在 root 的 Card 直接子项里为 `true`（嵌套在卡片里的同款组件不会被推出去）。脚注区（截断提示 / 诊断 / 原始输出）也补上同样的内边距以保持左对齐。
- **ArkUI 刷新机制（踩过的坑，改代码前必读）**：ArkUI 的 `ForEach` 在重渲染时先比对新旧键值，**键值不变的项直接复用已有子组件、连 item builder 都不会重新执行**；而"绑定值变了 → 重新物化出新树"这件事（物化树存在普通字段 `this.root` 里，不是可观察状态）只能靠键值变化传下去。真机表现：点 `Chips` / 单选 / 多选后选中态不变，切到别的会话再切回来（组件被销毁重建）才显示正确。
  现在的键是**渲染指纹**：`GuncatUiLang.elementSignature(el, values)`（djb2 哈希，覆盖 `type` + 排序后的属性 + 递归进嵌套元素/数组；**绑定属性取实时值**，另把控件状态键的实时值也混进去——`Chips` 这类按 `name` 绑定的控件选中值只在 state 里，不进指纹就会复发"选中态不刷新"）。键 = `child.key + '#' + 指纹`，于是"内容真的变了"的项换键重建（实时刷新）、"内容没变"的项继续复用。
  **绑定值刷新机制（真机五轮才试透，改这里前务必读）**：值变化时重新物化出一棵**新树**（`root` 是 `@State`）。让界面跟上靠的是**值节点自己重画**，**不是**"换 ForEach 键 ⇒ 重建该项"——后者在这台设备上一直不可靠：`.id(rev)` 触发器、方法内读 @State、恒真 `if` 包住整棵树、`root` 改 `@State` + 顶层列表当场取新树、拖动链指纹快照，全都试过、全都没稳定生效。真正有效的是：
  - `live(el)`（视图内）：读一下 `sigTick` **登记依赖**（读取发生在属性/组件参数表达式里，这是被追踪的形态），再按 **key** 从 `this.root` 取**当前树里的那个元素**，找不到才退回过期对象；
  - 全视图 **234 处值读取**都包了 `this.live(...)`。于是拖动中每次节流刷新（`revalue()`：只换树 + `sigTick++`）就足以让指标卡/图表/列表行跟着变，而且**不重建任何 ForEach 项** ⇒ 正在拖的 Slider 不会被销毁，**不需要冻结/快照机制**（那套已删除）。
  - **前提（踩过）**：`GuncatUiLang.assignKeys` 必须覆盖**三种**装子元素的形状 —— `children` 列表、元素数组属性、**单元素属性**（如 `OverviewCardItem(top, bottom)` 的 top/bottom、`FormControl` 的 control）。漏了第三种就会出现一批 **key 为空的元素** ⇒ `live()` 按 key 定位不到 ⇒ 那些节点永远显示旧值（真机实测 19 个节点里 7 个空 key，也正是"拖动链时找得到时找不到"的原因）。
  - Record 里的值（`EntityList` 的行、`Table` 单元格）是 baked 在对象里的，闭包捕获的是旧对象，需要 `liveRow` / `liveCell` 按下标从当前树取。
  - **Slider 是唯一例外**：它自己绑定的 `value` **不进指纹**（常驻豁免，不是拖动期间才豁免——那样拖动开始的一瞬间键就变了，反而触发一次重建）。因为指纹是**递归**的，`value` 一进指纹，Slider 自己**和它每一层祖先项**（`FormControl` → `SectionItem` → `SectionBlock`…）的键都会随拖动变 → ForEach 重建那些项 → 正在拖的 Slider 被销毁、手势当场丢失（真机症状：能点选、不跟手）。它的显示值由 `live()` 负责。选择类控件（`Chips`/单选/多选）**不能**豁免，否则选中高亮不刷新。
  - 拖动收尾：`End`/`Click` → `finishDrag()`；真机上 `End` 不一定来，用**静默计时器**（`DRAG_IDLE_MS`=220ms 没有新的 `Moving` 即当松手）兜底。**不要**给 Slider 挂 `.onTouch` —— 那会插手触摸派发，表现为"只能点选、不跟手"。
  **两个 epoch 分工**：`rev` 由 `rebuild()`/`rematerialize()` 递增，被 `.id()` 读到 → 触发整组件重跑（各子项按指纹决定复用还是重建）；`sigTick` 由拖动中的 `revalue()` 递增（**只换值、不动 id**）→ 只让各子项重算指纹，冻结链上的键仍来自快照，于是"兄弟节点实时刷新"和"手势不被打断"可以同时成立。
  **拖动中的 Slider 要特殊处理**：指纹机制靠"键变 ⇒ 重建"生效，而拖动时它的 `value` 一直在变，直接算指纹会被重建、手势当场丢失。所以用 **`dragFreeze` 祖先链指纹快照**：`Begin` 时用 `GuncatUiLang.pathToKey()` 取"root → 被拖控件"整条链，把链上每个元素**当时的指纹**快照下来，拖动期间这些元素一律用快照当键——与拖动前**逐字节相同**，谁都不重建。注意不能实现成"命中就返回一个常量指纹"：那样键在 `Begin` 一瞬间就变了，照样重建（只是把丢失推迟一次刷新）；而只冻控件自己也不够，祖先指纹含子树，同级兄弟一变祖先就换键。收尾走 `finishDrag()`：清快照 + `rematerialize()`（`rev` 变 → 整树重跑，把拖动期间压住的变化一次刷出来）+ 回传状态。
  代价与兜底：① 拖动期间被冻结那条链**内部**依赖当前值的变化不会实时刷新（同级兄弟照常实时刷新），松手时补上；② 收尾不能依赖 `SliderChangeMode.End`（真机上不一定来），但**也不能给 Slider 挂 `.onTouch` 兜底** —— 真机实测那样会插手它的触摸派发，表现为"只能点选、不跟手"（拖不动）；改用**静默计时器**：拖动中每次 `Moving` 重新起表，超过 `DRAG_IDLE_MS`(220ms) 没有新的 `Moving` 就当作松手（`finishDrag` 幂等，一次手势只回传一次）；③ 拖动中的实时刷新按 80ms 节流，被冻结项里的 `Slider` 数值文案靠 `sliderValueText()` 读 `sigTick` 单独重画（ArkUI 的按元素依赖跟踪，同文件里折叠/选项卡也是这么工作的）；④ **安全检查**：若拖动开始时 `pathToKey()` 没找到"root → 控件"的链（树形超出预期），就**关闭拖动中的实时刷新**，退回"松手再刷"——宁可少刷，也不能因为冻结没生效而把正在拖的 Slider 重建掉。
- **ArkUI 布局挤压（踩过的坑）**：`Row` 里"固定尺寸元素 + `layoutWeight` 文本"时，固定尺寸那个元素的布局宽度**偶尔会被测成 0**，于是文本左移、和它叠在一起（真机截图：小圆底图标压在标题第一个字上）。因此凡是这种组合都做三重保险：① 固定尺寸元素加 `.flexShrink(0)` + `.constraintSize({minWidth, minHeight})`；② 间距不用 `Row({space})` 而是给文本列显式 `.margin({left})`；③ 图标类元素把这三条**封装在组件内部**（`GuncatUiIcon` / `GuncatUiChevron` / `GuncatUiIconBadge`），这样任何一处使用都自动带上，不必逐个调用点记得加。已加固的位置：`IconText`、`ImageText`、`Callout`、`ListBlock(variant=image)`、`SwitchGroup`、`EntityList`、`Slider` 标签行、图表图例圆点、有序列表序号圆点。
- **图表绘制：`Path.commands` 是 px，其它属性是 vp（踩过的坑，改图表前必读）**：ArkUI 里 `Shape` 的**布局**（width/height）与 `strokeWidth` 等属性按 **vp**，而 `Path.commands` 路径命令按**物理像素 px**（[官方论坛确认](https://bbs.itying.com/topic/682aec1c062dc60098c28a3c)）。同一个组件里两套单位，混起来就会出现"比例全错"，三个真机症状都是它：
  - 折线图/饼图按 vp 写坐标 → 只画了约 1/3 大小、缩在左上角，盒子剩下大片空白（截图里"折线图太小、下面一大片空"）；
  - 径向图半径 28（vp 写法）= 28px，而环宽 8vp ≈ 26px → 描边比半径还粗，变成一个实心色块、百分比数字被挤出圆外；
  - 用 `viewPort` 缩放虽然能让图形尺寸对，但 `strokeWidth` 不跟着缩放 → 饼图画出 100vp 宽的巨型圆环被容器裁成半圆。
  现在的约定：
  - 几何计算**全部按 vp** 写（可读、可单测），只在**序列化成路径字符串**时统一乘 `UiChartGeom.unit`（= `vp2px(1)`，由 `GuncatUiChartUnit.ensure()` 在每个图表的 `aboutToAppear` 里设置）；`strokeWidth` 等属性保持 vp 原值，**不要乘**。
  - **不用 `viewPort`**：固定尺寸图表（饼/环/径向/雷达）用固定 vp 盒子 + 绝对坐标；宽度自适应的折线/面积图用 `onAreaChange` 量宽度（用"实测高度 ÷ 已知 vp 高度"自校准单位，所以不依赖 `Area` 报告的是 vp 还是 px），高度由 `chartHeight` 显式给（默认 160vp），不再用 `aspectRatio` 推导。
  - 饼图用**实心扇形** `wedgeAt`（不靠 strokeWidth 填满），环形用 `arcAt` 描边（半径取内外中线、环宽 = 描边宽度），径向用 `circleAt` 轨道 + `arcAt` 进度弧。
  - 几何计算集中在 `common/GuncatUiPaint.ts`（纯逻辑、可单测）：`linePath/areaPath/gridPaths/points` 接受 `UiBox`，另有 `arcAt/wedgeAt/circleAt`；`UiChartGeom.n()` 是唯一的单位换算点。
- **本地调参不碰滚动位置**：界面回传分两类 —— `kind='action'`（要模型重算）会追加用户消息并滚到底部；`kind='state'`（拖动 / 勾选 / 填表）**既不整页刷新也不滚动**（`ChatViewModel.persistUiState()` 刻意不调 `notifyUIChange()`，`ChatPage` 也只在 `action` 时 `refreshTick++` / `scrollToBottomDelayed()`），否则用户在卡片里操作时页面会突然被拽到底部。
- **输出形态纪律**：提示词禁止模型在程序之外写文字（详见上文「交互模式」一节的同名条目），设计上只做提示词约束、**不在客户端删除模型已写出的文字**——那等于丢内容，而"内容凭空消失"是这个项目一直避免的体验。
- **渐进渲染**：客户端的 `GuncatUiParts.build()` 每次拿到新文本就重新解析并物化整棵树；`root = Card([...])` 第一行就让外壳出现，后续语句逐一补齐。未写完时 `complete=false`，控件置灰。
- **文本与非围栏程序共存**：`GuncatUiParts` 会先用组件库判断一段正文是不是"界面程序"（要求至少 2 行 `标识符 = 组件名(...)` 语句，或 1 行且形如 `root = ...`），是则把程序**之前**的引导语留作文本片段。这样"模型写了 1~2 句引导语 + 一段程序"和"整条消息就是程序"两种形态都能正确渲染。
- **普通回答必须照常显示**（历史事故）：`ChatBubbleView.buildAIContent()` 早期版本在"消息里没有 guncat-ui 围栏"时直接跳过整段渲染，导致聊天模式下**不含界面的回答正文一个字都不显示**。现在两个视图都保证：`GuncatUiParts.build()` **永远至少产出一个文本片段**，而**没有界面片段时视图主动把 `uiSegs` 清空**、走 `uiSegs.length === 0 → RichTextView` 的快车道（既显示正文，又不会边生成边闪，见下文"三条渲染路径"）。
- **输出被截断也能收场**：`GuncatUiParts.build(content, finalized)` 用 `finalized`（来自 `!isStreaming`）区分"还在写"与"写完了但没断开"：后者标记 `truncated`，界面底部显示「界面未写完，以上为已生成的部分」，不会永久转圈。
- **补救（兜底）**：一轮结束时若最后一条 assistant 消息**完全没有可渲染的界面**（`GuncatUiParts.needsRepair` = 文本像程序但 `root` 为空），主循环用 `AgentLoopService.generateUiProgram()` 发一次**不带工具、低推理档**的补救请求，要求模型重新输出一份完整程序；拿到后校验可用（`isUsableProgram`）再作为一条新消息追加（标注「（界面已重新生成）」）。最多 `UI_CONTINUE_MAX_ROUNDS = 2` 轮；补救也失败才回落到"文本续写"。**注意补救请求不再使用 `response_format: json_object`** —— JSON 模式会把模型逼进"一个 JSON 对象"的思维，反而写不出多语句结构。
- **原始输出与诊断随时可查**：界面底部有「查看原始输出」开关（有源码时始终可点开，强制按字符换行 + 可滚动）；解析产生过诊断（未知组件 / 缺参数）时额外给出「诊断 · N 条」折叠面板。用户能直接看到模型到底写了什么。
- **重建时机**：`WorkTurnView` / `ChatBubbleView` 在正文变化时才重建片段（内容相同直接返回，避免 33ms 空转）；`GuncatUiView` 用 `@Prop @Watch('onProgramChanged') programText` 接收源码——**传字符串而不是嵌套对象**（ArkUI 里字符串 @Prop 的变更通知最可靠，嵌套对象经 @Prop 深拷贝既慢又容易丢状态）。
- **三条渲染路径：纯文本必须走快车道**（闪烁事故的修复口径，改这里前必读）：
  - **没有界面程序片段（工作模式 / 聊天模式的普通回答）→ `uiSegs` 保持为空**，正文由**单个 `RichTextView`** 承载。这是快车道：组件实例始终是同一个，内容靠 `@Prop` 更新，三方库自带流式增量渲染，**生成过程中不闪**。
  - **有界面程序片段时**才走分段 `ForEach`。原因：`ForEach` 键不变的项**连 item builder 都不重跑**，所以卡片旁边那段文本必须靠换 key 才能跟上内容。
  - **纯文本绝不能走分段路径**：分段路径里文本片段的 `renderKey` 每次内容变化都要递增（那是卡片旁文本刷新所必需的），而 key 一变 `ForEach` 就销毁重建 `RichTextView` —— 每 33ms 一次，真机表现就是**工作模式/聊天模式纯文本"不停闪烁"**（同一个 33ms 节流定时器驱动，所以只在生成过程中闪）。这也是 `uiSegs.length === 0 → RichTextView` 那条分支唯一被真正走到的场景，**不要删**。
- **两类 key，两种刷新节奏**（都踩过坑）：
  - **文本片段**（仅指卡片前/后的正文）内容变化时递增它自己的 `renderKey` → 强制重建那个 `RichTextView`。否则真机上会出现"卡片后面的正文只显示一两个字，刷新后才完整"（该 `RichTextView` 是 `ForEach` 里的项，键不变 ⇒ item builder 不重跑 ⇒ `@Prop` 永远是旧片段的文本）。
  - **界面片段的 key 不含程序文本**，只含语义（`uiSegsShape()` = 每段类型 + 闭合 + 未完成）。若把源码拼进 key，等于流式期间每 33ms 销毁重建整块界面 → 闪烁 + 输入框失焦。同理，`GuncatUiView` 内部的 `ForEach` key 由**元素自身的稳定标识**（命名语句用变量名、匿名内联元素用位置）**加该子树的渲染指纹**组成（早期版本拼的是全局 `rev`，会把所有子项一起重建，见上文"ArkUI 刷新机制"）。
- **绑定值变化靠 `@State` 唤醒 + 指纹换键来传**：物化后的元素树存在普通字段 `this.root`（不是可观察状态），所以赋值给 `@State rev` / `sigTick` 把重渲染打起来；`itemKey()` / `wake()` 各读一下它们（只用于登记依赖、不进键值），重跑键函数时子项按新指纹决定"复用还是重建"。
- **收尾自愈**：真机上"流式结束 → 组件按已结束语义重建"这一步可能不触发（`@Watch` / 父组件属性更新在真机时间线里不可靠）。因此两个视图各自带一个 `startUiSettleTimer()`：每 250ms 采样消息正文，连续两次一致即视为产出结束，就地按 `finalized` 重建片段，8 秒超时兜底，`aboutToDisappear` 清理。**组件自己负责收尾，不依赖任何外部通知。**
- **维护须知**：组件内派生的渲染数据一律用数组/基本类型 `@State` 整体赋值；需要"强制重新渲染某个子组件"时用 key 变化，但 **key 必须绑定语义而不是刷新次数**。
- **界面归属**：交互模式走 `ChatPage.buildWorkTimeline()` → `WorkTurnView`（共享时间线，含思考/工具行），聊天模式走 `ChatBubbleView`，两条路径都接了 `GuncatUiView`（聊天模式下界面可本地调参，但"回传模型"的动作会提示需切到交互模式）。

## 5. 交互闭环（本地重算 + 回传模型）

界面上的交互分两类，这是整个功能的核心设计：

```text
A. 本地交互（不发请求, 界面立即重算）
   声明 $变量 → 把控件绑到它 → 用户拖动/点选
   → GuncatUiState.set() → GuncatUiLang.render(program, bindings) 重新物化整棵树
   → 表达式里的 $变量用新值重算（"金额 " + $amount + " 万" 立即更新）
   → GuncatUiEvent{kind:'state'} → 仅持久化绑定值, 不触发新一轮

B. 回传助手（发一条消息, 触发新一轮回答）
   Button/Action([@ToAssistant("按 30 天口径重算")]) 或表单提交
   → GuncatUiEvent{kind:'action', message, stateJson}
   → ChatBubbleView/WorkTurnView.onUiInteract(messageId, ev)
   → ChatViewModel.sendUiInteraction(messageId, ev)
       ├─ 先把最新绑定值写回该条消息（尾标记）——模型看到的是"设置 + 诉求"
       ├─ 校验 messageId === 最后一条 assistant 消息（历史界面已归档, 仅提示不发送）
       ├─ 循环空闲 → executeWorkLoop(conv) 立即重算并重出界面
       └─ 循环进行中 → 推入 workSteerQueue, 本轮工具结束后作为「用户补充」注入
```

- **表单提交**：`GuncatUiRuntime.formMessage()` 把每个 `FormControl` 的标签与当前值拼成逐项清单，套上「【交互界面回传】<界面标题>」前缀；提交按钮自己的 `@ToAssistant` 文本会接在后面（形如「… / - 口径 = customers / 换口径重算」）。
- **不写 action 的按钮**等价于把按钮文字发给助手（对齐参考实现）。
- **状态键的选择**：控件有绑定（`value` 传了 `$x`）就用 `$x` 作状态键，没有绑定则退回控件自身的 `name`；`GuncatUiRuntime.stateKeyOf()` 统一这个规则。
- **状态随消息持久化**：绑定值以 `]]>guncat-ui:state` + 一行 JSON 追加在消息正文末尾（对齐参考实现的 `]]>openui:context`）。`GuncatUiParts` / `plainSummary` 都会先把它拆掉，用户看不到它。
- **下一轮把它翻译成人话**：`ChatViewModel.assistantLoopContent()` 在拼装循环历史时把尾标记换成 `(用户在当前交互界面上的设置: 金额=45; 口径=customers。)`（标签取自 `FormControl.label` / `Slider.label`，所以模型看到的是用户看到的词）。**同时清掉尾标记本身**——它对模型是噪音。
- **置灰规则**：`vm.pendingUiMessageId` 给出「当前可交互的那条消息 id」，其余界面（历史轮次、执行中的中间态）`locked=true`；`GuncatUiView.interactive() = complete && !locked`，所有控件与按钮统一用它。

## 6. 扩展与维护入口

| 想改什么 | 改哪里 |
| --- | --- |
| 新增组件 | `common/GuncatUiLibrary.ts` 的 `definitions()` 加一条（名字/分组/描述/位置参数表）→ `views/GuncatUiView.ets` 的 `renderNode()` 加一个分发分支 + 对应 `@Builder`。**提示词会自动跟着变**（组件清单由这张表生成） |
| 调整语言语法 | `common/GuncatUiLang.ts`（`UiLexer` 词法 / `UiParser` 语法 / `GuncatUiMaterializer` 求值）+ `GuncatUiPrompt.SYNTAX`（给模型的语法说明），两者必须同步 |
| 调整界面文案 / 引导语 | `GuncatUiPrompt` 的 `SYNTAX` / `RICHNESS`（丰富度与组件选择优先级）/ `INTERACTION` / `STREAMING` / `EXAMPLES` / `ANTI_PATTERNS` / `INTERACTIVE_DUTY` |
| 新增图表 | `common/GuncatUiPaint.ts`（纯几何，可单测）+ `views/GuncatUiCharts.ets`（声明式 Shape/Path 或 Row/Column）→ 在 `GuncatUiLibrary` 登记并在 `GuncatUiView.buildChart()` 分发 |
| 新增控件 | `GuncatUiLibrary` 登记 + `views/GuncatUiView.ets` 的 `isControl()` / `buildControl()`；绑定参数用 `bind()` 登记（解析器会记录变量名，渲染器据此读写状态） |
| 新增图标 | `views/GuncatUiIcons.ets` 的 `glyph()` 映射表（**用 Unicode 字形而不是 SymbolGlyph**：SymbolGlyph 的名字在不同 ROM 上可用集合不一致，缺失时渲染成空白且静默失败）。唯一的例外是折叠箭头 `GuncatUiChevron`：`⌃`/`⌄` 这类字符在不同字体下大小与基线差异极大，真机上是"右下角一个小小的尖、又没对齐"，所以那里特意改用 `sys.symbol.chevron_up/down` |
| 交互模式专属文案 | `ChatViewModel` 的 `loopModeTitle` / `loopModeHint` / `loopInputPlaceholder` / `loopEmptyDescription` / `loopToolLabel` |
| 模式常量 | `Constants.INTERACTIVE_AGENT_ID` / `MODE_*` / `UI_BLOCK_LANG` / `UI_CONTINUE_MESSAGE` / `UI_CONTINUE_MAX_ROUNDS` |

> **回归护栏（三层，缺一不可）**
> 1. 纯逻辑单测：`cd test/guncat-harness && node setup.mjs && node test-core.mjs`（507 项，含 guncat-ui lang 的词法/语法/前向引用/流式补齐/绑定重算/`@Each`/内置函数/`Action`/片段切分/状态序列化/图表几何/组件库与提示词）。
> 2. 服务层类型检查：`node check-setup.mjs && npx tsc -p check/tsconfig.json`。
> 3. **真实 ArkTS 编译**：`powershell -ExecutionPolicy Bypass -File tools/build-check.ps1`（调用 DevEco 自带的 hvigor）。
> 第 3 层不能省：ArkUI 有一批**只有编译器才知道**的规则——`@Builder` 方法体内不允许声明局部变量、自定义组件属性名不能与内置属性同名（`size` / `scale`）、`@Prop` 的 null 需要显式联合类型。这些在 node 侧 harness 里全都测不出来（harness 只覆盖 `common/**` 与 `service/**` 的纯 TS，不解析 `.ets`）。
