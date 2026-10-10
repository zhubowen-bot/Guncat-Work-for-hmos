# 项目结构

> [← 返回 README](../../README.md)


```text
entry/src/main/ets/
├── entryability/
│   └── EntryAbility.ets
├── pages/
│   ├── ChatPage.ets                # 主页：聊天 + Agent 模式时间线（工作/交互）+ 工作区面板接线
│   └── TableOcrPage.ets
├── views/
│   ├── ChatBubbleView.ets          # 聊天气泡（含深度思考条 / 工具步骤时间线 / WorkStepFormat）
│   ├── WorkTurnView.ets            # Agent 模式时间线的单轮渲染（思考→工具→正文，无头像）
│   ├── GuncatUiView.ets            # 交互模式渲染器：把 guncat-ui lang 程序渲染为原生可交互组件
│   ├── GuncatUiCharts.ets          # 交互模式图表（柱/折线/面积/横向条/饼环/径向/雷达/堆叠条）
│   ├── GuncatUiIcons.ets           # 交互模式图标（Unicode 字形，避免 SymbolGlyph 名字缺失时静默空白）
│   ├── WorkspaceBar.ets            # Agent 模式工作区面板（文件列表/上传/导出/清空）
│   ├── RichTextView.ets
│   ├── MessageInputView.ets
│   ├── AgentDrawerView.ets
│   ├── SettingsPanel.ets
│   ├── AboutPanel.ets
│   ├── FlyInLaunchView.ets
│   ├── ToastView.ets
│   ├── FilePreviewBar.ets
│   └── ImageLightbox.ets
├── viewmodel/
│   └── ChatViewModel.ets           # 聊天状态 + Agent Loop 驱动（工作/交互模式共用，注意是 .ets）
├── service/
│   ├── ChatService.ts              # 三协议 SSE 流式（解析函数已导出供 AgentLoopService 复用）
│   ├── AgentLoopService.ts         # Agent Loop：三协议 tool-calling 单轮请求 + 按模式的系统提示词（静态, 缓存红线）
│   ├── WorkToolRunner.ets          # 工作模式工具统一分发入口（Office 生成/PPT 读写等 .ets 能力）
│   ├── WorkFileService.ts          # 沙箱工作区 + 文件类/技能类工具实现 + 工具 Schema（toolDefs）
│   ├── WorkSkillService.ts         # 技能注册表（registry）+ rawfile 技能文档加载（list/load）
│   ├── OfficeReader.ts             # docx/xlsx/pptx 本地文本抽取（zlib 解包 + XML 扫描）
│   ├── PdfTextExtractor.ts         # 本地 PDF 文本抽取（字节层对象表/页面树/ToUnicode/内容流）
│   ├── Flate.ts                    # 纯 TS 实现的 DEFLATE/zlib inflate（SDK zlib 仅文件级 API）
│   ├── MultimodalService.ts
│   ├── FileService.ts
│   ├── FileUploadService.ts
│   ├── AgentLoader.ts
│   ├── TableOcrService.ts
│   ├── TextReaderService.ets
│   ├── BackgroundReaderService.ets
│   └── VoiceInputService.ets
├── export/
│   ├── DocModel.ets                # Word 中间层：Doc JSON 解析/校验/MdToDoc/DocOps 编辑算子（纯逻辑）
│   ├── DocxBuilder.ets             # Doc→.docx 渲染（样式分级 22→12pt、图片嵌入、内嵌 docProps/doc.json 源）
│   ├── DocxImporter.ets            # .docx→Doc（自家文件内嵌源无损还原；外来近似导入 + word/media 图片抽取）
│   ├── DocxExporter.ets            # 对话一键导出入口（薄封装 DocxBuilder）
│   ├── XlsxExporter.ets            # 表格→xlsx（含 buildXlsxFromRows, transform_file 用）
│   ├── XlsxModel.ets               # Excel 中间层：Workbook JSON 解析/校验/MdToXlsx/XlsxOps 编辑算子（纯逻辑）
│   ├── XlsxBuilder.ets             # Workbook→.xlsx 渲染（多工作表/表头样式/公式/数字格式/列宽/冻结窗格/内嵌 workbook.json 源）
│   ├── XlsxImporter.ets            # .xlsx→Workbook（自家文件内嵌源无损还原；外来 XML 近似导入）
│   ├── CsvWriter.ts                # 行数据→CSV（RFC 4180 转义 + 可选 BOM, 纯逻辑）
│   ├── DeckModel.ets               # PPT 中间层：Deck JSON 解析/校验/编辑算子（纯逻辑, 无 Kit API）
│   ├── PptxThemes.ets              # 8 套主题预设 + 语义色解析（纯逻辑）
│   ├── PptxCharts.ets              # 图表 part XML（bar/line/area/pie/doughnut, 纯逻辑）
│   ├── PptxImage.ets               # 图片解析（工作区/data URL/http + 尺寸嗅探）
│   ├── PptxBuilder.ets             # Deck→pptx 渲染器（13 种版式/内嵌 deck 源/备注）
│   ├── PptxImporter.ets            # pptx→Deck（内嵌源无损还原 / 外来 XML 近似导入）
│   ├── OoxmlBuilder.ets / MarkdownParser.ets / OmmlConverter.ets / TableHtmlParser.ets / XmlUtil.ets
│   └── ZipWriter.ts                # STORE 方式 zip 写入器（.ts：供 TS 模块打包工作区复用）
├── data/
│   └── StorageManager.ts
├── model/
│   ├── Message.ts / Conversation.ts / Attachment.ts / ToolCallRecord.ts
│   └── Agent.ts / ApiConfig.ts / ApiProfile.ts / MultimodalConfig.ts
└── common/
    ├── Constants.ts / Types.ts / Utils.ts / MarkdownSanitizer.ts
    ├── GuncatUiLang.ts              # 交互模式语言核心：guncat-ui lang 词法/语法/求值/围栏切分
    ├── GuncatUiLibrary.ts           # 交互模式组件库单一事实源（签名/描述/位置参数表 → 提示词）
    ├── GuncatUiPrompt.ts            # 交互模式系统提示词（语法/组件选择优先级与丰富度/交互/流式顺序/示例/反例/模式职责）
    ├── GuncatUiRuntime.ts           # 交互模式运行时：$绑定状态 / Action 执行 / 状态尾标记与回传文案
    ├── GuncatUiPaint.ts             # 交互模式图表几何与数值格式化（纯逻辑，可单测）
    └── GuncatUiParts.ts             # 消息体切分：Markdown 文本片段 + guncat-ui 界面程序片段

entry/src/main/resources/rawfile/
├── agents.json + *_prompt*.md      # 聊天智能体定义与提示词
└── skills/                         # 工作模式技能（5 主 Skill + 7 格式分支顶层直连，25 分支位于主 Skill 子目录；见「3.3 技能系统」）
    ├── ppt/
    │   ├── SKILL.md                # PPT 技能正文（工作流/速查/自检清单）
    │   └── reference/              # deck-dsl.md / design-guide.md / themes.md / troubleshooting.md / deck-blueprints.md / visual-components.md / style-guidelines.md
    ├── docx/
    │   ├── SKILL.md                # Word 技能正文（新建/编辑工作流/块速查/排版规则/自检清单）
    │   └── reference/              # doc-dsl.md / design-guide.md / troubleshooting.md / document-blueprints.md / professional-docs.md / chatgpt-design-presets.md
    ├── xlsx/
    │   ├── SKILL.md                # Excel 技能正文（新建/编辑工作流/公式优先/速查/自检清单）
    │   └── reference/              # workbook-dsl.md / format-guide.md / troubleshooting.md / report-blueprints.md / analysis-playbook.md
    ├── data/
    │   ├── SKILL.md                # 数据管道技能（transform_file ops/表达式语法/数据质量/清洗提取互转配方）
    │   └── reference/              # data-pipeline.md / data-quality.md / recipes.md
    ├── svg/
    │   ├── SKILL.md                # SVG 生图技能（生成→预览→修正工作流/自检清单）
    │   └── reference/              # svg-craft.md / svg-recipes.md / infographic-blueprints.md
    ├── research-intelligence/ academic-publishing/ content-writing/ legal-ip/ ai-tooling/   # 5 个主 Skill 路由入口（各含 SKILL.md + ROUTING.md + 分支子目录）
    └── …/                          # 另含 html/pdf 格式分支与 5 主 Skill 下 25 个分支，注册表共 37 项 = 32 原始 + 5 主路由

test/
├── pptx-harness/                   # PPT/CSV/Word/Excel 服务层离线验证（Node 构建 + python 校验 + tsc 类型检查）
├── docx-harness/                   # Word 生成器/导入器离线验证（Node 构建 + python-docx 校验）
└── xlsx-harness/                   # Excel 生成器/导入器离线验证（Node 构建 + openpyxl 校验）
```

