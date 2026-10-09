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

  // 模型常见的等价/近义 kind 归一化(不理解的取值才丢弃)
  static normalize(kind: string): string {
    let k: string = kind.trim().toLowerCase();
    if (k === 'kv' || k === 'keyvalue' || k === 'key-value' || k === 'pair' || k === 'pairs' ||
      k === 'rows' || k === 'tableview') {
      return GuncatUiKind.TABLE;
    }
    if (k === 'stats' || k === 'stat' || k === 'kpi' || k === 'indicators' ||
      k === 'metric-group' || k === 'metricgroup') {
      return GuncatUiKind.METRICS;
    }
    if (k === 'text' || k === 'paragraph' || k === 'p' || k === 'rich' ||
      k === 'richtext' || k === 'markdown-text') {
      return GuncatUiKind.MARKDOWN;
    }
    if (k === 'panel' || k === 'section' || k === 'box' || k === 'group' ||
      k === 'container' || k === 'list' || k === 'stack' || k === 'grid' || k === 'row' ||
      k === 'column' || k === 'columns' || k === 'flex') {
      return GuncatUiKind.LAYOUT;
    }
    if (k === 'tip' || k === 'info' || k === 'alert' || k === 'hint' || k === 'warning' ||
      k === 'message') {
      return GuncatUiKind.NOTE;
    }
    if (k === 'bar' || k === 'line' || k === 'pie' || k === 'area' || k === 'donut' ||
      k === 'doughnut' || k === 'column' || k === 'graph' || k === 'bars' || k === 'lines') {
      return GuncatUiKind.CHART;
    }
    if (k === 'progressbar' || k === 'bar-progress' || k === 'gauge') {
      return GuncatUiKind.PROGRESS;
    }
    if (k === 'input' || k === 'inputs' || k === 'controls' || k === 'fields' ||
      k === 'slider' || k === 'form-group') {
      return GuncatUiKind.FORM;
    }
    if (k === 'options' || k === 'select' || k === 'buttons' || k === 'choices' ||
      k === 'radio') {
      return GuncatUiKind.CHOICE;
    }
    if (k === 'value' || k === 'number' || k === 'kpi-item') {
      return GuncatUiKind.METRIC;
    }
    return GuncatUiKind.isAllowed(k) ? k : '';
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

// 数字保留两位小数(避免 1234.5000000000002 这类浮点尾巴)
function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

// 清洗 JSON 文本中夹带的 JS 注释(模型偶发): 仅处理字符串外且前导为空白的 // 与 /* */
function stripJsonComments(text: string): string {
  if (text.indexOf('//') < 0 && text.indexOf('/*') < 0) {
    return text;
  }
  let cleaned: string = '';
  let inString: boolean = false;
  let escaped: boolean = false;
  let i: number = 0;
  while (i < text.length) {
    let ch: string = text.charAt(i);
    let next: string = i + 1 < text.length ? text.charAt(i + 1) : '';
    if (inString) {
      cleaned = cleaned + ch;
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      i++;
      continue;
    }
    if (ch === '"') {
      inString = true;
      cleaned = cleaned + ch;
      i++;
      continue;
    }
    if (ch === '/' && next === '/') {
      while (i < text.length && text.charAt(i) !== '\n') {
        i++;
      }
      continue;
    }
    if (ch === '/' && next === '*') {
      i += 2;
      while (i < text.length && !(text.charAt(i) === '*' && i + 1 < text.length &&
        text.charAt(i + 1) === '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    cleaned = cleaned + ch;
    i++;
  }
  return cleaned;
}

// 去掉对象/数组内最后一个元素后的尾随逗号(模型偶发)
function stripTrailingCommas(text: string): string {
  let withoutCommas: string = '';
  let inString: boolean = false;
  let escaped: boolean = false;
  for (let i: number = 0; i < text.length; i++) {
    let ch: string = text.charAt(i);
    if (inString) {
      withoutCommas = withoutCommas + ch;
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
      withoutCommas = withoutCommas + ch;
      continue;
    }
    if (ch === ',') {
      // 向前看: 下一个非空白字符若是 } 或 ] 则该逗号是多余的
      let j: number = i + 1;
      while (j < text.length) {
        let probe: string = text.charAt(j);
        if (probe === ' ' || probe === '\t' || probe === '\n' || probe === '\r') {
          j++;
          continue;
        }
        break;
      }
      let after: string = j < text.length ? text.charAt(j) : '';
      if (after === '}' || after === ']') {
        continue;
      }
    }
    withoutCommas = withoutCommas + ch;
  }
  return withoutCommas;
}

// 把全角引号/花括号还原为半角(中文输入法污染的 JSON)
function normalizeFullWidth(text: string): string {
  if (text.indexOf('“') < 0 && text.indexOf('”') < 0 && text.indexOf('｛') < 0 &&
    text.indexOf('｝') < 0 && text.indexOf('：') < 0 && text.indexOf('，') < 0) {
    return text;
  }
  let fixed: string = text;
  fixed = fixed.split('“').join('"');
  fixed = fixed.split('”').join('"');
  fixed = fixed.split('｛').join('{');
  fixed = fixed.split('｝').join('}');
  fixed = fixed.split('［').join('[');
  fixed = fixed.split('］').join(']');
  return fixed;
}

// 清洗候选(注释 + 尾随逗号 + 全角符号), 解析失败时按候选逐级重试
function sanitizeJsonText(text: string): string {
  return stripTrailingCommas(stripJsonComments(normalizeFullWidth(text)));
}

// 顶层容器括号是否闭合(用于识别围栏内 JSON 是否被内嵌代码围栏提前截断)
function isBalancedJson(text: string): boolean {
  let startsWithBrace: boolean = text.startsWith('{');
  let startsWithBracket: boolean = text.startsWith('[');
  if (!startsWithBrace && !startsWithBracket) {
    return false;
  }
  let round: number = 0;
  let square: number = 0;
  let inString: boolean = false;
  let escaped: boolean = false;
  for (let i: number = 0; i < text.length; i++) {
    let ch: string = text.charAt(i);
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
      round++;
    } else if (ch === '}') {
      round--;
      if (round < 0) {
        return false;
      }
    } else if (ch === '[') {
      square++;
    } else if (ch === ']') {
      square--;
      if (square < 0) {
        return false;
      }
    }
  }
  return round === 0 && square === 0;
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
  let strs: string[] = [];
  for (let i: number = 0; i < raw.length && i < max; i++) {
    let item: Object = raw[i];
    let s: string = '';
    if (typeof item === 'string' || typeof item === 'number' || typeof item === 'boolean') {
      s = String(item);
    }
    if (s !== '') {
      strs.push(clampText(s, GuncatUiLimits.MAX_TITLE));
    }
  }
  return strs;
}

function toNumList(v: Object | undefined | null, max: number): number[] {
  let raw: Object[] = toList(v);
  let nums: number[] = [];
  for (let i: number = 0; i < raw.length && i < max; i++) {
    let item: Object = raw[i];
    if (typeof item === 'number' || typeof item === 'string') {
      let n: number = asNumber(item, NaN);
      if (!isNaN(n)) {
        nums.push(n);
      } else {
        nums.push(0);
      }
    } else {
      nums.push(0);
    }
  }
  return nums;
}

// kv / rows / items 形态的键值对 → 两列 rows(模型常把表格写成 [{label,value}] 或 [["a","b"]])
function toKeyValueRows(v: Object | undefined | null, max: number): string[][] {
  let raw: Object[] = toList(v);
  let rows: string[][] = [];
  for (let i: number = 0; i < raw.length && i < max; i++) {
    let item: Object = raw[i];
    if (item instanceof Array) {
      let cells: Object[] = item as Object[];
      let row: string[] = [];
      for (let c: number = 0; c < cells.length && c < GuncatUiLimits.MAX_COLS; c++) {
        row.push(clampText(asString(cells[c], ''), GuncatUiLimits.MAX_TITLE));
      }
      if (row.length > 0) {
        rows.push(row);
      }
      continue;
    }
    if (item !== null && item instanceof Object) {
      let o: Record<string, Object> = item as Record<string, Object>;
      let key: string = asString(o['label'], '');
      if (key === '') {
        key = asString(o['key'], '');
      }
      if (key === '') {
        key = asString(o['name'], '');
      }
      if (key === '') {
        key = asString(o['title'], '');
      }
      let value: string = asString(o['value'], '');
      if (value === '') {
        value = asString(o['text'], '');
      }
      if (key === '' && value === '') {
        continue;
      }
      rows.push([clampText(key, GuncatUiLimits.MAX_TITLE),
        clampText(value, GuncatUiLimits.MAX_TITLE)]);
    }
  }
  return rows;
}

// 宽松文本取值: 数字/布尔也接受(模型常把数值直接写进 text/title)
function textField(obj: Record<string, Object>, key: string): string {
  return asString(obj[key], '');
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
    // 模型偶发省略 name: 用 label 兜底, 再退化为下标占位由调用方处理
    input.name = asString(obj['id'], '');
  }
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
  // kind 允许近义/大小写/连字符变体(模型自由发挥时归一化, 完全不认识才丢弃)
  let rawKind: string = asString(obj['kind'], '');
  if (rawKind === '') {
    rawKind = asString(obj['type'], '');
  }
  let kind: string = GuncatUiKind.normalize(rawKind);
  if (kind === '') {
    return null;
  }
  let el: GuncatUiElement = new GuncatUiElement();
  el.kind = kind;
  el.id = asString(obj['id'], '');
  el.title = clampText(textField(obj, 'title'), GuncatUiLimits.MAX_TITLE);
  el.text = clampText(textField(obj, 'text'), GuncatUiLimits.MAX_TEXT);
  if (el.text === '') {
    el.text = clampText(textField(obj, 'content'), GuncatUiLimits.MAX_TEXT);
  }
  if (el.text === '' && kind === GuncatUiKind.CARD) {
    el.text = clampText(textField(obj, 'label'), GuncatUiLimits.MAX_TEXT);
  }
  el.layout = asString(obj['layout'], '');
  el.layout = el.layout.toLowerCase();
  el.bind = asString(obj['bind'], '');
  el.bind2 = asString(obj['bind2'], '');
  el.value = asNumber(obj['value'], 0);
  el.total = asNumber(obj['total'], 100);
  el.unit = clampText(asString(obj['unit'], ''), 16);
  el.label = clampText(textField(obj, 'label'), 40);
  el.delta = clampText(textField(obj, 'delta'), 40);
  el.bars = toNumList(obj['bars'], GuncatUiLimits.MAX_BARS);
  el.lines = toStrList(obj['lines'], GuncatUiLimits.MAX_LINES);
  el.headers = toStrList(obj['headers'], GuncatUiLimits.MAX_COLS);
  el.options = toStrList(obj['options'], GuncatUiLimits.MAX_OPTIONS);
  el.selects = toStrList(obj['selects'], GuncatUiLimits.MAX_OPTIONS);
  el.series = toStrList(obj['series'], GuncatUiLimits.MAX_SERIES);
  el.values = toNumList(obj['values'], GuncatUiLimits.MAX_BARS + GuncatUiLimits.MAX_SERIES);
  el.labels = toStrList(obj['labels'], GuncatUiLimits.MAX_BARS);
  el.totalLabel = clampText(asString(obj['totalLabel'], ''), 40);
  let chart: string = asString(obj['chart'], '').trim().toLowerCase();
  if (chart === '') {
    // chart 类型也可能写在 kind 里(kind: "pie")
    chart = rawKind.trim().toLowerCase();
  }
  if (chart === 'area') {
    chart = GuncatUiChartType.LINE;
  }
  if (chart === 'donut' || chart === 'doughnut' || chart === 'ring') {
    chart = GuncatUiChartType.PIE;
  }
  if (chart === 'column' || chart === 'bars' || chart === 'horizontalBar') {
    chart = GuncatUiChartType.BAR;
  }
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
  // 表格行: 优先 rows(二维数组), 其次 kv / pairs / data(键值对形态)
  let rows: string[][] = [];
  let rawRows: Object[] = toList(obj['rows']);
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
  if (rows.length === 0) {
    let kv: Object[] = toList(obj['kv']);
    if (kv.length === 0) {
      kv = toList(obj['pairs']);
    }
    if (kv.length === 0) {
      kv = toList(obj['data']);
    }
    if (kv.length === 0 && el.kind === GuncatUiKind.TABLE) {
      // 表格元素直接把 items 当键值对(metrics 之外的 items 形态)
      kv = toList(obj['items']);
    }
    if (kv.length > 0) {
      rows = toKeyValueRows(kv, GuncatUiLimits.MAX_ROWS);
    }
  }
  // kv 归一化成 table 时补默认表头
  if (el.kind === GuncatUiKind.TABLE && el.headers.length === 0 && rows.length > 0 &&
    rows[0].length === 2 &&
    (obj['kv'] !== undefined || obj['pairs'] !== undefined || obj['data'] !== undefined)) {
    el.headers = ['指标', '值'];
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

// 从流式缓冲中截取某个键之后的原文(用于未闭合 JSON 的渐进解析)。
// 注意: 必须避免把 "subtitle" / "totalLabel" 之类的键误当成 "title" / "label",
// 因此要求匹配位置的前一个字符不是字母或数字。
function sliceAfterKey(text: string, key: string): string {
  let token: string = '"' + key + '"';
  let from: number = 0;
  while (from <= text.length) {
    let idx: number = text.indexOf(token, from);
    if (idx < 0) {
      return '';
    }
    let prev: string = idx > 0 ? text.charAt(idx - 1) : '';
    let isWordChar: boolean = prev !== '' && /[A-Za-z0-9_]/.test(prev);
    if (!isWordChar) {
      return text.substring(idx + token.length);
    }
    from = idx + token.length;
  }
  return '';
}

export class GuncatUiSpecParser {
  // 容错解析: 缺字段用默认值, 未知 kind 归一化后仍不认识才丢弃; 结构性错误(非对象/无元素)返回 error。
  // 第一遍严格解析(失败抛错, 由调用方决定是否降级为原文渲染), 失败后再清洗注释/尾随逗号/全角符号重试一次。
  static parse(json: string): GuncatUiParseResult {
    let trimmed: string = json.trim();
    if (trimmed === '') {
      let emptyResult: GuncatUiParseResult = new GuncatUiParseResult();
      emptyResult.error = '内容为空';
      return emptyResult;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(trimmed) as Object;
    } catch (e) {
      // 清洗后重试(注释 / 尾随逗号 / 全角引号): 仍失败则把异常抛给调用方
      parsed = JSON.parse(sanitizeJsonText(trimmed)) as Object;
    }
    let result: GuncatUiParseResult = new GuncatUiParseResult();
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
    // 元素列表: elements / items / blocks / content 四种常见写法都接受
    let rawElements: Object[] = GuncatUiSpecParser.collectElements(obj);
    for (let i: number = 0; i < rawElements.length && i < GuncatUiLimits.MAX_ELEMENTS; i++) {
      let el: GuncatUiElement | null = parseElement(rawElements[i]);
      if (el !== null) {
        spec.elements.push(el);
      }
    }
    // 没有任何元素但声明了控件时, 兜底把控件渲染成表单, 而不是给出空白卡片
    if (spec.elements.length === 0 && spec.controls.length > 0) {
      let names: string[] = [];
      for (let i: number = 0; i < spec.controls.length; i++) {
        names.push(spec.controls[i].name);
      }
      let form: GuncatUiElement = new GuncatUiElement();
      form.kind = GuncatUiKind.FORM;
      form.id = 'fallback_form';
      form.title = spec.title;
      form.controls = names;
      let action: GuncatUiAction = new GuncatUiAction();
      action.id = 'submit';
      action.label = '提交';
      action.style = GuncatUiActionStyle.PRIMARY;
      form.action = action;
      spec.elements.push(form);
      spec.title = '';
    }
    if (spec.elements.length === 0) {
      result.error = '没有可渲染的元素(elements 为空或 kind 均非法)';
      return result;
    }
    result.spec = spec;
    return result;
  }

  // 汇总元素的多种写法: elements 数组 / items·blocks·content 数组 / 单个顶层元素对象
  private static collectElements(obj: Record<string, Object>): Object[] {
    let keys: string[] = ['elements', 'items', 'blocks', 'children', 'content', 'sections'];
    for (let i: number = 0; i < keys.length; i++) {
      let raw: Object | undefined = obj[keys[i]];
      if (raw === undefined) {
        continue;
      }
      if (raw instanceof Array) {
        let list: Object[] = raw as Object[];
        if (list.length > 0) {
          return list;
        }
      } else if (raw instanceof Object) {
        // 模型把 elements 写成了单个对象({ "elements": { "kind": "card" } })
        let single: Object[] = [];
        single.push(raw);
        return single;
      }
    }
    // 模型把「单个元素」当成了顶层文档({kind, title, text})
    if (obj['kind'] !== undefined) {
      let self: Object[] = [];
      self.push(obj as Object);
      return self;
    }
    return [];
  }

  // 流式容错解析: JSON 尚未闭合时也尽量给出可渲染的中间态(界面边生成边成形)。
  // 尚未成形时返回「骨架文档」(title 可能已有, elements 为空), 让界面立刻出现占位。
  static parseStreaming(json: string): GuncatUiParseResult {
    // 先清洗(注释/尾随逗号/全角符号)再补括号, 两种容错叠加后中间态的命中率最高
    let raw: string = sanitizeJsonText(json);
    let text: string = raw;
    let completed: boolean = false;
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
      // 中间态: 元素可能少于最终结果, 调用方据 fragment.complete 判定是否可交互。
      // 补括号会截掉尾部, 因此标题与已出现的控件要从原文再扫一遍补齐。
      return GuncatUiSpecParser.mergeRescued(result.spec, raw);
    }
    if (result.spec !== null) {
      return result;
    }
    // 补括号仍失败: 退化为「逐元素」渐进解析(同样先清洗)
    let loose: GuncatUiParseResult = GuncatUiSpecParser.parseLoosePrefix(raw);
    if (loose.spec !== null) {
      return loose;
    }
    // 再退化: 尾部被截断在字符串/半截数字里时, 逐级砍尾重试, 尽量救出已写完的元素。
    // (模型输出超长被截断时, 界面不该永远停在"生成中"的空骨架上)
    let salvaged: GuncatUiParseResult = GuncatUiSpecParser.salvageTruncated(raw);
    if (salvaged.spec !== null && salvaged.spec.elements.length > 0) {
      return salvaged;
    }
    // 连一个元素都没救出来: 退化为「文本级救助」——从**原文**里取出标题与已出现的控件, 做成一张可提交的表单。
    // 传原文而非补括号后的文本: 补括号会截掉尾部, 那里往往正是 title / 控件定义所在。
    return GuncatUiSpecParser.rescue(raw);
  }

  // 把「原文里能扫到的标题/控件」合并进已解析出的中间态文档:
  // 修复补括号截断尾部导致的「标题丢失」「控件只出现一部分」。
  private static mergeRescued(spec: GuncatUiSpec, raw: string): GuncatUiParseResult {
    let result: GuncatUiParseResult = new GuncatUiParseResult();
    if (spec.title === '') {
      spec.title = GuncatUiSpecParser.looseTitle(raw);
    }
    if (spec.subtitle === '') {
      spec.subtitle = GuncatUiSpecParser.looseSubtitle(raw);
    }
    let extra: GuncatUiParseResult = GuncatUiSpecParser.rescue(raw);
    if (extra.spec !== null) {
      // 补齐原文里已声明但补括号阶段被截掉的控件
      for (let i: number = 0; i < extra.spec.controls.length; i++) {
        let candidate: GuncatUiInput = extra.spec.controls[i];
        let exists: boolean = false;
        for (let j: number = 0; j < spec.controls.length; j++) {
          if (spec.controls[j].name === candidate.name) {
            exists = true;
            break;
          }
        }
        if (!exists && spec.controls.length < GuncatUiLimits.MAX_CONTROLS) {
          spec.controls.push(candidate);
        }
      }
      // 表单引用同步补齐(去重, 顺序保持)
      for (let i: number = 0; i < spec.elements.length; i++) {
        let el: GuncatUiElement = spec.elements[i];
        if (el.kind !== GuncatUiKind.FORM) {
          continue;
        }
        for (let j: number = 0; j < spec.controls.length; j++) {
          let name: string = spec.controls[j].name;
          let referenced: boolean = false;
          for (let k: number = 0; k < el.controls.length; k++) {
            if (el.controls[k] === name) {
              referenced = true;
              break;
            }
          }
          if (!referenced) {
            el.controls.push(name);
          }
        }
      }
    }
    result.spec = spec;
    return result;
  }

  // 极端截断的兜底: 从尾部逐级砍掉(最后一行 → 尾部 5% → 20% → 二分), 每次尝试清洗+补括号。
  // 只接受"能解析出至少 1 个元素"的结果, 避免把半截文档当完整文档。
  private static salvageTruncated(json: string): GuncatUiParseResult {
    let base: GuncatUiParseResult = new GuncatUiParseResult();
    base.error = '尚未成形';
    if (json.length < 2) {
      return base;
    }
    let cuts: number[] = [];
    // 1) 砍掉最后一个不完整的行(流式最常见的截断点)
    let lastNl: number = json.lastIndexOf('\n');
    if (lastNl > 0) {
      cuts.push(lastNl);
    }
    // 2) 尾部 5% / 15% / 30%(数字写成 "123.45" 或长字符串被截断的情形)
    cuts.push(json.length - Math.max(1, Math.floor(json.length * 0.05)));
    cuts.push(json.length - Math.max(1, Math.floor(json.length * 0.15)));
    cuts.push(json.length - Math.max(1, Math.floor(json.length * 0.30)));
    // 3) 二分兜底
    cuts.push(Math.floor(json.length / 2));
    for (let i: number = 0; i < cuts.length; i++) {
      let cut: number = cuts[i];
      if (cut <= 1 || cut >= json.length) {
        continue;
      }
      let candidate: string = sanitizeJsonText(json.substring(0, cut));
      let repaired: string = GuncatUiSpecParser.repairOpenJson(candidate);
      try {
        let r: GuncatUiParseResult = GuncatUiSpecParser.parse(repaired);
        if (r.spec !== null && r.spec.elements.length > 0) {
          return r;
        }
      } catch (e) {
        // 该截断点仍不可解析: 换下一个
      }
      let byElement: GuncatUiParseResult = GuncatUiSpecParser.parseLoosePrefix(candidate);
      if (byElement.spec !== null && byElement.spec.elements.length > 0) {
        return byElement;
      }
    }
    return base;
  }

  // 文本级救助: 结构已经完全不可解析时(输出在 controls/开头就被截断),
  // 直接从原文里扫出 title / subtitle / controls, 拼出一张**能真正用的表单**。
  // 目的: 界面卡片永远不出现"什么都没有"的空白态。
  private static rescue(json: string): GuncatUiParseResult {
    let result: GuncatUiParseResult = new GuncatUiParseResult();
    let spec: GuncatUiSpec = new GuncatUiSpec();
    spec.title = GuncatUiSpecParser.looseTitle(json);
    spec.subtitle = GuncatUiSpecParser.looseSubtitle(json);
    // 逐个 name 字段扫出控件(按下标命名兜底)
    let names: string[] = [];
    let search: string = '"name"';
    let from: number = 0;
    while (names.length < GuncatUiLimits.MAX_CONTROLS) {
      let idx: number = json.indexOf(search, from);
      if (idx < 0) {
        break;
      }
      let colon: number = json.indexOf(':', idx + search.length);
      if (colon < 0) {
        break;
      }
      let value: string = GuncatUiSpecParser.readJsonStringAt(json, colon + 1);
      from = colon + 1;
      if (value === '') {
        continue;
      }
      let duplicated: boolean = false;
      for (let i: number = 0; i < names.length; i++) {
        if (names[i] === value) {
          duplicated = true;
          break;
        }
      }
      if (!duplicated) {
        names.push(value);
      }
    }
    if (names.length === 0) {
      result.spec = spec;
      result.error = '尚未成形';
      return result;
    }
    let form: GuncatUiElement = new GuncatUiElement();
    form.kind = GuncatUiKind.FORM;
    form.id = 'rescue_form';
    form.title = '';
    form.controls = names;
    form.action = GuncatUiSpecParser.rescueAction(json);
    for (let i: number = 0; i < names.length; i++) {
      let input: GuncatUiInput = new GuncatUiInput();
      input.name = names[i];
      input.type = GuncatUiControlType.TEXT;
      input.label = names[i];
      spec.controls.push(input);
    }
    spec.elements.push(form);
    result.spec = spec;
    return result;
  }

  private static rescueAction(json: string): GuncatUiAction {
    let action: GuncatUiAction = new GuncatUiAction();
    action.id = 'submit';
    action.label = '提交';
    action.style = GuncatUiActionStyle.PRIMARY;
    // 只在 action 块内找 label(控件自己也有 label, 不能误取)
    let actionIdx: number = json.lastIndexOf('"action"');
    if (actionIdx < 0) {
      return action;
    }
    let block: string = json.substring(actionIdx);
    let idx: number = block.indexOf('"label"');
    if (idx >= 0) {
      let colon: number = block.indexOf(':', idx + 7);
      if (colon >= 0) {
        let value: string = GuncatUiSpecParser.readJsonStringAt(block, colon + 1);
        if (value !== '' && value.length <= 8) {
          action.label = value;
        }
      }
    }
    return action;
  }

  private static looseSubtitle(json: string): string {
    let tail: string = sliceAfterKey(json, 'subtitle');
    let colon: number = tail.indexOf(':');
    if (colon < 0) {
      return '';
    }
    return clampText(GuncatUiSpecParser.readJsonStringAt(tail, colon + 1),
      GuncatUiLimits.MAX_TITLE);
  }

  // 从 ": " 之后读取一个 JSON 字符串字面量(未闭合也能取值), 失败返回 ''
  private static readJsonStringAt(text: string, colonOrFrom: number): string {
    let i: number = colonOrFrom;
    while (i < text.length && (text.charAt(i) === ' ' || text.charAt(i) === '\t')) {
      i++;
    }
    if (i >= text.length || text.charAt(i) !== '"') {
      return '';
    }
    i++;
    let out: string = '';
    let escaped: boolean = false;
    while (i < text.length) {
      let ch: string = text.charAt(i);
      if (escaped) {
        out = out + ch;
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        break;
      } else {
        out = out + ch;
      }
      i++;
    }
    return out;
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
    let repaired: string = body;
    for (let i: number = opens.length - 1; i >= 0; i--) {
      repaired = repaired + (opens[i] === '{' ? '}' : ']');
    }
    return repaired;
  }

  // 最宽松的退化路径: 只保留已闭合的元素对象, 用顶层字段拼出可渲染文档
  private static parseLoosePrefix(json: string): GuncatUiParseResult {
    let result: GuncatUiParseResult = new GuncatUiParseResult();
    let looseSpec: GuncatUiSpec = new GuncatUiSpec();
    looseSpec.title = GuncatUiSpecParser.looseTitle(json);
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
              if (el !== null && looseSpec.elements.length < GuncatUiLimits.MAX_ELEMENTS) {
                looseSpec.elements.push(el);
              }
            } catch (e) {
              // 单个元素非法: 跳过
            }
            start = -1;
          }
        }
      }
    }
    if (looseSpec.elements.length === 0) {
      result.error = '尚未成形';
      return result;
    }
    result.spec = looseSpec;
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

  // 寻找真正的闭合围栏: 依次试每个 ``` 候选, 只接受能让顶层 JSON 闭合的那个。
  // 找不到闭合候选(流式中)返回 -1; 全部候选都不闭合时回退为第一个候选(保证不会漏掉块)。
  private static findClosingFence(text: string, bodyStart: number): number {
    let first: number = -1;
    let from: number = bodyStart;
    while (from <= text.length) {
      let idx: number = text.indexOf(GuncatUiBlocks.FENCE, from);
      if (idx < 0) {
        break;
      }
      if (first < 0) {
        first = idx;
      }
      let body: string = text.substring(bodyStart, idx);
      if (isBalancedJson(sanitizeJsonText(body).trim())) {
        return idx;
      }
      from = idx + GuncatUiBlocks.FENCE.length;
    }
    return first;
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
      // 关键: 块内 JSON 字符串里可能包含 ``` (例如 markdown 元素里嵌代码围栏),
      // 若直接取文本中"下一个 ``` "会把 JSON 截断 → 解析失败 → 界面退化成空骨架。
      // 因此从每个候选闭合围栏试起, 只接受能让顶层括号闭合的那一个。
      let close: number = GuncatUiBlocks.findClosingFence(text, bodyStart);
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
    let specs: GuncatUiSpec[] = [];
    let fragments: GuncatUiFragment[] = GuncatUiBlocks.split(text);
    for (let i: number = 0; i < fragments.length; i++) {
      let f: GuncatUiFragment = fragments[i];
      if (!f.fence || !f.complete) {
        continue;
      }
      try {
        let r: GuncatUiParseResult = GuncatUiSpecParser.parse(f.text);
        if (r.spec !== null) {
          specs.push(r.spec);
        }
      } catch (e) {
        // 非法 JSON: 交由调用方按原文渲染, 不阻断消息
      }
    }
    return specs;
  }

  // 至少存在一个已闭合且可解析的文档(用于决定是否隐藏原始围栏文本)
  static hasSpec(text: string): boolean {
    return GuncatUiBlocks.extract(text).length > 0;
  }
}

