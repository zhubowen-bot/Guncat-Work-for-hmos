// 个性化指令编辑页: 独立路由页, 负责新建 / 编辑单条用户偏好(名称 + 正文 + 生效范围)。
// 入口在设置页「能力 → 个性化指令」; 列表与跳转由 SettingsPage 负责, 本页只编辑一条。
// 传参: 跳转前调用 PersonalInstructionEditSession.bind(id), 本页 aboutToAppear 里 take()。
// 保存的始终是用户原文; Markdown 渲染只切换本页预览, 不改变落盘内容。
import { router, promptAction } from '@kit.ArkUI';
import { Agent } from '../model/Agent';
import { PersonalInstruction } from '../model/PersonalInstruction';
import { PersonalInstructionPrompt } from '../common/PersonalInstructionPrompt';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { SettingsSession } from '../viewmodel/SettingsSession';
import { PersonalInstructionEditSession } from '../viewmodel/PersonalInstructionEditSession';
import { RichTextView } from '../views/RichTextView';

@Entry
@Component
struct PersonalInstructionEditPage {
  // 聊天页共享的 ViewModel(引擎列表 / 保存 / 删除都走它)
  private vm: ChatViewModel | null = null;
  // 正在编辑的条目 id; 空串 = 新建
  private editId: string = '';
  // 打开时的原始快照(未保存退出提醒用); 普通成员, 不进入渲染
  private originalName: string = '';
  private originalContent: string = '';
  private originalScopes: string = '';

  // 编辑草稿
  @State private name: string = '';
  @State private content: string = '';
  @State private scopes: string[] = [];
  @State private previewOn: boolean = false;
  @State private saving: boolean = false;
  // 聊天引擎列表快照(VM 内部数组不受本页状态观察, 进页取一份)
  @State private engines: Agent[] = [];

  aboutToAppear(): void {
    this.vm = SettingsSession.current();
    if (this.vm === null) {
      // 进程恢复等极端情况下没有聊天页 VM: 直接返回, 避免操作空对象
      setTimeout((): void => {
        router.back();
      }, 0);
      return;
    }
    this.engines = this.vm.chatEngines();
    this.editId = PersonalInstructionEditSession.take();
    let item: PersonalInstruction | null = null;
    if (this.editId !== '') {
      item = this.vm.personalInstructionById(this.editId);
    }
    if (item !== null) {
      this.name = item.name;
      this.content = item.content;
      this.scopes = PersonalInstruction.sortScopesByOrder(item.scopes, this.scopeOrder());
    } else {
      // 新建, 或原条目已被删除: 都按新建处理(并清空可能残留的编辑 id)
      this.editId = '';
      this.name = '';
      this.content = '';
      this.scopes = [PersonalInstructionPrompt.SCOPE_INTERACTIVE,
        PersonalInstructionPrompt.SCOPE_WORK];
    }
    this.captureOriginal();
  }

