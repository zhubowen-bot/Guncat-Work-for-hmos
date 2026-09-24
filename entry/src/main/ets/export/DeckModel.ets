// DeckModel: 演示文稿的结构化中间层(Deck JSON) —— AI 可写、可编辑的 PPT 源
// 设计对齐 open-kimi-ppt-skill 的 PPTD 思想: 中间层与导出器分离,
// write_pptx 消费 Deck 渲染 pptx, read_ppt 把 pptx 还原为 Deck, edit_ppt 在 Deck 上应用操作算子。
// 本文件为纯逻辑模块(无 HarmonyOS API 依赖), 便于独立验证。

// 版式常量(与 ppt 技能文档保持一致)
export const DECK_LAYOUTS: string[] = ['cover', 'toc', 'section', 'content', 'two-col',
  'image-text', 'image', 'image-full', 'table', 'chart', 'quote', 'end', 'custom'];

// 单页最多要点数(超出按 7 条渲染并截断其余? 不截断, 仅提示)——不硬截断, 由设计规范约束
export const DECK_MAX_SLIDES: number = 80;

// ===== 结构类型 =====

// 要点条目
export class DeckBullet {
  text: string = '';
  level: number = 1; // 1 | 2
}

// 图片引用(src: 工作区相对路径 / data URL / http(s))
export class DeckImageRef {
  src: string = '';
  fit: string = 'contain'; // contain | cover | fill
}

// two-col 单栏
export class DeckColumn {
  heading: string = '';
  bullets: string[] = [];
}

// 图表数据的一个系列
export class DeckSeries {
  name: string = '';
  values: number[] = [];
}

// 图表数据
export class DeckChart {
  type: string = 'bar'; // bar | line | area | pie | doughnut
  categories: string[] = [];
  series: DeckSeries[] = [];
  showLegend: boolean = true;
  showValue: boolean = false;
}

// 表格数据
export class DeckTable {
  headers: string[] = [];
  rows: string[][] = [];
  widths: number[] = []; // 列宽比例, 可不填(均分)
  note: string = '';
}

// custom 版式的绝对定位元素(x/y/w/h 为 0~1 画布比例)
export class DeckElement {
  type: string = 'text'; // text | image | shape | table
  x: number = 0.1;
  y: number = 0.2;
  w: number = 0.8;
  h: number = 0.2;
  // text
  text: string = '';
  size: number = 18;
  bold: boolean = false;
  color: string = 'body';
  align: string = 'left'; // left | center | right
  // image
  src: string = '';
  fit: string = 'cover';
  // shape
  shape: string = 'rect'; // rect | roundRect | ellipse | triangle | arrow
  fill: string = 'primary';
  // table
  headers: string[] = [];
  rows: string[][] = [];
}

// 页面背景
export class DeckBackground {
  color: string = '';  // 语义色或 hex, 空则跟随主题
  image: string = '';  // 背景图 src(优先于 color)
  fit: string = 'cover';
  overlay: number = 0; // 0~1 深色遮罩(仅背景图时生效)
}

// 单页
export class DeckSlide {
  layout: string = 'content';
  title: string = '';
  subtitle: string = '';
  index: string = '';          // section 页编号(如 "01"), 空则自动编号
  bullets: DeckBullet[] = [];
  columns: DeckColumn[] = [];  // two-col 需要恰好 2 项
  image: DeckImageRef = new DeckImageRef();
  caption: string = '';
  table: DeckTable = new DeckTable();
  chart: DeckChart = new DeckChart();
  elements: DeckElement[] = [];
  background: DeckBackground = new DeckBackground();
  notes: string = '';
  text: string = '';           // quote 页引文
  author: string = '';         // quote 页署名
  imageSide: string = 'right'; // image-text: 图片在左(left)或右(right)
}

// 自定义主题色覆盖(空串字段继承所选预设)
export class DeckThemeOverride {
  primary: string = '';
  accent: string = '';
  bg: string = '';
  surface: string = '';
  title: string = '';
  body: string = '';
  sub: string = '';
  faint: string = '';
}

// 整册
export class Deck {
  title: string = '';
  theme: string = 'brand-blue';
  themeOverride: DeckThemeOverride = new DeckThemeOverride();
  slides: DeckSlide[] = [];
}

// ===== JSON 解析工具(ArkTS 安全: 全部走显式类型判断) =====

export class DeckJson {
  static asRec(v: Object): Record<string, Object> | null {
    if (typeof v === 'object' && v !== null && !(v instanceof Array)) {
      return v as Record<string, Object>;
    }
    return null;
  }

  static asStr(v: Object | undefined, def: string): string {
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return def;
  }

  static asNum(v: Object | undefined, def: number): number {
    if (typeof v === 'number' && !isNaN(v as number)) {
      return v as number;
    }
    if (typeof v === 'string') {
      let n: number = parseFloat(v as string);
      if (!isNaN(n)) {
        return n;
      }
    }
    return def;
  }

