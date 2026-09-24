// DocxImporter: .docx -> Doc(结构化中间层), 供 read_docx / edit_docx 使用
// 两级策略:
//   1) 本应用导出的 docx 内嵌 docProps/doc.json 源文件, 直接还原(无损往返, 图片 src 仍是工作区相对路径);
//   2) 外来 docx(无内嵌源)按 word/document.xml 近似导入: 标题/正文/列表/表格/图片还原;
//      图片抽取到 imageOutDir(供 view_image 查看与再次 write_docx 引用), 属于近似导入, 保真度有限。
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Doc, DocBlock, DocListItem, DocParser } from './DocModel.ts';
import { Constants } from './Constants.ts';

export class DocxImportResult {
  doc: Doc = new Doc();
  embedded: boolean = false;    // 是否来自内嵌源(无损)
  blockCount: number = 0;
  images: string[] = [];        // 外来文档抽取出的图片相对路径(工作区视角)
}

export class DocxImporter {
  // 解包并导入; 失败抛 Error(信息面向 AI)
  // imageOutDir: 外来文档图片的落盘目录(绝对路径); imageOutRelBase: 该目录对应的工作区相对路径
  static async import(absPath: string, cacheDir: string, imageOutDir: string,
    imageOutRelBase: string): Promise<DocxImportResult> {
    let tempDir: string = await DocxImporter.unpack(absPath, cacheDir);
    try {
      // 1) 内嵌源优先
      let docPath: string = tempDir + '/docProps/doc.json';
      if (fileIo.accessSync(docPath)) {
        let json: string = DocxImporter.readUtf8(docPath, 8 * 1024 * 1024);
        let result: DocxImportResult = new DocxImportResult();
        try {
          result.doc = DocParser.parse(json);
        } catch (e) {
          // 内嵌源损坏时降级为 XML 导入
          result.doc = DocxImporter.importFromXml(tempDir, imageOutDir, imageOutRelBase, result.images);
        }
        result.embedded = true;
        result.blockCount = result.doc.blocks.length;
        return result;
      }
      // 2) 外来文件: XML 近似导入
      let result: DocxImportResult = new DocxImportResult();
      result.doc = DocxImporter.importFromXml(tempDir, imageOutDir, imageOutRelBase, result.images);
      result.embedded = false;
      result.blockCount = result.doc.blocks.length;
      return result;
    } finally {
      DocxImporter.deleteDirSync(tempDir);
    }
  }

  // ===== 外来 docx -> Doc =====

