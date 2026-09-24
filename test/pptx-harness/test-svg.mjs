// SvgUtil 验证: 校验诊断的精确性 + width/height 自动补齐(实机踩坑回归)
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SvgUtil } from './gen/SvgUtil.ts';

const here = dirname(fileURLToPath(import.meta.url));
let failed = 0;

function assertEq(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? '  [OK] ' : '  [FAIL] ') + name + (ok ? '' : ` → got ${JSON.stringify(got)} want ${JSON.stringify(want)}`));
  if (!ok) failed++;
}

// ===== validate: 每条报错必须命中确切根因 =====
const good = '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 24 24"><title>箭头</title><path d="M5 12h14"/></svg>';
assertEq('完整骨架通过', SvgUtil.validate(good), '');
assertEq('缺 xmlns 报 xmlns', SvgUtil.validate('<svg width="96" height="96" viewBox="0 0 24 24"></svg>').includes('xmlns'), true);
// 仅 viewBox: validate 放行(可自动修复), 由 normalize 补齐 —— 不用报错打断模型
assertEq('仅 viewBox 放行(交给 normalize)', SvgUtil.validate('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"></svg>'), '');
assertEq('完全无尺寸才报错', SvgUtil.validate('<svg xmlns="http://www.w3.org/2000/svg"></svg>').includes('viewBox'), true);
assertEq('缺闭合标签', SvgUtil.validate('<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 24 24">').includes('闭合'), true);
assertEq('script 被拒', SvgUtil.validate('<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 24 24"><script>x</script></svg>').includes('script'), true);

// ===== aspect =====
assertEq('viewBox 尺寸', SvgUtil.aspect(good), [24, 24, 1]);
assertEq('小数 viewBox', SvgUtil.aspect('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 140"></svg>'), [480, 140, 1]);
assertEq('width/height 回退', SvgUtil.aspect('<svg xmlns="http://www.w3.org/2000/svg" width="300px" height="160"></svg>'), [300, 160, 1]);
assertEq('无尺寸无效', SvgUtil.aspect('<svg xmlns="http://www.w3.org/2000/svg"></svg>'), [0, 0, 0]);

// ===== normalize: P0 回归 —— 仅 viewBox 的输入补齐 width/height =====
const viewBoxOnly = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M5 12h14"/></svg>';
const n1 = SvgUtil.normalize(viewBoxOnly, 512);
assertEq('补 width', n1.includes(' width="24"'), true);
assertEq('补 height', n1.includes(' height="24"'), true);
assertEq('补齐后通过校验', SvgUtil.validate(n1), '');
assertEq('位置在根元素内', n1.startsWith('<svg  width="24"') || n1.startsWith('<svg width="24"'), true);

const sizeOnly = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 140" width="480"></svg>';
const n2 = SvgUtil.normalize(sizeOnly, 512);
assertEq('只缺 height 补 height', n2.includes(' height="140"'), true);
assertEq('已有 width 不动', n2.includes('width="480"'), true);

assertEq('完整输入原样返回', SvgUtil.normalize(good, 512), good);
assertEq('无 viewBox 缺尺寸用默认', SvgUtil.normalize('<svg xmlns="http://www.w3.org/2000/svg"></svg>', 512).includes('width="512" height="512"'), true);

// 复刻实机失败场景: 文档旧版最小示例(仅 xmlns+viewBox) -> normalize 后必须可解码格式
const oldDocExample = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none"\n     stroke="#1B2330" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\n  <path d="M5 12h14M13 6l6 6-6 6"/>\n</svg>';
const fixed = SvgUtil.normalize(oldDocExample, 512);
assertEq('实机案例: 补齐后 validate 通过', SvgUtil.validate(fixed), '');
assertEq('实机案例: width 注入', fixed.includes('width="24"'), true);
assertEq('实机案例: height 注入', fixed.includes('height="24"'), true);

// stroke-width 陷阱回归: 'stroke-width="' 含 'width="' 子串, 裸 indexOf 会误判已存在 width
const strokeTrap = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" stroke-width="2">\n  <rect x="2" y="2" width="20" height="20"/>\n</svg>';
assertEq('陷阱: aspect 不吃 stroke-width', SvgUtil.aspect(strokeTrap), [24, 24, 1]);
const fixedTrap = SvgUtil.normalize(strokeTrap, 512);
assertEq('陷阱: width 被注入', /<svg width="24"/.test(fixedTrap), true);
assertEq('陷阱: height 被注入', /<svg width="24" height="24"/.test(fixedTrap), true);
const halfTrap = '<svg xmlns="http://www.w3.org/2000/svg" width="96" stroke-width="2" viewBox="0 0 24 24"></svg>';
const fixedHalf = SvgUtil.normalize(halfTrap, 512);
assertEq('陷阱: 已有真 width 不重复注入', (fixedHalf.match(/width="96"/g) || []).length, 1);
assertEq('陷阱: 只补缺的 height', fixedHalf.includes('height="24"'), true);
assertEq('陷阱: validate 识别真 width 存在', SvgUtil.validate('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" stroke-width="2"></svg>'), '');

if (failed > 0) {
  console.error(`${failed} 项失败`);
  process.exit(1);
}
console.log('SVGUTIL ALL OK');
