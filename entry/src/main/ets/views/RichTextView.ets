// Markdown 渲染 — 使用 @luvi/lv-markdown-in 三方库
// 库提供: 完整 CommonMark + GFM 解析、内置 LaTeX / 代码高亮 / Mermaid / 流式渲染
// 库默认不直接写剪贴板 (隐私策略), 通过 setCodeCopyListener 注册回调, 自行调用 pasteboard
// 复制 / 复制 MD 按钮由 ChatBubbleView 外部触发 (vm.copyMessagePlain / copyMessageMarkdown),
// 这里只负责代码块内部点击复制
// 主题色: 引用块 / 超链接 / 列表点 等原本默认红色, 统一改为项目蓝色品牌色
// 系统主题由 EntryAbility 的 onConfigurationUpdate 写入 AppStorage('systemColorMode'),
// 这里用 @StorageProp 响应式监听, 主题切换时自动更新代码块主题与语法高亮
import { Markdown, MarkdownController, CodeHighlight } from '@luvi/lv-markdown-in';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
// 表格防闪退: 三方库 TableRender 对结构异常的表格 (空表头/缺列行) 会遍历 undefined
// 直接抛 TypeError 导致进程闪退 (3.4.5 最新版未修复), 渲染前先规范化表格结构
import { sanitizeMarkdownForRender } from '../common/MarkdownSanitizer';

@Component
export struct RichTextView {
  @Prop content: string = '';
  // 文本选择常开(长按拖选 + 局部复制); selectionTrigger 仅为兼容旧调用方保留, 已无实际作用
  @Prop @Watch('onSelectionTrigger') selectionTrigger: number = 0;
  // 消息区空白单击复位信号(ChatPage 递增): 武装(发生过拖选)状态下收到即取消选区
  @StorageLink('richSelectionResetTick') @Watch('onSelectionResetTick') resetTick: number = 0;
  // v1 组件不支持 @State 修饰 controller, 按库文档使用无装饰器字段
  private controller: MarkdownController = new MarkdownController();
  // 响应式监听系统主题 (由 EntryAbility 写入 AppStorage)
  // @Watch 回调中重建 controller 强制重新渲染数学公式
  @StorageProp('systemColorMode') @Watch('onSystemColorModeChange') systemColorMode: boolean = false;
  // 每次主题切换时递增, build() 中用 if 分支切换渲染以强制 Markdown 组件销毁重建
  // 因为库只在组件初始化时读取 controller, 同组件实例换 controller 不会触发重渲
  @State private renderKey: number = 0;

  aboutToAppear(): void {
    this.initializeController();
  }

  // 主题切换时重建 controller + 递增 renderKey, 触发 Markdown 组件销毁重建
  // (库内部公式 pixelMap 缓存随组件销毁而释放, 新组件用新 controller 渲染公式)
  onSystemColorModeChange(): void {
    this.controller = new MarkdownController();
    this.initializeController();
    this.renderKey++;
  }

