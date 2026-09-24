Do not default to style-name matching. Target files often use style names that do not match the template.

## Command（本项目执行说明）

原实现通过 `python3 scripts/format_docx.py` 及一批 `--参数` 直接编辑 OpenXML。本环境无 Python/终端，`scripts/*.py`、`render_docx.py`、LibreOffice/soffice 均不可用，**请勿尝试运行任何脚本**。执行层改为：

1. 先用 `load_skill("docx")` 读取本项目 `docx` 技能的 Doc JSON 语法、排版规范与专业文书规范。
2. 用 `read_docx` 读取目标 `.docx`（含模板与待排版稿），用 `docx` 技能的模型/编辑指令定位并修改样式、页边距、标题层级、段落/字体/行距、表格三线、公式制表位、引用编号、上下标、页眉页脚等。
3. 模板/证据提取：`.docx`/`.dotx` 用 `read_docx` 读取结构；PDF/截图用 `pdf_to_images`/`view_image` 或 `search_pdf` 提取文字规则；网页规则用 `web_fetch`；OCR 文字规则直接采用。
4. 规则优先级与边界、角色路由、直排格式清理、编号/上下标/表格/公式/页面设置/分栏等判定规则，全部以本技能各 references（style-routing / references-numbering-superscript / equations-tables-sections / preservation-rules / template-distill-render-qa / explicit-postprocess）为准，作为人工执行的检查清单。
5. 交付用 `write_docx`（或 `edit_docx` 修改后保存）；无渲染比对/Word/预览 QA，改为「在 Word 中打开人工核对 + 本项目自检清单」。

> 说明：下文保留的 `--参数`/`scripts/*.py` 字样来自原规范原文，仅作规则上下文参考，不可执行；实际请按上述 docx 技能手工实现对应能力。

## Version

- Version: 1.10.41
- Revision: skill5.144 website guide text rules and OOXML spacing normalization
- Date: 2026-07-21
- Compatibility: OOXML Word 2007+（本项目以 `docx` 技能实现）