  static asBool(v: Object | undefined, def: boolean): boolean {
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'string') {
      let s: string = (v as string).toLowerCase();
      if (s === 'true' || s === '1') {
        return true;
      }
      if (s === 'false' || s === '0') {
        return false;
      }
    }
    return def;
  }

  static asStrArr(v: Object | undefined): string[] {
    let out: string[] = [];
    if (v instanceof Array) {
      let arr: Object[] = v as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        out.push(DeckJson.asStr(arr[i], ''));
      }
    }
    return out;
  }

  static asNumArr(v: Object | undefined): number[] {
    let out: number[] = [];
    if (v instanceof Array) {
      let arr: Object[] = v as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        out.push(DeckJson.asNum(arr[i], 0));
      }
    }
    return out;
  }
}

// ===== Deck JSON -> Deck =====

export class DeckParser {
  // 解析并校验; 失败抛 Error(信息面向 AI, 便于其自行修正)
  static parse(deckJson: string): Deck {
    if (deckJson.trim() === '') {
      throw new Error('deck 为空。Deck JSON 形如 {"title":"标题","slides":[{"layout":"content","title":"页标题","bullets":["要点1","要点2"]}]}');
    }
    let root: Object;
    try {
      root = JSON.parse(deckJson);
    } catch (e) {
      throw new Error('deck 不是合法的 JSON: ' + DeckParser.errMsg(e) +
        '。注意 deck 参数是 JSON 字符串, 字符串值内部的引号需要转义');
    }
    let rec: Record<string, Object> | null = DeckJson.asRec(root);
    if (rec === null) {
      throw new Error('deck 需要是 JSON 对象, 如 {"title":"标题","slides":[...]}');
    }
    let deck: Deck = new Deck();
    deck.title = DeckJson.asStr(rec['title'], '').trim();
    deck.theme = DeckJson.asStr(rec['theme'], 'brand-blue').trim();
    let overrideRec: Record<string, Object> | null = DeckJson.asRec(rec['themeOverride']);
    if (overrideRec !== null) {
      deck.themeOverride.primary = DeckJson.asStr(overrideRec['primary'], '').replace('#', '').trim();
      deck.themeOverride.accent = DeckJson.asStr(overrideRec['accent'], '').replace('#', '').trim();
      deck.themeOverride.bg = DeckJson.asStr(overrideRec['bg'], '').replace('#', '').trim();
      deck.themeOverride.surface = DeckJson.asStr(overrideRec['surface'], '').replace('#', '').trim();
      deck.themeOverride.title = DeckJson.asStr(overrideRec['title'], '').replace('#', '').trim();
      deck.themeOverride.body = DeckJson.asStr(overrideRec['body'], '').replace('#', '').trim();
      deck.themeOverride.sub = DeckJson.asStr(overrideRec['sub'], '').replace('#', '').trim();
      deck.themeOverride.faint = DeckJson.asStr(overrideRec['faint'], '').replace('#', '').trim();
    }
    let slidesVal: Object = rec['slides'];
    if (!(slidesVal instanceof Array)) {
      throw new Error('deck 缺少 slides 数组, 如 {"slides":[{"layout":"content","title":"页标题","bullets":["要点"]}]}');
    }
    let slideArr: Object[] = slidesVal as Object[];
    if (slideArr.length === 0) {
      throw new Error('slides 为空, 至少需要一页');
    }
    if (slideArr.length > DECK_MAX_SLIDES) {
      throw new Error('slides 最多 ' + DECK_MAX_SLIDES.toString() + ' 页(当前 ' +
        slideArr.length.toString() + ' 页); 更长的 deck 请分两批: 先生成前半, 再用 edit_ppt 的 add_slide 追加');
    }
    for (let i: number = 0; i < slideArr.length; i++) {
      deck.slides.push(DeckParser.parseSlide(slideArr[i], i + 1));
    }
    if (deck.title === '') {
      // 未提供 title 时取第一个非空页标题
      for (let i: number = 0; i < deck.slides.length; i++) {
        if (deck.slides[i].title !== '') {
          deck.title = deck.slides[i].title;
          break;
        }
      }
    }
    return deck;
  }

