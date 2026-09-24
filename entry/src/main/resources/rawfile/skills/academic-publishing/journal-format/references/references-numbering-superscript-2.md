8. If the template has no author/affiliation superscript evidence, do not create author/affiliation superscripts.
9. If the template has no reference-citation superscript evidence, do not change target body reference citations at all. Preserve the original target citation formatting and mention this in the user-facing notes.
10. If the target author line has no marker text, do nothing. Never turn an entire author or affiliation line into superscript.

Few-shot:

| Template evidence | Target text | Expected behavior |
|---|---|---|
| Author has `Alice` + superscript `1` | `Alice1, Bob2` | Split text runs and superscript only `1` and `2` if markers are in the map. |
| Affiliation has superscript `1` | `University1` | Superscript only the trailing `1`; keep `University` normal. |
| Template has no superscript markers | `Alice1` | Leave target unchanged. |
| Body citation marker is superscript `[1]` | `method[1]` | Superscript only `[1]`; do not superscript every digit in body text. |
| Template only has author superscript `1`, `2`, `3` and no body citation superscript | `method[1] [2] [4]` | Leave all target body citations unchanged and warn the user that reference-citation superscript format was not extracted. |


---

> 本文件为拆分后的续篇，请按文件名序号与上篇连续阅读。
