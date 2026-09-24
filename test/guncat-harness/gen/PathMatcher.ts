// PathMatcher: glob 模式匹配(对齐 DeepSeek Harness tool-fs-search 的 glob 语义)
// 支持: ** 跨目录段 / * 段内任意字符 / ? 单字符 / {a,b} 分支 / [abc] 字符类。
// 纯逻辑模块, 不依赖设备 API, 可在桌面 Node 端验证(test/guncat-harness)。

// 编译选项: 大小写是否敏感
export class GlobOptions {
  caseSensitive: boolean = false;
}

export class PathMatcher {
  // 编译单条 glob 为 RegExp(整串匹配)。'/' 视为路径分隔符, ** 可跨段。
  static compile(pattern: string, options: GlobOptions | null): RegExp {
    let opts: GlobOptions = options !== null ? options : new GlobOptions();
    let re: string = '';
    let i: number = 0;
    while (i < pattern.length) {
      let ch: string = pattern.charAt(i);
      if (ch === '*') {
        if (i + 1 < pattern.length && pattern.charAt(i + 1) === '*') {
          // '**': 跳过其后紧跟的分隔符, 匹配任意路径(含跨段)
          let j: number = i + 2;
          if (j < pattern.length && pattern.charAt(j) === '/') {
            re += '(?:.*/)?';
            i = j + 1;
          } else {
            re += '.*';
            i = j;
          }
          continue;
        }
        // '*': 段内任意字符(不跨 '/')
        re += '[^/]*';
        i++;
        continue;
      }
      if (ch === '?') {
        re += '[^/]';
        i++;
        continue;
      }
      if (ch === '{') {
        // {a,b} 分支: 找到配对 '}'(支持一层嵌套)
        let depth: number = 1;
        let body: string = '';
        let j: number = i + 1;
        while (j < pattern.length && depth > 0) {
          let cj: string = pattern.charAt(j);
          if (cj === '{') {
            depth++;
          } else if (cj === '}') {
            depth--;
            if (depth === 0) {
              break;
            }
          }
          body += cj;
          j++;
        }
        re += '(?:' + PathMatcher.compileBody(body, opts) + ')';
        i = j + 1;
        continue;
      }
      if (ch === '[') {
        // [abc] / [a-z] / [!abc] 字符类: 原样透传, 转义首尾特殊情况
        let j: number = i + 1;
        let body: string = '';
        if (j < pattern.length && (pattern.charAt(j) === '!' || pattern.charAt(j) === '^')) {
          body += '^';
          j++;
        }
        while (j < pattern.length && pattern.charAt(j) !== ']') {
          let cj: string = pattern.charAt(j);
          if (cj === '\\') {
            body += '\\\\';
          } else {
            body += cj;
          }
          j++;
        }
        re += '[' + body + ']';
        i = j + 1;
        continue;
      }
      if ('.+^$()|\\/'.indexOf(ch) !== -1) {
        re += '\\' + ch;
      } else {
        re += ch;
      }
      i++;
    }
    let flags: string = opts.caseSensitive ? '' : 'i';
    return new RegExp('^' + re + '$', flags);
  }

  // {a,b} 分支体内的逐段编译: 以顶层 ',' 分隔(嵌套 {} 内的逗号不分隔)
  private static compileBody(body: string, opts: GlobOptions): string {
    let parts: string[] = [];
    let depth: number = 0;
    let cur: string = '';
    for (let i: number = 0; i < body.length; i++) {
      let ch: string = body.charAt(i);
      if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
      }
      if (ch === ',' && depth === 0) {
        parts.push(cur);
        cur = '';
        continue;
      }
      cur += ch;
    }
    parts.push(cur);
    let compiled: string[] = [];
    for (let i: number = 0; i < parts.length; i++) {
      compiled.push(PathMatcher.compile(parts[i], opts).source);
    }
    // 合并各分支的正则源(去掉外层 ^...$ 再拼接)
    let merged: string[] = [];
    for (let i: number = 0; i < compiled.length; i++) {
      let src: string = compiled[i];
      if (src.startsWith('^') && src.endsWith('$')) {
        src = src.substring(1, src.length - 1);
      }
      merged.push(src);
    }
    return merged.join('|');
  }

  // 路径是否匹配任一模式
  static matchAny(path: string, patterns: RegExp[]): boolean {
    for (let i: number = 0; i < patterns.length; i++) {
      if (patterns[i].test(path)) {
        return true;
      }
    }
    return false;
  }

  // 逗号分隔的多条 glob 编译(空白项跳过); 顶层逗号才分隔, {} 分支内的逗号保留
  static compileList(patternText: string, options: GlobOptions | null): RegExp[] {
    let out: RegExp[] = [];
    let parts: string[] = PathMatcher.splitTopLevel(patternText);
    for (let i: number = 0; i < parts.length; i++) {
      let p: string = parts[i].trim();
      if (p === '') {
        continue;
      }
      out.push(PathMatcher.compile(p, options));
    }
    return out;
  }

  // 按顶层逗号切分(嵌套 {} 内的逗号不分隔)
  private static splitTopLevel(text: string): string[] {
    let parts: string[] = [];
    let depth: number = 0;
    let cur: string = '';
    for (let i: number = 0; i < text.length; i++) {
      let ch: string = text.charAt(i);
      if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
      }
      if (ch === ',' && depth === 0) {
        parts.push(cur);
        cur = '';
        continue;
      }
      cur += ch;
    }
    parts.push(cur);
    return parts;
  }
}
