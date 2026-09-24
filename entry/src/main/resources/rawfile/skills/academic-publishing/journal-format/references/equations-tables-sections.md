# Equations Tables And Sections

Read this before applying equation tab-stop layout, table body formatting, section/page setup, headers/footers, or mixed-column layout repair.

## Equation Layout

Formula paragraphs and equation numbers are often positioned by paragraph tab stops (`w:pPr/w:tabs`) and inline tab runs (`w:tab`), not only by paragraph style.

Mandatory equation-layout behavior:

- Scan template paragraphs containing OMML (`m:oMath` or `m:oMathPara`), including OMML nested inside runs.
- Treat display formulas/equations as an independent `equation` role. Template paragraphs using `DisplayFormula`, `Equation`, or `Formula` styles, MathType/OLE formula paragraphs, numbered graphic-equation paragraphs, and formula-only/numbered formula paragraphs must not be mapped as generic `body`.
- Also detect equation-like object paragraphs in the target, including MathType/OLE embedded objects (`w:object`, `OLEObject`, `objectEmbed`, VML `imagedata` with equation/MathType ProgID) and numbered graphic-equation paragraphs. These are not OMML, but they can still receive paragraph tab-stop layout.
- Detect whether the paragraph has an equation number such as `(1)`, `（1）`, or `(2.3)`.
- Extract paragraph tab-stop definitions: each `w:tab` alignment (`left`, `center`, `right`, etc.) and position (`w:pos`).
- Extract inline tab structure: number of tabs before the formula, tabs between equation and number (`tabs_between_equation_and_number`), and tabs after the number.
- Store this as `equation_layout_map.json` internally.
- After direct-format cleanup, apply the extracted `w:tabs` and required `w:tab` runs to target equation paragraphs, including compatible MathType/OLE object paragraphs.
- Tab-run synchronization is exact, not append-only. If the template says `tabs_before_equation=0`, remove extra pure tab runs immediately before the formula. If the template says `tabs_between_equation_and_number=1`, reduce or add pure tab runs between formula and number until the count is exactly one.
- For MathType/OLE formulas, inspect both paragraph-child pure tab runs and `w:tab` children inside the same `w:r` as the object. Some target files store `TAB + OLE object + TAB + number` as separate runs, while others store tabs inside the object run. Both forms must be normalized.
- Do not treat generated role style IDs such as `14equation`, `DisplayFormula`, or other style names as formula object anchors. Equation anchors must come from OMML, OLE/object/embed/control, equation-like drawing/pict evidence, or explicitly equation-like object attributes, not from `w:pStyle`/`w:rStyle` values.
- Ignore non-layout markers such as `w:lastRenderedPageBreak` when deciding whether a run is a pure tab run; a run containing only `w:tab` plus render markers is still removable tab layout.
- If the template only provides an unnumbered centered formula sample with no `w:tabs`, treat this as valid evidence for formula role/alignment but not for numbered-equation tabs. For target numbered display equations, use the computed fallback below rather than preserving stale target tabs.
- Computed fallback for numbered display equations is mandatory when the template has no numbered-equation tab evidence: compute the active text width from the final target section containing that equation (`pgSz.w - pgMar.left - pgMar.right - pgMar.gutter`, adjusted per column when `w:cols` has multiple columns), set paragraph tabs to a center tab at half of that active width and a right tab at the full active width, remove old target equation tabs, then set exactly one `w:tab` before the formula and exactly one `w:tab` between the formula and the equation number.
- The fallback has Chinese and English single-column/multi-column variants, but all variants use the same geometry rule: single-column equations use the section text width; double-column equations use the computed column width, not the full page/body width. This prevents equations and equation numbers from crossing the column boundary when a single-column manuscript is converted to a two-column template.
- The fallback must be computed per equation paragraph or per active section, not once from the document's final section. Mixed-layout documents can contain single-column front matter, two-column body sections, and later full-width sections; each equation must receive tab stops appropriate to its own section.
- Computed fallback must place the equation number at the right edge of the body text area, not at the physical page edge. Page margins and columns must be respected.
- Apply equation tab layout only to display-equation paragraphs. OLE/MathType objects embedded inside normal prose are inline formulas and must stay as `body`; do not remove their surrounding text or tabs as if the whole paragraph were a display formula.
- If the template equation paragraph has no paragraph-level `w:tabs`, but its style/alignment centers the formula, remove stale target paragraph-level `w:tabs` from equation paragraphs instead of preserving incompatible tab stops.
- Do not modify OMML formula XML, MathType/OLE object XML, field codes, images, or the equation number text itself. Only change paragraph properties and tab run separators.
- After equation layout and after any final direct-format cleanup, protect display and inline equation/object paragraphs from exact fixed line-height clipping. If an OMML, MathType/OLE, drawing, or pict paragraph inherits `w:lineRule="exact"` from body/equation styles or direct `pPr`, override only that paragraph to `w:lineRule="auto"` before repack. This is a visual preservation guard, separate from equation tab layout, and must not rewrite formula/OLE payloads.
- If a target formula has no equation number, apply only the unnumbered formula layout when available; do not invent equation numbers.
- If the template has no equation tab-stop evidence, preserve target equation layout and mention in the final note that formula alignment/equation-number position needs visual confirmation.
- Report counts by equation kind, such as `omml`, `ole_object`, and `numbered_graphic_equation`, in the internal format report.

