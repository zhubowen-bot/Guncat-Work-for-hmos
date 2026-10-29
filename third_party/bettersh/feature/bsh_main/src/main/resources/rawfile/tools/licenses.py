# licenses.py — BetterSH 分发物里的第三方组件与各自许可
#
# 为什么要有这个：应用里既用了 MIT/BSD 这类许可，也用了 GPL/LGPL（qemu、glibc、
# glib、make），**分发时必须带上许可与版权声明**。这份清单就是那份声明。
#
# 两条维护约定：
#   * 只列**真的在分发物里**的东西（bundle libs + rawfile 里的 tar + pkg 源上的包）；
#   * 不写版本号 —— 版本会随构建漂，许可不会。要查版本看仓库 README 的依赖表，
#     或者设备上 `pkg list`。
#
# 颜色约定同 readme.py：不是终端就关，NO_COLOR 设了也关。

import os
import sys
import unicodedata

USE_COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ


def sgr(*codes):
    """按需产出 ANSI 序列；不开颜色时返回空串，调用处不用写分支。
    codes 允许写 int（sgr(0) 这样的字面量最顺手），所以这里统一转成字符串。"""
    if not USE_COLOR:
        return ""
    return "\x1b[" + ";".join(str(c) for c in codes) + "m"


def dw(text):
    """终端列宽：东亚宽字符占两列。"""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


RESET = sgr(0)
BOLD = sgr(1)
DIM = sgr(2)
CYAN = sgr(36)
GREEN = sgr(32)
YELLOW = sgr(33)
RED = sgr(31)

WIDTH = 72
NAME_W = 22
LIC_W = 16

# ── 随 HAP 分发 ────────────────────────────────────────────────────────────
# (组件, 许可, 来源)
PERMISSIVE = [
    ("toybox",            "0BSD",              "github.com/landley/toybox"),
    ("mksh",              "MirOS",             "github.com/MirBSD/mksh"),
    ("vim",               "Vim License",       "github.com/vim/vim"),
    ("ncurses",           "MIT 类",            "invisible-island.net/ncurses"),
    ("zlib",              "zlib",              "zlib.net"),
    ("zstd",              "BSD-3-Clause",      "github.com/facebook/zstd"),
    ("PCRE2",             "BSD-3 + 例外",      "github.com/PCRE2Project/pcre2"),
    ("OpenSSL",           "Apache-2.0",        "openssl.org"),
    ("Mbed TLS",          "Apache-2.0/GPL",   "github.com/Mbed-TLS/mbedtls"),
    ("musl libc",         "MIT",               "musl.libc.org"),
    ("Node.js",           "MIT",               "nodejs.org"),
    ("npm",               "Artistic-2.0",      "npmjs.com"),
    ("CPython",           "PSF-2.0",           "python.org"),
    ("libffi",            "MIT",               "github.com/libffi/libffi"),
    ("wayland",           "MIT",               "gitlab.freedesktop.org/wayland/wayland"),
    ("wayland-protocols", "MIT",               "gitlab.freedesktop.org/wayland/wayland-protocols"),
    ("weston",            "MIT",               "gitlab.freedesktop.org/wayland/weston"),
    ("libxkbcommon",      "MIT",               "github.com/xkbcommon/libxkbcommon"),
    ("xkeyboard-config",  "MIT 等",            "Debian xkb-data 包"),
    ("expat",             "MIT",               "libexpat.github.io"),
    ("fontconfig",        "MIT 类",            "freedesktop.org/software/fontconfig"),
    ("freetype",          "FTL 或 GPL-2.0",    "freetype.org"),
    ("libjpeg-turbo",     "IJG / BSD-3",       "libjpeg-turbo.org"),
    ("libpng",            "libpng-2.0",        "libpng.org"),
    ("Dropbear",          "MIT 为主",          "github.com/mkj/dropbear"),
    ("box64",             "MIT",               "github.com/ptitSeb/box64"),
    ("fastfetch",         "MIT",               "github.com/fastfetch-cli/fastfetch"),
    ("Info-ZIP zip/unzip", "Info-ZIP",         "info-zip.org"),
    ("OpenHarmony 工具",  "Apache-2.0",        "hdc / 签名与打包工具"),
]

COPYLEFT = [
    ("qemu (qemu-user)",  "GPL-2.0",           "github.com/qemu/qemu"),
    ("glibc",             "LGPL-2.1",          "gnu.org/software/libc"),
    ("glib",              "LGPL-2.1",          "gitlab.gnome.org/GNOME/glib"),
    ("gettext (libintl)", "LGPL-2.1",          "gnu.org/software/gettext"),
]

# ── 通过 pkg 按需下载（不随 HAP 走）────────────────────────────────────────
PKG_ONLY = [
    ("pip",               "MIT",               "github.com/pypa/pip"),
    ("GNU make",          "GPL-3.0",           "gnu.org/software/make"),
    ("ninja",             "Apache-2.0",        "github.com/ninja-build/ninja"),
    ("cmake",             "BSD-3-Clause",      "cmake.org"),
    ("LLVM / clang / lld", "Apache-2.0/LLVM",   "llvm.org"),
    ("Node.js headers",   "MIT",               "nodejs.org"),
    ("CPython headers",   "PSF-2.0",           "python.org"),
    ("hdc",               "Apache-2.0",        "OpenHarmony 命令行工具"),
    ("hap-sign-tool 等",  "Apache-2.0",        "OpenHarmony 签名与打包工具"),
]

# ── 默认构建里没有 ────────────────────────────────────────────────────────
NOT_BUILT = [
    ("Qt 6",              "LGPL-3.0",          "qt.io"),
    ("PyQt6",             "GPL-3.0",           "riverbankcomputing.com"),
    ("OpenJDK",           "GPL-2.0 + 例外",    "openjdk.org"),
]


def rule():
    print(DIM + "─" * WIDTH + RESET)


def title(text):
    print()
    rule()
    print(BOLD + CYAN + text + RESET)
    rule()


def rows(items, lic_color):
    for name, lic, src in items:
        pad = " " * max(1, NAME_W - dw(name))
        lpad = " " * max(1, LIC_W - dw(lic))
        print("  " + BOLD + name + RESET + pad + lic_color + lic + RESET + lpad + DIM + src + RESET)


def para(text):
    print()
    for line in text.strip("\n").split("\n"):
        print(("  " + line).rstrip() if line else "")


print()
print(BOLD + CYAN + "BetterSH — 第三方组件与许可" + RESET)
print(DIM + "  本项目暂未为自身选定许可证；以下列出**分发物里包含的**第三方组件。" + RESET)
print(DIM + "  应用市场里下载到的版本与本机自编版本的组件集合可能略有出入。" + RESET)

title("宽松许可 · 可自由再分发")
rows(PERMISSIVE, GREEN)

title("copyleft · 需要随分发提供许可与源码")
rows(COPYLEFT, YELLOW)
para("""
qemu 以 GPL-2.0 静态链接进应用，glibc / glib / libintl 以 LGPL-2.1 动态链接。
LGPL 部分按「动态链接 + 可替换」的方式使用（bundle 里的 .so 就是那份可替换件）。
BetterSH 因此整体按 GPL 兼容的方式开源，完整源码见：

  https://atomgit.com/qq_35859034/BetterSH
""")

title("默认构建里不包含")
rows(NOT_BUILT, DIM)
para("""
Qt6 / PyQt6 / OpenJDK 需要显式开启构建选项，默认不编进 HAP。
""")

rule()
print()
