- Override target table width only when the template provides explicit width evidence such as `w:type="pct"` with nonzero `w:w` or `w:type="dxa"` with nonzero `w:w`, or when the run uses `--allow-table-width-override`.
- If target width is preserved because template width is auto/unspecified, record this in `format_report` as `table_width_preserved`.
- Preserve table topology: do not change row count, column count, `gridSpan`, `vMerge`, `hMerge`, or nested tables during automatic formatting.
- If template and target table counts differ, do not hard-match by index. Use the strongest representative template table profile for target tables by default, so a weak second template table cannot remove borders from target table 2.
- If template and target table counts match, index matching is allowed only when the matched template table has enough formatting evidence. If the matched template table is weak and the representative template table is much stronger, bypass the weak profile and use the representative profile.
- Record representative-table reuse and weak-profile bypasses in `format_report`, including template table index, target table index, and reason.
- If no template table exists, or the only template tables are weak/placeholder tables without usable border/style evidence, apply the table fallback for both Chinese and English templates from `assets/fallback_ooxml_spec.json`: a conservative academic three-line table with top rule, header bottom rule, bottom rule, and no vertical/internal grid lines. Apply only border/cell-formatting XML from the selected language/column variant; preserve target table width, row/column count, merge topology, cell text, formulas, drawings, and media. Report `table_three_line_fallback` so the user confirms table borders visually.
- Three-line fallback must not rely on table-level `tblBorders` alone. Use the bundled sample `tblPr_xml` as a coarse backup and also write bundled or computed cell-level borders: first row every cell gets top thick rule, inferred final header row every cell gets bottom thin rule, final row every cell gets bottom thick rule, and left/right/inside borders use `none` rather than `nil`. This is required because Word may hide table-level top/bottom when cell borders override or conflict with them.
- For composite/multi-row headers, infer the last header row conservatively from merge topology, effective column spans, spanning group cells, short label/subheader rows, and the first data-like row with multiple numeric/percentage/checkmark cells. Put the header-bottom rule below the final header row, not always below row 1. When the inferred header has more than one row, add a thin horizontal separator between header levels so grouped headers such as `准确度` over `Top1/Top5` remain visually separated. If the template provides explicit multi-row header borders, template XML wins over fallback inference.

Few-shot:

| Template evidence | Expected behavior |
|---|---|
| Three-line table: table `top/bottom`, header row/cell `bottom`, no inside vertical lines | Target table receives cell-level top line on first row, header-bottom line under the final header row, bottom line on the final row, and no vertical/internal grid lines. |
| Template table has full grid with `insideH/insideV` and cell `tcBorders` | Target table receives matching horizontal and vertical grid lines. |
| Template has a styled `List Table 6 Colorful` table style plus explicit cell borders | Copy/apply the table style reference and explicit `tblBorders/tcBorders`; do not stop at paragraph roles. |
| Template has table 1 as a three-line table and table 2 as a borderless placeholder; target has 9 tables | Use table 1 as the representative format for target tables. Do not map target table 2 to the borderless template table 2. |
| Template/target both have 2 tables, but template table 2 has no border/style evidence while table 1 has strong borders | Bypass template table 2 and use the representative strong table for target table 2; report `table_weak_template_profile_bypassed`. |
| Template table has `w:tblW w:w="0" w:type="auto"` and target table has `w:tblW w:w="5000" w:type="pct"` | Preserve target `pct=5000`; apply borders/fonts/alignment but do not shrink the table. |
| Template table has explicit `w:tblW w:w="5000" w:type="pct"` | The explicit width may override target width unless the user has locked a reviewed table map. |
| Template has only a table caption and no actual table | Apply the conservative three-line table fallback to target tables and warn that table borders/body layout need confirmation. |
| English template has no usable table XML or only a weak placeholder table | Apply the same three-line table fallback; do not preserve target full-grid/vertical lines merely because the template is English. |
| Fallback three-line table renders without a visible top line in Word | Repair by writing first-row cell `tcBorders/top` explicitly; table-level `tblBorders/top` alone is not enough. |
| Header row 1 has a merged group cell such as `准确度` spanning two columns, row 2 has `Top1` and `Top5`, and row 3 starts data such as `87.60`/`97.55` | Treat rows 1-2 as the table header and place the header-bottom rule below row 2. |
| A fallback table has two header rows but only row 1 received the header bottom line | Repair by writing cell-level bottom borders to every cell in the final inferred header row and a thinner separator between header rows. |
| Row 1 is short labels and row 2 already contains multiple numeric data cells | Treat only row 1 as the header; do not swallow row 2 as a subheader just because it is short. |

Fallback table XML source:

