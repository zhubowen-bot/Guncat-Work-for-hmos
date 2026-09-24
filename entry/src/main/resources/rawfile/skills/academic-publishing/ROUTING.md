# 【新增】academic-publishing 路由索引

> 本文是主 Skill `academic-publishing` 的详细路由索引，原始分支 Skill 正文均未改动；分支 Skill 已物理归入本主 Skill 子目录，`load_skill` 仍用原分支 id。

## 分支清单与触发词

### `paper` — 论文改写与学术化

- 触发：把综述/散文/笔记/报告/讲义/对话/博客等改写为学术论文；论文扩写/润色/重构。
- 加载：`load_skill("paper")`。
- 注意：纯语言润色可转 `humanizer`（content-writing）；需要文献补充时按正文调用 `research`。

### `paper-close-reading` — 论文精读

- 触发：论文精读、深度解读、分析方法与实验、判断论文价值或局限。
- 加载：`load_skill("paper-close-reading")`。
- 注意：引用核验转 `reference-audit`；正式审稿转 `paper-reviewer`。

### `paper-reviewer` — 学术论文审稿

- 触发：审论文、论文评审、写评审意见、peer review、rebuttal 前自查。
- 加载：`load_skill("paper-reviewer")`。
- 注意：以作者身份回复审稿意见转 `paper-rebuttal`。

### `paper-rebuttal` — 论文 Rebuttal 回复

- 触发：rebuttal、审稿意见回复、回复审稿人、response to reviewers、major/minor revision 回复。
- 加载：`load_skill("paper-rebuttal")`。
- 注意：先精读论文/意见可配合 `paper-close-reading` / `paper-reviewer`。

### `research-proposal` — 学术立项书/基金申请撰写

- 触发：基金申请、开题报告、研究计划书、立项书、任务书一致性、学术提案。
- 加载：`load_skill("research-proposal")`。
- 注意：需要完整领域调研时先 `research`；需要润色可配合 `humanizer` / `paper`。

### `reference-audit` — 参考文献审计

- 触发：论文审计、参考文献检查、引用核对、引用是否支持观点、检查错引/过度推断/二手转引。
- 加载：`load_skill("reference-audit")`。
- 注意：精读论文转 `paper-close-reading`；开放主题综述转 `research-intelligence`。

### `journal-format` — 学术论文 DOCX 格式排版与修复

- 触发：论文排版、期刊投稿格式、学位论文格式、会议论文模板、套用 Word 模板、格式修复。
- 加载：`load_skill("journal-format")`。
- 注意：执行层依赖 `docx`，但入口在本分支；与排版无关的写作/润色/补引用等任务不进入本分支。

## 交叉引用

| 相邻主 Skill | 何时转出 |
|---|---|
| `research-intelligence` | 开放主题深度调研/行业研究/舆情/模型评测/用户研究 |
| `docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data` | 明确文件格式时直接加载对应分支，不经过主 Skill |
| `content-writing` | 公众号/小红书/短视频/营销文案/去 AI 味 |
| `legal-ip` | 法律/专利分析 |
| `ai-tooling` | 提示词工程/代码评审 |
