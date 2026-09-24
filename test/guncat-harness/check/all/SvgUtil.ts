// SvgUtil: SVG 源码的校验 / 尺寸解析 / 规整 (纯逻辑模块, 无 HarmonyOS API 依赖)
// 实机结论(6.0.0 调试): 设备栅格引擎要求根元素带显式 width/height, 仅 viewBox 无法解码。
// normalize() 在保存与栅格化前统一补齐, 从源头消除"按文档写必失败"的一整类问题;
// validate() 的报错逐条指向确切缺失项, 避免把模型引向"检查语法"的歧途。
// 注意: 属性探测必须带词边界(\s)——'stroke-width="' 包含 'width="' 子串, 裸 indexOf 会误判。
export class SvgUtil {
  static readonly SVG_XMLNS: string = 'http://www.w3.org/2000/svg';

  // 根元素是否带某属性(词边界: 要求属性名前是空白, 防止 stroke-width 误匹配 width)
  private static hasAttr(rootTag: string, attr: string): boolean {
    let re: RegExp = new RegExp('\\s' + attr + '\\s*=', 'i');
    return re.test(rootTag);
  }

  // 校验: 返回空串表示通过; 非空为可直接送回模型的精确诊断。
  // 缺 width/height 不在此报错——那是可自动修复项, 交给 normalize()(报错会让模型重写而非让工具修复)。
  static validate(svg: string): string {
    if (svg.trim() === '') {
      return 'SVG 内容为空';
    }
    let lower: string = svg.toLowerCase();
    let svgOpen: number = lower.indexOf('<svg');
    if (svgOpen < 0) {
      return 'SVG 缺少 <svg> 根元素';
    }
    if (lower.indexOf('</svg>') < 0) {
      return 'SVG 缺少 </svg> 闭合标签';
    }
    if (lower.indexOf('<script') !== -1 || lower.indexOf('javascript:') !== -1) {
      return 'SVG 不允许包含 <script> 或 javascript: 引用';
    }
    let rootEnd: number = lower.indexOf('>', svgOpen);
    let rootTag: string = rootEnd > svgOpen ? svg.substring(svgOpen, rootEnd) : '';
    if (rootTag.indexOf('xmlns="' + SvgUtil.SVG_XMLNS + '"') < 0) {
      return 'SVG 根元素缺少 xmlns="' + SvgUtil.SVG_XMLNS +
        '" —— 没有它无法栅格化, 请在 <svg 标签上补该属性';
    }
    if (!SvgUtil.hasAttr(rootTag, 'viewBox') &&
      (!SvgUtil.hasAttr(rootTag, 'width') || !SvgUtil.hasAttr(rootTag, 'height'))) {
      return 'SVG 根元素需要 viewBox="0 0 W H"(或 width/height), 否则无法确定画布比例';
    }
    return '';
  }

  // 解析 viewBox / width/height, 返回 [宽, 高, 是否有效]
  static aspect(svg: string): number[] {
    let lower: string = svg.toLowerCase();
    let svgOpen: number = lower.indexOf('<svg');
    let rootEnd: number = svg.indexOf('>', svgOpen);
    if (svgOpen < 0 || rootEnd < 0) {
      return [0, 0, 0];
    }
    let rootTag: string = svg.substring(svgOpen, rootEnd);
    let w: number = 0;
    let h: number = 0;
    let vb: string[] = SvgUtil.attrValue(rootTag, 'viewBox');
    if (vb.length === 1) {
      let parts: string[] = vb[0].trim().split(/\s+/);
      if (parts.length === 4) {
        w = parseFloat(parts[2]);
        h = parseFloat(parts[3]);
      }
    }
    if (!(w > 0 && h > 0)) {
      let ws: string[] = SvgUtil.attrValue(rootTag, 'width');
      let hs: string[] = SvgUtil.attrValue(rootTag, 'height');
      if (ws.length === 1 && hs.length === 1) {
        w = parseFloat(ws[0]);
        h = parseFloat(hs[0]);
      }
    }
    if (w > 0 && h > 0) {
      return [w, h, 1];
    }
    return [0, 0, 0];
  }

  // 规整: 根元素缺失 width/height 时按 viewBox 比例(无 viewBox 用 defaultSize 正方形)补齐。
  // 已有属性保持原样; 返回规整后的完整源码(未变化时原样返回)。
  static normalize(svg: string, defaultSize: number): string {
    let lower: string = svg.toLowerCase();
    let svgOpen: number = lower.indexOf('<svg');
    let rootEnd: number = svg.indexOf('>', svgOpen);
    if (svgOpen < 0 || rootEnd < 0) {
      return svg;
    }
    let rootTag: string = svg.substring(svgOpen, rootEnd);
    let hasW: boolean = SvgUtil.hasAttr(rootTag, 'width');
    let hasH: boolean = SvgUtil.hasAttr(rootTag, 'height');
    if (hasW && hasH) {
      return svg;
    }
    // 补齐目标: viewBox 比例优先, 否则 defaultSize 正方形
    let vw: number = defaultSize;
    let vh: number = defaultSize;
    let dims: number[] = SvgUtil.aspect(svg);
    if (dims[2] > 0) {
      vw = dims[0];
      vh = dims[1];
    }
    let inject: string = '';
    if (!hasW) {
      inject += ' width="' + SvgUtil.numText(vw) + '"';
    }
    if (!hasH) {
      inject += ' height="' + SvgUtil.numText(vh) + '"';
    }
    let head: string = svg.substring(0, svgOpen + 4); // '<svg'
    return head + inject + svg.substring(svgOpen + 4);
  }

  // 取 attr="value"(第一个命中, 带词边界), 无则空数组
  static attrValue(tag: string, attr: string): string[] {
    let re: RegExp = new RegExp('\\s' + attr + '\\s*=\\s*"([^"]*)"', 'i');
    let m: RegExpMatchArray | null = tag.match(re);
    if (m === null || m.length < 2) {
      return [];
    }
    return [m[1]];
  }

  private static numText(v: number): string {
    if (v === Math.round(v)) {
      return Math.round(v).toString();
    }
    return v.toFixed(2).replace(/0+$/, '').replace(/\.$/, '');
  }
}
