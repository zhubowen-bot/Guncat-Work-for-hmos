// 智能体(对齐 web 版本的 agents.json 中的 agent)
export class Agent {
  id: string = '';
  name: string = '';
  description: string = '';
  // 侧边栏短描述(对齐 web 版本 shortDescription 字段; 为空时 UI 回退到 description)
  shortDescription: string = '';
  category: string = '';
  promptFile: string = '';
  // 侧边栏独立图标(rawfile 下相对路径, 如 icons/guncat-3.0-flash.png; 为空时回退猫头像)
  icon: string = '';
  systemPrompt: string = '';

  static of(id: string, name: string, description: string, category: string,
    promptFile: string, systemPrompt: string): Agent {
    let agent: Agent = new Agent();
    agent.id = id;
    agent.name = name;
    agent.description = description;
    agent.category = category;
    agent.promptFile = promptFile;
    agent.systemPrompt = systemPrompt;
    return agent;
  }
}
