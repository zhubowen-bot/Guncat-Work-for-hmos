- For sample/proof PDFs, keep `source_type=text_rules` for `rules_json`; store visual diagnostics only in `pdf_evidence.json`.

When a PDF format source is present and no stronger `.docx`/explicit user rule covers the same properties, run:

```bash
（原脚本命令，本项目改用 search_pdf/pdf_to_images） source.pdf \
  --out-json pdf_evidence.json \
  --rules-json pdf_rules.json
```

Use the common PDF toolchain in this order, combining all available evidence rather than relying on one parser:

1. **本项目 PDF 提取（search_pdf / pdf_to_images / view_image）**: primary source for selectable-text PDFs. Extract text for explicit prose rules and line coordinates for column detection only.
2. **原 pdftotext 工具（本项目不可用）**: cross-check reading order, columns, line breaks, and selectable-text availability. Use layout text to catch extraction-order problems from PyMuPDF.
3. **原 pdffonts（本项目不可用）**: audit embedded/subset font inventory and font substitution risk. Treat subset names such as `ABCDEE+TimesNewRoman` as evidence for the normalized font family, not a literal Word font name.
4. **原 pdfplumber 库（本项目不可用）**: supplement text extraction, table/line diagnostics, and column detection when available.
5. **原 mutool/Poppler 工具（本项目不可用）**: supplement PDF metadata, page/object structure, and extraction diagnostics when available.
6. **OCR / screenshot inspection**: last resort for scanned or image-only PDFs. OCR can recover text rules but cannot reliably recover exact fonts, sizes, paragraph styles, numbering definitions, or table XML. Mark these properties unresolved unless visually obvious.

`pdf_rules.json` should not use `_meta.source_type="pdf_visual_inference"` or `pdf_text_visual_hybrid` for this skill route. If an external tool emits those old source types, sanitize them to `text_rules`, keep explicit text rules only, and move column evidence into `_meta.fallback_columns`.

PDF geometry inference may reasonably infer:

- page/column geometry for fallback selection and layout QA only, not paragraph style typography.

PDF column detection must be conservative. Do not infer double-column layout from multiple left-edge clusters alone: single-column academic PDFs commonly contain first-line indents, hanging references, centered titles/captions/equations, and short formula/title rows that create extra x-coordinate clusters. A double-column vote needs all of these:

- balanced left and right body-like text bands, not just two left-edge clusters;
- a clear blank gutter between the median right edge of the left band and the median left edge of the right band;
- enough right-band body lines with meaningful text width;
- few body lines crossing the inferred column boundary;
- agreement across more than one page, or an explicit user/source instruction.

Sample-issue PDFs can have very few body-like lines per page because page 1 contains front matter and later pages contain formulas, tables, figures, captions, and short equation rows. Do not let page-vote majority alone force single-column in that case. If page-level votes are weak, run a cross-page aggregate geometry check:

- collect looser non-decorative text lines across inspected pages only for column-start evidence;
- require stable left and right x-start clusters that recur across multiple pages;
- require pages where both clusters appear, a real gutter between the left-column median right edge and right-column median start, and low full-width crossing-line ratio;
- record this as `aggregate_vote` in `source_column_detection`;
- use it only to choose `fallback_columns`, never to define fonts, sizes, alignment, spacing, indentation, colors, role styles, or content/structure postprocess operations.

If both page-level body-band evidence and cross-page aggregate evidence are weak, default `_meta.fallback_columns` to `1`, set low confidence, and tell the user that `--body-cols 2` or explicit text instructions can override the PDF guess when the intended layout is double-column.

PDF must not be treated as authoritative for:

- Word style IDs, based-on/next style relationships, `pPr/rPr` inheritance, `docDefaults`, numbering IDs, section breaks, header/footer rels, object anchors, OMML/OLE equation internals, field codes, or exact tab stops;
- exact table XML such as `tblGrid`, `gridSpan`, vertical merges, cell margins, and border conflict resolution;
- exact line spacing when text is scanned, subset fonts are missing, or extraction order is inconsistent;
- exact font family, color, underline, italic, small caps, character spacing, and run-level formatting unless stated in explicit text rules.
- visual字号/point size, visual bold/italic, visual alignment, visual indentation, and visual reference hanging indent.

If `extract_pdf_format.py` extracts zero text rules, do not stop by default. Use OCR when practical; otherwise apply the selected standard fallback and warn that the source was not DOCX and no explicit PDF text rules were found.

PDF conformance QA must compare the final installed role styles against explicit PDF text rules plus fallback variant expectations. Do not audit or repair final alignment/字号/bold/indentation/spacing against PDF visual evidence.

## QA Audit Route

Run structural QA before and after formatting whenever practical:

```bash
（原脚本命令，本项目改为人工自检） template.docx --out-json template_qa.json
（原脚本命令，本项目改为人工自检） target.docx --out-json target_before_qa.json
（原脚本命令，本项目改为人工自检） output.docx --out-json output_qa.json
```

The formatter can do this during a normal run:

```bash
（原脚本命令，本项目改用 docx 技能） \
  -t template.docx -i target.docx -o output.docx \
  --qa-report-out qa_report.json
```

Use the QA report to compare:

