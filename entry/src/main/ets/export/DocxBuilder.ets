// DocxBuilder: Doc(结构化中间层) -> .docx 字节 (工作模式 write_docx 工具使用)
// 块类型: heading/paragraph/list/table/image/quote/code/divider/pagebreak + 封面/目录。
// 能力: 样式预设(default/academic/minimal)、分级标题(黑体加粗、字号递减)、正文 12pt 宋体 1.5 倍行距、
//       图片(工作区/data URL/http, 自动缩放至页宽)、表格(表头底色+边框)、引用/代码块/分隔线/分页。
// 设计: 全部使用 Word 内置样式(Heading1-6/Normal/Quote/CodeBlock…)而非内联格式,
//       导出文件内嵌 docProps/doc.json 源文件, read_docx/edit_docx 可无损还原。
// 行内文本经 InlineParser 解析: **粗体** *斜体* `代码` [链接](url) ![图](src) $公式$ ~~删除线~~。
import { XmlUtil } from './XmlUtil';
import { ZipWriter, ZipEntry } from './ZipWriter';
import { Doc, DocBlock, DocListItem, MdToDoc, DocStylePalette, DocStyleColors } from './DocModel';
import { InlineParser, InlineToken } from './MarkdownParser';
import { OmmlConverter } from './OmmlConverter';
import { Constants } from '../common/Constants';

// A4 页面(twips)与边距
const PAGE_W: number = 11906;
const PAGE_H: number = 16838;
const MARGIN: number = 1440;
const CONTENT_W: number = PAGE_W - MARGIN * 2; // 9026

// 内联图片最大像素宽(≈5.8 英寸, 与旧 OoxmlBuilder 一致)
const INLINE_IMG_MAX_PX: number = 550;

const XML_HEAD: string = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const NS_W: string = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const NS_R: string = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const NS_WP: string = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
const NS_A: string = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const NS_PIC: string = 'http://schemas.openxmlformats.org/drawingml/2006/picture';
const NS_M: string = 'http://schemas.openxmlformats.org/officeDocument/2006/math';

// 解析后的图片(二进制 + mime + 像素尺寸); 由注入的解析器产出
export class DocxImagePart {
  data: Uint8Array = new Uint8Array(0);
  mime: string = '';
  ext: string = 'png';
  widthPx: number = 0;
  heightPx: number = 0;
}

// 图片解析器: 由调用方注入(工作模式经 PptxImage 解析工作区/data URL/http + SVG 栅格化, 测试环境可注入桩)
export type DocImageResolver = (src: string) => Promise<DocxImagePart | null>;

// 图片部件(带 relId 与命名)
class DocxMediaPart {
  relId: string = '';
  name: string = '';
  data: Uint8Array = new Uint8Array(0);
  widthPx: number = 0;
  heightPx: number = 0;
}

// 超链接记录
class DocxHyperlink {
  relId: string = '';
  url: string = '';
}

export class DocxBuilder {
  private blocks: DocBlock[] = [];
  private mediaParts: DocxMediaPart[] = [];
  private mediaBySrc: Map<string, string> = new Map<string, string>(); // src -> relId
  private hyperlinks: DocxHyperlink[] = [];
  private hyperByUrl: Map<string, string> = new Map<string, string>(); // url -> relId
  private relCounter: number = 1;
  private drawIdCounter: number = 1;
  private palette: DocStyleColors = new DocStyleColors();

  // Doc -> docx 字节; 图片按需经 resolver 解析, 失败整篇报错(信息面向 AI)
  static async buildDocxBytes(doc: Doc, resolveImage: DocImageResolver): Promise<Uint8Array> {
    return DocxBuilder.buildDocx(doc, resolveImage);
  }

  // Markdown -> docx 字节(兼容旧 write_docx 入口; 行内/独立图片均支持工作区路径)
  static async buildFromMarkdown(markdown: string, title: string,
    resolveImage: DocImageResolver): Promise<Uint8Array> {
    let doc: Doc = MdToDoc.convert(markdown, title);
    return DocxBuilder.buildDocx(doc, resolveImage);
  }

