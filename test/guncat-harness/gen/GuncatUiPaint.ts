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

export class UiChartGeom {
  // ===== 折线/面积 =====
  static readonly LINE_W: number = 320;
  static readonly LINE_H: number = 160;
  static readonly LINE_PAD_L: number = 34;
  static readonly LINE_PAD_R: number = 8;
  static readonly LINE_PAD_T: number = 10;
  static readonly LINE_PAD_B: number = 20;

  static lineInnerW(): number {
    return UiChartGeom.LINE_W - UiChartGeom.LINE_PAD_L - UiChartGeom.LINE_PAD_R;
  }

  static lineInnerH(): number {
    return UiChartGeom.LINE_H - UiChartGeom.LINE_PAD_T - UiChartGeom.LINE_PAD_B;
  }

  // 第 i 个数据点的 x 坐标
  static lineX(index: number, count: number): number {
    let inner: number = UiChartGeom.lineInnerW();
    if (count <= 1) {
      return UiChartGeom.LINE_PAD_L + inner / 2;
    }
    return UiChartGeom.LINE_PAD_L + (inner * index) / (count - 1);
  }

  // 数值 v 的 y 坐标
  static lineY(v: number, scale: UiScale): number {
    let inner: number = UiChartGeom.lineInnerH();
    return UiChartGeom.LINE_PAD_T + inner * (1 - scale.norm(v));
  }

  static points(values: number[], scale: UiScale): UiPoint[] {
    let out: UiPoint[] = [];
    for (let i: number = 0; i < values.length; i++) {
      out.push(new UiPoint(UiChartGeom.lineX(i, values.length), UiChartGeom.lineY(values[i], scale)));
    }
    return out;
  }

  // 折线路径; variant=natural 时用三次贝塞尔平滑
  static linePath(values: number[], scale: UiScale, variant: string, close: boolean): string {
    if (values.length === 0) {
      return '';
    }
    let pts: UiPoint[] = UiChartGeom.points(values, scale);
    let base: number = UiChartGeom.LINE_H - UiChartGeom.LINE_PAD_B;
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
  static areaPath(values: number[], scale: UiScale, variant: string): string {
    return UiChartGeom.linePath(values, scale, variant, true);
  }

  // y 轴网格线路径
  static gridPaths(scale: UiScale, count: number): string[] {
    let out: string[] = [];
    let x0: number = UiChartGeom.LINE_PAD_L;
    let x1: number = UiChartGeom.LINE_W - UiChartGeom.LINE_PAD_R;
    for (let i: number = 0; i <= count; i++) {
      let y: number = UiChartGeom.lineY(scale.min + (scale.max - scale.min) * (i / count), scale);
      out.push('M' + UiChartGeom.n(x0) + ' ' + UiChartGeom.n(y) + ' L' + UiChartGeom.n(x1) + ' ' + UiChartGeom.n(y));
    }
    return out;
  }

  // 数据点圆圈路径(折线图上的点)
  static dotPath(p: UiPoint, r: number): string {
    let left: number = p.x - r;
    let right: number = p.x + r;
    return 'M' + UiChartGeom.n(left) + ' ' + UiChartGeom.n(p.y) +
      ' A' + UiChartGeom.n(r) + ' ' + UiChartGeom.n(r) + ' 0 1 1 ' + UiChartGeom.n(right) + ' ' + UiChartGeom.n(p.y) +
      ' A' + UiChartGeom.n(r) + ' ' + UiChartGeom.n(r) + ' 0 1 1 ' + UiChartGeom.n(left) + ' ' + UiChartGeom.n(p.y) + ' Z';
  }

  // ===== 饼图 / 环形 =====
  static readonly PIE_SIZE: number = 200;

  // 单段圆弧(极坐标 → SVG 弧)
  static arcPath(startRatio: number, sweepRatio: number, radius: number): string {
    if (sweepRatio <= 0) {
      return '';
    }
    let c: number = UiChartGeom.PIE_SIZE / 2;
    let sweep: number = sweepRatio;
    // 整圈时起点终点重合会不渲染: 留出极小缺口
    if (sweep >= 0.99999) {
      sweep = 0.99999;
    }
    let a0: number = startRatio * Math.PI * 2 - Math.PI / 2;
    let a1: number = (startRatio + sweep) * Math.PI * 2 - Math.PI / 2;
    let x0: number = c + radius * Math.cos(a0);
    let y0: number = c + radius * Math.sin(a0);
    let x1: number = c + radius * Math.cos(a1);
    let y1: number = c + radius * Math.sin(a1);
    let large: number = sweep > 0.5 ? 1 : 0;
    return 'M' + UiChartGeom.n(x0) + ' ' + UiChartGeom.n(y0) +
      ' A' + UiChartGeom.n(radius) + ' ' + UiChartGeom.n(radius) + ' 0 ' + large.toString() + ' 1 ' +
      UiChartGeom.n(x1) + ' ' + UiChartGeom.n(y1);
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
  static radarPoints(normValues: number[], radius: number): UiPoint[] {
    let out: UiPoint[] = [];
    let c: number = UiChartGeom.RADAR_SIZE / 2;
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
  static radarGrid(count: number, radius: number, rings: number): string[] {
    let out: string[] = [];
    for (let r: number = 1; r <= rings; r++) {
      let values: number[] = [];
      for (let i: number = 0; i < count; i++) {
        values.push(r / rings);
      }
      out.push(UiChartGeom.polygonPath(UiChartGeom.radarPoints(values, radius)));
    }
    return out;
  }

  // 雷达轴线
  static radarSpokes(count: number, radius: number): string[] {
    let out: string[] = [];
    let c: number = UiChartGeom.RADAR_SIZE / 2;
    for (let i: number = 0; i < count; i++) {
      let angle: number = (i / count) * Math.PI * 2 - Math.PI / 2;
      let x: number = c + radius * Math.cos(angle);
      let y: number = c + radius * Math.sin(angle);
      out.push('M' + UiChartGeom.n(c) + ' ' + UiChartGeom.n(c) + ' L' + UiChartGeom.n(x) + ' ' + UiChartGeom.n(y));
    }
    return out;
  }

  // 径向条形: 每个值的进度弧(0..1)
  static radialArc(ratio: number, radius: number, track: boolean): string {
    let c: number = UiChartGeom.PIE_SIZE / 2;
    let sweep: number = ratio;
    if (sweep <= 0) {
      return track ? UiChartGeom.arcPath(0, 0.99999, radius) : '';
    }
    if (sweep >= 0.99999) {
      sweep = 0.99999;
    }
    let a0: number = -Math.PI / 2;
    let a1: number = sweep * Math.PI * 2 - Math.PI / 2;
    let x0: number = c + radius * Math.cos(a0);
    let y0: number = c + radius * Math.sin(a0);
    let x1: number = c + radius * Math.cos(a1);
    let y1: number = c + radius * Math.sin(a1);
    let large: number = sweep > 0.5 ? 1 : 0;
    return 'M' + UiChartGeom.n(x0) + ' ' + UiChartGeom.n(y0) +
      ' A' + UiChartGeom.n(radius) + ' ' + UiChartGeom.n(radius) + ' 0 ' + large.toString() + ' 1 ' +
      UiChartGeom.n(x1) + ' ' + UiChartGeom.n(y1);
  }

  // 数字 → 路径文本(最多 1 位小数, 保证路径字符串短)
  static n(v: number): string {
    if (!isFinite(v) || isNaN(v)) {
      return '0';
    }
    return String(Math.round(v * 10) / 10);
  }
}
