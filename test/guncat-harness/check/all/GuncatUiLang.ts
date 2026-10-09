// 交互模式 (Intelligent UI) 语言核心 —— guncat-ui lang
//
// 对齐参考项目的 OpenUI Lang: 声明式、按行书写、位置参数、可前向引用(hoisting)。
// 模型输出的是「界面程序」而不是 JSON, 因此:
//   1. 结构先行: `root = Card([...])` 第一行就让外壳出现, 数据随流补齐 → 渐进渲染;
//   2. 截断优雅: 每行是一条独立语句, 输出被截断时已写完的语句全部保留,
//      未写完的那一行只是被丢弃(不会像 JSON 那样整块作废);
//   3. 可交互: `$变量` 是响应式绑定, `Action([@Set(...), @ToAssistant(...)])` 让按钮
//      既能改本地状态(立即重渲染)又能把消息回传给模型(触发新一轮)。
//
// 本文件是纯逻辑模块(无 ArkUI / 无 Kit API), 可被 .ets 与 harness 同时引用。
//
// 语法速览(与参考项目一致):
//   root = Card([header, chart])          语句: 标识符 = 表达式, 换行分隔
//   header = CardHeader("标题", "副标题")  位置参数, 顺序即字段顺序
//   $range = "7d"                          $变量 = 响应式绑定, 可有默认值
//   btn = Button("重算", Action([@Set($range, "30d"), @ToAssistant("换成 30 天")]))
//   Card("文本" + $range)                  表达式: + - * / % == != > < >= <= && || ! ?:
//   数组 [a, b] / 对象 {k: v} / 成员 data.rows / 下标 arr[0] / 三元 cond ? a : b
//   @Count/@Sum/@Avg/@Min/@Max/@Round/@Filter/@Sort/@Each  内置函数
//
// 解析容错(与参考项目对齐 + 本项目的取舍):
//   - 未闭合的括号/字符串会被自动补齐(autoClose), 因此流式中间态也能解析;
//   - 未定义的引用不会让整块失败, 只是该值暂时为 null(等定义流进来再出现);
//   - 组件必需参数缺失或类型不符时**不丢弃组件**, 用安全默认值渲染并在 errors 里记录
//     (聊天场景里"少一个字段"远好于"整块消失")。

// ===== 限额(防畸形程序撑爆渲染) =====
export class UiLimits {
  static readonly MAX_SOURCE: number = 200000;
  static readonly MAX_STATEMENTS: number = 400;
  static readonly MAX_DEPTH: number = 24;
  static readonly MAX_ARRAY: number = 600;
  static readonly MAX_CHILDREN: number = 200;
  static readonly MAX_TEXT: number = 4000;
  static readonly MAX_TITLE: number = 200;
  static readonly MAX_BINDINGS: number = 64;
  static readonly MAX_RENDER_NODES: number = 400;
}

// ===== 词法 =====
export class UiTk {
  static readonly NL: number = 0;
  static readonly LP: number = 1;
  static readonly RP: number = 2;
  static readonly LB: number = 3;
  static readonly RB: number = 4;
  static readonly LC: number = 5;
  static readonly RC: number = 6;
  static readonly COMMA: number = 7;
  static readonly COLON: number = 8;
  static readonly ASSIGN: number = 9;
  static readonly TRUE: number = 10;
  static readonly FALSE: number = 11;
  static readonly NULL: number = 12;
  static readonly EOF: number = 13;
  static readonly STR: number = 14;
  static readonly NUM: number = 15;
  static readonly IDENT: number = 16;
  static readonly COMP: number = 17;
  static readonly STATE: number = 18;
  static readonly DOT: number = 19;
  static readonly PLUS: number = 20;
  static readonly MINUS: number = 21;
  static readonly STAR: number = 22;
  static readonly SLASH: number = 23;
  static readonly PERCENT: number = 24;
  static readonly EQ: number = 25;
  static readonly NEQ: number = 26;
  static readonly GT: number = 27;
  static readonly LT: number = 28;
  static readonly GTE: number = 29;
  static readonly LTE: number = 30;
  static readonly AND: number = 31;
  static readonly OR: number = 32;
  static readonly NOT: number = 33;
  static readonly QUEST: number = 34;
  static readonly AT: number = 35;
}

export class UiToken {
  t: number = UiTk.EOF;
  // 标识符 / 字符串 / $变量 / @动作 的文本值
  s: string = '';
  // 数字字面量的值
  num: number = 0;
  // 该 token 结束处的源码偏移(用于流式语句切分)
  end: number = 0;

  static make(t: number, end: number): UiToken {
    let tok: UiToken = new UiToken();
    tok.t = t;
    tok.end = end;
    return tok;
  }

  static text(t: number, s: string, end: number): UiToken {
    let tok: UiToken = new UiToken();
    tok.t = t;
    tok.s = s;
    tok.end = end;
    return tok;
  }

  static number(v: number, end: number): UiToken {
    let tok: UiToken = new UiToken();
    tok.t = UiTk.NUM;
    tok.num = v;
    tok.end = end;
    return tok;
  }
}

function isDigitCode(code: number): boolean {
  return code >= 48 && code <= 57;
}

function isAlphaCode(code: number): boolean {
  return (code >= 97 && code <= 122) || (code >= 65 && code <= 90) || code === 95;
}

function isWordCode(code: number): boolean {
  return isAlphaCode(code) || isDigitCode(code);
}

// 参考项目令牌类型: 前一个 token 属于「值结束」时不把 '-' 当作负号(而是减号)
function endsValue(t: number): boolean {
  return t === UiTk.NUM || t === UiTk.STR || t === UiTk.TRUE || t === UiTk.FALSE ||
    t === UiTk.NULL || t === UiTk.RP || t === UiTk.RB || t === UiTk.RC ||
    t === UiTk.IDENT || t === UiTk.COMP || t === UiTk.STATE || t === UiTk.AT;
}

export class UiLexer {
  // 把源码切成 token 流(末尾一定带 EOF)
  static lex(src: string): UiToken[] {
    let toks: UiToken[] = [];
    let i: number = 0;
    let n: number = src.length;
    while (i < n) {
      let c: string = src.charAt(i);
      if (c === ' ' || c === '\t' || c === '\r') {
        i++;
        continue;
      }
      if (c === '\n') {
        toks.push(UiToken.make(UiTk.NL, i + 1));
        i++;
        continue;
      }
      if (c === '(') {
        toks.push(UiToken.make(UiTk.LP, i + 1));
        i++;
        continue;
      }
      if (c === ')') {
        toks.push(UiToken.make(UiTk.RP, i + 1));
        i++;
        continue;
      }
      if (c === '[') {
        toks.push(UiToken.make(UiTk.LB, i + 1));
        i++;
        continue;
      }
      if (c === ']') {
        toks.push(UiToken.make(UiTk.RB, i + 1));
        i++;
        continue;
      }
      if (c === '{') {
        toks.push(UiToken.make(UiTk.LC, i + 1));
        i++;
        continue;
      }
      if (c === '}') {
        toks.push(UiToken.make(UiTk.RC, i + 1));
        i++;
        continue;
      }
      if (c === ',') {
        toks.push(UiToken.make(UiTk.COMMA, i + 1));
        i++;
        continue;
      }
      if (c === ':') {
        toks.push(UiToken.make(UiTk.COLON, i + 1));
        i++;
        continue;
      }
      if (c === '=') {
        if (i + 1 < n && src.charAt(i + 1) === '=') {
          toks.push(UiToken.make(UiTk.EQ, i + 2));
          i += 2;
        } else {
          toks.push(UiToken.make(UiTk.ASSIGN, i + 1));
          i++;
        }
        continue;
      }
      if (c === '!') {
        if (i + 1 < n && src.charAt(i + 1) === '=') {
          toks.push(UiToken.make(UiTk.NEQ, i + 2));
          i += 2;
        } else {
          toks.push(UiToken.make(UiTk.NOT, i + 1));
          i++;
        }
        continue;
      }
      if (c === '>') {
        if (i + 1 < n && src.charAt(i + 1) === '=') {
          toks.push(UiToken.make(UiTk.GTE, i + 2));
          i += 2;
        } else {
          toks.push(UiToken.make(UiTk.GT, i + 1));
          i++;
        }
        continue;
      }
      if (c === '<') {
        if (i + 1 < n && src.charAt(i + 1) === '=') {
          toks.push(UiToken.make(UiTk.LTE, i + 2));
          i += 2;
        } else {
          toks.push(UiToken.make(UiTk.LT, i + 1));
          i++;
        }
        continue;
      }
      if (c === '&') {
        if (i + 1 < n && src.charAt(i + 1) === '&') {
          toks.push(UiToken.make(UiTk.AND, i + 2));
          i += 2;
        } else {
          toks.push(UiToken.make(UiTk.AND, i + 1));
          i++;
        }
        continue;
      }
      if (c === '|') {
        if (i + 1 < n && src.charAt(i + 1) === '|') {
          toks.push(UiToken.make(UiTk.OR, i + 2));
          i += 2;
        } else {
          toks.push(UiToken.make(UiTk.OR, i + 1));
          i++;
        }
        continue;
      }
      if (c === '.') {
        toks.push(UiToken.make(UiTk.DOT, i + 1));
        i++;
        continue;
      }
      if (c === '?') {
        toks.push(UiToken.make(UiTk.QUEST, i + 1));
        i++;
        continue;
      }
      if (c === '+') {
        toks.push(UiToken.make(UiTk.PLUS, i + 1));
        i++;
        continue;
      }
      if (c === '*') {
        toks.push(UiToken.make(UiTk.STAR, i + 1));
        i++;
        continue;
      }
      if (c === '/') {
        toks.push(UiToken.make(UiTk.SLASH, i + 1));
        i++;
        continue;
      }
      if (c === '%') {
        toks.push(UiToken.make(UiTk.PERCENT, i + 1));
        i++;
        continue;
      }
      if (c === '"') {
        let start: number = i;
        i++;
        let closed: boolean = false;
        while (i < n) {
          let ch: string = src.charAt(i);
          if (ch === '\\') {
            i += 2;
          } else if (ch === '"') {
            i++;
            closed = true;
            break;
          } else {
            i++;
          }
        }
        let raw: string = src.substring(start, i);
        let value: string = UiLexer.decodeDoubleQuoted(raw, closed);
        toks.push(UiToken.text(UiTk.STR, value, i));
        continue;
      }
      if (c === '\'') {
        i++;
        let out: string = '';
        while (i < n) {
          let ch: string = src.charAt(i);
          if (ch === '\\') {
            i++;
            if (i < n) {
              let esc: string = src.charAt(i);
              if (esc === '\'') {
                out = out + '\'';
              } else if (esc === '\\') {
                out = out + '\\';
              } else if (esc === 'n') {
                out = out + '\n';
              } else if (esc === 't') {
                out = out + '\t';
              } else {
                out = out + esc;
              }
              i++;
            }
          } else if (ch === '\'') {
            i++;
            break;
          } else {
            out = out + ch;
            i++;
          }
        }
        toks.push(UiToken.text(UiTk.STR, out, i));
        continue;
      }
      if (c === '-') {
        let prevT: number = toks.length > 0 ? toks[toks.length - 1].t : UiTk.NL;
        let negNumber: boolean = i + 1 < n && isDigitCode(src.charCodeAt(i + 1));
        if (!(negNumber && !endsValue(prevT))) {
          toks.push(UiToken.make(UiTk.MINUS, i + 1));
          i++;
          continue;
        }
      }
      let code: number = src.charCodeAt(i);
      let negDigit: boolean = c === '-' && i + 1 < n && isDigitCode(src.charCodeAt(i + 1));
      if (isDigitCode(code) || negDigit) {
        let start: number = i;
        if (c === '-') {
          i++;
        }
        while (i < n && isDigitCode(src.charCodeAt(i))) {
          i++;
        }
        if (i < n && src.charAt(i) === '.' && i + 1 < n && isDigitCode(src.charCodeAt(i + 1))) {
          i++;
          while (i < n && isDigitCode(src.charCodeAt(i))) {
            i++;
          }
        }
        if (i < n && (src.charAt(i) === 'e' || src.charAt(i) === 'E')) {
          i++;
          if (i < n && (src.charAt(i) === '+' || src.charAt(i) === '-')) {
            i++;
          }
          while (i < n && isDigitCode(src.charCodeAt(i))) {
            i++;
          }
        }
        let numText: string = src.substring(start, i);
        let parsed: number = parseFloat(numText);
        toks.push(UiToken.number(isNaN(parsed) ? 0 : parsed, i));
        continue;
      }
      if (c === '$' && i + 1 < n && isAlphaCode(src.charCodeAt(i + 1))) {
        let start: number = i;
        i++;
        while (i < n && isWordCode(src.charCodeAt(i))) {
          i++;
        }
        toks.push(UiToken.text(UiTk.STATE, src.substring(start, i), i));
        continue;
      }
      if (isAlphaCode(code)) {
        let start: number = i;
        while (i < n && isWordCode(src.charCodeAt(i))) {
          i++;
        }
        let word: string = src.substring(start, i);
        if (word === 'true') {
          toks.push(UiToken.make(UiTk.TRUE, i));
          continue;
        }
        if (word === 'false') {
          toks.push(UiToken.make(UiTk.FALSE, i));
          continue;
        }
        if (word === 'null') {
          toks.push(UiToken.make(UiTk.NULL, i));
          continue;
        }
        let upper: boolean = code >= 65 && code <= 90;
        toks.push(UiToken.text(upper ? UiTk.COMP : UiTk.IDENT, word, i));
        continue;
      }
      if (c === '@' && i + 1 < n && isAlphaCode(src.charCodeAt(i + 1))) {
        i++;
        let start: number = i;
        while (i < n && isWordCode(src.charCodeAt(i))) {
          i++;
        }
        toks.push(UiToken.text(UiTk.AT, src.substring(start, i), i));
        continue;
      }
      // 未知字符: 跳过(模型偶发写出全角符号时不让整块失败)
      i++;
    }
    toks.push(UiToken.make(UiTk.EOF, n));
    return toks;
  }

