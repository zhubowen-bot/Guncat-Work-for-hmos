Low-confidence visual evidence is column-count only. For PDF, converted DOC/DOT preview, OCR/image visual hints, screenshots, and blank carriers, do not emit or trust visual role, alignment, `size`, `bold`, `indent`, `spacing`, tabs, colors, underlines, or run-level properties. For website links, do not infer column count from visual hints, publisher brands, production article pages, or common journal practice; use explicit website/user text or default to single-column. Explicit prose/user text rules still win; everything else must come from fallback.

If visual/geometry screening can reliably determine single-column or double-column layout, write only `_meta.fallback_columns`/`source_column_detection`. Long front-matter lines are often misread as justified, so non-DOCX visual-only alignment must be dropped rather than normalized into `center`.

For weak-source fallback, abstract and keyword content should default to five-point size (`w:sz=21`). The labels `摘要`, `关键词`, `Abstract`, and `Key words`/`Keywords` are run-level bold markers only; the following abstract/keyword content must remain non-bold. Recognize label variants including `[Abstract]`, `【Abstract】`, `ABSTRACT`, `[摘要]`, `[Keywords]`, and `KEY WORDS` with or without a colon. Do not encode whole-style bold on `abstract`, `keywords`, `english_abstract`, or `english_keywords` just to bold the label.

Apply this same restriction to all non-DOCX visual routes, not only PDF. If image/OCR/website/rendered-preview rules JSON contains role alignment, `size`, `fonts`, `bold`, `italic`, `color`, `underline`, `indent`, `spacing`, `tabs`, or similar visual-format fields, sanitize them before merging with template text rules. Only explicit user/prose rules may keep style fields.

For clean publisher templates with explicit Word styles, canonical `styleId` mapping is mandatory and overrides heuristic paragraph guessing:

| Role | Preferred template style IDs |
|---|---|
| `title` | `IOPTitle`, `Titledocument`, `TitleDocument`, `Title` |
| `author` | `Authors`, `Author` |
| `affiliation` | `Affiliation`, `AdressLines`, `AddressLines`, `Affiliations` |
| `abstract` | `Abstract` |
| `keywords` | `KeyWords`, `Keywords`, `Keyword`, `KeyWord` |
| `heading1` | `IOPH1`, then `Head1`, then `Heading1` |
| `heading2` | `IOPH2`, then `Head2`, then `Heading2` |
| `heading3` | `IOPH3`, then `Head3`, then `Heading3` |
| `body` | `Para`, then `BodyText` variants, then `Normal` |
| `figure_caption` | `FigureCaption`, `CaptionFigure`, then `Caption` |
| `table_caption` | `TableCaption`, `CaptionTable`, `TableTitle`, then `Caption` |
| `references_heading` | `ReferenceHead`, `ACMRefHead`, then `Heading1` |
| `reference_item` | `IOPRefs`, `Bibentry`, `BibEntry`, `References`, `Bibliography` |
| `equation` | `DisplayFormula`, `Equation`, `Formula` |
| `english_title` | `EnglishTitle`, `TitleEnglish` |
| `english_author` | `EnglishAuthors`, `AuthorsEnglish` |
| `english_affiliation` | `EnglishAffiliation`, `AffiliationEnglish` |
| `english_abstract` | `EnglishAbstract`, `AbstractEnglish` |
| `english_keywords` | `EnglishKeywords`, `KeywordsEnglish` |
| `metadata` | `Metadata` |
| `citation_format` | `CitationFormat` |

Heuristics may fill missing roles only after this canonical pass, but canonical styles must be usage-validated. A style that merely exists in `styles.xml` is only a candidate; it is authoritative only when real template paragraphs for that role actually use that `pStyle`, or when the role is a publisher-defined non-body role with no better paragraph evidence. ACM, IOP, and other publisher templates often keep visible body/head/reference formatting in custom style IDs such as `Para`, `Head1`, `IOPH1`, `FigureCaption`, `ReferenceHead`, `IOPRefs`, and `Bibentry`; these must beat generic Word defaults such as `Normal`, `Heading1`, and `Heading2`. If a normal body paragraph has no explicit `pStyle`, build the role from `docDefaults + Normal` plus that paragraph's direct `pPr/rPr`; never emit an empty body fallback.

For unknown journal templates, do not rely only on the fixed canonical table. Also inspect every template style's `styleId`, visible `w:name`, real paragraph usage, and expanded `basedOn` chain. Generic semantic style names such as `ArticleTitle`, `PaperTitle`, `ManuscriptTitle`, `HeadingLevel1`, `SectionHead2`, `FigCaption`, `TableCaption`, `BibliographyEntry`, `ReferenceItem`, or `Refs` may define the role even when the style ID is not in the known-publisher list. This semantic fallback must run before content-only paragraph guessing, but it must avoid collisions: `TableTitle/FigureTitle` are captions, `ReferenceHead` is the references heading, and `Subtitle/RunningTitle/ShortTitle` are not the main title.

Each role entry must include:

- role id and generated `style_id`, such as `title -> 1title`, `body -> 9body`;
- display name and style type;
- structured font summary: CJK/Latin/complex fonts, size, bold/italic, color, underline, emphasis mark, strike, superscript/subscript, hidden text, character spacing, position, scaling, kerning, shading, border, language;
- structured paragraph summary: alignment, outline level, text direction, indentation, first-line/hanging indent, spacing before/after, line spacing, grid flags, keep/page-break controls, widow control, tabs, numbering, borders, shading, frame, text alignment;
- locked text rule that overrode template XML, if any;
- source sample and source style id for audit;
- raw `pPr_xml`, `rPr_xml`, and full `style_xml`.

