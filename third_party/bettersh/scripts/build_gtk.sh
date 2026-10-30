#!/bin/bash
# build_gtk.sh — GTK3（**只编 wayland 后端**）交叉编成 aarch64-ohos 的共享库，外加一个窗口探针
#
# 为什么做这件事：要判断"我们的合成器能不能承载一个真实 GUI 工具链"。桌面版 VS Code 是
# Electron（GTK/X11 栈）—— **GTK3 起不来，Electron 一定起不来**；GTK3 起来了，后面还有
# 一大截（Chromium 的 ozone-wayland、闭包、沙箱、渲染）。所以先拿 GTK3 当探针，它给出的
# 结论比任何推断都硬。
#
# 为什么只编 wayland 后端：这台设备**完全没有 X11/XWayland**（`scripts/build_weston_deps.sh`
# 那套里连 libX11 都没有），GTK3 的 X11 后端拿来也没用。而 GTK3 的 wayland 后端本来就用
# **wl_shm**（dmabuf 是 GTK4 才默认），我们的合成器正好有 wl_shm —— 也就是说协议面基本够，
# 缺的主要是 `wl_data_device_manager`（剪贴板/拖拽）这类可选项。
#
# ── 依赖分层：能复用的一个不重编 ──────────────────────────────────────────────
# 已有（build_weston_deps.sh / build_wayland.sh 的产物，都在 $SYSROOT_EXT，带 .pc 与头文件）：
#   glib/gobject/gio/gmodule/gthread、cairo、pixman、fontconfig、freetype、expat、
#   libpng/libjpeg/libwebp/zlib/pcre2/libffi、xkbcommon、
#   wayland-client / wayland-cursor / wayland-egl / wayland-server
# 本脚本补（按依赖顺序）：
#   wayland-protocols（只有 XML + .pc，GTK3 要用它生成协议代码）
#   → fribidi → harfbuzz → pango → gdk-pixbuf → atk → libepoxy → gtk+3
#
# 全部装到 $SYSROOT_EXT/usr（与 weston-deps 同一套布局），libdir 用 `lib/$TARGET` ——
# 这样已装的 .pc 与新装的在同一目录里互相找得到，pkg-config 一条 PKG_CONFIG_LIBDIR 就够。
#
# ── 几个刻意的选择 ────────────────────────────────────────────────────────
# * **共享库**（不是静态）：GTK3 这套必须共享 —— gtk3 依赖 gdk-pixbuf 的模块式结构、
#   而闭包最终要按 NEEDED 收集成"平铺目录 + ld.so 找得到"的形态（同 build_qtwl_demo.sh）。
# * gdk-pixbuf 用 `-Dbuiltin_loaders=all`：默认它把 PNG/JPEG 的 loader 装成**动态模块**
#   再靠 `loaders.cache` 找，而我们这套是平铺目录、没有 GDK_PIXBUF_MODULE_FILE，
#   直接内建进库里最省事（探针只需要能显示文字/图片）。
# * `-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0`：OHOS musl 的 fortify 会把 FD_SET 之类展开成
#   `__fd_chk`（它私有的越界检查），而 guest 跑的是 bundle 里那份 **vanilla musl**，
#   没这个符号 → 运行期 `Error relocating`。与 devtools/git 同一条理由。
# * `-D_FORTIFY_SOURCE=0` 之外还关掉 introspection/文档/测试/demos：它们要么需要
#   gobject-introspection（要跑目标程序，交叉编译下不可行），要么纯粹是体积。
#
# 用法：./scripts/build_gtk.sh [deps|gtk|probe|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"

SRC_ROOT="$BUILD_DIR/gtk-src"
BLD_ROOT="$BUILD_DIR/gtk-bld"
LOG_ROOT="$BUILD_DIR/gtk-logs"
CROSS="$BUILD_DIR/gtk-cross.ini"
mkdir -p "$SRC_ROOT" "$BLD_ROOT" "$LOG_ROOT"

