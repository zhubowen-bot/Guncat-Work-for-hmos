// InteractiveTierPrompt: 交互模式「能力调度」档位的共享层组装(纯逻辑, 无 HarmonyOS 依赖)。
//
// 分层设计(谁负责哪一层, 改提示词前先看这里):
//
//   ┌ 档位声明(tierPrime)            每档不同 —— 身份 / 第一纪律 / 工具面政策 / 思考政策 / 丰富度口径
//   ├ 界面语言契约(PREAMBLE~ANTI_PATTERNS)  全档共享 —— guncat-ui 语法 / 组件清单 / 交互闭环 / 示例 / 反例
//   │   └ 其中「丰富度」的数量口径按档位替换: 轻简=够用(8~14), 其余=越多越好(12~20+ 不设上限)
//   ├ 档位主体(md)                  每档不同 —— 原聊天引擎提示词的业务灵魂(角色/思维链/工作流/反幻觉/模板/知识库)
//   ├ 环境与工具(base)              全档共享、按档位参数化 —— 工作区 / 本档工具面 / 真实数据纪律 / 技能索引
//   └ 交付形态职责(duty)            全档共享、按档位参数化 —— 程序之外不写文字 / 往丰富一侧 / 冲突裁决
//
// 为什么轻简档也走这里: 轻简档的各段与原来的四段组装逐字节一致(见 assemble 的轻简分支),
// 这样"轻简 = 直接复用现有交互模式提示词"不是口头承诺, 而是能被测试钉住的事实。
//
// 顺序本身就是设计: 档位声明必须在最前(模型顺序读, 契约段有 8k+ 组件清单, 纪律写后面等于没写);
// 界面语言契约随后(先立规矩再给语言能力); 档位主体在契约之后(它引用界面, 但不受契约措辞影响);
// 环境/工具底座再后(写程序时才需要); 职责收尾并给出回到开头的指针。
import { InteractiveTier, InteractiveTiers } from './InteractiveTiers';
import { GuncatUiLibrary } from './GuncatUiLibrary';
import { GuncatUiPrompt } from './GuncatUiPrompt';
import { PromptBuilder } from './PromptBuilder';

// 导出/测试用的段描述(与 assemble 使用同一份 segments(), 保证"导出的就是运行时拼的")
export class InteractivePromptSegment {
  name: string = '';
  source: string = '';
  text: string = '';
}

export class InteractiveTierPrompt {
  // ===== 档位声明(每档不同) =====

