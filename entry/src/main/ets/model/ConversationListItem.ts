// ConversationListItem: 会话列表的轻量投影(仅 id/标题/归属/模式)
// 侧栏/抽屉经 @Prop 接收本列表 —— @Prop 会深拷贝数组, 若直接传 Conversation[]
// 会把全部消息与工具结果一并拷贝, 打开抽屉时在 UI 线程造成可感知的卡顿。
export class ConversationListItem {
  id: string = '';
  title: string = '';
  agentId: string = '';
  mode: string = 'chat';
}
