// LegalPage: 设置 →「合规与许可」。
//
// 只承载两类内容：
// - AI 生成内容标识说明；
// - 第三方组件与许可（含随包许可证原文）。
//
// 设计目标：和设置页一致的浅色卡片、蓝色品牌点、紧凑但不拥挤；
// 文档正文使用项目已有的 RichTextView，保证表格、标题和列表渲染一致。
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { RichTextView } from '../views/RichTextView';
import { LegalDoc, LegalDocuments, LegalLicense } from '../common/LegalDocuments';
import { Constants } from '../common/Constants';

@Entry
@Component
struct LegalPage {
  @State private view: string = 'home';
  @State private docId: string = '';
  @State private licenseFile: string = '';
  @State private licenseTitle: string = '';
  @State private licenseText: string = '';
  @State private rawText: string = '';
  @State private loading: boolean = false;

  private titleText(): string {
    if (this.view === 'doc') {
      let doc: LegalDoc | null = LegalDocuments.find(this.docId);
      return doc !== null ? doc.title : '文档';
    }
    if (this.view === 'rawDoc') {
      return '完整第三方声明';
    }
    if (this.view === 'licenses') {
      return '开源许可证';
    }
    if (this.view === 'licenseDoc') {
      return this.licenseTitle;
    }
    return '合规与许可';
  }

  private goBack(): void {
    if (this.view === 'home') {
      router.back();
      return;
    }
    if (this.view === 'licenseDoc') {
      this.view = 'licenses';
      return;
    }
    if (this.view === 'rawDoc') {
      this.docId = 'thirdparty';
      this.view = 'doc';
      return;
    }
    if (this.view === 'licenses') {
      this.view = 'home';
      return;
    }
    this.view = 'home';
  }

  onBackPress(): boolean {
    if (this.view === 'home') {
      return false;
    }
    this.goBack();
    return true;
  }

  build() {
    Column() {
      this.buildHeader()
      if (this.view === 'home') {
        this.buildHome()
      } else if (this.view === 'doc') {
        this.buildDoc()
      } else if (this.view === 'rawDoc') {
        this.buildRawDoc()
      } else if (this.view === 'licenses') {
        this.buildLicenseList()
      } else {
        this.buildLicenseDoc()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.sidebar_fill'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

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
        .onClick(() => {
          this.goBack();
        })

        Text(this.titleText())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })

        Text('v' + Constants.APP_VERSION)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(999)
          .backgroundColor($r('app.color.surface_secondary'))
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
  }