  private static async buildDocx(doc: Doc, resolveImage: DocImageResolver): Promise<Uint8Array> {
    let builder: DocxBuilder = new DocxBuilder();
    builder.blocks = doc.blocks;
    builder.palette = DocStylePalette.of(doc.style);
    await builder.collectImages(resolveImage, doc);
    let entries: ZipEntry[] = [];
    entries.push(DocxBuilder.xmlEntry('[Content_Types].xml', builder.buildContentTypesXml()));
    entries.push(DocxBuilder.xmlEntry('_rels/.rels', builder.buildRootRelsXml()));
    entries.push(DocxBuilder.xmlEntry('docProps/core.xml', builder.buildCoreXml(doc)));
    entries.push(DocxBuilder.xmlEntry('docProps/app.xml', builder.buildAppXml()));
    // 内嵌 Doc 源: read_docx/edit_docx 的无损往返依赖它
    let docSource: ZipEntry = new ZipEntry();
    docSource.name = 'docProps/doc.json';
    docSource.data = DocxBuilder.stringToBytes(JSON.stringify(doc));
    entries.push(docSource);
    entries.push(DocxBuilder.xmlEntry('word/document.xml', builder.buildDocumentXml(doc)));
    entries.push(DocxBuilder.xmlEntry('word/styles.xml', builder.buildStylesXml(doc.style)));
    entries.push(DocxBuilder.xmlEntry('word/numbering.xml', builder.buildNumberingXml()));
    entries.push(DocxBuilder.xmlEntry('word/_rels/document.xml.rels', builder.buildDocumentRelsXml()));
    for (let i: number = 0; i < builder.mediaParts.length; i++) {
      let part: DocxMediaPart = builder.mediaParts[i];
      let e: ZipEntry = new ZipEntry();
      e.name = 'word/media/' + part.name;
      e.data = part.data;
      entries.push(e);
      if ((i + 1) % 8 === 0) {
        await DocxBuilder.yieldNow();
      }
    }
    return ZipWriter.create(entries);
  }

  // ===== 图片收集(第一遍) =====

  private async collectImages(resolveImage: DocImageResolver, doc: Doc): Promise<void> {
    // 收集去重后的 src(独立图片块 + 行内图片)
    let srcs: string[] = [];
    let seen: Map<string, boolean> = new Map<string, boolean>();
    for (let i: number = 0; i < this.blocks.length; i++) {
      let b: DocBlock = this.blocks[i];
      if (b.type === 'image' && b.src !== '') {
        if (!seen.has(b.src)) {
          seen.set(b.src, true);
          srcs.push(b.src);
        }
      }
      if (b.type === 'paragraph' || b.type === 'heading' || b.type === 'quote') {
        DocxBuilder.collectInlineImages(b.text, srcs, seen);
      }
      for (let j: number = 0; j < b.items.length; j++) {
        DocxBuilder.collectInlineImages(b.items[j].text, srcs, seen);
      }
      for (let j: number = 0; j < b.headers.length; j++) {
        DocxBuilder.collectInlineImages(b.headers[j], srcs, seen);
      }
      for (let r: number = 0; r < b.rows.length; r++) {
        for (let c: number = 0; c < b.rows[r].length; c++) {
          DocxBuilder.collectInlineImages(b.rows[r][c], srcs, seen);
        }
      }
    }
    for (let i: number = 0; i < srcs.length; i++) {
      let src: string = srcs[i];
      let part: DocxImagePart | null = null;
      try {
        part = await resolveImage(src);
      } catch (e) {
        part = null;
      }
      if (part === null) {
        throw new Error('图片无法加载: "' + src +
          '"。src 需是工作区已有的图片相对路径(可用 list_files 确认)、data URL 或可访问的 http(s) 链接');
      }
      if (part.data.length > Constants.WORK_DOC_IMAGE_MAX_BYTES) {
        throw new Error('图片超过 ' +
          Math.floor(Constants.WORK_DOC_IMAGE_MAX_BYTES / 1024 / 1024).toString() +
          'MB 上限: "' + src + '", 请先压缩');
      }
      if (this.mediaParts.length >= Constants.WORK_DOC_MAX_IMAGES) {
        throw new Error('整篇图片数超过 ' + Constants.WORK_DOC_MAX_IMAGES.toString() + ' 张上限');
      }
      let media: DocxMediaPart = new DocxMediaPart();
      media.relId = 'rId' + this.relCounter.toString();
      this.relCounter++;
      media.name = 'image' + this.mediaParts.length.toString() + '.' + part.ext;
      media.data = part.data;
      media.widthPx = part.widthPx;
      media.heightPx = part.heightPx;
      this.mediaParts.push(media);
      this.mediaBySrc.set(src, media.relId);
    }
  }

