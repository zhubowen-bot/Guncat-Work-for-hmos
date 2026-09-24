import { Agent } from '../model/Agent';
import { ConversationListItem } from '../model/ConversationListItem';
import { router } from '@kit.ArkUI';

// 智能体 / 对话抽屉 (对齐 web 版本 .drawer)
// 会话列表传轻量投影 ConversationListItem(避免 @Prop 深拷贝全部消息导致打开卡顿)
@Component
export struct AgentDrawerView {
  // @Prop: 父组件 (ChatPage) 重渲染时新数组会传递进来, 解决删除/新建对话后侧边栏不更新
  // 之前用 private 字段, 父级 vm.conversations 变了子组件读不到
  @Prop agents: Agent[] = [];
  @Prop conversations: ConversationListItem[] = [];
  @Prop currentAgentId: string = '';
  @Prop currentConversationId: string = '';
  private onSelectAgent: (id: string) => void = (_id: string): void => {};
  private onSelectConversation: (id: string) => void = (_id: string): void => {};
  private onDeleteConversation: (id: string) => void = (_id: string): void => {};
  private onNewConversation: () => void = (): void => {};
  private onPlayGuide: () => void = (): void => {};
  private onClose: () => void = (): void => {};

  build() {
    Stack() {
      // 抽屉主体；遮罩/阴影由 ChatPage 的全屏 scrim 负责，避免阴影跟随抽屉滑动
      Column() {
        // 头部
        Row() {
          Image($r('app.media.cat_avatar'))
            .width(32)
            .height(32)
            .borderRadius(16)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('app.color.brand_light'))
          Text('Guncat Work')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .margin({ left: 8 })
            .layoutWeight(1)
          Button() {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(18)
              .fontColor([$r('app.color.text_secondary')])
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor($r('app.color.raised_surface'))
          .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
          .onClick(() => {
            this.onPlayGuide();
          })
        }
        .width('100%')
        .height(64)
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.surface'))
        .shadow({ radius: 16, color: '#0C000000', offsetX: 0, offsetY: 2 })
        .alignItems(VerticalAlign.Center)

        // 新建对话
        // 用包裹 Column 的 padding 实现左右内边距, 避免按钮 width('100%') + margin 溢出
        Column() {
          Button() {
            Row() {
              Text('+ 新建对话')
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .height(38)
          .borderRadius(18)
          .backgroundColor($r('app.color.brand_light'))
          .onClick(() => {
            this.onNewConversation();
          })
        }
        .width('100%')
        .padding({ left: 14, right: 14 })
        .margin({ top: 10, bottom: 8 })

        // 工具: 表格提取
        Column() {
          Button() {
            Row() {
              SymbolGlyph($r('sys.symbol.square_grid_2x2'))
                .fontSize(15)
                .fontColor([$r('app.color.brand')])
              Text('表格提取')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .fontWeight(FontWeight.Medium)
                .margin({ left: 8 })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .height(38)
          .borderRadius(18)
          .backgroundColor($r('app.color.raised_surface'))
          .shadow({ radius: 12, color: '#12000000', offsetX: 0, offsetY: 3 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/TableOcrPage' });
          })
        }
        .width('100%')
        .padding({ left: 14, right: 14 })
        .margin({ bottom: 10 })

        // Agent引擎分组(独立小节, 置于「聊天模式」标题上方; 小标题与条目样式和聊天模式完全一致)
        Column() {
          Text('Agent引擎')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .letterSpacing(0.5)
            .width('100%')
            .padding({ left: 20, right: 20, top: 4, bottom: 10 })
          Column() {
            ForEach(this.workAgents(), (agent: Agent) => {
              this.buildAgentItem(agent);
            }, (agent: Agent) => agent.id)
          }
          .width('100%')
          .padding({ left: 14, right: 14 })
        }
        .width('100%')

        // 聊天引擎列表
        Column() {
          Text('聊天引擎')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .letterSpacing(0.5)
            .width('100%')
            .padding({ left: 20, right: 20, top: 4, bottom: 10 })
          List() {
            ForEach(this.chatAgents(), (agent: Agent) => {
              ListItem() {
                this.buildAgentItem(agent);
              }
            }, (agent: Agent) => agent.id)
          }
          .width('100%')
          .layoutWeight(1)
          .listDirection(Axis.Vertical)
          .divider({ strokeWidth: 0 })
          .padding({ left: 14, right: 14 })
        }
        .width('100%')
        .layoutWeight(1)

        // 分割
        Divider().color($r('app.color.divider')).margin({ top: 8, left: 20, right: 20 })

        // 对话列表
        Column() {
          Text('历史对话')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .letterSpacing(0.5)
            .width('100%')
            .padding({ left: 20, right: 20, top: 12, bottom: 10 })
          List() {
            ForEach(this.conversations, (conv: ConversationListItem) => {
              ListItem() {
                this.buildConvItem(conv);
              }
            }, (conv: ConversationListItem) => conv.id)
          }
          .width('100%')
          .layoutWeight(1)
          .listDirection(Axis.Vertical)
          .divider({ strokeWidth: 0 })
          .padding({ left: 14, right: 14, bottom: 12 })
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('82%')
      .height('100%')
      .backgroundColor($r('app.color.surface'))
      .borderRadius({ topRight: 28, bottomRight: 28 })
      .alignItems(HorizontalAlign.Start)
      // 移除原 .shadow: 它的 radius 会向四个方向扩散, 导致顶部边线也出现阴影
      // 仅让抽屉 Column 向下延伸到底部系统安全区 (导航条), 不影响上侧
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      // 阴影改在 Stack 第一层 (遮罩层) 实现, 覆盖整个右侧 18% 露出区域, 不影响抽屉顶部
    }
    .width('100%')
    .height('100%')
    // Stack 默认居中, 改成左对齐让抽屉靠左
    .alignContent(Alignment.Start)
    // 空白区域不拦截点击，让下方的全屏 scrim 能响应关闭
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // Agent模式分组: 抽取 work 虚拟智能体, 作为独立小节展示在「聊天模式」标题上方
  private workAgents(): Agent[] {
    let list: Agent[] = [];
    for (let i: number = 0; i < this.agents.length; i++) {
      if (this.agents[i].id === 'work') {
        list.push(this.agents[i]);
      }
    }
    return list;
  }

  // 聊天智能体分组: 排除 work 虚拟项
  private chatAgents(): Agent[] {
    let list: Agent[] = [];
    for (let i: number = 0; i < this.agents.length; i++) {
      if (this.agents[i].id !== 'work') {
        list.push(this.agents[i]);
      }
    }
    return list;
  }

  @Builder
  buildAgentItem(agent: Agent) {
    Row() {
      // 工作模式虚拟智能体用机器人图标(无底色), 普通智能体用自定义图标或猫头像
      // 侧边栏机器人用 #0A59F7, 与轻简/效率/专家三个模式图标的蓝一致(非应用品牌蓝)
      if (agent.id === 'work') {
        Image($r('app.media.ic_work'))
          .width(32)
          .height(32)
          .fillColor('#0A59F7')
      } else {
        Image(agent.icon !== '' ? $rawfile(agent.icon) : $r('app.media.cat_avatar'))
          .width(32)
          .height(32)
          .borderRadius(16)
          .objectFit(ImageFit.Cover)
      }
      Column() {
        Text(agent.name)
          .fontSize(14)
          .fontWeight(this.currentAgentId === agent.id ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.currentAgentId === agent.id ? $r('app.color.brand') : $r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(agent.shortDescription !== '' ? agent.shortDescription : agent.description)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 10 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(18)
    .backgroundColor(this.currentAgentId === agent.id ? $r('app.color.brand_light') : Color.Transparent)
    .margin({ bottom: 6 })
    .onClick(() => {
      this.onSelectAgent(agent.id);
    })
  }

  @Builder
  buildConvItem(conv: ConversationListItem) {
    Row() {
      Text(this.getConvTitle(conv))
        .fontSize(14)
        .fontColor(this.currentConversationId === conv.id ? $r('app.color.brand') : $r('app.color.text_primary'))
        .fontWeight(this.currentConversationId === conv.id ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(14)
        .fontColor([$r('app.color.text_secondary')])
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(12)
        .onClick(() => {
          this.onDeleteConversation(conv.id);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(16)
    .backgroundColor(this.currentConversationId === conv.id ? $r('app.color.brand_light') : Color.Transparent)
    .margin({ bottom: 4 })
    .onClick(() => {
      this.onSelectConversation(conv.id);
    })
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
    return '新对话';
  }
}
