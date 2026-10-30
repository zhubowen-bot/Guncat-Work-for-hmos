#!/bin/bash
# build_weston_terminal.sh — 把 weston-terminal 编成**可执行程序**，随包分发给 elfloader 当 guest 跑
#
# 产物：
#   rawfile/tools/weston-terminal.tar   平铺目录（可执行 + 依赖闭包），设备端由 shell.cpp 的
#                                       UnpackRes 解到 <sysroot>/weston-terminal
#   rawfile/tools/{xkb,weston-data,fonts}.tar   运行期资源（见文件末尾）
#
# 与过去"编成命令 so（libwestterm.so）"的区别：
#   - 过去是 dlopen 进应用主进程，用的是 OHOS libc；现在是 elfloader 起的 guest，
#     自己带 /lib/ld-musl-aarch64.so.1 解释器，所以必须 **PIE + 依赖闭包 + rpath=$ORIGIN**，
#     形状与 scripts/build_qtwl_demo.sh 的 app 模式一致。
#   - fs/tty/exec 那几个 shim **不再编进来**：procmgr 起 guest 时会按 PT_INTERP 预载
#     libbshguest-musl.so 并置 BSH_FAKE_PTY / BSH_EXEC_SHIM（见 procmgr.cpp 的 ChildRunElf），
#     这些语义对 guest 是白给的。只保留 tty/bsh_pty.c —— forkpty/ioctl/read 那三个 wrap 是
#     "软 pty + winsize + master 的 EAGAIN" 的现行可用实现，换给 pty_shim 等于重做一遍。
#   - 因此也**不需要** -Wl,--wrap= 的 shim 清单，只留 bsh_pty 那三个。
#
# 组成：
#   - weston 源码（thirdparty/weston）：clients/terminal.c + clients/window.c + shared/*
#   - 协议（wayland-protocols + weston 自带）由宿主 wayland-scanner 生成
#   - 本工程：tty/bsh_pty.c（软 pty）、programs/weston_terminal/guest_compat.c（musl 1.2.2
#     缺 arc4random_buf，expat 要用）
#   - 依赖：libwayland-client/cursor **动态**（随 app 目录走）；cairo/fontconfig/freetype/
#     expat/pixman/png/jpeg/webp/xkbcommon/ffi/z **静态**，需先跑 scripts/build_weston_deps.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

WESTON_SRC="${WESTON_SRC:-$ROOT/thirdparty/weston}"
CPP_DIR="$ROOT/feature/bsh_main/src/main/cpp"
COMPAT_SRC="$CPP_DIR/programs/weston_terminal/guest_compat.c"

# 资源根的默认值从 common/bsh_paths.h 取（唯一来源，别在这里再抄一份字面量：
# config.h 的 WESTON_DEFAULT_RT_DIR 与 fonts.conf 的 <dir> 都用它）。
# 注意宏现在叫 BSH_SYSROOT_DEFAULT（旧名 BSH_SYSROOT 在分包时改成了"兜底默认值"的语义）。
SYSROOT_DEFAULT_RT_DIR="$(sed -n 's/^#define BSH_SYSROOT_DEFAULT  *"\(.*\)"/\1/p' "$CPP_DIR/common/bsh_paths.h")"
[ -n "$SYSROOT_DEFAULT_RT_DIR" ] || err "没能从 $CPP_DIR/common/bsh_paths.h 取到 BSH_SYSROOT_DEFAULT"

[ -f "$WESTON_SRC/clients/terminal.c" ] || err "weston 源码缺失: $WESTON_SRC/clients/terminal.c"
[ -f "$CPP_DIR/tty/bsh_pty.c" ] || err "缺 tty/bsh_pty.c"
[ -f "$COMPAT_SRC" ] || err "缺 $COMPAT_SRC"
[ -f "$SYSROOT_EXT_LIB/libcairo.a" ] || err "缺静态依赖: $SYSROOT_EXT_LIB/libcairo.a（先跑 scripts/build_weston_deps.sh）"
[ "$TARGET" = aarch64-linux-ohos ] || err "只支持 arm64-v8a（现在 NATIVE_ARCH=$NATIVE_ARCH）"

