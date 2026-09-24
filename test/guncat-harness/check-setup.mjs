// 服务层类型检查环境: 把 Agent Loop 相关服务(含 Guncat Work 6.1 新增模块)移植为 .ts
// 并扁平化到 check/all/, @kit.* 用 stubs 模拟, 配合 tsc --noEmit 做类型级检查。
// 用法: node check-setup.mjs && npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json
import { mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, '..', '..', 'entry', 'src', 'main', 'ets');
const allDir = join(here, 'check', 'all');
const stubsDir = join(here, 'check', 'stubs');
rmSync(join(here, 'check'), { recursive: true, force: true });
mkdirSync(allDir, { recursive: true });
mkdirSync(stubsDir, { recursive: true });

function withTs(spec) {
  if (spec.endsWith('.ts') || spec.endsWith('.mjs') || spec.endsWith('.js')) {
    return spec;
  }
  return spec + '.ts';
}

// 扁平化: ../export|service|common|model/X 与 ./X → ./X.ts
function port(relSrc, relDst, replaces) {
  let text = readFileSync(join(srcDir, relSrc), 'utf8');
  for (const [from, to] of replaces) {
    text = text.split(from).join(to);
  }
  text = text.replace(/(from\s+['"])(\.\.?\/)(?:export\/|service\/|common\/|model\/)?([^'"]*)(['"])/g,
    (_m, a, _dot, path, b) => a + withTs('./' + path) + b);
  text = text.replace(/(from\s+['"])(\.[^'"]*)(['"])/g, (_m, a, spec, b) => a + withTs(spec) + b);
  writeFileSync(join(allDir, relDst), text);
  console.log('port', relSrc);
}

// ===== 纯逻辑与导出模块 =====
for (const [relSrc, relDst, replaces] of [
  ['common/Constants.ts', 'Constants.ts', []],
  ['common/Utils.ts', 'Utils.ts', []],
  ['common/CsvParser.ts', 'CsvParser.ts', []],
  ['common/DataPipeline.ts', 'DataPipeline.ts', []],
  ['common/PathMatcher.ts', 'PathMatcher.ts', []],
  ['common/DiffUtil.ts', 'DiffUtil.ts', []],
  ['common/EditCore.ts', 'EditCore.ts', []],
  ['common/FileSearchCore.ts', 'FileSearchCore.ts', []],
  ['common/ToolExecutionGuard.ts', 'ToolExecutionGuard.ts', []],
  ['common/ToolSchemaValidator.ts', 'ToolSchemaValidator.ts', []],
  ['common/ToolRegistry.ts', 'ToolRegistry.ts', []],
  ['common/PromptBuilder.ts', 'PromptBuilder.ts', []],
  ['common/LoopMetrics.ts', 'LoopMetrics.ts', []],
  ['common/ToolScheduler.ts', 'ToolScheduler.ts', []],
  ['common/SessionLogAggregator.ts', 'SessionLogAggregator.ts', []],
  ['common/PromptBudget.ts', 'PromptBudget.ts', []],
  ['common/FaultInjector.ts', 'FaultInjector.ts', []],
  ['common/LLMProtocol.ts', 'LLMProtocol.ts', []],
  ['common/RepeatDetector.ts', 'RepeatDetector.ts', []],
  ['common/LoopDecisions.ts', 'LoopDecisions.ts', []],
  ['common/ToolDefAdapter.ts', 'ToolDefAdapter.ts', []],
  ['common/SSEProtocolAdapter.ts', 'SSEProtocolAdapter.ts', []],
  ['common/WorkLoopStateMachine.ts', 'WorkLoopStateMachine.ts', []],
  ['common/WorkLoopPlanner.ts', 'WorkLoopPlanner.ts', []],
  ['common/PluginManifestLoader.ts', 'PluginManifestLoader.ts', []],
  ['common/SkillDirectoryFormatter.ts', 'SkillDirectoryFormatter.ts', []],
  ['common/RetryPolicy.ts', 'RetryPolicy.ts', []],
  ['common/ToolRetryPolicy.ts', 'ToolRetryPolicy.ts', []],
  ['common/WorkLoopSimulator.ts', 'WorkLoopSimulator.ts', []],
  ['common/RetryAfterParser.ts', 'RetryAfterParser.ts', []],
  ['common/WorkLoopDriver.ts', 'WorkLoopDriver.ts', []],
  ['common/PluginToolExecutor.ts', 'PluginToolExecutor.ts', []],
  ['common/LoopError.ts', 'LoopError.ts', []],
  ['common/SubagentIsolation.ts', 'SubagentIsolation.ts', []],
  ['common/LoopTurnInfoMapper.ts', 'LoopTurnInfoMapper.ts', []],
  ['common/WorkLoopStepInfoBuilder.ts', 'WorkLoopStepInfoBuilder.ts', []],
  ['common/Types.ts', 'Types.ts', []],
  ['common/MarkdownSanitizer.ts', 'MarkdownSanitizer.ts', []],
  ['export/ZipWriter.ets', 'ZipWriter.ts', [["from '@kit.ArkTS'", "from './arkts-shim'"]]],
  ['export/ZipWriterTs.ts', 'ZipWriterTs.ts', []],
  ['export/MarkdownParser.ets', 'MarkdownParser.ts', []],
  ['export/OmmlConverter.ets', 'OmmlConverter.ts', []],
  ['export/DocModel.ets', 'DocModel.ts', []],
  ['export/DocxBuilder.ets', 'DocxBuilder.ts', []],
  ['export/DocxImporter.ets', 'DocxImporter.ts', []],
  ['export/XlsxModel.ets', 'XlsxModel.ts', []],
  ['export/XlsxBuilder.ets', 'XlsxBuilder.ts', []],
  ['export/XlsxImporter.ets', 'XlsxImporter.ts', []],
  ['export/XmlUtil.ets', 'XmlUtil.ts', []],
  ['export/CsvWriter.ts', 'CsvWriter.ts', []],
  ['export/SvgUtil.ts', 'SvgUtil.ts', []],
  ['export/DeckModel.ets', 'DeckModel.ts', []],
  ['export/PptxThemes.ets', 'PptxThemes.ts', []],
  ['export/PptxCharts.ets', 'PptxCharts.ts', []],
  ['export/PptxBuilder.ets', 'PptxBuilder.ts', [["from '../common/Constants'", "from './Constants'"]]],
  ['export/PptxImage.ets', 'PptxImage.ts', []],
  ['export/PptxImporter.ets', 'PptxImporter.ts', []],
]) {
  port(relSrc, relDst, replaces);
}

