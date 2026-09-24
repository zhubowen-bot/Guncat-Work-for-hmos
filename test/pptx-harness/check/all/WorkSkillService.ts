// WorkSkillService: 工作模式的「技能」注册与加载
// 技能 = 打包在 rawfile/skills/<id>/ 下的领域操作指南(SKILL.md + reference/*.md)。
// 对齐 Agent Skills 的渐进披露设计: 系统提示词只保留一句触发提示(前缀稳定),
// 模型通过 list_skills 看到技能清单, 需要时用 load_skill 按文件加载正文。
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Constants } from './Constants.ts';
import { ToolRegistry, SkillMeta, SkillFileMeta } from './ToolRegistry.ts';
import { SkillDirectoryFormatter } from './SkillDirectoryFormatter.ts';

// 技能可加载的文件
export class SkillFileInfo {
  file: string = '';        // 相对技能目录的路径(SKILL.md 或 reference/xxx.md)
  desc: string = '';        // 一句话说明
}

// 已注册技能
export class SkillInfo {
  id: string = '';
  name: string = '';
  description: string = ''; // 触发语义: 什么任务应该加载该技能
  files: SkillFileInfo[] = [];
}

export class WorkSkillService {
  // 技能是否已同步进 ToolRegistry(skill 作为首类插件)
  private static skillsSynced: boolean = false;

  private static ensureToolSkills(): void {
    if (WorkSkillService.skillsSynced) {
      return;
    }
    let list: SkillInfo[] = WorkSkillService.registry();
    for (let i: number = 0; i < list.length; i++) {
      let s: SkillInfo = list[i];
      let meta: SkillMeta = new SkillMeta();
      meta.id = s.id;
      meta.name = s.name;
      meta.description = s.description;
      for (let f: number = 0; f < s.files.length; f++) {
        let fm: SkillFileMeta = new SkillFileMeta();
        fm.file = s.files[f].file;
        fm.desc = s.files[f].desc;
        meta.files.push(fm);
      }
      ToolRegistry.registerSkill(meta);
    }
    WorkSkillService.skillsSynced = true;
  }

