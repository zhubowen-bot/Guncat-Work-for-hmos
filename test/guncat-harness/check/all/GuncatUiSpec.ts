// 交互模式 (Intelligent UI) 单一事实源:
// 1. guncat-ui DSL 的模型层 (控件 / 元素 / 文档) 与解析器 (容错 + 限额);
// 2. 流式分词器: 从流式 Markdown 中切出 ```guncat-ui 围栏块 (含未闭合态);
// 3. 交互回传载荷构造: 把用户在界面上的输入组装成回传给模型的中文消息;
// 4. 系统提示词正文: 与解析器同文件维护, 保证「模型看到的契约」= 「我们解析的契约」。
// 纯逻辑模块(无 ArkUI / 无 Kit API), 可被 .ets 与 harness 同时引用。

// ===== 限额 (防畸形 JSON 撑爆渲染) =====
export class GuncatUiLimits {
  static readonly MAX_CONTROLS: number = 12;
  static readonly MAX_ELEMENTS: number = 60;
  static readonly MAX_ROWS: number = 60;
  static readonly MAX_COLS: number = 8;
  static readonly MAX_BARS: number = 24;
  static readonly MAX_SERIES: number = 6;
  static readonly MAX_OPTIONS: number = 24;
  static readonly MAX_LINES: number = 24;
  static readonly MAX_TEXT: number = 4000;
  static readonly MAX_TITLE: number = 160;
  static readonly MAX_BARS_RENDER: number = 12;
}

// ===== 元素种类 =====
export class GuncatUiKind {
  static readonly CARD: string = 'card';
  static readonly LAYOUT: string = 'layout';
  static readonly NOTE: string = 'note';
  static readonly METRIC: string = 'metric';
  static readonly METRICS: string = 'metrics';
  static readonly PROGRESS: string = 'progress';
  static readonly TABLE: string = 'table';
  static readonly CHART: string = 'chart';
  static readonly FORM: string = 'form';
  static readonly CHOICE: string = 'choice';
  static readonly MARKDOWN: string = 'markdown';

  static isAllowed(kind: string): boolean {
    return kind === GuncatUiKind.CARD || kind === GuncatUiKind.LAYOUT ||
      kind === GuncatUiKind.NOTE || kind === GuncatUiKind.METRIC ||
      kind === GuncatUiKind.METRICS || kind === GuncatUiKind.PROGRESS ||
      kind === GuncatUiKind.TABLE || kind === GuncatUiKind.CHART ||
      kind === GuncatUiKind.FORM || kind === GuncatUiKind.CHOICE ||
      kind === GuncatUiKind.MARKDOWN;
  }
}

// 控件类型
export class GuncatUiControlType {
  static readonly SLIDER: string = 'slider';
  static readonly TOGGLE: string = 'toggle';
  static readonly SELECT: string = 'select';
  static readonly TEXT: string = 'text';

  static isAllowed(t: string): boolean {
    return t === GuncatUiControlType.SLIDER || t === GuncatUiControlType.TOGGLE ||
      t === GuncatUiControlType.SELECT || t === GuncatUiControlType.TEXT;
  }
}

// 动作样式 / 选择样式
export class GuncatUiActionStyle {
  static readonly PRIMARY: string = 'primary';
  static readonly SECONDARY: string = 'secondary';

  static isAllowed(s: string): boolean {
    return s === GuncatUiActionStyle.PRIMARY || s === GuncatUiActionStyle.SECONDARY;
  }
}

// 图表类型
export class GuncatUiChartType {
  static readonly BAR: string = 'bar';
  static readonly LINE: string = 'line';
  static readonly PIE: string = 'pie';

  static isAllowed(t: string): boolean {
    return t === GuncatUiChartType.BAR || t === GuncatUiChartType.LINE ||
      t === GuncatUiChartType.PIE;
  }
}

// ===== 模型类 =====
export class GuncatUiInput {
  name: string = '';
  type: string = GuncatUiControlType.TEXT;
  label: string = '';
  placeholder: string = '';
  defText: string = '';
  defNum: number = 0;
  defBool: boolean = false;
  min: number = 0;
  max: number = 100;
  step: number = 1;
  unit: string = '';
  options: string[] = [];
}

export class GuncatUiAction {
  id: string = '';
  label: string = '';
  style: string = GuncatUiActionStyle.PRIMARY;
  // 表单提交时的提示语(替代直接把全部参数拼成用户消息)
  confirm: string = '';
}