// ===== 数据模型 =====
for (const [relSrc, relDst, replaces] of [
  ['model/ApiConfig.ts', 'ApiConfig.ts', []],
  ['model/MultimodalConfig.ts', 'MultimodalConfig.ts', []],
  ['model/ApiProfile.ts', 'ApiProfile.ts', []],
  ['model/Attachment.ts', 'Attachment.ts', []],
  ['model/Agent.ts', 'Agent.ts', []],
  ['model/Message.ts', 'Message.ts', [['@Observed', '']]],
  ['model/ToolCallRecord.ts', 'ToolCallRecord.ts', []],
]) {
  port(relSrc, relDst, replaces);
}

// ===== 服务层(含 6.1 新增) =====
for (const [relSrc, relDst, replaces] of [
  ['service/ChatService.ts', 'ChatService.ts', []],
  ['service/SSEAdapterFactory.ts', 'SSEAdapterFactory.ts', []],
  ['service/AgentLoopService.ts', 'AgentLoopService.ts', []],
  ['service/WorkLoopDriverBridge.ts', 'WorkLoopDriverBridge.ts', []],
  ['service/WorkFileService.ts', 'WorkFileService.ts', []],
  ['service/HarnessTools.ts', 'HarnessTools.ts', []],
  ['service/AskUserBridge.ts', 'AskUserBridge.ts', []],
  ['service/SpillStore.ts', 'SpillStore.ts', []],
  ['service/ScheduleService.ts', 'ScheduleService.ts', []],
  ['service/GoalService.ts', 'GoalService.ts', []],
  ['service/WebFetchService.ts', 'WebFetchService.ts', []],
  ['service/SessionLogService.ts', 'SessionLogService.ts', []],
  ['service/SubagentService.ts', 'SubagentService.ts', []],
  ['service/WorkSkillService.ts', 'WorkSkillService.ts', []],
  ['service/PluginHotLoader.ts', 'PluginHotLoader.ts', []],
  ['service/ToolCallStream.ts', 'ToolCallStream.ts', []],
  ['service/LocalWebSearch.ts', 'LocalWebSearch.ts', []],
  ['service/JsCodeService.ts', 'JsCodeService.ts', [["from 'libguncatjs.so'", "from './jsvm-shim'"]]],
  ['service/WorkToolRunner.ets', 'WorkToolRunner.ts', []],
]) {
  port(relSrc, relDst, replaces);
}

// ===== 本地依赖桩 =====
writeFileSync(join(allDir, 'arkts-shim.ts'),
  `declare const Buffer: { from(s: string): Uint8Array };\n` +
  `export declare namespace util {\n  class TextEncoder { encode(input: string): Uint8Array; }\n}\n`);
