# Doc JSON 完整语法（write_docx 的 doc / doc_file 参数）

Doc JSON 是 Word 文档的结构化中间层：AI 写 JSON → 渲染为 .docx；文件内嵌源，
`read_docx`/`edit_docx` 可无损往返。顶层为对象：

```json
{
  "title": "文档标题",          // 建议填写（留空用默认名）
  "subtitle": "副标题",          // 可选，封面副标题
  "author": "经营分析组",        // 可选，封面作者/单位
  "date": "2026-08-07",          // 可选，封面日期；留空渲染时取当天
  "style": "default",            // 可选：default / academic / minimal
  "cover": true,                 // 可选：true 生成封面页（大标题居中 + 副标题 + 作者/日期）
  "toc": true,                   // 可选：true 生成目录页（Word 域，打开后右键"更新域"生成）
  "blocks": [ /* 内容块，必填，至少 1 个，最多 400 个 */ ]
}
```

## 内容块（blocks 数组元素）

### heading 标题
```json
{"type":"heading","level":1,"text":"一、总体经营情况"}
```
- `level`：1~6 必填。渲染为 Word 内置 Heading1~6 样式：黑体加粗，H1 22pt → H6 12pt 递减，颜色随样式预设。
- 层级要连续：H1 下接 H2，不要 H1 直接跳 H4。

### paragraph 正文
```json
{"type":"paragraph","text":"上半年营收 **1.2 亿元**，同比 *+18%*。"}
```
- 12pt 宋体、1.5 倍行距、首行缩进 2 字符。
- `text` 支持行内格式（见下方）。

### list 列表
```json
{"type":"list","ordered":false,"items":[
  {"text":"一级要点","level":0},
  {"text":"二级要点","level":1}
]}
```
- `ordered`：true=有序（1. 2. 3.）/ false=无序（•）。
- `items`：字符串或 `{"text","level"}`；`level` 0/1（两级缩进，最多 200 条）。
- 有序/无序在一个块内统一；混排拆成两个 list 块。

### table 表格
```json
{"type":"table","caption":"表 1 核心指标（来源：财务中台）",
 "headers":["指标","数值","同比"],
 "rows":[["营收","1.2 亿","+18%"],["利润","3,200 万","+12%"]]}
```
- `headers`：表头行，必填，≤20 列（自动加主题色浅底 + 加粗）。
- `rows`：数据行，每行数组长度 ≤ 表头列数，≤500 行。
- `caption` 可选，居中题注（10.5pt 灰字）。

### image 图片
```json
{"type":"image","src":"photos/trend.png","caption":"图 1 月度营收趋势","width":0.8}
```
- `src`：必填。三种来源，**禁止编造路径**：
  - 工作区相对路径：`assets/logo.png`（list_files 确认存在）
  - data URL：`data:image/png;base64,…`
  - http(s) 链接：`https://…`（导出时自动下载）
  - `.svg` 文件可直接引用，导出时自动栅格化为 PNG。
- `width`：0~1，占页面内容宽（约 15.7cm）的比例；0 或省略=按原图尺寸自适应（超页宽自动缩回）。
- `caption` 可选，居中题注。

### quote 引用
```json
{"type":"quote","text":"增长的本质是复利，而复利来自纪律。"}
```
- 左侧竖线 + 灰字样式；多行用 `\n` 分隔。

### code 代码块
```json
{"type":"code","language":"typescript","text":"const a = 1;"}
```
- 等宽字体（Consolas）+ 浅灰底；`language` 仅作标注（docx 不做语法高亮）。

### divider / pagebreak
```json
{"type":"divider"}
{"type":"pagebreak"}
```
- `divider`：细分隔线；`pagebreak`：强制分页。

## 行内格式（heading/paragraph/quote/表格单元格文本里直接用 Markdown 语法）

| 语法 | 效果 |
|---|---|
| `**粗体**` | 加粗 |
| `*斜体*` | 斜体 |
| `` `代码` `` | 行内代码（Consolas 红字浅底） |
| `[说明](https://example.com)` | 超链接 |
| `![说明](assets/icon.png)` | 行内图片（按需嵌入，最大宽 ≈5.8 英寸） |
| `$E=mc^2$` | 行内公式（渲染为 OMML） |
| `$$\\sum_{i=1}^n i$$` | 显示公式（独立成行） |
| `~~删除线~~` | 删除线 |
| `\\n` | 段落内换行 |

## 模板/仿制/占位符填充

先区分两类：**可编辑 DOCX 模板/底稿**（要继承原文件继续填）和**格式参考/仿制**（只能看样式后重建）。

- **可编辑 DOCX 模板/底稿（优先原位填充）**：
  1. `read_docx` 读模板，区分固定内容、示例内容、占位内容和真实已有内容；
  2. 用 `edit_docx` 原位编辑：`replace_text` 替换 `{{字段}}`/`【待填】`/`TODO`，`update_block`/`add_block`/`delete_block`/`move_block` 调整内容块；
  3. 未计划修改的页面设置、样式、编号、表格、图片等保持不动；不要因为“重建更可控”就丢掉模板版式。
- **格式参考/仿制（才重建）**：用户给的是 PDF、图片、不可编辑附件，或明确说“照这个样式/结构做”而非在原文件上填写时，`read_docx` 提取结构与风格，再用 Doc JSON 重建；重建版式不必逐像素还原，保留结构与风格即可。
- **Markdown → 正式 Word 快速路径**：`write_docx(path, markdown, title?, style?)` 直接接受 Markdown 文本——适合从草稿/笔记升级为正式文档；需要精细排版（封面/目录/表格/图片）时改用 `doc`/`doc_file`。
- **不要承诺邮件合并/域填充**：模板变量填充是"文本替换"，不是 Word 的 Mail Merge；需要批量生成的场景，用 `edit_docx` 的 `add_block`/`update_block` 或循环重建。

## 样式预设

| style | 标题色 | 表头底 | 适用 |
|---|---|---|---|
| `default` | 深蓝 #1F4E79 | 浅蓝 #DEEAF6 | 商务报告/方案/纪要（默认） |
| `academic` | 黑 #262626 | 浅灰 #F2F2F2 | 论文/学术/讲义 |
| `minimal` | 深灰 #595959 | 浅灰 #F5F5F5 | 内部备忘/周报 |

## edit_docx 操作（ops 数组）

| op | 参数 | 说明 |
|---|---|---|
| set_title | title | 改文档标题 |
| set_subtitle / set_author | subtitle / author | 改封面信息 |
| set_style | style | 换样式预设（default/academic/minimal） |
| set_cover / set_toc | cover / toc（bool） | 开/关封面页、目录页 |
| add_block | index?（1 起，默认末尾）, block | 插入内容块（block 语法同上方） |
| delete_block | index | 删除第 index 块 |
| update_block | index, block（部分字段） | 改第 index 块（text/level/ordered/caption/src/width/items/headers/rows 均可） |
| move_block | from, to | 移动第 from 块到第 to 位 |
| replace_text | find, replace | 全文替换（跳过代码块，避免破坏语法） |

例：
```json
[{"op":"update_block","index":3,"block":{"text":"1.2 亿元（同比 +18%）"}},
 {"op":"replace_text","find":"客户","replace":"用户"},
 {"op":"set_style","style":"academic"}]
```
index 以 `read_docx` 返回的 Doc 源中 blocks 数组顺序为准（1 起）。