  // 双引号字符串: 优先按 JSON 解码(支持 \n \t \" \\ \uXXXX), 失败则退化为剥引号
  private static decodeDoubleQuoted(raw: string, closed: boolean): string {
    let candidate: string = closed ? raw : raw + '"';
    try {
      let parsed: Object = JSON.parse(candidate) as Object;
      if (typeof parsed === 'string') {
        return parsed as string;
      }
    } catch (e) {
      // 落到下面的宽松解码
    }
    let body: string = raw;
    if (body.length > 0 && body.charAt(0) === '"') {
      body = body.substring(1);
    }
    if (body.length > 0 && body.charAt(body.length - 1) === '"') {
      body = body.substring(0, body.length - 1);
    }
    return body;
  }
}

// ===== 语法树 =====
export class UiAst {
  // Str | Num | Bool | Null | Arr | Obj | Comp | Ref | StateRef | BinOp | UnaryOp |
  // Ternary | Member | Index | Assign
  k: string = 'Null';
  s: string = '';
  num: number = 0;
  b: boolean = false;
  items: UiAst[] = [];
  keys: string[] = [];
  vals: UiAst[] = [];
  left: UiAst | null = null;
  right: UiAst | null = null;
  third: UiAst | null = null;

  static of(kind: string): UiAst {
    let node: UiAst = new UiAst();
    node.k = kind;
    return node;
  }

  static str(v: string): UiAst {
    let node: UiAst = UiAst.of('Str');
    node.s = v;
    return node;
  }

  static ref(name: string): UiAst {
    let node: UiAst = UiAst.of('Ref');
    node.s = name;
    return node;
  }

  static state(name: string): UiAst {
    let node: UiAst = UiAst.of('StateRef');
    node.s = name;
    return node;
  }
}

// 解析器: 语句流 → AST(带位置参数映射由 materialize 阶段完成)
export class UiParser {
  private toks: UiToken[] = [];
  private pos: number = 0;
  private depth: number = 0;
  private errors: string[] = [];

  private static readonly PREC_TERNARY: number = 1;
  private static readonly PREC_OR: number = 2;
  private static readonly PREC_AND: number = 3;
  private static readonly PREC_EQ: number = 4;
  private static readonly PREC_CMP: number = 5;
  private static readonly PREC_ADD: number = 6;
  private static readonly PREC_MUL: number = 7;
  private static readonly PREC_UNARY: number = 8;
  private static readonly PREC_MEMBER: number = 9;

  // 解析一段表达式 token 序列(不含尾部 NL / EOF)
  static expression(tokens: UiToken[], errors: string[]): UiAst {
    let p: UiParser = new UiParser();
    p.toks = tokens;
    p.errors = errors;
    p.pos = 0;
    let node: UiAst = p.parseExpr(0);
    return node;
  }

  private cur(): UiToken {
    if (this.pos < this.toks.length) {
      return this.toks[this.pos];
    }
    return UiToken.make(UiTk.EOF, 0);
  }

  private adv(): UiToken {
    let tok: UiToken = this.cur();
    this.pos++;
    return tok;
  }

  private eat(kind: number): void {
    if (this.cur().t === kind) {
      this.pos++;
    }
  }

  private infixPrec(t: number): number {
    if (t === UiTk.QUEST) {
      return UiParser.PREC_TERNARY;
    }
    if (t === UiTk.OR) {
      return UiParser.PREC_OR;
    }
    if (t === UiTk.AND) {
      return UiParser.PREC_AND;
    }
    if (t === UiTk.EQ || t === UiTk.NEQ) {
      return UiParser.PREC_EQ;
    }
    if (t === UiTk.GT || t === UiTk.LT || t === UiTk.GTE || t === UiTk.LTE) {
      return UiParser.PREC_CMP;
    }
    if (t === UiTk.PLUS || t === UiTk.MINUS) {
      return UiParser.PREC_ADD;
    }
    if (t === UiTk.STAR || t === UiTk.SLASH || t === UiTk.PERCENT) {
      return UiParser.PREC_MUL;
    }
    if (t === UiTk.DOT || t === UiTk.LB) {
      return UiParser.PREC_MEMBER;
    }
    return 0;
  }

  private parseExpr(minPrec: number): UiAst {
    let left: UiAst = this.parsePrefix();
    while (this.infixPrec(this.cur().t) > minPrec) {
      left = this.parseInfix(left);
    }
    return left;
  }

  private parsePrefix(): UiAst {
    let tok: UiToken = this.cur();
    if (tok.t === UiTk.STR) {
      this.adv();
      return UiAst.str(tok.s);
    }
    if (tok.t === UiTk.NUM) {
      this.adv();
      let node: UiAst = UiAst.of('Num');
      node.num = tok.num;
      return node;
    }
    if (tok.t === UiTk.TRUE) {
      this.adv();
      let node: UiAst = UiAst.of('Bool');
      node.b = true;
      return node;
    }
    if (tok.t === UiTk.FALSE) {
      this.adv();
      let node: UiAst = UiAst.of('Bool');
      node.b = false;
      return node;
    }
    if (tok.t === UiTk.NULL) {
      this.adv();
      return UiAst.of('Null');
    }
    if (tok.t === UiTk.LB) {
      return this.parseArr();
    }
    if (tok.t === UiTk.LC) {
      return this.parseObj();
    }
    if (tok.t === UiTk.STATE) {
      let name: string = tok.s;
      this.adv();
      if (this.cur().t === UiTk.ASSIGN) {
        this.adv();
        let node: UiAst = UiAst.of('Assign');
        node.s = name;
        node.left = this.parseExpr(0);
        return node;
      }
      return UiAst.state(name);
    }
    if (tok.t === UiTk.COMP || tok.t === UiTk.AT) {
      let next: UiToken = this.pos + 1 < this.toks.length ? this.toks[this.pos + 1] : UiToken.make(UiTk.EOF, 0);
      if (next.t === UiTk.LP) {
        return this.parseComp();
      }
      this.adv();
      return UiAst.ref(tok.s);
    }
    if (tok.t === UiTk.IDENT) {
      // 小写标识符后跟 '(': 内置函数(@Count 已带 @, 这里兼容 Count(...) 写法)
      let next: UiToken = this.pos + 1 < this.toks.length ? this.toks[this.pos + 1] : UiToken.make(UiTk.EOF, 0);
      if (next.t === UiTk.LP) {
        return this.parseComp();
      }
      this.adv();
      return UiAst.ref(tok.s);
    }
    if (tok.t === UiTk.NOT) {
      this.adv();
      let node: UiAst = UiAst.of('UnaryOp');
      node.s = '!';
      node.left = this.parseExpr(UiParser.PREC_UNARY);
      return node;
    }
    if (tok.t === UiTk.MINUS) {
      this.adv();
      let node: UiAst = UiAst.of('UnaryOp');
      node.s = '-';
      node.left = this.parseExpr(UiParser.PREC_UNARY);
      return node;
    }
    if (tok.t === UiTk.LP) {
      this.adv();
      let inner: UiAst = this.parseExpr(0);
      this.eat(UiTk.RP);
      return inner;
    }
    // 无法识别的 token: 前进一格避免死循环
    this.adv();
    return UiAst.of('Null');
  }

  private parseComp(): UiAst {
    let name: string = this.cur().s;
    this.adv();
    let node: UiAst = UiAst.of('Comp');
    node.s = name;
    this.eat(UiTk.LP);
    this.depth++;
    if (this.depth > UiLimits.MAX_DEPTH) {
      this.errors.push('表达式嵌套过深: ' + name);
      this.depth--;
      this.eat(UiTk.RP);
      return node;
    }
    while (this.cur().t !== UiTk.RP && this.cur().t !== UiTk.EOF) {
      let arg: UiAst = this.parseExpr(0);
      if (node.items.length < UiLimits.MAX_ARRAY) {
        node.items.push(arg);
      }
      if (this.cur().t === UiTk.COMMA) {
        this.adv();
      } else if (this.cur().t !== UiTk.RP && this.cur().t !== UiTk.EOF) {
        // 缺逗号: 参考实现会在碰到 ) 时停止; 这里前进一格防止死循环
        this.adv();
      }
    }
    this.eat(UiTk.RP);
    this.depth--;
    return node;
  }

  private parseArr(): UiAst {
    let node: UiAst = UiAst.of('Arr');
    this.eat(UiTk.LB);
    this.depth++;
    while (this.cur().t !== UiTk.RB && this.cur().t !== UiTk.EOF) {
      let item: UiAst = this.parseExpr(0);
      if (node.items.length < UiLimits.MAX_ARRAY) {
        node.items.push(item);
      }
      if (this.cur().t === UiTk.COMMA) {
        this.adv();
      } else if (this.cur().t !== UiTk.RB && this.cur().t !== UiTk.EOF) {
        this.adv();
      }
    }
    this.eat(UiTk.RB);
    this.depth--;
    return node;
  }

  private parseObj(): UiAst {
    let node: UiAst = UiAst.of('Obj');
    this.eat(UiTk.LC);
    this.depth++;
    while (this.cur().t !== UiTk.RC && this.cur().t !== UiTk.EOF) {
      let keyTok: UiToken = this.cur();
      if (keyTok.t !== UiTk.STR && keyTok.t !== UiTk.IDENT && keyTok.t !== UiTk.COMP) {
        this.adv();
        continue;
      }
      this.adv();
      if (this.cur().t === UiTk.COLON) {
        this.adv();
      }
      let value: UiAst = this.parseExpr(0);
      if (node.keys.length < UiLimits.MAX_ARRAY) {
        node.keys.push(keyTok.s);
        node.vals.push(value);
      }
      if (this.cur().t === UiTk.COMMA) {
        this.adv();
      }
    }
    this.eat(UiTk.RC);
    this.depth--;
    return node;
  }

  private parseInfix(left: UiAst): UiAst {
    let tok: UiToken = this.cur();
    if (tok.t === UiTk.DOT) {
      this.adv();
      let field: string = this.cur().s;
      this.adv();
      let node: UiAst = UiAst.of('Member');
      node.left = left;
      node.s = field;
      return node;
    }
    if (tok.t === UiTk.LB) {
      this.adv();
      let index: UiAst = this.parseExpr(0);
      this.eat(UiTk.RB);
      let node: UiAst = UiAst.of('Index');
      node.left = left;
      node.right = index;
      return node;
    }
    if (tok.t === UiTk.QUEST) {
      this.adv();
      let thenNode: UiAst = this.parseExpr(0);
      this.eat(UiTk.COLON);
      let elseNode: UiAst = this.parseExpr(UiParser.PREC_TERNARY - 1);
      let node: UiAst = UiAst.of('Ternary');
      node.left = left;
      node.right = thenNode;
      node.third = elseNode;
      return node;
    }
    this.adv();
    let prec: number = this.infixPrec(tok.t);
    let right: UiAst = this.parseExpr(prec);
    let node: UiAst = UiAst.of('BinOp');
    node.s = UiParser.opText(tok.t);
    node.left = left;
    node.right = right;
    return node;
  }

  private static opText(t: number): string {
    if (t === UiTk.PLUS) {
      return '+';
    }
    if (t === UiTk.MINUS) {
      return '-';
    }
    if (t === UiTk.STAR) {
      return '*';
    }
    if (t === UiTk.SLASH) {
      return '/';
    }
    if (t === UiTk.PERCENT) {
      return '%';
    }
    if (t === UiTk.EQ) {
      return '==';
    }
    if (t === UiTk.NEQ) {
      return '!=';
    }
    if (t === UiTk.GT) {
      return '>';
    }
    if (t === UiTk.LT) {
      return '<';
    }
    if (t === UiTk.GTE) {
      return '>=';
    }
    if (t === UiTk.LTE) {
      return '<=';
    }
    if (t === UiTk.AND) {
      return '&&';
    }
    if (t === UiTk.OR) {
      return '||';
    }
    return '?';
  }
}

// ===== 语句 =====
export class UiStatement {
  id: string = '';
  // 是否为 $变量声明
  isState: boolean = false;
  expr: UiAst = UiAst.of('Null');
  raw: string = '';
}

