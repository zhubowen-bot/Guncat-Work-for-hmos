// 一次性脚本: 导出交互模式系统提示词的实际结构(分段 + 体积 + 全文)。
// 用法: node setup.mjs && node dump-interactive-prompt.mjs > ../../build/interactive-prompt-preview.md
// 说明: 组件库/语法/丰富度/示例/反例/职责全部来自真实模块;
//       工具名索引取 ToolRegistry.INTERACTIVE_TOOL_WHITELIST(与请求里真正下发的 27 个工具名一致);
//       技能段用真实的 5 支格式技能(id + 名称 + 注册顺序)。
import { GuncatUiPrompt } from './gen/GuncatUiPrompt.ts';
import { GuncatUiLibrary } from './gen/GuncatUiLibrary.ts';
import { PromptBuilder } from './gen/PromptBuilder.ts';
import { ToolRegistry } from './gen/ToolRegistry.ts';
import { SkillDirectoryFormatter } from './gen/SkillDirectoryFormatter.ts';

// 与 WorkSkillService.interactiveIndex() 同源: visibleSkillList() 里被白名单命中的那几支
const skillList = [
  { id: 'ppt', name: 'PPT 制作与编辑', description: '', files: [] },
  { id: 'docx', name: 'Word 文档制作与编辑', description: '', files: [] },
  { id: 'xlsx', name: 'Excel 表格制作与编辑', description: '', files: [] },
  { id: 'svg', name: 'SVG 矢量绘图（生图）', description: '', files: [] },
  { id: 'data', name: '数据清洗与转换', description: '', files: [] }
];
const skills = SkillDirectoryFormatter.interactiveIndex(skillList);

// 与 AgentLoopService.interactiveToolDefs() 同源: 裁剪后的工具名(排序后拼成索引)
const defs = ToolRegistry.INTERACTIVE_TOOL_WHITELIST.map((n) => ({ 'name': n }));
const toolIndex = PromptBuilder.buildToolNameIndex(defs);

const segs = [
  ['① 身份与输出形态(开场)', GuncatUiPrompt.PREAMBLE],
  ['② 语法规则 + 表达式能力', GuncatUiPrompt.SYNTAX],
  ['③ 组件清单(76 个, 由 GuncatUiLibrary 生成)', GuncatUiLibrary.promptSection()],
  ['④ 丰富度(选择优先级 + 分层配方 + 合格/不合格对照)', GuncatUiPrompt.RICHNESS],
  ['⑤ 交互闭环(本地绑定 / 回传助手 / Action / 表单)', GuncatUiPrompt.INTERACTION],
  ['⑥ 输出顺序与流式渲染', GuncatUiPrompt.STREAMING],
  ['⑦ 输出形态正反例 + 完整示例 ×2', GuncatUiPrompt.EXAMPLES],
  ['⑧ 最常见的错误(自查清单)', GuncatUiPrompt.ANTI_PATTERNS],
  ['⑨ 快车道底座 · 身份(你是谁 / 第一纪律: 快 / 思考纪律: 短)', PromptBuilder.interactiveIdentity()],
  ['⑩ 快车道底座 · 工作区(素材区)', PromptBuilder.interactiveWorkspace()],
  ['⑪ 快车道底座 · 可用工具(裁剪后 27 个)', PromptBuilder.interactiveTools(toolIndex)],
  ['⑫ 快车道底座 · 真实数据纪律', PromptBuilder.interactiveTruth()],
  ['⑬ 技能库(极小索引: 5 支格式技能)', skills],
  ['⑭ 交互模式职责(交付形态, 最后解释权)', GuncatUiPrompt.INTERACTIVE_DUTY]
];

let total = 0;
const out = [];
out.push('# 交互模式系统提示词 · 实际结构与全文');
out.push('');
out.push('> 由 `test/guncat-harness/dump-interactive-prompt.mjs` 从真实模块导出（与本机运行时的差别只有：技能段用真实的 5 支格式技能、工具名索引取裁剪后的 27 个工具名）。');
out.push('');
out.push('## 结构一览（按拼接顺序）');
out.push('');
out.push('| # | 段 | 来源 | 字符 |');
out.push('| ---: | --- | --- | ---: |');
for (let i = 0; i < segs.length; i++) {
  total += segs[i][1].length;
  out.push('| ' + (i + 1) + ' | ' + segs[i][0] + ' | `' + (i < 8 ? 'GuncatUiPrompt' : (i < 12 ? 'PromptBuilder' : (i === 12 ? 'SkillDirectoryFormatter' : 'GuncatUiPrompt'))) + '` | ' + segs[i][1].length + ' |');
}
out.push('| | **合计** | | **' + total + '** |');
out.push('');
out.push('> 拼接方式：`AgentLoopService.buildInteractiveSystemPrompt()` = ① ~ ⑧ + 底座的 ⑨ ~ ⑬ + ⑭（段间以空行相连），整体静态、进程内缓存一次。');
out.push('');
out.push('---');
out.push('');
for (let i = 0; i < segs.length; i++) {
  out.push('## ' + segs[i][0] + '　`' + segs[i][1].length + ' 字符`');
  out.push('');
  out.push('```text');
  out.push(segs[i][1]);
  out.push('```');
  out.push('');
}
const tools = ToolRegistry.filterInteractive(defs).map((d) => d['name']);
out.push('---');
out.push('');
out.push('## 附：这一版裁剪后真正下发到请求里的 ' + tools.length + ' 个工具');
out.push('');
out.push(tools.map((t) => '`' + t + '`').join(' · '));
out.push('');
out.push('> 完整的 45 个工具名与被裁掉的 18 个（`todo_write` / `goal_*` / `schedule_*` / `subagent` / `session_search` /');
out.push('> `ask_user_question` / `edit` / `str_replace_editor` / `delete_file` / `move_file` / `edit_docx|edit_xlsx|edit_ppt` /');
out.push('> `record_search`）见 `test-core.mjs` 的 `allToolNames` 数组与 `ToolRegistry.INTERACTIVE_TOOL_WHITELIST`。');
out.push('');
console.log(out.join('\n'));
