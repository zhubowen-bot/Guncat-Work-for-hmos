// CsvParser(RFC 4180) + DataPipeline(受限数据管道) 的快速验证
// 用法: node setup.mjs && node test-transform.mjs
import { CsvParser } from './gen/CsvParser.ts';
import { DataPipeline } from './gen/DataPipeline.ts';
import { CsvWriter } from './gen/CsvWriter.ts';

let failed = 0;

function assertEq(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? '  [OK] ' : '  [FAIL] ') + name + (ok ? '' : ` → got ${JSON.stringify(got)} want ${JSON.stringify(want)}`));
  if (!ok) failed++;
}

function assertThrows(name, fn, keyword) {
  try {
    fn();
    console.log(`  [FAIL] ${name} → 未抛错`);
    failed++;
  } catch (e) {
    const ok = !keyword || String(e.message).includes(keyword);
    console.log((ok ? '  [OK] ' : '  [FAIL] ') + name + (ok ? '' : ` → 错误信息缺少 "${keyword}": ${e.message}`));
    if (!ok) failed++;
  }
}

// ===== CsvParser: RFC 4180 =====
const csv1 = CsvParser.parse('a,b,c\r\n"x,y",z,"多\r\n行"', ',');
assertEq('引号字段含逗号/换行', csv1, [['a', 'b', 'c'], ['x,y', 'z', '多\r\n行']]);

const csv2 = CsvParser.parse('"他说""你好""",2\n3,4', ',');
assertEq('引号转义', csv2, [['他说"你好"', '2'], ['3', '4']]);

const csv3 = CsvParser.parse('\uFEFF姓名,年龄\n张三,25\n', ',');
assertEq('BOM 剥离 + 行尾换行不产生空行', csv3, [['姓名', '年龄'], ['张三', '25']]);

const csv4 = CsvParser.parse('a;b\n1;2', ';');
assertEq('显式分号分隔符', csv4, [['a', 'b'], ['1', '2']]);

assertEq('空输入', CsvParser.parse('', ','), []);
assertEq('空引号字段', CsvParser.parse('a,"",b', ','), [['a', '', 'b']]);
assertEq('字段内分号不切分', CsvParser.parse('"a;b",c', ','), [['a;b', 'c']]);

assertEq('分隔符推断-逗号', CsvParser.detectDelimiter('a,b,c\n1,2,3'), ',');
assertEq('分隔符推断-分号', CsvParser.detectDelimiter('a;b;c\n1;2;3'), ';');
assertEq('分隔符推断-制表符', CsvParser.detectDelimiter('a\tb\tc\n1\t2\t3'), '\t');

// ===== CsvParser: 智能表格识别(替代旧 parseTableInput) =====
const md = '| 名称 | 备注 |\n|---|---|\n| 含,逗号 | "引号" |\n| b | c |';
assertEq('Markdown 表格', CsvParser.parseSmartTable(md),
  [['名称', '备注'], ['含,逗号', '"引号"'], ['b', 'c']]);

const tsv = 'a\tb\n1\t"引号,内逗号"';
assertEq('TSV + 引号字段', CsvParser.parseSmartTable(tsv), [['a', 'b'], ['1', '引号,内逗号']]);

assertEq('CSV 智能识别', CsvParser.parseSmartTable('姓名,年龄\n张三,"25,5"'.replace('25,5', '25')),
  [['姓名', '年龄'], ['张三', '25']]);

// ===== DataPipeline: 表达式 =====
function runSteps(text, steps, opts) {
  const cfg = Object.assign({ format: '', delimiter: '', jsonPath: '', hasHeader: true }, opts);
  return DataPipeline.run(text, cfg.format, cfg.delimiter, cfg.jsonPath, cfg.hasHeader,
    JSON.stringify(steps), 100000, 30);
}

