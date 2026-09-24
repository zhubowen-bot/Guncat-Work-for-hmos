// 构建"全版式"测试 pptx: 覆盖 13 种版式 + 图表/表格/图片/备注/背景/多主题 + 编辑算子 + 负例
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PptxBuilder, PptxImagePart } from './gen/PptxBuilder.ts';
import { DeckParser, DeckOutline, DeckOps } from './gen/DeckModel.ts';

const here = dirname(fileURLToPath(import.meta.url));
const b64File = join(here, 'png.b64');
if (!existsSync(b64File)) {
  console.error('缺少 png.b64, 先运行: python makepng.py > png.b64');
  process.exit(1);
}
const PNG_B64 = readFileSync(b64File, 'utf8').trim();
const pngBytes = Uint8Array.from(Buffer.from(PNG_B64, 'base64'));

function stubImage(src) {
  const p = new PptxImagePart();
  p.data = pngBytes;
  p.mime = 'image/png';
  p.ext = 'png';
  p.widthPx = 160;
  p.heightPx = 120;
  console.log('  [resolve]', src);
  return p;
}

const resolver = async (src) => (src === 'missing.png' ? null : stubImage(src));

function expectThrow(name, fn) {
  try {
    fn();
    console.error('FAIL(未抛错):', name);
    process.exitCode = 1;
  } catch (e) {
    console.log('  [负例OK]', name, '→', String(e.message).substring(0, 60));
  }
}

// ===== 1. 全版式 deck =====
const fullDeck = {
  title: 'Q3 经营复盘',
  theme: 'brand-blue',
  slides: [
    { layout: 'cover', title: 'Q3 经营复盘', subtitle: '2026-08 · 经营分析组' },
    { layout: 'toc', title: '目录', bullets: ['业绩概览', '渠道表现', '问题与对策', '下季度计划', '风险提示', '附录说明'] },
    { layout: 'section', title: '业绩概览' },
    { layout: 'content', title: '核心指标全面达标', notes: '口径: 财务中台, 截止 9-30。',
      bullets: ['营收 1.2 亿元，同比 +18%', '新增客户 3,240 家', { text: '华东区贡献 42%', level: 2 }, '客单价 3,700 元，环比 +5%'] },
    { layout: 'chart', title: '月度营收趋势（百万）', caption: '数据来源: 财务中台',
      chart: { type: 'bar', categories: ['4月', '5月', '6月'], showValue: true,
        series: [{ name: '营收', values: [36, 39, 45] }, { name: '去年', values: [31, 33, 38] }] } },
    { layout: 'two-col', title: '渠道表现对比',
      left: { heading: '线上渠道', bullets: ['占比 58%，同比 +9pct', '直播带货 GMV 2,300 万'] },
      right: { heading: '线下渠道', bullets: ['占比 42%，同比 -4pct', '新开门店 12 家'] } },
    { layout: 'image-text', title: '旗舰门店改造完成', image: { src: 'photos/demo.png', fit: 'cover' }, imageSide: 'left',
      bullets: ['坪效提升 22%', '单店模型可复制', 'Q4 推广至 8 家'] },
    { layout: 'image-full', image: { src: 'photos/demo.png' }, caption: '旗舰门店实景（来源: 品牌部）' },
    { layout: 'table', title: '区域达成率', note: '来源: 区域运营月报',
      headers: ['区域', '达成率', '同比'], widths: [0.4, 0.3, 0.3],
      rows: [['华东', '112%', '+9%'], ['华南', '104%', '+4%'], ['华北', '96%', '-2%']] },
    { layout: 'chart', title: '客群结构占比', chart: { type: 'pie', categories: ['新客', '复购', '会员'], series: [{ name: '占比', values: [32, 41, 27] }] } },
    { layout: 'content', title: '深色背景页', background: { image: 'photos/demo.png', overlay: 0.55 },
      bullets: ['背景图 + 遮罩示例', '白色文字保证对比'] },
    { layout: 'quote', text: '增长的本质是复利，而复利来自纪律。', author: '经营分析组' },
    { layout: 'section', title: '问题与对策' },
    { layout: 'content', title: '华北未达成，需专项跟进', bullets: ['达成率 96%，缺口 1,400 万', '大客户续约延迟是主因'] },
    { layout: 'custom', title: '', elements: [
      { type: 'text', x: 0.08, y: 0.2, w: 0.5, h: 0.2, text: 'Q4 关键动作', size: 30, bold: true, color: 'primary' },
      { type: 'shape', shape: 'roundRect', x: 0.6, y: 0.25, w: 0.32, h: 0.45, fill: 'surface' },
      { type: 'text', x: 0.08, y: 0.45, w: 0.45, h: 0.3, text: '8 家门店复制\n2 场行业大促', size: 18, color: 'body' },
      { type: 'image', src: 'photos/demo.png', x: 0.63, y: 0.3, w: 0.26, h: 0.35, fit: 'contain' }
    ] },
    { layout: 'line-fake' }
  ]
};
// 移除故意非法的最后一页(负例单独测)
fullDeck.slides.pop();