# 复用已有的那批 .pc（weston-deps/wayland 装的），**别让宿主那份混进来**：
# PKG_CONFIG_LIBDIR 会覆盖默认搜索路径。
# ⚠ 三个目录都要列出来：PKG_CONFIG_LIBDIR 一旦设了就**替代**默认搜索路径，少一个就找不到。
#   * $SYSROOT_EXT_LIB/pkgconfig  —— 绝大多数（weston-deps / 本脚本编的）
#   * $SYSROOT_EXT/usr/share/pkgconfig —— **架构无关**的包（wayland-protocols 装这儿）
#   * $SYSROOT_EXT_PC            —— env.sh 里那个（历史上可能用过的位置，兜底）
export PKG_CONFIG_LIBDIR="$SYSROOT_EXT_LIB/pkgconfig:$SYSROOT_EXT/usr/share/pkgconfig:$SYSROOT_EXT_PC"
# PKG_CONFIG_PATH 排在 LIBDIR **之前**，所以这里只放一个东西：宿主那份
# wayland-scanner.pc（build_wayland.sh 编的 host-tools）。交叉编译时**扫描器必须跑在
# 宿主机上** —— meson 的 `dependency('wayland-scanner')` 在 build machine 上找它，
# 而目标 sysroot 里只有 libwayland 的库、没有扫描器（GTK3 生成协议代码要用）。
# ⚠ 这个目录里**只能有 wayland-scanner.pc**：PATH 优先于 LIBDIR，同名 .pc 会把它盖掉
#    （比如在那儿放个 glib-2.0.pc，交叉构建就会链到宿主 x86_64 的 glib）。
_HP="$HOST_TOOLS/lib/pkgconfig"
if [ -d "$_HP" ]; then
    _extra="$(ls "$_HP" | grep -v '^wayland-scanner\.pc$' || true)"
    [ -z "$_extra" ] || err "$_HP 里除了 wayland-scanner.pc 还有别的 .pc（$_extra）——
  它在 PKG_CONFIG_PATH 里会**盖掉**同名目标库，先清掉再来"
    export PKG_CONFIG_PATH="$_HP"
else
    export PKG_CONFIG_PATH=""
fi
# 目标三元组的 pkg-config 结果里带的是**宿主绝对路径**（.pc 的 prefix 就是 $SYSROOT_EXT/usr），
# 所以**不要**设 PKG_CONFIG_SYSROOT_DIR —— 那会给它们再套一层前缀。
unset PKG_CONFIG_SYSROOT_DIR

# ── 就地把静态库的 .pc 补对 ────────────────────────────────────────────────
# 我们这批底层库是**静态**的（build_weston_deps.sh 用 --disable-shared 编的），
# 而 fontconfig 的 .pc 把 expat 写在 `Requires.private` 里 —— 那是"动态链接时不需要、
# 静态链接才需要"的写法，pkg-config 只有加 `--static` 才会带出来。于是任何用 pkg-config
# 链 fontconfig 的现代构建都会缺 XML_* 符号：
#     ld.lld: error: undefined symbol: XML_ParserCreate
#     >>> referenced by fcxml.c ... in archive .../libfontconfig.a
# （pango 的 meson 就是这么挂的：`cairo-ft does not have the required FontConfig support`
#   其实是这条链不上，报错信息误导得很。）
# build_weston_terminal.sh 之所以一直没事：它的链接行是**手写**的，-lfontconfig 后面
# 直接跟了 -lexpat。静态库本来就该把依赖写在 `Requires` 里 —— 就地补，幂等。
fix_static_pc() {
    local pc="$SYSROOT_EXT_LIB/pkgconfig/fontconfig.pc"
    [ -f "$pc" ] || return 0
    grep -q '^Requires:.*expat' "$pc" && return 0
    python3 - "$pc" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# Requires:  <a>            ← 追加 expat
# Requires.private:  expat  ← 去掉（已经挪到上面了）
s = re.sub(r'^Requires:(?!.*\bexpat\b)(.*)$', lambda m: 'Requires:' + m.group(1).rstrip() + ' expat\n', s, count=1, flags=re.M)
s = re.sub(r'^Requires\.private:\s*expat\s*$', 'Requires.private:', s, count=1, flags=re.M)
open(p, 'w', encoding='utf-8').write(s)
print('    已把 expat 从 Requires.private 挪到 Requires：' + p)
PY
}

