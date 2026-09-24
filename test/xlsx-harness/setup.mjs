// XLSX 生成器/导入器验证环境: 把纯逻辑 ArkTS 模块(export/*)移植为 Node 可运行的 .ts
// - XlsxModel/XlsxBuilder/XmlUtil/Constants/CsvParser 不依赖 HarmonyOS API, 直接复制;
// - ZipWriter 仅依赖 @kit.ArkTS 的 TextEncoder, 换成 arkts-shim 桩;
// - XlsxImporter 依赖 @kit 的 fileIo/zlib, 分别换成 kit-shim(fileIo+TextDecoder) 与 harness-unzip(zip 解包)。
// 用法: node setup.mjs && node test-build.mjs && python validate.py && python deep-check.py
import { rmSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, '..', '..', 'entry', 'src', 'main', 'ets');
const genDir = join(here, 'gen');
rmSync(genDir, { recursive: true, force: true });
mkdirSync(genDir, { recursive: true });

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

port('export/XlsxModel.ets', 'XlsxModel.ts', [
  ["from '../common/Constants'", "from './Constants'"],
  ["from '../common/CsvParser'", "from './CsvParser'"]
]);
port('export/XlsxBuilder.ets', 'XlsxBuilder.ts', [
  ["from '../common/Constants'", "from './Constants'"],
  ["from '@kit.ArkTS'", "from './arkts-shim'"]
]);
port('common/CsvParser.ts', 'CsvParser.ts', []);
port('export/XmlUtil.ets', 'XmlUtil.ts', []);
port('export/ZipWriter.ets', 'ZipWriter.ts', [
  ["from '@kit.ArkTS'", "from './arkts-shim'"]
]);
port('common/Constants.ts', 'Constants.ts', []);
port('export/XlsxImporter.ets', 'XlsxImporter.ts', [
  ["from '../common/Constants'", "from './Constants'"],
  ["import { fileIo } from '@kit.CoreFileKit';", "import { fileIo, util } from './kit-shim';"],
  ["import { zlib } from '@kit.BasicServicesKit';", ""],
  ["import { util } from '@kit.ArkTS';", ""],
  ["await zlib.decompressFile(absPath, tempDir);", "await harnessUnzip(absPath, tempDir);"],
  ["import { XlsxWorkbook, XlsxSheet, XlsxParser } from './XlsxModel';",
    "import { harnessUnzip } from './harness-unzip';\nimport { XlsxWorkbook, XlsxSheet, XlsxParser } from './XlsxModel';"]
]);
writeFileSync(join(genDir, 'arkts-shim.ts'), readFileSync(join(here, 'arkts-shim.ts')));
writeFileSync(join(genDir, 'kit-shim.ts'), readFileSync(join(here, 'kit-shim.ts')));
writeFileSync(join(genDir, 'harness-unzip.ts'), readFileSync(join(here, 'harness-unzip.ts')));
console.log('done');
