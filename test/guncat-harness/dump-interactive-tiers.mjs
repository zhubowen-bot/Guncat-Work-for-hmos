// 导出「交互模式 · 能力调度」九个档位的完整系统提示词(分段结构 + 全文)。
//
// 用法: cd test/guncat-harness && node setup.mjs && node dump-interactive-tiers.mjs
// 产物: docs/prompts/interactive-tiers/*.md（每档一份 + README 索引）、docs/interactive-prompt-preview.md（轻简档预览）
//
// 为什么要有这个脚本(而不是手写文档): 档位提示词 = 代码共享层 + rawfile 档位主体 md 的组合,
// 嵌入代码后无法直接比对。这里从**真实模块**组装(与运行时同一个 assemble 入口), 把"用户最终看到的提示词"
// 原样导出, 既能 review 也能回归(轻简档的组装结果与旧四段组装逐字节一致, 脚本里有断言)。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { InteractiveTiers } from './gen/InteractiveTiers.ts';
import { InteractiveTierPrompt } from './gen/InteractiveTierPrompt.ts';
import { GuncatUiPrompt } from './gen/GuncatUiPrompt.ts';
import { GuncatUiLibrary } from './gen/GuncatUiLibrary.ts';
import { PromptBuilder } from './gen/PromptBuilder.ts';
import { PromptBudget } from './gen/PromptBudget.ts';
import { ToolRegistry } from './gen/ToolRegistry.ts';
import { SkillDirectoryFormatter } from './gen/SkillDirectoryFormatter.ts';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const rawfileDir = join(repoRoot, 'entry', 'src', 'main', 'resources', 'rawfile');
const outDir = join(repoRoot, 'docs', 'prompts', 'interactive-tiers');

// 与 WorkSkillService.interactiveIndex() 同源: visibleSkillList() 里被白名单命中的那几支
const skillList = [
  { id: 'ppt', name: 'PPT 制作与编辑', description: '', files: [] },
  { id: 'docx', name: 'Word 文档制作与编辑', description: '', files: [] },
  { id: 'xlsx', name: 'Excel 表格制作与编辑', description: '', files: [] },
  { id: 'svg', name: 'SVG 矢量绘图（生图）', description: '', files: [] },
  { id: 'data', name: '数据清洗与转换', description: '', files: [] },
];
const skills = SkillDirectoryFormatter.interactiveIndex(skillList);

// 工具名索引: 与 AgentLoopService.buildInteractiveSystemPrompt() 同源 —— 取该档位白名单筛出的工具名,
// 再按 buildToolNameIndex 排序(运行时取的是 filterInteractive 后的真实定义名, 这里取白名单名,
// 差别只有插件动态工具, 与旧 dump 脚本口径一致)。
function toolIndexFor(tierId) {
  const names = ToolRegistry.interactiveWhitelist(tierId).map((n) => ({ name: n }));
  return PromptBuilder.buildToolNameIndex(names);
}

function formatChars(n) {
  return n.toLocaleString('en-US');
}

// 轻简档回归: 组装结果必须与原来的四段组装逐字节一致(改坏这里会立刻被这个断言拦住)
const liteToolIndex = toolIndexFor(InteractiveTiers.LITE_ID);
const liteOld = PromptBuilder.assembleInteractiveSystemPrompt(
  GuncatUiPrompt.promptSection(), skills, liteToolIndex, GuncatUiPrompt.INTERACTIVE_DUTY);
const liteNew = InteractiveTierPrompt.assemble(InteractiveTiers.LITE_ID, '', skills, liteToolIndex);
if (liteOld !== liteNew) {
  throw new Error('轻简档组装结果与旧四段组装不一致(应逐字节相同): ' +
    liteOld.length + ' vs ' + liteNew.length);
}

mkdirSync(outDir, { recursive: true });

const indexRows = [];
const tierSummaries = [];