export class GuncatUiElement {
  id: string = '';
  kind: string = '';
  title: string = '';
  text: string = '';
  layout: string = '';
  // 引用控件 id
  bind: string = '';
  bind2: string = '';
  // 标量
  value: number = 0;
  total: number = 100;
  unit: string = '';
  label: string = '';
  delta: string = '';
  // 列表
  bars: number[] = [];
  lines: string[] = [];
  headers: string[] = [];
  rows: string[][] = [];
  options: string[] = [];
  selects: string[] = [];
  // 图表
  chart: string = GuncatUiChartType.BAR;
  series: string[] = [];
  values: number[] = [];
  labels: string[] = [];
  totalLabel: string = '';
  // metrics 的分组指标(每个元素仍用同一元素类承载)
  items: GuncatUiElement[] = [];
  // 提示条语气 info/success/warn/danger
  tone: string = 'info';
  // form 引用的控件名
  controls: string[] = [];
  // 交互
  action: GuncatUiAction | null = null;
  action2: GuncatUiAction | null = null;
  // 嵌套
  children: GuncatUiElement[] = [];
}

export class GuncatUiSpec {
  version: number = 1;
  title: string = '';
  subtitle: string = '';
  controls: GuncatUiInput[] = [];
  elements: GuncatUiElement[] = [];

  findControl(name: string): GuncatUiInput | null {
    for (let i: number = 0; i < this.controls.length; i++) {
      if (this.controls[i].name === name) {
        return this.controls[i];
      }
    }
    return null;
  }
}

// 一个文本片段: fence 为 true 表示这是 ```guncat-ui 块正文, json 为 false 表示 JSON 非法
export class GuncatUiFragment {
  text: string = '';
  fence: boolean = false;
  complete: boolean = true;
}

// ===== 基础取值helper =====
function asString(v: Object | undefined | null, fallback: string): string {
  if (v === undefined || v === null) {
    return fallback;
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number' || typeof v === 'boolean') {
    return String(v);
  }
  return fallback;
}

function asNumber(v: Object | undefined | null, fallback: number): number {
  if (v === undefined || v === null) {
    return fallback;
  }
  if (typeof v === 'number') {
    let n: number = v as number;
    if (isNaN(n) || !isFinite(n)) {
      return fallback;
    }
    return n;
  }
  if (typeof v === 'string') {
    let n2: number = parseFloat(v as string);
    if (isNaN(n2) || !isFinite(n2)) {
      return fallback;
    }
    return n2;
  }
  return fallback;
}

