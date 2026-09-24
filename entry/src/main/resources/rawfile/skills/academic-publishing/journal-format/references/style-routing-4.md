- Author-line detection must run before plain English heading detection in the early front matter. A comma-separated English or pinyin name list such as `Zhang Ji, Bai Yakun, Liu Jiadong` maps to `author`, not `heading1`.
- After the initial role map is built, run a front-matter positional refinement pass before style application. In the short window after a title and before abstract/keywords/body, reclassify likely author lines and affiliation lines using both content and position.
- The refinement pass must treat comma-separated or Chinese-comma/顿号-separated names such as `Zhang Ji，Bai Yakun`, `Zhang Ji, Bai Yakun`, or `张三、李四` as `author` when they appear between title and affiliation/abstract, even when there are no superscript markers.
- If a line after the author line contains institution words such as `University`, `Institute`, `大学`, `学院`, `研究院`, `实验室`, or is immediately before an abstract marker, prefer `affiliation`.
- Do not classify numbered headings as authors. Strings such as `1 2D Human Pose Estimation` and `2 Methodology` remain `heading1` when they occur after front matter.

Heading routing must run before English title fallback after the first visible paragraph:

- `Introduction`, `Conclusion`, `Related Work`, `1 Introduction`, `1    Introduction`, and `1 2D Human Pose Estimation` are `heading1` when they occur after front matter.
- Numbered heading matching must tolerate multiple spaces between number and title.
- When a template heading role style such as ACM `Head1` has Word automatic numbering but a target heading already starts with a manual number, bind that paragraph to a no-number mirror of the same generated heading style. Keep automatic numbering for plain target headings without a manual prefix. This heading-specific conflict handling is separate from reference-list numbering repair.
- Plain English headings must be short and heading-like; long sentence text with verbs such as `allows`, `shows`, `uses`, `is`, or `which` must remain `body`.
- Do not let the broad early author/affiliation fallback classify ordinary body sentences. Author fallback needs name/marker features; affiliation fallback needs institution words.
- Do not let plain-heading title case logic capture comma-separated author lists. If a short line has multiple capitalized names separated by commas or Chinese commas and no institution words, prefer `author` in the front-matter zone.

Legacy `--style-mode name` may still be used for very clean documents, but it is a known risk when the source document was written with arbitrary or localized style names.

## Text Rule Priority

Before any style is injected, scan template body text for visible formatting rules such as:

- `正文五号宋体`
- `摘要小五号宋体`
- `一级标题四号黑体居中`
- `英文 Times New Roman`

Priority is locked:

1. `user_rules`: explicit JSON passed with `--rules-json`.
2. `template_text_rules`: prose rules extracted from the template body.
3. `template_style_xml`: actual style XML copied from the template.
4. `bundled_OOXML_fallback`: fill missing or implicit-default properties from `assets/fallback_ooxml_spec.json`, selected by language and column count.
5. `legacy_dictionary_fallback`: emergency backup only for fields still absent after the OOXML fragment merge.

If prose rules conflict with `styles.xml`, prose rules win. If user JSON conflicts with both, user JSON wins.

The bundled fallback is not prose. It is a role-level OpenXML fragment library generated from four fallback sample DOCX files: Chinese single-column, Chinese double-column, English single-column, and English double-column. Every weak source, blank carrier, converted legacy source, PDF/text/OCR route, and missing-property fallback must use those `pPr_xml/rPr_xml` fragments first. Do not reconstruct fallback styles from narrative text when the JSON fragment exists. Native `.docx` templates are the exception: do not use bundled fallback to fill role-style font/size/spacing/alignment gaps in native template styles.

When a prose/user text rule explicitly sets a property, it must overwrite the same property group from template styles, representative direct formatting, and fallback. Do not merely append the new value while leaving stale same-channel attributes in place:

- If the rule sets `eastAsia`, remove `eastAsiaTheme` before writing `eastAsia`.
- If the rule sets `ascii`, remove `asciiTheme`; if it sets `hAnsi`, remove `hAnsiTheme`; if it sets `cs`, remove `cstheme`.
- If the rule sets size, remove existing `sz/szCs` and rewrite them.
- If the rule sets bold or color, remove existing same-group children before rewriting.
- This rule is property-channel specific. For weak sources such as PDF/text/OCR/blank carrier, `正文5号宋体` locks `eastAsia=宋体` and size, but may leave Latin/theme fonts, indentation, paragraph spacing, and line spacing to the selected bundled OOXML fallback unless the prose also specifies those properties. For native `.docx` templates, missing properties remain template inheritance rather than bundled fallback.
- Do not skip an entire XML child just because a text rule locks one attribute. If a rule locks `rFonts/@eastAsia`, the fallback may still fill `rFonts/@ascii` and `rFonts/@hAnsi`. If a rule locks `spacing/@line`, the fallback may still fill `spacing/@before` and `spacing/@after`, and vice versa.

Because `template_text_rules` outrank template XML, false positives are dangerous. Extract prose rules only from explicit formatting instructions, not from ordinary document instructions:

- Skip UI/help/instruction paragraphs such as image Alt Text instructions, `right-click`, `left-click`, `double-click`, `click on`, `Edit Alt Text`, `Title text box`, `Description text box`, and similar Word operation text.
- Do not classify a paragraph as the `title` role merely because it contains the English word `Title`; require a format-rule context such as font, size, style, alignment, or journal role wording.
- Do not infer alignment from bare direction words in English. `right` inside `right-click` is not right alignment, and `left` inside `left-click` is not left alignment.
- Accept English alignment only when it is explicit, such as `align right`, `right aligned`, `right alignment`, `right-align`, `align center`, `centered`, `justify`, or `left aligned`.
- If a suspected text rule contains no actual formatting property after parsing font/size/bold/alignment/spacing/indent, drop it rather than recording an empty or partial override.

