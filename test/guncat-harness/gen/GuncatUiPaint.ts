// 交互模式 (Intelligent UI) 图表几何与数值格式化 —— 纯逻辑, 无 ArkUI 依赖。
//
// 渲染层用 Shape + Path(声明式)画图, 因此这里只负责"给定数据算路径字符串":
// 坐标空间固定(折线 320×160 / 饼图 200×200 / 雷达 220×220), 由 aspectRatio 保证等比缩放,
// 不会因为容器宽度变化而把线拉粗。
//
// 与参考项目的取舍: 参考项目用 Recharts(浏览器 DOM/SVG), 这里用 ArkUI 的 Shape+Path 等价重画,
// 保留同一套语义(多序列、堆叠、环形、径向), 但不做 tooltip 悬停(移动端以直接标注数值代替)。

export class UiPalette {
  // 与项目品牌色同族: 蓝为主, 依次绿/橙/紫/青/红, 保证深浅色模式都可读
  static readonly SERIES: string[] = [
    '#4176E6', '#34C77B', '#F5A524', '#A855F7', '#22B8CF', '#EF4444',
    '#6366F1', '#EC4899'
  ];
  // 分类色(饼图/径向): 对比更强
  static readonly CATEGORY: string[] = [
    '#4176E6', '#34C77B', '#F5A524', '#A855F7', '#22B8CF', '#EF4444',
    '#0EA5E9', '#84CC16', '#F97316', '#D946EF'
  ];
  static readonly GRID: string = '#0F000000';
  static readonly AXIS: string = '#3381858C';

  static series(i: number): string {
    return UiPalette.SERIES[i % UiPalette.SERIES.length];
  }

  static category(i: number): string {
    return UiPalette.CATEGORY[i % UiPalette.CATEGORY.length];
  }
}

export class UiNum {
  // 千分位: 1284 → 1,284
  static thousands(n: number): string {
    let neg: boolean = n < 0;
    let v: number = Math.abs(n);
    let rounded: number = Math.round(v * 100) / 100;
    let text: string = String(rounded);
    let dot: number = text.indexOf('.');
    let intPart: string = dot < 0 ? text : text.substring(0, dot);
    let fracPart: string = dot < 0 ? '' : text.substring(dot);
    let out: string = '';
    let count: number = 0;
    for (let i: number = intPart.length - 1; i >= 0; i--) {
      out = intPart.charAt(i) + out;
      count++;
      if (count % 3 === 0 && i > 0) {
        out = ',' + out;
      }
    }
    return (neg ? '-' : '') + out + fracPart;
  }

  // 紧凑: 1284000 → 128.4万; 用于轴上标注
  static compact(n: number): string {
    let abs: number = Math.abs(n);
    let sign: string = n < 0 ? '-' : '';
    if (abs >= 100000000) {
      return sign + UiNum.trim(abs / 100000000) + '亿';
    }
    if (abs >= 10000) {
      return sign + UiNum.trim(abs / 10000) + '万';
    }
    if (abs >= 1000) {
      return sign + UiNum.trim(abs / 1000) + 'k';
    }
    return sign + UiNum.trim(abs);
  }

  static trim(n: number): string {
    let rounded: number = Math.round(n * 10) / 10;
    return String(rounded);
  }

  static value(n: number): string {
    let abs: number = Math.abs(n);
    if (abs >= 10000) {
      return UiNum.compact(n);
    }
    if (Number.isInteger(n)) {
      return UiNum.thousands(n);
    }
    let rounded: number = Math.round(n * 100) / 100;
    return String(rounded);
  }

  static percent(part: number, total: number, digits: number = 1): string {
    if (total === 0) {
      return '0%';
    }
    let factor: number = Math.pow(10, digits);
    let v: number = Math.round((part / total) * 100 * factor) / factor;
    return String(v) + '%';
  }
}

// 二维点
export class UiPoint {
  x: number = 0;
  y: number = 0;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

// 数值轴: 把 [min,max] 映射到像素, 并给出"好看的"刻度
export class UiScale {
  min: number = 0;
  max: number = 1;

