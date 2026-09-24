// 工作模式(Agent Loop)单次工具调用记录
// 同一实例同时承载三条信息: 模型的调用参数(argsJson)、执行结果(result)、执行状态(durationMs<0 表示执行中)
// 会话持久化时随 Message.toJson 一起落盘, 重启后据此还原步骤时间线与 LLM 历史
export class ToolCallRecord {
  id: string = '';
  name: string = '';
  argsJson: string = '';
  result: string = '';
  isError: boolean = false;
  // 执行耗时(毫秒); -1 表示尚未执行完成
  durationMs: number = -1;
  // 结构化展示数据(JSON 字符串), 如 edit 工具的 diff 卡片; 随会话持久化供 UI 重放
  meta: string = '';
  // 运行态标记(不持久化): true 表示模型还在流式生成调用参数, 尚未开始执行;
  // 区分时间线上的"生成调用中"与"执行中/等待中"状态
  preparing: boolean = false;
  // 运行态标记(不持久化): true 表示该调用已真正启动执行(区别于仍在排队等待)
  started: boolean = false;
  // 可观测标记(持久化): 由执行护栏设置, 用于审计工具超时率/取消率/schema 错误率
  timeout: boolean = false;
  cancelled: boolean = false;
  schemaError: boolean = false;
  // 请求级 traceId(持久化): 跨会话归因单次工具调用
  traceId: string = '';

  static of(id: string, name: string, argsJson: string): ToolCallRecord {
    let rec: ToolCallRecord = new ToolCallRecord();
    rec.id = id;
    rec.name = name;
    rec.argsJson = argsJson;
    rec.result = '';
    rec.isError = false;
    rec.durationMs = -1;
    rec.timeout = false;
    rec.cancelled = false;
    rec.schemaError = false;
    rec.traceId = '';
    return rec;
  }

  static fromJson(json: Record<string, Object>): ToolCallRecord {
    let rec: ToolCallRecord = new ToolCallRecord();
    rec.id = (json['id'] as string) ?? '';
    rec.name = (json['name'] as string) ?? '';
    rec.argsJson = (json['argsJson'] as string) ?? '';
    rec.result = (json['result'] as string) ?? '';
    rec.isError = (json['isError'] as boolean) ?? false;
    rec.durationMs = (json['durationMs'] as number) ?? -1;
    rec.meta = (json['meta'] as string) ?? '';
    rec.timeout = (json['timeout'] as boolean) ?? false;
    rec.cancelled = (json['cancelled'] as boolean) ?? false;
    rec.schemaError = (json['schemaError'] as boolean) ?? false;
    rec.traceId = (json['traceId'] as string) ?? '';
    return rec;
  }

  toJson(): Record<string, Object> {
    return {
      'id': this.id,
      'name': this.name,
      'argsJson': this.argsJson,
      'result': this.result,
      'isError': this.isError,
      'durationMs': this.durationMs,
      'meta': this.meta,
      'timeout': this.timeout,
      'cancelled': this.cancelled,
      'schemaError': this.schemaError,
      'traceId': this.traceId
    };
  }
}