  private static importFromXml(tempDir: string, imageOutDir: string, imageOutRelBase: string,
    imagesOut: string[]): Doc {
    let docXmlPath: string = tempDir + '/word/document.xml';
    if (!fileIo.accessSync(docXmlPath)) {
      throw new Error('该 docx 中没有 word/document.xml(文件可能损坏)');
    }
    let docXml: string = DocxImporter.readUtf8(docXmlPath, 8 * 1024 * 1024);
    // 编号方案: numId -> 是否无序(bullet)
    let bulletNumIds: Map<string, boolean> = DocxImporter.parseNumbering(tempDir);
    // 关系: rId -> Target
    let rels: Map<string, string> = DocxImporter.parseRels(tempDir);
    // 图片去重缓存(媒体相对路径 -> 输出相对名)
    let imageCache: Map<string, string> = new Map<string, string>();

    let doc: Doc = new Doc();
    doc.title = '导入的 Word 文档';
    let firstHeading: string = '';
    // 顶层块切分(按出现顺序): 段落/表格
    let segments: DocxSegment[] = [];
    DocxImporter.splitBodyChildren(docXml, segments);
    // 连续列表项合并为一个 list 块
    let pendingList: DocBlock | null = null;
    for (let i: number = 0; i < segments.length; i++) {
      let seg: DocxSegment = segments[i];
      if (seg.tag === 'w:tbl') {
        pendingList = DocxImporter.flushList(pendingList, doc);
        let block: DocBlock | null = DocxImporter.parseTable(seg.body);
        if (block !== null) {
          doc.blocks.push(block);
        }
        continue;
      }
      // w:p
      let pinfo: DocxParaInfo = DocxImporter.parseParagraph(seg.body, tempDir, rels, bulletNumIds,
        imageOutDir, imageOutRelBase, imageCache, imagesOut);
      if (pinfo.listNumId !== '') {
        // 列表项: 与上一个列表同型(有序/无序)则并入, 否则新开
        if (pendingList === null || pendingList.ordered !== pinfo.ordered) {
          pendingList = DocxImporter.flushList(pendingList, doc);
          pendingList = new DocBlock();
          pendingList.type = 'list';
          pendingList.ordered = pinfo.ordered;
        }
        let li: DocListItem = new DocListItem();
        li.text = pinfo.text;
        li.level = pinfo.level;
        pendingList.items.push(li);
        continue;
      }
      pendingList = DocxImporter.flushList(pendingList, doc);
      if (pinfo.headingLevel > 0) {
        if (firstHeading === '') {
          firstHeading = pinfo.text;
        }
        let block: DocBlock = new DocBlock();
        block.type = 'heading';
        block.level = pinfo.headingLevel;
        block.text = pinfo.text;
        doc.blocks.push(block);
      } else if (pinfo.images.length > 0 && pinfo.text.trim() === '') {
        // 纯图片段: 每个图片一个 image 块
        for (let j: number = 0; j < pinfo.images.length; j++) {
          let block: DocBlock = new DocBlock();
          block.type = 'image';
          block.src = pinfo.images[j];
          doc.blocks.push(block);
        }
      } else {
        if (pinfo.text.trim() !== '') {
          let block: DocBlock = new DocBlock();
          block.type = 'paragraph';
          block.text = pinfo.text;
          doc.blocks.push(block);
        }
        for (let j: number = 0; j < pinfo.images.length; j++) {
          let block: DocBlock = new DocBlock();
          block.type = 'image';
          block.src = pinfo.images[j];
          doc.blocks.push(block);
        }
      }
    }
    pendingList = DocxImporter.flushList(pendingList, doc);
    if (doc.blocks.length === 0) {
      throw new Error('该 docx 中没有可识别的正文内容');
    }
    if (firstHeading !== '') {
      doc.title = firstHeading;
    }
    if (doc.blocks.length > Constants.WORK_DOC_MAX_BLOCKS) {
      doc.blocks.length = Constants.WORK_DOC_MAX_BLOCKS;
    }
    return doc;
  }

  private static flushList(pending: DocBlock | null, doc: Doc): DocBlock | null {
    if (pending !== null) {
      doc.blocks.push(pending);
    }
    return null;
  }

  // 顶层 body 子元素切分: 仅 w:p 与 w:tbl, 保持文档顺序; captureElement 负责跳过嵌套(表格内段落不误伤)
  private static splitBodyChildren(xml: string, out: DocxSegment[]): void {
    let bodyIdx: number = xml.indexOf('<w:body>');
    if (bodyIdx < 0) {
      DocxImporter.splitLooseParagraphs(xml, out);
      return;
    }
    let i: number = bodyIdx + '<w:body>'.length;
    let n: number = xml.length;
    while (i < n) {
      let lt: number = xml.indexOf('<', i);
      if (lt < 0) {
        break;
      }
      let gt: number = xml.indexOf('>', lt);
      if (gt < 0) {
        break;
      }
      let tagRaw: string = xml.substring(lt + 1, gt);
      if (tagRaw.charAt(0) === '?' || tagRaw.charAt(0) === '!') {
        i = gt + 1;
        continue;
      }
      if (tagRaw.charAt(0) === '/') {
        i = gt + 1;
        continue;
      }
      let selfClose: boolean = tagRaw.charAt(tagRaw.length - 1) === '/';
      if (selfClose) {
        i = gt + 1;
        continue;
      }
      let name: string = DocxImporter.tagName(tagRaw);
      if (name === 'w:p' || name === 'w:tbl') {
        let body: string = DocxImporter.captureElement(xml, lt, gt, name);
        let seg: DocxSegment = new DocxSegment();
        seg.tag = name;
        seg.body = body;
        out.push(seg);
        i = lt + body.length;
      } else {
        // 其他 body 级元素(w:sectPr 等)内部不含 w:p/w:tbl, 直接跳过
        i = gt + 1;
      }
    }
  }

