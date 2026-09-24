# 技能路由总索引（【新增】Skill Architecture Routing Index）

> 本文是新增的路由索引文件，不属于任何原始 Skill 的正文；原始 `SKILL.md` 与 `reference/*` 均保持原样、零删减。
> 作用：当任务命中多个相似技能时，先按本索引确定**唯一主 Skill**，再通过主 Skill 进入对应分支 Skill。

## 使用方式

1. 判断用户请求的**首要意图**，不是先挑工具，也不是先凭技能名猜。
2. 明确文件格式请求（Word/Excel/PPT/SVG/HTML/PDF 读取/数据清洗）**不需要主 Skill 路由**，直接加载对应格式分支：`docx` / `xlsx` / `ppt` / `svg` / `html` / `pdf` / `data`。
3. 其余内容/研究/学术/法律/AI 类请求按下表进入唯一主 Skill：`load_skill("<主 Skill id>")`。
4. 主 Skill 的 SKILL.md/ROUTING.md 会给出分支路由，再 `load_skill("<分支 Skill id>")`。
5. 分支 Skill 不直接出现在 `list_skills` 清单中，只通过主 Skill 路由发现并加载；直接 `load_skill` 分支 id 仍然可用。
6. 如果请求跨越两个主 Skill（例如“营销方案 + 广告合规审查”），先做主意图，再按交叉引用加载相邻主 Skill 的对应分支。

## 主 Skill 一览

| 主 Skill id | 主 Skill 名称 | 负责的意图域 | 主要分支数 |
|---|---|---|---|
| `research-intelligence` | 情报调研与分析 | 用户要深度研究、时效溯源、舆情、行业研究、模型评测、用户研究等**信息调研分析** | 7 |
| `academic-publishing` | 学术写作与论文全流程 | 用户要论文改写、精读、审稿、rebuttal、基金立项、引用审计、论文排版等**学术生命周期** | 7 |
| `content-writing` | 内容创作与营销文案 | 用户要公众号/小红书/短视频/多平台改写/去 AI 味/营销方案等**内容创作** | 5 |
| `legal-ip` | 法律/IP/合规 | 用户要法律分析、专利撰写、法律翻译、营销素材合规审核等**法律与知识产权** | 4 |
| `ai-tooling` | AI 工程与提示词 | 用户要写/优化提示词、代码评审等 **AI 工程辅助** | 2 |

## 分支 Skill 归属总表

> 7 个文件格式类 Skill 为**直接分支**（保留在 `skills/` 顶层，不设主 Skill）；其余每个原始 Skill 已**物理归入对应主 Skill 子目录**（如 `skills/research-intelligence/research/`），`load_skill` 仍使用原分支 id 加载，外部不感知嵌套路径。

### 直接格式分支（不设主 Skill）

> 这些格式彼此边界清晰，不设主 Skill 路由；用户要什么格式就直接加载对应分支。

| 分支 Skill id | 何时进入该分支 |
|---|---|
| `docx` | 要生成/编辑/重建 Word 文档 |
| `xlsx` | 要生成/编辑/分析 Excel 工作簿 |
| `ppt` | 要生成/编辑/美化 PowerPoint |
| `svg` | 要生成矢量图/图标/流程图/信息图/插画 |
| `html` | 要生成单页 HTML/落地页/数据看板/交互原型 |
| `pdf` | 要读取/搜索/扫描件阅读 PDF |
| `data` | 要清洗/转换/互转 CSV/JSON/XLSX 等数据文件 |

### research-intelligence（情报调研与分析）

| 分支 Skill id | 何时进入该分支 | 相邻主 Skill/说明 |
|---|---|---|
| `research` | 开放主题深度调研、多轮交叉验证、结构化研究报告 | 行业深度报告转 `industry-analysis`；论文文献类任务可转 `academic-publishing` |
| `sift` | 查“最新版本/最新状态/排名对比”，需过滤 AI 文、锚定官方一手来源 | 模型对比/选型转 `llm-eval` |
| `llm-eval` | 大模型对比、评测、选型、benchmark 解读 | 通用时效溯源转 `sift` |
| `sentiment-tracker` | 舆情监控、社媒反馈、品牌声量、用户评价溯源 | 用户研究问卷转 `questionnaire` |
| `industry-analysis` | 某一行业/赛道的中长期深度研究报告 | 公司/宏观/财报类问题不属于本分支 |
| `research-lineage-map` | 梳理研究/技术主题发展历史、谱系演进、Mermaid 图 | 需要深度调研时先 `research` 补材料 |
| `questionnaire` | 问卷设计、访谈提纲、开放题打标、定量问卷分析 | 舆情反馈转 `sentiment-tracker` |

