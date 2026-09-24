// CsvWriter + glob 过滤的快速验证(与 WorkFileService.globRegexOne 同逻辑)
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CsvWriter } from './gen/CsvWriter.ts';

const here = dirname(fileURLToPath(import.meta.url));
let failed = 0;

function assertEq(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? '  [OK] ' : '  [FAIL] ') + name + (ok ? '' : ` → got ${JSON.stringify(got)} want ${JSON.stringify(want)}`));
  if (!ok) failed++;
}

// ===== CsvWriter =====
const rows = [
  ['区域', '达成率', '备注'],
  ['华东', '112%', '含直营,加盟'],
  ['华南', '104%', '他说"超标了"'],
  ['华北', '96%\n缺口1400万', 'a"b'],
  ['UTF-8列', '中文,逗号', '行尾']
];
const bytes = CsvWriter.buildCsvBytes(rows, true);
assertEq('BOM 头', [bytes[0], bytes[1], bytes[2]], [0xEF, 0xBB, 0xBF]);
const text = Buffer.from(bytes.subarray(3)).toString('utf8');
assertEq('字段含逗号被引号包裹', text.includes('"含直营,加盟"'), true);
assertEq('引号翻倍', text.includes('"他说""超标了""'), true);
assertEq('换行字段被包裹(内容原样保留)', text.includes('"96%\n缺口1400万"'), true);
assertEq('CRLF 行尾', text.split('\r\n').length, 6);
assertEq('无 BOM 模式', Array.from(CsvWriter.buildCsvBytes(rows, false).subarray(0, 1)), [0xE5]); // '区' 的 UTF-8 首字节

// 空格/普通字段不加引号
assertEq('普通字段无引号', CsvWriter.encodeRow(['a', 'b c', 'd']), 'a,b c,d');
assertEq('空单元格', CsvWriter.encodeRow(['a', '', 'c']), 'a,,c');

// ===== glob(与 WorkFileService.globRegexOne 同实现) =====
function globRegexOne(pattern) {
  let re = '';
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern.charAt(i);
    if (ch === '*') re += '.*';
    else if (ch === '?') re += '.';
    else if ('.+^${}()|[]\\'.indexOf(ch) !== -1) re += '\\' + ch;
    else re += ch;
  }
  return new RegExp('^' + re + '$', 'i');
}
function matchAny(name, patterns) {
  const regs = patterns.split(',').map(p => p.trim()).filter(p => p !== '').map(globRegexOne);
  if (regs.length === 0) return true; // 与 matchGlob 一致: 无过滤全通过
  return regs.some(r => r.test(name));
}
assertEq('*.md 命中', matchAny('report.md', '*.md'), true);
assertEq('*.md 不命中图片', matchAny('photo.png', '*.md'), false);
assertEq('多模式', matchAny('p.png', '*.png, *.jpg'), true);
assertEq('问号命中单字符', matchAny('ab.csv', 'a?.csv'), true);
assertEq('问号不匹配两字符', matchAny('abc.csv', 'a?.csv'), false);
assertEq('点号被转义(md不命中mdb)', matchAny('x.mdb', '*.md'), false);
assertEq('大小写不敏感', matchAny('Report.MD', '*.md'), true);
assertEq('无过滤全通过', matchAny('anything.xyz', ''), true);

if (failed > 0) {
  console.error(`${failed} 项失败`);
  process.exit(1);
}
console.log('CSV/GLOB ALL OK');