项目采用类似 MVVM 的分层方式：

- View：ArkUI 页面与组件。
- ViewModel：集中管理聊天、附件、配置、工作模式循环和持久化状态。
- Service：负责 SSE、Agent Loop、工具执行、本地文档解析、系统分享、TTS 和 ASR 等能力。
- Model：消息、对话、附件、工具调用记录、智能体及 API 配置模型。

> **扩展名即依赖规则**：ArkTS 禁止 `.ts` 文件导入 `.ets` 文件（`.ets` 可以导入 `.ts`）。新建/移动文件时先看依赖方向再定扩展名——需要被 `ChatViewModel.ets` / `WorkToolRunner.ets` 等 `.ets` 模块引用的能力（如 Office 生成、多模态）必须放在 `.ets`；纯逻辑工具（如 ZipWriter、PDF/Office 解析）放 `.ts` 即可被两侧复用。

## 数据流

```text
【聊天模式】
ChatService (SSE)
  → ChatViewModel
  → @Observed Message
  → @ObjectLink ChatBubbleView
  → RichTextView

【工作模式】每轮循环
用户任务 → ChatViewModel.executeWorkLoop
  → AgentLoopService.runTurn（三协议 SSE + 流式工具调用累积）
  → WorkToolRunner.execute → WorkFileService.executeTool
      → OfficeReader / PdfTextExtractor（读取）
      → DocxExporter / XlsxExporter（生成）
      → PptxBuilder / PptxImporter / PptxImage / DeckOps（PPT 写/读/编辑, 见「3.1」）
      → WorkSkillService（list_skills / load_skill, 见「3.3」）
  → 工具结果回填 ToolCallRecord → 注入下一轮请求历史
  → 每轮一条 @Observed Message（思考/工具/文本）
  → ChatPage.buildWorkTimeline → WorkTurnView
```