export class UiSplitResult {
  statements: UiStatement[] = [];
  errors: string[] = [];
  // 末尾是否有「写到一半」的语句(流式中)
  pendingTail: string = '';
  pendingStart: number = 0;
}

export class UiStatements {
  // 把 token 流按「深度 0 的换行」切成语句
  static split(tokens: UiToken[], errors: string[]): UiSplitResult {
    let out: UiSplitResult = new UiSplitResult();
    let pos: number = 0;
    let n: number = tokens.length;
    while (pos < n) {
      while (pos < n && tokens[pos].t === UiTk.NL) {
        pos++;
      }
      if (pos >= n || tokens[pos].t === UiTk.EOF) {
        break;
      }
      let head: UiToken = tokens[pos];
      if (head.t !== UiTk.IDENT && head.t !== UiTk.COMP && head.t !== UiTk.STATE) {
        while (pos < n && tokens[pos].t !== UiTk.NL && tokens[pos].t !== UiTk.EOF) {
          pos++;
        }
        continue;
      }
      let id: string = head.s;
      let isState: boolean = head.t === UiTk.STATE;
      pos++;
      if (pos >= n || tokens[pos].t !== UiTk.ASSIGN) {
        // 不是 "标识符 = ..." 的行: 整行跳过(可能是散文或注释)
        while (pos < n && tokens[pos].t !== UiTk.NL && tokens[pos].t !== UiTk.EOF) {
          pos++;
        }
        continue;
      }
      pos++;
      let exprToks: UiToken[] = [];
      let depth: number = 0;
      let ternary: number = 0;
      while (pos < n && tokens[pos].t !== UiTk.EOF) {
        let tt: number = tokens[pos].t;
        if (tt === UiTk.NL && depth <= 0 && ternary <= 0) {
          let peek: number = pos + 1;
          while (peek < n && tokens[peek].t === UiTk.NL) {
            peek++;
          }
          let nextT: number = peek < n ? tokens[peek].t : UiTk.EOF;
          if (nextT === UiTk.QUEST || (nextT === UiTk.COLON && ternary > 0)) {
            pos++;
            continue;
          }
          break;
        }
        if (tt === UiTk.NL) {
          pos++;
          continue;
        }
        if (tt === UiTk.LP || tt === UiTk.LB || tt === UiTk.LC) {
          depth++;
        } else if ((tt === UiTk.RP || tt === UiTk.RB || tt === UiTk.RC) && depth > 0) {
          depth--;
        } else if (tt === UiTk.QUEST && depth === 0) {
          ternary++;
        } else if (tt === UiTk.COLON && depth === 0 && ternary > 0) {
          ternary--;
        }
        exprToks.push(tokens[pos]);
        pos++;
      }
      if (exprToks.length > 0) {
        let stmt: UiStatement = new UiStatement();
        stmt.id = id;
        stmt.isState = isState;
        stmt.expr = UiParser.expression(exprToks, errors);
        out.statements.push(stmt);
      }
    }
    return out;
  }

  // 源码级语句切分(用于流式增量: 只关心已写完的完整行)
  // 返回: statements=已完整写完的语句文本; pending=末尾未写完的部分
  static splitSource(src: string): UiSplitResult {
    let out: UiSplitResult = new UiSplitResult();
    let errors: string[] = [];
    let depth: number = 0;
    let ternary: number = 0;
    let inStr: string = '';
    let esc: boolean = false;
    let stmtStart: number = 0;
    for (let i: number = 0; i < src.length; i++) {
      let c: string = src.charAt(i);
      if (esc) {
        esc = false;
        continue;
      }
      if (inStr !== '') {
        if (c === '\\') {
          esc = true;
        } else if (c === inStr) {
          inStr = '';
        }
        continue;
      }
      if (c === '"' || c === '\'') {
        inStr = c;
        continue;
      }
      if (c === '(' || c === '[' || c === '{') {
        depth++;
        continue;
      }
      if (c === ')' || c === ']' || c === '}') {
        depth = depth > 0 ? depth - 1 : 0;
        continue;
      }
      if (c === '?' && depth === 0) {
        ternary++;
        continue;
      }
      if (c === ':' && depth === 0 && ternary > 0) {
        ternary--;
        continue;
      }
      if (c === '\n' && depth <= 0 && ternary <= 0) {
        let body: string = src.substring(stmtStart, i);
        UiStatements.appendSource(body, errors, out.statements);
        stmtStart = i + 1;
      }
    }
    out.pendingStart = stmtStart;
    out.pendingTail = src.substring(stmtStart);
    out.errors = errors;
    return out;
  }

  private static appendSource(body: string, errors: string[], out: UiStatement[]): void {
    let trimmed: string = body.trim();
    if (trimmed === '') {
      return;
    }
    let toks: UiToken[] = UiLexer.lex(trimmed);
    let part: UiSplitResult = UiStatements.split(toks, errors);
    for (let i: number = 0; i < part.statements.length; i++) {
      part.statements[i].raw = trimmed;
      out.push(part.statements[i]);
    }
  }
}

// ===== 自动补齐(流式中间态可解析) =====
export class UiAutoClose {
  static readonly RESULT_COMPLETE: number = 0;
  static readonly RESULT_INCOMPLETE: number = 1;

  text: string = '';
  incomplete: boolean = false;

  static run(input: string): UiAutoClose {
    let out: UiAutoClose = new UiAutoClose();
    let stack: string[] = [];
    let inStr: string = '';
    let esc: boolean = false;
    for (let i: number = 0; i < input.length; i++) {
      let c: string = input.charAt(i);
      if (esc) {
        esc = false;
        continue;
      }
      if (inStr !== '') {
        if (c === '\\') {
          esc = true;
        } else if (c === inStr) {
          inStr = '';
        }
        continue;
      }
      if (c === '"' || c === '\'') {
        inStr = c;
        continue;
      }
      if (c === '(' || c === '[' || c === '{') {
        stack.push(c);
        continue;
      }
      if (c === ')' && stack.length > 0 && stack[stack.length - 1] === '(') {
        stack.pop();
        continue;
      }
      if (c === ']' && stack.length > 0 && stack[stack.length - 1] === '[') {
        stack.pop();
        continue;
      }
      if (c === '}' && stack.length > 0 && stack[stack.length - 1] === '{') {
        stack.pop();
        continue;
      }
    }
    if (inStr === '' && stack.length === 0) {
      out.text = input;
      out.incomplete = false;
      return out;
    }
    let text: string = input;
    if (inStr !== '') {
      if (esc) {
        text = text + '\\';
      }
      text = text + inStr;
    }
    for (let j: number = stack.length - 1; j >= 0; j--) {
      let c2: string = stack[j];
      text = text + (c2 === '(' ? ')' : (c2 === '[' ? ']' : '}'));
    }
    out.text = text;
    out.incomplete = true;
    return out;
  }
}

// ===== 预处理: 去注释 =====
export class UiPreprocess {
  // 去掉 // 与 # 行注释(字符串内不处理)
  static stripComments(input: string): string {
    let lines: string[] = input.split('\n');
    let out: string[] = [];
    let inStr: string = '';
    for (let li: number = 0; li < lines.length; li++) {
      let line: string = lines[li];
      let cut: number = -1;
      for (let i: number = 0; i < line.length; i++) {
        let c: string = line.charAt(i);
        if (inStr !== '') {
          if (c === '\\') {
            i++;
          } else if (c === inStr) {
            inStr = '';
          }
          continue;
        }
        if (c === '"' || c === '\'') {
          inStr = c;
          continue;
        }
        if (c === '/' && i + 1 < line.length && line.charAt(i + 1) === '/') {
          cut = i;
          break;
        }
        if (c === '#') {
          cut = i;
          break;
        }
      }
      out.push(cut >= 0 ? line.substring(0, cut).trim() : line);
    }
    return out.join('\n');
  }
}

// ===== 求值结果模型 =====
// 界面元素(渲染器的唯一输入)
export class UiElement {
  type: string = '';
  // 具名属性: string | number | boolean | null | UiElement | Object[] | Record<string,Object>
  props: Record<string, Object> = {};
  // 双向绑定: 属性名 → $变量名(渲染器改动控件时写回该变量并触发重渲染)
  binds: Record<string, string> = {};
  partial: boolean = false;
  statementId: string = '';
  // 渲染顺序中的稳定 key
  key: string = '';
}

export class UiActionStep {
  // toAssistant | openUrl | set | reset
  kind: string = '';
  text: string = '';
  target: string = '';
  value: Object | null = null;
}

export class UiActionPlan {
  steps: UiActionStep[] = [];
}

export class UiProgram {
  root: UiElement | null = null;
  statements: UiStatement[] = [];
  // $变量默认值
  state: Record<string, Object> = {};
  errors: string[] = [];
  unresolved: string[] = [];
  incomplete: boolean = false;
  statementCount: number = 0;
  // 模型是否写出了任何 "标识符 = 表达式" 语句
  hasStatements: boolean = false;
}

// ===== 内置函数 =====
export class UiBuiltins {
  static readonly NAMES: string[] = ['Count', 'Sum', 'Avg', 'Min', 'Max', 'Round', 'Filter',
    'Sort', 'Each', 'Join', 'Len', 'Upper', 'Lower', 'Abs', 'Floor', 'Ceil', 'Pct', 'Coalesce'];

  static isBuiltin(name: string): boolean {
    for (let i: number = 0; i < UiBuiltins.NAMES.length; i++) {
      if (UiBuiltins.NAMES[i] === name) {
        return true;
      }
    }
    return false;
  }

  static signatureList(): string[] {
    return [
      '@Count(arr) — 元素个数',
      '@Sum(arr) / @Avg(arr) / @Min(arr) / @Max(arr) — 数值聚合',
      '@Round(n, digits?) — 四舍五入',
      '@Abs(n) / @Floor(n) / @Ceil(n) — 取整',
      '@Len(s) — 字符串长度',
      '@Join(arr, sep) — 数组拼字符串',
      '@Upper(s) / @Lower(s) — 大小写',
      '@Pct(part, total, digits?) — 百分比数值',
      '@Coalesce(a, b) — a 为空时取 b',
      '@Filter(arr, field, op, value) — 过滤',
      '@Sort(arr, field, desc?) — 排序',
      '@Each(arr, "item", 模板表达式) — 逐项展开(模板里才能用 item)'
    ];
  }
}

// ===== 动作内置 =====
export class UiActions {
  static readonly NAMES: string[] = ['Action', 'ToAssistant', 'OpenUrl', 'Set', 'Reset', 'Run'];

  static isActionName(name: string): boolean {
    for (let i: number = 0; i < UiActions.NAMES.length; i++) {
      if (UiActions.NAMES[i] === name) {
        return true;
      }
    }
    return false;
  }
}

// ===== 解析入口 =====
export class GuncatUiLang {
  static readonly FENCE_LANG: string = 'guncat-ui';
  // 兼容参考项目的围栏语言名
  static readonly FENCE_LANG_ALT: string = 'openui-lang';

  // 完整解析: 已经拿到全部文本(可能因截断而不完整)
  static parse(source: string): UiProgram {
    let program: UiProgram = new UiProgram();
    if (source === null || source === undefined) {
      return program;
    }
    let text: string = source;
    if (text.length > UiLimits.MAX_SOURCE) {
      text = text.substring(0, UiLimits.MAX_SOURCE);
      program.errors.push('界面程序过长, 已截断到 ' + UiLimits.MAX_SOURCE.toString() + ' 字符');
    }
    let cleaned: string = UiPreprocess.stripComments(text).trim();
    if (cleaned === '') {
      return program;
    }
    let closed: UiAutoClose = UiAutoClose.run(cleaned);
    program.incomplete = closed.incomplete;
    let errors: string[] = [];
    let toks: UiToken[] = UiLexer.lex(closed.text);
    let split: UiSplitResult = UiStatements.split(toks, errors);
    if (split.statements.length === 0) {
      program.errors = errors;
      return program;
    }
    let statements: UiStatement[] = [];
    for (let i: number = 0; i < split.statements.length; i++) {
      if (statements.length >= UiLimits.MAX_STATEMENTS) {
        program.errors.push('语句数超过上限, 已忽略其余语句');
        break;
      }
      statements.push(split.statements[i]);
    }
    program.statements = statements;
    program.statementCount = statements.length;
    program.hasStatements = true;
    GuncatUiMaterializer.run(program, errors, null);
    program.errors = errors;
    return program;
  }

  // 用给定的绑定值重新物化(用户改动控件后调用: 表达式里的 $变量要用新值重算)
  static render(program: UiProgram, preset: Record<string, Object> | null): UiElement | null {
    let errors: string[] = [];
    GuncatUiMaterializer.run(program, errors, preset);
    program.errors = errors;
    return program.root;
  }

  // ===== 渲染指纹 =====