  // 统一初始化 controller 的所有样式与监听
  // 主题切换时由 onSystemColorModeChange() 调用以强制重新渲染数学公式 (清空旧 pixelMap 缓存)
  private initializeController(): void {
    this.controller = new MarkdownController();
    // 主题色统一改成蓝色, 与项目 brand (#0A7AFF / #409CFF) 一致
    // 必须显式设置正文颜色, 否则库默认黑色, 在深色模式下看不见
    this.controller
      .setTextColor($r('app.color.text_primary'))
      // 各级标题 (1-6) 颜色统一改成蓝色品牌色, 库默认是红色
      .setTitleColor([
        $r('app.color.brand'),
        $r('app.color.brand'),
        $r('app.color.brand'),
        $r('app.color.brand'),
        $r('app.color.brand'),
        $r('app.color.brand')
      ])
      .setQuoteBorderColor($r('app.color.brand'))
      .setQuoteBackgroundColor($r('app.color.brand_light'))
      .setQuoteTextColor($r('app.color.text_primary'))
      .setQuoteBorderWidth(3)
      .setQuoteBorderRadius(12)
      .setQuotePadding({ left: 14, right: 12, top: 10, bottom: 10 })
      .setHyperlinkTextColor($r('app.color.brand'))
      .setHyperlinkUnderlineState(true)
      .setUlPointColor($r('app.color.brand'))
      .setTodoSelectedColor($r('app.color.brand'))
      .setInlineCodeColor($r('app.color.brand'))
      .setInlineCodeBackgroundColor($r('app.color.surface_secondary'))
      .setLineColor($r('app.color.border'))
      // 表格样式: 库默认表格背景是白色, 与深色模式下的白色正文混在一起看不见
      // 把背景统一改为 surface_secondary (浅色模式浅灰, 深色模式中灰), 表头用 brand_light 蓝色淡色
      // 交错行用 surface 让偶数行与奇数行有视觉区分
      .setTableBackgroundColor($r('app.color.surface_secondary'))
      .setTableInterleaveBackgroundColor($r('app.color.surface'))
      .setTableTitleBackgroundColor($r('app.color.brand_light'))
      .setTableTitleTextColor($r('app.color.brand'))
      .setTableOuterBorderColor($r('app.color.border'))
      .setTableInnerBorderColor($r('app.color.border'))
      .setTableBorderRadius(14);

    // setTableNormalTextColor / setTableInterleaveTextColor 返回 void, 不可链式, 单独调用
    this.controller.setTableNormalTextColor($r('app.color.text_primary'));
    this.controller.setTableInterleaveTextColor($r('app.color.text_primary'));

    // 应用代码块主题与数学公式颜色
    this.applyCodeBlockTheme(this.systemColorMode);
    this.applyLatexMathTextColor(this.systemColorMode);

    // 代码块点击复制: 库只回传文本, 业务侧负责写剪贴板
    this.controller.setCodeCopyListener((text: string) => {
      try {
        const pb = pasteboard.getSystemPasteboard();
        const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
        pb.setData(data).then(() => {
          promptAction.showToast({ message: '已复制' });
        });
      } catch (e) {
        // ignore
      }
    });
    // 文本选择复制监听 (复制局部): 长按拖选后点操作栏「复制」时回传选中文本
    // 库只回传文本, 业务侧负责写剪贴板
    this.controller.setTextSelectionCopyListener((text: string) => {
      try {
        const pb = pasteboard.getSystemPasteboard();
        const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
        pb.setData(data).then(() => {
          promptAction.showToast({ message: '已复制' });
        });
      } catch (e) {
        // ignore
      }
    });
    // 文本选择常开: 创建即允许长按拖选局部复制, 不再需要「复制局部」按钮触发
    this.controller.setTextSelectionEnable(true);
  }

  // 兼容保留: 历史调用方递增 selectionTrigger 时重复开启一次(无副作用)
  onSelectionTrigger(): void {
    this.controller.setTextSelectionEnable(true);
  }

  // 消息区空白单击信号: 武装(发生过拖选)状态下复位选区, 未武装则忽略
  onSelectionResetTick(): void {
    this.handleRootClick();
  }

  // 根据系统深色模式切换代码块主题与语法高亮配色
  private applyCodeBlockTheme(isDark: boolean): void {
    this.controller.setCodeBlockTheme(isDark ? 'dark' : 'light');
    this.controller.setCodeHighlight(isDark ? this.darkHighlight() : this.lightHighlight());
  }

  // setLatexMathTextColor 只接受 number (十六进制), 不能用 $r
  // 库默认 0xFF000000 (黑色), 在深色模式下整段公式看不清
  // 这里按主题切换, 浅色用 text_primary 的 #1B2330, 深色用 #EDF0F5
  private applyLatexMathTextColor(isDark: boolean): void {
    this.controller.setLatexMathTextColor(isDark ? 0xFFEDF0F5 : 0xFF1B2330);
  }

  // 浅色模式语法高亮: 暖色调, 适配 #F9FAFB 背景
  private lightHighlight(): CodeHighlight {
    const h = new CodeHighlight();
    h.keyword = '#7C3AED';     // 关键字 (紫)
    h.method = '#0A7AFF';      // 方法名 (蓝)
    h.type = '#0891B2';        // 类型 (青)
    h.modifier = '#7C3AED';    // 修饰符 (紫)
    h.constant = '#EA580C';    // 常量 (橙)
    h.variable = '#1B2330';    // 变量 (深灰)
    h.operator = '#475569';    // 操作符 (灰)
    h.punctuation = '#475569'; // 标点 (灰)
    h.brace = '#475569';       // 小括号 (灰)
    h.bigBrace = '#475569';    // 大括号 (灰)
    h.string = '#16A34A';      // 字符串 (绿)
    h.number = '#EA580C';      // 数字 (橙)
    h.boolean = '#7C3AED';     // 布尔 (紫)
    h.nullish = '#7C3AED';     // null/undefined (紫)
    h.promise = '#0891B2';     // Promise (青)
    h.tag = '#DC2626';         // 标签名 (红)
    h.attrName = '#EA580C';    // 属性名 (橙)
    h.attrValue = '#16A34A';   // 属性值 (绿)
    h.doctype = '#475569';     // doctype (灰)
    h.comment = '#94A3B8';     // 注释 (浅灰)
    h.decorator = '#7C3AED';   // 装饰器 (紫)
    h.component = '#0A7AFF';   // 组件 (蓝)
    h.normal = '#1B2330';      // 普通文本 (深灰)
    return h;
  }

