---
name: ai-tooling
description: 【新增】主 Skill（路由入口）。用户请求属于 AI 工程辅助——写/优化/调试 AI 提示词、系统提示词、自定义指令、Agent 技能说明，或对代码变更做只读代码评审——时，先加载本技能做意图判别与分支分流，再 load_skill 对应分支 Skill（prompt-engineering/review-agent）。大模型评测选型转 research-intelligence。
---

# 【新增】主 Skill：AI 工程与提示词（ai-tooling）

> 本文件是新增的**主 Skill 路由入口**，用于降低 `prompt-engineering` / `review-agent` 与相邻评测/评审类技能之间的生态位重叠。
> 原始分支 Skill 的 `SKILL.md` 与 `reference/*` 全部保持原样，不在此重复、不删改。
> 详细路由见本目录 `ROUTING.md`（`load_skill("ai-tooling","ROUTING.md")`）。
> 分支 Skill 不直接出现在 `list_skills` 清单中，经本主 Skill 路由后按分支 id 加载。

## 何时进入本主 Skill

命中以下任一**首要意图**时进入，**必须先 `load_skill("ai-tooling")`，未加载前不得自行处理**（先判意图，再选分支）：

1. 写/优化/调试 **AI 提示词、系统提示词、自定义指令、Agent 技能说明** → 分支 `prompt-engineering`
2. 对**代码变更**做只读、缺陷优先的**代码评审** → 分支 `review-agent`

## 路由速查表

| 用户意图 | 分支 Skill | 加载方式 |
|---|---|---|
| 提示词工程 | `prompt-engineering` | `load_skill("prompt-engineering")` |
| 代码评审 | `review-agent` | `load_skill("review-agent")` |

## 边界：不进入本主 Skill

- 用户要**大模型对比/评测/选型** → 先进 `research-intelligence` → `llm-eval`。
- 用户要**学术论文评审** → 先进 `academic-publishing` → `paper-reviewer`。
- 用户要**通用 Word/Excel/PPT/SVG/HTML/PDF/数据清洗产物** → 直接加载对应格式分支（`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`），不经过主 Skill。
- 用户要**内容创作/营销文案** → 先进 `content-writing`。

## 使用步骤

1. `load_skill("ai-tooling")` 读本入口。
2. 按上表判定唯一分支；如不确定，读 `ROUTING.md`。
3. `load_skill("<分支 Skill id>")` 进入分支正文执行。
4. 分支正文要求调用的 `write_file` / `docx` / `xlsx` 等工具链，按分支正文指示加载。
