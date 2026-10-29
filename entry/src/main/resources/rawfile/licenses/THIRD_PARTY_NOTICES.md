# 第三方组件与许可声明

> 本文档是本仓库（Guncat Work，Apache-2.0）随附的第三方组件声明。
> `shell` 工具（IEC 原生执行核）与 `run_python`（原生 CPython）涉及的组件最多，集中在第 1、2 节。
> 完整许可原文见 [`LICENSES/`](LICENSES/)，同一份声明与原文也打包进 HAP 的 `resources/rawfile/licenses/`。

---

## 1. Shell 工具（IEC 原生执行核）

`shell` 工具不再包含虚拟机。命令都是随包的 HarmonyOS 原生 `.so`，由 IEC 的 exec 服务
`fork` 后直接运行；下面每一项都以独立 `.so` 分发。

### 1.1 IEC — MIT

**用途**：`third_party/bettersh/iec`（exec/tty 服务、loader、fs/exec/tty shim、NAPI）。
`shell` 工具的全部进程创建、管道、超时、作业级取消都靠它。

| 项 | 值 |
| --- | --- |
| 上游 | <https://github.com/panedioic/iec>，commit `b1b89fa`；同作者的 BetterSH 在 `27d2440` |
| 我们的改动 | 新增 exec 会话 API（`exec_session.*`）、NAPI 导出、作业级整树终止、NCP 失败回落 fork、启动失败原因回传；逐条记录在 [`third_party/bettersh/VENDOR.md`](third_party/bettersh/VENDOR.md) |
| 许可 | MIT，Copyright (c) Yiyan。原文见 [`LICENSES/IEC-MIT.txt`](LICENSES/IEC-MIT.txt) 与 [`LICENSES/BetterSH-MIT.txt`](LICENSES/BetterSH-MIT.txt) |

### 1.2 mksh — MirOS licence

