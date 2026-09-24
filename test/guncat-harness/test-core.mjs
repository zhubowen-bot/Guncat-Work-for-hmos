// Guncat Work 6.1 核心逻辑测试: PathMatcher / DiffUtil / EditCore / FileSearchCore
// 运行: node setup.mjs && node test-core.mjs (Node ≥ 22.6 原生 TS strip)
import { PathMatcher } from './gen/PathMatcher.ts';
import { DiffUtil, FileDiff } from './gen/DiffUtil.ts';
import { EditCore } from './gen/EditCore.ts';
import { FileSearchCore, GrepOptions } from './gen/FileSearchCore.ts';
import { ToolExecutionGuard } from './gen/ToolExecutionGuard.ts';
import { ToolSchemaValidator } from './gen/ToolSchemaValidator.ts';
import { ToolRegistry, SkillMeta, SkillFileMeta } from './gen/ToolRegistry.ts';
import { PromptBuilder } from './gen/PromptBuilder.ts';
import { LoopMetrics } from './gen/LoopMetrics.ts';
import { ToolScheduler } from './gen/ToolScheduler.ts';
import { SessionLogAggregator } from './gen/SessionLogAggregator.ts';
import { PromptBudget } from './gen/PromptBudget.ts';
import { FaultInjector } from './gen/FaultInjector.ts';
import { LLMProtocol } from './gen/LLMProtocol.ts';
import { RepeatDetector } from './gen/RepeatDetector.ts';
import { LoopDecisions } from './gen/LoopDecisions.ts';
import { ToolDefAdapter } from './gen/ToolDefAdapter.ts';
import { SSEProtocolAdapter, SSEParseContext } from './gen/SSEProtocolAdapter.ts';
import { WorkLoopStateMachine, WorkLoopState } from './gen/WorkLoopStateMachine.ts';
import { WorkLoopPlanner, WorkLoopTurnInfo, WorkLoopStep } from './gen/WorkLoopPlanner.ts';
import { PluginManifestLoader } from './gen/PluginManifestLoader.ts';
import { SkillDirectoryFormatter } from './gen/SkillDirectoryFormatter.ts';
import { RetryPolicy } from './gen/RetryPolicy.ts';
import { ToolRetryPolicy } from './gen/ToolRetryPolicy.ts';
import { WorkLoopSimulator } from './gen/WorkLoopSimulator.ts';
import { RetryAfterParser } from './gen/RetryAfterParser.ts';
import { LoopTurnInfoMapper } from './gen/LoopTurnInfoMapper.ts';
import { WorkLoopStepInfoBuilder } from './gen/WorkLoopStepInfoBuilder.ts';
import { WorkLoopDriver, WorkLoopDriverConfig } from './gen/WorkLoopDriver.ts';
import { PluginToolExecutor, PluginToolResult } from './gen/PluginToolExecutor.ts';
import { LoopError } from './gen/LoopError.ts';
import { ToolCallRecord } from './gen/ToolCallRecord.ts';
import { AbortSignal } from './gen/Types.ts';
import { SubagentIsolation } from './gen/SubagentIsolation.ts';

let passed = 0;
let failed = 0;

function check(name, cond) {
  if (cond) {
    passed++;
    console.log('  OK ' + name);
  } else {
    failed++;
    console.log('  FAIL: ' + name);
  }
}

// ===== PathMatcher =====
console.log('[PathMatcher]');
const m = (pattern, path) => PathMatcher.matchAny(path, PathMatcher.compileList(pattern, null));

check('**/*.csv 命中根文件', m('**/*.csv', 'a.csv'));
check('**/*.csv 命中深层', m('**/*.csv', 'x/y/z.csv'));
check('**/*.csv 不命中其他扩展', !m('**/*.csv', 'a/b.csv.txt'));
check('* 段内不跨目录', !m('*.md', 'a/b.md'));
check('*.md 命中同级', m('*.md', 'README.md'));
check('assets/*.svg 命中', m('assets/*.svg', 'assets/icon.svg'));
check('assets/*.svg 不命中子目录', !m('assets/*.svg', 'assets/sub/icon.svg'));
check('{docx,xlsx} 分支', m('output/{docx,xlsx}/*.docx', 'output/docx/r.docx'));
check('{docx,xlsx} 分支排除', !m('output/{docx,xlsx}/*', 'output/csv/r.csv'));
check('? 单字符', m('?at.txt', 'cat.txt') && !m('?at.txt', 'chat.txt'));
check('[ab] 字符类', m('[ab].txt', 'b.txt') && !m('[ab].txt', 'c.txt'));
check('默认大小写不敏感', m('DATA/*.CSV', 'data/x.csv'));
check('点号转义(不按正则)', !m('a.txt', 'aXtxt'));

// ===== DiffUtil =====
console.log('[DiffUtil]');
{
  const old1 = 'line1\nline2\nline3';
  const new1 = 'line1\nline2-changed\nline3';
  const d1 = DiffUtil.computeFileDiff(old1, new1, 'a.txt', 3);
  check('单处修改 adds=1', d1.adds === 1);
  check('单处修改 dels=1', d1.dels === 1);
  check('生成一个 hunk', d1.hunks.length === 1);
  check('hunk 含上下文行', d1.hunks[0].lines.length >= 3);
  const plain = DiffUtil.renderPlain(d1);
  check('渲染含 + 行', plain.indexOf('+ line2-changed') !== -1);
  check('渲染含 - 行', plain.indexOf('- line2') !== -1);

  const same = DiffUtil.computeFileDiff(old1, old1.slice(), 'a.txt', 3);
  check('相同文本无 hunk', same.hunks.length === 0 && same.adds === 0 && same.dels === 0);

  const old2 = 'a\nb\nc\nd\ne\nf';
  const new2 = 'A\nb\nc\nd\ne\nF';
  const d2 = DiffUtil.computeFileDiff(old2, new2, 'x', 1);
  check('两处远距修改产生两个 hunk', d2.hunks.length === 2);

  // 序列化往返(meta 持久化 → UI 重放)
  const round = FileDiff.fromJson(JSON.parse(JSON.stringify(d1.toJsonObject())));
  check('meta 序列化往返 adds 一致', round.adds === d1.adds && round.dels === d1.dels);
  check('meta 序列化往返行数一致',
    round.hunks.length === d1.hunks.length &&
    round.hunks[0].lines.length === d1.hunks[0].lines.length);
  check('meta 往返行文本一致', round.hunks[0].lines[1].text === d1.hunks[0].lines[1].text);

  // 插入 diff(对应 str_replace_editor insert)
  const d3 = DiffUtil.computeFileDiff('a\nc', 'a\nb\nc', 'x', 0);
  check('纯插入 adds=1 dels=0', d3.adds === 1 && d3.dels === 0);
}

