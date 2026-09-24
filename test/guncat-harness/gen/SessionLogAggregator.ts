// SessionLogAggregator: 会话日志聚合(纯逻辑, 无 HarmonyOS 依赖)
// 输入 SessionLogService 的事件对象数组(每条含 type + payload 字段),
// 输出按工具聚合的成功率/超时/取消/schema 错误统计与 turn 状态汇总。
export class ToolCallAgg {
  name: string = '';
  calls: number = 0;
  ok: number = 0;
  fail: number = 0;
  timeout: number = 0;
  cancelled: number = 0;
  schemaError: number = 0;
  totalDurationMs: number = 0;
  p50Ms: number = 0;
  p90Ms: number = 0;
  p99Ms: number = 0;
}

export class SessionLogSummary {
  totalEvents: number = 0;
  turnStarts: number = 0;
  turnEnds: number = 0;
  statusCounts: Record<string, number> = {};
  protocolCounts: Record<string, number> = {};
  toolCalls: ToolCallAgg[] = [];
  toolTotalCalls: number = 0;
  toolTotalOk: number = 0;
  toolTotalFail: number = 0;
  toolTotalTimeout: number = 0;
  toolTotalCancel: number = 0;
  toolTotalSchemaError: number = 0;
}

export class SessionLogAggregator {
  static aggregateToolCalls(events: Record<string, Object>[]): ToolCallAgg[] {
    let byName: Record<string, ToolCallAgg> = {};
    let durations: Record<string, number[]> = {};
    for (let i: number = 0; i < events.length; i++) {
      let ev: Record<string, Object> = events[i];
      if (ev['type'] !== 'tool_result') {
        continue;
      }
      let nameObj: Object | undefined = ev['name'];
      if (typeof nameObj !== 'string') {
        continue;
      }
      let name: string = nameObj as string;
      let agg: ToolCallAgg | undefined = byName[name];
      if (agg === undefined) {
        agg = new ToolCallAgg();
        agg.name = name;
        byName[name] = agg;
      }
      agg.calls++;
      let ok: boolean = (ev['ok'] as boolean) === true;
      if (ok) {
        agg.ok++;
      } else {
        agg.fail++;
      }
      if ((ev['timeout'] as boolean) === true) {
        agg.timeout++;
      }
      if ((ev['cancelled'] as boolean) === true) {
        agg.cancelled++;
      }
      if ((ev['schemaError'] as boolean) === true) {
        agg.schemaError++;
      }
      let durObj: Object | undefined = ev['durationMs'];
      if (typeof durObj === 'number') {
        let dur: number = durObj as number;
        agg.totalDurationMs += dur;
        let list: number[] | undefined = durations[name];
        if (list === undefined) {
          list = [];
          durations[name] = list;
        }
        list.push(dur);
      }
    }
    let names: string[] = Object.keys(byName);
    names.sort();
    let out: ToolCallAgg[] = [];
    for (let i: number = 0; i < names.length; i++) {
      let name: string = names[i];
      let agg: ToolCallAgg = byName[name];
      let list: number[] | undefined = durations[name];
      if (list !== undefined && list.length > 0) {
        agg.p50Ms = SessionLogAggregator.percentile(list, 0.50);
        agg.p90Ms = SessionLogAggregator.percentile(list, 0.90);
        agg.p99Ms = SessionLogAggregator.percentile(list, 0.99);
      }
      out.push(agg);
    }
    return out;
  }

  // 最近邻分位数(0..1): 排序后取 Math.ceil(p*n)-1 下标; 空列表返回 0
  static percentile(values: number[], p: number): number {
    if (values.length === 0) {
      return 0;
    }
    let sorted: number[] = values.slice();
    sorted.sort((a: number, b: number): number => {
      if (a < b) {
        return -1;
      }
      if (a > b) {
        return 1;
      }
      return 0;
    });
    let idx: number = Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1));
    return sorted[idx];
  }

  // 由 tool_result 事件生成按工具的延迟分位数事件(供日志汇总/可视化消费)
  static buildToolLatencyEvents(events: Record<string, Object>[]): Record<string, Object>[] {
    let aggs: ToolCallAgg[] = SessionLogAggregator.aggregateToolCalls(events);
    let out: Record<string, Object>[] = [];
    for (let i: number = 0; i < aggs.length; i++) {
      let a: ToolCallAgg = aggs[i];
      out.push({
        'type': 'tool_latency',
        'name': a.name,
        'calls': a.calls,
        'p50Ms': a.p50Ms,
        'p90Ms': a.p90Ms,
        'p99Ms': a.p99Ms
      });
    }
    return out;
  }

  // 跨会话聚合: 输入多个会话的事件数组, 合并协议/turn/工具统计与延迟分位
  static aggregateAll(eventGroups: Record<string, Object>[][]): SessionLogSummary {
    let merged: Record<string, Object>[] = [];
    for (let g: number = 0; g < eventGroups.length; g++) {
      let group: Record<string, Object>[] = eventGroups[g];
      for (let i: number = 0; i < group.length; i++) {
        merged.push(group[i]);
      }
    }
    return SessionLogAggregator.summarize(merged);
  }

  static summarize(events: Record<string, Object>[]): SessionLogSummary {
    let s: SessionLogSummary = new SessionLogSummary();
    s.totalEvents = events.length;
    for (let i: number = 0; i < events.length; i++) {
      let ev: Record<string, Object> = events[i];
      let type: string = ev['type'] as string;
      if (type === 'turn_start') {
        s.turnStarts++;
        let protoObj: Object | undefined = ev['protocol'];
        if (typeof protoObj === 'string' && (protoObj as string) !== '') {
          let proto: string = protoObj as string;
          let pc: number = s.protocolCounts[proto] !== undefined ? s.protocolCounts[proto] : 0;
          s.protocolCounts[proto] = pc + 1;
        }
      } else if (type === 'turn_end') {
        s.turnEnds++;
        let statusObj: Object | undefined = ev['status'];
        if (typeof statusObj === 'string') {
          let status: string = statusObj as string;
          let cur: number = s.statusCounts[status] !== undefined ? s.statusCounts[status] : 0;
          s.statusCounts[status] = cur + 1;
        }
      }
    }
    s.toolCalls = SessionLogAggregator.aggregateToolCalls(events);
    for (let i: number = 0; i < s.toolCalls.length; i++) {
      let a: ToolCallAgg = s.toolCalls[i];
      s.toolTotalCalls += a.calls;
      s.toolTotalOk += a.ok;
      s.toolTotalFail += a.fail;
      s.toolTotalTimeout += a.timeout;
      s.toolTotalCancel += a.cancelled;
      s.toolTotalSchemaError += a.schemaError;
    }
    return s;
  }
}
