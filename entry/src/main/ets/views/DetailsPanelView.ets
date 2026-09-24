// DetailsPanelView: 桌面宽屏右侧详情栏(对齐 DeepSeek Harness 的 details 列)
// 工作区文件浏览 + 任务清单/目标概览 + 本轮统计(tok/s、缓存命中、耗时), 可由边栏开关收起。
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { WorkspaceFileInfo } from '../service/WorkFileService';
import { WorkspaceFileIcons } from './WorkspaceBar';
import { WorkFileService } from '../service/WorkFileService';
import { GoalService, GoalItem } from '../service/GoalService';
import { Message } from '../model/Message';
import { common } from '@kit.AbilityKit';

@Component
export struct DetailsPanelView {
  @ObjectLink vm: ChatViewModel;
  @Prop @Watch('onExternalRefresh') refreshTick: number = 0;
  private onUpload: () => void = (): void => {};
  private onExport: () => void = (): void => {};
  private onDeleteFile: (path: string) => void = (_p: string): void => {};
  private onRefresh: () => void = (): void => {};
  private onClose: () => void = (): void => {};
  // 展示数据走本地 @State 投影: @ObjectLink 对 vm 内部字段变更的观察在宽屏常驻面板上不可靠,
  // 改由 1s 定时器 + refreshTick(@Watch) 双驱动把 vm 数据同步进来, 保证面板实时刷新
  // (与 WorkTurnView 流式文本的轮询投影同一机制)
  @State private files: WorkspaceFileInfo[] = [];
  @State private elapsedSec: number = 0;
  @State private speedText: string = '—';
  @State private cacheText: string = '—';
  @State private toolCallCount: number = 0;
  @State private goal: string = '';
  private syncTimer: number = -1;

  aboutToAppear(): void {
    this.syncFromVm();
    this.syncTimer = setInterval((): void => {
      this.syncFromVm();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.syncTimer !== -1) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
  }

  // 上传/删除/手动刷新等动作由 ChatPage 递增 refreshTick, 立即同步一次
  onExternalRefresh(): void {
    this.syncFromVm();
  }

  // 把 vm 的展示字段投影进本地 @State; 仅在实际变化时赋值, 空闲秒 tick 不触发无谓重渲染
  private syncFromVm(): void {
    if (this.vm.workspaceFiles !== this.files) {
      this.files = this.vm.workspaceFiles;
    }
    if (this.vm.workElapsedSec !== this.elapsedSec) {
      this.elapsedSec = this.vm.workElapsedSec;
    }
    let last: Message | null = this.lastAssistant();
    let nextSpeed: string = last !== null && last.tokenSpeed > 0 ?
      Math.round(last.tokenSpeed).toString() + ' 字符/秒' : '—';
    if (nextSpeed !== this.speedText) {
      this.speedText = nextSpeed;
    }
    let nextCache: string = last !== null && last.cacheHitRate >= 0 ?
      Math.round(last.cacheHitRate * 100).toString() + '%' : '—';
    if (nextCache !== this.cacheText) {
      this.cacheText = nextCache;
    }
    let nextCalls: number = last !== null ? last.toolCalls.length : 0;
    if (nextCalls !== this.toolCallCount) {
      this.toolCallCount = nextCalls;
    }
    let nextGoal: string = this.readGoalText();
    if (nextGoal !== this.goal) {
      this.goal = nextGoal;
    }
  }

  private currentConvMessages(): Message[] {
    return this.vm.currentMessages;
  }

  private lastAssistant(): Message | null {
    let msgs: Message[] = this.currentConvMessages();
    for (let i: number = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role === 'assistant') {
        return msgs[i];
      }
    }
    return null;
  }

  private readGoalText(): string {
    if (this.vm.context === null || this.vm.currentConversationId === '') {
      return '';
    }
    let ctx: common.UIAbilityContext = this.vm.context;
    let root: string = WorkFileService.workspaceRoot(ctx, this.vm.currentConversationId);
    let goal: GoalItem | null = GoalService.read(root);
    return goal !== null ? goal.objective : '';
  }

  build() {
    Column() {
      // 面板头
      Row({ space: 8 }) {
        Text('工作区详情')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(15)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.onRefresh();
        })
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(15)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .padding({ left: 14, right: 10, top: 10, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 统计卡
          Column({ space: 6 }) {
            Text('本轮统计')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .letterSpacing(1)
            this.buildStatRow('任务用时', this.elapsedSec.toString() + ' 秒')
            this.buildStatRow('输出速度', this.speedText)
            this.buildStatRow('缓存命中', this.cacheText)
            this.buildStatRow('工具调用轮数', this.toolCallCount.toString())
          }
          .width('100%')
          .padding(12)
          .borderRadius(12)
          .border({ width: 1, color: $r('app.color.divider') })
          .alignItems(HorizontalAlign.Start)

          // 目标卡
          if (this.goal !== '') {
            Column({ space: 6 }) {
              Text('当前目标')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .letterSpacing(1)
              Text(this.goal)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(18)
                .width('100%')
            }
            .width('100%')
            .padding(12)
            .borderRadius(12)
            .border({ width: 1, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)
          }

          // 文件卡
          Column({ space: 8 }) {
            Row() {
              Text('文件 (' + this.files.length.toString() + ')')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .letterSpacing(1)
                .layoutWeight(1)
              Text('上传')
                .fontSize(11)
                .fontColor($r('app.color.brand'))
                .padding({ left: 8, right: 4, top: 2, bottom: 2 })
                .onClick(() => {
                  this.onUpload();
                })
              Text('导出')
                .fontSize(11)
                .fontColor($r('app.color.brand'))
                .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .onClick(() => {
                  this.onExport();
                })
            }
            .width('100%')

            if (this.files.length === 0) {
              Text('(工作区为空)')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .padding({ top: 8, bottom: 8 })
            } else {
              ForEach(this.files, (item: WorkspaceFileInfo) => {
                Row({ space: 6 }) {
                  if (item.isDir) {
                    SymbolGlyph($r('sys.symbol.folder'))
                      .fontSize(14)
                      .fontColor([$r('app.color.text_tertiary')])
                  } else {
                    SymbolGlyph(WorkspaceFileIcons.iconFor(item.path))
                      .fontSize(14)
                      .fontColor([$r('app.color.text_tertiary')])
                  }
                  Text(item.path)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  if (!item.isDir) {
                    Text(WorkFileService.formatSize(item.size))
                      .fontSize(10)
                      .fontColor($r('app.color.text_tertiary'))
                    SymbolGlyph($r('sys.symbol.trash'))
                      .fontSize(12)
                      .fontColor([$r('app.color.text_tertiary')])
                      .padding(3)
                      .onClick(() => {
                        this.onDeleteFile(item.path);
                      })
                  }
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
              }, (item: WorkspaceFileInfo) => item.path + '#' + item.size.toString())
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius(12)
          .border({ width: 1, color: $r('app.color.divider') })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 10, right: 10, bottom: 12 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }

  @Builder
  private buildStatRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
      Text(value)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
  }
}
