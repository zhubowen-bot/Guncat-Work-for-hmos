#!/bin/bash
# build_wayland.sh — 交叉编译 libwayland（server/client/cursor/egl）+ libffi → HAP libs / dist SDK
#
# 产物：
#   feature/bsh_main/libs/<abi>/            libwayland-{server,client,cursor,egl}.so + libffi.so（打进 HAP）
#   dist/<abi>/                  libwayland-client.so + 头文件 + .pc（客户端 SDK 交付物）
#
# 用法：NATIVE_ARCH=arm64-v8a| x86_64 ./scripts/build_wayland.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

[ -f "$WAYLAND_SRC/meson.build" ] || err "wayland 源码缺失: $WAYLAND_SRC（thirdparty/wayland submodule，指向 waymony fork 已含 WAYLAND_TCP patch）"
[ -f "$XDG_SHELL_XML" ] || err "xdg-shell.xml 缺失: $XDG_SHELL_XML（需 wayland-protocols）"
# 注：wayland submodule 已指向 waymony fork（含 WAYLAND_TCP patch + wlproxy_tcp），
# 无需再应用 patch（历史版本需手动 git apply scripts/wayland-waymony.patch）

mkdir -p "$BUILD_DIR" "$HOST_TOOLS" "$SYSROOT_EXT_INC" "$SYSROOT_EXT_LIB" "$SYSROOT_EXT_PC" \
         "$HAP_LIBS_DIR" "$CPP_INC_DIR" "$DIST_DIR/lib" "$DIST_DIR/include" "$DIST_DIR/share"

# ══════════════════════════════════════════════════════════
# 1. libffi → sysroot-ext（wayland-client 依赖；SDK sysroot 无 ffi.h）
# ══════════════════════════════════════════════════════════
build_libffi() {
    # libffi 以静态库（.a）形式安装（链入 libwayland-client）
    [ -f "$SYSROOT_EXT_INC/ffi.h" ] && [ -f "$SYSROOT_EXT_LIB/libffi.a" ] && {
        log "libffi 已就绪，跳过"; return; }
    [ -f "$LIBFFI_SRC/configure.ac" ] || err "libffi 源码缺失: $LIBFFI_SRC"
    log "=== 构建 libffi ($NATIVE_ARCH) ==="

    local lf_build="$BUILD_DIR/libffi-$NATIVE_ARCH"
    rm -rf "$lf_build"; mkdir -p "$lf_build"
    (cd "$LIBFFI_SRC" && ./autogen.sh >/dev/null 2>&1) || err "libffi autogen.sh 失败"

    # out-of-tree 构建：必须在独立 build 目录内运行 configure（autotools 要求）
    # --host 用 GNU triple 使 configure 生成正确的 AArch64 配置，实际编译由 CC/CFLAGS target 决定
    # --enable-static：libffi 静态链入 libwayland-client，避免 HAP 再带一份 libffi.so 的符号冲突
    (
        cd "$lf_build"
        CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
        CXX="$CLANGXX --target=$TARGET --sysroot=$SYSROOT" \
        CFLAGS="-O2 -fPIC -D__MUSL__ -DOHOS_NDK" \
        LDFLAGS="-fuse-ld=lld --target=$TARGET --sysroot=$SYSROOT" \
        "$LIBFFI_SRC/configure" --host="$HOST_TRIPLE" --prefix="$lf_build/install" \
            --disable-docs --disable-shared --enable-static >/dev/null 2>&1 \
            || err "libffi configure 失败"
        make -j"$JOBS" >/dev/null || err "libffi make 失败"
        make install >/dev/null || err "libffi install 失败"
    )

    cp "$lf_build/install/include/ffi.h" "$lf_build/install/include/ffitarget.h" "$SYSROOT_EXT_INC/" 2>/dev/null || true
    cp "$lf_build/install/lib/libffi.a" "$SYSROOT_EXT_LIB/"
    cat > "$SYSROOT_EXT_PC/libffi.pc" <<EOF
prefix=$SYSROOT_EXT/usr
includedir=\${prefix}/include
libdir=\${prefix}/lib/$TARGET
Name: libffi
Description: Library supporting Foreign Function Interfaces
Version: 3.4.6
Libs: -L\${libdir} -lffi
Cflags: -I\${includedir}
EOF
    log "libffi → $SYSROOT_EXT"
}