**用途**：`libmksh.so`，`sh` / `mksh`（`main`）。上游为 OpenHarmony 的
[third_party_mksh](https://gitcode.com/openharmony/third_party_mksh) 镜像。
原文见 [`LICENSES/mksh-MirOS.txt`](LICENSES/mksh-MirOS.txt)。

### 1.3 toybox — 0BSD

**用途**：`libtoybox.so`，70+ 常用命令（`ls/cat/grep/sed/awk/find/xargs/tar/gzip/…`），
入口 `bsh_toybox_main`，按 `argv[0]` 分发。上游 <https://github.com/landley/toybox>。
原文见 [`LICENSES/toybox-0BSD.txt`](LICENSES/toybox-0BSD.txt)。

### 1.4 libarchive — BSD-2-Clause

**用途**：`libbsdtar.so` / `libbsdunzip.so` / `libbsdcpio.so` / `libzipcmd.so`
（`tar`/`unzip`/`cpio`/`zip`），静态链接 zlib。上游 <https://libarchive.org>（3.7.7），
构建脚本 `iec/scripts/build_libarchive.sh`。

### 1.5 git — GPL-2.0

**用途**：`libgit.so`（`git`，入口 `iec_git_main`）与 `libgit-remote-http.so`
（`git-remote-http(s)`，入口 `iec_git_remote_http_main`）。静态链接 zlib / OpenSSL /
PCRE2 / libcurl。

| 项 | 值 |
| --- | --- |
| 版本 / 源码 | git 2.56.0，<https://github.com/git/git> tag `v2.56.0` |
| 构建 | `iec/scripts/optional/build_git.sh`（`-fPIC` 重编、`main` 改名、链 IEC shim） |
| 许可 | GPL-2.0，全文见 [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt)。二进制以独立 `.so` 分发，对应源码为上述 tag，构建脚本随仓库提供 |

### 1.6 dropbear — MIT

**用途**：`libdropbear.so`，`ssh` / `scp` / `ssh-keygen` / `dropbearkey` 等（按 `argv[0]` 分发）。
上游 <https://github.com/mkj/dropbear>。原文见 [`LICENSES/dropbear-MIT.txt`](LICENSES/dropbear-MIT.txt)。

### 1.7 Node.js — MIT

**用途**：`libnode.so`，`node` / `npm` / `npx`。上游 <https://nodejs.org>（v22.19.0），
构建脚本 `iec/scripts/optional/build_node.sh`（静态 ICU、OpenSSL、zlib）。

### 1.8 jq 1.7.1 — MIT

**用途**：`libjqcmd.so`，`jq`（入口 `iec_jq_main`）。上游 <https://github.com/jqlang/jq>
tag `jq-1.7.1`，构建脚本 `iec/scripts/optional/build_jq.sh`，正则引擎静态链接 oniguruma。
原文见 [`LICENSES/jq-MIT.txt`](LICENSES/jq-MIT.txt)。

### 1.9 oniguruma 6.9.9 — BSD-2-Clause

**用途**：jq 的正则引擎，静态链接进 `libjqcmd.so`（不单独随包）。上游
<https://github.com/kkos/oniguruma> tag `v6.9.9`。
原文见 [`LICENSES/oniguruma-BSD-2-Clause.txt`](LICENSES/oniguruma-BSD-2-Clause.txt)。

### 1.10 curl 8.22.0 — curl licence

**用途**：`libcurlcmd.so`，`curl`（入口 `iec_curl_main`），静态链接 OpenSSL 与 zlib；
git 的 https 传输（`libgit-remote-http.so`）也静态链接同一份 libcurl。
上游 <https://curl.se/download/curl-8.22.0.tar.gz>，构建脚本
`iec/scripts/optional/build_curl.sh` 与 `build_curlcmd.sh`。
原文见 [`LICENSES/curl-LICENSE.txt`](LICENSES/curl-LICENSE.txt)。

### 1.11 GNU bc 1.07.1 — GPL-2.0-or-later

**用途**：`libbccmd.so`，`bc`（入口 `iec_bc_main`），未启用 readline。上游
<https://ftp.gnu.org/gnu/bc/bc-1.07.1.tar.gz>，构建脚本
`iec/scripts/optional/build_bc.sh`。

> **GPL 声明**：bc 以 GPL-2.0-or-later 分发。本项目**未修改** bc 源码，只做交叉编译
> 与入口改名；二进制以独立 `.so`（`libbccmd.so`）随包，不与主程序静态合并。
> 对应源码为上游客 tarball 加本仓库的构建脚本，二者均可公开获取。
> GPL-2.0 全文见 [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt)。

### 1.12 OpenSSH sftp 9.9p2 — BSD（ISC 风格）

**用途**：`libsftpcmd.so`，`sftp`（入口 `iec_sftp_main`），静态链接 OpenSSL 与 zlib；
只取 portable 发行版里的 sftp 客户端，不含 sshd/ssh 服务端。
上游 <https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p2.tar.gz>，
构建脚本 `iec/scripts/optional/build_sftp.sh`。
原文见 [`LICENSES/openssh-BSD.txt`](LICENSES/openssh-BSD.txt)。

### 1.13 自写补充命令：nc / hexdump / diff

- `nc`（`libnc.so`）与 `hexdump`（`libhexdump.so`）是**本项目自己编写**的命令，
  源码在 `iec/scripts/optional/cmd_nc.c`、`cmd_hexdump.c`，按主仓库的 Apache-2.0 分发；
- `diff`（`libdiff.so`）是同样自写的薄包装，实际比较由随包的 git（GPL-2.0，见 §1.5）
  完成。

### 1.14 上述二进制的静态依赖

| 组件 | 版本 | 许可 | 被谁使用 |
| --- | --- | --- | --- |
| zlib | 1.3.1 | zlib License | libarchive / git / node / curl / sftp |
| OpenSSL | 3.0.22 | Apache-2.0（原文 [`LICENSES/Apache-2.0-OpenSSL.txt`](LICENSES/Apache-2.0-OpenSSL.txt)） | git（https）/ node / curl / sftp |
| PCRE2 | 10.x | BSD-3-Clause | git |
| libcurl | 8.22.0 | curl licence（MIT 风格） | git（https）/ curl |
| ICU | 随 Node 源码 | Unicode-3.0 | node |
| oniguruma | 6.9.9 | BSD-2-Clause | jq |

---

## 2. 原生 Python（`run_python` 与 shell 里的 `python3`）

### 2.1 CPython 3.12 — PSF-2.0

**用途**：`entry/libs/arm64-v8a/libpython3.12.so`、`rawfile/python/python312.zip`、
`rawfile/python/lib-dynload/*.so`（51 个 C 扩展）。以动态库形式在应用进程内加载，不经虚拟机。

| 项 | 值 |
| --- | --- |
| 版本 | CPython 3.12.15（<https://www.python.org/downloads/release/python-31215/>） |
| 许可 | Python Software Foundation License 2.0（PSF-2.0）；全文见 [`LICENSES/CPython-LICENSE.txt`](LICENSES/CPython-LICENSE.txt) |
| 我们的改动 | **未改 CPython 源码**；只做交叉编译（`--host=aarch64-linux-gnu` + OHOS clang、`--enable-shared`、裁剪扩展模块）与 strip。脚本见 [`tooling/python/build-cpython-ohos.sh`](tooling/python/build-cpython-ohos.sh) |
| 源码获取 | 上述官方 tarball + 本仓库脚本即可复现同一产物 |

CPython 内静态链接/随包分发的第三方代码（均由 CPython 自身的 LICENSE 覆盖并列出原文）：

| 组件 | 许可 | 说明 |
| --- | --- | --- |
| expat | MIT | `pyexpat` 扩展（XML 解析） |
| libmpdec | BSD-2-Clause | `_decimal` 扩展（十进制浮点） |
| zlib | zlib License | `zlib` 扩展（与 §1.2 同一份 zlib 1.3.1 说明） |
| asyncio / 标准库 | PSF-2.0 | `python312.zip` 内的纯 Python 模块 |

> 未编入的模块：`_ssl`/`_hashlib`（无 OpenSSL）、`_sqlite3`、`_ctypes`（无 libffi）、
> `_locale`、curses/readline/tkinter、`_bz2`/`_lzma`、`_uuid`、`_multiprocessing`。

### 2.2 SQLite / OpenSSL / libffi（历史说明）

本版本**没有**打包这三个库（因此 `sqlite3`、`ssl`、`ctypes` 不可用），无需声明。

### 2.14 中文字体：Source Han Sans SC

- **Source Han Sans SC Regular**（思源黑体）— SIL Open Font License 1.1 (OFL-1.1)，
  Copyright 2014-2021 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'.
- 位置：`entry/src/main/resources/rawfile/python/fonts/SourceHanSansSC-Regular.otf`，
  按 GB2312 字符集子集化（保留字形轮廓，未修改字形设计）。
- OFL 允许随软件分发与子集化；保留原版权声明与许可文本即可（见 `docs/legal/`）。

### 2.14 scipy / OpenBLAS（C/Fortran 扩展，交叉编译）

- **scipy 1.14.1** — BSD-3-Clause（Copyright (c) 2001-2002 Enthought, Inc. 2003-2024, SciPy Developers）；
  构建脚本 `tooling/python/build-scipy-ohos.sh`，产物 `entry/libs/arm64-v8a/scipy/`（113 个扩展）
  + `.py` 在 `extras.zip`；
- **OpenBLAS 0.3.28** — BSD-3-Clause（`libopenblas.so` 随包，含 LAPACK）；
- **运行时替身库**（本项目自己编写，非第三方）：`libgfortran.so.5`、`libgcc_s.so.1`、`libmvec.so.1`
  —— 只提供 scipy 实际引用的少量符号，见 `tooling/python/gfortran-rt-stub.c` 等。

### 2.13 reportlab / watchdog（纯 Python 运行）

- **reportlab 4.2.5** — BSD-3-Clause（ReportLab Inc.）；字体数据各有许可（见包内 `fonts/`）；
- **watchdog 6.0.0** — Apache-2.0。

### 2.12 regex / psutil（C 扩展）

- **regex 2024.11.6** — Apache-2.0；产物 `entry/libs/arm64-v8a/regex/`，`.py` 在 `extras.zip`；
- **psutil 6.1.0** — BSD-3-Clause；产物 `entry/libs/arm64-v8a/psutil/`。

### 2.11 PyCryptodome（C 扩展，交叉编译）

- **PyCryptodome 3.21.0** — Public Domain（部分 BSD-2-Clause / MIT，见包内 LICENSE.rst）；
  构建脚本 `tooling/python/build-pycryptodome-ohos.sh`，产物 `entry/libs/arm64-v8a/Crypto/`
  （40 个 `.abi3.so`）+ `.py` 进 `extras.zip`。

### 2.10 文档 / 数学类纯 Python 包

| 包 | 许可 |
| --- | --- |
| python-docx 1.2.0 | MIT |
| python-pptx 1.0.2 | MIT |
| XlsxWriter | BSD-2-Clause |
| qrcode | BSD-3-Clause |
| sympy | BSD-3-Clause |
| mpmath | BSD-3-Clause |

### 2.9 lxml / libxml2 / libxslt（C 扩展，交叉编译）

- **lxml 5.3.0** — BSD-3-Clause（Copyright (c) 2004 Infrae）；
- **libxml2 2.13.5** — MIT；**libxslt 1.1.42** — MIT（两者随包：`libxml2.so.2` / `libxslt.so.1` / `libexslt.so.0`）；
- **cssselect 1.6.0** — BSD-3-Clause（纯 Python，见 2.4 节表格）。

### 2.8 matplotlib 及其依赖（C/C++ 扩展，交叉编译）

- **matplotlib 3.9.2** — PSF-2.0 AND MIT AND CC0-1.0 AND OFL-1.1 AND Bitstream-Vera AND Public-Domain
  （字体与样例数据各有单独许可，见包内 `LICENSE/` 目录）；
- **freetype 2.13.3** — FreeType License (FTL) 或 GPLv2（本项目按 FTL 使用）；
- **qhull 8.0.2** — Qhull 许可（BSD 风格）；
- **kiwisolver 1.4.7** — BSD-3-Clause；**contourpy 1.3.1** — BSD-3-Clause；
- 纯 Python 依赖 pyparsing / cycler / fonttools 见 2.4 节的表格。

### 2.7 Pillow / libjpeg-turbo / libpng（C 扩展，交叉编译）

- **Pillow 11.0.0** — HPND（Historical Permission Notice and Disclaimer，见 Pillow 仓库 LICENSE）；
  构建脚本 `tooling/python/build-pillow-ohos.sh`，产物 `entry/libs/arm64-v8a/PIL/`；
- **libjpeg-turbo 3.0.4** — BSD-3-Clause / IJG（`libjpeg.so.62` 随包）；
- **libpng 1.6.44** — libpng-2.0（`libpng16.so.16` 随包）；zlib 1.3.1 — zlib license（已有）。

### 2.6 pandas / libffi（C 扩展，交叉编译）

- **pandas 2.2.3** — BSD-3-Clause（Copyright (c) 2008-2011, AQR Capital Management, LLC, Lambda Foundry, Inc. and PyData Development Team）；
  构建脚本 `tooling/python/build-pandas-ohos.sh`，产物 `entry/libs/arm64-v8a/pandas/`；
- **libffi 3.4.6** — MIT（`libffi.so.8` 随包，供 `ctypes`/`_ctypes` 使用）。

### 2.5 numpy（C 扩展，交叉编译）

- **numpy 2.1.3** — BSD-3-Clause（Copyright (c) 2005-2024, NumPy Developers）；
  构建脚本 `tooling/python/build-numpy-ohos.sh`，产物在 `entry/libs/arm64-v8a/numpy/`；
- **libc++ 运行时**（`libc++_shared.so`，随 OHOS SDK / LLVM 提供，Apache-2.0 with LLVM exception）——
  `numpy.fft` 的 pocketfft 是 C++ 实现；
- numpy 自带 `LICENSES_bundled.txt` 列出的第三方片段（libdivide 等）按其各自许可分发，
  原文见 numpy 源码仓库。

### 2.4 纯 Python 三方库（vendor 进 site-packages.zip）

由 [`tooling/python/vendor-pure.sh`](tooling/python/vendor-pure.sh) 从 PyPI 拉取**纯 Python 轮子**并打包，
运行时挂在 `PYTHONPATH` 上（`filesDir/python/lib/python3.12/site-packages.zip`）。各包版本与许可：

<!-- VENDOR-LICENSES:START -->

# vendor 纯 Python 包许可摘要(自动生成, 勿手改)

| 包 | 版本 | 许可 |
| --- | --- | --- |
| beautifulsoup4 | 4.15.0 | MIT License |
| certifi | 2026.10.23 | MPL-2.0 |
| charset-normalizer | 3.5.2 | MIT |
| cssselect | 1.6.0 | BSD-3-Clause |
| cycler | 0.12.1 | BSD License |
| et_xmlfile | 2.0.0 | MIT |
| idna | 3.20 | BSD-3-Clause |
| Jinja2 | 3.1.6 | BSD License |
| Markdown | 3.11.2 | BSD-3-Clause |
| MarkupSafe | 3.0.2 | BSD-3-Clause |
| mpmath | 1.4.1 | BSD-3-Clause |
| openpyxl | 3.1.5 | MIT |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause |
| pyparsing | 3.3.3 | MIT |
| pypdf | 6.21.2 | BSD-3-Clause |
| python-dateutil | 3.0.0 | Dual License |
| python-docx | 1.2.0 | MIT |
| python-pptx | 1.0.2 | MIT |
| pytz | 2026.5 | MIT |
| PyYAML | 6.0.2 | MIT |
| qrcode | 8.2 | BSD |
| requests | 2.34.2 | Apache-2.0 |
| six | 1.17.0 | MIT |
| soupsieve | 3.0.4 | MIT |
| sympy | 1.14.0 | BSD |
| tabulate | 0.10.0 | MIT |
| tqdm | 4.70.1 | MPL-2.0 AND MIT |
| typing_extensions | 4.16.0 | PSF-2.0 |
| urllib3 | 2.8.0 | MIT |
| xlrd | 2.0.2 | BSD |
| xlsxwriter | 3.3.0 | BSD-2-Clause |

<!-- VENDOR-LICENSES:END -->
### 2.3 OpenSSL / SQLite / bzip2 / xz —— 原生 Python 的可选依赖

这几项是随后补进来的（交叉编译见 [`tooling/python/build-native-deps.sh`](tooling/python/build-native-deps.sh)），
只被 `run_python` 的解释器使用：

| 组件 | 版本 | 许可 | 用途 |
| --- | --- | --- | --- |
| OpenSSL | 3.0.15 | **Apache-2.0** | `_ssl` / `_hashlib`（TLS、`pbkdf2_hmac`、`scrypt`） |
| SQLite | 3.45.3 | **Public Domain** | `_sqlite3` |
| bzip2 | 1.0.8 | BSD 风格（Julian Seward） | `_bz2` |
| xz / liblzma | 5.4.6 | **Public Domain**（liblzma 部分 0BSD） | `_lzma` |

OpenSSL 以 Apache-2.0 分发，与本项目 Apache-2.0 兼容；许可原文见
[`LICENSES/Apache-2.0-OpenSSL.txt`](LICENSES/Apache-2.0-OpenSSL.txt)（构建后可从 OpenSSL 源码的 `LICENSE.txt` 取得）。

---

## 3. 其它既有第三方组件

| 组件 | 许可 | 说明 |
| --- | --- | --- |
| `@luvi/lv-markdown-in` | 见 `oh_modules` 内 LICENSE | Markdown 渲染 |
| `@cangjie-tpc/formula_hybrid` / `prism_hybrid` | 见 `oh_modules` 内 LICENSE | LaTeX / 代码高亮 |
| HarmonyOS SDK / JSVM-API | 华为 HarmonyOS SDK 许可 | `run_js` 依赖 `libjsvm.so` |

> 本项目自身代码为 Apache-2.0，见 [`LICENSE`](LICENSE)。

---

## 4. 维护约定

- **新增第三方代码或二进制**时，同步更新本文件与 `LICENSES/`，并把许可原文复制进
  `entry/src/main/resources/rawfile/licenses/`（随 HAP 分发）。
- 更新命令 so（mksh/toybox/libarchive/git/dropbear/node）时，更新本文档里的**版本、提交号与来源 URL**。
- 自检：`ls LICENSES/` 应至少包含 `IEC-MIT.txt`、`BetterSH-MIT.txt`、`mksh-MirOS.txt`、
  `toybox-0BSD.txt`、`GPL-2.0.txt`、`dropbear-MIT.txt`、`CPython-LICENSE.txt`。
