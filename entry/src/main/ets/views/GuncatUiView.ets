// 交互模式 (Intelligent UI) 原生渲染器。
//
// 输入是一份 guncat-ui lang 程序(字符串), 这里负责把它渲染成原生 ArkUI 界面。
// 设计要点(对齐参考项目的观感):
//   1. **回答没有卡片外壳**: Card 只是一个 16 间距的纵向容器, 节奏来自间距与各组件自身的内边距,
//      而不是"一个带边框和状态徽标的盒子"(这正是旧实现显得鸡肋的主要原因);
//   2. **绑定是活的**: 用户拖动/点选后重新物化整棵树(表达式里的 $变量用新值重算), 界面立即变化;
//      需要模型重算时用 Action([@ToAssistant(...)]) 回传一条消息, 触发新一轮;
//   3. **流式中禁用交互**: 程序没写完时控件置灰, 避免在残缺界面上提交;
//   4. 绑定值随消息持久化(尾标记), 用户填过的参数在滚动/切换会话/重启后仍在。
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  GuncatUiLang,
  UiProgram,
  UiElement,
  UiNode,
  UiActionStep,
  GuncatUiMaterializer,
  UiLimits
} from '../common/GuncatUiLang';
import { GuncatUiLibrary } from '../common/GuncatUiLibrary';
import {
  GuncatUiState,
  GuncatUiEvent,
  GuncatUiRuntime
} from '../common/GuncatUiRuntime';
import { UiNum, UiPalette } from '../common/GuncatUiPaint';
import {
  GuncatUiBarChart,
  GuncatUiLineChart,
  GuncatUiPieChart,
  GuncatUiRadialChart,
  GuncatUiStackedBar,
  GuncatUiRadarChart,
  GuncatUiHorizontalBars
} from './GuncatUiCharts';
import { GuncatUiChevron, GuncatUiIcon, GuncatUiIconBadge } from './GuncatUiIcons';
import { RichTextView } from './RichTextView';

@Component
export struct GuncatUiView {
  // 拖动"静默"判定阈值(ms): 拖动中每次 Moving 重新起表, 超过它没有新的 Moving 就当作松手。
  // 比手指移动的间隔(通常 16~32ms)宽得多, 又比人反应过来"我松手了"短得多。
  private static readonly DRAG_IDLE_MS: number = 220;

  // 程序源码。传字符串而不是对象: ArkUI 里字符串 @Prop 的变更通知最可靠,
  // 而嵌套对象经 @Prop 深拷贝后既慢又容易丢状态。
  @Prop @Watch('onProgramChanged') programText: string = '';
  // 程序是否已写完(流式中为 false)
  @Prop complete: boolean = true;
  // 未写完但本轮产出已结束
  @Prop truncated: boolean = false;
  // 已归档 / 流式中: 禁止交互
  @Prop locked: boolean = false;
  // 消息里持久化的绑定值
  @Prop stateJson: string = '';
  // 界面标题(回传消息前缀用)
  @Prop title: string = '';

  // 交互回传: kind='action' 需要发消息给模型, kind='state' 只持久化绑定值
  private onInteract: (ev: GuncatUiEvent) => void = (_ev: GuncatUiEvent): void => {};

  @State private rev: number = 0;
  // 拖动中的"实时刷新"唤醒源(与 rev 分开: rev 表示"整树重新物化", sigTick 表示"只把内联表达式
  // 重画一遍" —— 拖动期间被冻结的项不能整项重建, 但里面的数值文案要跟着走, 见 sliderValueText)
  @State private sigTick: number = 0;
  @State private showRaw: boolean = false;
  @State private showErrors: boolean = false;
  // 折叠/选项卡的展开状态(键 = 元素 key + 子项 value)
  @State private expanded: Record<string, boolean> = {};
  @State private selectedTab: Record<string, number> = {};

  // 拖动是否已开始(Begin 置位, 收尾清掉): Slider 的 End/Click 与静默计时器都可能触发收尾, 用它去重
  private dragging: boolean = false;
  // 拖动中实时刷新的节流时间戳(80ms 一次, 不必每帧都重新物化)
  private lastLiveTickMs: number = 0;
  // 拖动"静默"计时器: 拖动中每次 Moving 重新起表, 超时即当作松手(见 armDragIdleTimer)
  private dragIdleTimer: number = -1;
  // live() 的缓存: 一份 key→当前元素 的映射, 按 (rev, sigTick) 失效(见 live)
  private liveStamp: string = '';
  private liveMap: Record<string, UiElement> = {};

  private program: UiProgram = new UiProgram();
  // ⚠️ 必须是 @State, 不能是普通字段!! 真机踩透的坑:
  //   绑定值变化 → rematerialize() 重新物化出**新树**并赋给这里; 但 ForEach 的数据表达式是
  //   `this.wake(list, …)` 里的 `list`, 而 list 是**上一次构建时闭包捕获的旧数组** ——
  //   即使 ForEach 重跑, 它拿到的还是旧元素, 各子项的渲染指纹按**旧元素**算, 自然不变 →
  //   一项都不会重建。表现就是"拖动时数值/指标卡/图表全都不动, 切走再回来才变"。
  //   放进 @State 后, 顶层 ForEach 的数据表达式当场读 `this.root`(见 buildRootTree), 树一换
  //   它就是新树 → 指纹按新元素重算 → 依赖绑定值的子项换键重建。
  @State private root: UiElement | null = null;
  private state: GuncatUiState = new GuncatUiState();
  private lastText: string = '';
  private booted: boolean = false;

  aboutToAppear(): void {
    GuncatUiLibrary.init();
    this.rebuild();
  }

  // 组件销毁时清掉拖动静默计时器, 避免回调打到已销毁的实例上
  aboutToDisappear(): void {
    this.disarmDragIdleTimer();
    this.dragging = false;
  }

  // 程序文本变化(流式/最终): 重新解析并保持用户已改的绑定值
  onProgramChanged(): void {
    this.rebuild();
  }

  private rebuild(): void {
    let text: string = this.programText;
    if (this.booted && text === this.lastText) {
      return;
    }
    this.lastText = text;
    this.program = GuncatUiLang.parse(text);
    let carry: Record<string, Object> | null = null;
    if (this.booted) {
      // 流式期间: 以当前绑定值为准, 保住用户已经调过的参数
      carry = this.state.values;
    } else if (this.stateJson.trim() !== '' && this.stateJson.trim() !== '{}') {
      carry = GuncatUiState.fromJson(this.stateJson);
    }
    this.state = GuncatUiState.of(this.program, carry);
    this.root = GuncatUiLang.render(this.program, this.state.values);
    this.booted = true;
    this.rev++;
  }

  // 绑定值变化后重新物化(表达式里的 $变量要用新值重算)
  private rematerialize(): void {
    this.root = GuncatUiLang.render(this.program, this.state.values);
    this.rev++;
  }

  // 拖动中的实时刷新: 同样重新物化, 但**只动 sigTick、不动 rev**。
  // 它唯一的作用是让各节点**自己重画**(见 live): sigTick 一变, 表达式里调过 live() 的节点就被
  // 标脏、重画时从新树里取值。它不负责、也不会触发 ForEach 项的重建(真机证明那条路不可靠)。
  private revalue(): void {
    this.root = GuncatUiLang.render(this.program, this.state.values);
    this.sigTick++;
  }

  // 取"当前物化树里"的那个元素, 并在**表达式里**读一下 sigTick。
  //
  // 为什么必须这样(真机多轮实测的结论, 别改成别的形态):
  //   - 物化树每次都是新对象(root 的赋值会换掉整棵树), 而各个 @Builder 里的 el 是**上一次
  //     构建时闭包捕获的旧对象**, 它的 props 里是旧值 —— 直接读它就永远是旧值;
  //   - ArkUI 只把"构建期表达式里当场读到"的 @State 登记成依赖。本方法是在属性/组件参数表达式
  //     里被调用的(如 Text(UiNode.str(this.live(el), 'value', ''))), 所以这个 sigTick 读取会被
  //     登记 → sigTick 一变, 这个节点自己重画, 重画时取到的就是新树里的新值;
  //   - 而"换 ForEach 键 ⇒ 重建该项"这条路上所有变体在这台设备上都不可靠(见文件里各处注释),
  //     所以值节点必须能"自己重画", 不能指望祖先重建。
  // 按 key 找(而不是对象身份): key 跨物化稳定(GuncatUiMaterializer.assignKeys 保证), 而对象
  // 身份会因为 rebuild/revalue 换树而漂移(真机就出现过"时找到时找不到")。找不到就退回传进来的 el。
  //
  // 一次构建里同一个元素可能被读几十次, 所以按 (rev, sigTick) 缓存一份 key→当前元素 的映射:
  // 缓存只在"树或 epoch 变了"时失效, 不改变任何行为。
  private live(el: UiElement): UiElement {
    let tick: number = this.sigTick;
    if (tick < 0) {
      return el;
    }
    let stamp: string = this.rev.toString() + ':' + tick.toString();
    if (stamp !== this.liveStamp) {
      this.liveStamp = stamp;
      this.liveMap = {};
    }
    let hit: UiElement | undefined = this.liveMap[el.key];
    if (hit !== undefined) {
      return hit;
    }
    let chain: UiElement[] = GuncatUiLang.pathToKey(this.root, el.key);
    let cur: UiElement = chain.length === 0 ? el : chain[chain.length - 1];
    this.liveMap[el.key] = cur;
    return cur;
  }

  // 取"当前树里"的某个 **Record 值**(对象数组属性按下标; 单对象属性用 index < 0)。
  //
  // 为什么光有 live(el) 还不够: 列表行里的值是 baked 在 Record 里的(EntityList 的 rows、
  // ImageGallery 的 images、Table 的 data...), 而 ForEach 的 item builder 在键值不变时**根本不会
  // 重跑** —— 它闭包捕获的那个旧 Record 永远出不来新值。所以行文本必须在**自己的表达式**里
  // 重新取一次 Record(顺便读一下 sigTick 登记依赖), 才会跟着绑定值变。
  private liveRow(el: UiElement, prop: string, index: number): Record<string, Object> | null {
    let tick: number = this.sigTick;
    let cur: UiElement = tick < 0 ? el : this.live(el);
    if (index < 0) {
      return UiNode.obj(cur, prop);
    }
    let rows: Record<string, Object>[] = UiNode.objList(cur, prop);
    if (index >= rows.length) {
      return null;
    }
    return rows[index];
  }

  // 表格单元: 与 liveRow 同理, 但表格的行是 string[] (由 colTexts 拼出来的)
  private liveCell(el: UiElement, row: number, col: number): string {
    let tick: number = this.sigTick;
    let cur: UiElement = tick < 0 ? el : this.live(el);
    let rows: string[][] = this.tableRows(cur);
    if (row >= rows.length || col >= rows[row].length) {
      return '';
    }
    return rows[row][col];
  }

  // 结束一次拖动/点选: 重新物化(把值刷进树) + 整树重画 + 回传状态。
  //
  // explicit = 这次调用来自 End/Click 这种明确信号; 静默计时器跟在 End 后面时不该重复回传,
  // 用 dragging 去重保证一次手势只回传一次。
  private finishDrag(explicit: boolean): void {
    let wasDragging: boolean = this.dragging;
    this.disarmDragIdleTimer();
    this.dragging = false;
    this.rematerialize();
    this.sigTick++;
    if (explicit || wasDragging) {
      this.emitState();
    }
  }