  // 深色模式语法高亮: 高饱和暖色, 适配 #111418 深背景
  private darkHighlight(): CodeHighlight {
    const h = new CodeHighlight();
    h.keyword = '#C4B5FD';     // 关键字 (浅紫)
    h.method = '#409CFF';      // 方法名 (浅蓝)
    h.type = '#67E8F9';        // 类型 (浅青)
    h.modifier = '#C4B5FD';    // 修饰符 (浅紫)
    h.constant = '#FDBA74';    // 常量 (浅橙)
    h.variable = '#EDF0F5';    // 变量 (浅灰)
    h.operator = '#CBD5E1';    // 操作符 (灰)
    h.punctuation = '#CBD5E1'; // 标点 (灰)
    h.brace = '#CBD5E1';       // 小括号 (灰)
    h.bigBrace = '#CBD5E1';    // 大括号 (灰)
    h.string = '#86EFAC';      // 字符串 (浅绿)
    h.number = '#FDBA74';      // 数字 (浅橙)
    h.boolean = '#C4B5FD';     // 布尔 (浅紫)
    h.nullish = '#C4B5FD';     // null/undefined (浅紫)
    h.promise = '#67E8F9';     // Promise (浅青)
    h.tag = '#FCA5A5';         // 标签名 (浅红)
    h.attrName = '#FDBA74';    // 属性名 (浅橙)
    h.attrValue = '#86EFAC';   // 属性值 (浅绿)
    h.doctype = '#CBD5E1';     // doctype (灰)
    h.comment = '#64748B';     // 注释 (中灰)
    h.decorator = '#C4B5FD';   // 装饰器 (浅紫)
    h.component = '#409CFF';   // 组件 (浅蓝)
    h.normal = '#EDF0F5';      // 普通文本 (浅灰)
    return h;
  }

  build() {
    Column() {
      // 用 if 分支切换渲染, renderKey 变化时 Markdown 会销毁旧实例重建新实例
      // 这是强制三方库组件感知 controller 变化的唯一可靠手段
      if (this.renderKey % 2 === 0) {
        Markdown({
          controller: this.controller,
          text: sanitizeMarkdownForRender(this.content),
          mode: 'text',
        })
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      } else {
        Markdown({
          controller: this.controller,
          text: sanitizeMarkdownForRender(this.content),
          mode: 'text',
        })
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      }
    }
    .width('100%')
    // 桌面端: 跟踪本组件内的左键拖选, 之后单击任意处即可取消选区
    .onMouse((event: MouseEvent) => {
      this.trackMouseForSelection(event);
    })
    // 组件内单击: 若此前发生过拖选, 复位选区(重建 Markdown 组件)
    .onClick(() => {
      this.handleRootClick();
    })
  }

  // ===== 单击取消文本选择(桌面鼠标拖选场景) =====
  // 三方库自身要求双击空白才取消, 且未公开清除选区的接口;
  // 这里跟踪"发生过拖选"状态, 拖选后的下一次单击通过 renderKey 重建组件复位选区。
  // 未拖选过的普通点击(链接/图片/代码复制等)不会触发重建, 避免无谓闪烁
  private mousePressed: boolean = false;
  private mousePressX: number = 0;
  private mousePressY: number = 0;
  private selectionArmed: boolean = false;

  private trackMouseForSelection(event: MouseEvent): void {
    if (event.action === MouseAction.Press && event.button === 0) {
      this.mousePressed = true;
      this.mousePressX = event.x;
      this.mousePressY = event.y;
    } else if (event.action === MouseAction.Move && this.mousePressed &&
      event.button === 0) {
      const dx: number = event.x - this.mousePressX;
      const dy: number = event.y - this.mousePressY;
      if (dx * dx + dy * dy > 16) {
        this.selectionArmed = true;
      }
    } else if (event.action === MouseAction.Release) {
      this.mousePressed = false;
    }
  }

  private handleRootClick(): void {
    if (!this.selectionArmed) {
      return;
    }
    this.clearActiveTextSelection();
  }

  // 复位选区: 关→开文本选择能力并重建 Markdown 组件, 高亮与操作条随之消失
  private clearActiveTextSelection(): void {
    this.selectionArmed = false;
    this.controller.setTextSelectionEnable(false);
    this.controller.setTextSelectionEnable(true);
    this.renderKey++;
  }
}