  static of(values: number[]): UiScale {
    let sc: UiScale = new UiScale();
    if (values.length === 0) {
      sc.min = 0;
      sc.max = 1;
      return sc;
    }
    let lo: number = values[0];
    let hi: number = values[0];
    for (let i: number = 1; i < values.length; i++) {
      if (values[i] < lo) {
        lo = values[i];
      }
      if (values[i] > hi) {
        hi = values[i];
      }
    }
    // 柱状图/面积图从 0 起; 折线图允许最小值为负
    let includeZero: boolean = !(lo < 0);
    if (includeZero && lo > 0) {
      lo = 0;
    }
    if (hi === lo) {
      hi = lo + 1;
    }
    sc.min = lo;
    sc.max = hi;
    return sc;
  }

  // 归一化到 0..1(0 = min, 1 = max)
  norm(v: number): number {
    let span: number = this.max - this.min;
    if (span <= 0) {
      return 0;
    }
    let t: number = (v - this.min) / span;
    if (t < 0) {
      return 0;
    }
    if (t > 1) {
      return 1;
    }
    return t;
  }

  // 4 条网格线
  ticks(count: number): number[] {
    let out: number[] = [];
    for (let i: number = 0; i <= count; i++) {
      out.push(this.min + (this.max - this.min) * (i / count));
    }
    return out;
  }
}

// 绘图盒(绝对坐标, 单位 vp)。
//
// 为什么需要它: ArkUI 的 `Shape` 里"布局按 vp、绘制按 px", 而 `Path.commands` 又是 px ——
// 三者混在一起时, 唯一能保证比例正确的做法是**在真实尺寸的坐标系里画**, 再由
// `UiChartGeom.unit` 统一换算成 px 输出。历史教训:
//   - 用 `viewPort` 缩放内容能让图形大小对, 但 `strokeWidth` 不跟着缩放 → 饼图画出巨型圆环被裁;
//   - 不用 `viewPort` 而按 vp 写坐标 → 图形只有 1/3 大小缩在左上角。
// 详见 `UiChartGeom.n()` 的注释。
export class UiBox {
  w: number = UiChartGeom.LINE_W;
  h: number = UiChartGeom.LINE_H;
  padL: number = UiChartGeom.LINE_PAD_L;
  padR: number = UiChartGeom.LINE_PAD_R;
  padT: number = UiChartGeom.LINE_PAD_T;
  padB: number = UiChartGeom.LINE_PAD_B;

  // 按真实尺寸造盒: 内边距按比例收缩, 窄屏时不会把绘图区挤没
  static of(w: number, h: number): UiBox {
    let box: UiBox = new UiBox();
    box.w = w > 40 ? w : 40;
    box.h = h > 40 ? h : 40;
    box.padL = Math.min(UiChartGeom.LINE_PAD_L, box.w * 0.13);
    box.padR = Math.min(UiChartGeom.LINE_PAD_R, box.w * 0.04);
    box.padT = Math.min(UiChartGeom.LINE_PAD_T, box.h * 0.08);
    box.padB = Math.min(UiChartGeom.LINE_PAD_B, box.h * 0.15);
    return box;
  }

  innerW(): number {
    let v: number = this.w - this.padL - this.padR;
    return v > 1 ? v : 1;
  }

  innerH(): number {
    let v: number = this.h - this.padT - this.padB;
    return v > 1 ? v : 1;
  }

  baseY(): number {
    return this.h - this.padB;
  }
}

export class UiChartGeom {
  // ===== 折线/面积(默认盒尺寸; 实际绘制请用 UiBox.of(实测宽, 高)) =====
  static readonly LINE_W: number = 320;
  static readonly LINE_H: number = 160;
  // 左内边距只留一点点: 本项目的折线图**不画 y 轴刻度文字**(极值改在下方单独一行展示),
  // 原来按"有轴标签"留了 34vp 的左侧留白, 真机上就是一整块空白、绘图区被推到右边,
  // 看起来像"图表内容偏右/没对齐"。左右接近对称(12 / 8)才正常。
  static readonly LINE_PAD_L: number = 12;
  static readonly LINE_PAD_R: number = 8;
  static readonly LINE_PAD_T: number = 10;
  static readonly LINE_PAD_B: number = 20;