  // DeckOps 跨类调用, 不能声明为 private(TS/ArkTS 的 private 是类级)
  static parseSlide(v: Object, pageNo: number): DeckSlide {
    let rec: Record<string, Object> | null = DeckJson.asRec(v);
    if (rec === null) {
      throw new Error('第 ' + pageNo.toString() + ' 页不是 JSON 对象');
    }
    let slide: DeckSlide = new DeckSlide();
    slide.layout = DeckJson.asStr(rec['layout'], 'content').trim();
    let known: boolean = false;
    for (let i: number = 0; i < DECK_LAYOUTS.length; i++) {
      if (DECK_LAYOUTS[i] === slide.layout) {
        known = true;
        break;
      }
    }
    if (!known) {
      throw new Error('第 ' + pageNo.toString() + ' 页 layout="' + slide.layout +
        '" 不支持。可用: ' + DECK_LAYOUTS.join(' / '));
    }
    slide.title = DeckJson.asStr(rec['title'], '');
    slide.subtitle = DeckJson.asStr(rec['subtitle'], '');
    slide.index = DeckJson.asStr(rec['index'], '');
    slide.caption = DeckJson.asStr(rec['caption'], '');
    slide.notes = DeckJson.asStr(rec['notes'], '');
    slide.text = DeckJson.asStr(rec['text'], '');
    slide.author = DeckJson.asStr(rec['author'], '');
    slide.imageSide = DeckJson.asStr(rec['imageSide'], 'right') === 'left' ? 'left' : 'right';

    // bullets: 字符串或 {text, level} 混合数组
    let bulletsVal: Object = rec['bullets'];
    if (bulletsVal instanceof Array) {
      let arr: Object[] = bulletsVal as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        let item: Object = arr[i];
        if (typeof item === 'string') {
          let b: DeckBullet = new DeckBullet();
          b.text = item as string;
          b.level = 1;
          slide.bullets.push(b);
        } else {
          let brec: Record<string, Object> | null = DeckJson.asRec(item);
          if (brec !== null) {
            let b: DeckBullet = new DeckBullet();
            b.text = DeckJson.asStr(brec['text'], '');
            b.level = DeckJson.asNum(brec['level'], 1) >= 2 ? 2 : 1;
            if (b.text !== '') {
              slide.bullets.push(b);
            }
          }
        }
      }
    }

    // two-col: left/right 或 columns 数组
    let leftRec: Record<string, Object> | null = DeckJson.asRec(rec['left']);
    let rightRec: Record<string, Object> | null = DeckJson.asRec(rec['right']);
    if (leftRec !== null || rightRec !== null) {
      slide.columns.push(DeckParser.parseColumn(leftRec));
      slide.columns.push(DeckParser.parseColumn(rightRec));
    } else {
      let colsVal: Object = rec['columns'];
      if (colsVal instanceof Array) {
        let cols: Object[] = colsVal as Object[];
        for (let i: number = 0; i < cols.length && i < 2; i++) {
          slide.columns.push(DeckParser.parseColumn(DeckJson.asRec(cols[i])));
        }
      }
    }

    // image: 对象或字符串(路径)
    let imageVal: Object = rec['image'];
    if (typeof imageVal === 'string') {
      slide.image.src = imageVal as string;
    } else {
      let imageRec: Record<string, Object> | null = DeckJson.asRec(imageVal);
      if (imageRec !== null) {
        slide.image.src = DeckJson.asStr(imageRec['src'], '');
        slide.image.fit = DeckJson.asStr(imageRec['fit'], 'contain');
        if (slide.image.fit !== 'contain' && slide.image.fit !== 'cover' && slide.image.fit !== 'fill') {
          slide.image.fit = 'contain';
        }
      }
    }

    // table: 对象或 {headers, rows} 内联在页上
    let tableVal: Object = rec['table'];
    let tableRec: Record<string, Object> | null = DeckJson.asRec(tableVal);
    if (tableRec !== null) {
      slide.table = DeckParser.parseTable(tableRec);
    } else {
      slide.table.headers = DeckJson.asStrArr(rec['headers']);
      let rowsVal: Object = rec['rows'];
      if (rowsVal instanceof Array) {
        let rows: Object[] = rowsVal as Object[];
        for (let i: number = 0; i < rows.length; i++) {
          slide.table.rows.push(DeckJson.asStrArr(rows[i]));
        }
      }
      slide.table.widths = DeckJson.asNumArr(rec['widths']);
      slide.table.note = DeckJson.asStr(rec['note'], '');
    }

    // chart
    let chartRec: Record<string, Object> | null = DeckJson.asRec(rec['chart']);
    if (chartRec !== null) {
      slide.chart.type = DeckJson.asStr(chartRec['type'], 'bar').trim().toLowerCase();
      if (slide.chart.type !== 'bar' && slide.chart.type !== 'line' &&
        slide.chart.type !== 'area' && slide.chart.type !== 'pie' && slide.chart.type !== 'doughnut') {
        throw new Error('第 ' + pageNo.toString() + ' 页 chart.type="' + slide.chart.type +
          '" 不支持。可用: bar / line / area / pie / doughnut');
      }
      slide.chart.categories = DeckJson.asStrArr(chartRec['categories']);
      let seriesVal: Object = chartRec['series'];
      if (seriesVal instanceof Array) {
        let series: Object[] = seriesVal as Object[];
        for (let i: number = 0; i < series.length; i++) {
          let srec: Record<string, Object> | null = DeckJson.asRec(series[i]);
          if (srec === null) {
            continue;
          }
          let s: DeckSeries = new DeckSeries();
          s.name = DeckJson.asStr(srec['name'], '系列' + (i + 1).toString());
          s.values = DeckJson.asNumArr(srec['values']);
          slide.chart.series.push(s);
        }
      }
      slide.chart.showLegend = DeckJson.asBool(chartRec['showLegend'], true);
      slide.chart.showValue = DeckJson.asBool(chartRec['showValue'], false);
    }