# ── meson 交叉文件 ────────────────────────────────────────────────────────
# meson 的交叉支持靠这个；编译器/ar/strip 全用 SDK clang 那套，flags 里带 target+sysroot。
# `needs_exe_wrapper = true`：交叉编译时不许 meson 去**运行**目标程序做探测。
write_cross() {
    cat > "$CROSS" <<EOF
[binaries]
c = '$CLANG'
cpp = '$CLANGXX'
ar = '$CLANG_DIR/llvm-ar'
strip = '$CLANG_DIR/llvm-strip'
pkg-config = '/usr/bin/pkg-config'
# ── build-time 工具必须指到**宿主**那份 ────────────────────────────────
# meson 的 gnome 模块（compile_resources / g_schema_compile）会先查 machine file 的
# `[binaries]`，查不到才退到 glib-2.0.pc 的 `bindir` —— 而那是**目标**的 bin，
# 于是它去跑 aarch64 的 glib-compile-resources，宿主上直接炸：
#     FAILED: gtk/et.gresource
#     aarch64-binfmt-P: Could not open '/lib/ld-musl-aarch64.so.1'
# 这类"构建期要跑的工具"在交叉编译里都得指向宿主那份（宿主有 glib 2.80 的这几个）。
wayland-scanner = '$HOST_TOOLS/bin/wayland-scanner'
glib-compile-resources = '/usr/bin/glib-compile-resources'
glib-compile-schemas = '/usr/bin/glib-compile-schemas'
glib-mkenums = '/usr/bin/glib-mkenums'
glib-genmarshal = '/usr/bin/glib-genmarshal'
gtk-update-icon-cache = '/usr/bin/gtk-update-icon-cache'

[built-in options]
c_args = ['--target=$TARGET', '--sysroot=$SYSROOT', '-U_FORTIFY_SOURCE', '-D_FORTIFY_SOURCE=0', '-D__MUSL__', '-DOHOS_NDK']
c_link_args = ['--target=$TARGET', '--sysroot=$SYSROOT', '-fuse-ld=lld']
cpp_args = ['--target=$TARGET', '--sysroot=$SYSROOT', '-U_FORTIFY_SOURCE', '-D_FORTIFY_SOURCE=0', '-D__MUSL__', '-DOHOS_NDK']
cpp_link_args = ['--target=$TARGET', '--sysroot=$SYSROOT', '-fuse-ld=lld']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
}

fetch() {   # $1=解压后的目录名 $2=tarball 名 $3..=候选 URL
    local dir="$1" tar="$2"; shift 2
    [ -d "$SRC_ROOT/$dir" ] && return 0
    [ -s "$SRC_ROOT/$tar" ] || {
        log "下载 $tar"
        local u ok=
        for u in "$@"; do
            if curl -sL --retry 3 -m 900 -o "$SRC_ROOT/$tar.part" "$u" && [ -s "$SRC_ROOT/$tar.part" ]; then
                mv "$SRC_ROOT/$tar.part" "$SRC_ROOT/$tar"; ok=1; break
            fi
        done
        [ -n "$ok" ] || err "下载失败：$tar"
    }
    mkdir -p "$SRC_ROOT/$dir"
    case "$tar" in
        *.tar.xz) tar xJf "$SRC_ROOT/$tar" -C "$SRC_ROOT/$dir" --strip-components=1 ;;
        *)        tar xzf "$SRC_ROOT/$tar" -C "$SRC_ROOT/$dir" --strip-components=1 ;;
    esac
}

