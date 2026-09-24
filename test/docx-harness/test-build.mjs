// 构建"全类型"测试 docx: 封面/目录/全块类型/行内格式/多块编辑 + markdown 路径 + 外来文档导入 + 负例
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DocxBuilder, DocxImagePart } from './gen/DocxBuilder.ts';
import { DocParser, DocOps, MdToDoc } from './gen/DocModel.ts';
import { DocxImporter } from './gen/DocxImporter.ts';
import { ZipWriter, ZipEntry } from './gen/ZipWriter.ts';

const here = dirname(fileURLToPath(import.meta.url));
const b64File = join(here, 'png.b64');
if (!existsSync(b64File)) {
  console.error('缺少 png.b64, 先运行: python makepng.py > png.b64');
  process.exit(1);
}
const PNG_B64 = readFileSync(b64File, 'utf8').trim();
const pngBytes = Uint8Array.from(Buffer.from(PNG_B64, 'base64'));

function stubImage(src) {
  const p = new DocxImagePart();
  p.data = pngBytes;
  p.mime = 'image/png';
  p.ext = 'png';
  p.widthPx = 160;
  p.heightPx = 120;
  console.log('  [resolve]', src);
  return p;
}

const resolver = async (src) => (src === 'missing.png' ? null : stubImage(src));

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return a === b;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false;
    return true;
  }
  if (typeof a === 'object') {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    if (ka.length !== kb.length) return false;
    for (let i = 0; i < ka.length; i++) {
      if (ka[i] !== kb[i]) return false;
      if (!deepEqual(a[ka[i]], b[ka[i]])) return false;
    }
    return true;
  }
  return false;
}

function expectThrow(name, fn) {
  try {
    fn();
    console.error('FAIL(未抛错):', name);
    process.exitCode = 1;
  } catch (e) {
    console.log('  [负例OK]', name, '→', String(e.message).substring(0, 70));
  }
}

// ===== 1. 全类型文档 =====
const fullDoc = {
  title: '2026 年上半年经营分析报告',
  subtitle: '提交：董事会',
  author: '经营分析组',
  style: 'default',
  cover: true,
  toc: true,
  blocks: [
    { type: 'heading', level: 1, text: '一、总体经营情况' },
    { type: 'paragraph', text: '上半年营收 **1.2 亿元**，同比 *+18%*，主要来自华东区。行内代码 `WORK_DOC_MAX`、链接 [财务中台](https://example.com/report)、公式 $E=mc^2$ 均支持。' },
    { type: 'image', src: 'photos/trend.png', caption: '图 1 月度营收趋势（来源：财务中台）', width: 0.8 },
    { type: 'heading', level: 2, text: '1.1 分渠道表现' },
    { type: 'table', caption: '表 1 核心指标（来源：财务中台）',
      headers: ['渠道', '营收', '同比'],
      rows: [['线上', '7,000 万', '+22%'], ['线下', '5,000 万', '+11%']] },
    { type: 'list', ordered: false, items: [
      { text: '直播带货 GMV **2,300 万**', level: 0 },
      { text: '新开门店 12 家', level: 0 },
      { text: '其中华东 5 家', level: 1 }] },
    { type: 'list', ordered: true, items: ['第一步梳理口径', '第二步复核数据'] },
    { type: 'heading', level: 3, text: '1.1.1 数据口径说明' },
    { type: 'quote', text: '增长的本质是复利，而复利来自纪律。' },
    { type: 'code', language: 'typescript', text: 'const total = 1.2e8;\nconsole.log(total);' },
    { type: 'divider' },
    { type: 'paragraph', text: '下图是内联图片：![示意](photos/trend.png) 展示在段落中间。' },
    { type: 'heading', level: 1, text: '二、问题与下一步' },
    { type: 'paragraph', text: '华北未达标，需专项跟进。' },
    { type: 'pagebreak' },
    { type: 'heading', level: 1, text: '三、附录' },
    { type: 'paragraph', text: '附录内容。' }
  ]
};

// ===== 2. 编辑后的文档(edit_docx 算子) =====
const editOps = [
  { op: 'set_style', style: 'academic' },
  { op: 'update_block', index: 2, block: { text: '上半年营收 **1.25 亿元**，同比 *+19%*。' } },
  { op: 'add_block', index: 3, block: { type: 'paragraph', text: '新增段落：口径已复核。' } },
  { op: 'replace_text', find: '营收', replace: '收入' },
  { op: 'delete_block', index: 5 },
  { op: 'move_block', from: 7, to: 8 }
];

