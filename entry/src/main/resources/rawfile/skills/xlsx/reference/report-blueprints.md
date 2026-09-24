# 常见 Excel 报表蓝图（Report Blueprints）

面向不同交付物给出可直接套用的工作簿蓝图：**先选蓝图 → 规划 sheet/列/公式 → 写 Workbook JSON → 生成 → read_xlsx 验证**。
蓝图规定结构与公式职责；具体数值必须来自工作区资料或用户提供，禁止编造。

> **来源说明**：蓝图 7–10 直接移植自 ChatGPT 官方模板（Financial Budget / Three-Statement Forecast / Sales Pipeline / Project Tracker+Gantt）。蓝图 1–6 是**本工作模式的落地骨架**；正式分析报告模板见 Doubao `doubao-data-analysis` 的报告结构（执行摘要 → 数据说明 → 分析方法 → 数据探索 → 分析结果 → 结论建议 → 附录），视觉规范见 `format-guide.md`。

## 通用工作簿规范

- 派生值（合计/同比/占比/差异）一律公式，禁止手算数字。
- 假设类参数集中放"假设"sheet，计算区只引用假设，不写死数字。
- **分层**：`说明`（口径/来源/更新时间）→ `原始数据`（只读）→ `计算`（中间构建）→ `结论/Dashboard`（摘要）；不要把原始数据和结论混在一个 sheet。
- 每个 sheet 一表一事；表头必给、列名简短；长明细才冻结表头（`freeze:"A2"`），普通报表不默认冻结。
- 金额 `money`、比率 `percent`（存小数）、年份 `year`、数量 `int`、文本 `text`。
- 模型带 `Check`/`Checks` 勾稽表，全部 PASS 才允许 `Model Status = PASS`。
- 交付前 `read_xlsx` 抽查表名/行数/关键值/公式。

## 蓝图 1：经营月报 / 周报

适合：收入/费用/利润月度经营分析。

```
Sheet「摘要」
  核心指标表：指标 / 本月 / 上月 / 环比
  环比公式：=(B2-C2)/C2（percent）
Sheet「收入」
  收入明细：月份 / 渠道 / 金额（text / text / money）
  合计行：=SUM(C2:C9)
Sheet「费用」
  费用明细：科目 / 金额（text / money）
Sheet「利润」
  汇总表：收入合计 / 费用合计 / 利润
  利润公式：=收入!C10-费用!B10
Sheet「口径说明」
  列：口径 / 说明（text）
```

要点：摘要页全部引用明细 sheet 公式，不要复制数字。

## 蓝图 2：预算 vs 实际

适合：部门预算、项目预算、费用控制。

```
Sheet「假设」
  假设项 / 数值 / 单位：预算总盘、增长率、费率等
Sheet「预算」
  科目 / 1月 / 2月 / ... / 合计
  合计列：=SUM(B2:M2)
Sheet「实际」
  科目 / 1月 / 2月 / ... / 合计（结构与预算一致）
Sheet「差异」
  科目 / 预算合计 / 实际合计 / 差异 / 达成率
  差异：=预算!N2-实际!N2
  达成率：=实际!N2/预算!N2（percent）
```

要点：预算与实际结构完全一致，差异页才能用同一行列号引用。

## 蓝图 3：财务模型（简化版）

适合：单项目/单产品投入产出模型、经营测算。

```
Sheet「假设」
  单价 / 销量 / 变动成本率 / 固定成本 / 税率（percent 存小数）
Sheet「模型」
  收入：=假设!B2*假设!B3
  变动成本：=收入*假设!B4
  毛利：=收入-变动成本
  净利润：=毛利-假设!B5-税金
Sheet「敏感性」（可选）
  销量档位 / 对应净利润：每行引用假设销量再乘系数
```

要点：模型区只出现公式，所有可调参数在"假设"sheet。

## 蓝图 4：明细 + 汇总（SUMIF 统计）

适合：订单/流水/销售明细 + 按维度汇总。

```
Sheet「明细」
  日期 / 区域 / 渠道 / 金额（date 或 text / text / text / money）
Sheet「汇总」
  区域 / 订单数 / 金额
  订单数：=COUNTIF(明细!B:B, A2)
  金额：=SUMIF(明细!B:B, A2, 明细!D:D)
Sheet「渠道汇总」
  渠道 / 金额：=SUMIF(明细!C:C, A2, 明细!D:D)
```

要点：明细 sheet 数据中间不要插空行，避免公式区域断裂；汇总行数 = 去重后的维度数。

## 蓝图 5：项目/任务跟踪表

适合：任务清单、项目排期、跟踪台账。

```
单 Sheet「任务」
  编号 / 任务 / 负责人 / 状态 / 优先级 / 开始 / 截止 / 进度 / 备注
  formats：text / text / text / text / text / date 或 text / date 或 text / percent / text
  freeze："A2"
```

要点：进度列存小数（0.6=60%）配 percent；状态用统一词（未开始/进行中/已完成/阻塞），不要混用同义词。

## 蓝图 6：数据清单/台账

适合：客户清单、资产台账、物料清单、字典表。

```
单 Sheet「清单」
  编号 / 名称 / 分类 / 数值 / 单位 / 状态 / 备注
  formats：text / text / text / number / text / text / text
  freeze："A2"
```

要点：标识号（ID/单号/身份证）用文本存储，避免科学计数；长文本列加宽（colWidths 20~40）。

## 蓝图 7：财务预算与预测（参考 ChatGPT Financial Budget 模板）

适合：公司/部门年度预算与滚动预测。