# meson_pkg <名字> <已装好的 .pc 名> <源码目录> <tarball> <URL...> -- <meson 选项...>
meson_pkg() {
    local name="$1" pc="$2" dir="$3" tar="$4"; shift 4
    local urls=()
    while [ "$1" != "--" ]; do urls+=("$1"); shift; done
    shift
    if [ -f "$SYSROOT_EXT_LIB/pkgconfig/$pc.pc" ] || [ -f "$SYSROOT_EXT_PC/$pc.pc" ]; then
        log "已有 $pc（跳过 $name）"
        return 0
    fi
    fetch "$dir" "$tar" "${urls[@]}"
    log "=== 配置+编译 $name ==="
    rm -rf "$BLD_ROOT/$name"
    PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR" meson setup "$BLD_ROOT/$name" "$SRC_ROOT/$dir" \
        --cross-file "$CROSS" \
        --prefix="$SYSROOT_EXT/usr" \
        --libdir="lib/$TARGET" \
        --includedir=include \
        --buildtype=release \
        "$@" > "$LOG_ROOT/$name-setup.log" 2>&1 \
        || { tail -30 "$LOG_ROOT/$name-setup.log" >&2; err "$name: meson setup 失败（$LOG_ROOT/$name-setup.log）"; }
    ninja -C "$BLD_ROOT/$name" > "$LOG_ROOT/$name-build.log" 2>&1 \
        || { tail -40 "$LOG_ROOT/$name-build.log" >&2; err "$name: 编译失败（$LOG_ROOT/$name-build.log）"; }
    ninja -C "$BLD_ROOT/$name" install > "$LOG_ROOT/$name-install.log" 2>&1 \
        || { tail -30 "$LOG_ROOT/$name-install.log" >&2; err "$name: 安装失败（$LOG_ROOT/$name-install.log）"; }
    log "✓ $name"
}