async function main() {
  // ===== 1. 全类型文档(含封面/目录/图片/表格/代码/公式) =====
  const doc1 = DocParser.parse(JSON.stringify(fullDoc));
  const outAll = await DocxBuilder.buildDocxBytes(doc1, resolver);
  writeFileSync(join(here, 'gen', 'out_all.docx'), outAll);
  console.log('built out_all.docx', outAll.length, 'bytes');

  // ===== 2. markdown 路径(图片用工作区路径, 验证 markdown 也能带图) =====
  const md = '# 一、背景\n\n本文档由 markdown 生成，含 **加粗** 与图片：\n\n![趋势图](photos/trend.png)\n\n## 1.1 要点\n\n- 要点一\n- 要点二\n\n| 指标 | 数值 |\n|---|---|\n| 营收 | 1.2 亿 |\n';
  const outMd = await DocxBuilder.buildFromMarkdown(md, 'Markdown 测试文档', resolver);
  writeFileSync(join(here, 'gen', 'out_md.docx'), outMd);
  console.log('built out_md.docx', outMd.length, 'bytes');

  // ===== 3. 编辑算子 =====
  const docEdit = DocParser.parse(JSON.stringify(fullDoc));
  const editSummary = DocOps.apply(docEdit, JSON.stringify(editOps));
  console.log('edit summary:\n' + editSummary);
  const outEdit = await DocxBuilder.buildDocxBytes(docEdit, resolver);
  writeFileSync(join(here, 'gen', 'out_edit.docx'), outEdit);
  console.log('built out_edit.docx', outEdit.length, 'bytes');

  // ===== 4. 无损往返: read_docx 读回内嵌源 =====
  const tmpDir = join(here, 'gen', 'tmp');
  const imgOut = join(here, 'gen', 'imgout');
  const rt = await DocxImporter.import(join(here, 'gen', 'out_all.docx'), tmpDir, imgOut, 'docx_images/out_all');
  if (!rt.embedded) {
    console.error('FAIL: out_all.docx 应走内嵌源无损还原');
    process.exitCode = 1;
  }
  const srcObj = JSON.parse(JSON.stringify(doc1));
  const rtObj = JSON.parse(JSON.stringify(rt.doc));
  if (!deepEqual(srcObj, rtObj)) {
    console.error('FAIL: 内嵌源往返不一致');
    console.error('src:', JSON.stringify(srcObj).substring(0, 300));
    console.error('rt :', JSON.stringify(rtObj).substring(0, 300));
    process.exitCode = 1;
  } else {
    console.log('  [OK] 内嵌源无损往返一致 (' + rt.blockCount + ' 块)');
  }

  // ===== 5. 外来 docx(无内嵌源): 近似导入 + 图片抽取 =====
  const foreign = buildForeignDocx();
  const fp = join(here, 'gen', 'foreign.docx');
  writeFileSync(fp, foreign);
  const frt = await DocxImporter.import(fp, tmpDir, imgOut, 'docx_images/foreign');
  if (frt.embedded) {
    console.error('FAIL: 外来 docx 不应命中内嵌源');
    process.exitCode = 1;
  }
  const types = frt.doc.blocks.map((b) => b.type);
  console.log('  foreign blocks:', JSON.stringify(types));
  const needTypes = ['heading', 'paragraph', 'list', 'table', 'image'];
  for (const t of needTypes) {
    if (!types.includes(t)) {
      console.error('FAIL: 外来导入缺少块类型', t);
      process.exitCode = 1;
    }
  }
  if (frt.images.length !== 1 || frt.images[0] !== 'docx_images/foreign/image1.png') {
    console.error('FAIL: 外来图片抽取结果异常', JSON.stringify(frt.images));
    process.exitCode = 1;
  } else {
    const imgFile = join(here, 'gen', 'imgout', 'image1.png');
    if (!existsSync(imgFile)) {
      console.error('FAIL: 抽取的图片文件未落盘', imgFile);
      process.exitCode = 1;
    } else {
      console.log('  [OK] 外来导入: 标题=' + frt.doc.title + ', 图片已抽取 ' + frt.images.length + ' 张 → ' + frt.images[0]);
    }
  }
  // 列表应识别为无序
  const listBlock = frt.doc.blocks.find((b) => b.type === 'list');
  if (!listBlock || listBlock.ordered !== false || listBlock.items.length !== 2) {
    console.error('FAIL: 外来列表解析异常');
    process.exitCode = 1;
  } else {
    console.log('  [OK] 外来列表: 无序, 2 条');
  }

  // ===== 6. 负例 =====
  expectThrow('未知块类型', () => DocParser.parse(JSON.stringify({ title: 'x', blocks: [{ type: 'nope', text: 'x' }] })));
  expectThrow('heading 级别非法', () => DocParser.parse(JSON.stringify({ title: 'x', blocks: [{ type: 'heading', level: 7, text: 'x' }] })));
  expectThrow('image 缺 src', () => DocParser.parse(JSON.stringify({ title: 'x', blocks: [{ type: 'image' }] })));
  expectThrow('table 行超列', () => DocParser.parse(JSON.stringify({ title: 'x', blocks: [{ type: 'table', headers: ['a'], rows: [['1', '2']] }] })));
  expectThrow('blocks 为空', () => DocParser.parse(JSON.stringify({ title: 'x', blocks: [] })));
  expectThrow('ops 未知操作', () => DocOps.apply(DocParser.parse(JSON.stringify(fullDoc)), JSON.stringify([{ op: 'nope' }])));
  expectThrow('delete_block 越界', () => DocOps.apply(DocParser.parse(JSON.stringify(fullDoc)), JSON.stringify([{ op: 'delete_block', index: 99 }])));
  let threw = false;
  try {
    await DocxBuilder.buildDocxBytes(DocParser.parse(JSON.stringify({ title: 'x', blocks: [{ type: 'image', src: 'missing.png' }] })), resolver);
  } catch (e) {
    threw = true;
    console.log('  [负例OK] 图片解析失败 →', String(e.message).substring(0, 60));
  }
  if (!threw) {
    console.error('FAIL: 图片解析失败未抛错');
    process.exitCode = 1;
  }
  console.log('ALL BUILD OK');
}