```
Sheet「Summary」
  顶部：Selected Scenario / Actuals Through / Model Status / Currency / Units
  主指标：FY BOOKINGS / FY REVENUE / FY EBITDA / ENDING CASH / EXIT RUNWAY
  全部引用下方 Build，不复制数字
Sheet「Assumptions」
  假设项 / 数值：Opening Sales Reps / Opening Customers / Opening Cash / Avg Booking per Customer / 各项费率
Sheet「Op Build」
  按月列：Month / Period Status(Actual/Forecast) / Sales Reps / Bookings / Revenue / Opex / Cash / …
  分组行：Sales Capacity, Bookings and Recognized Revenue / Operating Expenses / Cash
Sheet「Checks」
  Check / Actual-Delta / Threshold / Status / Where to Fix
  勾稽检查：Customer roll-forward、Expense composition、Cash roll-forward
```

要点：模型必须带 Checks sheet 做机器可读的勾稽校验；`Model Status` 只允许在全部 Check PASS 时显示 PASS；没有真实假设时先向用户要，不硬填。

## 蓝图 8：三表预测（参考 ChatGPT Three-Statement Forecast 模板）

适合：有融资/估值/董事会需求的完整财务模型。

```
Sheet「Read Me」：模型说明、颜色约定、版本
Sheet「Assumptions」：全部可调参数
Sheet「Outputs >>」：核心输出页（关键指标/KPI）
Sheet「Exec Sum」：管理层摘要
Sheet「Statements >>」：IS / BS / CF 三张报表
Sheet「Builds >>」：Revenue / OpEx / HC / WC / FA & D&A / Fin, Tax & Equity 驱动构建
```

要点：三表之间必须用公式勾稽（IS 净利润 → BS 留存收益 → CF 期末现金 → BS 现金）；构建层驱动报表层，报表层只做引用；勾稽不过时在"Checks/Read Me"明确标注，不交付未校验模型。

## 蓝图 9：销售管道（参考 ChatGPT Sales Pipeline 模板）

适合：销售漏斗、管道覆盖、预测。

```
Sheet「Sales Pipeline」
  Forecast Controls：As-of Date / Forecast Horizon / Quarter Target / Stale Threshold
  Stage 概率表：Discovery 10% / Qualification 20% / Solution Fit 35% / Technical Validation 55% / …
  主指标：TOTAL OPEN PIPELINE / WEIGHTED OPEN PIPELINE / HORIZON FORECAST / PIPELINE COVERAGE / WIN RATE / AVG SALES CYCLE / OPEN DEALS / STALE OPEN DEALS
  Opportunity Portfolio 行：Company / Deal / Owner / Amount / Stage / Probability / Expected Close / Weighted Amount / Stale Flag
  加权金额：=金额*概率
  Stale Flag：=IF(距离上次活动>Stale Threshold,"Stale","")
```

要点：Stage/Probability 做成"控制参数"，加权金额和 Stale Flag 全部公式驱动；预置空行保持 blank-safe。

## 蓝图 10：项目计划与周 Gantt（参考 ChatGPT Project Tracker 模板）

适合：带周甘特视图的项目跟踪。

```
Sheet「Project Plan」
  PROJECT PROFILE：Project Title / Company Name / Project Manager / Timeline Start
  LAUNCH PULSE：TOTAL TASKS / COMPLETE / IN PROGRESS / AT RISK / P0 TASKS
  WORKSTREAM PLAN：Workstream / Task / Owner / Status / Priority / Start Date / End Date / Days
  GANTT — 20-WEEK VIEW：每周一列，任务起止周打 1
```

要点：状态用统一词（Complete / In Progress / At Risk / Not Started）；P0 任务数用 COUNTIF；甘特用每列 1 标记任务在该周覆盖；周列用 date 格式。

## 蓝图 11：数据分析 / 诊断报告式工作簿（参考 Doubao doubao-data-analysis 报告结构）

适合：从数据出发给结论的分析交付，不只是“一张表”。按报告结构组织 sheet，让审查者能顺着“结论 → 依据 → 方法 → 数据 → 附录”复查。

```
Sheet「执行摘要」
  核心结论 / 关键数字 / 建议（每项结论写“依据见哪个 sheet/行”）
Sheet「数据说明」
  数据来源 / 口径 / 时间范围 / 单位 / 已知缺失与限制（text）
Sheet「分析方法」
  清洗规则 / 指标定义 / 分组与筛选口径（text）
Sheet「数据探索」
  原始/清洗后关键维度的行数与异常清单（只读，不手改）
Sheet「分析结果」
  按问题组织的指标与交叉表；派生值全部公式，结论列引用对应 sheet
Sheet「结论建议」
  结论 / 置信度 / 建议动作 / 责任人（text）
Sheet「附录」
  明细表、公式说明、来源清单（行式数据可带“来源”列）
```

要点：
- **每一页结论都能指回依据**：执行摘要和结论建议里的每条判断，注明“依据：分析结果!B2”或具体 sheet/行。
- **口径先定后算**：收入=含税/不含税、用户=去重/活跃等口径写进「数据说明」，不要在结论页临时解释。
- **缺失值不编造**：数据缺失、口径未确认时，在「数据说明」和结论里显式标注，不用推算值充数。
- **异常要入附录台账**：会改变主数字/可信度的异常按“发现 → 原值 → 重算/证据 → 影响”记录。

## 从蓝图到 Workbook 的步骤

1. 选蓝图 → 按实际字段增删列/sheet（每个 sheet 一表一事）。
2. 先定"哪些是原始录入、哪些是派生值"：派生值全部公式。
3. 假设/参数集中放"假设"sheet（涉及模型时）。
4. 写 Workbook JSON（长表用 workbook_file 分块写）。
5. 生成后 `read_xlsx` 抽查：表名、行数、关键值、公式是否保留。