  // "静默计时器": 拖动中每次 Moving 重新起表, 一段时间没有新的 Moving 就当作松手。
  // 为什么不给 Slider 挂 .onTouch: 那会插手它的触摸派发, 真机上表现为"只能点选、不跟手"。
  private armDragIdleTimer(): void {
    this.disarmDragIdleTimer();
    this.dragIdleTimer = setTimeout(() => {
      this.dragIdleTimer = -1;
      this.finishDrag(false);
    }, GuncatUiView.DRAG_IDLE_MS);
  }

  private disarmDragIdleTimer(): void {
    if (this.dragIdleTimer !== -1) {
      clearTimeout(this.dragIdleTimer);
      this.dragIdleTimer = -1;
    }
  }

  private interactive(): boolean {
    return this.complete && !this.locked;
  }

  // 整棵界面的重渲染开关(见 build 里那个恒真的 if)。
  //
  // 为什么要这么一个"没用"的方法: 与绑定值有关的读取都靠"构建期表达式里当场读到 @State"来登记
  // 依赖(真机一轮轮试出来的: 组件参数/属性表达式里的读取→被追踪 ✓; 读在方法内部或只读在 .id()
  // 上→不被追踪 ✗; 条件表达式在构建期求值、分支体整段重跑→被追踪 ✓)。这个 if 是整棵树的兜底
  // 唤醒: 它一重跑, 里面的 buildChildren(this.root, ...) 会重新读**刚物化出来的新树**。
  // 真正让值跟上的是各值节点的 live()(自己重画), 这里只是不让整棵树僵住。
  // 恒真: rev/sigTick 都从 0 开始递增, 不可能为负。
  private treeAwake(): boolean {
    return this.rev + this.sigTick >= 0;
  }

  // ===== 回传 =====
  private emitAction(message: string): void {
    if (message.trim() === '' || !this.interactive()) {
      return;
    }
    let ev: GuncatUiEvent = new GuncatUiEvent();
    ev.kind = 'action';
    ev.message = message;
    ev.title = this.title !== '' ? this.title : this.uiTitle();
    ev.stateJson = this.stateSnapshot();
    this.onInteract(ev);
  }

  private emitState(): void {
    let ev: GuncatUiEvent = new GuncatUiEvent();
    ev.kind = 'state';
    ev.stateJson = this.stateSnapshot();
    this.onInteract(ev);
  }

  private stateSnapshot(): string {
    this.state.compact(this.program);
    return this.state.toJson();
  }

  // 界面标题: 优先用消息里记录的, 其次从 CardHeader 取
  private uiTitle(): string {
    if (this.root === null) {
      return '';
    }
    let kids: UiElement[] = UiNode.elementList(this.root, 'children');
    for (let i: number = 0; i < kids.length; i++) {
      if (kids[i].type === 'CardHeader') {
        let t: string = UiNode.str(kids[i], 'title', '');
        if (t !== '') {
          return t;
        }
      }
    }
    return '';
  }

  private openUrl(url: string): void {
    if (url === '') {
      return;
    }
    try {
      let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      context.openLink(url);
    } catch (e) {
      promptAction.showToast({ message: '无法打开链接', duration: 2000 });
    }
  }

  private copyText(text: string): void {
    try {
      let pb = pasteboard.getSystemPasteboard();
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pb.setData(data).then(() => {
        promptAction.showToast({ message: '已复制', duration: 1500 });
      });
    } catch (e) {
      // 剪贴板不可用时静默
    }
  }

  // 绑定值写入
  private setBind(varName: string, value: Object, live: boolean): void {
    if (varName === '') {
      return;
    }
    this.state.set(varName, value);
    if (live) {
      this.rematerialize();
    }
    this.emitState();
  }

  // 控件当前值
  private bindStr(varName: string, fallback: string): string {
    return this.state.str(varName, fallback);
  }

  private bindNum(varName: string, fallback: number): number {
    return this.state.num(varName, fallback);
  }

  // ===== 动作执行 =====
  private runButton(el: UiElement, form: UiElement | null): void {
    if (!this.interactive()) {
      return;
    }
    let steps: UiActionStep[] = UiNode.actionSteps(this.live(el), 'action');
    let url: string = GuncatUiRuntime.urlOf(steps);
    if (url !== '') {
      this.openUrl(url);
    }
    let changed: boolean = GuncatUiRuntime.applySteps(steps, this.state);
    let messages: string[] = GuncatUiRuntime.collectMessages(steps);
    let message: string = messages.length > 0 ? messages.join('\n') : '';
    if (message === '' && steps.length === 0) {
      // 没写 action 的按钮: 把按钮文字发给助手(与参考项目一致)
      message = GuncatUiRuntime.buttonMessage(el);
    }
    // 表单内的按钮: 把字段当前值一并带上
    if (form !== null) {
      let body: string = GuncatUiRuntime.formMessage(form, this.state);
      if (message !== '') {
        body = body === '' ? message : body + '\n' + message;
      }
      message = GuncatUiRuntime.interactionText(this.title !== '' ? this.title : this.uiTitle(), body);
    }
    if (changed) {
      this.rematerialize();
    }
    if (message !== '') {
      this.emitAction(message);
    } else if (changed) {
      this.emitState();
    }
  }

  // 选中型控件的点击(单选/多选/开关): 只改本地绑定, 不发请求
  private toggleChoice(el: UiElement, value: string, multi: boolean): void {
    if (!this.interactive()) {
      return;
    }
    let key: string = GuncatUiRuntime.stateKeyOf(el);
    if (key === '') {
      return;
    }
    let type: string = el.type;
    if (type === 'SwitchGroup') {
      let on: boolean = GuncatUiRuntime.switchValue(this.state, key, value, el);
      GuncatUiRuntime.setMapValue(this.state, key, value, !on);
    } else if (type === 'CheckBoxGroup') {
      let current: Object | null = this.state.get(key);
      let on2: boolean = GuncatUiRuntime.boolMapValue(current, value);
      GuncatUiRuntime.setMapValue(this.state, key, value, !on2);
    } else if (multi) {
      let current2: Object | null = this.state.get(key);
      let list: string[] = [];
      if (current2 instanceof Array) {
        let arr: Object[] = current2 as Object[];
        for (let i: number = 0; i < arr.length; i++) {
          list.push(GuncatUiMaterializer.toStr(arr[i]));
        }
      }
      let next: string[] = [];
      let found: boolean = false;
      for (let i: number = 0; i < list.length; i++) {
        if (list[i] === value) {
          found = true;
        } else {
          next.push(list[i]);
        }
      }
      if (!found) {
        next.push(value);
      }
      this.state.set(key, next as Object);
    } else {
      this.state.set(key, value);
    }
    this.rematerialize();
    this.emitState();
  }

