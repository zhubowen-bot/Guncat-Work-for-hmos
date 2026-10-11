// 交互模式卡片文字"长按自由复制"的回归护栏。
//
// 背景: GuncatUiView 把 guncat-ui lang 程序渲染成原生界面, 界面里的文字是**内容**
// (模型写出来的标题/正文/表格单元/指标值…), 用户常要长按选中摘出来用。ArkUI 的
// Text 默认 copyOption = CopyOptions.None(不可复制), 所以每个内容型 Text 都必须显式挂
// `.copyOption(CopyOptions.LocalDevice)` —— 官方语义是"长按文本会弹出文本选择菜单,
// 可选中文本并进行复制、全选操作"。
//
// 为什么需要这个脚本: 组件很多(70+ 个 Text), 而且每隔几轮就会新增组件。漏挂一个不会
// 报错、也不会崩, 只会让那块文字"长按没反应"——正是本护栏要防的那种静默回归。
// 第 3 层真实编译(tools/build-check.ps1)也拦不住它: 那只是"语法合法"。
//
// 判定规则:
//   - 每个 `Text(` 开头的链要么含 `.copyOption(CopyOptions.LocalDevice)`, 要么在
//     `Text(` 那一行以行尾 `// copy-off: 原因` 显式豁免;
//   - 豁免只给**交互控件标签**(按钮 / 选项卡 / 单选多选药丸 / 下拉项 / 标签选项 /
//     折叠触发器 / 追问胶囊 / 行内动作 / 序号圆点): 它们的整块区域就是点击热区, 挂上
//     选择能力会跟自己的点击事件抢手势(社区与真机都出现过"点了没反应, 只有长按出复制");
//   - 豁免必须写清原因(空原因的 copy-off 视为违规), 免得它被当成"随手跳过检查"的开关。
//
// 覆盖范围刻意只到 GuncatUiView.ets: GuncatUiCharts.ets / GuncatUiIcons.ets 里的 Text 是
// 坐标轴刻度、图例、图标字形这类**装饰性微标签**(字号 9~11、被自绘布局紧约束), 对它们做
// 长按选区既没有可读性也容易和图表手势打架, 属于有意排除。
//
// 用法(在仓库根目录或本目录都可以):
//   node test/guncat-harness/check-ui-copy.mjs
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const target = process.argv[2] !== undefined
  ? process.argv[2]
  : join(repoRoot, 'entry', 'src', 'main', 'ets', 'views', 'GuncatUiView.ets');

const COPY_ON = '.copyOption(CopyOptions.LocalDevice)';

const source = readFileSync(target, 'utf8');
const lines = source.split('\n');

// 括号/中括号/大括号的净深度: 用来判断一条链有没有走完(链里可能有 `.onClick(() => { … })`)
function balance(line) {
  let depth = 0;
  for (const ch of line) {
    if (ch === '(' || ch === '[' || ch === '{') {
      depth++;
    } else if (ch === ')' || ch === ']' || ch === '}') {
      depth--;
    }
  }
  return depth;
}

// 一条 Text 链的行区间: 深度未归零就继续, 或下一行以 `.` 续接
function chainEnd(start) {
  let depth = balance(lines[start]);
  let end = start;
  while (end + 1 < lines.length) {
    const continues = depth > 0 || /^\s*\./.test(lines[end + 1]);
    if (!continues) {
      break;
    }
    end++;
    depth += balance(lines[end]);
  }
  return end;
}

const failures = [];
let copyable = 0;
let exempt = 0;

for (let i = 0; i < lines.length; i++) {
  if (!/^\s*Text\(/.test(lines[i])) {
    continue;
  }
  const end = chainEnd(i);
  const chain = lines.slice(i, end + 1).join('\n');
  const markerAt = lines[i].indexOf('// copy-off:');
  if (markerAt >= 0) {
    const reason = lines[i].substring(markerAt + '// copy-off:'.length).trim();
    if (reason === '') {
      failures.push(`第 ${i + 1} 行: copy-off 豁免没有写原因 —— 豁免必须写明"为什么这块不是内容文字"`);
    }
    if (chain.includes(COPY_ON)) {
      failures.push(`第 ${i + 1} 行: 同时标了 copy-off 又挂了 copyOption —— 二者只能留一个`);
    }
    exempt++;
    continue;
  }
  if (!chain.includes(COPY_ON)) {
    failures.push(`第 ${i + 1} 行: Text 既没有 ${COPY_ON}, 也没有 // copy-off: 原因\n` +
      `    ${lines[i].trim()}`);
    continue;
  }
  copyable++;
}

// 反向兜底: 谁把这条纪律整段删掉(比如全局搜替), 上面循环会"零命中"地通过
if (copyable < 30) {
  failures.push(`只找到 ${copyable} 个挂了 copyOption 的内容型 Text —— 数量少得不像话, ` +
    `大概率是这条纪律被整段删掉了(或本脚本扫错了文件)`);
}

console.log(`check-ui-copy: ${target}`);
console.log(`  内容型 Text 可复制 = ${copyable}, 控件标签豁免 = ${exempt}`);

if (failures.length > 0) {
  console.error(`\n交互界面文字可复制护栏失败 ${failures.length} 项:\n`);
  for (const f of failures) {
    console.error('  ✗ ' + f);
  }
  console.error('\n规则: 内容文字必须可长按复制; 点击热区(按钮/选项卡/胶囊/折叠触发器)才豁免。');
  process.exit(1);
}
console.log('  ✓ 全部内容型 Text 都可长按自由复制');
