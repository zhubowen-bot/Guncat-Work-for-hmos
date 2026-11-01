import { XmlUtil } from './XmlUtil';

// LaTeX → OMML (Office Math Markup Language) 转换器
// 支持: 分式/上下标/根式/求和积分(nary)/分隔符尺寸(\left\right)/矩阵环境/希腊字母/常用符号/\text 等,
// 让导出的 Word 文档中的公式成为真正的 Word 公式(可编辑, 不乱码)。
// 无法识别的命令按原样输出为普通文本, 保证不丢失内容。

// \left(...\right) 分隔符配对标记
class DelimMarker {
  start: number = 0; // 在当前 parts 数组中的起始下标
  beg: string = '';  // 起始分隔符字符, '.' 表示不可见
}

// 常量: 命令 -> Unicode 符号
class LatexSymbols {
  static readonly MAP: Map<string, string> = new Map<string, string>();
  static readonly GREEK: Map<string, string> = new Map<string, string>();
  static readonly FUNCTIONS: string[] = ['sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'log', 'ln', 'lg', 'exp', 'max', 'min',
    'sup', 'inf', 'arg', 'deg', 'det', 'dim', 'ker', 'mod', 'gcd', 'Pr', 'limsup', 'liminf'];

  static init(): void {
    if (LatexSymbols.MAP.size > 0) {
      return;
    }
    let map: Map<string, string> = LatexSymbols.MAP;
    map.set('times', '×');
    map.set('div', '÷');
    map.set('pm', '±');
    map.set('mp', '∓');
    map.set('cdot', '⋅');
    map.set('ast', '∗');
    map.set('star', '⋆');
    map.set('circ', '∘');
    map.set('bullet', '•');
    map.set('oplus', '⊕');
    map.set('ominus', '⊖');
    map.set('otimes', '⊗');
    map.set('oslash', '⊘');
    map.set('odot', '⊙');
    map.set('neq', '≠');
    map.set('ne', '≠');
    map.set('leq', '≤');
    map.set('le', '≤');
    map.set('geq', '≥');
    map.set('ge', '≥');
    map.set('leqq', '≦');
    map.set('geqq', '≧');
    map.set('ll', '≪');
    map.set('gg', '≫');
    map.set('sim', '∼');
    map.set('simeq', '≃');
    map.set('approx', '≈');
    map.set('cong', '≅');
    map.set('equiv', '≡');
    map.set('doteq', '≐');
    map.set('propto', '∝');
    map.set('infty', '∞');
    map.set('partial', '∂');
    map.set('nabla', '∇');
    map.set('prime', '′');
    map.set('degree', '°');
    map.set('angle', '∠');
    map.set('perp', '⊥');
    map.set('parallel', '∥');
    map.set('forall', '∀');
    map.set('exists', '∃');
    map.set('nexists', '∄');
    map.set('neg', '¬');
    map.set('lnot', '¬');
    map.set('land', '∧');
    map.set('wedge', '∧');
    map.set('lor', '∨');
    map.set('vee', '∨');
    map.set('rightarrow', '→');
    map.set('to', '→');
    map.set('leftarrow', '←');
    map.set('leftrightarrow', '↔');
    map.set('Rightarrow', '⇒');
    map.set('Leftarrow', '⇐');
    map.set('Leftrightarrow', '⇔');
    map.set('uparrow', '↑');
    map.set('downarrow', '↓');
    map.set('longrightarrow', '⟶');
    map.set('longleftarrow', '⟵');
    map.set('mapsto', '↦');
    map.set('in', '∈');
    map.set('notin', '∉');
    map.set('ni', '∋');
    map.set('subset', '⊂');
    map.set('supset', '⊃');
    map.set('subseteq', '⊆');
    map.set('supseteq', '⊇');
    map.set('cup', '∪');
    map.set('cap', '∩');
    map.set('emptyset', '∅');
    map.set('varnothing', '∅');
    map.set('aleph', 'ℵ');
    map.set('hbar', 'ℏ');
    map.set('ell', 'ℓ');
    map.set('Re', 'ℜ');
    map.set('Im', 'ℑ');
    map.set('wp', '℘');
    map.set('dots', '…');
    map.set('ldots', '…');
    map.set('cdots', '⋯');
    map.set('vdots', '⋮');
    map.set('ddots', '⋱');
    map.set('surd', '√');
    map.set('triangle', '△');
    map.set('square', '□');
    map.set('Box', '□');
    map.set('blacksquare', '■');
    map.set('clubsuit', '♣');
    map.set('diamondsuit', '♦');
    map.set('heartsuit', '♥');
    map.set('spadesuit', '♠');
    map.set('bigcup', '⋃');
    map.set('bigcap', '⋂');
    map.set('bigoplus', '⨁');
    map.set('bigotimes', '⨂');
    map.set('bigodot', '⨀');
    map.set('bigsqcup', '⨆');
    map.set('iint', '∬');
    map.set('iiint', '∭');
    map.set('oint', '∮');
    map.set('S', '§');
    map.set('P', '¶');
    map.set('dag', '†');
    map.set('ddag', '‡');
    map.set('copyright', '©');
    map.set('pounds', '£');
    map.set('euro', '€');
    map.set('yen', '¥');
    map.set('zeta', 'ζ');
    map.set('checkmark', '✓');
    // 定界符(不在 \left...\right 里单独使用时也要能显示)
    map.set('langle', '⟨');
    map.set('rangle', '⟩');
    map.set('lfloor', '⌊');
    map.set('rfloor', '⌋');
    map.set('lceil', '⌈');
    map.set('rceil', '⌉');
    map.set('vert', '|');
    map.set('Vert', '‖');
    map.set('lvert', '|');
    map.set('rvert', '|');
    map.set('lVert', '‖');
    map.set('rVert', '‖');
    map.set('backslash', '\\');
    // 逻辑/关系/集合的常用补充
    map.set('because', '∵');
    map.set('therefore', '∴');
    map.set('triangleq', '≜');
    map.set('coloneqq', '≔');
    map.set('eqqcolon', '≕');
    map.set('approxeq', '≊');
    map.set('lesssim', '≲');
    map.set('gtrsim', '≳');
    map.set('leqslant', '⩽');
    map.set('geqslant', '⩾');
    map.set('nleq', '≰');
    map.set('ngeq', '≱');
    map.set('nless', '≮');
    map.set('ngtr', '≯');
    map.set('subsetneq', '⊊');
    map.set('supsetneq', '⊋');
    map.set('setminus', '∖');
    map.set('mid', '∣');
    map.set('nmid', '∤');
    map.set('vdash', '⊢');
    map.set('dashv', '⊣');
    map.set('models', '⊨');
    map.set('top', '⊤');
    map.set('bot', '⊥');
    map.set('imath', 'ı');
    map.set('jmath', 'ȷ');
    map.set('mho', '℧');
    map.set('measuredangle', '∡');
    map.set('sphericalangle', '∢');
    map.set('ltimes', '⋉');
    map.set('rtimes', '⋊');
    map.set('uplus', '⊎');
    map.set('sqcup', '⊔');
    map.set('sqcap', '⊓');
    map.set('amalg', '⨿');
    map.set('dagger', '†');
    map.set('ddagger', '‡');

    let greek: Map<string, string> = LatexSymbols.GREEK;
    greek.set('alpha', 'α');
    greek.set('beta', 'β');
    greek.set('gamma', 'γ');
    greek.set('delta', 'δ');
    greek.set('epsilon', 'ε');
    greek.set('varepsilon', 'ε');
    greek.set('zeta', 'ζ');
    greek.set('eta', 'η');
    greek.set('theta', 'θ');
    greek.set('vartheta', 'ϑ');
    greek.set('iota', 'ι');
    greek.set('kappa', 'κ');
    greek.set('varkappa', 'ϰ');
    greek.set('lambda', 'λ');
    greek.set('mu', 'μ');
    greek.set('nu', 'ν');
    greek.set('xi', 'ξ');
    greek.set('omicron', 'ο');
    greek.set('pi', 'π');
    greek.set('varpi', 'ϖ');
    greek.set('rho', 'ρ');
    greek.set('varrho', 'ϱ');
    greek.set('sigma', 'σ');
    greek.set('varsigma', 'ς');
    greek.set('tau', 'τ');
    greek.set('upsilon', 'υ');
    greek.set('phi', 'ϕ');
    greek.set('varphi', 'φ');
    greek.set('chi', 'χ');
    greek.set('psi', 'ψ');
    greek.set('omega', 'ω');
    greek.set('Gamma', 'Γ');
    greek.set('Delta', 'Δ');
    greek.set('Theta', 'Θ');
    greek.set('Lambda', 'Λ');
    greek.set('Xi', 'Ξ');
    greek.set('Pi', 'Π');
    greek.set('Sigma', 'Σ');
    greek.set('Upsilon', 'Υ');
    greek.set('Phi', 'Φ');
    greek.set('Psi', 'Ψ');
    greek.set('Omega', 'Ω');
    greek.set('digamma', 'ϝ');
  }