// ===== EditCore =====
console.log('[EditCore]');
{
  // str_replace 基础语义
  const r1 = EditCore.apply('a\nb\nc', 'b', 'B', false);
  check('唯一替换成功', r1.ok && r1.status === 'ok' && r1.newText === 'a\nB\nc');
  const r2 = EditCore.apply('abc', 'x', 'y', false);
  check('未找到返回 not_found', !r2.ok && r2.status === 'not_found');
  const r3 = EditCore.apply('xa\nxb', 'x', 'Y', false);
  check('多处匹配返回 multiple 且带次数', !r3.ok && r3.status === 'multiple' && r3.matchCount === 2);
  const r4 = EditCore.apply('xa\nxb', 'x', 'Y', true);
  check('replace_all 全部替换', r4.ok && r4.newText === 'Ya\nYb');
  const r5 = EditCore.apply('a\nb\nc', 'b\n', '', false);
  check('带换行的空替换删除整行', r5.ok && r5.newText === 'a\nc');
  const r6 = EditCore.apply('aaaa', 'aa', 'b', false);
  check('非重叠计数 multiple=2', !r6.ok && r6.status === 'multiple' && r6.matchCount === 2);
  const r7 = EditCore.apply('xind', 'ind', 'y', false);
  check('子串匹配不锚定行首', r7.ok && r7.newText === 'xy');
  const r8 = EditCore.apply('Apple', 'apple', 'x', false);
  check('大小写严格', !r8.ok && r8.status === 'not_found');
  const r9 = EditCore.apply('a  b', 'a b', 'x', false);
  check('空白逐字符严格', !r9.ok && r9.status === 'not_found');

  // 换行风格自适应
  const c1 = EditCore.apply('a\r\nb\r\nc', 'a\nb', 'X', false);
  check('CRLF 文件接受 LF 多行 old_string', c1.ok && c1.newText === 'X\r\nc');
  const c2 = EditCore.apply('a\r\nb\r\nc', 'b', 'X\nY', false);
  check('CRLF 文件新文本换行自动对齐', c2.ok && c2.newText === 'a\r\nX\r\nY\r\nc');
  const c3 = EditCore.apply('a\nb', 'a\r\nb', 'X', false);
  check('LF 文件接受 CRLF old_string', c3.ok && c3.newText === 'X');
  const c4 = EditCore.apply('a\nb\nc', 'b', 'X\nY', false);
  check('LF 文件新文本保持 LF', c4.ok && c4.newText === 'a\nX\nY\nc');
  const c5 = EditCore.apply('a\r\nb', 'a\nb', 'a\nb', false);
  check('换行归一后等价内容判 no_change', !c5.ok && c5.status === 'no_change');
  const c6 = EditCore.apply('a\r\nb\r\nc', 'a\r\nb\r\nc', '', false);
  check('CRLF 内容原样匹配可整段删除', c6.ok && c6.newText === '');

  // insertLines
  const i1 = EditCore.insertLines('a\nc', 1, 'b');
  check('LF 中部插入', i1.ok && i1.newText === 'a\nb\nc');
  const i2 = EditCore.insertLines('a\nb', 0, 'x');
  check('LF 首部插入', i2.ok && i2.newText === 'x\na\nb');
  const i3 = EditCore.insertLines('a\nb', 2, 'c');
  check('LF 末尾插入', i3.ok && i3.newText === 'a\nb\nc');
  const i4 = EditCore.insertLines('a\r\nb\r\n', 1, 'X');
  check('CRLF 中部插入补 \\r', i4.ok && i4.newText === 'a\r\nX\r\nb\r\n');
  const i5 = EditCore.insertLines('a\r\nb\r\n', 0, 'X\nY');
  check('CRLF 多行插入逐行补 \\r', i5.ok && i5.newText === 'X\r\nY\r\na\r\nb\r\n');
  const i6 = EditCore.insertLines('a\r\nb', 2, 'c');
  check('CRLF 末行后插入原末行补 \\r', i6.ok && i6.newText === 'a\r\nb\r\nc');
  const i7 = EditCore.insertLines('a\nc', 1, 'b\r\nd');
  check('LF 文件插入文本剔除 CR', i7.ok && i7.newText === 'a\nb\nd\nc');
  const i8 = EditCore.insertLines('a\r\nb\r\n', 5, 'x');
  check('插入越界返回 range 且带总行数', !i8.ok && i8.status === 'range' && i8.lineTotal === 3);
}


console.log('[FileSearchCore]');

// 内存文件系统适配器(键为绝对路径, 与 fileIo 的绝对路径语义一致)
class MemFs {
  constructor(files) {
    this.files = files; // { '/a.md': 'text...' }
  }
  list(dirPath) {
    const prefix = dirPath.endsWith('/') ? dirPath : dirPath + '/';
    const seen = new Map();
    for (const p of Object.keys(this.files)) {
      if (!p.startsWith(prefix)) {
        continue;
      }
      const rest = p.substring(prefix.length);
      seen.set(rest.split('/')[0], rest.includes('/'));
    }
    return [...seen.keys()];
  }
  isDir(path) {
    const prefix = path.endsWith('/') ? path : path + '/';
    for (const p of Object.keys(this.files)) {
      if (p.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }
  readText(path, maxBytes) {
    const t = this.files[path];
    if (t === undefined) {
      return '';
    }
    return t.length > maxBytes ? '' : t;
  }
}

const fs = new MemFs({
  '/a.md': 'hello world\nfoo bar',
  '/sub/b.csv': 'id,name\n1,x\n2,y',
  '/sub/c.txt': 'say HELLO loud',
  '/logo.png': '\u0000\u0001binary'
});

{
  const hits = FileSearchCore.globSearch(fs, '/', '**/*.csv', '', ['.spill']);
  check('glob **/*.csv 命中 1 个', hits.length === 1 && hits[0].path === 'sub/b.csv');

  const hits2 = FileSearchCore.globSearch(fs, '/', 'sub/*', '', ['.spill']);
  check('glob sub/* 命中 2 个', hits2.length === 2);

  const hits3 = FileSearchCore.globSearch(fs, '/', '**/*.md', 'sub', ['.spill']);
  check('glob 限定 path 无命中', hits3.length === 0);

  const g1 = new GrepOptions();
  g1.pattern = 'hello';
  const ghits = FileSearchCore.grepSearch(fs, '/', g1, '', ['.spill']);
  check('grep 大小写不敏感命中 2 文件', ghits.length === 2);
  check('grep 命中带文件:行号', ghits.some(h => h.file === 'a.md' && h.line === 1));

  const g2 = new GrepOptions();
  g2.pattern = 'hello';
  g2.ignoreCase = false;
  const ghits2 = FileSearchCore.grepSearch(fs, '/', g2, '', ['.spill']);
  check('grep 大小写敏感仅命中原文小写', ghits2.length === 1 && ghits2[0].file === 'a.md');

  const g3 = new GrepOptions();
  g3.pattern = '\\d+';
  g3.glob = '*.csv';
  const ghits3 = FileSearchCore.grepSearch(fs, '/', g3, '', ['.spill']);
  check('grep 正则 \\d+ + glob 过滤', ghits3.length === 2 && ghits3.every(h => h.file.endsWith('.csv')));

  const g4 = new GrepOptions();
  g4.pattern = 'hello';
  g4.maxMatches = 1;
  const ghits4 = FileSearchCore.grepSearch(fs, '/', g4, '', ['.spill']);
  check('grep maxMatches 截断', ghits4.length === 1);

  const g5 = new GrepOptions();
  g5.pattern = '['; // 非法正则
  const ghits5 = FileSearchCore.grepSearch(fs, '/', g5, '', ['.spill']);
  check('非法正则返回空而非崩溃', ghits5.length === 0);

  const rendered = FileSearchCore.renderHits(ghits);
  check('renderHits 输出 file:line: text', rendered.indexOf('a.md:1: hello world') !== -1);
}

// ===== ToolExecutionGuard =====
console.log('[ToolExecutionGuard]');

// 任务先完成 → 透传结果
{
  const v = await ToolExecutionGuard.run(
    Promise.resolve('ok'), 1000, null, () => 'timeout', () => 'aborted');
  check('任务先完成透传结果', v === 'ok');
}

// 任务失败 → 透传错误
{
  let caught = '';
  try {
    await ToolExecutionGuard.run(
      Promise.reject(new Error('boom')), 1000, null, () => 'timeout', () => 'aborted');
  } catch (e) {
    caught = e.message;
  }
  check('任务失败透传错误', caught === 'boom');
}

// 超时 → 返回超时兜底
{
  const v = await ToolExecutionGuard.run(
    new Promise((resolve) => setTimeout(() => resolve('late'), 200)),
    30, null, () => 'timeout', () => 'aborted');
  check('超时返回兜底结果', v === 'timeout');
}

// 取消信号已置位 → 直接返回取消兜底
{
  const ab = new AbortSignal();
  ab.aborted = true;
  const v = await ToolExecutionGuard.run(
    new Promise(() => {}), 1000, ab, () => 'timeout', () => 'aborted');
  check('已取消直接返回', v === 'aborted');
}

// 等待中置位取消 → 快速返回取消兜底
{
  const ab = new AbortSignal();
  const task = ToolExecutionGuard.run(
    new Promise((resolve) => setTimeout(() => resolve('late'), 500)),
    2000, ab, () => 'timeout', () => 'aborted');
  setTimeout(() => { ab.aborted = true; }, 50);
  const started = Date.now();
  const v = await task;
  check('等待中取消返回取消兜底', v === 'aborted' && (Date.now() - started) < 500);
}

// 超时后底层任务才失败 → 不抛未处理拒绝, 仍返回超时兜底
{
  const v = await ToolExecutionGuard.run(
    new Promise((_resolve, reject) => setTimeout(() => reject(new Error('late-fail')), 100)),
    20, null, () => 'timeout', () => 'aborted');
  await new Promise((resolve) => setTimeout(resolve, 150));
  check('超时后底层失败被吞掉', v === 'timeout');
}

// ===== ToolSchemaValidator =====
console.log('[ToolSchemaValidator]');

const defRead = {
  name: 'read_file',
  description: 'read',
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '路径' },
      offset: { type: 'number', description: '行号' },
      verbose: { type: 'boolean', description: '开关' }
    },
    required: ['path']
  }
};