  // 从开标签 '<' 处捕获元素完整 XML(含嵌套), 返回含开闭标签的完整片段
  private static captureElement(xml: string, openStart: number, openEnd: number, name: string): string {
    let depth: number = 1;
    let i: number = openEnd + 1;
    let n: number = xml.length;
    while (i < n) {
      let lt: number = xml.indexOf('<', i);
      if (lt < 0) {
        break;
      }
      let gt: number = xml.indexOf('>', lt);
      if (gt < 0) {
        break;
      }
      let tagRaw: string = xml.substring(lt + 1, gt);
      if (tagRaw.charAt(0) === '?' || tagRaw.charAt(0) === '!') {
        i = gt + 1;
        continue;
      }
      let selfClose: boolean = tagRaw.charAt(tagRaw.length - 1) === '/';
      if (selfClose) {
        i = gt + 1;
        continue;
      }
      if (tagRaw.charAt(0) === '/') {
        depth--;
        if (depth === 0) {
          return xml.substring(openStart, gt + 1);
        }
        i = gt + 1;
        continue;
      }
      depth++;
      i = gt + 1;
    }
    return xml.substring(openStart, n);
  }

  private static tagName(tagRaw: string): string {
    let name: string = '';
    let k: number = 0;
    while (k < tagRaw.length) {
      let ch: string = tagRaw.charAt(k);
      if (ch === ' ' || ch === '/' || ch === '>') {
        break;
      }
      name += ch;
      k++;
    }
    return name;
  }

  // 降级: 无 <w:body> 时按 <w:p> 顺序切分(忽略表格嵌套误差)
  private static splitLooseParagraphs(xml: string, out: DocxSegment[]): void {
    let pos: number = 0;
    while (true) {
      let pStart: number = xml.indexOf('<w:p>', pos);
      let tblStart: number = xml.indexOf('<w:tbl>', pos);
      if (pStart < 0 && tblStart < 0) {
        break;
      }
      if (tblStart >= 0 && (pStart < 0 || tblStart < pStart)) {
        let end: number = xml.indexOf('</w:tbl>', tblStart);
        if (end < 0) {
          break;
        }
        let seg: DocxSegment = new DocxSegment();
        seg.tag = 'w:tbl';
        seg.body = xml.substring(tblStart, end + '</w:tbl>'.length);
        out.push(seg);
        pos = end + '</w:tbl>'.length;
        continue;
      }
      let end: number = xml.indexOf('</w:p>', pStart);
      if (end < 0) {
        break;
      }
      let seg: DocxSegment = new DocxSegment();
      seg.tag = 'w:p';
      seg.body = xml.substring(pStart, end + '</w:p>'.length);
      out.push(seg);
      pos = end + '</w:p>'.length;
    }
  }

