#!/bin/sh
# ============================================================================
# VS Code 启动器（由 shell.cpp 从 rawfile 解到 $SYSROOT/bin/code）
#
# 职责：自检资源并在缺失时给出**可照做的下载指引**；② 摆好一整套环境变量；
#       ③ 用正确的可执行文件和必需的 Chromium 开关启动。
# ============================================================================

S="${BSH_SYSROOT:-/data/storage/el2/base/haps/tablet/files}"
HOME_DIR="${HOME:-$S/home}"

# VS Code 本体：**必须和依赖同目录**（usr/lib/vscode）。
# 实测（阶段 s1a / s2a / s2a2 / s2a3 / s2b2）：同一个 code 二进制、同样的 LD_LIBRARY_PATH，
#   · 从 $S/usr/lib/vscode/code 起  -> 出窗口
#   · 从 $S/usr/lib/code/code 起    -> 静默 SIGSEGV(139)（协议层正常，抓不到回溯）
# 把本体 mv 过去、或复制一份过去、原件保留，三种做法后者都是 139，所以不是"缺文件"，
# 而是"本体所在目录"本身。既然依赖解包落在 usr/lib/vscode，本体也放这儿最省事。
VSCODE_ROOT="${BSH_VSCODE_ROOT:-$S/usr/lib/vscode}"
# 依赖与数据：113 个系统库 + share/{mime,icons,glib-2.0/schemas} + gdk-pixbuf/gtk-3.0
DEPS_ROOT="${BSH_VSCODE_DEPS:-$S/usr/lib/vscode}"

# ── code 可执行文件位置修复 ───────────────────────────────────────────────
# 为什么非铺不可：本体留在 usr/share/code（依赖在 usr/lib/vscode）时，code 一跑就静默
# SIGSEGV(139)，日志停在 "Failed to initialize drm render node handle" 之后什么都没有。
# 东西得真放在一个目录里。bug 的原因留作以后再查找
if [ -x "$S/usr/share/code/code" ] && [ ! -x "$S/usr/lib/vscode/code" ]; then
    echo "  铺 usr/share/code → $S/usr/lib/vscode（tar 管道；软链会被沙箱拒，忽略）"
    ( cd "$S/usr/share/code" && tar cf - . ) | ( cd "$S/usr/lib/vscode" && tar xf - ) 2>/dev/null
    chmod 755 "$S/usr/lib/vscode/code/code" 2>/dev/null
fi

# 真正的可执行文件（见文件头那条纪律）
if [ -x "$VSCODE_ROOT/code" ]; then
    EXE="$VSCODE_ROOT/code"
elif [ -x "$VSCODE_ROOT/bin/code" ]; then
    EXE="$VSCODE_ROOT/bin/code"      # 兜底：万一是别的打包方式
else
    EXE=""
fi

# ── 自检与指引 ─────────────────────────────────────────────────────────────
miss=0
if [ -z "$EXE" ]; then
    miss=1
    cat <<EOF

╭─ VS Code 未就绪 ─────────────────────────────────────────────────────────
│ 请先手动下载安装包并进行安装！
│
│ 1) 下载官方 arm64 包（请下载 Linux .deb arm64 版本）：
│    https://code.visualstudio.com/Download
│
│ 2) cd 至安装包下载目录，或者拷贝安装包到当前目录，随后执行命令：
│    apt install --flatten \$SYSROOT/usr/lib/vscode ./code_x.xxx.x-xxx_arm64.deb
│    即可完成安装。（注：因为一些暂未修复的 bug, --flatten 必须保留。）
╰──────────────────────────────────────────────────────────────────────────
EOF
exit
fi

# ── 环境变量 ───────────────────────────────────────────────────────────────
# 库搜索：VS Code 自己 → 依赖目录。
# ⚠ **不要**在这里写 `$S/lib:$S/lib64` —— 那会把它们插到 procmgr 给 guest 准备的
#   bundle libs **前面**，于是 libc.so.6 命中 `$S/lib` 里那份（1.5MB，另一份构建），
#   而 glibc 程序是由 bundle 的 ld-linux-aarch64.so.1 装载的：ld.so 与 libc 不配套，
#   TLS/内部 ABI 就对不上 —— 多模块的 glibc 程序（glib/gtk 那一族）会在
#   `____strtod_l_internal` 里 SIGSEGV（x3 = locale = NULL，从 TLS 读到 0）。
#   实测 `glib-compile-schemas` 正是这么挂的，而单模块的小程序碰巧看不出来。
#   libc/libm/libdl/libpthread 一律由 bundle libs 提供（procmgr 每次 fork 都会 prepend）。
LD_LIBRARY_PATH="$VSCODE_ROOT:$DEPS_ROOT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