writeFileSync(join(allDir, 'FileService.ts'),
  `export class PickedFile {\n  name: string = '';\n  buffer: ArrayBuffer = new ArrayBuffer(0);\n}\n`);
writeFileSync(join(allDir, 'OfficeReader.ts'),
  `export class OfficeReader {\n  static async extractAll(absPath: string, tempRoot: string): Promise<string> {\n    return '';\n  }\n}\n`);
writeFileSync(join(allDir, 'DocxExporter.ts'),
  `export class DocxExporter {\n  static async buildDocxBytes(title: string, markdown: string): Promise<Uint8Array> {\n    return new Uint8Array(0);\n  }\n  static async exportToDocx(context: object, markdown: string, title: string): Promise<string> {\n    return '';\n  }\n}\n`);
writeFileSync(join(allDir, 'XlsxExporter.ts'),
  `export class XlsxExporter {\n  static buildXlsxFromRows(rows: string[][]): Uint8Array {\n    return new Uint8Array(0);\n  }\n}\n`);
writeFileSync(join(allDir, 'PdfTextExtractor.ts'),
  `export class PdfPagesResult { pageCount: number = 0; startPage: number = 1; endPage: number = 1; nextStartPage: number = 0; pages: string[] = []; }\n` +
  `export class PdfSearchHit { pageIndex: number = 0; context: string = ''; }\n` +
  `export class PdfRenderResult { pageCount: number = 0; startPage: number = 1; endPage: number = 1; nextStartPage: number = 0; files: string[] = []; }\n` +
  `export class PdfTextExtractor {\n` +
  `  static async extractPages(abs: string, page: number, limit: number, cap: number): Promise<PdfPagesResult> { return new PdfPagesResult(); }\n` +
  `  static async searchText(abs: string, query: string, max: number): Promise<PdfSearchHit[]> { return []; }\n` +
  `  static async renderPages(abs: string, page: number, limit: number, outDir: string): Promise<PdfRenderResult> { return new PdfRenderResult(); }\n` +
  `  static async extractText(abs: string, cap: number): Promise<string> { return ''; }\n}\n`);
// run_js 的原生模块(libguncatjs.so)在 Node 侧无实现, 仅提供类型等价桩
writeFileSync(join(allDir, 'jsvm-shim.ts'),
  `export interface JsRunOptions {\n` +
  `  inputs?: Record<string, string>;\n  resourceName?: string;\n  heapMb?: number;\n` +
  `  stdoutLimitKb?: number;\n  outputFileLimitKb?: number;\n  outputTotalLimitKb?: number;\n` +
  `  maxOutputFiles?: number;\n}\n` +
  `export interface JsRunResult {\n` +
  `  ok: boolean;\n  hasResult: boolean;\n  stdout: string;\n  result: string;\n  error: string;\n` +
  `  notice: string;\n  durationMs: number;\n  inputCount: number;\n  inputKeys: string[];\n  outputs: Record<string, string>;\n}\n` +
  `export function runJs(code: string, options?: JsRunOptions): Promise<JsRunResult> {\n` +
  `  return Promise.reject(new Error('jsvm-shim: 原生模块仅在设备侧可用'));\n}\n` +
  `export function engineStatus(): string { return 'jsvm-shim'; }\n`);

// ===== @kit 桩 =====
writeFileSync(join(stubsDir, '@kit.CoreFileKit.ts'),
  `export declare namespace fileIo {\n` +
  `  interface Stat { size: number; mtime: number; isDirectory(): boolean; }\n` +
  `  interface File { fd: number; }\n` +
  `  enum OpenMode { READ_ONLY = 0, READ_WRITE = 1, CREATE = 2, TRUNC = 4, APPEND = 8 }\n` +
  `  function accessSync(path: string): boolean;\n  function statSync(path: string): Stat;\n` +
  `  function mkdirSync(path: string, recursion?: boolean): void;\n  function listFileSync(path: string): string[];\n` +
  `  function openSync(path: string, mode: number): File;\n` +
  `  function readSync(fd: number, buffer: ArrayBuffer, opts: { offset: number }): number;\n` +
  `  function writeSync(fd: number, buffer: ArrayBuffer): number;\n` +
  `  function writeSync(fd: number, buffer: ArrayBuffer, opts: { offset: number; length?: number }): number;\n` +
  `  function closeSync(fileOrFd: File | number): void;\n` +
`  function unlinkSync(path: string): void;  function rmdirSync(path: string): void;\n` +
`  function renameSync(oldPath: string, newPath: string): void;\n` +
`  function moveFileSync(src: string, dst: string): void;  function moveDirSync(src: string, dst: string): void;\n}\n` +
  `export declare namespace picker {\n` +
  `  class DocumentSaveOptions { newFileNames?: string[]; fileSuffixChoices?: string[]; }\n` +
  `  class DocumentViewPicker { constructor(context: object); save(options: DocumentSaveOptions): Promise<string[]>; }\n}\n`);
