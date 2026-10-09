// 交互模式 (Intelligent UI) 消息体切分:
// 把一条 assistant 消息切成「普通 Markdown 片段 + guncat-ui 界面程序片段」。
//
// 支持两种交付形态(都对齐参考项目):
//   1. 非围栏(推荐, 与参考项目一致): 整条消息就是一份界面程序, 模型可在程序前写 1~2 句引导文字;
//   2. 围栏: ```guncat-ui (或 ```openui-lang) 包裹程序, 围栏外是正文;
// 其它语言的围栏(```json/```python …)一律按普通 Markdown 代码块渲染, 不当作界面。
//
// 关键约定:
//   - **永远至少产出一个文本片段**(没有界面程序时就是一个纯文本片段)。历史事故: 调用方
//     自己在外面判断"消息里有没有 guncat-ui 块"并在没有时跳过整段渲染, 导致普通回答一个字都不显示。
//   - 未写完的程序(流式中)也照样渲染, 只是禁用交互 —— guncat-ui lang 是按行语句,
//     已经写完的语句全部有效, 因此"截断"只会少画最后几个元素, 不会整块作废。
import {
  GuncatUiLang,
  UiProgram,
  UiElement,
  UiNode,
  UiLimits,
  GuncatUiFences,
  UiFragment
} from './GuncatUiLang.ts';
import { GuncatUiLibrary } from './GuncatUiLibrary.ts';
import { GuncatUiTrailer, GuncatUiSplit } from './GuncatUiRuntime.ts';

export class GuncatUiSegType {
  static readonly TEXT: string = 'text';
  static readonly UI: string = 'ui';
}

export class GuncatUiSeg {
  type: string = GuncatUiSegType.TEXT;
  text: string = '';
  // 文本片段的渲染 key: 内容变化时递增, 父组件据此强制重建 RichTextView。
  // 真机事故: 卡片后面的正文只显示一两个字, 刷新后才完整 —— 渲染库复用了同一个
  // RichTextView 实例而没有重新排版尾部文本, 所以尾部文本必须有独立且可变的 key。
  renderKey: number = 0;
  // UI 片段: 程序是否已写完(流式中为 false)
  complete: boolean = true;
  // 未写完但本轮产出已结束(输出被截断/中断): 按"未完成"静态渲染, 不再显示"生成中"
  truncated: boolean = false;
  // 解析出的界面程序
  program: UiProgram | null = null;
  // 块内原文(诊断 / "查看原始输出"用)
  raw: string = '';
  // 界面标题(从首个 CardHeader 或 InlineHeader 取, 用于回传消息前缀)
  title: string = '';
  // 该消息的绑定值 JSON(从正文尾标记里取)
  stateJson: string = '';
  // 是否为围栏承载
  fenced: boolean = false;
  // 程序是否有可渲染内容
  empty: boolean = false;
}

export class GuncatUiParts {
  segments: GuncatUiSeg[] = [];
  // 是否至少有一个界面程序片段(可解析)
  hasUi: boolean = false;
  // 是否至少有一个界面片段(含解析失败的)
  hasUiSeg: boolean = false;
  // 消息携带的绑定值 JSON
  stateJson: string = '';
  // 去除界面程序后的纯文本(用于复制/导出/标题生成)
  textOnly: string = '';