  static get(name: string): string {
    if (LatexSymbols.MAP.size === 0) {
      LatexSymbols.init();
    }
    if (LatexSymbols.GREEK.has(name)) {
      return LatexSymbols.GREEK.get(name) as string;
    }
    let v: string | undefined = LatexSymbols.MAP.get(name);
    return v !== undefined ? v : '';
  }

  static isFunction(name: string): boolean {
    for (let i: number = 0; i < LatexSymbols.FUNCTIONS.length; i++) {
      if (LatexSymbols.FUNCTIONS[i] === name) {
        return true;
      }
    }
    return false;
  }
}

// LaTeX 解析审计: 记录未识别命令与结构性错误, 由 DocxBuilder 生成后自检使用。
// 关键原则: 不静默降级 —— 解析不了的内容要么明确记录, 要么原样保留, 由自检决定拒绝写盘。
class LatexAudit {
  private static unknown: Map<string, number> = new Map<string, number>();
  private static issues: string[] = [];

  static begin(): void {
    LatexAudit.unknown = new Map<string, number>();
    LatexAudit.issues = [];
  }

  static unknownCommand(name: string): void {
    let n: number | undefined = LatexAudit.unknown.get(name);
    LatexAudit.unknown.set(name, n === undefined ? 1 : n + 1);
  }

  static issue(message: string): void {
    if (LatexAudit.issues.indexOf(message) === -1) {
      LatexAudit.issues.push(message);
    }
  }

  static take(): MathAuditResult {
    let r: MathAuditResult = new MathAuditResult();
    r.unknownCommands = Array.from(LatexAudit.unknown.keys());
    r.issues = LatexAudit.issues.slice();
    LatexAudit.unknown = new Map<string, number>();
    LatexAudit.issues = [];
    return r;
  }
}

export class MathAuditResult {
  unknownCommands: string[] = [];
  issues: string[] = [];
}

// 行内数学渲染上下文 (供 parseCommand 中的 \text 内部转义等使用)
class LatexParser {
  private src: string = '';
  private pos: number = 0;

  // 完整解析一段 latex, 返回 OMML 内容(不含 <m:oMath> 包裹)
  parseAll(): string {
    return this.parseSegment(false);
  }

  // 解析到 '}' (stopAtEnd=true 时消费掉并停止) 或 \end 或结尾
  private parseSegment(stopAtEnd: boolean): string {
    let parts: string[] = [];
    let stack: DelimMarker[] = [];
    let len: number = this.src.length;
    while (this.pos < len) {
      let c: string = this.src.charAt(this.pos);
      if (c === '}') {
        if (stopAtEnd) {
          this.pos++;
          break;
        }
        // 孤立的 '}' 直接输出
        parts.push(LatexParser.run('}'));
        this.pos++;
        continue;
      }
      if (c === '\\') {
        // \left / \right 需要在当前 segment 的栈上配对, 其余命令一律按「原子 + 上下标」处理。
        // 这是 \mu_0 / \alpha_2 / \bar{I}^2 下标被吞的根因: 命令直接写入 parts 后,
        // 后面的 ^/_ 找不到基元, 只能退化成空 run + 普通文本。
        let cmdName: string = this.peekCommandName();
        if (cmdName === 'left') {
          this.parseCommand(parts, stack);
          continue;
        }
        if (cmdName === 'right') {
          this.parseCommand(parts, stack);
          if (parts.length > 0) {
            parts[parts.length - 1] = this.applyScripts(parts[parts.length - 1]);
          }
          continue;
        }
        parts.push(this.parseAtomWithScripts());
        continue;
      }
      if (c === '^' || c === '_') {
        // 没有基元的上下标属于非法输入: 记录后仍消费参数, 让自检拒绝写盘, 不再静默降级。
        LatexAudit.issue('上下标缺少基元(如公式以 ^ 或 _ 开头, 或前面是空组)');
        this.pos++;
        let orphan: string = this.parseScriptArg();
        parts.push(LatexParser.emptyRun());
        if (orphan !== '') {
          parts.push(orphan);
        }
        continue;
      }
      if (c === '&' || c === '\\' && this.pos + 1 < len && this.src.charAt(this.pos + 1) === '\\') {
        // '&' 与 '\\' 仅在矩阵环境中出现, 在此处按空格处理, 避免结构损坏
        parts.push(LatexParser.spaceRun());
        this.pos += (c === '&') ? 1 : 2;
        continue;
      }
      if (c === ' ' || c === '\t' || c === '\n') {
        // 数学模式中的空白压缩为一个空格
        this.pos++;
        continue;
      }
      // 普通原子 + 可能的上下标
      parts.push(this.parseAtomWithScripts());
    }
    // 处理未闭合的 \left( ... 栈: 保留已经解析出的内容, 只补回可见的起始定界符。
    // 不能把 marker.start 之后的内容整段替换掉 —— 那是静默丢内容。
    for (let i: number = stack.length - 1; i >= 0; i--) {
      let marker: DelimMarker = stack[i];
      LatexAudit.issue('\\left 缺少配对的 \\right(已保留内容, 但定界符不会自动缩放)');
      if (marker.beg !== '') {
        parts.splice(marker.start, 0, LatexParser.run(marker.beg));
      }
    }
    return parts.join('');
  }

