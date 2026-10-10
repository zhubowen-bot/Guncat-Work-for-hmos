// ToolRegistry: 工具注册中心(纯逻辑, 无 HarmonyOS 依赖)
// 统一维护工具定义 + 元数据(命名空间/版本/只读/变更/权限/分类),
// 为动态工具目录注入、权限过滤、子代理工具面裁剪提供单一事实源。
// 现有 WorkFileService.toolDefs() 仍是工具定义的唯一构造入口;
// WorkFileService 在首次访问时把 defs + 分类名单同步进注册中心。
export class ToolMeta {
  namespace: string = 'core';
  version: string = '1';
  readOnly: boolean = false;
  mutating: boolean = false;
  parallelSafe: boolean = false; // 并行安全：可与同类工具并发执行（如 subagent）
  permissions: string[] = [];
  category: string = '';
  timeoutMs: number = 0;   // 0 表示使用全局默认
  maxRetries: number = -1; // -1 表示使用工具默认策略
}

export class ToolRegistryEntry {
  def: Record<string, Object> = {};
  meta: ToolMeta = new ToolMeta();
}

export class SkillFileMeta {
  file: string = '';
  desc: string = '';
}

export class SkillMeta {
  id: string = '';
  name: string = '';
  description: string = '';
  files: SkillFileMeta[] = [];
}

export class ToolRegistry {
  private static entries: ToolRegistryEntry[] = [];
  private static synced: boolean = false;
  private static skills: SkillMeta[] = [];

  // 同步/合并一批工具定义与元数据; 同名工具更新 def 与 meta(幂等, 可增量注册动态工具)
  static sync(defs: Record<string, Object>[], readOnly: string[], mutating: string[],
    namespace: string = 'core', version: string = '1',
    permissions: string[] = [], category: string = ''): void {
    for (let i: number = 0; i < defs.length; i++) {
      let nameObj: Object | undefined = defs[i]['name'];
      if (typeof nameObj !== 'string') {
        continue;
      }
      let name: string = nameObj as string;
      let meta: ToolMeta = new ToolMeta();
      meta.namespace = namespace;
      meta.version = version;
      meta.readOnly = readOnly.indexOf(name) !== -1;
      meta.mutating = mutating.indexOf(name) !== -1;
      meta.permissions = permissions.slice();
      meta.category = category;
      let existing: ToolRegistryEntry | null = ToolRegistry.findEntry(name);
      if (existing !== null) {
        existing.def = defs[i];
        existing.meta = meta;
      } else {
        let entry: ToolRegistryEntry = new ToolRegistryEntry();
        entry.def = defs[i];
        entry.meta = meta;
        ToolRegistry.entries.push(entry);
      }
    }
    ToolRegistry.synced = true;
  }

  // 首次同步用(避免每次查询重复构建)
  static ensure(defs: Record<string, Object>[], readOnly: string[], mutating: string[],
    namespace: string = 'core', version: string = '1'): void {
    if (!ToolRegistry.synced) {
      ToolRegistry.sync(defs, readOnly, mutating, namespace, version);
    }
  }

  static findDef(name: string): Record<string, Object> | null {
    let entry: ToolRegistryEntry | null = ToolRegistry.findEntry(name);
    return entry !== null ? entry.def : null;
  }

  static findMeta(name: string): ToolMeta | null {
    let entry: ToolRegistryEntry | null = ToolRegistry.findEntry(name);
    return entry !== null ? entry.meta : null;
  }

  // 动态调整单个工具的权限(供插件/动态工具目录注入时设置)
  static setPermissions(name: string, permissions: string[]): void {
    let meta: ToolMeta | null = ToolRegistry.findMeta(name);
    if (meta !== null) {
      meta.permissions = permissions.slice();
    }
  }

  // 动态设置单个工具的运行期配置(timeoutMs=0 表示全局默认; maxRetries<0 表示工具默认策略)
  static setRuntimeConfig(name: string, timeoutMs: number, maxRetries: number): void {
    let meta: ToolMeta | null = ToolRegistry.findMeta(name);
    if (meta !== null) {
      if (timeoutMs >= 0) {
        meta.timeoutMs = timeoutMs;
      }
      if (maxRetries >= 0) {
        meta.maxRetries = maxRetries;
      }
    }
  }

  static isReadOnly(name: string): boolean {
    let meta: ToolMeta | null = ToolRegistry.findMeta(name);
    return meta !== null && meta.readOnly;
  }

  static isMutating(name: string): boolean {
    let meta: ToolMeta | null = ToolRegistry.findMeta(name);
    return meta !== null && meta.mutating;
  }

  // 是否“并行安全”：可与同类工具并发执行（典型如 subagent——独立上下文/独立 LLM 循环）
  static isParallelSafe(name: string): boolean {
    let meta: ToolMeta | null = ToolRegistry.findMeta(name);
    return meta !== null && meta.parallelSafe;
  }

