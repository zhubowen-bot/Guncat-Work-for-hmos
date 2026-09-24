# ChatGPT 官方文档设计预设（Design Presets 移植）

来源：`chatgpt/plugins/openai-primary-runtime/documents/26.805.11740/skills/documents/references/design_presets.md`。
这些预设是 ChatGPT 生成 DOCX 时使用的**真实 token 级规范**。我们的 `write_docx` 只有 `default/academic/minimal` 三种内置样式，不能逐 token 定制；但遇到用户要"正式 memo/RFI/提案/决策备忘/使用指南"时，按下面选型并说明需要外部 Word 套版的部分。

## 选型

| 预设/别名 | 用途 | 关键特征 |
|---|---|---|
| `google_docs_default` | 净新建 Google Docs 风格文档 | Arial 11pt、黑色标题、无蓝色标题、无页眉页脚、表格极简无底色 |
| `standard_business_brief` | 正式备忘录、RFI 回复、决策备忘、董事会材料 | Calibri 11pt、H1 16pt `#2E74B5`、H2 13pt、H3 12pt、表头 `#F2F4F7` |
| `compact_reference_guide` | 上线指南、谈判简报、清单、密集操作参考 | Calibri 11pt、1.25 行距、表头 `#E8EEF5`、label-detail 表格 |
| `narrative_proposal` | 资助申请、商务提案、长文说服 | Calibri 11pt、两端对齐、1.333 行距、表头 `#F4F6F9` |
| `rfi_response` | RFI 回复 | 基于 business brief；3-4 列全宽合规矩阵 |
| `decision_memo` | 决策备忘 | 基于 business brief；Arial 基础字体 |
| `launch_messaging_guide` | 发布信息指南 | 基于 compact guide；表格可多用 |
| `contract_negotiation_brief` | 合同谈判简报 | 基于 compact guide；label-detail 1.181/5.319in |
| `grant_proposal` | 资助申请 | 基于 narrative proposal；表格留给预算/评估 |
| `neighborhood_business_proposal` | 本地商业提案 | 基于 narrative proposal |

## 关键 token（标准 business/compact/proposal 通用）

- 页面：US Letter 8.5×11in portrait；边距 1.0in；版心宽 6.5in / 9360 DXA。
- 正文：Calibri 11pt；`before=0pt`，`after=6~8pt`；行距 1.10~1.333。
- H1：16pt `#2E74B5`；H2：13pt `#2E74B5`；H3：12pt `#1F4D78`。
- 表格：全宽 9360 DXA；`tblInd=120 DXA` 对齐正文；细单线网格；表头低饱和底色（business `#F2F4F7`、compact `#E8EEF5`、proposal `#F4F6F9`）；数据区白底。
- 列表：真实 numbering definitions，不用手工 `•`/`1.`；marker 对齐 0.25in、文本 0.5in、悬挂 0.25in。
- 表上/表下引用文字用 `table_citation_text`（前后 4pt），不继承正文/题注。
- 页眉页脚：多页 polished 文档用安静标签 + 右对齐页码；`google_docs_default` 不用页眉页脚。

## 表格列宽模式

| 模式 | 列宽 | 用途 |
|---|---|---|
| One-column callout | 6.5in | 消息块、示例 |
| Compact label-detail | 1.181in / 5.319in | 术语/值、条款/立场 |
| Standard label-detail | 1.875in / 4.625in | 元信息、描述表 |
| Two-up comparison | 3.25in / 3.25in | A/B、do/don't、before/after |
| Three-column matrix | 1.5in / 2.5in / 2.5in | 决策标准、利益相关方 |
| Four-column matrix | 内容决定，合计 6.5in | 合规、预算、状态、风险 |

## 中文场景注意

- ChatGPT 预设以英文排版为主；中文正式文档优先按 Doubao Word `writing-taxonomy` 字体体系（黑体/宋体/楷体、A4、2.5cm 边距）。
- 若用户明确要"西式 memo / proposal / Google Docs 风格"，按本文件预设执行，并在交付说明中说明字体/页边距已按预设。
- 当前渲染器不支持页眉页脚/页码/自定义 numbering 定义/固定 DXA 表格；这些需要外部 Word/WPS 套版。

## 交付前核对

- [ ] 选了一个预设/别名且没有混用？
- [ ] 标题不是蓝色 underline/Word 模板残留？（google_docs_default 必须全黑）
- [ ] 表格列宽按内容分配，合计等于版心宽度？
- [ ] 列表用的是真实编号/项目符号，不是手打符号？
- [ ] 表上/表下引用文字与正文/题注区分清楚？