function asBoolean(v: Object | undefined | null, fallback: boolean): boolean {
  if (v === undefined || v === null) {
    return fallback;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  if (typeof v === 'string') {
    let s: string = (v as string).toLowerCase();
    if (s === 'true' || s === 'yes' || s === '1' || s === '开' || s === '是') {
      return true;
    }
    if (s === 'false' || s === 'no' || s === '0' || s === '关' || s === '否') {
      return false;
    }
  }
  return fallback;
}

function clampText(s: string, max: number): string {
  if (s.length > max) {
    return s.substring(0, max);
  }
  return s;
}

function toList(v: Object | undefined | null): Object[] {
  if (v === undefined || v === null || !(v instanceof Array)) {
    return [];
  }
  return v as Object[];
}

function toStrList(v: Object | undefined | null, max: number): string[] {
  let raw: Object[] = toList(v);
  let out: string[] = [];
  for (let i: number = 0; i < raw.length && i < max; i++) {
    let item: Object = raw[i];
    let s: string = '';
    if (typeof item === 'string' || typeof item === 'number' || typeof item === 'boolean') {
      s = String(item);
    }
    if (s !== '') {
      out.push(clampText(s, GuncatUiLimits.MAX_TITLE));
    }
  }
  return out;
}

function toNumList(v: Object | undefined | null, max: number): number[] {
  let raw: Object[] = toList(v);
  let out: number[] = [];
  for (let i: number = 0; i < raw.length && i < max; i++) {
    let item: Object = raw[i];
    if (typeof item === 'number' || typeof item === 'string') {
      let n: number = asNumber(item, NaN);
      if (!isNaN(n)) {
        out.push(n);
      } else {
        out.push(0);
      }
    } else {
      out.push(0);
    }
  }
  return out;
}

// ===== 解析: 控件 =====
function parseInput(v: Object): GuncatUiInput | null {
  if (v === null || !(v instanceof Object)) {
    return null;
  }
  let obj: Record<string, Object> = v as Record<string, Object>;
  let input: GuncatUiInput = new GuncatUiInput();
  input.name = asString(obj['name'], '');
  if (input.name === '') {
    return null;
  }
  let type: string = asString(obj['type'], GuncatUiControlType.TEXT);
  input.type = GuncatUiControlType.isAllowed(type) ? type : GuncatUiControlType.TEXT;
  input.label = clampText(asString(obj['label'], input.name), GuncatUiLimits.MAX_TITLE);
  input.placeholder = clampText(asString(obj['placeholder'], ''), GuncatUiLimits.MAX_TITLE);
  input.unit = clampText(asString(obj['unit'], ''), 16);
  input.min = asNumber(obj['min'], 0);
  input.max = asNumber(obj['max'], 100);
  if (input.max <= input.min) {
    input.max = input.min + 1;
  }
  input.step = asNumber(obj['step'], 1);
  if (input.step <= 0) {
    input.step = 1;
  }
  input.options = toStrList(obj['options'], GuncatUiLimits.MAX_OPTIONS);
  let def: Object | undefined = obj['default'];
  if (input.type === GuncatUiControlType.TOGGLE) {
    input.defBool = asBoolean(def, false);
  } else if (input.type === GuncatUiControlType.SLIDER) {
    input.defNum = asNumber(def, (input.min + input.max) / 2);
  } else if (input.type === GuncatUiControlType.SELECT) {
    let prefer: string = asString(def, '');
    input.defText = input.options.length > 0 ? input.options[0] : '';
    for (let i: number = 0; i < input.options.length; i++) {
      if (input.options[i] === prefer) {
        input.defText = prefer;
        break;
      }
    }
  } else {
    input.defText = clampText(asString(def, ''), GuncatUiLimits.MAX_TEXT);
  }
  return input;
}

// ===== 解析: 动作 =====
function parseAction(v: Object | undefined): GuncatUiAction | null {
  if (v === undefined || v === null || !(v instanceof Object)) {
    return null;
  }
  let obj: Record<string, Object> = v as Record<string, Object>;
  let action: GuncatUiAction = new GuncatUiAction();
  action.id = asString(obj['id'], '');
  if (action.id === '') {
    return null;
  }
  action.label = clampText(asString(obj['label'], '继续'), 40);
  let style: string = asString(obj['style'], GuncatUiActionStyle.PRIMARY);
  action.style = GuncatUiActionStyle.isAllowed(style) ? style : GuncatUiActionStyle.PRIMARY;
  action.confirm = clampText(asString(obj['confirm'], ''), 200);
  return action;
}

// ===== 解析: 元素(递归) =====
function parseElement(v: Object): GuncatUiElement | null {
  if (v === null || !(v instanceof Object)) {
    return null;
  }
  let obj: Record<string, Object> = v as Record<string, Object>;
  let kind: string = asString(obj['kind'], '');
  if (!GuncatUiKind.isAllowed(kind)) {
    return null;
  }
  let el: GuncatUiElement = new GuncatUiElement();
  el.kind = kind;
  el.id = asString(obj['id'], '');
  el.title = clampText(asString(obj['title'], ''), GuncatUiLimits.MAX_TITLE);
  el.text = clampText(asString(obj['text'], ''), GuncatUiLimits.MAX_TEXT);
  el.layout = asString(obj['layout'], '');
  el.bind = asString(obj['bind'], '');
  el.bind2 = asString(obj['bind2'], '');
  el.value = asNumber(obj['value'], 0);
  el.total = asNumber(obj['total'], 100);
  el.unit = clampText(asString(obj['unit'], ''), 16);
  el.label = clampText(asString(obj['label'], ''), 40);
  el.delta = clampText(asString(obj['delta'], ''), 40);
  el.bars = toNumList(obj['bars'], GuncatUiLimits.MAX_BARS);
  el.lines = toStrList(obj['lines'], GuncatUiLimits.MAX_LINES);
  el.headers = toStrList(obj['headers'], GuncatUiLimits.MAX_COLS);
  el.options = toStrList(obj['options'], GuncatUiLimits.MAX_OPTIONS);
  el.selects = toStrList(obj['selects'], GuncatUiLimits.MAX_OPTIONS);
  el.series = toStrList(obj['series'], GuncatUiLimits.MAX_SERIES);
  el.values = toNumList(obj['values'], GuncatUiLimits.MAX_BARS + GuncatUiLimits.MAX_SERIES);
  el.labels = toStrList(obj['labels'], GuncatUiLimits.MAX_BARS);
  el.totalLabel = clampText(asString(obj['totalLabel'], ''), 40);
  let chart: string = asString(obj['chart'], GuncatUiChartType.BAR);
  el.chart = GuncatUiChartType.isAllowed(chart) ? chart : GuncatUiChartType.BAR;
  el.action = parseAction(obj['action']);
  el.action2 = parseAction(obj['action2']);
  el.controls = toStrList(obj['controls'], GuncatUiLimits.MAX_CONTROLS);
  let tone: string = asString(obj['tone'], 'info');
  el.tone = (tone === 'success' || tone === 'warn' || tone === 'danger') ? tone : 'info';
  // metrics 的 items: 复用同一元素类(只取 label/value/unit/delta)
  let rawItems: Object[] = toList(obj['items']);
  let items: GuncatUiElement[] = [];
  for (let i: number = 0; i < rawItems.length && i < 6; i++) {
    let rawItem: Object = rawItems[i];
    if (rawItem === null || !(rawItem instanceof Object)) {
      continue;
    }
    let itemObj: Record<string, Object> = rawItem as Record<string, Object>;
    let metric: GuncatUiElement = new GuncatUiElement();
    metric.kind = GuncatUiKind.METRIC;
    metric.label = clampText(asString(itemObj['label'], ''), 40);
    metric.value = asNumber(itemObj['value'], 0);
    metric.unit = clampText(asString(itemObj['unit'], ''), 16);
    metric.delta = clampText(asString(itemObj['delta'], ''), 40);
    items.push(metric);
  }
  el.items = items;
  // 表格行
  let rawRows: Object[] = toList(obj['rows']);
  let rows: string[][] = [];
  for (let i: number = 0; i < rawRows.length && i < GuncatUiLimits.MAX_ROWS; i++) {
    let rawRow: Object = rawRows[i];
    if (!(rawRow instanceof Array)) {
      continue;
    }
    let cells: Object[] = rawRow as Object[];
    let row: string[] = [];
    for (let c: number = 0; c < cells.length && c < GuncatUiLimits.MAX_COLS; c++) {
      let cell: Object = cells[c];
      let s: string = '';
      if (typeof cell === 'string' || typeof cell === 'number' || typeof cell === 'boolean') {
        s = String(cell);
      }
      row.push(clampText(s, GuncatUiLimits.MAX_TITLE));
    }
    rows.push(row);
  }
  el.rows = rows;
  // 嵌套子元素
  let rawChildren: Object[] = toList(obj['children']);
  let children: GuncatUiElement[] = [];
  for (let i: number = 0; i < rawChildren.length && i < GuncatUiLimits.MAX_ELEMENTS; i++) {
    let child: GuncatUiElement | null = parseElement(rawChildren[i]);
    if (child !== null) {
      children.push(child);
    }
  }
  el.children = children;
  return el;
}

// ===== 解析: 文档 =====
export class GuncatUiParseResult {
  spec: GuncatUiSpec | null = null;
  error: string = '';
}

// 从流式缓冲中截取某个键之后的原文(用于未闭合 JSON 的渐进解析)
function sliceAfterKey(text: string, key: string): string {
  let token: string = '"' + key + '"';
  let idx: number = text.indexOf(token);
  if (idx < 0) {
    return '';
  }
  return text.substring(idx + token.length);
}

export class GuncatUiSpecParser {
  // 容错解析: 缺字段用默认值, 未知 kind 直接丢弃; 结构性错误(非对象/无元素)返回 error
  static parse(json: string): GuncatUiParseResult {
    let result: GuncatUiParseResult = new GuncatUiParseResult();
    let trimmed: string = json.trim();
    if (trimmed === '') {
      result.error = '内容为空';
      return result;
    }
    let parsed: Object = JSON.parse(trimmed) as Object;
    if (parsed === null || !(parsed instanceof Object) || parsed instanceof Array) {
      result.error = '顶层必须是 JSON 对象';
      return result;
    }
    let obj: Record<string, Object> = parsed as Record<string, Object>;
    let spec: GuncatUiSpec = new GuncatUiSpec();
    spec.version = asNumber(obj['version'], 1);
    spec.title = clampText(asString(obj['title'], ''), GuncatUiLimits.MAX_TITLE);
    spec.subtitle = clampText(asString(obj['subtitle'], ''), GuncatUiLimits.MAX_TITLE);
    let rawControls: Object[] = toList(obj['controls']);
    for (let i: number = 0; i < rawControls.length && i < GuncatUiLimits.MAX_CONTROLS; i++) {
      let input: GuncatUiInput | null = parseInput(rawControls[i]);
      if (input !== null) {
        spec.controls.push(input);
      }
    }
    let rawElements: Object[] = toList(obj['elements']);
    for (let i: number = 0; i < rawElements.length && i < GuncatUiLimits.MAX_ELEMENTS; i++) {
      let el: GuncatUiElement | null = parseElement(rawElements[i]);
      if (el !== null) {
        spec.elements.push(el);
      }
    }
    if (spec.elements.length === 0) {
      result.error = '没有可渲染的元素(elements 为空或 kind 均非法)';
      return result;
    }
    result.spec = spec;
    return result;
  }

  // 流式容错解析: JSON 尚未闭合时也尽量给出可渲染的中间态(界面边生成边成形)。
  // 尚未成形时返回「骨架文档」(title 可能已有, elements 为空), 让界面立刻出现占位。
  static parseStreaming(json: string): GuncatUiParseResult {
    let text: string = json;
    let completed: boolean = false;
    // 尾部未闭合就补齐括号, 让完整的前缀元素先解析出来
    try {
      GuncatUiSpecParser.parse(text);
      completed = true;
    } catch (e) {
      text = GuncatUiSpecParser.repairOpenJson(text);
    }
    let result: GuncatUiParseResult;
    try {
      result = GuncatUiSpecParser.parse(text);
    } catch (e2) {
      result = new GuncatUiParseResult();
      result.error = '尚未成形';
    }
    if (!completed && result.spec !== null) {
      // 中间态: 元素可能少于最终结果, 调用方据 fragment.complete 判定是否可交互
      return result;
    }
    if (result.spec !== null) {
      return result;
    }
    // 补括号仍失败: 退化为「逐元素」渐进解析
    let loose: GuncatUiParseResult = GuncatUiSpecParser.parseLoosePrefix(json);
    if (loose.spec === null) {
      // 连一个完整元素都没有: 给出骨架, 保证流式期间界面盒子已经存在
      let skeleton: GuncatUiParseResult = new GuncatUiParseResult();
      let empty: GuncatUiSpec = new GuncatUiSpec();
      empty.title = GuncatUiSpecParser.looseTitle(json);
      skeleton.spec = empty;
      skeleton.error = loose.error;
      return skeleton;
    }
    return loose;
  }

  // 从流式缓冲中尽可能取出 title
  private static looseTitle(json: string): string {
    let tail: string = sliceAfterKey(json, 'title');
    let colon: number = tail.indexOf(':');
    if (colon < 0) {
      return '';
    }
    let after: string = tail.substring(colon + 1).trim();
    if (!after.startsWith('"')) {
      return '';
    }
    let end: number = after.indexOf('"', 1);
    if (end <= 0) {
      return '';
    }
    return clampText(after.substring(1, end), GuncatUiLimits.MAX_TITLE);
  }

  // 截断到最后一个完整的 `}` 并把未闭合的 [ { 补齐
  private static repairOpenJson(text: string): string {
    let lastBrace: number = text.lastIndexOf('}');
    let body: string = lastBrace >= 0 ? text.substring(0, lastBrace + 1) : text;
    let opens: string[] = [];
    let inString: boolean = false;
    let escaped: boolean = false;
    for (let i: number = 0; i < body.length; i++) {
      let ch: string = body.charAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch === '\\') {
          escaped = true;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
      } else if (ch === '{' || ch === '[') {
        opens.push(ch);
      } else if (ch === '}' || ch === ']') {
        if (opens.length > 0) {
          opens.pop();
        }
      }
    }
    let out: string = body;
    for (let i: number = opens.length - 1; i >= 0; i--) {
      out = out + (opens[i] === '{' ? '}' : ']');
    }
    return out;
  }

  // 最宽松的退化路径: 只保留已闭合的元素对象, 用顶层字段拼出可渲染文档
  private static parseLoosePrefix(json: string): GuncatUiParseResult {
    let result: GuncatUiParseResult = new GuncatUiParseResult();
    let out: GuncatUiSpec = new GuncatUiSpec();
    out.title = GuncatUiSpecParser.looseTitle(json);
    let elementsRaw: string = sliceAfterKey(json, 'elements');
    let arrStart: number = elementsRaw.indexOf('[');
    if (arrStart < 0) {
      result.error = '尚未成形';
      return result;
    }
    let body: string = elementsRaw.substring(arrStart + 1);
    // 逐个扫描顶层 { ... }, 只接受成对闭合的片段
    let depth: number = 0;
    let inString: boolean = false;
    let escaped: boolean = false;
    let start: number = -1;
    for (let i: number = 0; i < body.length; i++) {
      let ch: string = body.charAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch === '\\') {
          escaped = true;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
      } else if (ch === '{') {
        if (depth === 0) {
          start = i;
        }
        depth++;
      } else if (ch === '}') {
        if (depth > 0) {
          depth--;
          if (depth === 0 && start >= 0) {
            let chunk: string = body.substring(start, i + 1);
            try {
              let el: GuncatUiElement | null = parseElement(JSON.parse(chunk) as Object);
              if (el !== null && out.elements.length < GuncatUiLimits.MAX_ELEMENTS) {
                out.elements.push(el);
              }
            } catch (e) {
              // 单个元素非法: 跳过
            }
            start = -1;
          }
        }
      }
    }
    if (out.elements.length === 0) {
      result.error = '尚未成形';
      return result;
    }
    result.spec = out;
    return result;
  }
}