{
  check('缺 required 报错', ToolSchemaValidator.validate(defRead, {}) === '缺少参数 path');
  check('required 齐全通过', ToolSchemaValidator.validate(defRead, { path: 'a.txt' }) === '');
  check('string 接受 number 类型值', ToolSchemaValidator.validate(defRead, { path: 123 }) === '');
  check('number 接受数字字符串', ToolSchemaValidator.validate(defRead, { path: 'a', offset: '42' }) === '');
  check('number 拒绝非数字串', ToolSchemaValidator.validate(defRead, { path: 'a', offset: 'abc' }).indexOf('offset') !== -1);
  check('boolean 接受 "true"', ToolSchemaValidator.validate(defRead, { path: 'a', verbose: 'true' }) === '');
  check('boolean 拒绝 1', ToolSchemaValidator.validate(defRead, { path: 'a', verbose: 1 }).indexOf('verbose') !== -1);
  check('未知字段不拒绝', ToolSchemaValidator.validate(defRead, { path: 'a', extra: { x: 1 } }) === '');
  check('数组参数直接报错', ToolSchemaValidator.validate(defRead, ['a']) === '参数必须是 JSON 对象');
}

// ===== ToolCallRecord 可观测标记持久化 =====
console.log('[ToolCallRecord]');

{
  const rec = ToolCallRecord.of('c1', 'read_file', '{"path":"a"}');
  rec.timeout = true;
  rec.cancelled = false;
  rec.schemaError = true;
  rec.traceId = 'call-42';
  const round = ToolCallRecord.fromJson(JSON.parse(JSON.stringify(rec.toJson())));
  check('timeout 标记序列化往返', round.timeout === true);
  check('cancelled 标记序列化往返', round.cancelled === false);
  check('schemaError 标记序列化往返', round.schemaError === true);
  check('traceId 序列化往返', round.traceId === 'call-42');
  check('旧记录缺字段默认 false',
    ToolCallRecord.fromJson({ id: 'x', name: 'y', argsJson: '{}' }).cancelled === false &&
    ToolCallRecord.fromJson({ id: 'x', name: 'y', argsJson: '{}' }).schemaError === false &&
    ToolCallRecord.fromJson({ id: 'x', name: 'y', argsJson: '{}' }).traceId === '');
}

// ===== ToolRegistry =====
console.log('[ToolRegistry]');

{
  ToolRegistry.clear();
  ToolRegistry.sync([
    { name: 'read_file', description: 'r', parameters: { type: 'object', properties: {} } },
    { name: 'write_file', description: 'w', parameters: { type: 'object', properties: {} } },
    { name: 'admin_tool', description: 'a', parameters: { type: 'object', properties: {} } }
  ], ['read_file'], ['write_file'], 'test', '2');

  check('findDef 命中', ToolRegistry.findDef('read_file') !== null);
  check('findDef 未命中返回 null', ToolRegistry.findDef('missing') === null);
  check('readOnly 分类', ToolRegistry.isReadOnly('read_file') === true);
  check('mutating 分类', ToolRegistry.isMutating('write_file') === true);
  check('普通工具非只读', ToolRegistry.isReadOnly('admin_tool') === false);
  check('parallelSafe 默认 false', ToolRegistry.isParallelSafe('admin_tool') === false);
  ToolRegistry.setParallelSafe('admin_tool', true);
  check('setParallelSafe 可标记', ToolRegistry.isParallelSafe('admin_tool') === true);
  ToolRegistry.setParallelSafe('admin_tool', false);
  check('setParallelSafe 可关闭', ToolRegistry.isParallelSafe('admin_tool') === false);
  check('names 排除子代理工具', ToolRegistry.names(['admin_tool']).join(',') === 'read_file,write_file');
  check('defCount 统计', ToolRegistry.defCount() === 3);
  check('listTools 排除', ToolRegistry.listTools(['admin_tool']).length === 2 &&
    ToolRegistry.listTools(['admin_tool'])[0]['name'] === 'read_file');
  check('defsByPermission 未设权限时全通过', ToolRegistry.defsByPermission([]).length === 3);
  ToolRegistry.setPermissions('read_file', ['user']);
  ToolRegistry.setPermissions('write_file', ['user']);
  ToolRegistry.setPermissions('admin_tool', ['admin']);
  check('defsByPermission 设权限后空权限', ToolRegistry.defsByPermission([]).length === 0);
  check('defsByPermission 按权限', ToolRegistry.defsByPermission(['admin']).length === 1);
  check('defsByPermission 用户权限', ToolRegistry.defsByPermission(['user']).length === 2);
  check('defsByPermission 多权限合并', ToolRegistry.defsByPermission(['admin', 'user']).length === 3);
  ToolRegistry.setRuntimeConfig('read_file', 3000, 2);
  check('runtime config 写入', ToolRegistry.findMeta('read_file').timeoutMs === 3000 &&
    ToolRegistry.findMeta('read_file').maxRetries === 2);
  ToolRegistry.clear();
  ToolRegistry.sync([
    { name: 'core_a', description: 'c', parameters: { type: 'object', properties: {} } }
  ], [], []);
  ToolRegistry.registerPlugin('ppt_plugin', [
    { name: 'make_slide', description: 'p', parameters: { type: 'object', properties: {} } }
  ], ['make_slide'], []);
  check('插件 findDef 命中', ToolRegistry.findDef('make_slide') !== null);
  check('插件命名空间过滤', ToolRegistry.defs('ppt_plugin').length === 1);
  check('插件命名空间枚举', ToolRegistry.pluginNamespaces().join(',') === 'ppt_plugin');
  check('插件 defs 汇总', ToolRegistry.pluginDefs().length === 1);
  ToolRegistry.unregisterPlugin('ppt_plugin');
  check('插件注销后不可见', ToolRegistry.findDef('make_slide') === null);
  const skill = new SkillMeta();
  skill.id = 'ppt';
  skill.name = 'PPT';
  skill.description = '制作 PPT 时加载';
  const sf = new SkillFileMeta();
  sf.file = 'reference/deck-dsl.md';
  sf.desc = 'Deck 语法';
  skill.files.push(sf);
  ToolRegistry.registerSkill(skill);
  check('技能注册 findSkill', ToolRegistry.findSkill('ppt') !== null);
  check('技能清单枚举', ToolRegistry.skillIds().join(',') === 'ppt');
  ToolRegistry.unregisterSkill('ppt');
  check('技能注销后不可见', ToolRegistry.findSkill('ppt') === null);
  ToolRegistry.clear();
}