### academic-publishing（学术写作与论文全流程）

| 分支 Skill id | 何时进入该分支 | 相邻主 Skill/说明 |
|---|---|---|
| `paper` | 非论文文体改写成学术论文，或论文润色/扩写/重构 | 纯语言润色可转 `humanizer`（content-writing） |
| `paper-close-reading` | 对已有论文做深度精读、方法/证据拆解、可信边界判断 | 文献引用核验转 `reference-audit` |
| `paper-reviewer` | 以审稿人视角对论文做系统评审、OpenReview 风格 review | 作者回复审稿意见转 `paper-rebuttal` |
| `paper-rebuttal` | 处理审稿意见、回复审稿人、修改论文并写 response letter | 先精读/审稿可配合 `paper-close-reading`/`paper-reviewer` |
| `research-proposal` | 基金申请、开题报告、研究计划书、立项书撰写/审查 | 需要补充领域调研时先 `research` |
| `reference-audit` | 参考文献真实性、题录准确性、文内—文后对应、主张支持度审计 | 论文精读转 `paper-close-reading` |
| `journal-format` | 学术论文 DOCX 格式排版/套模板/格式修复 | 排版执行依赖 `docx`，但入口在本主 Skill |

### content-writing（内容创作与营销文案）

| 分支 Skill id | 何时进入该分支 | 相邻主 Skill/说明 |
|---|---|---|
| `khazix-writer` | 以“数字生命卡兹克”风格写公众号长文/续写/扩写 | 通用公众号/小红书/短视频转 `newmedia-writing` |
| `newmedia-writing` | 小红书图文、公众号文章、短视频分镜脚本、复合创作 | 多平台已有母稿分发转 `content-rewrite` |
| `content-rewrite` | 基于已有母稿做多平台改写分发（≥2 平台或单平台有素材） | 从零创作转 `newmedia-writing`/`khazix-writer` |
| `humanizer` | 去 AI 味、拟人化、可读性改写 | 学术论文润色转 `paper`（academic-publishing） |
| `marketing-plan` | 营销策划全案、活动策划、产品上市方案等方案类 | 营销素材合规审核转 `legal-ip` → `marketing-material-review` |

### legal-ip（法律/IP/合规）

| 分支 Skill id | 何时进入该分支 | 相邻主 Skill/说明 |
|---|---|---|
| `law` | 企业法律案例/纠纷分析、国企国资监管、合同纠纷、合规与责任认定 | 法律翻译转 `translation` |
| `patent-drafting` | 基于技术交底书撰写/修改中国专利申请文件，或审查权利要求 | 专利检索/FTO/无效等相邻业务不在本分支主流程 |
| `translation` | 中文法律文书翻译为英文/中英双语，术语审校，双语 Word | 非法律翻译不使用本分支 |
| `marketing-material-review` | 广告宣传语/海报文案/社媒推广文案/直播话术的合规审查 | 营销方案创作转 `content-writing` → `marketing-plan` |

### ai-tooling（AI 工程与提示词）

| 分支 Skill id | 何时进入该分支 | 相邻主 Skill/说明 |
|---|---|---|
| `prompt-engineering` | 写/优化/调试 AI 提示词、系统提示词、自定义指令、Agent 技能说明 | 大模型选型评测转 `research-intelligence` → `llm-eval` |
| `review-agent` | 对代码变更做只读、缺陷优先的代码评审 | 论文评审转 `academic-publishing` → `paper-reviewer` |

## 边界与防误选规则

- **文件格式优先**：请求最终要 `.docx/.xlsx/.pptx/.svg/.html` 等文件且没有更强的内容方法论时，直接加载对应格式分支（`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`），不经过主 Skill。
- **内容方法论优先**：请求属于学术论文、公众号/小红书/短视频、营销方案、法律/专利等专业领域时，先进对应主 Skill，再由分支调用 `docx`/`xlsx`/`svg` 等作为工具。
- **信息调研优先**：请求需要联网检索、溯源、验证、分析并产出报告时，先进 `research-intelligence`，不要直接用文档工具硬做。
- **不确定时**：先 `load_skill` 主 Skill 的 ROUTING.md，按其中的意图判别表二次确认；不要同时加载多个相似分支 Skill。