  build() {
    Column() {
      this.buildHeader()

      Scroll() {
        Column() {
          this.buildSectionLabel('名称（可选）')
          this.buildNameCard()
          this.buildNameHint()
          this.buildContentCard()
          this.buildContentHint()
          this.buildSectionLabel('生效范围')
          this.buildScopeCard()
          this.buildFooterNoteCard()
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16, bottom: 16 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      this.buildBottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.sidebar_fill'))
    // 只把页面底色延伸到屏幕底部导航条安全区；顶部状态栏保持原样
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  // ===== 顶栏: 返回 + 标题 + 编辑态删除 =====
  @Builder
  private buildHeader() {
    Column() {
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.handleBack();
        })

        Text(this.pageTitle())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .margin({ left: 8 })

        if (this.editId !== '') {
          Button() {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(18)
              .fontColor([$r('app.color.text_secondary')])
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor(Color.Transparent)
          .onClick((): void => {
            this.deleteItem();
          })
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .height(56)
      .padding({ left: 10, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(56)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.surface'))
    .border({ width: { bottom: 0.5 }, color: { bottom: $r('app.color.divider') } })
  }

  // ===== 名称(可选) =====
  @Builder
  private buildSectionLabel(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4 })
      .margin({ top: 12, bottom: 8 })
  }

  @Builder
  private buildNameCard() {
    Column() {
      TextInput({ placeholder: '例如：英文回答、代码风格', text: this.name })
        .width('100%')
        .height(46)
        .borderRadius(14)
        .backgroundColor($r('app.color.surface_secondary'))
        .padding({ left: 12, right: 12 })
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .maxLength(PersonalInstruction.MAX_NAME_CHARS)
        .onChange((value: string): void => {
          this.name = value;
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(22)
    .border({ width: 1, color: $r('app.color.divider') })
  }

  @Builder
  private buildNameHint() {
    Text('不填时用指令正文第一行作为列表标题。')
      .fontSize(11)
      .fontColor($r('app.color.text_tertiary'))
      .lineHeight(17)
      .width('100%')
      .padding({ left: 4, right: 4 })
      .margin({ top: 8 })
  }

  // ===== 指令内容: 原文编辑 / Markdown 预览 =====
  @Builder
  private buildContentCard() {
    Column() {
      Row() {
        Text('指令内容')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)

        // 预览开关: 只影响本页展示, 保存的始终是原文
        Row() {
          SymbolGlyph($r('sys.symbol.doc_text'))
            .fontSize(14)
            .fontColor([this.previewOn ? $r('app.color.brand') : $r('app.color.text_secondary')])
          Text(this.previewOn ? '返回编辑' : 'Markdown 渲染')
            .fontSize(12)
            .fontColor(this.previewOn ? $r('app.color.brand') : $r('app.color.text_secondary'))
            .margin({ left: 4 })
        }
        .height(30)
        .padding({ left: 10, right: 10 })
        .borderRadius(15)
        .backgroundColor(this.previewOn ? $r('app.color.brand_light') : $r('app.color.raised_surface'))
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.previewOn = !this.previewOn;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.previewOn) {
        if (this.content.trim() !== '') {
          RichTextView({ content: this.content })
        } else {
          Text('没有可预览的内容')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding(16)
        }
      } else {
        Column() {
          TextArea({
            placeholder: '写下你的指令、偏好或约束，例如语气、输出格式、常用术语，支持 Markdown。',
            text: this.content
          })
            .width('100%')
            .height(200)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .maxLength(PersonalInstruction.MAX_CONTENT_CHARS)
            .onChange((value: string): void => {
              this.content = value;
            })
          Text(this.content.length.toString() + ' / ' +
            PersonalInstruction.MAX_CONTENT_CHARS.toString())
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.End)
            .margin({ top: 6 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 14 })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(22)
    .border({ width: 1, color: $r('app.color.divider') })
    .margin({ top: 12 })
  }

  @Builder
  private buildContentHint() {
    Text('渲染只影响这里的预览；保存的始终是原始文本，纯文本也能直接保存。')
      .fontSize(11)
      .fontColor($r('app.color.text_tertiary'))
      .lineHeight(17)
      .width('100%')
      .padding({ left: 4, right: 4 })
      .margin({ top: 8 })
  }

  // ===== 生效范围: 两个模式 + 各聊天引擎, 多选 =====
  @Builder
  private buildScopeCard() {
    Column() {
      this.buildScopeGroupTitle('模式')
      this.buildScopeRow(PersonalInstructionPrompt.SCOPE_INTERACTIVE, '交互模式',
        '每轮回答直接交付可操作界面')
      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.divider'))
        .margin({ left: 40 })
      this.buildScopeRow(PersonalInstructionPrompt.SCOPE_WORK, '工作模式',
        '多轮工具循环，完成长程任务')

      this.buildScopeGroupTitle('聊天引擎')
      if (this.engines.length === 0) {
        Text('暂无可用的聊天引擎')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 12 })
      } else {
        ForEach(this.engines, (engine: Agent, index: number) => {
          if (index > 0) {
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ left: 40 })
          }
          this.buildScopeRow(engine.id, engine.name, engine.description)
        }, (engine: Agent) => engine.id)
      }

      Text(this.scopeSummaryText())
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(17)
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 14 })
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(22)
    .border({ width: 1, color: $r('app.color.divider') })
    .clip(true)
  }

  @Builder
  private buildScopeGroupTitle(title: string) {
    Text(title)
      .fontSize(11)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: 16 })
      .margin({ top: 12, bottom: 6 })
  }

  // 一个可多选的生效范围行: 左侧勾选圈, 右侧标题 + 副标题, 整行点击切换
  @Builder
  private buildScopeRow(scope: string, title: string, subtitle: string) {
    Row() {
      Column() {
        if (this.isScopeSelected(scope)) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(20)
            .fontColor([$r('app.color.brand')])
        } else {
          Column()
            .width(18)
            .height(18)
            .borderRadius(9)
            .border({ width: 1.5, color: $r('app.color.text_quaternary') })
        }
      }
      .width(20)
      .alignItems(HorizontalAlign.Center)

      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(subtitle)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
    }
    .width('100%')
    .padding({ left: 14, right: 16, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.toggleScope(scope);
    })
  }

  // 底部说明: 保存后拼进系统提示词的方式与生效时机
  @Builder
  private buildFooterNoteCard() {
    Column() {
      Text('保存后，这些内容会作为「个性化指令」段落，附加到所选模式 / 聊天引擎的系统提示词末尾；从下一次请求开始生效，不改变工具与权限。')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(17)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(22)
    .border({ width: 1, color: $r('app.color.divider') })
    .margin({ top: 16, bottom: 8 })
  }

  // ===== 底部主操作: 新建「添加」/ 编辑「保存」 =====
  @Builder
  private buildBottomBar() {
    Column() {
      Button() {
        Text(this.editId !== '' ? '保存' : '添加')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      .width('100%')
      .height(46)
      .borderRadius(23)
      .backgroundColor($r('app.color.brand'))
      .enabled(!this.saving)
      .onClick((): void => {
        this.save();
      })
    }
    .width('100%')
    .constraintSize({ maxWidth: 720 })
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  // ===== 状态与行为 =====
  private pageTitle(): string {
    return this.editId !== '' ? '编辑个性化指令' : '新建个性化指令';
  }

  // 生效范围的稳定顺序: 交互模式 → 工作模式 → 聊天引擎(按列表顺序), 与保存时规范化一致
  private scopeOrder(): string[] {
    let order: string[] = [PersonalInstructionPrompt.SCOPE_INTERACTIVE,
      PersonalInstructionPrompt.SCOPE_WORK];
    for (let i: number = 0; i < this.engines.length; i++) {
      order.push(this.engines[i].id);
    }
    return order;
  }

  private isScopeSelected(scope: string): boolean {
    return this.scopes.indexOf(scope) !== -1;
  }

  // @State 数组按引用替换, 保证更新被界面观察到
  private toggleScope(scope: string): void {
    let next: string[] = this.scopes.slice();
    let index: number = next.indexOf(scope);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(scope);
    }
    this.scopes = next;
  }

  private scopeSummaryText(): string {
    if (this.scopes.length === 0) {
      return '尚未选择生效范围，保存后不会生效。';
    }
    let ordered: string[] = PersonalInstruction.sortScopesByOrder(this.scopes, this.scopeOrder());
    let labels: string[] = [];
    let vm: ChatViewModel | null = this.vm;
    for (let i: number = 0; i < ordered.length; i++) {
      labels.push(vm !== null ? vm.personalScopeLabel(ordered[i]) : ordered[i]);
    }
    return '将附加到：' + labels.join('、');
  }

  // ===== 未保存退出提醒 =====
  // 原始快照用普通成员而不是 @State: 它只用于比较, 不参与渲染
  private captureOriginal(): void {
    this.originalName = this.name;
    this.originalContent = this.content;
    this.originalScopes = this.sortedScopesKey();
  }

  // 用规范化后的范围集合做快照, 避免"取消又勾上"这类顺序变化被误判为有修改
  private sortedScopesKey(): string {
    return PersonalInstruction.sortScopesByOrder(this.scopes, this.scopeOrder()).join('|');
  }

  private isDirty(): boolean {
    if (this.name !== this.originalName || this.content !== this.originalContent) {
      return true;
    }
    return this.sortedScopesKey() !== this.originalScopes;
  }

  private handleBack(): void {
    if (!this.isDirty()) {
      router.back();
      return;
    }
    this.confirmDiscard();
  }

  onBackPress(): boolean {
    if (!this.isDirty()) {
      return false;
    }
    this.confirmDiscard();
    return true;
  }

  private async confirmDiscard(): Promise<void> {
    try {
      let res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '放弃编辑？',
        message: '还有未保存的修改，返回后这些修改会丢失。',
        buttons: [
          { text: '取消', color: '#6B7280' },
          { text: '放弃', color: '#E05252' }
        ]
      });
      if (res.index === 1) {
        router.back();
      }
    } catch (e) {
      // 弹窗不可用时留在当前页, 不丢修改
    }
  }

  // ===== 保存 / 删除 =====
  private async save(): Promise<void> {
    let vm: ChatViewModel | null = this.vm;
    if (vm === null || this.saving) {
      return;
    }
    if (this.content.trim() === '') {
      promptAction.showToast({ message: '请先输入指令内容', duration: 1600 });
      return;
    }
    if (this.scopes.length === 0) {
      promptAction.showToast({ message: '请至少选择一个生效范围', duration: 1600 });
      return;
    }
    this.saving = true;
    let scopes: string[] = PersonalInstruction.sortScopesByOrder(this.scopes, this.scopeOrder());
    let item: PersonalInstruction = PersonalInstruction.create(this.name, this.content, scopes);
    if (this.editId !== '') {
      // 编辑: 保留原 id 与创建身份, 只更新内容和保存时间
      item.id = this.editId;
      item.updatedAt = Date.now();
    }
    try {
      await vm.savePersonalInstruction(item);
      router.back();
    } catch (e) {
      this.saving = false;
      promptAction.showToast({ message: '保存失败，请稍后重试', duration: 2000 });
    }
  }

  private async deleteItem(): Promise<void> {
    let vm: ChatViewModel | null = this.vm;
    if (vm === null || this.editId === '') {
      return;
    }
    try {
      let res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '删除个性化指令',
        message: '删除后会立即从所有生效范围移除，且无法恢复。',
        buttons: [
          { text: '取消', color: '#6B7280' },
          { text: '删除', color: '#E05252' }
        ]
      });
      if (res.index !== 1) {
        return;
      }
      await vm.deletePersonalInstruction(this.editId);
      router.back();
    } catch (e) {
      // 弹窗取消 / 删除失败时留在当前页
    }
  }
}