  // ===== 技能注册表(新增技能: 在 rawfile/skills/<id>/ 放文档 + 在此登记) =====
  private static registry(): SkillInfo[] {
    let list: SkillInfo[] = [];
    let ppt: SkillInfo = new SkillInfo();
    ppt.id = 'ppt';
    ppt.name = 'PPT 制作与编辑';
    ppt.description = '制作/修改/美化演示文稿(.pptx)时加载，V3 全量加载所有 reference：Deck JSON 完整语法(13 种版式/图表/表格/图片/备注/背景装饰)、' +
      '8 套主题 + themeOverride 多色混搭、视觉风格目录(科技/古风/简约/杂志/商务/学术/路演)与每页内容配图(流程图/时间轴/架构图/插画/信息图)、设计规范、内容纪律与自检报告。' +
      '任何 write_pptx / read_ppt / edit_ppt 任务开始前先 load_skill("ppt") 全量加载；新建 PPT 前须 ask_user_question 前置提问；默认 20 页以上；每页装饰 + 内容配图；交付前写 ppt_qa_report.md。';
    let f1: SkillFileInfo = new SkillFileInfo();
    f1.file = 'reference/deck-dsl.md';
    f1.desc = 'Deck JSON 完整字段定义与示例';
    let f2: SkillFileInfo = new SkillFileInfo();
    f2.file = 'reference/design-guide.md';
    f2.desc = '页面设计规范与场景建议';
    let f3: SkillFileInfo = new SkillFileInfo();
    f3.file = 'reference/themes.md';
    f3.desc = '主题预设清单与自定义主题';
    let f4: SkillFileInfo = new SkillFileInfo();
    f4.file = 'reference/troubleshooting.md';
    f4.desc = '常见问题排查（症状→修复）';
    let f5: SkillFileInfo = new SkillFileInfo();
    f5.file = 'reference/deck-blueprints.md';
    f5.desc = '常见演示文稿蓝图：经营复盘/商业计划/技术分享/培训/路演页面节奏';
    let f6: SkillFileInfo = new SkillFileInfo();
    f6.file = 'reference/visual-components.md';
    f6.desc = 'PPT 视觉组件目录：指标区/对比/SWOT/雷达/漏斗/甘特/时间线/飞轮/分层架构';
    let f7: SkillFileInfo = new SkillFileInfo();
    f7.file = 'reference/style-guidelines.md';
    f7.desc = 'ChatGPT 演示文稿风格指南：沟通任务/叙事弧/文案/构图纪律/字号下限';
    let f8: SkillFileInfo = new SkillFileInfo();
    f8.file = 'reference/visual-styles.md';
    f8.desc = '视觉风格目录与装饰配方：科技/古风/简约/杂志/商务/学术/路演 + 纹理/勾边/花色 SVG 骨架';
    ppt.files.push(f1);
    ppt.files.push(f2);
    ppt.files.push(f3);
    ppt.files.push(f4);
    ppt.files.push(f5);
    ppt.files.push(f6);
    ppt.files.push(f7);
    ppt.files.push(f8);
    list.push(ppt);
    let docx: SkillInfo = new SkillInfo();
    docx.id = 'docx';
    docx.name = 'Word 文档制作与编辑';
    docx.description = '制作/修改 Word 文档(.docx)时加载，V3 全量加载所有 reference：Doc JSON 完整语法(封面/目录/分级标题/正文/列表/表格/图片/引用/代码块)、' +
      '三种样式预设、中文排版规范、文档形态选型与表格门禁、专业文书规范、自检报告。任何 write_docx / read_docx / edit_docx 任务开始前先 load_skill("docx") 全量加载；新建文档前须 ask_user_question 前置提问；交付前写 docx_qa_report.md。';
    let d1: SkillFileInfo = new SkillFileInfo();
    d1.file = 'reference/doc-dsl.md';
    d1.desc = 'Doc JSON 完整字段定义与示例';
    let d2: SkillFileInfo = new SkillFileInfo();
    d2.file = 'reference/design-guide.md';
    d2.desc = '中文文档排版规范与场景建议';
    let d3: SkillFileInfo = new SkillFileInfo();
    d3.file = 'reference/troubleshooting.md';
    d3.desc = '常见问题排查（症状→修复）';
    let d4: SkillFileInfo = new SkillFileInfo();
    d4.file = 'reference/document-blueprints.md';
    d4.desc = '常见 Word 文档蓝图：商务报告/方案/纪要/论文/操作手册结构';
    let d5: SkillFileInfo = new SkillFileInfo();
    d5.file = 'reference/professional-docs.md';
    d5.desc = '专业文书规范：公文/合同/研究报告/新闻稿/技术交底书结构与 Doc JSON 建议';
    let d6: SkillFileInfo = new SkillFileInfo();
    d6.file = 'reference/chatgpt-design-presets.md';
    d6.desc = 'ChatGPT 官方文档设计预设：memo/RFI/提案/决策备忘/指南的 token 级排版参考';
    docx.files.push(d1);
    docx.files.push(d2);
    docx.files.push(d3);
    docx.files.push(d4);
    docx.files.push(d5);
    docx.files.push(d6);
    list.push(docx);
    let xlsx: SkillInfo = new SkillInfo();
    xlsx.id = 'xlsx';
    xlsx.name = 'Excel 表格制作与编辑';
    xlsx.description = '制作/修改/分析 Excel 表格(.xlsx)时加载，V3 全量加载所有 reference：Workbook JSON 完整语法(多工作表/表头/公式/数字格式/列宽/冻结窗格)、' +
      '表格规范(公式优先/数字格式矩阵/负数与零值显示/假设区与模型区分离)、数据分析与报表交付链路、编辑完整性规则与自检报告。任何 write_xlsx / read_xlsx / edit_xlsx 任务开始前先 load_skill("xlsx") 全量加载；新建工作簿前须 ask_user_question 前置提问；交付前写 xlsx_qa_report.md。';
    let x1: SkillFileInfo = new SkillFileInfo();
    x1.file = 'reference/workbook-dsl.md';
    x1.desc = 'Workbook JSON 完整字段定义与示例';
    let x2: SkillFileInfo = new SkillFileInfo();
    x2.file = 'reference/format-guide.md';
    x2.desc = '表格规范: 公式优先/数字格式/财务配色/编辑完整性';
    let x3: SkillFileInfo = new SkillFileInfo();
    x3.file = 'reference/troubleshooting.md';
    x3.desc = '常见问题排查（症状→修复）';
    let x4: SkillFileInfo = new SkillFileInfo();
    x4.file = 'reference/report-blueprints.md';
    x4.desc = '常见 Excel 报表蓝图：经营月报/预算/财务模型/明细汇总/任务跟踪/台账';
    let x5: SkillFileInfo = new SkillFileInfo();
    x5.file = 'reference/analysis-playbook.md';
    x5.desc = '数据分析玩法：趋势/对比/构成/异常归因/敏感性/口径审计';
    xlsx.files.push(x1);
    xlsx.files.push(x2);
    xlsx.files.push(x3);
    xlsx.files.push(x4);
    xlsx.files.push(x5);
    list.push(xlsx);
    let svg: SkillInfo = new SkillInfo();
    svg.id = 'svg';
    svg.name = 'SVG 矢量绘图（生图）';
    svg.description = '需要生成图片——图标、徽标、示意图、流程图、架构图、信息图、插画、装饰图形——或任务要求"画图/生图/出图/配图"而工作区没有现成素材时加载: SVG 绘制规范(视框/描边风格/配色/文字处理)、"生成→预览→修正"工作流、可视化类型选择、可直接套用的配方。任何 write_svg 任务开始前先加载。';
    let s1: SkillFileInfo = new SkillFileInfo();
    s1.file = 'reference/svg-craft.md';
    s1.desc = '绘制规范: 视框/网格/path优先/文字风险/配色纪律';
    let s2: SkillFileInfo = new SkillFileInfo();
    s2.file = 'reference/svg-recipes.md';
    s2.desc = '可套用模板: 描边图标/流程图/架构图/信息图卡片/柱状对比/时间轴/封面装饰';
    let s3: SkillFileInfo = new SkillFileInfo();
    s3.file = 'reference/infographic-blueprints.md';
    s3.desc = '常见信息图蓝图: 对比/流程/时间线/架构/KPI卡/机制因果';
    svg.files.push(s1);
    svg.files.push(s2);
    svg.files.push(s3);
    list.push(svg);
    let data: SkillInfo = new SkillInfo();
    data.id = 'data';
    data.name = '数据清洗与转换';
    data.description = '处理表格/结构化数据时加载——CSV/JSON 清洗、去重、拆列、正则提取、' +
      '格式互转(CSV/TSV/JSON/Markdown 表格/XLSX)、大文件本地转换, 或任何 transform_file 任务开始前: ' +
      '管道 ops 与表达式完整语法、场景配方、能力边界(无分组聚合/merge/concat, 替代方案见技能正文)、限额与自检清单。';
    list.push(data);
    // ===== 五个专家智能体的 prompt 注册为技能(prompt 原文在 skills/<id>/SKILL.md) =====
    let paper: SkillInfo = new SkillInfo();
    paper.id = 'paper';
    paper.name = '论文改写与学术化';
    paper.description = '把综述/散文/笔记/报告/讲义/对话/博客等非论文文体改写为规范学术论文, 或论文扩写/润色/重构时加载: ' +
      '源文体诊断、八项改写参数(论文类型/改写模式/扩充策略/学术深度/字数策略/引用格式/语言风格/输出粒度)、' +
      '分文体改写策略与质量自检清单。';
    list.push(paper);
    let law: SkillInfo = new SkillInfo();
    law.id = 'law';
    law.name = '国企法律事务分析';
    law.description = '分析企业法律案例/纠纷并输出结构化法律意见书时加载, 尤其国企国资监管、股权转让、合同纠纷、合规与责任认定: ' +
      '合同解释五法、法理分析工具箱、六条深度推理链、法律时效性铁律与法律意见书模板。';
    list.push(law);
    let research: SkillInfo = new SkillInfo();
    research.id = 'research';
    research.name = '深度研究与多轮验证';
    research.description = '对任何主题做事实核查、深度调研、多源交叉验证并产出结构化研究报告时加载: ' +
      '4-6 轮检索验证流程、术语精细辨析、多源体系化解释、分析工具箱(因果链/利益相关方/反事实推演等)与研究报告模板。';
    list.push(research);
    let sift: SkillInfo = new SkillInfo();
    sift.id = 'sift';
    sift.name = '信息溯源与AI内容过滤';
    sift.description = '查询"最新版本/最新状态/排名对比"等时效敏感信息, 需甄别AI生成内容与营销文、锚定官方一手来源时加载: ' +
      '九步深度搜索法(官方渠道溯源→实体状态锚定→AI内容识别过滤→整合输出)、来源分级与时效标记规范。';
    list.push(sift);
    let llmEval: SkillInfo = new SkillInfo();
    llmEval.id = 'llm-eval';
    llmEval.name = '大模型评测与选型分析';
    llmEval.description = '对比/评估/选型大模型时加载——"XX相当于什么模型""XX与YY谁强""推荐哪个模型"、benchmark分数解读、模型推荐: ' +
      '信源分级(Tier 1-6)与引用前检查门、版本时间戳校验与跨版本比较禁令、代际确认与知识库对标约束、能力维度拆解(代码能力主权重)、对标类问题强制自检清单。';
    let le1: SkillFileInfo = new SkillFileInfo();
    le1.file = 'reference/capability-alignment.md';
    le1.desc = 'Step 5-8: 模型代际确认与知识库对标约束、能力维度拆解与差距量化、场景化选型、版本模式标注';
    let le2: SkillFileInfo = new SkillFileInfo();
    le2.file = 'reference/output-checklist.md';
    le2.desc = 'Step 9-12: 生态位与性价比分析、认知误区纠正、自检清单、结构化输出规范';
    llmEval.files.push(le1);
    llmEval.files.push(le2);
    list.push(llmEval);
    // ===== 2026-09-17 四平台参考移植新增（见 SKILL_PORTING_REPORT.md） =====
    let humanizer: SkillInfo = new SkillInfo();
    humanizer.id = 'humanizer';
    humanizer.name = '去 AI 味与拟人化改写';
    humanizer.description = '去除 AI 写作痕迹、让文本更自然更像真人、或做拟人化/可读性改写时加载: ' +
      '24 项通用 AI 模式库(空洞拔高/宣传腔/模糊归因/规则三连/破折号滥用等)、社媒 16 项检测清单、' +
      '结论先行/不造术语/分层交付输出规范。触发词: 去 AI 味、AI 味太重、太像 AI 写的、自然一点、像人写的。';
    let h2: SkillFileInfo = new SkillFileInfo();
    h2.file = 'reference/general-patterns-2.md';
    h2.desc = '24 项通用 AI 模式（第二部分：风格/沟通/填充与完整示例）';
    let h3: SkillFileInfo = new SkillFileInfo();
    h3.file = 'reference/social-media.md';
    h3.desc = '社媒 16 项 AI 味检测清单与评级（de-AI writing 完整版）';
    let h4: SkillFileInfo = new SkillFileInfo();
    h4.file = 'reference/readability.md';
    h4.desc = '输出可读性完整规范：结论先行/不造术语/分层交付/不暴露写作规则';
    humanizer.files.push(h2);
    humanizer.files.push(h3);
    humanizer.files.push(h4);
    list.push(humanizer);
    let promptEng: SkillInfo = new SkillInfo();
    promptEng.id = 'prompt-engineering';
    promptEng.name = '提示词工程';
    promptEng.description = '撰写/优化/调试 AI 提示词、系统提示词、自定义指令或 Agent 技能说明时加载: ' +
      '清晰直接原则、CoT/few-shot/XML/角色/预填充/提示链技巧、评测用例、反模式识别与上下文预算。' +
      '触发词: 写提示词、优化提示词、prompt、系统提示词、让 AI 更听话。';
    let pe2: SkillFileInfo = new SkillFileInfo();
    pe2.file = 'reference/BEST_PRACTICES.md';
    pe2.desc = '提示词最佳实践全文';
    let pe3: SkillFileInfo = new SkillFileInfo();
    pe3.file = 'reference/TECHNIQUES.md';
    pe3.desc = '提示词进阶技巧全文';
    let pe4: SkillFileInfo = new SkillFileInfo();
    pe4.file = 'reference/TROUBLESHOOTING.md';
    pe4.desc = '提示词排查全文';
    let pe5: SkillFileInfo = new SkillFileInfo();
    pe5.file = 'reference/EXAMPLES.md';
    pe5.desc = '提示词示例集';
    let pe6: SkillFileInfo = new SkillFileInfo();
    pe6.file = 'reference/START_HERE.md';
    pe6.desc = '提示词工程入门入口';
    let pe7: SkillFileInfo = new SkillFileInfo();
    pe7.file = 'reference/GETTING_STARTED.md';
    pe7.desc = '快速上手';
    let pe8: SkillFileInfo = new SkillFileInfo();
    pe8.file = 'reference/SUMMARY.md';
    pe8.desc = '技能摘要';
    let pe9: SkillFileInfo = new SkillFileInfo();
    pe9.file = 'reference/INDEX.md';
    pe9.desc = '技能索引';
    let pe10: SkillFileInfo = new SkillFileInfo();
    pe10.file = 'reference/CLAUDE.md';
    pe10.desc = 'Claude/Agent 使用说明';
    promptEng.files.push(pe2);
    promptEng.files.push(pe3);
    promptEng.files.push(pe4);
    promptEng.files.push(pe5);
    promptEng.files.push(pe6);
    promptEng.files.push(pe7);
    promptEng.files.push(pe8);
    promptEng.files.push(pe9);
    promptEng.files.push(pe10);
    list.push(promptEng);
    let pdfSkill: SkillInfo = new SkillInfo();
    pdfSkill.id = 'pdf';
    pdfSkill.name = 'PDF 文档处理';
    pdfSkill.description = '处理 PDF 的读取/搜索/扫描件阅读时加载: parse_document 按页解析、search_pdf 定位关键词、' +
      'pdf_to_images + view_image 读扫描件/版式，长 PDF 分块与目标定位策略，能力边界(不创建/编辑/合并/水印/填表)。' +
      '触发词: 读 PDF、解析 PDF、PDF 里找 XX、扫描件 PDF、提取 PDF 文字。';
    let pdf0t: SkillFileInfo = new SkillFileInfo();
    pdf0t.file = 'reference/tool-notes.md';
    pdf0t.desc = '本项目工具映射/工作流/能力边界（适配层）';
    pdfSkill.files.push(pdf0t);
    list.push(pdfSkill);
    let translationSkill: SkillInfo = new SkillInfo();
    translationSkill.id = 'translation';
    translationSkill.name = '翻译与术语一致性';
    translationSkill.description = '将中文法律文书翻译为英文或中英双语、执行术语审校与一致性检查、生成双语对照 Word 时加载（原始移植自 legal-translation）：先建术语表、法域/术语/编号/数字一致性、双语 Word 交付。' +
      '医学文献翻译可另加载 medical-* 参考。触发词: 翻译法律文书、审校法律英译、起草英文版、制作双语 Word、统一术语。';
    let tr3: SkillFileInfo = new SkillFileInfo();
    tr3.file = 'reference/medical-1.md';
    tr3.desc = '医学文献翻译完整技能（1/5）：来源与范围/核验正文/分段翻译';
    let tr4: SkillFileInfo = new SkillFileInfo();
    tr4.file = 'reference/medical-2.md';
    tr4.desc = '医学文献翻译完整技能（2/5）：聊天直出';
    let tr5: SkillFileInfo = new SkillFileInfo();
    tr5.file = 'reference/medical-3.md';
    tr5.desc = '医学文献翻译完整技能（3/5）：门槛A最小格式与表图校验';
    let tr6: SkillFileInfo = new SkillFileInfo();
    tr6.file = 'reference/medical-4.md';
    tr6.desc = '医学文献翻译完整技能（4/5）：写入飞书';
    let tr7: SkillFileInfo = new SkillFileInfo();
    tr7.file = 'reference/medical-5.md';
    tr7.desc = '医学文献翻译完整技能（5/5）：门槛B与最终交付';
    translationSkill.files.push(tr3);
    translationSkill.files.push(tr4);
    translationSkill.files.push(tr5);
    translationSkill.files.push(tr6);
    translationSkill.files.push(tr7);
    list.push(translationSkill);
    // ===== 2026-09-17 R3 新增：questionnaire（Doubao 完整移植） =====
    let questionnaire: SkillInfo = new SkillInfo();
    questionnaire.id = 'questionnaire';
    questionnaire.name = '问卷与用户研究';
    questionnaire.description = '设计问卷/访谈提纲、开放题原声打标、定量问卷分析时加载（完整移植自 doubao-questionnaire-designer）：' +
      'M1 问卷设计、M2 深访提纲、M3 原声编码、M4 定量分析；交付用 write_docx/write_xlsx。' +
      '触发词: 设计问卷、写问卷、满意度调研、NPS、访谈提纲、深访提纲、开放题打标、VOC 分析、问卷分析。';
    let q1: SkillFileInfo = new SkillFileInfo();
    q1.file = 'references/m1-questionnaire-design.md';
    q1.desc = 'M1 问卷设计完整细则';
    let q2: SkillFileInfo = new SkillFileInfo();
    q2.file = 'references/m2-interview-outline.md';
    q2.desc = 'M2 访谈提纲完整细则';
    let q3: SkillFileInfo = new SkillFileInfo();
    q3.file = 'references/m3-verbatim-tagging.md';
    q3.desc = 'M3 开放题原声打标完整细则';
    let q4: SkillFileInfo = new SkillFileInfo();
    q4.file = 'references/m4-quantitative-analysis.md';
    q4.desc = 'M4 定量问卷分析完整细则';
    let q5: SkillFileInfo = new SkillFileInfo();
    q5.file = 'CHANGELOG.md';
    q5.desc = '技能版本变更记录';
    questionnaire.files.push(q1);
    questionnaire.files.push(q2);
    questionnaire.files.push(q3);
    questionnaire.files.push(q4);
    questionnaire.files.push(q5);
    list.push(questionnaire);
    // ===== 2026-09-17 R5 新增：content-rewrite（Doubao 完整移植） =====
    let contentRewrite: SkillInfo = new SkillInfo();
    contentRewrite.id = 'content-rewrite';
    contentRewrite.name = '多平台内容改写分发';
    contentRewrite.description = '把已有母稿/素材改写成可发布的多平台版本（公众号/短视频/微博/小红书等≥2平台分发、单平台有素材改写）时加载：' +
      '完整移植自 doubao-multiplatform-rewrite，含母稿资产化、平台语法、分发包结构、排版 SSOT、事实与合规红线。' +
      '触发词: 一稿多发、多平台分发、内容矩阵、跨平台改写、分发执行包、改成公众号版/短视频版/微博版/小红书版。';
    let cr1: SkillFileInfo = new SkillFileInfo();
    cr1.file = 'references/common/cover-design-methodology.md';
    cr1.desc = '封面与图片设计方法（完整原文）';
    let cr2: SkillFileInfo = new SkillFileInfo();
    cr2.file = 'references/common/distribution-package-format.md';
    cr2.desc = '分发包文档骨架/模块顺序/图片放置（完整原文）';
    let cr3: SkillFileInfo = new SkillFileInfo();
    cr3.file = 'references/common/fact-check-and-compliance.md';
    cr3.desc = '事实核查与合规边界（完整原文）';
    let cr4: SkillFileInfo = new SkillFileInfo();
    cr4.file = 'references/common/image-generation.md';
    cr4.desc = '生图策略/提示词/质检（完整原文，适配为 SVG 或用户供图）';
    let cr5: SkillFileInfo = new SkillFileInfo();
    cr5.file = 'references/common/internet-search.md';
    cr5.desc = '联网判断/query 拆分/结果沉淀（完整原文，对应 search_web）';
    let cr6: SkillFileInfo = new SkillFileInfo();
    cr6.file = 'references/common/output-standard.md';
    cr6.desc = '唯一通用排版 SSOT（完整原文）';
    let cr7: SkillFileInfo = new SkillFileInfo();
    cr7.file = 'references/common/source-analysis.md';
    cr7.desc = '母稿拆解/素材补全/事实边界（完整原文）';
    let cr8: SkillFileInfo = new SkillFileInfo();
    cr8.file = 'references/platforms/short-video.md';
    cr8.desc = '短视频平台改写细则（完整原文）';
    let cr9: SkillFileInfo = new SkillFileInfo();
    cr9.file = 'references/platforms/wechat.md';
    cr9.desc = '微信公众号改写细则（完整原文）';
    let cr10: SkillFileInfo = new SkillFileInfo();
    cr10.file = 'references/platforms/weibo.md';
    cr10.desc = '微博改写细则（完整原文）';
    let cr11: SkillFileInfo = new SkillFileInfo();
    cr11.file = 'references/platforms/xhs.md';
    cr11.desc = '小红书改写细则（完整原文）';
    contentRewrite.files.push(cr1);
    contentRewrite.files.push(cr2);
    contentRewrite.files.push(cr3);
    contentRewrite.files.push(cr4);
    contentRewrite.files.push(cr5);
    contentRewrite.files.push(cr6);
    contentRewrite.files.push(cr7);
    contentRewrite.files.push(cr8);
    contentRewrite.files.push(cr9);
    contentRewrite.files.push(cr10);
    contentRewrite.files.push(cr11);
    list.push(contentRewrite);
    // ===== 2026-09-17 R7 新增：html（Doubao 完整移植） =====
    let htmlSkill: SkillInfo = new SkillInfo();
    htmlSkill.id = 'html';
    htmlSkill.name = '单页 HTML 开发';
    htmlSkill.description = '设计/生成/修改可直接在浏览器打开的单页 HTML（官网/落地页/营销页、数据看板/信息图/长图、动画/3D/小游戏、UI 高保真/可交互原型、轻量小工具）时加载：' +
      '完整移植自 doubao html，含单文件自包含规范、视觉与防 AI slop 红线、响应式、visual/3D 技法。' +
      '触发词: 做个网页、写个 HTML、落地页、单页、HTML 页面、数据看板网页、交互原型。';
    let ht1: SkillFileInfo = new SkillFileInfo();
    ht1.file = 'references/frontend-design.md';
    ht1.desc = '前端视觉方向确立（完整原文）';
    let ht2: SkillFileInfo = new SkillFileInfo();
    ht2.file = 'references/visual-techniques.md';
    ht2.desc = '动效/Canvas/WebGL/进阶排印/材质/地图/音频技法（完整原文）';
    let ht3: SkillFileInfo = new SkillFileInfo();
    ht3.file = 'references/3d-design.md';
    ht3.desc = '3D 场景设计方法（完整原文）';
    let ht4: SkillFileInfo = new SkillFileInfo();
    ht4.file = 'references/chart-atlas.md';
    ht4.desc = '图表可视化参考（完整原文）';
    htmlSkill.files.push(ht1);
    htmlSkill.files.push(ht2);
    htmlSkill.files.push(ht3);
    htmlSkill.files.push(ht4);
    list.push(htmlSkill);
    // ===== 2026-09-17 R9 新增：paper-reviewer + review-agent（文档型完整移植） =====
    let paperReviewer: SkillInfo = new SkillInfo();
    paperReviewer.id = 'paper-reviewer';
    paperReviewer.name = '学术论文审稿';
    paperReviewer.description = '以顶会审稿人标准对学术论文进行系统评审并输出 OpenReview 风格 review 时加载（完整移植自 workbuddy paper-reviewer）：' +
      '五维度证据化分析、分学科检查清单、Summary/Strengths/Weaknesses/Questions/Score/Confidence。' +
      '触发词: 审论文、论文评审、写评审意见、review this paper、peer review、rebuttal 前自查。';
    let pr1: SkillFileInfo = new SkillFileInfo();
    pr1.file = 'references/review-criteria.md';
    pr1.desc = '五维度评审细则与分学科检查清单（完整原文）';
    let pr2: SkillFileInfo = new SkillFileInfo();
    pr2.file = 'references/review-template.md';
    pr2.desc = 'OpenReview 标准输出模板（完整原文）';
    paperReviewer.files.push(pr1);
    paperReviewer.files.push(pr2);
    list.push(paperReviewer);
    let reviewAgent: SkillInfo = new SkillInfo();
    reviewAgent.id = 'review-agent';
    reviewAgent.name = '代码评审';
    reviewAgent.description = '对代码变更做只读、缺陷优先的评审并按 P0–P3 输出可执行发现时加载（完整移植自 chatgpt review-agent）：' +
      '先读 AGENTS/完整 diff/调用点，只报真实且由本次变更引入的问题，不臆造 finding。' +
      '触发词: 代码评审、review code、review this change、code review、帮我审代码。';
    let ra1: SkillFileInfo = new SkillFileInfo();
    ra1.file = 'agents/openai.yaml';
    ra1.desc = '原始 agent 配置（保留参考）';
    reviewAgent.files.push(ra1);
    list.push(reviewAgent);
    // ===== R10 目标第 1 轮：高优先级移植（paper-rebuttal / research-lineage-map / marketing-plan / reference-audit / paper-close-reading） =====
    let paperRebuttal: SkillInfo = new SkillInfo();
    paperRebuttal.id = 'paper-rebuttal';
    paperRebuttal.name = '论文 Rebuttal 回复';
    paperRebuttal.description = '以论文作者身份完成学术审稿 rebuttal 全流程时加载（完整移植自 workbuddy paper-rebuttal）：' +
      '意见清单化拆解、A/B/C/D 分类判定、可追溯修改日志、point-by-point 回复模板。' +
      '触发词: rebuttal、审稿意见回复、回复审稿人、response to reviewers、major/minor revision 回复。';
    let pbr1: SkillFileInfo = new SkillFileInfo();
    pbr1.file = 'references/comment-taxonomy.md';
    pbr1.desc = '审稿意见分类体系与 A/B/C/D 判定细则';
    let pbr2: SkillFileInfo = new SkillFileInfo();
    pbr2.file = 'references/rebuttal-writing-guide.md';
    pbr2.desc = 'Rebuttal 写作原则、语气与中英文常用句式';
    let pbr3: SkillFileInfo = new SkillFileInfo();
    pbr3.file = 'references/response-template.md';
    pbr3.desc = 'Point-by-point response letter 模板';
    paperRebuttal.files.push(pbr1);
    paperRebuttal.files.push(pbr2);
    paperRebuttal.files.push(pbr3);
    list.push(paperRebuttal);
    let lineageMap: SkillInfo = new SkillInfo();
    lineageMap.id = 'research-lineage-map';
    lineageMap.name = '研究谱系演进图';
    lineageMap.description = '绘制研究/技术主题的谱系脉络与历史演进图时加载（完整移植自 workbuddy research-lineage-map）：' +
      '"问题→解决"叙事、年份硬约束、Mermaid 演进图 + 节点明细表 + 阶段叙事。' +
      '触发词: 梳理发展历史、family tree、技术演进路线、X 是如何一步步发展来的、X 解决了前人的什么问题。';
    let lm1: SkillFileInfo = new SkillFileInfo();
    lm1.file = 'references/mermaid-patterns.md';
    lm1.desc = '谱系图专用 Mermaid 语法模式与常见坑';
    let lm2: SkillFileInfo = new SkillFileInfo();
    lm2.file = 'references/output-template.md';
    lm2.desc = '输出 Markdown 完整模板与填充示例';
    lineageMap.files.push(lm1);
    lineageMap.files.push(lm2);
    list.push(lineageMap);
    let marketingPlan: SkillInfo = new SkillInfo();
    marketingPlan.id = 'marketing-plan';
    marketingPlan.name = '营销策划方案';
    marketingPlan.description = '把模糊业务诉求转化为实战级营销策划方案时加载（完整移植自 doubao-marketing-plan）：' +
      '路由边界、方法论选型、热点检索、图片落位、输出红线，交付 Markdown/Word。' +
      '触发词: 营销方案、营销策划、活动策划、产品上市方案、整合营销、增长转化方案。';
    let mp1: SkillFileInfo = new SkillFileInfo();
    mp1.file = 'references/hotspot-guide.md';
    mp1.desc = '联网与实时热点检索规则';
    let mp2: SkillFileInfo = new SkillFileInfo();
    mp2.file = 'references/image-methodology.md';
    mp2.desc = '图片创意与素材创作方法论';
    let mp3: SkillFileInfo = new SkillFileInfo();
    mp3.file = 'references/output-format.md';
    mp3.desc = '输出格式与排版规范（强约束）';
    let mp4: SkillFileInfo = new SkillFileInfo();
    mp4.file = 'references/planning-methodology.md';
    mp4.desc = '营销策划核心方法论';
    marketingPlan.files.push(mp1);
    marketingPlan.files.push(mp2);
    marketingPlan.files.push(mp3);
    marketingPlan.files.push(mp4);
    list.push(marketingPlan);
    let referenceAudit: SkillInfo = new SkillInfo();
    referenceAudit.id = 'reference-audit';
    referenceAudit.name = '参考文献审计';
    referenceAudit.description = '审查论文/学位论文参考文献真实性、题录准确性、文内—文后对应与主张支持度时加载（完整移植自 doubao-reference-audit）：' +
      '七阶段审计、引用角色判断、证据边界，交付 Markdown/Word 审计报告。' +
      '触发词: 论文审计、参考文献检查、引用核对、引用是否支持观点、检查错引/过度推断/二手转引。';
    let ra2: SkillFileInfo = new SkillFileInfo();
    ra2.file = 'assets/report-template.md';
    ra2.desc = '审计报告模板（已适配本项目）';
    referenceAudit.files.push(ra2);
    list.push(referenceAudit);
    let paperCloseReading: SkillInfo = new SkillInfo();
    paperCloseReading.id = 'paper-close-reading';
    paperCloseReading.name = '论文精读';
    paperCloseReading.description = '对学术论文做专业深度精读并生成研究报告时加载（完整移植自 doubao-paper-close-reading）：' +
      '重建研究故事、方法/证据拆解、可信边界、复现风险，交付 Markdown/Word。' +
      '触发词: 论文精读、深度解读、分析方法与实验、判断论文价值或局限。';
    let pc1: SkillFileInfo = new SkillFileInfo();
    pc1.file = 'assets/report-template.md';
    pc1.desc = '精读报告模板（已适配本项目）';
    paperCloseReading.files.push(pc1);
    list.push(paperCloseReading);
    // ===== R10 目标第 2 轮：继续移植高优先级（khazix-writer / newmedia-writing / marketing-material-review / patent-drafting / sentiment-tracker） =====
    let khazixWriter: SkillInfo = new SkillInfo();
    khazixWriter.id = 'khazix-writer';
    khazixWriter.name = '公众号长文写作（卡兹克风格）';
    khazixWriter.description = '以「数字生命卡兹克」的个人风格撰写/续写/扩写公众号长文时加载（完整移植自 workbuddy khazix-writer）：' +
      '选题判断、价值观底色、长文结构、内容方法论与风格示例。' +
      '触发词: 写文章、写稿子、帮我写、续写、扩写、公众号文章、长文、按我的风格写。';
    let kz1: SkillFileInfo = new SkillFileInfo();
    kz1.file = 'references/content_methodology.md';
    kz1.desc = '内容方法论（选题/分类/节奏/创意案例工作法）';
    let kz2: SkillFileInfo = new SkillFileInfo();
    kz2.file = 'references/style_examples.md';
    kz2.desc = '卡兹克风格示例与改写示范';
    khazixWriter.files.push(kz1);
    khazixWriter.files.push(kz2);
    list.push(khazixWriter);
    let newmediaWriting: SkillInfo = new SkillInfo();
    newmediaWriting.id = 'newmedia-writing';
    newmediaWriting.name = '新媒体写作（小红书/公众号/短视频）';
    newmediaWriting.description = '生成、改写、优化中文新媒体内容时加载（完整移植自 doubao-newmedia-writing）：' +
      '小红书图文笔记、公众号文章、3 分钟以内短视频分镜脚本及复合方案，交付 Markdown/Word。' +
      '触发词: 小红书笔记、公众号文章、短视频分镜、爆款文案、种草文、账号定位、内容创作方案。';
    let nm1: SkillFileInfo = new SkillFileInfo();
    nm1.file = 'references/genre-guide/composite.writing-guide.md';
    nm1.desc = '复合型创作主干';
    let nm2: SkillFileInfo = new SkillFileInfo();
    nm2.file = 'references/genre-guide/lark-doc.writing-guide.md';
    nm2.desc = '文档创建与写入规则（本项目适配版）';
    let nm3: SkillFileInfo = new SkillFileInfo();
    nm3.file = 'references/genre-guide/short-video.writing-guide.md';
    nm3.desc = '短视频分镜脚本主干';
    let nm4: SkillFileInfo = new SkillFileInfo();
    nm4.file = 'references/genre-guide/wechat.writing-guide.md';
    nm4.desc = '公众号文章主干';
    let nm5: SkillFileInfo = new SkillFileInfo();
    nm5.file = 'references/genre-guide/xhs.writing-guide.md';
    nm5.desc = '小红书图文笔记主干';
    let nm6: SkillFileInfo = new SkillFileInfo();
    nm6.file = 'references/short-video.samples/creative-playbook.md';
    nm6.desc = '短视频创意手册 sample';
    let nm7: SkillFileInfo = new SkillFileInfo();
    nm7.file = 'references/short-video.samples/output-format.md';
    nm7.desc = '短视频分镜输出格式 sample';
    let nm8: SkillFileInfo = new SkillFileInfo();
    nm8.file = 'references/short-video.samples/research-workflow.md';
    nm8.desc = '短视频调研工作流 sample';
    let nm9: SkillFileInfo = new SkillFileInfo();
    nm9.file = 'references/short-video.samples/visual-storyboard.md';
    nm9.desc = '短视频视觉分镜 sample';
    let nm10: SkillFileInfo = new SkillFileInfo();
    nm10.file = 'references/wechat.samples/Internet-search-rules.md';
    nm10.desc = '公众号联网检索规则 sample';
    let nm11: SkillFileInfo = new SkillFileInfo();
    nm11.file = 'references/wechat.samples/Layout-and-illustration-requirements.md';
    nm11.desc = '公众号排版与配图要求 sample';
    let nm12: SkillFileInfo = new SkillFileInfo();
    nm12.file = 'references/wechat.samples/writing-styles/cognitive-opinion.md';
    nm12.desc = '公众号写作风格：认知观点';
    let nm13: SkillFileInfo = new SkillFileInfo();
    nm13.file = 'references/wechat.samples/writing-styles/emotional-healing.md';
    nm13.desc = '公众号写作风格：情感治愈';
    let nm14: SkillFileInfo = new SkillFileInfo();
    nm14.file = 'references/wechat.samples/writing-styles/narrative-nonfiction.md';
    nm14.desc = '公众号写作风格：故事纪实';
    let nm15: SkillFileInfo = new SkillFileInfo();
    nm15.file = 'references/wechat.samples/writing-styles/news-hotspot.md';
    nm15.desc = '公众号写作风格：新闻热点';
    let nm16: SkillFileInfo = new SkillFileInfo();
    nm16.file = 'references/wechat.samples/writing-styles/professional-explainer.md';
    nm16.desc = '公众号写作风格：专业解读';
    let nm17: SkillFileInfo = new SkillFileInfo();
    nm17.file = 'references/xhs.samples/xhs-note-proposal.samples.creation-methodology.md';
    nm17.desc = '小红书创作方法论 sample';
    let nm18: SkillFileInfo = new SkillFileInfo();
    nm18.file = 'references/xhs.samples/xhs-note-proposal.samples.creation-methods.md';
    nm18.desc = '小红书创作方法 sample';
    let nm19: SkillFileInfo = new SkillFileInfo();
    nm19.file = 'references/xhs.samples/xhs-note-proposal.samples.hotspot-guide.md';
    nm19.desc = '小红书热点指南 sample';
    let nm20: SkillFileInfo = new SkillFileInfo();
    nm20.file = 'references/xhs.samples/xhs-note-proposal.samples.image-cover-methodology.md';
    nm20.desc = '小红书封面方法论 sample';
    let nm21: SkillFileInfo = new SkillFileInfo();
    nm21.file = 'references/xhs.samples/xhs-note-proposal.samples.image-design-methods.md';
    nm21.desc = '小红书配图设计方法 sample（上）';
    let nm22: SkillFileInfo = new SkillFileInfo();
    nm22.file = 'references/xhs.samples/xhs-note-proposal.samples.image-design-methods-2.md';
    nm22.desc = '小红书配图设计方法 sample（下）';
    let nm23: SkillFileInfo = new SkillFileInfo();
    nm23.file = 'references/xhs.samples/xhs-note-proposal.samples.output-format.md';
    nm23.desc = '小红书文档内图文排版规范 sample';
    newmediaWriting.files.push(nm1);
    newmediaWriting.files.push(nm2);
    newmediaWriting.files.push(nm3);
    newmediaWriting.files.push(nm4);
    newmediaWriting.files.push(nm5);
    newmediaWriting.files.push(nm6);
    newmediaWriting.files.push(nm7);
    newmediaWriting.files.push(nm8);
    newmediaWriting.files.push(nm9);
    newmediaWriting.files.push(nm10);
    newmediaWriting.files.push(nm11);
    newmediaWriting.files.push(nm12);
    newmediaWriting.files.push(nm13);
    newmediaWriting.files.push(nm14);
    newmediaWriting.files.push(nm15);
    newmediaWriting.files.push(nm16);
    newmediaWriting.files.push(nm17);
    newmediaWriting.files.push(nm18);
    newmediaWriting.files.push(nm19);
    newmediaWriting.files.push(nm20);
    newmediaWriting.files.push(nm21);
    newmediaWriting.files.push(nm22);
    newmediaWriting.files.push(nm23);
    list.push(newmediaWriting);
    let marketingMaterialReview: SkillInfo = new SkillInfo();
    marketingMaterialReview.id = 'marketing-material-review';
    marketingMaterialReview.name = '营销素材审核';
    marketingMaterialReview.description = '对广告宣传语、营销海报文案、社媒推广文案、直播话术等营销素材做合规风险审查时加载（完整移植自 doubao-marketing-material-review）：' +
      '虚假/夸大/绝对化用语、比较广告、引证数据、价格、有奖营销、风险行业等维度，交付 Markdown/Word 审查报告。' +
      '触发词: 营销素材审核、广告文案合规审查、宣传语合规、广告法审查、促销价格合规、有奖活动规则审查。';
    list.push(marketingMaterialReview);
    let patentDrafting: SkillInfo = new SkillInfo();
    patentDrafting.id = 'patent-drafting';
    patentDrafting.name = '专利申请文件撰写';
    patentDrafting.description = '基于技术交底书撰写/修改中国发明、实用新型申请文件或审查权利要求书时加载（完整移植自 doubao-patent-drafting）：' +
      '三阶段主流程（材料审计/权利要求/说明书）+ 红线清单 + 自检清单，交付 Word。' +
      '触发词: 专利撰写、专利申请、技术交底书、权利要求、说明书、实用新型、发明专利。';
    let pd1: SkillFileInfo = new SkillFileInfo();
    pd1.file = 'README.md';
    pd1.desc = '技能目录说明（本项目适配版）';
    let pd2: SkillFileInfo = new SkillFileInfo();
    pd2.file = 'references/writing-style.md';
    pd2.desc = '措辞分寸表与套话黑名单';
    let pd3: SkillFileInfo = new SkillFileInfo();
    pd3.file = 'sub-skills/claims/SKILL.md';
    pd3.desc = '阶段二：权利要求撰写判据';
    let pd4: SkillFileInfo = new SkillFileInfo();
    pd4.file = 'sub-skills/intake-audit/SKILL.md';
    pd4.desc = '阶段一：交底材料审计';
    let pd5: SkillFileInfo = new SkillFileInfo();
    pd5.file = 'sub-skills/specification/SKILL.md';
    pd5.desc = '阶段三：说明书与摘要';
    patentDrafting.files.push(pd1);
    patentDrafting.files.push(pd2);
    patentDrafting.files.push(pd3);
    patentDrafting.files.push(pd4);
    patentDrafting.files.push(pd5);
    list.push(patentDrafting);
    let sentimentTracker: SkillInfo = new SkillInfo();
    sentimentTracker.id = 'sentiment-tracker';
    sentimentTracker.name = '舆情追踪与溯源';
    sentimentTracker.description = '进行舆情监控、调研、社交媒体反馈收集、用户评价、品牌声量追踪时加载（完整移植自 doubao-sentiment-tracker）：' +
      '五步法（全网检索→平台深度检索→筛选→强制溯源→整理输出），一手信源优先，交付报告文档。' +
      '触发词: 舆情监控、舆情调研、品牌声量、用户反馈收集、社媒口碑、帮我看下网上怎么说。';
    let st1: SkillFileInfo = new SkillFileInfo();
    st1.file = 'agents/openai.yaml';
    st1.desc = '原始 agent 配置（保留参考）';
    let st2: SkillFileInfo = new SkillFileInfo();
    st2.file = 'references/evaluation-set.md';
    st2.desc = '评估集与自检样例';
    let st3: SkillFileInfo = new SkillFileInfo();
    st3.file = 'references/twitter-guide.md';
    st3.desc = 'Twitter(X) 平台溯源指南';
    let st4: SkillFileInfo = new SkillFileInfo();
    st4.file = 'references/weibo-guide.md';
    st4.desc = '微博平台溯源指南';
    sentimentTracker.files.push(st1);
    sentimentTracker.files.push(st2);
    sentimentTracker.files.push(st3);
    sentimentTracker.files.push(st4);
    list.push(sentimentTracker);
    // ===== R13（目标第 3 轮）：journal-format / research-proposal / industry-analysis =====
    let journalFormat: SkillInfo = new SkillInfo();
    journalFormat.id = 'journal-format';
    journalFormat.name = '学术论文 DOCX 格式排版与修复';
    journalFormat.description = '对学术论文类 Word/DOCX 文档进行期刊、学校、会议或课程要求的格式排版与修复时加载（完整移植自 doubao-journal-format）：' +
      '触发/边界、角色样式路由、编号/上下标、公式/表格/分栏、保留规则与交付自检；本环境无 Python 脚本，执行改用 docx 技能。' +
      '触发词: 论文排版、期刊投稿格式、学位论文格式、会议论文模板、套用 Word 模板、格式修复。';
    let jf1: SkillFileInfo = new SkillFileInfo();
    jf1.file = 'SKILL-2.md';
    jf1.desc = 'SKILL 拆分续篇（触发边界后半）';
    let jf2: SkillFileInfo = new SkillFileInfo();
    jf2.file = 'SKILL-3.md';
    jf2.desc = 'SKILL 拆分续篇（模块路由/强制路由）';
    let jf3: SkillFileInfo = new SkillFileInfo();
    jf3.file = 'SKILL-4.md';
    jf3.desc = 'SKILL 拆分续篇（强制路由后半）';
    let jf4: SkillFileInfo = new SkillFileInfo();
    jf4.file = 'SKILL-5.md';
    jf4.desc = 'SKILL 拆分结尾（本项目执行说明/版本）';
    let jf5: SkillFileInfo = new SkillFileInfo();
    jf5.file = 'references/equations-tables-sections.md';
    jf5.desc = '公式/表格/分节/分栏规范（上）';
    let jf6: SkillFileInfo = new SkillFileInfo();
    jf6.file = 'references/equations-tables-sections-2.md';
    jf6.desc = '公式/表格/分节/分栏规范（中）';
    let jf7: SkillFileInfo = new SkillFileInfo();
    jf7.file = 'references/equations-tables-sections-3.md';
    jf7.desc = '公式/表格/分节/分栏规范（下）';
    let jf8: SkillFileInfo = new SkillFileInfo();
    jf8.file = 'references/explicit-postprocess.md';
    jf8.desc = '显式后处理规则';
    let jf9: SkillFileInfo = new SkillFileInfo();
    jf9.file = 'references/preservation-rules.md';
    jf9.desc = '保留与最终输出护栏（上）';
    let jf10: SkillFileInfo = new SkillFileInfo();
    jf10.file = 'references/preservation-rules-2.md';
    jf10.desc = '保留与最终输出护栏（中）';
    let jf11: SkillFileInfo = new SkillFileInfo();
    jf11.file = 'references/preservation-rules-3.md';
    jf11.desc = '保留与最终输出护栏（下）';
    let jf12: SkillFileInfo = new SkillFileInfo();
    jf12.file = 'references/references-numbering-superscript.md';
    jf12.desc = '参考文献编号/上标规范（上）';
    let jf13: SkillFileInfo = new SkillFileInfo();
    jf13.file = 'references/references-numbering-superscript-2.md';
    jf13.desc = '参考文献编号/上标规范（下）';
    let jf14: SkillFileInfo = new SkillFileInfo();
    jf14.file = 'references/style-routing.md';
    jf14.desc = '角色样式路由与直排清理（上）';
    let jf15: SkillFileInfo = new SkillFileInfo();
    jf15.file = 'references/style-routing-2.md';
    jf15.desc = '角色样式路由与直排清理（中一）';
    let jf16: SkillFileInfo = new SkillFileInfo();
    jf16.file = 'references/style-routing-3.md';
    jf16.desc = '角色样式路由与直排清理（中二）';
    let jf17: SkillFileInfo = new SkillFileInfo();
    jf17.file = 'references/style-routing-4.md';
    jf17.desc = '角色样式路由与直排清理（中三）';
    let jf18: SkillFileInfo = new SkillFileInfo();
    jf18.file = 'references/style-routing-5.md';
    jf18.desc = '角色样式路由与直排清理（下）';
    let jf19: SkillFileInfo = new SkillFileInfo();
    jf19.file = 'references/template-distill-render-qa.md';
    jf19.desc = '模板蒸馏/渲染 QA 规范（上）';
    let jf20: SkillFileInfo = new SkillFileInfo();
    jf20.file = 'references/template-distill-render-qa-2.md';
    jf20.desc = '模板蒸馏/渲染 QA 规范（中）';
    let jf21: SkillFileInfo = new SkillFileInfo();
    jf21.file = 'references/template-distill-render-qa-3.md';
    jf21.desc = '模板蒸馏/渲染 QA 规范（下）';
    journalFormat.files.push(jf1);
    journalFormat.files.push(jf2);
    journalFormat.files.push(jf3);
    journalFormat.files.push(jf4);
    journalFormat.files.push(jf5);
    journalFormat.files.push(jf6);
    journalFormat.files.push(jf7);
    journalFormat.files.push(jf8);
    journalFormat.files.push(jf9);
    journalFormat.files.push(jf10);
    journalFormat.files.push(jf11);
    journalFormat.files.push(jf12);
    journalFormat.files.push(jf13);
    journalFormat.files.push(jf14);
    journalFormat.files.push(jf15);
    journalFormat.files.push(jf16);
    journalFormat.files.push(jf17);
    journalFormat.files.push(jf18);
    journalFormat.files.push(jf19);
    journalFormat.files.push(jf20);
    journalFormat.files.push(jf21);
    list.push(journalFormat);
    let researchProposal: SkillInfo = new SkillInfo();
    researchProposal.id = 'research-proposal';
    researchProposal.name = '学术立项书/基金申请撰写';
    researchProposal.description = '用于国自然、国社科等基金申请、开题报告、博士后/人才计划、研究计划书等学术提案的撰写、审查和优化时加载（完整移植自 doubao-research-proposal）：' +
      '信息分层、分阶段确认、事实台账、论证闭环与输出检查，交付 Markdown/Word。' +
      '触发词: 基金申请、开题报告、研究计划书、立项书、任务书一致性、学术提案。';
    let rp1: SkillFileInfo = new SkillFileInfo();
    rp1.file = 'references/academic-grant-guide.md';
    rp1.desc = '基金申请指南（模板匹配规则，本项目未内置二进制模板）';
    let rp2: SkillFileInfo = new SkillFileInfo();
    rp2.file = 'references/academic-scenarios-guide.md';
    rp2.desc = '开题/计划书/套磁等场景指南';
    let rp3: SkillFileInfo = new SkillFileInfo();
    rp3.file = 'references/anti-fabrication-rules.md';
    rp3.desc = '事实边界/匿名化/占位符/引用风险';
    let rp4: SkillFileInfo = new SkillFileInfo();
    rp4.file = 'references/literature-review-guide.md';
    rp4.desc = '文献综述与材料理解指南';
    let rp5: SkillFileInfo = new SkillFileInfo();
    rp5.file = 'references/output-and-validation.md';
    rp5.desc = '输出文件与终稿检查';
    let rp6: SkillFileInfo = new SkillFileInfo();
    rp6.file = 'references/research-logic-design.md';
    rp6.desc = '研究逻辑设计（问题-目标-内容-路线-证据）';
    let rp7: SkillFileInfo = new SkillFileInfo();
    rp7.file = 'references/workflow-checkpoints.md';
    rp7.desc = '分阶段确认与检查点';
    researchProposal.files.push(rp1);
    researchProposal.files.push(rp2);
    researchProposal.files.push(rp3);
    researchProposal.files.push(rp4);
    researchProposal.files.push(rp5);
    researchProposal.files.push(rp6);
    researchProposal.files.push(rp7);
    list.push(researchProposal);
    let industryAnalysis: SkillInfo = new SkillInfo();
    industryAnalysis.id = 'industry-analysis';
    industryAnalysis.name = '行业深度研究';
    industryAnalysis.description = '针对某一行业的中长期基本面与产业研究，交付完整深度报告时加载（完整移植自 doubao-industry-analysis）：' +
      '判断主线、三级数据分级、五大板块、三情景与引用纪律，交付 Markdown/Word。' +
      '触发词: 行业研究、行业深度报告、产业链分析、市场规模、竞争格局、趋势研判。';
    let ia1: SkillFileInfo = new SkillFileInfo();
    ia1.file = 'agents/openai.yaml';
    ia1.desc = '原始 agent 配置（保留参考）';
    let ia2: SkillFileInfo = new SkillFileInfo();
    ia2.file = 'references/analysis-framework.md';
    ia2.desc = '行业分析镜头';
    let ia3: SkillFileInfo = new SkillFileInfo();
    ia3.file = 'references/data-collection-protocol.md';
    ia3.desc = '取数协议与合规红线';
    let ia4: SkillFileInfo = new SkillFileInfo();
    ia4.file = 'references/data-grading-and-citation.md';
    ia4.desc = '三级数据分级/引用与措辞纪律';
    let ia5: SkillFileInfo = new SkillFileInfo();
    ia5.file = 'references/industry-structure-playbooks.md';
    ia5.desc = '行业结构类型分析侧重';
    let ia6: SkillFileInfo = new SkillFileInfo();
    ia6.file = 'references/insight-spine.md';
    ia6.desc = '判断主线底稿模板';
    let ia7: SkillFileInfo = new SkillFileInfo();
    ia7.file = 'references/lark-doc-report-standard.md';
    ia7.desc = 'Markdown 拼接与文件交付标准（本项目适配版）';
    let ia8: SkillFileInfo = new SkillFileInfo();
    ia8.file = 'references/report-finalization.md';
    ia8.desc = '五大板块写作大纲与交付前自检';
    let ia9: SkillFileInfo = new SkillFileInfo();
    ia9.file = 'references/task-router.md';
    ia9.desc = '任务路由与不触发场景';
    industryAnalysis.files.push(ia1);
    industryAnalysis.files.push(ia2);
    industryAnalysis.files.push(ia3);
    industryAnalysis.files.push(ia4);
    industryAnalysis.files.push(ia5);
    industryAnalysis.files.push(ia6);
    industryAnalysis.files.push(ia7);
    industryAnalysis.files.push(ia8);
    industryAnalysis.files.push(ia9);
    list.push(industryAnalysis);
    return list;
  }

