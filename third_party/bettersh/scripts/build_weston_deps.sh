#!/bin/bash
# build_weston_deps.sh — 交叉编译 weston-terminal 的静态依赖库（OHOS arm64）
#
# 依赖链（全部静态 .a，装到 sysroot-ext）：
#   zlib → libpng → pixman → freetype → expat → fontconfig → cairo
#   独立：xkbcommon（libxkbcommon.a）+ libjpeg-turbo + libwebp
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

DEPS_SRC="$BUILD_DIR/weston-deps-src"
DEPS_BUILD="$BUILD_DIR/weston-deps-build"
mkdir -p "$DEPS_SRC" "$DEPS_BUILD" "$SYSROOT_EXT_INC" "$SYSROOT_EXT_LIB" "$SYSROOT_EXT_PC"

# 交叉编译公共环境（autotools）
export CC="$CLANG --target=$TARGET --sysroot=$SYSROOT"
export CXX="$CLANGXX --target=$TARGET --sysroot=$SYSROOT"
export CFLAGS="-O2 -fPIC -D__MUSL__ -DOHOS_NDK -I$SYSROOT_EXT_INC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-fuse-ld=lld --target=$TARGET --sysroot=$SYSROOT -L$SYSROOT_EXT_LIB"
export PKG_CONFIG="pkg-config"
export PKG_CONFIG_LIBDIR="$SYSROOT_EXT_PC:$SYSROOT_EXT_LIB/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_EXT/usr"
export AR="$CLANG_DIR/llvm-ar"
export RANLIB="$CLANG_DIR/llvm-ranlib"
export NM="$CLANG_DIR/llvm-nm"

# 下载并解压 tarball（多源重试）
fetch_src() {
    local name="$1" url="$2"
    local dir="$DEPS_SRC/$name"
    [ -d "$dir" ] && { echo "[deps] $name 已就绪"; return; }
    echo "[deps] 下载 $name"
    local fname
    fname="$(basename "$url")"
    local tgz="$DEPS_SRC/$fname"
    local ok=0
    for i in 1 2 3; do
        if curl -sL --retry 2 -m 300 -o "$tgz" "$url"; then ok=1; break; fi
        echo "[deps] $name 下载失败（第 $i 次），重试..."
        sleep 2
    done
    [ "$ok" = 1 ] || { echo "[deps] $name 下载失败"; exit 1; }
    mkdir -p "$dir"
    case "$tgz" in
        *.tar.xz) tar -xJf "$tgz" -C "$dir" --strip-components=1 ;;
        *.tar.bz2) tar -xjf "$tgz" -C "$dir" --strip-components=1 ;;
        *) tar -xzf "$tgz" -C "$dir" --strip-components=1 ;;
    esac
}

# 通用 autotools 静态构建
build_autotools() {
    local name="$1" url="$2" conf_args="$3"
    fetch_src "$name" "$url"
    local src="$DEPS_SRC/$name"
    local bd="$DEPS_BUILD/$name"
    local stamp="$SYSROOT_EXT_LIB/.stamp-$name"
    [ -f "$stamp" ] && { echo "[deps] $name 已构建"; return; }
    echo "[deps] 构建 $name ..."
    rm -rf "$bd"; mkdir -p "$bd"
    (cd "$src" && [ -f configure ] || ./autogen.sh >/dev/null 2>&1 || true)
    (
        cd "$bd"
        "$src/configure" --host="$HOST_TRIPLE" \
            --prefix="$SYSROOT_EXT/usr" --libdir="$SYSROOT_EXT_LIB" \
            --includedir="$SYSROOT_EXT_INC" \
            --enable-static --disable-shared $conf_args >/dev/null 2>&1 \
            || { echo "[deps] $name configure 失败"; exit 1; }
        make -j"$JOBS" >/dev/null 2>&1 || { echo "[deps] $name make 失败"; exit 1; }
        make install >/dev/null 2>&1 || { echo "[deps] $name install 失败"; exit 1; }
    )
    touch "$stamp"
    echo "[deps] ✓ $name"
}