  // 查看当前反斜杠命令名(不移动 pos); 转义字符或末尾返回 ''
  private peekCommandName(): string {
    let len: number = this.src.length;
    if (this.pos >= len || this.src.charAt(this.pos) !== '\\') {
      return '';
    }
    let i: number = this.pos + 1;
    if (i >= len || !LatexParser.isLetter(this.src.charAt(i))) {
      return '';
    }
    let name: string = '';
    while (i < len && LatexParser.isLetter(this.src.charAt(i))) {
      name += this.src.charAt(i);
      i++;
    }
    return name;
  }

  // 解析一个普通原子(单字符/组), 然后附加可能的 ^ 和 _ 后缀, 返回组合后的 OMML
  private parseAtomWithScripts(): string {
    return this.applyScripts(this.parseAtom());
  }

  // 把紧随其后的 ^/_ 绑定到 base 上。\left...\right 组、命令、字符、组都走同一条路径。
  private applyScripts(base: string): string {
    let subStr: string = '';
    let supStr: string = '';
    let len: number = this.src.length;
    // 顺序: _ 或 ^ 均可先后出现
    for (let i: number = 0; i < 2; i++) {
      if (this.pos >= len) {
        break;
      }
      let c: string = this.src.charAt(this.pos);
      if (c === '^') {
        this.pos++;
        supStr = this.parseScriptArg();
      } else if (c === '_') {
        this.pos++;
        subStr = this.parseScriptArg();
      } else {
        break;
      }
    }
    if (supStr !== '' && subStr !== '') {
      return '<m:sSubSup><m:e>' + base + '</m:e><m:sub>' + subStr + '</m:sub><m:sup>' + supStr + '</m:sup></m:sSubSup>';
    }
    if (supStr !== '') {
      return '<m:sSup><m:e>' + base + '</m:e><m:sup>' + supStr + '</m:sup></m:sSup>';
    }
    if (subStr !== '') {
      return '<m:sSub><m:e>' + base + '</m:e><m:sub>' + subStr + '</m:sub></m:sSub>';
    }
    return base;
  }

  // 读取一个上/下标参数: 组 {...} 或单个原子
  private parseScriptArg(): string {
    let len: number = this.src.length;
    if (this.pos >= len) {
      LatexAudit.issue('上下标缺少内容(公式在 ^ 或 _ 后结束)');
      return LatexParser.emptyRun();
    }
    if (this.src.charAt(this.pos) === '{') {
      this.pos++;
      let inner: string = this.parseSegment(true);
      // 空组 {} 视为「没有上下标」, 不生成空 m:t 节点
      return inner;
    }
    if (this.src.charAt(this.pos) === '^' || this.src.charAt(this.pos) === '_') {
      LatexAudit.issue('上下标缺少内容(连续出现 ^ 或 _)');
      return LatexParser.emptyRun();
    }
    return this.parseAtom();
  }

  // 解析一个原子(不含上下标): 组 / 命令 / 单字符, 返回 OMML
  private parseAtom(): string {
    let len: number = this.src.length;
    if (this.pos >= len) {
      return '';
    }
    let c: string = this.src.charAt(this.pos);
    if (c === '{') {
      this.pos++;
      let inner: string = this.parseSegment(true);
      return inner;
    }
    if (c === '\\') {
      // 命令作为基元
      let localParts: string[] = [];
      let localStack: DelimMarker[] = [];
      let cmdRes: CmdResult = this.parseCommand(localParts, localStack);
      if (cmdRes.produced) {
        for (let i: number = localStack.length - 1; i >= 0; i--) {
          let marker: DelimMarker = localStack[i];
          if (marker.beg !== '') {
            localParts.splice(marker.start, 0, LatexParser.run(marker.beg));
          }
        }
        return localParts.join('');
      }
      LatexAudit.issue('反斜杠后缺少命令');
      return '';
    }
    // 单字符
    this.pos++;
    return LatexParser.run(c);
  }

  // 命令解析: 返回是否产生了输出(写入 parts)
  private parseCommand(parts: string[], stack: DelimMarker[]): CmdResult {
    let len: number = this.src.length;
    let result: CmdResult = new CmdResult();
    if (this.pos >= len || this.src.charAt(this.pos) !== '\\') {
      return result;
    }
    this.pos++;
    if (this.pos >= len) {
      result.produced = false;
      return result;
    }
    let c: string = this.src.charAt(this.pos);
    if (!LatexParser.isLetter(c)) {
      // 转义字符: \& \% \$ \# \_ \{ \} \\ \~ \^ 等
      this.pos++;
      let esc: string = '';
      if (c === '&') {
        esc = '&';
      } else if (c === '%') {
        esc = '%';
      } else if (c === '$') {
        esc = '$';
      } else if (c === '#') {
        esc = '#';
      } else if (c === '_') {
        esc = '_';
      } else if (c === '{') {
        esc = '{';
      } else if (c === '}') {
        esc = '}';
      } else if (c === '\\') {
        esc = '';
      } else if (c === '|') {
        // LaTeX 的 \| 是双竖线(范数), 不是单竖线
        esc = '‖';
      } else if (c === '~') {
        esc = ' ';
      } else if (c === '^') {
        esc = '^';
      } else if (c === ',') {
        esc = ' ';
      } else if (c === ';') {
        esc = ' ';
      } else if (c === '!') {
        esc = '';
      } else if (c === ' ') {
        esc = ' ';
      } else {
        esc = c;
      }
      parts.push(LatexParser.run(esc));
      result.produced = true;
      return result;
    }
    // 字母命令
    let name: string = '';
    while (this.pos < len && LatexParser.isLetter(this.src.charAt(this.pos))) {
      name += this.src.charAt(this.pos);
      this.pos++;
    }
    result.produced = true;
    this.handleNamedCommand(name, parts, stack);
    return result;
  }