  // 单段落解析 -> 文本/标题级别/列表信息/图片引用
  private static parseParagraph(body: string, tempDir: string, rels: Map<string, string>,
    bulletNumIds: Map<string, boolean>, imageOutDir: string, imageOutRelBase: string,
    imageCache: Map<string, string>, imagesOut: string[]): DocxParaInfo {
    let info: DocxParaInfo = new DocxParaInfo();
    // 样式
    let pStyle: string = DocxImporter.attrOf(body, 'w:pStyle', 'w:val');
    if (pStyle.startsWith('Heading')) {
      let n: number = parseInt(pStyle.substring(7), 10);
      info.headingLevel = (!isNaN(n) && n >= 1 && n <= 6) ? n : 0;
    }
    // 列表
    let numId: string = DocxImporter.attrOf(body, 'w:numId', 'w:val');
    if (numId !== '') {
      info.listNumId = numId;
      info.ordered = !(bulletNumIds.get(numId) === true);
      let ilvl: string = DocxImporter.attrOf(body, 'w:ilvl', 'w:val');
      let lv: number = parseInt(ilvl, 10);
      info.level = (!isNaN(lv) && lv > 0) ? 1 : 0;
    }
    // 文本(含 w:tab -> 制表符)
    let texts: string[] = [];
    DocxImporter.collectParaText(body, texts);
    info.text = texts.join('').replace(/\u00A0/g, ' ').trim();
    // 图片
    let blipIds: string[] = [];
    DocxImporter.collectBlipRelIds(body, blipIds);
    for (let i: number = 0; i < blipIds.length && imagesOut.length < Constants.WORK_DOC_IMPORT_MAX_IMAGES; i++) {
      let rId: string = blipIds[i];
      let target: string | undefined = rels.get(rId);
      if (target === undefined) {
        continue;
      }
      let relPath: string = DocxImporter.wordMediaPath(target);
      if (relPath === '') {
        continue;
      }
      let cached: string | undefined = imageCache.get(relPath);
      if (cached !== undefined) {
        info.images.push(cached);
        continue;
      }
      let srcRel: string = DocxImporter.exportImage(tempDir, relPath, imageOutDir, imageOutRelBase,
        imageCache, imagesOut);
      if (srcRel !== '') {
        info.images.push(srcRel);
      }
    }
    return info;
  }

  // 从解包目录复制图片到输出目录; 返回工作区相对路径; 失败返回 ''
  // relPath 为 word/ 目录下的相对路径(如 media/image1.png)
  private static exportImage(tempDir: string, relPath: string, imageOutDir: string,
    imageOutRelBase: string, imageCache: Map<string, string>, imagesOut: string[]): string {
    let srcAbs: string = DocxImporter.joinDir(DocxImporter.joinDir(tempDir, 'word'), relPath);
    if (!fileIo.accessSync(srcAbs)) {
      return '';
    }
    let stat: fileIo.Stat = fileIo.statSync(srcAbs);
    if (stat.size <= 0 || stat.size > Constants.WORK_DOC_IMPORT_MAX_BYTES) {
      return '';
    }
    let slash: number = relPath.lastIndexOf('/');
    let baseName: string = slash >= 0 ? relPath.substring(slash + 1) : relPath;
    let ext: string = DocxImporter.extOfName(baseName);
    if (ext === '') {
      return '';
    }
    let data: Uint8Array = DocxImporter.readBytes(srcAbs, stat.size);
    let outName: string = 'image' + (imagesOut.length + 1).toString() + '.' + ext;
    if (!fileIo.accessSync(imageOutDir)) {
      fileIo.mkdirSync(imageOutDir, true);
    }
    DocxImporter.writeBytes(DocxImporter.joinDir(imageOutDir, outName), data);
    let srcRel: string = imageOutRelBase !== '' ? imageOutRelBase + '/' + outName : outName;
    imageCache.set(relPath, srcRel);
    imagesOut.push(srcRel);
    return srcRel;
  }

  // 关系 Target -> word 目录下的相对路径(word/media/xxx 或 media/xxx); 非图片返回 ''
  private static wordMediaPath(target: string): string {
    let t: string = target.replace(/\\/g, '/');
    if (t.startsWith('/')) {
      t = t.substring(1);
    }
    if (t.startsWith('word/media/')) {
      t = t.substring('word/'.length);
    }
    if (!t.startsWith('media/')) {
      return '';
    }
    let ext: string = DocxImporter.extOfName(t);
    return ext === '' ? '' : t;
  }

  private static extOfName(name: string): string {
    let dot: number = name.lastIndexOf('.');
    if (dot < 0) {
      return '';
    }
    let ext: string = name.substring(dot + 1).toLowerCase();
    if (ext === 'png' || ext === 'jpeg' || ext === 'jpg' || ext === 'gif' || ext === 'bmp') {
      return ext === 'jpg' ? 'jpeg' : ext;
    }
    return '';
  }