// ===== SubagentIsolation =====
console.log('[SubagentIsolation]');
{
  const out = 'subagents/sa_1';
  const parse = (s) => JSON.parse(s);

  check('裸路径写入重定向到 output_dir',
    SubagentIsolation.redirectPath('same_name.txt', out) === 'subagents/sa_1/same_name.txt');
  check('已带 output_dir 前缀不再重复',
    SubagentIsolation.redirectPath('subagents/sa_1/a.txt', out) === 'subagents/sa_1/a.txt');
  check('绝对路径去除前导斜杠后仍重定向',
    SubagentIsolation.redirectPath('/abs.txt', out) === 'subagents/sa_1/abs.txt');
  check('跨目录 ../ 仍保留供 resolveSafe 拒绝',
    SubagentIsolation.redirectPath('../escape.txt', out) === 'subagents/sa_1/../escape.txt');

  const w1 = parse(SubagentIsolation.isolatedArgsJson('write_file',
    JSON.stringify({ path: 'main_marker.txt', content: 'x' }), out));
  check('write_file 不覆盖主文件', w1.path === 'subagents/sa_1/main_marker.txt');

  const del = parse(SubagentIsolation.isolatedArgsJson('delete_file',
    JSON.stringify({ path: 'main_delete_probe.txt' }), out));
  check('delete_file 只删自己目录内副本', del.path === 'subagents/sa_1/main_delete_probe.txt');

  const mv = parse(SubagentIsolation.isolatedArgsJson('move_file',
    JSON.stringify({ from: 'main.txt', to: 'moved.txt' }), out));
  check('move_file 源与目标都重定向', mv.from === 'subagents/sa_1/main.txt' && mv.to === 'subagents/sa_1/moved.txt');

  const tf = parse(SubagentIsolation.isolatedArgsJson('transform_file',
    JSON.stringify({ input: 'main_data.csv', output: 'out.csv' }), out));
  check('transform_file 输入读主文件、输出重定向',
    tf.input === 'main_data.csv' && tf.output === 'subagents/sa_1/out.csv');

  const docx = parse(SubagentIsolation.isolatedArgsJson('write_docx',
    JSON.stringify({ path: 'report.docx', doc_file: 'main_doc.json' }), out));
  check('write_docx 目标重定向、doc_file 输入保留',
    docx.path === 'subagents/sa_1/report.docx' && docx.doc_file === 'main_doc.json');

  const dl = parse(SubagentIsolation.isolatedArgsJson('download_file',
    JSON.stringify({ url: 'https://x/a.png' }), out));
  check('download_file 省略 path 时落入 output_dir', dl.path === 'subagents/sa_1/download');

  const runJs = parse(SubagentIsolation.isolatedArgsJson('run_js',
    JSON.stringify({ code: 'write("out.csv", "x")' }), out));
  check('run_js 注入 _output_dir', runJs._output_dir === 'subagents/sa_1');

  const read = SubagentIsolation.isolatedArgsJson('read_file',
    JSON.stringify({ path: 'main_data.csv' }), out);
  check('read_file 不重定向(可读主工作区)', read === JSON.stringify({ path: 'main_data.csv' }));

  const view = parse(SubagentIsolation.isolatedArgsJson('str_replace_editor',
    JSON.stringify({ command: 'view', path: 'main.txt' }), out));
  check('str_replace_editor view 不重定向', view.path === 'main.txt');
  const create = parse(SubagentIsolation.isolatedArgsJson('str_replace_editor',
    JSON.stringify({ command: 'create', path: 'new.txt' }), out));
  check('str_replace_editor create 重定向', create.path === 'subagents/sa_1/new.txt');

  check('delete_file 清空工作区被拦截',
    SubagentIsolation.isolationBlockReason('delete_file', JSON.stringify({ path: '' }), out) !== '');
  check('delete_file 删自己目录内不拦截',
    SubagentIsolation.isolationBlockReason('delete_file', JSON.stringify({ path: 'subagents/sa_1/x.txt' }), out) === '');
  check('delete_file 越界(主文件)被拦截',
    SubagentIsolation.isolationBlockReason('delete_file', JSON.stringify({ path: 'main/protected.txt' }), out) !== '');
  check('move_file 源为主文件被拦截',
    SubagentIsolation.isolationBlockReason('move_file', JSON.stringify({ from: 'main.txt', to: 'x.txt' }), out) !== '');
  check('move_file 源在目录内放行',
    SubagentIsolation.isolationBlockReason('move_file', JSON.stringify({ from: 'subagents/sa_1/a.txt', to: 'b.txt' }), out) === '');
  const notice = SubagentIsolation.redirectNotice('write_file', JSON.stringify({ path: 'main/evil.txt' }), out);
  check('写入越界返回重定向提示',
    notice !== '' && notice.indexOf('main/evil.txt') >= 0 && notice.indexOf(out) >= 0);
  check('目录内写入无提示',
    SubagentIsolation.redirectNotice('write_file', JSON.stringify({ path: 'subagents/sa_1/ok.txt' }), out) === '');
}

// ===== PromptBuilder =====
console.log('[PromptBuilder]');

{
  check('身份块', PromptBuilder.identity().indexOf('# 角色') !== -1);
  check('工作区块', PromptBuilder.workspace().indexOf('# 工作区') !== -1);
  check('工具目录块', PromptBuilder.toolsDirectory().indexOf('# 可用工具') !== -1);
  check('方法论块', PromptBuilder.methodology().indexOf('四步法') !== -1);
  check('工作流块', PromptBuilder.workflow().indexOf('# 工作流程') !== -1);
  check('压缩块', PromptBuilder.compression().indexOf('# 上下文压缩') !== -1);
  check('输出块', PromptBuilder.output().indexOf('输出丰富性') !== -1);
  check('Mermaid 块', PromptBuilder.mermaid().indexOf('flowchart TD') !== -1);
  check('反幻觉块', PromptBuilder.antiHallucination().indexOf('# 反幻觉') !== -1);
  check('安全块', PromptBuilder.safety().indexOf('# 安全') !== -1);
  check('能力边界块', PromptBuilder.capability().indexOf('# 能力边界') !== -1);
  check('自检清单块', PromptBuilder.preDeliveryChecklist().indexOf('# 交付前自检清单') !== -1);
  const p = PromptBuilder.build('【技能】test-skill');
  check('组装包含技能块', p.indexOf('【技能】test-skill') !== -1);
  check('组装以开始指令结尾', p.trimEnd().endsWith('现在开始：收到任务后，先分析复杂度，再按上述流程执行。'));

  const defs2 = [
    { name: 'read_file', description: '读文件', parameters: { type: 'object', properties: {} } },
    { name: 'brand_new_tool', description: '全新工具', parameters: { type: 'object', properties: {} } }
  ];
  const missing = PromptBuilder.missingToolNames(PromptBuilder.toolsDirectory(), defs2);
  check('静态清单缺新工具', missing.indexOf('brand_new_tool') !== -1 && missing.indexOf('read_file') === -1);
  const dir = PromptBuilder.buildToolDirectory(PromptBuilder.defsByNames(defs2, missing));
  check('自动目录含新工具', dir.indexOf('brand_new_tool') !== -1);
  const p2 = PromptBuilder.build('', dir);
  check('组装注入自动工具目录', p2.indexOf('# 自动工具目录') !== -1);
  const dynOnly = PromptBuilder.buildWithToolDirectoryMode('', 'STATIC_DIR', 'DYNAMIC_DIR', 'dynamic_only');
  check('A/B dynamic_only 不含静态目录', dynOnly.indexOf('STATIC_DIR') === -1 && dynOnly.indexOf('DYNAMIC_DIR') !== -1);
  const bothMode = PromptBuilder.buildWithToolDirectoryMode('', 'STATIC_DIR', 'DYNAMIC_DIR', 'static_plus_dynamic');
  check('A/B static_plus_dynamic 双目录', bothMode.indexOf('STATIC_DIR') !== -1 && bothMode.indexOf('DYNAMIC_DIR') !== -1);
}

// ===== LoopMetrics =====
console.log('[LoopMetrics]');