## 核心组件

1. **ChatViewModel**
   
   - 管理对话列表、智能体选择、API 配置和输入状态。
   - 处理消息发送、流式响应、附件解析与重新生成。
   - 负责持久化存储和状态恢复。
   - 工作模式：`executeWorkLoop` 驱动 Agent 循环（每轮一条消息、工具执行、图片注入、上下文自动压缩；循环主体默认由 `WorkLoopDriver` 驱动，见「2.1」）。

2. **ChatService**
   
   - 实现 SSE 流式通信和请求中断。
   - 支持 Chat Completions 与 Responses API。
   - 解析增量回答并处理网络及服务端错误。

3. **AgentLoopService / WorkToolRunner / WorkFileService（工作模式三件套）**
   
   - `AgentLoopService`：单轮 LLM 请求——三协议请求体构建（含工具定义、图片消息）、流式工具调用累积、工作模式系统提示词。
   - `WorkToolRunner`：工具统一分发入口，实现需要 `.ets` 模块的能力（write_docx/xlsx/pptx、parse_document）。
   - `WorkFileService`：沙箱工作区全部文件操作、文件类工具实现、工具 Schema（`toolDefs()`）、工作区打包导出。

4. **MultimodalService**
   
   - 处理图片、文本、PDF 和 Office 文档。
   - 支持预解析、重试与并发控制。
   - 支持 Responses API 图片和文件直传。

5. **OfficeReader / PdfTextExtractor / Flate（本地解析引擎）**
   
   - `OfficeReader`：解包 OOXML 并按标签边界抽取 `w:t`/`a:t`/`sharedStrings` 文本。
   - `PdfTextExtractor`：字节层对象表 + ObjStm 展开 + 页面树资源继承 + ToUnicode CMap + 内容流文本。
   - `Flate`：纯 TS 的 DEFLATE/zlib 解压（SDK zlib 只有文件级 API，无法按缓冲区解压）。

6. **StorageManager**
   
   - 封装本地持久化：对话历史存沙箱文件（`filesDir/guncat_conversations.json`），配置/开关/朗读偏好存 Preferences。
   - 管理对话、配置、开关和朗读偏好。

7. **TextReaderService / BackgroundReaderService**
   
   - 查询和管理 CoreSpeechKit 音色。
   - 管理朗读、暂停、进度跳转与语速。
   - 通过 AVSession 和长时任务维持后台音频会话。
