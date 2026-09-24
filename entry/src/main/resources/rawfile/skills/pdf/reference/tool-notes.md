# PDF 技能 · 本项目工具映射（适配层）

> 本文件是 `pdf/SKILL.md` 的项目内工作流与工具映射。原参考技能中不可在本环境使用的脚本/库/生成编辑类操作已按用户要求移除，仅保留读取/搜索/扫描件阅读能力。

## 可用工具

| 工具 | 用途 |
| --- | --- |
| `parse_document(path, page?, page_count?)` | 解析 PDF 文字层，按页分批返回；超长会提示"未读完"和续读页码 |
| `search_pdf(path, query)` | 在 PDF 文字层搜索关键词（大小写不敏感），返回页码+上下文，最多 50 处 |
| `pdf_to_images(path, page?, page_count?)` | 把 PDF 页渲染成 `pdf_images/<文件名>/p001.jpg`，用于扫描件/版式阅读 |
| `view_image(path)` | 多模态查看渲染出的图片 |

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