# ── xkb 位置修复 ───────────────────────────────────────────────────────────
# 因为之前可能是手误，x11 默认位置有误，此时必须修改一下才能正常运行。
# 后续再对这个问题进行修复。
if [ -d "$S/usr/share/X11" ] && [ ! -e "$S/usr/share/x11" ]; then
    mv "$S/usr/share/X11" "$S/usr/share/x11" && echo "  已改名 usr/share/X11 → usr/share/x11"
fi

# ── xkb 数据的位置 ───────────────────────────────────────────────────────────
# libxkbcommon 把 include path 硬编码成 /usr/share/X11/xkb（沙箱里没有这个路径），
# 而我们的数据在 $S/usr/share/x11/xkb。它有两条环境变量可走：
#   XKB_CONFIG_ROOT        —— 它是**父目录**：xkbcommon 会在其下再拼 "xkb"，
#                             所以要给 $S/usr/share/x11（给成 …/x11/xkb 的话它会去找
#                             …/x11/xkb/xkb，等于白设 —— 之前就是这么错过的）
#   XKB_CONFIG_EXTRA_PATH  —— 额外的 include path，给到 …/x11/xkb 本身
# 两个都设、互为兜底：只设一个时要看那版的拼接规则，两个都给它就总有一条对得上。
XKB_CONFIG_ROOT="$S/usr/share/x11"
XKB_CONFIG_EXTRA_PATH="$S/usr/share/x11/xkb"
export XKB_CONFIG_ROOT XKB_CONFIG_EXTRA_PATH

# ── gschemas.compiled 的兜底 ───────────────────────────────────────────────
# GTK 初始化必须能读到 gschemas.compiled，而它是**装包时由 dpkg trigger 生成**的
# （`.gschema.xml` 的编译产物），deb 里没有 —— 正常路径是 `code --download` 在设备上
# 调 glib-compile-schemas 现编。但设备上那条路实测会崩（libglib 里调 strtod 时
# locale 参数为 NULL，见 STATUS「VS Code 依赖链」§2b），所以这里留一份**随包走**的
# 兜底：内容就是同一个 `glib-compile-schemas` 在宿主上对同一批 .gschema.xml 编出来的
# 产物（2.3KB）。设备侧一旦编成功会覆盖它，坏了也不影响 —— 免得整个 GTK 起不来。
BOOT_SCHEMAS="$S/usr/share/glib-2.0/schemas/gschemas.compiled"
if [ ! -e "$BOOT_SCHEMAS" ] && [ -e "$(dirname "$0")/gschemas.compiled" ]; then
    mkdir -p "$(dirname "$BOOT_SCHEMAS")" 2>/dev/null
    cp "$(dirname "$0")/gschemas.compiled" "$BOOT_SCHEMAS" 2>/dev/null \
        && echo "[code] 用随包兜底的 gschemas.compiled 顶上（设备侧 glib-compile-schemas 没编出来）"
fi

# GTK 初始化必须能读到 gschemas.compiled，否则 gtk_init 直接 abort。
# 三种布局都可能：依赖目录下、VS Code 目录下、以及 sysroot 的 usr/share（`code --download`
# 走的就是最后一种 —— 它按 deb 里的原路径把 usr/share/** 落到 $SYSROOT）。
# 只把**真实存在**的目录拼进去：设成不存在的路径会让 GLib 一个 schema 都找不到。
GSETTINGS_SCHEMA_DIR=""
for d in "$DEPS_ROOT/share/glib-2.0/schemas" "$VSCODE_ROOT/share/glib-2.0/schemas" "$S/usr/share/glib-2.0/schemas"; do
    [ -d "$d" ] || continue
    GSETTINGS_SCHEMA_DIR="${GSETTINGS_SCHEMA_DIR:+$GSETTINGS_SCHEMA_DIR:}$d"
done
[ -n "$GSETTINGS_SCHEMA_DIR" ] && export GSETTINGS_SCHEMA_DIR

# GIO 找 shared-mime-info 与图标主题。**缺它连 PNG 都认不出来**：
#   gdk-pixbuf 选 loader 不是靠魔数嗅探，而是 g_content_type_guess() 猜 mime → 按 mime 找模块；
#   猜不出 image/png → 找不到 loader → GTK 连自带兜底图标都加载不了 → Bail out! → abort。
XDG_DATA_DIRS="$DEPS_ROOT/share:$VSCODE_ROOT/share:$S/usr/share"
export XDG_DATA_DIRS

# glibc 侧 exec shim 对**裸名**不做 PATH 查找（musl 侧做），SHELL 给绝对路径才不会 ENOENT
SHELL=/bin/sh
export SHELL

