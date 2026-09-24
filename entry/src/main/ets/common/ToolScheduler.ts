// ToolScheduler: 工具调度分组(纯逻辑, 无 HarmonyOS 依赖)
// 对齐 ChatViewModel 当前调度规则: 连续只读调用聚为一组(有界滚动池并发执行),
// 非只读调用逐个执行。为下一步 LoopOrchestrator 提供可单测的调度决策层。
export class ScheduledGroup {
  start: number = 0;
  count: number = 1;
  parallel: boolean = false;
}

export class SchedulerSummary {
  groupCount: number = 0;
  parallelGroupCount: number = 0;
  readOnlyGroupCount: number = 0;
  maxPoolSize: number = 1;
}

export class ToolScheduler {
  // readOnlyFlags[i] 表示第 i 个工具是否只读; maxParallel 为只读组并发上限。
  // allowParallel=false 时禁用只读组并行(全部按单工具顺序执行), 用于逐工具串行场景。
  // 返回按模型顺序切分好的执行组: parallel=true 表示整组只读可并发, false 表示单工具独占。
  static schedule(readOnlyFlags: boolean[], maxParallel: number,
    allowParallel: boolean = true): ScheduledGroup[] {
    let groups: ScheduledGroup[] = [];
    let i: number = 0;
    while (i < readOnlyFlags.length) {
      if (readOnlyFlags[i] && allowParallel) {
        let j: number = i;
        while (j < readOnlyFlags.length && readOnlyFlags[j]) {
          j++;
        }
        let group: ScheduledGroup = new ScheduledGroup();
        group.start = i;
        group.count = j - i;
        group.parallel = true;
        groups.push(group);
        i = j;
      } else {
        let group: ScheduledGroup = new ScheduledGroup();
        group.start = i;
        group.count = 1;
        group.parallel = false;
        groups.push(group);
        i++;
      }
    }
    if (maxParallel < 1) {
      // 非法上限按 1 处理(防除零/空循环)
      return groups;
    }
    return groups;
  }

  // 只读组建议的并发池大小
  static poolSize(group: ScheduledGroup, maxParallel: number): number {
    if (!group.parallel || group.count <= 1) {
      return 1;
    }
    let p: number = maxParallel < 1 ? 1 : maxParallel;
    return Math.min(p, group.count);
  }

  // 调度结果统计(组数/并行组/只读组/最大并发池), 供日志与调试
  static summary(groups: ScheduledGroup[], maxParallel: number): SchedulerSummary {
    let s: SchedulerSummary = new SchedulerSummary();
    s.groupCount = groups.length;
    let maxPool: number = 1;
    for (let i: number = 0; i < groups.length; i++) {
      let g: ScheduledGroup = groups[i];
      if (g.parallel) {
        s.parallelGroupCount++;
        let pool: number = ToolScheduler.poolSize(g, maxParallel);
        if (pool > maxPool) {
          maxPool = pool;
        }
      } else {
        s.readOnlyGroupCount++;
      }
    }
    s.maxPoolSize = maxPool;
    return s;
  }
}
