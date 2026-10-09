// 交互模式 (Intelligent UI) 图表渲染器。
//
// 全部使用**声明式** ArkUI 组件(Row/Column/Stack/Shape/Path)而不是 Canvas:
// 声明式的好处是数据一变自动重绘, 不需要手动 invalidate, 也不会因为容器尺寸变化而错位。
// 坐标空间固定(折线 320×160 / 饼图 200×200 / 雷达 220×220) + aspectRatio 保证等比缩放。
//
// 组件接口只接收**基本类型与基本类型数组**: 避免把 UiElement 树通过 @Prop 深拷贝传进子组件
// (ArkUI 的 @Prop 对嵌套对象做深拷贝, 既慢又容易丢状态)。
import {
  UiPoint,
  UiBox,
  UiChartGeom,
  UiPalette,
  UiNum,
  UiScale
} from '../common/GuncatUiPaint';

// 图表单位初始化。
//
// `Path.commands` 用物理像素 px, 而组件宽高/strokeWidth 用 vp, 两者相差一个屏幕密度。
// 几何代码统一按 vp 计算, 只在序列化路径时乘 `UiChartGeom.unit`(= vp2px(1))。
// 每个图表在 aboutToAppear 里调一次 ensure(), 这样图表组件可以被单独复用而不依赖调用方。
export class GuncatUiChartUnit {
  private static applied: boolean = false;

  static ensure(): void {
    if (GuncatUiChartUnit.applied) {
      return;
    }
    GuncatUiChartUnit.applied = true;
    UiChartGeom.unit = vp2px(1);
  }

  // 由 Area 报告值反推 px/vp 比例: height 是已知的 vp 布局高度, 比值即单位比例。
  // 这样无论 Area 报的是 vp 还是 px 都能算对(实测为 vp, 这里保留自校准以免依赖未文档化的行为)。
  static ratioFromArea(areaHeight: Object, layoutHeightVp: number): number {
    let h: number = GuncatUiChartUnit.len(areaHeight, 0);
    if (h <= 0 || layoutHeightVp <= 0) {
      return 1;
    }
    let k: number = h / layoutHeightVp;
    return k > 0.5 ? k : 1;
  }

  // Area.width/height 的类型是 Length(string|number|Resource), 统一转成数值
  static len(value: Object, fallback: number): number {
    if (typeof value === 'number') {
      return value as number;
    }
    if (typeof value === 'string') {
      let n: number = parseFloat(value as string);
      return isNaN(n) ? fallback : n;
    }
    return fallback;
  }
}

// ===== 图例 =====
@Component
export struct GuncatUiLegend {
  @Prop names: string[] = [];
  @Prop colors: string[] = [];
  @Prop vertical: boolean = false;

  build() {
    if (this.vertical) {
      Column({ space: 6 }) {
        ForEach(this.names, (name: string, i: number) => {
          this.legendRow(name, i)
        }, (name: string, i: number) => 'lv' + i.toString() + name)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    } else {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.names, (name: string, i: number) => {
          Row({ space: 5 }) {
            Row()
              .width(8)
              .height(8)
              .constraintSize({ minWidth: 8, minHeight: 8 })
              .flexShrink(0)
              .borderRadius(4)
              .backgroundColor(this.colorAt(i))
            Text(name)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .margin({ right: 12, bottom: 4 })
        }, (name: string, i: number) => 'lh' + i.toString() + name)
      }
      .width('100%')
    }
  }

  @Builder
  legendRow(name: string, i: number) {
    Row({ space: 5 }) {
      Row()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(this.colorAt(i))
      Text(name)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
  }

  private colorAt(i: number): string {
    if (this.colors.length === 0) {
      return UiPalette.series(i);
    }
    return this.colors[i % this.colors.length];
  }
}

// ===== 柱状图(纵向, 支持分组/堆叠) =====
@Component
export struct GuncatUiBarChart {
  @Prop labels: string[] = [];
  @Prop seriesNames: string[] = [];
  @Prop seriesValues: number[][] = [];
  @Prop stacked: boolean = false;
  @Prop bodyHeight: number = 150;
  @Prop yLabel: string = '';