writeFileSync(join(stubsDir, '@kit.AbilityKit.ts'),
  `export declare namespace common {\n` +
  `  interface ResourceManager { getRawFileContent(path: string): Promise<Uint8Array>; }\n` +
  `  class UIAbilityContext { filesDir: string; cacheDir: string; resourceManager: ResourceManager; }\n}\n`);
writeFileSync(join(stubsDir, '@kit.ArkTS.ts'),
  `export declare namespace util {\n` +
  `  class TextEncoder { encode(input: string): Uint8Array; }\n` +
  `  class TextDecoder {\n    static create(encoding: string, opts?: { ignoreBOM?: boolean }): TextDecoder;\n` +
  `    decodeToString(input: Uint8Array, opts?: { stream: boolean }): string;\n  }\n` +
  `  class Base64Helper { decodeSync(src: string): Uint8Array; }\n}\n`);
writeFileSync(join(stubsDir, '@kit.PerformanceAnalysisKit.ts'),
  `export declare const hilog: { error(domain: number, tag: string, msg: string, ...args: any[]): void;\n` +
  `  info(domain: number, tag: string, msg: string, ...args: any[]): void; };\n`);
writeFileSync(join(stubsDir, '@kit.BasicServicesKit.ts'),
  `export declare namespace zlib {\n  function decompressFile(src: string, dest: string): Promise<void>;\n}\n` +
  `export declare namespace pasteboard {\n  function getSystemPasteboard(): { setData(content: object): Promise<void>; };\n` +
  `  function createData(mime: string): { addTextRecord(text: string): void; };\n  function createPlainTextData(text: string): object;\n}\n`);
writeFileSync(join(stubsDir, '@kit.NetworkKit.ts'),
  `export declare namespace http {\n` +
  `  enum RequestMethod { GET = 'GET', POST = 'POST' }\n` +
  `  enum HttpDataType { STRING = 0, ARRAY_BUFFER = 1 }\n` +
  `  enum HttpProtocol { HTTP1_1 = 0, HTTP2 = 1 }\n` +
  `  interface HttpResponse { responseCode: number; result: Object; header: Object; }\n` +
  `  interface HttpRequestOptions {\n` +
  `    method?: RequestMethod;\n    header?: Record<string, string>;\n    extraData?: string;\n` +
  `    connectTimeout?: number;\n    readTimeout?: number;\n    usingProtocol?: HttpProtocol;\n  }\n` +
  `  interface HttpRequest {\n` +
  `    request(url: string, options: object): Promise<HttpResponse>;\n` +
  `    requestInStream(url: string, options: object): Promise<number>;\n` +
  `    destroy(): void;\n` +
  `    on(type: string, cb: (data: object) => void): void;\n` +
  `    off(type: string): void;\n  }\n` +
  `  function createHttp(): HttpRequest;\n}\n`);
writeFileSync(join(stubsDir, '@kit.ImageKit.ts'),
  `export declare namespace image {\n` +
  `  interface Size { width: number; height: number; }\n` +
  `  interface DecodingOptions { desiredSize?: Size; }\n` +
  `  interface PackingOption { format: string; quality: number; }\n` +
  `  class PixelMap { release(): Promise<void>; }\n` +
  `  class ImageSource { createPixelMap(opts?: DecodingOptions): Promise<PixelMap>; release(): Promise<void>; }\n` +
  `  class ImagePacker { packToData(pixelMap: PixelMap, opts: PackingOption): Promise<ArrayBuffer>; release(): Promise<void>; }\n` +
  `  function createImageSource(fd: number): ImageSource;\n` +
  `  function createImagePacker(): ImagePacker;\n}\n`);

// ===== tsconfig =====
writeFileSync(join(here, 'check', 'tsconfig.json'), JSON.stringify({
  compilerOptions: {
    target: 'ES2021',
    module: 'ESNext',
    moduleResolution: 'node',
    baseUrl: '.',
    paths: { '@kit.*': ['./stubs/@kit.*.ts'] },
    allowImportingTsExtensions: true,
    noEmit: true,
    skipLibCheck: true,
    strict: false,
    noImplicitAny: false,
    types: []
  },
  include: ['all/**/*.ts']
}, null, 2));
console.log('done');
