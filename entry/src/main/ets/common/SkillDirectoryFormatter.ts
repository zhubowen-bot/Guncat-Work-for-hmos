// SkillDirectoryFormatter: 技能目录提示词格式化(纯逻辑, 无 HarmonyOS 依赖)
// 支持两种目录模式:
//   full_index   → 完整技能清单(触发条件)直接进系统提示词(默认, 命中即先 load_skill)
//   trigger_only → 只保留一句触发提示, 模型经 list_skills 自行发现(渐进披露, 省 token)
import { SkillMeta } from './ToolRegistry';

export class SkillDirectoryFormatter {
  static readonly MODE_FULL_INDEX: string = 'full_index';
  static readonly MODE_TRIGGER_ONLY: string = 'trigger_only';

  // 技能使用铁律：提升技能优先级，避免模型“觉得自己会”而跳过技能
  static skillPriorityRules(): string {
    return '## 技能使用铁律（最高优先级，先于你自己的通用能力）\n' +
      '1. **命中即加载**：任务命中任一技能（主 Skill 或格式分支）的领域/触发词时，**第一步必须是 load_skill**；未加载前禁止开始处理。\n' +
      '2. **不确定也先查**：无法确定是否命中时，先 list_skills 检查清单再判断；禁止凭“我本来就会”或“这很简单”跳过技能。\n' +
      '3. **主 Skill 优先**：命中的是主 Skill 覆盖领域时，先 load_skill("<主 Skill>")，再按其中 ROUTING.md 进入分支；不要直接猜分支。\n' +
      '4. **技能正文优先**：技能正文 > 你的默认做法 > 通用知识；技能要求的前置提问、检索、全量加载、自检等步骤不可跳过。\n' +
      '5. **未加载视为违规**：若最终产出属于技能覆盖范围却未加载技能，视为执行错误；发现后立即补加载并按技能重做。\n';
  }

  // list_skills 输出: 技能清单(含触发语义与文件索引)
  static listText(list: SkillMeta[]): string {
    if (list.length === 0) {
      return '(当前没有可用技能)';
    }
    let out: string = '可用技能(用 load_skill(name) 加载正文, load_skill(name, file) 加载参考文件)：\n';
    out += SkillDirectoryFormatter.skillPriorityRules();
    out += '命中下列任一技能的触发条件时，**第一步必须 load_skill 加载对应技能**，未加载前不要自行处理。\n';
    for (let i: number = 0; i < list.length; i++) {
      let s: SkillMeta = list[i];
      out += '\n- ' + s.id + ' — ' + s.name + '\n  触发: ' + s.description + '\n  文件: SKILL.md(正文)';
      for (let f: number = 0; f < s.files.length; f++) {
        out += ', ' + s.files[f].file + '(' + s.files[f].desc + ')';
      }
      if (s.id === 'ppt' || s.id === 'docx' || s.id === 'xlsx') {
        out += '\n  注意: ' + s.id + ' 为全量必读技能，必须 load_skill("' + s.id + '") 一次加载 SKILL.md + 全部 reference，禁止按需挑读。';
      }
      out += '\n';
    }
    return out;
  }

  // 完整索引: id/名称/触发条件直接暴露在系统提示词, 促成"命中即先 load_skill"
  static fullIndex(list: SkillMeta[]): string {
    if (list.length === 0) {
      return '';
    }
    let out: string = '# 技能库（命中领域的任务，第一步先加载技能）\n';
    out += SkillDirectoryFormatter.skillPriorityRules();
    out += '下面列出全部可用技能及其触发条件。任务命中某技能的触发条件时，**必须先 load_skill 加载该技能再动手**，按其方法论执行；';
    out += '技能正文优先于你的默认做法，也优先于"直接搜索后凭通用知识作答"——技能规定要检索的信息缺口，再用搜索/读文件工具按技能的要求补足。';
    out += '技能内的参考文件：若技能正文要求全量加载（如 ppt/docx/xlsx），必须一次 load_skill(name) 读取全部参考，不得挑读；未要求全量时按需加载。\n';
    for (let i: number = 0; i < list.length; i++) {
      let s: SkillMeta = list[i];
      out += '\n- ' + s.id + ' — ' + s.name + '\n  触发: ' + s.description + '\n';
    }
    return out;
  }

  // 触发提示: 渐进披露, 不列清单; 模型需要时经 list_skills 查看
  static triggerOnly(): string {
    return '# 技能库（命中领域的任务，第一步先加载技能）\n' +
      SkillDirectoryFormatter.skillPriorityRules() +
      '系统内置多个领域技能。任务命中某个领域（演示文稿/Word/Excel/SVG/研究/信息溯源/模型评测等）时，' +
      '先用 list_skills 查看可用技能，再 load_skill 加载对应技能正文后按其方法论执行；技能正文优先于默认做法。\n';
  }

  // ===== 交互模式: 极小技能索引 =====
  //
  // 工作模式的技能库整段注入(几十支技能的触发词)对交互模式毫无用处 —— 交互模式的产出是界面,
  // **做界面不需要任何技能**。这里只留"真要产出文件时才会用到"的几支格式技能,
  // 让模型连"我是不是该先加载个技能"这个念头都不会起。
  // **新增技能默认不进交互模式**(与工具白名单同一口径)。
  static readonly INTERACTIVE_SKILL_IDS: string[] = ['docx', 'xlsx', 'ppt', 'svg', 'data'];

  // 交互模式技能段: 正常情况下**一个都不加载**, 只有明确要导出文件时才加载对应格式技能
  static interactiveIndex(list: SkillMeta[]): string {
    let out: string = '# 技能库（默认一个都不加载）\n' +
      '交互模式的产出是界面, **做界面不需要任何技能**。只有用户**明确**要产出 Word / Excel / PPT / SVG 文件, ' +
      '或明确要转换工作区里的数据文件时, 才 `load_skill` 加载下面这一支 —— 然后直接产出, 不要走技能里的前置提问。\n';
    for (let i: number = 0; i < list.length; i++) {
      let s: SkillMeta = list[i];
      if (SkillDirectoryFormatter.INTERACTIVE_SKILL_IDS.indexOf(s.id) !== -1) {
        out += '- ' + s.id + ' — ' + s.name + '\n';
      }
    }
    out += '其余技能（研究 / 写作 / 法律 / AI 工程 …）在交互模式下一律不用; ' +
      '也不要为了"看看有什么技能"去 `list_skills`。';
    return out;
  }

  static format(list: SkillMeta[], mode: string): string {
    if (mode === SkillDirectoryFormatter.MODE_TRIGGER_ONLY) {
      return SkillDirectoryFormatter.triggerOnly();
    }
    return SkillDirectoryFormatter.fullIndex(list);
  }
}