  // 解析 numbering.xml: numId -> 是否 bullet
  private static parseNumbering(tempDir: string): Map<string, boolean> {
    let map: Map<string, boolean> = new Map<string, boolean>();
    let path: string = tempDir + '/word/numbering.xml';
    if (!fileIo.accessSync(path)) {
      return map;
    }
    let xml: string = DocxImporter.readUtf8(path, 4 * 1024 * 1024);
    // numId -> abstractNumId
    let numToAbstract: Map<string, string> = new Map<string, string>();
    let nums: string[] = [];
    DocxImporter.splitTopLevel(xml, '<w:num ', '</w:num>', nums);
    for (let i: number = 0; i < nums.length; i++) {
      let gt: number = nums[i].indexOf('>');
      let tagSeg: string = gt >= 0 ? nums[i].substring(0, gt) : nums[i];
      let nid: string = DocxImporter.attrValue(tagSeg, 'w:numId');
      // abstractNumId 是 num 的子元素(<w:abstractNumId w:val="0"/>), 用元素属性读取
      let aid: string = DocxImporter.attrOf(nums[i], 'w:abstractNumId', 'w:val');
      if (nid !== '' && aid !== '') {
        numToAbstract.set(nid, aid);
      }
    }
    // abstractNumId -> 是否 bullet(看 ilvl 0 的 numFmt)
    let abstractBullet: Map<string, boolean> = new Map<string, boolean>();
    let abstracts: string[] = [];
    DocxImporter.splitTopLevel(xml, '<w:abstractNum ', '</w:abstractNum>', abstracts);
    for (let i: number = 0; i < abstracts.length; i++) {
      let gt: number = abstracts[i].indexOf('>');
      let tagSeg: string = gt >= 0 ? abstracts[i].substring(0, gt) : abstracts[i];
      let aid: string = DocxImporter.attrValue(tagSeg, 'w:abstractNumId');
      if (aid === '') {
        continue;
      }
      let fmt: string = DocxImporter.attrOf(abstracts[i], 'w:numFmt', 'w:val');
      abstractBullet.set(aid, fmt === 'bullet');
    }
    let keys: string[] = [];
    numToAbstract.forEach((_v: string, k: string): void => {
      keys.push(k);
    });
    for (let i: number = 0; i < keys.length; i++) {
      let nid: string = keys[i];
      let aid: string = numToAbstract.get(nid) as string;
      map.set(nid, abstractBullet.get(aid) === true);
    }
    return map;
  }

  // 解析 document.xml.rels: rId -> Target
  private static parseRels(tempDir: string): Map<string, string> {
    let map: Map<string, string> = new Map<string, string>();
    let path: string = tempDir + '/word/_rels/document.xml.rels';
    if (!fileIo.accessSync(path)) {
      return map;
    }
    let xml: string = DocxImporter.readUtf8(path, 4 * 1024 * 1024);
    let rels: string[] = [];
    DocxImporter.splitTopLevel(xml, '<Relationship ', '/>', rels);
    for (let i: number = 0; i < rels.length; i++) {
      let r: string = rels[i];
      let gt: number = r.indexOf('>');
      let tagSeg: string = gt >= 0 ? r.substring(0, gt) : r;
      let rid: string = DocxImporter.attrValue(tagSeg, 'Id');
      let target: string = DocxImporter.attrValue(tagSeg, 'Target');
      if (rid !== '' && target !== '') {
        map.set(rid, target);
      }
    }
    return map;
  }