# ══════════════════════════════════════════════════════════
# 2. 宿主 wayland-scanner（生成协议头/代码用）
# ══════════════════════════════════════════════════════════
build_host_scanner() {
    [ -x "$WAYLAND_SCANNER" ] && { log "wayland-scanner 已就绪: $WAYLAND_SCANNER"; return; }
    log "=== 构建宿主 wayland-scanner ==="
    local hb="$BUILD_DIR/wayland-native-host"
    rm -rf "$hb"; mkdir -p "$hb"
    meson setup "$hb" "$WAYLAND_SRC" \
        --prefix="$HOST_TOOLS" --libdir=lib \
        -Dscanner=true -Dlibraries=false -Dtests=false \
        -Ddocumentation=false -Ddtd_validation=false --buildtype=release >/dev/null
    ninja -C "$hb" >/dev/null
    ninja -C "$hb" install >/dev/null
    log "wayland-scanner: $WAYLAND_SCANNER"
}

# ══════════════════════════════════════════════════════════
# 3. wayland 交叉编译 → sysroot-ext
# ══════════════════════════════════════════════════════════
build_wayland() {
    local wb="$BUILD_DIR/wayland-$NATIVE_ARCH"
    local cross_file="$BUILD_DIR/wayland-cross-$NATIVE_ARCH.txt"
    local all_ok=1
    for f in libwayland-server.so.0.22.0 libwayland-client.so.0.22.0 libwayland-cursor.so.0.0.3 \
             libwayland-egl.so.1.22.0; do
        [ -f "$SYSROOT_EXT_LIB/$f" ] || all_ok=0
    done
    [ "$all_ok" = 1 ] && { log "wayland 已就绪，跳过"; return; }

    log "=== 构建 wayland ($NATIVE_ARCH) ==="
    cat > "$cross_file" <<EOF
[binaries]
c          = ['$CLANG', '--target=$TARGET', '--sysroot=$SYSROOT']
cpp        = ['$CLANGXX', '--target=$TARGET', '--sysroot=$SYSROOT']
ar         = '$CLANG_DIR/llvm-ar'
strip      = '$CLANG_DIR/llvm-strip'
ranlib     = '$CLANG_DIR/llvm-ranlib'
pkg-config = 'pkg-config'

[built-in options]
c_args    = ['-O2', '-fPIC', '-DOHOS_NDK', '-D__MUSL__=1', '-I$SYSROOT_EXT_INC']
cpp_args  = ['-O2', '-fPIC', '-DOHOS_NDK', '-D__MUSL__=1', '-I$SYSROOT_EXT_INC']
c_link_args   = ['-L$SYSROOT_EXT_LIB']
cpp_link_args = ['-L$SYSROOT_EXT_LIB']

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$SYSROOT_EXT_PC:$SYSROOT/usr/lib/pkgconfig'
sys_root = '$SYSROOT'

[host_machine]
system     = 'linux'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'
EOF
    # 交叉编译 host_machine.cpu_family 按 NATIVE_ARCH 修正
    case "$NATIVE_ARCH" in
        x86_64) sed -i "s/cpu_family = 'aarch64'/cpu_family = 'x86_64'/; s/^cpu        = 'aarch64'/cpu        = 'x86_64'/" "$cross_file" ;;
    esac

    rm -rf "$wb"; mkdir -p "$wb"
    # 宿主 pkg-config 路径仅供 native 查询（host scanner 的 .pc），交叉侧由 pkg_config_libdir 提供
    env -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR \
        PKG_CONFIG_PATH="$HOST_TOOLS/lib/pkgconfig" \
        meson setup "$wb" "$WAYLAND_SRC" \
            --cross-file "$cross_file" \
            --prefix="$SYSROOT_EXT/usr" --libdir="lib/$TARGET" \
            -Dscanner=false -Dlibraries=true -Dtests=false \
            -Ddocumentation=false -Ddtd_validation=false --buildtype=release >/dev/null
    ninja -C "$wb" -j"$JOBS" >/dev/null
    ninja -C "$wb" install >/dev/null
    log "wayland → $SYSROOT_EXT"
}

