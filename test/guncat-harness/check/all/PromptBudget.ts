// PromptBudget: System Prompt token 预算估算(纯逻辑, 无 HarmonyOS 依赖)
// 用于 Prompt A/B: 静态手写工具目录 vs 动态生成目录, 评估分块 token 成本。
// 估算是启发式(中文按 1 字≈1 token, 英文按 4 字符≈1 token), 用于相对比较而非精确计费。
export class PromptBudgetEntry {
  name: string = '';
  chars: number = 0;
  tokens: number = 0;
}

export class PromptBudgetSnapshot {
  entries: PromptBudgetEntry[] = [];
  totalChars: number = 0;
  totalTokens: number = 0;

  // 是否超出预算(用于压缩/裁剪触发判断)
  overTarget(maxTokens: number): boolean {
    return this.totalTokens > maxTokens;
  }

  // 距预算还余多少 token(可为负)
  remaining(maxTokens: number): number {
    return maxTokens - this.totalTokens;
  }
}

export class PromptBudget {
  static estimateTokens(text: string): number {
    let tokens: number = 0;
    let latin: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      let code: number = text.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) {
        tokens++;
        if (latin > 0) {
          tokens += Math.ceil(latin / 4);
          latin = 0;
        }
      } else if (code <= 0x7F) {
        if (text[i] === ' ' || text[i] === '\n' || text[i] === '\t' || text[i] === '\r') {
          if (latin > 0) {
            tokens += Math.ceil(latin / 4);
            latin = 0;
          }
        } else {
          latin++;
        }
      } else {
        // 其他非 ASCII(如全角标点/韩文/日文)粗略按 1 token
        tokens++;
        if (latin > 0) {
          tokens += Math.ceil(latin / 4);
          latin = 0;
        }
      }
    }
    if (latin > 0) {
      tokens += Math.ceil(latin / 4);
    }
    return tokens;
  }

  static fromSections(sections: Record<string, string>): PromptBudgetSnapshot {
    let s: PromptBudgetSnapshot = new PromptBudgetSnapshot();
    let keys: string[] = Object.keys(sections);
    keys.sort();
    for (let i: number = 0; i < keys.length; i++) {
      let entry: PromptBudgetEntry = new PromptBudgetEntry();
      entry.name = keys[i];
      entry.chars = sections[keys[i]].length;
      entry.tokens = PromptBudget.estimateTokens(sections[keys[i]]);
      s.totalChars += entry.chars;
      s.totalTokens += entry.tokens;
      s.entries.push(entry);
    }
    return s;
  }

  static fromPrompt(prompt: string): PromptBudgetSnapshot {
    let s: PromptBudgetSnapshot = new PromptBudgetSnapshot();
    let entry: PromptBudgetEntry = new PromptBudgetEntry();
    entry.name = 'system_prompt';
    entry.chars = prompt.length;
    entry.tokens = PromptBudget.estimateTokens(prompt);
    s.totalChars = entry.chars;
    s.totalTokens = entry.tokens;
    s.entries.push(entry);
    return s;
  }
}
