// 交互模式 (Intelligent UI) 运行时 —— 绑定状态与动作执行。
//
// 三层状态:
//   1. 界面内绑定($变量): 用户拖动滑块 / 输入文字 / 勾选选项时**立刻**写回并重渲染,
//      不发请求、不等模型 —— 这是"能上手操作"的关键;
//   2. 消息级持久化: 绑定值随消息保存(以 `]]>guncat-ui:state` 尾标记的形式追加在正文末尾),
//      因此划过屏幕、切换会话、重启应用后, 用户填过的值仍在;
//   3. 会话级回传: 模型下一轮需要知道用户当前的选择时, 由 describeStateForModel()
//      把尾标记翻译成一句人话注入请求(对齐参考项目把 ]] >openui:context 改写成句子的做法)。
//
// 动作语义(对齐参考项目):
//   @ToAssistant("文本")  → 把文本作为一条用户消息发给模型(触发新一轮)
//   @OpenUrl("https://…") → 打开链接
//   @Set($x, 值)          → 写绑定值(仅本地重渲染)
//   @Reset($x, …)         → 绑定值恢复为该 $变量声明的默认值
//   不带 action 的 Button   → 等价于 @ToAssistant(label)
import {
  UiElement,
  UiActionPlan,
  UiActionStep,
  UiNode,
  UiProgram,
  GuncatUiMaterializer,
  UiLimits
} from './GuncatUiLang';

// 绑定值集合
export class GuncatUiState {
  values: Record<string, Object> = {};
  // 变量声明的默认值(供 @Reset 使用)
  defaults: Record<string, Object> = {};

  static of(program: UiProgram | null, saved: Record<string, Object> | null): GuncatUiState {
    let st: GuncatUiState = new GuncatUiState();
    if (program !== null) {
      let names: string[] = Object.keys(program.state);
      for (let i: number = 0; i < names.length; i++) {
        let value: Object = program.state[names[i]];
        st.defaults[names[i]] = value;
        st.values[names[i]] = value;
      }
    }
    if (saved !== null) {
      let keys: string[] = Object.keys(saved);
      for (let i: number = 0; i < keys.length && i < UiLimits.MAX_BINDINGS; i++) {
        st.values[keys[i]] = saved[keys[i]];
      }
    }
    return st;
  }

  get(name: string): Object | null {
    let v: Object | undefined = this.values[name];
    return v === undefined ? null : v;
  }

  str(name: string, fallback: string): string {
    let v: Object | null = this.get(name);
    if (v === null) {
      return fallback;
    }
    return GuncatUiMaterializer.toStr(v);
  }

  num(name: string, fallback: number): number {
    let v: Object | null = this.get(name);
    if (v === null) {
      return fallback;
    }
    return GuncatUiMaterializer.toNum(v);
  }

  bool(name: string, fallback: boolean): boolean {
    let v: Object | null = this.get(name);
    if (v === null) {
      return fallback;
    }
    return GuncatUiMaterializer.truthy(v);
  }

  set(name: string, value: Object): void {
    if (name === '') {
      return;
    }
    this.values[name] = value;
  }

  reset(name: string): void {
    let d: Object | undefined = this.defaults[name];
    this.values[name] = d === undefined ? ('' as Object) : d;
  }

  // 只保留前 MAX_BINDINGS 个键并按变量名排序(保证尾标记稳定, 避免每帧都在变)
  compact(program: UiProgram | null): void {
    let names: string[] = Object.keys(this.values);
    names.sort();
    let keep: Record<string, Object> = {};
    let limit: number = names.length < UiLimits.MAX_BINDINGS ? names.length : UiLimits.MAX_BINDINGS;
    for (let i: number = 0; i < limit; i++) {
      keep[names[i]] = this.values[names[i]];
    }
    this.values = keep;
  }

  private static indexOf(list: string[], value: string): number {
    for (let i: number = 0; i < list.length; i++) {
      if (list[i] === value) {
        return i;
      }
    }
    return -1;
  }