  // 元素子树的「渲染指纹」: 只要它变了, 说明这棵子树画出来会不一样。
  // 给渲染层当 ForEach 的键用 —— ArkUI 的 ForEach 对**键值不变**的项直接复用已有子组件
  // (连 item builder 都不会重新执行), 所以"绑定值变了 → 重新物化出新树"必须靠键值变化才能
  // 传到界面。用指纹而不是全局版本号, 是为了让"内容没变"的子项继续复用(不重建), 只有真的会
  // 画出不同结果的项才换键重建。
  //
  // values: 当前绑定值(绑定属性取实时值)。
  //
  // ⚠️ Slider 有**常驻豁免**(见下面循环里的 continue): 它绑定的 value 不参与指纹。理由是真机
  // 反复踩出来的: 指纹是**递归**的, Slider 的 value 一进指纹, 它自己**以及它每一层祖先项**的键
  // 都会随拖动变 → ForEach 重建那些项 → 正在拖的 Slider 被销毁, 手势当场丢失(表现为"只能点一下、
  // 不跟手")。豁免必须是**常驻**的: 若只在拖动期间豁免, 拖动开始那一瞬间键就从"含 value"变成
  // "不含 value", 同样会触发一次重建 —— 键必须与上一次渲染完全一致。
  // (选择类控件不能这么豁免: Chips/单选/多选的选中值不在 props 里, 靠下面的状态值进指纹才能刷新。)
  static elementSignature(el: UiElement | null, values: Record<string, Object>): string {
    if (el === null) {
      return 'nil';
    }
    let acc: number = 5381;
    acc = GuncatUiLang.hashStr(acc, el.type);
    // 属性名排序后遍历, 保证同一棵树每次算出同一个指纹
    let names: string[] = Object.keys(el.props);
    names.sort();
    for (let i: number = 0; i < names.length; i++) {
      let name: string = names[i];
      if (el.type === 'Slider' && UiNode.bindOf(el, name) !== '') {
        continue;
      }
      acc = GuncatUiLang.hashStr(acc, name);
      acc = GuncatUiLang.hashValue(acc, GuncatUiLang.propValue(el, name, values), values);
    }
    // 控件状态键的实时值也要进指纹。
    //   Chips / 单选 / 多选这类"按 name 绑定"的控件, 选中值存在 values[name] 里、**并没有 baked
    //   进 props**, 只看 binds 会让"选中态变化"不进指纹 → 项被复用 → 高亮不刷新(就是当初
    //   "点按钮后 UI 没切换过去"那个真机 bug 复发)。这里就地判断 binds['value'] / props['name'],
    //   不去调 GuncatUiRuntime.stateKeyOf —— 那个文件 import 了本文件, 反向 import 会成环。
    //   Slider 例外(同上): 它的状态值也不进指纹, 否则拖动中祖先项照样会换键重建。
    let stateKey: string = el.type === 'Slider' ? '' : GuncatUiLang.stateKeyOfLocal(el);
    if (stateKey !== '') {
      let live: Object | undefined = values[stateKey];
      if (live !== undefined) {
        acc = GuncatUiLang.hashStr(acc, '~state');
        acc = GuncatUiLang.hashValue(acc, live, values);
      }
    }
    return (acc >>> 0).toString(36);
  }

  // 从 el 出发找到 key 对应元素, 返回**从 el 到它的链**(含两端); 找不到返回空数组。
  static pathToKey(el: UiElement | null, key: string): UiElement[] {
    return GuncatUiLang.pathToMatch(el, key, null);
  }

  // 按**对象身份**找(比按 key 可靠: key 可能是匿名元素的占位值、甚至为空, 也可能在不同列表
  // 里重名)。渲染层拖动时手里拿的就是树里那个实例, 所以身份匹配是首选; 失败再退回 key。
  static pathToElement(el: UiElement | null, target: UiElement | null): UiElement[] {
    if (target === null) {
      return [];
    }
    let byId: UiElement[] = GuncatUiLang.pathToMatch(el, '', target);
    if (byId.length > 0) {
      return byId;
    }
    return GuncatUiLang.pathToMatch(el, target.key, null);
  }

  // 遍历规则(真机踩过: 只认 props 里的 UiElement 和数组是不够的):
  //   UiElement → 递归; 数组 → 逐项看; **普通对象(Record) → 也要进去看** ——
  //   有些参数是把子元素包在对象里(如 {content: [...]}) 的, 漏了这种形状就整条链找不到,
  //   表现为拖动时"冻结快照 0 条"(实时刷新被安全检查挡掉)。
  private static pathToMatch(el: UiElement | null, key: string, target: UiElement | null):
    UiElement[] {
    if (el === null) {
      return [];
    }
    let hit: boolean = target !== null ? el === target : (key !== '' && el.key === key);
    if (hit) {
      return [el];
    }
    let props: Record<string, Object> = el.props;
    let names: string[] = Object.keys(props);
    for (let i: number = 0; i < names.length; i++) {
      let v: Object | undefined = props[names[i]];
      if (v === undefined || v === null) {
        continue;
      }
      let sub: UiElement[] = GuncatUiLang.pathInValue(v, key, target);
      if (sub.length > 0) {
        let out: UiElement[] = [el];
        for (let k: number = 0; k < sub.length; k++) {
          out.push(sub[k]);
        }
        return out;
      }
    }
    return [];
  }

  // 在一个属性值里找(值可能是 UiElement / 数组 / 普通对象)
  private static pathInValue(v: Object, key: string, target: UiElement | null): UiElement[] {
    if (v instanceof UiElement) {
      return GuncatUiLang.pathToMatch(v as UiElement, key, target);
    }
    if (v instanceof Array) {
      let arr: Object[] = v as Object[];
      for (let j: number = 0; j < arr.length; j++) {
        let r: UiElement[] = GuncatUiLang.pathInValue(arr[j], key, target);
        if (r.length > 0) {
          return r;
        }
      }
      return [];
    }
    if (typeof v === 'object') {
      // 普通对象: 只看它自己的值(不递归纯标量); 深度有限, 不会有环
      let rec: Record<string, Object> = v as Record<string, Object>;
      let ks: string[] = Object.keys(rec);
      for (let i: number = 0; i < ks.length; i++) {
        let inner: Object | undefined = rec[ks[i]];
        if (inner === undefined || inner === null || typeof inner !== 'object') {
          continue;
        }
        let r2: UiElement[] = GuncatUiLang.pathInValue(inner, key, target);
        if (r2.length > 0) {
          return r2;
        }
      }
    }
    return [];
  }

  // 属性在指纹里该用的值: 是绑定属性且绑定值存在 → 用**实时值**(表达式重算的依据),
  // 否则用物化时 baked 进 props 的值。
  private static propValue(el: UiElement, name: string, values: Record<string, Object>):
    Object | null {
    let bindName: string = UiNode.bindOf(el, name);
    if (bindName !== '') {
      let live: Object | undefined = values[bindName];
      if (live !== undefined) {
        return live;
      }
    }
    let baked: Object | undefined = el.props[name];
    return baked === undefined ? null : baked;
  }

  // 元素的状态键(与 GuncatUiRuntime.stateKeyOf 同一套规则, 就地实现避免循环依赖)
  private static stateKeyOfLocal(el: UiElement): string {
    let bindName: string = UiNode.bindOf(el, 'value');
    if (bindName !== '') {
      return bindName;
    }
    return UiNode.str(el, 'name', '');
  }

  // djb2 变体: 32 位累加(acc * 33 + x), 用 | 0 截成 int32
  private static hashStr(acc: number, s: string): number {
    let out: number = acc;
    for (let i: number = 0; i < s.length; i++) {
      out = (out * 33 + s.charCodeAt(i)) | 0;
    }
    return out;
  }

  // 值递归进指纹: string 逐字符 / number / boolean / null / 嵌套 UiElement / 数组 / 普通对象
  private static hashValue(acc: number, v: Object | null,
    values: Record<string, Object>): number {
    if (v === null || v === undefined) {
      return GuncatUiLang.hashStr(acc, '~nil');
    }
    if (typeof v === 'string') {
      return GuncatUiLang.hashStr(acc, 's' + (v as string));
    }
    if (typeof v === 'number') {
      return GuncatUiLang.hashStr(acc, 'n' + (v as number).toString());
    }
    if (typeof v === 'boolean') {
      return GuncatUiLang.hashStr(acc, (v as boolean) ? '#t' : '#f');
    }
    if (v instanceof UiElement) {
      return GuncatUiLang.hashStr(acc, GuncatUiLang.elementSignature(v as UiElement, values));
    }
    if (v instanceof Array) {
      let arr: Object[] = v as Object[];
      let out: number = GuncatUiLang.hashStr(acc, '[' + arr.length.toString());
      for (let i: number = 0; i < arr.length; i++) {
        out = GuncatUiLang.hashValue(out, arr[i], values);
      }
      return GuncatUiLang.hashStr(out, ']');
    }
    let obj: Record<string, Object> = v as Record<string, Object>;
    let names: string[] = Object.keys(obj);
    names.sort();
    let out2: number = GuncatUiLang.hashStr(acc, '{');
    for (let i: number = 0; i < names.length; i++) {
      out2 = GuncatUiLang.hashStr(out2, names[i]);
      out2 = GuncatUiLang.hashValue(out2, obj[names[i]], values);
    }
    return GuncatUiLang.hashStr(out2, '}');
  }

  // 判断某段文本是否「像」一份界面程序(用于把非围栏正文识别为界面)
  static looksLikeProgram(text: string): boolean {
    if (text === null || text === undefined || text === '') {
      return false;
    }
    let lines: string[] = text.split('\n');
    let hits: number = 0;
    for (let i: number = 0; i < lines.length && i < 60; i++) {
      let line: string = lines[i].trim();
      if (line === '') {
        continue;
      }
      if (GuncatUiLang.statementLine(line)) {
        hits++;
        if (hits >= 2) {
          return true;
        }
      }
    }
    // 只有一行时, 必须是 root = 才认(避免把 `a = B(...)` 这种巧合当界面)
    if (hits === 1) {
      return GuncatUiLang.hasRootLine(text);
    }
    return false;
  }

  static hasRootLine(text: string): boolean {
    let lines: string[] = text.split('\n');
    for (let i: number = 0; i < lines.length && i < 80; i++) {
      let line: string = lines[i].trim();
      if (line.indexOf('root') === 0 && line.length > 4 && line.charAt(4) === ' ') {
        let eq: number = line.indexOf('=');
        if (eq > 0) {
          return true;
        }
      }
      if (line.indexOf('root=') === 0) {
        return true;
      }
    }
    return false;
  }

  // 单行形如 `name = ComponentName(` 或 `$name = ...`
  private static statementLine(line: string): boolean {
    let eq: number = line.indexOf('=');
    if (eq <= 0) {
      return false;
    }
    let lhs: string = line.substring(0, eq).trim();
    if (lhs === '' || lhs.indexOf(' ') >= 0 || lhs.indexOf('(') >= 0) {
      return false;
    }
    let c0: string = lhs.charAt(0);
    let lhsOk: boolean = (c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || c0 === '_' || c0 === '$';
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
    let m: number = rhs.indexOf('(');
    if (m <= 0) {
      // $var = "7d" 这类绑定声明也算
      return c0 === '$' && (rhs.charAt(0) === '"' || rhs.charAt(0) === '\'' ||
        rhs.charAt(0) === '-' || (rhs.charAt(0) >= '0' && rhs.charAt(0) <= '9') ||
        rhs === 'true' || rhs === 'false' || rhs === 'null');
    }
    let name: string = rhs.substring(0, m);
    if (name === '') {
      return false;
    }
    let first: string = name.charAt(0);
    if (!(first >= 'A' && first <= 'Z')) {
      return false;
    }
    return true;
  }

  // 该文本里是否含有可渲染的界面(根节点存在)
  static hasProgram(source: string): boolean {
    let program: UiProgram = GuncatUiLang.parse(source);
    return program.root !== null;
  }

  // 界面是否「残缺」(没有任何根节点): 需要触发一次重做
  static isDegenerate(source: string): boolean {
    let program: UiProgram = GuncatUiLang.parse(source);
    if (program.root === null) {
      return program.hasStatements;
    }
    return false;
  }

  // 流式中间态: 返回末尾未写完的部分(供"生成中"占位判断)
  static lastPartial(source: string): string {
    let cleaned: string = UiPreprocess.stripComments(source).trim();
    if (cleaned === '') {
      return '';
    }
    let split: UiSplitResult = UiStatements.splitSource(cleaned);
    return split.pendingTail.trim();
  }
}

// ===== 物化(求值): 语句表 → 元素树 =====
export class UiMaterializeContext {
  symbols: Record<string, UiStatement> = {};
  order: string[] = [];
  state: Record<string, Object> = {};
  // @Each 引入的循环变量作用域(只在模板表达式里可见)
  scope: Record<string, Object> = {};
  errors: string[] = [];
  unresolved: string[] = [];
  visiting: string[] = [];
  partial: boolean = false;
  depth: number = 0;
}

export class GuncatUiMaterializer {
  // preset: 用户改过的绑定值(优先级高于语句里写的默认值)
  static run(program: UiProgram, errors: string[], preset: Record<string, Object> | null): void {
    let ctx: UiMaterializeContext = new UiMaterializeContext();
    while (errors.length > 0) {
      errors.pop();
    }
    ctx.errors = errors;
    ctx.partial = program.incomplete;
    for (let i: number = 0; i < program.statements.length; i++) {
      let stmt: UiStatement = program.statements[i];
      if (ctx.symbols[stmt.id] === undefined) {
        ctx.order.push(stmt.id);
      }
      ctx.symbols[stmt.id] = stmt;
    }
    // $变量默认值: 用户改过的值优先
    for (let i: number = 0; i < program.statements.length; i++) {
      let stmt2: UiStatement = program.statements[i];
      if (!stmt2.isState) {
        continue;
      }
      let presetValue: Object | undefined = preset === null ? undefined : preset[stmt2.id];
      if (presetValue !== undefined) {
        ctx.state[stmt2.id] = presetValue;
        continue;
      }
      let value: Object | null = GuncatUiMaterializer.evalValue(stmt2.expr, ctx);
      ctx.state[stmt2.id] = value === null ? ('' as Object) : value;
    }
    // 未被声明但被引用到的 $变量: 自动补空值
    GuncatUiMaterializer.autoDeclareStates(program, ctx);
    // 入口: 优先 root, 其次第一个组件语句
    let entry: string = '';
    if (ctx.symbols['root'] !== undefined) {
      entry = 'root';
    } else {
      for (let i: number = 0; i < ctx.order.length; i++) {
        let st: UiStatement | undefined = ctx.symbols[ctx.order[i]];
        if (st !== undefined && !st.isState) {
          entry = ctx.order[i];
          break;
        }
      }
    }
    program.state = ctx.state;
    if (entry === '') {
      program.root = null;
      return;
    }
    let rootStmt: UiStatement | undefined = ctx.symbols[entry];
    if (rootStmt === undefined) {
      program.root = null;
      return;
    }
    let value: Object | null = GuncatUiMaterializer.evalValue(rootStmt.expr, ctx);
    let element: UiElement | null = GuncatUiMaterializer.asElement(value);
    if (element !== null) {
      element.statementId = entry;
      GuncatUiMaterializer.assignKeys(element, 'r');
      program.root = element;
    } else {
      program.root = null;
    }
    program.state = ctx.state;
  }