{
  const m = new LoopMetrics();
  m.recordTurn(true);
  m.recordToolCall(true, false, false, false);
  m.recordTurn(true);
  m.recordToolCall(false, true, false, true);
  m.recordTurn(false);
  m.recordSubagentCall();
  m.recordRetry();
  m.recordCompaction();
  m.recordMaxTokens();
  m.recordRetry();
  const s = m.snapshot();
  check('steps 计数', s.steps === 3);
  check('toolCalls 计数', s.toolCalls === 2);
  check('success/failure 计数', s.toolSuccesses === 1 && s.toolFailures === 1);
  check('timeout/schema 计数', s.timeouts === 1 && s.schemaErrors === 1);
  check('invalidSteps 计数', s.invalidSteps === 1);
  check('subagentCalls 计数', s.subagentCalls === 1);
  check('retry/compact/maxTokens 计数', s.retries === 2 && s.compactions === 1 && s.maxTokens === 1);
  check('successRate 计算', s.successRate === 50);
  check('timeoutRate 计算', s.timeoutRate === 50);
  check('invalidStepRate 计算', s.invalidStepRate === 33.33);
}

// ===== ToolScheduler =====
console.log('[ToolScheduler]');

{
  const groups = ToolScheduler.schedule([true, true, false, true], 2);
  check('分组数量', groups.length === 3);
  check('只读组连续聚合', groups[0].start === 0 && groups[0].count === 2 && groups[0].parallel === true);
  check('非只读单组', groups[1].start === 2 && groups[1].count === 1 && groups[1].parallel === false);
  check('尾部只读单组', groups[2].start === 3 && groups[2].count === 1 && groups[2].parallel === true);
  check('poolSize 上限', ToolScheduler.poolSize(groups[0], 2) === 2);
  check('非只读 poolSize 为 1', ToolScheduler.poolSize(groups[1], 8) === 1);
  const empty = ToolScheduler.schedule([], 4);
  check('空调度', empty.length === 0);
  const seq = ToolScheduler.schedule([true, true, true], 4, false);
  check('禁并行后全部单组', seq.length === 3 && seq[0].parallel === false && seq[1].count === 1);
  check('禁并行 poolSize 为 1', ToolScheduler.poolSize(seq[0], 4) === 1);
  const sum = ToolScheduler.summary(groups, 2);
  check('summary 统计', sum.groupCount === 3 && sum.parallelGroupCount === 2 &&
    sum.readOnlyGroupCount === 1 && sum.maxPoolSize === 2);
}

// ===== SessionLogAggregator =====
console.log('[SessionLogAggregator]');

{
  const events = [
    { type: 'turn_start', protocol: 'openai-completions' },
    { type: 'tool_result', name: 'read_file', ok: true, durationMs: 10, timeout: false, cancelled: false, schemaError: false },
    { type: 'tool_result', name: 'write_file', ok: false, durationMs: 20, timeout: true, cancelled: false, schemaError: false },
    { type: 'tool_result', name: 'read_file', ok: false, durationMs: 5, timeout: false, cancelled: true, schemaError: true },
    { type: 'turn_end', status: 'complete' }
  ];
  const agg = SessionLogAggregator.aggregateToolCalls(events);
  check('聚合工具数', agg.length === 2);
  check('read_file 聚合', agg[0].name === 'read_file' && agg[0].calls === 2 &&
    agg[0].ok === 1 && agg[0].fail === 1 && agg[0].cancelled === 1);
  const s = SessionLogAggregator.summarize(events);
  check('事件总数', s.totalEvents === 5);
  check('turn 计数', s.turnStarts === 1 && s.turnEnds === 1 && s.statusCounts['complete'] === 1);
  check('工具总量', s.toolTotalCalls === 3 && s.toolTotalOk === 1 &&
    s.toolTotalTimeout === 1 && s.toolTotalSchemaError === 1);
  check('协议维度计数', s.protocolCounts['openai-completions'] === 1);
  const lat = SessionLogAggregator.buildToolLatencyEvents(events);
  check('延迟分位事件', lat.length === 2 && lat[0].type === 'tool_latency' &&
    lat[0].p50Ms === 5 && lat[1].p90Ms === 20);
  const all = SessionLogAggregator.aggregateAll([events, [
    { type: 'turn_start', protocol: 'anthropic-messages' },
    { type: 'tool_result', name: 'read_file', ok: true, durationMs: 15, timeout: false, cancelled: false, schemaError: false },
    { type: 'turn_end', status: 'complete' }
  ]]);
  check('跨会话协议汇总', all.protocolCounts['openai-completions'] === 1 &&
    all.protocolCounts['anthropic-messages'] === 1);
  check('跨会话工具汇总', all.toolTotalCalls === 4 &&
    all.toolCalls.length === 2 && all.toolCalls[0].calls === 3);
  check('跨会话延迟分位合并', all.toolCalls[0].p50Ms === 10);
  check('read_file 延迟分位', agg[0].p50Ms === 5 && agg[0].p90Ms === 10 && agg[0].p99Ms === 10);
  check('write_file 延迟分位', agg[1].p50Ms === 20);
  check('percentile 空列表', SessionLogAggregator.percentile([], 0.9) === 0);
}

// ===== PromptBudget =====
console.log('[PromptBudget]');

{
  check('空串 0 token', PromptBudget.estimateTokens('') === 0);
  check('CJK 1 字 1 token', PromptBudget.estimateTokens('中文') === 2);
  check('英文近似', PromptBudget.estimateTokens('hello world') === 4);
  const s = PromptBudget.fromSections({ 'a': '中文', 'b': 'hello world' });
  check('sections 汇总', s.totalTokens === 6 && s.entries.length === 2);
  const p = PromptBudget.fromPrompt('你是一个智能体');
  check('fromPrompt 单条', p.entries.length === 1 && p.totalTokens === 7);
  check('overTarget 超预算', p.overTarget(5) === true && p.overTarget(7) === false);
  check('remaining 剩余', p.remaining(10) === 3 && p.remaining(5) === -2);
}

// ===== FaultInjector =====
console.log('[FaultInjector]');

{
  const happy = FaultInjector.execute(FaultInjector.scenario('happy'), 0);
  check('happy 成功', happy.ok === true && happy.timeout === false);
  const to = FaultInjector.execute(FaultInjector.scenario('one_timeout'), 0);
  check('超时注入', to.ok === false && to.timeout === true);
  const to2 = FaultInjector.execute(FaultInjector.scenario('one_timeout'), 1);
  check('脚本外成功', to2.ok === true);
  const se = FaultInjector.execute(FaultInjector.scenario('one_schema_error'), 0);
  check('schema 错误注入', se.ok === false && se.schemaError === true);
  const cn = FaultInjector.execute(FaultInjector.scenario('one_cancel'), 0);
  check('取消注入', cn.ok === false && cn.cancelled === true);
  const af = FaultInjector.execute(FaultInjector.scenario('all_fail'), 1);
  check('全失败场景', af.ok === false && af.fail === true);
}

// ===== LLMProtocol =====
console.log('[LLMProtocol]');

{
  check('provider→responses', LLMProtocol.pick('openai-responses') === 'responses');
  check('provider→anthropic', LLMProtocol.pick('anthropic-messages') === 'anthropic');
  check('provider→completions', LLMProtocol.pick('deepseek') === 'completions');
  check('responses 端点', LLMProtocol.resolveEndpoint('https://api.openai.com/v1', 'responses', true) ===
    'https://api.openai.com/v1/responses');
  check('anthropic 端点', LLMProtocol.resolveEndpoint('https://api.anthropic.com/v1', 'anthropic', true) ===
    'https://api.anthropic.com/v1/messages');
  check('completions 端点', LLMProtocol.resolveEndpoint('https://x.com/v1', 'completions', true) ===
    'https://x.com/v1/chat/completions');
  check('autoSuffix=false 原样', LLMProtocol.resolveEndpoint(' https://x.com/custom ', 'completions', false) ===
    'https://x.com/custom');
}

// ===== RepeatDetector =====
console.log('[RepeatDetector]');

