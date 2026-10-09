// 交互模式 (Intelligent UI) 原生渲染器:
// 把模型输出的 ```guncat-ui 文档(GuncatUiSpec)渲染为可交互的 ArkUI 组件——
// 指标卡 / 进度条 / 表格 / 横向柱状图 / 折线图 / 环形占比 / 表单控件(滑块·开关·下拉·输入) / 选项按钮 / 提示条。
// 设计约定:
// - 控件当前值存在组件内部 @State values 中(键 = 控件 name), 不写回消息, 因此不落盘、不膨胀会话;
// - 用户拖动滑块/输入/切换开关由 submitForm 汇总为一条 user 消息回传给模型, 模型据此重出界面(闭环);
// - 选项按钮(choice)点击即回传, 不等提交;
// - 流式期间 spec 会不断重建, @Watch('onSpecChanged') 只为新出现的控件补默认值, 不覆盖用户已改的值;
// - 所有渲染受 complete 控制: 未闭合时禁用交互并显示「生成中」。
import {
  GuncatUiSpec,
  GuncatUiInput,
  GuncatUiElement,
  GuncatUiAction,
  GuncatUiKind,
  GuncatUiControlType,
  GuncatUiActionStyle,
  GuncatUiChartType,
  GuncatUiMessageBuilder,
  GuncatUiPayload,
  GuncatUiLimits
} from '../common/GuncatUiSpec';

@Component
export struct GuncatUiView {
  @Prop @Watch('onSpecChanged') spec: GuncatUiSpec;
  // 文档是否已闭合(流式中为 false, 界面按中间态渲染并禁用交互)
  @Prop complete: boolean = true;
  // 未闭合且本轮产出已结束(输出被截断/中断): 按"未完成"静态渲染, 而不是一直显示"生成中"
  @Prop truncated: boolean = false;
  // 已提交/已点击过: 置灰防止重复回传(由父组件按消息维度控制)
  @Prop locked: boolean = false;
  // 解析失败时块内原文: 非空则卡片展示「原始输出」而不是空盒子(spec 为 null 或解析不出元素时)
  @Prop rawFallback: string = '';
  // 交互回传(父组件转成 user 消息交给 Agent Loop)
  private onInteract: (payload: GuncatUiPayload) => void = (_payload: GuncatUiPayload): void => {};

  // 控件当前值(键 = 控件 name); 用 Record 而非 Map, 便于 ArkUI 状态追踪
  @State private values: Record<string, Object> = {};
  // 用户是否已改动过任一控件(未改动时提交按钮弱化为次要样式)
  @State private dirty: boolean = false;
  // 「查看原始输出」开关(解析失败或输出被截断时可用于自查)
  @State private showRaw: boolean = false;

  aboutToAppear(): void {
    this.seedDefaults();
  }

  // spec 在流式中会被反复重建: 只补新控件的默认值
  onSpecChanged(): void {
    this.seedDefaults();
  }

  private seedDefaults(): void {
    if (this.spec === null) {
      return;
    }
    for (let i: number = 0; i < this.spec.controls.length; i++) {
      let input: GuncatUiInput = this.spec.controls[i];
      if (this.values[input.name] === undefined) {
        if (input.type === GuncatUiControlType.TOGGLE) {
          this.values[input.name] = input.defBool;
        } else if (input.type === GuncatUiControlType.SLIDER) {
          this.values[input.name] = input.defNum;
        } else {
          this.values[input.name] = input.defText;
        }
      }
    }
  }

  private setValue(name: string, value: Object): void {
    this.values[name] = value;
    this.dirty = true;
  }

  private numOf(name: string, fallback: number): number {
    let raw: Object | undefined = this.values[name];
    if (raw === undefined) {
      return fallback;
    }
    if (typeof raw === 'number') {
      return raw as number;
    }
    if (typeof raw === 'string') {
      let n: number = parseFloat(raw as string);
      return isNaN(n) ? fallback : n;
    }
    return fallback;
  }

  private boolOf(name: string, fallback: boolean): boolean {
    let raw: Object | undefined = this.values[name];
    if (raw === undefined) {
      return fallback;
    }
    if (typeof raw === 'boolean') {
      return raw as boolean;
    }
    return fallback;
  }