- Select `zh_single`, `zh_double`, `en_single`, or `en_double` from `assets/fallback_ooxml_spec.json`.
- Use `tables.three_line.tblPr_xml`, `header_tcPr_xml`, `body_tcPr_xml`, and `footer_tcPr_xml` as the primary fallback.
- Do not copy `tblW type="auto" w="0"` from the sample over target table width. Preserve target width unless the source template has explicit nonzero `pct/dxa` width or the user passes `--allow-table-width-override`.
- Keep the final cell-border enforcement pass even when the bundled XML is applied; it protects Word rendering of the top/header/bottom rules across target tables with inherited cell borders.
- Record `three_line_header_inference` and `three_line_multi_header_separator_enforced` in the internal table stats so multi-row header decisions can be audited when the rendered table still looks off.

## Section Routing

Word documents may contain multiple sections. Section properties can live in the final `body/sectPr` or inside paragraph properties as `pPr/sectPr`. Treat every `sectPr` as active page setup.

Mandatory behavior:

- Extract all template `sectPr` records, not only the final `body/sectPr`.
- If template and target section counts match, apply template section geometry by position.
- If the target has only one section but the template clearly has a mixed-column front/body structure, insert a continuous section break before target body text before applying page setup.
- Automatic section insertion is allowed only when all of these are true: the template has multiple section profiles, the chosen front/body sections have different column counts, the target currently has exactly one section, and the target body start can be located after abstract/keywords/front matter.
- Locate the target body start conservatively from role evidence: after title/author/affiliation/abstract/keywords/metadata, the first `heading1/heading2/heading3/body` paragraph can start the body section. If the body start is unclear, do not insert a section break; warn instead.
- Insert the break as paragraph-level `pPr/sectPr` on the paragraph immediately before body start, using the template front-matter section geometry. The final/body `sectPr` then receives the selected template body geometry.
- If counts differ and both have multiple sections, do content-aware section routing. Classify each template and target section as front matter, body, back matter/reference, or unknown from the text roles inside that section. Apply the template front-matter section to target front matter, the template body section to target body, and the template back/reference section to target back matter. Do not simply repeat the template final section.
- Treat `w:cols` as a key layout property, not just a passive child of `sectPr`.
- For mixed-column journal templates, do not choose the first multi-column body-like section blindly. Score all body-section candidates and choose the representative body section by column count, real body evidence, heading/abstract/keyword/reference evidence, section length, and penalties for front-matter/title/author/affiliation-heavy sections, tiny sections, and caption-only sections.
- By default, prefer a strong two-column body candidate over a three-column section when the three-column section is short or dominated by title/author/affiliation content. Three-column regions in templates are often author grids or special front-matter layouts, not the actual paper body.
- If the template has multiple body-like sections with different `w:cols`, print every candidate's section index, column count, character count, score, and the chosen section. Warn the user that body columns need visual confirmation.
- Provide a manual override such as `--body-cols 2` when the template's real body column count is known or the automatic score is ambiguous.
- For mixed-column journal templates, apply the chosen representative body section's `cols` to target body sections even when it is not the final template section.
- If the target has one section and the source is a native template without safe mixed-column evidence, use the template final/body section.
- If the source is weak/non-`.docx`/blank-carrier and the selected fallback is double-column, do not apply the body/double-column `cols` to the whole one-section target. Use the fallback front section for title/author/metadata/abstract/keywords, insert a continuous section break before the target body start, then apply the fallback body double-column section. If the body start is unclear, keep the one remaining section single-column and warn rather than making front matter double-column.
- Apply `pgSz`, `pgMar`, `cols`, and `docGrid` to every target `sectPr`, not only `body/sectPr`.
- Preserve section identity fields such as `type` and `titlePg`, but replace page geometry fields with template values.
- Remove old target `headerReference` and `footerReference` entries from every target `sectPr`.
- Insert template header/footer references into every target `sectPr`.
- Print and audit the number of sections processed. A multi-section target must report all sections, for example `Applied page setup to 6 section(s)` and `Applied headers/footers to 6 section(s)`.
- When section counts differ, print the template section profile sequence, target section profile sequence, and the chosen route, including each section's `cols` count. If no template body section with multi-column `cols` exists but the target has body sections, warn that body column layout needs visual confirmation.
- Record automatic mixed-column section insertion in `format_report` as `mixed_column_section_inserted`, including front/body column counts, target body-start child index, and chosen template body section index.

Failure mode to avoid: applying ACM page setup only to the final `body/sectPr` while earlier paragraph-level sections keep the target A4 page size, old margins, old columns, or stale footers. This makes the output visually unlike the template even when paragraph styles are correct.


---

> 因文档体量拆分：后续内容见 `equations-tables-sections-3.md`。