# ══════════════════════════════════════════════════════════
# 3b. wayland 静态库（HNP 客户端静态链接用，libwayland-client.a）


# ══════════════════════════════════════════════════════════
# 4. 生成协议头 + 布局产物
# ══════════════════════════════════════════════════════════
gen_protocol_headers() {
    log "=== 生成协议头 ==="
    # 核心协议头（server 编译 + 客户端 SDK 都需要）
    "$WAYLAND_SCANNER" server-header "$WAYLAND_SRC/protocol/wayland.xml" "$CPP_INC_DIR/wayland-server-protocol.h"
    "$WAYLAND_SCANNER" client-header "$WAYLAND_SRC/protocol/wayland.xml" "$DIST_DIR/include/wayland-client-protocol.h"
    # xdg-shell（server 编译用，与 harmonybox/winehua 相同的生成方式）
    "$WAYLAND_SCANNER" server-header "$XDG_SHELL_XML" "$CPP_INC_DIR/xdg-shell-server-protocol.h"
    "$WAYLAND_SCANNER" private-code   "$XDG_SHELL_XML" "$CPP_INC_DIR/xdg-shell-protocol.c"
    # xdg-shell 客户端协议（HNP 客户端编译用）
    "$WAYLAND_SCANNER" client-header "$XDG_SHELL_XML" "$DIST_DIR/include/xdg-shell-client-protocol.h"
    "$WAYLAND_SCANNER" private-code   "$XDG_SHELL_XML" "$DIST_DIR/include/xdg-shell-protocol.c"
    # viewporter（占位实现用，位于 wayland-protocols）
    "$WAYLAND_SCANNER" server-header "$WAYLAND_PROTOCOLS_SRC/stable/viewporter/viewporter.xml" \
        "$CPP_INC_DIR/viewporter-server-protocol.h"
    "$WAYLAND_SCANNER" private-code   "$WAYLAND_PROTOCOLS_SRC/stable/viewporter/viewporter.xml" \
        "$CPP_INC_DIR/viewporter-protocol.c"
    # 扩展协议（compositor 支持面：pointer-constraints/relative-pointer/tablet/color-management/text-cursor-position）
    "$WAYLAND_SCANNER" server-header "$WAYLAND_PROTOCOLS_SRC/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml" \
        "$CPP_INC_DIR/zwp_pointer_constraints-server-protocol.h"
    "$WAYLAND_SCANNER" private-code   "$WAYLAND_PROTOCOLS_SRC/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml" \
        "$CPP_INC_DIR/zwp_pointer_constraints-protocol.c"
    "$WAYLAND_SCANNER" server-header "$WAYLAND_PROTOCOLS_SRC/unstable/relative-pointer/relative-pointer-unstable-v1.xml" \
        "$CPP_INC_DIR/zwp_relative_pointer-server-protocol.h"
    "$WAYLAND_SCANNER" private-code   "$WAYLAND_PROTOCOLS_SRC/unstable/relative-pointer/relative-pointer-unstable-v1.xml" \
        "$CPP_INC_DIR/zwp_relative_pointer-protocol.c"
    "$WAYLAND_SCANNER" server-header "$WAYLAND_PROTOCOLS_SRC/unstable/tablet/tablet-unstable-v2.xml" \
        "$CPP_INC_DIR/zwp_tablet-server-protocol.h"
    "$WAYLAND_SCANNER" private-code   "$WAYLAND_PROTOCOLS_SRC/unstable/tablet/tablet-unstable-v2.xml" \
        "$CPP_INC_DIR/zwp_tablet-protocol.c"
    log "协议头 → $CPP_INC_DIR"
}

