- Do not apply a heading style with Word automatic numbering directly to a target heading that already begins with a manual heading number such as `1 Introduction`, `1 2D Human Pose Estimation`, `1.1 Method`, `I. INTRODUCTION`, or `第一章 绪论`. This displays duplicate numbers. Create/use a no-number mirror of the generated heading style for only those manually numbered target heading paragraphs, and keep the original automatically numbered heading style for plain target headings such as `Introduction`.
- Do not solve heading-numbering conflicts by globally stripping all heading `numPr`. That breaks templates whose plain headings depend on Word automatic numbering.
- Do not confuse reference-list numbering repair with style numbering migration. Style `numId` migration makes numbered styles valid; reference-list numbering repair normalizes visible bibliography prefixes only when template examples prove the pattern.
- Do not strip `reference_item` `w:numPr` blindly. Strip it only in `visible_text` mode to avoid duplicated displays like `[10] [10]`; preserve it in `word_auto` mode such as ACM/IEEE `Bibentry`, otherwise bibliography numbers disappear.
- Do not add reference-list numbers to body citations, headings, captions, equation numbers, URLs, DOI-only continuation lines, or paragraphs outside `reference_item`.
- Do not invent reference-list numbers when the template has no explicit numbered reference examples.
- Do not duplicate existing reference-list numbers such as `[1]`, `1.`, `1．`, `1、`, or `1)`.
- Do not leave downstream manual reference numbers unchanged after inserting a missing item. Once a missing item receives `[11]`, following visible prefixes must be renumbered `[12]`, `[13]`, etc., unless they are uncertain continuations.
- Do not leave visible-prefix `reference_item` styles without any hanging/first-line indentation when the template lacks explicit `w:ind`; apply the reference-only hanging-indent fallback and report it.
- Do not write `reference_item` fallback as `w:hanging` alone. Pair it with `w:left` equal to or greater than `w:hanging`, otherwise the first reference line can protrude left of the body text boundary.
- Do not add style-level hanging-indent fallback to `reference_item` when the style uses Word automatic numbering through `w:numPr`; rely on copied `numbering.xml` level indentation instead.
- Do not ignore user reference indentation rules. Normalize `indentation.hanging`, `paragraph.indentation.hanging`, and `hangingIndent` into Word `w:ind w:hanging`.
- Do not preserve a visible-text `reference_item` style with `w:hanging > w:left` or with `w:hanging` but missing `w:left`; repair it before style installation and report the fallback/guarded indentation.
- Do not delete or rewrite OMML formulas when applying equation layout.
- Do not delete or rewrite MathType/OLE equation objects when applying equation layout.
- Do not treat OLE/MathType/OMML preservation as only an object-count problem. The object can remain in the package but be visually clipped when its paragraph keeps `lineRule=exact`; QA must flag and the formatter must repair this before delivery.
- Do not map display formula/equation paragraphs as generic `body`. `role_counts` should show `equation` when target display formulas exist and the template/target contains formula evidence.
- Do not limit equation tab layout to OMML only. MathType/OLE object paragraphs and numbered graphic-equation paragraphs may receive paragraph `w:tabs` and separator `w:tab` runs when template tab evidence exists.
- Do not apply formula/equation-number tab layout before direct-format cleanup; cleanup removes paragraph `tabs`, so equation layout must be restored after cleanup.
- Do not implement equation tab layout as append-only. Extra pure tab runs before the formula or between formula and equation number must be removed when the template requires fewer tabs.
- Do not identify formula anchors from style names or generated style IDs such as `14equation`; this makes `pPr` look like the first equation child and prevents removal of real tabs before the OLE run.
- Do not skip equation layout just because the template formula sample has no explicit `w:tabs`. A centered formula paragraph with an equation object and `tabs_before_equation=0` is enough evidence to remove stale target formula-before tabs.
- Do not preserve stale target formula/number tabs merely because the template lacks a numbered formula sample. Use computed fallback tabs from the page text width for numbered display equations.
- Do not calculate fallback equation-number tabs from the physical page width. Use the active text width after margins, gutter, and columns, so the equation number aligns with the body text right edge.
- Do not apply display-equation tab cleanup to inline MathType/OLE objects inside prose body paragraphs.
- Do not preserve target equation paragraph-level `w:tabs` when the template equation sample has no `w:tabs`; stale tab stops can override centered formula styles.
- Do not treat `table_caption` as table body formatting. Captions and tables are separate surfaces.
- Do not leave table body formatting outside the workflow. Extract and apply `tblPr/tblBorders`, row properties, `tcPr/tcBorders`, and table-internal paragraph/run formatting.
- Do not rewrite table cell text, formulas, drawings, media, relationships, or merge topology when applying table body formatting.
- Do not leave English templates outside the table fallback route. When template table XML evidence is missing or weak, apply the same conservative academic three-line table fallback for both English and Chinese templates: top rule, header bottom rule, bottom rule, and no vertical/internal grid lines. This fallback may change only borders; it must preserve width, row/column count, merges, text, formulas, and media, and it must be reported for visual confirmation.
- Do not hand-code table fallback when `assets/fallback_ooxml_spec.json` provides the selected variant's `tables.three_line` XML. Use that XML first, then keep the redundant cell-border enforcement pass.
- Do not implement three-line table fallback with table-level `tblBorders` only. Word can hide table-level rules when cell borders are present or inherited. Write redundant cell-level borders: first row top, final header row bottom, final row bottom, and explicit `none` for left/right/internal borders. Avoid `nil` for disabled fallback borders because it can inherit or render inconsistently.
- Do not assume every table has a single header row. For weak/fallback table formatting, infer composite header rows conservatively from merges, spanning group cells, short subheader rows, and the first data-like row. Place the header-bottom line under the last inferred header row, and when multiple header rows exist, add a thin separator between header levels; preserve explicit template multi-row header borders when available.
- Do not omit bilingual figure/table captions in Chinese fallback samples when the surrounding manuscript has bilingual title/abstract/front matter. If the template lacks caption language evidence, Chinese fallback should prefer Chinese caption followed by its English translation directly below it for figure and table captions. Write them as two consecutive caption paragraphs, not as one paragraph with an embedded newline, so Word layout, spacing, and role mapping stay stable. Otherwise record caption-language confirmation risk.
- Do not copy template `w:tblW w:w="0" w:type="auto"` over target tables by default. This can shrink full-width target tables to content width.
- Do not overwrite target table width unless the template width is explicit nonzero `pct/dxa` or the user explicitly allows table-width override.
- Do not copy `w:tblLayout w:type="autofit"` as a side effect of broad `tblPr` replacement when preserving target width.
- Do not hard-match template tables to target tables by index when counts differ. A later weak or borderless template table may be a placeholder and must not clear target borders.
- Do not let a weak template table remove borders from a target table when a stronger representative template table exists.
- Do not keep target vertical lines, inside horizontal lines, shading, or cell margins when the template's table XML explicitly defines a different border/margin model.
- Do not let template style XML override extracted prose rules.
- Do not let stale `pPr/rPr` override locked prose/user rules inside the generated role style.
- Do not leave deterministic role-style conformance failures for the user to find visually. After role binding and direct-format cleanup, automatically repair wrong `w:pStyle` bindings, remaining direct font/size/color/bold/italic/spacing/indent/alignment overrides, and stale generated-style `pPr/rPr` or `pPr/rPr/rPr` properties that conflict with or are absent from `style_spec.json`. Report only unresolved or evidence-uncertain conformance issues.
- Do not finish a blank/carrier-template run without checking fallback role samples. At minimum verify that title and heading paragraph spacing, body line spacing/font/字号, equation alignment/line spacing, and target `Normal/docDefaults` match the selected language fallback or explicit rules. A title/heading/body style still showing carrier `line="240"` after a Chinese-target fallback is a repair failure, not a final-note-only risk.
- Do not remove or normalize colors only in structured summaries. Any template hint color cleanup must modify authoritative `style_xml`, `pPr_xml`, and `rPr_xml`.
- Do not preserve red/orange/blue template hint colors as final role styles for metadata, abstract, keywords, citation-format, reference-item, or body roles unless explicitly required.
- Do not add paragraph alignment (`w:jc`) from granular fallback for native DOCX sources. Missing `w:jc` means Word default left alignment and must stay missing unless explicit evidence sets it. For non-DOCX text/fallback sources, alignment comes from explicit text rules or the selected fallback baseline, never from visual-only alignment.
- Do not choose role style sources from tables or template explanation/front-matter paragraphs.
- Do not disable direct-format cleanup unless the user asks for it.
- Do not encode author/affiliation superscript in the paragraph style. Use `superscript_map.json` and run-level `w:vertAlign` only.
- Do not use author/affiliation superscript numbers as evidence for reference-citation superscript style.
- Do not modify target reference citations when the template does not explicitly define reference-citation superscript formatting; preserve the original target formatting and mention it in the final note.
- Do not add concrete fallback fonts into `rFonts` when the corresponding theme font attribute already exists.
- Do not mark a body source untrustworthy just because the source text is shorter than 80 characters. Check whether it is a real/placeholder body paragraph versus an explicit format hint or Word operation instruction.
- Do not treat `pStyle=None` body paragraphs as `docDefaults` only. Merge the template default paragraph style such as `Normal` first, then overlay paragraph direct properties.

## Known Limits

This remains a lightweight tool. It does not fully replace the stricter source-template skill line. Use the stricter workflow when exact journal compliance, multi-stage audits, numbering repair, table normalization, object counts, or relationship validation are required.


---

> 本文件为拆分后的续篇，请按文件名序号与上篇连续阅读。