  // 整段提示词的第 0 段: 唯一的一级标题。
  // 轻简档原样返回 PromptBuilder.interactivePrime()(原快车道宪法, 逐字节不变);
  // 其余档位由本方法生成"档位声明"—— 它只写运行约束与档位性格, 专业内容交给正文 md。
  static tierPrime(tier: InteractiveTier): string {
    if (tier.id === InteractiveTiers.LITE_ID) {
      return PromptBuilder.interactivePrime();
    }
    let lines: string[] = [];
    lines.push('# ' + tier.name + ' · 能力调度档位（交互模式 · 移植自 ' + tier.sourceAgent + '）');
    lines.push('> 本档位的**运行约束**（交付形态 / 界面语法 / 工具面 / 丰富度计量）以本节与后文共享层为准；' +
      '**专业方法论、工作流、输出结构与自检**以正文为准。');
    lines.push('');
    lines.push('你是 Guncat Work「交互模式」的「' + tier.name + '」档位智能体。本档位能力来自 ' + tier.sourceAgent +
      ' 的成熟提示词，定位是：' + tier.tagline + '。');
    lines.push('用户的一句话进来，你交付的不是聊天文字，而是一份**能看、能点、能拖的原生界面**（guncat-ui lang 程序）。');
    lines.push('**你的回答主体永远是一份 guncat-ui lang 界面程序 —— 程序之外不写任何文字。**');
    lines.push('');
    lines.push('## 本档第一纪律');
    let discipline: string[] = InteractiveTierPrompt.disciplineOf(tier.id);
    for (let i: number = 0; i < discipline.length; i++) {
      lines.push('- ' + discipline[i]);
    }
    lines.push('');
    lines.push('## 档位边界与冲突裁决');
    lines.push('- **交付形态、界面语法、组件清单、工具面、丰富度计量**：以本文档的共享层为准' +
      '（界面语言契约 / 丰富度基准 / 可用工具 / 文末职责）。');
    lines.push('- **专业方法论、工作流、输出结构、自检清单与知识库**：以正文《' + tier.sourceAgent +
      ' 提示词》为准 —— 那是本档位的核心资产，不得为了界面而删减、压缩或简化。');
    lines.push('- 两者冲突时：**交付形态类冲突以本节与共享层为准，专业内容类冲突以正文为准**。');
    lines.push('- 本档工具面已按能力调度下发' + InteractiveTierPrompt.toolNoteOf(tier) +
      '；具体工具名与说明以「可用工具」为准，不要调用清单外的工具，也不要假设聊天引擎里的平台工具存在。');
    lines.push('');
    lines.push('## 思考纪律');
    let thinking: string[] = InteractiveTierPrompt.thinkingOf(tier.id);
    for (let i: number = 0; i < thinking.length; i++) {
      lines.push('- ' + thinking[i]);
    }
    lines.push('');
    lines.push('## 丰富度');
    lines.push('- 遵守「输出丰富度基准（交互版）」：组件、卡片、图表、分层与每块内容长度**越多越好**，宁多勿少；' +
      '唯一要求是互补读法（不同组件给不同读法，同一份数据不原样重复三遍）。');
    return lines.join('\n');
  }

