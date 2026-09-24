// PdfTextExtractor: 基于 HarmonyOS 系统 PDF Kit(@kit.PDFKit) 的 PDF 文本抽取/搜索/转图
// 文本: PdfDocument.loadDocument(沙箱绝对路径, 同步) → 逐页 PdfPage.getTextContent()
//   (getTextContent 为 API 23(6.1.0) 新增接口, 一次取整页文本, 由系统引擎处理 ObjStm/
//   XRef Stream/加密/字体 CMap 等全部结构); 某页为空时用 getGraphicsObjects() 按版面顺序兜底。
// 搜索: PdfDocument.searchKey(API 21 新增) 原生全文检索, 返回页码+上下文; 原生不可用或
//   无结果时逐页取文字层文本做大小写不敏感子串扫描兜底。
// 分段: extractPages 支持按页区间提取, 供超长 PDF 分批读取(每次调用重新 loadDocument,
//   开销可接受, 换取调用无状态)。
// 转图: renderPages 按页区间把页面渲染为 jpg(getAreaPixelMapWithOptions 控制分辨率,
//   API 18+; 失败时退化 getPagePixelMap), 供扫描件走 view_image 多模态查看。
// 限制: 加密文档(无密码)返回 PARSE_ERROR_PASSWORD; 扫描件(纯图片)无文字层, 文本返回空。
// 性能: loadDocument/getTextContent 为同步原生调用(无法内部让出), 页间 await 让出主线程
//   防止多页大文档触发 watchdog(THREAD_BLOCK)。
import { pdfService } from '@kit.PDFKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

// 分页提取结果: 页码均为 1-based
export class PdfPagesResult {
  pageCount: number = 0;      // 文档总页数
  startPage: number = 0;      // 本次提取起始页
  endPage: number = 0;        // 本次提取末页(0 表示未提取到任何页)
  nextStartPage: number = 0;  // 建议的下一批起始页(0 表示已到末页)
  pages: string[] = [];       // 与 startPage..endPage 一一对应的各页文本
}

// 单条搜索命中
export class PdfSearchHit {
  pageIndex: number = 0; // 1-based 页码
  context: string = '';  // 命中处上下文摘录
}

// 页面转图结果: 页码均为 1-based
export class PdfRenderResult {
  pageCount: number = 0;      // 文档总页数
  startPage: number = 0;      // 本次渲染起始页
  endPage: number = 0;        // 本次渲染末页(0 表示未渲染出任何页)
  nextStartPage: number = 0;  // 建议的下一批起始页(0 表示已到末页)
  files: string[] = [];       // 生成的图片绝对路径(与页码顺序一致)
}

export class PdfTextExtractor {
  // 整文提取(read_file 快捷路径): 返回前 maxChars 字符量的页面文本; 失败抛 Error。
  static async extractText(absPath: string, maxChars: number): Promise<string> {
    let r: PdfPagesResult = await PdfTextExtractor.extractPages(absPath, 1, 1000000, maxChars);
    let texts: string[] = [];
    for (let i: number = 0; i < r.pages.length; i++) {
      if (r.pages[i] !== '') {
        texts.push(r.pages[i]);
      }
    }
    if (texts.length === 0) {
      return '(未能从该 PDF 提取到文本: 可能是扫描件/纯图片 PDF, 或文档无文字层; ' +
        '可用 pdf_to_images 转成图片后用 view_image 逐页查看)';
    }
    let out: string = texts.join('\n');
    if (out.length > maxChars) {
      out = out.substring(0, maxChars) +
        '\n...(内容过长已截断; 可用 parse_document 带 page 参数分页提取全文)';
    }
    return out;
  }