BUILD="$BUILD_DIR/weston-term"
PROTO_GEN="$BUILD/protocols"
# 组装目录按 FHS 摆：可执行进 usr/bin、依赖闭包进 usr/lib，rpath=$ORIGIN/../lib。
# 这样打出来的 tar 顶层就是 usr/，"安装" = tar -C <资源根> -x（pkg 包与 HAP 内置共用同一套路径，
# 两边装到同一个地方，不会互相打架）。xkb / weston-data 也已经是 usr/share/… 的形状。
APPDIR="$BUILD/app"
BINDIR="$APPDIR/usr/bin"
LIBDIR="$APPDIR/usr/lib"
APP_NAME="weston-terminal"
# 三个包**不再随 HAP 打包**：产出到 dist/pkgs/（dist/ 已被 gitignore），由人工上传到
# 包服务器 https://bsh.y1yan.com/（见 index.json 的 file 字段）。装它们的是 pkg 命令。
PKG_OUT="$ROOT/dist/pkgs"
OUT_TAR="$PKG_OUT/$APP_NAME.tar"
# fonts 仍然是随包资源（不在 pkg 里）：终端窗口没字体就什么都看不见。
RES_TOOLS="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools"
mkdir -p "$PROTO_GEN" "$PKG_OUT"

if pkg-config --exists wayland-scanner; then
    SCANNER="$(pkg-config --variable=wayland_scanner wayland-scanner)"
else
    SCANNER="$WAYLAND_SCANNER"
fi
[ -x "$SCANNER" ] || err "wayland-scanner 不可用: $SCANNER"
WPS="$WAYLAND_PROTOCOLS_SRC/stable"
WPU="$WAYLAND_PROTOCOLS_SRC/unstable"
WPG="$WAYLAND_PROTOCOLS_SRC/staging"
WSP="$WESTON_SRC/protocol"

# ── 1. 协议生成（client 头 + 实现）──────────────────────────
gen_proto() {
    local xml="$1" base="$2"
    [ -f "$xml" ] || err "缺协议 XML: $xml"
    "$SCANNER" client-header "$xml" "$PROTO_GEN/${base}-client-protocol.h"
    "$SCANNER" private-code  "$xml" "$PROTO_GEN/${base}-protocol.c"
}
log "=== 生成协议 ==="
gen_proto "$WPS/xdg-shell/xdg-shell.xml"                                 "xdg-shell"
gen_proto "$WPS/viewporter/viewporter.xml"                               "viewporter"
gen_proto "$WPU/relative-pointer/relative-pointer-unstable-v1.xml"       "relative-pointer-unstable-v1"
gen_proto "$WPU/pointer-constraints/pointer-constraints-unstable-v1.xml" "pointer-constraints-unstable-v1"
gen_proto "$WPU/tablet/tablet-unstable-v2.xml"                           "tablet-unstable-v2"
gen_proto "$WPG/color-management/color-management-v1.xml"                "color-management-v1"
gen_proto "$WPG/single-pixel-buffer/single-pixel-buffer-v1.xml"          "single-pixel-buffer-v1"
gen_proto "$WSP/text-cursor-position.xml"                                "text-cursor-position"

