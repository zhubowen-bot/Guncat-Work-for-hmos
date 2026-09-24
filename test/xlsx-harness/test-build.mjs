// 构建"全类型"测试 xlsx: 多工作表/公式/数字格式/列宽/冻结窗格 + markdown 路径 + 编辑算子 + 外来导入 + 负例
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { XlsxBuilder } from './gen/XlsxBuilder.ts';
import { XlsxParser, XlsxOps, MdToXlsx } from './gen/XlsxModel.ts';
import { XlsxImporter } from './gen/XlsxImporter.ts';
import { ZipWriter, ZipEntry } from './gen/ZipWriter.ts';

const here = dirname(fileURLToPath(import.meta.url));

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

// ===== 1. 全功能工作簿(两表/公式/格式/列宽/冻结) =====
const fullWb = {
  name: '2026 年度经营预算',
  style: 'default',
  sheets: [
    {
      name: '假设',
      headers: ['假设项', '数值'],
      rows: [
        ['营收增长率', 0.08],
        ['毛利率', 0.65],
        ['所得税率', 0.25]
      ],
      formats: ['text', 'percent'],
      colWidths: [22, 14]
    },
    {
      name: '收入',
      headers: ['年份', '线上', '线下', '合计'],
      rows: [
        [2024, 1000000, 800000, '=SUM(B2:C2)'],
        [2025, '=B2*(1+假设!B2)', '=C2*(1+假设!B2)', '=SUM(B3:C3)'],
        ['合计', '=SUM(B2:B3)', '=SUM(C2:C3)', '=SUM(D2:D3)']
      ],
      formats: ['year', 'money', 'money', 'money'],
      colWidths: [10, 14, 14, 14],
      freeze: 'A2'
    }
  ]
};

// ===== 2. 编辑算子 =====
const editOps = [
  { op: 'set_name', name: '2026 预算(修订版)' },
  { op: 'set_style', style: 'academic' },
  { op: 'set_cell', sheet: '假设', row: 1, col: 2, value: 0.1 },
  { op: 'add_row', sheet: '收入', index: 2, row: [2023, 900000, 700000, '=SUM(B2:C2)'] },
  { op: 'add_sheet', sheet: { name: '费用', headers: ['科目', '金额'], rows: [['房租', 50000], ['水电', 12000]], formats: ['text', 'money'] } },
  { op: 'set_header', sheet: '收入', col: 2, value: '电商收入' },
  { op: 'replace_text', find: '线上', replace: '电商' },
  { op: 'delete_row', sheet: '假设', index: 3 }
];

function expectThrowOps(name, wb, ops) {
  expectThrow(name, () => XlsxOps.apply(XlsxParser.parse(JSON.stringify(wb)), JSON.stringify(ops)));
}