  // 处理命名命令(名称不含反斜杠)
  private handleNamedCommand(name: string, parts: string[], stack: DelimMarker[]): void {
    let len: number = this.src.length;

    // 大小定界符: \big( \Big[ \bigl\{ ... 只输出定界符本身
    if (name === 'big' || name === 'Big' || name === 'bigg' || name === 'Bigg' ||
      name === 'bigl' || name === 'bigr' || name === 'Bigl' || name === 'Bigr' ||
      name === 'biggl' || name === 'biggr' || name === 'Biggl' || name === 'Biggr') {
      let delim: string = this.readDelimiter();
      if (delim !== '.') {
        parts.push(LatexParser.run(delim));
      }
      return;
    }

    // \not 组合: 常见否定关系直接映射, 避免整条公式因未知命令被拒
    if (name === 'not') {
      let target: string = '';
      if (this.pos < len && this.src.charAt(this.pos) === '\\') {
        target = this.peekCommandName();
        this.pos += 1 + target.length;
      } else if (this.pos < len) {
        target = this.src.charAt(this.pos);
        this.pos++;
      }
      let negMap: Map<string, string> = new Map<string, string>();
      negMap.set('=', '≠');
      negMap.set('<', '≮');
      negMap.set('>', '≯');
      negMap.set('in', '∉');
      negMap.set('subset', '⊄');
      negMap.set('supset', '⊅');
      negMap.set('subseteq', '⊈');
      negMap.set('supseteq', '⊉');
      negMap.set('equiv', '≢');
      negMap.set('approx', '≉');
      negMap.set('leq', '≰');
      negMap.set('geq', '≱');
      let neg: string | undefined = negMap.get(target);
      parts.push(LatexParser.run(neg !== undefined ? neg : '¬' + target));
      return;
    }

    // 公式编号与矩阵横线: 属于排版元信息, 丢弃但必须消费参数, 不能把 \tag{1} 当正文
    if (name === 'tag') {
      this.readGroupRaw();
      return;
    }
    if (name === 'notag' || name === 'nonumber' || name === 'hline' || name === 'hdashline') {
      return;
    }
    if (name === 'cline') {
      this.readGroupRaw();
      return;
    }

    // \middle| 作为 \left...\right 中间的分隔符, 直接输出字符
    if (name === 'middle') {
      let delim: string = this.readDelimiter();
      if (delim !== '.') {
        parts.push(LatexParser.run(delim));
      }
      return;
    }

    // \left / \right 分隔符; '.' 表示不可见, 用空 begChr/endChr 而不是字面句点
    if (name === 'left' || name === 'right') {
      let delim: string = this.readDelimiter();
      let visible: string = delim === '.' ? '' : delim;
      if (name === 'left') {
        let marker: DelimMarker = new DelimMarker();
        marker.start = parts.length;
        marker.beg = visible;
        stack.push(marker);
        return;
      }
      // right: 弹栈 wrap
      if (stack.length === 0) {
        LatexAudit.issue('\\right 缺少配对的 \\left');
        if (visible !== '') {
          parts.push(LatexParser.run(visible));
        }
        return;
      }
      let marker: DelimMarker = stack.pop() as DelimMarker;
      let begVal: string = marker.beg;
      let endVal: string = visible;
      let inner: string = parts.slice(marker.start).join('');
      parts.splice(marker.start, parts.length - marker.start, '');
      let dXml: string = '<m:d><m:dPr><m:begChr m:val="' + XmlUtil.escapeAttr(begVal) + '"/>' +
        '<m:endChr m:val="' + XmlUtil.escapeAttr(endVal) + '"/></m:dPr><m:e>' + inner + '</m:e></m:d>';
      parts.splice(marker.start, 1, dXml);
      return;
    }

    // 分式
    if (name === 'frac' || name === 'dfrac' || name === 'tfrac') {
      let num: string = this.readGroupOrAtom();
      let den: string = this.readGroupOrAtom();
      if (num === '' || den === '') {
        parts.push(LatexParser.run('\\' + name));
        return;
      }
      parts.push('<m:f><m:num>' + num + '</m:num><m:den>' + den + '</m:den></m:f>');
      return;
    }

    // 根式
    if (name === 'sqrt') {
      let deg: string = '';
      if (this.pos < len && this.src.charAt(this.pos) === '[') {
        this.pos++;
        let d: string = '';
        while (this.pos < len && this.src.charAt(this.pos) !== ']') {
          d += this.src.charAt(this.pos);
          this.pos++;
        }
        if (this.pos < len) {
          this.pos++;
        }
        deg = d;
      }
      let content: string = this.readGroupOrAtom();
      if (content === '') {
        parts.push(LatexParser.run('\\' + name));
        return;
      }
      if (deg === '') {
        parts.push('<m:rad><m:radPr><m:degHide m:val="on"/></m:radPr><m:deg/>' +
          '<m:e>' + content + '</m:e></m:rad>');
      } else {
        parts.push('<m:rad><m:deg>' + new LatexParser().initAndParse(deg) + '</m:deg>' +
          '<m:e>' + content + '</m:e></m:rad>');
      }
      return;
    }

    // nary: 求和/积分等 (读取随后的 ^ 和 _)
    let naryChr: string = '';
    let naryLoc: string = '';
    if (name === 'sum') {
      naryChr = '∑';
      naryLoc = 'undOvr';
    } else if (name === 'prod') {
      naryChr = '∏';
      naryLoc = 'undOvr';
    } else if (name === 'coprod') {
      naryChr = '∐';
      naryLoc = 'undOvr';
    } else if (name === 'int') {
      naryChr = '∫';
      naryLoc = 'subSup';
    } else if (name === 'iint') {
      naryChr = '∬';
      naryLoc = 'subSup';
    } else if (name === 'iiint') {
      naryChr = '∭';
      naryLoc = 'subSup';
    } else if (name === 'oint') {
      naryChr = '∮';
      naryLoc = 'subSup';
    } else if (name === 'bigcup') {
      naryChr = '⋃';
      naryLoc = 'undOvr';
    } else if (name === 'bigcap') {
      naryChr = '⋂';
      naryLoc = 'undOvr';
    } else if (name === 'bigoplus') {
      naryChr = '⨁';
      naryLoc = 'undOvr';
    } else if (name === 'bigotimes') {
      naryChr = '⨂';
      naryLoc = 'undOvr';
    } else if (name === 'bigodot') {
      naryChr = '⨀';
      naryLoc = 'undOvr';
    } else if (name === 'bigsqcup') {
      naryChr = '⨆';
      naryLoc = 'undOvr';
    } else if (name === 'bigvee') {
      naryChr = '⋁';
      naryLoc = 'undOvr';
    } else if (name === 'bigwedge') {
      naryChr = '⋀';
      naryLoc = 'undOvr';
    }
    if (naryChr !== '') {
      let subXml: string = '';
      let supXml: string = '';
      let remain: boolean = true;
      while (remain && this.pos < len) {
        let c: string = this.src.charAt(this.pos);
        if (c === '_') {
          this.pos++;
          subXml = this.parseScriptArg();
        } else if (c === '^') {
          this.pos++;
          supXml = this.parseScriptArg();
        } else {
          remain = false;
        }
      }
      // 没有上下限时用空元素(合法), 不要生成空 m:t 节点 —— 否则自检无法区分「正常的无上下限」
      // 与「脚本被吞掉的坏公式」。
      if (subXml === '') {
        subXml = '<m:sub/>';
      } else {
        subXml = '<m:sub>' + subXml + '</m:sub>';
      }
      if (supXml === '') {
        supXml = '<m:sup/>';
      } else {
        supXml = '<m:sup>' + supXml + '</m:sup>';
      }
      parts.push('<m:nary><m:naryPr><m:chr m:val="' + naryChr + '"/>' +
        '<m:limLoc m:val="' + naryLoc + '"/></m:naryPr>' + subXml + supXml + '<m:e/></m:nary>');
      return;
    }

    // 极限: \lim_{x \to 0}
    if (name === 'lim' || name === 'liminf' || name === 'limsup') {
      let label: string = name === 'liminf' ? 'lim inf' : (name === 'limsup' ? 'lim sup' : 'lim');
      if (this.pos < len && this.src.charAt(this.pos) === '_') {
        this.pos++;
        let sub: string = this.parseScriptArg();
        parts.push('<m:limLow><m:e>' + LatexParser.styledRun(label, 'p') + '</m:e><m:lim>' + sub + '</m:lim></m:limLow>');
      } else {
        parts.push(LatexParser.styledRun(label, 'p'));
      }
      return;
    }

    // 函数名(带自动正体与可选的上下标由外层处理): sin cos tan 等
    if (LatexSymbols.isFunction(name)) {
      parts.push(LatexParser.styledRun(name, 'p'));
      return;
    }

    // 希腊字母与符号
    let sym: string = LatexSymbols.get(name);
    if (sym !== '') {
      parts.push(LatexParser.run(sym));
      return;
    }

    // \text / \textbf 等真正的文本模式: 内容按原样显示, 不解析 ^/_
    if (name === 'text' || name === 'textbf' || name === 'textit' || name === 'textnormal' ||
      name === 'texttt' || name === 'textsc') {
      let txt: string = this.readGroupRaw();
      let sty: string = 'p';
      if (name === 'textbf') {
        sty = 'b';
      } else if (name === 'textit') {
        sty = 'i';
      }
      parts.push(LatexParser.styledRun(escText(txt), sty));
      return;
    }
    // \mathrm 是数学模式里的正体, 不是 \text: 组内必须继续解析 ^/_/分式等
    if (name === 'mathrm') {
      let inner: string = this.readGroupOrAtom();
      parts.push(LatexParser.applyStyle(inner, 'p'));
      return;
    }
    // \operatorname{arg\,max}: 函数名按文本读取, 但整体保持正体
    if (name === 'operatorname') {
      let txt: string = this.readGroupRaw();
      parts.push(LatexParser.styledRun(escText(txt), 'p'));
      return;
    }
    // \mathbf / \boldsymbol / \mathit: 保留组内结构(上下标/分式), 只给每个 m:r 加字形
    if (name === 'mathbf' || name === 'boldsymbol' || name === 'mathit') {
      let inner: string = this.readGroupOrAtom();
      let sty: string = name === 'mathit' ? 'i' : 'b';
      parts.push(LatexParser.applyStyle(inner, sty));
      return;
    }
    // \mathbb{R} 等双线体: 直接映射到 Unicode 双线字符(Word 不依赖额外字体)
    if (name === 'mathbb') {
      let raw: string = this.readGroupRaw();
      parts.push(LatexParser.run(LatexParser.blackboard(raw)));
      return;
    }
    // \mathcal / \mathfrak / \mathsf 等: 至少保留内容, 不静默丢弃
    if (name === 'mathcal' || name === 'mathfrak' || name === 'mathsf' || name === 'mathscr' ||
      name === 'mathnormal') {
      let raw: string = this.readGroupRaw();
      parts.push(LatexParser.run(raw));
      return;
    }
    // 上下堆叠: \overset{上}{基} / \underset{下}{基} / \stackrel{上}{基}
    if (name === 'overset' || name === 'underset' || name === 'stackrel') {
      let over: string = this.readGroupOrAtom();
      let base: string = this.readGroupOrAtom();
      if (base === '') {
        parts.push(LatexParser.run('\\' + name));
        return;
      }
      let tag: string = name === 'underset' ? 'm:limLow' : 'm:limUpp';
      let limTag: string = name === 'underset' ? 'm:lim' : 'm:lim';
      parts.push('<' + tag + '><m:e>' + base + '</m:e><' + limTag + '>' + over + '</' + limTag + '></' + tag + '>');
      return;
    }

    // 重音: 用组合附加符(比 ASCII ^ / ~ 更贴近 Word 数学排版)
    let accMap: Map<string, string> = new Map<string, string>();
    accMap.set('hat', '̂');
    accMap.set('widehat', '̂');
    accMap.set('vec', '⃗');
    accMap.set('dot', '̇');
    accMap.set('ddot', '̈');
    accMap.set('tilde', '̃');
    accMap.set('widetilde', '̃');
    accMap.set('check', '̌');
    accMap.set('breve', '̆');
    accMap.set('overrightarrow', '⃗');
    accMap.set('overleftarrow', '⃖');
    accMap.set('overleftrightarrow', '⃡');
    if (accMap.has(name)) {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:acc><m:accPr><m:chr m:val="' + accMap.get(name) + '"/></m:accPr>' +
        '<m:e>' + content + '</m:e></m:acc>');
      return;
    }