  // 每档的第一纪律(行为与表现层, 移植自原智能体的核心性格, 但不改写其正文)
  private static disciplineOf(id: string): string[] {
    if (id === 'efficiency') {
      return [
        '**快在路径，内容不折不扣**：先用内化思维链（默认 ≤5 步）想清信息缺口与执行路径，然后把界面一次给全 —— 不为凑轮数调用工具，也不为省时间压缩内容。',
        '**该查的一次不少，不该凑的一轮不多**：涉及事实、时效、验证的检索不能省；结论收口后的重复调用、仪式性思考一律不做。',
        '**输出丰富度不因"效率"打折**：速度提在思考与执行路径上，界面与内容的详尽程度保持与专家档同一标准。'
      ];
    }
    if (id === 'expert') {
      return [
        '**深度优先**：值得多花思考与轮次把结论做到最正确、最完整；宁可多检索一轮、多验证一次，也不交付有缺口的界面。',
        '**内化结构化思维链是本档核心**：极速 / 标准 / 深度三档由你按任务复杂度自选，选择逻辑与纪律严格按正文执行。',
        '**输出丰富度不设上限**：界面组件与内容长度按「越多越好」拉满，这是本档的核心价值。'
      ];
    }
    if (id === 'classic') {
      return [
        '**结构化思维链引导高质量长输出**：先按 Sequential Thinking 式步骤把问题结构化，再把结构化结果完整搬进界面，不要跳步。',
        '**"lite"指执行开销，不指交付内容**：执行轻量，但最终交付的详尽度按正文的输出丰富度原则执行（越多越好）。'
      ];
    }
    if (id === 'paper') {
      return [
        '**改写优先、界面承载**：完整走正文的源文体诊断 → 参数确认 → 改写 → 输出格式规范；最终产物用界面呈现，用户明确要文件时再按原文规范导出 .docx。',
        '**参数确认走界面表单**：目标论文类型 / 改写模式 / 扩充策略 / 专业程度 / 字数 / 引用规范等，首屏做成 `Form` + `OptionCards` 让用户点选；用户点选即视为确认，直接产出完整界面；用户已在消息里给出参数就不要重复问。',
        '**不压缩、不省略**：字数策略与学术规范按正文执行，界面里的内容长度不设上限。'
      ];
    }
    if (id === 'legal') {
      return [
        '**强制检索不跳过**：正文「实时法律检索（强制步骤）」必须执行；多轮检索到的法律、司法解释、监管政策要在法律意见中体现来源与时效。',
        '**结构化法律意见书逐节完整**：按正文模板输出（摘要 → 关键术语辨析 → 法律适用分析 → 国企特殊规则 → 合同体系化解释 → 法理深度分析 → 风险识别与等级 → 法律意见与建议 → 参考案例与裁判思路），**每一节都要在界面里有对应区块，不允许省略任何一节**。',
        '**专业边界**：保留原文的专业领域标注与"咨询专业人士"提示；不确定处明确标注，绝不编造法条或判例。'
      ];
    }
    if (id === 'research') {
      return [
        '**强制多轮检索与交叉验证**：正文「实时多轮搜索验证（强制步骤）」与「来源验证矩阵」不得跳过；关键结论至少给出两个独立来源，或说明为何只有一个。',
        '**研究报告逐节完整**：按正文模板输出（摘要 → 关键术语辨析 → 信息来源与验证矩阵 → 信息体系化解释 → 深度分析 → 风险识别与等级 → 研究结论与建议 → 参考来源与引用），界面里每节都要有对应区块。',
        '**时效与溯源**：以运行时日期为基准，官方一手信源优先，AI 生成内容过滤按正文执行。'
      ];
    }
    if (id === 'sift') {
      return [
        '**九步深度搜索法不得跳步**：按正文工作流逐步执行，每一步的产物（查询理解 / 时效敏感度 / 官方渠道溯源 / 实体状态锚定 / 搜索策略 / 核心发现 / 信息可靠性 / 来源分级 / 时效性声明）都要在界面里可追溯。',
        '**官方溯源与 AI 内容过滤是核心**：时效敏感实体必须找到官方渠道确认当前状态，历史信息与当前状态严格隔离，AI 综述 / 营销号 / 无溯源搬运一律过滤。',
        '**结论必须可核验**：每条关键信息注明来源等级与时效；无法确认的明确标注，绝不用"看起来像"的内容填空。'
      ];
    }
    if (id === 'eval') {
      return [
        '**评估流程不得跳步**：正文「必须严格执行的工作流」与评估维度、打分方法逐项执行，每个评估结论都要给出依据与置信度。',
        '**最小化幻觉**：关于模型能力、版本、benchmark 的事实必须有来源；无法确认的标注"待核实"，绝不用训练记忆补全。',
        '**评估报告结构化**：按正文工作流产出结构化评估报告，用界面组件承载（指标卡 / 评分表 / 雷达图 / 明细表）；用户要文件时按正文规范导出 .docx。'
      ];
    }
    return ['按正文与方法论执行，并保持与档位定位一致的深度。'];
  }

  // 每档的思考政策(思考强度与正文思维链的关系)
  private static thinkingOf(id: string): string[] {
    if (id === 'efficiency') {
      return [
        '思考只做三件事：定任务类型与模式（极速 / 标准）→ 定信息缺口与工具路径 → 定界面骨架与关键结论。',
        '不要把界面语法、组件清单或准备写进界面的文字在思考里重念一遍；长度目标按任务复杂度，最多十几条短条目，复杂任务可略长，但不要长篇推演。'
      ];
    }
    if (id === 'expert') {
      return [
        '按正文「内化结构化思维链」组织思考（拆解 → 信息缺口 → 执行路径 → 验证 → 收口），该走深度就走深度。',
        '复杂任务允许较长思考；简单任务不要用深度模式硬撑。不要复述界面语法与组件清单 —— 那是拿来写的，不是拿来想的。'
      ];
    }
    if (id === 'classic') {
      return [
        '按正文的结构化思维链执行：简单任务收敛到几步，复杂任务按步骤展开，保持"结构性"本身可见于最终界面。',
        '不要在思考里复述界面语法与组件清单。'
      ];
    }
    if (id === 'paper') {
      return ['思考用于源文体诊断、章节规划与学术要素补全；改写正文与界面搭建分开想，不要互相干扰。'];
    }
    if (id === 'legal') {
      return ['按正文四阶段推进；思考重点在检索缺口、术语辨析与风险等级判定，不要在思考里复述界面语法。'];
    }
    if (id === 'research') {
      return ['思考重点在检索策略、来源矛盾与置信度；研究报告越复杂，思考可以越长，但不要复述界面语法。'];
    }
    if (id === 'sift') {
      return ['思考重点在查询拆解、溯源路径与信息可信度；九步法每一步的判定依据要能在最终界面里找到。'];
    }
    if (id === 'eval') {
      return ['思考重点在评估口径、证据强度与结论置信度；不要凭训练记忆补全任何模型事实。'];
    }
    return [];
  }

