// FileSearchCore: glob 文件收集 + grep 正则搜索内核(对齐 DeepSeek Harness tool-fs-search)
// 通过 FsAdapter 注入文件系统访问, 设备侧接 fileIo, 桌面 Node 端接 fs, 双端共用同一套逻辑。
// 纯逻辑模块, 可在桌面 Node 端验证(test/guncat-harness)。
import { PathMatcher, GlobOptions } from './PathMatcher.ts';
import { Constants } from './Constants.ts';

// 文件系统适配器: 设备侧与桌面侧各实现一份
export interface FsAdapter {
  // 列出目录下的条目名(不含路径); 目录不存在返回空数组
  list(dirPath: string): string[];
  // 是否为目录; 不存在返回 false
  isDir(path: string): boolean;
  // 读取文本文件(UTF-8), 超过 maxBytes 截断; 失败/二进制返回空串
  readText(path: string, maxBytes: number): string;
}

// glob 收集结果项
export class GlobHit {
  path: string = ''; // 工作区相对路径
  size: number = 0;
}

// grep 命中项
export class GrepHit {
  file: string = '';
  line: number = 0;
  text: string = '';
}

// grep 搜索选项
export class GrepOptions {
  pattern: string = '';
  // 大小写不敏感(默认 true, 对齐 search_files 习惯)
  ignoreCase: boolean = true;
  // 文件名过滤 glob(逗号分隔, 可空)
  glob: string = '';
  // 最大命中数
  maxMatches: number = Constants.WORK_GREP_MAX_MATCHES;
  // 是否输出上下文行(每命中前后各 context 行, 0 关闭)
  context: number = 0;
}

export class FileSearchCore {
  // 路径拼接: 兼容带尾分隔符的 base(如根路径 '/'), 避免产生 '//' 双斜杠
  private static join(base: string, name: string): string {
    if (base.endsWith('/')) {
      return base + name;
    }
    return base + '/' + name;
  }

  // 递归收集 base 下所有文件相对路径(目录先序; 跳过 skipRel 列出的子树)
  private static collectFiles(adapter: FsAdapter, baseAbs: string, relPrefix: string,
    out: string[], skipRel: string[]): void {
    if (out.length > Constants.WORK_GLOB_MAX_FILES * 4) {
      return;
    }
    let names: string[] = adapter.list(baseAbs);
    names.sort();
    for (let i: number = 0; i < names.length; i++) {
      let rel: string = relPrefix === '' ? names[i] : relPrefix + '/' + names[i];
      let abs: string = FileSearchCore.join(baseAbs, names[i]);
      if (FileSearchCore.inSkipList(rel, skipRel)) {
        continue;
      }
      if (adapter.isDir(abs)) {
        FileSearchCore.collectFiles(adapter, abs, rel, out, skipRel);
      } else {
        out.push(rel);
      }
    }
  }

  private static inSkipList(rel: string, skipRel: string[]): boolean {
    for (let i: number = 0; i < skipRel.length; i++) {
      if (rel === skipRel[i] || rel.startsWith(skipRel[i] + '/')) {
        return true;
      }
    }
    return false;
  }

  // glob 工具: pattern 匹配工作区相对路径, 返回按 mtime 无法获取时按路径序的上限内命中
  static globSearch(adapter: FsAdapter, rootAbs: string, pattern: string,
    baseRel: string, skipRel: string[]): GlobHit[] {
    let opts: GlobOptions = new GlobOptions();
    let regs: RegExp[] = PathMatcher.compileList(pattern, opts);
    if (regs.length === 0) {
      return [];
    }
    let baseAbs: string = rootAbs;
    let prefix: string = '';
    if (baseRel !== '') {
      baseAbs = FileSearchCore.join(rootAbs, baseRel);
      prefix = baseRel + '/';
    }
    let all: string[] = [];
    FileSearchCore.collectFiles(adapter, baseAbs, '', all, skipRel);
    let hits: GlobHit[] = [];
    for (let i: number = 0; i < all.length; i++) {
      let rel: string = prefix + all[i];
      if (!PathMatcher.matchAny(rel, regs)) {
        continue;
      }
      let hit: GlobHit = new GlobHit();
      hit.path = rel;
      hit.size = FileSearchCore.safeSize(adapter, FileSearchCore.join(rootAbs, rel));
      hits.push(hit);
      if (hits.length >= Constants.WORK_GLOB_MAX_FILES) {
        break;
      }
    }
    return hits;
  }

  private static safeSize(adapter: FsAdapter, abs: string): number {
    // FsAdapter 不暴露 stat: 通过读文本长度近似为 0(仅展示用途);
    // 设备侧 WorkFileService 会在结果里补真实大小
    return adapter.isDir(abs) ? 0 : -1;
  }

  // grep 工具: 正则搜索(带 filename glob 过滤), 返回 "文件:行号: 内容" 命中
  static grepSearch(adapter: FsAdapter, rootAbs: string, options: GrepOptions,
    baseRel: string, skipRel: string[]): GrepHit[] {
    let pattern: string = options.pattern;
    if (pattern === '') {
      return [];
    }
    let flags: string = options.ignoreCase ? 'gi' : 'g';
    let regex: RegExp;
    try {
      regex = new RegExp(pattern, flags);
    } catch (e) {
      return [];
    }
    let globRegs: RegExp[] = PathMatcher.compileList(options.glob, null);
    let baseAbs: string = rootAbs;
    let prefix: string = '';
    if (baseRel !== '') {
      baseAbs = FileSearchCore.join(rootAbs, baseRel);
      prefix = baseRel + '/';
    }
    let files: string[] = [];
    FileSearchCore.collectFiles(adapter, baseAbs, '', files, skipRel);
    let hits: GrepHit[] = [];
    for (let i: number = 0; i < files.length; i++) {
      if (hits.length >= options.maxMatches) {
        break;
      }
      let rel: string = prefix + files[i];
      if (globRegs.length > 0 && !PathMatcher.matchAny(FileSearchCore.fileNameOf(rel), globRegs)) {
        continue;
      }
      let text: string = adapter.readText(FileSearchCore.join(rootAbs, rel),
        Constants.WORK_GREP_FILE_MAX_BYTES);
      if (text === '') {
        continue;
      }
      let lines: string[] = text.split('\n');
      for (let ln: number = 0; ln < lines.length && hits.length < options.maxMatches; ln++) {
        regex.lastIndex = 0;
        if (!regex.test(lines[ln])) {
          continue;
        }
        let shown: string = lines[ln].trim();
        if (shown.length > 240) {
          shown = shown.substring(0, 240) + '...';
        }
        let hit: GrepHit = new GrepHit();
        hit.file = rel;
        hit.line = ln + 1;
        hit.text = shown;
        hits.push(hit);
      }
    }
    return hits;
  }

  private static fileNameOf(rel: string): string {
    let idx: number = rel.lastIndexOf('/');
    return idx >= 0 ? rel.substring(idx + 1) : rel;
  }

  // 命中渲染为 "文件:行号: 内容" 行(grep / search_files 同构)
  static renderHits(hits: GrepHit[]): string {
    let lines: string[] = [];
    for (let i: number = 0; i < hits.length; i++) {
      lines.push(hits[i].file + ':' + hits[i].line.toString() + ': ' + hits[i].text);
    }
    return lines.join('\n');
  }
}
