// AskUserBridge: ask_user_question 工具与 UI 之间的桥(对齐 DeepSeek Harness 的 ask_user 交互)
// 工具执行线程注册问题并挂起等待; ChatPage 渲染问题卡片, 用户作答后 resolve, 结果回传模型。
// 纯逻辑模块, 不依赖设备 API。

// 一次待回答的提问
export class PendingAsk {
  id: string = '';
  question: string = '';
  options: string[] = [];
  multiSelect: boolean = false;
}

// 回答结果(送回模型的文本由 resolve 调用方组装)
export class AskAnswer {
  selections: string[] = [];
  note: string = ''; // 用户自定义补充, 可空
}

export class AskUserBridge {
  private static pending: Map<string, PendingAsk> = new Map();
  private static resolvers: Map<string, (answer: AskAnswer | null) => void> = new Map();
  private static seq: number = 0;

  // 注册提问并等待用户作答; 用户中断时返回 null
  static ask(question: string, options: string[], multiSelect: boolean,
    timeoutMs: number): Promise<AskAnswer | null> {
    let id: string = 'ask_' + Date.now().toString() + '_' + (AskUserBridge.seq++).toString();
    let item: PendingAsk = new PendingAsk();
    item.id = id;
    item.question = question;
    item.options = options;
    item.multiSelect = multiSelect;
    AskUserBridge.pending.set(id, item);
    return new Promise<AskAnswer | null>((resolve: (a: AskAnswer | null) => void) => {
      AskUserBridge.resolvers.set(id, resolve);
      if (timeoutMs > 0) {
        setTimeout((): void => {
          if (AskUserBridge.resolvers.has(id)) {
            // 超时未答: 以取消收场, 避免工具永久挂起
            AskUserBridge.resolveWith(id, null);
          }
        }, timeoutMs);
      }
    });
  }

  // 当前是否有待回答的提问(供 UI 轮询)
  static current(): PendingAsk | null {
    let first: PendingAsk | null = null;
    AskUserBridge.pending.forEach((v: PendingAsk, _k: string): void => {
      if (first === null) {
        first = v;
      }
    });
    return first;
  }

  // 用户作答
  static answer(id: string, answer: AskAnswer): boolean {
    return AskUserBridge.resolveWith(id, answer);
  }

  // 用户取消作答
  static cancel(id: string): boolean {
    return AskUserBridge.resolveWith(id, null);
  }

  // 取消全部挂起提问(循环被中断时调用)
  static cancelAll(): void {
    let ids: string[] = [];
    AskUserBridge.pending.forEach((_v: PendingAsk, k: string): void => {
      ids.push(k);
    });
    for (let i: number = 0; i < ids.length; i++) {
      AskUserBridge.resolveWith(ids[i], null);
    }
  }

  private static resolveWith(id: string, answer: AskAnswer | null): boolean {
    let resolver: (answer: AskAnswer | null) => void | undefined =
      AskUserBridge.resolvers.get(id);
    if (resolver === undefined) {
      return false;
    }
    AskUserBridge.resolvers.delete(id);
    AskUserBridge.pending.delete(id);
    resolver(answer);
    return true;
  }
}