  private static autoDeclareStates(program: UiProgram, ctx: UiMaterializeContext): void {
    let referenced: string[] = [];
    for (let i: number = 0; i < program.statements.length; i++) {
      GuncatUiMaterializer.collectStates(program.statements[i].expr, referenced);
    }
    for (let i: number = 0; i < referenced.length; i++) {
      let name: string = referenced[i];
      if (ctx.state[name] === undefined) {
        ctx.state[name] = '' as Object;
      }
    }
  }

  private static collectStates(node: UiAst, out: string[]): void {
    if (node.k === 'StateRef' || node.k === 'Assign') {
      if (GuncatUiMaterializer.indexOfString(out, node.s) < 0) {
        out.push(node.s);
      }
    }
    for (let i: number = 0; i < node.items.length; i++) {
      GuncatUiMaterializer.collectStates(node.items[i], out);
    }
    for (let i: number = 0; i < node.vals.length; i++) {
      GuncatUiMaterializer.collectStates(node.vals[i], out);
    }
    if (node.left !== null) {
      GuncatUiMaterializer.collectStates(node.left, out);
    }
    if (node.right !== null) {
      GuncatUiMaterializer.collectStates(node.right, out);
    }
    if (node.third !== null) {
      GuncatUiMaterializer.collectStates(node.third, out);
    }
  }

  private static indexOfString(list: string[], value: string): number {
    for (let i: number = 0; i < list.length; i++) {
      if (list[i] === value) {
        return i;
      }
    }
    return -1;
  }

  // 求值: 任何 AST → 运行时值
  static evalValue(node: UiAst, ctx: UiMaterializeContext): Object | null {
    if (node === null) {
      return null;
    }
    let k: string = node.k;
    if (k === 'Str') {
      return node.s;
    }
    if (k === 'Num') {
      return node.num;
    }
    if (k === 'Bool') {
      return node.b;
    }
    if (k === 'Null') {
      return null;
    }
    if (k === 'Ref') {
      return GuncatUiMaterializer.resolveRef(node.s, ctx);
    }
    if (k === 'StateRef') {
      let v: Object | undefined = ctx.state[node.s];
      return v === undefined ? null : v;
    }
    if (k === 'Assign') {
      // $x = value 出现在表达式里: 求值并写入状态
      let value: Object | null = GuncatUiMaterializer.evalValue(node.left, ctx);
      ctx.state[node.s] = value === null ? ('' as Object) : value;
      return value;
    }
    if (k === 'Arr') {
      let out: Object[] = [];
      for (let i: number = 0; i < node.items.length; i++) {
        let item: UiAst = node.items[i];
        let value: Object | null = GuncatUiMaterializer.evalValue(item, ctx);
        if (value === null && (item.k === 'Comp' || item.k === 'Ref')) {
          continue;
        }
        if (value === null && item.k === 'Null') {
          out.push(null as Object);
          continue;
        }
        if (value !== null) {
          out.push(value);
        }
      }
      return out as Object;
    }
    if (k === 'Obj') {
      let obj: Record<string, Object> = {};
      for (let i: number = 0; i < node.keys.length; i++) {
        let value: Object | null = GuncatUiMaterializer.evalValue(node.vals[i], ctx);
        obj[node.keys[i]] = value === null ? (null as Object) : value;
      }
      return obj as Object;
    }
    if (k === 'Comp') {
      return GuncatUiMaterializer.evalComp(node, ctx);
    }
    if (k === 'BinOp') {
      if (node.s === '&&') {
        let left: Object | null = GuncatUiMaterializer.evalValue(node.left, ctx);
        if (!GuncatUiMaterializer.truthy(left)) {
          return left;
        }
        return GuncatUiMaterializer.evalValue(node.right, ctx);
      }
      if (node.s === '||') {
        let left2: Object | null = GuncatUiMaterializer.evalValue(node.left, ctx);
        if (GuncatUiMaterializer.truthy(left2)) {
          return left2;
        }
        return GuncatUiMaterializer.evalValue(node.right, ctx);
      }
      let l: Object | null = GuncatUiMaterializer.evalValue(node.left, ctx);
      let r: Object | null = GuncatUiMaterializer.evalValue(node.right, ctx);
      return GuncatUiMaterializer.binary(node.s, l, r);
    }
    if (k === 'UnaryOp') {
      let v: Object | null = GuncatUiMaterializer.evalValue(node.left, ctx);
      if (node.s === '!') {
        return !GuncatUiMaterializer.truthy(v);
      }
      return -GuncatUiMaterializer.toNum(v);
    }
    if (k === 'Ternary') {
      let cond: Object | null = GuncatUiMaterializer.evalValue(node.left, ctx);
      if (GuncatUiMaterializer.truthy(cond)) {
        return GuncatUiMaterializer.evalValue(node.right, ctx);
      }
      return GuncatUiMaterializer.evalValue(node.third, ctx);
    }
    if (k === 'Member') {
      let obj: Object | null = GuncatUiMaterializer.evalValue(node.left, ctx);
      return GuncatUiMaterializer.member(obj, node.s);
    }
    if (k === 'Index') {
      let obj2: Object | null = GuncatUiMaterializer.evalValue(node.left, ctx);
      let idx: Object | null = GuncatUiMaterializer.evalValue(node.right, ctx);
      return GuncatUiMaterializer.index(obj2, idx);
    }
    return null;
  }

  private static binary(op: string, l: Object | null, r: Object | null): Object | null {
    if (op === '+') {
      if (typeof l === 'string' || typeof r === 'string') {
        return GuncatUiMaterializer.toStr(l) + GuncatUiMaterializer.toStr(r);
      }
      return GuncatUiMaterializer.toNum(l) + GuncatUiMaterializer.toNum(r);
    }
    if (op === '-') {
      return GuncatUiMaterializer.toNum(l) - GuncatUiMaterializer.toNum(r);
    }
    if (op === '*') {
      return GuncatUiMaterializer.toNum(l) * GuncatUiMaterializer.toNum(r);
    }
    if (op === '/') {
      let d: number = GuncatUiMaterializer.toNum(r);
      return d === 0 ? 0 : GuncatUiMaterializer.toNum(l) / d;
    }
    if (op === '%') {
      let d2: number = GuncatUiMaterializer.toNum(r);
      return d2 === 0 ? 0 : GuncatUiMaterializer.toNum(l) % d2;
    }
    if (op === '==') {
      return GuncatUiMaterializer.toStr(l) === GuncatUiMaterializer.toStr(r);
    }
    if (op === '!=') {
      return GuncatUiMaterializer.toStr(l) !== GuncatUiMaterializer.toStr(r);
    }
    if (op === '>') {
      return GuncatUiMaterializer.toNum(l) > GuncatUiMaterializer.toNum(r);
    }
    if (op === '<') {
      return GuncatUiMaterializer.toNum(l) < GuncatUiMaterializer.toNum(r);
    }
    if (op === '>=') {
      return GuncatUiMaterializer.toNum(l) >= GuncatUiMaterializer.toNum(r);
    }
    if (op === '<=') {
      return GuncatUiMaterializer.toNum(l) <= GuncatUiMaterializer.toNum(r);
    }
    return null;
  }

  private static resolveRef(name: string, ctx: UiMaterializeContext): Object | null {
    // @Each 的循环变量优先
    let scoped: Object | undefined = ctx.scope[name];
    if (scoped !== undefined) {
      return scoped;
    }
    if (GuncatUiMaterializer.indexOfString(ctx.visiting, name) >= 0) {
      if (GuncatUiMaterializer.indexOfString(ctx.unresolved, name) < 0) {
        ctx.unresolved.push(name);
      }
      return null;
    }
    let stmt: UiStatement | undefined = ctx.symbols[name];
    if (stmt === undefined) {
      if (GuncatUiMaterializer.indexOfString(ctx.unresolved, name) < 0) {
        ctx.unresolved.push(name);
      }
      return null;
    }
    ctx.visiting.push(name);
    if (ctx.depth > UiLimits.MAX_DEPTH) {
      ctx.visiting.pop();
      return null;
    }
    ctx.depth++;
    let value: Object | null = GuncatUiMaterializer.evalValue(stmt.expr, ctx);
    ctx.depth--;
    ctx.visiting.pop();
    let element: UiElement | null = GuncatUiMaterializer.asElement(value);
    if (element !== null) {
      element.statementId = name;
      if (element.key === '') {
        element.key = name;
      }
    }
    return value;
  }

  private static evalComp(node: UiAst, ctx: UiMaterializeContext): Object | null {
    let name: string = node.s;
    if (name === 'Each') {
      return GuncatUiMaterializer.evalEach(node, ctx);
    }
    if (UiActions.isActionName(name)) {
      return GuncatUiMaterializer.evalActionBuiltin(name, node.items, ctx);
    }
    if (UiBuiltins.isBuiltin(name)) {
      let args: Object[] = [];
      for (let i: number = 0; i < node.items.length; i++) {
        let v: Object | null = GuncatUiMaterializer.evalValue(node.items[i], ctx);
        args.push(v === null ? (null as Object) : v);
      }
      return UiBuiltinFns.call(name, args);
    }
    // 普通组件: 位置参数 → 具名属性
    if (!UiRegistry.isEmpty() && !UiRegistry.has(name)) {
      // 未登记组件一律丢弃(对齐参考项目): 保留会渲染成莫名的空卡片, 反而更难排查
      ctx.errors.push('未知组件 ' + name + ', 已忽略');
      return null;
    }
    return GuncatUiMaterializer.mapComponent(name, node.items, ctx);
  }

  // @Each(arr, "item", 模板) —— 逐项展开成元素数组。
  // 循环变量只在模板表达式里可见, 通过 ctx.scope 注入; 嵌套 @Each 时内层覆盖外层。
  private static evalEach(node: UiAst, ctx: UiMaterializeContext): Object | null {
    if (node.items.length < 3) {
      return null;
    }
    let listValue: Object | null = GuncatUiMaterializer.evalValue(node.items[0], ctx);
    if (listValue === null || !(listValue instanceof Array)) {
      return null;
    }
    let varNode: UiAst = node.items[1];
    let varName: string = varNode.k === 'Str' ? varNode.s : (varNode.k === 'Ref' ? varNode.s : '');
    if (varName === '') {
      return null;
    }
    let template: UiAst = node.items[2];
    let arr: Object[] = listValue as Object[];
    let out: Object[] = [];
    let hadScope: boolean = ctx.scope[varName] !== undefined;
    let savedScope: Object | undefined = ctx.scope[varName];
    for (let i: number = 0; i < arr.length && i < UiLimits.MAX_ARRAY; i++) {
      ctx.scope[varName] = arr[i];
      let item: Object | null = GuncatUiMaterializer.evalValue(template, ctx);
      if (item === null) {
        continue;
      }
      if (item instanceof Array) {
        let inner: Object[] = item as Object[];
        for (let j: number = 0; j < inner.length; j++) {
          out.push(inner[j]);
        }
      } else {
        out.push(item);
      }
    }
    if (hadScope) {
      ctx.scope[varName] = savedScope === undefined ? (null as Object) : savedScope;
    } else {
      delete ctx.scope[varName];
    }
    return out as Object;
  }

