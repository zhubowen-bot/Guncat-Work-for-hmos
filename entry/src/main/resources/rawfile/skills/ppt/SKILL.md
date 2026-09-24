---
name: ppt
description: 用 Deck JSON 制作与编辑 PPT（write_pptx / read_ppt / edit_ppt）。V3：全量加载所有 reference、新建前 ask_user_question 前置提问、默认 20+ 页、每页 SVG 装饰、强制自检报告。
---

# PPT 制作与编辑（V3）

本文是 PPT 技能的总入口与流程主线。**V3 把“文档”改成“门”**：全量加载、前置提问、篇幅下限、每页装饰、自检报告都是不可跳过的硬门，均有可核对产出物。**对外契约不变**：仍只通过 `write_pptx(path, deck | deck_file | outline, theme?, title?)`、`read_ppt(path)`、`edit_ppt(path, ops)` 完成制作、读取与编辑。

## 0. TL;DR 铁律（优先级最高，冲突时以本节为准）

1. **[铁律] 每次接到新 PPT 指令或新附件后，第一个工具调用必须是 `load_skill("ppt")` 全量加载**。`load_skill("ppt")` 会一次返回 SKILL.md + 全部 reference（deck-dsl / design-guide / themes / visual-styles / deck-blueprints / visual-components / style-guidelines / troubleshooting）。禁止只读 SKILL.md 后挑读 reference，禁止跳过、中途截断或凭记忆继续。
2. **[铁律] 新建演示文稿（工作流 A）在动手生成前，必须先调用 `ask_user_question` 做一次前置提问**：目的/受众、篇幅、风格、素材、硬约束一次问全。用户已提供全部关键信息或明确说“不用问/直接做”时才能跳过，且必须在最终总结记录假设。
3. **[铁律] 用户未提供篇幅时，默认 24~30 页，任何情况下不得少于 20 页**（除非用户明确指定更少）。用户给了逐页大纲则对齐其页数；给了文档/主题则按内容量扩到 20 页以上。
4. **[铁律] 每一页必须有视觉装饰 + 内容配图，禁止纯色背景+纯文字**。**装饰**：每页有装饰性 SVG 或纹理背景（`background.image` / custom 元素），封面/分节/结尾页也有设计母题。**配图**：每页必须有至少一个“内容性视觉”——流程图、时间轴、架构图、对比图、简单插画、信息图、数据可视化等，不能只有小图标或角标。纯要点页必须把一部分要点转成流程图、时间线或示意图。全册统一风格，双色以上混搭，禁止裸用 8 套纯色预设。
5. **[铁律] 交付前必须产出可核对的自检报告**：用 `read_ppt` 逐页回读核对，写入 `ppt_qa_report.md`，并在最终总结附 `## PPT 交付自检报告` 摘要。没有报告不视为完成。

## 1. 规则分级与冲突裁决

| 级别 | 含义 | 违反后果 |
|---|---|---|
| **铁律** | 任何情况下不可跳过，除非用户显式覆盖 | 任务未完成，必须回到对应步骤补齐 |
| **强规则** | 必须遵守；与用户明确要求冲突时以用户为准 | 视为质量问题，需在自检中列出并修复 |
| **建议** | 默认应遵守；有充分理由时可有意偏离 | 偏离时在自检报告说明理由 |
| **软参考** | 帮助判断，不强制 | — |

**冲突裁决程序（出现规则打架时按此顺序，不自行选阻力最小路径）**：

1. 用户当前明确指令 > 用户历史明确指令 > 模板/品牌规范 > 本技能铁律 > 强规则 > 建议 > 软参考。
2. “默认不打断”与“不确定项一次问清”冲突时：**新建 PPT 走“前置提问门”（铁律），编辑/读取走“不打断”**；两者按场景路由分流，不并存。
3. “每页都有装饰”与“装饰不凑数/不加无关配图”冲突时：装饰必须是**与选定视觉风格一致、有语义或纯装饰但克制的 SVG 母题**；不能为了凑装饰放无关照片或乱加元素。
4. “内容要丰富 20+ 页”与“信息密度/不注水”冲突时：用拆页、每节多页、案例/数据/图表/对比/问答/行动页来撑内容，禁止复制粘贴相同要点或空话扩页。

## 2. 全量加载门（硬门，不可跳过）