  private static collectInlineImages(text: string, srcs: string[], seen: Map<string, boolean>): void {
    let tokens: InlineToken[] = InlineParser.parse(text);
    for (let i: number = 0; i < tokens.length; i++) {
      let t: InlineToken = tokens[i];
      if (t.type === 'image' && t.text.trim() !== '') {
        let src: string = t.text.trim();
        if (!seen.has(src)) {
          seen.set(src, true);
          srcs.push(src);
        }
      }
    }
  }

  // ===== document.xml =====

  private buildDocumentXml(doc: Doc): string {
    let body: string = '';
    if (doc.cover) {
      body += this.buildCover(doc);
    }
    if (doc.toc) {
      body += this.buildToc();
    }
    for (let i: number = 0; i < this.blocks.length; i++) {
      body += this.renderBlock(this.blocks[i]);
    }
    body += '<w:sectPr><w:pgSz w:w="' + PAGE_W.toString() + '" w:h="' + PAGE_H.toString() + '"/>' +
      '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" ' +
      'w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>';
    return XML_HEAD + '<w:document xmlns:w="' + NS_W + '" xmlns:r="' + NS_R + '" xmlns:wp="' + NS_WP +
      '" xmlns:a="' + NS_A + '" xmlns:pic="' + NS_PIC + '" xmlns:m="' + NS_M + '">' +
      '<w:body>' + body + '</w:body></w:document>';
  }

  // 封面: 垂直留白 + 大标题 + 副标题 + 作者/日期, 后接分页
  private buildCover(doc: Doc): string {
    let out: string = '';
    out += '<w:p><w:pPr><w:spacing w:before="3600"/></w:pPr></w:p>';
    out += '<w:p><w:pPr><w:pStyle w:val="Title"/><w:jc w:val="center"/></w:pPr>' +
      this.renderInline(doc.title) + '</w:p>';
    if (doc.subtitle.trim() !== '') {
      out += '<w:p><w:pPr><w:pStyle w:val="Subtitle"/><w:jc w:val="center"/></w:pPr>' +
        this.renderInline(doc.subtitle) + '</w:p>';
    }
    let meta: string = '';
    if (doc.author.trim() !== '') {
      meta += doc.author.trim();
    }
    let dateText: string = doc.date.trim() !== '' ? doc.date.trim() : DocxBuilder.todayText();
    if (meta !== '') {
      meta += '　' + dateText;
    } else {
      meta = dateText;
    }
    out += '<w:p><w:pPr><w:spacing w:before="2400"/><w:jc w:val="center"/></w:pPr>' +
      '<w:r><w:rPr><w:color w:val="808080"/><w:sz w:val="24"/></w:rPr>' +
      '<w:t>' + XmlUtil.escape(meta) + '</w:t></w:r></w:p>';
    out += this.pageBreak();
    return out;
  }

  // 目录: Word TOC 域(打开后右键"更新域"生成目录)
  private buildToc(): string {
    let out: string = '';
    out += '<w:p><w:pPr><w:pStyle w:val="TOCHeading"/><w:jc w:val="center"/></w:pPr>' +
      '<w:r><w:t>目　录</w:t></w:r></w:p>';
    out += '<w:p><w:pPr><w:tabs><w:tab w:val="right" w:leader="dot" w:pos="9026"/></w:tabs></w:pPr>' +
      '<w:r><w:fldChar w:fldCharType="begin" w:dirty="true"/></w:r>' +
      '<w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\z \\u </w:instrText></w:r>' +
      '<w:r><w:fldChar w:fldCharType="separate"/></w:r>' +
      '<w:r><w:t>（打开文档后右键此处，选择"更新域"即可生成目录）</w:t></w:r>' +
      '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>';
    out += this.pageBreak();
    return out;
  }

  private pageBreak(): string {
    return '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';
  }

  private renderBlock(block: DocBlock): string {
    if (block.type === 'heading') {
      return '<w:p><w:pPr><w:pStyle w:val="Heading' + block.level.toString() + '"/>' +
        '<w:keepNext/></w:pPr>' + this.renderInline(block.text) + '</w:p>';
    }
    if (block.type === 'paragraph') {
      // 正文首行缩进 2 字符(中文排版惯例)
      return '<w:p><w:pPr><w:ind w:firstLineChars="200" w:firstLine="480"/>' +
        '<w:spacing w:after="120"/></w:pPr>' + this.renderInline(block.text) + '</w:p>';
    }
    if (block.type === 'list') {
      return this.renderList(block);
    }
    if (block.type === 'table') {
      return this.renderTable(block);
    }
    if (block.type === 'image') {
      return this.renderImageBlock(block);
    }
    if (block.type === 'quote') {
      let lines: string[] = block.text.split('\n');
      let out: string = '';
      for (let i: number = 0; i < lines.length; i++) {
        out += '<w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr>' + this.renderInline(lines[i]) + '</w:p>';
      }
      return out;
    }
    if (block.type === 'code') {
      return this.renderCodeBlock(block);
    }
    if (block.type === 'divider') {
      return '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="BFBFBF"/>' +
        '</w:pBdr><w:spacing w:before="60" w:after="60"/></w:pPr></w:p>';
    }
    if (block.type === 'pagebreak') {
      return this.pageBreak();
    }
    return '<w:p>' + this.renderInline(block.text) + '</w:p>';
  }

