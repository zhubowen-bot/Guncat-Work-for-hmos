// DswSidebar: 桌面宽屏左侧栏(对齐 DeepSeek Harness 三栏框架的 sidebar 列)
// 宽屏常驻, 支持折叠为 56vp 图标栏(对齐 dsh 的 collapse rail); 品牌行 + 新建会话按钮 +
// 引擎切换 + 会话列表 + 底部设置, 视觉令牌全部来自 --dsw 同源色彩。
import { Agent } from '../model/Agent';
import { ConversationListItem } from '../model/ConversationListItem';

@Component
export struct DswSidebar {
  @Prop agents: Agent[] = [];
  @Prop conversations: ConversationListItem[] = [];
  @Prop currentAgentId: string = '';
  @Prop currentConversationId: string = '';
  @Prop collapsed: boolean = false;
  private onToggleCollapse: () => void = (): void => {};
  private onSelectAgent: (id: string) => void = (_id: string): void => {};
  private onSelectConversation: (id: string) => void = (_id: string): void => {};
  private onDeleteConversation: (id: string) => void = (_id: string): void => {};
  private onNewConversation: () => void = (): void => {};
  private onSettings: () => void = (): void => {};
  private onPlayGuide: () => void = (): void => {};
  private onOpenDetails: () => void = (): void => {};