- **每次新指令/新附件后的第一个工具调用**：`load_skill("ppt")`。若之前已加载但中间发生了上下文压缩/新用户消息，也重新 `load_skill("ppt")` 一次。
- `load_skill("ppt")` 返回内容应包含下列文件清单；如果返回中没有 `reference/visual-styles.md` 或明显被截断，视为加载失败，需重试：
  - `SKILL.md`（本文）
  - `reference/deck-dsl.md`
  - `reference/design-guide.md`
  - `reference/themes.md`
  - `reference/visual-styles.md`
  - `reference/deck-blueprints.md`
  - `reference/visual-components.md`
  - `reference/style-guidelines.md`
  - `reference/troubleshooting.md`
- **禁止**：只读 SKILL.md 后说“参考文件按需读”；禁止用 `load_skill("ppt","reference/xxx.md")` 替代全量加载（个别文件可在全量之后用于精读，但不能代替）。
- 生成 SVG 装饰时还需 `load_skill("svg")`，按 svg 技能规范写 SVG 并 `view_image` 预览。

## 3. 前置提问门（新建演示文稿，硬门）

**新建 PPT 前必须调用一次 `ask_user_question`**，把下列问题合并为一次提问（不要挤牙膏）。由于 `ask_user_question` 是单问题工具，请把 5 项合并为一段 question 文本；`options` 可提供风格/篇幅候选，但不要拆成多次提问。

| # | 问题 | 选项/示例 | 默认假设（用户取消回答时用） |
|---|---|---|---|
| 1 | 这份 PPT 的**目的与受众/场景**是什么？ | 经营汇报 / 融资路演 / 技术分享 / 培训 / 产品发布 / 品牌故事 / 学术答辩 / 其他 | 按主题合理推断，总结中说明 |
| 2 | **篇幅**大约多少页？ | 20 页左右（推荐）/ 25~30 页 / 30~40 页 / 用户自定义 | **24~30 页，且不少于 20 页** |
| 3 | 想要哪种**视觉风格**？ | 科技 / 古风 / 简约 / 杂志 / 商务 / 学术 / 路演 / 自定义 | 根据主题选最匹配风格，见 `reference/visual-styles.md` |
| 4 | 有没有**素材/文档/数据/模板/图片**需要我使用？ | 有（列出路径）/ 没有 | 用工作区已有资料 + 合理推断，禁止编造数据 |
| 5 | 有没有**硬约束**（必须包含/不能出现/品牌色/模板）？ | 自由填写 | 无 |

- 用户已经提供了以上全部信息，或明确说“不要问，直接做”，可跳过提问，但必须在最终总结写“采用假设：目的/受众/篇幅/风格”。
- **编辑已有 PPT、读取分析、模板保真场景不触发前置提问**；只有真正影响方向的硬阻塞（附件打不开、意图矛盾）才问。

## 4. 场景路由

| 用户任务 | 走哪条流程 |
|---|---|
| 新建演示文稿（从零、根据文档/大纲、把图片/PDF 复刻成 PPT） | 工作流 A |
| 编辑已有 PPT（含多轮对话中修改前轮产物） | 工作流 B |
| 用户提供了模板（PPTX，说“照这个风格做”） | 工作流 B · 模板保真 |
| 读取/分析已有幻灯片 | `read_ppt(path)` 读回 Deck JSON；外来文件按提示中的近似导入说明理解 |

无论改动大小，先判断场景再动手。**编辑已有 PPT 时先 `read_ppt(path)` 读回现状，不要凭上一轮记忆直接改**；用户给了模板时，以模板为最高视觉约束，不走“默认新建”的设计流程。

## 5. 工具链

| 工具 | 用途 |
|---|---|
| `write_pptx(path, deck | deck_file | outline, theme?, title?)` | 生成/重建 .pptx（16:9） |
| `read_ppt(path)` | 读回 Deck JSON 源（自家文件无损；外来文件近似导入） |
| `edit_ppt(path, ops)` | 结构化编辑已有 .pptx（增删页/改内容/换主题/全文替换） |
| `write_svg(path, svg, width?)` | 生成装饰 SVG/图标/示意图；`write_pptx` 可直接引用 `.svg` |
| `ask_user_question` | 新建 PPT 前置提问（见 §3） |