  private renderList(block: DocBlock): string {
    let numId: number = block.ordered ? 2 : 1;
    let out: string = '';
    for (let i: number = 0; i < block.items.length; i++) {
      let item: DocListItem = block.items[i];
      let ilvl: number = item.level < 0 ? 0 : item.level;
      if (ilvl > 1) {
        ilvl = 1;
      }
      out += '<w:p><w:pPr><w:pStyle w:val="ListParagraph"/>' +
        '<w:numPr><w:ilvl w:val="' + ilvl.toString() + '"/><w:numId w:val="' + numId.toString() + '"/></w:numPr>' +
        '<w:spacing w:after="60"/></w:pPr>' + this.renderInline(item.text) + '</w:p>';
    }
    return out;
  }

  private renderCodeBlock(block: DocBlock): string {
    let code: string = block.text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    let lines: string[] = code.split('\n');
    if (lines.length === 0) {
      lines = [''];
    }
    let out: string = '';
    for (let i: number = 0; i < lines.length; i++) {
      out += '<w:p><w:pPr><w:pStyle w:val="CodeBlock"/></w:pPr>' +
        '<w:r><w:rPr><w:rStyle w:val="CodeChar"/></w:rPr>' +
        '<w:t xml:space="preserve">' + XmlUtil.escape(lines[i]) + '</w:t></w:r></w:p>';
    }
    return out;
  }

  private renderTable(block: DocBlock): string {
    let colCount: number = block.headers.length;
    for (let r: number = 0; r < block.rows.length; r++) {
      if (block.rows[r].length > colCount) {
        colCount = block.rows[r].length;
      }
    }
    if (colCount === 0) {
      colCount = 1;
    }
    let colW: number = Math.floor(CONTENT_W / colCount);
    let grid: string = '';
    for (let c: number = 0; c < colCount; c++) {
      grid += '<w:gridCol w:w="' + colW.toString() + '"/>';
    }
    let out: string = '';
    if (block.caption.trim() !== '') {
      out += '<w:p><w:pPr><w:pStyle w:val="Caption"/><w:jc w:val="center"/></w:pPr>' +
        this.renderInline(block.caption) + '</w:p>';
    }
    out += '<w:tbl><w:tblPr><w:tblW w:w="' + CONTENT_W.toString() + '" w:type="dxa"/>' +
      '<w:tblBorders>' +
      '<w:top w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/>' +
      '<w:left w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/>' +
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/>' +
      '<w:right w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/>' +
      '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/>' +
      '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/>' +
      '</w:tblBorders>' +
      '<w:tblCellMar><w:top w:w="60" w:type="dxa"/><w:left w:w="100" w:type="dxa"/>' +
      '<w:bottom w:w="60" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar>' +
      '</w:tblPr><w:tblGrid>' + grid + '</w:tblGrid>';
    // 表头(主题色浅底 + 加粗)
    out += this.renderTableRow(block.headers, colCount, colW, true);
    // 数据行
    for (let r: number = 0; r < block.rows.length; r++) {
      out += this.renderTableRow(block.rows[r], colCount, colW, false);
    }
    out += '</w:tbl>';
    // 表后留一个空行, 避免与下段粘连
    out += '<w:p><w:pPr><w:spacing w:after="0"/></w:pPr></w:p>';
    return out;
  }

  private renderTableRow(cells: string[], colCount: number, colW: number, header: boolean): string {
    let xml: string = '<w:tr>';
    for (let c: number = 0; c < colCount; c++) {
      let cellText: string = c < cells.length ? cells[c] : '';
      let tcPr: string = '<w:tcPr><w:tcW w:w="' + colW.toString() + '" w:type="dxa"/>' +
        '<w:vAlign w:val="center"/>';
      if (header) {
        tcPr += '<w:shd w:val="clear" w:color="auto" w:fill="' + this.palette.tableFill + '"/>';
      }
      tcPr += '</w:tcPr>';
      let content: string = '<w:p><w:pPr><w:spacing w:before="20" w:after="20"/></w:pPr>' +
        this.renderInline(cellText, header) + '</w:p>';
      xml += '<w:tc>' + tcPr + content + '</w:tc>';
    }
    xml += '</w:tr>';
    return xml;
  }

