import { Attachment } from './Attachment';
import { ToolCallRecord } from './ToolCallRecord';

// 消息(对齐 web 版本的 message 字段)
// 必须 @Observed 才能让 @ObjectLink 追踪属性变化 (流式输出时 content 增量更新)
@Observed
export class Message {
  id: string = '';
  role: string = 'user';
  content: string = '';
  displayContent: string = '';
  attachments: Attachment[] = [];
  timestamp: number = 0;
  // 工作模式(Agent Loop)中本条 assistant 消息发起的工具调用步骤; 聊天模式恒为空
  // 流式期间记录随 onToolCalls 即时进入该列表(preparing 态), 时间线得以实时展示
  toolCalls: ToolCallRecord[] = [];
  // 深度思考内容 (对齐 web 版本 msg.reasoning)
  reasoning: string = '';
  // 由 API 返回的 usage 派生的统计: token 速度(tok/s)与缓存命中率(0..1), -1 表示无返回值
  tokenSpeed: number = -1;
  cacheHitRate: number = -1;
  // Anthropic 协议思考块的签名(仅内存内有效, 不持久化): 聊天模式本地工具循环中,
  // 思考模式下带 tool_use 的 assistant 消息回传给下一轮请求时需随思考块携带签名
  thinkingSignature: string = '';

  static ofUser(id: string, content: string, displayContent: string,
    attachments: Attachment[]): Message {
    let msg: Message = new Message();
    msg.id = id;
    msg.role = 'user';
    msg.content = content;
    msg.displayContent = displayContent;
    msg.attachments = attachments;
    msg.timestamp = new Date().getTime();
    return msg;
  }

  static ofAssistant(id: string, content: string): Message {
    let msg: Message = new Message();
    msg.id = id;
    msg.role = 'assistant';
    msg.content = content;
    msg.displayContent = content;
    msg.attachments = [];
    msg.timestamp = new Date().getTime();
    return msg;
  }

  static fromJson(json: Record<string, Object>): Message {
    let msg: Message = new Message();
    msg.id = (json['id'] as string) ?? '';
    msg.role = (json['role'] as string) ?? 'user';
    msg.content = (json['content'] as string) ?? '';
    msg.displayContent = (json['displayContent'] as string) ?? '';
    msg.timestamp = (json['timestamp'] as number) ?? 0;
    msg.reasoning = (json['reasoning'] as string) ?? '';
    msg.tokenSpeed = (json['tokenSpeed'] as number) ?? -1;
    msg.cacheHitRate = (json['cacheHitRate'] as number) ?? -1;
    let raw: Object = json['attachments'];
    if (raw !== undefined) {
      let rawAttachments: Object[] = raw as Object[];
      let result: Attachment[] = [];
      for (let i: number = 0; i < rawAttachments.length; i++) {
        result.push(Attachment.fromJson(rawAttachments[i] as Record<string, Object>));
      }
      msg.attachments = result;
    }
    let rawCalls: Object = json['toolCalls'];
    if (rawCalls !== undefined && rawCalls instanceof Array) {
      let rawCallArr: Object[] = rawCalls as Object[];
      let calls: ToolCallRecord[] = [];
      for (let i: number = 0; i < rawCallArr.length; i++) {
        calls.push(ToolCallRecord.fromJson(rawCallArr[i] as Record<string, Object>));
      }
      msg.toolCalls = calls;
    }
    return msg;
  }

  toJson(): Record<string, Object> {
    let attArr: Object[] = [];
    for (let i: number = 0; i < this.attachments.length; i++) {
      attArr.push(this.attachments[i].toJson());
    }
    let callArr: Object[] = [];
    for (let i: number = 0; i < this.toolCalls.length; i++) {
      callArr.push(this.toolCalls[i].toJson());
    }
    return {
      'id': this.id,
      'role': this.role,
      'content': this.content,
      'displayContent': this.displayContent,
      'attachments': attArr,
      'timestamp': this.timestamp,
      'reasoning': this.reasoning,
      'tokenSpeed': this.tokenSpeed,
      'cacheHitRate': this.cacheHitRate,
      'toolCalls': callArr
    };
  }
}