    // 上下划线: \bar / \overline 只加一层 m:bar, 不再走 m:acc(避免一层变两层)
    if (name === 'bar' || name === 'overline') {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:bar><m:barPr><m:pos m:val="top"/></m:barPr><m:e>' + content + '</m:e></m:bar>');
      return;
    }
    if (name === 'underline') {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:bar><m:barPr><m:pos m:val="bottom"/></m:barPr><m:e>' + content + '</m:e></m:bar>');
      return;
    }
    if (name === 'overbrace') {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:groupChr><m:groupChrPr><m:chr m:val="⏞"/><m:pos m:val="top"/>' +
        '<m:vertJc m:val="bot"/></m:groupChrPr><m:e>' + content + '</m:e></m:groupChr>');
      return;
    }
    if (name === 'underbrace') {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:groupChr><m:groupChrPr><m:chr m:val="⏟"/><m:pos m:val="bot"/>' +
        '<m:vertJc m:val="top"/></m:groupChrPr><m:e>' + content + '</m:e></m:groupChr>');
      return;
    }

    // 二项式: 近似为分式
    if (name === 'binom' || name === 'dbinom' || name === 'tbinom') {
      let top: string = this.readGroupOrAtom();
      let bottom: string = this.readGroupOrAtom();
      if (top === '' || bottom === '') {
        parts.push(LatexParser.run('\\' + name));
        return;
      }
      parts.push('<m:d><m:dPr><m:begChr m:val="("/><m:endChr m:val=")"/></m:dPr>' +
        '<m:e><m:f><m:num>' + top + '</m:num><m:den>' + bottom + '</m:den></m:f></m:e></m:d>');
      return;
    }

    // 方框: \boxed{...}
    if (name === 'boxed') {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:borderBox><m:borderBoxPr><m:hide m:val="off"/></m:borderBoxPr>' +
        '<m:e>' + content + '</m:e></m:borderBox>');
      return;
    }

    // 矩阵与对齐环境
    if (name === 'begin') {
      let env: string = this.readBracedName();
      this.parseEnvironment(env, parts);
      return;
    }
    if (name === 'end') {
      // 单独出现的 \end 忽略(环境解析由 parseEnvironment 消费)
      this.readBracedName();
      return;
    }

    // 间距
    if (name === 'quad' || name === 'qquad' || name === 'enspace' || name === 'thinspace' ||
      name === 'medspace' || name === 'thickspace' || name === 'smallint' || name === 'negthinspace') {
      parts.push(LatexParser.spaceRun());
      return;
    }

    // \color{...}{...} / \textcolor{..}{..}: 跳过颜色参数
    if (name === 'color' || name === 'textcolor' || name === 'colorbox' || name === 'fcolorbox') {
      if (name === 'fcolorbox') {
        this.readGroupOrAtom();
      }
      let inner: string = this.readGroupOrAtom();
      if (inner !== '') {
        parts.push(inner);
      }
      return;
    }

    // 忽略参数的控制结构
    if (name === 'limits' || name === 'nolimits' || name === 'displaystyle' || name === 'textstyle' ||
      name === 'scriptstyle' || name === 'scriptscriptstyle' || name === 'leftmargin' || name === 'protect' ||
      name === 'relax' || name === 'noindent' || name === 'itemindent' || name === 'label' || name === 'ref' ||
      name === 'eqref' || name === 'pageref' || name === 'vspace' || name === 'hspace' || name === 'vskip' ||
      name === 'kern' || name === 'mkern' || name === 'phantom' || name === 'hphantom' || name === 'vphantom' ||
      name === 'rule' || name === 'smash' || name === 'hfill' || name === 'vfill' || name === 'small' ||
      name === 'normalsize' || name === 'large' || name === 'Large' || name === 'LARGE' || name === 'huge' ||
      name === 'Huge' || name === 'scriptsize' || name === 'footnotesize' || name === 'tiny' || name === 'bf' ||
      name === 'it' || name === 'em' || name === 'rm' || name === 'sf' || name === 'tt' || name === 'cal' ||
      name === 'mathcal' || name === 'mathbb' || name === 'mathfrak' || name === 'mathscr' || name === 'mathsf') {
      // 部分命令需要吃掉参数
      let takeArgs: boolean = name === 'label' || name === 'ref' || name === 'eqref' || name === 'pageref' ||
        name === 'rule' || name === 'kern' || name === 'mkern' || name === 'vspace' ||
        name === 'hspace' || name === 'vskip' || name === 'phantom' || name === 'hphantom' ||
        name === 'vphantom';
      if (takeArgs) {
        this.readGroupOrAtom();
      }
      return;
    }

    // 未知命令: 保留完整的 \name 原文(而不是只留 name), 并记录到审计;
    // 这样自检能明确拒绝, 不会生成「看起来成功、实际丢了命令」的文档。
    LatexAudit.unknownCommand(name);
    parts.push(LatexParser.run('\\' + name));
  }

  // 解析环境体(矩阵/对齐), 输出到 parts
  private parseEnvironment(env: string, parts: string[]): void {
    let openDelim: string = '';
    let closeDelim: string = '';
    let isEqArray: boolean = false;
    let len: number = this.src.length;
    if (env === 'pmatrix') {
      openDelim = '(';
      closeDelim = ')';
    } else if (env === 'bmatrix') {
      openDelim = '[';
      closeDelim = ']';
    } else if (env === 'Bmatrix') {
      openDelim = '{';
      closeDelim = '}';
    } else if (env === 'vmatrix') {
      openDelim = '|';
      closeDelim = '|';
    } else if (env === 'Vmatrix') {
      openDelim = '‖';
      closeDelim = '‖';
    } else if (env === 'cases') {
      // cases 只有左大括号, 没有右定界符
      openDelim = '{';
      closeDelim = '';
    } else if (env === 'aligned' || env === 'alignedat' || env === 'split' || env === 'gathered' ||
      env === 'gather' || env === 'multline' || env === 'align' || env === 'align*' ||
      env === 'flalign' || env === 'equation' || env === 'equation*' || env === 'displaymath' ||
      env === 'math') {
      // 对齐环境用 m:eqArr, 不再退化成两列矩阵
      isEqArray = true;
    } else if (env === 'array' || env === 'matrix' || env === 'smallmatrix') {
      openDelim = '';
    } else {
      // 未知环境: 不再静默跳过(那会让用户以为公式生成成功)。记录后跳过内容, 由自检拒绝写盘。
      LatexAudit.issue('不支持的环境: \\begin{' + env + '}');
      while (this.pos < len) {
        if (this.src.startsWith('\\end', this.pos)) {
          this.pos += 4;
          this.readBracedName();
          break;
        }
        this.pos++;
      }
      return;
    }
    // array / alignedat 的环境参数({cc} 列格式 / {2} 对齐点数量)不是公式内容, 必须消费掉
    if ((env === 'array' || env === 'alignedat') && this.pos < len && this.src.charAt(this.pos) === '{') {
      this.readBracedName();
    }
    // 收集矩阵单元格(按 \\ 分行, & 分列)
    let rows: string[][] = [];
    let currentRow: string[] = [];
    let currentCell: string = '';
    while (this.pos < len) {
      if (this.src.startsWith('\\end', this.pos)) {
        this.pos += 4;
        this.readBracedName();
        break;
      }
      if (this.pos + 1 < len && this.src.charAt(this.pos) === '\\' && this.src.charAt(this.pos + 1) === '\\') {
        currentRow.push(currentCell);
        currentCell = '';
        rows.push(currentRow);
        currentRow = [];
        this.pos += 2;
        // 跳过行尾的 \cr 或可选间距 [2pt]
        if (this.src.startsWith('\\cr', this.pos)) {
          this.pos += 3;
        }
        if (this.pos < len && this.src.charAt(this.pos) === '[') {
          let close: number = this.src.indexOf(']', this.pos);
          if (close !== -1) {
            this.pos = close + 1;
          }
        }
        continue;
      }
      if (this.src.charAt(this.pos) === '&') {
        if (isEqArray) {
          // 对齐环境里的 & 只是对齐点标记, 不产生新列
          this.pos++;
          continue;
        }
        currentRow.push(currentCell);
        currentCell = '';
        this.pos++;
        continue;
      }
      currentCell += this.src.charAt(this.pos);
      this.pos++;
    }
    if (currentCell !== '' || currentRow.length > 0) {
      currentRow.push(currentCell);
      rows.push(currentRow);
    }
    // 空矩阵容错
    if (rows.length === 0) {
      rows.push(['']);
    }
    let mXml: string = '';
    if (isEqArray) {
      // 对齐环境: 每行一个 m:e, 由 Word 按关系符对齐(不再是 m:m 两列)
      mXml = '<m:eqArr>';
      for (let r: number = 0; r < rows.length; r++) {
        let rowText: string = rows[r].join('').trim();
        let cellXml: string = rowText === '' ? '' : new LatexParser().initAndParse(rowText);
        mXml += '<m:e>' + cellXml + '</m:e>';
      }
      mXml += '</m:eqArr>';
    } else {
      // 渲染 <m:m>
      mXml = '<m:m>';
      for (let r: number = 0; r < rows.length; r++) {
        mXml += '<m:mr>';
        let row: string[] = rows[r];
        if (row.length === 0) {
          row = [''];
        }
        for (let cIdx: number = 0; cIdx < row.length; cIdx++) {
          let cellXml: string = row[cIdx].trim();
          cellXml = cellXml === '' ? '' : new LatexParser().initAndParse(cellXml);
          mXml += '<m:e>' + cellXml + '</m:e>';
        }
        mXml += '</m:mr>';
      }
      mXml += '</m:m>';
    }
    // 带定界符的环境包一层 m:d(自动缩放); cases 只有左括号, closeDelim 为空
    if (openDelim !== '' || closeDelim !== '') {
      parts.push('<m:d><m:dPr><m:begChr m:val="' + XmlUtil.escapeAttr(openDelim) + '"/>' +
        '<m:endChr m:val="' + XmlUtil.escapeAttr(closeDelim) + '"/></m:dPr><m:e>' + mXml + '</m:e></m:d>');
    } else {
      parts.push(mXml);
    }
  }

  // 读取 \left / \right / \big 之后的分隔符(支持 \langle / \lfloor 等命名定界符)
  private readDelimiter(): string {
    let len: number = this.src.length;
    if (this.pos >= len) {
      return '.';
    }
    if (this.src.charAt(this.pos) !== '\\') {
      let c: string = this.src.charAt(this.pos);
      this.pos++;
      return c;
    }
    this.pos++;
    if (this.pos >= len) {
      return '.';
    }
    let c: string = this.src.charAt(this.pos);
    if (!LatexParser.isLetter(c)) {
      this.pos++;
      if (c === '|') {
        return '‖';
      }
      if (c === '{' || c === '}' || c === '.') {
        return c;
      }
      return c;
    }
    let name: string = '';
    while (this.pos < len && LatexParser.isLetter(this.src.charAt(this.pos))) {
      name += this.src.charAt(this.pos);
      this.pos++;
    }
    let map: Map<string, string> = new Map<string, string>();
    map.set('langle', '⟨');
    map.set('rangle', '⟩');
    map.set('lfloor', '⌊');
    map.set('rfloor', '⌋');
    map.set('lceil', '⌈');
    map.set('rceil', '⌉');
    map.set('vert', '|');
    map.set('Vert', '‖');
    map.set('lvert', '|');
    map.set('rvert', '|');
    map.set('lVert', '‖');
    map.set('rVert', '‖');
    map.set('backslash', '\\');
    map.set('lbrack', '[');
    map.set('rbrack', ']');
    map.set('lbrace', '{');
    map.set('rbrace', '}');
    let mapped: string | undefined = map.get(name);
    if (mapped !== undefined) {
      return mapped;
    }
    LatexAudit.unknownCommand(name);
    return '.';
  }

  // 读取 {name} 形式的参数
  private readBracedName(): string {
    let len: number = this.src.length;
    let name: string = '';
    if (this.pos < len && this.src.charAt(this.pos) === '{') {
      this.pos++;
      while (this.pos < len && this.src.charAt(this.pos) !== '}') {
        name += this.src.charAt(this.pos);
        this.pos++;
      }
      if (this.pos < len) {
        this.pos++;
      }
    }
    return name;
  }

  // 读取组 {...} 或单个原子, 返回其 OMML (作为参数内容)
  private readGroupOrAtom(): string {
    let len: number = this.src.length;
    if (this.pos >= len) {
      return '';
    }
    if (this.src.charAt(this.pos) === '{') {
      this.pos++;
      let inner: string = this.parseSegment(true);
      return inner === '' ? '' : inner;
    }
    // 单个原子(允许命令), 但不消费上下标
    return this.parseAtom();
  }

  // 读取组 {...} 的原始文本(不做数学解析, 供 \text 使用)
  private readGroupRaw(): string {
    let len: number = this.src.length;
    let raw: string = '';
    if (this.pos < len && this.src.charAt(this.pos) === '{') {
      this.pos++;
      let depth: number = 1;
      while (this.pos < len && depth > 0) {
        let c: string = this.src.charAt(this.pos);
        if (c === '{') {
          depth++;
        } else if (c === '}') {
          depth--;
          if (depth === 0) {
            this.pos++;
            break;
          }
        }
        raw += c;
        this.pos++;
      }
    } else if (this.pos < len) {
      raw = this.parseAtom() !== '' ? this.src.charAt(this.pos - 1) : '';
    }
    return raw;
  }

  static isLetter(c: string): boolean {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
  }

  // 普通数学 run
  static run(text: string): string {
    if (text === '') {
      return '';
    }
    return '<m:r>' + LatexParser.mathFontPr(text) + '<m:t xml:space="preserve">' +
      XmlUtil.escape(text) + '</m:t></m:r>';
  }

  // 空 run(占位; 仅用于非法输入, 正常路径不应产生)
  static emptyRun(): string {
    return '<m:r><m:t/></m:r>';
  }

  // 空格 run
  static spaceRun(): string {
    return '<m:r><m:t xml:space="preserve"> </m:t></m:r>';
  }

  // 指定字形的 run
  static styledRun(text: string, style: string): string {
    if (text === '') {
      return '';
    }
    return '<m:r><m:rPr><m:sty m:val="' + style + '"/></m:rPr>' + LatexParser.mathFontPr(text) +
      '<m:t xml:space="preserve">' + XmlUtil.escape(text) + '</m:t></m:r>';
  }

  // 给一段已生成的 OMML 里每个 m:r 加字形(保留上下标/分式等结构)。
  // \mathrm{m/s^2} 这类写法必须先按数学解析, 再统一改成正体, 不能按 \text 原样吞掉。
  static applyStyle(inner: string, style: string): string {
    if (inner === '') {
      return '';
    }
    return inner.replace(/<m:r>([\s\S]*?)<\/m:r>/g,
      (full: string, body: string): string => {
        if (body.indexOf('<m:sty ') !== -1) {
          return full;
        }
        if (body.indexOf('<m:rPr>') !== -1) {
          return '<m:r>' + body.replace('<m:rPr>',
            '<m:rPr><m:sty m:val="' + style + '"/>') + '</m:r>';
        }
        return '<m:r><m:rPr><m:sty m:val="' + style + '"/></m:rPr>' + body + '</m:r>';
      });
  }

  // 数学 run 的字体兜底: CJK 用宋体, 特殊符号用 Cambria Math, 避免 Uₐ 这类字符
  // 在默认数学字体里缺字形后被无声吞掉。
  private static mathFontPr(text: string): string {
    let needMath: boolean = false;
    let needCjk: boolean = false;
    for (let i: number = 0; i < text.length;) {
      let code: number = text.codePointAt(i) ?? 0;
      let step: number = code > 0xFFFF ? 2 : 1;
      if (LatexParser.isCjkCode(code)) {
        needCjk = true;
      } else if (LatexParser.isMathSymbolCode(code)) {
        needMath = true;
      }
      i += step;
    }
    if (!needMath && !needCjk) {
      return '';
    }
    return '<w:rPr><w:rFonts w:ascii="Cambria Math" w:hAnsi="Cambria Math" w:eastAsia="宋体"/></w:rPr>';
  }

  static isCjkCode(code: number): boolean {
    return (code >= 0x2E80 && code <= 0x9FFF) || (code >= 0xF900 && code <= 0xFAFF) ||
      (code >= 0xFE30 && code <= 0xFE4F) || (code >= 0xFF00 && code <= 0xFFEF) ||
      (code >= 0x20000 && code <= 0x2FA1F);
  }

  static isMathSymbolCode(code: number): boolean {
    return (code >= 0x00B2 && code <= 0x00B3) || code === 0x00B9 ||
      (code >= 0x2070 && code <= 0x209F) || (code >= 0x2100 && code <= 0x214F) ||
      (code >= 0x2190 && code <= 0x21FF) || (code >= 0x2200 && code <= 0x22FF) ||
      (code >= 0x2300 && code <= 0x23FF) || (code >= 0x25A0 && code <= 0x25FF) ||
      (code >= 0x27C0 && code <= 0x27FF) || (code >= 0x2900 && code <= 0x297F) ||
      (code >= 0x2A00 && code <= 0x2AFF) || (code >= 0x1D400 && code <= 0x1D7FF);
  }

  // \mathbb 字母 -> Unicode 双线体
  static blackboard(text: string): string {
    let upper: string[] = ['𝔸', '𝔹', 'ℂ', '𝔻', '𝔼', '𝔽', '𝔾', 'ℍ', '𝕀', '𝕁', '𝕂', '𝕃', '𝕄',
      'ℕ', '𝕆', 'ℙ', 'ℚ', 'ℝ', '𝕊', '𝕋', '𝕌', '𝕍', '𝕎', '𝕏', '𝕐', 'ℤ'];
    let lower: string[] = ['𝕒', '𝕓', '𝕔', '𝕕', '𝕖', '𝕗', '𝕘', '𝕙', '𝕚', '𝕛', '𝕜', '𝕝', '𝕞',
      '𝕟', '𝕠', '𝕡', '𝕢', '𝕣', '𝕤', '𝕥', '𝕦', '𝕧', '𝕨', '𝕩', '𝕪', '𝕫'];
    let digits: string[] = ['𝟘', '𝟙', '𝟚', '𝟛', '𝟜', '𝟝', '𝟞', '𝟟', '𝟠', '𝟡'];
    let out: string = '';
    for (let i: number = 0; i < text.length; i++) {
      let c: string = text.charAt(i);
      let code: number = text.charCodeAt(i);
      if (code >= 65 && code <= 90) {
        out += upper[code - 65];
      } else if (code >= 97 && code <= 122) {
        out += lower[code - 97];
      } else if (code >= 48 && code <= 57) {
        out += digits[code - 48];
      } else {
        out += c;
      }
    }
    return out;
  }

  initAndParse(src: string): string {
    this.src = src;
    this.pos = 0;
    return this.parseAll();
  }
}