  // 分页提取: 从 startPage(1-based) 起最多 maxPages 页, 累计文本达 maxChars 提前停止。
  // 起始页超出范围时返回 pages 为空(由调用方提示), 加密/损坏抛 Error。
  static async extractPages(absPath: string, startPage: number, maxPages: number,
    maxChars: number): Promise<PdfPagesResult> {
    let result: PdfPagesResult = new PdfPagesResult();
    let doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    let loaded: boolean = false;
    try {
      let pr: pdfService.ParseResult = pdfService.ParseResult.PARSE_ERROR_HANDLER;
      try {
        pr = doc.loadDocument(absPath);
      } catch (e) {
        throw new Error('PDF 加载异常: ' + PdfTextExtractor.errMessage(e as Object));
      }
      if (pr !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error(PdfTextExtractor.parseResultMessage(pr));
      }
      loaded = true;
      result.pageCount = doc.getPageCount();
      let s: number = startPage < 1 ? 1 : startPage;
      result.startPage = s;
      if (result.pageCount <= 0 || s > result.pageCount) {
        return result;
      }
      let produced: number = 0;
      for (let i: number = s - 1; i < result.pageCount && i < s - 1 + maxPages; i++) {
        let page: pdfService.PdfPage = doc.getPage(i);
        let text: string = PdfTextExtractor.pageText(page);
        page.release();
        if (text.length > maxChars) {
          text = text.substring(0, maxChars) + '...(单页过长已截断)';
        }
        result.pages.push(text);
        produced += text.length;
        result.endPage = i + 1;
        if (produced >= maxChars) {
          break;
        }
        // 页间让出主线程一轮事件循环, 避免长解析冻结
        await PdfTextExtractor.yieldNow();
      }
      result.nextStartPage = (result.endPage > 0 && result.endPage < result.pageCount)
        ? result.endPage + 1 : 0;
    } finally {
      if (loaded) {
        doc.releaseDocument();
      }
    }
    return result;
  }

  // 全文搜索: 优先系统 searchKey(API 21+); 不可用或无结果时逐页子串扫描兜底。
  // 返回至多 maxMatches 条命中(1-based 页码 + 上下文摘录); 加密/损坏抛 Error。
  static async searchText(absPath: string, keyword: string, maxMatches: number): Promise<PdfSearchHit[]> {
    let hits: PdfSearchHit[] = [];
    if (keyword === '') {
      return hits;
    }
    let doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    let loaded: boolean = false;
    try {
      let pr: pdfService.ParseResult = pdfService.ParseResult.PARSE_ERROR_HANDLER;
      try {
        pr = doc.loadDocument(absPath);
      } catch (e) {
        throw new Error('PDF 加载异常: ' + PdfTextExtractor.errMessage(e as Object));
      }
      if (pr !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error(PdfTextExtractor.parseResultMessage(pr));
      }
      loaded = true;
      try {
        let options: pdfService.SearchOptions = { isMatchCase: false, contextStringLength: 120 };
        let listener: pdfService.SearchKeyCallback =
          (results: pdfService.SearchResultData[]): boolean => {
            for (let i: number = 0; i < results.length && hits.length < maxMatches; i++) {
              let hit: PdfSearchHit = new PdfSearchHit();
              hit.pageIndex = results[i].pageIndex + 1;
              hit.context = results[i].contextString.replace(/\s+/g, ' ').trim();
              hits.push(hit);
            }
            // true 终止后续页的搜索
            return hits.length >= maxMatches;
          };
        await doc.searchKey(keyword, listener, options);
      } catch (e) {
        hits = [];
      }
      if (hits.length === 0) {
        await PdfTextExtractor.fallbackSearch(doc, keyword, maxMatches, hits);
      }
    } finally {
      if (loaded) {
        doc.releaseDocument();
      }
    }
    return hits;
  }