  toJson(): string {
    let names: string[] = Object.keys(this.values);
    names.sort();
    let parts: string[] = [];
    for (let i: number = 0; i < names.length; i++) {
      let name: string = names[i];
      let value: Object = this.values[name];
      parts.push('"' + GuncatUiState.escapeKey(name) + '":' + GuncatUiState.jsonValue(value));
    }
    return '{' + parts.join(',') + '}';
  }

  private static escapeKey(name: string): string {
    return name.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  }

  private static jsonValue(value: Object): string {
    if (value === null || value === undefined) {
      return 'null';
    }
    if (typeof value === 'number') {
      let n: number = value as number;
      return isFinite(n) ? String(n) : '0';
    }
    if (typeof value === 'boolean') {
      return (value as boolean) ? 'true' : 'false';
    }
    if (value instanceof Array) {
      let arr: Object[] = value as Object[];
      let parts: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        parts.push(GuncatUiState.jsonValue(arr[i]));
      }
      return '[' + parts.join(',') + ']';
    }
    if (typeof value === 'object') {
      let rec: Record<string, Object> = value as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      let parts: string[] = [];
      for (let i: number = 0; i < keys.length; i++) {
        parts.push('"' + GuncatUiState.escapeKey(keys[i]) + '":' + GuncatUiState.jsonValue(rec[keys[i]]));
      }
      return '{' + parts.join(',') + '}';
    }
    return JSON.stringify(GuncatUiMaterializer.toStr(value));
  }

  static fromJson(json: string): Record<string, Object> {
    let out: Record<string, Object> = {};
    if (json === null || json === undefined || json.trim() === '') {
      return out;
    }
    try {
      let parsed: Object = JSON.parse(json) as Object;
      if (parsed !== null && typeof parsed === 'object' && !(parsed instanceof Array)) {
        let rec: Record<string, Object> = parsed as Record<string, Object>;
        let keys: string[] = Object.keys(rec);
        for (let i: number = 0; i < keys.length && i < UiLimits.MAX_BINDINGS; i++) {
          out[keys[i]] = rec[keys[i]];
        }
      }
    } catch (e) {
      // 非法 JSON: 视为没有状态
    }
    return out;
  }
}

// 交互事件(渲染器 → 视图模型)
export class GuncatUiEvent {
  // action = 需要回传模型(触发新一轮); state = 仅本地状态变化
  kind: string = 'action';
  // 回传给模型的用户消息正文
  message: string = '';
  // 界面标题(消息前缀用)
  title: string = '';
  // 最新绑定值 JSON(用于随消息持久化)
  stateJson: string = '';
}

// 状态尾标记: 追加在消息正文末尾, 与模型可见的正文分离
export class GuncatUiTrailer {
  static readonly MARK: string = ']]>guncat-ui:state';

  // 拆出正文与状态 JSON
  static split(content: string): GuncatUiSplit {
    let out: GuncatUiSplit = new GuncatUiSplit();
    if (content === null || content === undefined) {
      return out;
    }
    let at: number = content.indexOf(GuncatUiTrailer.MARK);
    if (at < 0) {
      out.body = content;
      return out;
    }
    out.body = content.substring(0, at);
    let rest: string = content.substring(at + GuncatUiTrailer.MARK.length).trim();
    let end: number = rest.indexOf('\n');
    let json: string = end < 0 ? rest : rest.substring(0, end);
    if (end >= 0) {
      // 尾标记之后的其它内容(理论上没有)并回正文, 避免丢字
      let tail: string = rest.substring(end + 1);
      if (tail.trim() !== '') {
        out.body = out.body + '\n' + tail;
      }
    }
    out.stateJson = json.trim();
    out.hasState = out.stateJson !== '';
    return out;
  }

  static append(content: string, stateJson: string): string {
    let split: GuncatUiSplit = GuncatUiTrailer.split(content);
    if (stateJson === '' || stateJson === '{}') {
      return split.body;
    }
    return split.body + '\n' + GuncatUiTrailer.MARK + '\n' + stateJson;
  }
}

export class GuncatUiSplit {
  body: string = '';
  stateJson: string = '';
  hasState: boolean = false;
}

