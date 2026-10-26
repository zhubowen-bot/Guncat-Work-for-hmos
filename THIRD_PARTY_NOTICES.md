# 第三方组件与许可声明

> 本文档是本仓库（Guncat Work，Apache-2.0）随附的第三方组件声明。
> `shell` 工具（设备内真 Linux）与 `run_python`（原生 CPython）涉及的组件最多，集中在第 1、2 节。
> 完整许可原文见 [`LICENSES/`](LICENSES/)，同一份声明与原文也打包进 HAP 的 `resources/rawfile/licenses/`。

---

## 1. Shell 工具（Linux VM）
### 1.1 HiSH — MIT

**用途**：本项目的 Linux VM 方案整体建立在 [HiSH](https://github.com/harmoninux/HiSH) 的实践之上，
具体包括三处衍生：

| 位置 | 与 HiSH 的关系 |
| --- | --- |
| [`tooling/linux-vm/deps/`](tooling/linux-vm/deps/) | 构建配方（`Makefile` / `utils/Makefrag` / zlib / zstd / pcre2 / glib / pixman / libqemu）**改编自 HiSH 的 `deps/` 目录**；改动点：改用 `codeload.github.com` 下载、glib 的 `proxy-libintl` 改为直接解包、zlib/pcre2 改静态链接、编完 strip、统一 `QEMU_TCI=1` |
| `entry/src/main/resources/rawfile/vm/rootfs_guncat.qcow2` | 以 HiSH 发布的 Alpine 底座镜像（`harmoninux/linux-config` 的 `alpine-20251205/rootfs_aarch64.qcow2`）为底座，注入我们自己的 `/etc/guncat-setup`、`/usr/local/bin/guncat-agent`、`inittab`，并预装 Python 3 / pip / jq |
| [`entry/src/main/cpp/vm/guncat_vm.cpp`](entry/src/main/cpp/vm/guncat_vm.cpp)、`fetch-assets.sh`、`build-rootfs.sh` | 代码为本项目新写；但「QEMU 以 `.so` 形式 dlopen、串口走 unix socket、9p 共享目录、内核与镜像的取用方式」沿用 HiSH 的做法与发布物 |

**许可**：MIT，Copyright (c) 2025 hackeris。全文见 [`LICENSES/HiSH-MIT.txt`](LICENSES/HiSH-MIT.txt)。

```
MIT License

Copyright (c) 2025 hackeris

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, ... （全文见 LICENSES/HiSH-MIT.txt）
```

### 1.2 QEMU — GPL-2.0

**用途**：`entry/libs/arm64-v8a/libqemu-system-aarch64-tci.so`（打包进 HAP）由 QEMU 编译而来，
以动态库形式在应用进程内 dlopen 运行。

| 项 | 值 |
| --- | --- |
| 上游 | <https://github.com/harmoninux/qemu>（QEMU 的 fork，提供 `libqemu-system-aarch64.so` 目标与 `qemu_system_entry` 入口） |
| 分支 / 提交 | `hish-libqemu` @ `50ce7096eb6b338bee88a0960c543f93f1b16959`（2025-12-13） |
| QEMU 版本 | 10.2.0（见源码 `VERSION`） |
| 我们的改动 | **只改构建开关，未改 QEMU 源码**：`--enable-tcg-interpreter`（TCI 解释执行，不生成机器码）、zlib/pcre2 静态链接、`llvm-strip`。全部开关与步骤见 [`tooling/linux-vm/deps/libqemu/Makefile`](tooling/linux-vm/deps/libqemu/Makefile) 与 [`build-libqemu-tci.sh`](tooling/linux-vm/build-libqemu-tci.sh) |
| 源码获取 | 按上文 URL 取 `hish-libqemu` 分支（或 `git clone -b hish-libqemu`），用本仓库脚本即可复现同一 `.so`；GPL-2.0 全文见 [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt) |

QEMU 内部静态链接的第三方库（同一 GPL-2.0 二进制内，不再单独分发 `.so`）：

| 库 | 版本 | 许可 | 上游 |
| --- | --- | --- | --- |
| zlib | 1.3.1 | zlib License（© 1995-2022 Jean-loup Gailly, Mark Adler） | <https://zlib.net> |
| PCRE2 | 10.45 | BSD-3-Clause（PCRE2 LICENCE） | <https://github.com/PCRE2Project/pcre2> |
| GLib | 2.82.0 | LGPL-2.1-or-later（全文见 [`LICENSES/LGPL-2.1.txt`](LICENSES/LGPL-2.1.txt)） | <https://gitlab.gnome.org/GNOME/glib> |
| pixman | 0.42.2 | MIT | <https://cairographics.org> |
| zstd | 1.5.7 | BSD-3-Clause / GPL-2.0（双许可） | <https://github.com/facebook/zstd> |
| libffi | （glib 子项目） | MIT（© 1996-2014 Anthony Green, Red Hat, Inc and others） | <https://github.com/libffi/libffi> |
| proxy-libintl | 0.4 | LGPL-2.0（glib 的 intl 回落子项目，© Frida） | <https://github.com/frida/proxy-libintl> |

GLib 为 LGPL：本项目以静态方式把它链入 GPL-2.0 的 `libqemu-system-aarch64-tci.so`，该 `.so` 以独立文件分发、
源码与完整可重建脚本（含链接参数）均在公开仓库，满足 LGPL 的「可重新链接」要求。

### 1.3 libslirp — BSD 风格（Danny Gasparovski）

**用途**：`entry/libs/arm64-v8a/libslirp.so.0`，QEMU 的用户态网络（`-netdev user`）。
Copyright (c) 1995,1996 Danny Gasparovski。原文见 [`LICENSES/libslirp-COPYRIGHT.txt`](LICENSES/libslirp-COPYRIGHT.txt)。

### 1.4 Linux kernel — GPL-2.0

**用途**：`entry/src/main/resources/rawfile/vm/kernel_aarch64`（约 12MB，aarch64 `Image`），
打包进 HAP 并在设备上引导。

| 项 | 值 |
| --- | --- |
| 版本 | Linux 6.12（`uname` 报 `6.12.60`） |
| 源码 | <https://github.com/torvalds/linux>（`v6.12` 分支） |
| 构建配置 | <https://github.com/harmoninux/linux-config> 的 `arm64_virt`（构建步骤见 HiSH README「构建Linux内核」一节） |
| 我们的改动 | 无（直接使用 HiSH 发布的预编译内核） |
| 分发来源 | <https://github.com/harmoninux/linux-config/releases/tag/kernel-20260228> |
| 许可全文 | [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt) |

> GPL-2.0 要求分发二进制时提供对应源码。上面给出了源码仓库、精确配置文件名与构建步骤；
> 如需逐字节一致的二进制，用同一配置 + 同一工具链重建即可（本仓库 `tooling/linux-vm/fetch-assets.sh` 也会取该发布物）。

### 1.5 Alpine Linux 与镜像内的 apk 包 — 各自许可

**用途**：`rootfs_guncat.qcow2` 内的用户态（Alpine 3.22 + 我们预装的 `python3`/`py3-pip`/`jq`/`ca-certificates` 等 49 个包）。

- Alpine 基础系统与各包分别适用 **MIT / BSD / GPL-2.0 / LGPL / MPL-2.0** 等许可（逐包不同）。
- 镜像内的**逐包清单与版本**可查：`apk info -v`，或解包后看 `/lib/apk/db/installed`。
- 各包源码与 `APKBUILD` 见 Alpine 的 [aports](https://gitlab.alpinelinux.org/alpine/aports)。
- 其中 Python 为 **PSF-2.0**，`jq` 为 **MIT**，`ca-certificates` 为 **MPL-2.0**。
- 预装过程与包清单见 [`tooling/linux-vm/provision-packages.sh`](tooling/linux-vm/provision-packages.sh)。

### 1.6 QEMU 固件与键盘映射

`rawfile/vm/efi-virtio.rom`、`rawfile/vm/keymaps/en-us` 取自 QEMU 源码树（`pc-bios/`），随 QEMU 同许可（GPL-2.0）。

---

## 2. 原生 Python（`run_python` 与 `npy` 桥）

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

# vendor 纯 Python 包许可摘要(自动生成, 勿手改)

| 包 | 版本 | 许可 |
| --- | --- | --- |
| beautifulsoup4 | 4.15.0 | MIT License |
| certifi | 2026.10.23 | MPL-2.0 |
| et_xmlfile | 2.0.0 | MIT |
| idna | 3.20 | BSD-3-Clause |
| Jinja2 | 3.1.6 | BSD License |
| Markdown | 3.11.2 | BSD-3-Clause |
| openpyxl | 3.1.5 | MIT |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause |
| pypdf | 6.21.2 | BSD-3-Clause |
| python-dateutil | 3.0.0 | Dual License |
| pytz | 2026.5 | MIT |
| requests | 2.34.2 | Apache-2.0 |
| six | 1.17.0 | MIT |
| soupsieve | 3.0.4 | MIT |
| tabulate | 0.10.0 | MIT |
| tqdm | 4.70.1 | MPL-2.0 AND MIT |
| typing_extensions | 4.16.0 | PSF-2.0 |
| urllib3 | 2.8.0 | MIT |
| xlrd | 2.0.2 | BSD |

（完整许可原文随各包位于 `site-packages.zip` 内的 `*.dist-info/` 目录。）

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
- 更新 QEMU 分支 / 内核镜像时，更新本文档里的**提交号、版本与来源 URL**。
- 自检：`ls LICENSES/` 应至少包含 `HiSH-MIT.txt`、`GPL-2.0.txt`、`LGPL-2.1.txt`、`libslirp-COPYRIGHT.txt`、`CPython-LICENSE.txt`。