  // 兜底搜索: 逐页取文字层文本, 大小写不敏感子串扫描; 单页至多 20 处避免超长页刷屏
  private static async fallbackSearch(doc: pdfService.PdfDocument, keyword: string,
    maxMatches: number, hits: PdfSearchHit[]): Promise<void> {
    const perPageLimit: number = 20;
    let lowerKey: string = keyword.toLowerCase();
    let pageCount: number = doc.getPageCount();
    for (let p: number = 0; p < pageCount && hits.length < maxMatches; p++) {
      let page: pdfService.PdfPage = doc.getPage(p);
      let text: string = PdfTextExtractor.pageText(page);
      page.release();
      if (text === '') {
        continue;
      }
      let lowerText: string = text.toLowerCase();
      let from: number = 0;
      let inPage: number = 0;
      while (hits.length < maxMatches && inPage < perPageLimit) {
        let idx: number = lowerText.indexOf(lowerKey, from);
        if (idx < 0) {
          break;
        }
        let ctxStart: number = idx > 48 ? idx - 48 : 0;
        let ctxEnd: number = idx + lowerKey.length + 96;
        if (ctxEnd > text.length) {
          ctxEnd = text.length;
        }
        let hit: PdfSearchHit = new PdfSearchHit();
        hit.pageIndex = p + 1;
        hit.context = (ctxStart > 0 ? '...' : '') +
          text.substring(ctxStart, ctxEnd).replace(/\s+/g, ' ').trim() +
          (ctxEnd < text.length ? '...' : '');
        hits.push(hit);
        inPage++;
        from = idx + lowerKey.length;
      }
      await PdfTextExtractor.yieldNow();
    }
  }

  // 页面转图: 从 startPage(1-based) 起最多 maxPages 页, 输出 outDir/p001.jpg...;
  // 返回生成文件列表与下一批提示; 加密/损坏抛 Error, 单页失败跳过。
  static async renderPages(absPath: string, startPage: number, maxPages: number,
    outDir: string): Promise<PdfRenderResult> {
    let result: PdfRenderResult = new PdfRenderResult();
    let doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    let loaded: boolean = false;
    try {
      let pr: pdfService.ParseResult = pdfService.ParseResult.PARSE_ERROR_HANDLER;
      try {
        pr = doc.loadDocument(absPath);
      } catch (e) {
        throw new Error('PDF 加载异常: ' + PdfTextExtractor.errMessage(e as Object));
      }
      if (pr !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error(PdfTextExtractor.parseResultMessage(pr));
      }
      loaded = true;
      result.pageCount = doc.getPageCount();
      let s: number = startPage < 1 ? 1 : startPage;
      result.startPage = s;
      if (result.pageCount <= 0 || s > result.pageCount) {
        return result;
      }
      if (!fileIo.accessSync(outDir)) {
        fileIo.mkdirSync(outDir, true);
      }
      let packer: image.ImagePacker = image.createImagePacker();
      for (let i: number = s - 1; i < result.pageCount && i < s - 1 + maxPages; i++) {
        let page: pdfService.PdfPage = doc.getPage(i);
        let outFile: string = outDir + '/p' + PdfTextExtractor.pad3(i + 1) + '.jpg';
        let done: boolean = await PdfTextExtractor.renderOnePage(page, packer, outFile);
        page.release();
        if (done) {
          result.files.push(outFile);
          result.endPage = i + 1;
        }
        // 页间让出主线程, 避免连续渲染冻结
        await PdfTextExtractor.yieldNow();
      }
      try {
        await packer.release();
      } catch (e) {
        // 释放失败不影响结果
      }
      result.nextStartPage = (result.endPage > 0 && result.endPage < result.pageCount)
        ? result.endPage + 1 : 0;
    } finally {
      if (loaded) {
        doc.releaseDocument();
      }
    }
    return result;
  }

