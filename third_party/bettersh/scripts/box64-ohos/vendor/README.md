# vendor/ —— 两个第三方库的上游快照（**仅供溯源与许可**）

构建**不读这个目录**。它只是留着说明 `files/src/musl_fts.c`、
`files/src/include/fts.h`、`files/src/musl_obstack.c`、`files/src/include/obstack.h`
的来源（这四个文件是逐字拷贝，行数一一对应：1255/155/378/538）。

| 目录 | 上游 | 钉的 commit | 许可（按源文件头，分发前请自行确认） |
|---|---|---|---|
| `musl-fts/` | https://github.com/void-linux/musl-fts | `0bde52df588e8969879a2cae51c3a4774ec62472`（v1.2.7, 2017-01-13） | BSD 3-clause（`fts.c` 头是 NetBSD/UC Regents 的 BSD 文本） |
| `musl-obstack/` | https://github.com/void-linux/musl-obstack | `362629706cb24a68b5e02876f0250df95e2e3f8d`（2023-10-21） | GNU 系：仓库 `COPYING` 写 GPL-2.0-or-later，而 `obstack.c` 文件头声明 **LGPL-2.1-or-later**（来自 glibc） |

为什么要 vendored 而不是构建时 `git clone`：旧脚本（`scripts/patch_box64.sh`）在打补丁
阶段现 clone 到 `build/box64/thirdparty/`，属于**构建期联网**；现在内容固化进 `files/`，
打完 box64 本体之后的整条链路离线可复现。

> `obstack.c`/`obstack.h` 会被编进 `libbox64.so`（box64 本体是 MIT），许可不是同一条 ——
> 真要对外分发 `libbox64.so` 时这一条值得单独过一遍。