{
  const d = new RepeatDetector();
  let o1 = d.record('read_file', '{"path":"a"}');
  check('首次计数', o1.count === 1 && o1.shouldRemind === false);
  let o2 = d.record('read_file', '{"path":"a"}');
  check('二次计数', o2.count === 2 && o2.shouldRemind === false);
  let o3 = d.record('read_file', '{"path":"a"}');
  check('三次提醒', o3.count === 3 && o3.shouldRemind === true);
  let o4 = d.record('read_file', '{"path":"b"}');
  check('换参重置', o4.count === 1 && o4.shouldRemind === false);
  d.reset();
  let o5 = d.record('read_file', '{"path":"a"}');
  check('reset 后重新计数', o5.count === 1);
}

// ===== LoopDecisions =====
console.log('[LoopDecisions]');

{
  check('快照相同不追加', LoopDecisions.shouldAppendSnapshot('S', 'S') === false);
  check('快照变化追加', LoopDecisions.shouldAppendSnapshot('S1', 'S2') === true);
  check('溢出强制压缩', LoopDecisions.shouldForceCompactOnOverflow(false, true, false) === true);
  check('已压缩不再压', LoopDecisions.shouldForceCompactOnOverflow(false, true, true) === false);
  check('中止不压缩', LoopDecisions.shouldForceCompactOnOverflow(true, true, false) === false);
  check('非溢出不压缩', LoopDecisions.shouldForceCompactOnOverflow(false, false, false) === false);
  check('max_tokens 收尾', LoopDecisions.shouldBreakOnMaxTokens('max_tokens') === true);
  check('无效步判定', LoopDecisions.isInvalidStep(0) === true && LoopDecisions.isInvalidStep(2) === false);
}

// ===== ToolDefAdapter =====
console.log('[ToolDefAdapter]');

{
  const tools = [{ name: 'read_file', description: '读文件', parameters: { type: 'object', properties: {} } }];
  const c = ToolDefAdapter.adapt(tools, 'completions');
  check('completions 形态', c[0]['type'] === 'function' && c[0]['function']['name'] === 'read_file');
  const r = ToolDefAdapter.adapt(tools, 'responses');
  check('responses 形态', r[0]['type'] === 'function' && r[0]['name'] === 'read_file');
  const a = ToolDefAdapter.adapt(tools, 'anthropic');
  check('anthropic 形态', a[0]['name'] === 'read_file' && a[0]['input_schema']['type'] === 'object');
}

// ===== SSEProtocolAdapter =====
console.log('[SSEProtocolAdapter]');

{
  const adapter = new SSEProtocolAdapter();
  adapter.protocol = 'fake';
  adapter.extractDelta = (s) => s.includes('T') ? 'd' : '';
  adapter.extractReasoning = (s) => s.includes('R') ? 'r' : '';
  adapter.extractUsage = (s) => s.includes('U') ? { 'output_tokens': 1 } : null;
  adapter.collectToolEvent = (s) => { seenTool = seenTool || s.includes('F'); };
  adapter.extractFinishReason = (s) => s.includes('M') ? 'max_tokens' : '';
  let seenTool = false;
  const ctx = new SSEParseContext();
  let tokens = ''; let reasoning = ''; let usageCount = 0; let finish = '';
  ctx.onToken = (d) => { tokens += d; };
  ctx.onReasoning = (r) => { reasoning += r; };
  ctx.onUsage = (u) => { usageCount++; };
  ctx.onToolEvent = (s) => { adapter.collectToolEvent(s); };
  ctx.onFinishReason = (f) => { finish = f; };
  adapter.handleLine('T R U F M', ctx);
  check('适配器文本派发', tokens === 'd' && reasoning === 'r');
  check('适配器 usage 派发', usageCount === 1);
  check('适配器工具事件', seenTool === true);
  check('适配器 finish 派发', finish === 'max_tokens');
  let stopped = false;
  adapter.extractFailure = (s) => s.includes('E') ? 'boom' : '';
  const ctx2 = new SSEParseContext();
  ctx2.onFailure = (m) => { stopped = true; return true; };
  adapter.handleLine('E', ctx2);
  check('失败优先停止', stopped === true);
}

// ===== WorkLoopStateMachine =====
console.log('[WorkLoopStateMachine]');

{
  const sm = new WorkLoopStateMachine();
  check('初始 idle', sm.currentText() === 'idle');
  check('start 合法', sm.start() === true && sm.currentText() === 'running');
  check('重复 start 非法', sm.start() === false);
  check('pause 合法', sm.pause() === true && sm.currentText() === 'paused');
  check('resume 合法', sm.resume() === true && sm.currentText() === 'running');
  check('awaitUser 合法', sm.awaitUser() === true && sm.currentText() === 'awaiting_user');
  check('userAnswered 合法', sm.userAnswered() === true && sm.currentText() === 'running');
  check('finish 合法', sm.finish() === true && sm.currentText() === 'idle');
  check('idle 后 abort 合法', sm.abort() === true && sm.currentText() === 'aborting');
  check('aborted 回 idle', sm.aborted() === true && sm.currentText() === 'idle');
  check('can 校验', sm.can('start') === true && sm.can('finish') === false);
  sm.start();
  sm.fail();
  check('fail 回 idle', sm.currentText() === 'idle');
}

// ===== WorkLoopPlanner =====
console.log('[WorkLoopPlanner]');

{
  const info = new WorkLoopTurnInfo();
  info.toolCallsCount = 2;
  let d = WorkLoopPlanner.decide(info);
  check('有工具调用 → tool', d.action === WorkLoopStep.TOOL && d.reason === 'tool_calls');
  info.toolCallsCount = 0; info.contentLength = 5;
  d = WorkLoopPlanner.decide(info);
  check('有文本 → finish', d.action === WorkLoopStep.FINISH && d.reason === 'final_answer');
  info.contentLength = 0; info.finishReason = 'max_tokens';
  d = WorkLoopPlanner.decide(info);
  check('max_tokens → finish', d.action === WorkLoopStep.FINISH && d.reason === 'max_tokens');
  info.finishReason = ''; info.contextOverflow = true;
  d = WorkLoopPlanner.decide(info);
  check('溢出 → compact', d.action === WorkLoopStep.COMPACT);
  info.contextOverflow = false; info.aborted = true;
  d = WorkLoopPlanner.decide(info);
  check('中止 → abort', d.action === WorkLoopStep.ABORT);
  info.aborted = false; info.maxStepsReached = true;
  d = WorkLoopPlanner.decide(info);
  check('达步数上限 → finish', d.action === WorkLoopStep.FINISH && d.reason === 'max_steps');
  const toolInfo = new WorkLoopTurnInfo(); toolInfo.toolCallsCount = 2;
  check('describe 工具调用', WorkLoopPlanner.describe(toolInfo) === '工具调用 2');
  const abortInfo = new WorkLoopTurnInfo(); abortInfo.aborted = true;
  check('describe 中止', WorkLoopPlanner.describe(abortInfo) === '中止');
  const compactInfo = new WorkLoopTurnInfo(); compactInfo.contextOverflow = true;
  check('describe 压缩', WorkLoopPlanner.describe(compactInfo) === '上下文溢出压缩');
  const noOut = new WorkLoopTurnInfo();
  check('describe 无输出', WorkLoopPlanner.describe(noOut) === '无输出收尾');
}

// ===== PluginManifestLoader =====
console.log('[PluginManifestLoader]');