  private static mapComponent(name: string, args: UiAst[], ctx: UiMaterializeContext): UiElement {
    let el: UiElement = new UiElement();
    el.type = name;
    el.partial = ctx.partial;
    let params: UiParam[] = UiRegistry.params(name);
    let used: string[] = [];
    for (let i: number = 0; i < params.length && i < args.length; i++) {
      let param: UiParam = params[i];
      // 双向绑定参数: 需要变量名本身(而不是它的当前值), 因此直接读 AST
      if (param.type === 'binding') {
        let node: UiAst = args[i];
        if (node.k === 'StateRef') {
          el.binds[param.name] = node.s;
          let cur: Object | undefined = ctx.state[node.s];
          el.props[param.name] = cur === undefined ? ('' as Object) : cur;
        } else if (node.k === 'Assign') {
          el.binds[param.name] = node.s;
          ctx.state[node.s] = ('' as Object);
          el.props[param.name] = '' as Object;
        } else {
          let raw: Object | null = GuncatUiMaterializer.evalValue(node, ctx);
          el.props[param.name] = raw === null ? ('' as Object) : raw;
        }
        used.push(param.name);
        continue;
      }
      let raw: Object | null = GuncatUiMaterializer.evalValue(args[i], ctx);
      el.props[param.name] = GuncatUiCoerce.apply(param, raw, name, ctx.errors);
      used.push(param.name);
    }
    if (params.length === 0 && args.length > 0) {
      // 未登记组件: 把参数按 arg0..argN 保留, 渲染器可做通用兜底
      for (let i: number = 0; i < args.length; i++) {
        let raw2: Object | null = GuncatUiMaterializer.evalValue(args[i], ctx);
        el.props['arg' + i.toString()] = raw2 === null ? (null as Object) : raw2;
      }
    }
    // 展开变参: children / items 允许传数组
    GuncatUiMaterializer.applyDefaults(el, params, used, ctx);
    return el;
  }

  private static applyDefaults(el: UiElement, params: UiParam[], used: string[], ctx: UiMaterializeContext): void {
    for (let i: number = 0; i < params.length; i++) {
      let param: UiParam = params[i];
      if (GuncatUiMaterializer.indexOfString(used, param.name) >= 0) {
        continue;
      }
      if (!param.required) {
        continue;
      }
      ctx.errors.push(el.type + ' 缺少参数 ' + param.name + ', 已用默认值渲染');
      el.props[param.name] = GuncatUiCoerce.defaultOf(param);
    }
  }

  private static evalActionBuiltin(name: string, args: UiAst[], ctx: UiMaterializeContext): Object | null {
    if (name === 'Action') {
      let plan: UiActionPlan = new UiActionPlan();
      if (args.length > 0 && (args[0].k === 'Arr' || args[0].k === 'Str')) {
        let items: UiAst[] = args[0].k === 'Arr' ? args[0].items : args;
        for (let i: number = 0; i < items.length; i++) {
          let step: Object | null = GuncatUiMaterializer.evalValue(items[i], ctx);
          let s: UiActionStep | null = GuncatUiMaterializer.asStep(step);
          if (s !== null) {
            plan.steps.push(s);
          }
        }
      }
      return plan as Object;
    }
    let step: UiActionStep = new UiActionStep();
    if (name === 'ToAssistant') {
      step.kind = 'toAssistant';
      step.text = args.length > 0 ? GuncatUiMaterializer.toStr(GuncatUiMaterializer.evalValue(args[0], ctx)) : '';
      return step as Object;
    }
    if (name === 'OpenUrl') {
      step.kind = 'openUrl';
      step.text = args.length > 0 ? GuncatUiMaterializer.toStr(GuncatUiMaterializer.evalValue(args[0], ctx)) : '';
      return step as Object;
    }
    if (name === 'Set') {
      step.kind = 'set';
      // 参考实现: @Set($var, value) — $var 是 StateRef, 求值时取的是「当前值」,
      // 这里需要的是变量名本身, 所以直接读 AST。
      if (args.length > 0 && (args[0].k === 'StateRef' || args[0].k === 'Str' || args[0].k === 'Ref')) {
        step.target = args[0].s;
      }
      step.value = args.length > 1 ? GuncatUiMaterializer.evalValue(args[1], ctx) : null;
      return step as Object;
    }
    if (name === 'Reset') {
      let plan: UiActionPlan = new UiActionPlan();
      for (let i: number = 0; i < args.length; i++) {
        let one: UiActionStep = new UiActionStep();
        one.kind = 'reset';
        if (args[i].k === 'StateRef' || args[i].k === 'Str' || args[i].k === 'Ref') {
          one.target = args[i].s;
        }
        plan.steps.push(one);
      }
      return plan as Object;
    }
    if (name === 'Run') {
      step.kind = 'run';
      step.text = args.length > 0 ? GuncatUiMaterializer.toStr(GuncatUiMaterializer.evalValue(args[0], ctx)) : '';
      return step as Object;
    }
    return null;
  }

  private static asStep(value: Object | null): UiActionStep | null {
    if (value === null) {
      return null;
    }
    if (value instanceof UiActionStep) {
      return value as UiActionStep;
    }
    if (value instanceof UiActionPlan) {
      let plan: UiActionPlan = value as UiActionPlan;
      if (plan.steps.length > 0) {
        return plan.steps[0];
      }
      return null;
    }
    return null;
  }

  private static asElement(value: Object | null): UiElement | null {
    if (value === null) {
      return null;
    }
    if (value instanceof UiElement) {
      return value as UiElement;
    }
    return null;
  }

  // 为元素树分配稳定 key(渲染层 ForEach 依赖)
  //
  // ⚠️ 真机踩过的坑: 这里必须覆盖**所有**装着子元素的属性形状, 漏一种就会出现一批 key 为空的
  // 元素。渲染层的 live(el)(按 key 从当前树里取新元素)对空 key 只能放弃查找、退回过期对象,
  // 于是那些节点永远显示旧值 —— 症状就是"绑定的值怎么都不刷新"。
  // 三种形状: ① children 列表; ② 元素数组属性(items/series/columns/sections...);
  //          ③ **单元素属性**(如 OverviewCardItem(top, bottom) 的 top/bottom、FormControl 的
  //          control)—— 第三种原先没遍历, 正是空 key 的来源。
  private static assignKeys(el: UiElement, prefix: string): void {
    if (el.key === '') {
      el.key = prefix;
    }
    let children: UiElement[] = GuncatUiMaterializer.childElements(el);
    for (let i: number = 0; i < children.length; i++) {
      if (children[i].key === '') {
        children[i].key = prefix + '_' + i.toString();
      }
      GuncatUiMaterializer.assignKeys(children[i], children[i].key);
    }
    // 元素类型的属性: 数组 → 逐项; 单个元素 → 直接递归
    let keys: string[] = GuncatUiMaterializer.propNames(el);
    for (let i: number = 0; i < keys.length; i++) {
      let value: Object | undefined = el.props[keys[i]];
      if (value instanceof Array) {
        let arr: Object[] = value as Object[];
        for (let j: number = 0; j < arr.length; j++) {
          let child: UiElement | null = GuncatUiMaterializer.asElement(arr[j]);
          if (child !== null) {
            if (child.key === '') {
              child.key = el.key + '_' + keys[i] + '_' + j.toString();
            }
            GuncatUiMaterializer.assignKeys(child, child.key);
          }
        }
      } else {
        let single: UiElement | null = GuncatUiMaterializer.asElement(value);
        if (single !== null) {
          if (single.key === '') {
            single.key = el.key + '_' + keys[i];
          }
          GuncatUiMaterializer.assignKeys(single, single.key);
        }
      }
    }
  }

  static propNames(el: UiElement): string[] {
    let names: string[] = [];
    let keys: string[] = Object.keys(el.props);
    for (let i: number = 0; i < keys.length; i++) {
      names.push(keys[i]);
    }
    return names;
  }

  // 元素的「子元素」: 容器类组件的 children 属性
  static childElements(el: UiElement): UiElement[] {
    let out: UiElement[] = [];
    let value: Object | undefined = el.props['children'];
    if (value === undefined || !(value instanceof Array)) {
      return out;
    }
    let arr: Object[] = value as Object[];
    for (let i: number = 0; i < arr.length; i++) {
      let child: UiElement | null = GuncatUiMaterializer.asElement(arr[i]);
      if (child !== null) {
        out.push(child);
      }
    }
    return out;
  }

  static truthy(value: Object | null): boolean {
    if (value === null || value === undefined) {
      return false;
    }
    if (typeof value === 'boolean') {
      return value as boolean;
    }
    if (typeof value === 'number') {
      return (value as number) !== 0;
    }
    if (typeof value === 'string') {
      return (value as string) !== '';
    }
    return true;
  }

  static toStr(value: Object | null): string {
    if (value === null || value === undefined) {
      return '';
    }
    if (typeof value === 'string') {
      return value as string;
    }
    if (typeof value === 'number') {
      return GuncatUiMaterializer.numText(value as number);
    }
    if (typeof value === 'boolean') {
      return (value as boolean) ? 'true' : 'false';
    }
    if (value instanceof Array) {
      let arr: Object[] = value as Object[];
      let parts: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        parts.push(GuncatUiMaterializer.toStr(arr[i]));
      }
      return parts.join(', ');
    }
    return String(value);
  }

  static numText(n: number): string {
    if (isNaN(n) || !isFinite(n)) {
      return '0';
    }
    let rounded: number = Math.round(n * 1000000) / 1000000;
    return String(rounded);
  }

  static toNum(value: Object | null): number {
    if (value === null || value === undefined) {
      return 0;
    }
    if (typeof value === 'number') {
      return value as number;
    }
    if (typeof value === 'boolean') {
      return (value as boolean) ? 1 : 0;
    }
    if (typeof value === 'string') {
      let s: string = (value as string).trim();
      if (s === '') {
        return 0;
      }
      let n: number = parseFloat(s);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }

  private static member(obj: Object | null, field: string): Object | null {
    if (obj === null || obj === undefined) {
      return null;
    }
    if (obj instanceof Array) {
      let arr: Object[] = obj as Object[];
      if (field === 'length' || field === 'count') {
        return arr.length;
      }
      let out: Object[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        out.push(GuncatUiMaterializer.member(arr[i], field));
      }
      return out as Object;
    }
    if (field === 'length') {
      if (typeof obj === 'string') {
        return (obj as string).length;
      }
    }
    if (typeof obj === 'object') {
      let rec: Record<string, Object> = obj as Record<string, Object>;
      let v: Object | undefined = rec[field];
      return v === undefined ? null : v;
    }
    return null;
  }

  private static index(obj: Object | null, idx: Object | null): Object | null {
    if (obj === null || idx === null) {
      return null;
    }
    if (obj instanceof Array) {
      let arr: Object[] = obj as Object[];
      let i: number = Math.floor(GuncatUiMaterializer.toNum(idx));
      if (i < 0 || i >= arr.length) {
        return null;
      }
      return arr[i];
    }
    if (typeof obj === 'object') {
      let rec: Record<string, Object> = obj as Record<string, Object>;
      let key: string = GuncatUiMaterializer.toStr(idx);
      let v: Object | undefined = rec[key];
      return v === undefined ? null : v;
    }
    return null;
  }
}

// ===== 内置函数实现 =====
export class UiBuiltinFns {
  static call(name: string, args: Object[]): Object | null {
    if (name === 'Count') {
      return UiBuiltinFns.arrLen(UiBuiltinFns.arg(args, 0));
    }
    if (name === 'Len') {
      let v: Object | null = UiBuiltinFns.arg(args, 0);
      if (v instanceof Array) {
        return (v as Object[]).length;
      }
      return GuncatUiMaterializer.toStr(v).length;
    }
    if (name === 'Sum' || name === 'Avg' || name === 'Min' || name === 'Max') {
      return UiBuiltinFns.aggregate(name, UiBuiltinFns.arg(args, 0));
    }
    if (name === 'Round') {
      let n: number = GuncatUiMaterializer.toNum(UiBuiltinFns.arg(args, 0));
      let digits: number = args.length > 1 ? Math.floor(GuncatUiMaterializer.toNum(args[1])) : 0;
      let factor: number = Math.pow(10, digits);
      return Math.round(n * factor) / factor;
    }
    if (name === 'Abs') {
      return Math.abs(GuncatUiMaterializer.toNum(UiBuiltinFns.arg(args, 0)));
    }
    if (name === 'Floor') {
      return Math.floor(GuncatUiMaterializer.toNum(UiBuiltinFns.arg(args, 0)));
    }
    if (name === 'Ceil') {
      return Math.ceil(GuncatUiMaterializer.toNum(UiBuiltinFns.arg(args, 0)));
    }
    if (name === 'Upper') {
      return GuncatUiMaterializer.toStr(UiBuiltinFns.arg(args, 0)).toUpperCase();
    }
    if (name === 'Lower') {
      return GuncatUiMaterializer.toStr(UiBuiltinFns.arg(args, 0)).toLowerCase();
    }
    if (name === 'Join') {
      let v: Object | null = UiBuiltinFns.arg(args, 0);
      let sep: string = args.length > 1 ? GuncatUiMaterializer.toStr(args[1]) : ', ';
      if (!(v instanceof Array)) {
        return GuncatUiMaterializer.toStr(v);
      }
      let arr: Object[] = v as Object[];
      let parts: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        parts.push(GuncatUiMaterializer.toStr(arr[i]));
      }
      return parts.join(sep);
    }
    if (name === 'Pct') {
      let part: number = GuncatUiMaterializer.toNum(UiBuiltinFns.arg(args, 0));
      let total: number = GuncatUiMaterializer.toNum(UiBuiltinFns.arg(args, 1));
      let digits: number = args.length > 2 ? Math.floor(GuncatUiMaterializer.toNum(args[2])) : 1;
      if (total === 0) {
        return 0;
      }
      let factor: number = Math.pow(10, digits);
      return Math.round((part / total) * 100 * factor) / factor;
    }
    if (name === 'Coalesce') {
      for (let i: number = 0; i < args.length; i++) {
        let v: Object | null = args[i];
        if (v === null || v === undefined || v === '') {
          continue;
        }
        return v;
      }
      return null;
    }
    if (name === 'Filter') {
      return UiBuiltinFns.filter(args);
    }
    if (name === 'Sort') {
      return UiBuiltinFns.sort(args);
    }
    if (name === 'Each') {
      // @Each 在物化阶段需要保留模板, 这里退化为「逐项取字段」的宽松语义
      return UiBuiltinFns.arg(args, 0);
    }
    return null;
  }