  // 第 i 个数据点的 x 坐标
  static lineX(index: number, count: number, box: UiBox | null = null): number {
    let b: UiBox = box === null ? new UiBox() : box;
    let inner: number = b.innerW();
    if (count <= 1) {
      return b.padL + inner / 2;
    }
    return b.padL + (inner * index) / (count - 1);
  }

  // 数值 v 的 y 坐标
  static lineY(v: number, scale: UiScale, box: UiBox | null = null): number {
    let b: UiBox = box === null ? new UiBox() : box;
    return b.padT + b.innerH() * (1 - scale.norm(v));
  }

  static points(values: number[], scale: UiScale, box: UiBox | null = null): UiPoint[] {
    let out: UiPoint[] = [];
    for (let i: number = 0; i < values.length; i++) {
      out.push(new UiPoint(UiChartGeom.lineX(i, values.length, box),
        UiChartGeom.lineY(values[i], scale, box)));
    }
    return out;
  }

  // 折线路径; variant=natural 时用三次贝塞尔平滑
  static linePath(values: number[], scale: UiScale, variant: string, close: boolean,
    box: UiBox | null = null): string {
    if (values.length === 0) {
      return '';
    }
    let b: UiBox = box === null ? new UiBox() : box;
    let pts: UiPoint[] = UiChartGeom.points(values, scale, b);
    let base: number = b.baseY();
    let path: string = '';
    if (variant === 'step' && pts.length > 1) {
      path = 'M' + UiChartGeom.n(pts[0].x) + ' ' + UiChartGeom.n(pts[0].y);
      for (let i: number = 1; i < pts.length; i++) {
        path = path + ' L' + UiChartGeom.n(pts[i].x) + ' ' + UiChartGeom.n(pts[i - 1].y) +
          ' L' + UiChartGeom.n(pts[i].x) + ' ' + UiChartGeom.n(pts[i].y);
      }
    } else if ((variant === 'natural' || variant === 'smooth') && pts.length > 2) {
      path = 'M' + UiChartGeom.n(pts[0].x) + ' ' + UiChartGeom.n(pts[0].y);
      for (let i: number = 0; i < pts.length - 1; i++) {
        let p0: UiPoint = pts[i];
        let p1: UiPoint = pts[i + 1];
        let cx: number = (p0.x + p1.x) / 2;
        path = path + ' C' + UiChartGeom.n(cx) + ' ' + UiChartGeom.n(p0.y) + ' ' +
          UiChartGeom.n(cx) + ' ' + UiChartGeom.n(p1.y) + ' ' +
          UiChartGeom.n(p1.x) + ' ' + UiChartGeom.n(p1.y);
      }
    } else {
      path = 'M' + UiChartGeom.n(pts[0].x) + ' ' + UiChartGeom.n(pts[0].y);
      for (let i: number = 1; i < pts.length; i++) {
        path = path + ' L' + UiChartGeom.n(pts[i].x) + ' ' + UiChartGeom.n(pts[i].y);
      }
    }
    if (close && pts.length > 1) {
      path = path + ' L' + UiChartGeom.n(pts[pts.length - 1].x) + ' ' + UiChartGeom.n(base) +
        ' L' + UiChartGeom.n(pts[0].x) + ' ' + UiChartGeom.n(base) + ' Z';
    }
    return path;
  }

  // 面积填充路径(线 + 回到底边闭合)
  static areaPath(values: number[], scale: UiScale, variant: string,
    box: UiBox | null = null): string {
    return UiChartGeom.linePath(values, scale, variant, true, box);
  }

  // y 轴网格线路径
  static gridPaths(scale: UiScale, count: number, box: UiBox | null = null): string[] {
    let b: UiBox = box === null ? new UiBox() : box;
    let out: string[] = [];
    let x0: number = b.padL;
    let x1: number = b.w - b.padR;
    for (let i: number = 0; i <= count; i++) {
      let y: number = UiChartGeom.lineY(scale.min + (scale.max - scale.min) * (i / count), scale, b);
      out.push('M' + UiChartGeom.n(x0) + ' ' + UiChartGeom.n(y) + ' L' + UiChartGeom.n(x1) + ' ' + UiChartGeom.n(y));
    }
    return out;
  }

