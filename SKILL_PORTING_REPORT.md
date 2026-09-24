# Skills 移植分析报告（四平台参考 → 本项目）

> 生成时间：2026-09-17
> 参考目录：`C:\Users\a1519\Documents\doubao-workbuddy-qwenwork-skills-skill\doubao-workbuddy-qwenwork-skills-skill`
> 目标目录：`entry/src/main/resources/rawfile/skills/<id>/` + `WorkSkillService.registry()`
> 执行约束：不删除原文件、不覆盖未确认内容。本报告只新增文件与登记条目。

## 1. 参考范围

| 平台 | 扫描目录 | 说明 |
| --- | --- | --- |
| ChatGPT | `chatgpt/skills/` | 6 个系统技能（imagegen / openai-docs / plugin-creator / review-agent / skill-creator / skill-installer） |
| Doubao | `doubao/skills/` | 109 个技能（办公/文档/PPT、数据分析、金融、医疗、学术、内容运营、协作工具等） |
| QwenWork | `qwenwork/skills/` | 25 个技能（docx/pptx/xlsx/pdf、钉钉产品族、媒体生成、技能创建等） |
| WorkBuddy | `workbuddy/skills/` + `workbuddy/experts/**/skills/` | 17 个通用技能 + 大量专家团队技能（论文、内容、法务、数据、前端等） |

## 2. 现有技能覆盖（32 个：原 10 + 移植 22）

| id | 覆盖领域 |
| --- | --- |
| ppt | 演示文稿制作/编辑 |
| docx | Word 文档制作/编辑 |
| xlsx | Excel 表格制作/分析 |
| svg | SVG 矢量绘图/生图 |
| data | transform_file 数据管道 |
| paper | 论文改写/学术化写作 |
| law | 国企法律事务分析 |
| research | 深度研究/多轮验证 |
| sift | 信息溯源/AI 内容过滤 |
| llm-eval | 大模型评测与选型 |
| humanizer | 去 AI 味/拟人化/可读性（移植） |
| prompt-engineering | 提示词工程（移植） |
| pdf | PDF 读取/搜索/扫描件阅读（移植） |
| translation | 法律翻译/术语一致性/双语 Word（移植） |
| questionnaire | 问卷/深访/原声打标/定量分析（移植） |
| content-rewrite | 多平台内容改写分发（移植） |
| html | 单页 HTML 开发（移植） |
| paper-reviewer | 学术论文审稿（移植） |
| review-agent | 代码评审（移植） |
| paper-rebuttal | 审稿意见 rebuttal 回复（移植） |
| research-lineage-map | 研究谱系演进图（移植） |
| marketing-plan | 营销策划方案（移植） |
| reference-audit | 参考文献审计（移植） |
| paper-close-reading | 论文精读（移植） |
| khazix-writer | 公众号长文写作（卡兹克风格）（移植） |
| newmedia-writing | 小红书/公众号/短视频新媒体写作（移植） |
| marketing-material-review | 营销素材合规审核（移植） |
| patent-drafting | 专利申请文件撰写（移植） |
| sentiment-tracker | 舆情追踪与溯源（移植） |
| journal-format | 学术论文 DOCX 格式排版与修复（移植） |
| research-proposal | 学术立项书/基金申请撰写（移植） |
| industry-analysis | 行业深度研究（移植） |

## 3. 筛选维度

筛选参考技能时按以下维度打分：

1. **高频**：跨平台反复出现、用户日常高频需求；
2. **通用**：不绑定单一平台/单一垂直行业（如不选 lark/dingtalk 办公族、不选亚马逊选品、不选量化交易）；
3. **可复用**：方法论/工作流可脱离参考平台脚本独立成立；
4. **与现有 skill 不重复**：不与上表 10 个技能主责冲突。

## 4. 落选但记录在案的候选（暂不移植）

| 参考技能 | 落选原因 |
| --- | --- |
| 各平台 docx/pptx/xlsx/pdf 全套 | docx/pptx/xlsx 已有；pdf 部分能力（创建/合并/水印/填表）当前工具集不支持 |
| doubao-newmedia-writing / wechat-article-pro | 强平台绑定（公众号/小红书/微博/短视频单平台写作），核心改写纪律并入 humanizer；多平台分发已选 `content-rewrite` |
| chatgpt review-agent / 各平台 frontend-dev / html | 依赖代码评审/前端发布链路，超出当前工具边界 |
| deep-research / paper-reviewer / paper-rebuttal | 与现有 research / paper 技能重叠或属于其上一步/下一步（可后续增强） |
| 各平台 lark/dingtalk 协作族、金融/医疗/法务垂直技能 | 强平台或强行业绑定，不符合"通用"维度 |

## 5. 移植清单（截至当前已新增 22 个新技能）