for (let ti = 0; ti < InteractiveTiers.ALL.length; ti++) {
  const tier = InteractiveTiers.ALL[ti];
  const seq = String(ti + 1).padStart(2, '0');
  let body = '';
  if (tier.promptFile !== '') {
    try {
      body = readFileSync(join(rawfileDir, tier.promptFile), 'utf8');
    } catch (e) {
      throw new Error('档位主体缺失: rawfile/' + tier.promptFile + '(档位 ' + tier.id + ')');
    }
    if (body.trim() === '') {
      throw new Error('档位主体为空: rawfile/' + tier.promptFile);
    }
  }
  const toolIndex = toolIndexFor(tier.id);
  const assembled = InteractiveTierPrompt.assemble(tier.id, body, skills, toolIndex);
  const segs = InteractiveTierPrompt.segments(tier.id, body, skills, toolIndex);
  // 自检: 段的拼接就是最终提示词(防止"导出的结构"与"运行时拼接"分叉)
  const rebuilt = segs.filter((s) => s.text !== '').map((s) => s.text).join('\n\n');
  if (rebuilt !== assembled) {
    throw new Error('档位 ' + tier.id + ': segments 拼接与 assemble 结果不一致');
  }
  const totalChars = assembled.length;
  const totalTokens = PromptBudget.estimateTokens(assembled);
  const tierToolCount = ToolRegistry.interactiveWhitelist(tier.id).length;

  const out = [];
  out.push('# 交互模式 · 能力调度档位「' + tier.name + '」系统提示词（完整导出）');
  out.push('');
  out.push('> 本文件由 `test/guncat-harness/dump-interactive-tiers.mjs` 从**真实模块 + rawfile 档位主体**组装导出，' +
    '与运行时 `AgentLoopService.buildInteractiveSystemPrompt(tier)` 走同一个 `InteractiveTierPrompt.assemble()` 入口。');
  out.push('> 与本机运行时的差别只有两处：技能段用真实的 5 支格式技能；工具名索引取该档位白名单对应的工具名（插件动态工具不在其中）。');
  out.push('');
  out.push('## 档位元数据');
  out.push('');
  out.push('| 项 | 值 |');
  out.push('| --- | --- |');
  out.push('| 档位 id | `' + tier.id + '` |');
  out.push('| 名称 | ' + tier.name + ' |');
  out.push('| 定位 | ' + tier.tagline + ' |');
  out.push('| 移植来源 | ' + (tier.sourceFile !== '' ? '`' + tier.sourceFile + '`' : '无（轻简档复用原交互模式提示词）') + ' |');
  out.push('| 档位主体文件 | ' + (tier.promptFile !== '' ? '`rawfile/' + tier.promptFile + '`' : '无') + ' |');
  out.push('| 默认思考强度 | `' + tier.defaultEffort + '` |');
  out.push('| 档位追加工具 | ' + (tier.extraTools.length > 0 ? tier.extraTools.map((n) => '`' + n + '`').join(' / ') : '无') + ' |');
  out.push('| 交互工具面 | ' + tierToolCount + ' 个工具 |');
  out.push('| 字符数 | ' + formatChars(totalChars) + ' |');
  out.push('| 估算 tokens | 约 ' + formatChars(totalTokens) + ' |');
  out.push('');
  out.push('## 结构一览（按拼接顺序）');
  out.push('');
  out.push('| # | 段 | 来源 | 字符 |');
  out.push('| ---: | --- | --- | ---: |');
  for (let i = 0; i < segs.length; i++) {
    out.push('| ' + (i + 1) + ' | ' + segs[i].name + ' | `' + segs[i].source + '` | ' +
      formatChars(segs[i].text.length) + ' |');
  }
  out.push('| | **合计** | | **' + formatChars(totalChars) + '** |');
  out.push('');
  out.push('---');
  out.push('');
  for (let i = 0; i < segs.length; i++) {
    if (segs[i].text === '') {
      continue;
    }
    out.push('## ' + segs[i].name + '　`' + formatChars(segs[i].text.length) + ' 字符`');
    out.push('');
    out.push('```text');
    out.push(segs[i].text);
    out.push('```');
    out.push('');
  }
  const file = seq + '-' + tier.id + '.md';
  writeFileSync(join(outDir, file), out.join('\n'), 'utf8');
  indexRows.push('| ' + (ti + 1) + ' | ' + tier.name + ' | ' + (tier.sourceFile !== '' ? '`' + tier.sourceFile.replace('.md', '') + '`' : '—（原交互模式提示词）') +
    ' | ' + (tier.promptFile !== '' ? '`' + tier.promptFile + '`' : '—') +
    ' | `' + tier.defaultEffort + '` | ' + tierToolCount + ' | ' + formatChars(totalChars) + ' | [查看](' + file + ') |');
  tierSummaries.push({ id: tier.id, name: tier.name, chars: totalChars, tokens: totalTokens, segs: segs.length, file });
  console.log('导出', file, totalChars, '字符,', totalTokens, 'tokens');
}

