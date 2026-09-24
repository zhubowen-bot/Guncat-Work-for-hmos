- PDF/sample/article/proof sources use this exception in the current route because their visual evidence may select only fallback columns, not style properties. Still run structural QA, Word/预览 compatibility QA, and final local Word visual-confirmation notes.

Render-engine priority is locked:

1. Microsoft Word PDF export.
2. Word/预览 PDF export.
3. System preview/QuickLook when available.
4. Word GUI screenshot only as a last manual fallback.

For automated comparison, use the same engine for both the target-before DOCX and the final DOCX. Never compare `target-before` rendered by Word/预览 against `final` rendered by Word, or any other mixed-engine pair. If either side fails under one engine, abandon that engine and retry both files with the next engine. Record `engine`, `attempted_engines`, and any failure kinds in `render_compare_qa`.

```bash
（原脚本命令，本项目改为 docx 技能预览/人工核对） target.docx --output_dir render_qa/target_before --engine word
（原脚本命令，本项目改为 docx 技能预览/人工核对） output.docx --output_dir render_qa/final --engine word
```

The formatter can call the same gate:

```bash
（原脚本命令，本项目改用 docx 技能） \
  -t template.docx -i target.docx -o output.docx \
  --format-report-out format_report.json \
  --qa-report-out qa_report.json
```

If `--render-qa-dir` is omitted, the formatter creates `<output-stem>_render_qa` for native visual sources. The report must include `render_compare_qa`, containing either the selected engine, attempted engines, target-before render status, final render status, page counts, page dimension changes, missing pages, and changed pages; or the explicit text-rule-source skip fields described above. Changed pages are expected after formatting; the purpose is to prove rendering happened and to surface page-count, page-size, or missing-page anomalies.

Inspect the rendered final pages at 100% zoom when possible. Check:

- font substitution or missing glyphs;
- title/author/affiliation/abstract/keywords hierarchy;
- body font, size, line spacing, and paragraph rhythm;
- table borders, cell padding, width, wrapping, and captions;
- equation centering and equation-number right alignment;
- images, floating objects, and captions;
- headers/footers, page numbers, margins, columns, and section breaks;
- reference-list numbering, hanging indentation, and citation superscripts;
- overlap, clipping, excessive blank gaps, and broken page/table breaks.

If rendering fails across all engines, do not claim visual QA passed. Treat it as a render-toolchain or document-compatibility blocker, record `mandatory_render_compare_failed` or `render_qa_failed` in `format_report.json`, keep the DOCX only if ZIP/package structural QA passes, and tell the user to open the file locally in Word for confirmation. If Word rendering fails but Word/预览 rendering succeeds for both files, report that the successful comparison used a lower-priority engine and ask the user to confirm in Word.

The expected execution environment is cloud-side and should already expose the render toolchain. Invoke the toolchain directly; failures are QA findings and must be recorded in the report.

## Visual Diff

For bug-fix regression checks, render two DOCX files and compare:

```bash
（原脚本命令，本项目改为人工比对） before.docx after.docx --outdir diff_qa
```

Do not use visual diff as a strict pass/fail when the target content differs from the template. Use it to find unexplained changes: missing objects, changed page geometry, broken headers, unexpected pagination, or large layout movement outside the intended formatting scope.

## Legacy Word And Non-DOCX Sources

When a `.doc`/`.dot` source is detected, use a temporary-conversion route with Microsoft Word when available or Word/预览 otherwise only to extract text and optional column-count metadata. When a `.doc`/`.dot` source is converted to temporary `.docx`, or when a PDF/image/website is used as format evidence, mark the evidence source as lower confidence and standard-fallback-backed.

All non-DOCX sources share the same conservative route:

1. Use explicit user rules first.
2. Extract source text rules next, including PDF selectable text, OCR text, website text, converted DOC/DOT body instructions, and visible prose examples.
3. Use reliable visual/geometry evidence only to choose single-column or double-column fallback. For website links, skip this visual/geometry column inference unless the website/user text explicitly names the required column count; otherwise default to single-column.
4. Do not use converted style XML, converted direct formatting, visual role/alignment, headers/footers, support files, or page XML as formatting evidence.
5. Fill the remaining holes with granular fallback.
6. Run structural QA and Word/预览 load/export compatibility QA. Skip target-before/final render comparison as text-rule-source routing, and tell the user to visually confirm in Word.

Native DOCX template text rules and representative displayed/direct formatting remain valid only for native DOCX/DOTX templates. Non-DOCX text rules beat fallback only for explicitly stated properties; final notes must say the source was not DOCX, standard fallback was used for missing formatting, and better accuracy usually needs either a native `.docx` template/source-format file or explicit formatting rules provided directly as text instructions.


---

> 本文件为拆分后的续篇，请按文件名序号与上篇连续阅读。
