// InteractiveTiers: 交互模式「能力调度」档位元数据(纯逻辑, 无 HarmonyOS 依赖)。
//
// 背景: 交互模式原有一份"为快而生"的快车道提示词(agent loop 架构工程师设计), 聊天引擎另有一批
// 由提示词工程师打磨的智能体提示词。交互模式把后者吸收成可调档位:
//   - 轻简档 = 原封不动复用原快车道提示词(不迁移, 没有档位主体 md);
//   - 其余八档 = 原聊天引擎提示词的**主体** + 交互模式共享层(界面语言契约/丰富度/环境/工具/职责)。
//
// 本文件只放"元数据": 档位 id/名称/来源/适配后的主体文件/默认思考强度/档位追加工具。
// 真正的提示词文本由 InteractiveTierPrompt(共享层组装) + rawfile 档位主体 md(迁移内容)组成。
// 排序即设置页与导出文档的顺序: 轻简(最快) → 效率 → 专家 → 经典 → 论文转换 → 法律检索 → 深度研究
// → 信息筛滤 → LLM评估。
//
// 维护约定:
//   1. 增删档位时同步 InteractiveTierPrompts(加载) / ToolRegistry(追加工具) / 设置页(ForEach 自本表生成) /
//      test/guncat-harness/dump-interactive-tiers.mjs(导出);
//   2. 档位主体 md 的适配规则见 docs/prompts/interactive-tier-adaptation.md;
//   3. 轻简档不迁移, 它的行为纪律仍由 PromptBuilder.interactivePrime() 承担, 不要在这里给它加主体文件。

export class InteractiveTier {
  // 稳定 id(持久化与代码分支用, 不要改名)
  id: string = '';
  // 设置页显示名(与聊天引擎智能体名一一对应)
  name: string = '';
  // 源智能体/源提示词的简短署名(展示与溯源用, 如 "Guncat 3.0-Flash")
  sourceAgent: string = '';
  // 设置页一行副标题(能力定位)
  tagline: string = '';
  // 设置页详情说明(2~3 句: 适合什么、移植自哪里、量级)
  description: string = '';
  // 源提示词文件名(rawfile 下的原始聊天智能体提示词, 仅溯源, 运行时不读)
  sourceFile: string = '';
  // 适配后的档位主体 md(rawfile 文件名; 轻简档为空 = 不迁移)
  promptFile: string = '';
  // 切到本档位时推荐的交互模式思考强度: 'off' | 'low' | 'high'
  defaultEffort: string = '';
  // 在交互模式基础 27 个工具面之上为本档位追加的工具(空数组 = 与轻简档一致)
  extraTools: string[] = [];
}

export class InteractiveTiers {
  // 轻简档 id: 原封不动复用现有交互模式提示词(默认档位, 不迁移)
  static readonly LITE_ID: string = 'lite';
  // 未设置/未知档位时的回退
  static readonly DEFAULT_ID: string = 'lite';

  // 设置页与导出文档的顺序 = 能力由轻到重
  static readonly ALL: InteractiveTier[] = InteractiveTiers.buildAll();