# ── zlib（静态；configure 为 zlib 专用参数）──────────────
build_zlib() {
    local name="zlib-1.3.1"
    fetch_src "$name" "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
    local stamp="$SYSROOT_EXT_LIB/.stamp-$name"
    [ -f "$stamp" ] && { echo "[deps] $name 已构建"; return; }
    echo "[deps] 构建 $name ..."
    local src="$DEPS_SRC/$name"
    local bd="$DEPS_BUILD/$name"
    rm -rf "$bd"; mkdir -p "$bd"
    (
        cd "$bd"
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        "$src/configure" --prefix="$SYSROOT_EXT/usr" \
            --libdir="$SYSROOT_EXT_LIB" --includedir="$SYSROOT_EXT_INC" \
            --static >/dev/null 2>&1 \
            || { echo "[deps] $name configure 失败"; exit 1; }
        make -j"$JOBS" >/dev/null 2>&1 || { echo "[deps] $name make 失败"; exit 1; }
        make install >/dev/null 2>&1 || { echo "[deps] $name install 失败"; exit 1; }
    )
    touch "$stamp"
    echo "[deps] ✓ $name"
}
build_zlib

# ── libpng（依赖 zlib）───────────────────────────────────
build_autotools libpng-1.6.43 \
    "https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.43.tar.gz" \
    "--disable-tools --disable-apng"

# ── pixman（依赖 zlib/libpng 可选；禁用 ARM 汇编——clang 不兼容 GNU asm）──
build_autotools pixman-0.42.2 \
    "https://www.cairographics.org/releases/pixman-0.42.2.tar.gz" \
    "--disable-gtk --disable-arm-simd --disable-arm-neon --disable-arm-a64-neon --disable-arm-iwmmxt"

# ── freetype（依赖 zlib；png/bzip2/harfbuzz 裁剪）────────
build_autotools freetype-2.13.2 \
    "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.gz" \
    "--without-png --without-bzip2 --without-harfbuzz --without-brotli"

# ── expat（fontconfig 依赖）──────────────────────────────
build_autotools expat-2.6.2 \
    "https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.gz" \
    "--without-examples --without-tests --without-docbook"

# ── fontconfig（依赖 freetype + expat）───────────────────
build_autotools fontconfig-2.15.0 \
    "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz" \
    "--enable-libxml2=no --disable-docs"

# ── cairo（meson 静态：1.18 起为 meson 构建）──────────────
build_meson_cross() {
    # build_meson_cross <name> <url> <meson-args...>
    local name="$1" url="$2"; shift 2
    fetch_src "$name" "$url"
    local stamp="$SYSROOT_EXT_LIB/.stamp-$name"
    [ -f "$stamp" ] && { echo "[deps] $name 已构建"; return; }
    local src="$DEPS_SRC/$name"
    local bd="$DEPS_BUILD/$name"
    echo "[deps] 构建 $name ..."
    rm -rf "$bd"; mkdir -p "$bd"
    # cairo 的 csi-replay/csi-exec/csi-trace 是构建期宿主诊断工具：
    # 交叉链接静态 libfontconfig.a 时缺 expat 依赖（XML_* 符号无法解析）且 westerm 不需要。
    # 从 meson 构建中剔除（源码在 BUILD_DIR 构建树，不入库；weston 源码保持零修改）。
    if [ "$name" = "cairo-1.18.0" ]; then
        sed -i \
            -e '/^csi_replay_exe = executable/,/^)/d' \
            -e '/^csi_exec_exe = executable/,/^)/d' \
            -e '/^if feature_conf.get(.CAIRO_HAS_SCRIPT_SURFACE/,/^endif/d' \
            "$src/util/cairo-script/meson.build" 2>/dev/null || true
    fi
    cat > "$bd/cross.txt" <<EOF
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
        meson setup "$bd/build" "$src" \
            --cross-file "$bd/cross.txt" \
            --prefix="$SYSROOT_EXT/usr" --libdir="lib/$TARGET" \
            --default-library=static \
            "$@" >/dev/null 2>&1 \
        || { echo "[deps] $name meson setup 失败"; exit 1; }
    ninja -C "$bd/build" >/dev/null 2>&1 || { echo "[deps] $name ninja 失败"; exit 1; }
    ninja -C "$bd/build" install >/dev/null 2>&1
    touch "$stamp"
    echo "[deps] ✓ $name"
}

