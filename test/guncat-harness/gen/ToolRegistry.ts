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
