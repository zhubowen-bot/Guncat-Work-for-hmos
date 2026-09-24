---
name: research-intelligence
description: 【新增】主 Skill（路由入口）。用户请求需要联网检索、溯源、验证、调研、舆情、行业研究、模型评测或用户研究并产出分析/报告时，先加载本技能做意图判别与分支分流，再 load_skill 对应分支 Skill（research/sift/llm-eval/sentiment-tracker/industry-analysis/research-lineage-map/questionnaire）。涉及论文/学术写作与引用审计的任务，先转 academic-publishing。
---

# 【新增】主 Skill：情报调研与分析（research-intelligence）

> 本文件是新增的**主 Skill 路由入口**，用于降低 `research` / `sift` / `llm-eval` / `sentiment-tracker` / `industry-analysis` / `research-lineage-map` / `questionnaire` 之间的生态位重叠。
> 原始分支 Skill 的 `SKILL.md` 与 `reference/*` 全部保持原样，不在此重复、不删改。
> 详细路由见本目录 `ROUTING.md`（`load_skill("research-intelligence","ROUTING.md")`）。
> 分支 Skill 不直接出现在 `list_skills` 清单中，经本主 Skill 路由后按分支 id 加载。

## 何时进入本主 Skill

命中以下任一**首要意图**时进入，**必须先 `load_skill("research-intelligence")`，未加载前不得自行处理**（先判意图，再选分支）：

1. 开放主题**深度调研 / 事实核查 / 多源交叉验证 / 结构化研究报告** → 分支 `research`
2. 查“最新版本 / 最新状态 / 排名对比”等**时效敏感信息**，需过滤 AI 文、锚定官方一手来源 → 分支 `sift`
3. **大模型对比 / 评测 / 选型 / benchmark 解读** → 分支 `llm-eval`
4. **舆情监控 / 社媒反馈 / 品牌声量 / 用户评价溯源** → 分支 `sentiment-tracker`
5. 某一**行业/赛道的中长期深度研究报告** → 分支 `industry-analysis`
6. 梳理研究/技术主题的**谱系脉络 / 历史演进 / Mermaid 演进图** → 分支 `research-lineage-map`
7. **问卷设计 / 访谈提纲 / 开放题打标 / 定量问卷分析** → 分支 `questionnaire`

## 路由速查表

| 用户意图 | 分支 Skill | 加载方式 |
|---|---|---|
| 深度调研/研究报告 | `research` | `load_skill("research")` |
| 时效溯源/过滤 AI 文 | `sift` | `load_skill("sift")` |
| 大模型评测/选型 | `llm-eval` | `load_skill("llm-eval")` |
| 舆情追踪与溯源 | `sentiment-tracker` | `load_skill("sentiment-tracker")` |
| 行业深度研究 | `industry-analysis` | `load_skill("industry-analysis")` |
| 研究谱系演进图 | `research-lineage-map` | `load_skill("research-lineage-map")` |
| 问卷与用户研究 | `questionnaire` | `load_skill("questionnaire")` |

## 边界：不进入本主 Skill

- 用户要的是**论文全流程**（改写/精读/审稿/rebuttal/引用审计/基金立项/论文排版）→ 先进 `academic-publishing`。
- 用户要的是**明确格式的文件产物**（Word/Excel/PPT/SVG/HTML/PDF 读取/数据清洗）→ 直接加载对应格式分支（`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`），不经过主 Skill。
- 用户要的是**内容创作**（公众号/小红书/短视频/营销文案）→ 先进 `content-writing`。
- 用户要的是**法律/专利**分析 → 先进 `legal-ip`。

## 使用步骤

1. `load_skill("research-intelligence")` 读本入口。
2. 按上表判定唯一分支；如不确定，读 `ROUTING.md`。
3. `load_skill("<分支 Skill id>")` 进入分支正文执行。
4. 分支正文要求的检索/溯源/验证纪律必须完整执行，不得跳过。