  // 独立图片块: 居中 + 按页宽比例缩放 + 题注
  private renderImageBlock(block: DocBlock): string {
    let relId: string | undefined = this.mediaBySrc.get(block.src);
    if (relId === undefined) {
      return '';
    }
    let part: DocxMediaPart | null = this.findMedia(relId);
    if (part === null) {
      return '';
    }
    let size: number[] = this.blockImageSize(part, block.width);
    let cx: number = size[0];
    let cy: number = size[1];
    let drawId: number = this.drawIdCounter;
    this.drawIdCounter++;
    let out: string = '';
    out += '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:before="120" w:after="120"/></w:pPr>' +
      this.picRun(drawId, part.relId, cx, cy) + '</w:p>';
    if (block.caption.trim() !== '') {
      out += '<w:p><w:pPr><w:pStyle w:val="Caption"/><w:jc w:val="center"/></w:pPr>' +
        this.renderInline(block.caption) + '</w:p>';
    }
    return out;
  }

  // 计算独立图片的 EMU 尺寸: width 为页内容宽比例(0=按原始像素自适应)
  private blockImageSize(part: DocxMediaPart, width: number): number[] {
    let targetTwips: number = 0;
    if (width > 0) {
      targetTwips = Math.round(CONTENT_W * width);
    } else {
      targetTwips = part.widthPx * 15; // 96dpi: 1px = 15 twips
      if (targetTwips > CONTENT_W) {
        targetTwips = CONTENT_W;
      }
    }
    if (targetTwips < 300) {
      targetTwips = 300; // 最小可读宽度
    }
    let heightTwips: number = Math.round(targetTwips * part.heightPx / part.widthPx);
    // 防超高: 超过页面内容高(约 14000 twips)时按高限缩回
    if (heightTwips > 13900) {
      heightTwips = 13900;
      targetTwips = Math.round(heightTwips * part.widthPx / part.heightPx);
    }
    return [Math.round(targetTwips * 635), Math.round(heightTwips * 635)];
  }

  // ===== 行内渲染 =====

  private renderInline(text: string, forceBold: boolean = false): string {
    if (text === '') {
      return '';
    }
    let tokens: InlineToken[] = InlineParser.parse(text);
    let out: string = '';
    for (let i: number = 0; i < tokens.length; i++) {
      out += this.renderToken(tokens[i], forceBold);
    }
    return out;
  }

  private renderToken(token: InlineToken, forceBold: boolean): string {
    if (token.type === 'br') {
      return '<w:r><w:br/></w:r>';
    }
    if (token.type === 'math') {
      if (token.displayMath) {
        return '<w:r>' + OmmlConverter.display(token.text) + '</w:r>';
      }
      return '<w:r>' + OmmlConverter.inline(token.text) + '</w:r>';
    }
    if (token.type === 'link') {
      let relId: string = this.ensureHyperlink(token.href);
      if (relId === '') {
        return this.renderRun(token.text, token.bold, token.italic, token.strike, false, forceBold);
      }
      return '<w:hyperlink r:id="' + relId + '" w:history="1">' +
        this.renderInline(token.text, forceBold) + '</w:hyperlink>';
    }
    if (token.type === 'image') {
      return this.renderInlineImage(token);
    }
    // text
    return this.renderRun(token.text, token.bold, token.italic, token.strike, token.code, forceBold);
  }

  private renderRun(text: string, bold: boolean, italic: boolean, strike: boolean,
    code: boolean, forceBold: boolean): string {
    let rPr: string = '';
    if (code) {
      rPr += '<w:rStyle w:val="CodeChar"/>';
    }
    if (bold || forceBold) {
      rPr += '<w:b/><w:bCs/>';
    }
    if (italic) {
      rPr += '<w:i/><w:iCs/>';
    }
    if (strike) {
      rPr += '<w:strike/>';
    }
    let rPrXml: string = rPr === '' ? '' : '<w:rPr>' + rPr + '</w:rPr>';
    return '<w:r>' + rPrXml + '<w:t xml:space="preserve">' + XmlUtil.escape(text) + '</w:t></w:r>';
  }