图片来源只能是：工作区已有文件（用户上传、`pdf_to_images` 的 `pdf_images/` 产物）、data URL 或 http(s) 链接。`.svg` 文件可直接引用（导出时自动栅格化）；需要照片级素材用 `download_file` 下载到工作区；需要图标/示意图用 `write_svg` 生成（见 svg 技能）。**禁止编造不存在的图片路径**——先用 list_files 确认。

## 6. 沟通任务与叙事弧

- 先定义**沟通任务**：`By the end, [audience] should [outcome] because [central takeaway].` 不确定受众时不要默认“受众就是用户本人”。
- 选择适合的**叙事弧**：Context → stakes → evidence → implications → action；Question → analysis → answer；Problem → causes/options → recommendation；Current state → change → future state；或 chronology / process / learning progression / claim → evidence → consequence。
- **议程不是叙事**。页面顺序要累积推进：每节为下一节制造需求，不要只把话题平铺成目录。
- 每页只承担一个叙事任务、一个主结论；标题用 takeaway 风格（“营收 +18%”而非“营收情况”）。
- **开场与收尾都要刻意设计**：开场给出背景/目的/问题/张力，收尾解决开场提出的问题——给结论、建议、行动、综合或后续问题；不要在一堆细节后突兀停在泛泛的“谢谢”页。`end` 版式应放在结论/行动页之后收束全篇。
- 证据要“转成意义”：不要只陈列数字/图表；说明它对本受众意味着什么、如何改变结论或下一步。

## 7. 工作流 A：新建演示文稿

**核心顺序：全量加载 → 前置提问 → 理解需求 → 选定设计系统 → 收集素材 → 规划页面/篇幅 → 制作装饰 SVG → 写 Deck JSON → 生成 → 回读 → 写自检报告 → 交付。**

1. **全量加载**：`load_skill("ppt")`（§2）。如要生成装饰 SVG，同时 `load_skill("svg")`。
2. **前置提问**：`ask_user_question`（§3）。收到回答后确定目的、受众、页数、风格、素材、硬约束。
3. **理解需求**：确定目的、受众、页数、风格倾向、输入类型（仅主题 / 完整文档 / 逐页大纲讲稿）。用户给了逐页大纲则对齐其页数；只给主题或长文档时按内容量推测合理页数并说明理由。**默认页数：24~30 页，下限 20 页**。
4. **选定设计系统**：全量加载已包含设计文档。先看 `reference/visual-styles.md` 选**视觉风格**（科技/古风/简约/杂志/商务/学术/路演等），再看 `reference/themes.md` 选主题并叠加 `themeOverride` 双色以上混搭；按 `reference/design-guide.md` 定版式纪律。**选定后，配色、纹理、装饰、字体、留白、版式、图片密度等所有视觉决策全程遵守这套系统，不中途混入冲突风格**。用户已给品牌/配色/字体/参考风格时，以用户为准。
5. **收集素材**：完整阅读用户上传/提供的附件，图片、表格、公式里的信息不能只靠纯文本抽取；关键数字、图表、截图要保留原始信息，可缩放适配排版，但**不做裁剪**。需要真实图片时用工作区文件/下载/SVG；**禁止编造数据与图片路径**，所有外部来源记下出处。
6. **规划页面节奏与篇幅**：把叙事弧落成页面蓝图。**默认 20 页以上**，结构建议：
   ```
   cover → toc → 开场/背景 → section → 内容页×3~5 → section → 内容页×3~5 →
   section → 数据/证据页×2~4 → section → 方案/结论页×2~4 → 行动/下一步 → end
   ```
   每节 2~5 页内容，不要一节一页；先套 `reference/deck-blueprints.md` 再按实际内容增删页。
7. **制作装饰 SVG 与内容配图 SVG**：为全册做一套装饰资产（建议放在 `assets/ppt-decor/`），再按每页内容做内容配图（建议放在 `assets/ppt-diagrams/`），均按 `reference/visual-styles.md` 的风格配方生成：
   - 装饰资产：背景纹理/图案（如科技网格、古风山水线、简约几何、杂志纸纹）、每页可复用的边角/勾边/花色母题；
   - 内容配图：把要点/流程/架构/时间线/对比/机制转成流程图、时间轴、架构图、对比图、简单插画或信息图；
   - 生成后用 `view_image` 预览，确认透明、可读、不抢内容、与主题色一致。
