// 交互模式 (Intelligent UI) 组件库 —— 单一事实源。
//
// 这里登记 guncat-ui lang 能用的全部组件: 名字、分组、描述、**位置参数表**。
// 同一份表同时驱动三件事:
//   1. 系统提示词里的「组件清单」(模型看到的契约);
//   2. 解析阶段的参数映射与宽松类型转换(UiRegistry / GuncatUiCoerce);
//   3. 渲染阶段的合法性判断(GuncatUiLibrary.isKnown)。
// 三者共用一张表, 才能保证「模型看到的」= 「我们解析的」= 「我们能画的」。
//
// 与参考项目(OpenUI)的取舍: 组件名/参数顺序/取值域尽量对齐, 便于复用同一套提示词习惯;
// 渲染能力受 HarmonyOS ArkUI 限制的部分(地图、3D)以等效视觉替代。
import { UiParam, UiRegistry } from './GuncatUiLang.ts';

// 组件定义
export class UiComp {
  name: string = '';
  group: string = '';
  desc: string = '';
  params: UiParam[] = [];

  constructor(name: string, group: string, desc: string, params: UiParam[]) {
    this.name = name;
    this.group = group;
    this.desc = desc;
    this.params = params;
  }
}

function p(name: string, type: string, required: boolean, hint: string): UiParam {
  let param: UiParam = new UiParam();
  param.name = name;
  param.type = type;
  param.required = required;
  param.hint = hint;
  return param;
}

function s(name: string, required: boolean): UiParam {
  return p(name, 'string', required, '');
}

function sOpt(name: string): UiParam {
  return p(name, 'string', false, '');
}

function num(name: string, required: boolean): UiParam {
  return p(name, 'number', required, '');
}

function boolean(name: string, required: boolean): UiParam {
  return p(name, 'boolean', required, '');
}

// 元素: 单个组件引用
function el(name: string, required: boolean): UiParam {
  return p(name, 'element', required, '');
}

// 元素数组: 子组件列表
function els(name: string, required: boolean): UiParam {
  return p(name, 'element[]', required, '');
}

function strings(name: string, required: boolean): UiParam {
  return p(name, 'string[]', required, '');
}

function numbers(name: string, required: boolean): UiParam {
  return p(name, 'number[]', required, '');
}

function obj(name: string, required: boolean): UiParam {
  return p(name, 'object', required, '');
}

function objs(name: string, required: boolean): UiParam {
  return p(name, 'object[]', required, '');
}

// 双向绑定参数: 传 $变量, 控件改动会写回该变量(并立即重渲染)
function bind(name: string, required: boolean): UiParam {
  return p(name, 'binding', required, '');
}

function act(name: string, required: boolean): UiParam {
  return p(name, 'action', required, '');
}

function anyOf(name: string, required: boolean): UiParam {
  return p(name, 'any', required, '');
}

export class GuncatUiLibrary {
  static readonly GROUP_ORDER: string[] = [
    '根与内容', '布局', '表格与数据', '图表', '指标与文本',
    '卡片块', '列表与追问', '表单', '按钮与图标'
  ];

  private static table: Record<string, UiComp> = {};
  private static order: string[] = [];
  private static ready: boolean = false;

  static init(): void {
    if (GuncatUiLibrary.ready) {
      return;
    }
    GuncatUiLibrary.ready = true;
    let defs: UiComp[] = GuncatUiLibrary.definitions();
    for (let i: number = 0; i < defs.length; i++) {
      let def: UiComp = defs[i];
      if (GuncatUiLibrary.table[def.name] === undefined) {
        GuncatUiLibrary.order.push(def.name);
      }
      GuncatUiLibrary.table[def.name] = def;
      UiRegistry.register(def.name, def.params);
    }
  }

  static def(name: string): UiComp | null {
    GuncatUiLibrary.init();
    let found: UiComp | undefined = GuncatUiLibrary.table[name];
    if (found === undefined) {
      return null;
    }
    return found;
  }

  static isKnown(name: string): boolean {
    return GuncatUiLibrary.def(name) !== null;
  }