  // <w:tbl> -> table 块(首行为表头)
  private static parseTable(body: string): DocBlock | null {
    let block: DocBlock = new DocBlock();
    block.type = 'table';
    let trs: string[] = [];
    DocxImporter.splitTopLevel(body, '<w:tr ', '</w:tr>', trs);
    if (trs.length === 0) {
      DocxImporter.splitTopLevel(body, '<w:tr>', '</w:tr>', trs);
    }
    let first: boolean = true;
    for (let r: number = 0; r < trs.length; r++) {
      let tcs: string[] = [];
      DocxImporter.splitTopLevel(trs[r], '<w:tc>', '</w:tc>', tcs);
      if (tcs.length === 0) {
        DocxImporter.splitTcWithAttrs(trs[r], tcs);
      }
      let row: string[] = [];
      for (let c: number = 0; c < tcs.length; c++) {
        let texts: string[] = [];
        DocxImporter.collectParaText(tcs[c], texts);
        row.push(texts.join('').replace(/\u00A0/g, ' ').trim());
      }
      if (row.length === 0) {
        continue;
      }
      if (first) {
        block.headers = row;
        first = false;
      } else {
        block.rows.push(row);
      }
    }
    if (block.headers.length === 0) {
      return null;
    }
    if (block.headers.length > Constants.WORK_DOC_TABLE_MAX_COLS) {
      block.headers.length = Constants.WORK_DOC_TABLE_MAX_COLS;
    }
    if (block.rows.length > Constants.WORK_DOC_TABLE_MAX_ROWS) {
      block.rows.length = Constants.WORK_DOC_TABLE_MAX_ROWS;
    }
    return block;
  }

  // ===== 基础工具 =====

  private static async unpack(absPath: string, tempRoot: string): Promise<string> {
    let tempDir: string = tempRoot + '/dim_' + Date.now().toString() + '_' +
      Math.floor(Math.random() * 10000).toString();
    if (!fileIo.accessSync(tempRoot)) {
      fileIo.mkdirSync(tempRoot, true);
    }
    if (fileIo.accessSync(tempDir)) {
      DocxImporter.deleteDirSync(tempDir);
    }
    fileIo.mkdirSync(tempDir, true);
    await zlib.decompressFile(absPath, tempDir);
    return tempDir;
  }

  private static readUtf8(absPath: string, maxBytes: number): string {
    let stat: fileIo.Stat = fileIo.statSync(absPath);
    let size: number = stat.size;
    if (size > maxBytes) {
      size = maxBytes;
    }
    let data: Uint8Array = DocxImporter.readBytes(absPath, size);
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(data, { stream: false });
  }