8. **写 Deck JSON**：每页都落实装饰与内容配图——
   - 用 `background.image` 放全页纹理/图案（`fit:"cover"`，`overlay` 按文字可读性调 0~0.6）；
   - 或对 `custom` 页用 `elements` 里的 image/shape 放装饰元素；
   - 用 `themeOverride` 把主题扩展为至少两色以上混搭，避免纯色默认模板；
   - 数据页用 chart/table；**每页至少一个内容配图**（流程图/时间轴/架构图/对比图/插画/信息图），用 `image-text` 或 `custom` 放 SVG 配图；
   - 纯要点页不能只有要点：把至少一部分内容转成 SVG 流程图/示意图/时间线。
   速查最小例：
   ```json
   {"title":"Q3 经营复盘","theme":"brand-blue",
    "themeOverride":{"primary":"0A3D62","accent":"E8590C","bg":"F7F3EC","surface":"EFE6DA"},
    "slides":[
     {"layout":"cover","title":"Q3 经营复盘","subtitle":"2026-08 · 经营分析组",
      "background":{"image":"assets/ppt-decor/tech-cover.svg","fit":"cover","overlay":0.35}},
     {"layout":"toc","bullets":["业绩概览","问题分析","下季度计划"],
      "background":{"image":"assets/ppt-decor/tech-texture.svg","fit":"cover","overlay":0}},
     {"layout":"content","title":"核心指标全面达标","bullets":[
       "营收 1.2 亿，同比 +18%","新增客户 3,240 家",{"text":"华东区贡献 42%","level":2}],
      "background":{"image":"assets/ppt-decor/tech-corner.svg","fit":"cover","overlay":0}},
     {"layout":"chart","title":"月度营收趋势","chart":{"type":"bar",
       "categories":["4月","5月","6月"],"series":[{"name":"营收(百万)","values":[36,39,45]}]},
      "background":{"image":"assets/ppt-decor/tech-grid.svg","fit":"cover","overlay":0}},
     {"layout":"end","title":"谢谢","subtitle":"欢迎讨论",
      "background":{"image":"assets/ppt-decor/tech-end.svg","fit":"cover","overlay":0.2}}]}
   ```
   > 更多风格配方和 SVG 骨架见 `reference/visual-styles.md`；字段语法见 `reference/deck-dsl.md`。
9. **生成**：≤10 页直接 `write_pptx` 传 `deck`；更长先 `write_file("deck.json", …)` 分块写好（后续 `append_file` 续写），再 `write_pptx` 传 `deck_file:"deck.json"`。**必须拿到成功返回才算生成完成**：返回失败/异常按提示修复后重新导出，不把未成功导出当完成。
10. **回读校验**：长 deck 不要只看生成成功——用 `read_ppt` 按页序逐页回读（页序/标题/要点/图片/装饰/notes），有问题用 `edit_ppt` 修正或改 deck 后重新导出。
11. **写自检报告并交付**：按 §10 模板写 `ppt_qa_report.md`；最终总结必须附 `## PPT 交付自检报告` 摘要。

## 8. 工作流 B：编辑已有 PPT

1. `load_skill("ppt")` 全量加载（每次新指令后必做）。
2. `read_ppt(path)` 读回源（外来文件注意提示中的近似导入说明）。
3. 小改：`edit_ppt` 用 `replace_text`（全文改词）/`update_slide`（改单页）/`add_slide`/`delete_slide`/`move_slide`。
4. 换风格：`edit_ppt` 传 `{"op":"set_theme","theme":"midnight"}`；需要多色混搭/纹理时用 `themeOverride` 或给受影响页加 `background.image`（用 `update_slide`）。
5. **仿制模板**（用户给了一份 pptx 说“照这个风格做”）——走**模板保真**：
   - **模板是最高视觉约束**：不要混入另一套设计系统或默认主题；用户模板优先于本技能的通用风格默认值。
   - **先 QA 模板**：`read_ppt` 读回后判断模板是“可用”还是“弱”。可用就直接尊重其设计复用；弱则在模板自己的色板和字体体系内，用现有版式/视觉组件升级坏页，不要另起炉灶。
   - **模板容量判定**：模板内容版式数量撑不起计划页数时，不要为“严格沿用模板”把所有内容硬塞进重复版式——品牌身份（配色/字体/logo/页脚/页码）保留，内容页在模板自己的视觉体系里重建。
   - **分别提取结构与风格**：结构=页面节奏/每页内容组织；风格=配色（主题色）、文字层级、图表密度。外来文件近似导入时图片与图表数据不保留，只保留文本与版面；重建时保持模板的版式契约。
   - 重建优先用工作流 A 的 Deck JSON 方式：重建版式更精致、可再编辑，但必须沿用模板的配色/字体/层级/密度，而不是套用默认主题。