  build() {
    Column({ space: 8 }) {
      if (this.yLabel !== '') {
        Text(this.yLabel)
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      Row() {
        ForEach(this.labels, (label: string, gi: number) => {
          Column({ space: 5 }) {
            if (this.stacked) {
              this.stackedGroup(gi)
            } else {
              this.groupedGroup(gi)
            }
            Text(label)
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }, (label: string, gi: number) => 'bg' + gi.toString() + label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      if (this.seriesNames.length > 1) {
        GuncatUiLegend({ names: this.seriesNames })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  groupedGroup(gi: number) {
    Row({ space: 2 }) {
      ForEach(this.seriesValues, (values: number[], si: number) => {
        Column() {
          Blank()
          Column()
            .width('100%')
            .height(this.barHeight(gi, si))
            .borderRadius({ topLeft: 3, topRight: 3 })
            .backgroundColor(UiPalette.series(si))
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.End)
      }, (values: number[], si: number) => 'bs' + gi.toString() + '_' + si.toString())
    }
    .width('100%')
    .height(this.bodyHeight)
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  stackedGroup(gi: number) {
    Column() {
      Blank()
      ForEach(this.seriesValues, (values: number[], si: number) => {
        Column()
          .width('100%')
          .height(this.stackHeight(gi, si))
          .backgroundColor(UiPalette.series(si))
      }, (values: number[], si: number) => 'st' + gi.toString() + '_' + si.toString())
    }
    .width('100%')
    .height(this.bodyHeight)
    .justifyContent(FlexAlign.End)
    .borderRadius({ topLeft: 3, topRight: 3 })
    .clip(true)
  }

  private maxTotal(): number {
    let max: number = 0;
    for (let i: number = 0; i < this.seriesValues.length; i++) {
      let vals: number[] = this.seriesValues[i];
      for (let j: number = 0; j < vals.length; j++) {
        if (vals[j] > max) {
          max = vals[j];
        }
      }
    }
    return max <= 0 ? 1 : max;
  }

  private stackTotal(gi: number): number {
    let sum: number = 0;
    for (let si: number = 0; si < this.seriesValues.length; si++) {
      let vals: number[] = this.seriesValues[si];
      if (gi < vals.length && vals[gi] > 0) {
        sum += vals[gi];
      }
    }
    return sum;
  }

  private maxStackTotal(): number {
    let max: number = 0;
    for (let gi: number = 0; gi < this.labels.length; gi++) {
      let total: number = this.stackTotal(gi);
      if (total > max) {
        max = total;
      }
    }
    return max <= 0 ? 1 : max;
  }

  private barHeight(gi: number, si: number): number {
    let vals: number[] = this.seriesValues[si];
    if (vals === undefined || gi >= vals.length) {
      return 0;
    }
    let value: number = vals[gi] > 0 ? vals[gi] : 0;
    let h: number = (value / this.maxTotal()) * (this.bodyHeight - 4);
    return h < 2 && value > 0 ? 2 : h;
  }

  private stackHeight(gi: number, si: number): number {
    let vals: number[] = this.seriesValues[si];
    if (vals === undefined || gi >= vals.length) {
      return 0;
    }
    let value: number = vals[gi] > 0 ? vals[gi] : 0;
    let h: number = (value / this.maxStackTotal()) * (this.bodyHeight - 4);
    return h < 1 && value > 0 ? 1 : h;
  }
}

// ===== 折线图 / 面积图 =====
//
// 尺寸策略: 折线图宽度必须自适应, 而 ArkUI 里 `Path.commands` 用 px、组件宽高与 strokeWidth
// 用 vp(见 UiChartGeom.n() 的说明), 用 viewPort 缩放又会把 strokeWidth 甩掉。
// 因此这里: **onAreaChange 量出真实宽度 → 几何按 vp 计算 → 序列化时统一换算成 px**。
@Component
export struct GuncatUiLineChart {
  @Prop labels: string[] = [];
  @Prop seriesNames: string[] = [];
  @Prop seriesValues: number[][] = [];
  @Prop smooth: boolean = false;
  @Prop area: boolean = false;
  @Prop showDots: boolean = true;
  // 绘图高度(vp); 由调用方按 chart 的 height 参数给, 默认 150
  @Prop chartHeight: number = 150;
  // 实测宽度(vp): 首帧用默认值, onAreaChange 后修正
  @State private boxW: number = 300;

  aboutToAppear(): void {
    GuncatUiChartUnit.ensure();
  }

  build() {
    Column({ space: 6 }) {
      Shape() {
        // 网格线
        ForEach(this.gridPaths(), (path: string, i: number) => {
          Path()
            .commands(path)
            .stroke(UiPalette.GRID)
            .strokeWidth(1)
            .fill(Color.Transparent)
        }, (path: string, i: number) => 'grid' + i.toString())

        // y 轴刻度文字用绝对定位的 Text 不好放, 这里改为在下方单独一行展示极值
        ForEach(this.seriesValues, (values: number[], si: number) => {
          if (this.area) {
            Path()
              .commands(this.areaPathFor(values))
              .fill(UiPalette.series(si))
              .opacity(0.16)
              .stroke(Color.Transparent)
          }
          Path()
            .commands(this.linePathFor(values))
            .stroke(UiPalette.series(si))
            .strokeWidth(2)
            .fill(Color.Transparent)
            .strokeLineJoin(LineJoinStyle.Round)
            .strokeLineCap(LineCapStyle.Round)
        }, (values: number[], si: number) => 'ln' + si.toString())

        if (this.showDots) {
          ForEach(this.seriesValues, (values: number[], si: number) => {
            ForEach(this.dotsFor(values), (dot: string, di: number) => {
              Path()
                .commands(dot)
                .fill(UiPalette.series(si))
                .stroke($r('app.color.surface'))
                .strokeWidth(1.4)
            }, (dot: string, di: number) => 'dot' + si.toString() + '_' + di.toString())
          }, (values: number[], si: number) => 'ds' + si.toString())
        }
      }
      .width('100%')
      .height(this.chartHeight)
      .onAreaChange((_old: Area, next: Area) => {
        // 用"实测高度 / 已知 vp 高度"反推单位比例, 再换算宽度 —— 不依赖 Area 报的是 vp 还是 px
        let k: number = GuncatUiChartUnit.ratioFromArea(next.height, this.chartHeight);
        let w: number = GuncatUiChartUnit.len(next.width, this.boxW) / k;
        // 只在宽度真的变化时重算, 避免 onAreaChange → 重绘 → onAreaChange 抖动
        if (w > 40 && Math.abs(w - this.boxW) > 1) {
          this.boxW = w;
        }
      })

      Row() {
        Text(this.rangeText())
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
        Text(this.xRangeText())
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .flexShrink(0)
      }
      .width('100%')

      if (this.seriesNames.length > 1) {
        GuncatUiLegend({ names: this.seriesNames })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private box(): UiBox {
    return UiBox.of(this.boxW, this.chartHeight);
  }

  private allValues(): number[] {
    let out: number[] = [];
    for (let i: number = 0; i < this.seriesValues.length; i++) {
      let vals: number[] = this.seriesValues[i];
      for (let j: number = 0; j < vals.length; j++) {
        out.push(vals[j]);
      }
    }
    return out;
  }

  private axisScale(): UiScale {
    return UiScale.of(this.allValues());
  }

  private gridPaths(): string[] {
    return UiChartGeom.gridPaths(this.axisScale(), 4, this.box());
  }

  private linePathFor(values: number[]): string {
    return UiChartGeom.linePath(values, this.axisScale(), this.smooth ? 'natural' : 'linear',
      false, this.box());
  }

  private areaPathFor(values: number[]): string {
    return UiChartGeom.areaPath(values, this.axisScale(), this.smooth ? 'natural' : 'linear',
      this.box());
  }

  private dotsFor(values: number[]): string[] {
    let pts: UiPoint[] = UiChartGeom.points(values, this.axisScale(), this.box());
    let out: string[] = [];
    for (let i: number = 0; i < pts.length; i++) {
      out.push(UiChartGeom.dotPath(pts[i], 2.6));
    }
    return out;
  }

  private rangeText(): string {
    let sc: UiScale = this.axisScale();
    return UiNum.compact(sc.max) + ' / ' + UiNum.compact(sc.min);
  }

  private xRangeText(): string {
    if (this.labels.length === 0) {
      return '';
    }
    if (this.labels.length === 1) {
      return this.labels[0];
    }
    return this.labels[0] + ' → ' + this.labels[this.labels.length - 1];
  }
}

// ===== 饼图 / 环形图 =====
@Component
export struct GuncatUiPieChart {
  // 绘图盒与内外半径(全部 vp): 固定尺寸 + 绝对坐标绘制, 不依赖 viewPort 缩放
  static readonly BOX: number = 128;
  static readonly OUTER: number = 58;
  static readonly INNER: number = 34;
  static readonly RING: number = 24;

  aboutToAppear(): void {
    GuncatUiChartUnit.ensure();
  }

  @Prop labels: string[] = [];
  @Prop values: number[] = [];
  @Prop donut: boolean = true;

  build() {
    Column({ space: 10 }) {
      Row({ space: 14 }) {
        Stack() {
          Shape() {
            ForEach(this.ratios(), (ratio: number, i: number) => {
              if (this.donut) {
                // 环形: 用描边画弧(半径与描边宽度都是 vp, 不再受 viewPort 缩放影响)
                Path()
                  .commands(this.donutArcAt(i))
                  .stroke(UiPalette.category(i))
                  .strokeWidth(GuncatUiPieChart.RING)
                  .fill(Color.Transparent)
                  .strokeLineCap(LineCapStyle.Butt)
              } else {
                // 饼图: **实心扇形**。旧实现用 strokeWidth(100) 想把扇形填满, 但 strokeWidth
                // 不随 viewPort 缩放 → 实际画出一条 100vp 宽的巨型圆环, 被容器裁成半圆。
                Path()
                  .commands(this.wedgeAt(i))
                  .fill(UiPalette.category(i))
                  .stroke(Color.Transparent)
              }
            }, (ratio: number, i: number) => 'arc' + i.toString())
          }
          .width(GuncatUiPieChart.BOX)
          .height(GuncatUiPieChart.BOX)

          if (this.donut) {
            Column({ space: 1 }) {
              Text(this.totalText())
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              Text('合计')
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
            }
          }
        }
        .width(GuncatUiPieChart.BOX)
        .height(GuncatUiPieChart.BOX)
        .constraintSize({ minWidth: GuncatUiPieChart.BOX, minHeight: GuncatUiPieChart.BOX })
        .flexShrink(0)
        .clip(false)

        Column({ space: 6 }) {
          ForEach(this.labels, (label: string, i: number) => {
            Row({ space: 6 }) {
              Row()
                .width(8)
                .height(8)
                .constraintSize({ minWidth: 8, minHeight: 8 })
                .flexShrink(0)
                .borderRadius(4)
                .backgroundColor(UiPalette.category(i))
              Text(label)
                .fontSize(11)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(this.valueText(i))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
          }, (label: string, i: number) => 'pl' + i.toString() + label)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private ratios(): number[] {
    return UiChartGeom.ratios(this.values);
  }

  // 环形的一段(描边弧): 半径取内外半径中线, 描边宽度 = 环宽
  private donutArcAt(i: number): string {
    let ratios: number[] = this.ratios();
    if (i >= ratios.length) {
      return '';
    }
    let starts: number[] = UiChartGeom.startRatios(ratios);
    let c: number = GuncatUiPieChart.BOX / 2;
    let mid: number = (GuncatUiPieChart.OUTER + GuncatUiPieChart.INNER) / 2;
    return UiChartGeom.arcAt(c, c, mid, starts[i], ratios[i]);
  }

  // 饼图的一段(实心扇形), 半径 = 外半径
  private wedgeAt(i: number): string {
    let ratios: number[] = this.ratios();
    if (i >= ratios.length) {
      return '';
    }
    let starts: number[] = UiChartGeom.startRatios(ratios);
    let c: number = GuncatUiPieChart.BOX / 2;
    return UiChartGeom.wedgeAt(c, c, GuncatUiPieChart.OUTER, starts[i], ratios[i]);
  }

  private totalText(): string {
    let total: number = 0;
    for (let i: number = 0; i < this.values.length; i++) {
      if (this.values[i] > 0) {
        total += this.values[i];
      }
    }
    return UiNum.value(total);
  }

  private valueText(i: number): string {
    if (i >= this.values.length) {
      return '';
    }
    return UiNum.value(this.values[i]) + ' · ' + UiNum.percent(this.values[i], this.sum());
  }

  private sum(): number {
    let total: number = 0;
    for (let i: number = 0; i < this.values.length; i++) {
      if (this.values[i] > 0) {
        total += this.values[i];
      }
    }
    return total;
  }
}

// ===== 径向条形图(多个达成率) =====
//
// 尺寸策略: 圆圈固定 72vp + 绝对坐标绘制(不设 viewPort)。旧实现用 52vp 盒子 + 200 的 viewPort,
// 内容是按 0.26 倍缩放的, 但 strokeWidth(8) 按 vp 画 → 环宽是半径的好几倍, 真机上就成了一圈
// 又小又粗、几乎看不出比例的色块, 百分比数字也被挤到圈外。
@Component
export struct GuncatUiRadialChart {
  static readonly BOX: number = 72;
  static readonly RING_R: number = 28;
  static readonly RING_W: number = 8;

  aboutToAppear(): void {
    GuncatUiChartUnit.ensure();
  }

  @Prop labels: string[] = [];
  @Prop values: number[] = [];

  build() {
    Column({ space: 12 }) {
      ForEach(this.labels, (label: string, i: number) => {
        Row() {
          Stack() {
            Shape() {
              // 轨道(整圈) + 进度弧, 都是绝对坐标
              Path()
                .commands(UiChartGeom.circleAt(GuncatUiRadialChart.BOX / 2,
                  GuncatUiRadialChart.BOX / 2, GuncatUiRadialChart.RING_R))
                .stroke($r('app.color.surface_secondary'))
                .strokeWidth(GuncatUiRadialChart.RING_W)
                .fill(Color.Transparent)
              Path()
                .commands(UiChartGeom.arcAt(GuncatUiRadialChart.BOX / 2,
                  GuncatUiRadialChart.BOX / 2, GuncatUiRadialChart.RING_R, 0, this.ratioAt(i)))
                .stroke(UiPalette.category(i))
                .strokeWidth(GuncatUiRadialChart.RING_W)
                .fill(Color.Transparent)
                .strokeLineCap(LineCapStyle.Round)
            }
            .width(GuncatUiRadialChart.BOX)
            .height(GuncatUiRadialChart.BOX)

            // 百分比放在圈心(半径 28 的圈内, 字号 12 放得下两位数)
            Text(String(Math.round(this.ratioAt(i) * 100)) + '%')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .width(GuncatUiRadialChart.BOX)
          .height(GuncatUiRadialChart.BOX)
          .constraintSize({
            minWidth: GuncatUiRadialChart.BOX,
            minHeight: GuncatUiRadialChart.BOX
          })
          .flexShrink(0)

          Column({ space: 2 }) {
            Text(label)
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(UiNum.value(this.valueAt(i)))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .margin({ left: 10 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }, (label: string, i: number) => 'rd' + i.toString() + label)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 约定: 值 <= 1 视为占比, > 1 视为百分数
  private ratioAt(i: number): number {
    let v: number = this.valueAt(i);
    let r: number = v > 1 ? v / 100 : v;
    if (r < 0) {
      return 0;
    }
    if (r > 1) {
      return 1;
    }
    return r;
  }

  private valueAt(i: number): number {
    return i < this.values.length ? this.values[i] : 0;
  }
}

// ===== 单条堆叠条(整体构成) =====
@Component
export struct GuncatUiStackedBar {
  @Prop labels: string[] = [];
  @Prop values: number[] = [];

  build() {
    Column({ space: 8 }) {
      Row() {
        ForEach(this.values, (value: number, i: number) => {
          if (value > 0) {
            Row()
              .layoutWeight(value)
              .height('100%')
              .backgroundColor(UiPalette.category(i))
          }
        }, (value: number, i: number) => 'sb' + i.toString())
      }
      .width('100%')
      .height(14)
      .borderRadius(7)
      .backgroundColor($r('app.color.surface_secondary'))
      .clip(true)

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.labels, (label: string, i: number) => {
          Row({ space: 5 }) {
            Row()
              .width(8)
              .height(8)
              .constraintSize({ minWidth: 8, minHeight: 8 })
              .flexShrink(0)
              .borderRadius(4)
              .backgroundColor(UiPalette.category(i))
            Text(label + ' ' + UiNum.percent(this.valueAt(i), this.sum()))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
          }
          .margin({ right: 12, bottom: 4 })
        }, (label: string, i: number) => 'sl' + i.toString() + label)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private valueAt(i: number): number {
    return i < this.values.length ? this.values[i] : 0;
  }

  private sum(): number {
    let total: number = 0;
    for (let i: number = 0; i < this.values.length; i++) {
      if (this.values[i] > 0) {
        total += this.values[i];
      }
    }
    return total;
  }
}

// ===== 雷达图 =====
@Component
export struct GuncatUiRadarChart {
  static readonly BOX: number = 220;
  static readonly R: number = 84;
  static readonly RINGS: number = 4;

  aboutToAppear(): void {
    GuncatUiChartUnit.ensure();
  }

  @Prop labels: string[] = [];
  @Prop seriesNames: string[] = [];
  // 每个序列已归一化到 0..1 的数值
  @Prop seriesNorm: number[][] = [];

  build() {
    Column({ space: 8 }) {
      Stack() {
        Shape() {
          // 与饼图/径向同理: 固定 220vp 的盒子 + 绝对坐标(几何按 vp, 输出时由 UiChartGeom.unit 换算成 px)
          ForEach(UiChartGeom.radarGrid(this.labels.length, GuncatUiRadarChart.R,
            GuncatUiRadarChart.RINGS, GuncatUiRadarChart.BOX), (path: string, i: number) => {
            Path()
              .commands(path)
              .stroke(UiPalette.GRID)
              .strokeWidth(1)
              .fill(Color.Transparent)
          }, (path: string, i: number) => 'rg' + i.toString())

          ForEach(UiChartGeom.radarSpokes(this.labels.length, GuncatUiRadarChart.R,
            GuncatUiRadarChart.BOX), (path: string, i: number) => {
            Path()
              .commands(path)
              .stroke(UiPalette.GRID)
              .strokeWidth(1)
              .fill(Color.Transparent)
          }, (path: string, i: number) => 'rs' + i.toString())

          ForEach(this.seriesNorm, (values: number[], si: number) => {
            Path()
              .commands(UiChartGeom.polygonPath(UiChartGeom.radarPoints(values,
                GuncatUiRadarChart.R, GuncatUiRadarChart.BOX)))
              .stroke(UiPalette.series(si))
              .strokeWidth(2)
              .fill(UiPalette.series(si))
              .opacity(0.18)
          }, (values: number[], si: number) => 'rp' + si.toString())
        }
        .width(GuncatUiRadarChart.BOX)
        .height(GuncatUiRadarChart.BOX)
      }
      .width(GuncatUiRadarChart.BOX)
      .height(GuncatUiRadarChart.BOX)
      .constraintSize({
        minWidth: GuncatUiRadarChart.BOX,
        minHeight: GuncatUiRadarChart.BOX
      })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.labels, (label: string, i: number) => {
          Text(label)
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ right: 10, bottom: 4 })
        }, (label: string, i: number) => 'rl' + i.toString() + label)
      }
      .width('100%')

      if (this.seriesNames.length > 1) {
        GuncatUiLegend({ names: this.seriesNames })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// ===== 横向条形图(排名最易读) =====
@Component
export struct GuncatUiHorizontalBars {
  @Prop labels: string[] = [];
  @Prop seriesNames: string[] = [];
  @Prop seriesValues: number[][] = [];
  @Prop colors: string[] = [];
  @Prop unit: string = '';

  build() {
    Column({ space: 7 }) {
      ForEach(this.labels, (label: string, i: number) => {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(label)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.valueText(i))
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')

          if (this.seriesValues.length <= 1) {
            Row() {
              Row()
                .width((this.ratioAt(0, i) * 100) + '%')
                .height('100%')
                .borderRadius(4)
                .backgroundColor(this.colorAt(i))
            }
            .width('100%')
            .height(8)
            .borderRadius(4)
            .backgroundColor($r('app.color.surface_secondary'))
          } else {
            Row({ space: 2 }) {
              ForEach(this.seriesValues, (values: number[], si: number) => {
                Row()
                  .layoutWeight(this.weightAt(si, i))
                  .height('100%')
                  .backgroundColor(UiPalette.series(si))
              }, (values: number[], si: number) => 'hb' + i.toString() + '_' + si.toString())
            }
            .width('100%')
            .height(8)
            .borderRadius(4)
            .backgroundColor($r('app.color.surface_secondary'))
            .clip(true)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }, (label: string, i: number) => 'hbl' + i.toString() + label)

      if (this.seriesNames.length > 1) {
        GuncatUiLegend({ names: this.seriesNames })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private colorAt(i: number): string {
    if (this.colors.length > 0) {
      return this.colors[i % this.colors.length];
    }
    return UiPalette.category(i);
  }

  private valueAt(si: number, i: number): number {
    let vals: number[] = this.seriesValues[si];
    if (vals === undefined || i >= vals.length) {
      return 0;
    }
    return vals[i] > 0 ? vals[i] : 0;
  }

  private maxAll(): number {
    let max: number = 0;
    for (let si: number = 0; si < this.seriesValues.length; si++) {
      let vals: number[] = this.seriesValues[si];
      for (let i: number = 0; i < vals.length; i++) {
        if (vals[i] > max) {
          max = vals[i];
        }
      }
    }
    return max <= 0 ? 1 : max;
  }

  private ratioAt(si: number, i: number): number {
    return this.valueAt(si, i) / this.maxAll();
  }

  private weightAt(si: number, i: number): number {
    let v: number = this.valueAt(si, i);
    return v <= 0 ? 0.0001 : v;
  }

  private valueText(i: number): string {
    if (this.seriesValues.length > 1) {
      let parts: string[] = [];
      for (let si: number = 0; si < this.seriesValues.length; si++) {
        parts.push(UiNum.value(this.valueAt(si, i)));
      }
      return parts.join(' / ');
    }
    let v: number = this.valueAt(0, i);
    return UiNum.value(v) + this.unit;
  }
}