// ===== 围栏分词: 从流式 Markdown 中切出 guncat-ui 块 =====
export class GuncatUiProgress {
  spec: GuncatUiSpec | null = null;
  error: string = '';
}

export class GuncatUiBlocks {
  static readonly LANG: string = 'guncat-ui';
  static readonly OPEN: string = '```guncat-ui';
  static readonly FENCE: string = '```';

  // 从 start 起寻找开栏位置: "```guncat-ui" 需独占行首(允许前置空白)
  private static findOpen(text: string, start: number): number {
    let from: number = start;
    while (from <= text.length) {
      let idx: number = text.indexOf(GuncatUiBlocks.OPEN, from);
      if (idx < 0) {
        return -1;
      }
      let lineStart: number = text.lastIndexOf('\n', idx - 1) + 1;
      let prefix: string = text.substring(lineStart, idx);
      if (prefix.trim() === '') {
        return idx;
      }
      from = idx + GuncatUiBlocks.OPEN.length;
    }
    return -1;
  }

  // 返回片段序列: fence=false 为普通文本, fence=true 为 guncat-ui 块正文
  static split(text: string): GuncatUiFragment[] {
    let fragments: GuncatUiFragment[] = [];
    let cursor: number = 0;
    while (cursor < text.length) {
      let open: number = GuncatUiBlocks.findOpen(text, cursor);
      if (open < 0) {
        let tail: string = text.substring(cursor);
        if (tail !== '') {
          let f: GuncatUiFragment = new GuncatUiFragment();
          f.text = tail;
          fragments.push(f);
        }
        break;
      }
      if (open > cursor) {
        let head: GuncatUiFragment = new GuncatUiFragment();
        head.text = text.substring(cursor, open);
        fragments.push(head);
      }
      let bodyStart: number = open + GuncatUiBlocks.OPEN.length;
      // 跳过语言标记所在行的剩余部分(允许 ```guncat-ui 后有空格/回车)
      let nl: number = text.indexOf('\n', bodyStart);
      if (nl < 0) {
        // 语言标记行尚未结束(流式中): 整段作为未完成块
        let partial: GuncatUiFragment = new GuncatUiFragment();
        partial.text = text.substring(bodyStart);
        partial.fence = true;
        partial.complete = false;
        fragments.push(partial);
        break;
      }
      bodyStart = nl + 1;
      let close: number = text.indexOf(GuncatUiBlocks.FENCE, bodyStart);
      if (close < 0) {
        let partial2: GuncatUiFragment = new GuncatUiFragment();
        partial2.text = text.substring(bodyStart);
        partial2.fence = true;
        partial2.complete = false;
        fragments.push(partial2);
        break;
      }
      let body: GuncatUiFragment = new GuncatUiFragment();
      body.text = text.substring(bodyStart, close);
      body.fence = true;
      body.complete = true;
      fragments.push(body);
      // 跳过收尾围栏整行
      let closeLineEnd: number = text.indexOf('\n', close);
      cursor = closeLineEnd < 0 ? text.length : closeLineEnd + 1;
    }
    return fragments;
  }

