---
name: content-writing
description: 【新增】主 Skill（路由入口）。用户请求属于内容创作与营销文案——公众号长文、小红书/短视频、多平台改写分发、去 AI 味、营销策划方案——时，先加载本技能做意图判别与分支分流，再 load_skill 对应分支 Skill（khazix-writer/newmedia-writing/content-rewrite/humanizer/marketing-plan）。营销素材合规审核转 legal-ip。
---

# 【新增】主 Skill：内容创作与营销文案（content-writing）

> 本文件是新增的**主 Skill 路由入口**，用于降低 `khazix-writer` / `newmedia-writing` / `content-rewrite` / `humanizer` / `marketing-plan` 之间的生态位重叠。
> 原始分支 Skill 的 `SKILL.md` 与 `reference/*` 全部保持原样，不在此重复、不删改。
> 详细路由见本目录 `ROUTING.md`（`load_skill("content-writing","ROUTING.md")`）。
> 分支 Skill 不直接出现在 `list_skills` 清单中，经本主 Skill 路由后按分支 id 加载。

## 何时进入本主 Skill

命中以下任一**首要意图**时进入，**必须先 `load_skill("content-writing")`，未加载前不得自行处理**（先判意图，再选分支）：

1. 以“数字生命卡兹克”风格写/续写/扩写**公众号长文** → 分支 `khazix-writer`
2. **小红书图文 / 公众号文章 / 短视频分镜脚本 / 复合型创作** → 分支 `newmedia-writing`
3. 基于已有母稿做**多平台改写分发**（≥2 平台，或有素材的单平台改写）→ 分支 `content-rewrite`
4. **去 AI 味 / 拟人化 / 可读性改写** → 分支 `humanizer`
5. **营销策划全案 / 活动策划 / 产品上市方案**等方案类 → 分支 `marketing-plan`

## 路由速查表

| 用户意图 | 分支 Skill | 加载方式 |
|---|---|---|
| 卡兹克风格公众号长文 | `khazix-writer` | `load_skill("khazix-writer")` |
| 小红书/公众号/短视频/复合创作 | `newmedia-writing` | `load_skill("newmedia-writing")` |
| 多平台改写分发 | `content-rewrite` | `load_skill("content-rewrite")` |
| 去 AI 味/拟人化改写 | `humanizer` | `load_skill("humanizer")` |
| 营销策划方案 | `marketing-plan` | `load_skill("marketing-plan")` |

## 边界：不进入本主 Skill

- 用户要**学术论文改写/润色** → 先进 `academic-publishing` → `paper`；纯语言润色可回 `humanizer`。
- 用户要**营销素材合规审查**（广告法/宣传语合规）→ 先进 `legal-ip` → `marketing-material-review`。
- 用户要**深度调研/行业研究/舆情** → 先进 `research-intelligence`。
- 用户要**具体 Word/Excel/PPT/SVG/HTML/PDF/数据清洗文件**且没有内容方法论要求 → 直接加载对应格式分支（`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`），不经过主 Skill。

## 使用步骤

1. `load_skill("content-writing")` 读本入口。
2. 按上表判定唯一分支；如不确定，读 `ROUTING.md`。
3. `load_skill("<分支 Skill id>")` 进入分支正文执行。
4. 分支正文要求调用的 `docx` / `xlsx` / `svg` 等工具链，按分支正文指示加载。
