// SteerQueue: 用户插话(steering)队列 —— 对齐 DeepSeek Harness 的 next-step steering。
//
// 为什么必须"排队 + 在安全点注入", 而不是收到就打断:
//   任务执行中, 模型的一轮 assistant 消息带着 tool_calls, 与它后面的一串 tool_result 是一对
//   严格的协议配对。用户在 write_file / shell / subagent 执行到一半时插一句话, 如果立刻中止
//   并把它塞进请求, 会拆散这对配对(provider 直接报错), 也会让已经跑了一半的工具调用白费。
//   所以插话只入队, 真正注入只发生在两个安全插话点:
//     1. 一轮工具结果全部落地、本轮 assistant 消息收尾之后(下一轮请求之前);
//     2. 本轮已经决定收尾、但队列里还有插话时 —— 驱动再跑一轮, 而不是 break 收工。
//   两处都在"轮"的边界上, 任何在途工具/流式输出都不会被切断。
//
// 只做纯逻辑(无 HarmonyOS 依赖), 由 test/guncat-harness 的断言守着。
export class SteerQueue {
  // 注入请求时统一加的前缀: 让模型知道这是任务执行中追加的要求, 而不是新开的一轮任务
  static readonly INJECT_PREFIX: string = '【用户补充】';

  private items: string[] = [];

  // 入队; 空串/纯空白不入队(返回 false)
  push(text: string): boolean {
    let value: string = text.trim();
    if (value === '') {
      return false;
    }
    this.items.push(value);
    return true;
  }

  hasPending(): boolean {
    return this.items.length > 0;
  }

  size(): number {
    return this.items.length;
  }

  // 到达安全插话点: 整体取走(保持入队顺序)并清空队列
  drain(): string[] {
    let out: string[] = this.items;
    this.items = [];
    return out;
  }

  // 任务开始/中止时清空: 已被清掉的插话仍留在会话历史里, 不会丢消息
  clear(): void {
    this.items = [];
  }

  // 注入到循环历史里的文本
  static inject(text: string): string {
    return SteerQueue.INJECT_PREFIX + text.trim();
  }
}

// 执行中点"发送"时, 这条输入该走哪条路(纯决策, 便于单测):
//   空闲 → 正常发送; 执行中 + Agent Loop(工作/交互) → 插话排队; 执行中 + 聊天模式 → 提示等待。
// 这里曾经把"执行中"一律当成不可发送, 于是插话按钮点了没反应 —— 判定集中在这里, 别再散落到界面里。
export class SendRoute {
  static readonly SEND: string = 'send';
  static readonly STEER: string = 'steer';
  static readonly WAIT: string = 'wait';
  static readonly IGNORE: string = 'ignore';

  static decide(text: string, isStreaming: boolean, agentLoopMode: boolean): string {
    if (text.trim() === '') {
      return SendRoute.IGNORE;
    }
    if (!isStreaming) {
      return SendRoute.SEND;
    }
    return agentLoopMode ? SendRoute.STEER : SendRoute.WAIT;
  }
}