  private ensureHyperlink(url: string): string {
    if (url === '') {
      return '';
    }
    if (this.hyperByUrl.has(url)) {
      return this.hyperByUrl.get(url) as string;
    }
    let rec: DocxHyperlink = new DocxHyperlink();
    rec.relId = 'rId' + this.relCounter.toString();
    this.relCounter++;
    rec.url = url;
    this.hyperlinks.push(rec);
    this.hyperByUrl.set(url, rec.relId);
    return rec.relId;
  }

  // 行内图片: 固定最大宽(≈5.8 英寸), 超宽等比缩放
  private renderInlineImage(token: InlineToken): string {
    let url: string = token.text.trim();
    let relId: string | undefined = this.mediaBySrc.get(url);
    if (relId === undefined) {
      let alt: string = token.alt !== '' ? token.alt : url;
      return this.renderRun(alt, false, true, false, false, false);
    }
    let part: DocxMediaPart | null = this.findMedia(relId);
    if (part === null) {
      return '';
    }
    let maxW: number = INLINE_IMG_MAX_PX;
    let w: number = part.widthPx;
    let h: number = part.heightPx;
    if (w > maxW) {
      h = Math.round(h * maxW / w);
      w = maxW;
    }
    let drawId: number = this.drawIdCounter;
    this.drawIdCounter++;
    return this.picRun(drawId, relId, Math.round(w * 9525), Math.round(h * 9525));
  }

  private picRun(drawId: number, relId: string, cx: number, cy: number): string {
    let picName: string = '图片' + drawId.toString();
    return '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">' +
      '<wp:extent cx="' + cx.toString() + '" cy="' + cy.toString() + '"/>' +
      '<wp:effectExtent l="0" t="0" r="0" b="0"/>' +
      '<wp:docPr id="' + drawId.toString() + '" name="' + picName + '"/>' +
      '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>' +
      '<a:graphic><a:graphicData uri="' + NS_PIC + '">' +
      '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="' + picName + '"/><pic:cNvPicPr/></pic:nvPicPr>' +
      '<pic:blipFill><a:blip r:embed="' + relId + '"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>' +
      '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="' + cx.toString() + '" cy="' + cy.toString() + '"/>' +
      '</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>' +
      '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';
  }

  private findMedia(relId: string): DocxMediaPart | null {
    for (let i: number = 0; i < this.mediaParts.length; i++) {
      if (this.mediaParts[i].relId === relId) {
        return this.mediaParts[i];
      }
    }
    return null;
  }

  // ===== styles.xml(排版核心: 正文字号/行距/标题分级都在这) =====