# ══ 1. deps ═══════════════════════════════════════════════════════════════
do_deps() {
    write_cross
    fix_static_pc
    # 前置：已有那几层必须在。缺了就地报出来（否则会编到 pango/gtk 才炸，日志翻半天）。
    local miss=""
    # 注意**没有 cairo**：它从"共享 cairo"那次改动起就归本脚本管了（下面自己会重编）。
    for pc in glib-2.0 gobject-2.0 gio-2.0 fontconfig freetype2 libpng \
              wayland-client wayland-cursor xkbcommon; do
        [ -f "$SYSROOT_EXT_LIB/pkgconfig/$pc.pc" ] || miss="$miss $pc"
    done
    [ -z "$miss" ] || err "缺这些已有依赖的 .pc：$miss
  先跑 scripts/build_weston_deps.sh 与 scripts/build_wayland.sh"
    log "已有依赖：$(ls "$SYSROOT_EXT_LIB/pkgconfig" | grep -c '\.pc$') 个 .pc 在 $SYSROOT_EXT_LIB/pkgconfig"

    # ── cairo-gobject：GTK3 的硬依赖，而我们手上这份 cairo 没有 ───────────────
    # build_weston_deps.sh 编 cairo 时是 `-Dglib=disabled`，而 cairo 1.18 的 `glib`
    # 开关就是 cairo-gobject（GObject 类型注册）。GTK3 要在 GObject 属性里用 cairo 类型，
    # 少了它 meson 直接报 `Dependency "cairo-gobject" not found`。
    #
    # 按**与 weston-deps 完全相同的口径**重编（同一份源码树、同一套 cross 文件、
    # 同样 `--default-library=static`），只多开 `-Dglib=enabled`：
    #   * **必须是共享库**（这是第一版的教训）：cairo 静态链进去之后，
    #     libgdk-3.so / libpangocairo-1.0.so / libgtk-3.so **各带一份 cairo 及其全局
    #     缓存**，而 GTK 会把一个副本创建的 cairo 对象交给另一个副本用 ——
    #     实测在设备上跑到"给窗口画内容"那一步直接炸：
    #         Assertion failed: !"reached" (cairo-1.18.0/src/cairo-hash.c:
    #                                    _cairo_hash_table_lookup: 374)
    #         [crash] signal=6  in=/lib/ld-musl-aarch64.so.1   ← __assert_fail → abort
    #     （那个断言是"遍历整张表既没命中也没找到空槽"，典型的表被并发/多副本搞坏。）
    #     取证：libgdk-3.so.0 的 NEEDED 里**没有** libcairo，可它却崩在 cairo 的
    #     源码行上 —— cairo 就是编在它里面的。
    #     weston-terminal/qtwl-demo 不受影响：它们按 NEEDED 收闭包，会自动把
    #     libcairo.so.2 一起带走（而眼前这份已构建好的包保持静态内嵌，也照常能用）。
    #   * 复用 weston-deps 那份源码树：它已经被 sed 掉了 csi-replay/csi-exec/csi-trace
    #     那几个**构建期宿主工具**（交叉链静态 fontconfig 时缺 XML_* 符号）。
    if [ ! -f "$SYSROOT_EXT_LIB/pkgconfig/cairo-gobject.pc" ] || [ ! -f "$SYSROOT_EXT_LIB/libcairo.so" ]; then
        local csrc="$BUILD_DIR/weston-deps-src/cairo-1.18.0"
        local cbd="$BLD_ROOT/cairo-gobject"
        [ -f "$csrc/meson.build" ] || err "缺 $csrc（先跑 scripts/build_weston_deps.sh）"
        log "=== 重编 cairo（-Dglib=enabled，只加 cairo-gobject）==="
        rm -rf "$cbd"; mkdir -p "$cbd"
        cat > "$cbd/cross.txt" <<EOF
[binaries]
c          = ['$CLANG', '--target=$TARGET', '--sysroot=$SYSROOT']
cpp        = ['$CLANGXX', '--target=$TARGET', '--sysroot=$SYSROOT']
ar         = '$CLANG_DIR/llvm-ar'
strip      = '$CLANG_DIR/llvm-strip'
ranlib     = '$CLANG_DIR/llvm-ranlib'
pkg-config = 'pkg-config'
[built-in options]
c_args    = ['-O2', '-fPIC', '-D__MUSL__', '-DOHOS_NDK', '-I$SYSROOT_EXT_INC']
cpp_args  = ['-O2', '-fPIC', '-D__MUSL__', '-DOHOS_NDK', '-I$SYSROOT_EXT_INC']
c_link_args   = ['-L$SYSROOT_EXT_LIB']
cpp_link_args = ['-L$SYSROOT_EXT_LIB']
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$SYSROOT_EXT_PC:$SYSROOT_EXT_LIB/pkgconfig'
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
        env -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR \
            PKG_CONFIG_PATH="$SYSROOT_EXT_PC:$SYSROOT_EXT_LIB/pkgconfig" \
            meson setup "$cbd/build" "$csrc" \
                --cross-file "$cbd/cross.txt" \
                --prefix="$SYSROOT_EXT/usr" --libdir="lib/$TARGET" \
                --default-library=shared \
                -Dglib=enabled -Dxlib=disabled -Dxcb=disabled -Ddwrite=disabled \
                -Dquartz=disabled -Dtee=disabled -Dspectre=disabled \
                -Dtests=disabled -Dfontconfig=enabled -Dfreetype=enabled -Dpng=enabled \
                > "$LOG_ROOT/cairo-gobject-setup.log" 2>&1 \
            || { tail -25 "$LOG_ROOT/cairo-gobject-setup.log" >&2; err "cairo(glib) setup 失败"; }
        ninja -C "$cbd/build" > "$LOG_ROOT/cairo-gobject-build.log" 2>&1 \
            || { tail -30 "$LOG_ROOT/cairo-gobject-build.log" >&2; err "cairo(glib) 编译失败"; }
        ninja -C "$cbd/build" install > "$LOG_ROOT/cairo-gobject-install.log" 2>&1 \
            || { tail -25 "$LOG_ROOT/cairo-gobject-install.log" >&2; err "cairo(glib) 安装失败"; }
        [ -f "$SYSROOT_EXT_LIB/pkgconfig/cairo-gobject.pc" ] \
            || err "装完还是没 cairo-gobject.pc（看看 meson 是否真找到了 gobject-2.0）"
        [ -f "$SYSROOT_EXT_LIB/libcairo.so" ] \
            || err "装完没有 libcairo.so —— cairo 必须是共享库（见上面的取证）"
        # 陈旧的静态 cairo 一并删掉：留着它，日后谁用 `-l:libcairo.a` 或 --static 就把
        # 多副本那份又拉回来了。
        rm -f "$SYSROOT_EXT_LIB"/libcairo.a "$SYSROOT_EXT_LIB"/libcairo-script-interpreter.a
        [ -f "$SYSROOT_EXT_LIB/libcairo-gobject.so" ] || \
            warn "没看到 libcairo-gobject.so（只有 .a 也不至于坏，但最好确认一下）"
        log "✓ cairo（**共享**：libcairo.so.2 + cairo-gobject，静态那份已删）"
    fi

    # wayland-protocols：只有 XML + .pc，**没有任何编译产物**，所以按**宿主原生**编 ——
    # 它的 meson 要一个 build-time 的 wayland-scanner（`dependency('wayland-scanner')`），
    # 交叉模式下 meson 会去目标 sysroot 找，而那里只有 libwayland 的库、没有扫描器：
    #     Build-time dependency wayland-scanner found: NO
    #     ERROR: Neither a subproject directory nor a wayland.wrap file was found.
    # 纯数据包按原生编不会引入任何架构相关的东西，XP 与 .pc 装进去就是对的。
    if [ -f "$SYSROOT_EXT_LIB/pkgconfig/wayland-protocols.pc" ]; then
        log "已有 wayland-protocols（跳过）"
    else
        fetch wayland-protocols-1.41 wayland-protocols-1.41.tar.xz \
            https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.41/downloads/wayland-protocols-1.41.tar.xz
        rm -rf "$BLD_ROOT/wayland-protocols"
        meson setup "$BLD_ROOT/wayland-protocols" "$SRC_ROOT/wayland-protocols-1.41" \
            --prefix="$SYSROOT_EXT/usr" \
            --libdir="lib/$TARGET" \
            --includedir=include \
            --buildtype=release \
            -Dtests=false > "$LOG_ROOT/wayland-protocols-setup.log" 2>&1 \
            || { tail -20 "$LOG_ROOT/wayland-protocols-setup.log" >&2; err "wayland-protocols: setup 失败"; }
        ninja -C "$BLD_ROOT/wayland-protocols" install > "$LOG_ROOT/wayland-protocols-install.log" 2>&1 \
            || { tail -20 "$LOG_ROOT/wayland-protocols-install.log" >&2; err "wayland-protocols: install 失败"; }
        log "✓ wayland-protocols（XML → $SYSROOT_EXT/usr/share/wayland-protocols）"
    fi

    meson_pkg fribidi fribidi fribidi-1.0.15 fribidi-1.0.15.tar.xz \
        https://github.com/fribidi/fribidi/releases/download/v1.0.15/fribidi-1.0.15.tar.xz \
        -- -Ddocs=false -Dtests=false -Dbin=false

    meson_pkg harfbuzz harfbuzz harfbuzz-10.1.0 harfbuzz-10.1.0.tar.xz \
        https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz \
        -- -Dglib=enabled -Dfreetype=enabled -Dcairo=disabled -Dicu=disabled \
           -Dgraphite=disabled -Dgobject=disabled -Dintrospection=disabled \
           -Ddocs=disabled -Dtests=disabled -Dutilities=disabled -Dbenchmark=disabled

    meson_pkg pango pango-1.0 pango-1.54.0 pango-1.54.0.tar.xz \
        https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz \
        -- -Dintrospection=disabled -Ddocumentation=false -Dfreetype=enabled \
           -Dcairo=enabled -Dxft=disabled -Dsysprof=disabled -Dlibthai=disabled

    # builtin_loaders=all：把 PNG/JPEG 的 loader **编进库里**，免得还要处理
    # lib/gdk-pixbuf-2.0/*/loaders.cache（本项目的交付形态是平铺目录，没有那个环境变量）
    meson_pkg gdk-pixbuf gdk-pixbuf-2.0 gdk-pixbuf-2.42.12 gdk-pixbuf-2.42.12.tar.xz \
        https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz \
        -- -Dintrospection=disabled -Dgtk_doc=false -Ddocs=false -Dtests=false \
           -Dinstalled_tests=false -Dman=false -Drelocatable=false \
           -Dpng=enabled -Djpeg=enabled -Dtiff=disabled -Dgif=disabled -Dothers=disabled \
           -Dbuiltin_loaders=all -Dgio_sniffing=false

    meson_pkg atk atk atk-2.38.0 atk-2.38.0.tar.xz \
        https://download.gnome.org/sources/atk/2.38/atk-2.38.0.tar.xz \
        -- -Dintrospection=false -Ddocs=false

    # libepoxy 是 GTK3 的硬依赖（GL 函数分发）。X11/GLX 全关，只留 EGL。
    meson_pkg libepoxy epoxy epoxy-1.5.10 epoxy-1.5.10.tar.xz \
        https://download.gnome.org/sources/libepoxy/1.5/libepoxy-1.5.10.tar.xz \
        -- -Dglx=no -Degl=yes -Dx11=false -Dtests=false -Ddocs=false
}