class CmdResult {
  produced: boolean = false;
}

// \text 内部文本的转义展开: 处理 \~ \& \% 等
function escText(raw: string): string {
  let out: string = '';
  let i: number = 0;
  let len: number = raw.length;
  while (i < len) {
    let c: string = raw.charAt(i);
    if (c === '\\' && i + 1 < len) {
      let n: string = raw.charAt(i + 1);
      if (n === '~' || n === ' ') {
        out += ' ';
      } else if (n === '&') {
        out += '&';
      } else if (n === '%') {
        out += '%';
      } else if (n === '$') {
        out += '$';
      } else if (n === '#') {
        out += '#';
      } else if (n === '_') {
        out += '_';
      } else if (n === '{') {
        out += '{';
      } else if (n === '}') {
        out += '}';
      } else if (n === '\\') {
        out += '\\';
      } else if (n === ',') {
        out += ' ';
      } else {
        out += n;
      }
      i += 2;
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

export class OmmlConverter {
  // 每次生成文档前 beginAudit(), 生成完 takeAudit() 读取未识别命令/结构问题
  static beginAudit(): void {
    LatexAudit.begin();
  }

  static takeAudit(): MathAuditResult {
    return LatexAudit.take();
  }

  // 字体兜底分类(供 DocxBuilder 的普通文本 run 复用同一套字符范围)
  static isCjkCode(code: number): boolean {
    return LatexParser.isCjkCode(code);
  }

  static isMathSymbolCode(code: number): boolean {
    return LatexParser.isMathSymbolCode(code);
  }

  // 行内公式: 返回完整 <m:oMath>...</m:oMath>
  static inline(latex: string): string {
    let p: LatexParser = new LatexParser();
    return '<m:oMath>' + p.initAndParse(latex) + '</m:oMath>';
  }

  // 显示公式: 返回 <m:oMathPara>...</m:oMathPara> (居中)
  static display(latex: string): string {
    let p: LatexParser = new LatexParser();
    return '<m:oMathPara><m:oMathParaPr><m:jc m:val="center"/></m:oMathParaPr>' +
      '<m:oMath>' + p.initAndParse(latex) + '</m:oMath></m:oMathPara>';
  }
}