  // 流式期间取最后一个未完成块的正文(用于「正在生成交互界面」占位)
  static lastPartial(text: string): string {
    let fragments: GuncatUiFragment[] = GuncatUiBlocks.split(text);
    for (let i: number = fragments.length - 1; i >= 0; i--) {
      if (fragments[i].fence && !fragments[i].complete) {
        return fragments[i].text;
      }
    }
    return '';
  }

  // 流式中: 取最后一个未完成块的渐进解析结果(边生成边成形); 无未完成块时返回 null
  static progress(text: string): GuncatUiProgress {
    let fragments: GuncatUiFragment[] = GuncatUiBlocks.split(text);
    for (let i: number = fragments.length - 1; i >= 0; i--) {
      let f: GuncatUiFragment = fragments[i];
      if (f.fence && !f.complete) {
        let r: GuncatUiParseResult = GuncatUiSpecParser.parseStreaming(f.text);
        let progress: GuncatUiProgress = new GuncatUiProgress();
        progress.spec = r.spec;
        progress.error = r.error;
        return progress;
      }
    }
    return null;
  }

  // 解析单个已闭合块(不抛异常, 失败返回 error)
  static parseComplete(body: string): GuncatUiParseResult {
    try {
      return GuncatUiSpecParser.parse(body);
    } catch (e) {
      let result: GuncatUiParseResult = new GuncatUiParseResult();
      result.error = 'JSON 解析失败';
      return result;
    }
  }