  @Builder
  private buildHero() {
    Column() {
      Row({ space: 14 }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(34)
          .fontColor([$r('app.color.brand')])
          .flexShrink(0)

        Column({ space: 4 }) {
          Text('合规与许可')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('AI 生成内容标识与第三方组件声明')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(18)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(24)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildHome() {
    Scroll() {
      Column() {
        Column() {
          this.buildHero()

          this.buildSectionLabel('AI 与内容标识')
          Column() {
            this.buildDocRow($r('sys.symbol.wand_and_stars'), LegalDocuments.AIGC, (): void => {
              this.openDoc('aigc');
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.divider') })
          .clip(true)

          this.buildSectionLabel('第三方组件')
          Column() {
            this.buildDocRow($r('sys.symbol.link'), LegalDocuments.THIRD_PARTY, (): void => {
              this.openDoc('thirdparty');
            })
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ left: 66 })
            this.buildActionRow($r('sys.symbol.list_checkmark'), '开源许可证全文',
              '查看随包分发的许可证原文', (): void => {
                this.view = 'licenses';
              })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.divider') })
          .clip(true)

          Text('更新日期 ' + LegalDocuments.UPDATED + ' · Version ' + Constants.APP_VERSION)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 18, bottom: 8 })
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

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
  private buildDocRow(icon: Resource, doc: LegalDoc, onTap: () => void) {
    Row({ space: 12 }) {
      Row() {
        SymbolGlyph(icon)
          .fontSize(22)
          .fontColor([$r('app.color.brand')])
      }
      .width(26)
      .height(26)
      .justifyContent(FlexAlign.Center)

      Column({ space: 3 }) {
        Text(doc.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(doc.summary)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(15)
        .fontColor([$r('app.color.text_quaternary')])
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  private buildActionRow(icon: Resource, title: string, subtitle: string, onTap: () => void) {
    Row({ space: 12 }) {
      Row() {
        SymbolGlyph(icon)
          .fontSize(22)
          .fontColor([$r('app.color.brand')])
      }
      .width(26)
      .height(26)
      .justifyContent(FlexAlign.Center)

      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(15)
        .fontColor([$r('app.color.text_quaternary')])
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      onTap();
    })
  }

  private openDoc(id: string): void {
    this.docId = id;
    this.view = 'doc';
  }

  @Builder
  private buildDoc() {
    if (this.docId === '') {
      this.buildEmpty()
    } else {
      Scroll() {
        Column() {
          Column() {
            this.buildDocMeta()
            Column() {
              RichTextView({ content: this.currentDocBody() })
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(22)
            .border({ width: 1, color: $r('app.color.divider') })
            .clip(true)

            if (this.docId === 'thirdparty') {
              this.buildWideButton('查看完整第三方声明', $r('sys.symbol.doc_text'), (): void => {
                this.loadRawDoc();
              })
              this.buildWideButton('查看许可证全文', $r('sys.symbol.list_checkmark'), (): void => {
                this.view = 'licenses';
              })
            }
          }
          .width('100%')
          .constraintSize({ maxWidth: 720 })
          .padding({ left: 16, right: 16, top: 8, bottom: 24 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  private buildDocMeta() {
    Column({ space: 6 }) {
      Text(this.currentDocTitle())
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Row({ space: 8 }) {
        Text('更新 ' + LegalDocuments.UPDATED)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Text('Version ' + Constants.APP_VERSION)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      Text(this.currentDocSummary())
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(18)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 12 })
  }

  private currentDocBody(): string {
    let doc: LegalDoc | null = LegalDocuments.find(this.docId);
    return doc !== null ? doc.body : '';
  }

  private currentDocTitle(): string {
    let doc: LegalDoc | null = LegalDocuments.find(this.docId);
    return doc !== null ? doc.title : '文档';
  }

  private currentDocSummary(): string {
    let doc: LegalDoc | null = LegalDocuments.find(this.docId);
    return doc !== null ? doc.summary : '';
  }

  @Builder
  private buildWideButton(label: string, icon: Resource, onTap: () => void) {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph(icon)
          .fontSize(16)
          .fontColor([$r('app.color.brand')])
        Text(label)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(46)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface_secondary'))
    .margin({ top: 12 })
    .onClick(() => {
      onTap();
    })
  }

  private loadRawDoc(): void {
    this.loading = true;
    this.rawText = '';
    this.view = 'rawDoc';
    let context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.resourceManager.getRawFileContent('licenses/THIRD_PARTY_NOTICES.md')
      .then((data: Uint8Array) => {
        let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        this.rawText = decoder.decodeToString(data, { stream: false });
        this.loading = false;
      })
      .catch((error: Error) => {
        this.rawText = '无法读取完整声明：' + error.message;
        this.loading = false;
      });
  }

  @Builder
  private buildRawDoc() {
    Scroll() {
      Column() {
        Column() {
          if (this.loading) {
            this.buildLoading()
          } else {
            Column() {
              RichTextView({ content: this.rawText })
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(22)
            .border({ width: 1, color: $r('app.color.divider') })
            .clip(true)
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private buildLicenseList() {
    Scroll() {
      Column() {
        Column() {
          Column({ space: 4 }) {
          Text('随包许可证原文')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('共 ' + LegalDocuments.LICENSES.length.toString() +
            ' 份，均随应用包分发。点击查看全文。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(18)
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(20)
        .border({ width: 1, color: $r('app.color.divider') })
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 12 })

        Column() {
          ForEach(LegalDocuments.LICENSES, (item: LegalLicense, index: number) => {
            if (index > 0) {
              Divider()
                .strokeWidth(0.5)
                .color($r('app.color.divider'))
                .margin({ left: 14 })
            }
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text(item.label)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text(item.license + ' · ' + item.file)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([$r('app.color.text_quaternary')])
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.loadLicense(item);
            })
          }, (item: LegalLicense) => item.file)
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })
        .clip(true)
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  private loadLicense(item: LegalLicense): void {
    this.licenseFile = item.file;
    this.licenseTitle = item.label;
    this.licenseText = '';
    this.loading = true;
    this.view = 'licenseDoc';
    let context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.resourceManager.getRawFileContent(item.file)
      .then((data: Uint8Array) => {
        let decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        this.licenseText = decoder.decodeToString(data, { stream: false });
        this.loading = false;
      })
      .catch((error: Error) => {
        this.licenseText = '无法读取许可证原文：' + error.message;
        this.loading = false;
      });
  }

  @Builder
  private buildLicenseDoc() {
    Scroll() {
      Column() {
        Column() {
          if (this.loading) {
            this.buildLoading()
          } else {
            Column() {
              Row({ space: 8 }) {
                Text(this.licenseTitle)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(this.licenseFile)
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 10 })

              Divider()
                .strokeWidth(0.5)
                .color($r('app.color.divider'))

              Text(this.licenseText)
                .fontSize(12)
                .lineHeight(19)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding(14)
                .copyOption(CopyOptions.LocalDevice)
                .wordBreak(WordBreak.BREAK_ALL)
            }
            .width('100%')
            .backgroundColor($r('app.color.surface'))
            .borderRadius(22)
            .border({ width: 1, color: $r('app.color.divider') })
            .clip(true)
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private buildLoading() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(26)
        .height(26)
        .color($r('app.color.brand'))
      Text('正在读取随包文件…')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 60, bottom: 60 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private buildEmpty() {
    Column({ space: 8 }) {
      Text('没有找到这份文档')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 80 })
    .alignItems(HorizontalAlign.Center)
  }
}
