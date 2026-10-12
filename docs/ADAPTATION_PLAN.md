# 新移植技能定制化适配计划（ADAPTATION_PLAN）

> 本文件记录对 22 个新移植技能结合本应用真实工具（docx / xlsx / ppt / svg / data 核心技能 + read/write/edit 系列 + pdf/search_pdf/pdf_to_images + search_web/web_fetch + write_file + subagent）所做的定制化适配。
> 原则：保留原文提示词体量不简化；只增不改可用语义；不可用平台/脚本继续删除或改写；每次改动保持 `check-docs` / `tsc` / frontmatter / registry 一致。

## 已完成适配状态

| 技能 | 核心定制 | 状态 |
|---|---|---|
| `journal-format` | 已深度接入 `load_skill("docx")` + `read_docx`/`edit_docx`/`write_docx`；PDF 用 `search_pdf`/`pdf_to_images`/`view_image` | ✅ 移植期完成 |
| `pdf` | 已接入 `parse_document`/`pdf_to_images`/`view_image`/`search_pdf`，表格输出 `write_xlsx`，文档输出 `write_docx`/`write_pptx` | ✅ 移植期完成 |
| `questionnaire` | 已声明 `load_skill("docx")`/`write_docx`、`load_skill("xlsx")`/`write_xlsx`/`edit_xlsx`、`transform_file` | ⏳ 待加深 |

## 批次 A（Office/方案类，已完成）

### research-proposal
- [x] 交付说明补充：Word 正式提案用 `load_skill("docx")` + `write_docx`（Doc JSON：标题层级/表格/占位符）
- [x] 事实台账/参考文献可另交付 `write_xlsx`（workbook-dsl）便于排序筛选

### industry-analysis
- [x] 数据台账与关键对比表用 `load_skill("xlsx")` + `write_xlsx`/`edit_xlsx`
- [x] 最终报告 Markdown 或 `load_skill("docx")` + `write_docx`；可选执行摘要 PPT 用 `load_skill("ppt")` + `write_pptx`

### patent-drafting
- [x] 权利要求对照表/核验表用 `load_skill("xlsx")` + `write_xlsx`（已有 docx 交付）
- [x] 保持 docx 技能深度绑定

### marketing-plan
- [x] Word 方案用 `load_skill("docx")` + `write_docx`
- [x] 预算分配/执行排期/效果预估表用 `load_skill("xlsx")` + `write_xlsx`
- [x] 配图/图表用 `write_svg`（svg 技能）

### newmedia-writing
- [x] Word 文档用 `load_skill("docx")` + `write_docx`
- [x] 分镜脚本表/内容日历用 `load_skill("xlsx")` + `write_xlsx`
- [x] 封面/配图用 `write_svg`（svg 技能）

### khazix-writer
- [x] 交付说明：长文 Markdown 用 `write_file`；Word 版用 `load_skill("docx")` + `write_docx`
- [x] 配图位说明用 `write_svg` 或用户供图

## 批次 B（学术/审计类，已完成）

### paper-rebuttal
- [x] rebuttal 主交付 `load_skill("docx")` + `write_docx`（或 Markdown `write_file`）
- [x] 意见清单表/修改日志用 `load_skill("xlsx")` + `write_xlsx`
- [x] DOCX 论文修改用 `read_docx`/`edit_docx`

### paper-reviewer
- [x] 评审意见表/评分表用 `load_skill("xlsx")` + `write_xlsx`
- [x] 评审报告 `load_skill("docx")` + `write_docx` 或 `write_file`

### paper-close-reading
- [x] Word 报告用 `load_skill("docx")` + `write_docx`
- [x] 关键图表/数字核对表可选 `load_skill("xlsx")` + `write_xlsx`

### reference-audit
- [x] Word 审查书用 `load_skill("docx")` + `write_docx`
- [x] 待核验条目/核验结果台账用 `load_skill("xlsx")` + `write_xlsx`

### sentiment-tracker
- [x] 报告 `write_file` Markdown 或 `load_skill("docx")` + `write_docx`
- [x] 舆情台账用 `load_skill("xlsx")` + `write_xlsx`（平台/链接/互动/倾向可筛选）

### questionnaire
- [x] 加深：M3/M4 数据与标注用 `load_skill("xlsx")` + `write_xlsx`，M4 用 `transform_file`/`edit_xlsx` 清洗

## 批次 C（写作/通用类，已完成）

### translation
- [x] 双语文档用 `load_skill("docx")` + `write_docx`（已有）
- [x] 术语表用 `load_skill("xlsx")` + `write_xlsx`

### humanizer
- [x] 改写稿 Word 用 `load_skill("docx")` + `write_docx`
- [x] 前后对照表可选 `load_skill("xlsx")` + `write_xlsx`

### prompt-engineering
- [x] Prompt 库用 `write_file`/`write_docx`；Prompt 清单可用 `load_skill("xlsx")` + `write_xlsx`

### content-rewrite
- [x] 多平台内容分片用 `load_skill("docx")` + `write_docx` 或 `write_file`
- [x] 平台对照表/发布检查表用 `load_skill("xlsx")` + `write_xlsx`

### marketing-material-review
- [x] 审核报告用 `load_skill("docx")` + `write_docx` 或 `write_file`
- [x] 审核条目表用 `load_skill("xlsx")` + `write_xlsx`

### research-lineage-map
- [x] Markdown 主交付保留；节点明细表可用 `load_skill("xlsx")` + `write_xlsx`
- [x] 可选 SVG 版演进图用 `write_svg`（svg 技能）

### html
- [x] 已用 `write_file` 输出 .html + `write_svg` 配图；无需大改

### pdf
- [x] 已深度接入 `parse_document`/`pdf_to_images`/`view_image`/`search_pdf` + `write_xlsx`/`write_docx`/`write_pptx`；无需大改

## 已完成（本轮后续更新状态）