    // elements (custom)
    let elementsVal: Object = rec['elements'];
    if (elementsVal instanceof Array) {
      let els: Object[] = elementsVal as Object[];
      if (els.length > 30) {
        throw new Error('第 ' + pageNo.toString() + ' 页 elements 最多 30 个');
      }
      for (let i: number = 0; i < els.length; i++) {
        let el: DeckElement | null = DeckParser.parseElement(els[i], pageNo, i + 1);
        if (el !== null) {
          slide.elements.push(el);
        }
      }
    }

    // background
    let bgVal: Object = rec['background'];
    if (typeof bgVal === 'string') {
      slide.background.color = bgVal as string;
    } else {
      let bgRec: Record<string, Object> | null = DeckJson.asRec(bgVal);
      if (bgRec !== null) {
        slide.background.color = DeckJson.asStr(bgRec['color'], '');
        slide.background.image = DeckJson.asStr(bgRec['image'], '');
        slide.background.fit = DeckJson.asStr(bgRec['fit'], 'cover');
        slide.background.overlay = DeckJson.asNum(bgRec['overlay'], 0);
      }
    }

    // 版式必备字段校验
    DeckParser.validateSlide(slide, pageNo);
    return slide;
  }

  private static parseColumn(rec: Record<string, Object> | null): DeckColumn {
    let col: DeckColumn = new DeckColumn();
    if (rec === null) {
      return col;
    }
    col.heading = DeckJson.asStr(rec['heading'], '');
    col.bullets = DeckJson.asStrArr(rec['bullets']);
    return col;
  }

  private static parseTable(rec: Record<string, Object>): DeckTable {
    let t: DeckTable = new DeckTable();
    t.headers = DeckJson.asStrArr(rec['headers']);
    let rowsVal: Object = rec['rows'];
    if (rowsVal instanceof Array) {
      let rows: Object[] = rowsVal as Object[];
      for (let i: number = 0; i < rows.length; i++) {
        t.rows.push(DeckJson.asStrArr(rows[i]));
      }
    }
    t.widths = DeckJson.asNumArr(rec['widths']);
    t.note = DeckJson.asStr(rec['note'], '');
    return t;
  }

  private static parseElement(v: Object, pageNo: number, elNo: number): DeckElement | null {
    let rec: Record<string, Object> | null = DeckJson.asRec(v);
    if (rec === null) {
      return null;
    }
    let el: DeckElement = new DeckElement();
    el.type = DeckJson.asStr(rec['type'], 'text');
    if (el.type !== 'text' && el.type !== 'image' && el.type !== 'shape' && el.type !== 'table') {
      throw new Error('第 ' + pageNo.toString() + ' 页第 ' + elNo.toString() +
        ' 个元素 type="' + el.type + '" 不支持。可用: text / image / shape / table');
    }
    el.x = DeckParser.ratio(DeckJson.asNum(rec['x'], 0.1), 'x', pageNo, elNo);
    el.y = DeckParser.ratio(DeckJson.asNum(rec['y'], 0.2), 'y', pageNo, elNo);
    el.w = DeckParser.ratio(DeckJson.asNum(rec['w'], 0.8), 'w', pageNo, elNo);
    el.h = DeckParser.ratio(DeckJson.asNum(rec['h'], 0.2), 'h', pageNo, elNo);
    el.text = DeckJson.asStr(rec['text'], '');
    el.size = DeckJson.asNum(rec['size'], 18);
    if (el.size < 8) {
      el.size = 8;
    } else if (el.size > 96) {
      el.size = 96;
    }
    el.bold = DeckJson.asBool(rec['bold'], false);
    el.color = DeckJson.asStr(rec['color'], 'body');
    el.align = DeckJson.asStr(rec['align'], 'left');
    if (el.align !== 'left' && el.align !== 'center' && el.align !== 'right') {
      el.align = 'left';
    }
    el.src = DeckJson.asStr(rec['src'], '');
    el.fit = DeckJson.asStr(rec['fit'], 'cover');
    el.shape = DeckJson.asStr(rec['shape'], 'rect');
    el.fill = DeckJson.asStr(rec['fill'], 'primary');
    el.headers = DeckJson.asStrArr(rec['headers']);
    let rowsVal: Object = rec['rows'];
    if (rowsVal instanceof Array) {
      let rows: Object[] = rowsVal as Object[];
      for (let i: number = 0; i < rows.length; i++) {
        el.rows.push(DeckJson.asStrArr(rows[i]));
      }
    }
    return el;
  }

  private static ratio(v: number, field: string, pageNo: number, elNo: number): number {
    if (v < 0) {
      throw new Error('第 ' + pageNo.toString() + ' 页第 ' + elNo.toString() + ' 个元素 ' +
        field + ' 不能为负(坐标是 0~1 的画布比例)');
    }
    if (v > 1) {
      throw new Error('第 ' + pageNo.toString() + ' 页第 ' + elNo.toString() + ' 个元素 ' +
        field + '=' + v.toString() + ' 超出范围——custom 元素坐标是 0~1 的画布比例, 不是像素');
    }
    return v;
  }

  // 同上: 被 DeckOps.mergeSlide 复用
  static validateSlide(slide: DeckSlide, pageNo: number): void {
    let need: string = '';
    if (slide.layout === 'image' || slide.layout === 'image-full' || slide.layout === 'image-text') {
      if (slide.image.src === '') {
        need = 'image.src(图片路径: 工作区相对路径 / data URL / http(s))';
      }
    }
    if (slide.layout === 'table' && slide.table.headers.length === 0 && slide.table.rows.length === 0) {
      need = 'table 的 headers/rows';
    }
    if (slide.layout === 'chart') {
      if (slide.chart.categories.length === 0) {
        need = 'chart.categories';
      } else if (slide.chart.series.length === 0) {
        need = 'chart.series(至少 1 个系列 {name, values})';
      }
    }
    if (slide.layout === 'quote' && slide.text === '') {
      need = 'text(引文内容)';
    }
    if (slide.layout === 'custom' && slide.elements.length === 0) {
      need = 'elements(至少 1 个元素)';
    }
    if (need !== '') {
      throw new Error('第 ' + pageNo.toString() + ' 页(layout=' + slide.layout + ') 缺少 ' + need);
    }
    let hasContent: boolean = slide.title !== '' || slide.bullets.length > 0 ||
      slide.columns.length > 0 || slide.image.src !== '' || slide.table.rows.length > 0 ||
      slide.chart.series.length > 0 || slide.text !== '' || slide.elements.length > 0;
    if (!hasContent) {
      throw new Error('第 ' + pageNo.toString() + ' 页(layout=' + slide.layout +
        ') 没有任何内容; 若是章节间隔页请用 layout=section');
    }
  }

  private static errMsg(e: Object): string {
    if (e instanceof Error) {
      let err: Error = e as Error;
      return err.message !== undefined ? err.message : String(e);
    }
    return String(e);
  }
}