  private static arg(args: Object[], i: number): Object | null {
    return i < args.length ? args[i] : null;
  }

  private static arrLen(v: Object | null): number {
    if (v instanceof Array) {
      return (v as Object[]).length;
    }
    if (v === null || v === undefined) {
      return 0;
    }
    return 1;
  }

  private static aggregate(name: string, v: Object | null): number {
    let nums: number[] = [];
    if (v instanceof Array) {
      let arr: Object[] = v as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        let n: number = GuncatUiMaterializer.toNum(arr[i]);
        nums.push(n);
      }
    } else {
      nums.push(GuncatUiMaterializer.toNum(v));
    }
    if (nums.length === 0) {
      return 0;
    }
    let sum: number = 0;
    let min: number = nums[0];
    let max: number = nums[0];
    for (let i: number = 0; i < nums.length; i++) {
      sum += nums[i];
      if (nums[i] < min) {
        min = nums[i];
      }
      if (nums[i] > max) {
        max = nums[i];
      }
    }
    if (name === 'Sum') {
      return sum;
    }
    if (name === 'Avg') {
      return sum / nums.length;
    }
    if (name === 'Min') {
      return min;
    }
    return max;
  }

  private static filter(args: Object[]): Object {
    let v: Object | null = UiBuiltinFns.arg(args, 0);
    let field: string = GuncatUiMaterializer.toStr(UiBuiltinFns.arg(args, 1));
    let op: string = GuncatUiMaterializer.toStr(UiBuiltinFns.arg(args, 2));
    let target: Object | null = UiBuiltinFns.arg(args, 3);
    let out: Object[] = [];
    if (!(v instanceof Array)) {
      return out;
    }
    let arr: Object[] = v as Object[];
    for (let i: number = 0; i < arr.length; i++) {
      let row: Object | null = arr[i];
      let cell: Object | null = field === '' ? row : UiBuiltinFns.fieldOf(row, field);
      if (UiBuiltinFns.compare(cell, op, target)) {
        out.push(row === null ? (null as Object) : row);
      }
    }
    return out as Object;
  }

  private static sort(args: Object[]): Object {
    let v: Object | null = UiBuiltinFns.arg(args, 0);
    let field: string = GuncatUiMaterializer.toStr(UiBuiltinFns.arg(args, 1));
    let desc: boolean = args.length > 2 ? GuncatUiMaterializer.truthy(args[2]) : false;
    if (!(v instanceof Array)) {
      return v === null ? (null as Object) : v;
    }
    let arr: Object[] = (v as Object[]).slice();
    // 插入排序: 稳定且无回调依赖
    for (let i: number = 1; i < arr.length; i++) {
      let cur: Object = arr[i];
      let j: number = i - 1;
      while (j >= 0 && UiBuiltinFns.before(cur, arr[j], field, desc)) {
        arr[j + 1] = arr[j];
        j--;
      }
      arr[j + 1] = cur;
    }
    return arr as Object;
  }

  private static before(a: Object, b: Object, field: string, desc: boolean): boolean {
    let av: Object | null = field === '' ? a : UiBuiltinFns.fieldOf(a, field);
    let bv: Object | null = field === '' ? b : UiBuiltinFns.fieldOf(b, field);
    let an: number = GuncatUiMaterializer.toNum(av);
    let bn: number = GuncatUiMaterializer.toNum(bv);
    let numeric: boolean = (typeof av === 'number' || typeof bv === 'number');
    let cmp: number;
    if (numeric) {
      cmp = an < bn ? -1 : (an > bn ? 1 : 0);
    } else {
      let as: string = GuncatUiMaterializer.toStr(av);
      let bs: string = GuncatUiMaterializer.toStr(bv);
      cmp = as < bs ? -1 : (as > bs ? 1 : 0);
    }
    return desc ? cmp > 0 : cmp < 0;
  }

  private static fieldOf(row: Object | null, field: string): Object | null {
    if (row === null || row === undefined) {
      return null;
    }
    if (typeof row === 'object') {
      let rec: Record<string, Object> = row as Record<string, Object>;
      let v: Object | undefined = rec[field];
      return v === undefined ? null : v;
    }
    return null;
  }

  private static compare(cell: Object | null, op: string, target: Object | null): boolean {
    if (op === '==' || op === '=' || op === '') {
      return GuncatUiMaterializer.toStr(cell) === GuncatUiMaterializer.toStr(target);
    }
    if (op === '!=') {
      return GuncatUiMaterializer.toStr(cell) !== GuncatUiMaterializer.toStr(target);
    }
    if (op === '>') {
      return GuncatUiMaterializer.toNum(cell) > GuncatUiMaterializer.toNum(target);
    }
    if (op === '<') {
      return GuncatUiMaterializer.toNum(cell) < GuncatUiMaterializer.toNum(target);
    }
    if (op === '>=') {
      return GuncatUiMaterializer.toNum(cell) >= GuncatUiMaterializer.toNum(target);
    }
    if (op === '<=') {
      return GuncatUiMaterializer.toNum(cell) <= GuncatUiMaterializer.toNum(target);
    }
    if (op === 'contains') {
      return GuncatUiMaterializer.toStr(cell).indexOf(GuncatUiMaterializer.toStr(target)) >= 0;
    }
    return false;
  }
}

// ===== 参数登记(由 GuncatUiLibrary 提供) =====
export class UiParam {
  name: string = '';
  // 'string' | 'number' | 'boolean' | 'any' | 'element' | 'string[]' | 'number[]' |
  // 'element[]' | 'object' | 'object[]' | 'action' | 'raw'
  type: string = 'string';
  required: boolean = false;
  // 参数说明中显示的默认值(仅提示用途)
  hint: string = '';
}

// 组件参数登记表: 由 GuncatUiLibrary 在加载时注册, 避免两个模块互相 import 成环
export class UiRegistry {
  private static table: Record<string, UiParam[]> = {};
  private static names: string[] = [];
  // GuncatUiLibrary 在模块加载时把自己的 init() 挂到这里, 于是任何一处 parse 都能拿到组件表
  static boot: (() => void) | null = null;
  private static bootTried: boolean = false;

  private static bootOnce(): void {
    if (UiRegistry.bootTried) {
      return;
    }
    UiRegistry.bootTried = true;
    if (UiRegistry.boot !== null) {
      UiRegistry.boot();
    }
  }

  static register(component: string, params: UiParam[]): void {
    if (UiRegistry.table[component] === undefined) {
      UiRegistry.names.push(component);
    }
    UiRegistry.table[component] = params;
  }

  static params(component: string): UiParam[] {
    UiRegistry.bootOnce();
    let found: UiParam[] | undefined = UiRegistry.table[component];
    if (found === undefined) {
      let none: UiParam[] = [];
      return none;
    }
    return found;
  }

  static has(component: string): boolean {
    UiRegistry.bootOnce();
    return UiRegistry.table[component] !== undefined;
  }

  static isEmpty(): boolean {
    UiRegistry.bootOnce();
    return UiRegistry.names.length === 0;
  }

  static components(): string[] {
    UiRegistry.bootOnce();
    return UiRegistry.names.slice();
  }
}

// ===== 参数类型宽松转换 =====
export class GuncatUiCoerce {
  // 按参数登记类型把运行时值转成渲染器期望的形态。
  // 宽松策略: 类型不符时尽力转换, 实在不行用安全默认值 —— 绝不丢弃组件。
  static apply(param: UiParam, raw: Object | null, component: string, errors: string[]): Object {
    let t: string = param.type;
    if (t === 'any' || t === 'raw') {
      return raw === null ? (null as Object) : raw;
    }
    if (t === 'string') {
      if (raw === null || raw === undefined) {
        return param.required ? GuncatUiCoerce.missing(param, component, errors) : ('' as Object);
      }
      if (typeof raw === 'string') {
        let s: string = raw as string;
        return s.length > UiLimits.MAX_TEXT ? s.substring(0, UiLimits.MAX_TEXT) : s;
      }
      return GuncatUiMaterializer.toStr(raw);
    }
    if (t === 'number') {
      if (raw === null || raw === undefined) {
        return param.required ? GuncatUiCoerce.missing(param, component, errors) : 0;
      }
      return GuncatUiMaterializer.toNum(raw);
    }
    if (t === 'boolean') {
      if (raw === null || raw === undefined) {
        return false;
      }
      if (typeof raw === 'boolean') {
        return raw as boolean;
      }
      return GuncatUiMaterializer.truthy(raw);
    }
    if (t === 'string[]') {
      return GuncatUiCoerce.toStringList(raw);
    }
    if (t === 'number[]') {
      return GuncatUiCoerce.toNumberList(raw);
    }
    if (t === 'element[]') {
      return GuncatUiCoerce.toElementList(raw);
    }
    if (t === 'element') {
      return raw === null ? (null as Object) : raw;
    }
    if (t === 'object') {
      if (raw === null || raw === undefined) {
        return ({} as Record<string, Object>) as Object;
      }
      if (typeof raw === 'object' && !(raw instanceof Array)) {
        return raw;
      }
      return ({} as Record<string, Object>) as Object;
    }
    if (t === 'object[]') {
      return GuncatUiCoerce.toObjectList(raw);
    }
    if (t === 'action') {
      return raw === null ? (null as Object) : raw;
    }
    return raw === null ? ('' as Object) : raw;
  }

  static defaultOf(param: UiParam): Object {
    let t: string = param.type;
    if (t === 'number') {
      return 0;
    }
    if (t === 'boolean') {
      return false;
    }
    if (t === 'string[]' || t === 'number[]' || t === 'element[]' || t === 'object[]') {
      let empty: Object[] = [];
      return empty as Object;
    }
    if (t === 'object') {
      return ({} as Record<string, Object>) as Object;
    }
    return '' as Object;
  }

  private static missing(param: UiParam, component: string, errors: string[]): Object {
    errors.push(component + ' 缺少必需参数 ' + param.name);
    return GuncatUiCoerce.defaultOf(param);
  }

  private static toStringList(raw: Object | null): Object {
    let out: string[] = [];
    if (raw === null || raw === undefined) {
      return out as Object;
    }
    if (raw instanceof Array) {
      let arr: Object[] = raw as Object[];
      for (let i: number = 0; i < arr.length && i < UiLimits.MAX_ARRAY; i++) {
        out.push(GuncatUiMaterializer.toStr(arr[i]));
      }
      return out as Object;
    }
    out.push(GuncatUiMaterializer.toStr(raw));
    return out as Object;
  }

  private static toNumberList(raw: Object | null): Object {
    let out: number[] = [];
    if (raw === null || raw === undefined) {
      return out as Object;
    }
    if (raw instanceof Array) {
      let arr: Object[] = raw as Object[];
      for (let i: number = 0; i < arr.length && i < UiLimits.MAX_ARRAY; i++) {
        out.push(GuncatUiMaterializer.toNum(arr[i]));
      }
      return out as Object;
    }
    out.push(GuncatUiMaterializer.toNum(raw));
    return out as Object;
  }

  private static toElementList(raw: Object | null): Object {
    let out: Object[] = [];
    if (raw === null || raw === undefined) {
      return out;
    }
    if (raw instanceof Array) {
      let arr: Object[] = raw as Object[];
      for (let i: number = 0; i < arr.length && i < UiLimits.MAX_CHILDREN; i++) {
        if (arr[i] instanceof UiElement) {
          out.push(arr[i]);
        }
      }
      return out;
    }
    if (raw instanceof UiElement) {
      out.push(raw);
    }
    return out;
  }