Few-shot:

| Template evidence | Target equation paragraph | Expected behavior |
|---|---|---|
| Formula + one tab + `(1)`, with center/right tab stops | Formula + `(2)` without tab | Add the template tab stops and insert one tab between formula and `(2)`. |
| Template has unnumbered formula centered by a tab stop | Target unnumbered formula | Apply the unnumbered formula tab-stop layout; do not add a number. |
| Template OMML equation has center/right tab stops | Target MathType OLE equation with `(3)` in the same paragraph | Apply the template paragraph tabs and insert the required separator tabs around the OLE object; do not edit the OLE payload. |
| Template `DisplayFormula` style is centered and has no `w:tabs`; target is `TAB + OLE formula + TAB + (1)` | Map the paragraph as `equation`, apply centered equation style, remove the formula-before tab, and keep only the required tab between formula and number if the template profile requires one. |
| Template has an unnumbered centered OLE/OMML formula and no numbered formula example | Target is `TAB + OLE formula + TAB + (1)` | Compute fallback tabs from the equation's active section/column width, set center/right tab stops, normalize to exactly one tab before formula and one tab before number. |
| Template has no usable formula tab evidence, target has numbered display equations in a two-column body | Target is `OLE formula + (1)` or stale `TAB + OLE + TAB + (1)` | Compute center/right tabs from the column width, not the full body/page width, and normalize the runs to `TAB + formula + TAB + number`. |
| Template has no usable formula tab evidence, target has numbered equations in both single-column and double-column sections | Same document has equations in different sections | Use different computed fallback widths per section: single-column equations use section text width; double-column equations use column width. |
| Target paragraph has an image plus equation number `(4)` and no prose caption words | Treat as a numbered graphic equation candidate and apply paragraph tab layout; do not treat ordinary figures/captions as equations. |
| Target body paragraph contains `text + OLE inline formula + text` | Keep it as `body`; do not apply display-equation tab cleanup. |
| Template has no formula tab evidence | Target formulas exist | Preserve target formula layout and warn the user to check formulas. |

## Table Body Formatting

`table_caption` only formats the text above or below a table. It does not format the table body. Table body formatting must have its own bridge file, `table_format_map.json`.

For Chinese fallback with bilingual front matter and no stronger template evidence, figure/table captions should be bilingual: Chinese caption first, English translation in the immediately following caption paragraph. Do not put the English translation in the same paragraph via a soft line break or raw newline; separate paragraphs make spacing and role mapping auditable.

Mandatory table behavior:

- Scan every template `<w:tbl>` and extract table body XML features, not only nearby captions.
- Score every template table for formatting strength before applying it to targets. Border evidence, cell border evidence, table styles, shading, margins, header-row evidence, and internal paragraph/run formatting make a table stronger. Text volume alone must not make a table representative.
- Treat tables with little or no border/style evidence as weak or possible placeholder/occupancy tables.
- Extract table-level properties from `w:tblPr`, including `w:tblStyle`, `w:jc`, `w:tblInd`, `w:tblCellSpacing`, `w:tblLook`, `w:tblCellMar`, `w:shd`, and especially `w:tblBorders`.
- Treat table width (`w:tblW`) and layout (`w:tblLayout`) as protected layout-size properties, not ordinary formatting children. Do not include them in broad `tblPr` overwrite.
- Extract every table-border side separately: `top`, `bottom`, `left`, `right`, `insideH`, and `insideV`, including `val`, `sz`, `space`, `color`, `themeColor`, and related attributes.
- Extract row-level properties from `w:trPr`, including header-row repeat `w:tblHeader`, row height, `cantSplit`, row alignment, and row cell spacing.
- Extract representative row profiles for header row, body rows, and footer/last row. Three-line tables usually encode top line on the table/header, header bottom line on the first row's cells, and bottom line on the last row or table border.
- Extract cell-level formatting properties from `w:tcPr`, including `w:tcW`, `w:tcBorders`, `w:shd`, `w:tcMar`, `w:textDirection`, and vertical alignment. Recognize merge/topology properties such as `gridSpan`, `hMerge`, and `vMerge` for audit, but do not force template merge topology onto target tables.
- Extract each cell-border side separately: `top`, `bottom`, `left`, `right`, `insideH`, `insideV`, `tl2br`, and `tr2bl` when present.
- Extract representative table-internal paragraph/run formatting from non-empty cells so table text font, size, bold, alignment, spacing, and vertical alignment do not remain from the target.
- Apply the extracted table profile to target tables after direct-format cleanup. Replace only formatting containers; never rewrite cell text, formulas, drawings, media, field codes, or relationship parts.
- Preserve target table width by default when the template table width is `auto`, missing, or `w:w="0"`. Many templates use `w:tblW w:type="auto" w:w="0"` only to let the sample table fit its content; copying it can shrink target tables from full page width to content width.

---

> 因文档体量拆分：后续内容见 `equations-tables-sections-2.md`。