  private textOf(name: string, fallback: string): string {
    let raw: Object | undefined = this.values[name];
    if (raw === undefined) {
      return fallback;
    }
    if (typeof raw === 'string') {
      return raw as string;
    }
    if (typeof raw === 'number' || typeof raw === 'boolean') {
      return String(raw);
    }
    return fallback;
  }

  // ===== 回传 =====
  private submitForm(action: GuncatUiAction, names: string[]): void {
    if (!this.complete || this.locked) {
      return;
    }
    let payload: GuncatUiPayload = new GuncatUiPayload();
    payload.kind = 'form';
    payload.actionId = action.id;
    payload.confirm = action.confirm;
    payload.title = this.spec.title;
    let refs: string[] = names.length > 0 ? names : this.allControlNames();
    for (let i: number = 0; i < refs.length; i++) {
      let input: GuncatUiInput | null = this.spec.findControl(refs[i]);
      if (input === null) {
        continue;
      }
      payload.names.push(input.name);
      payload.labels.push(input.label);
      payload.values.push(GuncatUiMessageBuilder.controlValueText(input, this.values));
    }
    this.onInteract(payload);
  }

  private allControlNames(): string[] {
    let names: string[] = [];
    if (this.spec === null) {
      return names;
    }
    for (let i: number = 0; i < this.spec.controls.length; i++) {
      names.push(this.spec.controls[i].name);
    }
    return names;
  }

  private clickAction(action: GuncatUiAction, value: string): void {
    if (!this.complete || this.locked) {
      return;
    }
    let payload: GuncatUiPayload = new GuncatUiPayload();
    payload.kind = 'action';
    payload.actionId = action.id;
    payload.confirm = action.confirm;
    payload.title = this.spec.title;
    payload.label = action.label;
    payload.value = value;
    this.onInteract(payload);
  }

  // ===== 数值展示 =====
  private fmt(n: number): string {
    let rounded: number = Math.round(n * 100) / 100;
    return String(rounded);
  }

  private ratio(value: number, total: number): number {
    if (total <= 0) {
      return 0;
    }
    let r: number = value / total;
    if (r < 0) {
      return 0;
    }
    if (r > 1) {
      return 1;
    }
    return r;
  }

  private toneColor(tone: string): ResourceColor {
    if (tone === 'success') {
      return $r('app.color.success');
    }
    if (tone === 'warn') {
      return $r('app.color.warning');
    }
    if (tone === 'danger') {
      return $r('app.color.danger');
    }
    return $r('app.color.brand');
  }

  private chartColor(i: number): string {
    const palette: string[] = ['#4176E6', '#34C77B', '#F5A524', '#A855F7', '#22B8CF', '#EF4444'];
    return palette[i % palette.length];
  }

