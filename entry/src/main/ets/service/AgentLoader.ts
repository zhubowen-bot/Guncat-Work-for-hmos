// AgentLoader: 读取 rawfile 下的 agents.json 与对应提示词 .md
import { Agent } from '../model/Agent';
import { AgentConfigEntry } from '../common/Types';
import { InteractiveTier, InteractiveTiers } from '../common/InteractiveTiers';
import { InteractiveTierPrompts } from '../common/InteractiveTierPrompts';
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

  // 读取交互模式「能力调度」各档位的档位主体提示词(rawfile/interactive-tier-*.md)到内存注册表。
  // 轻简档没有主体文件(它就是原交互模式提示词), 跳过; 读失败/空文件的档位不登记,
  // 服务层据此回退轻简档, 保证"档位没加载好"不会把交互模式弄成一份没有业务主体的空壳提示词。
  // 在 ChatViewModel.restoreState() 里随 agents 一起加载一次, 之后系统提示词走进程内缓存。
  static async loadInteractiveTierPrompts(context: Context): Promise<void> {
    InteractiveTierPrompts.clear();
    for (let i: number = 0; i < InteractiveTiers.ALL.length; i++) {
      let tier: InteractiveTier = InteractiveTiers.ALL[i];
      if (tier.promptFile === '') {
        continue;
      }
      try {
        let text: string = await AgentLoader.loadPromptContent(context, tier.promptFile);
        if (text.trim() !== '') {
          InteractiveTierPrompts.set(tier.id, text);
        }
      } catch (e) {
        // 缺文件不致命: 该档位运行时回退轻简档(见 AgentLoopService.buildInteractiveSystemPrompt)
      }
    }
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