  static names(): string[] {
    GuncatUiLibrary.init();
    return GuncatUiLibrary.order.slice();
  }

  private static definitions(): UiComp[] {
    let g1: string = '根与内容';
    let g2: string = '布局';
    let g3: string = '表格与数据';
    let g4: string = '图表';
    let g5: string = '指标与文本';
    let g6: string = '卡片块';
    let g7: string = '列表与追问';
    let g8: string = '表单';
    let g9: string = '按钮与图标';
    let out: UiComp[] = [];

    // ===== 根与内容 =====
    out.push(new UiComp('Card', g1,
      '回答的根容器。**root 必须是一个 Card**。第一个参数是所有内容组成的数组, 按流式顺序排列。',
      [els('children', true), objs('sources', false)]));
    out.push(new UiComp('CardHeader', g1, '标题 + 副标题。一个回答最多用一次。',
      [s('title', false), sOpt('subtitle')]));
    out.push(new UiComp('TextContent', g1,
      '一段正文(支持 **粗体**、[链接](https://…) 与 `行内代码`)。size 取 small|default|large|small-heavy|large-heavy。',
      [s('text', true), sOpt('size')]));
    out.push(new UiComp('MarkDownRenderer', g1,
      '需要完整 Markdown 排版的正文(标题/列表/表格/代码块), variant 取 clear|card|sunk。',
      [s('textMarkdown', true), sOpt('variant')]));
    out.push(new UiComp('Callout', g1,
      '强调提示条。variant 取 info|warning|error|success|neutral。',
      [s('variant', true), s('title', true), s('description', true)]));
    out.push(new UiComp('TextCallout', g1,
      '轻量提示条。variant 取 neutral|info|warning|success|danger。',
      [sOpt('variant'), sOpt('title'), sOpt('description')]));
    out.push(new UiComp('Image', g1, '单张图片。src 必须是真实可访问的 https 地址或工作区相对路径。',
      [s('alt', true), sOpt('src')]));
    out.push(new UiComp('ImageBlock', g1, '大图块, 带加载态。',
      [s('src', true), sOpt('alt')]));
    out.push(new UiComp('ImageGallery', g1,
      '图片墙(2~6 张)。每项形如 {"src":"https://…","alt":"说明"}。',
      [objs('images', true)]));
    out.push(new UiComp('CodeBlock', g1, '代码块, 带语言标记与语法高亮。',
      [s('language', true), s('codeString', true)]));
    out.push(new UiComp('Separator', g1, '分隔线。orientation 取 horizontal|vertical。',
      [sOpt('orientation')]));
    out.push(new UiComp('InlineHeader', g1, '小标题 +一句话说明。',
      [s('heading', true), sOpt('description')]));
    out.push(new UiComp('TagBlock', g1, '标签组。size 取 sm|md|lg。',
      [strings('tags', true), sOpt('size')]));
    out.push(new UiComp('Tag', g1, '单个标签。variant 取 neutral|info|success|warning|danger。',
      [s('text', true), el('icon', false), sOpt('size'), sOpt('variant')]));
    out.push(new UiComp('EntityList', g1,
      '左右两列的键值清单(合计/明细)。rows 形如 [{"left":"合计","right":"1,280","rightVariant":"number"}]。',
      [objs('rows', false), sOpt('size'), obj('header', false), obj('footer', false)]));

    // ===== 布局 =====
    out.push(new UiComp('SectionBlock', g2,
      '可折叠分节列表(比 Tabs 轻, 适合长内容分段)。sections 传 SectionItem 数组。',
      [els('sections', true), boolean('isFoldable', false)]));
    out.push(new UiComp('SectionItem', g2, '分节项: 标题 + 内容数组。',
      [s('value', true), s('trigger', true), els('content', true)]));
    out.push(new UiComp('Tabs', g2, '选项卡。items 传 TabItem 数组。',
      [els('items', true)]));
    out.push(new UiComp('TabItem', g2, '选项卡页: value 唯一标识 + trigger 标签文字 + content 内容数组。',
      [s('value', true), s('trigger', true), els('content', true)]));
    out.push(new UiComp('Accordion', g2, '折叠面板。items 传 AccordionItem 数组。',
      [els('items', true)]));
    out.push(new UiComp('AccordionItem', g2, '折叠项: value + trigger + content。',
      [s('value', true), s('trigger', true), els('content', true)]));
    out.push(new UiComp('Carousel', g2,
      '横向卡片轮播(手机上比网格更好读)。children 传卡片数组, 每项一屏卡片。',
      [els('children', true), sOpt('variant')]));
    out.push(new UiComp('Steps', g2, '步骤条。items 传 StepsItem 数组。',
      [els('items', true)]));
    out.push(new UiComp('StepsItem', g2, '步骤项: 标题 + 说明。',
      [s('title', true), s('details', true)]));

    // ===== 表格与数据 =====
    out.push(new UiComp('Table', g3,
      '列式数据表: columns 传 Col 数组, **每列自带一列数据**。适合精确数值对比。',
      [els('columns', true)]));
    out.push(new UiComp('Col', g3,
      '表格的一列: label 表头, data 该列数据数组, type 取 string|number|action。',
      [s('label', true), anyOf('data', true), sOpt('type')]));

    // ===== 图表 =====
    out.push(new UiComp('BarChart', g4,
      '柱状图。series 传 Series 数组; variant 取 grouped|stacked。',
      [strings('labels', true), els('series', true), sOpt('variant'), sOpt('xLabel'), sOpt('yLabel'), num('height', false)]));
    out.push(new UiComp('LineChart', g4,
      '折线图, 用于趋势。variant 取 linear|natural|step。',
      [strings('labels', true), els('series', true), sOpt('variant'), sOpt('xLabel'), sOpt('yLabel'), num('height', false)]));
    out.push(new UiComp('AreaChart', g4,
      '面积图, 用于累积/占比趋势。variant 取 linear|natural|step。',
      [strings('labels', true), els('series', true), sOpt('variant'), sOpt('xLabel'), sOpt('yLabel'), num('height', false)]));
    out.push(new UiComp('HorizontalBarChart', g4,
      '横向条形图(手机竖屏最易读的排名图)。variant 取 grouped|stacked。',
      [strings('labels', true), els('series', true), sOpt('variant'), sOpt('xLabel'), sOpt('yLabel')]));
    out.push(new UiComp('PieChart', g4,
      '饼图/环形图。labels 与 values 一一对应; variant 取 pie|donut。',
      [strings('labels', true), numbers('values', true), sOpt('variant')]));
    out.push(new UiComp('RadialChart', g4, '径向条形图(多个 0~100 的达成率)。',
      [strings('labels', true), numbers('values', true)]));
    out.push(new UiComp('SingleStackedBarChart', g4, '单条堆叠条, 表达整体构成。',
      [strings('labels', true), numbers('values', true)]));
    out.push(new UiComp('Series', g4, '图表的一条数据序列: category 系列名 + values 数值数组。',
      [s('category', true), numbers('values', true)]));

    // ===== 指标与文本 =====
    out.push(new UiComp('Text', g5,
      '一段带下标的文本。variant 取 text|number; size 取 xs|sm|md|lg。',
      [sOpt('variant'), s('value', true), sOpt('subtext'), sOpt('subtextVariant'), sOpt('size')]));
    out.push(new UiComp('BoldText', g5, '加粗文本(通常用于关键数字)。参数同 Text。',
      [sOpt('variant'), s('value', true), sOpt('subtext'), sOpt('subtextVariant'), sOpt('size')]));
    out.push(new UiComp('IconText', g5,
      '图标 + 标题 + 副标题。icon 传 Icon; layout 取 horizontal|vertical。',
      [el('icon', true), s('title', true), sOpt('subtitle'), boolean('bold', false), sOpt('layout')]));
    out.push(new UiComp('ImageText', g5,
      '缩略图 + 标题 + 副标题。layout 取 horizontal|vertical。',
      [s('src', true), s('title', true), sOpt('subtitle'), boolean('bold', false), sOpt('layout')]));
    out.push(new UiComp('MetricIndicatorInline', g5,
      '单个指标 + 涨跌。trend 形如 {"direction":"up","value":12.5}。',
      [s('value', true), sOpt('subtext'), obj('trend', false)]));
    out.push(new UiComp('MetricIndicatorWithStrikethrough', g5,
      '带划掉旧值的指标(改前 → 改后)。',
      [s('value', true), sOpt('subtext'), sOpt('previousValue'), obj('trend', false)]));

    // ===== 卡片块 =====
    out.push(new UiComp('SnippetCardBlock', g6,
      '紧凑信息卡网格(左图标/图 + 右数值)。items 传 SnippetCardItem; layout 取 grid。',
      [els('items', true), sOpt('layout'), num('gap', false)]));
    out.push(new UiComp('SnippetCardItem', g6, '信息卡项: lhs 图标或图, rhs 数值。',
      [el('lhs', true), el('rhs', false), sOpt('id')]));
    out.push(new UiComp('OverviewCardBlock', g6,
      '概览卡网格(上部图标/文本 + 下部指标)。items 传 OverviewCardItem。',
      [els('items', true), sOpt('layout'), num('gap', false)]));
    out.push(new UiComp('OverviewCardItem', g6, '概览卡项: top 图标/文本, bottom 指标。',
      [el('top', true), el('bottom', false), sOpt('id')]));
    out.push(new UiComp('ContextCardBlock', g6,
      '情境卡(标题 + 正文), 适合并列的几段摘要。items 传 ContextCardItem。',
      [els('items', true), sOpt('layout'), num('gap', false)]));
    out.push(new UiComp('ContextCardItem', g6, '情境卡项: title + body。',
      [s('title', true), sOpt('body'), sOpt('id'), sOpt('bgColor')]));
    out.push(new UiComp('CompositeCardBlock', g6,
      '复合卡(头部 + 主体内容数组 + 底部价格/按钮)。items 传 CompositeCardItem。',
      [els('items', true), sOpt('layout'), num('gap', false)]));
    out.push(new UiComp('CompositeCardItem', g6, '复合卡项: header 头部, body 内容数组, footer 底部。',
      [el('header', true), els('body', false), obj('footer', false), sOpt('id')]));
    out.push(new UiComp('VisualCardBlock', g6,
      '视觉卡(大图 + 角标 + 文字)。items 传 VisualCardItem。',
      [els('items', true), sOpt('layout'), num('gap', false)]));
    out.push(new UiComp('VisualCardItem', g6, '视觉卡项: body 文字, tag 角标, bgImageSrc 背景图。',
      [el('body', true), sOpt('id'), sOpt('bgImageSrc'), el('tag', false)]));

    // ===== 列表与追问 =====
    out.push(new UiComp('ListBlock', g7,
      '列表。variant 取 number|image; size 取 default|small。items 传 ListItem。',
      [els('items', true), sOpt('variant'), sOpt('size')]));
    out.push(new UiComp('ListItem', g7,
      '列表项: title + subtitle; 可选 image {"src","alt"}、actionLabel + action 做行内按钮。',
      [s('title', true), sOpt('subtitle'), obj('image', false), sOpt('actionLabel'), act('action', false)]));
    out.push(new UiComp('FollowUpBlock', g7,
      '追问建议(点一下就把该文本发给助手)。items 传 FollowUpItem。' +
      '**不推荐**: 每个界面末尾都挂三条猜出来的问题很像模板, 默认不要用; ' +
      '需要下一步入口时优先 Buttons / OptionCards 给具体动作。',
      [els('items', true)]));
    out.push(new UiComp('FollowUpItem', g7, '追问项: 一句话问题(配合 FollowUpBlock, 不推荐默认使用)。',
      [s('text', true)]));

    // ===== 表单 =====
    out.push(new UiComp('Form', g8,
      '表单容器: name 唯一标识, buttons 提交按钮组, fields 字段数组。字段填完点按钮即回传助手。',
      [s('name', true), el('buttons', true), els('fields', false)]));
    out.push(new UiComp('FormControl', g8, '表单项: 标签 + 控件 + 可选提示。',
      [s('label', true), el('input', true), sOpt('hint')]));
    out.push(new UiComp('Input', g8,
      '单行文本输入。type 取 text|number|email|url。value 传 $变量 时改动实时写回。',
      [s('name', true), sOpt('placeholder'), sOpt('type'), obj('rules', false), bind('value', false)]));
    out.push(new UiComp('TextArea', g8, '多行文本输入。rows 建议 3~6。',
      [s('name', true), sOpt('placeholder'), num('rows', false), obj('rules', false), bind('value', false)]));
    out.push(new UiComp('Select', g8, '下拉单选。items 传 SelectItem 数组。',
      [s('name', true), els('items', true), sOpt('placeholder'), obj('rules', false), bind('value', false)]));
    out.push(new UiComp('SelectItem', g8, '下拉项: value 回传值 + label 显示文字。',
      [s('value', true), s('label', true)]));
    out.push(new UiComp('Slider', g8,
      '滑块。variant 取 continuous|discrete; defaultValue 传 [数值]; value 传 $变量 时拖动实时写回。',
      [s('name', true), s('variant', true), num('min', true), num('max', true),
        num('step', false), numbers('defaultValue', false), sOpt('label'), bind('value', false)]));
    out.push(new UiComp('RadioGroup', g8, '单选组。defaultValue 必须与某个 RadioItem 的 value 完全一致。',
      [s('name', true), els('items', true), sOpt('defaultValue'), bind('value', false)]));
    out.push(new UiComp('RadioItem', g8, '单选项: label 显示, description 补充(可为空串), value 回传值。',
      [s('label', true), s('description', true), s('value', true)]));
    out.push(new UiComp('CheckBoxGroup', g8, '多选组。',
      [s('name', true), els('items', true), bind('value', false)]));
    out.push(new UiComp('CheckBoxItem', g8, '多选项: label + description + name + defaultChecked。',
      [s('label', true), s('description', true), s('name', true), boolean('defaultChecked', false)]));
    out.push(new UiComp('SwitchGroup', g8, '开关组(每项独立开关)。',
      [s('name', true), els('items', true), bind('value', false)]));
    out.push(new UiComp('SwitchItem', g8, '开关项: label + name + description。',
      [s('label', true), s('name', true), sOpt('description'), boolean('defaultChecked', false)]));
    out.push(new UiComp('Chips', g8,
      '标签选择(单/多选)。type 取 single|multiple, 点一下即写回。',
      [s('name', true), sOpt('type'), els('items', false), anyOf('defaultValue', false), bind('value', false)]));
    out.push(new UiComp('ChipItem', g8, '标签项: value + label。',
      [s('value', true), s('label', true), boolean('disabled', false)]));
    out.push(new UiComp('OptionCards', g8,
      '卡片式选择(比 Chip 更重, 适合 2~4 个互斥方案)。type 取 single|multiple。',
      [s('name', true), sOpt('type'), els('items', false), anyOf('defaultValue', false), bind('value', false)]));
    out.push(new UiComp('OptionCard', g8, '卡片选项: value + title + subtitle。',
      [s('value', true), s('title', true), sOpt('subtitle'), boolean('disabled', false)]));
    out.push(new UiComp('DatePicker', g8, '日期选择。mode 取 single|range。',
      [s('name', true), sOpt('mode'), bind('value', false)]));

    // ===== 按钮与图标 =====
    out.push(new UiComp('Button', g9,
      '按钮。**不写 action 时点一下会把 label 原文发给助手**; 需要精确控制时写 Action([...])。'
        + 'variant 取 primary|secondary|tertiary; type 取 normal|destructive; size 取 extra-small|small|medium|large。',
      [s('label', true), act('action', false), sOpt('variant'), sOpt('type'), sOpt('size')]));
    out.push(new UiComp('Buttons', g9, '按钮组。direction 取 row|column。',
      [els('buttons', true), sOpt('direction')]));
    out.push(new UiComp('IconButton', g9,
      '图标按钮。name 是唯一标识, 点一下把 name 发给助手。',
      [s('name', true), el('icon', false), act('action', false), sOpt('variant'), sOpt('size'), sOpt('shape')]));
    out.push(new UiComp('Icon', g9,
      '内置矢量图标。name 取: check, close, add, remove, arrow-right, arrow-left, arrow-up, arrow-down,'
        + ' chart, table, list, search, star, heart, share, download, edit, delete, info, warning,'
        + ' success, error, clock, calendar, user, home, settings, sparkle, refresh, filter, sort。',
      [s('name', true), sOpt('category')]));

    return out;
  }