  private static readBytes(absPath: string, size: number): Uint8Array {
    let buffer: ArrayBuffer = new ArrayBuffer(size);
    let file: fileIo.File = fileIo.openSync(absPath, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0 });
    } finally {
      fileIo.closeSync(file.fd);
    }
    return new Uint8Array(buffer);
  }

  private static writeBytes(absPath: string, data: Uint8Array): void {
    let buffer: ArrayBuffer = data.buffer as ArrayBuffer;
    if (data.byteOffset !== 0 || data.byteLength !== buffer.byteLength) {
      buffer = data.slice().buffer as ArrayBuffer;
    }
    let file: fileIo.File = fileIo.openSync(absPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file.fd);
    }
  }

  // 段落内文本(含 <w:tab> -> 制表符)
  private static collectParaText(xml: string, out: string[]): void {
    let open: string = '<w:t';
    let pos: number = 0;
    while (true) {
      let start: number = xml.indexOf(open, pos);
      if (start < 0) {
        break;
      }
      let after: string = xml.charAt(start + open.length);
      if (!(after === '>' || after === ' ' || after === '\t' || after === '\n' || after === '\r')) {
        pos = start + open.length;
        continue;
      }
      let gt: number = xml.indexOf('>', start);
      if (gt < 0) {
        break;
      }
      if (xml.charAt(gt - 1) === '/') {
        pos = gt + 1;
        continue;
      }
      let end: number = xml.indexOf('</w:t>', gt + 1);
      if (end < 0) {
        break;
      }
      out.push(DocxImporter.decodeEntities(xml.substring(gt + 1, end)));
      pos = end + '</w:t>'.length;
    }
    let tabPos: number = 0;
    while (true) {
      let at: number = xml.indexOf('<w:tab/>', tabPos);
      if (at < 0) {
        break;
      }
      out.push('\t');
      tabPos = at + '<w:tab/>'.length;
    }
  }

  // 收集 <a:blip r:embed="rIdN"/> 的 rId
  private static collectBlipRelIds(xml: string, out: string[]): void {
    let key: string = 'r:embed="';
    let pos: number = 0;
    while (true) {
      let at: number = xml.indexOf(key, pos);
      if (at < 0) {
        break;
      }
      let start: number = at + key.length;
      let end: number = xml.indexOf('"', start);
      if (end < 0) {
        break;
      }
      let rid: string = xml.substring(start, end);
      if (rid !== '') {
        out.push(rid);
      }
      pos = end + 1;
    }
  }

  // 取 <tagAttr ... valAttr="值"> 中第一个匹配属性的值
  private static attrOf(xml: string, tagAttr: string, valAttr: string): string {
    let tagIdx: number = xml.indexOf('<' + tagAttr);
    if (tagIdx < 0) {
      return '';
    }
    let gt: number = xml.indexOf('>', tagIdx);
    if (gt < 0) {
      return '';
    }
    return DocxImporter.attrValue(xml.substring(tagIdx, gt), valAttr);
  }

  // 在标签片段(开标签到 '>' 之间)中取 name="值" 的属性值
  private static attrValue(tagSeg: string, name: string): string {
    let key: string = name + '="';
    let at: number = tagSeg.indexOf(key);
    if (at < 0) {
      return '';
    }
    let start: number = at + key.length;
    let end: number = tagSeg.indexOf('"', start);
    if (end < 0) {
      return '';
    }
    return tagSeg.substring(start, end);
  }

  // 按 begin/end 切分出片段(含 begin..end)
  private static splitTopLevel(xml: string, begin: string, end: string, out: string[]): void {
    let pos: number = 0;
    while (true) {
      let start: number = xml.indexOf(begin, pos);
      if (start < 0) {
        break;
      }
      let stop: number = xml.indexOf(end, start + begin.length);
      if (stop < 0) {
        break;
      }
      out.push(xml.substring(start, stop + end.length));
      pos = stop + end.length;
    }
  }

  // 带属性单元格切分: <w:tc ...>...</w:tc>
  private static splitTcWithAttrs(xml: string, out: string[]): void {
    let pos: number = 0;
    while (true) {
      let start: number = xml.indexOf('<w:tc ', pos);
      if (start < 0) {
        break;
      }
      let stop: number = xml.indexOf('</w:tc>', start);
      if (stop < 0) {
        break;
      }
      out.push(xml.substring(start, stop + '</w:tc>'.length));
      pos = stop + '</w:tc>'.length;
    }
  }

  private static decodeEntities(text: string): string {
    let out: string = text;
    if (out.indexOf('&') === -1) {
      return out;
    }
    out = out.replace(/&lt;/g, '<');
    out = out.replace(/&gt;/g, '>');
    out = out.replace(/&quot;/g, '"');
    out = out.replace(/&apos;/g, '\'');
    out = out.replace(/&#x([0-9A-Fa-f]+);/g, (_m: string, hex: string): string => {
      return String.fromCharCode(parseInt(hex, 16));
    });
    out = out.replace(/&#(\d+);/g, (_m: string, dec: string): string => {
      return String.fromCharCode(parseInt(dec, 10));
    });
    out = out.replace(/&amp;/g, '&');
    return out;
  }

  private static joinDir(a: string, b: string): string {
    if (a === '') {
      return b;
    }
    if (a.charAt(a.length - 1) === '/' || a.charAt(a.length - 1) === '\\') {
      return a + b;
    }
    return a + '/' + b;
  }

  private static deleteDirSync(abs: string): void {
    try {
      if (!fileIo.accessSync(abs)) {
        return;
      }
      let stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.isDirectory()) {
        let names: string[] = fileIo.listFileSync(abs);
        for (let i: number = 0; i < names.length; i++) {
          DocxImporter.deleteDirSync(abs + '/' + names[i]);
        }
        fileIo.rmdirSync(abs);
      } else {
        fileIo.unlinkSync(abs);
      }
    } catch (e) {
      // 清理失败不阻断主流程
    }
  }
}

class DocxSegment {
  tag: string = '';
  body: string = '';
}

class DocxParaInfo {
  text: string = '';
  headingLevel: number = 0;
  listNumId: string = '';
  ordered: boolean = false;
  level: number = 0;
  images: string[] = [];
}