  private buildStylesXml(style: string): string {
    let palette: DocStyleColors = DocStylePalette.of(style);
    let styles: string = XML_HEAD + '<w:styles xmlns:w="' + NS_W + '">';
    styles += '<w:docDefaults><w:rPrDefault><w:rPr>' +
      '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="宋体" w:cs="Calibri"/>' +
      '<w:sz w:val="24"/><w:szCs w:val="24"/>' +
      '<w:lang w:val="en-US" w:eastAsia="zh-CN" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>' +
      '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="360" w:lineRule="auto"/>' +
      '</w:pPr></w:pPrDefault></w:docDefaults>';
    styles += '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">' +
      '<w:name w:val="Normal"/><w:qFormat/></w:style>';
    // 封面大标题
    styles += '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>' +
      '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:uiPriority w:val="10"/>' +
      '<w:pPr><w:spacing w:before="240" w:after="240"/><w:jc w:val="center"/></w:pPr>' +
      '<w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi" w:eastAsia="黑体"/>' +
      '<w:b/><w:bCs/><w:color w:val="' + palette.heading[0] + '"/>' +
      '<w:sz w:val="56"/><w:szCs w:val="56"/></w:rPr></w:style>';
    // 封面副标题
    styles += '<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/>' +
      '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:uiPriority w:val="11"/>' +
      '<w:pPr><w:spacing w:before="120" w:after="120"/><w:jc w:val="center"/></w:pPr>' +
      '<w:rPr><w:color w:val="595959"/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>';
    // 目录标题
    styles += '<w:style w:type="paragraph" w:styleId="TOCHeading"><w:name w:val="TOCHeading"/>' +
      '<w:basedOn w:val="Normal"/><w:qFormat/><w:uiPriority w:val="12"/>' +
      '<w:pPr><w:spacing w:before="240" w:after="240"/><w:jc w:val="center"/></w:pPr>' +
      '<w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi" w:eastAsia="黑体"/>' +
      '<w:b/><w:bCs/><w:color w:val="' + palette.heading[0] + '"/>' +
      '<w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>';
    // 标题分级: H1 22pt → H6 12pt, 黑体加粗, 字号递减保证区分度
    let headingSizes: string[] = ['44', '36', '32', '28', '26', '24'];
    for (let h: number = 1; h <= 6; h++) {
      styles += '<w:style w:type="paragraph" w:styleId="Heading' + h.toString() + '">' +
        '<w:name w:val="heading ' + h.toString() + '"/><w:basedOn w:val="Normal"/>' +
        '<w:next w:val="Normal"/><w:qFormat/><w:uiPriority w:val="9"/>' +
        '<w:pPr><w:keepNext/><w:keepLines/>' +
        '<w:spacing w:before="' + (h <= 2 ? '360' : '240').toString() + '" w:after="' +
        (h === 1 ? '200' : '120').toString() + '"/>' +
        '<w:outlineLvl w:val="' + (h - 1).toString() + '"/></w:pPr>' +
        '<w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi" w:eastAsia="黑体"/>' +
        '<w:b/><w:bCs/><w:color w:val="' + palette.heading[h - 1] + '"/>' +
        '<w:sz w:val="' + headingSizes[h - 1] + '"/><w:szCs w:val="' + headingSizes[h - 1] + '"/></w:rPr>' +
        '</w:style>';
    }
    // 题注(图表下方说明)
    styles += '<w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="Caption"/>' +
      '<w:basedOn w:val="Normal"/><w:qFormat/><w:uiPriority w:val="13"/>' +
      '<w:pPr><w:spacing w:before="60" w:after="120"/><w:jc w:val="center"/></w:pPr>' +
      '<w:rPr><w:color w:val="808080"/><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr></w:style>';
    // 引用
    styles += '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/>' +
      '<w:basedOn w:val="Normal"/><w:qFormat/><w:uiPriority w:val="15"/>' +
      '<w:pPr><w:spacing w:before="60" w:after="60"/><w:ind w:left="425"/>' +
      '<w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="9E9E9E"/></w:pBdr></w:pPr>' +
      '<w:rPr><w:color w:val="616161"/></w:rPr></w:style>';
    // 代码块段落
    styles += '<w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="CodeBlock"/>' +
      '<w:basedOn w:val="Normal"/><w:qFormat/><w:uiPriority w:val="16"/>' +
      '<w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>' +
      '<w:ind w:left="140" w:right="140"/>' +
      '<w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/></w:pPr></w:style>';
    // 列表段落
    styles += '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="ListParagraph"/>' +
      '<w:basedOn w:val="Normal"/><w:uiPriority w:val="17"/>' +
      '<w:pPr><w:ind w:left="567" w:hanging="283"/></w:pPr></w:style>';
    // 行内代码字符
    styles += '<w:style w:type="character" w:styleId="CodeChar"><w:name w:val="CodeChar"/>' +
      '<w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="19"/>' +
      '<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="宋体"/>' +
      '<w:sz w:val="21"/><w:szCs w:val="21"/><w:color w:val="C7254E"/>' +
      '<w:shd w:val="clear" w:color="auto" w:fill="F3EFF4"/></w:rPr></w:style>';
    // 超链接
    styles += '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>' +
      '<w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="20"/>' +
      '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>';
    styles += '</w:styles>';
    return styles;
  }

  // ===== numbering.xml(无序/有序两级列表) =====

  private buildNumberingXml(): string {
    return XML_HEAD + '<w:numbering xmlns:w="' + NS_W + '">' +
      '<w:abstractNum w:abstractNumId="0">' +
      '<w:multiLevelType w:val="hybridMultilevel"/>' +
      '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/>' +
      '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="567" w:hanging="283"/></w:pPr>' +
      '<w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/></w:rPr></w:lvl>' +
      '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="◦"/>' +
      '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="850" w:hanging="425"/></w:pPr>' +
      '<w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/></w:rPr></w:lvl>' +
      '</w:abstractNum>' +
      '<w:abstractNum w:abstractNumId="1">' +
      '<w:multiLevelType w:val="hybridMultilevel"/>' +
      '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/>' +
      '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="567" w:hanging="283"/></w:pPr></w:lvl>' +
      '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%2."/>' +
      '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="850" w:hanging="425"/></w:pPr></w:lvl>' +
      '</w:abstractNum>' +
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>' +
      '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>' +
      '</w:numbering>';
  }

  // ===== 包结构部件 =====