- section count, page size, margins, and columns;
- direct run/paragraph formatting before and after cleanup;
- key parts such as `styles.xml`, `numbering.xml`, settings, font table, and theme;
- media, embeddings, charts, diagrams, headers, footers, rels, and customXml counts;
- remaining direct formatting examples that can still override role styles.
- table geometry: `tblW`, `tblInd`, `tblGrid`, row/cell `tcW`, explicit table/cell borders, header-row evidence, cell margins, and whether auto-width tables may render differently.
- image placement: `wp:inline` versus `wp:anchor`, drawing sizes, relationship targets, and missing image targets.
- high-inline-content line spacing: any paragraph containing `w:drawing`, `w:pict`, `w:object`/OLE/MathType, or OMML with effective `w:lineRule="exact"` is a high-risk clipping case. Final QA must flag it as `fixed_line_spacing_high_inline_content`; the formatter should repair it by applying a direct paragraph `w:spacing w:lineRule="auto"` before delivery, then rerun QA.
- header/footer watermark residue: `word/header*.xml` and `word/footer*.xml` containing `wp:anchor behindDoc="1"` or large anchored drawings can render as proof/sample watermarks. These should be removed when they are image-only background paragraphs, and flagged if still present after cleanup.
- Word fields: `PAGE`, `NUMPAGES`, `TOC`, `REF`, `PAGEREF`, `SEQ`, and other fields that may display stale values until Word updates fields.
- heading hierarchy: generated role heading styles, numbered heading-like paragraphs, level jumps, and numbered non-heading paragraphs that may break TOC behavior.

If object counts drop unexpectedly, or if media/drawing/embedding/table/field counts shrink after formatting, stop and repair before delivery.

Run format-conformance QA immediately after role-style binding and direct-format cleanup, before bibliography numbering, table body formatting, equation tab layout, and superscript markers. This QA is a repair gate: verify generated role styles still match `style_spec.json`, verify every mapped target paragraph uses the expected role style, remove direct formatting that would override role font/size/spacing/indent/alignment, and re-audit. Record repair counts in `format_conformance_qa`; final notes should mention only unresolved or uncertainty-based failures, not deterministic repairs that succeeded.

For final user notes, convert QA findings into concise confirmation items only. Do not list successful formatting. Mention tables, images/floating anchors, high-inline-content spacing repairs or unresolved clipping risk, header/footer watermark cleanup or residue, fields/page numbers/TOC, heading hierarchy, object-count drops, and residual direct formatting only when the internal QA report actually flags them.

## Word/预览 Compatibility Gate

Run this gate after final DOCX repack and structural QA, before user delivery. This gate improves Word/预览 openability without weakening Word/OpenXML fidelity:

```bash
Word/预览 --headless --invisible --norestore --convert-to pdf --outdir lo_compat final.docx
```

Rules:

- Use Word/预览 only to load the final DOCX and export a temporary PDF. This proves that Word/预览 can open the package well enough to render/export.
- Do not save, normalize, repair, or replace the final DOCX through Word/预览. A Word/预览-resaved DOCX may rewrite OMML formulas, MathType/OLE objects, floating anchors, fields, numbering, and Word-specific layout.
- Keep the original OpenXML-edited DOCX as the final deliverable when structural QA passes.
- Before this gate, inspect/rewrite package relationship parts so every `*.rels` serializes with the default package relationship namespace. If Word/预览 reports a source-load failure, inspect `word/_rels/document.xml.rels`, header/footer `.rels`, and copied part `.rels` first for `ns0:Relationships`/`ns0:Relationship`.
- Record the gate result as `libreoffice_compatibility_qa` in `qa_report.json`.
- If Word/预览 load/export fails, record `libreoffice_compatibility_failed` in `format_report.json` with the failure kind and stderr tail. Include a concise final user note that Word/预览 compatibility needs checking, but do not silently replace the file with a Word/预览-normalized copy.
- If Microsoft Word render QA passes but Word/预览 compatibility fails, prefer Word fidelity and report the Word/预览 compatibility risk.

## Render Compare Gate

Rendering is an internal QA gate, not a user deliverable. After producing the final `.docx`, the formatter usually renders both the original target DOCX and the final DOCX to PNG pages and compares them before delivery. This gate is mandatory for native DOCX/DOTX visual templates; absence of `--render-qa-dir` is not permission to skip it for those sources.

Text-rule-source exception:

- If the desired format came primarily from text-only/OCR/non-DOCX-derived rules, skip target-before/final render comparison because the final layout is expected to differ greatly from the original target and visual diff becomes misleading.
- Text-rule sources include explicit plain-text formatting instructions, selectable-text PDF author/submission guidelines, legacy `.doc`/`.dot` converted text rules, OCR text extracted from screenshots/images, and website/image text instructions.
- Use `--format-source-type ocr_text_rules`, `--format-source-type text_rules`, `--format-source-type converted_docx_template`, or set `_meta.source_type` in `rules.json` to one of `text_rules`, `ocr_text_rules`, `image_text_rules`, `screenshot_text_rules`, or `website_text_rules`.
- Record `render_compare_qa` with `enabled=false`, `skipped=true`, `skip_reason=format_source_text_rules`, and record `render_compare_skipped_text_rules` in `format_report.json`.
- This exception skips only target-before/final visual comparison. Structural QA, package relationship checks, object-count audits, and Word/预览 load/export compatibility QA must still run.

---

> 因文档体量拆分：后续内容见 `template-distill-render-qa-3.md`。