  // 动态标注单个工具为“并行安全”（由 WorkFileService 在注册中心同步后对核心工具打标）
  static setParallelSafe(name: string, flag: boolean): void {
    let meta: ToolMeta | null = ToolRegistry.findMeta(name);
    if (meta !== null) {
      meta.parallelSafe = flag;
    }
  }

  // 动态注册插件工具: 以 namespace 为插件名同步一批工具定义与元数据(幂等, 支持热更新)
  static registerPlugin(namespace: string, defs: Record<string, Object>[],
    readOnly: string[], mutating: string[], version: string = '1',
    permissions: string[] = [], category: string = 'plugin'): void {
    ToolRegistry.sync(defs, readOnly, mutating, namespace, version, permissions, category);
  }

  // 注销插件: 按命名空间移除其全部工具(热更新/禁用用)
  static unregisterPlugin(namespace: string): void {
    let keep: ToolRegistryEntry[] = [];
    for (let i: number = 0; i < ToolRegistry.entries.length; i++) {
      let entry: ToolRegistryEntry = ToolRegistry.entries[i];
      if (entry.meta.namespace !== namespace) {
        keep.push(entry);
      }
    }
    ToolRegistry.entries = keep;
  }

  // 已注册插件命名空间列表(去重)
  static pluginNamespaces(): string[] {
    let out: string[] = [];
    for (let i: number = 0; i < ToolRegistry.entries.length; i++) {
      let ns: string = ToolRegistry.entries[i].meta.namespace;
      if (ns !== 'core' && out.indexOf(ns) === -1) {
        out.push(ns);
      }
    }
    return out;
  }

