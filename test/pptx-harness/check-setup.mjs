// 服务层类型检查环境: 把 WorkFileService/WorkSkillService/WorkToolRunner/PptxImage/PptxImporter
// 移植为 .ts 并扁平化到 check/all/, @kit.* 用 stubs 模拟, 配合 tsc --noEmit 做类型级检查。
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

// 扁平化: ../export/X / ../service/X / ../common/X / ./X → ./X.ts
function port(relSrc, relDst, replaces) {
  let text = readFileSync(join(srcDir, relSrc), 'utf8');
  for (const [from, to] of replaces) {
    text = text.split(from).join(to);
  }
  text = text.replace(/(from\s+['"])(\.\.?\/)(?:export\/|service\/|common\/)?([^'"]*)(['"])/g,
    (_m, a, _dot, path, b) => a + './' + path + b ? a + withTs('./' + path) + b : a + b);
  text = text.replace(/(from\s+['"])(\.[^'"]*)(['"])/g, (_m, a, spec, b) => a + withTs(spec) + b);
  writeFileSync(join(allDir, relDst), text);
  console.log('port', relSrc);
}

// ===== 从 gen/ 复用已移植的纯模块 =====
for (const f of ['DeckModel.ts', 'PptxThemes.ts', 'PptxCharts.ts', 'PptxBuilder.ts', 'XmlUtil.ts',
  'ZipWriter.ts', 'Constants.ts', 'CsvWriter.ts', 'SvgUtil.ts', 'CsvParser.ts', 'DataPipeline.ts',
  'DocModel.ts', 'DocxBuilder.ts', 'MarkdownParser.ts', 'OmmlConverter.ts', 'DocxImporter.ts',
  'XlsxModel.ts', 'XlsxBuilder.ts', 'XlsxImporter.ts',
  'arkts-shim.ts']) {
  writeFileSync(join(allDir, f), readFileSync(join(here, 'gen', f)));
}

// ===== 服务层 =====
port('service/WorkFileService.ts', 'WorkFileService.ts', []);
port('service/WorkSkillService.ts', 'WorkSkillService.ts', []);
port('service/WorkToolRunner.ets', 'WorkToolRunner.ts', []);
port('export/PptxImage.ets', 'PptxImage.ts', []);
port('export/PptxImporter.ets', 'PptxImporter.ts', []);
port('common/Utils.ts', 'Utils.ts', []);
// WorkFileService 的既有依赖(补全类型检查覆盖)
port('export/ZipWriterTs.ts', 'ZipWriterTs.ts', [
  ["from '@kit.ArkTS'", "from './arkts-shim'"]
]);
port('service/HarnessTools.ts', 'HarnessTools.ts', []);
port('service/LocalWebSearch.ts', 'LocalWebSearch.ts', []);
port('service/AskUserBridge.ts', 'AskUserBridge.ts', []);
port('service/ScheduleService.ts', 'ScheduleService.ts', []);
port('service/GoalService.ts', 'GoalService.ts', []);
port('service/WebFetchService.ts', 'WebFetchService.ts', []);
port('service/SessionLogService.ts', 'SessionLogService.ts', []);
port('common/PathMatcher.ts', 'PathMatcher.ts', []);
port('common/FileSearchCore.ts', 'FileSearchCore.ts', []);
port('common/DiffUtil.ts', 'DiffUtil.ts', []);
port('common/EditCore.ts', 'EditCore.ts', []);
port('common/Types.ts', 'Types.ts', []);
mkdirSync(join(allDir, 'model'), { recursive: true });
port('model/ToolCallRecord.ts', 'model/ToolCallRecord.ts', []);

// check 专用 shim: namespace 形式(仅类型检查, 不参与 Node 运行时)
writeFileSync(join(allDir, 'arkts-shim.ts'),
  `declare const Buffer: { from(s: string): Uint8Array };\n` +
  `export declare namespace util {\n  class TextEncoder { encode(input: string): Uint8Array; }\n}\n` +
  `export const util2 = 0;\n`);

// ===== 本地依赖桩(仅声明被用到的 API) =====
writeFileSync(join(allDir, 'FileService.ts'),
  `export class PickedFile {\n  name: string = '';\n  buffer: ArrayBuffer = new ArrayBuffer(0);\n}\n`);
writeFileSync(join(allDir, 'OfficeReader.ts'),
  `export class OfficeReader {\n  static async extractAll(absPath: string, tempRoot: string): Promise<string> {\n    return '';\n  }\n}\n`);
writeFileSync(join(allDir, 'DocxExporter.ts'),
  `export class DocxExporter {\n  static async buildDocxBytes(title: string, markdown: string): Promise<Uint8Array> {\n    return new Uint8Array(0);\n  }\n}\n`);
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
  `  function closeSync(fileOrFd: File | number): void;\n` +
  `  function unlinkSync(path: string): void;  function rmdirSync(path: string): void;\n` +
  `  function moveFileSync(src: string, dst: string): void;  function moveDirSync(src: string, dst: string): void;\n` +
  `  function renameSync(oldPath: string, newPath: string): void;\n}\n` +
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
  `export declare namespace zlib {\n  function decompressFile(src: string, dest: string): Promise<void>;\n}\n`);
writeFileSync(join(stubsDir, '@kit.NetworkKit.ts'),
  `export declare namespace http {\n` +
  `  enum RequestMethod { GET = 'GET', POST = 'POST' }\n` +
  `  enum HttpDataType { STRING = 0, ARRAY_BUFFER = 1 }\n` +
  `  enum HttpProtocol { HTTP1_1 = 'HTTP/1.1', HTTP2 = 'HTTP/2', HTTP3 = 'HTTP/3', NONE = 'NONE' }\n` +
  `  interface HttpRequestOptions { method?: string; header?: object | string; extraData?: object | string;\n` +
  `    expectDataType?: number; usingCache?: boolean; usingProtocol?: HttpProtocol;\n` +
  `    connectTimeout?: number; readTimeout?: number; }\n` +
  `  interface HttpResponse { responseCode: number; result: Object; header: Object; }\n` +
  `  interface HttpRequest { request(url: string, options: HttpRequestOptions): Promise<HttpResponse>; destroy(): void; }\n` +
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