# ══ 2. gtk ════════════════════════════════════════════════════════════════
do_gtk() {
    write_cross
    fix_static_pc
    meson_pkg gtk3 gtk+-3.0 gtk+-3.24.43 gtk+-3.24.43.tar.xz \
        https://download.gnome.org/sources/gtk+/3.24/gtk+-3.24.43.tar.xz \
        https://download.gnome.org/sources/gtk+/3.24/gtk+-3.24.43.tar.xz \
        -- -Dwayland_backend=true -Dx11_backend=false -Dbroadway_backend=false \
           -Dwin32_backend=false -Dquartz_backend=false \
           -Dprint_backends=file -Dcolord=no -Dcloudproviders=false -Dtracker3=false \
           -Dintrospection=false -Dgtk_doc=false -Dman=false -Ddemos=false \
           -Dtests=false -Dinstalled_tests=false -Dexamples=false
}

# ══ 3. probe ══════════════════════════════════════════════════════════════
# 一个最小 GTK3 窗口。它要证明的是"GTK3 能在我们的合成器上把窗口拉起来"，
# 所以刻意什么都不做：建窗、放一个 label、显示、跑主循环。
do_probe() {
    local src="$ROOT/feature/bsh_main/src/main/cpp/programs/gtkprobe"
    # 产物放 bin/ 下：`gtk-probe/` 这一层还要放打包用的 stage/，同名会撞（踩过）
    local out="$BUILD_DIR/gtk-probe/bin"
    [ -f "$src/main.c" ] || err "缺探针源码：$src/main.c"
    [ -f "$SYSROOT_EXT_LIB/pkgconfig/gtk+-3.0.pc" ] || err "还没编 gtk3（先跑 $0 deps && $0 gtk）"
    mkdir -p "$out"
    log "=== 编探针 ==="
    # shellcheck disable=SC2086
    $CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld \
        -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -D__MUSL__ -DOHOS_NDK \
        -O2 -o "$out/gtkprobe" "$src/main.c" \
        $(pkg-config --cflags --libs gtk+-3.0) \
        -Wl,-rpath,'$ORIGIN' -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 \
        > "$LOG_ROOT/probe-build.log" 2>&1 \
        || { tail -30 "$LOG_ROOT/probe-build.log" >&2; err "探针编译失败（$LOG_ROOT/probe-build.log）"; }
    log "✓ $out/gtkprobe（$(du -h "$out/gtkprobe" | cut -f1)）"
    log "  它 NEEDED：$("$CLANG_DIR/llvm-readelf" -d "$out/gtkprobe" | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF);printf "%s ",$NF}')"
}