  build() {
    Column() {
      // 品牌行(dsh logoRow: 60vp, 折叠时 36vp 图标)
      Row({ space: 8 }) {
        Image($r('app.media.cat_avatar'))
          .width(28)
          .height(28)
          .borderRadius(14)
          .objectFit(ImageFit.Cover)
        if (!this.collapsed) {
          Text('Guncat Work')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .layoutWeight(1)
          // 右侧栏开关(折叠)
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(18)
              .fontColor([$r('app.color.text_secondary')])
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.onToggleCollapse();
          })
        }
      }
      .width('100%')
      .height(this.collapsed ? 36 : 60)
      .padding({ left: this.collapsed ? 4 : 12, right: this.collapsed ? 4 : 12 })
      .alignItems(VerticalAlign.Center)
      .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)

      if (this.collapsed) {
        // 折叠栏: 竖排图标(展开/新建/工作区/设置)
        Column({ space: 12 }) {
          this.buildRailButton($r('sys.symbol.chevron_right'), (): void => this.onToggleCollapse())
          this.buildRailButton($r('sys.symbol.plus'), (): void => this.onNewConversation())
          this.buildRailButton($r('sys.symbol.doc_text'), (): void => this.onOpenDetails())
          Blank()
          this.buildRailAvatar((): void => this.onPlayGuide())
          this.buildRailButton($r('sys.symbol.gearshape'), (): void => this.onSettings())
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: 8, bottom: 12 })
        .alignItems(HorizontalAlign.Center)
      } else {
        // 新建会话(dsh newSession: 38vp bar, radius 12, elevated fill + l2 边框)
        Column() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(15)
              .fontColor([$r('app.color.text_primary')])
            Text('新建会话')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height(38)
        .margin({ bottom: 8 })
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.border') })
        .backgroundColor($r('app.color.raised_surface'))
        .onClick(() => {
          this.onNewConversation();
        })

        // 引擎(智能体)区
        Text('引擎')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .letterSpacing(1)
          .width('100%')
          .padding({ left: 8, bottom: 6 })
        Column({ space: 2 }) {
          ForEach(this.workAgents(), (agent: Agent) => {
            this.buildAgentItem(agent)
          }, (agent: Agent) => agent.id)
          ForEach(this.chatAgents(), (agent: Agent) => {
            this.buildAgentItem(agent)
          }, (agent: Agent) => agent.id)
        }
        .width('100%')

        // 会话列表
        Row({ space: 6 }) {
          Text('会话')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .letterSpacing(1)
          Blank()
          Text(this.conversations.length.toString())
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 12, bottom: 6 })

        List() {
          ForEach(this.conversations, (conv: ConversationListItem) => {
            ListItem() {
              this.buildConvItem(conv)
            }
          }, (conv: ConversationListItem) => conv.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ bottom: 8 })

        // 底部: 关于 + 设置
        Divider()
          .strokeWidth(1)
          .color($r('app.color.divider'))
          .margin({ top: 4, bottom: 6 })
        Row({ space: 4 }) {
          this.buildFootButton($r('sys.symbol.info_circle'), '玩转应用', (): void => this.onPlayGuide())
          this.buildFootButton($r('sys.symbol.doc_text'), '工作区', (): void => this.onOpenDetails())
          this.buildFootButton($r('sys.symbol.gearshape'), '设置', (): void => this.onSettings())
        }
        .width('100%')
        .padding({ bottom: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 6, bottom: 6, left: 6, right: 6 })
    .backgroundColor($r('app.color.sidebar_fill'))
  }

  @Builder
  private buildRailButton(icon: Resource, onTap: () => void) {
    Button() {
      SymbolGlyph(icon)
        .fontSize(19)
        .fontColor([$r('app.color.text_primary')])
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  private buildRailAvatar(onTap: () => void) {
    Button() {
      Image($r('app.media.cat_avatar'))
        .width(24)
        .height(24)
        .borderRadius(12)
        .objectFit(ImageFit.Cover)
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  private buildAgentItem(agent: Agent) {
    Row({ space: 8 }) {
      if (agent.id === 'work') {
        Image($r('app.media.ic_work'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.brand'))
      } else {
        Image(agent.icon !== '' ? $rawfile(agent.icon) : $r('app.media.cat_avatar'))
          .width(22)
          .height(22)
          .borderRadius(11)
          .objectFit(ImageFit.Cover)
      }
      Text(agent.name)
        .fontSize(13)
        .fontWeight(this.currentAgentId === agent.id ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentAgentId === agent.id ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(34)
    .padding({ left: 8, right: 8 })
    .borderRadius(8)
    .backgroundColor(this.currentAgentId === agent.id ?
      $r('app.color.sidebar_item_active') : Color.Transparent)
    .onClick(() => {
      this.onSelectAgent(agent.id);
    })
  }

  @Builder
  private buildConvItem(conv: ConversationListItem) {
    Row({ space: 6 }) {
      Text(this.getConvTitle(conv))
        .fontSize(13)
        .fontColor(this.currentConversationId === conv.id ?
          $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(13)
        .fontColor([$r('app.color.text_tertiary')])
        .padding(4)
        .borderRadius(8)
        .onClick(() => {
          this.onDeleteConversation(conv.id);
        })
    }
    .width('100%')
    .padding({ left: 8, right: 4, top: 7, bottom: 7 })
    .borderRadius(8)
    .backgroundColor(this.currentConversationId === conv.id ?
      $r('app.color.sidebar_item_active') : Color.Transparent)
    .onClick(() => {
      this.onSelectConversation(conv.id);
    })
  }

  @Builder
  private buildFootButton(icon: Resource, label: string, onTap: () => void) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(17)
        .fontColor([$r('app.color.text_secondary')])
      Text(label)
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
    }
    .layoutWeight(1)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .onClick(() => {
      onTap();
    })
  }

  private workAgents(): Agent[] {
    let list: Agent[] = [];
    for (let i: number = 0; i < this.agents.length; i++) {
      if (this.agents[i].id === 'work') {
        list.push(this.agents[i]);
      }
    }
    return list;
  }

  private chatAgents(): Agent[] {
    let list: Agent[] = [];
    for (let i: number = 0; i < this.agents.length; i++) {
      if (this.agents[i].id !== 'work') {
        list.push(this.agents[i]);
      }
    }
    return list;
  }

  private getConvTitle(conv: ConversationListItem): string {
    if (conv.title !== '') {
      return conv.title;
    }
    for (let i: number = 0; i < this.agents.length; i++) {
      if (this.agents[i].id === conv.agentId) {
        return '与 ' + this.agents[i].name + ' 的对话';
      }
    }
    return '新会话';
  }
}