layout() {
    log "=== 布局产物 → $HAP_LIBS_DIR / $DIST_DIR ==="
    # HAP libs：server 运行需要 libwayland-{server,client,cursor,egl}。
    # 每个库拷成两个真实文件名：无版本名（dlopen/link 用）+ SONAME（DT_NEEDED 解析用）。
    # libffi 已静态链入 libwayland-client.so（DT_NEEDED 仅 libc.so），HAP 无需再带。
    for f in "$SYSROOT_EXT_LIB"/libwayland-*.so.*; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue               # 跳过 .so / .so.0 符号链接，只取真身
        base=$(basename "$f")                 # libwayland-server.so.0.22.0
        name=${base%%.so.*}.so                # libwayland-server.so
        soname=${base%.*.*}                    # libwayland-server.so.0（SONAME，去掉版本号两段）
        cp "$f" "$HAP_LIBS_DIR/$name"
        cp "$f" "$HAP_LIBS_DIR/$soname"
    done
    # server 头文件（编译 HAP C++ 用）
    for h in wayland-server.h wayland-server-core.h wayland-server-protocol.h wayland-client.h \
             wayland-client-core.h wayland-util.h wayland-version.h; do
        src="$WAYLAND_SRC/src/$h"
        [ -f "$src" ] || src="$SYSROOT_EXT_INC/$h"
        [ -f "$src" ] && cp "$src" "$CPP_INC_DIR/"
    done
    [ -f "$CPP_INC_DIR/wayland-server-protocol.h" ] || err "wayland-server-protocol.h 生成失败"

    # 客户端 SDK：libwayland-client（核心）+ cursor + egl，libffi 已静态包含
    for f in libwayland-client.so.0.22.0 libwayland-cursor.so.0.22.0 libwayland-egl.so.1.22.0; do
        [ -f "$SYSROOT_EXT_LIB/$f" ] && cp "$SYSROOT_EXT_LIB/$f" "$DIST_DIR/lib/"
    done
    for f in libwayland-client.so.0 libwayland-cursor.so.0 libwayland-egl.so.1; do
        [ -f "$SYSROOT_EXT_LIB/$f" ] && cp -P "$SYSROOT_EXT_LIB/$f" "$DIST_DIR/lib/"
    done
    for h in wayland-client.h wayland-client-core.h wayland-util.h wayland-version.h wayland-client-protocol.h; do
        [ -f "$CPP_INC_DIR/$h" ] && cp "$CPP_INC_DIR/$h" "$DIST_DIR/include/"
    done
    cp "$WAYLAND_SRC/protocol/wayland.xml" "$DIST_DIR/share/" 2>/dev/null || true
    cat > "$DIST_DIR/README.txt" <<EOF
Waymony Wayland 客户端 SDK ($NATIVE_ARCH, wayland $WAYLAND_VERSION)
用法见 docs/CLIENT_GUIDE.md：
  - lib/libwayland-client.so.0  客户端核心库（libffi 已静态链入，无额外依赖）
  - include/                    头文件
  - share/wayland.xml           核心协议定义
EOF
    log "HAP libs: $HAP_LIBS_DIR"
    log "SDK:      $DIST_DIR"
}

# ══════════════════════════════════════════════════════════
# 本工程目录布局:按 waymony 约定生成的协议文件拆到 wayland/protocol
# (compositor 源码 include "protocol/*";公共 wayland 头留在 CPP_INC_DIR)
# ══════════════════════════════════════════════════════════
layout_project_dirs() {
    local proto="$ROOT/feature/bsh_main/src/main/cpp/wayland/protocol"
    mkdir -p "$proto"
    for f in "$CPP_INC_DIR"/*-protocol.h "$CPP_INC_DIR"/*-protocol.c; do
        [ -f "$f" ] || continue
        mv "$f" "$proto/"
    done
    # 客户端核心协议(waymony 放 DIST)也供 wldemo 使用
    cp "$DIST_DIR/include/wayland-client-protocol.h" "$proto/" 2>/dev/null || true
    cp "$DIST_DIR/include/xdg-shell-client-protocol.h" "$proto/" 2>/dev/null || true
    log "协议 → $proto"
}

build_libffi
build_host_scanner
build_wayland
gen_protocol_headers
layout
layout_project_dirs
log "✅ build_wayland.sh 完成 ($NATIVE_ARCH)"
