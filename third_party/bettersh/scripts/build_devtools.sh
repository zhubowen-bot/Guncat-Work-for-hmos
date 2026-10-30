#!/bin/bash
# build_devtools.sh — 交叉编设备侧用得到的构建工具（GNU make + ninja）
#
# 为什么需要：pip 装 sdist 时，
#   * 走 setuptools 的包要到 autotools 那一步（`./configure && make`，比如 cffi 自带的
#     libffi）就得有 **make**；
#   * 走 meson 的包（numpy）得有 **ninja**。
#
# 为什么不用 SDK 自带的那两个：`ohos-sdk-prune` 里确实有 ninja 与 cmake
# （`opt/ohos-sdk/openharmony/native/build-tools/cmake/bin/`，也是 aarch64），
# 但它们是**给 aarch64 Linux(glibc) 宿主**编的 —— 跑起来要 `libstdc++.so.6`，
# 而我们资源根里只有 glibc 的 libc。为了两个工具去凑一整套 glibc C++ 运行时不值当，
# 自己编 musl 版更干净（而且编译器的目标本来就和我们一致）。
#
# 产物：dist/pkgs/devtools.tar.zst（顶层 usr/bin/{make,ninja}）—— **pkg 的包**，
# 不随 HAP 走，设备上 `pkg install devtools` 后解到 $SYSROOT（见 build/pkgserver/index.json）。
# 资源根是 noexec，所以运行时由 elfloader 直接装载（procmgr 认真 ELF）；
# PATH 里有 $SYSROOT/usr/bin，pip 调 `make` / `ninja` 就能走到。
#
# 用法：./scripts/build_devtools.sh        （DEVTOOLS_REBUILD=1 强制重来）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

MAKE_VER="${MAKE_VER:-4.4.1}"
NINJA_VER="${NINJA_VER:-1.12.1}"
MAKE_SRC="$ROOT/thirdparty/make-$MAKE_VER"
NINJA_SRC="$ROOT/thirdparty/ninja-$NINJA_VER"
MAKE_BLD="$BUILD_DIR/make-$NATIVE_ARCH"
NINJA_BLD="$BUILD_DIR/ninja-$NATIVE_ARCH"
OUT_PKG="$ROOT/dist/pkgs/devtools.tar.zst"   # 产物：**pkg 的包**，不再随 HAP 走

AR="$CLANG_DIR/llvm-ar"
RANLIB="$CLANG_DIR/llvm-ranlib"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT"
# **动态**链接（不 -static）——这条是 2026-10-04 定位出来的：
#   静态 guest 吃不到 LD_PRELOAD 的 shim（`[elf] loaded ET_EXEC` 就是它），于是
#   make 内部的 execvp(/bin/sh)、ninja 起 shell 都**直接打到内核**，不走 procmgr 的
#   exec 委托。实测 node-gyp 现场编原生扩展时 gyp 生成的 Makefile 就死在这儿：
#       make: /bin/sh: Permission denied          ← 内核给的 EACCES
#       （把 SHELL 指到我们的 #BSHSO 启动器更绕：内核 ENOEXEC → 启动器被当 shell
#         脚本逐行解释，报三行 "printf[2]…printf[3]…printf[4]…"）
#   动态之后 LD_PRELOAD 生效 → exec 委托生效 → `/bin/sh` 走命令表里的 sh。
#   解释器路径与其它 guest 一致（见 build_weston_terminal.sh / build_qtwl_demo.sh）；
#   loader 本身在 bundle libs 里（procmgr 按 PT_INTERP 的 basename 找）。
DTOOLS_LDFLAGS="-Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1"
# 关掉 OHOS 的 fortify：它的 sys/select.h 把 FD_SET/FD_CLR 展开成 `__fd_chk(fd)`
# （OHOS musl 私有的越界检查），而 bundle 里的 ld-musl-aarch64.so.1 是 **vanilla
# musl 1.2.2**、根本没这个符号 —— 动态链接时链接器不查未定义符号，运行期才炸：
#     Error relocating make: __fd_chk: symbol not found
# 实测就是 make（jobserver 用 select/FD_SET）踩的。关掉 fortify 等价于用 vanilla
# musl 的 FD_SET —— 语义一致，只是少一道 OHOS 特有的越界检查。
# （根治办法是给我们的 musl 补一个 __fd_chk，见 README 的待办。）
DTOOLS_CFLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
TRIPLE_FLAGS="--target=$TARGET --sysroot=$SYSROOT"

if [ -f "$OUT_PKG" ] && [ -x "$MAKE_BLD/make" ] && [ -x "$NINJA_BLD/ninja" ] && [ -z "${DEVTOOLS_REBUILD:-}" ]; then
    log "devtools 包已存在：$OUT_PKG（DEVTOOLS_REBUILD=1 可重来）"
    exit 0
fi
command -v zstd >/dev/null 2>&1 || err "缺 zstd（apt install zstd）"

fetch_src() {   # $1=tar 路径 $2=解压后目录名 $3..=候选 URL
    local tar="$1" dir="$2"; shift 2
    [ -d "$ROOT/thirdparty/$dir" ] && return 0
    if [ ! -s "$tar" ]; then
        log "下载 $(basename "$tar")"
        local ok= u
        for u in "$@"; do
            if curl -sL --retry 2 -m 300 -o "$tar" "$u" && [ -s "$tar" ]; then ok=1; break; fi
        done
        [ -n "$ok" ] || err "下载失败：$tar"
    fi
    tar xzf "$tar" -C "$ROOT/thirdparty"
}

