// PPTX 生成器验证环境: 把纯逻辑 ArkTS 模块(export/*)移植为 Node 可运行的 .ts
// - PptxBuilder/DeckModel/PptxThemes/PptxCharts/XmlUtil 不依赖任何 HarmonyOS API, 直接复制;
// - ZipWriter 仅依赖 @kit.ArkTS 的 TextEncoder, 换成 arkts-shim 桩;
// - Constants 纯 TS, 直接复制。
// 用法: node setup.mjs && node test-build.mjs && python validate.py
import { rmSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, '..', '..', 'entry', 'src', 'main', 'ets');
const genDir = join(here, 'gen');
rmSync(genDir, { recursive: true, force: true });
mkdirSync(genDir, { recursive: true });

// 给无扩展名的相对 import 补 .ts(Node ESM 要求显式扩展名)
function withTs(spec) {
  if (spec.endsWith('.ts') || spec.endsWith('.mjs') || spec.endsWith('.js')) {
    return spec;
  }
  return spec + '.ts';
}

function port(relSrc, relDst, replaces) {
  let text = readFileSync(join(srcDir, relSrc), 'utf8');
  for (const [from, to] of replaces) {
    text = text.split(from).join(to);
  }
  text = text.replace(/(from\s+['"])(\.[^'"]*)(['"])/g, (_m, a, spec, b) => a + withTs(spec) + b);
  writeFileSync(join(genDir, relDst), text);
  console.log('port', relSrc, '->', relDst);
}

port('export/DeckModel.ets', 'DeckModel.ts', []);
port('export/PptxThemes.ets', 'PptxThemes.ts', []);
port('export/PptxCharts.ets', 'PptxCharts.ts', []);
// Word 管线(供 check-setup 类型检查 WorkToolRunner 使用)
port('export/DocModel.ets', 'DocModel.ts', [
  ["from '../common/Constants'", "from './Constants'"]
]);
port('export/DocxBuilder.ets', 'DocxBuilder.ts', [
  ["from '../common/Constants'", "from './Constants'"]
]);
port('export/MarkdownParser.ets', 'MarkdownParser.ts', []);
port('export/OmmlConverter.ets', 'OmmlConverter.ts', []);
// Excel 管线(供 check-setup 类型检查 WorkToolRunner 使用)
port('export/XlsxModel.ets', 'XlsxModel.ts', [
  ["from '../common/Constants'", "from './Constants'"],
  ["from '../common/CsvParser'", "from './CsvParser'"]
]);
port('export/XlsxBuilder.ets', 'XlsxBuilder.ts', [
  ["from '../common/Constants'", "from './Constants'"]
]);
port('export/XlsxImporter.ets', 'XlsxImporter.ts', [
  ["from '../common/Constants'", "from './Constants'"]
]);
port('export/CsvWriter.ts', 'CsvWriter.ts', [
  ["from '@kit.ArkTS'", "from './arkts-shim'"]
]);
port('common/CsvParser.ts', 'CsvParser.ts', []);
port('common/DataPipeline.ts', 'DataPipeline.ts', []);
port('export/SvgUtil.ts', 'SvgUtil.ts', []);
port('export/PptxBuilder.ets', 'PptxBuilder.ts', [
  ["from '../common/Constants'", "from './Constants'"]
]);
port('export/XmlUtil.ets', 'XmlUtil.ts', []);
port('export/ZipWriter.ets', 'ZipWriter.ts', [
  ["from '@kit.ArkTS'", "from './arkts-shim'"]
]);
port('common/Constants.ts', 'Constants.ts', []);
port('export/DocxImporter.ets', 'DocxImporter.ts', [
  ["from '../common/Constants'", "from './Constants'"]
]);
// shim 同样放入 gen/, 供 gen/ZipWriter.ts 引用
writeFileSync(join(genDir, 'arkts-shim.ts'), readFileSync(join(here, 'arkts-shim.ts')));
console.log('done');
