// FileObservation: 「编辑前必须见过这个文件」的登记表(纯逻辑, 不碰文件系统)
//
// 提示词里一直写着「修改文件前先读取确认现状」，但它只是一句劝告：模型经常凭文件名和想象
// 直接 edit —— old_string 恰好匹配上时，改动就落进了它从没看过的内容里；更糟的是文件在
// 它读取之后已被外部改过(shell、run_python、transform_file、用户自己编辑)，它却按旧印象改。
// 这里把劝告变成内核强制：登记每个文件被「看过/写过」时的版本，edit 类工具动手前先比对。
//
// 版本由调用方(WorkFileService.fsVersionOf)算出(大小 + 修改时间 + 开头一段内容的廉价指纹)，
// 本类只管登记与比对，因此规则可以脱离真实进程与磁盘做断言。
import { Constants } from './Constants';

export class FileObservation {
  // 两种拒绝码会原样出现在工具结果里，模型据此知道下一步该做什么(先读再改)
  static readonly CODE_NOT_OBSERVED: string = 'FS_NOT_OBSERVED';
  static readonly CODE_STALE_VERSION: string = 'FS_STALE_VERSION';

  // 绝对路径 → 上一次看过/写过它时的版本。用 Map 而不是普通对象: 文件路径里带特殊字符
  // (方括号、点、空格)时对象键的语义容易踩坑, Map 只按字符串相等匹配。
  private static versions: Map<string, string> = new Map<string, string>();

  // 工具在这一条守卫里的角色: 'read'/'write' 登记版本, 'edit' 先比对, 'forget' 清登记, '' 不参与
  // command 只给 str_replace_editor 用(它一个工具名下面挂着 view/create/str_replace/insert 四种活)
  static roleOf(name: string, command: string): string {
    if (name === 'read_file') {
      return 'read';
    }
    if (name === 'write_file' || name === 'append_file') {
      return 'write';
    }
    if (name === 'edit') {
      return 'edit';
    }
    if (name === 'str_replace_editor') {
      if (command === 'view') {
        return 'read';
      }
      if (command === 'create') {
        return 'write';
      }
      return 'edit';
    }
    if (name === 'delete_file' || name === 'move_file') {
      return 'forget';
    }
    return '';
  }

  // 登记一次「看过/写过」。超出上限时按登记先后淘汰最旧条目：
  // 被淘汰的代价只是模型需要重新读一次文件，不会改坏内容，所以宁可粗保护也不做复杂 LRU。
  static observe(abs: string, version: string): void {
    if (abs === '' || version === '') {
      return;
    }
    // 先删再写: Map 的迭代顺序即插入顺序, 重新登记要把它挪到队尾, 否则热文件会被先淘汰
    FileObservation.versions.delete(abs);
    FileObservation.versions.set(abs, version);
    let drop: number = FileObservation.versions.size - Constants.WORK_FS_OBSERVATION_MAX_ENTRIES;
    if (drop <= 0) {
      return;
    }
    let keys: string[] = [];
    FileObservation.versions.forEach((_v: string, k: string): void => {
      keys.push(k);
    });
    for (let i: number = 0; i < drop; i++) {
      FileObservation.versions.delete(keys[i]);
    }
  }

  // 文件被删除/移走：旧路径的登记必须清掉，否则同名文件重建后会被当成「已经看过」
  static forget(abs: string): void {
    if (abs !== '') {
      FileObservation.versions.delete(abs);
    }
  }

  // 整个工作区被清空/删除时按目录前缀清登记
  static forgetRoot(root: string): void {
    if (root === '') {
      return;
    }
    let keys: string[] = [];
    FileObservation.versions.forEach((_v: string, k: string): void => {
      keys.push(k);
    });
    for (let i: number = 0; i < keys.length; i++) {
      if (keys[i].startsWith(root + '/')) {
        FileObservation.versions.delete(keys[i]);
      }
    }
  }

  // 这个路径是否被登记过(测试与诊断用)
  static observed(abs: string): boolean {
    return FileObservation.versions.has(abs);
  }

  // 登记条数(测试与诊断用)
  static size(): number {
    return FileObservation.versions.size;
  }

  // edit 类工具动手前的比对。返回空串=放行；否则是给用户与模型看的拒绝说明。
  // rel 用模型自己写的那个相对路径，回给它的修复指令才能直接照抄。
  static check(abs: string, rel: string, version: string): string {
    let seen: string | undefined = FileObservation.versions.get(abs);
    if (seen === undefined) {
      return '[' + FileObservation.CODE_NOT_OBSERVED + '] 这个文件你还没读过就编辑，已拒绝: ' + rel +
        '。先 read_file("' + rel + '") 看清现状再 edit —— 凭文件名和想象改一份没看过的内容，' +
        '匹配上了也会改坏上下文。';
    }
    if (seen !== version) {
      return '[' + FileObservation.CODE_STALE_VERSION + '] 这个文件在你上次读取之后已经变化，已拒绝: ' +
        rel + '。可能是你自己写的、也可能是 shell/run_python/transform_file 或用户改的 —— ' +
        '重新 read_file("' + rel + '") 拿到当前内容后再编辑。';
    }
    return '';
  }

  // 测试用: 清空登记
  static clear(): void {
    FileObservation.versions.clear();
  }
}
