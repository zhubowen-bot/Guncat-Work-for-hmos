# 常见 Word 文档蓝图（Document Blueprints）

面向不同交付物给出可直接套用的结构蓝图：**先选蓝图 → 规划章节 → 写 Doc JSON → 生成 → 自检**。
蓝图规定章节与信息职责，具体内容/数据必须来自工作区资料，禁止编造。

> **来源说明**：蓝图 6–8 直接移植自 ChatGPT 官方模板（Design Report / Experiment Analysis / Investment Committee Memo），可放心保留。蓝图 1–5 是**本工作模式的落地骨架**，不是某个平台原文；涉及正式公文、合同、研究报告、论文等专业文体时，必须先读 `professional-docs.md`（已按 Doubao word 各文体指南校准），以其中的权威格式规则为准，本蓝图只提供章节组织参考。

## 通用文档骨架（所有正式文档）

```
封面（可选，正式对外建议加）   title + subtitle + author + date
目录（≥8 块 / 章节 ≥3 时建议加）  H1 章节
H1 章节（一个主题）
  H2 小节（一个论点）
    段落（一段一个观点）
    表格 / 图片（证据与数据）
  H2 …
H1 结论与下一步
```

- 标题是结论句，不用"情况说明"这类空泛词。
- 表格只放"行×列可比较"的数据；单元格成段就改回 prose/list。
- 所有数据来源写 caption 或文末来源表。

## 蓝图 1：商务报告 / 经营分析

适合：经营分析报告、月报/季报、业务复盘。

```
H1 摘要（结论先行，3~5 条）
H1 总体经营情况
  H2 核心指标（table：计划/实际/同比）
  H2 趋势分析（图片/表格 + 解读段落）
H1 问题与归因
  H2 主要问题（list，每条含数据）
  H2 根因分析（段落 + 因果链）
H1 下阶段计划
  H2 目标（list/table）
  H2 行动项（有序 list：时间+负责人）
H1 附录：口径与来源（table）
```

- style：default；正式对外加 cover+toc。
- 图表类图片用 write_svg 或 write_pptx 导出后引用，来源写 caption。

## 蓝图 2：方案 / 提案

适合：项目方案、立项报告、产品方案、解决方案。

```
H1 背景与目标
  H2 现状与问题
  H2 目标与非目标（list）
H1 方案设计
  H2 总体思路（段落）
  H2 关键设计（table：模块/职责/说明）
  H2 流程/架构（图片，建议 write_svg）
H1 实施计划
  H2 里程碑（table：阶段/时间/交付物）
  H2 资源与风险（list）
H1 结论与请示事项
```

- style：default 或 minimal；对内方案 minimal 即可，对外 default + cover。

## 蓝图 3：会议纪要

适合：周会、项目例会、评审会、客户会。

```
H1 会议信息（table：时间/地点/参会人/记录人）
H1 议题与结论
  H2 议题一（结论加粗 + 讨论要点 + 待办）
  H2 议题二…
H1 待办事项（table：事项/负责人/截止时间）
H1 下次会议（可选：时间/议题）
```

- style：default；无封面/目录；决议加粗。
- 待办必须能执行：有动词、有负责人、有截止时间。

## 蓝图 4：论文 / 学术文档

适合：课程论文、文献综述、研究报告、投稿草稿。

```
H1 摘要（一段话：背景/方法/结果/结论）
H1 引言（问题背景 → 研究空白 → 本文贡献）
H1 相关工作（文献综述，按主题/时间组织）
H1 方法（理论框架 → 方法设计 → 数据来源）
H1 结果与分析（数据/图表 → 结果解释）
H1 讨论与结论（局限 → 展望 → 结论）
H1 参考文献（表格列引用：作者/标题/出处/年份）
```

- style：academic；章节编号可用"1/1.1"或"一/（一）"，全文统一。
- 引用必须真实，禁止编造文献；需要核实时用 `web_search`/`web_fetch`。