  // 还原一个块的原始 Markdown 文本(解析失败时交还 Markdown 库渲染)
  static renderRaw(body: string): string {
    return GuncatUiBlocks.OPEN + '\n' + body + '\n' + GuncatUiBlocks.FENCE;
  }

  // 提取全部已闭合的 guncat-ui 文档
  static extract(text: string): GuncatUiSpec[] {
    let out: GuncatUiSpec[] = [];
    let fragments: GuncatUiFragment[] = GuncatUiBlocks.split(text);
    for (let i: number = 0; i < fragments.length; i++) {
      let f: GuncatUiFragment = fragments[i];
      if (!f.fence || !f.complete) {
        continue;
      }
      try {
        let r: GuncatUiParseResult = GuncatUiSpecParser.parse(f.text);
        if (r.spec !== null) {
          out.push(r.spec);
        }
      } catch (e) {
        // 非法 JSON: 交由调用方按原文渲染, 不阻断消息
      }
    }
    return out;
  }

  // 至少存在一个已闭合且可解析的文档(用于决定是否隐藏原始围栏文本)
  static hasSpec(text: string): boolean {
    return GuncatUiBlocks.extract(text).length > 0;
  }
}

// ===== 交互回传 =====
export class GuncatUiPayload {
  // 'form' = 表单提交(带控件值), 'action' = 按钮/选项点击(带 value)
  kind: string = 'form';
  actionId: string = '';
  confirm: string = '';
  value: string = '';
  label: string = '';
  title: string = '';
  // 控件取值(按控件顺序)
  names: string[] = [];
  labels: string[] = [];
  values: string[] = [];
}