{
  ToolRegistry.clear();
  ToolRegistry.sync([
    { name: 'core_read', description: 'c', parameters: { type: 'object', properties: {} } }
  ], ['core_read'], []);
  const manifestJson = JSON.stringify({
    id: 'ppt_plugin',
    version: '2',
    permissions: ['user'],
    tools: [
      { name: 'make_slide', description: 'p', parameters: { type: 'object', properties: {} }, readOnly: true, timeoutMs: 5000, maxRetries: 2 },
      { name: 'core_read', description: 'conflict', parameters: { type: 'object', properties: {} } }
    ],
    skills: [
      { id: 'ppt', name: 'PPT', description: '制作 PPT', files: [{ file: 'reference/deck-dsl.md', desc: 'Deck' }] }
    ]
  });
  const manifest = PluginManifestLoader.parse(manifestJson);
  check('manifest 解析', manifest !== null && manifest.id === 'ppt_plugin' && manifest.tools.length === 2);
  if (manifest !== null) {
    const r = PluginManifestLoader.apply(manifest);
    check('插件工具注册', ToolRegistry.findDef('make_slide') !== null);
    check('插件工具运行期配置', ToolRegistry.findMeta('make_slide') !== null &&
      ToolRegistry.findMeta('make_slide').timeoutMs === 5000 &&
      ToolRegistry.findMeta('make_slide').maxRetries === 2);
    check('插件技能注册', ToolRegistry.findSkill('ppt') !== null);
    check('冲突跳过', r.conflicts.join(',') === 'core_read:core' && r.ok === false);
    check('冲突未覆盖核心', ToolRegistry.findDef('core_read') !== null &&
      ToolRegistry.findMeta('core_read') !== null && ToolRegistry.findMeta('core_read').namespace === 'core');
    PluginManifestLoader.unload(manifest);
    check('卸载后工具/技能移除', ToolRegistry.findDef('make_slide') === null && ToolRegistry.findSkill('ppt') === null);
  }
  check('非法 manifest 返回 null', PluginManifestLoader.parse('{}') === null);
  ToolRegistry.clear();
}

// ===== SkillDirectoryFormatter =====
console.log('[SkillDirectoryFormatter]');

{
  const sk = new SkillMeta();
  sk.id = 'ppt'; sk.name = 'PPT'; sk.description = '制作 PPT';
  const skf = new SkillFileMeta();
  skf.file = 'reference/deck-dsl.md'; skf.desc = 'Deck 语法';
  sk.files.push(skf);
  const list = [sk];
  const full = SkillDirectoryFormatter.format(list, 'full_index');
  check('完整索引含技能 id', full.indexOf('ppt') !== -1 && full.indexOf('制作 PPT') !== -1);
  const trigger = SkillDirectoryFormatter.format(list, 'trigger_only');
  check('触发模式不含技能 id', trigger.indexOf('ppt') === -1 && trigger.indexOf('list_skills') !== -1);
  const txt = SkillDirectoryFormatter.listText(list);
  check('listText 含文件', txt.indexOf('reference/deck-dsl.md') !== -1);
}

// ===== RetryPolicy =====
console.log('[RetryPolicy]');

{
  const p = new RetryPolicy(3, 500, 8000, 0.2);
  let d = p.decide('rate_limit', 0, -1, 0.5);
  check('可重试 kind 且退避', d.shouldRetry === true && d.delayMs === 500 && d.reason === 'backoff');
  d = p.decide('server', 2, -1, 0.5);
  check('指数退避', d.delayMs === 2000);
  d = p.decide('auth', 0, -1, 0.5);
  check('auth 不重试', d.shouldRetry === false && d.reason === 'kind_not_retryable:auth');
  d = p.decide('rate_limit', 3, -1, 0.5);
  check('达上限不重试', d.shouldRetry === false && d.reason === 'max_retries');
  d = p.decide('rate_limit', 0, 300, 0.5);
  check('retry-after 尊重', d.delayMs === 300 && d.reason === 'retry_after');
  d = p.decide('rate_limit', 0, 20000, 0.5);
  check('retry-after 封顶', d.delayMs === 8000);
  d = p.decide('transport', 0, -1, 0.0);
  check('抖动下限', d.delayMs === 400);
  d = p.decide('transport', 0, -1, 1.0);
  check('抖动上限', d.delayMs === 600);
}

// ===== ToolRetryPolicy =====
console.log('[ToolRetryPolicy]');

{
  const p = new ToolRetryPolicy();
  let d = p.decide('web_fetch', 0, true, false, false, false, -1, 0.5);
  check('web_fetch 超时可重试', d.shouldRetry === true && d.delayMs === 600);
  d = p.decide('read_file', 0, true, false, false, false);
  check('非网络工具不重试', d.shouldRetry === false && d.reason === 'not_retryable');
  d = p.decide('web_fetch', 1, true, false, false, false);
  check('达到上限不重试', d.shouldRetry === false && d.reason === 'max_retries');
  d = p.decide('web_fetch', 0, true, false, true, false);
  check('取消不重试', d.shouldRetry === false && d.reason === 'cancelled');
  d = p.decide('web_fetch', 0, false, false, false, false);
  check('成功不重试', d.shouldRetry === false && d.reason === 'ok');
  p.setMaxRetries('web_fetch', 3);
  d = p.decide('web_fetch', 2, true, false, false, false);
  check('override 后第3次仍重试', d.shouldRetry === true);
  d = p.decide('web_fetch', 3, true, false, false, false);
  check('override 上限生效', d.shouldRetry === false && d.reason === 'max_retries');
}

// ===== WorkLoopSimulator =====
console.log('[WorkLoopSimulator]');

{
  const happy = WorkLoopSimulator.run((i) => {
    if (i < 2) {
      const t = new WorkLoopTurnInfo();
      t.toolCallsCount = 1;
      return t;
    }
    const t = new WorkLoopTurnInfo();
    t.contentLength = 3;
    return t;
  }, 10);
  check('happy 循环工具→收尾', happy.toolSteps === 2 && happy.textSteps === 1 &&
    happy.finalReason === 'final_answer' && happy.aborted === false);

  const abort = WorkLoopSimulator.run((i) => {
    const t = new WorkLoopTurnInfo();
    if (i === 0) {
      t.toolCallsCount = 1;
    } else {
      t.aborted = true;
    }
    return t;
  }, 10);
  check('取消场景中止', abort.aborted === true && abort.finalReason === 'aborted');

  const overflow = WorkLoopSimulator.run((i) => {
    const t = new WorkLoopTurnInfo();
    if (i === 0) {
      t.contextOverflow = true;
    } else {
      t.contentLength = 1;
    }
    return t;
  }, 10);
  check('溢出压缩后收尾', overflow.compactSteps === 1 && overflow.textSteps === 1);

  const max = WorkLoopSimulator.run((i) => {
    const t = new WorkLoopTurnInfo();
    t.toolCallsCount = 1;
    return t;
  }, 3);
  check('步数上限兜底', max.steps === 3 && max.finalReason === 'max_steps');
}

// ===== WorkLoopDriver ↔ WorkLoopSimulator 等价 =====
console.log('[WorkLoopDriver/Simulator equivalence]');

{
  const seq = [1, 1, 0];
  let di = 0;
  const dHappy = await WorkLoopDriver.run({
    async runTurn() {
      if (di >= seq.length) {
        return null;
      }
      const t = new WorkLoopTurnInfo();
      if (seq[di] === 1) {
        t.toolCallsCount = 1;
      } else {
        t.contentLength = 1;
      }
      di++;
      return t;
    }
  }, new WorkLoopDriverConfig());
  const sHappy = WorkLoopSimulator.run((i) => {
    if (i >= seq.length) {
      return null;
    }
    const t = new WorkLoopTurnInfo();
    if (seq[i] === 1) {
      t.toolCallsCount = 1;
    } else {
      t.contentLength = 1;
    }
    return t;
  }, 200);
  check('driver/simulator 等价: happy', dHappy.steps === sHappy.steps &&
    dHappy.toolSteps === sHappy.toolSteps && dHappy.textSteps === sHappy.textSteps &&
    dHappy.finalReason === sHappy.finalReason);

  let ai = 0;
  const dAbort = await WorkLoopDriver.run({
    async runTurn() {
      ai++;
      const t = new WorkLoopTurnInfo();
      if (ai === 1) {
        t.toolCallsCount = 1;
      } else {
        t.aborted = true;
      }
      return t;
    }
  }, new WorkLoopDriverConfig());
  const sAbort = WorkLoopSimulator.run((i) => {
    const t = new WorkLoopTurnInfo();
    if (i === 0) {
      t.toolCallsCount = 1;
    } else {
      t.aborted = true;
    }
    return t;
  }, 10);
  check('driver/simulator 等价: abort', dAbort.aborted === sAbort.aborted &&
    dAbort.finalReason === sAbort.finalReason);
}

