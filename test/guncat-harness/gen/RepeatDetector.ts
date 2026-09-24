// RepeatDetector: 工具重复调用检测(纯逻辑, 无 HarmonyOS 依赖)
// 对齐 DeepSeek Harness repeat-tool-reminder: 连续同工具同参数调用计数,
// 第 3/5/8 次触发系统提醒; 新任务开始时 reset。
export class RepeatOutcome {
  count: number = 1;
  shouldRemind: boolean = false;
}

export class RepeatDetector {
  private key: string = '';
  private count: number = 0;

  record(name: string, argsJson: string): RepeatOutcome {
    let out: RepeatOutcome = new RepeatOutcome();
    let newKey: string = name + '|' + argsJson;
    if (newKey === this.key) {
      this.count++;
    } else {
      this.key = newKey;
      this.count = 1;
    }
    out.count = this.count;
    out.shouldRemind = this.count === 3 || this.count === 5 || this.count === 8;
    return out;
  }

  reset(): void {
    this.key = '';
    this.count = 0;
  }
}