## 蓝图 5：操作手册 / 工作手册

适合：SOP、用户手册、新人指南、规章制度。

```
H1 目的与适用范围
H1 前置条件（list：账号/权限/工具）
H1 操作流程
  H2 流程一（有序 list 步骤 + 截图/图示）
  H2 流程二…
H1 常见问题（table：现象/原因/处理）
H1 附录（名词表、快捷键、模板）
```

- style：minimal 或 default；步骤必须可验证：每步有操作对象和预期结果。
- 图示用 write_svg 生成，真实截图来自工作区。

## 蓝图 6：设计/研究报告（参考 ChatGPT Design Report 模板）

适合：研究结论 + 证据 + 建议的报告。

```
H1 Executive Summary（结论先行；At a glance / Introduction）
H1 Key Findings（Context and conditions / Patterns in the evidence / Implications）
H1 Recommendations（建议按序：Clarify → Sequence → Review；Conclusion）
H1 Appendix（Notes / Source placeholders）
```

- 样式：default + cover + toc；表格用 `主题/观察/影响` 三列（Theme/Observation/Implication）。
- 来源占位符不能编造：`[Author or organization]. [Source title]. [Publisher], [Year].`

## 蓝图 7：实验分析报告（参考 ChatGPT Experiment Analysis 模板）

适合：A/B 实验、效果评估、数据决策。

```
H1 Document Control（Version / Prepared By / Reviewers / Date）
H1 Purpose
H1 Business Context
H1 Experiment Summary
H1 Design Notes（实验设计、随机/排除/运行时）
H1 Hypothesis（if/then：control/treatment/audience/指标方向/机制）
H1 Success Criteria（主指标 + guardrail + 决策阈值）
H1 Pre-Launch Validation
H1 Sample and Exposure Summary
H1 Primary Outcome（主指标结果、显著性、效应量）
H1 Guardrail Metrics（每项 pass/fail）
H1 Segment Results（确认性 vs 方向性）
H1 Data Quality and Limitations
H1 Interpretation（结果→业务影响→决策姿态）
H1 Decision Log / Post Test Actions
H1 Appendix A: Metric Definitions / Appendix B: Analyst Notes
```

- 表格：`版本/作者/评审`、`指标与阈值`、`Variant A/B 对比`、`Guardrail Pass/Fail`、`Segment 对比`。
- 禁止编造实验数字；没有结果时保留占位并说明需要数据。

## 蓝图 8：投资委员会备忘录（参考 ChatGPT Investment Committee Memo 模板）

适合：投资决策、投委会材料、审批备忘录。

```
H1 1. Executive Summary, Recommendation, and Decision Requested
  H2 Decision and exposure（Current Commitment / Amount Requested Now / Future capital / Total Potential Exposure）
  H2 Underwriting at a glance（Why invest / What supports / What could break / Do terms compensate）
H1 2. Investment Thesis（每个 thesis：We believe…supported by…requires…）
H1 3. Company and Product（Business overview / Product and customer value / Customer and use case）
H1 4. Market and Competition（Market / Competitive position / Moats）
H1 5. Financial Review（Historical / Forecast / Unit economics）
H1 6. Risk and Mitigations（Key risks / Mitigations）
H1 7. Return and Exit（Scenario table：Low/Base/High）
H1 8. Conditions, Approvals, and Next Steps
```

- 表格：资本构成/授权/时序/是否计入收益；敏感性 Low/Base/High。
- 推荐必须明确 `Approve / decline / defer`；关键数字全部有 as-of 日期。

## 从蓝图到 Doc 的步骤

1. 选蓝图 → 按任务增删章节（H1 下至少 2 个 H2）。
2. 每章写一句话任务，写不出就删章。
3. 数据/引用先确认来源；图片路径先 list_files 确认。
4. 写 Doc JSON（长文用 doc_file 分块写）。
5. 生成后 read_docx 抽查 + 按 SKILL.md 自检清单复验。
