#!/bin/sh
# ============================================================================
# ZCode 启动器（由 shell.cpp 从 rawfile 解到 $SYSROOT/bin/zcode）
#
# ZCode 是 Electron 应用（deb 布局 /opt/ZCode/{zcode,resources/app.asar,…}），
# 与 VS Code 同族，所以本脚本是 code.sh 的同构版：差别只在**本体目录与数据目录**。
#   · ZCode 的 deb **不装 /usr/bin/zcode**（postinst 用 update-alternatives 建软链，
#     而沙箱不允许软链），所以 apt 装完不会有代偿启动器 —— 这个脚本就是那根链子。
#   · 依赖用 `apt install --flatten $S/opt/ZCode …` 平铺到**本体目录**里。
#     为什么坚持"本体和依赖同目录"：见 code.sh 文件头那段实测（换个目录就静默 139）。
#
# 安装（用户侧）：
#     cd 到 deb 所在目录
#     apt install --flatten $SYSROOT/opt/ZCode ./ZCode-<版本>-linux-arm64.deb
# ============================================================================

S="${BSH_SYSROOT:-/data/storage/el2/base/haps/tablet/files}"
HOME_DIR="${HOME:-$S/home}"

# 本体目录 = 依赖目录（--flatten 的目标）。两个环境变量留给调试覆盖。
ZC_ROOT="${BSH_ZCODE_ROOT:-$S/opt/ZCode}"
DEPS_ROOT="${BSH_ZCODE_DEPS:-$S/opt/ZCode}"

EXE=""
[ -x "$ZC_ROOT/zcode" ] && EXE="$ZC_ROOT/zcode"

# ── 自检与指引 ─────────────────────────────────────────────────────────────
if [ -z "$EXE" ]; then
    cat <<EOF

╭─ ZCode 未就绪 ───────────────────────────────────────────────────────────
│ 请先手动下载安装包并进行安装！
│
│ 1) 下载官方 arm64 包（请下载 Linux .deb arm64 版本）：
│    https://zcode.z.ai/cn/docs/install#download
│
│ 2) cd 至安装包下载目录，或者拷贝安装包到当前目录，随后执行命令：
│    apt install --flatten \$SYSROOT/opt/ZCode ./ZCode_x.xx.x_arm64.deb
│    即可完成安装。（注：因为一些暂未修复的 bug, --flatten 必须保留。）
╰──────────────────────────────────────────────────────────────────────────
EOF
exit
fi

# ── 环境变量 ───────────────────────────────────────────────────────────────
# 库搜索：ZCode 自带（libEGL/libGLESv2/libffmpeg/libvulkan）→ 平铺进来的依赖。
# ⚠ **不要**把 $S/lib:$S/lib64 插进来 —— 那会让 libc.so.6 命中 bundle 里另一份构建，
#   与装载它的 ld-linux-aarch64.so.1 不配套（详见 code.sh 同一处的长注释）。
LD_LIBRARY_PATH="$ZC_ROOT:$DEPS_ROOT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

# ── xkb 位置修复 ───────────────────────────────────────────────────────────
if [ -d "$S/usr/share/X11" ] && [ ! -e "$S/usr/share/x11" ]; then
    mv "$S/usr/share/X11" "$S/usr/share/x11" && echo "  已改名 usr/share/X11 → usr/share/x11"
fi
XKB_CONFIG_ROOT="$S/usr/share/x11"
XKB_CONFIG_EXTRA_PATH="$S/usr/share/x11/xkb"
export XKB_CONFIG_ROOT XKB_CONFIG_EXTRA_PATH

# ── gschemas.compiled 的兜底 ───────────────────────────────────────────────
BOOT_SCHEMAS="$S/usr/share/glib-2.0/schemas/gschemas.compiled"
if [ ! -e "$BOOT_SCHEMAS" ] && [ -e "$(dirname "$0")/gschemas.compiled" ]; then
    mkdir -p "$(dirname "$BOOT_SCHEMAS")" 2>/dev/null
    cp "$(dirname "$0")/gschemas.compiled" "$BOOT_SCHEMAS" 2>/dev/null \
        && echo "[zcode] 用随包兜底的 gschemas.compiled 顶上"
fi
GSETTINGS_SCHEMA_DIR=""
for d in "$DEPS_ROOT/share/glib-2.0/schemas" "$ZC_ROOT/share/glib-2.0/schemas" "$S/usr/share/glib-2.0/schemas"; do
    [ -d "$d" ] || continue
    GSETTINGS_SCHEMA_DIR="${GSETTINGS_SCHEMA_DIR:+$GSETTINGS_SCHEMA_DIR:}$d"
