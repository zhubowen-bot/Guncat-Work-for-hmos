# 【新增】research-intelligence 路由索引

> 本文是主 Skill `research-intelligence` 的详细路由索引，原始分支 Skill 正文均未改动；分支 Skill 已物理归入本主 Skill 子目录，`load_skill` 仍用原分支 id。

## 分支清单与触发词

### `research` — 深度研究与多轮验证

- 触发：开放主题深度调研、事实核查、多源交叉验证、结构化研究报告。
- 加载：`load_skill("research")`。
- 注意：行业深度报告转 `industry-analysis`；论文文献类任务可转 `academic-publishing`。

### `sift` — 信息溯源与 AI 内容过滤

- 触发：查“最新版本/最新状态/排名对比”，需甄别 AI 生成内容、锚定官方一手来源。
- 加载：`load_skill("sift")`。
- 注意：模型对比/选型转 `llm-eval`。

### `llm-eval` — 大模型评测与选型分析

- 触发：对比/评估/选型大模型、benchmark 解读、模型推荐。
- 加载：`load_skill("llm-eval")`。
- 注意：通用时效溯源转 `sift`。

### `sentiment-tracker` — 舆情追踪与溯源

- 触发：舆情监控、调研、社媒反馈、用户评价、品牌声量、网上怎么看。
- 加载：`load_skill("sentiment-tracker")`。
- 注意：问卷/访谈类转 `questionnaire`。

### `industry-analysis` — 行业深度研究

- 触发：某一行业/赛道的中长期深度报告、产业链分析、竞争格局、趋势研判。
- 加载：`load_skill("industry-analysis")`。
- 注意：个股/宏观事件/财报类问题不属于本分支。

### `research-lineage-map` — 研究谱系演进图

- 触发：梳理发展历史、family tree、技术演进路线、X 如何一步步发展、X 解决了前人的什么问题。
- 加载：`load_skill("research-lineage-map")`。
- 注意：需要深度调研补充材料时先 `research`。

### `questionnaire` — 问卷与用户研究

- 触发：设计问卷、写问卷、满意度调研、NPS、访谈提纲、深访提纲、开放题打标、VOC 分析、问卷分析。
- 加载：`load_skill("questionnaire")`。
- 注意：舆情反馈转 `sentiment-tracker`。

## 交叉引用

| 相邻主 Skill | 何时转出 |
|---|---|
| `academic-publishing` | 论文写作/精读/审稿/rebuttal/引用审计/基金立项/论文排版 |
| `docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data` | 明确文件格式时直接加载对应分支，不经过主 Skill |
| `content-writing` | 公众号/小红书/短视频/营销文案创作 |
| `legal-ip` | 法律/专利分析 |
| `ai-tooling` | 提示词工程/代码评审 |
