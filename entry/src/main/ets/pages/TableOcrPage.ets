import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { ApiConfig } from '../model/ApiConfig';
import { ApiProfile } from '../model/ApiProfile';
import { StorageManager } from '../data/StorageManager';
import { Constants } from '../common/Constants';
import { FileService, PickedFile } from '../service/FileService';
import { TableOcrService } from '../service/TableOcrService';
import { HtmlTableParser, TableGridInfo, TableCellInfo, TableRowInfo } from '../export/TableHtmlParser';
import { XlsxExporter } from '../export/XlsxExporter';
import { XmlUtil } from '../export/XmlUtil';

// 预览用单元格 (带网格坐标)
export class PreviewCell {
  r: number = 0;
  c: number = 0;
  rowspan: number = 1;
  colspan: number = 1;
  text: string = '';
  isHeader: boolean = false;
  height: number = 36;
}

// 表格识别可选的模型项：来自所有 API Profile 的主模型 + 多模态解析模型
export class OcrModelOption {
  key: string = '';
  label: string = '';
  model: string = '';
  baseUrl: string = '';
  apiKey: string = '';
  configType: string = 'main';
  profileName: string = '';

  constructor(key: string, label: string, model: string, baseUrl: string, apiKey: string,
    configType: string, profileName: string) {
    this.key = key;
    this.label = label;
    this.model = model;
    this.baseUrl = baseUrl;
    this.apiKey = apiKey;
    this.configType = configType;
    this.profileName = profileName;
  }
}

const COLUMN_WIDTH: number = 90;
const BASE_ROW_HEIGHT: number = 36;
const LINE_VP: number = 18;

@Entry
@Component
struct TableOcrPage {
  @State providerIndex: number = 0;
  @State selectedUri: string = '';
  @State converting: boolean = false;
  @State statusText: string = '';
  @State errorMsg: string = '';
  @State activeTab: number = 0;
  @State grid: TableGridInfo | null = null;
  @State currentHtml: string = '';
  @State excelInfo: string = '';
  @State gridInfoLines: string[] = [];
  @State gridInfoOk: boolean = true;
  @State debugText: string = '';
  @State previewCells: PreviewCell[] = [];
  @State gridTotalHeight: number = 120;
  private profiles: ApiProfile[] = [];
  @State modelOptions: OcrModelOption[] = [];
  private selectedBytes: ArrayBuffer | null = null;
  private selectedMime: string = 'image/jpeg';

  aboutToAppear(): void {
    this.loadConfig();
  }