  static build(content: string, finalized: boolean = false): GuncatUiParts {
    let parts: GuncatUiParts = new GuncatUiParts();
    if (content === null || content === undefined || content === '') {
      return parts;
    }
    GuncatUiLibrary.init();
    // 1) 拆掉状态尾标记: 它不参与渲染, 但要交给界面组件恢复绑定值
    let split: GuncatUiSplit = GuncatUiTrailer.split(content);
    parts.stateJson = split.stateJson;
    let body: string = split.body;
    if (body === '') {
      return parts;
    }
    // 2) 按围栏切成片段; 正文累积到 pending, 遇到界面片段先冲刷成文本片段
    let fragments: UiFragment[] = GuncatUiFences.split(body);
    let pending: string = '';
    for (let i: number = 0; i < fragments.length; i++) {
      let f: UiFragment = fragments[i];
      if (f.fence) {
        if (GuncatUiFences.isUiFence(f.info)) {
          pending = GuncatUiParts.flushText(parts, pending);
          GuncatUiParts.appendProgram(parts, f.text, f.complete, finalized, true);
        } else {
          pending = pending + GuncatUiParts.renderCodeFence(f);
        }
        continue;
      }
      // 非围栏正文: 可能整段就是一份界面程序(参考项目的默认形态)
      if (GuncatUiParts.looksLikeProgram(f.text)) {
        let cut: number = GuncatUiParts.firstStatementLine(f.text);
        if (cut > 0) {
          pending = pending + f.text.substring(0, cut);
        }
        pending = GuncatUiParts.flushText(parts, pending);
        GuncatUiParts.appendProgram(parts, cut > 0 ? f.text.substring(cut) : f.text,
          true, finalized, false);
      } else {
        pending = pending + f.text;
      }
    }
    GuncatUiParts.flushText(parts, pending);

    if (parts.segments.length === 0) {
      // 极端兜底: 什么都没有时也产出一个可渲染的文本片段
      let seg: GuncatUiSeg = new GuncatUiSeg();
      seg.text = body;
      parts.segments.push(seg);
    }
    if (parts.hasUiSeg) {
      // 把状态回填给所有界面片段
      for (let i: number = 0; i < parts.segments.length; i++) {
        let seg2: GuncatUiSeg = parts.segments[i];
        if (seg2.type === GuncatUiSegType.UI) {
          seg2.stateJson = parts.stateJson;
        }
      }
    }
    let joined: string = '';
    for (let i: number = 0; i < parts.segments.length; i++) {
      if (parts.segments[i].type === GuncatUiSegType.TEXT) {
        joined = joined + parts.segments[i].text;
      }
    }
    parts.textOnly = joined;
    return parts;
  }

  // 把累积的正文落成一个文本片段(纯空白则丢弃)
  private static flushText(parts: GuncatUiParts, pending: string): string {
    if (pending.trim() === '') {
      return '';
    }
    let seg: GuncatUiSeg = new GuncatUiSeg();
    seg.type = GuncatUiSegType.TEXT;
    seg.text = pending;
    parts.segments.push(seg);
    return '';
  }

  // 一段文本是否像界面程序: 需要至少 2 行语句, 或 1 行且含 root
  private static looksLikeProgram(text: string): boolean {
    let lines: string[] = text.split('\n');
    let hits: number = 0;
    let rootHit: boolean = false;
    for (let i: number = 0; i < lines.length && i < 120; i++) {
      let line: string = lines[i].trim();
      if (line === '' || line.charAt(0) === '#') {
        continue;
      }
      if (GuncatUiParts.statementLine(line)) {
        hits++;
        if (line.indexOf('root') === 0) {
          rootHit = true;
        }
        if (hits >= 2) {
          return true;
        }
      }
    }
    return hits === 1 && rootHit;
  }

  // 第一个语句行的起始偏移
  private static firstStatementLine(text: string): number {
    let lines: string[] = text.split('\n');
    let offset: number = 0;
    for (let i: number = 0; i < lines.length; i++) {
      let line: string = lines[i];
      let trimmed: string = line.trim();
      if (trimmed !== '' && GuncatUiParts.statementLine(trimmed)) {
        return offset;
      }
      offset += line.length + 1;
    }
    return -1;
  }