# 协议生成物必须叫 PROTO_SOURCES：下面的 SOURCES 靠 ${PROTO_SOURCES[@]} 引它。
# （537fd26 那次加 tty_shim 时被误改名成 SOURCES，于是协议源再没参与编译过，症状是
#  加载期报 wp_color_manager_v1_interface / xdg_wm_base_interface "symbol not found"。
#  别再把这两个数组混成同一个名字。）
PROTO_SOURCES=(
    "$PROTO_GEN/xdg-shell-protocol.c"
    "$PROTO_GEN/viewporter-protocol.c"
    "$PROTO_GEN/relative-pointer-unstable-v1-protocol.c"
    "$PROTO_GEN/pointer-constraints-unstable-v1-protocol.c"
    "$PROTO_GEN/tablet-unstable-v2-protocol.c"
    "$PROTO_GEN/color-management-v1-protocol.c"
    "$PROTO_GEN/single-pixel-buffer-v1-protocol.c"
    "$PROTO_GEN/text-cursor-position-protocol.c"
)

# ── 2. stub config.h（资源目录走环境变量，运行时由会话设置）──
cat > "$BUILD/config.h" <<EOF
#ifndef WESTON_TERMINAL_CONFIG_H
#define WESTON_TERMINAL_CONFIG_H
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include <stdlib.h>
#define PACKAGE_STRING  "weston-terminal"
#define PACKAGE_VERSION "13.0.0"
#define WESTON_DEFAULT_RT_DIR "$SYSROOT_DEFAULT_RT_DIR"
#define DATADIR     (getenv("WESTON_DATADIR")     ?: WESTON_DEFAULT_RT_DIR)
#define SYSCONFDIR  (getenv("WESTON_SYSCONFDIR")  ?: WESTON_DEFAULT_RT_DIR)
#define LIBEXECDIR  (getenv("WESTON_LIBEXECDIR")  ?: WESTON_DEFAULT_RT_DIR "/libexec")
#define BINDIR      (getenv("WESTON_BINDIR")      ?: "/system/bin")
#endif
/* musl 无 glibc 的 program_invocation_short_name（weston xalloc.h 用到） */
#ifndef program_invocation_short_name
extern const char *__progname;
#define program_invocation_short_name __progname
#endif
EOF

# ── 3. 编译并链接成可执行文件 ───────────────────────────────
WARN_FLAGS="-Wno-format -Wno-format-security -Wno-error=format-security \
-Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable \
-Wno-unused-but-set-variable -Wno-unused-result -Wno-int-conversion \
-Wno-error=int-conversion -Wno-incompatible-pointer-types \
-Wno-implicit-function-declaration -Wno-array-bounds"

INCLUDES="-I$BUILD -I$ROOT/feature/bsh_main/src/main/cpp/wayland/include -I$ROOT/feature/bsh_main/src/main/cpp/wayland/protocol -I$WAYLAND_SRC/cursor -I$SYSROOT_EXT_INC -I$SYSROOT_EXT_INC/pixman-1 -I$SYSROOT_EXT_INC/freetype2 \
-I$SYSROOT_EXT_INC/cairo \
-I$PROTO_GEN -I$WESTON_SRC -I$WESTON_SRC/include -I$WESTON_SRC/shared -I$WESTON_SRC/clients \
-I$CPP_DIR"

SOURCES=(
    "$WESTON_SRC/clients/terminal.c"
    "$WESTON_SRC/clients/window.c"
    "$WESTON_SRC/shared/os-compatibility.c"
    "$WESTON_SRC/shared/option-parser.c"
    "$WESTON_SRC/shared/file-util.c"
    "$WESTON_SRC/shared/cairo-util.c"
    "$WESTON_SRC/shared/frame.c"
    "$WESTON_SRC/shared/config-parser.c"
    "$WESTON_SRC/shared/matrix.c"
    "$WESTON_SRC/shared/image-loader.c"
    "${PROTO_SOURCES[@]}"
    "$CPP_DIR/tty/bsh_pty.c"          # 软 pty：forkpty/ioctl/read 的 link-time wrap
    "$COMPAT_SRC"                     # musl 1.2.2 缺 arc4random_buf
)