build_meson_cross cairo-1.18.0 \
    "https://www.cairographics.org/releases/cairo-1.18.0.tar.xz" \
    -Dglib=disabled -Dxlib=disabled -Dxcb=disabled -Ddwrite=disabled \
    -Dquartz=disabled -Dtee=disabled -Dspectre=disabled \
    -Dtests=disabled -Dfontconfig=enabled -Dfreetype=enabled -Dpng=enabled

# ── libxkbcommon（meson 静态）────────────────────────────
build_xkbcommon() {
    local name="libxkbcommon-1.6.0"
    fetch_src "$name" "https://codeload.github.com/xkbcommon/libxkbcommon/tar.gz/refs/tags/xkbcommon-1.6.0"
    local stamp="$SYSROOT_EXT_LIB/.stamp-$name"
    [ -f "$stamp" ] && { echo "[deps] $name 已构建"; return; }
    local src="$DEPS_SRC/$name"
    local bd="$DEPS_BUILD/$name"
    rm -rf "$bd"; mkdir -p "$bd"
    cat > "$bd/cross.txt" <<EOF
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
        PKG_CONFIG_PATH="$SYSROOT_EXT_PC" \
        meson setup "$bd/build" "$src" \
            --cross-file "$bd/cross.txt" \
            --prefix="$SYSROOT_EXT/usr" --libdir="lib/$TARGET" \
            --default-library=static \
            -Denable-docs=false -Denable-tools=false -Denable-x11=false -Denable-xkbregistry=false -Dxkb-config-root=/data/storage/el2/base/haps/entry/files/xkb \
            -Denable-wayland=false >/dev/null 2>&1 \
        || { echo "[deps] $name meson setup 失败"; exit 1; }
    ninja -C "$bd/build" >/dev/null 2>&1 || { echo "[deps] $name ninja 失败"; exit 1; }
    ninja -C "$bd/build" install >/dev/null 2>&1
    touch "$stamp"
    echo "[deps] ✓ $name"
}
build_xkbcommon

# ── libjpeg-turbo（cmake 静态）───────────────────────────
build_jpeg() {
    local name="libjpeg-turbo-3.0.2"
    fetch_src "$name" "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.0.2/libjpeg-turbo-3.0.2.tar.gz"
    local stamp="$SYSROOT_EXT_LIB/.stamp-$name"
    [ -f "$stamp" ] && { echo "[deps] $name 已构建"; return; }
    local src="$DEPS_SRC/$name"
    local bd="$DEPS_BUILD/$name"
    rm -rf "$bd"; mkdir -p "$bd"
    cmake -S "$src" -B "$bd" \
        -DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake" \
        -DCMAKE_INSTALL_PREFIX="$SYSROOT_EXT/usr" \
        -DCMAKE_INSTALL_LIBDIR="lib/$TARGET" \
        -DCMAKE_INSTALL_INCLUDEDIR="$SYSROOT_EXT_INC" \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
        -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF >/dev/null 2>&1 \
        || { echo "[deps] $name cmake 失败"; exit 1; }
    cmake --build "$bd" -j"$JOBS" >/dev/null 2>&1 || { echo "[deps] $name build 失败"; exit 1; }
    cmake --install "$bd" >/dev/null 2>&1
    touch "$stamp"
    echo "[deps] ✓ $name"
}
build_jpeg

# ── libwebp（configure 静态，裁剪）───────────────────────
build_autotools libwebp-1.4.0 \
    "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0.tar.gz" \
    "--disable-shared --enable-static --disable-everything --enable-libwebpdecoder --enable-libwebpdemux"

log "✅ build_weston_deps.sh 完成"
ls "$SYSROOT_EXT_LIB"/*.a 2>/dev/null | sed 's/^/  /'
