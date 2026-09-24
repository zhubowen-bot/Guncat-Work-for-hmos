// PptxCharts: Deck 图表 -> OOXML chart part (c:chartSpace)
// 数据以内嵌 strCache/numCache 写入, 不携带外部 workbook(PowerPoint/WPS 均可直接渲染,
// 仅"编辑数据"入口不可用)。支持 bar / line / area / pie / doughnut。
// 纯逻辑模块(无 HarmonyOS API 依赖)。
import { DeckChart, DeckSeries } from './DeckModel.ts';
import { ThemeColors } from './PptxThemes.ts';
import { XmlUtil } from './XmlUtil.ts';

const AX_CAT: string = '111111111';
const AX_VAL: string = '222222222';

export class PptxCharts {
  static buildXml(chart: DeckChart, colors: ThemeColors): string {
    let type: string = chart.type;
    let plot: string = '';
    let axes: string = '';
    if (type === 'bar') {
      plot = '<c:barChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/>' +
        PptxCharts.seriesAll(chart, colors, false) +
        '<c:gapWidth val="80"/><c:overlap val="-27"/>' +
        PptxCharts.axIds() + '</c:barChart>';
      axes = PptxCharts.catAx(colors) + PptxCharts.valAx(colors);
    } else if (type === 'line') {
      plot = '<c:lineChart><c:grouping val="clustered"/><c:varyColors val="0"/>' +
        PptxCharts.seriesAll(chart, colors, true) +
        '<c:marker val="1"/>' + PptxCharts.axIds() + '</c:lineChart>';
      axes = PptxCharts.catAx(colors) + PptxCharts.valAx(colors);
    } else if (type === 'area') {
      plot = '<c:areaChart><c:grouping val="standard"/><c:varyColors val="0"/>' +
        PptxCharts.seriesAll(chart, colors, false) +
        PptxCharts.axIds() + '</c:areaChart>';
      axes = PptxCharts.catAx(colors) + PptxCharts.valAx(colors);
    } else {
      // pie / doughnut: 只取第一个系列
      let ser: DeckSeries = chart.series.length > 0 ? chart.series[0] : new DeckSeries();
      let head: string = type === 'doughnut'
        ? '<c:doughnutChart><c:varyColors val="1"/>'
        : '<c:pieChart><c:varyColors val="1"/>';
      plot = head + PptxCharts.pieSer(chart, ser, colors) +
        PptxCharts.dLbls(colors, chart.showValue, true, type === 'pie') +
        '<c:firstSliceAng val="0"/>' +
        (type === 'doughnut' ? '<c:holeSize val="50"/>' : '') + '</c:' +
        (type === 'doughnut' ? 'doughnutChart' : 'pieChart') + '>';
    }
    let legend: string = '';
    if (chart.showLegend && (chart.series.length > 1 || type === 'pie' || type === 'doughnut')) {
      legend = '<c:legend><c:legendPos val="b"/><c:overlay val="0"/>' + PptxCharts.txPr(colors, 1000) + '</c:legend>';
    }
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" ' +
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
      '<c:roundedCorners val="0"/>' +
      '<c:chart><c:autoTitleDeleted val="1"/>' +
      '<c:plotArea><c:layout/>' + plot + axes + '</c:plotArea>' +
      legend + '<c:plotVisOnly val="1"/></c:chart>' +
      '<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr>' +
      PptxCharts.txPr(colors, 1000) +
      '</c:chartSpace>';
  }

  private static axIds(): string {
    return '<c:axId val="' + AX_CAT + '"/><c:axId val="' + AX_VAL + '"/>';
  }

  // bar/line/area 的系列
  private static seriesAll(chart: DeckChart, colors: ThemeColors, withMarker: boolean): string {
    let out: string = '';
    for (let i: number = 0; i < chart.series.length && i < 6; i++) {
      let s: DeckSeries = chart.series[i];
      let color: string = colors.series[i % colors.series.length];
      out += '<c:ser><c:idx val="' + i.toString() + '"/><c:order val="' + i.toString() + '"/>' +
        PptxCharts.tx(escape0(s.name), i) +
        '<c:spPr><a:solidFill><a:srgbClr val="' + color + '"/></a:solidFill>' +
        (chart.type === 'line'
          ? '<a:ln w="28575" cap="rnd"><a:solidFill><a:srgbClr val="' + color + '"/></a:solidFill></a:ln>'
          : '<a:ln><a:noFill/></a:ln>') +
        '</c:spPr>' +
        (withMarker
          ? '<c:marker><c:symbol val="circle"/><c:size val="5"/><c:spPr><a:solidFill><a:srgbClr val="' +
            color + '"/></a:solidFill></c:spPr></c:marker>'
          : '') +
        PptxCharts.dLbls(colors, chart.showValue, false, false) +
        '<c:cat>' + PptxCharts.catRef(chart.categories) + '</c:cat>' +
        '<c:val>' + PptxCharts.numRef(i, s.values) + '</c:val>' +
        (chart.type === 'line' ? '<c:smooth val="0"/>' : '') +
        '</c:ser>';
    }
    return out;
  }

  // pie/doughnut 的单系列(逐点上色)
  private static pieSer(chart: DeckChart, ser: DeckSeries, colors: ThemeColors): string {
    let out: string = '<c:ser><c:idx val="0"/><c:order val="0"/>' +
      PptxCharts.tx(escape0(ser.name), 0);
    let count: number = Math.min(ser.values.length, chart.categories.length, 12);
    for (let i: number = 0; i < count; i++) {
      out += '<c:dPt><c:idx val="' + i.toString() + '"/><c:bubble3D val="0"/>' +
        '<c:spPr><a:solidFill><a:srgbClr val="' + colors.series[i % colors.series.length] + '"/></a:solidFill>' +
        '<a:ln><a:noFill/></a:ln></c:spPr></c:dPt>';
    }
    out += '<c:cat>' + PptxCharts.catRef(chart.categories) + '</c:cat>' +
      '<c:val>' + PptxCharts.numRef(0, ser.values) + '</c:val></c:ser>';
    return out;
  }