# 静态依赖从 $SYSROOT_EXT_LIB 取 —— **必须排在 $HAP_LIBS_DIR 前面**：
# 两个目录里有同名的 libfontconfig/libfreetype/libexpat/libjpeg，顺序反了就会链成
# 应用里的 .so（旧版本就是这样，NEEDED 里全是 OHOS 编出来的动态库，进 guest 后
# 会因为 OHOS libc 专有符号缺失而加载失败）。wayland 只有 .so，靠 dist/HAP 目录。
LIBS="-lwayland-client -lwayland-cursor \
-lcairo -lfontconfig -lfreetype -lexpat -lpixman-1 -lpng16 -ljpeg -lwebp \
-lxkbcommon -lffi -lz -lm -ldl -lpthread"

rm -rf "$APPDIR"; mkdir -p "$BINDIR" "$LIBDIR"
log "=== 链接 $APP_NAME（PIE + musl 解释器；usr/bin + usr/lib）==="
"$CLANG" --target="$TARGET" --sysroot="$SYSROOT" \
    $WARN_FLAGS $INCLUDES "${SOURCES[@]}" \
    -O2 -fPIE -pie \
    -L"$SYSROOT_EXT_LIB" -L"$DIST_DIR/lib" -L"$HAP_LIBS_DIR" \
    $LIBS \
    -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 \
    -Wl,-rpath,'$ORIGIN/../lib' \
    -Wl,--export-dynamic \
    -Wl,--wrap=forkpty -Wl,--wrap=ioctl -Wl,--wrap=read \
    -o "$BINDIR/$APP_NAME" \
    || err "链接 $APP_NAME 失败"

# ── 4. 依赖闭包（只认 NEEDED）→ usr/lib ─────────────────────
# guest 的 ld.so 会先看 rpath=$ORIGIN/../lib，再看系统目录 —— 少拷一个就会去 /system/lib64
# 抓 OHOS 那份（然后拖进整条 OHOS 服务链）。libc/libm/ld-musl 由 guest 运行时提供，
# 拷进来反而和会话里那份打架。
copy_closure() {
    local dirs=("$DIST_DIR/lib" "$HAP_LIBS_DIR" "$SYSROOT_EXT_LIB" \
                "$ROOT/thirdparty/ohos-extra/additional-packages/lib")
    declare -A seen
    MISSING=""
    resolve() {
        local name="$1" p="" d
        [ -n "${seen[$name]:-}" ] && return
        seen[$name]=1
        case "$name" in
            libc.so|libc.so.6|libdl.so*|libm.so*|libpthread.so*|librt.so*|ld-musl*|ld-linux*) return;;
        esac
        for d in "${dirs[@]}"; do
            if [ -f "$d/$name" ]; then p="$d/$name"; break; fi
        done
        if [ -z "$p" ]; then MISSING="$MISSING $name"; return; fi
        cp -f "$p" "$LIBDIR/$name"
        local n
        for n in $("$CLANG_DIR/llvm-readelf" -d "$p" 2>/dev/null \
                   | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}'); do
            resolve "$n"
        done
    }
    local n
    for n in $("$CLANG_DIR/llvm-readelf" -d "$BINDIR/$APP_NAME" 2>/dev/null \
               | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}'); do
        resolve "$n"
    done
    warn "闭包里本机找不到的 NEEDED（可能指望 /system/lib64）：${MISSING:- 无}"
}
log "=== 拷贝依赖闭包 ==="
copy_closure

