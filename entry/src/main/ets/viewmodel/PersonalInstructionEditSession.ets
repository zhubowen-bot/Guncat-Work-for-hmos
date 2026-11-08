// 个性化指令编辑页是独立路由页, 不能像普通组件那样通过 @Prop 接收"要编辑哪一条"。
// 这里用模块级单例在跳转前交接一个指令 id (与 SettingsSession 交接 ChatViewModel 同一模式)。
// 约定: 空串 = 新建; take() 取出即清空, 避免"返回后再点新建"误用上一次的编辑 id。
export class PersonalInstructionEditSession {
  private static pendingId: string = '';

  static bind(id: string): void {
    PersonalInstructionEditSession.pendingId = id;
  }

  static take(): string {
    let id: string = PersonalInstructionEditSession.pendingId;
    PersonalInstructionEditSession.pendingId = '';
    return id;
  }
}
