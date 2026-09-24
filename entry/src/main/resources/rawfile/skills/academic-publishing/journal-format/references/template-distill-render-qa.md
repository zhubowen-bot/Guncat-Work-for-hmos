# Template Evidence And Render QA

Read this when extracting a template into `style_spec.json`, writing audit artifacts, running visual QA, or diagnosing why the final Word display does not match the template.

## Evidence Contract

Before applying styles to the target, treat the template as an evidence source and distill it into an evidence contract. The contract can be written as `template_evidence.json` or folded into `style_spec.json` plus `qa_report.json`, but it must answer these questions:

- Template identity: absolute path, original extension, SHA-256 when practical, page count if rendered, section count, and whether the source was native `.docx` or converted from `.doc`/`.dot`.
- Page system: page size, orientation, margins, columns, gutter, header/footer distances, first/odd/even behavior, and every `sectPr` location.
- Role typography: title, author, affiliation, abstract, keywords, heading levels, body, captions, references, metadata, citation format, and equation roles with concrete font slots, size, bold/italic, color, underline, language, spacing, indents, tabs, borders, shading, keep/page-break controls, and raw `style_xml/pPr_xml/rPr_xml`.
- Direct-format evidence: representative paragraph/run properties only for native DOCX/DOTX templates. Converted legacy Word files are text-extraction carriers and must not donate direct formatting to role styles.
- Numbering evidence: style `numPr`, reference-list visible prefix pattern, automatic numbering definitions, abstractNum/num IDs, hanging indentation, and continuation-line behavior.
- Table evidence: `tblPr`, `tblGrid`, row properties, `tcPr`, top/header/bottom/inside/vertical border model, cell margins, table width, and representative table strength.
- Equation evidence: equation paragraph style, formula object kind, tabs before equation, tabs between equation and number, computed fallback tab stops, and whether tabs were template-derived or fallback-derived.
- Object preservation evidence: media, embeddings/OLE, charts, diagrams, headers, footers, comments, footnotes/endnotes, fields, hyperlinks, relationships, and custom XML part counts.

Unresolved values must be recorded as unresolved or filled only by granular fallback. Do not invent a style value merely because a paper template usually has it.

## Unified Evidence Fusion Route

Every usable format source must be normalized into the same role-based evidence contract before target formatting. The target-formatting stage consumes `style_spec.json` and `role_map.json`; it must not care whether the source began as `.docx`, `.dotx`, `.doc`, `.dot`, PDF, image, website, or text instructions.

Use this source-aware extraction route:

1. Identify the original source type and record it in `qa_report.format_source` and, when a style spec is written, `style_spec._meta`.
2. For native `.docx`/`.dotx`, extract OpenXML style, numbering, section, table, equation, header/footer, relationship, representative paragraph, and prose-rule evidence directly.
3. For legacy `.doc`/`.dot`, convert to temporary `.docx` with Microsoft Word when available or Word/预览 otherwise only so text and reliable column-count metadata can be extracted. Do not use converted OpenXML styles, converted direct formatting, support files, headers/footers, or page XML as formatting authority. Do inspect converted `sectPr/w:cols` only to choose fallback column count, and record the detection source. If converted `sectPr` detection fails, use source filename keywords such as `双栏`, `单栏`, `two-column`, or `single-column` as lower-priority fallback hints before defaulting to single-column.
4. For PDF/image/website sources, extract text rules before OCR/visual checks, then write rules JSON. Text-format guides define primary rules. Explicit source prose may also define supported content/structure operations through `postprocess_operations`, such as tables/figures after references, body citation marker conversion, reference-prefix conversion, or caption-prefix normalization. Visual/geometry evidence may select only the fallback variant column count (`fallback_columns=1` or `2`); it must not identify role alignment, style properties, or postprocess operations. Website links are the exception for column fallback: if website text/user rules do not explicitly state single-column or double-column manuscript layout, record single-column fallback instead of inferring from website visuals or publisher production examples.
5. Merge evidence at property level, not whole-role level. For example, if text says `正文五号宋体` but not line spacing, keep the text-rule font/size and fill line spacing from fallback; do not replace the entire body style with fallback and do not use non-DOCX visual/converted direct formatting.

Do not phrase the evidence result as "website/PDF text rules are weak and fallback was used" when explicit text rules were extracted. Say instead that the source container was non-DOCX, explicit text rules were applied first, and fallback completed only missing properties.

Legacy `.doc`/`.dot` warning pattern: if conversion yields a `.docx`, do not conclude that converted styles or direct formatting are trustworthy. Use converted text rules first, optional column-count detection second, then granular fallback. The target-formatting stage must still consume only `style_spec.json` and `role_map.json`; it must not branch into a `.doc`-specific formatter. Converted shell styles are carriers, not authority.

## PDF Text Rules And Column Fallback

PDF sources are not Word templates. They do not expose reliable `styles.xml`, `numbering.xml`, section XML, paragraph style IDs, header/footer relationships, object anchors, or Word table/equation XML. Treat every PDF as text-rule evidence plus optional single/double-column fallback selection.

