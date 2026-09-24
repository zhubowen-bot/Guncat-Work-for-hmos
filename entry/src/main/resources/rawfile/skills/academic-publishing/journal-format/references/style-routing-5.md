- Treat common hint colors such as `FF0000`, `FF6600`, `0000FF`, `0070C0`, and `00B0F0` as suspicious in instruction-heavy templates. Remove them from generated role styles unless an explicit user rule or clear prose rule says the final submission style requires that color.
- Record removed hint colors in the internal format report so the final user note can call out metadata/abstract/keywords as visual-confirmation areas.

Example `rules.json`:

```json
{
  "roles": {
    "body": {
      "size": "21",
      "fonts": {
        "eastAsia": "宋体",
        "ascii": "Times New Roman",
        "hAnsi": "Times New Roman"
      },
      "align": "both"
    },
    "title": {
      "size": "32",
      "fonts": {
        "eastAsia": "黑体"
      },
      "bold": true,
      "align": "center"
    }
  }
}
```

`size` uses Word half-points, so 10.5 pt is `21`, 12 pt is `24`, and 16 pt is `32`.

## Direct Formatting Cleanup

After role binding, clean direct formatting that can override the assigned style:

- paragraph-level overrides: alignment, spacing, indentation, tabs, paragraph `rPr`, keep settings, outline level;
- run-level overrides: `rFonts`, `sz`, `szCs`, bold, italic, color, underline, highlight, shading, spacing, position, language.

This is required because Word display priority often lets run/paragraph direct formatting beat `styles.xml`. If this cleanup is skipped, fonts and sizes may still look like the original document even after styles were changed.

After cleanup, run format-conformance QA before reference numbering, table formatting, equation tabs, or superscript passes. It must compare `role_map.json` paragraph bindings against the actual target `w:pStyle`, and compare installed generated role styles against authoritative `style_spec.json` raw `pPr_xml`/`rPr_xml`. Deterministic mismatches are repair work, not final-note material: rebind wrong paragraphs, remove remaining direct overrides, and clear stale generated-style font/size/color/bold/italic/spacing/indent/alignment properties that are absent from the spec but could still override display. Only unresolved style IDs, ambiguous role mapping, or evidence-uncertain formatting should reach the user as visual-confirmation notes.

The cleanup only removes formatting properties from paragraph/run containers. It must not delete text nodes, drawings, OMML math, OLE objects, embedded media, tables, or relationship parts.


---

> 本文件为拆分后的续篇，请按文件名序号与上篇连续阅读。