6. 外来文件改前会自动备份 `*_原版备份.pptx`，不要删它。
7. 编辑完成后同样执行回读 + 写 `ppt_qa_report.md`（若只是极小文字替换，报告可精简，但最终总结仍需附自检摘要）。

## 9. 能力边界（重要：不要承诺做不到的功能）

**支持**：13 种版式、8 套主题 + `themeOverride` 自定义色板、图表（bar/line/area/pie/doughnut，数据内嵌）、表格、图片（工作区/data URL/http/svg 自动栅格化）、演讲备注、深色主题自动反白、全页背景图/纹理。

**不支持**（用户要求时**明确说明做不到**，并给替代方案）：
- 动画、页面切换（transition）效果
- 音视频嵌入、超链接跳转
- 图表在 PPT 里二次编辑（数据是内嵌只读的；要改数据就改 Deck 的 chart 重新导出）
- 母版/版式定制、自定义字体嵌入、宏/插件
- 多比例画布（固定 16:9）

遇到这些需求：说明“当前版本不支持 X”；图表改数用 `edit_ppt` 的 `update_slide` 或改 deck 重导。

## 10. 交付前自检（强制产出物）

**没有产出物的检查 = 不存在的检查。** 以下步骤完成后，必须 `write_file("ppt_qa_report.md", …)`，把逐项 PASS/FAIL 写成报告；报告必须能独立复核。

```markdown
# PPT 交付自检报告
生成文件：<路径>
页数：<N>
视觉风格：<科技/古风/…>
主题/themeOverride：<theme + 关键色>
## 逐页回读核对（read_ppt 按页序）
| 页 | 标题 | 版式 | 装饰SVG/背景 | 数据/来源 | notes | 结果 |
|---|---|---|---|---|---|---|
| 1 | … | cover | ✓ assets/…svg | — | 3~5句 | PASS |
| 2 | … | content | ✓ … | — | … | PASS |
| … | … | … | … | … | … | PASS |
## 硬门核对
- [ ] load_skill("ppt") 已全量加载（SKILL.md + 8 个 reference）？
- [ ] 新建前 ask_user_question 已调用，或已记录用户已提供全部信息？
- [ ] 页数 ≥ 20（或用户明确指定更少）？
- [ ] 每页都有装饰性 SVG/纹理，无纯色背景+文字？
- [ ] 每页都有内容配图（流程图/时间轴/架构图/对比图/插画/信息图），非纯文字页？
- [ ] 全册视觉风格统一，配色 ≥ 2 色混搭？
- [ ] 无占位残留（xxxx/lorem/占位/TODO/TBD）？
- [ ] 无重叠/溢出/裁切/意外换行（尤其标题/横幅单行）？
- [ ] chart/table 数字与工作区资料一致？来源标注？
- [ ] 引用的图片路径真实存在？同一张图未重复滥用（统一装饰除外）？
- [ ] write_pptx 成功返回且 read_ppt 能读回最终文件？
- [ ] 每页 notes 有 3~5 句可直接照读讲稿，或至少写清口径/来源？
## 发现与修复记录
- 问题1：… → 修复动作：… → 复验：PASS
- 问题2：…
## 结论
- [ ] 所有铁律通过；可以交付。
```

最终总结必须包含 `## PPT 交付自检报告` 摘要（页数、风格、关键 PASS/FAIL、修复记录），不能只说“已自检”。

## 11. 版式速选

