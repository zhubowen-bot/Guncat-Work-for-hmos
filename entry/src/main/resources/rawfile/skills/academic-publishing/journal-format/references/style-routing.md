# Style Spec And Routing

Read this before generating or consuming `style_spec.json`, classifying roles, applying text rules, installing role styles, or cleaning direct formatting.

## Intermediate Style Spec

The role style spec is the mandatory bridge between template extraction and target formatting. It must be generated from the template only, then consumed by the target stage. Target styles, target style names, and target direct formatting must never influence what a role should look like.

All source formats must enter this same bridge. Do not maintain separate target-formatting routes for native `.docx`, legacy `.doc`, PDF, images, or website rules after evidence extraction. Convert every usable source into a role-based `style_spec.json`, then classify the target into `role_map.json`, then apply the spec. The only difference between source formats is evidence priority and confidence.

When `references/template-distill-render-qa.md` is used, `template_evidence.json` or `qa_report.json` may support `style_spec.json` only on the template side. Target-before QA can warn about direct-format cleanup needs and object-preservation risks, but it must not define the desired role style. The target file answers "where is each role"; the template evidence answers "how each role should look."

Source-aware priority is locked:

- Native `.docx`/`.dotx`: `user_rules > template_text_rules > representative_template_direct_format > template_style_xml > property-level granular fallback only for explicit prose text rules with missing/default core properties`. Do not inject whole-role bundled fallback into clean native DOCX styles because missing properties can be intentional Word inheritance. Instruction-heavy native DOCX templates are different: if text says `摘要：楷体小5号` or `文章正文是5号宋体` but the paragraph/style exposes no real line spacing, indentation, or paragraph spacing, preserve the explicit font/字号 and fill only the missing paragraph properties from granular fallback.
- All non-DOCX sources, including legacy `.doc`/`.dot`, PDF, screenshot/image/OCR, website, and externally supplied visual rules: `user_rules > extracted_text_rules > source_column_detection_for_fallback_variant > bundled_OOXML_fallback > legacy_dictionary_fallback`. For website links, the source-column step is allowed only when website/user text explicitly says single-column or double-column manuscript layout; otherwise choose single-column fallback and record `website_unspecified_columns_default_single`.

Priority wording is important: "non-DOCX source is lower confidence" means the carrier lacks reliable Word XML style parts. It does not mean extracted text rules are weaker than fallback. Explicit text rules must lock the exact property channels they mention, and fallback may only fill unstated or unsafe-default channels. Re-apply explicit user/text rules after fallback merge.

Rules JSON explicit fields do not need `source` or `confidence` to be honored. A role rule containing deterministic formatting keys such as `size`, `font_size`, `fonts`, `font`, `spacing`, `line_spacing`, `indent`, `paragraph.indentation`, `align`, `bold`, `italic`, `color`, `tabs`, or `numbering` is an explicit text/user rule by structure and must survive non-DOCX sanitization. Drop only fields marked as visual/geometry inference, such as `source=visual_role_alignment`, `pdf_visual`, `visual_supplement`, or similar visual-only evidence.

Rules JSON must be normalized before any visual sanitization, text-rule merge, fallback merge, or style installation. Accept both the flat schema and OOXML-summary schema:

```json
{
  "roles": {
    "body": {
      "size": "24",
      "spacing": {"line": "480", "lineRule": "auto"}
    }
  }
}
```

```json
{
  "body": {
    "summary": {
      "pPr": {"spacing": {"line": "480"}},
      "rPr": {"sz": {"val": "24"}}
    }
  }
}
```

The second form must normalize to `body.size="24"` and `body.spacing={"line":"480","lineRule":"auto"}`. `summary.pPr.ind`, `summary.pPr.jc`, `summary.rPr.rFonts`, root-level `pPr/rPr`, and `paragraph.pPr` are also valid sources for the same flat fields. Record accepted summary paths in `rules_schema_diagnostics.normalized_fields`. Invalid role names or role rules with no recognized deterministic fields must generate schema warnings; do not silently run fallback as if the user rule succeeded.

Spacing normalization is mandatory, not cosmetic. WordprocessingML `w:spacing/@w:line` is not a free-form decimal field. Convert semantic line-spacing rules before writing XML: `1.5`/`1.5x`/`一倍半` -> `360` with `lineRule="auto"`, `double-spaced`/`double line spacing` -> `480`, `single-spaced`/`single line` -> `240`, and exact point spacing -> points*20 with `lineRule="exact"`. This applies to flat rules, OOXML-summary rules, extracted website/PDF text, legacy DOC text, `style_spec.json`, role `style_xml`, `pPr_xml`, `Normal`, `docDefaults`, and any final direct paragraph spacing. If a reused spec already contains `w:line="1.5"`, repair it before repack and record the repair in QA.

Website author guidelines are not native Word templates. Pages such as Nature formatting guides often state submission rules such as `Contributions should be double-spaced and written in English`, organization order, title length, reference limits, and figure/table placement, but not full Word style XML. Treat these as high-priority extracted text rules for the properties they state; map manuscript-wide rules to content roles such as abstract/summary, body, reference items, captions, and display equations. Missing typography, paragraph spacing, table XML, equation tabs, and page setup still come from the selected standard fallback. Do not infer Nature/Science production PDF layout or double columns from the website brand when the manuscript guide does not explicitly require it.