  // list_skills 输出: 技能清单(含触发语义与文件索引)
  static listText(): string {
    WorkSkillService.ensureToolSkills();
    return SkillDirectoryFormatter.listText(ToolRegistry.skillList());
  }

  // @deprecated 请使用 promptSectionWithMode(mode); 保留默认 full_index 兼容
  static promptSection(): string {
    WorkSkillService.ensureToolSkills();
    return SkillDirectoryFormatter.format(ToolRegistry.skillList(), SkillDirectoryFormatter.MODE_FULL_INDEX);
  }

  // 按目录模式生成技能提示词(full_index 完整清单 / trigger_only 渐进披露)
  static promptSectionWithMode(mode: string): string {
    WorkSkillService.ensureToolSkills();
    return SkillDirectoryFormatter.format(ToolRegistry.skillList(), mode);
  }

  // load_skill: 读取技能文档; 技能名或文件名不在注册表内时报错(防路径探测)
  static async load(context: common.UIAbilityContext, skillId: string, file: string): Promise<string> {
    WorkSkillService.ensureToolSkills();
    let id: string = skillId.trim().toLowerCase();
    let skill: SkillMeta | null = ToolRegistry.findSkill(id);
    if (skill === null) {
      let ids: string[] = ToolRegistry.skillIds();
      return 'ERROR: 未知技能 "' + skillId + '"。可用技能: ' + (ids.length > 0 ? ids.join(' / ') : '(无)');
    }
    let target: string = file.trim();
    if (target === '') {
      target = 'SKILL.md';
    }
    // V3: 核心办公技能 load_skill(name) 必须全量返回 SKILL.md + 全部 reference，禁止按需挑读。
    if ((skill.id === 'ppt' || skill.id === 'docx' || skill.id === 'xlsx') && target === 'SKILL.md') {
      return await WorkSkillService.loadBundle(context, skill);
    }
    let allowed: boolean = target === 'SKILL.md';
    for (let i: number = 0; i < skill.files.length; i++) {
      if (skill.files[i].file === target) {
        allowed = true;
        break;
      }
    }
    if (!allowed) {
      let names: string[] = ['SKILL.md'];
      for (let i: number = 0; i < skill.files.length; i++) {
        names.push(skill.files[i].file);
      }
      return 'ERROR: 技能 ' + skill.id + ' 没有 "' + file + '"。可用文件: ' + names.join(' / ');
    }
    let rawPath: string = 'skills/' + skill.id + '/' + target;
    try {
      let raw: Uint8Array = await context.resourceManager.getRawFileContent(rawPath);
      let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      let text: string = decoder.decodeToString(raw, { stream: false });
      if (text.trim() === '') {
        return 'ERROR: 技能文件为空: ' + rawPath;
      }
      if (text.length > Constants.WORK_SKILL_MAX_CHARS) {
        text = text.substring(0, Constants.WORK_SKILL_MAX_CHARS) + '\n...(过长已截断)';
      }
      return '【技能 ' + skill.id + ' · ' + target + '】\n' + text;
    } catch (e) {
      let msg: string = e instanceof Error ? (e as Error).message : String(e);
      return 'ERROR: 技能文件加载失败(' + msg + '): ' + rawPath;
    }
  }

