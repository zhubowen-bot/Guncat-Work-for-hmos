# 【新增】ai-tooling 路由索引

> 本文是主 Skill `ai-tooling` 的详细路由索引，原始分支 Skill 正文均未改动；分支 Skill 已物理归入本主 Skill 子目录，`load_skill` 仍用原分支 id。

## 分支清单与触发词

### `prompt-engineering` — 提示词工程

- 触发：写提示词、优化提示词、prompt、系统提示词、自定义指令、让 AI 更听话、Agent 技能说明。
- 加载：`load_skill("prompt-engineering")`。
- 注意：大模型选型评测转 `research-intelligence` → `llm-eval`。

### `review-agent` — 代码评审

- 触发：代码评审、review code、review this change、code review、帮我审代码。
- 加载：`load_skill("review-agent")`。
- 注意：学术论文评审转 `academic-publishing` → `paper-reviewer`。

## 交叉引用

| 相邻主 Skill | 何时转出 |
|---|---|
| `research-intelligence` | 大模型评测/选型 |
| `academic-publishing` | 学术论文评审/rebuttal |
| `docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data` | 明确文件格式时直接加载对应分支，不经过主 Skill |
| `content-writing` | 内容创作/营销文案 |
| `legal-ip` | 法律/专利分析 |