Fallback must be granular, bilingual, and property-level:

- Detect template language as `zh` or `en`.
- Use the Chinese fallback for Chinese templates and the English fallback for English templates.
- Fill only missing properties. Never replace a whole role style with a fallback role style.
- Do not fill missing paragraph alignment (`w:jc`) through fallback. A missing `w:jc` has standard Word semantics: default left alignment. Preserve that implicit default unless a higher-priority user rule, template prose rule, template style, or real template paragraph explicitly sets alignment.
- Treat most explicit OOXML values as present even when they look falsy. Exception: `w:spacing w:line="0"` means no explicit line spacing was set, so treat the line-spacing semantic group as missing and fill both `line` and `lineRule` from fallback.
- If template prose says "正文宋体五号" but says nothing about line spacing, write body font/size from the prose rule, then inspect the actual body sample. Use the sample's line spacing only if it is trustworthy and explicit; otherwise fill missing body line spacing from the Chinese fallback.
- Chinese body fallback line spacing is 1.5 line spacing: `w:line="360" w:lineRule="auto"`.
- If template prose says "固定值 20 磅", write `w:spacing w:line="400" w:lineRule="exact"`.
- If template prose says "1.5 倍行距", write `w:spacing w:line="360" w:lineRule="auto"`.
- If template XML has `w:spacing w:line="0"` and no higher-priority text/user rule explicitly sets line spacing, replace that implicit default with the language fallback line-spacing pair, such as `w:line="240" w:lineRule="auto"` for explicit single line. Do not preserve stale `lineRule="atLeast"` or `lineRule="exact"` when `line="0"` triggered fallback; otherwise Word displays "at least 12 pt" instead of single spacing. Keep other zero values like `before="0"` and `after="0"` as real values.

Few-shot:

| Template evidence | Expected `style_spec.json` behavior |
|---|---|
| Text says `正文宋体五号`; style XML has `w:spacing w:line="0" w:lineRule="atLeast"` | Body keeps 宋体/五号 from text rule, treats the line-spacing group as missing, and writes zh body fallback `line="360" lineRule="auto"`. |
| Text says `文章正文是5号宋体`; source paragraph is only that hint and has single spacing | Body keeps 宋体/五号 from text rule, ignores the hint paragraph's spacing, and writes zh body fallback `line="360" lineRule="auto"`. |
| Real body sample has explicit `w:spacing w:line="300" w:lineRule="auto"` | Body preserves `line="300" lineRule="auto"` and does not overwrite it with fallback. |
| Springer-style `Normal` has `w:jc w:val="both"` and body sample text is short or `pStyle=None` | Body materializes `Normal + docDefaults + paragraph direct pPr`, preserving `jc="both"` instead of falling back to default left alignment. |
| Placeholder body text says `Enter text here.` in a body-like paragraph | Treat it as a valid body formatting sample if it has no explicit format-rule/operation-instruction wording. |
| Text says `正文宋体五号`; style XML has no `spacing` | Body keeps 宋体/五号, then fills only missing spacing from zh fallback. |
| Text says `文章正文是5号宋体`; demo body paragraph uses a different font/theme | Body writes `eastAsia=宋体`, removes `eastAsiaTheme`, writes `sz/szCs=21`, and does not let the demo paragraph's same-channel font/size override it. |
| Text says `body Times New Roman 12 pt`; style XML has no alignment | Body keeps Times New Roman/12 pt and preserves missing `w:jc` as Word default left alignment; fallback must not add alignment. |
| ACM `Titledocument`, `Authors`, or `Affiliation` style has no `w:jc` | Preserve missing `w:jc`; do not add `center` just because those roles often look centered in other templates. |
| Text says `正文固定值 20 磅` | Body writes fixed 20 pt line spacing regardless of fallback. |
| Text says `参考文献悬挂缩进2字符` | `reference_item` writes `w:left="420" w:hanging="420"` from the text rule. |
| Blank carrier DOCX has `Normal` single spacing `line="240"` and external Chinese rules are otherwise incomplete | Route as `blank_carrier_template`; body writes Chinese fallback `line="360"`, title/heading styles write their fallback paragraph spacing, and target `Normal/docDefaults` are rewritten to the body fallback baseline. |

Apply locked text rules to both `style/rPr` and nested `style/pPr/rPr`. Word may consult either location, so leaving old sizes or fonts in `pPr/rPr` can make the displayed result look like the old template/style even when `style/rPr` is correct.

Template hint colors must be normalized at the raw XML level:

- Instruction templates often use red, orange, or blue text for hints such as `点击在线查询分类号`, `分号`, `突出体现文章的新意`, or parenthetical reference-format labels.
- These colors are not necessarily journal-required formatting. Do not let them silently become official role styles for `metadata`, `abstract`, `keywords`, `citation_format`, `reference_item`, or `body`.
- Cleaning only structured fields such as `font.color` is insufficient. The authoritative `style_xml`, `pPr_xml`, and `rPr_xml` must also remove or normalize `<w:color>` nodes, otherwise Word will still display the inherited hint color.

---

> 因文档体量拆分：后续内容见 `style-routing-5.md`。
