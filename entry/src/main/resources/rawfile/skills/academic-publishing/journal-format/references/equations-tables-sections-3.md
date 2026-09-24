Failure mode to avoid: in templates with `front single-column -> body double-column -> back single-column`, do not use the final single-column section as the fallback for every target body section. The body area must receive the body/double-column `w:cols` when the template provides one.

Failure mode to avoid: in templates with `single-column title -> three-column author grid -> two-column body -> full-width figure -> two-column references`, do not select the three-column author grid as the representative body section merely because it is the first multi-column section. The representative body section should be the longer two-column section with body/heading/abstract/keyword/reference evidence. The IJCA mixed single/double-column template is a canonical example.

Failure mode to avoid: when a target paper starts as a single-section manuscript and the template is `front single-column -> body double-column`, do not apply the body/double-column `cols` to the whole document. Insert a section break before the target body start so title, abstract, and keywords remain in the front-matter column layout while body text receives the body column layout.

Failure mode to avoid: when the format source is PDF/DOC/image/website/text rules and only selects the bundled double-column fallback, do not assume the fallback means all content is double-column. The fallback double-column variants are front-single/body-double for both Chinese and English. If no safe body-start split exists, single-column front layout is safer than double-column front matter.

Do not let section routing affect role routing. Sections only control page geometry/header/footer. They must not reset paragraph role state, choose style sources, or make the model restart classification after each section. If adding multi-section support appears to make mapping worse, inspect `style_spec.json` and `role_map.json`: the likely fault is role source selection or classifier state, not the section XML update itself.

## Chinese Metadata Tab Layout

Whenever the target document explicitly contains Chinese classification metadata such as `中图分类号：TP311；TP391. 文献标志码：A`, format only that metadata pair as one paragraph with a right-aligned tab stop, not justified text and not repeated spaces. This is a deterministic target cleanup, not a weak-source-only fallback, because native DOCX templates can also contain manually spaced or untrustworthy metadata rows:

- Keep `中图分类号：...` at the left.
- Insert exactly one tab before `文献标志码：...`.
- Set the tab stop to `right` at the body text boundary computed from `pgSz.w - pgMar.left - pgMar.right - pgMar.gutter`.
- Set paragraph alignment to `left`; remove `both`/`distribute` justification and stale paragraph tabs.
- If the two fields are in adjacent paragraphs, merge only those two metadata paragraphs and move any paragraph-level `sectPr` from the removed paragraph to the kept paragraph so section routing is preserved.
- Run this after role-map-dependent passes such as reference numbering and superscript mapping, because merging paragraphs earlier can invalidate paragraph indexes.
- Apply it for native DOCX templates and weak/non-DOCX/blank-carrier sources alike unless the user explicitly disables it or gives a conflicting instruction.
- Do not infer this layout for unrelated metadata such as article number, received dates, funding, DOI, author affiliations, or citation-format lines.

Few-shot:

| Target metadata evidence | Expected behavior |
|---|---|
| One paragraph contains both `中图分类号` and `文献标志码`, separated by many spaces and justified | Replace the separator with a Word tab, add one right tab stop at the text boundary, and set `w:jc` to `left`. |
| `中图分类号：TP311` and the next paragraph is `文献标志码：A` | Merge into one metadata paragraph with one tab separator; do not merge unrelated metadata or body text. |
| Native DOCX route contains a `中图分类号` + `文献标志码` row with manual spaces, first-line indent, or justification | Still apply the one-line tab repair; this row is a known Chinese classification metadata layout, not generic metadata styling. |
| Native DOCX template explicitly gives a conflicting user/template instruction for this row | Follow the explicit instruction and report the conflict instead of applying the automatic tab repair. |

## Multi-Column Object Width Fitting

When section routing changes a body area from single-column to multi-column, wide objects from the original manuscript can remain at single-column/page width. This must be handled as a layout adaptation step after final section geometry exists:

- Compute the active text width for each section from `pgSz - left/right/gutter`, then compute the column width from `w:cols/@num` and `w:cols/@space`.
- In sections with more than one column, any inline or floating drawing whose `wp:extent/@cx` exceeds the active column width should be scaled down to fit the column while preserving aspect ratio. Update the matching drawing extents consistently.
- Skip small icons/logos and other tiny objects; do not enlarge objects.
- In multi-column sections, wide tables should be constrained to the active column width when their explicit `tblW`, `tblGrid`, or row cell widths exceed the column. Preserve row/column count, merge topology, text, formulas, drawings, and media.
- This fitting pass must run after page setup/section insertion and after table body formatting, because both can affect the final width context.
- Record scaled drawings/tables in the internal report and final risk notes. The user should visually confirm readability and placement.
- If the template intentionally uses full-width figures/tables through separate single-column sections, do not force those objects into a two-column section; section routing should keep/insert the full-width section first.

Few-shot:

| Situation | Expected behavior |
|---|---|
| Target manuscript is single-column, template body is two-column, a body image is 6.8 inches wide | Scale the image down to the computed column width and keep aspect ratio. |
| Target has a small icon under 0.5 inch in a two-column section | Leave it unchanged. |
| Target has a 100% page-width table in a two-column body section | Fit table width/grid/cell widths to the column while preserving content and merge topology. |
| Template has a full-width figure section between two-column body sections | Keep the figure in the full-width section when section evidence supports it; do not shrink solely because other sections are two-column. |


---

> 本文件为拆分后的续篇，请按文件名序号与上篇连续阅读。