  private static tx(name: string, idx: number): string {
    return '<c:tx><c:strRef><c:f>Sheet1!$' + PptxCharts.colLetter(idx + 2) + '$1</c:f>' +
      '<c:strCache><c:ptCount val="1"/><c:pt idx="0"><c:v>' + XmlUtil.escape(name) + '</c:v></c:pt>' +
      '</c:strCache></c:strRef></c:tx>';
  }

  private static catRef(categories: string[]): string {
    let pts: string = '';
    let count: number = Math.min(categories.length, 64);
    for (let i: number = 0; i < count; i++) {
      pts += '<c:pt idx="' + i.toString() + '"><c:v>' + XmlUtil.escape(categories[i]) + '</c:v></c:pt>';
    }
    return '<c:strRef><c:f>Sheet1!$A$2:$A$' + (count + 1).toString() + '</c:f>' +
      '<c:strCache><c:ptCount val="' + count.toString() + '"/>' + pts + '</c:strCache></c:strRef>';
  }

  private static numRef(seriesIdx: number, values: number[]): string {
    let pts: string = '';
    let count: number = Math.min(values.length, 64);
    for (let i: number = 0; i < count; i++) {
      let v: number = values[i];
      if (isNaN(v)) {
        v = 0;
      }
      pts += '<c:pt idx="' + i.toString() + '"><c:v>' + PptxCharts.numText(v) + '</c:v></c:pt>';
    }
    let col: string = PptxCharts.colLetter(seriesIdx + 2);
    return '<c:numRef><c:f>Sheet1!$' + col + '$2:$' + col + '$' + (count + 1).toString() + '</c:f>' +
      '<c:numCache><c:formatCode>General</c:formatCode><c:ptCount val="' + count.toString() + '"/>' +
      pts + '</c:numCache></c:numRef>';
  }

  // 数值序列化: 整数不带小数点, 小数最多 4 位
  private static numText(v: number): string {
    if (v === Math.round(v) && Math.abs(v) < 1e15) {
      return Math.round(v).toString();
    }
    return v.toFixed(4).replace(/0+$/, '').replace(/\.$/, '');
  }

  private static colLetter(idx: number): string {
    // 1 -> A, 2 -> B, ...
    let n: number = idx;
    let out: string = '';
    while (n > 0) {
      let rem: number = (n - 1) % 26;
      out = String.fromCharCode(65 + rem) + out;
      n = Math.floor((n - 1) / 26);
    }
    return out === '' ? 'A' : out;
  }

  private static catAx(colors: ThemeColors): string {
    return '<c:catAx><c:axId val="' + AX_CAT + '"/>' +
      '<c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/>' +
      '<c:tickLblPos val="nextTo"/>' + PptxCharts.txPr(colors, 1000) +
      '<c:crossAx val="' + AX_VAL + '"/><c:crosses val="autoZero"/><c:auto val="1"/>' +
      '<c:lblAlgn val="ctr"/><c:lblOffset val="100"/><c:noMultiLvlLbl val="0"/></c:catAx>';
  }

  private static valAx(colors: ThemeColors): string {
    return '<c:valAx><c:axId val="' + AX_VAL + '"/>' +
      '<c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/>' +
      '<c:majorGridlines><c:spPr><a:ln w="9525"><a:solidFill><a:srgbClr val="' +
      (colors.dark ? '1E293B' : 'E2E8F0') + '"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>' +
      '<c:numFmt formatCode="General" sourceLinked="0"/>' +
      '<c:tickLblPos val="nextTo"/>' + PptxCharts.txPr(colors, 1000) +
      '<c:crossAx val="' + AX_CAT + '"/><c:crosses val="autoZero"/></c:valAx>';
  }

  private static dLbls(colors: ThemeColors, showValue: boolean, showPercent: boolean,
    outsideEnd: boolean): string {
    // pie 数据标签放到扇区外(outEnd), 避免深色文字叠在饱和扇区上不可读;
    // doughnut 不支持 dLblPos, 保持默认
    let pos: string = outsideEnd ? '<c:dLblPos val="outEnd"/>' : '';
    return '<c:dLbls><c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr>' +
      '<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="900"><a:solidFill>' +
      '<a:srgbClr val="' + colors.sub + '"/></a:solidFill></a:defRPr></a:pPr>' +
      '<a:endParaRPr lang="zh-CN"/></a:p></c:txPr>' + pos +
      '<c:showLegendKey val="0"/><c:showVal val="' + (showValue ? '1' : '0') + '"/>' +
      '<c:showCatName val="0"/><c:showSerName val="0"/>' +
      '<c:showPercent val="' + (showPercent ? '1' : '0') + '"/><c:showBubbleSize val="0"/></c:dLbls>';
  }

  private static txPr(colors: ThemeColors, size: number): string {
    return '<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="' + size.toString() + '">' +
      '<a:solidFill><a:srgbClr val="' + colors.sub + '"/></a:solidFill>' +
      '<a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/></a:defRPr></a:pPr>' +
      '<a:endParaRPr lang="zh-CN"/></a:p></c:txPr>';
  }
}

// 系列名占位: 空名给默认
function escape0(name: string): string {
  return name === '' ? '系列' : name;
}