// ===== 简易大纲(兼容旧格式) -> Deck =====

export class DeckOutline {
  // 兼容 write_pptx 旧 outline 格式:
  //   "# 标题" -> 内容页; "## 标题" -> 分节页; "- 要点"/普通行 -> 一级要点; 缩进"- " -> 二级要点
  static parse(outline: string, title: string): Deck {
    let deck: Deck = new Deck();
    deck.title = title;
    let lines: string[] = outline.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      let raw: string = lines[i].replace(/\t/g, '  ');
      let trimmed: string = raw.trim();
      if (trimmed === '') {
        continue;
      }
      if (trimmed.startsWith('#')) {
        let slide: DeckSlide = new DeckSlide();
        slide.layout = trimmed.startsWith('##') ? 'section' : 'content';
        slide.title = trimmed.replace(/^#+\s*/, '');
        deck.slides.push(slide);
        continue;
      }
      if (deck.slides.length === 0) {
        let first: DeckSlide = new DeckSlide();
        first.layout = 'content';
        first.title = title;
        deck.slides.push(first);
      }
      let text: string = trimmed.replace(/^[-*•]\s*/, '');
      if (text === '') {
        continue;
      }
      let indent: number = raw.length - raw.replace(/^\s+/, '').length;
      let b: DeckBullet = new DeckBullet();
      b.text = text;
      b.level = indent >= 2 ? 2 : 1;
      deck.slides[deck.slides.length - 1].bullets.push(b);
    }
    if (deck.slides.length === 0 && title.trim() !== '') {
      let cover: DeckSlide = new DeckSlide();
      cover.layout = 'cover';
      cover.title = title;
      deck.slides.push(cover);
    }
    return deck;
  }
}

// ===== 编辑算子(edit_ppt) =====

