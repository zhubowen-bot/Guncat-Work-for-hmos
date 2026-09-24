// AgentLoader: 读取 rawfile 下的 agents.json 与对应提示词 .md
import { Agent } from '../model/Agent';
import { AgentConfigEntry } from '../common/Types';
import { util } from '@kit.ArkTS';

export class AgentLoader {
  static async loadAllAgents(context: Context): Promise<Agent[]> {
    let entries: AgentConfigEntry[] = [];
    try {
      entries = await AgentLoader.loadAgentConfig(context);
    } catch (e) {
      return [];
    }
    let agents: Agent[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      let entry: AgentConfigEntry = entries[i];
      let prompt: string = '';
      try {
        prompt = await AgentLoader.loadPromptContent(context, entry.promptFile);
        if (prompt !== '') {
          // 在系统提示词最前面拼接今天的日期
          prompt = AgentLoader.getDatePrefix() + '\n\n' + prompt;
        }
      } catch (e) {
        prompt = '';
      }
      agents.push(Agent.of(entry.id, entry.name, entry.description, entry.category, entry.promptFile, prompt));
      // 对齐 web 版本: 补充侧边栏短描述与独立图标路径(of() 保持原有签名, 此处追加赋值)
      agents[agents.length - 1].shortDescription = entry.shortDescription;
      agents[agents.length - 1].icon = entry.icon;
    }
    return agents;
  }

  static async loadAgentConfig(context: Context): Promise<AgentConfigEntry[]> {
    let raw: Uint8Array = await context.resourceManager.getRawFileContent('agents.json');
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    let text: string = decoder.decodeToString(raw, { stream: false });
    let json: Object = JSON.parse(text);
    if (typeof json !== 'object' || json === null) {
      return [];
    }
    let agentsField: Object = (json as Record<string, Object>)['agents'];
    if (!(agentsField instanceof Array)) {
      return [];
    }
    let arr: Object[] = agentsField as Object[];
    let result: AgentConfigEntry[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      let item: Object = arr[i];
      if (typeof item !== 'object' || item === null) {
        continue;
      }
      let rec: Record<string, Object> = item as Record<string, Object>;
      let id: string = (rec['id'] as string) ?? '';
      let name: string = (rec['name'] as string) ?? '';
      let desc: string = (rec['description'] as string) ?? '';
      let shortDesc: string = (rec['shortDescription'] as string) ?? '';
      let icon: string = (rec['icon'] as string) ?? '';
      let cat: string = (rec['category'] as string) ?? '';
      let pf: string = (rec['promptFile'] as string) ?? '';
      if (id === '') {
        continue;
      }
      result.push({ id: id, name: name, description: desc, shortDescription: shortDesc,
        icon: icon, category: cat, promptFile: pf });
    }
    return result;
  }

  static async loadPromptContent(context: Context, fileName: string): Promise<string> {
    if (fileName === '') {
      return '';
    }
    let raw: Uint8Array = await context.resourceManager.getRawFileContent(fileName);
    let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(raw, { stream: false });
  }

  // 获取今天的日期（本地时区），用于拼接到系统提示词最前面
  static getDatePrefix(): string {
    const now: Date = new Date();
    const y: number = now.getFullYear();
    const m: string = String(now.getMonth() + 1).padStart(2, '0');
    const d: string = String(now.getDate()).padStart(2, '0');
    return `今天的日期是 ${y}年${m}月${d}日。`;
  }
}
