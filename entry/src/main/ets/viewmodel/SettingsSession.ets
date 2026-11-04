import { ChatViewModel } from './ChatViewModel';

// 设置页是独立路由页, 不能像普通组件那样通过 @Prop 接收 ChatViewModel。
// 这里用模块级单例把聊天页正在使用的同一个 VM 交给设置页, 两边读写同一份内存状态,
// 保存后关闭设置页即可在聊天页看到最新配置, 不需要重新加载或额外复制一份配置对象。
export class SettingsSession {
  private static vm: ChatViewModel | null = null;

  static bind(viewModel: ChatViewModel): void {
    SettingsSession.vm = viewModel;
  }

  static current(): ChatViewModel | null {
    return SettingsSession.vm;
  }
}