| 版式 | 何时用 |
|---|---|
| cover / end | 首页 / 收尾（end 自动品牌色整版） |
| toc | ≥6 页时给目录 |
| section | 章节隔页（大字 + 编号，自动编） |
| content | 默认内容页（要点列表，需配装饰） |
| two-col | 对比/双栏要点 |
| table | 结构化数据（≤20 行） |
| chart | 数据趋势(bar/line/area)与占比(pie/doughnut) |
| image-text | 图文并排 |
| image / image-full | 单图展示 / 全幅大图 |
| quote | 引用金句 |
| custom | 自由版面（绝对定位元素，坐标 0~1，可放装饰元素） |

字段级语法（必填项、chart/table/image 全字段、custom 元素、背景、备注）：`reference/deck-dsl.md`（已随全量加载包含）。

## 12. 主题、视觉风格与内容纪律

- 8 套预设只是**色板基座**：brand-blue / midnight / forest / sunset / violet / graphite / ivory / crimson。**禁止裸用纯色默认模板**；必须用 `themeOverride` 扩展为至少两色以上混搭，并叠加 `background.image` 纹理/图案/勾边。
- **每页配图**：除装饰外，每页要有内容性 SVG 配图——流程、时间轴、架构、对比、插画、信息图。参考 `reference/visual-styles.md` 的“每页配图”与 `reference/visual-components.md` 的组件选型。
- 风格目录（科技/古风/简约/杂志/商务/学术/路演等）、色板配方、纹理/勾边/图案/花色 SVG 骨架：`reference/visual-styles.md`。
- 页面设计、图表/表格/图片/字号、模板跟随、视觉方向：`reference/design-guide.md`。
- 内容纪律（面向观众、来源可追溯、信息密度、每页 notes）：与 V2 一致，继续遵守；页面可见文本避免 emoji。

## 13. 变更来源（Source Map）

| 变更点 | 来源文件（参考平台相对路径） | 移植内容/出处要点 |
|---|---|---|
| V3：规则分级（铁律/强规则/建议/软参考）与冲突裁决程序 | `qwenwork/skills/pptx/SKILL.md` + 用户反馈的结构性问题 | 把 100+ 条规则分级，明确 TL;DR 铁律；冲突不再交给 agent 自行选择 |
| V3：全量加载门（load_skill("ppt") 一次加载全部 reference） | `doubao/skills/ppt/SKILL.md` 权威经验 #3 | “技能中的所有文档都必须完整读完，尾部有重要信息，不要中途截断”移植为强制门 |
| V3：新建前 ask_user_question 前置提问 | `workbuddy/experts/humanize-ppt-team/skills/guizang-ppt-skill/SKILL.md` Step 1 | 需求澄清“动手前必做”，6 问清单适配为 5 问（目的/篇幅/风格/素材/硬约束） |
| V3：默认 20 页以上篇幅 | `workbuddy/experts/humanize-ppt-team/skills/guizang-ppt-skill/SKILL.md` Step 1 + 用户反馈 | 15 分钟≈10 页/30 分钟≈20 页/45 分钟≈25-30 页；本环境默认 24~30 页、下限 20 页 |
| V3：每页 SVG 装饰、禁止纯色默认模板、视觉风格目录 | `workbuddy/official_experts/plugins/pptx/SKILL.md` Design Ideas + `workbuddy/experts/humanize-ppt-team/skills/guizang-ppt-skill/SKILL.md` | “Every slide needs a visual element / Don't create boring slides / Pick a bold palette / Commit to a visual motif”适配到 Deck JSON 的 background.image 与 custom |
| V3.1：每页内容配图（流程图/时间轴/架构图/对比图/插画/信息图） | `workbuddy/experts/humanize-ppt-team/skills/guizang-ppt-skill/SKILL.md` + `qwenwork/skills/pptx/visual-directions.md` + 用户反馈 | 纯文字页必须把一部分内容转成图；配图与装饰分离，`image-text`/`custom` 放内容配图，`background.image` 放纹理/母题 |
| V3：自检报告作为强制产出物 | `workbuddy/official_experts/plugins/pptx/SKILL.md` QA + `qwenwork/skills/pptx/SKILL.md` QA | “Assume there are problems / find them / verification loop”从内部愿望改为 write_file 报告 + 最终总结摘要 |
| 兼容性说明 | — | **无破坏性变更**：`write_pptx` / `read_ppt` / `edit_ppt` 签名、已有 edit_ppt 操作、已有 load_skill 引用路径均保持不变，不新增/删除工具或参数；仅 load_skill("ppt") 的返回内容扩展为全量 bundle |
