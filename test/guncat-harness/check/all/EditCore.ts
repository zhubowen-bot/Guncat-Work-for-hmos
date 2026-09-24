// EditCore: edit / str_replace_editor 的纯匹配替换逻辑(对齐 DeepSeek Harness tool-fs 的编辑语义)。
// 语义: old_string 逐字符精确子串匹配(大小写与空白敏感, 不锚定行首行尾);
// 换行符风格(CRLF/LF)与文件实际风格不一致时, 自动把 old/new 的换行归一到文件风格后重试,
// 避免模型写 \n 而文件是 CRLF(或反之)时误报"不存在", 也避免替换后产生混合换行。
// 纯逻辑模块, 不依赖设备 API, 可在桌面 Node 端验证(test/guncat-harness)。
export class EditOutcome {
  ok: boolean = false;
  status: string = '';      // ok / not_found / multiple / no_change / range
  newText: string = '';
  matchCount: number = 0;   // status=multiple 时的命中次数
  lineTotal: number = 0;    // status=range 时的总行数(insert)
}

export class EditCore {
  // 用 oldStr 在 oldText 中定位并替换; 默认要求唯一(非重叠)匹配, replaceAll 时全部替换
  static apply(oldText: string, oldStr: string, newStr: string, replaceAll: boolean): EditOutcome {
    let out: EditOutcome = new EditOutcome();
    let fileCrlf: boolean = oldText.indexOf('\r\n') >= 0;
    let oldPat: string = oldStr;
    let newPat: string = newStr;
    let first: number = oldText.indexOf(oldPat);
    if (first < 0) {
      // 换行风格不一致: 把 old/new 的换行符对齐到文件实际风格再试一次
      oldPat = fileCrlf ? EditCore.toCrlf(oldStr) : EditCore.toLf(oldStr);
      newPat = fileCrlf ? EditCore.toCrlf(newStr) : EditCore.toLf(newStr);
      first = oldText.indexOf(oldPat);
      if (first < 0) {
        out.status = 'not_found';
        return out;
      }
    } else {
      // 匹配成功也把新文本的换行对齐到文件风格, 避免写入混合换行
      newPat = fileCrlf ? EditCore.toCrlf(newStr) : EditCore.toLf(newStr);
    }
    let count: number = 0;
    let cursor: number = 0;
    while (true) {
      let found: number = oldText.indexOf(oldPat, cursor);
      if (found < 0) {
        break;
      }
      count++;
      cursor = found + oldPat.length;
    }
    if (!replaceAll && count > 1) {
      out.status = 'multiple';
      out.matchCount = count;
      return out;
    }
    let newText: string = replaceAll ?
      EditCore.replaceAllLiteral(oldText, oldPat, newPat) :
      oldText.substring(0, first) + newPat + oldText.substring(first + oldPat.length);
    if (newText === oldText) {
      // 换行归一后 new 与 old 等价(如传了 CRLF 改 LF 文件), 实际无需改动
      out.status = 'no_change';
      return out;
    }
    out.ok = true;
    out.status = 'ok';
    out.newText = newText;
    return out;
  }

  // 在第 lineNo 行后插入 insertText(行号按 split('\n') 语义, 0 = 文件最前)
  static insertLines(oldText: string, lineNo: number, insertText: string): EditOutcome {
    let out: EditOutcome = new EditOutcome();
    let lines: string[] = oldText.split('\n');
    if (lineNo < 0 || lineNo > lines.length) {
      out.status = 'range';
      out.lineTotal = lines.length;
      return out;
    }
    let fileCrlf: boolean = oldText.indexOf('\r\n') >= 0;
    let insArr: string[] = (fileCrlf ? insertText : EditCore.toLf(insertText)).split('\n');
    let rebuilt: string[] = [];
    for (let i: number = 0; i < lineNo; i++) {
      rebuilt.push(lines[i]);
    }
    for (let i: number = 0; i < insArr.length; i++) {
      rebuilt.push(insArr[i]);
    }
    for (let i: number = lineNo; i < lines.length; i++) {
      rebuilt.push(lines[i]);
    }
    // CRLF 文件: 除最后一段外每个 split 段都以 \r 结尾, 插入行与被顺延的原末行也要补齐
    if (fileCrlf) {
      for (let i: number = 0; i < rebuilt.length - 1; i++) {
        if (!rebuilt[i].endsWith('\r')) {
          rebuilt[i] = rebuilt[i] + '\r';
        }
      }
    }
    out.ok = true;
    out.status = 'ok';
    out.newText = rebuilt.join('\n');
    return out;
  }

  // 字面替换全部(不对特殊字符做正则解释)
  static replaceAllLiteral(text: string, oldStr: string, newStr: string): string {
    let out: string = '';
    let cursor: number = 0;
    while (cursor < text.length) {
      let found: number = text.indexOf(oldStr, cursor);
      if (found < 0) {
        out += text.substring(cursor);
        break;
      }
      out += text.substring(cursor, found) + newStr;
      cursor = found + oldStr.length;
    }
    return out;
  }

  static toLf(text: string): string {
    return EditCore.replaceAllLiteral(text, '\r\n', '\n');
  }

  static toCrlf(text: string): string {
    return EditCore.replaceAllLiteral(EditCore.toLf(text), '\n', '\r\n');
  }
}