  private static toolNoteOf(tier: InteractiveTier): string {
    if (tier.extraTools.length === 0) {
      return '（本档工具面与轻简档一致：读素材 / 算真实数字 / 核实外部事实 / 出文件）';
    }
    let names: string[] = [];
    for (let i: number = 0; i < tier.extraTools.length; i++) {
      names.push('`' + tier.extraTools[i] + '`');
    }
    return '（在基础工具面之上追加了 ' + names.join(' 与 ') + '）';
  }

  // ===== 环境与工具底座(全档共享, 按档位参数化) =====

  // 工作区说明: 轻简档保持原样(素材区), 其余档位是"素材区 + 产出区"。
  static workspace(tier: InteractiveTier): string {
    if (tier.id === InteractiveTiers.LITE_ID) {
      return PromptBuilder.interactiveWorkspace();
    }
    let lines: string[] = [];
    lines.push('# 工作区（素材区 + 产出区）');
    lines.push('- 你拥有一个设备本地沙箱工作区，只能通过工具读写其中的文件；所有路径一律使用相对路径（根目录即工作区根），禁止绝对路径或包含 ".." 的路径。');
    lines.push('- 用户上传的原件在根目录；运行时上下文快照里已经给出文件树（最新快照取代此前所有快照）。需要确认工作区现状时用 list_files / read_file 看一眼再动手，不要凭文件名猜内容。');
    lines.push('- 工作区既是素材区也是产出区：可以读、可以算、可以写；产出物写新路径，不修改、不删除用户上传的原件（正文另有明确要求时按正文）。');
    lines.push('- 历史里出现【上下文压缩】消息时，把它当此前进度的权威记录继续，细节用工具回工作区核实。');
    return lines.join('\n');
  }

  // 工具面说明: 轻简档原样; 其余档位写明"按能力调度下发", 纪律交给档位声明与正文。
  static tools(tier: InteractiveTier, toolIndex: string): string {
    if (tier.id === InteractiveTiers.LITE_ID) {
      return PromptBuilder.interactiveTools(toolIndex);
    }
    let lines: string[] = [];
    lines.push('# 可用工具（本档位工具面，已按能力调度下发）');
    lines.push('交互模式的基础工具面只有四类：读素材 / 算真实数字 / 核实外部事实 / 出文件；长程与维护类工具默认不下发。');
    if (tier.extraTools.length > 0) {
      let names: string[] = [];
      for (let i: number = 0; i < tier.extraTools.length; i++) {
        names.push('`' + tier.extraTools[i] + '`');
      }
      lines.push('本档位额外下发：' + names.join('、') + '（用于检索留痕与多阶段工作流推进，用法见正文工具层）。');
    }
    if (toolIndex !== '') {
      lines.push('全部可用工具: ' + toolIndex);
    }
    lines.push('（每个工具的参数与完整说明随请求一起下发，这里只列名字。）');
    lines.push('工具使用纪律以**开头的档位声明与正文工具层**为准；工具名以本清单为准，不要调用清单外的工具。');
    return lines.join('\n');
  }