  // ===== 提示词片段 =====
  static signature(name: string): string {
    let def: UiComp | null = GuncatUiLibrary.def(name);
    if (def === null) {
      return name;
    }
    let parts: string[] = [];
    for (let i: number = 0; i < def.params.length; i++) {
      let param: UiParam = def.params[i];
      let typeText: string = GuncatUiLibrary.typeText(param.type);
      parts.push(param.name + (param.required ? '' : '?') + ': ' + typeText);
    }
    return name + '(' + parts.join(', ') + ')';
  }

  private static typeText(type: string): string {
    if (type === 'element') {
      return '组件';
    }
    if (type === 'element[]') {
      return '组件[]';
    }
    if (type === 'string[]') {
      return 'string[]';
    }
    if (type === 'number[]') {
      return 'number[]';
    }
    if (type === 'object') {
      return '对象';
    }
    if (type === 'object[]') {
      return '对象[]';
    }
    if (type === 'action') {
      return 'Action';
    }
    if (type === 'binding') {
      return '$变量';
    }
    if (type === 'any') {
      return '任意';
    }
    return type;
  }

  // 生成「组件清单」段落(参数是位置参数, 顺序即签名顺序)
  static promptSection(): string {
    GuncatUiLibrary.init();
    let lines: string[] = [];
    lines.push('## 组件清单');
    lines.push('');
    lines.push('参数带 `?` 为可选, **参数按位置传递**(顺序即签名顺序), 不要写 `name: value`。');
    lines.push('标 `$变量` 的参数是双向绑定: 传 `$x` 后控件改动会实时写回并重渲染界面。');
    lines.push('');
    for (let gi: number = 0; gi < GuncatUiLibrary.GROUP_ORDER.length; gi++) {
      let group: string = GuncatUiLibrary.GROUP_ORDER[gi];
      let groupLines: string[] = [];
      for (let i: number = 0; i < GuncatUiLibrary.order.length; i++) {
        let def: UiComp | undefined = GuncatUiLibrary.table[GuncatUiLibrary.order[i]];
        if (def === undefined || def.group !== group) {
          continue;
        }
        groupLines.push('- `' + GuncatUiLibrary.signature(def.name) + '` — ' + def.desc);
      }
      if (groupLines.length === 0) {
        continue;
      }
      lines.push('### ' + group);
      for (let i: number = 0; i < groupLines.length; i++) {
        lines.push(groupLines[i]);
      }
      lines.push('');
    }
    return lines.join('\n');
  }

  // 容器类组件: 必须有 children/items/sections 才有内容
  static isContainer(name: string): boolean {
    return name === 'Card' || name === 'SectionBlock' || name === 'Tabs' ||
      name === 'Accordion' || name === 'Carousel' || name === 'Form' ||
      name === 'ListBlock' || name === 'FollowUpBlock' || name === 'SnippetCardBlock' ||
      name === 'OverviewCardBlock' || name === 'ContextCardBlock' ||
      name === 'CompositeCardBlock' || name === 'VisualCardBlock' || name === 'Table' ||
      name === 'Buttons' || name === 'SectionItem' || name === 'TabItem' ||
      name === 'AccordionItem';
  }
}

// 让任何一处 parse 都能自动拿到组件表
// (否则忘记显式 init 时, 所有组件都会被当成"未知组件"丢弃 —— 这是最隐蔽的一类故障)
UiRegistry.boot = (): void => {
  GuncatUiLibrary.init();
};