// ===== 序列化: 把 GuncatUiSpec 重新写成标准界面块 =====
// 用途: 主回答里的界面块被输出上限截断时, 用「JSON Output 专用请求」另出一份界面,
// 再由这里序列化成规范的 ```guncat-ui 块追加到该条消息末尾, 渲染路径完全复用。
export class GuncatUiSpecWriter {
  // 规范化 JSON 文本(不含围栏)
  static toJsonText(spec: GuncatUiSpec): string {
    let obj: Record<string, Object> = {};
    obj['version'] = 1;
    if (spec.title !== '') {
      obj['title'] = spec.title;
    }
    if (spec.subtitle !== '') {
      obj['subtitle'] = spec.subtitle;
    }
    if (spec.controls.length > 0) {
      let controls: Record<string, Object>[] = [];
      for (let i: number = 0; i < spec.controls.length; i++) {
        let input: GuncatUiInput = spec.controls[i];
        let c: Record<string, Object> = {};
        c['name'] = input.name;
        c['type'] = input.type;
        c['label'] = input.label;
        if (input.type === GuncatUiControlType.SLIDER) {
          c['min'] = input.min;
          c['max'] = input.max;
          c['step'] = input.step;
          c['default'] = input.defNum;
        } else if (input.type === GuncatUiControlType.TOGGLE) {
          c['default'] = input.defBool;
        } else if (input.type === GuncatUiControlType.SELECT) {
          c['options'] = input.options;
          c['default'] = input.defText;
        } else {
          c['default'] = input.defText;
          if (input.placeholder !== '') {
            c['placeholder'] = input.placeholder;
          }
        }
        if (input.unit !== '') {
          c['unit'] = input.unit;
        }
        controls.push(c);
      }
      obj['controls'] = controls;
    }
    let elements: Record<string, Object>[] = [];
    for (let i: number = 0; i < spec.elements.length; i++) {
      elements.push(GuncatUiSpecWriter.elementToJson(spec.elements[i]));
    }
    obj['elements'] = elements;
    return JSON.stringify(obj, null, 2);
  }