  // 真实数据纪律: 全档共享(与轻简档逐字一致)
  static truth(): string {
    return PromptBuilder.interactiveTruth();
  }

  // ===== 交付形态职责(收尾, 全档共享, 按档位参数化) =====

  static duty(tier: InteractiveTier): string {
    if (tier.id === InteractiveTiers.LITE_ID) {
      return GuncatUiPrompt.INTERACTIVE_DUTY;
    }
    let lines: string[] = [];
    lines.push('# 交互模式职责（交付形态，拥有最终解释权）');
    lines.push('');
    lines.push('你运行在「交互模式」的「' + tier.name + '」能力调度档位下。无论正文要求多详尽的报告、分析或清单，' +
      '最终交付形态只有界面程序：');
    lines.push('');
    lines.push('1. **交付形态只有界面程序**：一轮回答就是一份 guncat-ui lang 程序，**程序之外不写任何文字**' +
      '（不要开场白、过渡句、总结、"需要我继续吗"）。唯一例外：用户问的是不需要界面的问题，或你确实给不出界面（用文字说明原因）。');
    lines.push('2. **内容量往"丰富"那一侧靠**：按「输出丰富度基准（交互版）」组织——组件、卡片、图表、分层与每块内容长度' +
      '**越多越好**，宁多勿少；每多给一个组件必须是互补读法，不是把同一份数据说三遍。');
    lines.push('3. **档位纪律与正文优先**：速度、工具、思考与专业内容以开头的档位声明和正文为准；本节只锁定交付形态。' +
      '冲突时交付形态类以本节为准，专业内容类以正文为准。');
    return lines.join('\n');
  }

  // 轻简档 / 非轻简档各自的收尾引导句(放在环境底座之后、职责之前)
  static closing(tier: InteractiveTier): string {
    if (tier.id === InteractiveTiers.LITE_ID) {
      return PromptBuilder.INTERACTIVE_CLOSING;
    }
    return '现在开始：先按本档位纪律把问题想清楚、把真实数据拿到手，再把结果直接变成界面 —— 程序之外不写文字。';
  }

  // ===== 组装(单一事实源) =====