When a canonical `styleId` is selected, the audit sample/signature must come from a real template paragraph using that same `pStyle` whenever possible. Do not borrow samples from another detected paragraph of the same role, and do not use table style-inventory rows as role samples. Publisher-specific canonical IDs such as IOP `IOPTitle`, `IOPH1`, `IOPH2`, `IOPH3`, and `IOPRefs` must be treated as explicit role evidence before generic Word styles; record the selected `source_style_id` and its `basedOn` chain in `style_spec.json`.

Run-level direct formatting must be promoted to role styles only through representative coverage, never by the first formatted run:

- Paragraph-level `pPr/rPr` is authoritative for paragraph mark character style. If it exists, use it before inspecting child runs.
- If paragraph-level `pPr/rPr` is absent, infer representative run formatting by text-length coverage across all meaningful text runs. Font, size, language, and character spacing may be promoted only when the same property covers a strong majority of the paragraph text.
- Local emphasis properties such as italic, bold, underline, color, highlight, shading, superscript/subscript, strike, emphasis marks, hidden text, caps, and character position need an even stronger near-whole-paragraph majority before promotion.
- A single formatted run, or the first formatted run, is not representative when surrounding text has no matching direct formatting. This prevents reference examples, captions, metadata, and body paragraphs from turning entirely italic/bold/colored because one journal name, volume number, marker, or hint phrase is formatted locally.
- Run-level superscript markers remain a separate marker pass. They must not become whole-paragraph `style/rPr` or nested `style/pPr/rPr`.

Few-shot:

| Template evidence | Expected behavior |
|---|---|
| Reference item text has normal authors/year, italic journal name, bold volume, then normal pages | `reference_item` keeps the paragraph/font/size evidence but does not write whole-style italic or bold. |
| Figure caption has only `Fig. 1` bold and the caption text normal | `figure_caption` does not become entirely bold. |
| A full title paragraph is entirely bold/italic in nearly every run | The emphasis may be promoted because it is representative whole-role formatting. |
| Author line has superscript affiliation numbers after names | Do not promote `vertAlign=superscript` to `author`; apply superscript only to detected marker runs later. |

Role-source content consistency is mandatory and must be generic, not a publisher-specific blacklist:

- A paragraph can define a core role style only when its text, position, and surrounding context are compatible with that role. Being early in the template, short, large, bold, or assigned a custom Word style is insufficient.
- Publisher metadata, date/DOI/copyright/received/revised/accepted notes, footnotes, correspondence notes, UI/operation instructions, and placeholder/rule prose must not become the source sample for `title`, `author`, `affiliation`, `abstract`, `keywords`, `body`, headings, captions, or references.
- Such paragraphs may map to `metadata` only when they are real front-matter metadata; footnotes and operation/help text should usually be skipped as style sources unless the target has an explicit matching role.
- If a style's first used paragraph is metadata/instruction text, do not infer the style's semantic role from position alone. Continue scanning for a content-consistent paragraph using the same role, or fall back through the source-aware priority chain.
- Do not fix this with hardcoded style-name blacklists. Use content features such as date/DOI/copyright/received/revised/accepted markers, footnote/correspondence language, UI operation words, formatting-rule wording, and role-zone context.

Few-shot:

| Template evidence | Expected behavior |
|---|---|
| Early paragraph says `Date of publication...` and uses a custom style | Treat as metadata/source-noise, not title/body, even if it is the first visible paragraph. |
| Early paragraph says `Digital Object Identifier...` or contains `doi:10...` | Do not use it as author/body/title style evidence; at most map as metadata. |
| A footnote/copyright/correspondence note appears before the real paper title | Skip it as a core role source; keep scanning for the real title/author/body samples. |
| A custom style's first used paragraph is a Word operation instruction such as Alt Text guidance | Do not use that paragraph's `pPr/rPr` as the body or caption style. |
| Real paper title appears after several publisher metadata rows | The real title paragraph, not the first visible short paragraph, supplies `title` evidence. |

Body source selection has an extra guardrail:

- Do not select `BodyText`, `BodyTextIndent`, `Para`, or any body canonical style just because it exists in `styles.xml`.
- First verify that actual body-like template paragraphs use that `pStyle`.
- If the template has many real body paragraphs with `pStyle=None`, use their `Normal/docDefaults + direct paragraph/run formatting` as the body style source even when an unused `BodyText` style exists.
- Record this as `source_route=detected_paragraph`, not `used_canonical_style_id`.
- This avoids Springer-style templates where headings/captions use named custom styles but real body text remains Normal, while an unused `BodyText` style in `styles.xml` has different font/size/spacing.
- When a real body paragraph has no explicit `pStyle`, materialize the template default paragraph style, usually `Normal`, together with `docDefaults` before applying the paragraph's direct formatting. Do not treat `pStyle=None` as `docDefaults` only; otherwise properties stored on `Normal`, such as `w:jc w:val="both"`, disappear.
- Do not use a hard minimum text length such as 80 characters to decide whether a body source is trustworthy. Short placeholder body samples such as `Enter text here.`, `Sample body text.`, or a short real paragraph may still carry the correct `Normal`/`BodyText` formatting.

---

> 因文档体量拆分：后续内容见 `style-routing-3.md`。