  private static elementToJson(el: GuncatUiElement): Record<string, Object> {
    let out: Record<string, Object> = {};
    out['kind'] = el.kind;
    if (el.title !== '') {
      out['title'] = el.title;
    }
    if (el.text !== '') {
      out['text'] = el.text;
    }
    if (el.bind !== '') {
      out['bind'] = el.bind;
    }
    if (el.kind === GuncatUiKind.NOTE) {
      out['tone'] = el.tone;
    }
    if (el.kind === GuncatUiKind.LAYOUT) {
      out['layout'] = el.layout === '' ? 'list' : el.layout;
    }
    if (el.kind === GuncatUiKind.PROGRESS) {
      out['value'] = el.value;
      out['total'] = el.total;
      out['label'] = el.label;
      out['unit'] = el.unit;
    }
    if (el.kind === GuncatUiKind.METRIC || el.kind === GuncatUiKind.METRICS) {
      out['value'] = el.value;
      out['unit'] = el.unit;
      out['label'] = el.label;
      out['delta'] = el.delta;
    }
    if (el.kind === GuncatUiKind.TABLE) {
      out['headers'] = el.headers;
      out['rows'] = el.rows;
    }
    if (el.kind === GuncatUiKind.CHART) {
      out['chart'] = el.chart;
      out['labels'] = el.labels;
      out['values'] = el.values;
      out['series'] = el.series;
      out['unit'] = el.unit;
    }
    if (el.controls.length > 0) {
      out['controls'] = el.controls;
    }
    if (el.options.length > 0) {
      out['options'] = el.options;
    }
    if (el.action !== null) {
      out['action'] = GuncatUiSpecWriter.actionToJson(el.action);
    }
    if (el.action2 !== null) {
      out['action2'] = GuncatUiSpecWriter.actionToJson(el.action2);
    }
    if (el.items.length > 0) {
      let items: Record<string, Object>[] = [];
      for (let i: number = 0; i < el.items.length; i++) {
        let metric: GuncatUiElement = el.items[i];
        items.push({
          'label': metric.label, 'value': metric.value,
          'unit': metric.unit, 'delta': metric.delta
        });
      }
      out['items'] = items;
    }
    if (el.children.length > 0) {
      let children: Record<string, Object>[] = [];
      for (let i: number = 0; i < el.children.length; i++) {
        children.push(GuncatUiSpecWriter.elementToJson(el.children[i]));
      }
      out['children'] = children;
    }
    return out;
  }

