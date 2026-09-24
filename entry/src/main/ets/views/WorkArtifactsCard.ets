// WorkArtifactsCard: 工作模式产物汇总卡片(Codex 风格 Changes)
// 默认展开列出改动文件; 每个文件的行级 diff 缩略默认折叠, 点箭头展开; 文件可点击就地预览、一键分享原始文件。
import { WorkArtifactFile } from '../common/WorkArtifacts';
import { FileDiff } from '../common/DiffUtil';
import { WorkspaceFileIcons } from './WorkspaceBar';

class ArtifactDiffRow {
  type: string = 'same';
  text: string = '';
}

@Component
export struct WorkArtifactsCard {
  @Prop files: WorkArtifactFile[] = [];
  @Prop totalAdds: number = 0;
  @Prop totalDels: number = 0;
  private onPreview: (path: string) => void = (_path: string): void => {};
  private onShare: (path: string) => void = (_path: string): void => {};
  @State expanded: boolean = true;
  // 每个文件的行级 diff 缩略独立折叠, 默认折叠
  @State expandedDiffFiles: string[] = [];

  build() {
    Column({ space: 6 }) {
      // 折叠头: 产物数量 + 增减统计 + 展开箭头
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(16)
          .fontColor([$r('app.color.brand')])
        Column() {
          Text('产物')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.files.length.toString() + ' 个文件 · +' + this.totalAdds.toString() +
            ' -' + this.totalDels.toString())
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        this.expanded = !this.expanded;
      })

      if (this.expanded) {
        Column({ space: 6 }) {
          ForEach(this.files, (file: WorkArtifactFile) => {
            this.buildFile(file)
          }, (file: WorkArtifactFile) => file.path)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(4)
    .borderRadius(14)
    .border({ width: 1, color: $r('app.color.divider') })
    .backgroundColor($r('app.color.raised_surface'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildFile(file: WorkArtifactFile) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Row({ space: 8 }) {
          SymbolGlyph(WorkspaceFileIcons.iconFor(file.path))
            .fontSize(14)
            .fontColor([$r('app.color.brand')])
          Text(file.path)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .layoutWeight(1)
        .onClick(() => {
          this.onPreview(file.path);
        })
        if (file.adds > 0 || file.dels > 0) {
          Text('+' + file.adds.toString() + ' -' + file.dels.toString())
            .fontSize(10)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_tertiary'))
        }
        if (file.hasDiff && file.diff !== null) {
          SymbolGlyph(this.isFileDiffExpanded(file.path) ?
            $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(10)
            .fontColor([$r('app.color.text_tertiary')])
            .padding({ left: 2, right: 2, top: 4, bottom: 4 })
            .onClick(() => {
              this.toggleFileDiff(file.path);
            })
        }
        Text('预览')
          .fontSize(10)
          .fontColor($r('app.color.brand'))
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(8)
          .backgroundColor($r('app.color.brand_light'))
          .onClick(() => {
            this.onPreview(file.path);
          })
        Text('分享')
          .fontSize(10)
          .fontColor($r('app.color.brand'))
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(8)
          .backgroundColor($r('app.color.brand_light'))
          .onClick(() => {
            this.onShare(file.path);
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 2 })

      if (file.hasDiff && file.diff !== null && this.isFileDiffExpanded(file.path)) {
        // diff 缩略: 最多 8 行, 保留 + / - 增删着色; 默认折叠, 点箭头展开
        Column({ space: 1 }) {
          ForEach(this.diffPreviewRows(file.diff), (row: ArtifactDiffRow, idx: number) => {
            Text((row.type === 'add' ? '+ ' : row.type === 'del' ? '- ' : '  ') + row.text)
              .fontSize(10)
              .fontFamily('monospace')
              .fontColor(row.type === 'add' ? $r('app.color.diff_add') :
                row.type === 'del' ? $r('app.color.diff_del') : $r('app.color.text_tertiary'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (row: ArtifactDiffRow, idx: number) => idx.toString() + row.type + row.text)
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(8)
        .backgroundColor($r('app.color.code_bg'))
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
    .borderRadius(10)
    .backgroundColor($r('app.color.input_bg'))
  }

  private isFileDiffExpanded(path: string): boolean {
    return this.expandedDiffFiles.indexOf(path) >= 0;
  }

  private toggleFileDiff(path: string): void {
    let idx: number = this.expandedDiffFiles.indexOf(path);
    if (idx >= 0) {
      let next: string[] = [];
      for (let i: number = 0; i < this.expandedDiffFiles.length; i++) {
        if (i !== idx) {
          next.push(this.expandedDiffFiles[i]);
        }
      }
      this.expandedDiffFiles = next;
    } else {
      let next: string[] = this.expandedDiffFiles.slice();
      next.push(path);
      this.expandedDiffFiles = next;
    }
  }

  private diffPreviewRows(diff: FileDiff): ArtifactDiffRow[] {
    let rows: ArtifactDiffRow[] = [];
    for (let i: number = 0; i < diff.hunks.length && rows.length < 8; i++) {
      let lines = diff.hunks[i].lines;
      for (let j: number = 0; j < lines.length && rows.length < 8; j++) {
        let row: ArtifactDiffRow = new ArtifactDiffRow();
        row.type = lines[j].type;
        row.text = lines[j].text;
        rows.push(row);
      }
    }
    return rows;
  }
}
