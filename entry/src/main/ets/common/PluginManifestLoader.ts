// PluginManifestLoader: 插件 manifest JSON → ToolRegistry 热加载(纯逻辑, 无 HarmonyOS 依赖)
// 支持工具插件与技能插件; apply 幂等(同名替换), 检测工具名冲突(不覆盖核心/他插件工具)。
import { ToolRegistry, SkillMeta, SkillFileMeta, ToolMeta } from './ToolRegistry';

export class PluginToolManifest {
  name: string = '';
  description: string = '';
  parameters: Record<string, Object> = {};
  readOnly: boolean = false;
  mutating: boolean = false;
  timeoutMs: number = 0;
  maxRetries: number = -1;
}

export class PluginManifest {
  id: string = '';
  version: string = '1';
  category: string = 'plugin';
  permissions: string[] = [];
  tools: PluginToolManifest[] = [];
  skills: SkillMeta[] = [];
}

export class PluginManifestResult {
  ok: boolean = true;
  error: string = '';
  registeredTools: string[] = [];
  registeredSkills: string[] = [];
  conflicts: string[] = [];
}

export class PluginManifestLoader {
  // 解析 manifest JSON; 不合法返回 null(error 由调用方取)
  static parse(json: string): PluginManifest | null {
    let manifest: PluginManifest = new PluginManifest();
    try {
      let raw: Object = JSON.parse(json);
      if (typeof raw !== 'object' || raw === null) {
        return null;
      }
      let rec: Record<string, Object> = raw as Record<string, Object>;
      let id: Object = rec['id'];
      if (typeof id !== 'string' || (id as string) === '') {
        return null;
      }
      manifest.id = id as string;
      let version: Object = rec['version'];
      if (typeof version === 'string') {
        manifest.version = version as string;
      }
      let category: Object = rec['category'];
      if (typeof category === 'string') {
        manifest.category = category as string;
      }
      let perms: Object = rec['permissions'];
      if (perms instanceof Array) {
        for (let i: number = 0; i < (perms as Object[]).length; i++) {
          let p: Object = (perms as Object[])[i];
          if (typeof p === 'string') {
            manifest.permissions.push(p as string);
          }
        }
      }
      let tools: Object = rec['tools'];
      if (tools instanceof Array) {
        for (let i: number = 0; i < (tools as Object[]).length; i++) {
          let t: Object = (tools as Object[])[i];
          if (typeof t !== 'object' || t === null) {
            continue;
          }
          let tr: Record<string, Object> = t as Record<string, Object>;
          let nameObj: Object = tr['name'];
          if (typeof nameObj !== 'string' || (nameObj as string) === '') {
            continue;
          }
          let tool: PluginToolManifest = new PluginToolManifest();
          tool.name = nameObj as string;
          let desc: Object = tr['description'];
          tool.description = typeof desc === 'string' ? desc as string : '';
          let params: Object = tr['parameters'];
          if (typeof params === 'object' && params !== null) {
            tool.parameters = params as Record<string, Object>;
          } else {
            tool.parameters = { 'type': 'object', 'properties': {} };
          }
          tool.readOnly = tr['readOnly'] === true;
          tool.mutating = tr['mutating'] === true;
          let to: Object = tr['timeoutMs'];
          if (typeof to === 'number') {
            tool.timeoutMs = to as number;
          }
          let mr: Object = tr['maxRetries'];
          if (typeof mr === 'number') {
            tool.maxRetries = mr as number;
          }
          manifest.tools.push(tool);
        }
      }
      let skills: Object = rec['skills'];
      if (skills instanceof Array) {
        for (let i: number = 0; i < (skills as Object[]).length; i++) {
          let s: Object = (skills as Object[])[i];
          if (typeof s !== 'object' || s === null) {
            continue;
          }
          let sr: Record<string, Object> = s as Record<string, Object>;
          let idObj: Object = sr['id'];
          if (typeof idObj !== 'string' || (idObj as string) === '') {
            continue;
          }
          let meta: SkillMeta = new SkillMeta();
          meta.id = idObj as string;
          let nameObj: Object = sr['name'];
          meta.name = typeof nameObj === 'string' ? nameObj as string : meta.id;
          let desc: Object = sr['description'];
          meta.description = typeof desc === 'string' ? desc as string : '';
          let files: Object = sr['files'];
          if (files instanceof Array) {
            for (let j: number = 0; j < (files as Object[]).length; j++) {
              let f: Object = (files as Object[])[j];
              if (typeof f !== 'object' || f === null) {
                continue;
              }
              let fr: Record<string, Object> = f as Record<string, Object>;
              let fm: SkillFileMeta = new SkillFileMeta();
              let fileObj: Object = fr['file'];
              fm.file = typeof fileObj === 'string' ? fileObj as string : '';
              let d: Object = fr['desc'];
              fm.desc = typeof d === 'string' ? d as string : '';
              if (fm.file !== '') {
                meta.files.push(fm);
              }
            }
          }
          manifest.skills.push(meta);
        }
      }
      return manifest;
    } catch (e) {
      return null;
    }
  }

  // 应用到注册中心: 幂等热加载; 工具名与已注册(核心/他插件)冲突时跳过并记录
  static apply(manifest: PluginManifest): PluginManifestResult {
    let result: PluginManifestResult = new PluginManifestResult();
    let defs: Record<string, Object>[] = [];
    let readOnly: string[] = [];
    let mutating: string[] = [];
    for (let i: number = 0; i < manifest.tools.length; i++) {
      let t: PluginToolManifest = manifest.tools[i];
      let existing: ToolMeta | null = ToolRegistry.findMeta(t.name);
      if (existing !== null && existing.namespace !== manifest.id) {
        result.conflicts.push(t.name + ':' + existing.namespace);
        continue;
      }
      defs.push({
        'name': t.name,
        'description': t.description,
        'parameters': t.parameters
      });
      if (t.readOnly) {
        readOnly.push(t.name);
      }
      if (t.mutating) {
        mutating.push(t.name);
      }
      result.registeredTools.push(t.name);
    }
    if (defs.length > 0) {
      ToolRegistry.registerPlugin(manifest.id, defs, readOnly, mutating,
        manifest.version, manifest.permissions, manifest.category);
    }
    for (let i: number = 0; i < manifest.tools.length; i++) {
      let t: PluginToolManifest = manifest.tools[i];
      if (t.timeoutMs > 0 || t.maxRetries >= 0) {
        ToolRegistry.setRuntimeConfig(t.name, t.timeoutMs, t.maxRetries);
      }
    }
    for (let i: number = 0; i < manifest.skills.length; i++) {
      ToolRegistry.registerSkill(manifest.skills[i]);
      result.registeredSkills.push(manifest.skills[i].id);
    }
    if (result.conflicts.length > 0) {
      result.ok = false;
      result.error = 'tool_name_conflict';
    }
    return result;
  }

  // 卸载插件: 移除其工具与技能
  static unload(manifest: PluginManifest): void {
    ToolRegistry.unregisterPlugin(manifest.id);
    for (let i: number = 0; i < manifest.skills.length; i++) {
      ToolRegistry.unregisterSkill(manifest.skills[i].id);
    }
  }
}
