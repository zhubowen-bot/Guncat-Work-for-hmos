// SkillDirectoryFormatter: 技能目录提示词格式化(纯逻辑, 无 HarmonyOS 依赖)
// 支持两种目录模式:
//   full_index   → 完整技能清单(触发条件)直接进系统提示词(默认, 命中即先 load_skill)
//   trigger_only → 只保留一句触发提示, 模型经 list_skills 自行发现(渐进披露, 省 token)
import { SkillMeta } from './ToolRegistry.ts';

export class SkillDirectoryFormatter {
  static readonly MODE_FULL_INDEX: string = 'full_index';
  static readonly MODE_TRIGGER_ONLY: string = 'trigger_only';

  // list_skills 输出: 技能清单(含触发语义与文件索引)
  static listText(list: SkillMeta[]): string {
    if (list.length === 0) {
      return '(当前没有可用技能)';
    }
    let out: string = '可用技能(用 load_skill(name) 加载正文, load_skill(name, file) 加载参考文件):\n';
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
      '系统内置多个领域技能。任务命中某个领域（演示文稿/Word/Excel/SVG/研究/信息溯源/模型评测等）时，' +
      '先用 list_skills 查看可用技能，再 load_skill 加载对应技能正文后按其方法论执行；技能正文优先于默认做法。\n';
  }

  static format(list: SkillMeta[], mode: string): string {
    if (mode === SkillDirectoryFormatter.MODE_TRIGGER_ONLY) {
      return SkillDirectoryFormatter.triggerOnly();
    }
    return SkillDirectoryFormatter.fullIndex(list);
  }
}
