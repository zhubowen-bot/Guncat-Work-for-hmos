// PptxBuilder: Deck(结构化中间层) -> .pptx 字节 (工作模式 write_pptx 工具使用)
// 版式: cover/toc/section/content/two-col/image-text/image/image-full/table/chart/quote/end/custom
// 能力: 主题预设与覆盖、图表(bar/line/area/pie/doughnut)、表格、图片(工作区/data URL/http)、
//       演讲备注、页面背景(纯色/图+遮罩)、custom 绝对定位元素。
// 设计: 每页为独立文本框/图形(不依赖占位符继承), WPS/PowerPoint 均可打开;
//       导出的 pptx 内嵌 docProps/deck.json 源文件, read_ppt/edit_ppt 可无损还原。
import { XmlUtil } from './XmlUtil';
import { ZipWriter, ZipEntry } from './ZipWriter';
import { Deck, DeckSlide, DeckBullet, DeckElement, DeckTable, DECK_MAX_SLIDES } from './DeckModel';
import { PptxThemes, ThemeColors } from './PptxThemes';
import { PptxCharts } from './PptxCharts';
import { Constants } from '../common/Constants';

// 16:9 画布 (EMU)
const SLIDE_W: number = 12192000;
const SLIDE_H: number = 6858000;
const MARGIN_X: number = 900000;
const ACCENT_H: number = 76200;
const TITLE_Y: number = 480000;
const TITLE_H: number = 1000000;
const UNDERLINE_Y: number = 1560000;
const BODY_Y: number = 1800000;
const BODY_H: number = 4500000;
const FOOTER_Y: number = SLIDE_H - 430000;

// XML 声明与命名空间前缀
const XML_HEAD: string = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const NS_A: string = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"';
const NS_R: string = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
const NS_P: string = 'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';

// 解析后的图片(二进制 + mime + 像素尺寸); 由 PptxImage 产出
export class PptxImagePart {
  data: Uint8Array = new Uint8Array(0);
  mime: string = '';
  ext: string = 'png';
  widthPx: number = 0;
  heightPx: number = 0;
}

// 图片解析器: 由调用方注入(工作模式经 PptxImage 解析工作区/data URL/http, 测试环境可注入桩)
export type ImageResolver = (src: string) => Promise<PptxImagePart | null>;

// 单页渲染上下文: 关系 id 计数 + 部件收集
class SlideContext {
  index: number = 0;               // 0 基页序
  relId: number = 1;               // rId1 固定为 slideLayout
  layoutRels: string = '';         // 除 layout 外的关系条目
  mediaParts: PptxImagePart[] = [];   // 本页图片部件(顺序对应分配的 relId)
  chartXmls: string[] = [];           // 本页图表 part
  chartNos: number[] = [];            // 图表的全局编号(与 contentTypes 一致)
  chartColors: ThemeColors = new ThemeColors(); // 图表配色(深色底时文字反白, 色板不变)
  hasNotes: boolean = false;
  notes: string = '';

  nextRel(): string {
    this.relId++;
    return 'rId' + this.relId.toString();
  }
}

// 页面文字方案: 深色背景时自动反白, 保证对比度
class TextScheme {
  title: string = '1B2330';
  body: string = '333F50';
  sub: string = '6B7280';
  faint: string = '9AA3AF';
}

export class PptxBuilder {
  // Deck -> pptx 字节; 图片按需经 resolver 解析, 失败整册报错(信息面向 AI)
  static async buildPptxBytes(deck: Deck, resolveImage: ImageResolver): Promise<Uint8Array> {
    let colors: ThemeColors = PptxThemes.resolve(deck);
    let imageCache: Map<string, PptxImagePart> = new Map();
    let contexts: SlideContext[] = [];
    let chartCount: number = 0;

    // ===== 第一遍: 解析全部图片 + 预建每页上下文 =====
    for (let i: number = 0; i < deck.slides.length && i < DECK_MAX_SLIDES; i++) {
      let ctx: SlideContext = new SlideContext();
      ctx.index = i;
      let slide: DeckSlide = deck.slides[i];
      let srcs: string[] = PptxBuilder.slideImageSrcs(slide);
      for (let s: number = 0; s < srcs.length; s++) {
        let src: string = srcs[s];
        let part: PptxImagePart | null = imageCache.get(src) === undefined ? null : imageCache.get(src) as PptxImagePart;
        if (part === null) {
          try {
            part = await resolveImage(src);
          } catch (e) {
            part = null;
          }
          if (part === null) {
            throw new Error('第 ' + (i + 1).toString() + ' 页图片无法加载: "' + src +
              '"。src 需是工作区已有的图片相对路径(可用 list_files 确认)、data URL 或可访问的 http(s) 链接');
          }
          if (part.data.length > Constants.WORK_PPT_IMAGE_MAX_BYTES) {
            throw new Error('第 ' + (i + 1).toString() + ' 页图片超过 ' +
              Math.floor(Constants.WORK_PPT_IMAGE_MAX_BYTES / 1024 / 1024).toString() +
              'MB 上限: "' + src + '", 请先压缩');
          }
          if (imageCache.size >= Constants.WORK_PPT_MAX_IMAGES) {
            throw new Error('整册图片数超过 ' + Constants.WORK_PPT_MAX_IMAGES.toString() + ' 张上限');
          }
          imageCache.set(src, part);
        }
        ctx.mediaParts.push(part);
      }
      // 图表 part(全局编号在此分配, 与 contentTypes/rels 共用); 深色底页图表文字反白
      if (slide.layout === 'chart') {
        chartCount++;
        ctx.chartColors = PptxBuilder.isDarkBg(slide, colors) ? PptxBuilder.lightened(colors) : colors;
        ctx.chartXmls.push(PptxCharts.buildXml(slide.chart, ctx.chartColors));
        ctx.chartNos.push(chartCount);
      }
      if (slide.notes.trim() !== '') {
        ctx.hasNotes = true;
        ctx.notes = slide.notes.trim();
      }
      contexts.push(ctx);
    }

    // ===== 第二遍: 逐页渲染 =====
    let entries: ZipEntry[] = [];
    let slideCount: number = deck.slides.length;
    entries.push(PptxBuilder.xmlEntry('[Content_Types].xml',
      PptxBuilder.contentTypesXml(slideCount, contexts)));
    entries.push(PptxBuilder.xmlEntry('_rels/.rels', PptxBuilder.rootRelsXml()));
    entries.push(PptxBuilder.xmlEntry('docProps/core.xml', PptxBuilder.coreXml(deck.title)));
    entries.push(PptxBuilder.xmlEntry('docProps/app.xml', PptxBuilder.appXml(slideCount)));
    // 内嵌 Deck 源: read_ppt/edit_ppt 的无损往返依赖它
    let deckSource: ZipEntry = new ZipEntry();
    deckSource.name = 'docProps/deck.json';
    deckSource.data = PptxBuilder.stringToBytes(JSON.stringify(deck));
    entries.push(deckSource);
    entries.push(PptxBuilder.xmlEntry('ppt/presentation.xml', PptxBuilder.presentationXml(slideCount)));
    entries.push(PptxBuilder.xmlEntry('ppt/_rels/presentation.xml.rels',
      PptxBuilder.presentationRelsXml(slideCount)));
    entries.push(PptxBuilder.xmlEntry('ppt/theme/theme1.xml', PptxBuilder.themeXml(colors)));
    entries.push(PptxBuilder.xmlEntry('ppt/slideMasters/slideMaster1.xml', PptxBuilder.slideMasterXml()));
    entries.push(PptxBuilder.xmlEntry('ppt/slideMasters/_rels/slideMaster1.xml.rels',
      PptxBuilder.slideMasterRelsXml()));
    entries.push(PptxBuilder.xmlEntry('ppt/slideLayouts/slideLayout1.xml', PptxBuilder.slideLayoutXml()));
    entries.push(PptxBuilder.xmlEntry('ppt/slideLayouts/_rels/slideLayout1.xml.rels',
      PptxBuilder.slideLayoutRelsXml()));
    entries.push(PptxBuilder.xmlEntry('ppt/notesMasters/notesMaster1.xml', PptxBuilder.notesMasterXml()));
    entries.push(PptxBuilder.xmlEntry('ppt/notesMasters/_rels/notesMaster1.xml.rels',
      PptxBuilder.notesMasterRelsXml()));

    let chartIdx: number = 0;
    let notesIdx: number = 0;
    let sectionNo: number = 0;
    for (let i: number = 0; i < slideCount; i++) {
      let slide: DeckSlide = deck.slides[i];
      let ctx: SlideContext = contexts[i];
      if (slide.layout === 'section') {
        sectionNo++;
      }
      // 全局 section 自动编号
      entries.push(PptxBuilder.xmlEntry('ppt/slides/slide' + (i + 1).toString() + '.xml',
        PptxBuilder.renderSlide(slide, ctx, colors, i + 1, slideCount, sectionNo)));
      entries.push(PptxBuilder.xmlEntry('ppt/slides/_rels/slide' + (i + 1).toString() + '.xml.rels',
        PptxBuilder.slideRelsXml(ctx)));
      for (let m: number = 0; m < ctx.mediaParts.length; m++) {
        let part: PptxImagePart = ctx.mediaParts[m];
        let mediaEntry: ZipEntry = new ZipEntry();
        mediaEntry.name = 'ppt/media/' + PptxBuilder.mediaName(i, m, part.ext);
        mediaEntry.data = part.data;
        entries.push(mediaEntry);
      }
      for (let c: number = 0; c < ctx.chartXmls.length; c++) {
        chartIdx++;
        entries.push(PptxBuilder.xmlEntry('ppt/charts/chart' + chartIdx.toString() + '.xml',
          ctx.chartXmls[c]));
      }
      if (ctx.hasNotes) {
        notesIdx++;
        entries.push(PptxBuilder.xmlEntry('ppt/notesSlides/notesSlide' + notesIdx.toString() + '.xml',
          PptxBuilder.notesSlideXml(ctx.notes)));
        entries.push(PptxBuilder.xmlEntry('ppt/notesSlides/_rels/notesSlide' + notesIdx.toString() + '.xml.rels',
          PptxBuilder.notesSlideRelsXml(i + 1)));
      }
      if ((i + 1) % 8 === 0) {
        await PptxBuilder.yieldNow();
      }
    }
    return ZipWriter.create(entries);
  }

