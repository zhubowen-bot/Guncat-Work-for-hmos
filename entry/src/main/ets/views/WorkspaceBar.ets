// 工作模式工作区面板: 挂在"工作模式"胶囊上方的弹层(文件列表 + 上传 / 导出 zip)
// 通过 @ObjectLink 直接观察 ChatViewModel 的工作区字段(workspaceFiles/workElapsedSec 变更时自动刷新)
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { WorkFileService, WorkspaceFileInfo } from '../service/WorkFileService';
import { Message } from '../model/Message';

// 工作区文件行按扩展名映射类别图标(sys.symbol), 未知类型回退通用文档图标
export class WorkspaceFileIcons {
  static iconFor(path: string): Resource {
    let dot: number = path.lastIndexOf('.');
    let ext: string = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
      case 'svg':
      case 'heic':
        return $r('sys.symbol.picture');
      case 'pdf':
        return $r('sys.symbol.pdf_doc');
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
      case 'tgz':
        return $r('sys.symbol.doc_zipper');
      case 'docx':
      case 'doc':
      case 'rtf':
      case 'odt':
        return $r('sys.symbol.doc_text');
      case 'pptx':
      case 'ppt':
        return $r('sys.symbol.rectangle_stack');
      case 'xlsx':
      case 'xls':
      case 'csv':
      case 'tsv':
        return $r('sys.symbol.grid');
      case 'md':
      case 'markdown':
        return $r('sys.symbol.text_and_arrow_down');
      case 'txt':
      case 'log':
      case 'yaml':
      case 'yml':
      case 'toml':
      case 'ini':
      case 'conf':
      case 'cfg':
      case 'properties':
      case 'env':
      case 'plist':
        return $r('sys.symbol.doc_plaintext');
      case 'json':
      case 'xml':
      case 'html':
      case 'htm':
      case 'css':
      case 'js':
      case 'jsx':
      case 'ts':
      case 'tsx':
      case 'py':
      case 'java':
      case 'kt':
      case 'kts':
      case 'swift':
      case 'c':
      case 'cpp':
      case 'h':
      case 'hpp':
      case 'cs':
      case 'go':
      case 'rs':
      case 'rb':
      case 'php':
      case 'sql':
      case 'sh':
      case 'bat':
      case 'gradle':
        return $r('sys.symbol.code');
      case 'mp3':
      case 'wav':
      case 'm4a':
      case 'aac':
      case 'flac':
      case 'ogg':
        return $r('sys.symbol.waveform');
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
      case 'webm':
        return $r('sys.symbol.movie');
      default:
        return $r('sys.symbol.doc');
    }
  }
}

@Component
export struct WorkspaceBar {
  @ObjectLink vm: ChatViewModel;
  private onUpload: () => void = (): void => {};
  private onExport: () => void = (): void => {};

  private formatWorkTime(totalSec: number): string {
    let h: number = Math.floor(totalSec / 3600);
    let m: number = Math.floor((totalSec % 3600) / 60);
    let s: number = totalSec % 60;
    let mm: string = m < 10 ? '0' + m.toString() : m.toString();
    let ss: string = s < 10 ? '0' + s.toString() : s.toString();
    if (h > 0) {
      let hh: string = h < 10 ? '0' + h.toString() : h.toString();
      return hh + ':' + mm + ':' + ss;
    }
    return mm + ':' + ss;
  }

  // 最近一条有缓存统计的 assistant 消息命中率 (0..1, -1 表示 API 未返回)
  private getCacheHitText(): string {
    let msgs: Message[] = this.vm.currentMessages;
    for (let i: number = msgs.length - 1; i >= 0; i--) {
      let m: Message = msgs[i];
      if (m.role === 'assistant' && m.cacheHitRate >= 0) {
        return Math.round(m.cacheHitRate * 100).toString() + '%';
      }
    }
    return '';
  }

  // 最近一条 assistant 消息的生成速度 (tok/s; 流式期间为实时估算值,
  // 该轮 usage 返回后被精确值覆盖; 无数据返回空串)
  private getSpeedText(): string {
    let msgs: Message[] = this.vm.currentMessages;
    for (let i: number = msgs.length - 1; i >= 0; i--) {
      let m: Message = msgs[i];
      if (m.role === 'assistant' && m.tokenSpeed > 0) {
        return m.tokenSpeed.toFixed(1) + ' tok/s';
      }
    }
    return '';
  }