export class GuncatUiMessageBuilder {
  static formatNumber(n: number): string {
    let rounded: number = Math.round(n * 100) / 100;
    return String(rounded);
  }

  static controlValueText(input: GuncatUiInput, state: Record<string, Object>): string {
    let raw: Object | undefined = state[input.name];
    if (input.type === GuncatUiControlType.TOGGLE) {
      return asBoolean(raw, input.defBool) ? '开启' : '关闭';
    }
    if (input.type === GuncatUiControlType.SLIDER) {
      let n: string = GuncatUiMessageBuilder.formatNumber(asNumber(raw, input.defNum));
      return input.unit === '' ? n : n + input.unit;
    }
    let text: string = asString(raw, input.defText);
    return text === '' ? '(空)' : text;
  }

  // 把载荷组装成回传给模型的用户消息(中文, 结构清晰便于模型对齐)
  static toUserText(payload: GuncatUiPayload): string {
    let lines: string[] = [];
    let head: string = '【交互界面回传】';
    if (payload.title !== '') {
      head = head + payload.title;
    }
    lines.push(head);
    if (payload.kind === 'action') {
      lines.push('用户点击了：' + (payload.label !== '' ? payload.label : payload.actionId));
      if (payload.value !== '') {
        lines.push('选择结果：' + payload.value);
      }
    } else {
      lines.push('用户提交了表单输入：');
      for (let i: number = 0; i < payload.names.length; i++) {
        lines.push('- ' + payload.labels[i] + ' = ' + payload.values[i]);
      }
    }
    if (payload.confirm !== '') {
      lines.push('');
      lines.push(payload.confirm);
    }
    return lines.join('\n');
  }
}