  private static yieldNow(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 0);
    });
  }

  private static mediaName(slideNo: number, imgIdx: number, ext: string): string {
    return 's' + (slideNo + 1).toString() + '_' + (imgIdx + 1).toString() + '.' + ext;
  }

  // 收集一页用到的全部图片 src(按出现顺序)
  private static slideImageSrcs(slide: DeckSlide): string[] {
    let srcs: string[] = [];
    let add: (s: string) => void = (s: string): void => {
      if (s.trim() !== '') {
        srcs.push(s.trim());
      }
    };
    if (slide.layout === 'image' || slide.layout === 'image-full' || slide.layout === 'image-text') {
      add(slide.image.src);
    }
    add(slide.background.image);
    for (let i: number = 0; i < slide.elements.length; i++) {
      if (slide.elements[i].type === 'image') {
        add(slide.elements[i].src);
      }
    }
    return srcs;
  }

  // ===== 单页渲染 =====

  // 背景是否偏暗(深色主题底色/深色 bg.color/背景图+较重遮罩)——决定文字是否反白
  private static isDarkBg(slide: DeckSlide, colors: ThemeColors): boolean {
    if (slide.background.image !== '') {
      return slide.background.overlay >= 0.3;
    }
    let hex: string = PptxThemes.resolveColor(colors, slide.background.color, colors.bg);
    let r: number = parseInt(hex.substring(0, 2), 16) / 255;
    let g: number = parseInt(hex.substring(2, 4), 16) / 255;
    let b: number = parseInt(hex.substring(4, 6), 16) / 255;
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return false;
    }
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.55;
  }

  // 反白主题副本(仅文字四色, 填充与色板不变)
  private static lightened(colors: ThemeColors): ThemeColors {
    let c: ThemeColors = new ThemeColors();
    c.name = colors.name;
    c.primary = colors.primary;
    c.accent = colors.accent;
    c.bg = colors.bg;
    c.surface = colors.surface;
    c.title = 'FFFFFF';
    c.body = 'E2E8F0';
    c.sub = 'A9B6C6';
    c.faint = '7E8CA0';
    c.onPrimary = colors.onPrimary;
    c.dark = true;
    c.series = colors.series;
    return c;
  }

  // 页面文字方案: 深色背景自动反白
  private static textScheme(slide: DeckSlide, colors: ThemeColors): TextScheme {
    let s: TextScheme = new TextScheme();
    if (PptxBuilder.isDarkBg(slide, colors)) {
      s.title = 'FFFFFF';
      s.body = 'E2E8F0';
      s.sub = 'A9B6C6';
      s.faint = '7E8CA0';
    } else {
      s.title = colors.title;
      s.body = colors.body;
      s.sub = colors.sub;
      s.faint = colors.faint;
    }
    return s;
  }

  private static renderSlide(slide: DeckSlide, ctx: SlideContext, colors: ThemeColors,
    pageNo: number, total: number, sectionNo: number): string {
    let spTree: string = '';
    spTree += '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>';
    spTree += '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/>' +
      '<a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';
    let ts: TextScheme = PptxBuilder.textScheme(slide, colors);
    let body: string = '';
    switch (slide.layout) {
      case 'cover':
        body = PptxBuilder.renderCover(slide, colors);
        break;
      case 'toc':
        body = PptxBuilder.renderToc(slide, colors, ts, pageNo, total);
        break;
      case 'section':
        body = PptxBuilder.renderSection(slide, colors, sectionNo);
        break;
      case 'content':
        body = PptxBuilder.renderContent(slide, colors, ts, pageNo, total);
        break;
      case 'two-col':
        body = PptxBuilder.renderTwoCol(slide, colors, ts, pageNo, total);
        break;
      case 'image-text':
        body = PptxBuilder.renderImageText(slide, ctx, colors, ts, pageNo, total);
        break;
      case 'image':
        body = PptxBuilder.renderImage(slide, ctx, colors, ts, pageNo, total);
        break;
      case 'image-full':
        body = PptxBuilder.renderImageFull(slide, ctx);
        break;
      case 'table':
        body = PptxBuilder.renderTable(slide, colors, ts, pageNo, total);
        break;
      case 'chart':
        body = PptxBuilder.renderChart(slide, ctx, colors, ts, pageNo, total);
        break;
      case 'quote':
        body = PptxBuilder.renderQuote(slide, colors, ts);
        break;
      case 'end':
        body = PptxBuilder.renderEnd(slide, colors);
        break;
      default:
        body = PptxBuilder.renderCustom(slide, ctx, colors, ts, pageNo, total);
        break;
    }
    // 背景层(最底): 背景图 + 遮罩, 或纯色(页面色 → 主题底色)
    if (slide.background.image !== '') {
      // image/image-full/image-text 版式的正文图片占 mediaParts[0], 背景图随后
      let bgIdx: number = (slide.layout === 'image' || slide.layout === 'image-full' ||
        slide.layout === 'image-text') ? 1 : 0;
      let part: PptxImagePart = ctx.mediaParts[bgIdx];
      let relId: string = 'rId' + (2 + bgIdx).toString();
      let bgXml: string = PptxBuilder.pic(90, 0, 0, SLIDE_W, SLIDE_H, relId, part.widthPx, part.heightPx,
        slide.background.fit === 'contain' ? 'contain' : 'cover');
      if (slide.background.overlay > 0) {
        bgXml += PptxBuilder.overlayRect(91, 0, 0, SLIDE_W, SLIDE_H, '000000',
          Math.round(slide.background.overlay * 100));
      }
      spTree += bgXml;
    } else {
      spTree += PptxBuilder.rect(90, 0, 0, SLIDE_W, SLIDE_H,
        PptxBuilder.resolve(colors, slide.background.color, colors.bg));
    }
    return XML_HEAD +
      '<p:sld ' + NS_A + ' ' + NS_R + ' ' + NS_P + '>' +
      '<p:cSld><p:spTree>' + spTree + body + '</p:spTree></p:cSld>' +
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
      '</p:sld>';
  }

  // 内容页公共骨架: 顶栏 + 标题 + 下划线 + 页脚, 文字用页面文字方案(深色底自动反白)
  private static contentChrome(id: number, title: string, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = '';
    xml += PptxBuilder.rect(id, 0, 0, SLIDE_W, ACCENT_H, colors.primary);
    let size: number = title.length <= 12 ? 3000 : (title.length <= 20 ? 2600 : 2200);
    xml += PptxBuilder.textBox(id + 1, MARGIN_X, TITLE_Y, SLIDE_W - MARGIN_X * 2, TITLE_H,
      PptxBuilder.para(title, size, ts.title, true, 'left'), 'anchor="ctr"');
    xml += PptxBuilder.rect(id + 2, MARGIN_X, UNDERLINE_Y, 720000, 57150, colors.primary);
    xml += PptxBuilder.textBox(id + 3, SLIDE_W - 1100000, FOOTER_Y, 800000, 280000,
      PptxBuilder.para(pageNo.toString() + ' / ' + total.toString(), 1100, ts.faint, false, 'right'), '');
    return xml;
  }

  private static renderCover(slide: DeckSlide, colors: ThemeColors): string {
    let withImage: boolean = slide.background.image !== '';
    let titleColor: string = withImage ? 'FFFFFF' : colors.title;
    let subColor: string = withImage ? 'E8EDF2' : colors.sub;
    let xml: string = '';
    xml += PptxBuilder.rect(3, MARGIN_X, 2280000, 900000, 127000, colors.primary);
    let titleSize: number = slide.title.length <= 10 ? 4400 : (slide.title.length <= 20 ? 4000 : 3400);
    xml += PptxBuilder.textBox(4, MARGIN_X, 2520000, SLIDE_W - MARGIN_X * 2 - 600000, 1600000,
      PptxBuilder.para(slide.title === '' ? '未命名演示' : slide.title, titleSize, titleColor, true, 'left'), 'anchor="t"');
    if (slide.subtitle !== '') {
      xml += PptxBuilder.textBox(5, MARGIN_X, 4280000, SLIDE_W - MARGIN_X * 2 - 1200000, 700000,
        PptxBuilder.para(slide.subtitle, 1800, subColor, false, 'left'), 'anchor="t"');
    }
    xml += PptxBuilder.rect(6, MARGIN_X, SLIDE_H - 500000, SLIDE_W - MARGIN_X * 2, 12700,
      withImage ? '5A6B7E' : colors.surface);
    return xml;
  }

  private static renderToc(slide: DeckSlide, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = PptxBuilder.contentChrome(2, slide.title === '' ? '目录' : slide.title, colors, ts, pageNo, total);
    let items: string[] = [];
    for (let i: number = 0; i < slide.bullets.length; i++) {
      items.push(slide.bullets[i].text);
    }
    if (items.length === 0 && slide.columns.length > 0) {
      for (let c: number = 0; c < slide.columns.length; c++) {
        items.push(slide.columns[c].heading);
      }
    }
    let cols: string[][] = [];
    if (items.length > 5) {
      let half: number = Math.ceil(items.length / 2);
      let left: string[] = [];
      let right: string[] = [];
      for (let i: number = 0; i < items.length; i++) {
        if (i < half) {
          left.push(items[i]);
        } else {
          right.push(items[i]);
        }
      }
      cols.push(left);
      cols.push(right);
    } else {
      cols.push(items);
    }
    let colW: number = (SLIDE_W - MARGIN_X * 2 - 700000) / 2;
    for (let c: number = 0; c < cols.length; c++) {
      let x: number = MARGIN_X + c * (colW + 700000);
      let rows: number = cols[c].length;
      let rowH: number = rows > 0 ? Math.min(760000, Math.floor(BODY_H / rows)) : 0;
      for (let i: number = 0; i < cols[c].length; i++) {
        let y: number = BODY_Y + 100000 + i * rowH;
        let num: string = (c * Math.ceil(items.length / 2) + i + 1).toString();
        num = num.length < 2 ? '0' + num : num;
        xml += PptxBuilder.textBox(20 + c * 30 + i, x, y, 700000, rowH,
          PptxBuilder.para(num, 1700, colors.primary, true, 'left'), 'anchor="t"');
        xml += PptxBuilder.textBox(21 + c * 30 + i, x + 800000, y, colW - 800000, rowH,
          PptxBuilder.para(cols[c][i], 1600, ts.title, false, 'left'), 'anchor="t"');
      }
    }
    return xml;
  }

  private static renderSection(slide: DeckSlide, colors: ThemeColors, sectionNo: number): string {
    let xml: string = '';
    xml += PptxBuilder.rect(2, 0, 0, SLIDE_W, SLIDE_H, colors.primary);
    let num: string = slide.index !== '' ? slide.index : (sectionNo < 10 ? '0' + sectionNo.toString() : sectionNo.toString());
    xml += PptxBuilder.textBox(3, MARGIN_X, 1200000, 3000000, 1300000,
      PptxBuilder.paraFill(num, 5400, PptxBuilder.alphaFill('FFFFFF', 45), true, 'left'), 'anchor="t"');
    let titleSize: number = slide.title.length <= 8 ? 4000 : (slide.title.length <= 16 ? 3600 : 3200);
    xml += PptxBuilder.textBox(4, MARGIN_X, 2600000, SLIDE_W - MARGIN_X * 2 - 800000, 1300000,
      PptxBuilder.para(slide.title, titleSize, colors.onPrimary, true, 'left'), 'anchor="t"');
    if (slide.subtitle !== '') {
      xml += PptxBuilder.textBox(5, MARGIN_X, 3980000, SLIDE_W - MARGIN_X * 2 - 1200000, 700000,
        PptxBuilder.paraFill(slide.subtitle, 1600, PptxBuilder.alphaFill(colors.onPrimary, 72), false, 'left'), 'anchor="t"');
    }
    xml += PptxBuilder.overlayRect(6, MARGIN_X, 2450000, 1400000, 50800, 'FFFFFF', 60);
    return xml;
  }

  private static renderContent(slide: DeckSlide, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = PptxBuilder.contentChrome(2, slide.title, colors, ts, pageNo, total);
    let l1: number = 0;
    for (let i: number = 0; i < slide.bullets.length; i++) {
      if (slide.bullets[i].level === 1) {
        l1++;
      }
    }
    let base: number = l1 <= 3 ? 2000 : (l1 <= 5 ? 1800 : (l1 <= 7 ? 1600 : 1400));
    let paras: string = '';
    for (let i: number = 0; i < slide.bullets.length; i++) {
      let b: DeckBullet = slide.bullets[i];
      let size: number = b.level === 2 ? Math.max(1200, base - 300) : base;
      paras += PptxBuilder.bulletPara(b.text, b.level, size, ts, colors);
    }
    if (paras === '') {
      paras = PptxBuilder.para('', 1600, ts.body, false, 'left');
    }
    xml += PptxBuilder.textBox(10, MARGIN_X, BODY_Y, SLIDE_W - MARGIN_X * 2, BODY_H, paras, '');
    return xml;
  }

  private static renderTwoCol(slide: DeckSlide, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = PptxBuilder.contentChrome(2, slide.title, colors, ts, pageNo, total);
    let gap: number = 800000;
    let colW: number = Math.floor((SLIDE_W - MARGIN_X * 2 - gap) / 2);
    for (let c: number = 0; c < 2; c++) {
      let colX: number = MARGIN_X + c * (colW + gap);
      let y: number = BODY_Y;
      let heading: string = c < slide.columns.length ? slide.columns[c].heading : '';
      let bullets: string[] = c < slide.columns.length ? slide.columns[c].bullets : [];
      if (heading !== '') {
        xml += PptxBuilder.rect(30 + c, colX, BODY_Y + 40000, 320000, 46000, colors.primary);
        xml += PptxBuilder.textBox(32 + c, colX + 420000, BODY_Y - 80000, colW - 420000, 500000,
          PptxBuilder.para(heading, 1800, ts.title, true, 'left'), '');
        y = BODY_Y + 560000;
      }
      let paras: string = '';
      let base: number = bullets.length <= 4 ? 1600 : (bullets.length <= 6 ? 1450 : 1300);
      for (let i: number = 0; i < bullets.length; i++) {
        paras += PptxBuilder.bulletPara(bullets[i], 1, base, ts, colors);
      }
      if (paras !== '') {
        xml += PptxBuilder.textBox(34 + c, colX, y, colW, BODY_Y + BODY_H - y, paras, '');
      }
    }
    return xml;
  }

  private static renderImageText(slide: DeckSlide, ctx: SlideContext, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = PptxBuilder.contentChrome(2, slide.title, colors, ts, pageNo, total);
    let imgW: number = 5200000;
    let gap: number = 600000;
    let textW: number = SLIDE_W - MARGIN_X * 2 - imgW - gap;
    let imgLeft: boolean = slide.imageSide === 'left';
    let imgX: number = imgLeft ? MARGIN_X : SLIDE_W - MARGIN_X - imgW;
    let txtX: number = imgLeft ? MARGIN_X + imgW + gap : MARGIN_X;
    // 图片部件顺序: 页面无背景图时 rId2 即首图
    let relId: string = 'rId2';
    xml += PptxBuilder.pic(10, imgX, BODY_Y + 60000, imgW, BODY_H - 120000, relId,
      PptxBuilder.partW(ctx, 0), PptxBuilder.partH(ctx, 0), slide.image.fit);
    let l1: number = 0;
    for (let i: number = 0; i < slide.bullets.length; i++) {
      if (slide.bullets[i].level === 1) {
        l1++;
      }
    }
    let base: number = l1 <= 3 ? 1800 : (l1 <= 5 ? 1600 : 1400);
    let paras: string = '';
    for (let i: number = 0; i < slide.bullets.length; i++) {
      let b: DeckBullet = slide.bullets[i];
      paras += PptxBuilder.bulletPara(b.text, b.level, b.level === 2 ? Math.max(1200, base - 250) : base, ts, colors);
    }
    if (paras !== '') {
      xml += PptxBuilder.textBox(11, txtX, BODY_Y + 100000, textW, BODY_H - 200000, paras, '');
    }
    return xml;
  }

  private static renderImage(slide: DeckSlide, ctx: SlideContext, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = PptxBuilder.contentChrome(2, slide.title, colors, ts, pageNo, total);
    let captionH: number = slide.caption !== '' ? 460000 : 0;
    let imgH: number = BODY_H - captionH - 100000;
    let relId: string = 'rId2';
    xml += PptxBuilder.pic(10, MARGIN_X, BODY_Y + 40000, SLIDE_W - MARGIN_X * 2, imgH,
      relId, PptxBuilder.partW(ctx, 0), PptxBuilder.partH(ctx, 0), slide.image.fit);
    if (captionH > 0) {
      xml += PptxBuilder.textBox(11, MARGIN_X, BODY_Y + imgH + 140000, SLIDE_W - MARGIN_X * 2, 360000,
        PptxBuilder.para(slide.caption, 1200, ts.sub, false, 'center'), '');
    }
    return xml;
  }

  private static renderImageFull(slide: DeckSlide, ctx: SlideContext): string {
    let xml: string = '';
    let relId: string = 'rId2';
    xml += PptxBuilder.pic(2, 0, 0, SLIDE_W, SLIDE_H, relId,
      PptxBuilder.partW(ctx, 0), PptxBuilder.partH(ctx, 0), 'cover');
    if (slide.caption !== '' || slide.title !== '') {
      let text: string = slide.caption !== '' ? slide.caption : slide.title;
      xml += PptxBuilder.overlayRect(3, 0, SLIDE_H - 900000, SLIDE_W, 900000, '000000', 55);
      xml += PptxBuilder.textBox(4, MARGIN_X, SLIDE_H - 800000, SLIDE_W - MARGIN_X * 2, 560000,
        PptxBuilder.para(text, 1500, 'FFFFFF', false, 'left'), 'anchor="ctr"');
    }
    return xml;
  }

  private static renderTable(slide: DeckSlide, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = PptxBuilder.contentChrome(2, slide.title, colors, ts, pageNo, total);
    if (slide.table.rows.length > 20) {
      throw new Error('第 ' + pageNo.toString() + ' 页表格超过 20 行, 请拆成多页');
    }
    let t: DeckTable = slide.table;
    let colCount: number = Math.max(t.headers.length, t.rows.length > 0 ? t.rows[0].length : 0, 1);
    let noteH: number = t.note !== '' ? 400000 : 0;
    let tblW: number = SLIDE_W - MARGIN_X * 2;
    let tblH: number = BODY_H - noteH;
    let headerH: number = 620000;
    let bodyRowH: number = t.rows.length > 0 ? Math.min(600000, Math.floor((tblH - headerH) / t.rows.length)) : 0;
    // 列宽
    let widths: number[] = [];
    if (t.widths.length === colCount) {
      let sum: number = 0;
      for (let i: number = 0; i < t.widths.length; i++) {
        sum += Math.max(t.widths[i], 0.01);
      }
      for (let i: number = 0; i < t.widths.length; i++) {
        widths.push(Math.floor(tblW * Math.max(t.widths[i], 0.01) / sum));
      }
    } else {
      for (let i: number = 0; i < colCount; i++) {
        widths.push(Math.floor(tblW / colCount));
      }
    }
    let grid: string = '';
    for (let i: number = 0; i < widths.length; i++) {
      grid += '<a:gridCol w="' + widths[i].toString() + '"/>';
    }
    let rowsXml: string = '';
    if (t.headers.length > 0) {
      rowsXml += '<a:tr h="' + headerH.toString() + '">';
      for (let c: number = 0; c < colCount; c++) {
        rowsXml += '<a:tc>' +
          PptxBuilder.cellBody(c < t.headers.length ? t.headers[c] : '', 1400, 'FFFFFF', true) +
          '<a:tcPr marL="109728" marR="109728" marT="45720" marB="45720" anchor="ctr">' +
          '<a:solidFill><a:srgbClr val="' + colors.primary + '"/></a:solidFill></a:tcPr></a:tc>';
      }
      rowsXml += '</a:tr>';
    }
    for (let r: number = 0; r < t.rows.length; r++) {
      rowsXml += '<a:tr h="' + bodyRowH.toString() + '">';
      // 隔行填充用主题 bg/surface, 与正文文字色(colors.body)在任何主题下都保持对比
      let band: string = r % 2 === 1 ? colors.surface : colors.bg;
      for (let c: number = 0; c < colCount; c++) {
        rowsXml += '<a:tc>' +
          PptxBuilder.cellBody(c < t.rows[r].length ? t.rows[r][c] : '', 1300, colors.body, false) +
          '<a:tcPr marL="109728" marR="109728" marT="45720" marB="45720" anchor="ctr">' +
          '<a:solidFill><a:srgbClr val="' + band + '"/></a:solidFill></a:tcPr></a:tc>';
      }
      rowsXml += '</a:tr>';
    }
    let tblY: number = BODY_Y;
    xml += '<p:graphicFrame>' +
      '<p:nvGraphicFramePr><p:cNvPr id="10" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>' +
      '<p:xfrm><a:off x="' + MARGIN_X.toString() + '" y="' + tblY.toString() + '"/>' +
      '<a:ext cx="' + tblW.toString() + '" cy="' + (headerH + bodyRowH * t.rows.length).toString() + '"/></p:xfrm>' +
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">' +
      '<a:tbl><a:tblPr firstRow="1" bandRow="1"/><a:tblGrid>' + grid + '</a:tblGrid>' +
      rowsXml + '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>';
    if (noteH > 0) {
      xml += PptxBuilder.textBox(11, MARGIN_X, BODY_Y + tblH + 60000, tblW, 320000,
        PptxBuilder.para(t.note, 1100, ts.sub, false, 'left'), '');
    }
    return xml;
  }

  private static cellBody(text: string, size: number, color: string, bold: boolean): string {
    return '<a:txBody><a:bodyPr/><a:lstStyle/>' +
      PptxBuilder.para(text, size, color, bold, 'left') + '</a:txBody>';
  }

  private static renderChart(slide: DeckSlide, ctx: SlideContext, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = PptxBuilder.contentChrome(2, slide.title, colors, ts, pageNo, total);
    let noteH: number = slide.caption !== '' ? 400000 : 0;
    // 关系分配: rId1=layout, rId2..=图片, 其后是图表(每页最多 1 个图表)
    let relId: string = 'rId' + (2 + ctx.mediaParts.length).toString();
    // 深色背景页时图表文字(轴/标签)用反白方案, 系列色板不变
    let chartColors: ThemeColors = ctx.chartColors;
    xml += '<p:graphicFrame>' +
      '<p:nvGraphicFramePr><p:cNvPr id="10" name="Chart"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>' +
      '<p:xfrm><a:off x="' + MARGIN_X.toString() + '" y="' + (BODY_Y + 40000).toString() + '"/>' +
      '<a:ext cx="' + (SLIDE_W - MARGIN_X * 2).toString() + '" cy="' + (BODY_H - noteH - 80000).toString() + '"/></p:xfrm>' +
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">' +
      '<c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="' + relId + '"/>' +
      '</a:graphicData></a:graphic></p:graphicFrame>';
    if (noteH > 0) {
      xml += PptxBuilder.textBox(11, MARGIN_X, BODY_Y + BODY_H - noteH + 60000, SLIDE_W - MARGIN_X * 2, 320000,
        PptxBuilder.para(slide.caption, 1100, ts.sub, false, 'left'), '');
    }
    return xml;
  }

  private static renderQuote(slide: DeckSlide, colors: ThemeColors, ts: TextScheme): string {
    let xml: string = '';
    xml += PptxBuilder.textBox(3, MARGIN_X, 700000, 2000000, 1500000,
      PptxBuilder.para('“', 9600, colors.primary, true, 'left'), 'anchor="t"');
    let len: number = slide.text.length;
    let size: number = len <= 20 ? 3200 : (len <= 40 ? 2800 : (len <= 80 ? 2400 : 2000));
    xml += PptxBuilder.textBox(4, MARGIN_X + 600000, 2300000, SLIDE_W - (MARGIN_X + 600000) * 2, 2400000,
      PptxBuilder.para(slide.text, size, ts.title, false, 'center'), 'anchor="ctr"');
    if (slide.author !== '') {
      xml += PptxBuilder.rect(5, SLIDE_W / 2 - 400000, 4950000, 800000, 38100, colors.primary);
      xml += PptxBuilder.textBox(6, MARGIN_X, 5100000, SLIDE_W - MARGIN_X * 2, 500000,
        PptxBuilder.para('—— ' + slide.author, 1500, ts.sub, false, 'center'), 'anchor="t"');
    }
    return xml;
  }

  private static renderEnd(slide: DeckSlide, colors: ThemeColors): string {
    let xml: string = '';
    xml += PptxBuilder.rect(2, 0, 0, SLIDE_W, SLIDE_H, colors.primary);
    xml += PptxBuilder.overlayRect(3, SLIDE_W / 2 - 700000, 2280000, 1400000, 90000, 'FFFFFF', 70);
    let titleSize: number = slide.title.length <= 6 ? 4800 : 4000;
    xml += PptxBuilder.textBox(4, MARGIN_X, 2560000, SLIDE_W - MARGIN_X * 2, 1400000,
      PptxBuilder.para(slide.title === '' ? '谢谢观看' : slide.title, titleSize, colors.onPrimary, true, 'center'), 'anchor="t"');
    if (slide.subtitle !== '') {
      xml += PptxBuilder.textBox(5, MARGIN_X, 4120000, SLIDE_W - MARGIN_X * 2, 700000,
        PptxBuilder.paraFill(slide.subtitle, 1700, PptxBuilder.alphaFill(colors.onPrimary, 75), false, 'center'), 'anchor="t"');
    }
    return xml;
  }

  private static renderCustom(slide: DeckSlide, ctx: SlideContext, colors: ThemeColors, ts: TextScheme,
    pageNo: number, total: number): string {
    let xml: string = '';
    if (slide.title !== '') {
      xml += PptxBuilder.contentChrome(3, slide.title, colors, ts, pageNo, total);
    }
    let imgOffset: number = slide.background.image !== '' ? 1 : 0;
    for (let i: number = 0; i < slide.elements.length; i++) {
      let el: DeckElement = slide.elements[i];
      let x: number = Math.round(el.x * SLIDE_W);
      let y: number = Math.round(el.y * SLIDE_H);
      let w: number = Math.round(el.w * SLIDE_W);
      let h: number = Math.round(el.h * SLIDE_H);
      let id: number = 50 + i * 2;
      if (el.type === 'text') {
        xml += PptxBuilder.textBox(id, x, y, w, h,
          PptxBuilder.para(el.text, Math.round(el.size * 100),
            PptxBuilder.elementColor(colors, ts, el.color), el.bold, el.align), 'anchor="t"');
      } else if (el.type === 'image') {
        let relId: string = 'rId' + (2 + imgOffset + PptxBuilder.imageIndexOf(ctx, slide, i)).toString();
        xml += PptxBuilder.pic(id, x, y, w, h, relId,
          PptxBuilder.partW(ctx, imgOffset + PptxBuilder.imageIndexOf(ctx, slide, i)),
          PptxBuilder.partH(ctx, imgOffset + PptxBuilder.imageIndexOf(ctx, slide, i)), el.fit);
      } else if (el.type === 'shape') {
        xml += PptxBuilder.shape(id, el.shape, x, y, w, h, PptxBuilder.resolve(colors, el.fill, colors.primary));
      } else {
        // 表格元素: 简化为无表头样式表
        xml += PptxBuilder.miniTable(id, el, x, y, w, h, colors);
      }
    }
    return xml;
  }

  // custom 文本元素语义色: title/body/sub/faint 取页面文字方案(深色底自动反白), 其余按主题解析
  private static elementColor(colors: ThemeColors, ts: TextScheme, spec: string): string {
    let lower: string = spec.trim().toLowerCase();
    if (lower === '' || lower === 'body') {
      return ts.body;
    }
    if (lower === 'title') {
      return ts.title;
    }
    if (lower === 'sub') {
      return ts.sub;
    }
    if (lower === 'faint') {
      return ts.faint;
    }
    return PptxThemes.resolveColor(colors, spec, ts.body);
  }

  // custom 页: 元素的 image 在 ctx.mediaParts 中的序号(与 slideImageSrcs 收集顺序一致)
  private static imageIndexOf(ctx: SlideContext, slide: DeckSlide, elIdx: number): number {
    let found: number = 0;
    let seen: number = 0;
    if (slide.layout === 'image' || slide.layout === 'image-full' || slide.layout === 'image-text') {
      seen++;
    }
    for (let i: number = 0; i < slide.elements.length; i++) {
      if (slide.elements[i].type === 'image') {
        if (i === elIdx) {
          found = seen;
          break;
        }
        seen++;
      }
    }
    return found;
  }

  private static miniTable(id: number, el: DeckElement, x: number, y: number, w: number, h: number,
    colors: ThemeColors): string {
    let colCount: number = Math.max(el.headers.length, el.rows.length > 0 ? el.rows[0].length : 1);
    let rowCount: number = el.rows.length + (el.headers.length > 0 ? 1 : 0);
    let rowH: number = rowCount > 0 ? Math.floor(h / rowCount) : h;
    let colW: number = Math.floor(w / colCount);
    let grid: string = '';
    for (let i: number = 0; i < colCount; i++) {
      grid += '<a:gridCol w="' + colW.toString() + '"/>';
    }
    let rowsXml: string = '';
    if (el.headers.length > 0) {
      rowsXml += '<a:tr h="' + rowH.toString() + '">';
      for (let c: number = 0; c < colCount; c++) {
        rowsXml += '<a:tc>' + PptxBuilder.cellBody(c < el.headers.length ? el.headers[c] : '',
          1300, 'FFFFFF', true) +
          '<a:tcPr anchor="ctr"><a:solidFill><a:srgbClr val="' + colors.primary + '"/></a:solidFill></a:tcPr></a:tc>';
      }
      rowsXml += '</a:tr>';
    }
    for (let r: number = 0; r < el.rows.length; r++) {
      rowsXml += '<a:tr h="' + rowH.toString() + '">';
      for (let c: number = 0; c < colCount; c++) {
        rowsXml += '<a:tc>' + PptxBuilder.cellBody(c < el.rows[r].length ? el.rows[r][c] : '',
          1200, colors.body, false) +
          '<a:tcPr anchor="ctr"><a:solidFill><a:srgbClr val="' +
          (r % 2 === 1 ? colors.surface : colors.bg) + '"/></a:solidFill></a:tcPr></a:tc>';
      }
      rowsXml += '</a:tr>';
    }
    return '<p:graphicFrame>' +
      '<p:nvGraphicFramePr><p:cNvPr id="' + id.toString() + '" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>' +
      '<p:xfrm><a:off x="' + x.toString() + '" y="' + y.toString() + '"/>' +
      '<a:ext cx="' + w.toString() + '" cy="' + h.toString() + '"/></p:xfrm>' +
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">' +
      '<a:tbl><a:tblPr firstRow="1" bandRow="1"/><a:tblGrid>' + grid + '</a:tblGrid>' +
      rowsXml + '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>';
  }

  // ===== 图形基元 =====

  private static resolve(colors: ThemeColors, spec: string, fallback: string): string {
    return PptxThemes.resolveColor(colors, spec, fallback);
  }

  private static rect(id: number, x: number, y: number, w: number, h: number, hex: string): string {
    return '<p:sp>' +
      '<p:nvSpPr><p:cNvPr id="' + id.toString() + '" name="Shape"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="' + Math.round(x).toString() + '" y="' + Math.round(y).toString() + '"/>' +
      '<a:ext cx="' + Math.round(w).toString() + '" cy="' + Math.round(h).toString() + '"/></a:xfrm>' +
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
      '<a:solidFill><a:srgbClr val="' + hex + '"/></a:solidFill>' +
      '<a:ln><a:noFill/></a:ln></p:spPr>' +
      '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="zh-CN"/></a:p></p:txBody></p:sp>';
  }

  // 半透明纯色矩形(遮罩/水印条)
  private static overlayRect(id: number, x: number, y: number, w: number, h: number,
    hex: string, alphaPct: number): string {
    return '<p:sp>' +
      '<p:nvSpPr><p:cNvPr id="' + id.toString() + '" name="Overlay"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="' + Math.round(x).toString() + '" y="' + Math.round(y).toString() + '"/>' +
      '<a:ext cx="' + Math.round(w).toString() + '" cy="' + Math.round(h).toString() + '"/></a:xfrm>' +
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
      PptxBuilder.alphaFill(hex, alphaPct) +
      '<a:ln><a:noFill/></a:ln></p:spPr>' +
      '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="zh-CN"/></a:p></p:txBody></p:sp>';
  }

  // fillHex 参数位置传入完整的 solidFill/alphaFill 片段
  private static shape(id: number, kind: string, x: number, y: number, w: number, h: number, colorHex: string): string {
    let prst: string = kind === 'roundRect' ? 'roundRect' :
      (kind === 'ellipse' ? 'ellipse' :
        (kind === 'triangle' ? 'triangle' :
          (kind === 'arrow' ? 'rightArrow' : 'rect')));
    let avLst: string = prst === 'roundRect' ? '<a:gd name="adj" fmla="val 12000"/>' : '';
    return '<p:sp>' +
      '<p:nvSpPr><p:cNvPr id="' + id.toString() + '" name="Shape"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="' + Math.round(x).toString() + '" y="' + Math.round(y).toString() + '"/>' +
      '<a:ext cx="' + Math.round(w).toString() + '" cy="' + Math.round(h).toString() + '"/></a:xfrm>' +
      '<a:prstGeom prst="' + prst + '"><a:avLst>' + avLst + '</a:avLst></a:prstGeom>' +
      '<a:solidFill><a:srgbClr val="' + colorHex + '"/></a:solidFill>' +
      '<a:ln><a:noFill/></a:ln></p:spPr>' +
      '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="zh-CN"/></a:p></p:txBody></p:sp>';
  }

  private static textBox(id: number, x: number, y: number, w: number, h: number,
    parasXml: string, anchor: string): string {
    return '<p:sp>' +
      '<p:nvSpPr><p:cNvPr id="' + id.toString() + '" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="' + Math.round(x).toString() + '" y="' + Math.round(y).toString() + '"/>' +
      '<a:ext cx="' + Math.round(w).toString() + '" cy="' + Math.round(h).toString() + '"/></a:xfrm>' +
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>' +
      '<p:txBody><a:bodyPr wrap="square" ' + anchor + '><a:normAutofit/></a:bodyPr><a:lstStyle/>' +
      parasXml + '</p:txBody></p:sp>';
  }

  // 单段落(支持 \n 换行为 <a:br/>; 颜色为 6 位 hex)
  private static para(text: string, size: number, colorHex: string, bold: boolean, align: string): string {
    return PptxBuilder.paraFill(text, size,
      '<a:solidFill><a:srgbClr val="' + colorHex + '"/></a:solidFill>', bold, align);
  }

  // 单段落(填充片段版, 支持带 alpha 的 solidFill)
  private static paraFill(text: string, size: number, fillFragment: string, bold: boolean,
    align: string): string {
    let algn: string = align === 'center' ? ' algn="ctr"' : (align === 'right' ? ' algn="r"' : '');
    let lines: string[] = text.split('\n');
    let runs: string = '';
    for (let i: number = 0; i < lines.length; i++) {
      if (i > 0) {
        runs += '<a:br/>';
      }
      if (lines[i] !== '') {
        runs += '<a:r><a:rPr lang="zh-CN" altLang="en-US" sz="' + Math.round(size).toString() + '"' +
          (bold ? ' b="1"' : '') + ' dirty="0">' + fillFragment +
          '</a:rPr><a:t>' + XmlUtil.escape(lines[i]) + '</a:t></a:r>';
      }
    }
    if (runs === '') {
      runs = '<a:endParaRPr lang="zh-CN" sz="' + Math.round(size).toString() + '"/>';
    }
    return '<a:p><a:pPr' + algn + '/>' + runs + '</a:p>';
  }

  private static bulletPara(text: string, level: number, size: number, ts: TextScheme,
    colors: ThemeColors): string {
    let marL: number = level === 2 ? 800100 : 342900;
    let indent: number = level === 2 ? -285750 : -342900;
    let ch: string = level === 2 ? '–' : '•';
    let color: string = level === 2 ? ts.sub : ts.body;
    let buColor: string = level === 2 ? ts.faint : colors.primary;
    return '<a:p><a:pPr marL="' + marL.toString() + '" indent="' + indent.toString() + '">' +
      '<a:spcBef><a:spcPts val="900"/></a:spcBef>' +
      '<a:buClr><a:srgbClr val="' + buColor + '"/></a:buClr>' +
      '<a:buFont typeface="Arial"/><a:buChar char="' + ch + '"/></a:pPr>' +
      '<a:r><a:rPr lang="zh-CN" altLang="en-US" sz="' + Math.round(size).toString() + '" dirty="0">' +
      '<a:solidFill><a:srgbClr val="' + color + '"/></a:solidFill></a:rPr>' +
      '<a:t>' + XmlUtil.escape(text) + '</a:t></a:r></a:p>';
  }

  // 图片(含 contain 按比例居中 / cover 按比例裁剪)
  private static pic(id: number, x: number, y: number, w: number, h: number, relId: string,
    imgW: number, imgH: number, fit: string): string {
    let srcRect: string = '';
    let bx: number = Math.round(x);
    let by: number = Math.round(y);
    let bw: number = Math.round(w);
    let bh: number = Math.round(h);
    if (fit === 'contain' && imgW > 0 && imgH > 0) {
      let scale: number = Math.min(w / imgW, h / imgH);
      let nw: number = imgW * scale;
      let nh: number = imgH * scale;
      bx = Math.round(x + (w - nw) / 2);
      by = Math.round(y + (h - nh) / 2);
      bw = Math.round(nw);
      bh = Math.round(nh);
    } else if (fit === 'cover' && imgW > 0 && imgH > 0 && w > 0 && h > 0) {
      let boxAspect: number = w / h;
      let imgAspect: number = imgW / imgH;
      if (imgAspect > boxAspect) {
        let crop: number = (1 - boxAspect / imgAspect) / 2;
        srcRect = '<a:srcRect l="' + Math.round(crop * 100000).toString() + '" r="' +
          Math.round(crop * 100000).toString() + '"/>';
      } else if (imgAspect < boxAspect) {
        let crop: number = (1 - imgAspect / boxAspect) / 2;
        srcRect = '<a:srcRect t="' + Math.round(crop * 100000).toString() + '" b="' +
          Math.round(crop * 100000).toString() + '"/>';
      }
    }
    return '<p:pic>' +
      '<p:nvPicPr><p:cNvPr id="' + id.toString() + '" name="Picture"/>' +
      '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>' +
      '<p:blipFill><a:blip r:embed="' + relId + '"/>' + srcRect +
      '<a:stretch><a:fillRect/></a:stretch></p:blipFill>' +
      '<p:spPr><a:xfrm><a:off x="' + bx.toString() + '" y="' + by.toString() + '"/>' +
      '<a:ext cx="' + bw.toString() + '" cy="' + bh.toString() + '"/></a:xfrm>' +
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>';
  }

  private static partW(ctx: SlideContext, idx: number): number {
    return idx < ctx.mediaParts.length ? ctx.mediaParts[idx].widthPx : 0;
  }

  private static partH(ctx: SlideContext, idx: number): number {
    return idx < ctx.mediaParts.length ? ctx.mediaParts[idx].heightPx : 0;
  }

  private static alphaFill(hex: string, alphaPct: number): string {
    return '<a:solidFill><a:srgbClr val="' + hex + '"><a:alpha val="' +
      Math.round(alphaPct * 1000).toString() + '"/></a:srgbClr></a:solidFill>';
  }

  // ===== 备注部件 =====

  private static notesSlideXml(notes: string): string {
    return XML_HEAD + '<p:notes ' + NS_A + ' ' + NS_R + ' ' + NS_P + '>' +
      '<p:cSld><p:spTree>' +
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>' +
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>' +
      '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image"/><p:cNvSpPr>' +
      '<a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr>' +
      '<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="zh-CN"/></a:p></p:txBody></p:sp>' +
      '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>' +
      '<p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>' +
      '<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>' +
      PptxBuilder.para(notes, 1200, '333333', false, 'left') +
      '</p:txBody></p:sp>' +
      '</p:spTree></p:cSld>' +
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
      '</p:notes>';
  }

  private static notesSlideRelsXml(slideNo: number): string {
    return XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster" Target="../notesMasters/notesMaster1.xml"/>' +
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="../slides/slide' + slideNo.toString() + '.xml"/>' +
      '</Relationships>';
  }

  private static notesMasterXml(): string {
    return XML_HEAD + '<p:notesMaster ' + NS_A + ' ' + NS_R + ' ' + NS_P + '>' +
      '<p:cSld><p:spTree>' +
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>' +
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>' +
      '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder"/><p:cNvSpPr>' +
      '<a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr>' +
      '<p:spPr/>' +
      '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="zh-CN"/></a:p></p:txBody></p:sp>' +
      '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>' +
      '<p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>' +
      '<p:spPr/>' +
      '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="zh-CN"/></a:p></p:txBody></p:sp>' +
      '</p:spTree></p:cSld>' +
      '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" ' +
      'accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>' +
      '<p:notesStyle><a:lvl1pPr><a:defRPr sz="1200"/></a:lvl1pPr></p:notesStyle>' +
      '</p:notesMaster>';
  }

  private static notesMasterRelsXml(): string {
    return XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>' +
      '</Relationships>';
  }

  // ===== 每页关系 =====

  private static slideRelsXml(ctx: SlideContext): string {
    let rels: string = '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>';
    let mediaIdx: number = 0;
    for (let i: number = 0; i < ctx.mediaParts.length; i++) {
      mediaIdx++;
      rels += '<Relationship Id="rId' + (mediaIdx + 1).toString() +
        '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/' +
        PptxBuilder.mediaName(ctx.index, mediaIdx - 1, ctx.mediaParts[i].ext) + '"/>';
    }
    for (let c: number = 0; c < ctx.chartXmls.length; c++) {
      mediaIdx++;
      rels += '<Relationship Id="rId' + (mediaIdx + 1).toString() +
        '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart' +
        (c < ctx.chartNos.length ? ctx.chartNos[c] : 1).toString() + '.xml"/>';
    }
    return XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + rels +
      '</Relationships>';
  }

  // ===== 部件 XML =====

  private static contentTypesXml(slideCount: number, contexts: SlideContext[]): string {
    let sb: string = '';
    sb += XML_HEAD;
    sb += '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">';
    sb += '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>';
    sb += '<Default Extension="xml" ContentType="application/xml"/>';
    sb += '<Default Extension="png" ContentType="image/png"/>';
    sb += '<Default Extension="jpeg" ContentType="image/jpeg"/>';
    sb += '<Default Extension="jpg" ContentType="image/jpeg"/>';
    sb += '<Default Extension="gif" ContentType="image/gif"/>';
    sb += '<Default Extension="bmp" ContentType="image/bmp"/>';
    sb += '<Default Extension="json" ContentType="application/json"/>';
    sb += '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>';
    sb += '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>';
    sb += '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>';
    sb += '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>';
    sb += '<Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml"/>';
    for (let i: number = 1; i <= slideCount; i++) {
      sb += '<Override PartName="/ppt/slides/slide' + i.toString() + '.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>';
    }
    let chartNo: number = 0;
    let notesNo: number = 0;
    for (let i: number = 0; i < contexts.length; i++) {
      for (let c: number = 0; c < contexts[i].chartXmls.length; c++) {
        chartNo++;
        sb += '<Override PartName="/ppt/charts/chart' + chartNo.toString() + '.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>';
      }
      if (contexts[i].hasNotes) {
        notesNo++;
        sb += '<Override PartName="/ppt/notesSlides/notesSlide' + notesNo.toString() + '.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"/>';
      }
    }
    sb += '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>';
    sb += '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>';
    sb += '</Types>';
    return sb;
  }

  private static rootRelsXml(): string {
    return XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>' +
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>' +
      '</Relationships>';
  }

  private static coreXml(title: string): string {
    let iso: string = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    return XML_HEAD +
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ' +
      'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
      '<dc:title>' + XmlUtil.escape(title) + '</dc:title>' +
      '<dc:creator>Guncat Work</dc:creator><cp:lastModifiedBy>Guncat Work</cp:lastModifiedBy>' +
      '<dcterms:created xsi:type="dcterms:W3CDTF">' + iso + '</dcterms:created>' +
      '<dcterms:modified xsi:type="dcterms:W3CDTF">' + iso + '</dcterms:modified>' +
      '</cp:coreProperties>';
  }

  private static appXml(slideCount: number): string {
    let titles: string = '';
    for (let i: number = 0; i < slideCount; i++) {
      titles += '<vt:lpstr>幻灯片 ' + (i + 1).toString() + '</vt:lpstr>';
    }
    return XML_HEAD +
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" ' +
      'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
      '<Application>Guncat Work</Application>' +
      '<HeadingPairs><vt:vector size="2" baseType="variant">' +
      '<vt:variant><vt:lpstr>幻灯片</vt:lpstr></vt:variant>' +
      '<vt:variant><vt:i4>' + slideCount.toString() + '</vt:i4></vt:variant>' +
      '</vt:vector></HeadingPairs>' +
      '<TitlesOfParts><vt:vector size="' + (slideCount + 1).toString() + '" baseType="lpstr">' +
      '<vt:lpstr>Office 主题</vt:lpstr>' + titles + '</vt:vector></TitlesOfParts>' +
      '</Properties>';
  }

  private static presentationXml(slideCount: number): string {
    let sldIds: string = '';
    for (let i: number = 0; i < slideCount; i++) {
      sldIds += '<p:sldId id="' + (256 + i).toString() + '" r:id="rId' + (i + 2).toString() + '"/>';
    }
    return XML_HEAD +
      '<p:presentation ' + NS_A + ' ' + NS_R + ' ' + NS_P + ' saveSubsetFonts="1">' +
      '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>' +
      '<p:notesMasterIdLst><p:notesMasterId id="2147483660" r:id="rId' + (slideCount + 2).toString() + '"/></p:notesMasterIdLst>' +
      '<p:sldIdLst>' + sldIds + '</p:sldIdLst>' +
      '<p:sldSz cx="' + SLIDE_W.toString() + '" cy="' + SLIDE_H.toString() + '"/>' +
      '<p:notesSz cx="6858000" cy="9144000"/>' +
      '</p:presentation>';
  }

  private static presentationRelsXml(slideCount: number): string {
    let rels: string = '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>';
    for (let i: number = 0; i < slideCount; i++) {
      rels += '<Relationship Id="rId' + (i + 2).toString() + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide' + (i + 1).toString() + '.xml"/>';
    }
    rels += '<Relationship Id="rId' + (slideCount + 2).toString() + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster" Target="notesMasters/notesMaster1.xml"/>';
    rels += '<Relationship Id="rId' + (slideCount + 3).toString() + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>';
    return XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + rels + '</Relationships>';
  }

  private static themeXml(colors: ThemeColors): string {
    let s: string[] = colors.series;
    return XML_HEAD +
      '<a:theme ' + NS_A + ' name="Guncat Deck">' +
      '<a:themeElements>' +
      '<a:clrScheme name="Deck">' +
      '<a:dk1><a:srgbClr val="' + colors.title + '"/></a:dk1>' +
      '<a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>' +
      '<a:dk2><a:srgbClr val="' + colors.body + '"/></a:dk2>' +
      '<a:lt2><a:srgbClr val="' + colors.surface + '"/></a:lt2>' +
      '<a:accent1><a:srgbClr val="' + colors.primary + '"/></a:accent1>' +
      '<a:accent2><a:srgbClr val="' + s[1 % s.length] + '"/></a:accent2>' +
      '<a:accent3><a:srgbClr val="' + s[2 % s.length] + '"/></a:accent3>' +
      '<a:accent4><a:srgbClr val="' + s[3 % s.length] + '"/></a:accent4>' +
      '<a:accent5><a:srgbClr val="' + s[4 % s.length] + '"/></a:accent5>' +
      '<a:accent6><a:srgbClr val="' + s[5 % s.length] + '"/></a:accent6>' +
      '<a:hlink><a:srgbClr val="' + colors.primary + '"/></a:hlink>' +
      '<a:folHlink><a:srgbClr val="' + colors.sub + '"/></a:folHlink>' +
      '</a:clrScheme>' +
      '<a:fontScheme name="Deck">' +
      '<a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>' +
      '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>' +
      '</a:fontScheme>' +
      '<a:fmtScheme name="Deck">' +
      '<a:fillStyleLst>' +
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' +
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' +
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' +
      '</a:fillStyleLst>' +
      '<a:lnStyleLst>' +
      '<a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>' +
      '<a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>' +
      '<a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>' +
      '</a:lnStyleLst>' +
      '<a:effectStyleLst>' +
      '<a:effectStyle><a:effectLst/></a:effectStyle>' +
      '<a:effectStyle><a:effectLst/></a:effectStyle>' +
      '<a:effectStyle><a:effectLst/></a:effectStyle>' +
      '</a:effectStyleLst>' +
      '<a:bgFillStyleLst>' +
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' +
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' +
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' +
      '</a:bgFillStyleLst>' +
      '</a:fmtScheme>' +
      '</a:themeElements>' +
      '</a:theme>';
  }

  private static slideMasterXml(): string {
    return XML_HEAD +
      '<p:sldMaster ' + NS_A + ' ' + NS_R + ' ' + NS_P + '>' +
      '<p:cSld><p:spTree>' +
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>' +
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>' +
      '</p:spTree></p:cSld>' +
      '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>' +
      '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>' +
      '</p:sldMaster>';
  }

  private static slideMasterRelsXml(): string {
    return XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>' +
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>' +
      '</Relationships>';
  }

  private static slideLayoutXml(): string {
    return XML_HEAD +
      '<p:sldLayout ' + NS_A + ' ' + NS_R + ' ' + NS_P + ' type="obj" preserve="1">' +
      '<p:cSld name="标题和内容"><p:spTree>' +
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>' +
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>' +
      '</p:spTree></p:cSld>' +
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
      '</p:sldLayout>';
  }

  private static slideLayoutRelsXml(): string {
    return XML_HEAD +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>' +
      '</Relationships>';
  }

  // ===== 底层工具 =====

  private static xmlEntry(name: string, xml: string): ZipEntry {
    let e: ZipEntry = new ZipEntry();
    e.name = name;
    e.data = PptxBuilder.stringToBytes(xml);
    return e;
  }

  // UTF-8 编码(含代理对), 与 DocxExporter 保持一致
  private static stringToBytes(text: string): Uint8Array {
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