  // V3 全量 bundle：一次返回 SKILL.md + 全部 reference（ppt/docx/xlsx），避免 agent 按需挑读。
  private static async loadBundle(context: common.UIAbilityContext, skill: SkillMeta): Promise<string> {
    let parts: string[] = [];
    let files: string[] = ['SKILL.md'];
    for (let i: number = 0; i < skill.files.length; i++) {
      files.push(skill.files[i].file);
    }
    for (let i: number = 0; i < files.length; i++) {
      let target: string = files[i];
      let rawPath: string = 'skills/' + skill.id + '/' + target;
      try {
        let raw: Uint8Array = await context.resourceManager.getRawFileContent(rawPath);
        let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        let text: string = decoder.decodeToString(raw, { stream: false });
        if (text.trim() === '') {
          return 'ERROR: 技能文件为空: ' + rawPath;
        }
        parts.push('【技能 ' + skill.id + ' · ' + target + '】\n' + text);
      } catch (e) {
        let msg: string = e instanceof Error ? (e as Error).message : String(e);
        return 'ERROR: 技能文件加载失败(' + msg + '): ' + rawPath;
      }
    }
    let bundle: string = parts.join('\n\n');
    if (bundle.length > Constants.WORK_SKILL_BUNDLE_MAX_CHARS) {
      bundle = bundle.substring(0, Constants.WORK_SKILL_BUNDLE_MAX_CHARS) + '\n...(过长已截断)';
    }
    return bundle;
  }
}