  private static actionToJson(action: GuncatUiAction): Record<string, Object> {
    let out: Record<string, Object> = {};
    out['id'] = action.id;
    out['label'] = action.label;
    out['style'] = action.style;
    if (action.confirm !== '') {
      out['confirm'] = action.confirm;
    }
    return out;
  }

  // 完整界面块(带围栏), 可直接追加到消息正文末尾
  static toBlock(spec: GuncatUiSpec): string {
    return GuncatUiBlocks.OPEN + '\n' + GuncatUiSpecWriter.toJsonText(spec) +
      '\n' + GuncatUiBlocks.FENCE;
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
    '- **elements 是必填数组，且至少有 1 个元素**；单个元素也要写进数组里，不要把它当成顶层文档。',
    '> **篇幅纪律（最重要）**：界面 JSON 写太长会被模型的输出上限截断，从而整块作废。因此**默认只写 2~4 个元素**，',
    '> 最多不超过 6 个；controls 最多 3 个；table rows 不超过 8 行、chart 不超过 8 个数据点；',
    '> 每条文案 ≤60 字、title ≤20 字；能 3 个元素说清的事绝不写 6 个。要展示更多内容时分两轮给（先说结论，再按需展开）。',
    '- 界面块之外可以写文字，但必须简短；**禁止在正文里重复界面已经表达的数据**。',
    '- 数值必须真实可核对：来自计算或工具结果的数值直接写；给不出数据的字段不要编造，改用 note 说明。',
    '- 图表 values 与 labels 数量必须一致；bar/line 的 values 默认 1 条序列与 labels 一一对应（多序列才用 series）。',
    '- 颜色/样式由系统决定，不要输出任何颜色、CSS、坐标、像素值。',
    '- 只使用清单内的 kind / type / chart / tone 取值；未知取值会被系统丢弃，界面将缺块。',
    '- 移动端竖屏：一屏能读完优先；元素顺序按「结论 → 数据 → 操作」排列。'
  ].join('\n');

  // 反例(模型最常见的错误——这些都会导致界面渲染不出来)
  static readonly ANTI_PATTERNS: string = [
    '# 交互界面常见错误（自查，写错就会渲染失败）',
    '- **只写了一个元素却没放进 elements**：`{"kind":"card","text":"…"}` 是错的，必须写成 `{"elements":[{"kind":"card","text":"…"}]}`。',
    '- **漏写 elements**：只有 title/controls 而没有 elements 时界面会是空的。至少要有 1 个元素。',
    '- 用 markdown 表格代替 table/chart：数据类内容一律用 table/chart/metrics，markdown 只用于叙述。',
    '- 只输出界面不输出行动入口：阐述完结论后若用户可能有下一步诉求，附 form 或 choice。',
    '- **JSON 语法违规**：中文全角引号 “ ”、单引号、`//` 或 `/* */` 注释、尾随逗号、把数字写成带单位的字符串（应写 4.8 + "unit": "%"）。',
    '- **在 JSON 字符串里写 Markdown 代码围栏**（三个反引号）：会提前截断界面块。需要代码内容时用普通文本描述，不要放围栏。',
    '- 编造元素或控件类型名（如 "kv"/"list"/"Card"）：只使用清单内的取值，否则该元素会被丢弃。'
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
