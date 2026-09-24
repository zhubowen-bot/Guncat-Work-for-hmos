// SubagentIsolation: 子代理工作区写隔离的纯逻辑(可单测)
// 策略: 子代理仍可读取/搜索整个主工作区; 但写类工具的目标路径统一重定向到
// 该子代理自己的 output_dir(已在目录内则原样), 防止污染/改写/删除主循环文件,
// 也避免并行子代理写同名文件互相覆盖。
// 反馈口径:
//  - 写入越界(如写 main/evil.txt): 自动重定向, 并在工具结果前附加明确提示;
//  - 删除/移动越界(如删 main/protected.txt): 直接“越界拦截”, 不执行。
export class SubagentIsolation {
  // 写类工具的“目标路径”字段: 这些字段会被自动重定向到子代理的 output_dir;
  // 输入型路径(如 write_docx.doc_file / transform_file.input)保持原样。
  static readonly writePathFields: Record<string, string[]> = {
    'write_file': ['path'],
    'append_file': ['path'],
    'delete_file': ['path'],
    'create_dir': ['path'],
    'move_file': ['from', 'to'],
    'write_csv': ['path'],
    'download_file': ['path'],
    'write_svg': ['path'],
    'write_docx': ['path'],
    'write_xlsx': ['path'],
    'write_pptx': ['path'],
    'edit': ['path'],
    'str_replace_editor': ['path'],
    'edit_docx': ['path'],
    'edit_xlsx': ['path'],
    'edit_ppt': ['path'],
    'transform_file': ['output']
  };

  static tryParseArgs(argsJson: string): Record<string, Object> | null {
    let trimmed: string = argsJson.trim();
    if (trimmed === '') {
      trimmed = '{}';
    }
    try {
      let parsed: Object = JSON.parse(trimmed);
      if (typeof parsed === 'object' && parsed !== null && !(parsed instanceof Array)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  static strArg(args: Record<string, Object>, key: string, defVal: string): string {
    let v: Object = args[key];
    if (typeof v === 'string') {
      return v as string;
    }
    if (typeof v === 'number') {
      return (v as number).toString();
    }
    return defVal;
  }

  // 归一化相对路径: 去 ./、前导 /、合并重复 /
  private static normalizePath(raw: string): string {
    let p: string = raw.trim();
    p = p.replace(/\\/g, '/');
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    p = p.replace(/\/+/g, '/');
    return p;
  }

  // 是否已经在 output_dir 内(等于 output_dir 或以 output_dir/ 开头)
  static isWithinOutputDir(raw: string, outputDir: string): boolean {
    let p: string = SubagentIsolation.normalizePath(raw);
    return p === outputDir || p.startsWith(outputDir + '/');
  }

  // 把相对路径重定向进 output_dir: 已在 output_dir 内则原样保留, 否则自动加前缀。
  // 含 ../ 或绝对路径的字符串交由下层 resolveSafe 继续拒绝。
  static redirectPath(raw: string, outputDir: string): string {
    let p: string = SubagentIsolation.normalizePath(raw);
    if (p === '' || p === '.') {
      return outputDir + '/' + (p === '' ? '' : '.');
    }
    if (p === outputDir || p.startsWith(outputDir + '/')) {
      return p;
    }
    return outputDir + '/' + p;
  }

  // 越界拦截/禁止操作。outputDir 用于判断删除/移动是否指向主工作区文件。
  static isolationBlockReason(name: string, argsJson: string, outputDir: string): string {
    let args: Record<string, Object> | null = SubagentIsolation.tryParseArgs(argsJson);
    if (args === null) {
      return '';
    }
    if (name === 'delete_file') {
      let p: string = SubagentIsolation.strArg(args, 'path', '');
      let t: string = p.trim();
      if (t === '' || t === '.' || t === './') {
        return '子代理不能清空或删除整个工作区根目录。请只删除自己产出目录(output_dir)内的文件。';
      }
      if (!SubagentIsolation.isWithinOutputDir(t, outputDir)) {
        return '越界拦截：子代理不能删除主工作区文件/目录「' + t +
          '」，只能删除自己产出目录内的文件。';
      }
    }
    if (name === 'move_file') {
      let from: string = SubagentIsolation.strArg(args, 'from', '');
      if (from.trim() !== '' && !SubagentIsolation.isWithinOutputDir(from, outputDir)) {
        return '越界拦截：子代理不能移动主工作区文件/目录「' + from.trim() +
          '」，只能移动自己产出目录内的文件。';
      }
    }
    return '';
  }

  // 写入重定向提示: 返回一段明确告知“越界已重定向”的文本; 无重定向时返回空串。
  // 删除/移动越界由 isolationBlockReason 拦截, 这里不处理。
  static redirectNotice(name: string, argsJson: string, outputDir: string): string {
    let fields: string[] | undefined = SubagentIsolation.writePathFields[name];
    if (fields === undefined) {
      return '';
    }
    let args: Record<string, Object> | null = SubagentIsolation.tryParseArgs(argsJson);
    if (args === null) {
      return '';
    }
    let viewOnly: boolean = name === 'str_replace_editor' &&
      SubagentIsolation.strArg(args, 'command', '').trim() === 'view';
    if (viewOnly) {
      return '';
    }
    let redirected: string[] = [];
    for (let i: number = 0; i < fields.length; i++) {
      let key: string = fields[i];
      // 删除/移动的源路径越界是拦截而非重定向; 移动目标(to)越界仍重定向并提示
      if (name === 'delete_file' || (name === 'move_file' && key === 'from')) {
        continue;
      }
      let raw: string = SubagentIsolation.strArg(args, key, '');
      let t: string = raw.trim();
      if (t === '') {
        continue;
      }
      if (!SubagentIsolation.isWithinOutputDir(t, outputDir)) {
        redirected.push('「' + t + '」→「' + SubagentIsolation.redirectPath(t, outputDir) + '」');
      }
    }
    if (redirected.length === 0) {
      return '';
    }
    return '【隔离提示】以下目标路径不在你的产出目录内，已自动重定向：' +
      redirected.join('；') + '。后续请直接使用重定向后的路径。';
  }

  // 对写类工具参数做隔离重写; 无写路径的工具原样返回
  static isolatedArgsJson(name: string, argsJson: string, outputDir: string): string {
    let fields: string[] | undefined = SubagentIsolation.writePathFields[name];
    if (fields === undefined && name !== 'run_js') {
      return argsJson;
    }
    let args: Record<string, Object> | null = SubagentIsolation.tryParseArgs(argsJson);
    if (args === null) {
      return argsJson;
    }
    // str_replace_editor 的 view 命令是只读查看, 不重定向(可看主工作区文件)
    let viewOnly: boolean = name === 'str_replace_editor' &&
      SubagentIsolation.strArg(args, 'command', '').trim() === 'view';
    if (fields !== undefined) {
      for (let i: number = 0; i < fields.length; i++) {
        let key: string = fields[i];
        if (viewOnly) {
          continue;
        }
        let raw: string = SubagentIsolation.strArg(args, key, '');
        if (raw.trim() === '') {
          // download_file 省略 path 时也必须落到自己的产出目录
          if (name === 'download_file' && key === 'path') {
            args[key] = outputDir + '/download';
          }
          continue;
        }
        args[key] = SubagentIsolation.redirectPath(raw, outputDir);
      }
    }
    if (name === 'run_js') {
      args['_output_dir'] = outputDir;
    }
    return JSON.stringify(args);
  }
}