done
[ -n "$GSETTINGS_SCHEMA_DIR" ] && export GSETTINGS_SCHEMA_DIR

XDG_DATA_DIRS="$DEPS_ROOT/share:$ZC_ROOT/share:$S/usr/share"
export XDG_DATA_DIRS

SHELL=/bin/sh
export SHELL

# ── gdk-pixbuf loaders.cache ───────────────────────────────────────────────
L="$DEPS_ROOT/gdk-pixbuf-2.0/2.10.0/loaders"
CACHE="$DEPS_ROOT/gdk-pixbuf-2.0/2.10.0/loaders.cache"
gen_cache() {
    [ -d "$L" ] || return 1
    {
        echo '# GdkPixbuf Image Loader Modules file'
        echo '# Automatically generated file, do not edit'
        echo '# Created by BetterSH launcher'
        echo '#'
        for m in "$L"/libpixbufloader-*.so; do
            [ -f "$m" ] || continue
            b=${m##*/}; n=${b#libpixbufloader-}; n=${n%.so}
            case "$n" in
                ani)  mi='application/x-navi-animation'; ex='ani' ;;
                bmp)  mi='image/bmp image/x-bmp'; ex='bmp' ;;
                gif)  mi='image/gif'; ex='gif' ;;
                icns) mi='image/x-icns'; ex='icns' ;;
                ico)  mi='image/x-icon image/ico image/x-ico image/icon image/x-win-bitmap application/ico text/ico'; ex='ico' ;;
                pnm)  mi='image/x-portable-anymap image/x-portable-bitmap image/x-portable-graymap image/x-portable-pixmap'; ex='pnm pbm pgm ppm' ;;
                qtif) mi='image/x-quicktime image/qtif'; ex='qtif' ;;
                tga)  mi='image/x-tga'; ex='tga' ;;
                tiff) mi='image/tiff'; ex='tiff tif' ;;
                xbm)  mi='image/x-bitmap image/x-xbitmap'; ex='xbm' ;;
                xpm)  mi='image/x-xpixmap'; ex='xpm' ;;
                *) continue ;;
            esac
            qmi=''; for t in $mi; do qmi="$qmi\"$t\" "; done
            qex=''; for t in $ex; do qex="$qex\"$t\" "; done
            echo "\"$m\""
            echo "\"$n\" 4 \"gdk-pixbuf\" \"BetterSH bundled loader\" \"LGPL\""
            echo "$qmi\"\""
            echo "$qex\"\""
            echo
        done
    } > "$CACHE" 2>/dev/null
}
gen_cache || true
if [ -s "$CACHE" ]; then
    GDK_PIXBUF_MODULE_FILE="$CACHE"
    export GDK_PIXBUF_MODULE_FILE
fi
unset GDK_PIXBUF_MODULEDIR

# ── 用户状态 ───────────────────────────────────────────────────────────────
USER_DATA="${BSH_ZCODE_UD:-$HOME_DIR/.zcode-bsh}"

# ── CLI 子命令：拿 Electron 当 node 跑 out/cli.js（不开窗口）────────────────
case "${1-}" in
    --version|-v|--help|-h|--status|--list-extensions|--show-versions|\
    --install-extension|--uninstall-extension|--update-extensions|tunnel|serve-web|\
    --locate-shell-integration-path)
        ELECTRON_RUN_AS_NODE=1
        export ELECTRON_RUN_AS_NODE
        exec "$EXE" "$ZC_ROOT/resources/app/out/cli.js" "$@"
        ;;
esac

# ── 启动 GUI ───────────────────────────────────────────────────────────────
# 开关与理由同 code.sh（ozone=wayland / no-zygote / no-sandbox / in-process-gpu…）。
set --
[ "${BSH_ZCODE_NO_OZONE:-0}" = 1 ] || set -- --ozone-platform="${BSH_OZONE:-wayland}"
[ "${BSH_ZCODE_NO_DISABLE_GPU:-0}" = 1 ] || set -- --disable-gpu "$@"
[ "${BSH_ZCODE_NO_INPROC_GPU:-0}" = 1 ] || set -- --in-process-gpu "$@"
set -- --no-zygote "$@"
set -- --disable-gpu-sandbox "$@"
set -- --disable-seccomp-filter-sandbox "$@"
set -- --no-sandbox "$@"
set -- --disable-dev-shm-usage "$@"
set -- --user-data-dir="$USER_DATA" "$@"
[ -n "${BSH_ZCODE_EXTRA:-}" ] && set -- $BSH_ZCODE_EXTRA "$@"
exec "$EXE" "$@"