# ── 运行时生成 gdk-pixbuf 的 loaders.cache ─────────────────────────────────
# debian 的 loaders.cache 是**装包时由 dpkg trigger 生成**的，.deb/tar 里根本没有；
# 不设 GDK_PIXBUF_MODULE_FILE 时 gdk-pixbuf 会去读编译进去的默认路径，那条错误路径上
# 会 g_error_new_literal(NULL) → GLib 断言 → **SIGSEGV**。所以这里必须造一份真实存在的。
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
unset GDK_PIXBUF_MODULEDIR     # 设了会触发"按目录重建缓存"那条逻辑，反而更糟

# ── 用户状态 ───────────────────────────────────────────────────────────────
# 目前存在的 bug: 旧的 $HOME/.vscode 存在会导致启动失败，每次启动之前先移走
if [ -e "$HOME_DIR/.vscode" ] && [ "${BSH_VSCODE_KEEP_STATE:-0}" != 1 ]; then
    mv "$HOME_DIR/.vscode" "$HOME_DIR/.vscode.bak-$(date +%s)" 2>/dev/null \
        && echo "[code] 已把旧的 \$HOME/.vscode 挪到 .vscode.bak-*（避免「第二次起不来」）"
fi
# 用我们自己的数据目录，避开 VS Code 默认的 ~/.config/Code
USER_DATA="${BSH_VSCODE_UD:-$HOME_DIR/.code-bsh}"

# ── CLI 子命令：拿 Electron 当 node 跑 out/cli.js（不开窗口）────────────────
case "${1-}" in
    --version|-v|--help|-h|--status|--list-extensions|--show-versions|\
    --install-extension|--uninstall-extension|--update-extensions|tunnel|serve-web|\
    --locate-shell-integration-path)
        ELECTRON_RUN_AS_NODE=1
        export ELECTRON_RUN_AS_NODE
        exec "$EXE" "$VSCODE_ROOT/resources/app/out/cli.js" "$@"
        ;;
esac

# ── 启动 GUI ───────────────────────────────────────────────────────────────
# 逐个开关的理由（都不是可选项）：
#   --ozone-platform=wayland  沙箱里只有 wayland，没有 X11/XWayland
#   --disable-gpu             没有 DRI；Chromium 走 SwiftShader（包里自带 libEGL/libGLESv2）
#   --in-process-gpu          否则另起 GPU 进程会在 sandbox/linux/services/proc_util.cc:114
#                             FATAL（读 /proc 被沙箱拒）→ 进程直接挂
#   --no-zygote               **关键**：zygote 只拿到 "0 fork delegates"，渲染器
#                             launch-failed(1002) → 窗口只有 1 帧背景、内容全黑
#   --no-sandbox              chrome-sandbox 要 setuid root + 用户命名空间，都没有
#   --disable-*-sandbox       同上
#   --disable-dev-shm-usage   设备的 /dev/shm 不可用
# ${BSH_VSCODE_EXTRA:-} **故意不加引号**：它按空白拆成多个开关（调试用，产品路径不设它）。
# 空的时候展开成零个参数。用它可以试 --use-gl=swiftshader 这类，而不必改这个文件。
# 开关**逐个前置**（set -- 前置比拼接字符串安全：值里有空格也不会被拆错）。
#   环境变量可以单独去掉某一个 —— 这几个开关是在"依赖来自我们托管的那份闭包"时
#   试出来的，现在依赖来自 deb 闭包 + 本体自带，未必还合适，得能单独验：
#     BSH_VSCODE_NO_DISABLE_GPU=1   不加 --disable-gpu
#     BSH_VSCODE_NO_INPROC_GPU=1    不加 --in-process-gpu
# 平台：BSH_VSCODE_NO_OZONE=1 时**整个开关都不传** —— 让 Chromium 自己选。
# 依据是"成功那轮"的真实命令（build/autorun.SUCCESS-from-backup.sh 第 198-200 行）
# 里根本没有 --ozone-platform，也没有 --disable-gpu。这两个是我后来加的，嫌疑最大。
set --
[ "${BSH_VSCODE_NO_OZONE:-0}" = 1 ] || set -- --ozone-platform="${BSH_OZONE:-wayland}"
[ "${BSH_VSCODE_NO_DISABLE_GPU:-0}" = 1 ] || set -- --disable-gpu "$@"
[ "${BSH_VSCODE_NO_INPROC_GPU:-0}" = 1 ] || set -- --in-process-gpu "$@"
set -- --no-zygote "$@"
set -- --disable-gpu-sandbox "$@"
set -- --disable-seccomp-filter-sandbox "$@"
set -- --no-sandbox "$@"
set -- --disable-dev-shm-usage "$@"
set -- --user-data-dir="$USER_DATA" "$@"
# 外部追加的开关（调试用）：${BSH_VSCODE_EXTRA:-} **故意不加引号** —— 它按空白拆成多个
# 开关，空的时候展开成零个参数。
[ -n "${BSH_VSCODE_EXTRA:-}" ] && set -- $BSH_VSCODE_EXTRA "$@"
exec "$EXE" "$@"