// 动作执行 + 回传文案
export class GuncatUiRuntime {
  // 执行动作步骤: 返回是否发生了绑定值变化
  static applySteps(steps: UiActionStep[], state: GuncatUiState): boolean {
    let changed: boolean = false;
    for (let i: number = 0; i < steps.length; i++) {
      let step: UiActionStep = steps[i];
      if (step.kind === 'set') {
        let value: Object = step.value === null ? ('' as Object) : step.value;
        let before: Object | null = state.get(step.target);
        state.set(step.target, value);
        if (GuncatUiMaterializer.toStr(before) !== GuncatUiMaterializer.toStr(value)) {
          changed = true;
        }
      } else if (step.kind === 'reset') {
        state.reset(step.target);
        changed = true;
      }
    }
    return changed;
  }

  // 步骤里是否有回传模型的动作
  static collectMessages(steps: UiActionStep[]): string[] {
    let out: string[] = [];
    for (let i: number = 0; i < steps.length; i++) {
      let step: UiActionStep = steps[i];
      if (step.kind === 'toAssistant' && step.text.trim() !== '') {
        out.push(step.text.trim());
      }
    }
    return out;
  }

  static urlOf(steps: UiActionStep[]): string {
    for (let i: number = 0; i < steps.length; i++) {
      if (steps[i].kind === 'openUrl') {
        return steps[i].text.trim();
      }
    }
    return '';
  }

  // 按钮点击 → 回传文案。
  // 有 @ToAssistant 时用它; 否则退化为按钮文案(参考实现: 无 action 的按钮直接把 label 发给助手)。
  static buttonMessage(el: UiElement): string {
    let steps: UiActionStep[] = UiNode.actionSteps(el, 'action');
    let messages: string[] = GuncatUiRuntime.collectMessages(steps);
    if (messages.length > 0) {
      return messages.join('\n');
    }
    if (steps.length > 0) {
      // 只有本地动作(@Set/@Reset)时不需要回传模型
      return '';
    }
    let label: string = UiNode.str(el, 'label', '');
    if (label === '') {
      label = UiNode.str(el, 'name', '');
    }
    return label;
  }

  // 收集表单字段的当前值, 组装成回传文案
  // 表单字段: FormControl(label, Input/Select/Slider/...) —— 控件名取自控件的 name 参数
  static formMessage(form: UiElement, state: GuncatUiState): string {
    let lines: string[] = [];
    let fields: UiElement[] = UiNode.elementList(form, 'fields');
    for (let i: number = 0; i < fields.length; i++) {
      let control: UiElement = fields[i];
      if (control.type !== 'FormControl') {
        continue;
      }
      let label: string = UiNode.str(control, 'label', '');
      let input: UiElement | null = UiNode.element(control, 'input');
      if (input === null) {
        continue;
      }
      let name: string = UiNode.str(input, 'name', '');
      let text: string = GuncatUiRuntime.controlText(input, state);
      lines.push('- ' + (label !== '' ? label : name) + ' = ' + text);
    }
    return lines.join('\n');
  }

  // 控件的状态键: 优先用双向绑定的 $变量, 没有绑定时退回控件自身的 name
  static stateKeyOf(input: UiElement): string {
    let bindName: string = UiNode.bindOf(input, 'value');
    if (bindName !== '') {
      return bindName;
    }
    return UiNode.str(input, 'name', '');
  }