  // 数据点圆圈路径(折线图上的点)
  static dotPath(p: UiPoint, r: number): string {
    return UiChartGeom.circleAt(p.x, p.y, r);
  }

  // 以 (cx, cy) 为圆心、半径 r 的整圆(闭合路径)
  static circleAt(cx: number, cy: number, r: number): string {
    let left: number = cx - r;
    let right: number = cx + r;
    return 'M' + UiChartGeom.n(left) + ' ' + UiChartGeom.n(cy) +
      ' A' + UiChartGeom.n(r) + ' ' + UiChartGeom.n(r) + ' 0 1 1 ' + UiChartGeom.n(right) + ' ' + UiChartGeom.n(cy) +
      ' A' + UiChartGeom.n(r) + ' ' + UiChartGeom.n(r) + ' 0 1 1 ' + UiChartGeom.n(left) + ' ' + UiChartGeom.n(cy) + ' Z';
  }

  // ===== 饼图 / 环形 / 径向(几何按 vp, 序列化时统一换算成 px) =====
  // 不用 viewPort 的原因见 UiBox 注释: strokeWidth 不随 viewPort 缩放, 用它会画出巨型圆环被裁掉。

  // 从 12 点方向开始的一段圆弧(描边用)
  static arcAt(cx: number, cy: number, r: number, startRatio: number, sweepRatio: number): string {
    if (sweepRatio <= 0 || r <= 0) {
      return '';
    }
    let sweep: number = sweepRatio;
    // 整圈时起点终点重合会不渲染: 留出极小缺口
    if (sweep >= 0.99999) {
      sweep = 0.99999;
    }
    let a0: number = startRatio * Math.PI * 2 - Math.PI / 2;
    let a1: number = (startRatio + sweep) * Math.PI * 2 - Math.PI / 2;
    let x0: number = cx + r * Math.cos(a0);
    let y0: number = cy + r * Math.sin(a0);
    let x1: number = cx + r * Math.cos(a1);
    let y1: number = cy + r * Math.sin(a1);
    let large: number = sweep > 0.5 ? 1 : 0;
    return 'M' + UiChartGeom.n(x0) + ' ' + UiChartGeom.n(y0) +
      ' A' + UiChartGeom.n(r) + ' ' + UiChartGeom.n(r) + ' 0 ' + large.toString() + ' 1 ' +
      UiChartGeom.n(x1) + ' ' + UiChartGeom.n(y1);
  }

  // 实心扇形(饼图用: 从圆心出发, 不依赖 strokeWidth)
  static wedgeAt(cx: number, cy: number, r: number, startRatio: number, sweepRatio: number): string {
    if (sweepRatio <= 0 || r <= 0) {
      return '';
    }
    let sweep: number = sweepRatio >= 0.99999 ? 0.99999 : sweepRatio;
    let a0: number = startRatio * Math.PI * 2 - Math.PI / 2;
    let a1: number = (startRatio + sweep) * Math.PI * 2 - Math.PI / 2;
    let x0: number = cx + r * Math.cos(a0);
    let y0: number = cy + r * Math.sin(a0);
    let x1: number = cx + r * Math.cos(a1);
    let y1: number = cy + r * Math.sin(a1);
    let large: number = sweep > 0.5 ? 1 : 0;
    return 'M' + UiChartGeom.n(cx) + ' ' + UiChartGeom.n(cy) +
      ' L' + UiChartGeom.n(x0) + ' ' + UiChartGeom.n(y0) +
      ' A' + UiChartGeom.n(r) + ' ' + UiChartGeom.n(r) + ' 0 ' + large.toString() + ' 1 ' +
      UiChartGeom.n(x1) + ' ' + UiChartGeom.n(y1) + ' Z';
  }

