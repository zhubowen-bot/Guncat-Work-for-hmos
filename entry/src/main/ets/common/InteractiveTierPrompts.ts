// InteractiveTierPrompts: 「能力调度」档位主体提示词的内存注册表(纯逻辑, 无 HarmonyOS 依赖)。
//
// 档位主体是 rawfile 下的 markdown(interactive-tier-*.md), 由 AgentLoader 在启动时读入这里。
// 为什么放 rawfile 而不是写成 TS 常量:
//   1. 原始提示词都在 rawfile, 档位主体与它们放一起, 便于对照与 diff(用户明确要求"可比对");
//   2. 每份 20KB~60KB, 写成代码常量既难读又难维护;
//   3. 系统提示词仍是"启动时读一次 + 进程内缓存", 与原来的静态提示词一样, KV 缓存前缀稳定。
// 组装时由 AgentLoopService(有 context/缓存) 把 body 传给 InteractiveTierPrompt.assemble();
// 组装函数保持纯逻辑, 所以 harness 测试可以直接传入文本断言顺序。
//
// 轻简档故意没有主体文件: 它就是现有交互模式提示词本身(body 为空, 组装走原快车道)。

export class InteractiveTierPrompts {
  // tierId -> 档位主体 markdown(轻简档不登记)
  private static bodies: Record<string, string> = {};

  static set(id: string, text: string): void {
    if (id === '') {
      return;
    }
    InteractiveTierPrompts.bodies[id] = text;
  }

  // 取档位主体; 未加载/轻简档返回空串(组装层据此走轻简或降级)
  static body(id: string): string {
    let text: string | undefined = InteractiveTierPrompts.bodies[id];
    return text === undefined ? '' : text;
  }

  // 已成功加载的档位 id(诊断/日志/回归断言用)
  static loadedIds(): string[] {
    let ids: string[] = [];
    let keys: string[] = Object.keys(InteractiveTierPrompts.bodies);
    for (let i: number = 0; i < keys.length; i++) {
      if (InteractiveTierPrompts.bodies[keys[i]] !== '') {
        ids.push(keys[i]);
      }
    }
    ids.sort();
    return ids;
  }

  // 测试与热重载用
  static clear(): void {
    InteractiveTierPrompts.bodies = {};
  }
}