  private static toObjectList(raw: Object | null): Object {
    let out: Object[] = [];
    if (raw === null || raw === undefined) {
      return out;
    }
    if (raw instanceof Array) {
      let arr: Object[] = raw as Object[];
      for (let i: number = 0; i < arr.length && i < UiLimits.MAX_ARRAY; i++) {
        out.push(arr[i] === null ? (null as Object) : arr[i]);
      }
      return out;
    }
    out.push(raw);
    return out;
  }
}

// ===== 渲染层只读访问器 =====
// 把 Record<string, Object> 里的值安全地读成渲染器需要的形态。
// 渲染器不直接碰 props, 一律通过这里读, 避免每个组件都写一遍类型判断。
export class UiNode {
  static raw(el: UiElement, name: string): Object | null {
    let v: Object | undefined = el.props[name];
    return v === undefined ? null : v;
  }

  static has(el: UiElement, name: string): boolean {
    let v: Object | undefined = el.props[name];
    if (v === undefined || v === null) {
      return false;
    }
    if (typeof v === 'string') {
      return (v as string) !== '';
    }
    if (v instanceof Array) {
      return (v as Object[]).length > 0;
    }
    return true;
  }

  static str(el: UiElement, name: string, fallback: string): string {
    let v: Object | null = UiNode.raw(el, name);
    if (v === null) {
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

  static num(el: UiElement, name: string, fallback: number): number {
    let v: Object | null = UiNode.raw(el, name);
    if (v === null) {
      return fallback;
    }
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      let parsed: number = parseFloat(v as string);
      return isNaN(parsed) ? fallback : parsed;
    }
    if (typeof v === 'boolean') {
      return (v as boolean) ? 1 : 0;
    }
    return fallback;
  }

  static bool(el: UiElement, name: string, fallback: boolean): boolean {
    let v: Object | null = UiNode.raw(el, name);
    if (v === null) {
      return fallback;
    }
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'string') {
      let s: string = (v as string).toLowerCase();
      return s === 'true' || s === '1' || s === 'yes' || s === 'on';
    }
    if (typeof v === 'number') {
      return (v as number) !== 0;
    }
    return fallback;
  }

  static bindOf(el: UiElement, name: string): string {
    let v: string | undefined = el.binds[name];
    return v === undefined ? '' : v;
  }

  static element(el: UiElement, name: string): UiElement | null {
    let v: Object | null = UiNode.raw(el, name);
    if (v !== null && v instanceof UiElement) {
      return v as UiElement;
    }
    return null;
  }

  static elementList(el: UiElement, name: string): UiElement[] {
    let out: UiElement[] = [];
    let v: Object | null = UiNode.raw(el, name);
    if (v === null || !(v instanceof Array)) {
      return out;
    }
    let arr: Object[] = v as Object[];
    for (let i: number = 0; i < arr.length; i++) {
      if (arr[i] instanceof UiElement) {
        out.push(arr[i] as UiElement);
      }
    }
    return out;
  }

  static strList(el: UiElement, name: string): string[] {
    let out: string[] = [];
    let v: Object | null = UiNode.raw(el, name);
    if (v === null) {
      return out;
    }
    if (v instanceof Array) {
      let arr: Object[] = v as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        out.push(GuncatUiMaterializer.toStr(arr[i]));
      }
      return out;
    }
    out.push(GuncatUiMaterializer.toStr(v));
    return out;
  }

  static numList(el: UiElement, name: string): number[] {
    let out: number[] = [];
    let v: Object | null = UiNode.raw(el, name);
    if (v === null) {
      return out;
    }
    if (v instanceof Array) {
      let arr: Object[] = v as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        out.push(GuncatUiMaterializer.toNum(arr[i]));
      }
      return out;
    }
    out.push(GuncatUiMaterializer.toNum(v));
    return out;
  }

  static objList(el: UiElement, name: string): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    let v: Object | null = UiNode.raw(el, name);
    if (v === null || !(v instanceof Array)) {
      return out;
    }
    let arr: Object[] = v as Object[];
    for (let i: number = 0; i < arr.length; i++) {
      let item: Object = arr[i];
      if (item !== null && typeof item === 'object' && !(item instanceof UiElement)) {
        out.push(item as Record<string, Object>);
      }
    }
    return out;
  }

  static obj(el: UiElement, name: string): Record<string, Object> | null {
    let v: Object | null = UiNode.raw(el, name);
    if (v !== null && typeof v === 'object' && !(v instanceof Array)) {
      return v as Record<string, Object>;
    }
    return null;
  }

  static objStr(row: Record<string, Object> | null, key: string, fallback: string): string {
    if (row === null) {
      return fallback;
    }
    let v: Object | undefined = row[key];
    if (v === undefined || v === null) {
      return fallback;
    }
    if (typeof v === 'string') {
      return v as string;
    }
    return String(v);
  }

  static objNum(row: Record<string, Object> | null, key: string, fallback: number): number {
    if (row === null) {
      return fallback;
    }
    let v: Object | undefined = row[key];
    if (v === undefined || v === null) {
      return fallback;
    }
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      let n: number = parseFloat(v as string);
      return isNaN(n) ? fallback : n;
    }
    return fallback;
  }

  // 把 Button/IconButton 的 action 属性规范化为步骤数组
  static actionSteps(el: UiElement, name: string): UiActionStep[] {
    let out: UiActionStep[] = [];
    let v: Object | null = UiNode.raw(el, name);
    if (v === null) {
      return out;
    }
    if (v instanceof UiActionPlan) {
      let plan: UiActionPlan = v as UiActionPlan;
      for (let i: number = 0; i < plan.steps.length; i++) {
        out.push(plan.steps[i]);
      }
      return out;
    }
    if (v instanceof UiActionStep) {
      out.push(v as UiActionStep);
      return out;
    }
    return out;
  }

  // 元素树节点数(带上限, 防止畸形程序拖垮渲染)
  static count(el: UiElement, budget: number): number {
    if (budget <= 0) {
      return 0;
    }
    let total: number = 1;
    let names: string[] = Object.keys(el.props);
    for (let i: number = 0; i < names.length; i++) {
      let v: Object | undefined = el.props[names[i]];
      if (v === undefined || v === null) {
        continue;
      }
      if (v instanceof UiElement) {
        total += UiNode.count(v as UiElement, budget - total);
      } else if (v instanceof Array) {
        let arr: Object[] = v as Object[];
        for (let j: number = 0; j < arr.length; j++) {
          if (arr[j] instanceof UiElement) {
            total += UiNode.count(arr[j] as UiElement, budget - total);
          }
        }
      }
      if (total >= budget) {
        return total;
      }
    }
    return total;
  }

  // 界面是否有真实内容(至少一个可渲染叶子)
  static hasContent(el: UiElement | null): boolean {
    if (el === null) {
      return false;
    }
    return UiNode.countContent(el, 0) > 0;
  }

  private static countContent(el: UiElement, depth: number): number {
    if (depth > UiLimits.MAX_DEPTH) {
      return 0;
    }
    let names: string[] = Object.keys(el.props);
    let childTotal: number = 0;
    for (let i: number = 0; i < names.length; i++) {
      let key: string = names[i];
      let v: Object | undefined = el.props[key];
      if (v === undefined || v === null) {
        continue;
      }
      if (v instanceof UiElement) {
        childTotal += UiNode.countContent(v as UiElement, depth + 1);
      } else if (v instanceof Array) {
        let arr: Object[] = v as Object[];
        for (let j: number = 0; j < arr.length; j++) {
          if (arr[j] instanceof UiElement) {
            childTotal += UiNode.countContent(arr[j] as UiElement, depth + 1);
          }
        }
      }
    }
    if (childTotal > 0) {
      return childTotal;
    }
    // 叶子: 本身能画出东西
    if (el.type === 'Separator') {
      return 0;
    }
    return 1;
  }
}

// ===== 围栏分词: 从流式正文里切出界面程序 =====
export class UiFragment {
  // true = 围栏块正文
  fence: boolean = false;
  // 围栏块是否已闭合
  complete: boolean = true;
  // 围栏 info string(如 guncat-ui / json / python)
  info: string = '';
  text: string = '';
}

export class GuncatUiFences {
  // 扫描正文, 跳过双引号字符串内容, 找出围栏位置
  private static isFenceAt(text: string, i: number): boolean {
    return text.charAt(i) === '`' && i + 2 < text.length + 1 &&
      text.charAt(i + 1) === '`' && text.charAt(i + 2) === '`';
  }

  // 跳过从 i 开始的双引号字符串(返回字符串结束后的位置); 非字符串返回 i
  private static skipString(text: string, i: number): number {
    if (text.charAt(i) !== '"') {
      return i;
    }
    let j: number = i + 1;
    while (j < text.length) {
      let c: string = text.charAt(j);
      if (c === '\\') {
        j += 2;
      } else if (c === '"') {
        return j + 1;
      } else {
        j++;
      }
    }
    return j;
  }

  static split(content: string): UiFragment[] {
    let out: UiFragment[] = [];
    let i: number = 0;
    let textStart: number = 0;
    let n: number = content.length;
    while (i < n) {
      let skipped: number = GuncatUiFences.skipString(content, i);
      if (skipped > i) {
        i = skipped;
        continue;
      }
      if (!GuncatUiFences.isFenceAt(content, i)) {
        i++;
        continue;
      }
      // 只认行首(允许前置空白)的围栏
      let lineStart: number = content.lastIndexOf('\n', i - 1) + 1;
      let prefix: string = content.substring(lineStart, i);
      if (prefix.trim() !== '') {
        i += 3;
        continue;
      }
      if (i > textStart) {
        let head: UiFragment = new UiFragment();
        head.fence = false;
        head.text = content.substring(textStart, i);
        out.push(head);
      }
      // info string: 到行尾
      let lineEnd: number = content.indexOf('\n', i);
      if (lineEnd < 0) {
        // 围栏标记行还没写完
        let partial: UiFragment = new UiFragment();
        partial.fence = true;
        partial.complete = false;
        partial.info = content.substring(i + 3).trim();
        partial.text = '';
        out.push(partial);
        return out;
      }
      let info: string = content.substring(i + 3, lineEnd).trim();
      let bodyStart: number = lineEnd + 1;
      // 找闭合围栏(跳过字符串)
      let close: number = -1;
      let k: number = bodyStart;
      while (k < n) {
        let sk: number = GuncatUiFences.skipString(content, k);
        if (sk > k) {
          k = sk;
          continue;
        }
        if (GuncatUiFences.isFenceAt(content, k)) {
          let ls: number = content.lastIndexOf('\n', k - 1) + 1;
          if (content.substring(ls, k).trim() === '') {
            close = k;
            break;
          }
        }
        k++;
      }
      let body: UiFragment = new UiFragment();
      body.fence = true;
      body.info = info;
      if (close < 0) {
        body.complete = false;
        body.text = content.substring(bodyStart);
        out.push(body);
        return out;
      }
      body.complete = true;
      body.text = content.substring(bodyStart, close);
      out.push(body);
      let closeLineEnd: number = content.indexOf('\n', close);
      i = closeLineEnd < 0 ? n : closeLineEnd + 1;
      textStart = i;
    }
    if (textStart < n) {
      let tail: UiFragment = new UiFragment();
      tail.fence = false;
      tail.text = content.substring(textStart);
      out.push(tail);
    }
    return out;
  }

  // 是否为界面围栏(语言标记为 guncat-ui / openui-lang, 或空 info)
  static isUiFence(info: string): boolean {
    let lower: string = info.toLowerCase();
    if (lower === '' || lower === GuncatUiLang.FENCE_LANG || lower === GuncatUiLang.FENCE_LANG_ALT) {
      return true;
    }
    return false;
  }

  // 已闭合的界面程序文本
  static extractPrograms(content: string): string[] {
    let out: string[] = [];
    let frags: UiFragment[] = GuncatUiFences.split(content);
    for (let i: number = 0; i < frags.length; i++) {
      let f: UiFragment = frags[i];
      if (f.fence && f.complete && GuncatUiFences.isUiFence(f.info)) {
        out.push(f.text);
      }
    }
    return out;
  }

  // 是否含有任意(含未闭合)的界面围栏
  static hasUiFence(content: string): boolean {
    let frags: UiFragment[] = GuncatUiFences.split(content);
    for (let i: number = 0; i < frags.length; i++) {
      if (frags[i].fence && GuncatUiFences.isUiFence(frags[i].info)) {
        return true;
      }
    }
    return false;
  }

  // 最后一个未闭合界面围栏的正文
  static lastOpenBody(content: string): string {
    let frags: UiFragment[] = GuncatUiFences.split(content);
    for (let i: number = frags.length - 1; i >= 0; i--) {
      let f: UiFragment = frags[i];
      if (f.fence && !f.complete && GuncatUiFences.isUiFence(f.info)) {
        return f.text;
      }
    }
    return '';
  }
}