  private buildContentTypesXml(): string {
    return XML_HEAD + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Default Extension="png" ContentType="image/png"/>' +
      '<Default Extension="jpeg" ContentType="image/jpeg"/>' +
      '<Default Extension="gif" ContentType="image/gif"/>' +
      '<Default Extension="bmp" ContentType="image/bmp"/>' +
      '<Default Extension="svg" ContentType="image/svg+xml"/>' +
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>' +
      '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>' +
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' +
      '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>' +
      '</Types>';
  }

  private buildRootRelsXml(): string {
    return XML_HEAD + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>' +
      '</Relationships>';
  }

  private buildDocumentRelsXml(): string {
    let rels: string = XML_HEAD + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
      '<Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>';
    for (let i: number = 0; i < this.mediaParts.length; i++) {
      let part: DocxMediaPart = this.mediaParts[i];
      rels += '<Relationship Id="' + part.relId +
        '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' +
        part.name + '"/>';
    }
    for (let i: number = 0; i < this.hyperlinks.length; i++) {
      let rec: DocxHyperlink = this.hyperlinks[i];
      rels += '<Relationship Id="' + rec.relId +
        '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="' +
        XmlUtil.escapeAttr(rec.url) + '" TargetMode="External"/>';
    }
    rels += '</Relationships>';
    return rels;
  }

  private buildCoreXml(doc: Doc): string {
    let now: string = XmlUtil.isoDateTime();
    return XML_HEAD + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ' +
      'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
      '<dc:title>' + XmlUtil.escape(doc.title) + '</dc:title>' +
      '<dc:creator>' + XmlUtil.escape(doc.author !== '' ? doc.author : 'Guncat Work') + '</dc:creator>' +
      '<cp:lastModifiedBy>Guncat Work</cp:lastModifiedBy>' +
      '<dcterms:created xsi:type="dcterms:W3CDTF">' + now + '</dcterms:created>' +
      '<dcterms:modified xsi:type="dcterms:W3CDTF">' + now + '</dcterms:modified>' +
      '</cp:coreProperties>';
  }

  private buildAppXml(): string {
    return XML_HEAD + '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" ' +
      'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
      '<Application>Guncat Work</Application>' +
      '<DocSecurity>0</DocSecurity>' +
      '<ScaleCrop>false</ScaleCrop>' +
      '<LinksUpToDate>false</LinksUpToDate>' +
      '<SharedDoc>false</SharedDoc>' +
      '<HyperlinksChanged>false</HyperlinksChanged>' +
      '<AppVersion>16.0000</AppVersion>' +
      '</Properties>';
  }

  // ===== 工具 =====

  private static xmlEntry(name: string, xml: string): ZipEntry {
    let e: ZipEntry = new ZipEntry();
    e.name = name;
    e.data = DocxBuilder.stringToBytes(xml);
    return e;
  }

  private static todayText(): string {
    let d: Date = new Date();
    let p: (n: number) => string = (n: number): string => {
      return n < 10 ? '0' + n.toString() : n.toString();
    };
    return d.getFullYear().toString() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }

  private static yieldNow(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 0);
    });
  }

  // UTF-8 编码(含代理对), 与 DocxExporter 保持一致
  static stringToBytes(text: string): Uint8Array {
    let bytes: Uint8Array = new Uint8Array(text.length * 3);
    let count: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      let code: number = text.charCodeAt(i);
      if (code < 0x80) {
        bytes[count] = code;
        count++;
      } else if (code < 0x800) {
        bytes[count] = 0xC0 | (code >> 6);
        bytes[count + 1] = 0x80 | (code & 0x3F);
        count += 2;
      } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        let low: number = text.charCodeAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          let cp: number = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
          bytes[count] = 0xF0 | (cp >> 18);
          bytes[count + 1] = 0x80 | ((cp >> 12) & 0x3F);
          bytes[count + 2] = 0x80 | ((cp >> 6) & 0x3F);
          bytes[count + 3] = 0x80 | (cp & 0x3F);
          count += 4;
          i++;
        } else {
          bytes[count] = 0xEF;
          bytes[count + 1] = 0xBF;
          bytes[count + 2] = 0xBD;
          count += 3;
        }
      } else {
        bytes[count] = 0xE0 | (code >> 12);
        bytes[count + 1] = 0x80 | ((code >> 6) & 0x3F);
        bytes[count + 2] = 0x80 | (code & 0x3F);
        count += 3;
      }
    }
    let result: Uint8Array = new Uint8Array(count);
    result.set(bytes.subarray(0, count));
    return result;
  }
}
