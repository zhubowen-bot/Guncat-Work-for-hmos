---
name: academic-publishing
description: 【新增】主 Skill（路由入口）。用户请求属于学术论文全生命周期——论文改写、精读、审稿、rebuttal、基金/立项书、参考文献审计、论文 DOCX 排版——时，先加载本技能做意图判别与分支分流，再 load_skill 对应分支 Skill（paper/paper-close-reading/paper-reviewer/paper-rebuttal/research-proposal/reference-audit/journal-format）。涉及开放主题深度调研的任务，先转 research-intelligence。
---

# 【新增】主 Skill：学术写作与论文全流程（academic-publishing）

> 本文件是新增的**主 Skill 路由入口**，用于降低 `paper` / `paper-close-reading` / `paper-reviewer` / `paper-rebuttal` / `research-proposal` / `reference-audit` / `journal-format` 之间的生态位重叠。
> 原始分支 Skill 的 `SKILL.md` 与 `reference/*` 全部保持原样，不在此重复、不删改。
> 详细路由见本目录 `ROUTING.md`（`load_skill("academic-publishing","ROUTING.md")`）。
> 分支 Skill 不直接出现在 `list_skills` 清单中，经本主 Skill 路由后按分支 id 加载。

## 何时进入本主 Skill

命中以下任一**首要意图**时进入，**必须先 `load_skill("academic-publishing")`，未加载前不得自行处理**（先判意图，再选分支）：

1. 把非论文文体改写为规范学术论文，或论文润色/扩写/重构 → 分支 `paper`
2. 对已有论文做**深度精读**、方法/证据拆解、可信边界判断 → 分支 `paper-close-reading`
3. 以审稿人标准对论文做**系统评审**、OpenReview 风格 review → 分支 `paper-reviewer`
4. 以作者身份处理审稿意见、写 **rebuttal / response letter** → 分支 `paper-rebuttal`
5. **基金申请 / 开题报告 / 研究计划书 / 立项书**撰写、审查和优化 → 分支 `research-proposal`
6. **参考文献真实性 / 题录准确性 / 文内—文后对应 / 主张支持度**审计 → 分支 `reference-audit`
7. 学术论文 **DOCX 格式排版 / 套模板 / 格式修复** → 分支 `journal-format`

## 路由速查表

| 用户意图 | 分支 Skill | 加载方式 |
|---|---|---|
| 论文改写/润色/重构 | `paper` | `load_skill("paper")` |
| 论文精读 | `paper-close-reading` | `load_skill("paper-close-reading")` |
| 论文审稿 | `paper-reviewer` | `load_skill("paper-reviewer")` |
| Rebuttal 回复 | `paper-rebuttal` | `load_skill("paper-rebuttal")` |
| 基金/立项书 | `research-proposal` | `load_skill("research-proposal")` |
| 参考文献审计 | `reference-audit` | `load_skill("reference-audit")` |
| 论文 DOCX 排版 | `journal-format` | `load_skill("journal-format")` |

## 边界：不进入本主 Skill

- 用户要做**开放主题深度调研/行业研究/舆情/模型评测** → 先进 `research-intelligence`。
- 用户只要**通用 Word/Excel/PPT/SVG/HTML/PDF/数据清洗产物**，不涉及学术方法论 → 直接加载对应格式分支（`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`），不经过主 Skill。
- 用户要**公众号/小红书/短视频/营销文案**等非学术内容创作 → 先进 `content-writing`。
- 用户要**法律/专利**分析 → 先进 `legal-ip`。

## 使用步骤

1. `load_skill("academic-publishing")` 读本入口。
2. 按上表判定唯一分支；如不确定，读 `ROUTING.md`。
3. `load_skill("<分支 Skill id>")` 进入分支正文执行。
4. 分支正文要求调用的 `research` / `docx` / `xlsx` 等工具链，按分支正文指示加载。
