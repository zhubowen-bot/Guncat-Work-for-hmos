import { Message } from './Message';
import { generateConversationId } from '../common/Utils';

// 对话(对齐 web 版本的 guncat_conversations)
export class Conversation {
  id: string = '';
  agentId: string = '';
  title: string = '';
  messages: Message[] = [];
  createdAt: number = 0;
  // 会话模式: 'chat' 聊天模式 | 'work' 工作模式(Agent Loop + 沙箱工作区); 旧数据缺省为 chat
  mode: string = 'chat';

  static create(agentId: string, title: string, mode: string): Conversation {
    let conv: Conversation = new Conversation();
    conv.id = generateConversationId();
    conv.agentId = agentId;
    conv.title = title;
    conv.mode = mode;
    conv.createdAt = new Date().getTime();
    return conv;
  }

  static fromJson(json: Record<string, Object>): Conversation {
    let conv: Conversation = new Conversation();
    conv.id = (json['id'] as string) ?? '';
    conv.agentId = (json['agentId'] as string) ?? '';
    conv.title = (json['title'] as string) ?? '';
    conv.createdAt = (json['createdAt'] as number) ?? 0;
    conv.mode = (json['mode'] as string) ?? 'chat';
    let raw: Object = json['messages'];
    if (raw !== undefined) {
      let rawMessages: Object[] = raw as Object[];
      let result: Message[] = [];
      for (let i: number = 0; i < rawMessages.length; i++) {
        result.push(Message.fromJson(rawMessages[i] as Record<string, Object>));
      }
      conv.messages = result;
    }
    return conv;
  }

  toJson(): Record<string, Object> {
    let msgs: Object[] = [];
    for (let i: number = 0; i < this.messages.length; i++) {
      msgs.push(this.messages[i].toJson());
    }
    return {
      'id': this.id,
      'agentId': this.agentId,
      'title': this.title,
      'messages': msgs,
      'createdAt': this.createdAt,
      'mode': this.mode
    };
  }
}