  private isSelected(el: UiElement, value: string): boolean {
    let key: string = GuncatUiRuntime.stateKeyOf(el);
    let type: string = el.type;
    if (type === 'SwitchGroup') {
      return GuncatUiRuntime.switchValue(this.state, key, value, el);
    }
    if (type === 'CheckBoxGroup') {
      let current: Object | null = this.state.get(key);
      return GuncatUiRuntime.boolMapValue(current, value);
    }
    let raw: Object | null = this.state.get(key);
    if (raw === null) {
      raw = UiNode.raw(this.live(el), 'defaultValue');
    }
    if (raw instanceof Array) {
      let arr: Object[] = raw as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        if (GuncatUiMaterializer.toStr(arr[i]) === value) {
          return true;
        }
      }
      return false;
    }
    return GuncatUiMaterializer.toStr(raw) === value;
  }

  private expandKey(el: UiElement, sub: string): string {
    return el.key + '#' + sub;
  }

  private isExpanded(el: UiElement, sub: string, defaultOpen: boolean): boolean {
    let v: boolean | undefined = this.expanded[this.expandKey(el, sub)];
    return v === undefined ? defaultOpen : v;
  }

  private toggleExpand(el: UiElement, sub: string, defaultOpen: boolean): void {
    let key: string = this.expandKey(el, sub);
    let next: Record<string, boolean> = {};
    let keys: string[] = Object.keys(this.expanded);
    for (let i: number = 0; i < keys.length; i++) {
      next[keys[i]] = this.expanded[keys[i]];
    }
    next[key] = !this.isExpanded(el, sub, defaultOpen);
    this.expanded = next;
  }

  // ===== 根 =====
  //
  // 宽度约定: 界面内容整体左右各留 EDGE 的内边距, 使**文字**与同一条消息里的正文
  // (RichTextView 的 16vp 内边距)左右对齐 —— 否则界面的文字行宽会比正文更宽, 看起来"溢出去了"。
  // 只有"天然需要更宽"的组件(表格 / 图表 / 图片 / 图片墙 / 轮播)用 bleed() 反向抵消这层内边距。
  private edge(): number {
    return 16;
  }

  // 通栏组件在顶层时抵消根的内边距, 拿到整屏宽度; 嵌套在卡片里时不动(否则会溢出容器)。
  private bleed(topLevel: boolean): Margin {
    if (topLevel) {
      return { left: -this.edge(), right: -this.edge() };
    }
    return { left: 0, right: 0 };
  }

  build() {
    Column({ space: 0 }) {
      // 整棵界面的"重渲染开关": 条件恒真, 但它在**构建期**读到了 rev/sigTick ——
      // 只有这种"构建期表达式里当场读到"的 @State 才会被 ArkUI 登记成依赖(真机踩透了:
      // 读在方法内部、或只读在 .id() 上都不算), 而条件分支一重跑, 分支体里的
      // buildChildren(this.root, ...) 就会重新读一遍**刚物化出来的新树**, 各子项的
      // 渲染指纹才会重算 → 依赖绑定值的节点跟着换键重建。折叠/选项卡本来就是这个机制。
      if (this.treeAwake()) {
        if (this.root === null) {
          this.buildEmpty()
        } else {
          Column({ space: 16 }) {
            this.buildRootTree(this.root, this.rev + this.sigTick)
            this.buildSources(this.root)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: this.edge(), right: this.edge() })
        }
        // 以下"脚注区"(截断提示 / 诊断 / 原始输出)与正文左对齐, 所以同样加左右内边距
        if (this.truncated) {
          Row({ space: 6 }) {
            GuncatUiIcon({ name: 'warning', iconSize: 12, color: '#F59E0B' })
            Text('界面未写完，以上为已生成的部分')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: this.edge(), right: this.edge() })
          .margin({ top: 10 })
        }
  
        if (this.program.errors.length > 0) {
          Row({ space: 6 }) {
            Text(this.showErrors ? '收起诊断' : ('诊断 · ' + this.program.errors.length.toString() + ' 条'))
              .fontSize(10)
              .fontColor($r('app.color.text_quaternary'))
          }
          .width('100%')
          .padding({ left: this.edge(), right: this.edge() })
          .margin({ top: 8 })
          .onClick(() => {
            this.showErrors = !this.showErrors;
          })
          if (this.showErrors) {
            Column({ space: 2 }) {
              ForEach(this.program.errors, (msg: string, i: number) => {
                Text(msg)
                  .fontSize(10)
                  .fontColor($r('app.color.text_quaternary'))
                  .width('100%')
              }, (msg: string, i: number) => 'err' + i.toString())
            }
            .width('100%')
            .padding(8)
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(8)
            .margin({ left: this.edge(), right: this.edge() })
          }
        }
  
        if (this.programText.trim() !== '') {
          Row({ space: 6 }) {
            Text(this.showRaw ? '收起原始输出' : '查看原始输出')
              .fontSize(10)
              .fontColor($r('app.color.text_quaternary'))
          }
          .width('100%')
          .padding({ left: this.edge(), right: this.edge() })
          .margin({ top: 8 })
          .onClick(() => {
            this.showRaw = !this.showRaw;
          })
          if (this.showRaw) {
            Scroll() {
              Text(this.programText)
                .fontSize(10)
                .fontFamily('monospace')
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .wordBreak(WordBreak.BREAK_ALL)
            }
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .constraintSize({ maxHeight: 260 })
            .width('100%')
            .padding(10)
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(8)
            .margin({ left: this.edge(), right: this.edge() })
          }
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 这里**不再**靠 id 变化触发重渲染: 真机证明那样不管用(读取没被登记成依赖), 而且每次变化
    // 的 id 没必要。重渲染开关是上面那个恒真的 `if (this.treeAwake())`。id 保持恒定。
    .id('guncat-ui')
  }

  @Builder
  buildEmpty() {
    Column({ space: 6 }) {
      if (this.complete) {
        Text(this.programText.trim() === ''
          ? '这段界面内容为空。'
          : '这段界面没能渲染成可交互组件，可以让我重新生成一次。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      } else {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.brand'))
          Text('正在生成界面…')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  // sources: 回答用到的来源列表(渲染在最底部)
  @Builder
  buildSources(root: UiElement) {
    if (this.sourceCount(root) > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.sourceRows(root), (row: string, i: number) => {
          Text((i + 1).toString() + '. ' + row)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .borderRadius(999)
            .backgroundColor($r('app.color.surface_secondary'))
            .margin({ right: 6, bottom: 6 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }, (row: string, i: number) => 'src' + i.toString())
      }
      .width('100%')
    }
  }

  private sourceCount(root: UiElement): number {
    return UiNode.objList(this.live(root), 'sources').length;
  }

  private sourceRows(root: UiElement): string[] {
    let rows: Record<string, Object>[] = UiNode.objList(this.live(root), 'sources');
    let out: string[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      let name: string = UiNode.objStr(rows[i], 'sourceName', '');
      if (name === '') {
        name = UiNode.objStr(rows[i], 'title', '');
      }
      out.push(name);
    }
    return out;
  }

  // 渲染元素的子元素。
  //
  // ⚠️ ForEach 的键里放的是**渲染指纹**(`GuncatUiLang.elementSignature`)。这是 ArkUI 的硬约束:
  //   ForEach 在父组件重渲染时先比对新旧键值, **键值不变的项直接复用已有子组件、连 item builder
  //   都不会重新执行**。用指纹后: 内容真的变了的项换键重建, 内容没变的项继续复用。
  //
  //   ⚠️ 真机结论: **不要再指望"换键 ⇒ 重建该项"来刷新绑定值**(这条路上所有变体在这台设备上
  //   都不可靠: .id(rev) 触发器、恒真 if 包住全树、root 改 @State + 当场取新树、拖动链指纹快照
  //   —— 全部试过, 都出现过"值写对了界面就是不动")。绑定值的刷新现在由 live() 负责: 值节点在
  //   自己的表达式里读 @State 并当场从当前树取值, 于是**自己重画**, 与祖先是否重建无关。
  //   指纹键保留的意义变成: 结构真的变了(增删项、切换选中态)时该项仍能重建。
  //   键里的 epoch 参数(wake)只用来给 ForEach 登记依赖, **不进键值**。
  private itemKey(child: UiElement, wake: number): string {
    let sig: string = GuncatUiLang.elementSignature(child, this.state.values);
    return child.key + '#' + sig + (wake < 0 ? '#w' : '');
  }

  // 原样返回列表, 参数只为把 rev/sigTick 的读取放在构建期表达式里(见 itemKey 的说明)。
  private wake(list: UiElement[], wake: number): UiElement[] {
    if (wake < 0) {
      return [];
    }
    return list;
  }

  @Builder
  buildElements(list: UiElement[], topLevel: boolean) {
    ForEach(this.wake(list, this.rev + this.sigTick), (child: UiElement, index: number) => {
      this.renderNode(this.live(child), topLevel)
    }, (child: UiElement, index: number) => this.itemKey(child, this.rev + this.sigTick))
  }

  // 顶层: **数据当场从 @State 的树里取**。
  // 与 buildElements 的区别就在这里: buildElements 收的是闭包捕获的旧列表(嵌套层用它没问题 ——
  // 只要子树里有东西变了, 祖先的指纹就会变、祖先项会重建, 于是嵌套层拿到的是新元素), 但顶层
  // 没有任何祖先帮它重建, 必须自己拿新树, 否则永远按旧元素算指纹(真机症状: 绑定值改了界面不动)。
  @Builder
  buildRootTree(tree: UiElement | null, epoch: number) {
    ForEach(this.rootKids(tree, epoch), (child: UiElement, index: number) => {
      this.renderNode(this.live(child), true)
    }, (child: UiElement, index: number) => this.itemKey(child, epoch))
  }

  // 顶层子元素列表: 参数 tree/epoch 由**数据表达式当场传入**(构建期读 @State, 才会被登记成依赖)
  private rootKids(tree: UiElement | null, epoch: number): UiElement[] {
    if (tree === null || epoch < 0) {
      return [];
    }
    return UiNode.elementList(tree, 'children')
  }

  // 通用 children 容器
  @Builder
  buildChildren(el: UiElement, topLevel: boolean) {
    this.buildElements(UiNode.elementList(this.live(el), 'children'), topLevel)
  }

  // ===== 元素分发 =====
  //
  // ⚠️ 这里**不能**写 `el = this.live(el);` —— ArkTS 不允许在 @Builder 体内赋值
  // ("does not meet UI component syntax")。所以"换成当前树里的新元素"这一步放在**调用点**
  // (buildElements / buildRootTree 的 item builder 传 this.live(child)), 见那两处注释。
  @Builder
  renderNode(el: UiElement, topLevel: boolean) {
    if (el.type === 'Card') {
      Column({ space: 16 }) {
        this.buildChildren(el, false)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (el.type === 'CardHeader') {
      this.buildCardHeader(el)
    } else if (el.type === 'InlineHeader') {
      this.buildInlineHeader(el)
    } else if (el.type === 'TextContent') {
      this.buildTextContent(el)
    } else if (el.type === 'MarkDownRenderer') {
      this.buildMarkdown(el)
    } else if (el.type === 'Callout' || el.type === 'TextCallout') {
      this.buildCallout(el)
    } else if (el.type === 'Separator') {
      this.buildSeparator(el)
    } else if (el.type === 'Image') {
      this.buildImage(el, false, topLevel)
    } else if (el.type === 'ImageBlock') {
      this.buildImage(el, true, topLevel)
    } else if (el.type === 'ImageGallery') {
      this.buildGallery(el, topLevel)
    } else if (el.type === 'CodeBlock') {
      this.buildCodeBlock(el)
    } else if (el.type === 'TagBlock' || el.type === 'Tag') {
      this.buildTags(el)
    } else if (el.type === 'EntityList') {
      this.buildEntityList(el)
    } else if (el.type === 'SectionBlock') {
      this.buildSectionBlock(el)
    } else if (el.type === 'Tabs') {
      this.buildTabs(el)
    } else if (el.type === 'Accordion') {
      this.buildAccordion(el)
    } else if (el.type === 'Carousel') {
      this.buildCarousel(el, topLevel)
    } else if (el.type === 'Steps') {
      this.buildSteps(el)
    } else if (el.type === 'Table') {
      this.buildTable(el)
    } else if (this.isChart(el.type)) {
      this.buildChart(el, topLevel)
    } else if (el.type === 'Text' || el.type === 'BoldText') {
      this.buildText(el)
    } else if (el.type === 'IconText') {
      this.buildIconText(el)
    } else if (el.type === 'ImageText') {
      this.buildImageText(el)
    } else if (el.type === 'MetricIndicatorInline' ||
      el.type === 'MetricIndicatorWithStrikethrough') {
      this.buildMetric(el)
    } else if (el.type === 'ContextCardItem' || el.type === 'ContextCardBlock') {
      this.buildContextCards(el)
    } else if (el.type === 'OverviewCardItem' || el.type === 'OverviewCardBlock') {
      this.buildOverviewCards(el)
    } else if (el.type === 'SnippetCardItem' || el.type === 'SnippetCardBlock') {
      this.buildSnippetCards(el)
    } else if (el.type === 'CompositeCardItem' || el.type === 'CompositeCardBlock') {
      this.buildCompositeCards(el)
    } else if (el.type === 'VisualCardItem' || el.type === 'VisualCardBlock') {
      this.buildVisualCards(el)
    } else if (el.type === 'ListBlock') {
      this.buildListBlock(el)
    } else if (el.type === 'ListItem') {
      this.buildListItem(el, false)
    } else if (el.type === 'FollowUpBlock') {
      this.buildFollowUps(el)
    } else if (el.type === 'Form') {
      this.buildForm(el)
    } else if (el.type === 'FormControl') {
      this.buildFormControl(el)
    } else if (this.isControl(el.type)) {
      this.buildControl(el)
    } else if (el.type === 'Buttons') {
      this.buildButtons(el, null)
    } else if (el.type === 'Button') {
      this.buildButton(el, null)
    } else if (el.type === 'IconButton') {
      this.buildIconButton(el, null)
    } else if (el.type === 'Icon') {
      GuncatUiIcon({ name: UiNode.str(this.live(el), 'name', 'dot'), iconSize: 14 })
    } else if (el.type === 'Series' || el.type === 'Col' || el.type === 'SectionItem' ||
      el.type === 'TabItem' || el.type === 'AccordionItem' || el.type === 'StepsItem' ||
      el.type === 'SelectItem' || el.type === 'RadioItem' || el.type === 'CheckBoxItem' ||
      el.type === 'SwitchItem' || el.type === 'ChipItem' || el.type === 'OptionCard' ||
      el.type === 'ListItem' || el.type === 'FollowUpItem') {
      // 这些是"参数型"组件, 只能作为父组件的参数使用; 单独出现时渲染其文字兜底
      Text(this.fallbackLabel(el))
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
    } else {
      // 未知/未实现组件: 不静默吞掉, 给一行浅色提示便于排查
      Text('未支持的组件 ' + el.type)
        .fontSize(11)
        .fontColor($r('app.color.text_quaternary'))
        .width('100%')
    }
  }

  private fallbackLabel(el: UiElement): string {
    let keys: string[] = ['text', 'title', 'label', 'value', 'heading', 'name', 'trigger'];
    for (let i: number = 0; i < keys.length; i++) {
      let v: string = UiNode.str(this.live(el), keys[i], '');
      if (v !== '') {
        return v;
      }
    }
    return el.type;
  }

  // ===== 内容类组件 =====
  @Builder
  buildCardHeader(el: UiElement) {
    Column({ space: 4 }) {
      Text(UiNode.str(this.live(el), 'title', ''))
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (UiNode.has(this.live(el), 'subtitle')) {
        Text(UiNode.str(this.live(el), 'subtitle', ''))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildInlineHeader(el: UiElement) {
    Column({ space: 3 }) {
      Text(UiNode.str(this.live(el), 'heading', ''))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (UiNode.has(this.live(el), 'description')) {
        Text(UiNode.str(this.live(el), 'description', ''))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildTextContent(el: UiElement) {
    Column() {
      this.inlineRich(UiNode.str(this.live(el), 'text', ''), this.contentSize(el), $r('app.color.text_primary'), false)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private contentSize(el: UiElement): number {
    let size: string = UiNode.str(this.live(el), 'size', 'default');
    if (size === 'small') {
      return 13;
    }
    if (size === 'small-heavy') {
      return 14;
    }
    if (size === 'large') {
      return 18;
    }
    if (size === 'large-heavy') {
      return 18;
    }
    return 15;
  }

  // 行内富文本: **粗体** / `code` / [文字](https://…) —— 用 Flex 换行承载,
  // 不做完整 Markdown(那由 MarkDownRenderer 负责), 避免正文被包成代码块样式。
  @Builder
  inlineRich(text: string, textSize: number, textColor: ResourceColor, forceBold: boolean) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.inlineSegments(text), (seg: InlineSeg, i: number) => {
        if (seg.kind === 'link') {
          Text(seg.text)
            .fontSize(textSize)
            .fontColor($r('app.color.brand'))
            .decoration({ type: TextDecorationType.Underline, color: $r('app.color.brand') })
            .onClick(() => {
              this.openUrl(seg.url);
            })
        } else {
          Text(seg.text)
            .fontSize(textSize)
            .fontWeight(seg.kind === 'bold' || forceBold ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(seg.kind === 'code' ? $r('app.color.brand') : textColor)
        }
      }, (seg: InlineSeg, i: number) => 'is' + i.toString() + seg.kind)
    }
    .width('100%')
  }

  private inlineSegments(text: string): InlineSeg[] {
    let out: InlineSeg[] = [];
    if (text === '') {
      return out;
    }
    let i: number = 0;
    let buf: string = '';
    while (i < text.length) {
      let c: string = text.charAt(i);
      // **粗体**
      if (c === '*' && i + 1 < text.length && text.charAt(i + 1) === '*') {
        let close: number = text.indexOf('**', i + 2);
        if (close > i + 2) {
          if (buf !== '') {
            out.push(InlineSeg.plain(buf));
            buf = '';
          }
          out.push(InlineSeg.bold(text.substring(i + 2, close)));
          i = close + 2;
          continue;
        }
      }
      // `行内代码`
      if (c === '`') {
        let close2: number = text.indexOf('`', i + 1);
        if (close2 > i + 1) {
          if (buf !== '') {
            out.push(InlineSeg.plain(buf));
            buf = '';
          }
          out.push(InlineSeg.code(text.substring(i + 1, close2)));
          i = close2 + 1;
          continue;
        }
      }
      // [文字](url)
      if (c === '[') {
        let mid: number = text.indexOf('](', i);
        if (mid > i) {
          let end: number = text.indexOf(')', mid + 2);
          if (end > mid + 2) {
            if (buf !== '') {
              out.push(InlineSeg.plain(buf));
              buf = '';
            }
            out.push(InlineSeg.link(text.substring(i + 1, mid), text.substring(mid + 2, end)));
            i = end + 1;
            continue;
          }
        }
      }
      buf = buf + c;
      i++;
    }
    if (buf !== '') {
      out.push(InlineSeg.plain(buf));
    }
    return out;
  }

  @Builder
  buildMarkdown(el: UiElement) {
    Column() {
      RichTextView({ content: UiNode.str(this.live(el), 'textMarkdown', '') })
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor(UiNode.str(this.live(el), 'variant', 'clear') === 'sunk'
      ? $r('app.color.surface_secondary') : Color.Transparent)
    .clip(true)
  }

  @Builder
  buildCallout(el: UiElement) {
    Row() {
      GuncatUiIcon({
        name: this.toneIcon(UiNode.str(this.live(el), 'variant', 'info')),
        iconSize: 15,
        color: this.toneColor(UiNode.str(this.live(el), 'variant', 'info'))
      })
      Column({ space: 3 }) {
        if (UiNode.has(this.live(el), 'title')) {
          Text(UiNode.str(this.live(el), 'title', ''))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
        }
        if (UiNode.has(this.live(el), 'description')) {
          Text(UiNode.str(this.live(el), 'description', ''))
            .fontSize(13)
            .lineHeight(20)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
      }
      .layoutWeight(1)
      .margin({ left: 9 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  private toneIcon(variant: string): string {
    if (variant === 'success') {
      return 'success';
    }
    if (variant === 'warning') {
      return 'warning';
    }
    if (variant === 'error' || variant === 'danger') {
      return 'error';
    }
    return 'info';
  }

  private toneColor(variant: string): string {
    if (variant === 'success') {
      return '#22C55E';
    }
    if (variant === 'warning') {
      return '#F59E0B';
    }
    if (variant === 'error' || variant === 'danger') {
      return '#EF4444';
    }
    return '#4176E6';
  }

  @Builder
  buildSeparator(el: UiElement) {
    if (UiNode.str(this.live(el), 'orientation', 'horizontal') === 'vertical') {
      Divider()
        .vertical(true)
        .height(16)
        .color($r('app.color.divider'))
    } else {
      Divider()
        .color($r('app.color.divider'))
        .width('100%')
    }
  }

  // ArkTS 的 @Builder 体内只允许 UI 组件语法(不能声明局部变量), 所以取值一律走私有方法
  private imageSrc(el: UiElement): string {
    return UiNode.str(this.live(el), 'src', '');
  }

  private imageAlt(el: UiElement): string {
    return UiNode.str(this.live(el), 'alt', '');
  }

  @Builder
  buildImage(el: UiElement, block: boolean, topLevel: boolean) {
    Column() {
      if (this.isRemoteImage(this.imageSrc(el))) {
        Image(this.imageSrc(el))
          .width('100%')
          .height(block ? 200 : 170)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .interpolation(ImageInterpolation.High)
      } else {
        Row() {
          GuncatUiIcon({ name: 'image', iconSize: 18, color: '#8F8F8F' })
        }
        .width('100%')
        .height(block ? 200 : 150)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(12)
      }
      if (this.imageAlt(el) !== '' && block) {
        Text(this.imageAlt(el))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .margin(this.bleed(topLevel))
  }

  private isRemoteImage(src: string): boolean {
    if (src === '') {
      return false;
    }
    return src.indexOf('https://') === 0 || src.indexOf('http://') === 0;
  }

  @Builder
  buildGallery(el: UiElement, topLevel: boolean) {
    Row({ space: 8 }) {
      ForEach(UiNode.objList(this.live(el), 'images'), (img: Record<string, Object>, i: number) => {
        Column() {
          if (this.isRemoteImage(UiNode.objStr(this.liveRow(el, 'images', i), 'src', ''))) {
            Image(UiNode.objStr(this.liveRow(el, 'images', i), 'src', ''))
              .width('100%')
              .aspectRatio(1.25)
              .objectFit(ImageFit.Cover)
              .borderRadius(12)
              .interpolation(ImageInterpolation.High)
          } else {
            Row() {
              GuncatUiIcon({ name: 'image', iconSize: 16, color: '#8F8F8F' })
            }
            .width('100%')
            .aspectRatio(1.25)
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(12)
          }
          if (UiNode.objStr(this.liveRow(el, 'images', i), 'alt', '') !== '') {
            Text(UiNode.objStr(this.liveRow(el, 'images', i), 'alt', ''))
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 4 })
          }
        }
        .layoutWeight(1)
      }, (img: Record<string, Object>, i: number) => 'gi' + i.toString())
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin(this.bleed(topLevel))
  }

  @Builder
  buildCodeBlock(el: UiElement) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(UiNode.str(this.live(el), 'language', 'text'))
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
        Text('复制')
          .fontSize(10)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            this.copyText(UiNode.str(this.live(el), 'codeString', ''));
          })
      }
      .width('100%')
      Scroll() {
        Text(UiNode.str(this.live(el), 'codeString', ''))
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.code_text'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
      .constraintSize({ maxHeight: 320 })
      .align(Alignment.TopStart)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.code_bg'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildTags(el: UiElement) {
    Flex({ wrap: FlexWrap.Wrap }) {
      if (el.type === 'Tag') {
        this.tagPill(UiNode.str(this.live(el), 'text', ''), UiNode.str(this.live(el), 'variant', 'neutral'))
      } else {
        ForEach(UiNode.strList(this.live(el), 'tags'), (tag: string, i: number) => {
          this.tagPill(tag, 'neutral')
        }, (tag: string, i: number) => 'tg' + i.toString() + tag)
      }
    }
    .width('100%')
  }

  @Builder
  tagPill(text: string, variant: string) {
    Text(text)
      .fontSize(11)
      .fontColor(this.tagTextColor(variant))
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .borderRadius(999)
      .backgroundColor(this.tagBgColor(variant))
      .margin({ right: 6, bottom: 6 })
  }

  private tagBgColor(variant: string): ResourceColor {
    if (variant === 'info') {
      return '#E4EDFD';
    }
    if (variant === 'success') {
      return '#E3F7EC';
    }
    if (variant === 'warning') {
      return '#FDF3E0';
    }
    if (variant === 'danger') {
      return '#FDE8E6';
    }
    return $r('app.color.surface_secondary');
  }

  private tagTextColor(variant: string): ResourceColor {
    if (variant === 'info') {
      return '#2A5DB0';
    }
    if (variant === 'success') {
      return '#12805A';
    }
    if (variant === 'warning') {
      return '#946200';
    }
    if (variant === 'danger') {
      return '#B4372F';
    }
    return $r('app.color.text_secondary');
  }

  @Builder
  buildEntityList(el: UiElement) {
    Column({ space: 0 }) {
      if (UiNode.obj(this.live(el), 'header') !== null) {
        this.entityRow(el, 'header', -1, true)
      }
      ForEach(UiNode.objList(this.live(el), 'rows'), (row: Record<string, Object>, i: number) => {
        this.entityRow(el, 'rows', i, false)
      }, (row: Record<string, Object>, i: number) => 'er' + i.toString())
      if (UiNode.obj(this.live(el), 'footer') !== null) {
        this.entityRow(el, 'footer', -1, true)
      }
    }
    .width('100%')
    .borderRadius(12)
    .border({ width: 1, color: $r('app.color.divider') })
    .clip(true)
  }

  // 一行实体: 值从**当前树**里当场取(见 liveRow), 这样绑定值一变这一行自己就重画。
  @Builder
  entityRow(el: UiElement, prop: string, index: number, emphasize: boolean) {
    Row() {
      Text(UiNode.objStr(this.liveRow(el, prop, index), 'left', ''))
        .fontSize(emphasize ? 12 : 13)
        .fontWeight(emphasize ? FontWeight.Medium : FontWeight.Normal)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(UiNode.objStr(this.liveRow(el, prop, index), 'right', ''))
        .fontSize(emphasize ? 12 : 13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .flexShrink(0)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .backgroundColor(emphasize ? $r('app.color.surface_secondary') : Color.Transparent)
  }

  // ===== 图表分发 =====
  private isChart(type: string): boolean {
    return type === 'BarChart' || type === 'LineChart' || type === 'AreaChart' ||
      type === 'HorizontalBarChart' || type === 'PieChart' || type === 'RadialChart' ||
      type === 'SingleStackedBarChart' || type === 'RadarChart';
  }

  @Builder
  buildChart(el: UiElement, topLevel: boolean) {
    // 图表**不做通栏**(不再 bleed)。真机反馈: 顶层图表比同卡片的文字更靠左, 看起来"位置偏左";
    // 而嵌在 SectionBlock/Tabs 里的图表本来就对齐, 于是同一屏里图表左边缘忽左忽右(用户说的"偶尔")。
    // 图表自带刻度/图例文字, 属于"要跟正文对齐"的一类(和表格同理); 通栏只留给纯视觉的
    // 图片 / 图片墙 / 轮播(用户明确说过"其他组件宽些没关系")。
    Column({ space: 10 }) {
      // 图表标题用邻近的 InlineHeader 承载, 这里不再重复
      if (el.type === 'BarChart') {
        GuncatUiBarChart({
          labels: UiNode.strList(this.live(el), 'labels'),
          seriesNames: this.seriesNames(el),
          seriesValues: this.seriesValues(el),
          stacked: UiNode.str(this.live(el), 'variant', 'grouped') === 'stacked',
          bodyHeight: UiNode.num(this.live(el), 'height', 150),
          yLabel: UiNode.str(this.live(el), 'yLabel', '')
        })
      } else if (el.type === 'LineChart' || el.type === 'AreaChart') {
        GuncatUiLineChart({
          labels: UiNode.strList(this.live(el), 'labels'),
          seriesNames: this.seriesNames(el),
          seriesValues: this.seriesValues(el),
          smooth: UiNode.str(this.live(el), 'variant', 'linear') === 'natural',
          area: el.type === 'AreaChart',
          showDots: UiNode.strList(this.live(el), 'labels').length <= 12,
          chartHeight: this.chartHeight(el)
        })
      } else if (el.type === 'HorizontalBarChart') {
        GuncatUiHorizontalBars({
          labels: UiNode.strList(this.live(el), 'labels'),
          seriesNames: this.seriesNames(el),
          seriesValues: this.seriesValues(el),
          colors: [],
          unit: ''
        })
      } else if (el.type === 'PieChart') {
        GuncatUiPieChart({
          labels: UiNode.strList(this.live(el), 'labels'),
          values: UiNode.numList(this.live(el), 'values'),
          donut: UiNode.str(this.live(el), 'variant', 'donut') !== 'pie'
        })
      } else if (el.type === 'RadialChart') {
        GuncatUiRadialChart({
          labels: UiNode.strList(this.live(el), 'labels'),
          values: UiNode.numList(this.live(el), 'values')
        })
      } else if (el.type === 'SingleStackedBarChart') {
        GuncatUiStackedBar({
          labels: UiNode.strList(this.live(el), 'labels'),
          values: UiNode.numList(this.live(el), 'values')
        })
      } else {
        GuncatUiRadarChart({
          labels: UiNode.strList(this.live(el), 'labels'),
          seriesNames: this.seriesNames(el),
          seriesNorm: this.seriesNorm(el)
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 折线/面积图的绘图高度: 模型给的 height 参数优先, 否则 160vp
  // (旧实现用 aspectRatio 让 ArkUI 推导高度, 真机上推出来的盒子又高又空、内容只画了一小块)
  private chartHeight(el: UiElement): number {
    let h: number = UiNode.num(this.live(el), 'height', 0);
    if (h < 80) {
      return 160;
    }
    if (h > 320) {
      return 320;
    }
    return h;
  }

  private seriesNames(el: UiElement): string[] {    let series: UiElement[] = UiNode.elementList(this.live(el), 'series');
    let out: string[] = [];
    for (let i: number = 0; i < series.length; i++) {
      out.push(UiNode.str(this.live(series[i]), 'category', '系列' + (i + 1).toString()));
    }
    return out;
  }

  private seriesValues(el: UiElement): number[][] {
    let series: UiElement[] = UiNode.elementList(this.live(el), 'series');
    let out: number[][] = [];
    for (let i: number = 0; i < series.length; i++) {
      out.push(UiNode.numList(this.live(series[i]), 'values'));
    }
    return out;
  }

  private seriesNorm(el: UiElement): number[][] {
    let values: number[][] = this.seriesValues(el);
    let max: number = 0;
    for (let i: number = 0; i < values.length; i++) {
      for (let j: number = 0; j < values[i].length; j++) {
        if (values[i][j] > max) {
          max = values[i][j];
        }
      }
    }
    if (max <= 0) {
      max = 1;
    }
    let out: number[][] = [];
    for (let i: number = 0; i < values.length; i++) {
      let row: number[] = [];
      for (let j: number = 0; j < values[i].length; j++) {
        row.push(values[i][j] / max);
      }
      out.push(row);
    }
    return out;
  }

  // ===== 表格 =====
  // 表格刻意**不做通栏**: 表头底色与每列文字都从最左侧开始, 一旦比正文宽出去就显得"整块偏左"。
  // 保持与正文同宽, 列多/列宽时靠横向滚动查看。
  @Builder
  buildTable(el: UiElement) {
    Column({ space: 0 }) {
      Scroll() {
        Column({ space: 0 }) {
          Row() {
            ForEach(UiNode.elementList(this.live(el), 'columns'), (col: UiElement, ci: number) => {
              Text(UiNode.str(this.live(col), 'label', ''))
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.brand'))
                .layoutWeight(1)
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(this.colAlign(col))
            }, (col: UiElement, ci: number) => 'th' + ci.toString())
          }
          .width(this.tableWidth(el))
          .backgroundColor($r('app.color.brand_light'))

          ForEach(this.tableRows(this.live(el)), (row: string[], ri: number) => {
            Row() {
              ForEach(row, (cell: string, ci: number) => {
                Text(this.liveCell(el, ri, ci))
                  .fontSize(11)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(this.colAlignAt(el, ci))
              }, (cell: string, ci: number) => 'tc' + ri.toString() + '_' + ci.toString())
            }
            .width(this.tableWidth(el))
            .backgroundColor(ri % 2 === 0 ? Color.Transparent : $r('app.color.surface_secondary'))
          }, (row: string[], ri: number) => 'tr' + ri.toString())
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

  private tableWidth(el: UiElement): number {
    let cols: number = UiNode.elementList(this.live(el), 'columns').length;
    return cols <= 0 ? 300 : cols * 116;
  }

  private colAlign(col: UiElement): TextAlign {
    return UiNode.str(this.live(col), 'type', 'string') === 'number' ? TextAlign.End : TextAlign.Start;
  }

  private colAlignAt(el: UiElement, index: number): TextAlign {
    let cols: UiElement[] = UiNode.elementList(this.live(el), 'columns');
    if (index >= cols.length) {
      return TextAlign.Start;
    }
    return this.colAlign(cols[index]);
  }

  // 列式数据 → 行数组
  private tableRows(el: UiElement): string[][] {
    let cols: UiElement[] = UiNode.elementList(this.live(el), 'columns');
    let data: string[][] = [];
    let maxLen: number = 0;
    for (let i: number = 0; i < cols.length; i++) {
      let values: string[] = this.colTexts(cols[i]);
      data.push(values);
      if (values.length > maxLen) {
        maxLen = values.length;
      }
    }
    let rows: string[][] = [];
    let limit: number = maxLen < 80 ? maxLen : 80;
    for (let r: number = 0; r < limit; r++) {
      let row: string[] = [];
      for (let c: number = 0; c < cols.length; c++) {
        row.push(r < data[c].length ? data[c][r] : '');
      }
      rows.push(row);
    }
    return rows;
  }

  private colTexts(col: UiElement): string[] {
    let raw: Object | null = UiNode.raw(this.live(col), 'data');
    let out: string[] = [];
    if (raw === null) {
      return out;
    }
    let isNumber: boolean = UiNode.str(this.live(col), 'type', 'string') === 'number';
    if (raw instanceof Array) {
      let arr: Object[] = raw as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        if (isNumber) {
          out.push(UiNum.value(GuncatUiMaterializer.toNum(arr[i])));
        } else {
          out.push(GuncatUiMaterializer.toStr(arr[i]));
        }
      }
      return out;
    }
    out.push(isNumber ? UiNum.value(GuncatUiMaterializer.toNum(raw)) : GuncatUiMaterializer.toStr(raw));
    return out;
  }

  // ===== 布局类组件 =====
  @Builder
  buildSectionBlock(el: UiElement) {
    Column({ space: 8 }) {
      ForEach(UiNode.elementList(this.live(el), 'sections'), (sec: UiElement, i: number) => {
        Column({ space: 8 }) {
          Row({ space: 6 }) {
            Text(UiNode.str(this.live(sec), 'trigger', ''))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            // isFoldable=false 的分节始终展开, 不显示折叠箭头
            if (this.foldable(el)) {
              GuncatUiChevron({
                up: this.isExpanded(el, this.sectionKey(sec, i), true),
                iconSize: 16
              })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (this.foldable(el)) {
              this.toggleExpand(el, this.sectionKey(sec, i), true);
            }
          })

          if (!this.foldable(el) || this.isExpanded(el, this.sectionKey(sec, i), true)) {
            Column({ space: 12 }) {
              this.buildElements(UiNode.elementList(this.live(sec), 'content'), false)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(12)
        .alignItems(HorizontalAlign.Start)
      }, (sec: UiElement, i: number) => sec.key)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 分节的折叠键: 优先用 value, 缺省退回下标(不能把下标直接写进表达式, @Builder 里不允许局部变量)
  private sectionKey(sec: UiElement, index: number): string {
    let value: string = UiNode.str(this.live(sec), 'value', '');
    return value === '' ? 'i' + index.toString() : value;
  }

  private foldable(el: UiElement): boolean {
    return UiNode.bool(this.live(el), 'isFoldable', true);
  }

  @Builder
  buildTabs(el: UiElement) {
    Column({ space: 12 }) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
            Text(UiNode.str(this.live(item), 'trigger', ''))
              .fontSize(13)
              .fontWeight(this.selectedIndexOf(el) === i ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.selectedIndexOf(el) === i ? Color.White : $r('app.color.text_secondary'))
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(999)
              .backgroundColor(this.selectedIndexOf(el) === i
                ? $r('app.color.brand') : $r('app.color.surface_secondary'))
              .onClick(() => {
                this.selectTab(el, i);
              })
          }, (item: UiElement, i: number) => 'tab' + i.toString())
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      Column({ space: 12 }) {
        ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
          if (this.selectedIndexOf(el) === i) {
            this.buildElements(UiNode.elementList(this.live(item), 'content'), false)
          }
        }, (item: UiElement, i: number) => 'tabc' + i.toString() + '_' + this.selectedIndexOf(el).toString())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private selectedIndexOf(el: UiElement): number {
    let v: number | undefined = this.selectedTab[el.key];
    return v === undefined ? 0 : v;
  }

  private selectTab(el: UiElement, index: number): void {
    let next: Record<string, number> = {};
    let keys: string[] = Object.keys(this.selectedTab);
    for (let i: number = 0; i < keys.length; i++) {
      next[keys[i]] = this.selectedTab[keys[i]];
    }
    next[el.key] = index;
    this.selectedTab = next;
  }

  @Builder
  buildAccordion(el: UiElement) {
    Column({ space: 8 }) {
      ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
        Column({ space: 8 }) {
          Row({ space: 6 }) {
            Text(UiNode.str(this.live(item), 'trigger', ''))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            GuncatUiChevron({
              up: this.isExpanded(el, UiNode.str(this.live(item), 'value', i.toString()), i === 0),
              iconSize: 16
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.toggleExpand(el, UiNode.str(this.live(item), 'value', i.toString()), i === 0);
          })

          if (this.isExpanded(el, UiNode.str(this.live(item), 'value', i.toString()), i === 0)) {
            Column({ space: 12 }) {
              this.buildElements(UiNode.elementList(this.live(item), 'content'), false)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(12)
        .alignItems(HorizontalAlign.Start)
      }, (item: UiElement, i: number) => item.key)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildCarousel(el: UiElement, topLevel: boolean) {
    Scroll() {
      Row({ space: 10 }) {
        ForEach(UiNode.elementList(this.live(el), 'children'), (child: UiElement, i: number) => {
          Column({ space: 10 }) {
        this.renderNode(this.live(child), false)
          }
          .width(264)
          .padding(12)
          .backgroundColor($r('app.color.surface_secondary'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)
        }, (child: UiElement, i: number) => 'cr' + i.toString() + '_' + child.key)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.TopStart)
    .margin(this.bleed(topLevel))
  }

  @Builder
  buildSteps(el: UiElement) {
    Column({ space: 0 }) {
      ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
        Row({ space: 10 }) {
          Column() {
            Text((i + 1).toString())
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
          }
          .width(20)
          .height(20)
          .borderRadius(10)
          .backgroundColor($r('app.color.brand'))
          .justifyContent(FlexAlign.Center)

          Column({ space: 3 }) {
            Text(UiNode.str(this.live(item), 'title', ''))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text(UiNode.str(this.live(item), 'details', ''))
              .fontSize(12)
              .lineHeight(19)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .alignItems(VerticalAlign.Top)
      }, (item: UiElement, i: number) => 'step' + i.toString())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 指标与文本 =====
  @Builder
  buildText(el: UiElement) {
    Column({ space: 3 }) {
      Text(UiNode.str(this.live(el), 'value', ''))
        .fontSize(this.textSize(el))
        .fontWeight(el.type === 'BoldText' || UiNode.str(this.live(el), 'variant', 'text') === 'number'
          ? FontWeight.Bold : FontWeight.Normal)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (UiNode.has(this.live(el), 'subtext')) {
        Text(UiNode.str(this.live(el), 'subtext', ''))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private textSize(el: UiElement): number {
    let size: string = UiNode.str(this.live(el), 'size', 'md');
    if (size === 'xs') {
      return 12;
    }
    if (size === 'sm') {
      return 14;
    }
    if (size === 'lg') {
      return 22;
    }
    return 16;
  }

  @Builder
  buildIconText(el: UiElement) {
    // 布局说明: 不再用 Row({space}) 让"间距"隐式产生, 而是给文本列显式 margin-left。
    // 真机事故: Row 里"固定尺寸图标 + layoutWeight 文本"时, 图标的布局宽度偶尔被测成 0,
    // 文本于是左移到图标下面(截图表现为"图标压在标题第一个字上")。显式 margin + 图标自身
    // 的 flexShrink(0)/minWidth 双重约束后, 无论测量怎么抖动两者都不会重叠。
    Row() {
      GuncatUiIconBadge({
        name: UiNode.element(this.live(el), 'icon') === null ? 'dot'
          : UiNode.str(UiNode.element(this.live(el), 'icon') as UiElement, 'name', 'dot'),
        badgeSize: 30
      })
      Column({ space: 2 }) {
        Text(UiNode.str(this.live(el), 'title', ''))
          .fontSize(13)
          .fontWeight(UiNode.bool(this.live(el), 'bold', false) ? FontWeight.Bold : FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (UiNode.has(this.live(el), 'subtitle')) {
          Text(UiNode.str(this.live(el), 'subtitle', ''))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .margin({ left: 10 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildImageText(el: UiElement) {
    // 与 IconText 同理: 固定尺寸缩略图 + 显式 margin, 避免"缩略图被压到 0 宽后与标题重叠"
    Row() {
      if (this.isRemoteImage(UiNode.str(this.live(el), 'src', ''))) {
        Image(UiNode.str(this.live(el), 'src', ''))
          .width(40)
          .height(40)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.High)
          .constraintSize({ minWidth: 40, minHeight: 40 })
          .flexShrink(0)
      } else {
        Stack() {
          GuncatUiIcon({ name: 'image', iconSize: 15, color: '#8F8F8F' })
        }
        .width(40)
        .height(40)
        .constraintSize({ minWidth: 40, minHeight: 40 })
        .flexShrink(0)
        .borderRadius(10)
        .backgroundColor($r('app.color.surface_secondary'))
      }
      Column({ space: 2 }) {
        Text(UiNode.str(this.live(el), 'title', ''))
          .fontSize(13)
          .fontWeight(UiNode.bool(this.live(el), 'bold', false) ? FontWeight.Bold : FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (UiNode.has(this.live(el), 'subtitle')) {
          Text(UiNode.str(this.live(el), 'subtitle', ''))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .margin({ left: 10 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildMetric(el: UiElement) {
    Row({ space: 8 }) {
      Text(UiNode.str(this.live(el), 'value', ''))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      if (UiNode.has(this.live(el), 'previousValue')) {
        Text(UiNode.str(this.live(el), 'previousValue', ''))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .decoration({ type: TextDecorationType.LineThrough, color: $r('app.color.text_tertiary') })
      }
      if (this.trendText(el) !== '') {
        Text(this.trendText(el))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.trendUp(el) ? '#12805A' : '#B4372F')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor(this.trendUp(el) ? '#E3F7EC' : '#FDE8E6')
      }
      if (UiNode.has(this.live(el), 'subtext')) {
        Text(UiNode.str(this.live(el), 'subtext', ''))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  private trendText(el: UiElement): string {
    let trend: Record<string, Object> | null = UiNode.obj(this.live(el), 'trend');
    if (trend === null) {
      return '';
    }
    let value: number = UiNode.objNum(trend, 'value', 0);
    if (value === 0) {
      return '';
    }
    let dir: string = UiNode.objStr(trend, 'direction', 'up');
    return (dir === 'down' ? '▼ ' : '▲ ') + UiNum.trim(Math.abs(value)) + '%';
  }

  private trendUp(el: UiElement): boolean {
    let trend: Record<string, Object> | null = UiNode.obj(this.live(el), 'trend');
    if (trend === null) {
      return true;
    }
    return UiNode.objStr(trend, 'direction', 'up') !== 'down';
  }

  // ===== 卡片块 =====
  @Builder
  buildContextCards(el: UiElement) {
    if (el.type === 'ContextCardItem') {
      this.contextCard(el)
    } else {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
          Column() {
            this.contextCard(item)
          }
          .width(UiNode.elementList(this.live(el), 'items').length <= 1 ? '100%' : '48%')
          .margin({ bottom: 8 })
        }, (item: UiElement, i: number) => 'cc' + i.toString())
      }
      .width('100%')
    }
  }

  @Builder
  contextCard(item: UiElement) {
    Column({ space: 4 }) {
      Text(UiNode.str(this.live(item), 'title', ''))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (UiNode.has(this.live(item), 'body')) {
        Text(UiNode.str(this.live(item), 'body', ''))
          .fontSize(12)
          .lineHeight(19)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildOverviewCards(el: UiElement) {
    if (el.type === 'OverviewCardItem') {
      this.overviewCard(el)
    } else {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
          Column() {
            this.overviewCard(item)
          }
          .width(UiNode.elementList(this.live(el), 'items').length <= 1 ? '100%' : '48%')
          .margin({ bottom: 8 })
        }, (item: UiElement, i: number) => 'oc' + i.toString())
      }
      .width('100%')
    }
  }

  @Builder
  overviewCard(item: UiElement) {
    Column({ space: 8 }) {
      if (UiNode.element(this.live(item), 'top') !== null) {
        this.renderNode(UiNode.element(this.live(item), 'top') as UiElement, false)
      }
      if (UiNode.element(this.live(item), 'bottom') !== null) {
        this.renderNode(UiNode.element(this.live(item), 'bottom') as UiElement, false)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildSnippetCards(el: UiElement) {
    if (el.type === 'SnippetCardItem') {
      this.snippetCard(el)
    } else {
      Column({ space: 8 }) {
        ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
          this.snippetCard(item)
        }, (item: UiElement, i: number) => 'sc' + i.toString())
      }
      .width('100%')
    }
  }

  @Builder
  snippetCard(item: UiElement) {
    Row({ space: 8 }) {
      Column() {
        if (UiNode.element(this.live(item), 'lhs') !== null) {
          this.renderNode(UiNode.element(this.live(item), 'lhs') as UiElement, false)
        }
      }
      .layoutWeight(1)
      if (UiNode.element(this.live(item), 'rhs') !== null) {
        this.renderNode(UiNode.element(this.live(item), 'rhs') as UiElement, false)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildCompositeCards(el: UiElement) {
    if (el.type === 'CompositeCardItem') {
      this.compositeCard(el)
    } else {
      Column({ space: 10 }) {
        ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
          this.compositeCard(item)
        }, (item: UiElement, i: number) => 'mc' + i.toString())
      }
      .width('100%')
    }
  }

  @Builder
  compositeCard(item: UiElement) {
    Column({ space: 10 }) {
      if (UiNode.element(this.live(item), 'header') !== null) {
        this.renderNode(UiNode.element(this.live(item), 'header') as UiElement, false)
      }
      Column({ space: 8 }) {
        this.buildElements(UiNode.elementList(this.live(item), 'body'), false)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      if (UiNode.obj(this.live(item), 'footer') !== null) {
        Row({ space: 10 }) {
          if (UiNode.objStr(UiNode.obj(this.live(item), 'footer'), 'price', '') !== '') {
            Text(UiNode.objStr(UiNode.obj(this.live(item), 'footer'), 'price', ''))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
          } else {
            Blank()
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .border({ width: 1, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildVisualCards(el: UiElement) {
    if (el.type === 'VisualCardItem') {
      this.visualCard(el)
    } else {
      Column({ space: 10 }) {
        ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
          this.visualCard(item)
        }, (item: UiElement, i: number) => 'vc' + i.toString())
      }
      .width('100%')
    }
  }

  @Builder
  visualCard(item: UiElement) {
    Column({ space: 8 }) {
      if (UiNode.element(this.live(item), 'tag') !== null) {
        Row() {
          this.renderNode(UiNode.element(this.live(item), 'tag') as UiElement, false)
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      if (UiNode.element(this.live(item), 'body') !== null) {
        this.renderNode(UiNode.element(this.live(item), 'body') as UiElement, false)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.brand_light'))
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 列表与追问 =====
  @Builder
  buildListBlock(el: UiElement) {
    Column({ space: el.type === 'ListBlock' && UiNode.str(this.live(el), 'variant', 'number') === 'number' ? 0 : 8 }) {
      ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
        if (UiNode.str(this.live(el), 'variant', 'number') === 'image') {
          Row() {
            if (this.isRemoteImage(UiNode.objStr(UiNode.obj(this.live(item), 'image'), 'src', ''))) {
              Image(UiNode.objStr(UiNode.obj(this.live(item), 'image'), 'src', ''))
                .width(44)
                .height(44)
                .borderRadius(10)
                .objectFit(ImageFit.Cover)
                .constraintSize({ minWidth: 44, minHeight: 44 })
                .flexShrink(0)
            }
            Column({ space: 2 }) {
              Text(UiNode.str(this.live(item), 'title', ''))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              if (UiNode.has(this.live(item), 'subtitle')) {
                Text(UiNode.str(this.live(item), 'subtitle', ''))
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
              }
            }
            .layoutWeight(1)
            .margin({ left: 10 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .alignItems(VerticalAlign.Center)
        } else {
          Row({ space: 9 }) {
            Column() {
              Text((i + 1).toString())
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.brand'))
            }
            .width(20)
            .height(20)
            .constraintSize({ minWidth: 20, minHeight: 20 })
            .flexShrink(0)
            .borderRadius(10)
            .backgroundColor($r('app.color.brand_light'))
            .justifyContent(FlexAlign.Center)

            Column({ space: 2 }) {
              Text(UiNode.str(this.live(item), 'title', ''))
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              if (UiNode.has(this.live(item), 'subtitle')) {
                Text(UiNode.str(this.live(item), 'subtitle', ''))
                  .fontSize(12)
                  .lineHeight(19)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            if (UiNode.has(this.live(item), 'actionLabel')) {
              Text(UiNode.str(this.live(item), 'actionLabel', ''))
                .fontSize(12)
                .fontColor($r('app.color.brand'))
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(999)
                .backgroundColor($r('app.color.brand_light'))
                .enabled(this.interactive())
                .onClick(() => {
                  this.runButton(item, null);
                })
            }
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .alignItems(VerticalAlign.Top)
        }
      }, (item: UiElement, i: number) => 'li' + i.toString() + item.key)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildListItem(el: UiElement, insideBlock: boolean) {
    Column({ space: 2 }) {
      Text(UiNode.str(this.live(el), 'title', ''))
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (UiNode.has(this.live(el), 'subtitle')) {
        Text(UiNode.str(this.live(el), 'subtitle', ''))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildFollowUps(el: UiElement) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
        Text(UiNode.str(this.live(item), 'text', ''))
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(999)
          .backgroundColor($r('app.color.brand_light'))
          .margin({ right: 8, bottom: 8 })
          .enabled(this.interactive())
          .onClick(() => {
            this.emitAction(UiNode.str(this.live(item), 'text', ''));
          })
      }, (item: UiElement, i: number) => 'fu' + i.toString())
    }
    .width('100%')
  }

  // ===== 表单 =====
  private isControl(type: string): boolean {
    return type === 'Input' || type === 'TextArea' || type === 'Select' ||
      type === 'Slider' || type === 'RadioGroup' || type === 'CheckBoxGroup' ||
      type === 'SwitchGroup' || type === 'Chips' || type === 'OptionCards' ||
      type === 'DatePicker';
  }

  @Builder
  buildForm(el: UiElement) {
    Column({ space: 14 }) {
      Column({ space: 14 }) {
        this.buildElements(UiNode.elementList(this.live(el), 'fields'), false)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      this.buildButtons(UiNode.element(this.live(el), 'buttons'), el)
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface_secondary'))
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildFormControl(el: UiElement) {
    Column({ space: 7 }) {
      Text(UiNode.str(this.live(el), 'label', ''))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (UiNode.element(this.live(el), 'input') !== null) {
        this.renderNode(UiNode.element(this.live(el), 'input') as UiElement, false)
      }
      if (UiNode.has(this.live(el), 'hint')) {
        Text(UiNode.str(this.live(el), 'hint', ''))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildControl(el: UiElement) {
    if (el.type === 'Input') {
      this.buildInput(el, false)
    } else if (el.type === 'TextArea') {
      this.buildInput(el, true)
    } else if (el.type === 'DatePicker') {
      this.buildDatePicker(el)
    } else if (el.type === 'Slider') {
      this.buildSlider(el)
    } else if (el.type === 'SwitchGroup') {
      this.buildSwitchGroup(el)
    } else if (el.type === 'CheckBoxGroup') {
      this.buildPillGroup(el, true)
    } else if (el.type === 'RadioGroup') {
      this.buildPillGroup(el, false)
    } else if (el.type === 'Select') {
      this.buildSelect(el)
    } else if (el.type === 'Chips') {
      this.buildChips(el)
    } else if (el.type === 'OptionCards') {
      this.buildOptionCards(el)
    }
  }

  @Builder
  buildInput(el: UiElement, multiline: boolean) {
    Column({ space: 4 }) {
      if (multiline) {
        TextArea({
          text: this.bindStr(GuncatUiRuntime.stateKeyOf(el), ''),
          placeholder: UiNode.str(this.live(el), 'placeholder', '')
        })
          .width('100%')
          .height(Math.max(64, UiNode.num(this.live(el), 'rows', 3) * 22))
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_quaternary'))
          .backgroundColor($r('app.color.surface'))
          .borderRadius(10)
          .enabled(this.interactive())
          .onChange((value: string) => {
            this.state.set(GuncatUiRuntime.stateKeyOf(el), value);
          })
          .onBlur(() => {
            this.emitState();
          })
      } else {
        TextInput({
          text: this.bindStr(GuncatUiRuntime.stateKeyOf(el), ''),
          placeholder: UiNode.str(this.live(el), 'placeholder', '')
        })
          .width('100%')
          .height(40)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_quaternary'))
          .backgroundColor($r('app.color.surface'))
          .borderRadius(10)
          .type(this.inputType(UiNode.str(this.live(el), 'type', 'text')))
          .enabled(this.interactive())
          .onChange((value: string) => {
            this.state.set(GuncatUiRuntime.stateKeyOf(el), value);
          })
          .onSubmit(() => {
            this.emitState();
          })
          .onBlur(() => {
            this.emitState();
          })
      }
      if (this.ruleText(el) !== '') {
        Text(this.ruleText(el))
          .fontSize(10)
          .fontColor($r('app.color.text_quaternary'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private inputType(type: string): InputType {
    if (type === 'number') {
      return InputType.Number;
    }
    if (type === 'email') {
      return InputType.Email;
    }
    if (type === 'url') {
      return InputType.Normal;
    }
    return InputType.Normal;
  }

  private ruleText(el: UiElement): string {
    let rules: Record<string, Object> | null = UiNode.obj(this.live(el), 'rules');
    if (rules === null) {
      return '';
    }
    let parts: string[] = [];
    let req: Object | undefined = rules['required'];
    if (req !== undefined && GuncatUiMaterializer.truthy(req)) {
      parts.push('必填');
    }
    let min: Object | undefined = rules['min'];
    if (min !== undefined) {
      parts.push('≥' + UiNum.trim(GuncatUiMaterializer.toNum(min)));
    }
    let max: Object | undefined = rules['max'];
    if (max !== undefined) {
      parts.push('≤' + UiNum.trim(GuncatUiMaterializer.toNum(max)));
    }
    return parts.join(' · ');
  }

  @Builder
  buildDatePicker(el: UiElement) {
    TextInput({
      text: this.bindStr(GuncatUiRuntime.stateKeyOf(el), ''),
      placeholder: UiNode.str(this.live(el), 'mode', 'single') === 'range' ? '开始日期 ~ 结束日期' : 'YYYY-MM-DD'
    })
      .width('100%')
      .height(40)
      .fontSize(14)
      .fontColor($r('app.color.text_primary'))
      .placeholderColor($r('app.color.text_quaternary'))
      .backgroundColor($r('app.color.surface'))
      .borderRadius(10)
      .enabled(this.interactive())
      .onChange((value: string) => {
        this.state.set(GuncatUiRuntime.stateKeyOf(el), value);
      })
      .onBlur(() => {
        this.emitState();
      })
  }

  @Builder
  buildSlider(el: UiElement) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        if (UiNode.has(this.live(el), 'label')) {
          Text(UiNode.str(this.live(el), 'label', ''))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Blank()
        }
        Text(this.sliderValueText(el))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
          .flexShrink(0)
      }
      .width('100%')

      Slider({
        value: this.bindNum(GuncatUiRuntime.stateKeyOf(el), GuncatUiRuntime.sliderDefault(el)),
        min: UiNode.num(this.live(el), 'min', 0),
        max: UiNode.num(this.live(el), 'max', 100),
        step: this.sliderStep(el),
        style: SliderStyle.OutSet
      })
        .width('100%')
        .selectedColor($r('app.color.brand'))
        .trackColor($r('app.color.surface'))
        .blockColor($r('app.color.surface'))
        .enabled(this.interactive())
        .onChange((value: number, mode: SliderChangeMode) => {
          // 拖动期间的刷新策略:
          //   值节点全部靠 live() 在**自己重画时**从新树取值(见 live 的注释), 所以拖动中只要
          //   重新物化 + 推进 sigTick, 界面就跟着变, 而且**不会重建任何一个 ForEach 项** ——
          //   正在拖的 Slider 因此不会被销毁, 不需要任何"冻结/快照"机制。
          //   收尾仍统一走 finishDrag: End/Click 是明确信号, 静默计时器兜底(真机上 End 不一定来)。
          if (mode === SliderChangeMode.Begin) {
            this.dragging = true;
          }
          this.state.set(GuncatUiRuntime.stateKeyOf(el), value);
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.finishDrag(true);
            return;
          }
          // 拖动中: 每次收到 Moving 就重新起一个"静默计时器"。真机上 End 可能不来(用户反馈
          // 松手后不刷新), 而**不要**用 .onTouch 兜底 —— 给 Slider 挂 onTouch 会插手它的触摸
          // 派发, 真机表现是"只能点选、不跟手"(拖不起来)。用"一段时间没有新的 Moving"来判定
          // 松手最安全: 不碰触摸管线, 且 finishDrag 幂等。
          this.armDragIdleTimer();
          // 节流刷新: 只换树 + 推进 sigTick(不重建任何项), 让值节点自己重画
          let now: number = Date.now();
          if (now - this.lastLiveTickMs >= 80) {
            this.lastLiveTickMs = now;
            this.revalue();
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // Slider 自己的数值文案。
  // 拖动期间 Slider 所在的项被**冻结**(为了不销毁手势), 整项不会重建 —— 但这一行文字必须继续
  // 跟着走。这里读一下 sigTick, 就让 ArkUI 把这个 Text 元素登记成依赖它的元素: sigTick 一变
  // 它自己重画, 不需要整项重建(同文件里折叠/选项卡也是靠按元素依赖跟踪工作的)。
  private sliderValueText(el: UiElement): string {
    let tick: number = this.sigTick;
    let text: string = UiNum.trim(this.bindNum(GuncatUiRuntime.stateKeyOf(el),
      GuncatUiRuntime.sliderDefault(el)));
    return tick < 0 ? '' : text;
  }

  private sliderStep(el: UiElement): number {
    let step: number = UiNode.num(this.live(el), 'step', 0);
    if (step > 0) {
      return step;
    }
    return UiNode.str(this.live(el), 'variant', 'continuous') === 'discrete' ? 1 : 1;
  }

  @Builder
  buildSwitchGroup(el: UiElement) {
    Column({ space: 0 }) {
      ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(UiNode.str(this.live(item), 'label', UiNode.str(this.live(item), 'name', '')))
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            if (UiNode.has(this.live(item), 'description')) {
              Text(UiNode.str(this.live(item), 'description', ''))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({
            type: ToggleType.Switch,
            isOn: this.isSelected(el, UiNode.str(this.live(item), 'name', ''))
          })
            .flexShrink(0)
            .selectedColor($r('app.color.brand'))
            .enabled(this.interactive())
            .onChange((_isOn: boolean) => {
              this.toggleChoice(el, UiNode.str(this.live(item), 'name', ''), false);
            })
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .alignItems(VerticalAlign.Center)
      }, (item: UiElement, i: number) => 'sw' + i.toString())
    }
    .width('100%')
  }

  // 单选/多选药丸组(reference 风格: 选中 = 深色实心)
  @Builder
  buildPillGroup(el: UiElement, multi: boolean) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
        if (UiNode.has(this.live(item), 'description')) {
          Column({ space: 3 }) {
            Text(UiNode.str(this.live(item), 'label', ''))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isSelected(el, this.itemValue(el, item)) && !multi
                ? $r('app.color.brand') : $r('app.color.text_primary'))
              .width('100%')
            Text(UiNode.str(this.live(item), 'description', ''))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .borderRadius(12)
          .backgroundColor($r('app.color.surface'))
          .border({
            width: 1,
            color: this.isSelected(el, this.itemValue(el, item))
              ? $r('app.color.brand') : $r('app.color.divider')
          })
          .margin({ bottom: 8 })
          .constraintSize({ minWidth: 140 })
          // 注意: 在 wrap 布局的 Flex 里用 layoutWeight 会把每一项都撑满整行,
          // 带描述的选项一律整行铺开(与 reference 的"带说明选项 = 整行卡片"一致)
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .enabled(this.interactive())
          .onClick(() => {
            this.toggleChoice(el, this.itemValue(el, item), multi);
          })
        } else {
          Text(UiNode.str(this.live(item), 'label', ''))
            .fontSize(13)
            .fontColor(this.isSelected(el, this.itemValue(el, item))
              ? Color.White : $r('app.color.text_primary'))
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .borderRadius(999)
            .backgroundColor(this.isSelected(el, this.itemValue(el, item))
              ? $r('app.color.brand') : $r('app.color.surface'))
            .border({ width: 1, color: $r('app.color.divider') })
            .margin({ right: 8, bottom: 8 })
            .enabled(this.interactive())
            .onClick(() => {
              this.toggleChoice(el, this.itemValue(el, item), multi);
            })
        }
      }, (item: UiElement, i: number) => 'pg' + i.toString() + item.key)
    }
    .width('100%')
  }

  // 选项的值: RadioItem/ChipItem/OptionCard 用 value; CheckBoxItem 用 name
  private itemValue(group: UiElement, item: UiElement): string {
    if (group.type === 'CheckBoxGroup') {
      return UiNode.str(this.live(item), 'name', '');
    }
    return UiNode.str(this.live(item), 'value', '');
  }

  @Builder
  buildSelect(el: UiElement) {
    Column({ space: 6 }) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
          Text(UiNode.str(this.live(item), 'label', ''))
            .fontSize(13)
            .fontColor(this.isSelected(el, UiNode.str(this.live(item), 'value', ''))
              ? Color.White : $r('app.color.text_primary'))
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .borderRadius(999)
            .backgroundColor(this.isSelected(el, UiNode.str(this.live(item), 'value', ''))
              ? $r('app.color.brand') : $r('app.color.surface'))
            .border({ width: 1, color: $r('app.color.divider') })
            .margin({ right: 8, bottom: 8 })
            .enabled(this.interactive())
            .onClick(() => {
              this.toggleChoice(el, UiNode.str(this.live(item), 'value', ''), false);
            })
        }, (item: UiElement, i: number) => 'sel' + i.toString() + item.key)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildChips(el: UiElement) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
        Text(UiNode.str(this.live(item), 'label', ''))
          .fontSize(12)
          .fontColor(this.isSelected(el, UiNode.str(this.live(item), 'value', ''))
            ? Color.White : $r('app.color.text_primary'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(999)
          .backgroundColor(this.isSelected(el, UiNode.str(this.live(item), 'value', ''))
            ? $r('app.color.brand') : $r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.divider') })
          .margin({ right: 8, bottom: 8 })
          .opacity(UiNode.bool(this.live(item), 'disabled', false) ? 0.45 : 1)
          .enabled(this.interactive() && !UiNode.bool(this.live(item), 'disabled', false))
          .onClick(() => {
            this.toggleChoice(el, UiNode.str(this.live(item), 'value', ''),
              UiNode.str(this.live(el), 'type', 'single') === 'multiple');
          })
      }, (item: UiElement, i: number) => 'ch' + i.toString() + item.key)
    }
    .width('100%')
  }

  @Builder
  buildOptionCards(el: UiElement) {
    Column({ space: 8 }) {
      ForEach(UiNode.elementList(this.live(el), 'items'), (item: UiElement, i: number) => {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(UiNode.str(this.live(item), 'title', ''))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            if (UiNode.has(this.live(item), 'subtitle')) {
              Text(UiNode.str(this.live(item), 'subtitle', ''))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          if (this.isSelected(el, UiNode.str(this.live(item), 'value', ''))) {
            GuncatUiIcon({ name: 'check', iconSize: 15, color: '#4176E6' })
          }
        }
        .width('100%')
        .padding(12)
        .borderRadius(12)
        .backgroundColor(this.isSelected(el, UiNode.str(this.live(item), 'value', ''))
          ? $r('app.color.brand_light') : $r('app.color.surface'))
        .border({
          width: 1,
          color: this.isSelected(el, UiNode.str(this.live(item), 'value', ''))
            ? $r('app.color.brand') : $r('app.color.divider')
        })
        .opacity(UiNode.bool(this.live(item), 'disabled', false) ? 0.45 : 1)
        .alignItems(VerticalAlign.Center)
        .enabled(this.interactive() && !UiNode.bool(this.live(item), 'disabled', false))
        .onClick(() => {
          this.toggleChoice(el, UiNode.str(this.live(item), 'value', ''),
            UiNode.str(this.live(el), 'type', 'single') === 'multiple');
        })
      }, (item: UiElement, i: number) => 'op' + i.toString() + item.key)
    }
    .width('100%')
  }

  // ===== 按钮 =====
  @Builder
  buildButtons(el: UiElement | null, form: UiElement | null) {
    if (el !== null) {
      if (UiNode.str(this.live(el), 'direction', 'row') === 'column') {
        Column({ space: 8 }) {
          this.buildElements(UiNode.elementList(this.live(el), 'buttons'), false)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      } else {
        Row({ space: 10 }) {
          ForEach(UiNode.elementList(this.live(el), 'buttons'), (btn: UiElement, i: number) => {
            Column() {
              if (btn.type === 'IconButton') {
                this.buildIconButton(btn, form)
              } else {
                this.buildButton(btn, form)
              }
            }
            // 单个按钮**不拉满整行**: 一整条彩色长条很难看(真机反馈"太难看"有一部分来自它),
            // 让它按内容宽度左对齐; 多个按钮才等分
            .layoutWeight(UiNode.elementList(this.live(el), 'buttons').length > 1 ? 1 : 0)
          }, (btn: UiElement, i: number) => 'btn' + i.toString())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
  }

  @Builder
  buildButton(el: UiElement, form: UiElement | null) {
    Text(UiNode.str(this.live(el), 'label', '按钮'))
      .fontSize(this.buttonFontSize(el))
      .fontWeight(FontWeight.Medium)
      .fontColor(this.buttonTextColor(el))
      .textAlign(TextAlign.Center)
      .width('100%')
      .constraintSize({ minHeight: this.buttonHeight(el) })
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .borderRadius(999)
      .backgroundColor(this.buttonBg(el))
      .border({ width: 1, color: this.buttonBorderColor(el) })
      .opacity(this.interactive() ? 1 : 0.5)
      .enabled(this.interactive())
      .onClick(() => {
        this.runButton(el, form);
      })
  }

  private buttonFontSize(el: UiElement): number {
    let size: string = UiNode.str(this.live(el), 'size', 'medium');
    if (size === 'extra-small' || size === 'small') {
      return 12;
    }
    if (size === 'large') {
      return 15;
    }
    return 13;
  }

  private buttonHeight(el: UiElement): number {
    let size: string = UiNode.str(this.live(el), 'size', 'medium');
    if (size === 'extra-small') {
      return 28;
    }
    if (size === 'small') {
      return 32;
    }
    if (size === 'large') {
      return 44;
    }
    return 38;
  }

  // 按钮视觉统一为"浅底 + 彩字"的胶囊, 不用实心大色块。
  // 真机反馈: 主按钮原先是大面积实心品牌蓝 + 白字(还经常被拉成一整条), 太重、很扎眼。
  // 现在: 主按钮 = brand_light 底 + brand 字(与「交互界面」胶囊同一套语言),
  //       次按钮 = raised_surface 底 + 1px 描边 + 主文字色,
  //       危险按钮 = danger_light 底 + danger 字,
  //       三级按钮 = 透明底 + brand 字(保持原样)。
  private buttonBg(el: UiElement): ResourceColor {
    if (UiNode.str(this.live(el), 'type', 'normal') === 'destructive') {
      return $r('app.color.danger_light');
    }
    let variant: string = UiNode.str(this.live(el), 'variant', 'primary');
    if (variant === 'primary') {
      return $r('app.color.brand_light');
    }
    if (variant === 'tertiary') {
      return Color.Transparent;
    }
    return $r('app.color.raised_surface');
  }

  // 次要按钮描边: 深色模式下 raised_surface 与卡片底色相同, 没有描边就"看不见按钮"
  private buttonBorderColor(el: UiElement): ResourceColor {
    if (UiNode.str(this.live(el), 'type', 'normal') === 'destructive') {
      return Color.Transparent;
    }
    return UiNode.str(this.live(el), 'variant', 'primary') === 'secondary' ?
      $r('app.color.divider') : Color.Transparent;
  }

  private buttonTextColor(el: UiElement): ResourceColor {
    if (UiNode.str(this.live(el), 'type', 'normal') === 'destructive') {
      return $r('app.color.danger');
    }
    let variant: string = UiNode.str(this.live(el), 'variant', 'primary');
    if (variant === 'primary' || variant === 'tertiary') {
      return $r('app.color.brand');
    }
    return $r('app.color.text_primary');
  }

  @Builder
  buildIconButton(el: UiElement, form: UiElement | null) {
    Row() {
      GuncatUiIcon({
        name: UiNode.element(this.live(el), 'icon') === null ? 'dot'
          : UiNode.str(UiNode.element(this.live(el), 'icon') as UiElement, 'name', 'dot'),
        iconSize: 16,
        // 与按钮文字同色(浅底 + 彩字), 不再出现"实心深蓝底 + 白图标"
        color: this.buttonTextColor(el)
      })
    }
    .width(this.buttonHeight(el))
    .height(this.buttonHeight(el))
    .borderRadius(UiNode.str(this.live(el), 'shape', 'circle') === 'square' ? 10 : this.buttonHeight(el) / 2)
    .backgroundColor(this.buttonBg(el))
    .justifyContent(FlexAlign.Center)
    .opacity(this.interactive() ? 1 : 0.5)
    .enabled(this.interactive())
    .onClick(() => {
      this.runButton(el, form);
    })
  }
}

// 行内富文本片段
class InlineSeg {
  kind: string = 'plain';
  text: string = '';
  url: string = '';

  static plain(text: string): InlineSeg {
    let s: InlineSeg = new InlineSeg();
    s.kind = 'plain';
    s.text = text;
    return s;
  }

  static bold(text: string): InlineSeg {
    let s: InlineSeg = new InlineSeg();
    s.kind = 'bold';
    s.text = text;
    return s;
  }

  static code(text: string): InlineSeg {
    let s: InlineSeg = new InlineSeg();
    s.kind = 'code';
    s.text = text;
    return s;
  }

  static link(text: string, url: string): InlineSeg {
    let s: InlineSeg = new InlineSeg();
    s.kind = 'link';
    s.text = text;
    s.url = url;
    return s;
  }
}