  // `name = Component(` 形态; 组件名必须是库内已知组件, 避免把散文里的 `x = Y(` 误当程序
  private static statementLine(line: string): boolean {
    let eq: number = line.indexOf('=');
    if (eq <= 0) {
      return false;
    }
    let lhs: string = line.substring(0, eq).trim();
    if (lhs === '' || lhs.indexOf(' ') >= 0 || lhs.indexOf('(') >= 0 || lhs.indexOf(')') >= 0) {
      return false;
    }
    let first: string = lhs.charAt(0);
    let lhsOk: boolean = (first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') ||
      first === '_' || first === '$';
    if (!lhsOk) {
      return false;
    }
    for (let i: number = 0; i < lhs.length; i++) {
      let c: string = lhs.charAt(i);
      let ok: boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c === '_' || c === '$';
      if (!ok) {
        return false;
      }
    }
    let rhs: string = line.substring(eq + 1).trim();
    if (rhs === '') {
      return false;
    }
    let paren: number = rhs.indexOf('(');
    if (paren <= 0) {
      // $var = "7d" / $var = 3 这类绑定声明
      return first === '$';
    }
    let name: string = rhs.substring(0, paren);
    if (name === '') {
      return false;
    }
    let head: string = name.charAt(0);
    if (!(head >= 'A' && head <= 'Z')) {
      return false;
    }
    for (let i: number = 0; i < name.length; i++) {
      let c: string = name.charAt(i);
      let ok: boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c === '_';
      if (!ok) {
        return false;
      }
    }
    return GuncatUiLibrary.isKnown(name);
  }

  private static appendProgram(parts: GuncatUiParts, body: string, complete: boolean,
    finalized: boolean, fenced: boolean): void {
    let program: UiProgram = GuncatUiLang.parse(body);
    let seg: GuncatUiSeg = new GuncatUiSeg();
    seg.type = GuncatUiSegType.UI;
    seg.complete = complete && !program.incomplete;
    seg.truncated = !seg.complete && finalized;
    seg.program = program;
    seg.raw = body;
    seg.fenced = fenced;
    seg.title = GuncatUiParts.titleOf(program);
    seg.empty = program.root === null;
    parts.segments.push(seg);
    parts.hasUiSeg = true;
    if (program.root !== null) {
      parts.hasUi = true;
    }
  }

  // 还原非界面语言的围栏, 交回 Markdown 渲染(代码块)
  private static renderCodeFence(f: UiFragment): string {
    let body: string = '```' + f.info + '\n' + f.text;
    if (!f.complete) {
      return body;
    }
    return body + '```';
  }

  // 从程序里取一个标题: 优先 root 的第一个 CardHeader / InlineHeader
  private static titleOf(program: UiProgram): string {
    if (program.root === null) {
      return '';
    }
    let kids: UiElement[] = UiNode.elementList(program.root, 'children');
    for (let i: number = 0; i < kids.length; i++) {
      let child: UiElement = kids[i];
      if (child.type === 'CardHeader') {
        let title: string = UiNode.str(child, 'title', '');
        if (title !== '') {
          return title;
        }
      }
      if (child.type === 'InlineHeader') {
        let heading: string = UiNode.str(child, 'heading', '');
        if (heading !== '') {
          return heading;
        }
      }
    }
    return '';
  }

  // 该消息里是否含有界面程序(用于决定是否启用可交互渲染路径)
  static hasProgram(content: string): boolean {
    if (content === null || content === undefined || content === '') {
      return false;
    }
    let split: GuncatUiSplit = GuncatUiTrailer.split(content);
    if (GuncatUiFences.hasUiFence(split.body)) {
      return true;
    }
    return GuncatUiLang.looksLikeProgram(split.body);
  }

  // 消息里所有界面程序拼起来的纯文本(用于复制/导出/标题生成)
  static textOnly(content: string): string {
    return GuncatUiParts.build(content, true).textOnly;
  }

  // 可读摘要: 正文文本 + 界面里用户能看到的关键文字(标题/段落/指标/表格)。
  // 用途: 复制为纯文本、导出 Word、生成会话标题 —— 这三处都不该出现程序源码。
  static plainSummary(content: string): string {
    let parts: GuncatUiParts = GuncatUiParts.build(content, true);
    let blocks: string[] = [];
    for (let i: number = 0; i < parts.segments.length; i++) {
      let seg: GuncatUiSeg = parts.segments[i];
      if (seg.type === GuncatUiSegType.TEXT) {
        let t: string = seg.text.trim();
        if (t !== '') {
          blocks.push(t);
        }
        continue;
      }
      if (seg.program !== null && seg.program.root !== null) {
        let lines: string[] = [];
        GuncatUiParts.collectPlain(seg.program.root, lines, 0);
        if (lines.length > 0) {
          blocks.push(lines.join('\n'));
        }
      }
    }
    return blocks.join('\n\n');
  }

  private static collectPlain(el: UiElement, out: string[], depth: number): void {
    if (depth > UiLimits.MAX_DEPTH) {
      return;
    }
    let type: string = el.type;
    // 标题类: 前面空一行, 便于阅读
    if (type === 'CardHeader') {
      let title: string = UiNode.str(el, 'title', '');
      if (title !== '') {
        out.push('');
        out.push('## ' + title);
      }
      let subtitle: string = UiNode.str(el, 'subtitle', '');
      if (subtitle !== '') {
        out.push(subtitle);
      }
      return;
    }
    if (type === 'InlineHeader') {
      let heading: string = UiNode.str(el, 'heading', '');
      if (heading !== '') {
        out.push('');
        out.push('### ' + heading);
      }
      let desc: string = UiNode.str(el, 'description', '');
      if (desc !== '') {
        out.push(desc);
      }
      return;
    }
    if (type === 'Table') {
      GuncatUiParts.appendTable(el, out);
      return;
    }
    if (type === 'CodeBlock') {
      out.push('```' + UiNode.str(el, 'language', '') );
      out.push(UiNode.str(el, 'codeString', ''));
      out.push('```');
      return;
    }
    // 普通文本类字段
    let fields: string[] = ['text', 'heading', 'title', 'value', 'label', 'description',
      'body', 'details', 'trigger', 'textMarkdown'];
    for (let i: number = 0; i < fields.length; i++) {
      let v: string = UiNode.str(el, fields[i], '');
      if (v !== '') {
        out.push(v);
      }
    }
    // 递归子元素
    let names: string[] = Object.keys(el.props);
    for (let i: number = 0; i < names.length; i++) {
      let v: Object | undefined = el.props[names[i]];
      if (v === undefined || v === null) {
        continue;
      }
      if (v instanceof UiElement) {
        GuncatUiParts.collectPlain(v as UiElement, out, depth + 1);
      } else if (v instanceof Array) {
        let arr: Object[] = v as Object[];
        for (let j: number = 0; j < arr.length; j++) {
          if (arr[j] instanceof UiElement) {
            GuncatUiParts.collectPlain(arr[j] as UiElement, out, depth + 1);
          }
        }
      }
    }
  }

  private static appendTable(el: UiElement, out: string[]): void {
    let cols: UiElement[] = UiNode.elementList(el, 'columns');
    if (cols.length === 0) {
      return;
    }
    let data: string[][] = [];
    let maxLen: number = 0;
    for (let i: number = 0; i < cols.length; i++) {
      let raw: Object | null = UiNode.raw(cols[i], 'data');
      let values: string[] = [];
      if (raw instanceof Array) {
        let arr: Object[] = raw as Object[];
        for (let j: number = 0; j < arr.length && j < 40; j++) {
          values.push(arr[j] === null ? '' : String(arr[j]));
        }
      } else if (raw !== null) {
        values.push(String(raw));
      }
      data.push(values);
      if (values.length > maxLen) {
        maxLen = values.length;
      }
    }
    let head: string[] = [];
    for (let i: number = 0; i < cols.length; i++) {
      head.push(UiNode.str(cols[i], 'label', ''));
    }
    out.push('');
    out.push('| ' + head.join(' | ') + ' |');
    let sep: string[] = [];
    for (let i: number = 0; i < cols.length; i++) {
      sep.push('---');
    }
    out.push('| ' + sep.join(' | ') + ' |');
    for (let r: number = 0; r < maxLen; r++) {
      let row: string[] = [];
      for (let c: number = 0; c < cols.length; c++) {
        row.push(r < data[c].length ? data[c][r] : '');
      }
      out.push('| ' + row.join(' | ') + ' |');
    }
  }

  // 界面程序是否残缺到需要重做(没有任何根节点)
  static needsRepair(content: string): boolean {
    if (content === null || content === undefined || content === '') {
      return false;
    }
    let split: GuncatUiSplit = GuncatUiTrailer.split(content);
    if (GuncatUiFences.hasUiFence(split.body) || GuncatUiLang.looksLikeProgram(split.body)) {
      let parts: GuncatUiParts = GuncatUiParts.build(content, true);
      return !parts.hasUi;
    }
    return false;
  }

  // 最后一个未闭合界面围栏的正文(流式占位判断)
  static lastOpenBody(content: string): string {
    let split: GuncatUiSplit = GuncatUiTrailer.split(content);
    return GuncatUiFences.lastOpenBody(split.body);
  }
}