  private seriesTotal(values: number[]): number {
    let sum: number = 0;
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] > 0) {
        sum += values[i];
      }
    }
    return sum;
  }

  // 横向柱状图/折线图共用的最大值
  private maxOf(values: number[]): number {
    let max: number = 0;
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] > max) {
        max = values[i];
      }
    }
    return max <= 0 ? 1 : max;
  }

  // 折线图极值
  private minOf(values: number[]): number {
    if (values.length === 0) {
      return 0;
    }
    let min: number = values[0];
    for (let i: number = 1; i < values.length; i++) {
      if (values[i] < min) {
        min = values[i];
      }
    }
    return min;
  }

  private statsText(): string {
    if (!this.complete) {
      // 产出已结束但块没闭合 = 输出被截断/中断, 不能再说"生成中"
      return this.truncated ? '未完成' : '生成中…';
    }
    if (this.locked) {
      return '已提交';
    }
    if (this.spec === null || this.spec.elements.length === 0) {
      return '无内容';
    }
    return this.dirty ? '已修改' : '可交互';
  }

  // 界面是否有真正可渲染的内容(元素或独立控件)
  private hasContent(): boolean {
    if (this.spec === null) {
      return false;
    }
    if (this.spec.elements.length > 0) {
      return true;
    }
    return this.orphanControls().length > 0;
  }

  // 兜底文案: 说明为什么这里没有正常界面
  private fallbackText(): string {
    if (this.truncated) {
      return '这段界面输出没有写完（模型输出被截断或中断），已按已生成的部分展示。发一句"继续"或让它重新生成即可。';
    }
    if (this.complete) {
      let chars: number = this.rawFallback.trim().length;
      let detail: string = chars > 0 ? '（模型在这段里只写了 ' + chars.toString() + ' 个字符）' : '';
      return '这段界面内容不完整，无法渲染成可交互组件' + detail +
        '。发一句"重新生成界面"即可，或直接说清你想要的图表/表单。';
    }
    return '界面生成中…';
  }

  // "查看原始输出"开关文案
  private rawToggleText(): string {
    return this.showRaw ? '收起原始输出' : '查看原始输出';
  }

  build() {
    Column({ space: 12 }) {
      // 头部: 图标 + 标题 + 状态徽标(没有标题也要出状态徽标, 避免出现"无标识空白盒")
      Row({ space: 8 }) {
        Text('✦')
          .fontSize(14)
          .fontColor($r('app.color.brand'))
        Column({ space: 2 }) {
          if (this.spec !== null && this.spec.title !== '') {
            Text(this.spec.title)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          if (this.spec !== null && this.spec.subtitle !== '') {
            Text(this.spec.subtitle)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.statsText())
          .fontSize(10)
          .fontColor(this.locked ? $r('app.color.text_tertiary') : $r('app.color.brand'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(8)
          .backgroundColor($r('app.color.brand_light'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 元素序列(spec 为空时跳过)
      if (this.spec !== null) {
        ForEach(this.spec.elements, (el: GuncatUiElement, index: number) => {
          this.buildElement(el, 'e' + index)
        }, (el: GuncatUiElement, index: number) => 'e' + index)

        // 独立控件(未被 form 引用时, 作为独立卡片渲染, 用默认动作回传)
        ForEach(this.orphanControls(), (input: GuncatUiInput) => {
          this.buildControlCard(input)
        }, (input: GuncatUiInput) => 'c_' + input.name)
      }

      // 骨架: 仅"正在生成且尚无内容"时显示(产出已结束的未闭合块走下面的"未完成"分支)
      if (!this.complete && !this.truncated && !this.hasContent()) {
        Column({ space: 8 }) {
          Row()
            .width('70%')
            .height(12)
            .borderRadius(6)
            .backgroundColor($r('app.color.surface_secondary'))
          Row()
            .width('45%')
            .height(12)
            .borderRadius(6)
            .backgroundColor($r('app.color.surface_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // 兜底: 没有可渲染内容(已闭合但解析不出元素 / 输出被截断) → 说明原因 + 原始输出入口
      if (!this.hasContent() && (this.complete || this.truncated)) {
        Text(this.fallbackText())
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      // 有内容但块没写完: 明确标注(避免用户以为界面"就这些")
      if (this.hasContent() && this.truncated) {
        Text('界面输出未完成，以下为已生成的部分。')
          .fontSize(11)
          .fontColor($r('app.color.warning'))
          .width('100%')
      }
      // 原始输出(自查用): 解析失败时默认展开, 其余情况折叠。
      // 强制按字符换行 + 加大高度上限 + 显示字符数: JSON 常是超长单行, 不换行会被裁掉看不见。
      if (this.rawFallback.trim() !== '' && (this.showRaw || (!this.hasContent() && this.complete))) {
        Column({ space: 4 }) {
          Row() {
            Text('模型原始输出 · ' + this.rawFallback.trim().length.toString() + ' 字符')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
          }
          .width('100%')

          Scroll() {
            Text(this.rawFallback)
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .fontFamily('monospace')
              .width('100%')
              .wordBreak(WordBreak.BREAK_ALL)
              .textAlign(TextAlign.Start)
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .constraintSize({ maxHeight: 300 })
          .width('100%')
          .align(Alignment.TopStart)
        }
        .width('100%')
        .padding(10)
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
      }
      // 「查看原始输出」开关: 有任何原文时都可点开核对
      if (this.rawFallback.trim() !== '' && !(!this.hasContent() && this.complete)) {
        Button() {
          Text(this.rawToggleText())
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .height(30)
        .padding({ left: 12, right: 12 })
        .borderRadius(10)
        .backgroundColor($r('app.color.surface_secondary'))
        .onClick(() => {
          this.showRaw = !this.showRaw;
        })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(18)
    .border({ width: 1, color: $r('app.color.divider') })
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 3 })
  }

  // 未被任何 form 引用的控件(单独成卡, 用空 id 提交=只回传改动)
  private orphanControls(): GuncatUiInput[] {
    if (this.spec === null) {
      let none: GuncatUiInput[] = [];
      return none;
    }
    let used: string[] = [];
    for (let i: number = 0; i < this.spec.elements.length; i++) {
      let el: GuncatUiElement = this.spec.elements[i];
      for (let j: number = 0; j < el.controls.length; j++) {
        used.push(el.controls[j]);
      }
      if (el.bind !== '') {
        used.push(el.bind);
      }
      if (el.bind2 !== '') {
        used.push(el.bind2);
      }
    }
    let orphans: GuncatUiInput[] = [];
    for (let i: number = 0; i < this.spec.controls.length; i++) {
      let input: GuncatUiInput = this.spec.controls[i];
      let isUsed: boolean = false;
      for (let j: number = 0; j < used.length; j++) {
        if (used[j] === input.name) {
          isUsed = true;
          break;
        }
      }
      if (!isUsed) {
        orphans.push(input);
      }
    }
    return orphans;
  }

  // ===== 元素分发 =====
  @Builder
  buildElement(el: GuncatUiElement, key: string) {
    if (el.kind === GuncatUiKind.LAYOUT) {
      this.buildLayout(el, key)
    } else if (el.kind === GuncatUiKind.METRICS) {
      this.buildMetrics(el, key)
    } else if (el.kind === GuncatUiKind.TABLE) {
      this.buildTable(el)
    } else if (el.kind === GuncatUiKind.CHART) {
      this.buildChart(el)
    } else if (el.kind === GuncatUiKind.FORM) {
      this.buildForm(el)
    } else if (el.kind === GuncatUiKind.CHOICE) {
      this.buildChoice(el)
    } else {
      this.buildPlain(el, key)
    }
  }

  // card / note / markdown / metric / progress
  @Builder
  buildPlain(el: GuncatUiElement, key: string) {
    if (el.kind === GuncatUiKind.METRIC) {
      this.buildMetricCard(el, 'm' + key)
    } else if (el.kind === GuncatUiKind.PROGRESS) {
      this.buildProgress(el)
    } else if (el.kind === GuncatUiKind.NOTE) {
      this.buildNote(el)
    } else {
      this.buildContainerCard(el, key)
    }
  }

  // card: 可选标题 + 文本 + 子元素
  @Builder
  buildContainerCard(el: GuncatUiElement, key: string) {
    Column({ space: 8 }) {
      if (el.title !== '') {
        Text(el.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      if (el.text !== '') {
        Text(el.text)
          .fontSize(13)
          .lineHeight(21)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      ForEach(el.children, (child: GuncatUiElement, index: number) => {
        this.buildElement(child, key + '_' + index)
      }, (child: GuncatUiElement, index: number) => key + '_' + index)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  // layout: list(默认, 纵向) / grid(两列) / row(横向等分)
  @Builder
  buildLayout(el: GuncatUiElement, key: string) {
    Column({ space: 8 }) {
      if (el.title !== '') {
        Text(el.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      if (el.layout === 'grid') {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(el.children, (child: GuncatUiElement, index: number) => {
            Column() {
              this.buildElement(child, key + '_g' + index)
            }
            .width('48%')
            .margin({ bottom: 8 })
          }, (child: GuncatUiElement, index: number) => key + '_g' + index)
        }
        .width('100%')
      } else if (el.layout === 'row') {
        Row({ space: 8 }) {
          ForEach(el.children, (child: GuncatUiElement, index: number) => {
            Column() {
              this.buildElement(child, key + '_r' + index)
            }
            .layoutWeight(1)
          }, (child: GuncatUiElement, index: number) => key + '_r' + index)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      } else {
        Column({ space: 8 }) {
          ForEach(el.children, (child: GuncatUiElement, index: number) => {
            this.buildElement(child, key + '_l' + index)
          }, (child: GuncatUiElement, index: number) => key + '_l' + index)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // metrics: 指标组(≤2 个一行, 更多时两列)
  @Builder
  buildMetrics(el: GuncatUiElement, key: string) {
    Column({ space: 8 }) {
      if (el.title !== '') {
        Text(el.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(el.items, (item: GuncatUiElement, index: number) => {
          Column() {
            this.buildMetricCard(item, key + '_i' + index)
          }
          .width(el.items.length <= 2 ? '48%' : '31%')
          .margin({ bottom: 8 })
        }, (item: GuncatUiElement, index: number) => key + '_i' + index)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildMetricCard(metric: GuncatUiElement, key: string) {
    Column({ space: 4 }) {
      if (metric.label !== '') {
        Text(metric.label)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Row({ space: 2 }) {
        Text(this.fmt(metric.value))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        if (metric.unit !== '') {
          Text(metric.unit)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 3 })
        }
      }
      .alignItems(VerticalAlign.Bottom)

      if (metric.delta !== '') {
        Text(metric.delta)
          .fontSize(11)
          .fontColor(metric.delta.startsWith('-') ? $r('app.color.success') : $r('app.color.danger'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  // progress: 进度条(可绑控件, 拖动即刷新)
  @Builder
  buildProgress(el: GuncatUiElement) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(el.title !== '' ? el.title : el.label)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.fmt(el.total > 0 ? Math.round(this.ratio(el.value, el.total) * 100) : 0) + '%')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')

      Row() {
        Row()
          .width((this.ratio(el.value, el.total) * 100) + '%')
          .height('100%')
          .borderRadius(6)
          .backgroundColor($r('app.color.brand'))
      }
      .width('100%')
      .height(10)
      .borderRadius(6)
      .backgroundColor($r('app.color.surface_secondary'))

      if (el.label !== '' && el.title !== '') {
        Text(el.label + ' ' + this.fmt(el.value) + (el.unit !== '' ? el.unit : ''))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // note: 提示条。
  // 实现要点(真机事故): 早期版本用 "Row().height('100%')" 当左侧竖条, 在自动高度的父容器里
  // 百分比高度会被解析成一个很大的值, 把整条撑成几百 vp 的空白(文字只占两行)。
  // 现在改用**左边框**画竖条, 整条高度完全由文字决定, 容器内没有任何百分比高度。
  @Builder
  buildNote(el: GuncatUiElement) {
    Column({ space: 2 }) {
      if (el.title !== '') {
        Text(el.title)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      Text(el.text)
        .fontSize(12)
        .lineHeight(19)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(10)
    .border({ width: { left: 3 }, color: this.toneColor(el.tone) })
    .alignItems(HorizontalAlign.Start)
  }

  // table: 表头 + 行(横向可滚动, 窄屏不挤)
  @Builder
  buildTable(el: GuncatUiElement) {
    Column({ space: 8 }) {
      if (el.title !== '') {
        Text(el.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      Scroll() {
        Column() {
          if (el.headers.length > 0) {
            Row() {
              ForEach(el.headers, (h: string, index: number) => {
                Text(h)
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.brand'))
                  .layoutWeight(1)
                  .padding({ left: 8, right: 8, top: 7, bottom: 7 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }, (h: string, index: number) => 'h' + index)
            }
            .width(el.headers.length * 92)
            .backgroundColor($r('app.color.brand_light'))
          }
          ForEach(el.rows, (row: string[], rIndex: number) => {
            Row() {
              ForEach(row, (cell: string, cIndex: number) => {
                Text(cell)
                  .fontSize(11)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }, (cell: string, cIndex: number) => 'c' + rIndex + '_' + cIndex)
            }
            .width(el.headers.length > 0 ? el.headers.length * 92 : row.length * 92)
            .backgroundColor(rIndex % 2 === 0 ? $r('app.color.surface') : $r('app.color.surface_secondary'))
          }, (row: string[], rIndex: number) => 'r' + rIndex)
        }
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.divider') })
        .clip(true)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.TopStart)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // chart: bar(横向柱) / pie(环形占比) / line(SVG 折线)
  @Builder
  buildChart(el: GuncatUiElement) {
    Column({ space: 8 }) {
      if (el.title !== '') {
        Text(el.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      if (el.chart === GuncatUiChartType.PIE) {
        this.buildPie(el)
      } else if (el.chart === GuncatUiChartType.LINE) {
        this.buildLine(el)
      } else {
        this.buildBars(el)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 横向柱状图: 手机竖屏最易读的形态
  @Builder
  buildBars(el: GuncatUiElement) {
    Column({ space: 7 }) {
      ForEach(el.values, (value: number, index: number) => {
        if (index < GuncatUiLimits.MAX_BARS_RENDER) {
          Column({ space: 3 }) {
            Row({ space: 6 }) {
              Text(index < el.labels.length ? el.labels[index] : '#' + (index + 1))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.fmt(value) + (el.unit !== '' ? el.unit : ''))
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')

            Row() {
              Row()
                .width((this.ratio(value, this.maxOf(el.values)) * 100) + '%')
                .height('100%')
                .borderRadius(4)
                .backgroundColor(this.chartColor(index))
            }
            .width('100%')
            .height(8)
            .borderRadius(4)
            .backgroundColor($r('app.color.surface_secondary'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }, (value: number, index: number) => 'bar' + index)

      if (el.values.length > GuncatUiLimits.MAX_BARS_RENDER) {
        Text('仅展示前 ' + GuncatUiLimits.MAX_BARS_RENDER + ' 项(共 ' + el.values.length + ' 项)')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 折线图: 纯 SVG path, 无需图片资源
  @Builder
  buildLine(el: GuncatUiElement) {
    Column({ space: 6 }) {
      Shape() {
        Path()
          .commands(this.linePath(el.values, 260, 90, 6))
          .stroke(this.chartColor(0))
          .strokeWidth(2)
          .fill(Color.Transparent)
      }
      .width('100%')
      .height(92)
      .viewPort({ x: 0, y: 0, width: 260, height: 90 })

      Row() {
        Text(el.labels.length > 0 ? el.labels[0] : '')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
        if (el.labels.length > 1) {
          Text(el.labels[el.labels.length - 1])
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 折线路径: SVG 坐标空间固定 260x90
  private linePath(values: number[], w: number, h: number, pad: number): string {
    if (values.length === 0) {
      return '';
    }
    let max: number = this.maxOf(values);
    let min: number = this.minOf(values);
    let span: number = max - min;
    if (span <= 0) {
      span = 1;
    }
    let step: number = values.length > 1 ? (w - pad * 2) / (values.length - 1) : 0;
    let path: string = '';
    for (let i: number = 0; i < values.length; i++) {
      let x: number = pad + step * i;
      let y: number = h - pad - ((values[i] - min) / span) * (h - pad * 2);
      path = path + (i === 0 ? 'M' : 'L') + (Math.round(x * 10) / 10) + ' ' +
        (Math.round(y * 10) / 10) + ' ';
    }
    return path.trim();
  }

  // 环形占比图 + 图例
  @Builder
  buildPie(el: GuncatUiElement) {
    Column({ space: 10 }) {
      Row({ space: 14 }) {
        Stack() {
          // 用环形描边拼出占比: 每个数据段按固定半径的角度绘制圆弧
          Shape() {
            ForEach(el.values, (value: number, index: number) => {
              Path()
                .commands(this.arcPath(el.values, index, 60, 60, 44))
                .stroke(this.chartColor(index))
                .strokeWidth(14)
                .fill(Color.Transparent)
                .strokeLineCap(LineCapStyle.Butt)
            }, (value: number, index: number) => 'arc' + index)
          }
          .width(120)
          .height(120)
          .viewPort({ x: 0, y: 0, width: 120, height: 120 })

          Column({ space: 1 }) {
            Text(el.totalLabel !== '' ? el.totalLabel : this.fmt(this.seriesTotal(el.values)))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            if (el.unit !== '') {
              Text(el.unit)
                .fontSize(10)
                .fontColor($r('app.color.text_secondary'))
            }
          }
        }
        .width(120)
        .height(120)

        Column({ space: 6 }) {
          ForEach(el.values, (value: number, index: number) => {
            if (index < 6) {
              Row({ space: 6 }) {
                Row()
                  .width(8)
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(this.chartColor(index))
                Text(index < el.labels.length ? el.labels[index] : '#' + (index + 1))
                  .fontSize(11)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.fmt(this.ratio(value, this.seriesTotal(el.values)) * 100) + '%')
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
            }
          }, (value: number, index: number) => 'lg' + index)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 单段圆弧路径(极坐标 → SVG path)
  private arcPath(values: number[], index: number, cx: number, cy: number, r: number): string {
    let total: number = this.seriesTotal(values);
    if (total <= 0) {
      return '';
    }
    let startRatio: number = 0;
    for (let i: number = 0; i < index; i++) {
      if (values[i] > 0) {
        startRatio += values[i] / total;
      }
    }
    let sweep: number = values[index] > 0 ? values[index] / total : 0;
    if (sweep <= 0) {
      return '';
    }
    // 单段铺满整圈时避免起点终点重合导致不渲染
    if (sweep >= 0.9999) {
      sweep = 0.9999;
    }
    let a0: number = startRatio * Math.PI * 2 - Math.PI / 2;
    let a1: number = (startRatio + sweep) * Math.PI * 2 - Math.PI / 2;
    let x0: number = cx + r * Math.cos(a0);
    let y0: number = cy + r * Math.sin(a0);
    let x1: number = cx + r * Math.cos(a1);
    let y1: number = cy + r * Math.sin(a1);
    let large: number = sweep > 0.5 ? 1 : 0;
    return 'M' + (Math.round(x0 * 10) / 10) + ' ' + (Math.round(y0 * 10) / 10) +
      ' A' + r + ' ' + r + ' 0 ' + large + ' 1 ' +
      (Math.round(x1 * 10) / 10) + ' ' + (Math.round(y1 * 10) / 10);
  }

  // form: 控件集合 + 提交按钮
  @Builder
  buildForm(el: GuncatUiElement) {
    Column({ space: 10 }) {
      if (el.title !== '') {
        Text(el.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      ForEach(el.controls, (name: string) => {
        this.buildControlByName(name, 'f_' + name)
      }, (name: string) => 'f_' + name)

      // 提交按钮: 未改动时为次要样式, 改动后转主样式
      Button() {
        Text(el.action !== null ? el.action.label : '提交')
          .fontSize(13)
          .fontColor(this.locked ? $r('app.color.text_tertiary') : Color.White)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(38)
      .borderRadius(12)
      .backgroundColor(this.locked ? $r('app.color.surface_secondary') :
        (this.dirty ? $r('app.color.brand') : $r('app.color.brand_pressed')))
      .enabled(this.complete && !this.locked)
      .onClick(() => {
        let action: GuncatUiAction = el.action !== null ? el.action : this.defaultAction();
        this.submitForm(action, el.controls);
      })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  private defaultAction(): GuncatUiAction {
    let action: GuncatUiAction = new GuncatUiAction();
    action.id = 'submit';
    action.label = '提交';
    action.style = GuncatUiActionStyle.PRIMARY;
    return action;
  }

  // choice: 选项按钮组(点击即回传) + 可选次要动作
  @Builder
  buildChoice(el: GuncatUiElement) {
    Column({ space: 8 }) {
      if (el.title !== '') {
        Text(el.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      ForEach(el.options, (option: string) => {
        Button() {
          Text(option)
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .constraintSize({ minHeight: 38 })
        .borderRadius(12)
        .backgroundColor($r('app.color.surface_secondary'))
        .border({ width: 1, color: $r('app.color.divider') })
        .enabled(this.complete && !this.locked)
        .onClick(() => {
          let action: GuncatUiAction = el.action !== null ? el.action : this.defaultAction();
          this.clickAction(action, option);
        })
      }, (option: string) => 'opt_' + option)

      if (el.action2 !== null) {
        Button() {
          Text(el.action2 !== null ? el.action2.label : '继续')
            .fontSize(12)
            .fontColor($r('app.color.brand'))
        }
        .width('100%')
        .height(34)
        .borderRadius(12)
        .backgroundColor($r('app.color.brand_light'))
        .enabled(this.complete && !this.locked)
        .onClick(() => {
          let secondary: GuncatUiAction | null = el.action2;
          if (secondary !== null) {
            this.clickAction(secondary, '');
          }
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 独立控件卡片(带默认提交动作)
  @Builder
  buildControlCard(input: GuncatUiInput) {
    Column({ space: 8 }) {
      this.buildControl(input, 'oc_' + input.name)
      Button() {
        Text('提交')
          .fontSize(12)
          .fontColor(this.locked ? $r('app.color.text_tertiary') : Color.White)
      }
      .width('100%')
      .height(34)
      .borderRadius(12)
      .backgroundColor(this.locked ? $r('app.color.surface_secondary') : $r('app.color.brand'))
      .enabled(this.complete && !this.locked)
      .onClick(() => {
        this.submitForm(this.defaultAction(), [input.name]);
      })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  // 按控件名渲染(form 内引用)
  @Builder
  buildControlByName(name: string, key: string) {
    if (this.spec.findControl(name) !== null) {
      this.buildControl(this.spec.findControl(name) as GuncatUiInput, key)
    }
  }

  // 单个控件: 标签行(值预览) + 具体形态
  @Builder
  buildControl(input: GuncatUiInput, key: string) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(input.label)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (input.type !== GuncatUiControlType.TEXT) {
          Text(GuncatUiMessageBuilder.controlValueText(input, this.values))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')

      if (input.type === GuncatUiControlType.SLIDER) {
        Slider({
          value: this.numOf(input.name, input.defNum),
          min: input.min,
          max: input.max,
          step: input.step,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .selectedColor($r('app.color.brand'))
          .trackColor($r('app.color.surface'))
          .blockColor($r('app.color.surface'))
          .enabled(this.complete && !this.locked)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.End) {
              this.setValue(input.name, value);
            }
          })
      } else if (input.type === GuncatUiControlType.TOGGLE) {
        Row() {
          Toggle({ type: ToggleType.Switch, isOn: this.boolOf(input.name, input.defBool) })
            .selectedColor($r('app.color.brand'))
            .enabled(this.complete && !this.locked)
            .onChange((isOn: boolean) => {
              this.setValue(input.name, isOn);
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
      } else if (input.type === GuncatUiControlType.SELECT) {
        this.buildSelect(input)
      } else {
        TextInput({ text: this.textOf(input.name, input.defText), placeholder: input.placeholder })
          .width('100%')
          .height(38)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .backgroundColor($r('app.color.surface'))
          .borderRadius(10)
          .maxLength(GuncatUiLimits.MAX_TEXT)
          .enabled(this.complete && !this.locked)
          .onChange((value: string) => {
            this.setValue(input.name, value);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildSelect(input: GuncatUiInput) {
    Select(input.options.map((option: string): SelectOption => {
      return { value: option } as SelectOption;
    }))
      .selected(this.selectIndex(input))
      .value(this.textOf(input.name, input.defText) !== '' ?
        this.textOf(input.name, input.defText) : '请选择')
      .width('100%')
      .height(38)
      .font({ size: 13 })
      .fontColor($r('app.color.text_primary'))
      .selectedOptionFont({ size: 13 })
      .optionFont({ size: 13 })
      .backgroundColor($r('app.color.surface'))
      .borderRadius(10)
      .enabled(this.complete && !this.locked)
      .onSelect((index: number, value: string) => {
        this.setValue(input.name, value);
      })
  }

  // 下拉当前选中下标(未命中时取 0, 与 defText 默认取首项一致)
  private selectIndex(input: GuncatUiInput): number {
    let current: string = this.textOf(input.name, input.defText);
    for (let i: number = 0; i < input.options.length; i++) {
      if (input.options[i] === current) {
        return i;
      }
    }
    return 0;
  }
}