// ===== 系统提示词 =====
// 目标是「模型直接输出可交互界面」: 契约必须短、可照抄、有正反例。
export class GuncatUiPrompt {
  static readonly RULES: string = [
    '# 交互界面输出能力（Intelligent UI）',
    '你与用户的每一次交流都以**界面**为交付形态：能可视化的不用文字堆，能操作的不用让用户打字。',
    '你的回答由两部分组成：**简短的引导文字**（1–3 句，说明界面在表达什么、让用户做什么）+ **一个或多个交互界面块**。',
    '界面块用 Markdown 围栏代码块承载：语言标记必须精确写作 guncat-ui，块内是**严格合法的 JSON**（不能有注释、不能有尾随逗号）。',
    '',
    '## 输出骨架（照抄结构，替换内容）',
    '```guncat-ui',
    '{',
    '  "version": 1,',
    '  "title": "界面标题（≤20 字）",',
    '  "subtitle": "一句话补充说明",',
    '  "controls": [',
    '    {"name": "amount", "type": "slider", "label": "金额", "min": 0, "max": 100, "step": 1, "default": 30, "unit": "万"}',
    '  ],',
    '  "elements": [',
    '    {"kind": "metrics", "items": [{"label": "年化收益", "value": 4.8, "unit": "%", "delta": "+0.3"}]},',
    '    {"kind": "chart", "chart": "bar", "title": "收益对比", "labels": ["方案A", "方案B"], "values": [4.8, 3.9], "series": ["年化"]},',
    '    {"kind": "form", "title": "调整参数", "controls": ["amount"], "action": {"id": "recalc", "label": "重新计算", "style": "primary", "confirm": "按新的金额重新测算。"}}',
    '  ]',
    '}',
    '```',
    '',
    '## 元素清单（kind 只能取以下 11 种）',
    '| kind | 用途 | 关键字段 |',
    '|---|---|---|',
    '| card | 卡片容器 | title, text, children |',
    '| layout | 分栏容器 | layout: "list" \\| "grid" \\| "row", children |',
    '| note | 轻提示条 | text, tone: info/success/warn/danger |',
    '| metric | 单个指标 | value, unit, label, delta |',
    '| metrics | 指标组（一行或两列） | items: [{label, value, unit, delta}] |',
    '| progress | 进度条 | value, total, label, unit |',
    '| table | 表格 | headers, rows（二维字符串数组） |',
    '| chart | 图表 | chart: bar/line/pie, labels, values, series, title |',
    '| form | 表单（承载控件与提交按钮） | controls: [控件 name], action: {id, label, style, confirm} |',
    '| choice | 选项按钮组（点一下就回传） | options, action: {id, label?}, action2（可空） |',
    '| markdown | 需要 Markdown 排版的正文 | text |',
    '',
    '## 控件清单（controls 数组，最多 12 个）',
    '| type | 形态 | 关键字段 |',
    '|---|---|---|',
    '| slider | 拖动数值 | min, max, step, default, unit |',
    '| toggle | 开关 | default: true/false |',
    '| select | 下拉单选 | options: ["A","B"], default |',
    '| text | 单行文本 | default, placeholder |',
    '控件必须带 name（英文/数字/下划线），form 通过 controls: ["name1","name2"] 引用。',
    '',
    '## 交互闭环（最重要）',
    '1. 用户在界面上拖动/输入/点击后，系统会把结果作为一条**用户消息**回传给你（形如「【交互界面回传】… / - 金额 = 45 / 按新的金额重新测算。」）。',
    '2. 收到回传后，你必须**基于新参数重新生成界面**（更新后的指标/图表/表格），而不是只回一句"好的"。',
    '3. 需要用户做选择时用 choice（点击即回传，比让用户打字快得多）；需要用户给数值/文本时用 form + 控件。',
    '4. 每个 form 必须有 action（提交按钮）；每个 choice 必须有 action。action.id 用英文短标识，action.label 是按钮文字（≤6 字）。',
    '',
    '## 硬性纪律',
    '- 一个 guncat-ui 块内只放一个 JSON 对象；一次回复最多 3 个界面块，宁少勿滥。',
    '- 界面块之外可以写文字，但必须简短；**禁止在正文里重复界面已经表达的数据**。',
    '- 数值必须真实可核对：来自计算或工具结果的数值直接写；给不出数据的字段不要编造，改用 note 说明。',
    '- 图表 values 与 labels 数量必须一致；bar/line 的 values 默认 1 条序列与 labels 一一对应（多序列才用 series）。',
    '- 颜色/样式由系统决定，不要输出任何颜色、CSS、坐标、像素值。',
    '- 只使用清单内的 kind / type / chart / tone 取值；未知取值会被系统丢弃，界面将缺块。',
    '- 移动端竖屏：一屏能读完优先；元素顺序按「结论 → 数据 → 操作」排列。'
  ].join('\n');

  // 反例(模型最常见的 3 类错误)
  static readonly ANTI_PATTERNS: string = [
    '# 交互界面常见错误（自查）',
    '- 用 markdown 表格代替 table/chart：数据类内容一律用 table/chart/metrics，markdown 只用于叙述。',
    '- 只输出界面不输出行动入口：阐述完结论后若用户可能有下一步诉求，附 form 或 choice。',
    '- JSON 里写中文全角引号、注释、尾随逗号、或把数字写成带单位的字符串（应写 4.8 + "unit": "%"）。'
  ].join('\n');

  static promptSection(): string {
    return GuncatUiPrompt.RULES + '\n\n' + GuncatUiPrompt.ANTI_PATTERNS;
  }

  // 交互模式专有职责段(追加在共享 Agent Loop 提示词之后, 覆盖其「交付格式」章节)
  static readonly INTERACTIVE_DUTY: string = [
    '# 交互模式职责（覆盖上文「输出丰富性原则 / 最终交付」中的文件优先要求）',
    '你运行在「交互模式」下, 用户要的是**能上手操作的界面**, 不是文档文件。因此:',
    '1. 默认交付形态是 guncat-ui 界面块; 只有用户明确要求导出文件(docx/xlsx/pptx/图片)时, 才调用 write_* 工具落盘, 并在界面里用 note 或 choice 告知产出位置。',
    '2. 每轮回复都遵循「引导文字 → 界面块」结构: 文字≤3 句, 界面块 1 个(信息量大时可 2–3 个)。',
    '3. 数据不足时不要编造: 用 note 标注缺口, 并用 form/choice 让用户补齐参数, 收到回传后再算再画。',
    '4. 需要计算/绘图数据时, 优先用 run_js 或 transform_file 在工作区算出真实数值, 再把结果写进界面块。',
    '5. 用户可能在界面上反复调参: 每次回传都要产出**更新后的**界面(新数值), 让界面成为可反复操作的仪表盘。',
    '6. 交互模式不使用 mermaid 导图交付(界面本身就是可视化); 需要结构化的总结时改用 layout/card/table 元素表达。',
    '7. 长任务仍需 todo_write 建清单, 并使用工作区文件保存中间结果; 界面交付必须基于真实计算与文件内容。'
  ].join('\n');
}
