// MentionQuery: @文件引用的「文本解析 + 候选排序」纯逻辑(无 UI、无文件系统, 可单测)
//
// 这里同时承担两件事, 且是**同一份口径**:
//   1. 内核侧: 从用户消息里抽出 @ 点名了哪些文件(WorkspaceMentionService 用它决定读哪几份正文);
//   2. 输入框侧: 判断用户此刻是不是正在敲一个 @引用, 以及按什么顺序给候选。
// 两边分开写就会出现"输入的能选中、发出去却解析不出来"这类错位, 所以规则只在这里维护一次。
//
// 关于 caret: 手机上没有可靠的「光标位置」输入事件(TextArea 的 onChange 只给整段文本),
// 而移动端输入几乎总在末尾, 所以 detectAtEnd 只认「文本末尾那个没写完的 @」——
// 用户把光标挪到中间补 @ 时不会弹层, 回到末尾继续敲就会弹。这个取舍换来了零选区依赖。
export class MentionQuery {
  // '@' 字符本身的下标
  start: number = 0;
  // 插入点(始终等于文本末尾)
  caret: number = 0;
  // @ 之后已经敲下的路径片段(可为空串 = 刚敲下 @, 要列全部)
  query: string = '';
}

export class MentionQueryParser {
  // 路径里允许出现的字符（其余字符或空白即视为引用结束）。中文文件名要能用，所以不按 \w 收口，
  // 而是把「显然不是路径」的分隔符列成黑名单。
  static readonly PATH_STOPS: string = '，。、；;：:！!？?“”"\'（）()【】[]{}<>《》|`~*?&\n\r\t ';
  // @ 前面这些字符说明这个 @ 属于邮箱/URL/句中之词, 不是文件引用的起点
  private static readonly WORD_CHARS: string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-';

  // ===== 内核侧: 扫描出文本里的全部 @ 引用(去重, 保持出现顺序) =====
  static extractTokens(text: string): string[] {
    let out: string[] = [];
    if (text === '' || text.indexOf('@') < 0) {
      return out;
    }
    let i: number = 0;
    while (i < text.length) {
      if (text.charAt(i) !== '@') {
        i++;
        continue;
      }
      let prev: string = i === 0 ? '' : text.charAt(i - 1);
      if (prev !== '' && MentionQueryParser.isWordish(prev)) {
        i++;
        continue;
      }
      let j: number = i + 1;
      while (j < text.length && !MentionQueryParser.isStop(text.charAt(j))) {
        j++;
      }
      let token: string = MentionQueryParser.trimTail(text.substring(i + 1, j));
      if (token !== '' && out.indexOf(token) === -1) {
        out.push(token);
      }
      i = j > i + 1 ? j : i + 1;
    }
    return out;
  }

  // @AGENTS.md、@./a.md、@/a.md 指向同一个文件：去掉开头的相对标记，统一成工作区相对路径
  static normalizeRel(token: string): string {
    let out: string = token.replace(/\\/g, '/');
    while (out.startsWith('./')) {
      out = out.substring(2);
    }
    while (out.startsWith('/') && !out.startsWith('//')) {
      out = out.substring(1);
    }
    if (out === '//') {
      return '';
    }
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  // ===== 输入框侧: 文本末尾那个还没写完的 @ 引用 =====
  static detectAtEnd(text: string): MentionQuery | null {
    if (text === '' || text.lastIndexOf('@') < 0) {
      return null;
    }
    let at: number = text.lastIndexOf('@');
    let query: string = text.substring(at + 1);
    // 引用中间出现空白或换行 = 已经结束(用户换行了, 不再补路径)
    for (let i: number = 0; i < query.length; i++) {
      let ch: string = query.charAt(i);
      if (ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t') {
        return null;
      }
    }
    // @ 前面紧贴 ASCII 词字符/点/斜杠/连字符 → 属于邮箱/URL(中文紧挨着 @ 是允许的)
    if (at > 0 && MentionQueryParser.isWordish(text.charAt(at - 1))) {
      return null;
    }
    let out: MentionQuery = new MentionQuery();
    out.start = at;
    out.caret = text.length;
    out.query = query;
    return out;
  }

  // 候选排序: 先按文件名前缀, 再按文件名包含, 最后按整条路径包含。
  // 空查询给最浅的几个文件(刚敲 @ 时最想要的通常在最上面)。
  static rank(paths: string[], query: string, limit: number): string[] {
    let q: string = query.trim().toLowerCase();
    if (q === '') {
      let shallow: string[] = paths.slice();
      shallow.sort((a: string, b: string): number => {
        let da: number = MentionQueryParser.depth(a);
        let db: number = MentionQueryParser.depth(b);
        if (da !== db) {
          return da - db;
        }
        return a < b ? -1 : (a > b ? 1 : 0);
      });
      return shallow.slice(0, limit);
    }
    let picked: string[] = [];
    let scores: number[] = [];
    for (let i: number = 0; i < paths.length; i++) {
      let lower: string = paths[i].toLowerCase();
      let base: string = MentionQueryParser.baseName(lower);
      let score: number = -1;
      if (base.startsWith(q)) {
        score = 0;
      } else if (base.indexOf(q) !== -1) {
        score = 1;
      } else if (lower.indexOf(q) !== -1) {
        score = 2;
      }
      if (score < 0) {
        continue;
      }
      // 插入排序: 候选量是工作区文件量级, 但只保留有限个, 简单插入足够且顺序稳定
      let pos: number = picked.length;
      for (let j: number = 0; j < picked.length; j++) {
        if (scores[j] > score) {
          pos = j;
          break;
        }
        if (scores[j] === score && picked[j] > paths[i]) {
          pos = j;
          break;
        }
      }
      picked.splice(pos, 0, paths[i]);
      scores.splice(pos, 0, score);
      if (picked.length > limit) {
        picked.pop();
        scores.pop();
      }
    }
    return picked;
  }

  // 把「@已输入片段」替换成「@完整路径 」，返回新文本(空格结尾让用户直接接着写)
  static applyPick(text: string, q: MentionQuery, path: string): string {
    let head: string = text.substring(0, q.start);
    return head + '@' + path + ' ';
  }

  private static isStop(ch: string): boolean {
    return MentionQueryParser.PATH_STOPS.indexOf(ch) !== -1;
  }

  private static isWordish(ch: string): boolean {
    if (ch === '') {
      return false;
    }
    if (MentionQueryParser.PATH_STOPS.indexOf(ch) !== -1) {
      return false;
    }
    return MentionQueryParser.WORD_CHARS.indexOf(ch) !== -1;
  }

  // 尾部这些符号是句读而不是文件名的一部分（「改一下 @a.md。」里的句号要摘掉）
  private static trimTail(token: string): string {
    let out: string = token;
    while (out.length > 0 &&
      ',.;:!?)]}"\''.indexOf(out.charAt(out.length - 1)) !== -1) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  private static baseName(path: string): string {
    let slash: number = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  private static depth(path: string): number {
    let n: number = 0;
    for (let i: number = 0; i < path.length; i++) {
      if (path.charAt(i) === '/') {
        n++;
      }
    }
    return n;
  }
}