# ── 5. strip ───────────────────────────────────────────────
"$CLANG_DIR/llvm-strip" --strip-unneeded "$BINDIR/$APP_NAME" 2>/dev/null || true
for f in "$LIBDIR"/*.so*; do
    [ -f "$f" ] || continue
    "$CLANG_DIR/llvm-strip" --strip-unneeded "$f" 2>/dev/null || true
done

# ── 6. 打包 ────────────────────────────────────────────────
# tar 顶层是 usr/（usr/bin/<可执行> + usr/lib/*.so）—— 与 xkb/weston-data 同形，
# 于是"安装"就是 tar -C <资源根> -x；HAP 内置的那份与 pkg 从服务器下的那份落到**同一处路径**，
# 不会互相打架。先写 .new 再 mv：中途失败时上一次已部署的 tar 原封不动。
log "=== 打包 → $OUT_TAR ==="
mkdir -p "$(dirname "$OUT_TAR")"
tar -cf "$OUT_TAR.new" -C "$APPDIR" usr || err "打 tar 失败"
mv -f "$OUT_TAR.new" "$OUT_TAR"

# ── 7. 自检 ────────────────────────────────────────────────
READELF="$CLANG_DIR/llvm-readelf"
arch_of() { "$READELF" -h "$1" 2>/dev/null | awk '/Machine:/{print $2}'; }
[ "$(arch_of "$BINDIR/$APP_NAME")" = AArch64 ] || err "$APP_NAME 不是 AArch64"
"$READELF" -l "$BINDIR/$APP_NAME" | grep -q "Requesting program interpreter: /lib/ld-musl-aarch64.so.1" \
    || err "$APP_NAME 的 PT_INTERP 不是 /lib/ld-musl-aarch64.so.1（elfloader 起不来）"
"$READELF" -d "$BINDIR/$APP_NAME" | grep -q 'Library runpath: \[\$ORIGIN/../lib\]' \
    || warn "$APP_NAME 的 RUNPATH 不是 \$ORIGIN/../lib（依赖可能找不到）"
for l in libwayland-client.so.0 libwayland-cursor.so.0; do
    [ -f "$LIBDIR/$l" ] || warn "闭包里缺 $l（设备上会找不到）"
done

# ── 8. 打包 ────────────────────────────────────────────────
# 目录按 FHS 摆：xkb → usr/share/x11/xkb、weston 数据 → usr/share/weston（XKB_CONFIG_ROOT /
# WESTON_DATA_DIR 指过去）。这两个与上面的 weston-terminal.tar 一起是 **pkg 的三个包**，
# 产出到 dist/pkgs/，由人工上传到包服务器（见 index.json）。
# 只有 fonts/ + fonts.conf 仍进 rawfile（随 HAP 打包；FONTCONFIG_FILE 指文件，
# <dir> 是写死的绝对路径）。
# 源码下到 $BUILD/res-src 缓存（已解压则跳过，离线可复用）。tar 不打压缩。
RES_SRC="$BUILD/res-src"
XKB_DATA_VER="2.42-1"
DEJAVU_VER="2.37"

fetch_res() {   # $1=名字 $2=url $3=解压后判定文件（相对解压根）
    local name="$1" url="$2" stamp="$3"
    [ -e "$RES_SRC/$name/$stamp" ] && return 0
    mkdir -p "$RES_SRC/$name"
    local tgz="$RES_SRC/$name.tar"
    [ -s "$tgz" ] || curl -sL --retry 2 -m 300 -o "$tgz" "$url" || err "下载失败: $url"
    case "$url" in
        *.tar.xz)  tar -xJf "$tgz" -C "$RES_SRC/$name" --strip-components=1 ;;
        *.tar.bz2) tar -xjf "$tgz" -C "$RES_SRC/$name" --strip-components=1 ;;
        *)         tar -xzf "$tgz" -C "$RES_SRC/$name" --strip-components=1 ;;
    esac
    [ -e "$RES_SRC/$name/$stamp" ] || err "解压后缺 $stamp: $name"
}

fetch_deb() {   # $1=名字 $2=url $3=解压后判定文件（deb 根下，如 usr/share/...）
    local name="$1" url="$2" stamp="$3"
    [ -e "$RES_SRC/$name/$stamp" ] && return 0
    command -v dpkg-deb >/dev/null || err "缺 dpkg-deb（解 .deb 需要，Debian/Ubuntu 自带）"
    mkdir -p "$RES_SRC/$name"
    local deb="$RES_SRC/$name.deb"
    [ -s "$deb" ] || curl -sL --retry 2 -m 300 -o "$deb" "$url" || err "下载失败: $url"
    dpkg-deb -x "$deb" "$RES_SRC/$name" || err "解包失败: $deb"
    [ -e "$RES_SRC/$name/$stamp" ] || err "解包后缺 $stamp: $name"
}

log "=== 打包运行时资源（xkb / weston-data / fonts）==="
mkdir -p "$RES_TOOLS"

# xkb：xkb-data 包里的 usr/share/X11/xkb（compat/geometry/keycodes/rules/symbols/types）。
# tar 里改成小写 x11（FHS 惯例，也让设备侧路径整齐）。rules/xorg{,.lst,.xml} 是指向 base* 的
# 符号链接（只有 Xorg DDX 用），而沙箱禁止创建 symlink：解包时 tar 会对它们报 EPERM 并非零退出。
# libxkbcommon 走 evdev 规则，用不到，直接不打进包。
fetch_deb xkb-data \
    "http://deb.debian.org/debian/pool/main/x/xkeyboard-config/xkb-data_${XKB_DATA_VER}_all.deb" \
    "usr/share/X11/xkb/rules/evdev.xml"
rm -rf "$BUILD/res-xkb"; mkdir -p "$BUILD/res-xkb/usr/share/x11"
cp -a "$RES_SRC/xkb-data/usr/share/X11/xkb" "$BUILD/res-xkb/usr/share/x11/xkb"
tar -cf "$PKG_OUT/xkb.tar" --exclude='xkb/rules/xorg*' -C "$BUILD/res-xkb" usr

# weston 窗口装饰按钮（png）→ <sysroot>/usr/share/weston
rm -rf "$BUILD/res-weston"; mkdir -p "$BUILD/res-weston/usr/share/weston"
cp "$WESTON_SRC"/data/*.png "$BUILD/res-weston/usr/share/weston/"
tar -cf "$PKG_OUT/weston-data.tar" -C "$BUILD/res-weston" usr

# 字体：DejaVu Sans Mono（终端等宽）+ fontconfig 配置（<dir> 指向资源根下的 fonts/）
fetch_res dejavu-fonts \
    "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-$DEJAVU_VER.tar.bz2" \
    "ttf/DejaVuSansMono.ttf"
rm -rf "$BUILD/res-fonts"; mkdir -p "$BUILD/res-fonts/fonts"
cp "$RES_SRC/dejavu-fonts/ttf/DejaVuSansMono.ttf" \
   "$RES_SRC/dejavu-fonts/ttf/DejaVuSansMono-Bold.ttf" "$BUILD/res-fonts/fonts/"
cat > "$BUILD/res-fonts/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$SYSROOT_DEFAULT_RT_DIR/fonts</dir>
  <match target="pattern">
    <test name="family"><string>monospace</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>DejaVu Sans Mono</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>sans</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>DejaVu Sans Mono</string></edit>
  </match>
</fontconfig>
EOF
tar -cf "$RES_TOOLS/fonts.tar" -C "$BUILD/res-fonts" fonts fonts.conf

log "✅ 产物："
ls -lh "$OUT_TAR" "$PKG_OUT/xkb.tar" "$PKG_OUT/weston-data.tar" "$RES_TOOLS/fonts.tar" \
    | awk '{print "  " $9 " (" $5 ")"}'
log "  ↑ 前三个是 **pkg 的包**（要上传到 bsh.y1yan.com），最后一个 fonts.tar 随 HAP 打包"
log "  app 目录（$(du -sh "$APPDIR" | cut -f1)）："
(cd "$APPDIR" && find usr -type f | sort | while read -r p; do printf '    %10d  %s\n' "$(stat -c%s "$p")" "$p"; done)
log "  解释器：$("$READELF" -l "$BINDIR/$APP_NAME" | awk '/interpreter/{print $NF}')"
"$READELF" -d "$BINDIR/$APP_NAME" | awk '/NEEDED|RUNPATH/{print "  "$0}'
