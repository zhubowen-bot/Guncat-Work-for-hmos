# Skill 架构重组说明（【新增】Routing Reorganization Report）

> 本文件是本次重组的新增说明，不属于任何原始 Skill 正文。
> 目标：在不改动任何现有 Skill 正文内容的前提下，降低生态位重叠，建立“主 Skill — 分支 Skill”的路由结构。

## 原则落实情况

- **原文零删减**：未修改、删除、替换、摘要、压缩、翻译或重写任何原始 `SKILL.md`、`reference/*`、`assets/*`、`sub-skills/*`。
- **只增不改**：仅新增路由层文件、主 Skill 目录和注册表新增条目；原有 Skill 正文未改动。
- **物理归组**：25 个非格式类分支 Skill 已整体移入对应主 Skill 子目录；`load_skill` 仍用原分支 id，外部不暴露嵌套路径。
- **内容体量只增不减**：原始 181 个文件、28,469 行保持不变；新增 11 个技能路由文件、548 行，另有 1 份根级说明文件。

## 新增结构

- `entry/src/main/resources/rawfile/skills/ROUTE_INDEX.md` — 全局路由总索引。
- 5 个主 Skill 目录，每个目录含：
  - `SKILL.md` — 主 Skill 路由入口（意图判别、边界说明、路由速查表）
  - `ROUTING.md` — 分支路由索引（分支触发词、加载方式、交叉引用）
  - 分支子目录：例如 `research-intelligence/research/`、`academic-publishing/paper/`
  - 目录：
    - `research-intelligence/` — 情报调研与分析
    - `academic-publishing/` — 学术写作与论文全流程
    - `content-writing/` — 内容创作与营销文案
    - `legal-ip/` — 法律/IP/合规
    - `ai-tooling/` — AI 工程与提示词
- `entry/src/main/ets/service/WorkSkillService.ts` — 在注册表末尾**新增** 5 个主 Skill 条目，并新增 `skillPath()` 路径映射，使原分支 id 仍可加载嵌套目录中的 Skill 文件（仅新增，未改任何原有条目）。

## 主 Skill 与分支归属

| 主 Skill | 分支 Skill |
|---|---|
| `research-intelligence` | `research` `sift` `llm-eval` `sentiment-tracker` `industry-analysis` `research-lineage-map` `questionnaire` |
| `academic-publishing` | `paper` `paper-close-reading` `paper-reviewer` `paper-rebuttal` `research-proposal` `reference-audit` `journal-format` |
| `content-writing` | `khazix-writer` `newmedia-writing` `content-rewrite` `humanizer` `marketing-plan` |
| `legal-ip` | `law` `patent-drafting` `translation` `marketing-material-review` |
| `ai-tooling` | `prompt-engineering` `review-agent` |

## 使用方式

1. 明确文件格式请求（Word/Excel/PPT/SVG/HTML/PDF 读取/数据清洗）直接加载对应分支：`docx` / `xlsx` / `ppt` / `svg` / `html` / `pdf` / `data`，不设主 Skill 路由。
2. 其余内容/研究/学术/法律/AI 类请求，先按首要意图进入唯一主 Skill：`load_skill("<主 Skill id>")`。
3. 主 Skill 的 `SKILL.md` 提供路由速查；不确定时读 `load_skill("<主 Skill id>","ROUTING.md")`。
4. 再 `load_skill("<分支 Skill id>")` 进入原始分支正文执行；分支文件虽在子目录中，但加载方式不变。
5. 分支正文要求全量加载的（`ppt` / `docx` / `xlsx`）仍按原契约全量加载。

## 技能优先级增强

为降低“模型觉得自己会而不加载技能”的概率，在提示词与工具描述层做了以下强化：

- `SkillDirectoryFormatter.skillPriorityRules()` 新增“技能使用铁律”：命中即加载、不确定先查、主 Skill 优先、技能正文优先、未加载视为违规。
- `full_index` / `trigger_only` / `list_skills` 输出均注入该铁律。
- `PromptBuilder.toolsDirectory()` 中 `list_skills` / `load_skill` 描述改为“第一步必须加载”。
- `PromptBuilder.methodology()` 增加“技能优先”步骤与“技能是第一动作”调度原则；`workflow()` 执行步骤同步强调“命中技能先 load_skill”。
- `WorkFileService` 实际工具 schema 中的 `list_skills` / `load_skill` 描述同步强化。
- 5 个主 Skill 的注册描述统一加上“命中必加载，不得自行处理”，并补充高频触发词以提升命中识别。

## 验证

- 原始 32 个 Skill 的文件数与行数均未变化（移动后逐目录校验通过）。
- 7 个文件格式类 Skill（`docx` / `xlsx` / `ppt` / `svg` / `html` / `pdf` / `data`）保留在 `skills/` 顶层，独立直连，不设冗余主 Skill。
- 其余 25 个原始 Skill 已物理归入 5 个主 Skill 子目录；`load_skill` 仍使用原分支 id，通过 `skillPath()` 映射读取。
- 运行时技能清单只暴露 5 个主 Skill + 7 个格式分支 = 12 个可见技能；25 个分支 Skill 不直接出现在 `list_skills` 中，由主 Skill 路由后加载。
- 新增主 Skill 已注册，`load_skill` 可访问 `SKILL.md` 与 `ROUTING.md`（需重新构建后生效）。