  // 只返回插件命名空间下的工具定义
  static pluginDefs(): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < ToolRegistry.entries.length; i++) {
      let entry: ToolRegistryEntry = ToolRegistry.entries[i];
      if (entry.meta.namespace !== 'core') {
        out.push(entry.def);
      }
    }
    return out;
  }

  // ===== 技能注册(技能作为首类插件, 独立于工具定义) =====
  static registerSkill(skill: SkillMeta): void {
    let existing: SkillMeta | null = ToolRegistry.findSkill(skill.id);
    if (existing !== null) {
      let idx: number = ToolRegistry.skills.indexOf(existing);
      if (idx >= 0) {
        ToolRegistry.skills[idx] = skill;
      }
      return;
    }
    ToolRegistry.skills.push(skill);
  }

  static unregisterSkill(id: string): void {
    let keep: SkillMeta[] = [];
    for (let i: number = 0; i < ToolRegistry.skills.length; i++) {
      if (ToolRegistry.skills[i].id !== id) {
        keep.push(ToolRegistry.skills[i]);
      }
    }
    ToolRegistry.skills = keep;
  }

  static findSkill(id: string): SkillMeta | null {
    for (let i: number = 0; i < ToolRegistry.skills.length; i++) {
      if (ToolRegistry.skills[i].id === id) {
        return ToolRegistry.skills[i];
      }
    }
    return null;
  }

  static skillList(): SkillMeta[] {
    let out: SkillMeta[] = [];
    for (let i: number = 0; i < ToolRegistry.skills.length; i++) {
      out.push(ToolRegistry.skills[i]);
    }
    out.sort((a: SkillMeta, b: SkillMeta): number => {
      if (a.id < b.id) {
        return -1;
      }
      if (a.id > b.id) {
        return 1;
      }
      return 0;
    });
    return out;
  }

  static skillIds(): string[] {
    let out: string[] = [];
    let list: SkillMeta[] = ToolRegistry.skillList();
    for (let i: number = 0; i < list.length; i++) {
      out.push(list[i].id);
    }
    return out;
  }

  // 返回全部工具定义(可按命名空间过滤; 空串表示不过滤)
  static defs(namespace: string = ''): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < ToolRegistry.entries.length; i++) {
      let entry: ToolRegistryEntry = ToolRegistry.entries[i];
      if (namespace === '' || entry.meta.namespace === namespace) {
        out.push(entry.def);
      }
    }
    return out;
  }

  // 返回工具名列表; excluded 用于子代理等受限工具面裁剪
  static names(excluded: string[] = []): string[] {
    let out: string[] = [];
    for (let i: number = 0; i < ToolRegistry.entries.length; i++) {
      let name: string = ToolRegistry.entries[i].def['name'] as string;
      if (excluded.indexOf(name) === -1) {
        out.push(name);
      }
    }
    return out;
  }

  // 已注册工具总数(含插件/技能工具; 供日志/摘要)
  static defCount(): number {
    return ToolRegistry.entries.length;
  }

  // 返回工具定义列表(可排除指定工具名; 供调试/受限工具面)
  static listTools(excluded: string[] = []): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < ToolRegistry.entries.length; i++) {
      let def: Record<string, Object> = ToolRegistry.entries[i].def;
      let name: string = def['name'] as string;
      if (excluded.indexOf(name) === -1) {
        out.push(def);
      }
    }
    return out;
  }

  // 权限过滤: 只返回调用方拥有 permissions 中任一权限的工具
  // (permissions 为空表示不按权限过滤)
  static defsByPermission(permissions: string[]): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < ToolRegistry.entries.length; i++) {
      let entry: ToolRegistryEntry = ToolRegistry.entries[i];
      if (ToolRegistry.hasAnyPermission(entry.meta.permissions, permissions)) {
        out.push(entry.def);
      }
    }
    return out;
  }

  static has(name: string): boolean {
    return ToolRegistry.findEntry(name) !== null;
  }

  // ===== 交互模式工具面白名单 =====
  //
  // 交互模式的产出是「一张能操作的界面」, 不是长程交付物 —— **速度就是它的产品力**。
  // 工作模式那 45 个工具全量下发时, 模型每一轮都看得见 todo_write / goal_* / schedule_* /
  // subagent / session_search 这些长程工具; 提示词里再怎么写"默认零工具", 也挡不住
  // "既然工具就摆在这儿, 顺手用一下" —— 用户等来的仍是与界面无关的工具调用。
  // 所以这里做**物理裁剪**: 交互模式只下发真正需要工具的四类场景 ——
  //   读素材(上传的文件) / 算真实数字 / 核实外部事实 / 出文件(用户明确要导出)。
  // **新增工具默认不进交互模式**(有意为之): 想让某个新工具在交互模式里可用, 必须显式加进本白名单。
  // 维护口径见 docs/architecture/interactive-mode.md。
  static readonly INTERACTIVE_TOOL_WHITELIST: string[] = [
    // 读素材: 用户上传的文件 / 工作区已有的素材
    'list_files', 'read_file', 'search_files', 'glob', 'grep',
    'parse_document', 'search_pdf', 'pdf_to_images', 'view_image',
    'read_docx', 'read_xlsx', 'read_ppt',
    // 算真实数字: 界面里的数字必须来自真实计算, 不是编出来的好看数字
    'run_js', 'transform_file',
    // 核实外部事实
    'web_fetch', 'local_web_search',
    // 出文件: 只在用户明确要导出时破例; 生成后从工作区引用素材
    'write_file', 'append_file', 'create_dir', 'write_csv', 'write_svg',
    'write_docx', 'write_xlsx', 'write_pptx', 'download_file',
    // 技能名册(导出走简化流程, 只加载对应格式技能)
    'list_skills', 'load_skill'
  ];

  // 交互模式是否允许下发该工具
  static interactiveAllows(name: string): boolean {
    return ToolRegistry.INTERACTIVE_TOOL_WHITELIST.indexOf(name) !== -1;
  }

  // 按交互模式白名单裁剪工具定义。**保持原有顺序** —— 工具的物理顺序即请求前缀的一部分,
  // 顺序稳定才能让相邻轮次的 KV 缓存命中。
  static filterInteractive(defs: Record<string, Object>[]): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < defs.length; i++) {
      let nameObj: Object | undefined = defs[i]['name'];
      if (typeof nameObj === 'string' && ToolRegistry.interactiveAllows(nameObj as string)) {
        out.push(defs[i]);
      }
    }
    return out;
  }

  // 被交互模式裁掉的工具名(供诊断/日志/回归断言; 顺序与传入定义一致)
  static interactiveDropped(defs: Record<string, Object>[]): string[] {
    let out: string[] = [];
    for (let i: number = 0; i < defs.length; i++) {
      let nameObj: Object | undefined = defs[i]['name'];
      if (typeof nameObj === 'string' && !ToolRegistry.interactiveAllows(nameObj as string)) {
        out.push(nameObj as string);
      }
    }
    return out;
  }

  // 测试/热更新用: 清空注册中心
  static clear(): void {
    ToolRegistry.entries = [];
    ToolRegistry.synced = false;
    ToolRegistry.skills = [];
  }

  private static findEntry(name: string): ToolRegistryEntry | null {
    for (let i: number = 0; i < ToolRegistry.entries.length; i++) {
      let entry: ToolRegistryEntry = ToolRegistry.entries[i];
      let n: Object | undefined = entry.def['name'];
      if (typeof n === 'string' && (n as string) === name) {
        return entry;
      }
    }
    return null;
  }

  private static hasAnyPermission(required: string[], granted: string[]): boolean {
    if (required.length === 0) {
      return true;
    }
    for (let i: number = 0; i < required.length; i++) {
      if (granted.indexOf(required[i]) !== -1) {
        return true;
      }
    }
    return false;
  }
}
