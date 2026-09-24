- Keep the false-positive guard: short formatting hints and operation instructions are not body formatting samples. Text such as `正文宋体五号`, `文章正文是5号宋体`, `right-click ... Edit Alt Text`, `Use single tab stops...`, or other Word operation/help text must not contribute paragraph `jc`, `spacing`, `ind`, or tab settings to the body style.
- Before inheriting body paragraph spacing from a detected source paragraph, decide whether the source paragraph is a real body sample or only a format hint. A paragraph like `文章正文是5号宋体` can provide font/size text rules, but its paragraph spacing is not trustworthy.
- If a real body sample has explicit spacing such as `line="300" lineRule="auto"` or exact fixed spacing, preserve it. If the source has `line="0"` or no spacing, treat line spacing as unspecified and use the granular fallback.

Generated style IDs must use this readable sequence:

| Role | Generated style ID |
|---|---|
| `title` | `1title` |
| `author` | `2author` |
| `affiliation` | `3affiliation` |
| `abstract` | `4abstract` |
| `keywords` | `5keywords` |
| `heading1` | `6heading1` |
| `heading2` | `7heading2` |
| `heading3` | `8heading3` |
| `body` | `9body` |
| `figure_caption` | `10figurecaption` |
| `table_caption` | `11tablecaption` |
| `references_heading` | `12referencesheading` |
| `reference_item` | `13referenceitem` |
| `equation` | `14equation` |
| `english_title` | `15englishtitle` |
| `english_author` | `16englishauthor` |
| `english_affiliation` | `17englishaffiliation` |
| `english_abstract` | `18englishabstract` |
| `english_keywords` | `19englishkeywords` |
| `metadata` | `20metadata` |
| `citation_format` | `21citationformat` |

The raw XML fields are authoritative. The structured fields are for audit, model routing, and sanity checks. If the structured parser misses a Word feature, the full `style_xml` must still carry it forward.

The target stage should:

1. Load the style spec.
2. Identify target paragraphs as title, abstract, keywords, body, heading levels, figure captions, table captions, references, display equations, etc.
3. Write `role_map.json` when requested.
4. Audit role-map warnings before style application. If a paragraph such as classification number, English title, affiliation, figure/table prose, or references is ambiguous, fix the role mapping rather than changing the style spec.
5. Audit style-spec warnings before installing styles. If body uses an unverified canonical route such as unused `BodyText`, regenerate or edit `style_spec.json`.
6. Re-run with `--role-map-in role_map.json` to lock the reviewed target role mapping.
7. Create/replace target role styles from `style_xml`.
8. Set each target paragraph `w:pStyle` to the role style. If the exact role style is unavailable, first use the cross-language equivalent role (`english_title -> title`, `english_author -> author`, `english_affiliation -> affiliation`, `english_abstract -> abstract`, `english_keywords -> keywords`, and the reverse pairs). Fall back to `body` only after exact and cross-language role styles are both unavailable, and report that as a visual-risk item.
9. Clean target direct formatting so it cannot override the spec.

`style_spec.json` and `role_map.json` are both reusable bridge files. `style_spec.json` answers "what should each role look like"; `role_map.json` answers "which target paragraph is which role." They may be emitted for audit, edited, and then supplied back with `--style-spec-in` and `--role-map-in` for deterministic reruns.

Locked bridge formatting means both inputs are supplied:

```bash
（原脚本命令，本项目改用 docx 技能） \
  -t template.docx -i target.docx -o output.docx \
  --style-spec-in style_spec.json \
  --role-map-in role_map.json
```

In this mode, the script must not auto-classify missing paragraphs. Every non-empty target paragraph must appear in `role_map.json`, every role in `role_map.json` must exist in `style_spec.json`, and the corresponding `style_xml` from `style_spec.json` must be installed before paragraph binding. Missing indexes or unknown roles are fatal errors.

Even in locked bridge mode, run the style-spec preflight before installation. A reviewed `style_spec.json` is allowed to override heuristics, but it must not silently carry known-invalid body routes such as `source_route=unused_canonical_style_id` for `BodyText` when real body paragraphs use `pStyle=None`.

## Style Routing

Default route is spec-backed role binding:

1. The template is scanned for representative paragraphs: title, author, affiliation, abstract, keywords, headings, body, figure captions, table captions, references heading, and reference items.
2. The matching template style/signature is normalized into `style_spec.json` with stable generated style IDs such as `1title`, `6heading1`, and `9body`.
3. Target paragraphs are classified by content, then their `w:pStyle` is set to the generated role style.
4. The target's original `w:name` values are not trusted as the bridge.

When building role styles, first expand the template `basedOn` chain from base to leaf and materialize the effective `pPr/rPr`. Do not simply remove `basedOn` and keep only the leaf style, or the visible font/size/spacing may become much worse. Template paragraph direct formatting may be merged as a patch, but it must not replace the whole effective `pPr/rPr`.

After expanding inheritance, scrub role-incompatible inherited properties:

- Author and affiliation roles must not carry `vertAlign=superscript` at `style/rPr` or `style/pPr/rPr`; superscript belongs to marker runs only.
- Body, author, affiliation, abstract, keywords, metadata, citation, caption, and reference-item roles must not inherit title-only `outlineLvl`, `keepNext`, `keepLines`, or `pageBreakBefore`.
- `w:b w:val="0"` inherited into author/affiliation/body should be removed instead of allowed to mask real bold inherited from the intended source.
- Audit raw `style_xml`, not only structured summaries, because inherited pollution may be invisible in summarized fields.