When the source is non-DOCX or a blank carrier DOCX used only because the formatter requires a package, the carrier template must be treated as unformatted. Start generated role styles from a clean style shell and write only properties from explicit text/user rules plus granular fallback. Do not inherit blank-template, converted DOC/DOT, PDF, website, OCR, or Word built-in Heading/Reference colors, underlines, borders, small caps, theme colors, stale sizes, single line spacing `w:line="240"`, style links, support files, headers/footers, or page XML. Visual/geometry evidence may only provide reliable `fallback_columns`, except website links where visual/brand/page-layout evidence must not provide double-column fallback without explicit website/user text.

Blank/carrier templates must materialize fallback instead of preserving Word defaults:

- If the source package has no meaningful format text/sample content but external rules exist, route it as `blank_carrier_template`.
- Generate `docDefaults` and `Normal` from the body fallback baseline, not from the blank Word package.
- Generate every role style from explicit text/user rules plus granular fallback. A blank carrier's existing `Normal`, `Heading1`, `Heading2`, and `Bibliography` styles are containers only.
- Validate at least `title`, `heading1`, `body`, and `equation` role styles after spec creation. For Chinese fallback, `title` and `heading1` must have explicit `w:spacing w:before="240" w:after="120" w:line="360" w:lineRule="auto"` where defined by fallback, `body` must have `w:line="360"`, and `Normal/docDefaults` must not remain at blank-template `w:line="240"` when the fallback language is Chinese.
- If user rules explicitly set body spacing, such as `line="480"`, materialize that same locked spacing into weak-source `docDefaults` and `Normal` after fallback merge. Do not leave `Normal` at `w:line="240"` while `9body` has `w:line="480"`, because unbound/body-like paragraphs can display with Normal spacing.
- When reusing an old `style_spec.json` created from a blank carrier, repair it before installation by rebuilding low-confidence role styles from the current fallback. Do not let stale `style_xml` carry the old carrier's 240-line spacing back into QA repair.

When the format source began as legacy `.doc` or `.dot` and was converted to temporary `.docx`, the converted package is only a text-extraction carrier. Do not use converted `styles.xml`, `Normal`, `Heading`, bibliography styles, representative paragraph/run direct formatting, rendered visual crosscheck, settings/fontTable/theme, headers/footers, or page XML as style authority. If converted text rules such as `正文五号宋体` are found, they lock only the stated properties; missing properties come from fallback. If the converted/rendered source reliably exposes single-column or double-column layout, record only `fallback_columns` for variant selection and final risk notes.

Legacy `.doc`/`.dot`, PDF, screenshot/image/OCR, website, and plain text rules must use the same bridge. Extract text rules and optional column-count metadata only; after that, the target formatting stage is still role-map plus style-spec application. Do not let a converted `Normal`, `Heading`, bibliography style, blank carrier, website display stylesheet, or PDF/OCR visual sample define blue headings, red underlined references, exact colors, exact fonts, underlines, local emphasis, role alignment, spacing, indentation, tabs, or other default shell formatting.

For converted `.doc`/`.dot`, do not hardcode `fallback_columns=1`. Although converted OpenXML is not style authority, the converted `sectPr/w:cols` count is allowed low-confidence structural evidence for choosing `zh_single`, `zh_double`, `en_single`, or `en_double`. If the converted package has any section with `w:cols/@w:num >= 2`, choose double-column fallback unless explicit user/rules metadata says otherwise. If `sectPr` detection fails, use source filename keywords such as `双栏`, `单栏`, `two-column`, or `single-column` as lower-priority hints, then default to single-column with a warning.

For non-DOCX sources, never replace an entire role with fallback just because one property is missing. Merge at property level. A rule like `正文宋体五号` locks body font and size; missing line spacing must come from fallback, not coarse visual evidence or converted-DOC direct formatting. A short rule paragraph can provide font/size wording but must not donate its paragraph spacing, indentation, tabs, color, or border.

If a website guideline says `正文 12 pt Times New Roman` and says nothing about spacing, body font/size must be `12 pt Times New Roman`; spacing may come from fallback. Do not report this as the text rule being weaker than fallback.

Apply the same property-level merge to native DOCX instruction templates. A native `.docx` is not automatically a high-quality style authority when it is mostly explanatory prose or sample instructions. If role text rules are explicit but the matched paragraph is a format hint, a label plus writing instructions, or has default/placeholder paragraph XML such as `w:spacing w:line="0"`, treat its paragraph properties as missing and complete them from granular fallback. Do not use this as permission to overwrite a clean native DOCX style that has trustworthy paragraph XML.

For paired abstract/keyword rules, allow font and字号 to propagate between the pair when one side gives the explicit format and the other side is only a keyword-count/example sentence. For example, `摘要：楷体小5号` plus `关键词：3-8个关键词...` means both abstract and keywords use 楷体小五 unless a stronger rule says otherwise; paragraph spacing/indent still comes from explicit evidence or fallback at property level.


---

> 因文档体量拆分：后续内容见 `style-routing-2.md`。