const src = '姓名,年龄,城市\n张三,25, 北京 \n李四,17,上海\n王五,30,\n赵六,abc,广州\n';
let out = runSteps(src, [
  { op: 'trim' },
  { op: 'filter', expr: "num(col('年龄')) >= 18" },
  { op: 'derive', name: '标签', expr: "col('姓名') + '@' + col('城市')" },
  { op: 'sort', expr: "num(col('年龄'))", desc: true }
]);
assertEq('管道后行数(年龄无法解析的行被过滤)', out.table.rows.length, 2);
assertEq('sort 降序首行', out.table.rows[0][0], '王五');
assertEq('derive 拼接(trim 生效)', out.table.rows[0][3], '王五@');
assertEq('applied 摘要条数', out.applied.length, 4);
assertEq('NaN 文本化置空', out.table.rows[0][3].indexOf('undefined'), -1);

// 裸标识符列引用 + 中文列名
out = runSteps(src, [{ op: 'derive', name: 'x', expr: "城市 != ''" }]);
assertEq('裸中文列名引用', out.table.rows[0][3], 'true');

// 函数
out = runSteps('t\nhello world\n', [
  { op: 'derive', name: 'a', expr: "upper(substr(col('t'), 0, 5))" },
  { op: 'derive', name: 'b', expr: "replace(col('t'), 'world', 'there')" },
  { op: 'derive', name: 'c', expr: "join(split(col('t'), ' '), '-')" },
  { op: 'derive', name: 'd', expr: "if(len(col('t')) > 5, '长', '短')" },
  { op: 'derive', name: 'e', expr: "round(10 / 3, 2)" },
  { op: 'derive', name: 'f', expr: "coalesce('', 'fallback')" },
  { op: 'derive', name: 'g', expr: "rownum()" },
  { op: 'derive', name: 'h', expr: "starts_with(col('t'), 'hello')" }
]);
const r = out.table.rows[0];
assertEq('upper+substr', r[1], 'HELLO');
assertEq('replace 全部替换', r[2], 'hello there');
assertEq('split+join', r[3], 'hello-world');
assertEq('if', r[4], '长');
assertEq('round', r[5], '3.33');
assertEq('coalesce', r[6], 'fallback');
assertEq('rownum', r[7], '1');
assertEq('starts_with', r[8], 'true');

// 正则
out = runSteps('line\n[2026-08-30] 耗时 650ms\n[2026-08-30] 耗时 100ms\n', [
  { op: 'extract', col: 'line', pattern: '\\[(\\d{4}-\\d{2}-\\d{2})\\]', name: '日期', group: 1 },
  { op: 'extract', col: 'line', pattern: '耗时 (\\d+)ms', name: '耗时', group: 1 },
  { op: 'filter', expr: "num(col('耗时')) > 500" },
  { op: 'select', cols: ['日期', '耗时'] }
]);
assertEq('正则提取行数', out.table.rows.length, 1);
assertEq('正则提取值', out.table.rows[0], ['2026-08-30', '650']);

// ===== DataPipeline: 表头与无表头 =====
const noHeader = '1,2\n3,4\n';
out = runSteps(noHeader, [{ op: 'set_header', names: ['x', 'y'] }], { hasHeader: false });
assertEq('set_header', out.table.header, ['x', 'y']);
assertEq('set_header 后行数', out.table.rows.length, 2);

out = runSteps('x,y\na,b\n', [{ op: 'promote_header' }], { hasHeader: false });
assertEq('promote_header 首行升为表头', out.table.header, ['x', 'y']);
assertEq('promote_header 剩余数据行', out.table.rows.length, 1);
assertThrows('promote_header 已有表头应报错', () => runSteps('x,y\na,b\n', [{ op: 'promote_header' }]), '已有表头');

out = runSteps('1,2\n3,4\n', [{ op: 'derive', name: 'z', expr: "num(col(1)) + num(col(2))" }], { hasHeader: false });
assertEq('无表头 col(列号) 数值算术', out.table.rows[0][2], '3');
assertEq('无表头 col(列号) 文本拼接', runSteps('1,2\n3,4\n',
  [{ op: 'derive', name: 'z', expr: "col(1) + col(2)" }], { hasHeader: false }).table.rows[0][2], '12');