// ===== RetryAfterParser =====
console.log('[RetryAfterParser]');

{
  check('秒数形态', RetryAfterParser.parseMs('120', 0) === 120000);
  check('空白容错', RetryAfterParser.parseMs('  5  ', 0) === 5000);
  const now = Date.parse('Wed, 21 Oct 2015 07:28:00 GMT');
  check('HTTP-date 形态', RetryAfterParser.parseSeconds('Wed, 21 Oct 2015 07:28:05 GMT', now) === 5);
  check('无效返回 -1', RetryAfterParser.parseMs('abc', 0) === -1);
  check('空串返回 -1', RetryAfterParser.parseMs('', 0) === -1);
}

// ===== WorkLoopDriver =====
console.log('[WorkLoopDriver]');

{
  const out = await WorkLoopDriver.run({
    async runTurn(i) {
      const t = new WorkLoopTurnInfo();
      if (i < 2) {
        t.toolCallsCount = 1;
      } else {
        t.contentLength = 2;
      }
      return t;
    }
  }, new WorkLoopDriverConfig());
  check('driver happy 循环', out.toolSteps === 2 && out.textSteps === 1 && out.aborted === false);
  check('driver isFinished', out.isFinished() === true);
}

{
  let retries = 0;
  let calls = 0;
  const cfg = new WorkLoopDriverConfig();
  cfg.maxRetriesPerTurn = 2;
  const out = await WorkLoopDriver.run({
    async runTurn(i) {
      calls++;
      if (calls === 1) {
        const e = new Error('rate');
        e.kind = 'rate_limit';
        throw e;
      }
      const t = new WorkLoopTurnInfo();
      t.contentLength = 1;
      return t;
    },
    onRetry(attempt) { retries = attempt; }
  }, cfg);
  check('driver 重试回调', retries === 1 && out.retries === 1 && out.textSteps === 1);
}

{
  let compacts = 0;
  const out = await WorkLoopDriver.run({
    async runTurn(i) {
      const t = new WorkLoopTurnInfo();
      if (i === 0) {
        t.contextOverflow = true;
      } else {
        t.contentLength = 1;
      }
      return t;
    },
    onCompact() { compacts++; }
  });
  check('driver 压缩回调', compacts === 1 && out.compactSteps === 1 && out.textSteps === 1);
}

{
  const steps = [];
  const out = await WorkLoopDriver.run({
    async runTurn(i) {
      const t = new WorkLoopTurnInfo();
      if (i < 2) {
        t.toolCallsCount = 1;
      } else {
        t.contentLength = 1;
      }
      return t;
    },
    onStep(step, action, reason) { steps.push(action + ':' + reason); }
  }, new WorkLoopDriverConfig());
  check('driver onStep 钩子', steps.length === 3 && steps[0] === 'tool:tool_calls' &&
    steps[2] === 'finish:final_answer' && out.textSteps === 1);
}

{
  const cfg = new WorkLoopDriverConfig();
  cfg.maxSteps = 2;
  const out = await WorkLoopDriver.run({
    async runTurn() {
      const t = new WorkLoopTurnInfo();
      t.toolCallsCount = 1;
      return t;
    }
  }, cfg);
  check('driver maxStepsReached 标记', out.maxStepsReached === true &&
    out.finalReason === 'max_steps' && out.steps === 2 && out.isFinished() === false);
}

{
  const actions = [];
  const out = await WorkLoopDriver.run({
    async runTurn(i) {
      const t = new WorkLoopTurnInfo();
      if (i === 0) {
        t.contextOverflow = true;
      } else if (i === 1) {
        t.toolCallsCount = 1;
      } else {
        t.contentLength = 1;
      }
      return t;
    },
    onStep(s, a) { actions.push(a); }
  }, new WorkLoopDriverConfig());
  check('driver 完整序列 compact→tool→finish',
    actions.join(',') === 'compact,tool,finish' &&
    out.compactSteps === 1 && out.toolSteps === 1 && out.textSteps === 1);
}

// ===== LoopTurnInfoMapper =====
console.log('[LoopTurnInfoMapper]');

{
  const info = LoopTurnInfoMapper.map({
    'toolCallsCount': 2, 'contentLength': 128, 'finishReason': 'tool-calls',
    'aborted': false, 'contextOverflow': true, 'maxStepsReached': false
  });
  check('mapper 基础字段', info.toolCallsCount === 2 && info.contentLength === 128 &&
    info.finishReason === 'tool-calls' && info.contextOverflow === true);
  const aborted = LoopTurnInfoMapper.map({
    'aborted': true, 'toolCallsCount': 0, 'contentLength': 0, 'finishReason': ''
  });
  check('mapper 中止字段', aborted.aborted === true && aborted.maxStepsReached === false);
}

// ===== WorkLoopStepInfoBuilder =====
console.log('[WorkLoopStepInfoBuilder]');

{
  const aborted = WorkLoopStepInfoBuilder.aborted();
  check('builder 中止', aborted.aborted === true && aborted.toolCallsCount === 0);
  const fin = WorkLoopStepInfoBuilder.finish(12, 'max_tokens');
  check('builder 收尾', fin.toolCallsCount === 0 && fin.contentLength === 12 &&
    fin.finishReason === 'max_tokens' && fin.aborted === false);
  const tool = WorkLoopStepInfoBuilder.tool(3, 0, 'tool-calls');
  check('builder 工具步', tool.toolCallsCount === 3 && tool.finishReason === 'tool-calls');
}

// ===== PluginToolExecutor =====
console.log('[PluginToolExecutor]');

{
  PluginToolExecutor.clear();
  check('初始无插件处理器', PluginToolExecutor.has('my_tool') === false);
  PluginToolExecutor.register('my_tool', async (context, convId, name, argsJson, abortSignal) => {
    const r = new PluginToolResult();
    r.ok = true;
    r.output = 'hello:' + argsJson;
    return r;
  });
  check('注册后存在', PluginToolExecutor.has('my_tool') === true);
  const p = PluginToolExecutor.execute('my_tool', {}, 'conv', '{}', null);
  check('执行返回结果', p !== null);
  if (p !== null) {
    const r = await p;
    check('插件执行输出', r.ok === true && r.output === 'hello:{}');
  }
  PluginToolExecutor.unregister('my_tool');
  check('注销后不存在', PluginToolExecutor.has('my_tool') === false);
  check('未注册执行返回 null', PluginToolExecutor.execute('my_tool', {}, 'c', '{}', null) === null);
  PluginToolExecutor.clear();
}

// ===== LoopError =====
console.log('[LoopError]');

{
  const rate = new LoopError('rate', 429, 'rate_limit', 1200, '请稍后再试');
  check('默认按 kind 显式 retryable', rate.retryable === true && LoopError.isRetryable(rate) === true);
  check('userMessage 显式', rate.userMessage === '请稍后再试');
  check('retryAfterMs 保留', rate.retryAfterMs === 1200);
  const auth = new LoopError('auth', 401, 'auth');
  check('auth 默认不可重试', auth.retryable === false && LoopError.isRetryable(auth) === false);
  const forced = new LoopError('custom', 500, 'server', -1, '自定义', false);
  check('显式强制不可重试', forced.retryable === false && forced.userMessage === '自定义');
  const overflow = new LoopError('context length exceeded', 400, 'http');
  check('上下文溢出识别', overflow.isContextOverflow() === true);
  check('上下文默认提示', overflow.contextOverflowMessage().indexOf('上下文窗口超限') === 0);
}

console.log('');
console.log('passed=' + passed + ' failed=' + failed);
process.exit(failed === 0 ? 0 : 1);