export class DeckOps {
  // 对 deck 应用操作数组, 返回可读的执行摘要; 非法操作抛 Error(整批不生效)
  static apply(deck: Deck, opsJson: string): string {
    let root: Object;
    try {
      root = JSON.parse(opsJson);
    } catch (e) {
      throw new Error('ops 不是合法的 JSON 数组, 如 [{"op":"add_slide","slide":{"layout":"content","title":"新页","bullets":["要点"]}}]');
    }
    if (!(root instanceof Array)) {
      throw new Error('ops 需要是 JSON 数组, 如 [{"op":"add_slide","slide":{...}}]');
    }
    let arr: Object[] = root as Object[];
    if (arr.length === 0) {
      throw new Error('ops 为空');
    }
    if (arr.length > 50) {
      throw new Error('ops 单次最多 50 个操作');
    }
    let lines: string[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      let rec: Record<string, Object> | null = DeckJson.asRec(arr[i]);
      if (rec === null) {
        throw new Error('第 ' + (i + 1).toString() + ' 个操作不是 JSON 对象');
      }
      let op: string = DeckJson.asStr(rec['op'], '');
      if (op === 'add_slide') {
        let slideVal: Object = rec['slide'];
        let slidesVal: Object = rec['slides'];
        let added: number = 0;
        let list: Object[] = [];
        if (slideVal !== undefined && slideVal !== null) {
          list.push(slideVal);
        }
        if (slidesVal instanceof Array) {
          list = list.concat(slidesVal as Object[]);
        }
        if (list.length === 0) {
          throw new Error('add_slide 缺少 slide(或 slides)字段');
        }
        let insertAt: number = DeckOps.indexArg(rec['index'], deck.slides.length);
        if (insertAt < 0 || insertAt > deck.slides.length) {
          insertAt = deck.slides.length;
        }
        for (let s: number = 0; s < list.length; s++) {
          let slide: DeckSlide = DeckParser.parseSlide(list[s], insertAt + s + 1);
          // section 编号由导出器在渲染时统一自动分配, 此处不写死
          if (insertAt >= deck.slides.length) {
            deck.slides.push(slide);
          } else {
            deck.slides.splice(insertAt, 0, slide);
          }
          insertAt++;
          added++;
        }
        if (deck.slides.length > DECK_MAX_SLIDES) {
          throw new Error('追加后超过 ' + DECK_MAX_SLIDES.toString() + ' 页上限');
        }
        lines.push('add_slide: 新增 ' + added.toString() + ' 页(现共 ' + deck.slides.length.toString() + ' 页)');
      } else if (op === 'delete_slide') {
        let idx: number = DeckOps.indexArg(rec['index'], -1);
        if (idx < 0 || idx >= deck.slides.length) {
          throw new Error('delete_slide 的 index=' + (idx + 1).toString() +
            ' 超出范围(1-' + deck.slides.length.toString() + ')');
        }
        let title: string = deck.slides[idx].title;
        deck.slides.splice(idx, 1);
        lines.push('delete_slide: 删除第 ' + (idx + 1).toString() + ' 页(' + (title === '' ? '无标题' : title) + ')');
      } else if (op === 'move_slide') {
        let from: number = DeckOps.indexArg(rec['from'], -1);
        let to: number = DeckOps.indexArg(rec['to'], -1);
        if (from < 0 || from >= deck.slides.length || to < 0 || to >= deck.slides.length) {
          throw new Error('move_slide 的 from/to 超出范围(1-' + deck.slides.length.toString() + ')');
        }
        if (from !== to) {
          let s: DeckSlide = deck.slides[from];
          deck.slides.splice(from, 1);
          deck.slides.splice(to, 0, s);
        }
        lines.push('move_slide: 第 ' + (from + 1).toString() + ' 页移到第 ' + (to + 1).toString() + ' 位');
      } else if (op === 'update_slide') {
        let idx: number = DeckOps.indexArg(rec['index'], -1);
        if (idx < 0 || idx >= deck.slides.length) {
          throw new Error('update_slide 的 index 超出范围(1-' + deck.slides.length.toString() + ')');
        }
        let patch: Record<string, Object> | null = DeckJson.asRec(rec['slide']);
        if (patch === null) {
          throw new Error('update_slide 缺少 slide 字段(要更新的字段, 如 {"title":"新标题"})');
        }
        DeckOps.mergeSlide(deck.slides[idx], patch, idx + 1);
        lines.push('update_slide: 更新第 ' + (idx + 1).toString() + ' 页');
      } else if (op === 'replace_text') {
        let find: string = DeckJson.asStr(rec['find'], '');
        let replace: string = DeckJson.asStr(rec['replace'], '');
        if (find === '') {
          throw new Error('replace_text 缺少 find');
        }
        let count: number = DeckOps.replaceText(deck, find, replace);
        lines.push('replace_text: "' + find + '" → "' + replace + '" 替换 ' + count.toString() + ' 处');
      } else if (op === 'set_theme') {
        let theme: string = DeckJson.asStr(rec['theme'], '');
        if (theme === '') {
          throw new Error('set_theme 缺少 theme');
        }
        deck.theme = theme;
        let themeRec: Record<string, Object> | null = DeckJson.asRec(rec['themeOverride']);
        if (themeRec !== null) {
          deck.themeOverride.primary = DeckJson.asStr(themeRec['primary'], deck.themeOverride.primary).replace('#', '');
          deck.themeOverride.accent = DeckJson.asStr(themeRec['accent'], deck.themeOverride.accent).replace('#', '');
          deck.themeOverride.bg = DeckJson.asStr(themeRec['bg'], deck.themeOverride.bg).replace('#', '');
          deck.themeOverride.title = DeckJson.asStr(themeRec['title'], deck.themeOverride.title).replace('#', '');
          deck.themeOverride.body = DeckJson.asStr(themeRec['body'], deck.themeOverride.body).replace('#', '');
        }
        lines.push('set_theme: ' + theme);
      } else if (op === 'set_title') {
        deck.title = DeckJson.asStr(rec['title'], deck.title);
        lines.push('set_title: ' + deck.title);
      } else if (op === 'set_notes') {
        let idx: number = DeckOps.indexArg(rec['index'], -1);
        if (idx < 0 || idx >= deck.slides.length) {
          throw new Error('set_notes 的 index 超出范围(1-' + deck.slides.length.toString() + ')');
        }
        deck.slides[idx].notes = DeckJson.asStr(rec['notes'], '');
        lines.push('set_notes: 第 ' + (idx + 1).toString() + ' 页备注' + (deck.slides[idx].notes === '' ? '已清空' : '已更新'));
      } else {
        throw new Error('未知操作 "' + op + '"。支持: add_slide / delete_slide / move_slide / update_slide / replace_text / set_theme / set_title / set_notes');
      }
    }
    return lines.join('\n');
  }

