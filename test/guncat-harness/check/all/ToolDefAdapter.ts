// ToolDefAdapter: 通用工具定义 → 三协议工具形态(纯逻辑, 无 HarmonyOS 依赖)
// 工作模式/聊天模式共用: completions 用 function.function, responses 用顶层 function,
// anthropic 用 input_schema。收敛 AgentLoopService/ChatService 中的重复映射。
export class ToolDefAdapter {
  static completionsTools(tools: Record<string, Object>[]): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < tools.length; i++) {
      let def: Record<string, Object> = tools[i];
      out.push({
        type: 'function',
        function: {
          name: def['name'],
          description: def['description'],
          parameters: def['parameters']
        }
      });
    }
    return out;
  }

  static responsesTools(tools: Record<string, Object>[]): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < tools.length; i++) {
      let def: Record<string, Object> = tools[i];
      out.push({
        type: 'function',
        name: def['name'],
        description: def['description'],
        parameters: def['parameters']
      });
    }
    return out;
  }

  static anthropicTools(tools: Record<string, Object>[]): Record<string, Object>[] {
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < tools.length; i++) {
      let def: Record<string, Object> = tools[i];
      out.push({
        name: def['name'],
        description: def['description'],
        input_schema: def['parameters']
      });
    }
    return out;
  }

  static adapt(tools: Record<string, Object>[], protocol: string): Record<string, Object>[] {
    if (protocol === 'responses') {
      return ToolDefAdapter.responsesTools(tools);
    }
    if (protocol === 'anthropic') {
      return ToolDefAdapter.anthropicTools(tools);
    }
    return ToolDefAdapter.completionsTools(tools);
  }
}