// ===== DataPipeline: JSON 输入/输出 =====
const json = JSON.stringify({ data: { items: [{ name: '甲', qty: 3 }, { name: '乙', qty: 10 }] } });
out = runSteps(json, [{ op: 'filter', expr: "num(col('qty')) > 5" }], { format: 'json', jsonPath: 'data.items' });
assertEq('json_path 定位 + filter', out.table.rows.length, 1);
assertEq('json 单元格', out.table.rows[0][0], '乙');

const jsonRows = DataPipeline.toJsonText(out.table);
const parsedBack = JSON.parse(jsonRows);
assertEq('JSON 输出往返', parsedBack[0]['name'], '乙');
assertEq('JSON 输出值类型(字符串化)', typeof parsedBack[0]['qty'], 'string');

// ===== DataPipeline: 其余 ops =====
out = runSteps(src, [
  { op: 'trim' },
  { op: 'dedupe' },
  { op: 'drop_empty' },
  { op: 'fill', col: '城市', value: '未知' },
  { op: 'replace', col: '城市', find: '北京', replace: 'BJ' },
  { op: 'split_col', col: '姓名', sep: '三', names: ['姓1', '姓2'] }
]);
assertEq('replace 生效(trim 后)', out.table.rows[0][2], 'BJ');
assertEq('split_col 加列(3+2)', out.table.header.length, 5);
assertEq('fill 空城市生效', out.table.rows[2][2], '未知');

out = runSteps(src, [
  { op: 'split_col', col: '姓名', sep: '三', names: ['姓1', '姓2'] },
  { op: 'limit', n: 2 },
  { op: 'select', cols: ['姓名', '城市'], optional: true }
]);
assertEq('limit 生效', out.table.rows.length, 2);
assertEq('select 后列数', out.table.header.length, 2);

assertThrows('未知 op 报错并列出可用项', () => runSteps(src, [{ op: 'nope' }]), '可用操作');
assertThrows('未知函数报错', () => runSteps(src, [{ op: 'derive', name: 'x', expr: "frobnicate(1)" }]), '未知函数');
assertThrows('列不存在报错并列出可用列', () => runSteps(src, [{ op: 'derive', name: 'x', expr: "col('不存在')" }]), '可用列');
assertThrows('steps 非数组报错', () => runSteps(src, '{"op":"filter"}'), '数组');
assertThrows('split_col 段数超限报错(引号字段)', () => runSteps('a,b\n"x,y,z",1\n',
  [{ op: 'split_col', col: 'a', sep: ',', names: ['p', 'q'] }], { format: 'csv' }), '拆出');
assertThrows('行数超限报错', () => DataPipeline.run('x\n1\n2\n', 'csv', '', '', true, '[]', 1, 30), '上限');

// 表达式语法错误带位置
assertThrows('表达式语法错误带定位', () => runSteps(src, [{ op: 'filter', expr: "col('a') ==" }]), '表达式错误');

// ===== 与 CsvWriter 往返(修复验证: 引号字段不再被裸 split 弄坏) =====
const dirtyCsv = '名称,备注\n"含,逗号","含""引号"\n';
const parsedDirty = CsvParser.parseSmartTable(dirtyCsv);
const roundTrip = Buffer.from(CsvWriter.buildCsvBytes(parsedDirty, false)).toString('utf8');
assertEq('解析-写出往返保真(CRLF 行尾)', roundTrip.replace(/\r\n/g, '\n').trim(), dirtyCsv.trim());
assertEq('引号字段列数正确', parsedDirty[1].length, 2);

if (failed > 0) {
  console.error(`${failed} 项失败`);
  process.exit(1);
}
console.log('TRANSFORM ALL OK');
