---
name: legal-ip
description: 【新增】主 Skill（路由入口）。用户请求属于法律/IP/合规——法律案例分析、专利申请文件撰写、法律翻译、营销素材合规审核——时，先加载本技能做意图判别与分支分流，再 load_skill 对应分支 Skill（law/patent-drafting/translation/marketing-material-review）。
---

# 【新增】主 Skill：法律 / IP / 合规（legal-ip）

> 本文件是新增的**主 Skill 路由入口**，用于降低 `law` / `patent-drafting` / `translation` / `marketing-material-review` 之间的生态位重叠。
> 原始分支 Skill 的 `SKILL.md` 与 `reference/*` 全部保持原样，不在此重复、不删改。
> 详细路由见本目录 `ROUTING.md`（`load_skill("legal-ip","ROUTING.md")`）。
> 分支 Skill 不直接出现在 `list_skills` 清单中，经本主 Skill 路由后按分支 id 加载。

## 何时进入本主 Skill

命中以下任一**首要意图**时进入，**必须先 `load_skill("legal-ip")`，未加载前不得自行处理**（先判意图，再选分支）：

1. **企业法律案例 / 纠纷分析**、国企国资监管、合同纠纷、合规与责任认定 → 分支 `law`
2. 基于技术交底书**撰写/修改中国专利申请文件**，或审查权利要求 → 分支 `patent-drafting`
3. **中文法律文书翻译**为英文/中英双语，术语审校，双语 Word → 分支 `translation`
4. **营销素材合规审查**：广告宣传语、海报文案、社媒推广文案、直播话术 → 分支 `marketing-material-review`

## 路由速查表

| 用户意图 | 分支 Skill | 加载方式 |
|---|---|---|
| 法律案例分析/意见书 | `law` | `load_skill("law")` |
| 专利申请文件撰写 | `patent-drafting` | `load_skill("patent-drafting")` |
| 法律翻译/术语审校 | `translation` | `load_skill("translation")` |
| 营销素材合规审核 | `marketing-material-review` | `load_skill("marketing-material-review")` |

## 边界：不进入本主 Skill

- 用户要**营销方案创作** → 先进 `content-writing` → `marketing-plan`；本主 Skill 只做营销素材的合规审查。
- 用户要**学术论文/基金立项** → 先进 `academic-publishing`。
- 用户要**通用 Word/Excel/PPT/SVG/HTML/PDF/数据清洗文件产物** → 直接加载对应格式分支（`docx`/`xlsx`/`ppt`/`svg`/`html`/`pdf`/`data`），不经过主 Skill。
- 用户要**法律类深度检索/时效验证**（如最新法规状态）→ 可先 `research-intelligence` 补材料，再回本主 Skill 分析。

## 使用步骤

1. `load_skill("legal-ip")` 读本入口。
2. 按上表判定唯一分支；如不确定，读 `ROUTING.md`。
3. `load_skill("<分支 Skill id>")` 进入分支正文执行。
4. 分支正文要求调用的 `docx` / `xlsx` / `search_web` 等工具链，按分支正文指示加载。