| 新技能 id | 定位 | 主要参考来源 | 工具映射（本项目） |
| --- | --- | --- | --- |
| `humanizer` | 去除 AI 写作痕迹、拟人化改写、可读性 | `workbuddy/skills/humanizer/SKILL.md`；`workbuddy/experts/social-content-team/skills/de-ai-writing/SKILL.md`、`output-readability/SKILL.md` | write_file / read_file / edit 类；交付可用 write_docx |
| `prompt-engineering` | 提示词工程：撰写/优化/评测/反模式 | `workbuddy/skills/prompt-engineering-expert/SKILL.md` + `docs/*.md` | 纯方法论，无特殊工具依赖 |
| `pdf` | PDF 读取/搜索/扫描件阅读（能力边界内） | `qwenwork/skills/pdf/SKILL.md`；`doubao/skills/doubao-pdf/SKILL.md` | parse_document / search_pdf / pdf_to_images / view_image；已移除生成/编辑/脚本类不可用内容 |
| `translation` | 法律文书翻译 + 术语一致性 + 双语 Word；附医学翻译参考 | `workbuddy/experts/cross-border-legal-expert/skills/legal-translation/SKILL.md`；`doubao/skills/doubao-medical-literature-translation/SKILL.md` | write_file / write_docx（load_skill("docx")）；web_search 辅助核验；已移除 python-docx/飞书/脚本类不可用内容 |
| `questionnaire` | 问卷设计 / 访谈提纲 / 开放题原声打标 / 定量问卷分析 | `doubao/skills/doubao-questionnaire-designer/SKILL.md` + `references/m1..m4` | write_docx / write_xlsx / transform_file 清洗；原文飞书交付已改为 Office/Markdown |
| `content-rewrite` | 母稿/素材 → 多平台分发版本（公众号/短视频/微博/小红书） | `doubao/skills/doubao-multiplatform-rewrite/SKILL.md` + `references/common/*.md` + `references/platforms/*.md` | write_file / write_docx / svg 配图 / search_web；原文飞书 Block 规范已改为文档结构 |
| `html` | 单页 HTML 开发（官网/落地页/看板/原型/轻工具） | `doubao/skills/html/SKILL.md` + `references/*.md`（4 个） | write_file 写 HTML / download_file 素材 / write_svg 配图；已移除 embed/shot 脚本与发布/平台差异章节 |
| `paper-reviewer` | 学术论文审稿（OpenReview 风格） | `workbuddy/skills/paper-reviewer/SKILL.md` + `references/*.md` | parse_document / pdf_to_images / download_file / web_fetch / search_web |
| `review-agent` | 代码评审（缺陷优先 P0–P3） | `chatgpt/skills/review-agent/SKILL.md` + `agents/openai.yaml` | read_file / search_files；git 命令不可用，依赖用户提供 diff |
| `paper-rebuttal` | 审稿意见 rebuttal 回复（point-by-point） | `workbuddy/skills/paper-rebuttal/SKILL.md` + `references/*.md`（3 个） | parse_document / read_file / edit / write_file / write_docx |
| `research-lineage-map` | 研究/技术谱系演进图（Mermaid） | `workbuddy/skills/research-lineage-map/SKILL.md` + `references/*.md`（2 个） | search_web / web_fetch / write_file；已移除 validate_mermaid.py，校验改为人工核对 |
| `marketing-plan` | 营销策划方案（Markdown/Word） | `doubao/skills/doubao-marketing-plan/SKILL.md` + `references/*.md`（4 个） | write_file / write_docx / search_web / svg 配图；原文飞书/Lark 交付已改为文件交付 |
| `reference-audit` | 参考文献真实性/题录/主张支持审计 | `doubao/skills/doubao-reference-audit/SKILL.md` + `assets/report-template.md` | search_web / web_fetch / write_file / write_docx；已移除 lookup_metadata.py，改为联网核验 |
| `paper-close-reading` | 论文深度精读（研究故事/证据/边界） | `doubao/skills/doubao-paper-close-reading/SKILL.md` + `assets/report-template.md` | parse_document / pdf_to_images / read_file / write_file / write_docx；原文飞书交付已改为文件交付 |
| `khazix-writer` | 公众号长文写作（卡兹克风格） | `workbuddy/skills/khazix-writer/SKILL.md` + `references/content_methodology.md` + `references/style_examples.md` | write_file / write_docx / search_web / web_fetch / read_file / parse_document；适配说明写入 references |
| `newmedia-writing` | 小红书/公众号/短视频新媒体写作与复合方案 | `doubao/skills/doubao-newmedia-writing/SKILL.md` + `references/**/*.md`（含拆分的 image-design-methods 上下篇） | write_file / write_docx / svg 配图 / search_web；飞书/Lark + lark-cli 交付改为 Markdown/Word 文档规则 |
| `marketing-material-review` | 营销素材合规审查 | `doubao/skills/doubao-marketing-material-review/SKILL.md` | write_file / write_docx / search_web / web_fetch；飞书报告改为文件交付 |
| `patent-drafting` | 专利申请文件撰写（发明/实用新型） | `doubao/skills/doubao-patent-drafting/SKILL.md` + `README.md` + `references/writing-style.md` + `sub-skills/*/SKILL.md` | load_skill("docx") / write_docx；已删除 scripts/patent_build.py，改为人工自检清单 + write_docx 交付 |
| `sentiment-tracker` | 舆情追踪与一手信源溯源 | `doubao/skills/doubao-sentiment-tracker/SKILL.md` + `references/*.md` + `agents/openai.yaml` | search_web / web_fetch / write_file / write_docx；浏览器自动化/登录墙改为用户提供链接或截图 |
| `journal-format` | 学术论文 DOCX 格式排版与修复 | `doubao/skills/doubao-journal-format/SKILL.md` + `references/*.md`（6 个） | SKILL.md 与多个 references 拆分为 <1.2 万字符片段；删除 render_docx.py/scripts/*.py/fallback_ooxml_spec.json；执行改为 docx 技能 + 人工自检 |
| `research-proposal` | 学术立项书/基金申请撰写、审查与优化 | `doubao/skills/doubao-research-proposal/SKILL.md` + `references/*.md`（7 个） | 二进制 `assets/templates/*.doc/.docx` 未移植，改为官方/用户模板；飞书/lark-cli 交付改为 write_file/write_docx；相邻豆包技能改为本项目技能映射 |
| `industry-analysis` | 行业深度研究（判断主线/三级数据/五大板块） | `doubao/skills/doubao-industry-analysis/SKILL.md` + `references/*.md`（8 个）+ `agents/openai.yaml` | 删除 scripts/*.py；飞书/Lark + OrganizerAgent 改为文件交付 + 同一执行者统筹；general_search/seed_finance_search 映射 search_web/web_fetch |

## 6. 不简化原则

用户新增要求：移植 skill 不能太简陋，提示词部分不能低于原体量，绝对不能简化。

因此本轮不是把参考技能压成摘要，而是：
- 每个新技能保留参考平台的**原始 SKILL.md 全文**（超长文件按 <1.2 万字符拆段，如 `pdf/SKILL.md` + `reference/original-prompt-2..4.md`、`translation/reference/medical-1..5.md`）；
- 同时保留配套 docs/references 全文（如 `prompt-engineering/reference/BEST_PRACTICES.md`、`TECHNIQUES.md`、`TROUBLESHOOTING.md`、`EXAMPLES.md` 等）；
- 在 SKILL.md 中提供本项目工具映射/能力边界，但不删减原始方法内容。

## 7. Source Map 摘要

| 移植点 | 参考来源（相对路径） | 落地 |
| --- | --- | --- |
| 24 项 AI 写作模式检测与修复 | `workbuddy/skills/humanizer/SKILL.md` | `humanizer/SKILL.md`（前半）+ `reference/general-patterns-2.md`（后半） |
| 社媒 16 项 AI 味检测与分级修复、不编造真实细节 | `workbuddy/experts/social-content-team/skills/de-ai-writing/SKILL.md` | `humanizer/reference/social-media.md` |
| 可读性四规则（结论先行/不造术语/分层交付/不暴露写作规则） | `workbuddy/experts/social-content-team/skills/output-readability/SKILL.md` | `humanizer/reference/readability.md` |
| 提示词核心原则/技巧/反模式/评测 | `workbuddy/skills/prompt-engineering-expert/SKILL.md`、`docs/BEST_PRACTICES.md`、`docs/TECHNIQUES.md` | `prompt-engineering/SKILL.md` + `reference/BEST_PRACTICES.md`、`TECHNIQUES.md`、`TROUBLESHOOTING.md`、`EXAMPLES.md` 等 |
| PDF 先分析再处理、目标先定位、分块读取、扫描件转图 | `qwenwork/skills/pdf/SKILL.md`、`doubao/skills/doubao-pdf/SKILL.md` | `pdf/SKILL.md`（本项目适配版）+ `reference/tool-notes.md`（已移除生成/编辑/脚本类不可用内容） |
| 翻译先建术语表、术语/结构/数字一致性、双语 Word | `workbuddy/experts/cross-border-legal-expert/skills/legal-translation/SKILL.md`、`doubao/skills/doubao-medical-literature-translation/SKILL.md` | `translation/SKILL.md`（法律翻译完整原文）+ `reference/medical-1..5.md` |
| 问卷/深访/原声打标/定量分析四模块 | `doubao/skills/doubao-questionnaire-designer/SKILL.md`、`references/m1-questionnaire-design.md`、`m2-interview-outline.md`、`m3-verbatim-tagging.md`、`m4-quantitative-analysis.md` | `questionnaire/SKILL.md` + `CHANGELOG.md` + `references/m1..m4.md`（原文飞书交付已改为 Office/Markdown） |
| 多平台改写分发完整工作流 | `doubao/skills/doubao-multiplatform-rewrite/SKILL.md`、`references/common/*.md`（7 个）、`references/platforms/*.md`（4 个） | `content-rewrite/SKILL.md` + `references/common/*.md` + `references/platforms/*.md`（原文飞书 Block 规范已改为文档结构） |
| 单页 HTML 开发完整规范 | `doubao/skills/html/SKILL.md`、`references/*.md`（6 个）、`scripts/embed.py`、`scripts/shot.py` | `html/SKILL.md`（已适配）+ `references/*.md`（4 个）；已删除 lark 发布/windows-compat/embed/shot 等不可用内容 |
| 学术论文审稿完整工作流 | `workbuddy/skills/paper-reviewer/SKILL.md`、`references/review-criteria.md`、`references/review-template.md` | `paper-reviewer/SKILL.md` + `references/*.md`（全文复制，仅加适配说明） |
| 代码评审完整工作流 | `chatgpt/skills/review-agent/SKILL.md`、`agents/openai.yaml` | `review-agent/SKILL.md` + `agents/openai.yaml`（全文复制，仅加适配说明） |
| Rebuttal 全流程（意见分类/判定/修改日志/回复模板） | `workbuddy/skills/paper-rebuttal/SKILL.md`、`references/comment-taxonomy.md`、`rebuttal-writing-guide.md`、`response-template.md` | `paper-rebuttal/SKILL.md` + `references/*.md`（全文复制，仅加适配说明） |
| 研究谱系“问题→解决”叙事 + Mermaid 模板 | `workbuddy/skills/research-lineage-map/SKILL.md`、`references/mermaid-patterns.md`、`output-template.md` | `research-lineage-map/SKILL.md` + `references/*.md`（全文复制；删除 validate_mermaid.py，校验改人工） |
| 营销策划方案（方法论/热点/图片/输出红线） | `doubao/skills/doubao-marketing-plan/SKILL.md`、`references/*.md`（4 个） | `marketing-plan/SKILL.md` + `references/*.md`（全文复制；飞书/Lark 交付改为 Markdown/Word） |
| 参考文献审计七阶段流程 | `doubao/skills/doubao-reference-audit/SKILL.md`、`assets/report-template.md` | `reference-audit/SKILL.md` + `assets/report-template.md`（全文复制；删除 lookup_metadata.py，改为 search_web/web_fetch 核验） |
| 论文精读七阶段流程 | `doubao/skills/doubao-paper-close-reading/SKILL.md`、`assets/report-template.md` | `paper-close-reading/SKILL.md` + `assets/report-template.md`（全文复制；飞书交付改为 Markdown/Word） |
| 卡兹克公众号长文写作（价值观/结构/方法/风格示例） | `workbuddy/skills/khazix-writer/SKILL.md`、`references/content_methodology.md`、`references/style_examples.md` | `khazix-writer/SKILL.md` + `references/*.md`（全文复制；适配说明写入 references，避免超长 SKILL.md） |
| 新媒体写作（小红书/公众号/短视频/复合）完整路由 | `doubao/skills/doubao-newmedia-writing/SKILL.md`、`references/genre-guide/*.md`、`references/{xhs,wechat,short-video}.samples/**/*.md` | `newmedia-writing/SKILL.md` + `references/**/*.md`（全文复制；`lark-doc.writing-guide.md` 改写为 Markdown/Word 文档规则；`image-design-methods.md` 超长拆为上下篇） |
| 营销素材合规审查五步流程 | `doubao/skills/doubao-marketing-material-review/SKILL.md` | `marketing-material-review/SKILL.md`（全文复制；飞书报告改为 Markdown/Word 文件交付） |
| 专利申请文件撰写三阶段主流程 | `doubao/skills/doubao-patent-drafting/SKILL.md`、`README.md`、`references/writing-style.md`、`sub-skills/{claims,intake-audit,specification}/SKILL.md` | `patent-drafting/SKILL.md` + `README.md` + `references/writing-style.md` + `sub-skills/*/SKILL.md`（全文复制；删除 scripts/patent_build.py，交付编译改为人工自检 + write_docx） |
| 舆情追踪五步法与一手信源溯源 | `doubao/skills/doubao-sentiment-tracker/SKILL.md`、`references/evaluation-set.md`、`references/twitter-guide.md`、`references/weibo-guide.md`、`agents/openai.yaml` | `sentiment-tracker/SKILL.md` + `references/*.md` + `agents/openai.yaml`（全文复制；浏览器自动化/豆包文档/手机端限制改写为本项目工具） |
| 学术论文 DOCX 格式排版与修复全流程 | `doubao/skills/doubao-journal-format/SKILL.md`、`references/{style-routing,references-numbering-superscript,equations-tables-sections,preservation-rules,template-distill-render-qa,explicit-postprocess}.md` | `journal-format/SKILL.md` + `SKILL-2..5.md` + `references/*（含 -2/-3 拆分片段）`（全文拆分复制；脚本/soffice/PDF 库改写为 docx 技能 + 人工自检） |
| 学术立项书/基金申请撰写流程 | `doubao/skills/doubao-research-proposal/SKILL.md`、`references/*.md`（7 个） | `research-proposal/SKILL.md` + `references/*.md`（全文复制；二进制模板未移植；飞书/lark-cli 交付与豆包相邻技能改写） |
| 行业深度研究（判断主线/三级数据/五大板块） | `doubao/skills/doubao-industry-analysis/SKILL.md`、`references/*.md`（8 个）、`agents/openai.yaml` | `industry-analysis/SKILL.md` + `references/*.md` + `agents/openai.yaml`（全文复制；scripts/飞书/OrganizerAgent 改写；lark-doc-report-standard.md 改写为文件交付标准） |

## 9. 双数轮复查（R2）

双数轮要求对上一轮技能全面复查，纠正简化/缩略/自编行为。R2 完成以下修正：

- **SKILL.md 改为直接移植原提示词，不再用自编摘要**：
  - `humanizer/SKILL.md` = 原 `workbuddy/skills/humanizer/SKILL.md` 正文前半（CONTENT PATTERNS 完整 before/after），后半在 `reference/general-patterns-2.md`；
  - `prompt-engineering/SKILL.md` = 原 `prompt-engineering-expert/SKILL.md` 原文（仅改 frontmatter 名）；
  - `pdf/SKILL.md` = 原 `qwenwork/skills/pdf/SKILL.md` 前半，后半在 `reference/original-prompt-2..4.md`；
  - `translation/SKILL.md` = 原 `legal-translation/SKILL.md` 全文（仅改 frontmatter 名），医学翻译全文在 `reference/medical-1..5.md`。
- **删除自编速查文件**：`prompt-engineering/reference/best-practices.md`、`translation/reference/translation-playbook.md`（原来自我简化，R2 移除，避免模型读到简化版）。
- **删除与 SKILL.md 重复的引用**：`humanizer/reference/general-patterns.md`、`prompt-engineering/reference/original-skill.md`、`pdf/reference/original-prompt-1.md`、`translation/reference/legal-full.md`（内容已由对应 SKILL.md 承载，R2 去重）。
- **新增适配层**：`pdf/reference/tool-notes.md`（本项目工具映射/工作流/能力边界），与原始提示词并存，不替代原始内容。
- **验证**：frontmatter 14 个技能全部一致；新技能文档全部 <1.2 万字符（仅既有 `ppt/SKILL.md` 13026 字符为历史遗留）；`WorkSkillService` 类型检查通过。

## 10. R3（单数轮）新增：questionnaire

- 直接完整移植 `doubao-questionnaire-designer`：SKILL.md + CHANGELOG.md + 4 个 references 全文，未做简化/合并；
- 仅修改 frontmatter `name` 为 `questionnaire`，并在 SKILL.md 末尾增加本项目适配说明（飞书交付改 `write_docx`/`write_xlsx`）；
- 已登记 `WorkSkillService.registry()` 并纳入 `check-docs.py`；
- 验证：frontmatter 15 个技能全部一致；新技能文件全部 <1.2 万字符；`tsc` 通过。

## 10a. R4（双数轮）复查 questionnaire

- MD5 比对：references/m1..m4、CHANGELOG.md 与参考源完全一致；
- SKILL.md 正文（去掉 frontmatter name 与适配说明）与参考源逐字符一致（2579 = 2579 字符）；
- 适配说明中的工具（write_docx/write_xlsx/transform_file/edit_xlsx）均已在本项目核实存在；
- 引用路径、注册白名单、check-docs 覆盖全部核验通过；
- 结论：未发现简化/缩略/自编，本轮为纯复查，未改动内容。

## 10b. R5（单数轮）新增：content-rewrite

- 直接完整移植 `doubao-multiplatform-rewrite`：SKILL.md + `references/common/*.md`（7 个）+ `references/platforms/*.md`（4 个）全文，未做简化/合并；
- 仅修改 frontmatter `name` 为 `content-rewrite`，并在 SKILL.md 末尾增加本项目适配说明（飞书交付改 `write_file`/`write_docx`；配图用 svg 或用户供图；`internet-search` 对应 `search_web`）；
- 已登记 `WorkSkillService.registry()` 并纳入 `check-docs.py`；
- 验证：frontmatter 16 个技能全部一致；新技能文件全部 <1.2 万字符；`tsc` 通过。

## 10c. R6（双数轮）复查 content-rewrite

- MD5 比对：references/common 7 个 + references/platforms 4 个与参考源完全一致；
- SKILL.md 正文（去掉 frontmatter name 与适配说明，忽略结尾空行）与参考源逐字符一致（8857 = 8858）；
- 适配说明中的工具/技能（write_file/write_docx/svg/search_web）均已在本项目核实存在；
- 引用路径、注册白名单、check-docs 覆盖全部核验通过；
- 结论：未发现简化/缩略/自编，本轮为纯复查，未改动内容。

## 10d. R7（单数轮）新增：html

- 直接完整移植 `doubao/skills/html`：SKILL.md + references（6 个）+ scripts（embed.py/shot.py 参考代码）全文，未做简化/合并；
- 源 frontmatter 已是 `html`，无需改名；仅在 SKILL.md 末尾增加本项目适配说明（脚本不可执行、present_files/妙搭发布不可用、交付用 write_file、素材用 download_file、配图用 write_svg）；
- 已登记 `WorkSkillService.registry()`（8 个文件全量登记）并纳入 `check-docs.py`（6 个 reference 文档 + SKILL.md）；
- 验证：references/scripts 哈希与参考源完全一致；SKILL.md 正文（去掉适配说明，忽略结尾空行）与参考源逐字符一致；frontmatter 17 个技能全部一致；`tsc` 通过。

## 10e. R8（双数轮）复查 html

- MD5 比对：references 6 个 + scripts 2 个与参考源完全一致；
- SKILL.md 正文（去掉适配说明，忽略结尾空行）与参考源逐字符一致（9857 = 9859）；
- 适配说明中的工具（write_file/download_file/write_svg）均已核实存在；present_files/妙搭/Python 执行如实标注为不可用；
- 引用路径、注册白名单、check-docs 覆盖全部核验通过；
- 结论：未发现简化/缩略/自编，本轮为纯复查，未改动内容。

## 10f. R9（单数轮）新增：paper-reviewer + review-agent

- 非重大文档型移植，本轮新增 2 个技能：
  - `paper-reviewer`：完整复制 `workbuddy/skills/paper-reviewer/`（SKILL.md + 2 个 references），仅加适配说明（PDF/arXiv/搜索工具映射）；
  - `review-agent`：完整复制 `chatgpt/skills/review-agent/`（SKILL.md + agents/openai.yaml），仅加适配说明（无 git，依赖用户提供 diff）；
- 已登记 `WorkSkillService.registry()` 并纳入 `check-docs.py`；
- 验证：references/yaml 哈希与参考源完全一致；两个 SKILL.md 正文（去掉适配说明，忽略结尾空行）与参考源逐字符一致；frontmatter 19 个技能全部一致；`tsc` 通过。

## 10g. R9 修正（用户反馈）：清理不可用工具/平台

用户指出原样复制保留了太多不可用工具/平台，要求“删除或改写不匹配的平台/工具”。已按此原则修正 9 个移植技能：

- **html**：删除 `references/lark-apps-publish.md`、`references/windows-compat.md`、`scripts/embed.py`、`scripts/shot.py`；SKILL.md 移除云电脑/本地判定、`present_files`、妙搭发布、截图脚本自检，改为 `write_file` 交付 + 人工自检清单；
- **pdf**：重写 SKILL.md 为“读取/搜索/扫描件阅读”能力边界版；删除 `original-prompt-2..4.md`、`advanced-libraries.md`、`forms-guide.md`、`generation-guide.md`、`security-guide.md`、`troubleshooting.md`、`extraction-guide.md`（原内容以不可用脚本/库为主）；
- **translation**：移除 `python-docx`/pip/`extract_text.py`/`create_bilingual.py` 及悬空 `references/*.md` 路由；双语 Word 改用 `write_docx`；医学参考 `medical-2/3/4/5.md` 改为人工校验/文档交付，`medical-5` 不再路由到不存在的豆包相邻技能；
- **review-agent**：正文不再要求 `git merge-base`/`git diff`，改为“请用户提供 diff/变更文件 + `read_file` 读取”；
- **questionnaire / content-rewrite**：全局把原文“飞书云文档/飞书表格/飞书 Block”替换为 Markdown/Word/Excel/文档结构，适配交付工具；
- **paper-reviewer / humanizer / prompt-engineering**：检查无不可用平台/工具残留（`WebSearch` 已替换为 `search_web`）。

验证：全部 19 个技能 frontmatter 一致；文档体量检查通过；`tsc` 通过；所有剩余文件均在注册表内。

## 10h. R10（目标第 1 轮）新增：paper-rebuttal + research-lineage-map + marketing-plan + reference-audit + paper-close-reading

- 非重大文档型移植，本轮新增 5 个技能（对应“先移植高优先级”目标第 1 轮）：
  - `paper-rebuttal`：完整复制 `workbuddy/skills/paper-rebuttal/`（SKILL.md + 3 个 references），仅加适配说明（PDF/Word/Markdown 读取、edit/write_file/write_docx）；
  - `research-lineage-map`：完整复制 `workbuddy/skills/research-lineage-map/`（SKILL.md + 2 个 references）；`scripts/validate_mermaid.py` 本环境不可用已删除，第 6 步校验改为人工核对 Mermaid，交付用 `write_file`；
  - `marketing-plan`：完整复制 `doubao/skills/doubao-marketing-plan/`（SKILL.md + 4 个 references）；原文飞书/Lark Doc 交付改写为 `write_file`（Markdown）/`write_docx`（Word），`<grid>/<column>` 分栏改为表格/分栏并排说明；
  - `reference-audit`：完整复制 `doubao/skills/doubao-reference-audit/`（SKILL.md + assets/report-template.md）；`scripts/lookup_metadata.py` 不可用已删除，题录核验改为 `search_web`/`web_fetch` 查 Crossref/PubMed/arXiv/DOI；飞书交付改为文件交付；
  - `paper-close-reading`：完整复制 `doubao/skills/doubao-paper-close-reading/`（SKILL.md + assets/report-template.md）；飞书交付改为 `write_file`/`write_docx`；“不适用”段引用的豆包相邻技能改为本项目技能映射；
- 顺带清理：`content-rewrite` 参考资料里残留的飞书 `<grid>/<column>`/Block 描述改为 Markdown/Word 排版规则；
- 已登记 `WorkSkillService.registry()` 并纳入 `check-docs.py`；
- 验证：frontmatter 24 个技能全部一致；check-docs 通过；`tsc` 通过；全部新增文件均已在注册表内（registry vs disk 无缺失/无未登记）。

## 10i. R11（目标第 2 轮）新增：khazix-writer + newmedia-writing + marketing-material-review + patent-drafting + sentiment-tracker

- 非重大文档型移植，本轮新增 5 个技能（对应“先移植高优先级”目标第 2 轮）：
  - `khazix-writer`：完整复制 `workbuddy/skills/khazix-writer/`（SKILL.md + 2 个 references）；SKILL.md 原长 11914 字符接近上限，适配说明写入 `references/content_methodology.md` 末尾（不超长 SKILL.md）；交付用 `write_file`/`write_docx`，搜索用 `search_web`/`web_fetch`；
  - `newmedia-writing`：完整复制 `doubao/skills/doubao-newmedia-writing/`（SKILL.md + 23 个 references）；`references/genre-guide/lark-doc.writing-guide.md` 由 lark-cli 命令改写为 Markdown/Word 文档创建/写入/校验规则；`references/xhs.samples/.../image-design-methods.md`（16324 字符）拆为 `image-design-methods.md`（上）+ `image-design-methods-2.md`（下），上篇末尾给出续读指引；SKILL.md 路由/自检、其余 guides 与 samples 全文保留；
  - `marketing-material-review`：完整复制 `doubao/skills/doubao-marketing-material-review/`（单文件 SKILL.md）；飞书报告交付改为 `write_file`/`write_docx`；法规检索改为 `search_web`/`web_fetch`；
  - `patent-drafting`：完整复制 `doubao/skills/doubao-patent-drafting/`（SKILL.md + README.md + references/writing-style.md + 3 个 sub-skills）；`scripts/patent_build.py` 本环境不可用已删除，“交付合同”改为「9 项人工自检清单（C1/C2/C3/C5/C7/C13/C14/格式一致性/事实分级）+ `load_skill("docx")` + `write_docx` 生成 Word」，降级路径改为 write_docx 失败时交付 draft.md + 手工自检；子 skill 中对脚本/C14 的引用同步改写；
  - `sentiment-tracker`：完整复制 `doubao/skills/doubao-sentiment-tracker/`（SKILL.md + 3 个 references + agents/openai.yaml）；浏览器自动化（interaction.request_action/browserControl/gui-browser-task-skill/browser-task）改为 `search_web`/`web_fetch` + 用户提供原帖链接/截图；“豆包文档”交付改为 `write_file`/`write_docx`；“网页端/手机端”触发限制改为“公开可读页面/登录墙”限制；
- 已登记 `WorkSkillService.registry()`（khazix 2 + newmedia 23 + marketing 0 + patent 5 + sentiment 4 个 reference 文件，全部 SKILL.md + references 入册）并纳入 `check-docs.py`；
- 验证：frontmatter 29 个技能全部一致；check-docs 通过（唯一超长仍为历史遗留 `ppt/SKILL.md` 13026 字符）；`tsc` 通过；registry vs disk 无缺失/无未登记；README/README_EN/技能计数同步到 29（10 核心 + 19 移植）。

## 10j. R13（目标第 3 轮）新增：journal-format + research-proposal + industry-analysis

- **journal-format（学术论文 DOCX 格式排版与修复）**：源为 `doubao/skills/doubao-journal-format`。SKILL.md（11683 字符）与 6 个 references 均超 1.2 万字符，拆分为 `SKILL.md`+`SKILL-2..5.md` 与 `references/*`（含 `-2`/`-3` 片段），全部 <1.2 万字符；删除 `scripts/*.py`、`render_docx.py`、`fallback_ooxml_spec.json`（未复制）；`SKILL-5.md` 的 Command 改写字为本项目 `docx` 技能 + 人工自检执行说明；references 中 soffice/PyMuPDF/pdfplumber/pdftotext/mutool/脚本命令统一改写为非可执行说明。
- **research-proposal（学术立项书/基金申请撰写）**：源为 `doubao/skills/doubao-research-proposal`。二进制 `assets/templates/*.doc/.docx` 未移植，模板章节与 `academic-grant-guide.md` 改写为“官方最新模板/用户模板优先 + 结构要点表”；飞书/lark-cli 交付改为 `write_file`/`write_docx`；相邻豆包技能（academic-researcher/polish/evaluator）改为本项目 research/paper/humanizer/paper-reviewer 映射。
- **industry-analysis（行业深度研究）**：源为 `doubao/skills/doubao-industry-analysis`。删除 `scripts/{assemble_report,renumber_references,validate_report,upload_report,report_pipeline_common}.py`（未复制）；`references/lark-doc-report-standard.md` 全文改写为 Markdown 拼接与文件交付标准；OrganizerAgent/飞书交付改为同一执行者统筹 + `write_file`/`write_docx`；`general_search`/`seed_finance_search` 映射 `search_web`/`web_fetch`；`agents/openai.yaml` 去飞书字样。
- 登记：`WorkSkillService.registry()` 新增 3 个技能（journalFormat jf1..jf21、researchProposal rp1..rp7、industryAnalysis ia1..ia9），当前共 32 个（10 核心 + 22 移植）。
- 验证：frontmatter 32 个技能全部一致；check-docs 通过（唯一超长仍为历史遗留 `ppt/SKILL.md` 13026 字符）；`tsc` 通过；registry vs disk 无缺失/无未登记；README/README_EN/技能计数同步到 32（10 核心 + 22 移植）。

## 10k. R14（双数轮）22 个移植技能结合本应用工具的定制化适配

- 对全部 22 个移植技能逐技能核对交付格式/工具与本应用真实工具（`docx`/`xlsx`/`ppt`/`svg`/`data` 核心技能 + read/write/edit 系列 + pdf/search_pdf/pdf_to_images + search_web/web_fetch + write_file + subagent）的一致性，把「泛泛的写文件/上传文档」改写为可执行的「`load_skill(核心技能)` + 具体工具调用」。
- 新增 `ADAPTATION_PLAN.md`：22 个技能的定制适配计划与完成状态（批次 A/B/C）。
- 代表性改动：research-proposal / industry-analysis / patent-drafting / marketing-plan / newmedia-writing（Word→docx 技能，表/台账→xlsx 技能，配图→write_svg，汇报→write_pptx）；questionnaire / sentiment-tracker / reference-audit / paper-rebuttal / paper-reviewer / paper-close-reading（报告→docx，清单/台账→xlsx）；translation / humanizer / prompt-engineering / content-rewrite / marketing-material-review / research-lineage-map（术语表/清单/明细表→xlsx，演进图→write_svg）；html / pdf / journal-format 移植期已深度接入，无需大改。
- 验证：全部保持原文提示词体量不简化（仅追加适配说明）；frontmatter 32/32；check-docs 通过（唯一超长仍为历史遗留 `ppt/SKILL.md`）；`tsc` 通过；registry vs disk 无缺失/无未登记；README/README_EN 计数不变（32 个 / 22 移植）。

## 11. 落地步骤（已完成/待办）

- [x] 扫描与分析（本报告）
- [x] 新建 22 个技能目录（SKILL.md + reference/references + assets + agents）
- [x] `WorkSkillService.registry()` 登记新技能（当前 32 个）
- [x] 更新 `test/pptx-harness/check-docs.py` 文档体量检查
- [x] 更新 `ITERATION_LOG.md` 记录本次移植
- [x] 结合本应用工具完成 22 个移植技能的定制化适配（见 `ADAPTATION_PLAN.md` 与 10k 段）
- [ ] 目标剩余轮次：偶数轮继续复查/迭代已适配技能与文档同步（含 journal-format/research-proposal/industry-analysis 及此前各轮技能），并持续维护 README/README_EN 双语文档一致性。