Respect theme fonts. If a template style uses `asciiTheme`, `hAnsiTheme`, `eastAsiaTheme`, or `cstheme`, do not add the corresponding concrete `ascii`, `hAnsi`, `eastAsia`, or `cs` fallback font unless a higher-priority user/prose rule explicitly requires it. Concrete font attributes can override Calibri/Cambria theme schemes in Word.

For instruction-heavy templates, filter front-matter and rule text before choosing style sources. Do not use paragraphs like `WORD模板`, `文章编号`, `引用格式`, `中图分类号`, format explanation text, table cells, or figure/table instruction text as body/title/author style sources. Body source should come from real body-like paragraphs after the body rule is encountered; otherwise let the text rule/fallback define the body style.

For English publisher templates, do not map `Heading1` titled `Abstract` to the abstract body style. Abstract body should use a body/normal style unless the template provides a dedicated abstract-body style.

Chinese bilingual instruction templates need expanded front-matter roles:

- Use separate roles for Chinese and English front matter: `title`, `author`, `affiliation`, `abstract`, `keywords`, plus `english_title`, `english_author`, `english_affiliation`, `english_abstract`, and `english_keywords`.
- Treat `文章编号`, `中图分类号`, and `文献标志码` as `metadata`, even when they visually use the same font/size as body.
- Treat `引用格式` and its immediate English continuation line as `citation_format`.
- Explicit labels must outrank broad author/title/affiliation heuristics. Paragraphs beginning with `摘要`, `摘  要`, or `Abstract` must map to abstract roles before author/heading/title checks. Paragraphs beginning with `关键词`, `关键字`, `Key words`, or `Keywords` must map to keyword roles before author/heading/title checks.
- Detect the marker `英文题名、作者、单位、摘要、关键词参考下面模式` as a state transition, not as a role source. The following paragraphs should be classified in order as English title, English author, English affiliation, English abstract, and English keywords.
- Treat `WORD模板`, `姓全部大写，名首字母大写`, and similar explanation-only markers as non-role text; they should not be mapped to title/body or used as style sources.
- Do not collapse these roles into body just because they use body-like direct formatting. A role can use body-like formatting while still needing separate role identity for target mapping.

Single-language templates need cross-language role equivalents:

- If a pure English target maps its title to `english_title` but the template only defines `title` through `Titledocument`, use the `title` style as the equivalent source. Do not fall back to `body` or `Para`.
- If a pure Chinese target maps front matter to `title`, `author`, or `abstract` but the template only defines English-prefixed roles, use the corresponding English-prefixed style before body fallback.
- The equivalent pairs are `title <-> english_title`, `author <-> english_author`, `affiliation <-> english_affiliation`, `abstract <-> english_abstract`, and `keywords <-> english_keywords`.
- Treat an exact front-matter role source that uses body-like styles such as `Para`, `BodyText`, `BodyTextIndent`, or `Normal` as weak evidence. If the cross-language equivalent role has a stronger non-body style such as `Titledocument`, `Authors`, `Affiliation`, `Abstract`, or `KeyWords`, use the stronger equivalent role instead of the weak exact source.
- Record cross-language role usage in the internal format report. It is acceptable and safer than body fallback, but the final note should mention it when relevant.
- Treat direct body fallback for any title/author/affiliation/abstract/keywords role as a warning-level risk that needs visual confirmation.

Reference routing is stateful:

- `参考文献：`, `参考文献`, `References`, `REFERENCE`, and `REFERENCES` start the reference zone.
- Inside the reference zone, reference-item detection must run before title/heading detection. A paragraph such as `[1] 作者1．文章题名[J]...` is a reference item even though it contains `文章题名`.
- In Chinese instruction templates, skip reference-format explanation rows such as `期刊与书(论文集)著录格式为:`, `作者1`, `著者1`, `起始页-终止页`, and `不要缺少...` when selecting the `reference_item` style source. Prefer real examples after `例：`.
- Numberless continuation lines inside the reference zone, especially English continuation lines containing journal names, years, `[J]`, `[C]`, `[EB/OL]`, etc., should still map to `reference_item`.

Figure/table caption routing must be anchored:

- Match `图1 ...`, `Fig.1 ...`, `Figure 1 ...`, `表1 ...`, `Tab.1 ...`, and `Table 1 ...` as captions.
- Do not map prose such as `图7的混淆矩阵...`, `图2(b)所示...`, or `表1可以看出...` as captions.

Front-matter routing must not turn metadata into affiliation:

- `文章编号`, `中图分类号`, and `文献标志码` must map to `metadata`; `引用格式` must map to `citation_format`. They should never map to author/affiliation or generic body merely because their visual formatting resembles body text.
- `摘要` and `关键词` paragraphs must not map to author/affiliation/title merely because they are short, bold, centered, or contain punctuation/markers. If the preflight sees an explicit abstract/keyword/metadata label mapped to another role, warn before style injection.
- Email/contact-only lines in the front matter must map to affiliation/contact metadata, not title, author, or heading. A line such as `jizhang@tongji.edu.cn` is never an English title or author just because it is short and appears before the abstract.
- A short English paper title before `Abstract` should map to `title`, not affiliation, unless it contains organization words such as `University`, `Institute`, `College`, `School`, `Laboratory`, or `Department`.

---

> 因文档体量拆分：后续内容见 `style-routing-4.md`。
