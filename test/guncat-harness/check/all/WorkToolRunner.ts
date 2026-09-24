// WorkToolRunner: 工作模式工具统一分发入口
// 文件类工具委托 WorkFileService(ts); Office 生成需要 .ets 模块
// (OoxmlBuilder/XlsxExporter/PptxBuilder/PptxImporter), 在此实现。全部工具均为本地实现, 无多模态依赖。
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { WorkFileService, ToolExecResult } from './WorkFileService.ts';
import { PdfTextExtractor, PdfPagesResult, PdfSearchHit, PdfRenderResult } from './PdfTextExtractor.ts';
import { DocxBuilder, DocxImagePart, DocImageResolver } from './DocxBuilder.ts';
import { DocxImporter, DocxImportResult } from './DocxImporter.ts';
import { Doc, DocParser, DocOps, MdToDoc } from './DocModel.ts';
import { XlsxExporter } from './XlsxExporter.ts';
import { XlsxBuilder } from './XlsxBuilder.ts';
import { XlsxImporter, XlsxImportResult } from './XlsxImporter.ts';
import { XlsxWorkbook, XlsxParser, XlsxOps, MdToXlsx } from './XlsxModel.ts';
import { CsvWriter } from './CsvWriter.ts';
import { CsvParser } from './CsvParser.ts';
import { DataPipeline, DpTable, DpOutcome } from './DataPipeline.ts';
import { PptxBuilder, ImageResolver, PptxImagePart } from './PptxBuilder.ts';
import { PptxImage } from './PptxImage.ts';
import { PptxImporter, PptxImportResult } from './PptxImporter.ts';
import { Deck, DeckParser, DeckOutline, DeckOps } from './DeckModel.ts';
import { SvgUtil } from './SvgUtil.ts';
import { XmlUtil } from './XmlUtil.ts';
import { Constants } from './Constants.ts';
import { ToolExecutionGuard } from './ToolExecutionGuard.ts';
import { ToolSchemaValidator } from './ToolSchemaValidator.ts';
import { ToolRetryPolicy } from './ToolRetryPolicy.ts';
import { ToolRegistry } from './ToolRegistry.ts';
import { PluginToolExecutor, PluginToolResult } from './PluginToolExecutor.ts';
import { AbortSignal } from './Types.ts';

export class WorkToolRunner {
  // 工具内 HTTP 请求注册表: 供 stopStreaming 深度取消(destroy 底层请求, 而不是只放弃等待)
  private static toolRequests: http.HttpRequest[] = [];
  // 统一工具入口: 先套超时/取消护栏, 再进入真正的分发实现; 网络类工具对瞬时失败少量重试。
  // 插件工具走声明式 PluginToolExecutor; 未注册实现的插件工具返回“插件未实现”。
  // abortSignal 为可选参数(主循环/子代理传入), 未传时只做超时保护。
  static async execute(context: common.UIAbilityContext, convId: string,
    name: string, argsJson: string,
    abortSignal: AbortSignal | null = null): Promise<ToolExecResult> {
    if (abortSignal !== null && abortSignal.aborted) {
      return WorkToolRunner.abortedResult(name);
    }
    WorkFileService.toolRegistrySynced();
    let meta = ToolRegistry.findMeta(name);
    let isPluginTool: boolean = meta !== null && meta.namespace !== 'core';
    if (isPluginTool && !PluginToolExecutor.has(name)) {
      return WorkToolRunner.pluginNotImplementedResult(name);
    }
    let timeoutMs: number = meta !== null && meta.timeoutMs > 0 ?
      meta.timeoutMs : Constants.WORK_TOOL_TIMEOUT_MS;
    let policy: ToolRetryPolicy = new ToolRetryPolicy();
    if (meta !== null && meta.maxRetries >= 0) {
      policy.setMaxRetries(name, meta.maxRetries);
    }
    let attempt: number = 0;
    while (true) {
      let result: ToolExecResult = await ToolExecutionGuard.run(
        WorkToolRunner.buildTask(context, convId, name, argsJson, abortSignal),
        timeoutMs,
        abortSignal,
        (): ToolExecResult => WorkToolRunner.timeoutResult(name),
        (): ToolExecResult => WorkToolRunner.abortedResult(name));
      let d = policy.decide(name, attempt, result.timeout, !result.ok,
        result.cancelled, result.schemaError);
      if (!d.shouldRetry) {
        return result;
      }
      attempt++;
      await WorkToolRunner.sleep(d.delayMs);
      if (abortSignal !== null && abortSignal.aborted) {
        return WorkToolRunner.abortedResult(name);
      }
    }
  }

  // 插件工具 → 声明式 handler; 其余走内部分发实现
  private static async buildTask(context: common.UIAbilityContext, convId: string,
    name: string, argsJson: string, abortSignal: AbortSignal | null): Promise<ToolExecResult> {
    if (PluginToolExecutor.has(name)) {
      return WorkToolRunner.runPluginHandler(context, convId, name, argsJson, abortSignal);
    }
    return await WorkToolRunner.executeInner(context, convId, name, argsJson, abortSignal);
  }

  private static async runPluginHandler(context: common.UIAbilityContext, convId: string,
    name: string, argsJson: string, abortSignal: AbortSignal | null): Promise<ToolExecResult> {
    // 插件 handler 同样先做结构化参数校验(与核心工具一致)
    let def: Record<string, Object> | null = WorkFileService.findToolDef(name);
    if (def !== null) {
      let parsed: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
      if (parsed === null) {
        return WorkToolRunner.argError();
      }
      let schemaErr: string = ToolSchemaValidator.validate(def, parsed);
      if (schemaErr !== '') {
        return WorkToolRunner.schemaFailMsg(schemaErr);
      }
    }
    let pr: PluginToolResult | null = await PluginToolExecutor.execute(name, context,
      convId, argsJson, abortSignal);
    if (pr === null) {
      return WorkToolRunner.pluginNotImplementedResult(name);
    }
    return WorkToolRunner.toToolResult(pr);
  }