  private static buildAll(): InteractiveTier[] {
    let tiers: InteractiveTier[] = [];
    tiers.push(InteractiveTiers.make('lite', '轻简', '交互模式快车道', '通用调度策略·轻量快速',
      '默认零工具、思考较短, 追求快速问答，一句话直接出界面。' +
        '适用于大多数日常问答请求。',
      '', '', 'low', []));
    tiers.push(InteractiveTiers.make('efficiency', '效率', 'Guncat 3.0-Flash', '通用调度策略·轻量全能',
      '融合多轮搜索、多步推理与行业领先的反幻觉体系, ' +
        '以较少的提示词工程量实现接近专家档的综合能力。适用于日常专业请求。',
      'Guncat 3.0-Flash_prompt_ZH_CN.md', 'interactive-tier-efficiency.md', 'low', ['record_search']));
    tiers.push(InteractiveTiers.make('expert', '专家', 'Guncat 3.0-Pro', '通用调度策略·超级全能',
      '融合多轮搜索、多步推理、全系专家能力与行业领先的反幻觉体系, ' +
        '五大领域专家能力内化在单体里。适用于复杂推理、跨领域综合与高要求回复。',
      'Guncat 3.0-Pro_prompt_ZH_CN.md', 'interactive-tier-expert.md', 'high',
      ['record_search', 'todo_write']));
    tiers.push(InteractiveTiers.make('classic', '经典', 'Guncat 2.5-lite', '通用调度策略·轻量详尽',
      '以最小的提示词工程量实现内容的长输出, ' +
        '执行开销小但输出内容详尽。适合需要条理与完整结构的常规任务。',
      'Guncat 2.5-lite _prompt.md', 'interactive-tier-classic.md', 'high', ['record_search']));
    tiers.push(InteractiveTiers.make('paper', '论文转换', 'Guncat Cnvt-Paper', '专家能力调度·论文转换',
      '提供任意文体材料，即可按学术规范重写为论文。' +
        '适合课程论文、文献综述、开题报告、期刊投稿等改写需求。',
      'Guncat Cnvt-Paper_prompt.md', 'interactive-tier-paper.md', 'low', []));
    tiers.push(InteractiveTiers.make('legal', '法律检索', 'Guncat Srch-Law', '专家能力调度·法律检索',
      '法律事务专家, 通过强制实时法规检索和深度分析, ' +
        '输出逐节完整的结构化法律意见书。',
      'Guncat Srch-Law V1.0-prompt.md', 'interactive-tier-legal.md', 'high',
      ['record_search', 'todo_write']));
    tiers.push(InteractiveTiers.make('research', '深度研究', 'Guncat Srch-Research', '专家能力调度·深度研究',
      '进行跨领域多轮检索与多源交叉验证, ' +
        '输出带来源验证矩阵的完整研究报告。',
      'Guncat Srch-Research-prompt.md', 'interactive-tier-research.md', 'high',
      ['record_search', 'todo_write']));
    tiers.push(InteractiveTiers.make('sift', '信息筛滤', 'Guncat Srch-Sift', '专家能力调度·信息筛滤',
      '通过九步深度搜索法、官方渠道溯源与 AI 内容过滤, ' +
        '把AI噪声、不可靠信源、过时数据等压到最低再给结论。',
      'Guncat Srch-Sift-prompt.md', 'interactive-tier-sift.md', 'high', ['record_search']));
    tiers.push(InteractiveTiers.make('eval', 'LLM评估', 'Guncat Eval-LLM', '专家能力调度·LLM评估',
      '按严格工作流与评估维度对大语言模型的综合能力做可核验的评估, ' +
        '极大地减少模型评估中时间与代际的幻觉问题，确保所有事实有来源、结论有置信度。',
      'Guncat Eval-LLM_prompt.md', 'interactive-tier-eval.md', 'high',
      ['record_search', 'todo_write']));
    return tiers;
  }

  private static make(id: string, name: string, sourceAgent: string, tagline: string,
    description: string, sourceFile: string, promptFile: string, defaultEffort: string,
    extraTools: string[]): InteractiveTier {
    let tier: InteractiveTier = new InteractiveTier();
    tier.id = id;
    tier.name = name;
    tier.sourceAgent = sourceAgent;
    tier.tagline = tagline;
    tier.description = description;
    tier.sourceFile = sourceFile;
    tier.promptFile = promptFile;
    tier.defaultEffort = defaultEffort;
    tier.extraTools = extraTools;
    return tier;
  }

  // 按 id 取档位; 未知 id 回退轻简档(持久化里出现旧值/脏值时不能把交互模式打崩)
  static byId(id: string): InteractiveTier {
    for (let i: number = 0; i < InteractiveTiers.ALL.length; i++) {
      if (InteractiveTiers.ALL[i].id === id) {
        return InteractiveTiers.ALL[i];
      }
    }
    return InteractiveTiers.ALL[0];
  }

  // 规范化持久化值: 只接受已登记的 id, 其余(空串/旧值/脏值)一律回退默认档
  static normalize(id: string): string {
    for (let i: number = 0; i < InteractiveTiers.ALL.length; i++) {
      if (InteractiveTiers.ALL[i].id === id) {
        return id;
      }
    }
    return InteractiveTiers.DEFAULT_ID;
  }

  static isLite(id: string): boolean {
    return InteractiveTiers.normalize(id) === InteractiveTiers.LITE_ID;
  }

  static nameOf(id: string): string {
    return InteractiveTiers.byId(id).name;
  }

  // 合法的思考强度(与 ChatViewModel.interactiveEffort 的取值域一致)
  static isValidEffort(effort: string): boolean {
    return effort === 'off' || effort === 'low' || effort === 'high';
  }
}
