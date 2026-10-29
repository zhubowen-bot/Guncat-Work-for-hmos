#!/bin/bash
# build_openssl.sh — 交叉编译 OpenSSL 3.0(只出静态库),供 CPython 的 _ssl/_hashlib 用
#
# 产物:
#   build/openssl/{include/openssl/*.h, lib/libssl.a, lib/libcrypto.a, lib/pkgconfig/*.pc}
# 消费者:
#   scripts/build_python.sh —— configure 时 `--with-openssl=<该目录>` 且
#   `PY_UNSUPPORTED_OPENSSL_BUILD=static`,CPython 会把 `-lssl -lcrypto` 换成
#   `-l:libssl.a -Wl,--exclude-libs,libssl.a`(见 configure.ac:7097-7116),
#   _ssl/_hashlib 两个模块随之被静态编进 libpython.so。
#
# 为什么是静态库(而不是 libssl.so/libcrypto.so):
#   * 命令 so 形态下,libpython.so 由 procmgr dlopen 进来,它再 dlopen 的 .so 必须落在
#     **可映射执行**的位置(bundle libs)。资源根(el2)是 noexec,openssl 的 so 放那儿
#     加载不了 —— 静态链把整块塞进 libpython.so,不引入新的装载问题。
#   * --exclude-libs 是刚需:否则 libcrypto 的符号会进 libpython.so 的**动态**符号表,
#     与宿主进程可能自带的 openssl 撞名(静态库符号默认是导出的)。
#   * libcrypto.a 必须带 -fPIC 才能链进 so,所以 Configure 末尾显式给 -fPIC。
#
# 为什么 no-module:
#   OpenSSL 3.x 的 provider 默认可以构建成**动态模块**(providers/*.so)。我们既要静态,
#   guest 侧又没有 DSO 加载能力 ⇒ 必须让 default provider 编进 libcrypto(no-module)。
#   顺带把 dynamic-engine / fips 一起关掉(Configure 的级联,见 Configure:601)。
#
# 依赖:宿主 perl(Configure 与 asm 生成都靠它)、OHOS SDK clang、env.sh。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

OSSL_VER="${OSSL_VER:-3.0.22}"
SRC_TAR="$ROOT/thirdparty/openssl-$OSSL_VER.tar.gz"
SRC="$ROOT/thirdparty/openssl-$OSSL_VER"
OUT="$BUILD_DIR/openssl"                 # 安装前缀(给 build_python.sh 用)
BLD="$BUILD_DIR/openssl-build"
SRC_URLS=(
    "https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-$OSSL_VER"
    "https://github.com/openssl/openssl/releases/download/openssl-$OSSL_VER/openssl-$OSSL_VER.tar.gz"
)

AR="$CLANG_DIR/llvm-ar"
RANLIB="$CLANG_DIR/llvm-ranlib"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT"
JOBS="${JOBS:-4}"

# 幂等:库文件在就跳过(整个重编约 3~5 分钟,增量重跑没必要)
if [ -f "$OUT/lib/libssl.a" ] && [ -f "$OUT/lib/libcrypto.a" ] && [ -z "${OSSL_REBUILD:-}" ]; then
    log "openssl 已构建:$OUT/lib/libssl.a(OSSL_REBUILD=1 可强制重来)"
    exit 0
fi

# ── 0. 源码 ────────────────────────────────────────────────
if [ ! -d "$SRC" ]; then
    if [ ! -s "$SRC_TAR" ]; then
        log "下载 openssl $OSSL_VER"
        ok=
        for u in "${SRC_URLS[@]}"; do
            # github 的 releases 走 objects.githubusercontent.com,不走代理时很慢;
            # env.sh 已经探测并 export 了代理,codeload 源优先。
            if curl -sL --retry 3 -m 600 -o "$SRC_TAR" "$u" && [ -s "$SRC_TAR" ]; then ok=1; break; fi
        done
        [ -n "$ok" ] || err "openssl 源码下载失败"
    fi
    log "解包 openssl $OSSL_VER"
    rm -rf "$BUILD_DIR/openssl-x" && mkdir -p "$BUILD_DIR/openssl-x"
    tar xzf "$SRC_TAR" -C "$BUILD_DIR/openssl-x"
    # git tarball 顶层是 openssl-openssl-<ver>/,发布版是 openssl-<ver>/
    inner="$(ls "$BUILD_DIR/openssl-x")"
    mv "$BUILD_DIR/openssl-x/$inner" "$SRC"
    rmdir "$BUILD_DIR/openssl-x"
fi
[ -f "$SRC/Configure" ] || err "openssl 源码结构异常:$SRC"

# ── 1. Configure(out-of-tree)────────────────────────────────
# OpenSSL 的 Configure 是 perl 脚本(不走 autotools),支持在源码树外运行:
# 在 $BLD 下 rootdir=.. 调用它,生成的 Makefile 会记住 SRCDIR。
if [ ! -f "$BLD/Makefile" ]; then
    log "=== 配置 openssl(linux-aarch64,静态) ==="
    rm -rf "$BLD" && mkdir -p "$BLD"
    ( cd "$BLD" && \
      CC="$CC_TARGET" AR="$AR" RANLIB="$RANLIB" CROSS_COMPILE= \
      perl "$SRC/Configure" linux-aarch64 \
        --prefix="$OUT" --openssldir="$OUT/ssl" --libdir=lib \
        no-shared no-module no-tests \
        -fPIC \
        > "$BUILD_DIR/openssl-configure.log" 2>&1 ) || {
            tail -30 "$BUILD_DIR/openssl-configure.log" >&2 || true
            err "openssl Configure 失败:见 $BUILD_DIR/openssl-configure.log"
        }
fi

# ── 2. make + install_sw ───────────────────────────────────
log "=== 编译 openssl(make -j$JOBS;几分钟) ==="
make -C "$BLD" -j"$JOBS" > "$BUILD_DIR/openssl-make.log" 2>&1 \
    || { tail -40 "$BUILD_DIR/openssl-make.log" >&2; err "openssl make 失败:见 $BUILD_DIR/openssl-make.log"; }

# install_sw = 装库 + 头文件 + apps(不装 man/文档;OpenSSL 3.0 没有 no-apps/no-docs
# 这两个开关,它们只出现在 configure 的级联表里,不是可传给 Configure 的选项)
log "=== 安装到 $OUT ==="
make -C "$BLD" install_sw > "$BUILD_DIR/openssl-install.log" 2>&1 \
    || { tail -30 "$BUILD_DIR/openssl-install.log" >&2; err "openssl install_sw 失败"; }

# ── 3. 校验 ────────────────────────────────────────────────
for f in lib/libssl.a lib/libcrypto.a include/openssl/ssl.h; do
    [ -e "$OUT/$f" ] || err "缺 $OUT/$f"
done
# 目标架构要是 aarch64(踩过:CC 没生效时会偷偷用宿主 gcc)
"$CLANG_DIR/llvm-objdump" -f "$OUT/lib/libcrypto.a" 2>/dev/null | grep -m1 -i "arch" \
    || warn "llvm-objdump 没读出架构,自己核一下 $OUT/lib/libcrypto.a"

log "openssl 就绪:$OUT"
log "  体积:libssl.a $(du -h "$OUT/lib/libssl.a" | cut -f1) / libcrypto.a $(du -h "$OUT/lib/libcrypto.a" | cut -f1)"