  private static indexArg(v: Object | undefined, def: number): number {
    let n: number = DeckJson.asNum(v, def);
    return Math.floor(n) - 1; // 对外 1 基
  }

  private static parseColumnFromRec(rec: Record<string, Object> | null): DeckColumn {
    let col: DeckColumn = new DeckColumn();
    if (rec !== null) {
      col.heading = DeckJson.asStr(rec['heading'], '');
      col.bullets = DeckJson.asStrArr(rec['bullets']);
    }
    return col;
  }

  // 部分字段合并(提供的字段覆盖, 未提供的保留)
  private static mergeSlide(target: DeckSlide, patch: Record<string, Object>, pageNo: number): void {
    if (patch['layout'] !== undefined) {
      target.layout = DeckJson.asStr(patch['layout'], target.layout).trim();
      let known: boolean = false;
      for (let i: number = 0; i < DECK_LAYOUTS.length; i++) {
        if (DECK_LAYOUTS[i] === target.layout) {
          known = true;
          break;
        }
      }
      if (!known) {
        throw new Error('第 ' + pageNo.toString() + ' 页 layout="' + target.layout + '" 不支持');
      }
    }
    if (patch['title'] !== undefined) {
      target.title = DeckJson.asStr(patch['title'], target.title);
    }
    if (patch['subtitle'] !== undefined) {
      target.subtitle = DeckJson.asStr(patch['subtitle'], target.subtitle);
    }
    if (patch['index'] !== undefined) {
      target.index = DeckJson.asStr(patch['index'], target.index);
    }
    if (patch['caption'] !== undefined) {
      target.caption = DeckJson.asStr(patch['caption'], target.caption);
    }
    if (patch['notes'] !== undefined) {
      target.notes = DeckJson.asStr(patch['notes'], target.notes);
    }
    if (patch['text'] !== undefined) {
      target.text = DeckJson.asStr(patch['text'], target.text);
    }
    if (patch['author'] !== undefined) {
      target.author = DeckJson.asStr(patch['author'], target.author);
    }
    if (patch['imageSide'] !== undefined) {
      target.imageSide = DeckJson.asStr(patch['imageSide'], target.imageSide) === 'left' ? 'left' : 'right';
    }
    if (patch['bullets'] !== undefined) {
      let bulletsVal: Object = patch['bullets'];
      if (bulletsVal instanceof Array) {
        target.bullets = [];
        let arr: Object[] = bulletsVal as Object[];
        for (let i: number = 0; i < arr.length; i++) {
          let item: Object = arr[i];
          let b: DeckBullet = new DeckBullet();
          if (typeof item === 'string') {
            b.text = item as string;
          } else {
            let brec: Record<string, Object> | null = DeckJson.asRec(item);
            if (brec === null) {
              continue;
            }
            b.text = DeckJson.asStr(brec['text'], '');
            b.level = DeckJson.asNum(brec['level'], 1) >= 2 ? 2 : 1;
          }
          if (b.text !== '') {
            target.bullets.push(b);
          }
        }
      }
    }
    if (patch['left'] !== undefined || patch['right'] !== undefined || patch['columns'] !== undefined) {
      target.columns = [];
      let leftRec: Record<string, Object> | null = DeckJson.asRec(patch['left']);
      let rightRec: Record<string, Object> | null = DeckJson.asRec(patch['right']);
      if (leftRec !== null || rightRec !== null) {
        target.columns.push(DeckOps.parseColumnFromRec(leftRec));
        target.columns.push(DeckOps.parseColumnFromRec(rightRec));
      } else {
        let colsVal: Object = patch['columns'];
        if (colsVal instanceof Array) {
          let cols: Object[] = colsVal as Object[];
          for (let i: number = 0; i < cols.length && i < 2; i++) {
            target.columns.push(DeckOps.parseColumnFromRec(DeckJson.asRec(cols[i])));
          }
        }
      }
    }
    if (patch['image'] !== undefined) {
      let imageVal: Object = patch['image'];
      if (typeof imageVal === 'string') {
        target.image.src = imageVal as string;
      } else {
        let imageRec: Record<string, Object> | null = DeckJson.asRec(imageVal);
        if (imageRec !== null) {
          target.image.src = DeckJson.asStr(imageRec['src'], target.image.src);
          target.image.fit = DeckJson.asStr(imageRec['fit'], target.image.fit);
        }
      }
    }
    if (patch['table'] !== undefined) {
      let trec: Record<string, Object> | null = DeckJson.asRec(patch['table']);
      if (trec !== null) {
        let t: DeckTable = new DeckTable();
        t.headers = DeckJson.asStrArr(trec['headers']);
        let rowsVal: Object = trec['rows'];
        if (rowsVal instanceof Array) {
          let rows: Object[] = rowsVal as Object[];
          for (let i: number = 0; i < rows.length; i++) {
            t.rows.push(DeckJson.asStrArr(rows[i]));
          }
        }
        t.widths = DeckJson.asNumArr(trec['widths']);
        t.note = DeckJson.asStr(trec['note'], '');
        target.table = t;
      }
    }
    if (patch['chart'] !== undefined) {
      let crec: Record<string, Object> | null = DeckJson.asRec(patch['chart']);
      if (crec !== null) {
        let c: DeckChart = new DeckChart();
        c.type = DeckJson.asStr(crec['type'], target.chart.type).toLowerCase();
        c.categories = DeckJson.asStrArr(crec['categories']);
        let seriesVal: Object = crec['series'];
        if (seriesVal instanceof Array) {
          let series: Object[] = seriesVal as Object[];
          for (let i: number = 0; i < series.length; i++) {
            let srec: Record<string, Object> | null = DeckJson.asRec(series[i]);
            if (srec === null) {
              continue;
            }
            let s: DeckSeries = new DeckSeries();
            s.name = DeckJson.asStr(srec['name'], '系列' + (i + 1).toString());
            s.values = DeckJson.asNumArr(srec['values']);
            c.series.push(s);
          }
        }
        c.showLegend = DeckJson.asBool(crec['showLegend'], target.chart.showLegend);
        c.showValue = DeckJson.asBool(crec['showValue'], target.chart.showValue);
        target.chart = c;
      }
    }
    if (patch['background'] !== undefined) {
      let bgVal: Object = patch['background'];
      if (typeof bgVal === 'string') {
        target.background.color = bgVal as string;
      } else {
        let bgRec: Record<string, Object> | null = DeckJson.asRec(bgVal);
        if (bgRec !== null) {
          target.background.color = DeckJson.asStr(bgRec['color'], target.background.color);
          target.background.image = DeckJson.asStr(bgRec['image'], target.background.image);
          target.background.overlay = DeckJson.asNum(bgRec['overlay'], target.background.overlay);
        }
      }
    }
    DeckParser.validateSlide(target, pageNo);
  }