// ===== 2. 主题变体 deck(midnight, 深色) =====
const darkDeck = {
  title: '技术架构演进',
  theme: 'midnight',
  slides: [
    { layout: 'cover', title: '技术架构演进', subtitle: 'Guncat Work · 2026' },
    { layout: 'chart', title: '接口耗时 P95（ms）', chart: { type: 'line', categories: ['v1', 'v2', 'v3', 'v4'], series: [{ name: 'P95', values: [420, 260, 180, 120] }] } },
    { layout: 'table', title: '模块迁移进度', headers: ['模块', '进度', '负责人'], rows: [['Agent 循环', '100%', 'A'], ['文件沙箱', '80%', 'B']] },
    { layout: 'end', title: '谢谢', subtitle: '欢迎交流' }
  ]
};

try {
  console.log('== 1) 全版式 deck ==');
  const deck = DeckParser.parse(JSON.stringify(fullDeck));
  const bytes = await PptxBuilder.buildPptxBytes(deck, resolver);
  writeFileSync(join(here, 'gen', 'out_all.pptx'), bytes);
  console.log('out_all.pptx', deck.slides.length, '页,', bytes.length, '字节');

  console.log('== 2) midnight deck ==');
  const dark = DeckParser.parse(JSON.stringify(darkDeck));
  const darkBytes = await PptxBuilder.buildPptxBytes(dark, resolver);
  writeFileSync(join(here, 'gen', 'out_dark.pptx'), darkBytes);
  console.log('out_dark.pptx', dark.slides.length, '页,', darkBytes.length, '字节');

  console.log('== 3) outline 兼容 ==');
  const legacy = DeckOutline.parse('## 开始\n- 第一条\n  - 二级\n# 明细\n- 要点 A\n- 要点 B\n- 要点 C', '旧版大纲');
  const legacyBytes = await PptxBuilder.buildPptxBytes(legacy, resolver);
  writeFileSync(join(here, 'gen', 'out_outline.pptx'), legacyBytes);
  console.log('out_outline.pptx', legacy.slides.length, '页,', legacyBytes.length, '字节');

  console.log('== 4) 编辑算子 ==');
  const editDeck = DeckParser.parse(JSON.stringify(fullDeck));
  const summary = DeckOps.apply(editDeck, JSON.stringify([
    { op: 'replace_text', find: '营收', replace: '收入' },
    { op: 'update_slide', index: 4, slide: { title: '核心指标超额达成', bullets: ['收入 1.2 亿，同比 +18%', '新客 3,240 家'] } },
    { op: 'add_slide', index: 6, slide: { layout: 'content', title: '插入的新页', bullets: ['插入要点'] } },
    { op: 'add_slide', slide: { layout: 'section', title: '追加章节' } },
    { op: 'move_slide', from: 2, to: 8 },
    { op: 'set_theme', theme: 'forest' },
    { op: 'set_title', title: 'Q3 经营复盘(修订)' },
    { op: 'set_notes', index: 2, notes: '章节过渡页' },
    { op: 'delete_slide', index: 16 }
  ]));
  console.log(summary);
  const editBytes = await PptxBuilder.buildPptxBytes(editDeck, resolver);
  writeFileSync(join(here, 'gen', 'out_edit.pptx'), editBytes);
  console.log('out_edit.pptx', editDeck.slides.length, '页,', editBytes.length, '字节');

  console.log('== 5) 负例 ==');
  expectThrow('未知版式', () => DeckParser.parse(JSON.stringify({ slides: [{ layout: 'line-fake', title: 'x' }] })));
  expectThrow('chart 缺 categories', () => DeckParser.parse(JSON.stringify({ slides: [{ layout: 'chart', title: 'x', chart: { type: 'bar', series: [{ name: 's', values: [1] }] } }] })));
  expectThrow('custom 坐标越界', () => DeckParser.parse(JSON.stringify({ slides: [{ layout: 'custom', elements: [{ type: 'text', x: 2, y: 0, w: 0.1, h: 0.1, text: 'x' }] }] })));
  expectThrow('image 页缺 src', () => DeckParser.parse(JSON.stringify({ slides: [{ layout: 'image', title: 'x' }] })));
  expectThrow('slides 为空', () => DeckParser.parse(JSON.stringify({ slides: [] })));
  expectThrow('ops 未知操作', () => DeckOps.apply(DeckParser.parse(JSON.stringify(fullDeck)), JSON.stringify([{ op: 'nope' }])));
  expectThrow('delete_slide 越界', () => DeckOps.apply(DeckParser.parse(JSON.stringify(fullDeck)), JSON.stringify([{ op: 'delete_slide', index: 99 }])));
  let threw = false;
  try {
    await PptxBuilder.buildPptxBytes(DeckParser.parse(JSON.stringify({ title: 'x', slides: [{ layout: 'image', title: 'x', image: { src: 'missing.png' } }] })), resolver);
  } catch (e) {
    threw = true;
    console.log('  [负例OK] 图片解析失败 →', String(e.message).substring(0, 50));
  }
  if (!threw) {
    console.error('FAIL: 图片解析失败未抛错');
    process.exitCode = 1;
  }
  console.log('ALL BUILD OK');
} catch (e) {
  console.error('BUILD FAIL:', e);
  process.exitCode = 1;
}
