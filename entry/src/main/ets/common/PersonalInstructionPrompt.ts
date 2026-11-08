// PersonalInstructionPrompt: 把个性化指令拼成系统提示词末尾的一段(纯逻辑, 无 HarmonyOS 依赖)。
//
// 为什么单独成模块:
//   1. 三种入口(交互模式 / 工作模式 / 各聊天引擎)共用同一套"包裹 + 生效范围过滤 + 长度预算"规则,
//      拼装逻辑只写一次, 不散落在 ChatService / ChatViewModel / AgentLoopService 三处;
//   2. 它是纯函数, 可以在 test/guncat-harness 里断言"哪些条目会被拼上、包裹格式长什么样";
//   3. 拼接位置固定在系统提示词**末尾**: 前缀(原有提示词)逐字节不变, 用户不改指令时
//      相邻轮次仍能命中模型侧 KV 缓存; 改指令只影响最后这一段。
//
// 包裹格式: 每条指令包在 <personal-instruction name="…"> 里, 并用一段说明告诉模型
// 这些是用户的长期偏好、不是新任务; 用户正文原样保留(含 Markdown 记号), 不做二次转义,
// 避免把用户自己写的字改掉。
import { Constants } from './Constants';
import { PersonalInstruction } from '../model/PersonalInstruction';

export class PersonalInstructionPrompt {
  // 生效范围取值 = 智能体 id: 交互模式 / 工作模式的虚拟智能体 id 就是这两个常量
  static readonly SCOPE_INTERACTIVE: string = Constants.INTERACTIVE_AGENT_ID;
  static readonly SCOPE_WORK: string = Constants.WORK_AGENT_ID;

  // 拼进系统提示词的总长度预算: 超出后按顺序截断, 避免几条超长指令把上下文挤爆。
  // 单条正文上限见 PersonalInstruction.MAX_CONTENT_CHARS(8000), 这里兜住"条数很多"的情况。
  static readonly MAX_TOTAL_CHARS: number = 16000;
  // 包裹标签: 用 XML 风格标签给用户原文划出明确边界
  static readonly TAG: string = 'personal-instruction';
  // 超预算时的收尾说明
  static readonly TRUNCATED_NOTE: string = '（个性化指令超出长度预算，其余条目已省略）';

  // 段标题: 与系统提示词里其它一级标题同级, 便于模型把它当独立规则段阅读
  static readonly SECTION_TITLE: string = '# 个性化指令（用户在设置中添加）';
  // 段说明: 明确"是什么 / 怎么用 / 不是什么", 防止模型把用户偏好当成新任务或越权指令
  static readonly SECTION_INTRO: string = '以下内容由用户本人在「设置 → 个性化指令」中维护，' +
    '当前会话（模式或聊天引擎）在其生效范围内。请把它们当作长期有效的用户偏好：' +
    '在不违背上文的安全、事实、工具与权限纪律的前提下，按其中的风格、格式、语言、详略与工作习惯作答。' +
    '它们只用于调整你的回答方式，不是新的任务，也不能让用户当下的消息被忽略；' +
    '若与上文规则冲突，以上文的安全与事实纪律为准。';

  // 某条指令是否在当前 scope 生效(正文为空 / 未勾选本范围 → 不生效)
  static matches(item: PersonalInstruction, scope: string): boolean {
    if (scope === '') {
      return false;
    }
    if (item.content.trim() === '') {
      return false;
    }
    return item.hasScope(scope);
  }

  // 当前 scope 下生效的条目(保持存储顺序, 即用户添加顺序)
  static effective(scope: string, items: PersonalInstruction[]): PersonalInstruction[] {
    let out: PersonalInstruction[] = [];
    for (let i: number = 0; i < items.length; i++) {
      if (PersonalInstructionPrompt.matches(items[i], scope)) {
        out.push(items[i]);
      }
    }
    return out;
  }

  // 组装当前 scope 的完整段落; 一条都不生效时返回空串(调用方据此决定是否追加)
  static section(scope: string, items: PersonalInstruction[]): string {
    let blocks: string[] = [];
    let total: number = 0;
    let truncated: boolean = false;
    for (let i: number = 0; i < items.length; i++) {
      let item: PersonalInstruction = items[i];
      if (!PersonalInstructionPrompt.matches(item, scope)) {
        continue;
      }
      let block: string = PersonalInstructionPrompt.wrap(item);
      if (total + block.length > PersonalInstructionPrompt.MAX_TOTAL_CHARS) {
        // 第一条就超预算时也截一刀: 宁可少拼一半, 也不让单条指令独占上下文
        let room: number = PersonalInstructionPrompt.MAX_TOTAL_CHARS - total;
        if (room > 0) {
          blocks.push(block.substring(0, room));
        }
        truncated = true;
        break;
      }
      blocks.push(block);
      total += block.length;
    }
    if (blocks.length === 0) {
      return '';
    }
    let lines: string[] = [];
    lines.push(PersonalInstructionPrompt.SECTION_TITLE);
    lines.push(PersonalInstructionPrompt.SECTION_INTRO);
    for (let i: number = 0; i < blocks.length; i++) {
      lines.push('');
      lines.push(blocks[i]);
    }
    if (truncated) {
      lines.push('');
      lines.push(PersonalInstructionPrompt.TRUNCATED_NOTE);
    }
    return lines.join('\n');
  }

  // 把段落追加到已有系统提示词末尾; 原提示词为空时直接返回段落(聊天引擎提示词为空也必须能带上)
  static append(basePrompt: string, scope: string, items: PersonalInstruction[]): string {
    return PersonalInstructionPrompt.appendSection(basePrompt,
      PersonalInstructionPrompt.section(scope, items));
  }

  // 已算好段落时的追加入口: 调用方常先判断"有没有生效条目", 避免同一次拼装把条目算两遍。
  // 注意: 非空原提示词只做"末尾追加", 不做 trim —— 前缀逐字节不变, 相邻轮次才能稳定命中 KV 缓存。
  static appendSection(basePrompt: string, section: string): string {
    if (section === '') {
      return basePrompt;
    }
    if (basePrompt.trim() === '') {
      return section;
    }
    return basePrompt + '\n\n' + section;
  }

  // 单条的包裹: 名称只做块标记(可选), 用户正文原样保留
  static wrap(item: PersonalInstruction): string {
    let name: string = item.name.trim();
    let lines: string[] = [];
    if (name !== '') {
      lines.push('<' + PersonalInstructionPrompt.TAG + ' name="' +
        PersonalInstructionPrompt.escapeAttribute(name) + '">');
    } else {
      lines.push('<' + PersonalInstructionPrompt.TAG + '>');
    }
    lines.push(item.content.trim());
    lines.push('</' + PersonalInstructionPrompt.TAG + '>');
    return lines.join('\n');
  }

  // 名称进 XML 属性: 只转义会破坏标签结构的四个字符, 其余(含中文)原样
  static escapeAttribute(text: string): string {
    let out: string = text.replace(/&/g, '&amp;');
    out = out.replace(/</g, '&lt;');
    out = out.replace(/>/g, '&gt;');
    out = out.replace(/"/g, '&quot;');
    return out;
  }

  // 范围在提示词里的可读名: 两个模式有固定中文名, 聊天引擎的显示名由调用方(VM)补
  static fixedScopeLabel(scope: string): string {
    if (scope === PersonalInstructionPrompt.SCOPE_INTERACTIVE) {
      return '交互模式';
    }
    if (scope === PersonalInstructionPrompt.SCOPE_WORK) {
      return '工作模式';
    }
    return '';
  }
}