  private static replaceText(deck: Deck, find: string, replace: string): number {
    let count: number = 0;
    for (let i: number = 0; i < deck.slides.length; i++) {
      let s: DeckSlide = deck.slides[i];
      count += DeckOps.replaceIn(s, 'title', find, replace);
      count += DeckOps.replaceIn(s, 'subtitle', find, replace);
      count += DeckOps.replaceIn(s, 'text', find, replace);
      count += DeckOps.replaceIn(s, 'caption', find, replace);
      count += DeckOps.replaceIn(s, 'notes', find, replace);
      count += DeckOps.replaceIn(s, 'author', find, replace);
      for (let b: number = 0; b < s.bullets.length; b++) {
        count += DeckOps.replaceIn(s.bullets[b], 'text', find, replace);
      }
      for (let c: number = 0; c < s.columns.length; c++) {
        count += DeckOps.replaceIn(s.columns[c], 'heading', find, replace);
        for (let k: number = 0; k < s.columns[c].bullets.length; k++) {
          if (s.columns[c].bullets[k].indexOf(find) !== -1) {
            s.columns[c].bullets[k] = s.columns[c].bullets[k].split(find).join(replace);
            count++;
          }
        }
      }
      for (let h: number = 0; h < s.table.headers.length; h++) {
        if (s.table.headers[h].indexOf(find) !== -1) {
          s.table.headers[h] = s.table.headers[h].split(find).join(replace);
          count++;
        }
      }
      for (let r: number = 0; r < s.table.rows.length; r++) {
        for (let c2: number = 0; c2 < s.table.rows[r].length; c2++) {
          if (s.table.rows[r][c2].indexOf(find) !== -1) {
            s.table.rows[r][c2] = s.table.rows[r][c2].split(find).join(replace);
            count++;
          }
        }
      }
      for (let e: number = 0; e < s.elements.length; e++) {
        count += DeckOps.replaceIn(s.elements[e], 'text', find, replace);
      }
    }
    if (deck.title.indexOf(find) !== -1) {
      deck.title = deck.title.split(find).join(replace);
      count++;
    }
    return count;
  }

  // 对对象指定字符串字段做替换(字段存在且为字符串才生效), 返回替换次数
  private static replaceIn(owner: Object, field: string, find: string, replace: string): number {
    let rec: Record<string, Object> = owner as Record<string, Object>;
    let v: Object = rec[field];
    if (typeof v === 'string') {
      let s: string = v as string;
      if (s.indexOf(find) !== -1) {
        rec[field] = s.split(find).join(replace);
        return 1;
      }
    }
    return 0;
  }
}