  private async loadConfig(): Promise<void> {
    let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      this.profiles = await this.loadProfiles(context);
    } catch (e) {
      this.profiles = [ApiProfile.fromLegacy('默认配置', ApiConfig.default(), MultimodalConfig.default())];
    }
    this.modelOptions = this.buildModelOptions(this.profiles);
    let savedProvider: string = await StorageManager.loadString(
      context, Constants.LS_KEY_TABLE_OCR_PROVIDER, '');
    let savedIndex: number = this.findSavedModelIndex(savedProvider);
    this.providerIndex = savedIndex >= 0 ? savedIndex : 0;
  }

  // 加载所有 API Profile；无 profile 时用旧版单配置降级
  private async loadProfiles(context: common.UIAbilityContext): Promise<ApiProfile[]> {
    let profiles: ApiProfile[] = await StorageManager.loadApiProfiles(context);
    if (profiles.length === 0) {
      let api: ApiConfig | null = await StorageManager.loadApiConfig(context);
      let legacyApi: ApiConfig = api !== null ? api : ApiConfig.default();
      let legacyMm: MultimodalConfig = await StorageManager.loadMultimodalConfig(context);
      return [ApiProfile.fromLegacy('默认配置', legacyApi, legacyMm)];
    }
    return profiles;
  }

  // 把所有 Profile 的主模型 + 多模态解析模型拍平成下拉选项
  private buildModelOptions(profiles: ApiProfile[]): OcrModelOption[] {
    let options: OcrModelOption[] = [];
    let seenModels: string[] = [];
    for (let i: number = 0; i < profiles.length; i++) {
      let profile: ApiProfile = profiles[i];
      if (profile.apiConfig.model !== '' && seenModels.indexOf(profile.apiConfig.model) === -1) {
        seenModels.push(profile.apiConfig.model);
        options.push(new OcrModelOption(
          profile.id + '|main',
          profile.apiConfig.model,
          profile.apiConfig.model,
          profile.apiConfig.baseUrl,
          profile.apiConfig.apiKey,
          'main',
          profile.name
        ));
      }
      if (profile.multimodalConfig.model !== '' && seenModels.indexOf(profile.multimodalConfig.model) === -1) {
        seenModels.push(profile.multimodalConfig.model);
        options.push(new OcrModelOption(
          profile.id + '|multimodal',
          profile.multimodalConfig.model,
          profile.multimodalConfig.model,
          profile.multimodalConfig.baseUrl,
          profile.multimodalConfig.apiKey,
          'multimodal',
          profile.name
        ));
      }
    }
    return options;
  }

  private findSavedModelIndex(saved: string): number {
    if (saved.indexOf('|') !== -1) {
      for (let i: number = 0; i < this.modelOptions.length; i++) {
        if (this.modelOptions[i].key === saved) {
          return i;
        }
      }
      return -1;
    }
    let type: string = '';
    if (saved === 'main' || saved === 'volc') {
      type = 'main';
    } else if (saved === 'multimodal' || saved === 'zhipu') {
      type = 'multimodal';
    }
    if (type === '') {
      return -1;
    }
    for (let i: number = 0; i < this.modelOptions.length; i++) {
      if (this.modelOptions[i].configType === type) {
        return i;
      }
    }
    return -1;
  }

  private getModelSelectOptions(): SelectOption[] {
    let options: SelectOption[] = [];
    for (let i: number = 0; i < this.modelOptions.length; i++) {
      options.push({ value: this.modelOptions[i].label });
    }
    if (options.length === 0) {
      options.push({ value: '未配置模型' });
    }
    return options;
  }

  private getSelectedConfigName(): string {
    if (this.providerIndex >= 0 && this.providerIndex < this.modelOptions.length) {
      return this.modelOptions[this.providerIndex].label;
    }
    return '未配置模型';
  }

  private buildOcrConfig(): MultimodalConfig {
    let config: MultimodalConfig = new MultimodalConfig();
    if (this.providerIndex >= 0 && this.providerIndex < this.modelOptions.length) {
      let option: OcrModelOption = this.modelOptions[this.providerIndex];
      config.baseUrl = option.baseUrl;
      config.model = option.model;
      config.apiKey = option.apiKey;
    }
    return config;
  }

  private async persistProvider(): Promise<void> {
    let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    let key: string = '';
    if (this.providerIndex >= 0 && this.providerIndex < this.modelOptions.length) {
      key = this.modelOptions[this.providerIndex].key;
    }
    await StorageManager.saveString(context, Constants.LS_KEY_TABLE_OCR_PROVIDER, key);
  }

  private async pickImage(): Promise<void> {
    if (this.converting) {
      return;
    }
    let files: PickedFile[] = [];
    try {
      files = await FileService.pickImages();
    } catch (e) {
      this.errorMsg = '选择图片失败: ' + (e as Error).message;
      return;
    }
    if (files.length === 0) {
      return;
    }
    let file: PickedFile = files[0];
    this.selectedUri = file.uri;
    this.selectedBytes = file.buffer;
    this.selectedMime = file.fileType;
    this.errorMsg = '';
    this.statusText = '';
    this.grid = null;
    this.currentHtml = '';
  }

  private clearAll(): void {
    this.selectedUri = '';
    this.selectedBytes = null;
    this.errorMsg = '';
    this.statusText = '';
    this.grid = null;
    this.currentHtml = '';
    this.excelInfo = '';
    this.gridInfoLines = [];
    this.debugText = '';
    this.previewCells = [];
  }

  private async startRecognize(): Promise<void> {
    if (this.selectedBytes === null) {
      return;
    }
    if (this.modelOptions.length === 0) {
      this.errorMsg = '请先在设置中配置主模型或多模态解析模型';
      return;
    }
    let configName: string = this.getSelectedConfigName();
    let config: MultimodalConfig = this.buildOcrConfig();
    if (config.apiKey === '') {
      this.errorMsg = '请先填写 API Key';
      return;
    }
    this.errorMsg = '';
    this.converting = true;
    this.statusText = '正在调用 ' + configName + ' (' + (config.model !== '' ? config.model : '未命名模型') + ')...';
    let raw: string = '';
    try {
      let compressed = await TableOcrService.compressImage(this.selectedBytes);
      raw = await TableOcrService.recognizeImage(config, compressed);
      let html: string = TableOcrService.cleanHtml(raw);
      let parsed: TableGridInfo = HtmlTableParser.parse(html);
      this.currentHtml = html;
      this.grid = parsed;
      this.debugText = HtmlTableParser.debugJson(parsed);
      this.buildPreview(parsed);
      this.buildGridInfo(parsed);
      this.buildExcelInfo(parsed);
      this.activeTab = 0;
      this.statusText = '✓ 识别完成';
    } catch (e) {
      let err: Error = e as Error;
      let detail: string = raw !== '' ? raw.substring(0, 1200) : '';
      this.errorMsg = err.message + (detail !== '' ? '\n原始输出：' + detail : '');
      this.debugText = raw;
      this.statusText = '✗ 失败';
    } finally {
      this.converting = false;
    }
  }

  // 构建预览单元格列表 (带坐标与高度)
  private buildPreview(info: TableGridInfo): void {
    let heights: number[] = [];
    let rows: number = info.totalRows;
    for (let r: number = 0; r < rows; r++) {
      let h: number = BASE_ROW_HEIGHT;
      if (info.rowData[r].dataLines > 1) {
        h = info.rowData[r].dataLines * LINE_VP;
      }
      heights.push(Math.max(h, BASE_ROW_HEIGHT));
    }
    let cells: PreviewCell[] = [];
    for (let r: number = 0; r < rows; r++) {
      for (let c: number = 0; c < info.maxCols; c++) {
        let cell: TableCellInfo | null = info.grid[r][c];
        if (cell === null) {
          continue;
        }
        let pc: PreviewCell = new PreviewCell();
        pc.r = r;
        pc.c = c;
        pc.rowspan = cell.rowspan;
        pc.colspan = cell.colspan;
        pc.text = cell.text;
        pc.isHeader = cell.isHeader;
        let total: number = 0;
        for (let dr: number = 0; dr < cell.rowspan; dr++) {
          total += heights[r + dr];
        }
        let textLines: number = 1;
        if (cell.text.indexOf('\n') !== -1) {
          textLines = cell.text.split('\n').length;
        }
        pc.height = Math.max(total, textLines * LINE_VP + 10);
        cells.push(pc);
      }
    }
    let totalHeight: number = 0;
    for (let r: number = 0; r < heights.length; r++) {
      totalHeight += heights[r];
    }
    this.previewCells = cells;
    this.gridTotalHeight = totalHeight;
  }

  private columnsTemplate(): string {
    let s: string = '';
    let cols: number = this.grid !== null ? this.grid.maxCols : 1;
    for (let i: number = 0; i < cols; i++) {
      s += COLUMN_WIDTH.toString() + 'vp ';
    }
    return s.trim();
  }

  private buildGridInfo(info: TableGridInfo): void {
    let lines: string[] = [];
    let ok: boolean = true;
    lines.push('共 ' + info.totalRows.toString() + ' 行 × ' + info.maxCols.toString() + ' 列');
    for (let r: number = 0; r < info.grid.length; r++) {
      if (info.grid[r].length !== info.maxCols) {
        lines.push('⚠ 第 ' + (r + 1).toString() + ' 行: ' + info.grid[r].length.toString() +
          ' 列 (应为 ' + info.maxCols.toString() + ')');
        ok = false;
      }
    }
    if (ok) {
      lines.push('✓ 列数一致性校验通过');
    }
    for (let r: number = 0; r < info.rowData.length; r++) {
      let row: TableRowInfo = info.rowData[r];
      if (row.dataLines > 1 || row.dataH !== '') {
        lines.push('高行: 第' + (r + 1).toString() + '行 (data-lines=' + row.dataLines.toString() +
          (row.dataH !== '' ? ', data-h=' + row.dataH : '') + ')');
      }
    }
    this.gridInfoLines = lines;
    this.gridInfoOk = ok;
  }

  private buildExcelInfo(info: TableGridInfo): void {
    let merges: number = 0;
    for (let r: number = 0; r < info.grid.length; r++) {
      for (let c: number = 0; c < info.maxCols; c++) {
        let cell: TableCellInfo | null = info.grid[r][c];
        if (cell !== null && (cell.rowspan > 1 || cell.colspan > 1)) {
          merges++;
        }
      }
    }
    let highRows: number = 0;
    for (let r: number = 0; r < info.rowData.length; r++) {
      if (info.rowData[r].dataLines > 1) {
        highRows++;
      }
    }
    this.excelInfo = info.totalRows.toString() + ' 行 × ' + info.maxCols.toString() + ' 列 · ' +
      merges.toString() + ' 个合并 · ' + highRows.toString() + ' 个高行';
  }

  private async copyHtml(): Promise<void> {
    if (this.currentHtml === '') {
      return;
    }
    let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.currentHtml);
    await pasteboard.getSystemPasteboard().setData(data);
    promptAction.showToast({ message: '已复制', duration: 1500 });
  }

  private async downloadHtml(): Promise<void> {
    if (this.currentHtml === '') {
      return;
    }
    let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      let encoder: util.TextEncoder = new util.TextEncoder();
      let bytes: Uint8Array = encoder.encodeInto(this.currentHtml);
      let fileName: string = await XlsxExporter.saveBytesViaPicker(context, bytes,
        '表格-' + XmlUtil.stamp(), '.html');
      promptAction.showToast({ message: '已保存 ' + fileName, duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: '保存失败: ' + (e as Error).message, duration: 2000 });
    }
  }

  private async downloadExcel(): Promise<void> {
    if (this.grid === null) {
      return;
    }
    let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      let fileName: string = await XlsxExporter.exportXlsx(context,
        this.grid.grid, this.grid.rowData, this.grid.maxCols);
      promptAction.showToast({ message: '已导出 ' + fileName, duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: '导出失败: ' + (e as Error).message, duration: 2000 });
    }
  }

  build() {
    Column() {
      this.buildHeader()
      Scroll() {
        Column() {
          this.buildApiSection()
          this.buildUploadSection()
          if (this.grid !== null) {
            this.buildResultSection()
          }
          if (this.errorMsg !== '') {
            this.buildErrorBox()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 32 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }

  @Builder
  buildHeader() {
    Column() {
      Row() {
        Button() {
          Text('‹')
            .fontSize(28)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: -4 })
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          router.back();
        })
        Text('表格识别插件')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 8 })
        Blank()
      }
      .width('100%')
      .height(58)
      .padding({ left: 8, right: 16 })
      .alignItems(VerticalAlign.Center)
      Text('图片 → HTML 表格 → Excel（保留合并单元格 + 行高）')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 12 })
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 16, color: '#0D000000', offsetX: 0, offsetY: 2 })
  }

  // ============ 1. API 设置 ============
  @Builder
  buildApiSection() {
    Column() {
      this.buildStepTitle('1', '模型选择')
      Select(this.getModelSelectOptions())
        .selected(this.providerIndex)
        .width('100%')
        .height(44)
        .borderRadius(16)
        .backgroundColor($r('app.color.surface_secondary'))
        .font({ size: 14 })
        .onSelect((index: number) => {
          if (this.providerIndex === index) {
            return;
          }
          this.providerIndex = index;
          this.persistProvider();
        })
      Text('请选择具有多模态能力的识别模型')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 10, bottom: 4 })
      Text('• 下拉框包含所有 API Profile 的主模型和多模态解析模型')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 12 })
      Text('• 识别时直接使用所选模型对应的 Base URL / API Key')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 4 })
      Text('• 不需要在这里填写 API Key')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(24)
    .shadow({ radius: 18, color: '#0D000000', offsetX: 0, offsetY: 4 })
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============ 2. 上传 ============
  @Builder
  buildUploadSection() {
    Column() {
      this.buildStepTitle('2', '上传表格图片')
      Column() {
        if (this.selectedUri === '') {
          Column() {
            SymbolGlyph($r('sys.symbol.camera'))
              .fontSize(40)
              .fontColor([$r('app.color.text_tertiary')])
              .margin({ bottom: 8 })
            Text('点击选择图片')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Text('支持 JPG / PNG / WebP，建议宽度 1000-3000px')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 4 })
          }
          .width('100%')
          .padding({ top: 36, bottom: 36 })
          .justifyContent(FlexAlign.Center)
        } else {
          Image(this.selectedUri)
            .width('100%')
            .height(200)
            .objectFit(ImageFit.Contain)
            .borderRadius(16)
            .backgroundColor($r('app.color.background'))
        }
      }
      .width('100%')
      .border({ width: 1.5, style: BorderStyle.Dashed, color: $r('app.color.border') })
      .borderRadius(20)
      .backgroundColor($r('app.color.background'))
      .onClick(() => {
        this.pickImage();
      })
      Row() {
        Button(this.converting ? '识别中...' : '识别表格')
          .fontSize(14)
          .height(44)
          .padding({ left: 20, right: 20 })
          .backgroundColor(this.converting || this.selectedUri === '' ?
            $r('app.color.text_tertiary') : $r('app.color.brand'))
          .fontColor(Color.White)
          .borderRadius(16)
          .enabled(!this.converting && this.selectedUri !== '')
          .onClick(() => {
            this.startRecognize();
          })
        Button('清除')
          .fontSize(13)
          .height(44)
          .padding({ left: 18, right: 18 })
          .backgroundColor($r('app.color.raised_surface'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(16)
          .shadow({ radius: 12, color: '#14000000', offsetX: 0, offsetY: 3 })
          .margin({ left: 12 })
          .enabled(!this.converting)
          .onClick(() => {
            this.clearAll();
          })
        Text(this.statusText)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 12 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(24)
    .shadow({ radius: 18, color: '#0D000000', offsetX: 0, offsetY: 4 })
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============ 3. 结果 ============
  @Builder
  buildResultSection() {
    Column() {
      this.buildStepTitle('3', '结果')
      // Tabs
      Row() {
        this.buildTabButton('渲染预览', 0)
        this.buildTabButton('HTML 代码', 1)
        this.buildTabButton('网格结构', 2)
        this.buildTabButton('调试信息', 3)
      }
      .width('100%')
      .margin({ top: 8 })
      if (this.activeTab === 0) {
        this.buildPreviewTab()
      } else if (this.activeTab === 1) {
        this.buildHtmlTab()
      } else if (this.activeTab === 2) {
        this.buildGridTab()
      } else {
        this.buildDebugTab()
      }
      // Excel 下载
      Row() {
        Button('下载 Excel (.xlsx)')
          .fontSize(14)
          .height(44)
          .padding({ left: 20, right: 20 })
          .backgroundColor($r('app.color.success'))
          .fontColor(Color.White)
          .borderRadius(16)
          .onClick(() => {
            this.downloadExcel();
          })
        Text(this.excelInfo)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 10 })
      }
      .width('100%')
      .margin({ top: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(24)
    .shadow({ radius: 18, color: '#0D000000', offsetX: 0, offsetY: 4 })
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildTabButton(label: string, index: number) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === index ? $r('app.color.brand') : $r('app.color.text_secondary'))
        .padding({ left: 8, right: 8, top: 8, bottom: 6 })
      Row()
        .width('100%')
        .height(3)
        .borderRadius(1.5)
        .backgroundColor(this.activeTab === index ? $r('app.color.brand') : Color.Transparent)
    }
    .layoutWeight(1)
    .onClick(() => {
      this.activeTab = index;
    })
  }

  // Tab: 渲染预览
  @Builder
  buildPreviewTab() {
    Column() {
      Scroll() {
        this.buildTableGrid()
      }
      .width('100%')
      .height(this.gridTotalHeight + 8)
      .scrollable(ScrollDirection.Free)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
    .margin({ top: 12 })
  }

  // Tab: HTML 代码
  @Builder
  buildHtmlTab() {
    Column() {
      Row() {
        Button('复制 HTML')
          .fontSize(12)
          .height(36)
          .padding({ left: 14, right: 14 })
          .backgroundColor($r('app.color.raised_surface'))
          .fontColor($r('app.color.text_primary'))
          .borderRadius(16)
          .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
          .onClick(() => {
            this.copyHtml();
          })
        Button('下载 .html')
          .fontSize(12)
          .height(36)
          .padding({ left: 14, right: 14 })
          .backgroundColor($r('app.color.raised_surface'))
          .fontColor($r('app.color.text_primary'))
          .borderRadius(16)
          .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
          .margin({ left: 8 })
          .onClick(() => {
            this.downloadHtml();
          })
      }
      .width('100%')
      .margin({ top: 12, bottom: 8 })
      Scroll() {
        Text(this.currentHtml)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor($r('app.color.code_text'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .height(260)
      .backgroundColor($r('app.color.code_bg'))
      .borderRadius(16)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .padding(12)
    }
    .width('100%')
  }

  // Tab: 网格结构
  @Builder
  buildGridTab() {
    Column() {
      Column() {
        ForEach(this.gridInfoLines, (line: string) => {
          Text(line)
            .fontSize(12)
            .fontColor(this.gridInfoOk ? $r('app.color.text_secondary') : $r('app.color.danger'))
            .width('100%')
            .margin({ top: 3 })
            .textAlign(TextAlign.Start)
        }, (line: string) => line)
      }
      .width('100%')
      .margin({ top: 12, bottom: 8 })
      .alignItems(HorizontalAlign.Start)
      Scroll() {
        this.buildTableGrid()
      }
      .width('100%')
      .height(this.gridTotalHeight + 8)
      .scrollable(ScrollDirection.Free)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
  }

  // Tab: 调试信息
  @Builder
  buildDebugTab() {
    Scroll() {
      Text(this.debugText)
        .fontSize(11)
        .fontFamily('monospace')
        .fontColor($r('app.color.code_text'))
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .height(280)
    .backgroundColor($r('app.color.code_bg'))
    .borderRadius(16)
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .margin({ top: 12 })
    .padding(12)
  }

  // 网格渲染 (预览/网格结构共用)
  @Builder
  buildTableGrid() {
    Grid() {
      ForEach(this.previewCells, (cell: PreviewCell) => {
        GridItem() {
          Column() {
            Text(cell.text === '' ? ' ' : cell.text)
              .fontSize(11)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
          }
          .width('100%')
          .height('100%')
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)
        }
        .rowStart(cell.r)
        .rowEnd(cell.r + cell.rowspan - 1)
        .columnStart(cell.c)
        .columnEnd(cell.c + cell.colspan - 1)
        .height(cell.height)
        .backgroundColor(cell.isHeader ? $r('app.color.brand_light') : $r('app.color.surface'))
        .border({ width: 0.5, color: $r('app.color.border') })
      }, (cell: PreviewCell) => cell.r.toString() + '_' + cell.c.toString())
    }
    .columnsTemplate(this.columnsTemplate())
    .rowsGap(0)
    .columnsGap(0)
    .width(this.grid !== null ? this.grid.maxCols * COLUMN_WIDTH : 1)
    .height(this.gridTotalHeight)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
    .clip(true)
  }

  @Builder
  buildStepTitle(numberText: string, title: string) {
    Row() {
      Text(numberText)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
        .borderRadius(10)
        .backgroundColor($r('app.color.brand'))
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 12 })
  }

  @Builder
  buildErrorBox() {
    Column() {
      Text('出错：')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.danger'))
        .width('100%')
      Text(this.errorMsg)
        .fontSize(12)
        .fontColor($r('app.color.danger'))
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.brand_light'))
    .borderRadius(16)
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }
}