  // 单个控件当前值的可读文本
  static controlText(input: UiElement, state: GuncatUiState): string {
    let key: string = GuncatUiRuntime.stateKeyOf(input);
    let type: string = input.type;
    if (type === 'Slider') {
      let value: number = state.num(key, GuncatUiRuntime.sliderDefault(input));
      return GuncatUiMaterializer.numText(value);
    }
    if (type === 'SwitchGroup') {
      let parts: string[] = [];
      let items: UiElement[] = UiNode.elementList(input, 'items');
      for (let i: number = 0; i < items.length; i++) {
        let itemName: string = UiNode.str(items[i], 'name', '');
        let label: string = UiNode.str(items[i], 'label', itemName);
        let on: boolean = GuncatUiRuntime.switchValue(state, key, itemName, items[i]);
        parts.push(label + '=' + (on ? '开' : '关'));
      }
      return parts.join(', ');
    }
    if (type === 'CheckBoxGroup') {
      let selected: string[] = [];
      let items2: UiElement[] = UiNode.elementList(input, 'items');
      let current: Object | null = state.get(key);
      for (let i: number = 0; i < items2.length; i++) {
        let itemName: string = UiNode.str(items2[i], 'name', '');
        let label: string = UiNode.str(items2[i], 'label', itemName);
        if (GuncatUiRuntime.boolMapValue(current, itemName)) {
          selected.push(label);
        }
      }
      return selected.length === 0 ? '(未选)' : selected.join(', ');
    }
    if (type === 'Chips' || type === 'OptionCards') {
      let current2: Object | null = state.get(key);
      if (current2 === null) {
        current2 = UiNode.raw(input, 'defaultValue');
      }
      let text: string = GuncatUiRuntime.multiText(current2);
      return text === '' ? '(未选)' : text;
    }
    if (type === 'RadioGroup' || type === 'Select') {
      let current3: Object | null = state.get(key);
      if (current3 === null || GuncatUiMaterializer.toStr(current3) === '') {
        current3 = UiNode.raw(input, 'defaultValue');
      }
      let text2: string = current3 === null ? '' : GuncatUiMaterializer.toStr(current3);
      return text2 === '' ? '(未选)' : text2;
    }
    let text3: string = state.str(key, '');
    return text3 === '' ? '(空)' : text3;
  }