  // 每段占比(忽略非正数)
  static ratios(values: number[]): number[] {
    let out: number[] = [];
    let total: number = 0;
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] > 0) {
        total += values[i];
      }
    }
    for (let i: number = 0; i < values.length; i++) {
      out.push(total > 0 && values[i] > 0 ? values[i] / total : 0);
    }
    return out;
  }

  static startRatios(ratios: number[]): number[] {
    let out: number[] = [];
    let acc: number = 0;
    for (let i: number = 0; i < ratios.length; i++) {
      out.push(acc);
      acc += ratios[i];
    }
    return out;
  }

  // 每段中间角度(画引导线/百分比标注用)
  static midAngle(startRatio: number, sweepRatio: number): number {
    return (startRatio + sweepRatio / 2) * Math.PI * 2 - Math.PI / 2;
  }

  // ===== 雷达 =====
  static readonly RADAR_SIZE: number = 220;

  // 归一化值(0..1) → 多边形顶点
  static radarPoints(normValues: number[], radius: number, size: number = 0): UiPoint[] {
    let out: UiPoint[] = [];
    let box: number = size > 0 ? size : UiChartGeom.RADAR_SIZE;
    let c: number = box / 2;
    let count: number = normValues.length;
    for (let i: number = 0; i < count; i++) {
      let angle: number = (i / count) * Math.PI * 2 - Math.PI / 2;
      let r: number = radius * normValues[i];
      out.push(new UiPoint(c + r * Math.cos(angle), c + r * Math.sin(angle)));
    }
    return out;
  }

  // 多边形路径(闭合)
  static polygonPath(pts: UiPoint[]): string {
    if (pts.length === 0) {
      return '';
    }
    let path: string = 'M' + UiChartGeom.n(pts[0].x) + ' ' + UiChartGeom.n(pts[0].y);
    for (let i: number = 1; i < pts.length; i++) {
      path = path + ' L' + UiChartGeom.n(pts[i].x) + ' ' + UiChartGeom.n(pts[i].y);
    }
    return path + ' Z';
  }

  // 雷达网格(同心多边形)
  static radarGrid(count: number, radius: number, rings: number, size: number = 0): string[] {
    let out: string[] = [];
    for (let r: number = 1; r <= rings; r++) {
      let values: number[] = [];
      for (let i: number = 0; i < count; i++) {
        values.push(r / rings);
      }
      out.push(UiChartGeom.polygonPath(UiChartGeom.radarPoints(values, radius, size)));
    }
    return out;
  }

  // 雷达轴线
  static radarSpokes(count: number, radius: number, size: number = 0): string[] {
    let out: string[] = [];
    let box: number = size > 0 ? size : UiChartGeom.RADAR_SIZE;
    let c: number = box / 2;
    for (let i: number = 0; i < count; i++) {
      let angle: number = (i / count) * Math.PI * 2 - Math.PI / 2;
      let x: number = c + radius * Math.cos(angle);
      let y: number = c + radius * Math.sin(angle);
      out.push('M' + UiChartGeom.n(c) + ' ' + UiChartGeom.n(c) + ' L' + UiChartGeom.n(x) + ' ' + UiChartGeom.n(y));
    }
    return out;
  }

  // 数字 → 路径文本(最多 1 位小数, 保证路径字符串短)
  //
  // ⚠️ 单位陷阱(必须理解, 否则图表比例全错):
  //   ArkUI 的 `Path.commands` **以物理像素 px 为单位**, 而组件的宽高、strokeWidth 等属性
  //   以 vp 为单位。也就是说同一个 Shape 里"布局按 vp、绘制按 px", 两者相差一个屏幕密度
  //   (通常 3~3.5 倍)。真机后果(全部踩过):
  //     - 折线图/饼图按 vp 写坐标 → 只画了 1/3 大小, 缩在左上角, 盒子剩下大片空白;
  //     - 径向图半径 28(vp 写法)= 28px, 而环宽 8vp = 26px → 描边比半径还粗, 变成一个实心色块;
  //     - 用 viewPort 缩放虽然能把图形放大回去, 但 strokeWidth 不跟着缩放 → 巨型圆环被裁。
  //   所以: 这里所有坐标统一按 vp 计算(几何代码可读、可单测), 只在**序列化成路径字符串**时
  //   乘上 `unit`(px/vp, 由 vp2px(1) 给出)。strokeWidth 等属性保持 vp 原值, 不要乘。
  static unit: number = 1;

  static n(v: number): string {
    if (!isFinite(v) || isNaN(v)) {
      return '0';
    }
    return String(Math.round(v * UiChartGeom.unit * 10) / 10);
  }
}