If the PDF text contains author instructions, submission guidelines, `投稿须知`, `来稿要求`, `作者指南`, `撰稿要求`, `格式要求`, `论文格式`, `参考文献格式`, or similar prose rules, treat the extracted text rules as the primary evidence. Do not infer the required manuscript style from the PDF guide page's own font/size/layout. A submission-guideline PDF may be typeset in a different style from the paper it describes.

Examples of text-guide rules that should win over visual inference:

| Extracted PDF text | Evidence to record |
|---|---|
| `表采用三线表的格式` | table border model is three-line; do not infer table borders from the instruction page itself. |
| `公式在文章中以阿拉伯数字连续编号，用（）括起置于公式右边` | equation numbering uses parenthesized Arabic numbers on the right; tab stops may still need fallback calculation. |
| `正文中引用参考文献时文献号须加[ ]用上标表示` | body reference citations should use bracketed superscript markers when applying a compatible superscript map/rule. |
| `参考文献格式 ... [期刊] 作者 年份 刊名 卷号 起始页码` | reference item pattern/order comes from the prose/example, not from the PDF paragraph's visual font. |

原 PDF 提取脚本（本项目用 search_pdf/pdf_to_images） must write `pdf_rules.json` with `_meta.source_type="text_rules"`, `_meta.non_docx_standard_fallback=true`, optional `_meta.fallback_columns`/`source_column_detection`, and optional text-derived `postprocess_operations`. Use that file as `--rules-json` and pass `--format-source-type text_rules` or rely on the metadata. Text rules remain locked and have higher priority than fallback for stated properties; missing properties come from the selected fallback. Text-derived postprocess operations auto-run after the first valid repack. If no explicit PDF text rule is found, continue with the selected fallback and warn the user.

Non-DOCX visual whitelist:

- Allow: reliable single-column or double-column detection for fallback variant selection.
- Do not allow: paragraph role identity, role alignment,字号/point size, exact Chinese font, exact Latin font, bold/italic, color, underline, small caps, indentation, local italic/bold spans, exact line spacing, character spacing, exact tab stops, or run-level style details.
- Treat visual font size and coordinates only as internal extraction diagnostics; do not write them to `pdf_rules.json` or `style_spec.json`.

For PDF visual, PDF hybrid, image/OCR/website, text-rule, blank-template, and converted legacy Word sources, do not use an old Word "blank template" or converted shell style as formatting authority. Treat any blank/converted carrier document as a low-confidence container. Generated role styles must come from the evidence contract plus granular fallback, with no inherited Heading/Reference colors, paragraph borders, underlines, small caps, theme colors, or stale Word defaults unless the source/user/text rule explicitly requires them.

Blank/carrier template QA is mandatory when the format source is weak and the DOCX package is only a carrier:

- Select fallback language from explicit rules first, then from the target document text. Do not infer Chinese/English from an empty carrier package.
- Rebuild low-confidence `style_spec.json` role styles before installation if old `style_xml` contains carrier defaults.
- Write the selected body fallback baseline into target `docDefaults` and `Normal`.
- Audit role styles before delivery: Chinese blank-carrier fallback should show body `line="360"` and five-point size, title/heading fallback spacing such as `before="240" after="120" line="360"` where defined, and no remaining carrier `Normal` single spacing `line="240"` in the generated title/heading/body role styles.
- If any of these deterministic checks fail, repair and rerun the audit instead of sending the issue only as a user warning.

This column-only visual rule is universal for non-DOCX visual sources. It applies to PDF, screenshots, images, OCR output, rendered DOC/DOT previews, and externally supplied visual rules JSON. Before `style_spec.json` is built, strip visual-only role/alignment/字号/font/bold/italic/color/underline/indentation/spacing/tabs/run-level fields. Retain only explicit prose/user text rules and optional fallback column metadata.

Website links have a stricter column rule than other visual sources. Do not use website captures, publisher article pages, journal brand reputation, Nature/Science-like production layouts, or visual website examples to infer double-column submission format. Only explicit website/user text such as `双栏`, `two-column`, `single-column`, or equivalent manuscript-layout wording may set `fallback_columns=2` or `fallback_columns=1`. If no such text is found, write `fallback_columns=1` and record `website_unspecified_columns_default_single`.

## PDF Geometry Evidence

Use PDF geometry evidence for sample articles, sample issues, publisher proofs, or PDFs that lack explicit text formatting instructions only to select single-column or double-column fallback. Recommend either a native `.docx` template/source-format file or explicit text formatting instructions in final notes.

Visual sample PDFs need role-source filtering before any rule is emitted:

- Ignore decorative or repeated watermark lines such as `样例`, `示例`, `样张`, `Sample`, `Draft`, and `Proof`, especially when they are huge, centered, or repeated across pages. They must never become `title`, `heading`, `body`, or caption style evidence.
- Do not let the largest font on the page define the title by itself. Use page position, text length, nearby title continuation lines, and front-matter state.
- Use a front-matter state machine on page 1: title may span multiple early large lines; the next short name-like line is `author`; institution/address lines are `affiliation`; communication author, funding, DOI, or dates are `metadata`; once abstract/keywords/body begins, later body lines must not be reclassified as author or affiliation merely because they contain institution words.
- Do not promote PDF visual bold/italic/color/font/size/alignment into role styles.

---

> 因文档体量拆分：后续内容见 `template-distill-render-qa-2.md`。