// README 索引
const readme = [];
readme.push('# 交互模式 · 能力调度档位提示词（完整导出）');
readme.push('');
readme.push('> 这些文件是**运行时真正拼出来的系统提示词**，不是设计稿。重新生成：');
readme.push('> `cd test/guncat-harness && node setup.mjs && node dump-interactive-tiers.mjs`');
readme.push('');
readme.push('## 档位一览');
readme.push('');
readme.push('| # | 档位 | 移植来源 | 档位主体 | 默认思考 | 工具面 | 字符数 | 全文 |');
readme.push('| ---: | --- | --- | --- | --- | ---: | ---: | --- |');
for (const row of indexRows) {
  readme.push(row);
}
readme.push('');
readme.push('## 分层结构（九个档位共用同一套骨架）');
readme.push('');
readme.push('| 段 | 内容 | 轻简 | 其余八档 |');
readme.push('| --- | --- | --- | --- |');
readme.push('| ① 档位声明 | 身份 + 第一纪律 + 工具面政策 + 思考政策 + 丰富度口径（唯一的一级标题） | 原 `interactivePrime()`（逐字节复用） | `InteractiveTierPrompt.tierPrime()` 按档生成 |');
readme.push('| ②~⑨ 界面语言契约 | guncat-ui 语法 / 组件清单（库内注册 77、清单可见 75；由 GuncatUiLibrary 生成）/ 丰富度 / 交互闭环 / 流式顺序 / 示例 / 反例 | 原文 | 原文（丰富度数量口径换为「越多越好」） |');
readme.push('| ⑩ 档位主体 | 原聊天引擎提示词的适配版（角色/思维链/工作流/反幻觉/模板/知识库） | 无 | `rawfile/interactive-tier-*.md` |');
readme.push('| ⑪~⑭ 环境底座 | 工作区 / 本档工具面 / 真实数据纪律 / 技能索引 | 素材区口径 | 素材区 + 产出区口径 |');
readme.push('| ⑮ 起手式 | 进入执行的最后一句引导 | 原句 | 档位版 |');
readme.push('| ⑯ 交付形态职责 | 程序之外不写文字 / 往丰富一侧 / 冲突裁决（最后解释权） | 原文 | 档位版 |');
readme.push('');
readme.push('> 组装顺序由 `InteractiveTierPrompt.segments()` 单一事实源固定；轻简档的组装结果与旧的四段组装**逐字节一致**' +
  '（导出脚本里有断言）。分层设计与适配说明见 [提示词适配说明](../interactive-tier-adaptation.md)。');
writeFileSync(join(outDir, 'README.md'), readme.join('\n'), 'utf8');

// 轻简档预览(保持 docs/interactive-prompt-preview.md 与当前实现同步)
const liteSegs = InteractiveTierPrompt.segments(InteractiveTiers.LITE_ID, '', skills, liteToolIndex);
const preview = [];
preview.push('# 交互模式系统提示词 · 实际结构与全文（轻简档 / 能力调度默认档）');
preview.push('');
preview.push('> 由 `test/guncat-harness/dump-interactive-tiers.mjs` 从真实模块导出。轻简档 = 原交互模式提示词，' +
  '与旧四段组装逐字节一致；其余档位见 [能力调度档位导出](prompts/interactive-tiers/README.md)。');
preview.push('');
preview.push('## 结构一览（按拼接顺序）');
preview.push('');
preview.push('| # | 段 | 来源 | 字符 |');
preview.push('| ---: | --- | --- | ---: |');
for (let i = 0; i < liteSegs.length; i++) {
  preview.push('| ' + (i + 1) + ' | ' + liteSegs[i].name + ' | `' + liteSegs[i].source + '` | ' +
    formatChars(liteSegs[i].text.length) + ' |');
}
preview.push('| | **合计** | | **' + formatChars(liteNew.length) + '** |');
preview.push('');
preview.push('> 拼接方式：`InteractiveTierPrompt.assemble(\'lite\', \'\', skills, toolIndex)` —— 顺序由 `InteractiveTierPrompt.segments()` 固定，' +
  '段间以空行相连，整体静态、进程内按档位缓存一次。');
preview.push('');
preview.push('---');
preview.push('');
for (let i = 0; i < liteSegs.length; i++) {
  if (liteSegs[i].text === '') {
    continue;
  }
  preview.push('## ' + liteSegs[i].name + '　`' + formatChars(liteSegs[i].text.length) + ' 字符`');
  preview.push('');
  preview.push('```text');
  preview.push(liteSegs[i].text);
  preview.push('```');
  preview.push('');
}
writeFileSync(join(repoRoot, 'docs', 'interactive-prompt-preview.md'), preview.join('\n'), 'utf8');
console.log('导出 docs/interactive-prompt-preview.md（轻简档）');
console.log('完成: 共', InteractiveTiers.ALL.length, '个档位');
