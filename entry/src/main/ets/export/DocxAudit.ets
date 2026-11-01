// DocxAudit: .docx 生成后的结构自检(纯字符串分析, 不依赖 Word/WPS)。
//
// 为什么要有它: 之前 write_docx 只回报「已生成 xxx.docx / 12.1 KB」, 但文件里的公式可能
// 已经坏了(空 m:t、上下标被吞、LaTeX 命令残留)。工具说成功、用户打开是废稿 —— 这是
// 最坏的一种失败。所以现在把「证据」而不是「结论」放进返回值:
//   14 公式段 / 151 行内公式 / 空 m:t 节点 0 / LaTeX 残留 0 / 未识别命令 0
//   oMathPara 父元素合规 14/14
// 有任何一项不为 0/不合规, 直接拒绝写盘并说明原因。

export class DocxAudit {
  blocks: number = 0;
  displayMath: number = 0;
  inlineMath: number = 0;
  emptyMathText: number = 0;
  latexResidue: number = 0;
  unknownCommands: string[] = [];
  issues: string[] = [];
  oMathParaTotal: number = 0;
  oMathParaCompliant: number = 0;
  oMathTotal: number = 0;
  oMathCompliant: number = 0;
  residueSamples: string[] = [];

  // 扫描 document.xml; unknownCommands/issues 来自 OmmlConverter 的解析审计
  static scan(xml: string, unknownCommands: string[], issues: string[], blocks: number): DocxAudit {
    let a: DocxAudit = new DocxAudit();
    a.blocks = blocks;
    a.unknownCommands = unknownCommands.slice();
    a.issues = issues.slice();

    a.displayMath = DocxAudit.countMatches(xml, /<m:oMathPara(?:\s|>)/g);
    let totalMath: number = DocxAudit.countMatches(xml, /<m:oMath(?:\s|>)/g);
    a.inlineMath = totalMath - a.displayMath;

    // 空 m:t: <m:t/> 或 <m:t ...></m:t>。正常的无上下限 nary 已改用 <m:sub/> / <m:sup/>,
    // 因此这里出现的空节点基本都意味着解析失败(上下标被吞/命令没产出内容)。
    a.emptyMathText = DocxAudit.countMatches(xml, /<m:t(?:\s[^>]*)?\/>|<m:t(?:\s[^>]*)?>\s*<\/m:t>/g);

    a.scanMathText(xml);
    a.scanMathParents(xml);
    return a;
  }

  hasErrors(): boolean {
    return this.emptyMathText > 0 || this.latexResidue > 0 || this.unknownCommands.length > 0 ||
      this.issues.length > 0 || this.oMathParaCompliant < this.oMathParaTotal ||
      this.oMathCompliant < this.oMathTotal;
  }

  // 面向模型的证据行(成功与失败都返回同一套口径)
  report(): string {
    let lines: string[] = [];
    lines.push(this.displayMath.toString() + ' 公式段 / ' + this.inlineMath.toString() +
      ' 行内公式 / 空 m:t 节点 ' + this.emptyMathText.toString() +
      ' / LaTeX 残留 ' + this.latexResidue.toString() +
      ' / 未识别命令 ' + this.unknownCommands.length.toString());
    lines.push('oMathPara 父元素合规 ' + this.oMathParaCompliant.toString() + '/' +
      this.oMathParaTotal.toString() + ', oMath 父元素合规 ' + this.oMathCompliant.toString() +
      '/' + this.oMathTotal.toString());
    return lines.join('\n');
  }

  // 自检不通过时抛出可直接给模型看的中文错误(不写盘)
  assertClean(): void {
    if (!this.hasErrors()) {
      return;
    }
    let reasons: string[] = [];
    if (this.emptyMathText > 0) {
      reasons.push('空 m:t 节点 ' + this.emptyMathText.toString() +
        ' 个(通常表示上下标/命令解析失败, Word 里会显示成缺口)');
    }
    if (this.latexResidue > 0) {
      let sample: string = this.residueSamples.length > 0
        ? '(示例: ' + this.residueSamples.join(' ; ') + ')' : '';
      reasons.push('LaTeX 残留 ' + this.latexResidue.toString() + ' 处' + sample);
    }
    if (this.unknownCommands.length > 0) {
      reasons.push('未识别命令: ' + this.unknownCommands.join(', '));
    }
    for (let i: number = 0; i < this.issues.length; i++) {
      reasons.push(this.issues[i]);
    }
    if (this.oMathParaCompliant < this.oMathParaTotal || this.oMathCompliant < this.oMathTotal) {
      reasons.push('公式父元素不合规: ' +
        ((this.oMathParaTotal - this.oMathParaCompliant) +
          (this.oMathTotal - this.oMathCompliant)).toString() +
        ' 处(m:oMathPara 必须是 w:p 的子元素, m:oMath 不能嵌在 w:r 里)');
    }
    throw new Error('文档自检未通过, 已拒绝写盘(避免交付坏文件):\n- ' + reasons.join('\n- ') +
      '\n自检: ' + this.report() +
      '\n请修正 LaTeX 或改用受支持的写法; 受支持命令见 load_skill("docx") 的 reference/doc-dsl.md。');
  }

  private scanMathText(xml: string): void {
    let re: RegExp = /<m:t(?:\s[^>]*)?>([\s\S]*?)<\/m:t>/g;
    let m: RegExpExecArray | null = re.exec(xml);
    while (m !== null) {
      let text: string = m[1];
      // 只检测反斜杠命令残留。不要检测 '$' —— \text{cost $5} 里的美元符号是正文内容,
      // 不是 LaTeX 残留; 把它算进去会误杀合法文档。
      let residueRe: RegExp = /\\[A-Za-z]+/g;
      let r: RegExpExecArray | null = residueRe.exec(text);
      while (r !== null) {
        this.latexResidue++;
        if (this.residueSamples.length < 5 && this.residueSamples.indexOf(r[0]) === -1) {
          this.residueSamples.push(r[0]);
        }
        r = residueRe.exec(text);
      }
      m = re.exec(xml);
    }
  }

  // 遍历标签栈, 统计 m:oMathPara / m:oMath 的父元素是否合规
  private scanMathParents(xml: string): void {
    let stack: string[] = [];
    let re: RegExp = /<(\/?)([A-Za-z_][\w:.-]*)([^>]*?)(\/?)>/g;
    let m: RegExpExecArray | null = re.exec(xml);
    while (m !== null) {
      let closing: boolean = m[1] === '/';
      let name: string = m[2];
      let selfClosing: boolean = m[4] === '/';
      if (!closing) {
        if (name === 'm:oMathPara' || name === 'm:oMath') {
          let parent: string = stack.length > 0 ? stack[stack.length - 1] : '';
          if (name === 'm:oMathPara') {
            this.oMathParaTotal++;
            if (parent === 'w:p') {
              this.oMathParaCompliant++;
            }
          } else {
            this.oMathTotal++;
            if (parent === 'w:p' || parent === 'm:oMathPara') {
              this.oMathCompliant++;
            }
          }
        }
        if (!selfClosing) {
          stack.push(name);
        }
      } else {
        for (let i: number = stack.length - 1; i >= 0; i--) {
          if (stack[i] === name) {
            stack.length = i;
            break;
          }
        }
      }
      m = re.exec(xml);
    }
  }

  private static countMatches(text: string, re: RegExp): number {
    let count: number = 0;
    let m: RegExpExecArray | null = re.exec(text);
    while (m !== null) {
      count++;
      m = re.exec(text);
    }
    return count;
  }
}