  private static multiText(value: Object | null): string {
    if (value === null) {
      return '';
    }
    if (value instanceof Array) {
      let arr: Object[] = value as Object[];
      let parts: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        parts.push(GuncatUiMaterializer.toStr(arr[i]));
      }
      return parts.join(', ');
    }
    if (typeof value === 'object') {
      let rec: Record<string, Object> = value as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      let parts: string[] = [];
      for (let i: number = 0; i < keys.length; i++) {
        if (GuncatUiMaterializer.truthy(rec[keys[i]])) {
          parts.push(keys[i]);
        }
      }
      return parts.join(', ');
    }
    return GuncatUiMaterializer.toStr(value);
  }

  static sliderDefault(input: UiElement): number {
    let defaults: number[] = UiNode.numList(input, 'defaultValue');
    if (defaults.length > 0) {
      return defaults[0];
    }
    return UiNode.num(input, 'min', 0);
  }

  static boolMapValue(map: Object | null, key: string): boolean {
    if (map === null) {
      return false;
    }
    if (typeof map === 'object' && !(map instanceof Array)) {
      let rec: Record<string, Object> = map as Record<string, Object>;
      let v: Object | undefined = rec[key];
      return v === undefined ? false : GuncatUiMaterializer.truthy(v);
    }
    if (map instanceof Array) {
      let arr: Object[] = map as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        if (GuncatUiMaterializer.toStr(arr[i]) === key) {
          return true;
        }
      }
    }
    return false;
  }

  static switchValue(state: GuncatUiState, group: string, itemName: string, item: UiElement): boolean {
    let current: Object | null = state.get(group);
    if (current !== null) {
      if (typeof current === 'object' && !(current instanceof Array)) {
        let rec: Record<string, Object> = current as Record<string, Object>;
        let v: Object | undefined = rec[itemName];
        if (v !== undefined) {
          return GuncatUiMaterializer.truthy(v);
        }
      }
    }
    return UiNode.bool(item, 'defaultChecked', false);
  }

  // 写回对象型绑定(多选/开关组)
  static setMapValue(state: GuncatUiState, group: string, key: string, on: boolean): void {
    let current: Object | null = state.get(group);
    let next: Record<string, Object> = {};
    if (current !== null && typeof current === 'object' && !(current instanceof Array)) {
      let rec: Record<string, Object> = current as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      for (let i: number = 0; i < keys.length; i++) {
        next[keys[i]] = rec[keys[i]];
      }
    }
    next[key] = on as Object;
    state.set(group, next as Object);
  }

  // 表单回传文案(带界面标题的行首)
  static interactionText(title: string, body: string): string {
    let head: string = '【交互界面回传】';
    if (title !== '') {
      head = head + title;
    }
    if (body === '') {
      return head;
    }
    return head + '\n' + body;
  }

  // ===== 把状态翻译成模型能读的句子(注入下一轮请求) =====
  static describeStateForModel(program: UiProgram | null, stateJson: string): string {
    if (stateJson === '' || stateJson === '{}') {
      return '';
    }
    let values: Record<string, Object> = GuncatUiState.fromJson(stateJson);
    let keys: string[] = Object.keys(values);
    if (keys.length === 0) {
      return '';
    }
    let labels: Record<string, string> = GuncatUiRuntime.bindingLabels(program);
    let parts: string[] = [];
    for (let i: number = 0; i < keys.length; i++) {
      let key: string = keys[i];
      let value: Object = values[key];
      let label: string | undefined = labels[key];
      let name: string = label === undefined ? key : label;
      parts.push(name + '=' + GuncatUiRuntime.humanValue(value));
    }
    return '(用户在当前交互界面上的设置: ' + parts.join('; ') + '。)';
  }

  // 变量名 → 界面上用户看到的标签(如 $amount → "金额")
  static bindingLabels(program: UiProgram | null): Record<string, string> {
    let out: Record<string, string> = {};
    if (program === null || program.root === null) {
      return out;
    }
    GuncatUiRuntime.collectLabels(program.root, out, 0);
    return out;
  }

  private static collectLabels(el: UiElement, out: Record<string, string>, depth: number): void {
    if (depth > UiLimits.MAX_DEPTH) {
      return;
    }
    // FormControl 的标签要落到它包着的控件上(用户看到的是 FormControl 的 label)
    if (el.type === 'FormControl') {
      let label: string = UiNode.str(el, 'label', '');
      let input: UiElement | null = UiNode.element(el, 'input');
      if (label !== '' && input !== null) {
        let inputBinds: string[] = Object.keys(input.binds);
        for (let i: number = 0; i < inputBinds.length; i++) {
          let varName: string = input.binds[inputBinds[i]];
          if (out[varName] === undefined) {
            out[varName] = label;
          }
        }
      }
    }
    let bindNames: string[] = Object.keys(el.binds);
    for (let i: number = 0; i < bindNames.length; i++) {
      let prop: string = bindNames[i];
      let varName2: string = el.binds[prop];
      let label2: string = '';
      if (el.type === 'Slider') {
        label2 = UiNode.str(el, 'label', '');
      }
      if (label2 === '') {
        label2 = UiNode.str(el, 'name', '');
      }
      if (label2 !== '' && out[varName2] === undefined) {
        out[varName2] = label2;
      }
    }
    let names: string[] = Object.keys(el.props);
    for (let i: number = 0; i < names.length; i++) {
      let v: Object | undefined = el.props[names[i]];
      if (v === undefined || v === null) {
        continue;
      }
      if (v instanceof UiElement) {
        GuncatUiRuntime.collectLabels(v as UiElement, out, depth + 1);
      } else if (v instanceof Array) {
        let arr: Object[] = v as Object[];
        for (let j: number = 0; j < arr.length; j++) {
          if (arr[j] instanceof UiElement) {
            GuncatUiRuntime.collectLabels(arr[j] as UiElement, out, depth + 1);
          }
        }
      }
    }
  }

  private static humanValue(value: Object): string {
    if (value === null || value === undefined) {
      return '空';
    }
    if (typeof value === 'boolean') {
      return (value as boolean) ? '开' : '关';
    }
    if (value instanceof Array) {
      let arr: Object[] = value as Object[];
      if (arr.length === 0) {
        return '未选';
      }
      let parts: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        parts.push(GuncatUiMaterializer.toStr(arr[i]));
      }
      return parts.join('、');
    }
    if (typeof value === 'object') {
      let rec: Record<string, Object> = value as Record<string, Object>;
      let keys: string[] = Object.keys(rec);
      let parts: string[] = [];
      for (let i: number = 0; i < keys.length; i++) {
        parts.push(keys[i] + '=' + ((GuncatUiMaterializer.truthy(rec[keys[i]])) ? '开' : '关'));
      }
      return parts.length === 0 ? '空' : parts.join('、');
    }
    let text: string = GuncatUiMaterializer.toStr(value);
    return text === '' ? '空' : text;
  }
}