// 手工组装一个"外来"docx(不带 docProps/doc.json): H1/正文/无序列表/表格/图片
function buildForeignDocx() {
  const entries = [];
  const xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  const nsW = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';
  const nsR = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  const nsWp = 'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"';
  const nsA = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"';
  const nsPic = 'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"';
  const body =
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章 测试章节</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>这是外来文档的正文段落。</w:t></w:r></w:p>' +
    '<w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>' +
    '<w:r><w:t>第一条要点</w:t></w:r></w:p>' +
    '<w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>' +
    '<w:r><w:t>第二条要点</w:t></w:r></w:p>' +
    '<w:tbl><w:tblPr><w:tblW w:w="9026" w:type="dxa"/></w:tblPr><w:tblGrid><w:gridCol w:w="4513"/><w:gridCol w:w="4513"/></w:tblGrid>' +
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="4513" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>列A</w:t></w:r></w:p></w:tc>' +
    '<w:tc><w:tcPr><w:tcW w:w="4513" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>列B</w:t></w:r></w:p></w:tc></w:tr>' +
    '<w:tr><w:tc><w:tcPr><w:tcW w:w="4513" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc>' +
    '<w:tc><w:tcPr><w:tcW w:w="4513" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc></w:tr>' +
    '</w:tbl>' +
    '<w:p><w:r><w:drawing><wp:inline><wp:extent cx="1524000" cy="1143000"/>' +
    '<wp:docPr id="1" name="图片1"/><a:graphic><a:graphicData uri="' + nsPic + '">' +
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="图片1"/><pic:cNvPicPr/></pic:nvPicPr>' +
    '<pic:blipFill><a:blip r:embed="rIdImg"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>' +
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1524000" cy="1143000"/></a:xfrm>' +
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>' +
    '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
    '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>';
  entries.push(xmlEntry('[Content_Types].xml',
    xmlHead + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Default Extension="png" ContentType="image/png"/>' +
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
    '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' +
    '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>' +
    '</Types>'));
  entries.push(xmlEntry('_rels/.rels',
    xmlHead + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>' +
    '</Relationships>'));
  entries.push(xmlEntry('word/document.xml', xmlHead + '<w:document ' + nsW + ' ' + nsR + ' ' + nsWp + ' ' + nsA + ' ' + nsPic + '><w:body>' + body + '</w:body></w:document>'));
  entries.push(xmlEntry('word/_rels/document.xml.rels',
    xmlHead + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rIdImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>' +
    '</Relationships>'));
  entries.push(xmlEntry('word/numbering.xml',
    xmlHead + '<w:numbering ' + nsW + '>' +
    '<w:abstractNum w:abstractNumId="0">' +
    '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/>' +
    '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="567" w:hanging="283"/></w:pPr>' +
    '<w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/></w:rPr></w:lvl>' +
    '</w:abstractNum>' +
    '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>' +
    '</w:numbering>'));
  entries.push(xmlEntry('word/styles.xml',
    xmlHead + '<w:styles ' + nsW + '><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>' +
    '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/></w:style>' +
    '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="ListParagraph"/><w:basedOn w:val="Normal"/></w:style>' +
    '</w:styles>'));
  entries.push(xmlEntry('docProps/core.xml',
    xmlHead + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>外来文档</dc:title></cp:coreProperties>'));
  entries.push(xmlEntry('docProps/app.xml',
    xmlHead + '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Test</Application></Properties>'));
  const media = new ZipEntry();
  media.name = 'word/media/image1.png';
  media.data = pngBytes;
  entries.push(media);
  return ZipWriter.create(entries);
}

function xmlEntry(name, xml) {
  const e = new ZipEntry();
  e.name = name;
  e.data = Uint8Array.from(Buffer.from(xml, 'utf8'));
  return e;
}

main().catch((e) => {
  console.error('BUILD FAIL:', e);
  process.exitCode = 1;
});