async function main() {
  // ===== 1. 全功能工作簿 =====
  const wb1 = XlsxParser.parse(JSON.stringify(fullWb));
  const outAll = XlsxBuilder.buildXlsxBytes(wb1);
  writeFileSync(join(here, 'gen', 'out_all.xlsx'), outAll);
  console.log('built out_all.xlsx', outAll.length, 'bytes');

  // ===== 2. markdown 路径 =====
  const md = '| 月份 | 收入 | 支出 |\n|---|---|---|\n| 1月 | 120000 | 80000 |\n| 2月 | 150000 | 95000 |\n| 合计 | 270000 | 175000 |\n';
  const wbMd = MdToXlsx.convert(md, 'Markdown 表');
  const outMd = XlsxBuilder.buildXlsxBytes(wbMd);
  writeFileSync(join(here, 'gen', 'out_md.xlsx'), outMd);
  console.log('built out_md.xlsx', outMd.length, 'bytes, sheets=', wbMd.sheets[0].name);

  // ===== 3. 编辑算子 =====
  const wbEdit = XlsxParser.parse(JSON.stringify(fullWb));
  const editSummary = XlsxOps.apply(wbEdit, JSON.stringify(editOps));
  console.log('edit summary:\n' + editSummary);
  // 坐标语义断言: row/index 按数据行(不含表头)从 1 起算
  const inc = wbEdit.sheets.find((s) => s.name === '收入');
  if (inc.headers[1] !== '电商收入') {
    console.error('FAIL: set_header 未生效', inc.headers);
    process.exitCode = 1;
  }
  if (inc.rows[0][0] !== 2024 || inc.rows[0][1] !== 1000000) {
    // 未动过的第一个数据行应保持原值(row:1 = 第一个数据行, 不是表头下的 Excel 第 2 行语义问题)
    console.error('FAIL: 数据行坐标语义异常', JSON.stringify(inc.rows[0]));
    process.exitCode = 1;
  }
  if (inc.rows[1][0] !== 2023) {
    console.error('FAIL: add_row index:2 插入位置异常', JSON.stringify(inc.rows[1]));
    process.exitCode = 1;
  }
  const hy = wbEdit.sheets.find((s) => s.name === '假设');
  if (hy.rows[0][1] !== 0.1) {
    console.error('FAIL: set_cell row:1 未命中第一个数据行', JSON.stringify(hy.rows[0]));
    process.exitCode = 1;
  }
  if (hy.rows.length !== 2) {
    console.error('FAIL: delete_row 未按数据行删除', hy.rows.length);
    process.exitCode = 1;
  }
  const fe = wbEdit.sheets.find((s) => s.name === '费用');
  if (fe.rows[0][0] !== '房租') {
    console.error('FAIL: add_sheet 未生效', JSON.stringify(fe.rows));
    process.exitCode = 1;
  }
  console.log('  [OK] 坐标语义: row/index 按数据行(不含表头); set_header 独立于 set_cell');
  const outEdit = XlsxBuilder.buildXlsxBytes(wbEdit);
  writeFileSync(join(here, 'gen', 'out_edit.xlsx'), outEdit);
  console.log('built out_edit.xlsx', outEdit.length, 'bytes');

  // ===== 4. 无损往返 =====
  const tmpDir = join(here, 'gen', 'tmp');
  const rt = await XlsxImporter.import(join(here, 'gen', 'out_all.xlsx'), tmpDir);
  if (!rt.embedded) {
    console.error('FAIL: out_all.xlsx 应走内嵌源无损还原');
    process.exitCode = 1;
  }
  const srcObj = JSON.parse(XlsxParser.toJson(wb1));
  const rtObj = JSON.parse(XlsxParser.toJson(rt.workbook));
  if (!deepEqual(srcObj, rtObj)) {
    console.error('FAIL: 内嵌源往返不一致');
    console.error('src:', JSON.stringify(srcObj).substring(0, 400));
    console.error('rt :', JSON.stringify(rtObj).substring(0, 400));
    process.exitCode = 1;
  } else {
    console.log('  [OK] 内嵌源无损往返一致 (' + rt.sheetCount + ' 表)');
  }

  // ===== 5. 外来 xlsx(无内嵌源): 表顺序/名称/公式/共享字符串/数字 =====
  const foreign = buildForeignXlsx();
  const fp = join(here, 'gen', 'foreign.xlsx');
  writeFileSync(fp, foreign);
  const frt = await XlsxImporter.import(fp, tmpDir);
  if (frt.embedded) {
    console.error('FAIL: 外来 xlsx 不应命中内嵌源');
    process.exitCode = 1;
  }
  const names = frt.workbook.sheets.map((s) => s.name);
  console.log('  foreign sheets:', JSON.stringify(names));
  if (names.join(',') !== 'Sheet1,Sheet2') {
    console.error('FAIL: 外来工作表顺序/名称异常');
    process.exitCode = 1;
  }
  const s1 = frt.workbook.sheets[0];
  // 外来文件无表头语义: 全部行进 rows(第 1 行"项目/金额/说明"也是数据行)
  // rows[0]=['项目','金额','说明'] rows[1]=['A',100,'文本一'] rows[2]=['B',200] rows[3]=['合计','=SUM(B2:B3)']
  if (s1.rows.length !== 4) {
    console.error('FAIL: 外来 sheet1 行数异常', s1.rows.length);
    process.exitCode = 1;
  }
  const r2 = s1.rows[1];
  if (r2[0] !== 'A' || r2[1] !== 100 || r2[2] !== '文本一') {
    console.error('FAIL: 外来数字/共享字符串解析异常', JSON.stringify(r2));
    process.exitCode = 1;
  }
  const r4 = s1.rows[3];
  if (r4[0] !== '合计' || r4[1] !== '=SUM(B2:B3)') {
    console.error('FAIL: 外来公式解析异常', JSON.stringify(r4));
    process.exitCode = 1;
  }
  console.log('  [OK] 外来导入: 表顺序=Sheet1,Sheet2; 数字/共享字符串/公式还原');

  // ===== 6. 负例 =====
  expectThrow('formats 未知格式', () => XlsxParser.parse(JSON.stringify({ sheets: [{ name: 'S', rows: [[1]], formats: ['nope'] }] })));
  expectThrow('行不矩形', () => XlsxParser.parse(JSON.stringify({ sheets: [{ name: 'S', rows: [[1, 2], [3]] }] })));
  expectThrow('工作表名重复', () => XlsxParser.parse(JSON.stringify({ sheets: [{ name: 'S', rows: [[1]] }, { name: 'S', rows: [[2]] }] })));
  expectThrow('rows 为空', () => XlsxParser.parse(JSON.stringify({ sheets: [{ name: 'S', rows: [] }] })));
  expectThrow('表头与数据列数不一致', () => XlsxParser.parse(JSON.stringify({ sheets: [{ name: 'S', headers: ['a', 'b'], rows: [[1]] }] })));
  expectThrow('freeze 格式非法', () => XlsxParser.parse(JSON.stringify({ sheets: [{ name: 'S', rows: [[1]], freeze: 'ABC' }] })));
  expectThrow('colWidths 越界', () => XlsxParser.parse(JSON.stringify({ sheets: [{ name: 'S', rows: [[1]], colWidths: [300] }] })));
  expectThrowOps('ops 未知操作', fullWb, [{ op: 'nope' }]);
  expectThrowOps('set_cell sheet 不存在', fullWb, [{ op: 'set_cell', sheet: '不存在', row: 1, col: 1, value: 1 }]);
  expectThrowOps('delete_row 越界', fullWb, [{ op: 'delete_row', sheet: '收入', index: 99 }]);
  expectThrowOps('add_row 列数不符', fullWb, [{ op: 'add_row', sheet: '收入', row: [1] }]);
  expectThrowOps('delete_sheet 最后一个', fullWb, [{ op: 'delete_sheet', sheet: '收入' }, { op: 'delete_sheet', sheet: '假设' }]);
  expectThrowOps('set_cell 值类型非法', fullWb, [{ op: 'set_cell', sheet: '收入', row: 1, col: 1, value: true }]);
  expectThrowOps('set_header 无表头', { sheets: [{ name: 'S', rows: [[1]] }] }, [{ op: 'set_header', sheet: 'S', col: 1, value: 'x' }]);
  expectThrowOps('set_header col 越界', fullWb, [{ op: 'set_header', sheet: '收入', col: 99, value: 'x' }]);
  expectThrowOps('set_header 值非文本', fullWb, [{ op: 'set_header', sheet: '收入', col: 1, value: true }]);
  expectThrowOps('set_cell row 不含表头越界', fullWb, [{ op: 'set_cell', sheet: '假设', row: 4, col: 1, value: 1 }]);
  console.log('ALL BUILD OK');
}