# ══ 4. pack ═══════════════════════════════════════════════════════════════
# 收 NEEDED 闭包 → 平铺目录 → rawfile 里的 tar。
#
# 交付形态照抄 qtwl-demo 的 app 模式：**二进制与它所有 .so 平铺在同一个目录**，
# 因为 procmgr 会给 guest 的 LD_LIBRARY_PATH 加"它自己所在目录"（procmgr.cpp 的
# ChildRunElf）。这样不用动 .bshrc，也不必把这三十多个库塞进 bundle libs。
#
# 为什么进 rawfile 而不是随 HAP 直接解到 <资源根>：探针只是**验证手段**，不该污染
# 产品的资源根。放 rawfile 里，设备上用 `bshutil rawfile get tools/gtkprobe.tar …`
# 自己取出来解（见脚本末尾打印的用法）。
do_pack() {
    # 两级：stage/ 是打包根，stage/gtkprobe/ 是 tar 里的成员名。
    # ⚠ 别把这两级合成一个 —— 探针二进制本身就叫 gtkprobe，和目录同名会撞（踩过：
    #   cp 把二进制当成目录、tar 打出个空包）。
    local stage="$BUILD_DIR/gtk-probe/stage"
    local app="$stage/gtkprobe"
    local tar="$HAP_RAWFILE_TOOLS_DIR/gtkprobe.tar"
    local re="$CLANG_DIR/llvm-readelf"
    [ -x "$BUILD_DIR/gtk-probe/bin/gtkprobe" ] || do_probe

    log "=== 收 NEEDED 闭包 → $app ==="
    rm -rf "$app"; mkdir -p "$app"
    cp -f "$BUILD_DIR/gtk-probe/bin/gtkprobe" "$app/"

    local seen="" missing=""
    # libc / loader 由**应用自己提供**（bundle libs 里那份打过补丁的 musl），
    # 拷进来反而会和会话里那份打架 —— 与 pack_hdc.sh / copy_needed_closure 同一条口径。
    _skip() {
        case "$1" in
            libc.so|libc.so.6|libdl.so*|libm.so*|libpthread.so*|librt.so*|ld-musl*|ld-linux*) return 0 ;;
            *) return 1 ;;
        esac
    }
    resolve() {
        local name="$1"
        case " $seen " in *" $name "*) return ;; esac
        seen="$seen $name"
        _skip "$name" && return
        local p=""
        for d in "$SYSROOT_EXT_LIB" "$SYSROOT_EXT/usr/lib" "$HAP_LIBS_DIR"; do
            [ -f "$d/$name" ] && { p="$d/$name"; break; }
        done
        if [ -z "$p" ]; then missing="$missing $name"; return; fi
        # -L：meson 装出来的 .so 是软链（libgtk-3.so → .so.0 → .so.0.2404.43），
        # 展开成真文件 —— 设备侧解出来的目录里没法保证软链（pkg/沙箱都不建软链）。
        cp -Lf "$p" "$app/$name"
        local n
        for n in $("$re" -d "$p" 2>/dev/null | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}'); do
            resolve "$n"
        done
    }
    local n
    for n in $("$re" -d "$app/gtkprobe" | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}'); do
        resolve "$n"
    done
    [ -z "$missing" ] || warn "本机找不到的 NEEDED（多半指望 /system/lib64，设备上可能起不来）：$missing"

    # 软链一律不该有（上面 -L 展开过了）：留一道闸，免得以后改了拷法又悄悄带进来
    local nl
    nl="$(find "$app" -type l | wc -l)"
    [ "$nl" = "0" ] || err "平铺目录里出现了 $nl 个软链（设备侧解不出来）"

    log "  闭包：$(ls "$app" | grep -c '\.so') 个 .so，合计 $(du -sh "$app" | cut -f1)"
    mkdir -p "$(dirname "$tar")"
    # tar 顶层是 gtkprobe/，解到哪就在哪 —— 与 qtapp.tar 同一个口径
    tar -C "$stage" -cf "$tar" gtkprobe
    log "✓ $tar（$(du -h "$tar" | cut -f1)）"
    echo
    log "设备上怎么跑（不需要改 shell.cpp，rawfile get 就够）："
    log "    bshutil rawfile get tools/gtkprobe.tar ~/gtkprobe.tar"
    log "    mkdir -p ~/gtkprobe && tar -x -f ~/gtkprobe.tar -C ~"
    log "    ~/gtkprobe/gtkprobe"
}

case "$PHASE" in
    deps)  do_deps ;;
    gtk)   do_gtk ;;
    probe) do_probe ;;
    pack)  do_pack ;;
    all)   do_deps; do_gtk; do_probe; do_pack ;;
    *)     err "用法：$0 [deps|gtk|probe|pack|all]" ;;
esac
log "✅ build_gtk.sh 完成（阶段 $PHASE）"
