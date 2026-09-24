---
name: pdf
description: 处理 PDF 的读取/搜索/扫描件阅读时加载：parse_document 按页解析文字层、search_pdf 定位关键词、pdf_to_images + view_image 读扫描件/版式，长 PDF 分块与目标定位策略。当前环境不支持创建/编辑/合并/拆分/旋转/水印/加密/表单填写/OCR 文字层生成。触发词：读 PDF、解析 PDF、PDF 里找 XX、扫描件 PDF、提取 PDF 文字。
---

# PDF 文档读取与扫描件阅读（本项目适配版）

本技能负责 PDF 的**读取、搜索、扫描件/版式阅读与内容提取**，不负责对 PDF 文件本身做结构化编辑。

## 支持的能力

| 需求 | 使用方式 |
|---|---|
| 读取文字型 PDF | `parse_document(path, page?, page_count?)`，按页分批返回；提示"未读完"时按页码续读 |
| 在 PDF 中定位关键词 | `search_pdf(path, query)`，返回页码 + 上下文，最多 50 处 |
| 阅读扫描件/纯图片 PDF | `pdf_to_images(path, page?, page_count?)` 渲染成 `pdf_images/<文件名>/p001.jpg`，再用 `view_image` 逐张看 |
| 提取表格/图表数据 | 文字型先 `parse_document`；表格乱序/图表用 `view_image` 看版面；提取结果写入 `write_xlsx` |
| 长 PDF 阅读 | 先目录/搜索定位再精读，或按"未读完"提示分批读完；摘要保留页码出处 |

## 不触发本技能

- 用户只是要写 Word/PPT/Excel 内容，PDF 只是输入素材 → 用对应 Office 技能；
- 用户要**创建、编辑、合并、拆分、旋转、裁剪、加水印、加密/解密、填表、生成可搜索 PDF/OCR 文字层** → 本环境不支持，直接如实说明，不假装完成；
- 文件未提供、不可访问或未授权 → 不处理。

## 工作流（本项目）

1. **判断类型**：`list_files` 确认文件；`parse_document` 读前 1-2 页——能读到文字为文字型；空/乱码/提示扫描件则 `pdf_to_images` + `view_image`。
2. **阅读与摘要**：短 PDF（≤30 页）一次读完，按"未读完"提示续读；长 PDF 先目录/搜索定位再精读；摘要保留页码出处。
3. **搜索定位**：`search_pdf(path, query)` 定位关键词 → `parse_document(page=N)` 精读；搜索不到但像扫描件则转图目视。
4. **扫描件/纯图片**：`pdf_to_images(page=1, page_count=10)` 分块（默认 10、最大 50），`view_image` 逐张看；不承诺 OCR 文字层。
5. **表格/图表**：文字型先 `parse_document`；表格乱序/图表数据用 `view_image` 读版面；提取表格写入 `write_xlsx`。
6. **交付**：摘要对话给并附页码；长报告 `write_file`/`write_docx`；表格 `write_xlsx`；研究核验配合 `research`/`sift`。

## 能力边界（照实说）

当前环境**不支持**：
- 创建/生成 PDF；
- 编辑/合并/拆分/旋转/裁剪 PDF；
- 加水印、加密/解密、表单填写；
- 生成可搜索文字层/OCR 文本层。

替代路径：
- 要 PDF 交付 → 生成对应 Office 文件（`write_docx`/`write_pptx`/`write_xlsx`）由用户/系统导出；
- 要编辑 PDF → 请用户提供可编辑源文件或使用专门 PDF 工具；
- 要 OCR → 当前可转图后由模型视觉阅读，但不会产出可搜索 PDF。

## 自检

- [ ] 文件路径真实存在；
- [ ] 文字型 PDF 已按页读完，没有漏掉"未读完"提示；
- [ ] 扫描件已转图并逐页查看；
- [ ] 关键数据/结论有页码来源；
- [ ] 能力边界如实说明，未假装生成/编辑 PDF。

## 参考文件

- `reference/tool-notes.md`：工具映射与工作流（本项目）
- `reference/troubleshooting.md`：常见问题排查（已适配本项目）
- `reference/extraction-guide.md`：多栏/表格/边界提取细节（已适配本项目）
