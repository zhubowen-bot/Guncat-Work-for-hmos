# 第三方组件与许可

本仓库自身源码以根目录 `LICENSE`（MIT）发布。**随 HAP 打包或由脚本产出的第三方组件**
仍遵循其各自许可证，不以 MIT 覆盖。下面按"是否随包分发"分组，准确的版本以
`.gitmodules`、`scripts/build_*.sh` 里固定的版本号与 `git submodule status` 为准。

## 一、随 HAP / 由本仓库构建产物分发的组件

| 组件 | 许可证 | 说明 |
| --- | --- | --- |
| [QEMU](https://www.qemu.org/)（`libqemu-aarch64.so` / `libqemu-x86_64.so`） | GPL-2.0 | 由 `scripts/build_qemu.sh` 从 `thirdparty/qemu` 构建，独立 `.so` 形式加载 |
| [toybox](https://github.com/landley/toybox)（`libtoybox.so`） | 0BSD | 单库多 applet |
| [mksh](https://github.com/MirBSD/mksh)（`libmksh.so`） | MirOS License | `sh` |
| [Vim](https://www.vim.org/)（`libvim.so` + runtime） | Vim License | 含 ncurses 静态链接 |
| [ncurses](https://invisible-island.net/ncurses/) | MIT 风格 | 宽字符版 |
| [zlib](https://zlib.net/) | zlib License | |
| [fastfetch](https://github.com/fastfetch-cli/fastfetch) | MIT | HarmonyOS fork |
| [CPython](https://www.python.org/)（`libpython.so` + stdlib） | PSF License | 3.12 |
| [OpenSSL](https://www.openssl.org/) | Apache-2.0 | 静态链入 CPython |
| [Node.js](https://nodejs.org/)（`libnode.so`） | MIT | 22.x，含 V8 |
| [dropbear](https://github.com/mkj/dropbear)（`libsshcore.so`） | MIT | ssh/scp/keygen/server |
| [Info-ZIP](http://www.info-zip.org/)（`libzipcmd.so` / `libunzipcmd.so`） | Info-ZIP License | |
| [git](https://git-scm.com/)（`pkg` 包） | GPL-2.0 | 由 `scripts/build_git.sh` 构建 |
| [libarchive](https://libarchive.org/) | BSD-2-Clause | `pkg` / `apt` 解包 |
| [mbedTLS](https://www.trustedfirmware.org/projects/mbedtls/) | Apache-2.0 | `pkg` / `apt` 的 TLS |
| [zstd](https://github.com/facebook/zstd) | BSD-3-Clause / GPL-2.0 双许可 | 只取解压半边 |
| [PCRE2](https://github.com/PCRE2Project/pcre2) | BSD-3-Clause | git 依赖 |
| [libffi](https://github.com/libffi/libffi) | MIT | CPython `_ctypes` |
| [Wayland](https://wayland.freedesktop.org/) / wayland-protocols | MIT | compositor 与其协议 |
| [weston](https://gitlab.freedesktop.org/wayland/weston)（weston-terminal） | MIT | 终端仿真器 |
| [glib](https://gitlab.gnome.org/GNOME/glib) | LGPL-2.1+ | weston 依赖 |
| [xterm.js](https://xtermjs.org/)（`rawfile/term/vendor/`） | MIT | 前端终端 |
| DejaVu Sans Mono | Bitstream Vera / DejaVu License | 终端字体，见 `fonts/LICENSE.txt` |
| [OpenJDK](https://openjdk.org/)（可选 `libjdk.so` + JDK tar） | GPL-2.0 + Classpath Exception | 默认不出包 |
| [Qt](https://www.qt.io/)（可选 Qt Wayland demo） | LGPL-3.0 / GPL | 默认不出包 |

## 二、仅作构建输入、不随包分发

`thirdparty/` 下的 LLVM/clang、glibc、musl、weston、wayland、qemu、vim、mksh、
ncurses、toybox、zlib、zstd、pcre2、mbedTLS、libffi、glib、dropbear、fastfetch
等子模块只在构建期使用；其源码不进入 HAP。各子模块许可证见其自身仓库。

## 三、分发前需要确认的两件事

1. **GPL-2.0 组件**（QEMU、git）以独立 `.so` / 独立可执行文件形式随包分发，
   分发时需按 GPL 提供对应源码（本仓库的 `thirdparty/` 子模块与
   `scripts/build_*.sh` 即为源码与构建方法的出处）。
2. **LGPL 组件**（glib、可选的 Qt）以动态链接形式使用，需保留其许可证文本与
   可替换性说明。

本文件是清单，不是法律意见；对外分发前请按目标渠道的要求复核。