  private static toToolResult(pr: PluginToolResult): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = pr.ok;
    r.output = pr.output;
    r.imageDataUrl = pr.imageDataUrl;
    r.meta = pr.meta;
    r.timeout = pr.timeout;
    r.cancelled = pr.cancelled;
    r.schemaError = pr.schemaError;
    return r;
  }

  private static pluginNotImplementedResult(name: string): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = false;
    r.output = '插件工具未实现: ' + name;
    return r;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  // 深度取消: 销毁所有由本执行器发起的工具内 HTTP 请求(下载/抓取等)
  static abortToolRequests(): void {
    for (let i: number = 0; i < WorkToolRunner.toolRequests.length; i++) {
      try {
        WorkToolRunner.toolRequests[i].destroy();
      } catch (e) {
        // 已销毁/已结束的请求忽略
      }
    }
    WorkToolRunner.toolRequests = [];
  }

  private static registerToolRequest(req: http.HttpRequest): void {
    WorkToolRunner.toolRequests.push(req);
  }

  private static unregisterToolRequest(req: http.HttpRequest): void {
    let idx: number = WorkToolRunner.toolRequests.indexOf(req);
    if (idx >= 0) {
      WorkToolRunner.toolRequests.splice(idx, 1);
    }
  }

  private static async executeInner(context: common.UIAbilityContext, convId: string,
    name: string, argsJson: string,
    abortSignal: AbortSignal | null): Promise<ToolExecResult> {
    // 结构化参数校验: 按工具定义的 JSON Schema 校验 required 与宽容类型;
    // 未知工具无定义则跳过, 交给分发层给出"未知工具"错误
    let def: Record<string, Object> | null = WorkFileService.findToolDef(name);
    if (def !== null) {
      let parsed: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
      if (parsed === null) {
        return WorkToolRunner.argError();
      }
      let schemaErr: string = ToolSchemaValidator.validate(def, parsed);
      if (schemaErr !== '') {
        return WorkToolRunner.schemaFailMsg(schemaErr);
      }
    }
    if (name === 'write_docx') {
      return await WorkToolRunner.toolWriteDocx(context, convId, argsJson);
    }
    if (name === 'read_docx') {
      return await WorkToolRunner.toolReadDocx(context, convId, argsJson);
    }
    if (name === 'edit_docx') {
      return await WorkToolRunner.toolEditDocx(context, convId, argsJson);
    }
    if (name === 'write_xlsx') {
      return await WorkToolRunner.toolWriteXlsx(context, convId, argsJson);
    }
    if (name === 'read_xlsx') {
      return await WorkToolRunner.toolReadXlsx(context, convId, argsJson);
    }
    if (name === 'edit_xlsx') {
      return await WorkToolRunner.toolEditXlsx(context, convId, argsJson);
    }
    if (name === 'write_csv') {
      return await WorkToolRunner.toolWriteCsv(context, convId, argsJson);
    }
    if (name === 'write_pptx') {
      return await WorkToolRunner.toolWritePptx(context, convId, argsJson);
    }
    if (name === 'read_ppt') {
      return await WorkToolRunner.toolReadPpt(context, convId, argsJson);
    }
    if (name === 'edit_ppt') {
      return await WorkToolRunner.toolEditPpt(context, convId, argsJson);
    }
    if (name === 'write_svg') {
      return await WorkToolRunner.toolWriteSvg(context, convId, argsJson);
    }
    if (name === 'download_file') {
      return await WorkToolRunner.toolDownloadFile(context, convId, argsJson);
    }
    if (name === 'parse_document') {
      return await WorkToolRunner.toolParseDocument(context, convId, argsJson);
    }
    if (name === 'search_pdf') {
      return await WorkToolRunner.toolSearchPdf(context, convId, argsJson);
    }
    if (name === 'pdf_to_images') {
      return await WorkToolRunner.toolPdfToImages(context, convId, argsJson);
    }
    if (name === 'transform_file') {
      return await WorkToolRunner.toolTransformFile(context, convId, argsJson);
    }
    return await WorkFileService.executeTool(context, convId, name, argsJson, abortSignal);
  }

  // ===== 参数读取 =====

  private static strArg(args: Record<string, Object>, key: string, defVal: string): string {
    let v: Object = args[key];
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return defVal;
  }

  private static argError(): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = false;
    r.output = 'ERROR: 参数不是合法的 JSON 对象';
    r.schemaError = true;
    return r;
  }

  private static parseArgs(argsJson: string): Record<string, Object> | null {
    let trimmed: string = argsJson.trim();
    if (trimmed === '') {
      trimmed = '{}';
    }
    try {
      let parsed: Object = JSON.parse(trimmed);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  private static extractErrMessage(e: Object): string {
    if (e instanceof Error) {
      let err: Error = e as Error;
      return err.message !== undefined ? err.message : String(e);
    }
    return String(e);
  }

  // 整数参数: 兼容 number 与数字字符串, 非法时用默认值
  private static intArg(args: Record<string, Object>, key: string, defVal: number): number {
    let v: Object = args[key];
    if (typeof v === 'number' && !isNaN(v as number)) {
      return Math.floor(v as number);
    }
    if (typeof v === 'string') {
      let n: number = parseInt(v as string, 10);
      if (!isNaN(n)) {
        return n;
      }
    }
    return defVal;
  }

  // 布尔参数: 兼容 boolean 与 'true'/'false' 字符串
  private static boolArg(args: Record<string, Object>, key: string, defVal: boolean): boolean {
    let v: Object = args[key];
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'string') {
      return (v as string).toLowerCase() === 'true';
    }
    return defVal;
  }

  // 文件名去扩展名+清洗(与 pdf_to_images 输出目录命名一致)
  private static baseNameNoExt(rel: string): string {
    let base: string = rel;
    let slash: number = base.lastIndexOf('/');
    if (slash >= 0) {
      base = base.substring(slash + 1);
    }
    let dot: number = base.lastIndexOf('.');
    if (dot > 0) {
      base = base.substring(0, dot);
    }
    base = base.replace(/[\\/:*?"<>|]/g, '_').trim();
    if (base === '') {
      base = 'doc';
    }
    return base;
  }

  // ===== write_docx: Doc JSON / doc 文件 / Markdown -> .docx =====
  private static async toolWriteDocx(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    let docJson: string = WorkToolRunner.strArg(args, 'doc', '');
    let docFile: string = WorkToolRunner.strArg(args, 'doc_file', '');
    let markdown: string = WorkToolRunner.strArg(args, 'markdown', '');
    let title: string = WorkToolRunner.strArg(args, 'title', '');
    let style: string = WorkToolRunner.strArg(args, 'style', '').toLowerCase();
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.docx')) {
      return WorkToolRunner.failMsg('path 建议以 .docx 结尾(当前: ' + rel + ')');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let doc: Doc;
    try {
      if (docJson.trim() !== '') {
        doc = DocParser.parse(docJson);
      } else if (docFile.trim() !== '') {
        let abs: string | null = WorkFileService.resolveSafe(root, docFile);
        if (abs === null || !WorkFileService.accessPath(abs) || WorkFileService.isDirPath(abs)) {
          return WorkToolRunner.failMsg('doc_file 不存在或非法: ' + docFile);
        }
        doc = DocParser.parse(WorkToolRunner.readWorkspaceText(abs));
      } else if (markdown.trim() !== '') {
        doc = MdToDoc.convert(markdown, title !== '' ? title : 'Guncat Work 文档');
      } else {
        return WorkToolRunner.failMsg('缺少 doc/doc_file/markdown 参数(三选一)。' +
          '正式文档用 doc(Doc JSON 结构化源, 支持封面/目录/分级标题/图片/表格, 语法 load_skill("docx"));' +
          '长文档先 write_file("doc.json", …) 分块写好再传 doc_file; 简单内容可直接传 markdown');
      }
    } catch (e) {
      return WorkToolRunner.failMsg(WorkToolRunner.extractErrMessage(e as Object));
    }
    if (title !== '') {
      doc.title = title;
    }
    if (style !== '') {
      if (!DocParser.isKnownStyle(style)) {
        return WorkToolRunner.failMsg('未知样式 "' + style + '"(支持 default/academic/minimal)');
      }
      doc.style = style;
    }
    try {
      let bytes: Uint8Array = await DocxBuilder.buildDocxBytes(doc,
        WorkToolRunner.docxResolver(context, root));
      let result: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel, bytes);
      if (result.ok) {
        result.output = '已生成《' + doc.title + '》(' + doc.blocks.length.toString() + ' 块' +
          (doc.cover ? ', 含封面' : '') + (doc.toc ? ', 含目录' : '') + ', 样式 ' + doc.style +
          ') → ' + rel + ' (' + WorkFileService.formatSize(bytes.length) + ')' +
          '\n—— 用 read_docx 或 read_file 抽查内容; 需要改图/改字用 edit_docx。';
      }
      return result;
    } catch (e) {
      return WorkToolRunner.failMsg('生成 Word 文档失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== read_docx: .docx -> Doc JSON(读回可编辑源; 外来文档抽取图片) =====
  private static async toolReadDocx(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.docx')) {
      return WorkToolRunner.failMsg('read_docx 仅支持 .docx');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + rel);
    }
    if (!WorkFileService.accessPath(abs)) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel);
    }
    // 外来文档图片输出目录: docx_images/<文件名>/(与 pdf_to_images 同款组织)
    let base: string = WorkToolRunner.baseNameNoExt(rel);
    let imageRelBase: string = 'docx_images/' + base;
    let imageOutDir: string = root + '/' + imageRelBase;
    try {
      let r: DocxImportResult = await DocxImporter.import(abs, context.cacheDir + '/work_docx',
        imageOutDir, imageRelBase);
      let docJson: string = JSON.stringify(r.doc);
      let head: string = r.embedded
        ? '《' + rel + '》的 Doc 源(无损还原, ' + r.blockCount.toString() + ' 块):\n'
        : '《' + rel + '》为外来 docx, 以下为近似导入的 Doc 源(' + r.blockCount.toString() +
          ' 块; 文本/表格/图片已还原, 版式细节可能丢失; edit_docx 保存前会自动备份原文件):\n';
      let out: string = head + docJson;
      if (out.length > Constants.WORK_RESULT_MAX_CHARS) {
        out = head + '整篇过大, 请用 edit_docx 的 update_block/delete_block/replace_text 按块号直接操作, ' +
          '或用 read_file 查看。\n第 1 块预览: ' + docJson.substring(0, 1500) + '...';
      }
      if (!r.embedded && r.images.length > 0) {
        out = out + '\n\n已抽取图片 ' + r.images.length.toString() +
          ' 张(可用 view_image 逐张查看, 也可直接用于再次 write_docx):\n- ' + r.images.join('\n- ');
      }
      return WorkToolRunner.okMsg(out);
    } catch (e) {
      return WorkToolRunner.failMsg('读取 Word 文档失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== edit_docx: 对已有 .docx 应用操作并保存 =====
  private static async toolEditDocx(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    let opsJson: string = WorkToolRunner.strArg(args, 'ops', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (opsJson.trim() === '') {
      return WorkToolRunner.failMsg('缺少参数 ops(JSON 数组), 如 [{"op":"update_block","index":2,"block":{"text":"新内容"}}]');
    }
    if (!rel.toLowerCase().endsWith('.docx')) {
      return WorkToolRunner.failMsg('edit_docx 仅支持 .docx');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + rel);
    }
    if (!WorkFileService.accessPath(abs)) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel + '(新建请用 write_docx)');
    }
    let base: string = WorkToolRunner.baseNameNoExt(rel);
    let imageRelBase: string = 'docx_images/' + base;
    let imageOutDir: string = root + '/' + imageRelBase;
    try {
      let r: DocxImportResult = await DocxImporter.import(abs, context.cacheDir + '/work_docx',
        imageOutDir, imageRelBase);
      let summary: string = DocOps.apply(r.doc, opsJson);
      // 外来文件(无内嵌源)重建前先备份原文件, 防止近似导入造成不可逆损失
      let backupNote: string = '';
      if (!r.embedded) {
        let backupRel: string = rel.replace(/\.docx$/i, '') + '_原版备份.docx';
        let backupAbs: string | null = WorkFileService.resolveSafe(root, backupRel);
        if (backupAbs !== null) {
          WorkFileService.copyFileSync(abs, backupAbs);
          backupNote = '\n原文件已备份为 ' + backupRel + '(外来 docx 为近似导入, 重建后不保留原版式细节)';
        }
      }
      let bytes: Uint8Array = await DocxBuilder.buildDocxBytes(r.doc,
        WorkToolRunner.docxResolver(context, root));
      let result: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel, bytes);
      if (result.ok) {
        result.output = '《' + rel + '》已更新(' + r.doc.blocks.length.toString() + ' 块, ' +
          WorkFileService.formatSize(bytes.length) + '):\n' + summary + backupNote;
      }
      return result;
    } catch (e) {
      return WorkToolRunner.failMsg('编辑 Word 文档失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // 图片解析器(docx): 工作区路径 / data URL / http 交给 PptxImage; .svg 源文件自动栅格化
  private static docxResolver(context: common.UIAbilityContext, root: string): DocImageResolver {
    return async (src: string): Promise<DocxImagePart | null> => {
      let p: PptxImagePart | null = await WorkToolRunner.imageResolver(context, root)(src);
      if (p === null) {
        return null;
      }
      let d: DocxImagePart = new DocxImagePart();
      d.data = p.data;
      d.mime = p.mime;
      d.ext = p.ext;
      d.widthPx = p.widthPx;
      d.heightPx = p.heightPx;
      return d;
    };
  }

  // ===== write_xlsx: Workbook JSON / workbook 文件 / Markdown表格·CSV·TSV -> .xlsx =====
  private static async toolWriteXlsx(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.xlsx')) {
      return WorkToolRunner.failMsg('path 建议以 .xlsx 结尾(当前: ' + rel + ')');
    }
    let workbookJson: string = WorkToolRunner.strArg(args, 'workbook', '');
    let workbookFile: string = WorkToolRunner.strArg(args, 'workbook_file', '');
    let table: string = WorkToolRunner.strArg(args, 'table', '');
    let name: string = WorkToolRunner.strArg(args, 'name', '');
    let style: string = WorkToolRunner.strArg(args, 'style', '');
    let wb: XlsxWorkbook;
    try {
      if (workbookJson.trim() !== '') {
        wb = XlsxParser.parse(workbookJson);
      } else if (workbookFile.trim() !== '') {
        let root: string = WorkFileService.workspaceRoot(context, convId);
        let abs: string | null = WorkFileService.resolveSafe(root, workbookFile);
        if (abs === null) {
          return WorkToolRunner.failMsg('workbook_file 越界或不存在: ' + workbookFile);
        }
        let text: string = WorkToolRunner.readWorkspaceText(abs);
        wb = XlsxParser.parse(text);
      } else if (table.trim() !== '') {
        wb = MdToXlsx.convert(table, name);
      } else {
        return WorkToolRunner.failMsg('缺少内容: 传 workbook(Workbook JSON, 语法 load_skill("xlsx"))、' +
          'workbook_file(工作区已有 workbook JSON 的相对路径)或 table(Markdown 表格/CSV/TSV 文本); ' +
          '正式表格建议用 workbook 结构化源, 支持多工作表/公式/数字格式/列宽/冻结窗格。');
      }
      if (style !== '') {
        if (!XlsxParser.isKnownStyle(style.toLowerCase())) {
          return WorkToolRunner.failMsg('未知样式 "' + style + '"(支持 default/academic/minimal)');
        }
        wb.style = style.toLowerCase();
      }
      let bytes: Uint8Array = XlsxBuilder.buildXlsxBytes(wb);
      let result: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel, bytes);
      let sheetNames: string = '';
      for (let i: number = 0; i < wb.sheets.length; i++) {
        if (i > 0) {
          sheetNames += '、';
        }
        sheetNames += wb.sheets[i].name;
      }
      result.output = '已写入 ' + rel + ' (' + wb.sheets.length.toString() + ' 个工作表: ' +
        sheetNames + '; 样式 ' + wb.style + ')。\n' +
        '—— 需要改数/改公式用 edit_xlsx 按 sheet/行/列操作; 想重做用 write_xlsx 传完整 workbook。';
      return result;
    } catch (e) {
      return WorkToolRunner.failMsg('生成 Excel 文件失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== read_xlsx: .xlsx -> Workbook JSON(读回可编辑源) =====
  private static async toolReadXlsx(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.xlsx')) {
      return WorkToolRunner.failMsg('read_xlsx 仅支持 .xlsx');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel);
    }
    try {
      let r: XlsxImportResult = await XlsxImporter.import(abs, context.cacheDir + '/work_xlsx');
      let jsonText: string = XlsxParser.toJson(r.workbook);
      let hint: string = '\n坐标约定: edit_xlsx 的 row/index 按数据行从 1 起算(不含表头), 与上方 rows 一一对应; ' +
        '改表头单元格用 set_header, 不能用 set_cell。';
      let head: string = r.embedded
        ? '《' + rel + '》的 Workbook 源(无损还原, ' + r.sheetCount.toString() + ' 个工作表, ' +
          r.rowCount.toString() + ' 行数据):' + hint
        : '《' + rel + '》为外来 xlsx, 以下为近似导入的 Workbook 源(' + r.sheetCount.toString() +
          ' 个工作表, ' + r.rowCount.toString() + ' 行; 数值/文本/公式已还原, 样式与合并等细节可能丢失; ' +
          'edit_xlsx 保存前会自动备份原文件):' + hint;
      let out: string = head + jsonText;
      if (out.length > Constants.WORK_RESULT_MAX_CHARS) {
        out = head + '整簿过大, 请用 edit_xlsx 的 set_cell/add_row/delete_row/replace_text 按 sheet/行/列直接操作, ' +
          '或用 read_file 查看文本视图。\n第 1 个工作表预览: ' +
          jsonText.substring(0, 1500) + '...';
      }
      return WorkToolRunner.okMsg(out);
    } catch (e) {
      return WorkToolRunner.failMsg('读取 Excel 文件失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== edit_xlsx: 对已有 .xlsx 应用操作并保存 =====
  private static async toolEditXlsx(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    let opsJson: string = WorkToolRunner.strArg(args, 'ops', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (opsJson.trim() === '') {
      return WorkToolRunner.failMsg('缺少参数 ops(JSON 数组), 如 [{"op":"set_cell","sheet":"收入","row":2,"col":2,"value":999}]');
    }
    if (!rel.toLowerCase().endsWith('.xlsx')) {
      return WorkToolRunner.failMsg('edit_xlsx 仅支持 .xlsx');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel + '(新建请用 write_xlsx)');
    }
    try {
      let r: XlsxImportResult = await XlsxImporter.import(abs, context.cacheDir + '/work_xlsx');
      let summary: string = XlsxOps.apply(r.workbook, opsJson);
      let backupNote: string = '';
      if (!r.embedded) {
        let backupRel: string = rel.replace(/\.xlsx$/i, '') + '_原版备份.xlsx';
        let backupAbs: string | null = WorkFileService.resolveSafe(root, backupRel);
        if (backupAbs !== null) {
          WorkFileService.copyFileSync(abs, backupAbs);
          backupNote = '\n原文件已备份为 ' + backupRel + '(外来 xlsx 为近似导入, 重建后不保留原样式细节)';
        }
      }
      let bytes: Uint8Array = XlsxBuilder.buildXlsxBytes(r.workbook);
      let result: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel, bytes);
      result.output = summary + '\n已保存到 ' + rel + backupNote;
      return result;
    } catch (e) {
      return WorkToolRunner.failMsg('编辑 Excel 文件失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // 表格文本解析: 优先 Markdown 表格(|), 其次 TSV(制表符), 最后 CSV(自动推断 , / ; 分隔符)。
  // 解析委托 CsvParser: RFC 4180 引号字段(内含逗号/引号/换行)正确处理
  private static parseTableInput(table: string): string[][] {
    return CsvParser.parseSmartTable(table);
  }

  // ===== write_csv: 表格文本 -> CSV(RFC 4180 转义, 可带 BOM) =====
  private static async toolWriteCsv(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    let table: string = WorkToolRunner.strArg(args, 'table', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (table.trim() === '') {
      return WorkToolRunner.failMsg('缺少参数 table');
    }
    let bom: boolean = WorkToolRunner.strArg(args, 'bom', 'true').toLowerCase() !== 'false';
    let rows: string[][] = WorkToolRunner.parseTableInput(table);
    if (rows.length === 0) {
      return WorkToolRunner.failMsg('表格数据为空, 请提供 Markdown 表格、CSV 或 TSV 文本');
    }
    let bytes: Uint8Array = CsvWriter.buildCsvBytes(rows, bom);
    let result: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel, bytes);
    if (result.ok) {
      let cols: number = rows[0].length;
      result.output = '已写入 ' + rel + ' (' + rows.length.toString() + ' 行 × ' + cols.toString() +
        ' 列, ' + WorkFileService.formatSize(bytes.length) + (bom ? ', UTF-8 BOM)' : ')');
    }
    return result;
  }

  // ===== write_svg: SVG 源码 -> 工作区 .svg + 栅格化 PNG 预览 =====
  private static async toolWriteSvg(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    let svg: string = WorkToolRunner.strArg(args, 'svg', '');
    let width: number = WorkToolRunner.intArg(args, 'width', 512);
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.svg')) {
      return WorkToolRunner.failMsg('path 需以 .svg 结尾(当前: ' + rel + ')');
    }
    if (svg.trim() === '') {
      return WorkToolRunner.failMsg('缺少参数 svg');
    }
    if (svg.length > Constants.WORK_SVG_MAX_CHARS) {
      return WorkToolRunner.failMsg('SVG 源码超过 ' +
        WorkFileService.formatSize(Constants.WORK_SVG_MAX_CHARS) + ' 上限, 请简化图形');
    }
    let check: string = SvgUtil.validate(svg);
    if (check !== '') {
      return WorkToolRunner.failMsg(check);
    }
    // 规整: 缺失 width/height 时自动按 viewBox 补齐(实机栅格引擎必需), 再落盘
    let normalized: string = SvgUtil.normalize(svg, 512);
    let encoder: util.TextEncoder = new util.TextEncoder();
    let saveResult: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel,
      encoder.encode(normalized));
    if (!saveResult.ok) {
      return saveResult;
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + rel);
    }
    // 尺寸信息
    let dims: number[] = SvgUtil.aspect(normalized);
    let aspectNote: string = dims[2] > 0
      ? 'viewBox ' + dims[0].toString() + '×' + dims[1].toString()
      : '未声明 viewBox/尺寸';
    let autoFixed: string = normalized !== svg
      ? '（源码缺 width/height, 已自动按 viewBox 补齐）'
      : '';
    // 栅格化预览
    if (width < 64) {
      width = 64;
    } else if (width > 2048) {
      width = 2048;
    }
    let previewRel: string = rel.replace(/\.svg$/i, '') + '_preview.png';
    let out: string = '已生成 ' + rel + ' (' + aspectNote + ')' + autoFixed;
    try {
      let png: PptxImagePart = await WorkToolRunner.rasterizeSvgFile(abs, width, dims,
        context.cacheDir + '/work_svg');
      let previewResult: ToolExecResult = WorkFileService.writeBytesAt(context, convId,
        previewRel, png.data);
      if (previewResult.ok) {
        out += '\n预览已生成: ' + previewRel + ' (' + png.widthPx.toString() + '×' +
          png.heightPx.toString() + ' PNG, ' + WorkFileService.formatSize(png.data.length) + ')' +
          '\n—— 立即用 view_image 查看 ' + previewRel + ' 自检; write_pptx 可直接引用 ' + rel +
          '(自动栅格化), write_docx 引用预览 PNG。';
      } else {
        out += '\n预览写入失败: ' + previewResult.output;
      }
    } catch (e) {
      let msg: string = WorkToolRunner.extractErrMessage(e as Object);
      out += '\nSVG 解码失败(' + msg + ')。xmlns 校验与 width/height 补齐已完成, 问题出在图形内容本身。' +
        '排查纪律: 先用最小 SVG(仅一个 <rect>)走通管线, 再逐步叠加元素二分定位;' +
        '渐变(<linearGradient>/<filter>)与 <text> 字体是最常见的不兼容点, 可先移除排查。';
    }
    return WorkToolRunner.okMsg(out);
  }

  // SVG 文件 -> PNG 字节(设备图片引擎栅格化; 抛错由调用方转为可读信息)
  // 流程: 读源码 -> SvgUtil.normalize 补齐 width/height -> 写临时规整文件 -> 解码打包 -> 清理。
  // 不改动工作区里的原文件; 临时文件落在 cacheDir。
  private static async rasterizeSvgFile(absPath: string, width: number, dims: number[],
    cacheDir: string): Promise<PptxImagePart> {
    let h: number = width;
    if (dims[2] > 0 && dims[0] > 0) {
      h = Math.round(width * dims[1] / dims[0]);
    }
    if (h < 1) {
      h = 1;
    }
    let svgText: string = WorkToolRunner.readWorkspaceText(absPath);
    let normalized: string = SvgUtil.normalize(svgText, 512);
    WorkFileService.ensureDir(cacheDir);
    let tempPath: string = cacheDir + '/svg_raster_' + Date.now().toString() + '.svg';
    let encoder: util.TextEncoder = new util.TextEncoder();
    WorkFileService.writeBytes(tempPath, encoder.encode(normalized));
    let file: fileIo.File = fileIo.openSync(tempPath, fileIo.OpenMode.READ_ONLY);
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      source = image.createImageSource(file.fd);
      let opts: image.DecodingOptions = { desiredSize: { width: width, height: h } };
      pixelMap = await source.createPixelMap(opts);
      packer = image.createImagePacker();
      let packOpts: image.PackingOption = { format: 'image/png', quality: 100 };
      let buffer: ArrayBuffer = await packer.packToData(pixelMap, packOpts);
      if (buffer.byteLength < 8) {
        throw new Error('栅格化输出为空');
      }
      let part: PptxImagePart = new PptxImagePart();
      part.data = new Uint8Array(buffer);
      part.mime = 'image/png';
      part.ext = 'png';
      part.widthPx = width;
      part.heightPx = h;
      return part;
    } finally {
      if (pixelMap !== null) {
        await pixelMap.release();
      }
      if (source !== null) {
        await source.release();
      }
      if (packer !== null) {
        await packer.release();
      }
      fileIo.closeSync(file);
      try {
        if (fileIo.accessSync(tempPath)) {
          fileIo.unlinkSync(tempPath);
        }
      } catch (e) {
        // 临时文件清理失败不阻断主流程
      }
    }
  }

  // ===== download_file: http(s) -> 工作区 =====
  private static async toolDownloadFile(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let url: string = WorkToolRunner.strArg(args, 'url', '').trim();
    let rel: string = WorkToolRunner.strArg(args, 'path', '').trim();
    if (url === '') {
      return WorkToolRunner.failMsg('缺少参数 url');
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return WorkToolRunner.failMsg('url 需以 http:// 或 https:// 开头');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let derived: boolean = false;
    if (rel === '') {
      rel = WorkToolRunner.urlFileName(url);
      rel = WorkFileService.uniqueName(root, WorkFileService.sanitizeFileName(rel));
      derived = true;
    } else if (rel.endsWith('/')) {
      rel = rel + WorkFileService.uniqueName(root, WorkFileService.sanitizeFileName(
        WorkToolRunner.urlFileName(url)));
      derived = true;
    }
    let req: http.HttpRequest = http.createHttp();
    WorkToolRunner.registerToolRequest(req);
    try {
      let headers: Record<string, string> = { 'user-agent': 'Mozilla/5.0 (Linux; HarmonyOS) GuncatWork' };
      let resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000,
        header: headers
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return WorkToolRunner.failMsg('下载失败: HTTP ' + resp.responseCode.toString() +
          '(链接失效/需要登录/反爬)。尝试换直链或换源');
      }
      let bytes: Uint8Array = new Uint8Array(resp.result as ArrayBuffer);
      if (bytes.length === 0) {
        return WorkToolRunner.failMsg('下载失败: 响应为空');
      }
      if (bytes.length > Constants.WORK_DOWNLOAD_MAX_BYTES) {
        return WorkToolRunner.failMsg('文件超过 ' +
          WorkFileService.formatSize(Constants.WORK_DOWNLOAD_MAX_BYTES) + ' 下载上限(实际 ' +
          WorkFileService.formatSize(bytes.length) + ')');
      }
      let contentType: string = '';
      try {
        let respHeaders: Record<string, string> = resp.header as Record<string, string>;
        contentType = respHeaders['content-type'] !== undefined ? respHeaders['content-type'] :
          (respHeaders['Content-Type'] !== undefined ? respHeaders['Content-Type'] : '');
      } catch (e) {
        contentType = '';
      }
      let sniffed: string = WorkToolRunner.sniffTypeName(bytes);
      let saveResult: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel, bytes);
      if (!saveResult.ok) {
        return saveResult;
      }
      let out: string = '已下载 ' + url + ' → ' + rel + ' (' +
        WorkFileService.formatSize(bytes.length) + ', 类型: ' + sniffed +
        (contentType !== '' ? ', content-type: ' + contentType : '') + ')';
      if (sniffed === '网页' || contentType.indexOf('text/html') !== -1) {
        out += '\n—— 注意: 下载到的是网页而非文件, 说明该链接不是直链(可能跳转/需要登录/防盗链)。' +
          '若你要的是图片, 请换直链重试或换图源。';
      }
      out += '\n—— 图片可直接用于 write_pptx / write_docx, 或 view_image 查看内容。';
      return WorkToolRunner.okMsg(out);
    } catch (e) {
      return WorkToolRunner.failMsg('下载失败: ' + WorkToolRunner.extractErrMessage(e as Object) +
        '(网络不可达/超时/证书问题)');
    } finally {
      WorkToolRunner.unregisterToolRequest(req);
      req.destroy();
    }
  }

  // 从 URL 提取文件名(去查询串; 取不到时按时间戳命名)
  private static urlFileName(url: string): string {
    let clean: string = url.split('?')[0].split('#')[0];
    let name: string = '';
    try {
      clean = decodeURIComponent(clean);
    } catch (e) {
      // 保留原串
    }
    let slash: number = clean.lastIndexOf('/');
    if (slash >= 0 && slash + 1 < clean.length) {
      name = clean.substring(slash + 1);
    }
    name = name.replace(/[\\/:*?"<>|]/g, '_').trim();
    if (name === '') {
      name = 'download_' + XmlUtil.stamp() + '.bin';
    }
    if (name.indexOf('.') < 0) {
      name = name + '.bin';
    }
    return name;
  }

  // 字节嗅探的可读类型名
  private static sniffTypeName(data: Uint8Array): string {
    if (data.length >= 8 && data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4E && data[3] === 0x47) {
      return 'PNG';
    }
    if (data.length >= 3 && data[0] === 0xFF && data[1] === 0xD8 && data[2] === 0xFF) {
      return 'JPEG';
    }
    if (data.length >= 6 && data[0] === 0x47 && data[1] === 0x49 && data[2] === 0x46) {
      return 'GIF';
    }
    if (data.length >= 12 && data[0] === 0x52 && data[1] === 0x49 && data[8] === 0x57 && data[9] === 0x45) {
      return 'WEBP';
    }
    if (data.length >= 2 && data[0] === 0x42 && data[1] === 0x4D) {
      return 'BMP';
    }
    if (data.length >= 5 && data[0] === 0x3C && data[1] === 0x73 && data[2] === 0x76 && data[3] === 0x67) {
      return 'SVG';
    }
    let head: string = '';
    for (let i: number = 0; i < data.length && i < 16; i++) {
      let ch: number = data[i];
      head += (ch >= 0x20 && ch < 0x7F) ? String.fromCharCode(ch) : '.';
    }
    let lower: string = head.toLowerCase();
    if (lower.indexOf('<!doctype') !== -1 || lower.indexOf('<html') !== -1) {
      return '网页';
    }
    if (lower.indexOf('pk') === 0) {
      return 'ZIP 容器(docx/xlsx/pptx?)';
    }
    return '未知(' + head.replace(/\./g, '') + ')';
  }

  // ===== write_pptx: Deck JSON / deck 文件 / 简易大纲 -> .pptx =====
  private static async toolWritePptx(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    let deckJson: string = WorkToolRunner.strArg(args, 'deck', '');
    let deckFile: string = WorkToolRunner.strArg(args, 'deck_file', '');
    let outline: string = WorkToolRunner.strArg(args, 'outline', '');
    let theme: string = WorkToolRunner.strArg(args, 'theme', '');
    let title: string = WorkToolRunner.strArg(args, 'title', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.pptx')) {
      return WorkToolRunner.failMsg('path 建议以 .pptx 结尾(当前: ' + rel + ')');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let deck: Deck;
    try {
      if (deckJson.trim() !== '') {
        deck = DeckParser.parse(deckJson);
      } else if (deckFile.trim() !== '') {
        let abs: string | null = WorkFileService.resolveSafe(root, deckFile);
        if (abs === null || !WorkFileService.accessPath(abs) || WorkFileService.isDirPath(abs)) {
          return WorkToolRunner.failMsg('deck_file 不存在或非法: ' + deckFile);
        }
        deck = DeckParser.parse(WorkToolRunner.readWorkspaceText(abs));
      } else if (outline.trim() !== '') {
        deck = DeckOutline.parse(outline, title !== '' ? title : 'Guncat Work 演示');
      } else {
        return WorkToolRunner.failMsg('缺少 deck/deck_file/outline 参数(三选一)。' +
          'Deck JSON 用法: load_skill("ppt"); 简单场景可直接传 outline 大纲');
      }
    } catch (e) {
      return WorkToolRunner.failMsg(WorkToolRunner.extractErrMessage(e as Object));
    }
    if (title !== '') {
      deck.title = title;
    }
    if (theme !== '') {
      deck.theme = theme;
    }
    try {
      let bytes: Uint8Array = await PptxBuilder.buildPptxBytes(deck, WorkToolRunner.imageResolver(context, root));
      let result: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel, bytes);
      if (result.ok) {
        result.output = '已生成《' + deck.title + '》(' + deck.slides.length.toString() + ' 页, 主题 ' +
          deck.theme + ') → ' + rel + ' (' + WorkFileService.formatSize(bytes.length) + ')';
      }
      return result;
    } catch (e) {
      return WorkToolRunner.failMsg('生成演示文稿失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== read_ppt: .pptx -> Deck JSON(读回可编辑源) =====
  private static async toolReadPpt(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.pptx')) {
      return WorkToolRunner.failMsg('read_ppt 仅支持 .pptx');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + rel);
    }
    if (!WorkFileService.accessPath(abs)) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel);
    }
    try {
      let r: PptxImportResult = await PptxImporter.import(abs, context.cacheDir + '/work_pptx');
      let deckJson: string = JSON.stringify(r.deck);
      let head: string = r.embedded
        ? '《' + rel + '》的 Deck 源(无损还原, ' + r.slideCount.toString() + ' 页):\n'
        : '《' + rel + '》为外来 pptx, 以下为近似导入的 Deck 源(' + r.slideCount.toString() +
          ' 页; 文本/表格/版面位置保留, 图片与图表数据未导入; edit_ppt 保存前会自动备份原文件):\n';
      let out: string = head + deckJson;
      if (out.length > Constants.WORK_RESULT_MAX_CHARS) {
        out = head + '整册过大, 请用 edit_ppt 的 replace_text/update_slide 按页码直接操作, 或用 read_file 查看。\n' +
          '第 1 页预览: ' + deckJson.substring(0, 1500) + '...';
      }
      return WorkToolRunner.okMsg(out);
    } catch (e) {
      return WorkToolRunner.failMsg('读取演示文稿失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== edit_ppt: 对已有 .pptx 应用操作并保存 =====
  private static async toolEditPpt(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    let opsJson: string = WorkToolRunner.strArg(args, 'ops', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (opsJson.trim() === '') {
      return WorkToolRunner.failMsg('缺少参数 ops(JSON 数组), 如 [{"op":"add_slide","slide":{"layout":"content","title":"新页","bullets":["要点"]}}]');
    }
    if (!rel.toLowerCase().endsWith('.pptx')) {
      return WorkToolRunner.failMsg('edit_ppt 仅支持 .pptx');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + rel);
    }
    if (!WorkFileService.accessPath(abs)) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel + '(新建请用 write_pptx)');
    }
    try {
      let r: PptxImportResult = await PptxImporter.import(abs, context.cacheDir + '/work_pptx');
      let summary: string = DeckOps.apply(r.deck, opsJson);
      // 外来文件(无内嵌源)重建前先备份原文件, 防止近似导入造成不可逆损失
      let backupNote: string = '';
      if (!r.embedded) {
        let backupRel: string = rel.replace(/\.pptx$/i, '') + '_原版备份.pptx';
        let backupAbs: string | null = WorkFileService.resolveSafe(root, backupRel);
        if (backupAbs !== null) {
          WorkFileService.copyFileSync(abs, backupAbs);
          backupNote = '\n原文件已备份为 ' + backupRel + '(外来 pptx 为近似导入, 重建后不保留原图表)';
        }
      }
      let bytes: Uint8Array = await PptxBuilder.buildPptxBytes(r.deck, WorkToolRunner.imageResolver(context, root));
      let result: ToolExecResult = WorkFileService.writeBytesAt(context, convId, rel, bytes);
      if (result.ok) {
        result.output = '《' + rel + '》已更新(' + r.deck.slides.length.toString() + ' 页, ' +
          WorkFileService.formatSize(bytes.length) + '):\n' + summary + backupNote;
      }
      return result;
    } catch (e) {
      return WorkToolRunner.failMsg('编辑演示文稿失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // 图片解析器: 工作区路径 / data URL / http(s) 交给 PptxImage; .svg 源文件自动栅格化为 PNG
  private static imageResolver(context: common.UIAbilityContext, root: string): ImageResolver {
    return async (src: string): Promise<PptxImagePart | null> => {
      if (src.trim().toLowerCase().endsWith('.svg')) {
        let abs: string | null = WorkFileService.resolveSafe(root, src.trim());
        if (abs === null || !WorkFileService.accessPath(abs) || WorkFileService.isDirPath(abs)) {
          return null;
        }
        try {
          let svg: string = WorkToolRunner.readWorkspaceText(abs);
          let dims: number[] = SvgUtil.aspect(svg);
          // PPT 图形位图按 1024px 宽栅格化保证清晰
          return await WorkToolRunner.rasterizeSvgFile(abs, 1024, dims,
            context.cacheDir + '/work_svg');
        } catch (e) {
          return null;
        }
      }
      return PptxImage.resolve(src, root);
    };
  }

  private static readWorkspaceText(abs: string): string {
    let buffer: ArrayBuffer = WorkFileService.readBytesPublic(abs, 4 * 1024 * 1024);
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(buffer), { stream: false });
  }

  // ===== parse_document: PDF 文本(本地, 支持按页分段提取) =====
  private static async toolParseDocument(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.pdf')) {
      return WorkToolRunner.failMsg('parse_document 仅支持 PDF; .docx/.xlsx/.pptx 请用 read_file(本地自动解析)');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + rel);
    }
    if (!WorkFileService.accessPath(abs)) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel);
    }
    if (WorkFileService.isDirPath(abs)) {
      return WorkToolRunner.failMsg('路径是目录而非文件: ' + rel);
    }
    let startPage: number = WorkToolRunner.intArg(args, 'page', 1);
    let pageLimit: number = WorkToolRunner.intArg(args, 'page_count', Constants.WORK_PDF_PAGES_PER_CALL);
    if (pageLimit < 1) {
      pageLimit = 1;
    } else if (pageLimit > 200) {
      pageLimit = 200;
    }
    try {
      let r: PdfPagesResult = await PdfTextExtractor.extractPages(abs, startPage, pageLimit,
        Constants.WORK_RESULT_MAX_CHARS * 2);
      if (r.pageCount <= 0) {
        return WorkToolRunner.failMsg('该 PDF 无有效页面(可能是加密或损坏文件)');
      }
      if (r.pages.length === 0) {
        return WorkToolRunner.failMsg('共 ' + r.pageCount.toString() + ' 页, 传入的 page=' +
          r.startPage.toString() + ' 超出范围(1-' + r.pageCount.toString() + ')');
      }
      let out: string = '《' + rel + '》共 ' + r.pageCount.toString() + ' 页, 本次为第 ' +
        r.startPage.toString() + '-' + r.endPage.toString() + ' 页:\n\n';
      for (let i: number = 0; i < r.pages.length; i++) {
        out = out + '[第 ' + (r.startPage + i).toString() + ' 页]\n' + r.pages[i] + '\n\n';
      }
      if (r.nextStartPage > 0) {
        out = out + '—— 未读完。继续提取请调用 parse_document, 参数 {"path":"' + rel +
          '","page":' + r.nextStartPage.toString() + '}; 需要定位关键词所在页可用 search_pdf。';
      } else {
        out = out + '—— 已到文档末页。';
      }
      return WorkToolRunner.okMsg(out);
    } catch (e) {
      return WorkToolRunner.failMsg('解析失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== search_pdf: PDF 关键词搜索(系统引擎, 兜底逐页扫描) =====
  private static async toolSearchPdf(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    let query: string = WorkToolRunner.strArg(args, 'query', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (query.trim() === '') {
      return WorkToolRunner.failMsg('缺少参数 query');
    }
    if (!rel.toLowerCase().endsWith('.pdf')) {
      return WorkToolRunner.failMsg('search_pdf 仅支持 PDF; 文本文件请用 search_files');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + rel);
    }
    if (!WorkFileService.accessPath(abs)) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel);
    }
    if (WorkFileService.isDirPath(abs)) {
      return WorkToolRunner.failMsg('路径是目录而非文件: ' + rel);
    }
    try {
      let hits: PdfSearchHit[] = await PdfTextExtractor.searchText(abs, query,
        Constants.WORK_SEARCH_MAX_MATCHES);
      if (hits.length === 0) {
        return WorkToolRunner.okMsg('未在《' + rel + '》中找到 "' + query + '"');
      }
      let out: string = '《' + rel + '》共 ' + hits.length.toString() + ' 处命中:\n';
      for (let i: number = 0; i < hits.length; i++) {
        let ctx: string = hits[i].context !== '' ? hits[i].context : '(无上下文摘录)';
        out = out + '第 ' + hits[i].pageIndex.toString() + ' 页: ' + ctx + '\n';
      }
      out = out + '—— 提取对应页请调用 parse_document, 参数 {"path":"' + rel + '","page":页码}。';
      return WorkToolRunner.okMsg(out);
    } catch (e) {
      return WorkToolRunner.failMsg('PDF 搜索失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== pdf_to_images: PDF 页面转图片(扫描件入口, 供 view_image 逐张查看) =====
  private static async toolPdfToImages(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let rel: string = WorkToolRunner.strArg(args, 'path', '');
    if (rel === '') {
      return WorkToolRunner.failMsg('缺少参数 path');
    }
    if (!rel.toLowerCase().endsWith('.pdf')) {
      return WorkToolRunner.failMsg('pdf_to_images 仅支持 PDF');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, rel);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + rel);
    }
    if (!WorkFileService.accessPath(abs)) {
      return WorkToolRunner.failMsg('文件不存在: ' + rel);
    }
    if (WorkFileService.isDirPath(abs)) {
      return WorkToolRunner.failMsg('路径是目录而非文件: ' + rel);
    }
    let startPage: number = WorkToolRunner.intArg(args, 'page', 1);
    let pageLimit: number = WorkToolRunner.intArg(args, 'page_count',
      Constants.WORK_PDF_RENDER_PAGES_PER_CALL);
    if (pageLimit < 1) {
      pageLimit = 1;
    } else if (pageLimit > 50) {
      pageLimit = 50;
    }
    // 输出目录: pdf_images/<去扩展名的文件名>/, 重名 PDF 各自独立
    let base: string = rel;
    let slash: number = base.lastIndexOf('/');
    if (slash >= 0) {
      base = base.substring(slash + 1);
    }
    let dot: number = base.lastIndexOf('.');
    if (dot > 0) {
      base = base.substring(0, dot);
    }
    base = base.replace(/[\\/:*?"<>|]/g, '_').trim();
    if (base === '') {
      base = 'doc';
    }
    let outDir: string = root + '/pdf_images/' + base;
    try {
      let r: PdfRenderResult = await PdfTextExtractor.renderPages(abs, startPage, pageLimit, outDir);
      if (r.pageCount <= 0) {
        return WorkToolRunner.failMsg('该 PDF 无有效页面(可能是加密或损坏文件)');
      }
      if (r.files.length === 0) {
        return WorkToolRunner.failMsg('共 ' + r.pageCount.toString() + ' 页, 传入的 page=' +
          r.startPage.toString() + ' 超出范围(1-' + r.pageCount.toString() + ')');
      }
      let out: string = '已渲染《' + rel + '》第 ' + r.startPage.toString() + '-' +
        r.endPage.toString() + ' 页(共 ' + r.pageCount.toString() + ' 页) → ' +
        'pdf_images/' + base + '/ :\n';
      for (let i: number = 0; i < r.files.length; i++) {
        let shown: string = r.files[i];
        if (shown.startsWith(root + '/')) {
          shown = shown.substring(root.length + 1);
        }
        out = out + shown + ' (第 ' + (r.startPage + i).toString() + ' 页)\n';
      }
      if (r.nextStartPage > 0) {
        out = out + '—— 用 view_image 逐张查看(每次传一个 path); 需要更多页: pdf_to_images 传 {"path":"' +
          rel + '","page":' + r.nextStartPage.toString() + '}。';
      } else {
        out = out + '—— 已是全部页面。用 view_image 逐张查看(每次传一个 path)。';
      }
      return WorkToolRunner.okMsg(out);
    } catch (e) {
      return WorkToolRunner.failMsg('渲染失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
  }

  // ===== transform_file: 本地数据管道(大文件清洗/转换/提取/格式互转, 不经模型上下文) =====
  // 流程: 省略 output 只预览前 3 行 -> 调整 steps -> 带 output 写盘; 求值由 DataPipeline 完成(无 I/O)。
  private static async toolTransformFile(context: common.UIAbilityContext, convId: string,
    argsJson: string): Promise<ToolExecResult> {
    let args: Record<string, Object> | null = WorkToolRunner.parseArgs(argsJson);
    if (args === null) {
      return WorkToolRunner.argError();
    }
    let input: string = WorkToolRunner.strArg(args, 'input', '').trim();
    let stepsJson: string = WorkToolRunner.strArg(args, 'steps', '');
    let format: string = WorkToolRunner.strArg(args, 'format', '');
    let delimiter: string = WorkToolRunner.strArg(args, 'delimiter', '');
    let jsonPath: string = WorkToolRunner.strArg(args, 'json_path', '');
    let output: string = WorkToolRunner.strArg(args, 'output', '').trim();
    let hasHeader: boolean = WorkToolRunner.boolArg(args, 'has_header', true);
    let bom: boolean = WorkToolRunner.boolArg(args, 'bom', true);
    let previewOnly: boolean = WorkToolRunner.boolArg(args, 'preview', false);
    if (input === '') {
      return WorkToolRunner.failMsg('缺少参数 input(要转换的工作区数据文件相对路径)');
    }
    if (stepsJson.trim() === '') {
      return WorkToolRunner.failMsg('缺少参数 steps(转换步骤 JSON 数组)。语法: load_skill("data")');
    }
    let root: string = WorkFileService.workspaceRoot(context, convId);
    let abs: string | null = WorkFileService.resolveSafe(root, input);
    if (abs === null) {
      return WorkToolRunner.failMsg('非法路径: ' + input);
    }
    if (!WorkFileService.accessPath(abs)) {
      return WorkToolRunner.failMsg('文件不存在: ' + input);
    }
    if (WorkFileService.isDirPath(abs)) {
      return WorkToolRunner.failMsg('路径是目录而非文件: ' + input);
    }
    if (fileIo.statSync(abs).size > Constants.WORK_TRANSFORM_INPUT_MAX_BYTES) {
      return WorkToolRunner.failMsg('输入文件超过 ' +
        WorkFileService.formatSize(Constants.WORK_TRANSFORM_INPUT_MAX_BYTES) + ' 上限(实际 ' +
        WorkFileService.formatSize(fileIo.statSync(abs).size) + ')。用 read_file/parse_document 分段定位' +
        '需要的数据, 拆分后分批转换');
    }
    let text: string = WorkToolRunner.readWorkspaceText(abs);
    let table: DpTable;
    let outcome: DpOutcome;
    try {
      outcome = DataPipeline.run(text, format, delimiter, jsonPath, hasHeader, stepsJson,
        Constants.WORK_TRANSFORM_MAX_ROWS, Constants.WORK_TRANSFORM_MAX_STEPS);
      table = outcome.table;
    } catch (e) {
      return WorkToolRunner.failMsg(WorkToolRunner.extractErrMessage(e as Object));
    }
    let head: string = '《' + input + '》转换完成: ' + DataPipeline.statsText(table);
    if (outcome.applied.length > 0) {
      head += '\n管道: ' + outcome.applied.join('\n     → ');
    }
    let previewBlock: string = '\n\n预览(前 ' + Constants.WORK_TRANSFORM_PREVIEW_ROWS.toString() + ' 行):\n' +
      DataPipeline.previewMarkdown(table, Constants.WORK_TRANSFORM_PREVIEW_ROWS, 40, 12);
    if (output === '' || previewOnly) {
      let tail: string = output !== '' && previewOnly
        ? '\n—— preview=true, 未写盘。确认无误后去掉 preview 或直接重新调用写盘。'
        : '\n—— 未写盘(预览模式)。确认数据无误后, 加 "output":"<目标文件>" 重新调用即写盘; 需要调整就修改 steps 再试。';
      return WorkToolRunner.okMsg(head + previewBlock + tail);
    }
    // 写盘: 按输出扩展名选择编码器(out_format 可显式覆盖)
    let outFormat: string = WorkToolRunner.strArg(args, 'out_format', '').trim().toLowerCase();
    if (outFormat === '') {
      let lower: string = output.toLowerCase();
      if (lower.endsWith('.csv')) {
        outFormat = 'csv';
      } else if (lower.endsWith('.tsv')) {
        outFormat = 'tsv';
      } else if (lower.endsWith('.json')) {
        outFormat = 'json';
      } else if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
        outFormat = 'md';
      } else if (lower.endsWith('.xlsx')) {
        outFormat = 'xlsx';
      } else if (lower.endsWith('.txt') || lower.endsWith('.log')) {
        outFormat = 'lines';
      } else {
        return WorkToolRunner.failMsg('output 扩展名无法识别输出格式(支持 .csv/.tsv/.json/.md/.xlsx/.txt), ' +
          '或用 out_format 显式指定');
      }
    }
    let bytes: Uint8Array;
    let rowsWithHeader: string[][] = DataPipeline.toCsvRows(table, true);
    let encoder: util.TextEncoder = new util.TextEncoder();
    try {
      if (outFormat === 'csv') {
        bytes = CsvWriter.buildCsvBytes(rowsWithHeader, bom);
      } else if (outFormat === 'xlsx') {
        if (table.rows.length > Constants.WORK_TRANSFORM_XLSX_MAX_ROWS) {
          return WorkToolRunner.failMsg('结果 ' + table.rows.length.toString() + ' 行, 超过 xlsx 输出上限 ' +
            Constants.WORK_TRANSFORM_XLSX_MAX_ROWS.toString() + ' 行(内存型构建)。请输出 .csv');
        }
        bytes = XlsxExporter.buildXlsxFromRows(rowsWithHeader);
      } else if (outFormat === 'tsv') {
        bytes = encoder.encode(DataPipeline.toTsvText(table));
      } else if (outFormat === 'json') {
        bytes = encoder.encode(DataPipeline.toJsonText(table));
      } else if (outFormat === 'md') {
        bytes = encoder.encode(DataPipeline.toMdText(table));
      } else if (outFormat === 'lines') {
        bytes = encoder.encode(DataPipeline.toLinesText(table));
      } else {
        return WorkToolRunner.failMsg('未知输出格式: "' + outFormat + '"(支持 csv/tsv/json/md/xlsx/lines)');
      }
    } catch (e) {
      return WorkToolRunner.failMsg('生成输出失败: ' + WorkToolRunner.extractErrMessage(e as Object));
    }
    if (bytes.length > Constants.WORK_TRANSFORM_OUTPUT_MAX_BYTES) {
      return WorkToolRunner.failMsg('输出 ' + WorkFileService.formatSize(bytes.length) + ', 超过写盘上限 ' +
        WorkFileService.formatSize(Constants.WORK_TRANSFORM_OUTPUT_MAX_BYTES) + '。用 limit/筛选缩减规模, ' +
        '或拆成多个输出文件');
    }
    let result: ToolExecResult = WorkFileService.writeBytesAt(context, convId, output, bytes);
    if (result.ok) {
      result.output = head + '\n\n已写入 ' + output + ' (' +
        WorkFileService.formatSize(bytes.length) + ')' +
        '\n—— 用 read_file 抽查前几行确认结果; 需要先预览再写盘时, 调用时省略 output。';
    }
    return result;
  }

  // ===== 结果封装 =====

  private static okMsg(output: string): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = true;
    r.output = output;
    return r;
  }

  private static failMsg(output: string): ToolExecResult {
    let r: ToolExecResult = new ToolExecResult();
    r.ok = false;
    r.output = 'ERROR: ' + output;
    return r;
  }

  // schema 校验失败(参数缺失/类型错/JSON 非法): 打上 schemaError 标记供评估
  private static schemaFailMsg(output: string): ToolExecResult {
    let r: ToolExecResult = WorkToolRunner.failMsg(output);
    r.schemaError = true;
    return r;
  }

  private static timeoutResult(name: string): ToolExecResult {
    let r: ToolExecResult = WorkToolRunner.failMsg('工具执行超时(超过 ' +
      Constants.WORK_TOOL_TIMEOUT_MS.toString() + ' ms): ' + name);
    r.timeout = true;
    return r;
  }

  private static abortedResult(name: string): ToolExecResult {
    let r: ToolExecResult = WorkToolRunner.failMsg('工具执行已取消: ' + name);
    r.cancelled = true;
    return r;
  }
}
