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
        let cmdRes: CmdResult = this.parseCommand(parts, stack);
        if (cmdRes.produced) {
          continue;
        }
        // 解析失败(命令为空), 跳过
        continue;
      }
      if (c === '{') {
        this.pos++;
        parts.push(this.parseSegment(true));
        continue;
      }
      if (c === '^' || c === '_') {
        // 基元为空时上下标单独成组(容错)
        parts.push(LatexParser.emptyRun());
        this.pos++;
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
    // 处理未闭合的 \left( ... 栈 (按普通字符回退)
    for (let i: number = stack.length - 1; i >= 0; i--) {
      let marker: DelimMarker = stack[i];
      let fallback: string = marker.beg !== '.' ? LatexParser.run(marker.beg) : '';
      parts.splice(marker.start, parts.length - marker.start, fallback);
    }
    return parts.join('');
  }

  // 解析一个普通原子(单字符/组), 然后附加可能的 ^ 和 _ 后缀, 返回组合后的 OMML
  private parseAtomWithScripts(): string {
    let base: string = this.parseAtom();
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
      return LatexParser.emptyRun();
    }
    if (this.src.charAt(this.pos) === '{') {
      this.pos++;
      let inner: string = this.parseSegment(true);
      if (inner === '') {
        return LatexParser.emptyRun();
      }
      return inner;
    }
    if (this.src.charAt(this.pos) === '^' || this.src.charAt(this.pos) === '_') {
      return LatexParser.emptyRun();
    }
    return this.parseAtom();
  }

  // 解析一个原子(不含上下标): 组 / 命令 / 单字符, 返回 OMML
  private parseAtom(): string {
    let len: number = this.src.length;
    if (this.pos >= len) {
      return LatexParser.emptyRun();
    }
    let c: string = this.src.charAt(this.pos);
    if (c === '{') {
      this.pos++;
      let inner: string = this.parseSegment(true);
      if (inner === '') {
        return LatexParser.emptyRun();
      }
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
          localParts.splice(marker.start, localParts.length - marker.start,
            marker.beg !== '.' ? LatexParser.run(marker.beg) : '');
        }
        return localParts.join('');
      }
      return LatexParser.emptyRun();
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

    // \left / \right 分隔符
    if (name === 'left' || name === 'right') {
      let delim: string = this.readDelimiter();
      if (name === 'left') {
        if (delim !== '.') {
          let marker: DelimMarker = new DelimMarker();
          marker.start = parts.length;
          marker.beg = delim;
          stack.push(marker);
        }
        return;
      }
      // right: 弹栈 wrap
      if (stack.length === 0) {
        if (delim !== '.') {
          parts.push(LatexParser.run(delim));
        }
        return;
      }
      let marker: DelimMarker = stack.pop() as DelimMarker;
      let begVal: string = marker.beg;
      let endVal: string = delim;
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
      if (subXml === '') {
        subXml = LatexParser.emptyRun();
      }
      if (supXml === '') {
        supXml = LatexParser.emptyRun();
      }
      parts.push('<m:nary><m:naryPr><m:chr m:val="' + naryChr + '"/>' +
        '<m:limLoc m:val="' + naryLoc + '"/></m:naryPr><m:sub>' + subXml + '</m:sub>' +
        '<m:sup>' + supXml + '</m:sup><m:e/></m:nary>');
      return;
    }

    // 极限: \lim_{x \to 0}
    if (name === 'lim' || name === 'liminf' || name === 'limsup') {
      let label: string = name === 'liminf' ? 'lim inf' : (name === 'limsup' ? 'lim sup' : 'lim');
      if (this.pos < len && this.src.charAt(this.pos) === '_') {
        this.pos++;
        let sub: string = this.parseScriptArg();
        parts.push('<m:limLow><m:e>' + LatexParser.run(label) + '</m:e><m:lim>' + sub + '</m:lim></m:limLow>');
      } else {
        parts.push(LatexParser.run(label));
      }
      return;
    }

    // 函数名(带自动正体与可选的上下标由外层处理): sin cos tan 等
    if (LatexSymbols.isFunction(name)) {
      parts.push(LatexParser.run(name));
      return;
    }

    // 希腊字母与符号
    let sym: string = LatexSymbols.get(name);
    if (sym !== '') {
      parts.push(LatexParser.run(sym));
      return;
    }

    // \text / \mathrm 等文本模式
    if (name === 'text' || name === 'mathrm' || name === 'operatorname' || name === 'textbf' ||
      name === 'textit' || name === 'textnormal' || name === 'texttt' || name === 'textsc') {
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
    if (name === 'mathbf' || name === 'boldsymbol') {
      let inner: string = this.readGroupOrAtom();
      parts.push('<m:r><m:rPr><m:sty m:val="b"/></m:rPr><m:t xml:space="preserve">' +
        XmlUtil.escape(inner.replace(/<[^>]*>/g, '')) + '</m:t></m:r>');
      return;
    }
    if (name === 'mathit') {
      let inner: string = this.readGroupOrAtom();
      parts.push('<m:r><m:rPr><m:sty m:val="i"/></m:rPr><m:t xml:space="preserve">' +
        XmlUtil.escape(inner.replace(/<[^>]*>/g, '')) + '</m:t></m:r>');
      return;
    }

    // 重音
    let accMap: Map<string, string> = new Map<string, string>();
    accMap.set('hat', '^');
    accMap.set('widehat', '^');
    accMap.set('vec', '→');
    accMap.set('bar', '‾');
    accMap.set('overline', '‾');
    accMap.set('dot', '˙');
    accMap.set('ddot', '̈');
    accMap.set('tilde', '~');
    accMap.set('widetilde', '~');
    accMap.set('check', 'ˇ');
    accMap.set('breve', '˘');
    if (accMap.has(name)) {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:acc><m:accPr><m:chr m:val="' + accMap.get(name) + '"/></m:accPr>' +
        '<m:e>' + content + '</m:e></m:acc>');
      return;
    }

    // 上下划线
    if (name === 'overbrace') {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:bar><m:barPr><m:pos m:val="top"/></m:barPr><m:e>' + content + '</m:e></m:bar>');
      return;
    }
    if (name === 'underbrace' || name === 'underline') {
      let content: string = this.readGroupOrAtom();
      parts.push('<m:under><m:underPr><m:pos m:val="bottom"/></m:underPr><m:e>' + content + '</m:e></m:under>');
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
        name === 'hspace' || name === 'vskip';
      if (takeArgs) {
        this.readGroupOrAtom();
      }
      return;
    }

    // 未知命令: 按原样输出名字
    parts.push(LatexParser.run(name));
  }

  // 解析环境体(矩阵等), 输出到 parts
  private parseEnvironment(env: string, parts: string[]): void {
    let openDelim: string = '';
    let len: number = this.src.length;
    if (env === 'pmatrix') {
      openDelim = '(';
    } else if (env === 'bmatrix') {
      openDelim = '[';
    } else if (env === 'Bmatrix') {
      openDelim = '{';
    } else if (env === 'vmatrix') {
      openDelim = '|';
    } else if (env === 'Vmatrix') {
      openDelim = '‖';
    } else if (env === 'cases') {
      openDelim = '{';
    } else if (env === 'array' || env === 'aligned' || env === 'split' || env === 'matrix' ||
      env === 'smallmatrix' || env === 'gathered' || env === 'alignedat' || env === 'equation' ||
      env === 'equation*' || env === 'displaymath' || env === 'multline' || env === 'gather' ||
      env === 'align' || env === 'align*' || env === 'flalign' || env === 'math') {
      openDelim = '';
    } else {
      // 未知环境: 跳过内容
      let depth: number = 0;
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
        // 跳过行尾的 \cr 或空白
        if (this.src.startsWith('\\cr', this.pos)) {
          this.pos += 3;
        }
        continue;
      }
      if (this.src.charAt(this.pos) === '&') {
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
    // 渲染 <m:m>
    let mXml: string = '<m:m>';
    if (openDelim !== '') {
      mXml += '<m:mPr><m:chr m:val="' + XmlUtil.escapeAttr(openDelim) + '"/></m:mPr>';
    }
    for (let r: number = 0; r < rows.length; r++) {
      mXml += '<m:mr>';
      let row: string[] = rows[r];
      if (row.length === 0) {
        row = [''];
      }
      for (let cIdx: number = 0; cIdx < row.length; cIdx++) {
        let cellXml: string = row[cIdx].trim();
        cellXml = cellXml === '' ? LatexParser.emptyRun() : new LatexParser().initAndParse(cellXml);
        mXml += '<m:e>' + cellXml + '</m:e>';
      }
      mXml += '</m:mr>';
    }
    mXml += '</m:m>';
    // 带定界符的环境包一层 m:d(自动缩放)
    if (openDelim === '{') {
      parts.push(mXml);
    } else if (openDelim !== '') {
      parts.push('<m:d><m:dPr><m:begChr m:val="' + XmlUtil.escapeAttr(openDelim) + '"/>' +
        '<m:endChr m:val="' + XmlUtil.escapeAttr(openDelim) + '"/></m:dPr><m:e>' + mXml + '</m:e></m:d>');
    } else {
      parts.push(mXml);
    }
  }

  // 读取 \begin{env} 之后紧邻的分隔符字符(\left( 等)
  private readDelimiter(): string {
    let len: number = this.src.length;
    if (this.pos >= len) {
      return '.';
    }
    if (this.src.charAt(this.pos) === '\\') {
      this.pos++;
      if (this.pos < len) {
        let c: string = this.src.charAt(this.pos);
        this.pos++;
        if (c === '{') {
          return '{';
        }
        if (c === '}') {
          return '}';
        }
        if (c === '|') {
          return '|';
        }
        if (c === '.') {
          return '.';
        }
        return c;
      }
      return '.';
    }
    let c: string = this.src.charAt(this.pos);
    this.pos++;
    return c;
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
    return '<m:r><m:t xml:space="preserve">' + XmlUtil.escape(text) + '</m:t></m:r>';
  }

  // 空 run(占位)
  static emptyRun(): string {
    return '<m:r><m:t/></m:r>';
  }

  // 空格 run
  static spaceRun(): string {
    return '<m:r><m:t xml:space="preserve"> </m:t></m:r>';
  }

  // 指定字形的 run
  static styledRun(text: string, style: string): string {
    return '<m:r><m:rPr><m:sty m:val="' + style + '"/></m:rPr><m:t xml:space="preserve">' +
      XmlUtil.escape(text) + '</m:t></m:r>';
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