# ══ 1. GNU make（静态：不依赖 glibc 那套）══════════════════════════
fetch_src "$ROOT/thirdparty/make-$MAKE_VER.tar.gz" "make-$MAKE_VER" \
    "https://ftp.gnu.org/gnu/make/make-$MAKE_VER.tar.gz" \
    "https://mirrors.tuna.tsinghua.edu.cn/gnu/make/make-$MAKE_VER.tar.gz"
[ -f "$MAKE_SRC/configure" ] || err "make 源码结构异常：$MAKE_SRC"

if [ ! -x "$MAKE_BLD/make" ]; then
    log "=== 配置 make（动态，musl）==="
    rm -rf "$MAKE_BLD"; mkdir -p "$MAKE_BLD"
    # --host 用 musl 而不是 ohos：config.sub 版本参差，认 musl 的比认 ohos 的多
    # （与 build_vim.sh / build_python.sh 同一个理由）。
    # --without-guile：省掉一个用不上的依赖（否则 configure 会去探测宿主 guile）。
    ( cd "$MAKE_BLD" && \
      "$MAKE_SRC/configure" \
        --host=aarch64-linux-musl --build=x86_64-pc-linux-gnu \
        --disable-nls --without-guile \
        CC="$CC_TARGET" AR="$AR" RANLIB="$RANLIB" CFLAGS="$DTOOLS_CFLAGS" LDFLAGS="$DTOOLS_LDFLAGS" \
        > configure.log 2>&1 ) || {
            tail -20 "$MAKE_BLD/configure.log" >&2 || true
            err "make configure 失败：$MAKE_BLD/configure.log"
        }
    log "=== 编译 make ==="
    make -C "$MAKE_BLD" -j"$JOBS" > "$MAKE_BLD/make.log" 2>&1 \
        || { tail -20 "$MAKE_BLD/make.log" >&2; err "make 编译失败：$MAKE_BLD/make.log"; }
fi
[ -x "$MAKE_BLD/make" ] || err "没产出 $MAKE_BLD/make"

# ══ 2. ninja（用宿主 cmake 交叉编）════════════════════════════════
fetch_src "$ROOT/thirdparty/ninja-$NINJA_VER.tar.gz" "ninja-$NINJA_VER" \
    "https://github.com/ninja-build/ninja/archive/refs/tags/v$NINJA_VER.tar.gz"
[ -f "$NINJA_SRC/CMakeLists.txt" ] || err "ninja 源码结构异常：$NINJA_SRC"

if [ ! -x "$NINJA_BLD/ninja" ]; then
    log "=== 交叉编 ninja ==="
    rm -rf "$NINJA_BLD"; mkdir -p "$NINJA_BLD"
    # 目标三元组全塞进 CMAKE_*_FLAGS：这样不用另写 toolchain file，也不用让 CMake
    # 去找目标的 libc（我们只要它把源码编译链接成 aarch64）。
    cmake -S "$NINJA_SRC" -B "$NINJA_BLD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="$CLANGXX" \
        -DCMAKE_C_FLAGS="$TRIPLE_FLAGS $DTOOLS_CFLAGS" \
        -DCMAKE_CXX_FLAGS="$TRIPLE_FLAGS $DTOOLS_CFLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$TRIPLE_FLAGS $DTOOLS_LDFLAGS" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        > "$NINJA_BLD/cmake.log" 2>&1 \
        || { tail -20 "$NINJA_BLD/cmake.log" >&2; err "ninja cmake configure 失败：$NINJA_BLD/cmake.log"; }
    cmake --build "$NINJA_BLD" -j"$JOBS" >> "$NINJA_BLD/cmake.log" 2>&1 \
        || { tail -30 "$NINJA_BLD/cmake.log" >&2; err "ninja 编译失败：$NINJA_BLD/cmake.log"; }
fi
[ -x "$NINJA_BLD/ninja" ] || err "没产出 $NINJA_BLD/ninja"

# ══ 3. 打包 ══════════════════════════════════════════════════════
RT="$BUILD_DIR/devtools-rt"
rm -rf "$RT"; mkdir -p "$RT/usr/bin"
cp -f "$MAKE_BLD/make"   "$RT/usr/bin/make"
cp -f "$NINJA_BLD/ninja" "$RT/usr/bin/ninja"
"$CLANG_DIR/llvm-strip" --strip-all "$RT/usr/bin/make" "$RT/usr/bin/ninja" 2>/dev/null || true
mkdir -p "$(dirname "$OUT_PKG")"
# tar + zstd，与 ohos-sdk-prune 同格式。顶层是 usr/，pkg 解到资源根 → <sysroot>/usr/bin/
tar -C "$RT" -cf - usr | zstd -q -f -19 -T"$JOBS" -o "$OUT_PKG"
[ -s "$OUT_PKG" ] || err "devtools 包是空的"

# ══ 4. 校验 ══════════════════════════════════════════════════════
for b in make ninja; do
    "$CLANG_DIR/llvm-readelf" -h "$RT/usr/bin/$b" | grep -q AArch64 \
        || err "$b 不是 AArch64"
done
log "✅ devtools：$OUT_PKG"
log "   make  $(du -h "$RT/usr/bin/make"  | cut -f1)"
log "   ninja $(du -h "$RT/usr/bin/ninja" | cut -f1)"
log "   size=$(stat -c %s "$OUT_PKG")  sha256=$(sha256sum "$OUT_PKG" | cut -d' ' -f1)"