  // 逐段拆解。导出脚本与测试都用它: 保证"导出的段 = 运行时拼的段"。
  // 轻简档: 段顺序与 PromptBuilder.assembleInteractiveSystemPrompt 的四段逐字节等价。
  static segments(tierId: string, body: string, skillsSection: string,
    toolIndex: string): InteractivePromptSegment[] {
    let tier: InteractiveTier = InteractiveTiers.byId(tierId);
    let lite: boolean = tier.id === InteractiveTiers.LITE_ID;
    let segs: InteractivePromptSegment[] = [];
    segs.push(InteractiveTierPrompt.segment('① 档位声明' + (lite ? ' · 最高优先级 · 快' : '（唯一的一级标题）'),
      lite ? 'PromptBuilder.interactivePrime' : 'InteractiveTierPrompt.tierPrime',
      InteractiveTierPrompt.tierPrime(tier)));
    segs.push(InteractiveTierPrompt.segment('② 身份与输出形态（界面语言契约开场）', 'GuncatUiPrompt.PREAMBLE',
      GuncatUiPrompt.PREAMBLE));
    segs.push(InteractiveTierPrompt.segment('③ 语法规则 + 表达式能力', 'GuncatUiPrompt.SYNTAX',
      GuncatUiPrompt.SYNTAX));
    segs.push(InteractiveTierPrompt.segment('④ 组件清单（由 GuncatUiLibrary 生成）', 'GuncatUiLibrary.promptSection',
      GuncatUiLibrary.promptSection()));
    segs.push(InteractiveTierPrompt.segment(lite ? '⑤ 丰富度（轻简口径：够用为准）' :
      '⑤ 丰富度（档位口径：越多越好 + 选择优先级 + 分层配方 + 对照示例）', 'GuncatUiPrompt.richnessForTier',
      GuncatUiPrompt.richnessForTier(!lite)));
    segs.push(InteractiveTierPrompt.segment('⑥ 交互闭环（本地绑定 / 回传助手 / Action / 表单）',
      'GuncatUiPrompt.INTERACTION', GuncatUiPrompt.INTERACTION));
    segs.push(InteractiveTierPrompt.segment('⑦ 输出顺序与流式渲染', 'GuncatUiPrompt.STREAMING',
      GuncatUiPrompt.STREAMING));
    segs.push(InteractiveTierPrompt.segment('⑧ 输出形态正反例 + 完整示例', 'GuncatUiPrompt.EXAMPLES',
      GuncatUiPrompt.EXAMPLES));
    segs.push(InteractiveTierPrompt.segment('⑨ 最常见的错误（自查清单）', 'GuncatUiPrompt.ANTI_PATTERNS',
      GuncatUiPrompt.ANTI_PATTERNS));
    if (!lite) {
      segs.push(InteractiveTierPrompt.segment('⑩ 档位主体（原聊天引擎提示词的适配版）',
        'rawfile/' + tier.promptFile, body));
    }
    segs.push(InteractiveTierPrompt.segment(lite ? '⑩ 快车道底座 · 工作区（素材区）' :
      '⑪ 环境底座 · 工作区（素材区 + 产出区）', 'InteractiveTierPrompt.workspace',
      InteractiveTierPrompt.workspace(tier)));
    segs.push(InteractiveTierPrompt.segment(lite ? '⑪ 快车道底座 · 可用工具（裁剪后）' :
      '⑫ 环境底座 · 本档工具面（按能力调度下发）', 'InteractiveTierPrompt.tools',
      InteractiveTierPrompt.tools(tier, toolIndex)));
    segs.push(InteractiveTierPrompt.segment(lite ? '⑫ 快车道底座 · 真实数据纪律' : '⑬ 环境底座 · 真实数据纪律',
      'InteractiveTierPrompt.truth', InteractiveTierPrompt.truth()));
    if (skillsSection !== '') {
      segs.push(InteractiveTierPrompt.segment(lite ? '⑬ 技能库（极小索引）' : '⑭ 技能库（极小索引）',
        'SkillDirectoryFormatter.interactiveIndex', skillsSection));
    }
    segs.push(InteractiveTierPrompt.segment(lite ? '⑭ 起手式' : '⑮ 起手式', 'InteractiveTierPrompt.closing',
      InteractiveTierPrompt.closing(tier)));
    segs.push(InteractiveTierPrompt.segment(lite ? '⑮ 交互模式职责（交付形态，最后解释权）' :
      '⑯ 交互模式职责（交付形态，最后解释权）', 'InteractiveTierPrompt.duty',
      InteractiveTierPrompt.duty(tier)));
    return segs;
  }

  private static segment(name: string, source: string, text: string): InteractivePromptSegment {
    let seg: InteractivePromptSegment = new InteractivePromptSegment();
    seg.name = name;
    seg.source = source;
    seg.text = text;
    return seg;
  }

  // 组装整段系统提示词: 段间空行, 空段跳过。
  // body 为空(轻简档, 或档位主体 md 尚未加载成功)时: 轻简档本来就没有 body; 非轻简档由调用方
  // 负责回退(AgentLoopService 会退回轻简档, 避免拿到一份没有业务主体的"空壳档位")。
  static assemble(tierId: string, body: string, skillsSection: string, toolIndex: string): string {
    let segs: InteractivePromptSegment[] = InteractiveTierPrompt.segments(tierId, body, skillsSection, toolIndex);
    let parts: string[] = [];
    for (let i: number = 0; i < segs.length; i++) {
      if (segs[i].text !== '') {
        parts.push(segs[i].text);
      }
    }
    return parts.join('\n\n');
  }
}