  build() {
    Column({ space: 8 }) {
      // 头部行: 标题 + 右侧上传 / 导出按钮
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(15)
          .fontColor([$r('app.color.brand')])
        Text(this.getHeaderTitle())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        this.buildHeaderButton('上传', (): void => {
          this.onUpload();
        })
        this.buildHeaderButton('导出', (): void => {
          this.onExport();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 文件列表
      Scroll() {
        Column({ space: 4 }) {
          if (this.vm.workspaceFiles.length === 0) {
            // 空状态: 固定高度撑出竖向空间, 文字垂直居中, 不贴顶
            Column() {
              Text(this.vm.isStreaming ? '任务执行中...' : '工作区为空, 点击"上传"添加文件')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .height(180)
            .justifyContent(FlexAlign.Center)
          } else {
            ForEach(this.vm.workspaceFiles, (item: WorkspaceFileInfo) => {
              this.buildFileRow(item)
            }, (item: WorkspaceFileInfo) => item.path + '|' + item.size.toString())
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 280 })
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // 撑开剩余空间, 把统计行压到面板底部
      Blank()

      // 底部统计行(左下角): 会话工作时间 + 生成速度 + 缓存命中率
      Row({ space: 6 }) {
        // 会话工作时间: 任务执行中每秒走字, 停止后定格, 未执行过任务不显示
        if (this.vm.workElapsedSec > 0) {
          Text(this.formatWorkTime(this.vm.workElapsedSec))
            .fontSize(11)
            .fontColor(this.vm.isStreaming ?
              $r('app.color.text_secondary') : $r('app.color.text_tertiary'))
        }
        // 生成速度: 流式期间实时刷新(面板随 workElapsedSec 每秒重渲染), 停止后定格
        if (this.getSpeedText() !== '') {
          Text(this.getSpeedText())
            .fontSize(11)
            .fontColor(this.vm.isStreaming ?
              $r('app.color.text_secondary') : $r('app.color.text_tertiary'))
        }
        // 缓存命中率: 任务停止后显示最近一条 assistant 消息的命中率
        if (!this.vm.isStreaming && this.getCacheHitText() !== '') {
          Text('缓存命中 ' + this.getCacheHitText())
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
    }
    .width(220)
    .constraintSize({ minHeight: 268 })
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .shadow({ radius: 24, color: '#2E000000', offsetX: 0, offsetY: 4 })
  }

  @Builder
  private buildHeaderButton(label: string, onTap: () => void) {
    Text(label)
      .fontSize(10)
      .fontColor(this.vm.isStreaming ? $r('app.color.text_tertiary') : $r('app.color.brand'))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(12)
      .backgroundColor($r('app.color.raised_surface'))
      // 白底胶囊按钮在白色卡片上靠阴影呈现立体感 (对齐输入区圆形按钮样式)
      .shadow({ radius: 12, color: '#14000000', offsetX: 0, offsetY: 3 })
      .opacity(this.vm.isStreaming ? 0.5 : 1)
      .onClick(() => {
        if (this.vm.isStreaming) {
          return;
        }
        onTap();
      })
  }

  @Builder
  private buildFileRow(item: WorkspaceFileInfo) {
    Row({ space: 8 }) {
      // 目录用文件夹图标, 文件按扩展名映射类别图标
      Row({ space: 8 }) {
        SymbolGlyph(item.isDir ? $r('sys.symbol.folder') : WorkspaceFileIcons.iconFor(item.path))
          .fontSize(14)
          .fontColor([$r('app.color.brand')])
        Text(item.path)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .onClick(() => {
        if (this.vm.isStreaming || item.isDir) {
          return;
        }
        this.vm.previewWorkspaceFile(item.path);
      })
      if (!item.isDir) {
        Text(WorkFileService.formatSize(item.size))
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
        // 一键分享原始文件: 不弹路径/压缩包/格式选择
        Text('分享')
          .fontSize(10)
          .fontColor($r('app.color.brand'))
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(8)
          .backgroundColor($r('app.color.brand_light'))
          .onClick(() => {
            if (this.vm.isStreaming) {
              return;
            }
            this.vm.shareWorkspaceFile(item.path);
          })
        Text('✕')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .padding({ left: 4, right: 2 })
          .onClick(() => {
            if (this.vm.isStreaming) {
              return;
            }
            this.vm.deleteWorkspaceFile(item.path);
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 6, bottom: 6 })
    .borderRadius(10)
    // 白色卡片上文件行改用输入框同款灰色底, 保持与白底按钮的层级区分
    .backgroundColor($r('app.color.input_bg'))
  }

  private getHeaderTitle(): string {
    if (this.vm.workspaceLoading) {
      return '工作区 · 读取中...';
    }
    let count: number = this.vm.workspaceFiles.length;
    let countText: string = count === 0 ? '空' : count.toString() + ' 项';
    return '工作区 · ' + countText;
  }
}