  // 单页渲染 → jpg 落盘: 约 2 倍页面尺寸(≈144dpi), 上限 2000px;
  // getAreaPixelMapWithOptions 失败时退化 getPagePixelMap(系统默认分辨率)。
  private static async renderOnePage(page: pdfService.PdfPage, packer: image.ImagePacker,
    outFile: string): Promise<boolean> {
    let pm: image.PixelMap | null = null;
    let file: fileIo.File | null = null;
    try {
      let pw: number = page.getWidth();
      let ph: number = page.getHeight();
      let targetW: number = Math.round(pw * 2);
      if (targetW < 720) {
        targetW = 720;
      } else if (targetW > 2000) {
        targetW = 2000;
      }
      let targetH: number = pw > 0 ? Math.round(targetW * ph / pw) : targetW;
      let matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix();
      matrix.x = 0;
      matrix.y = 0;
      matrix.width = pw;
      matrix.height = ph;
      matrix.rotate = 0;
      try {
        pm = page.getAreaPixelMapWithOptions(matrix, targetW, targetH);
      } catch (e) {
        pm = page.getPagePixelMap();
      }
      if (pm === null) {
        return false;
      }
      let opt: image.PackingOption = { format: 'image/jpeg', quality: 88 };
      file = fileIo.openSync(outFile,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await packer.packToFile(pm, file.fd, opt);
      return true;
    } catch (e) {
      return false;
    } finally {
      if (pm !== null) {
        try {
          pm.release();
        } catch (e) {
          // 忽略释放失败
        }
      }
      if (file !== null) {
        try {
          fileIo.closeSync(file.fd);
        } catch (e) {
          // 忽略关闭失败
        }
      }
    }
  }

  // 页码补零: 1 → '001'(文件名排序与页码一致)
  private static pad3(n: number): string {
    let s: string = n.toString();
    while (s.length < 3) {
      s = '0' + s;
    }
    return s;
  }

  // 单页文本: getTextContent 优先, 为空时用版面对象兜底
  private static pageText(page: pdfService.PdfPage): string {
    let text: string = '';
    try {
      text = page.getTextContent();
    } catch (e) {
      text = '';
    }
    text = PdfTextExtractor.normalize(text);
    if (text === '') {
      text = PdfTextExtractor.graphicsFallback(page);
    }
    return text;
  }

  // 版面对象兜底: 按 getGraphicsObjects 的版面顺序(左→右, 上→下)拼接 TextObject.text;
  // y(距页底距离)明显变化视为换行, 同行对象间水平留白超一个字宽补空格。
  private static graphicsFallback(page: pdfService.PdfPage): string {
    let objects: pdfService.GraphicsObject[] = [];
    try {
      objects = page.getGraphicsObjects();
    } catch (e) {
      return '';
    }
    let current: string = '';
    let prevY: number = Number.NaN;
    let prevRight: number = Number.NaN;
    for (let i: number = 0; i < objects.length; i++) {
      let obj: pdfService.GraphicsObject = objects[i];
      if (obj.type !== pdfService.GraphicsObjectType.OBJECT_TEXT) {
        continue;
      }
      let textObj: pdfService.TextObject = obj as pdfService.TextObject;
      let text: string = textObj.text;
      if (text === '') {
        continue;
      }
      if (!isNaN(prevY) && Math.abs(textObj.y - prevY) > 2) {
        current = current + '\n';
        prevRight = Number.NaN;
      } else if (!isNaN(prevRight) && textObj.x > prevRight + 1) {
        current = current + ' ';
      }
      current = current + text;
      prevY = textObj.y;
      // charRects 为逐字符矩形, 末字符右缘即对象右缘
      let rects: pdfService.PdfRect[] = textObj.charRects;
      if (rects.length > 0) {
        prevRight = rects[rects.length - 1].right;
      }
    }
    return PdfTextExtractor.normalize(current);
  }

  // 规范化: 统一换行, 去行尾空白, 压缩连续空行
  private static normalize(s: string): string {
    return s.replace(/\r\n?/g, '\n')
      .replace(/[ \t]+$/gm, '')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  private static parseResultMessage(result: pdfService.ParseResult): string {
    if (result === pdfService.ParseResult.PARSE_ERROR_FILE) {
      return '文件读取失败或不是有效的 PDF';
    }
    if (result === pdfService.ParseResult.PARSE_ERROR_FORMAT) {
      return 'PDF 格式解析失败(文档结构损坏)';
    }
    if (result === pdfService.ParseResult.PARSE_ERROR_PASSWORD) {
      return '该 PDF 已加密, 暂无法解析';
    }
    if (result === pdfService.ParseResult.PARSE_ERROR_CERT) {
      return 'PDF 证书校验失败';
    }
    return 'PDF 服务内部错误(码 ' + result.toString() + ')';
  }

  private static errMessage(e: Object): string {
    let err: Error = e as Error;
    if (err !== undefined && err.message !== undefined && err.message !== '') {
      return err.message;
    }
    return String(e);
  }

  // 让出主线程一轮事件循环
  private static yieldNow(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 0);
    });
  }
}