// 手工组装"外来"xlsx(不带 docProps/workbook.json): 2 表, 数字/共享字符串/公式
function buildForeignXlsx() {
  const entries = [];
  const xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  const ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"';
  entries.push(xmlEntry('[Content_Types].xml',
    xmlHead + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
    '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
    '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>' +
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
    '</Types>'));
  entries.push(xmlEntry('_rels/.rels',
    xmlHead + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
    '</Relationships>'));
  entries.push(xmlEntry('xl/workbook.xml',
    xmlHead + '<workbook ' + ns + ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
    '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/><sheet name="Sheet2" sheetId="2" r:id="rId2"/></sheets>' +
    '</workbook>'));
  entries.push(xmlEntry('xl/_rels/workbook.xml.rels',
    xmlHead + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>' +
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
    '</Relationships>'));
  // sheet1: 表头(共享字符串 0/1/2) + 数据(数字/共享字符串) + 合计(公式)
  entries.push(xmlEntry('xl/worksheets/sheet1.xml',
    xmlHead + '<worksheet ' + ns + '>' +
    '<sheetViews><sheetView workbookViewId="0"/></sheetViews>' +
    '<sheetData>' +
    '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>' +
    '<row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2"><v>100</v></c><c r="C2" t="s"><v>4</v></c></row>' +
    '<row r="3"><c r="A3" t="s"><v>5</v></c><c r="B3"><v>200</v></c></row>' +
    '<row r="4"><c r="A4" t="s"><v>6</v></c><c r="B4"><f>SUM(B2:B3)</f><v></v></c></row>' +
    '</sheetData></worksheet>'));
  entries.push(xmlEntry('xl/worksheets/sheet2.xml',
    xmlHead + '<worksheet ' + ns + '>' +
    '<sheetData><row r="1"><c r="A1" t="s"><v>7</v></c><c r="B1"><v>42</v></c></row>' +
    '</sheetData></worksheet>'));
  entries.push(xmlEntry('xl/sharedStrings.xml',
    xmlHead + '<sst ' + ns + ' count="8" uniqueCount="8">' +
    '<si><t>项目</t></si><si><t>金额</t></si><si><t>说明</t></si>' +
    '<si><t>A</t></si><si><t>文本一</t></si><si><t>B</t></si><si><t>合计</t></si><si><t>Sheet2标题</t></si>' +
    '</sst>'));
  entries.push(xmlEntry('xl/styles.xml',
    xmlHead + '<styleSheet ' + ns + '>' +
    '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>' +
    '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>' +
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
    '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>' +
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>' +
    '</styleSheet>'));
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
