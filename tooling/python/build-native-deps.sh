#!/usr/bin/env bash
# Guncat Work: 为原生 CPython 准备它缺的四个 C 依赖(交叉编译到 HarmonyOS aarch64):
#   * OpenSSL 3   → _ssl / _hashlib(https、pbkdf2_hmac、scrypt)
#   * SQLite 3    → _sqlite3
#   * bzip2       → _bz2
#   * xz/liblzma  → _lzma
#
# 产物装进同一个 prefix(默认 $HOME/ohos-py-deps), 随后 build-cpython-ohos.sh 用
# CPPFLAGS/LDFLAGS 指过去, configure 就会把这些扩展打开。
#
# 为什么用"共享库 + SONAME=短名": 扩展靠 DT_NEEDED 找它们(和 libz.so 同一条路径),
# 设备上应用 lib 目录里的 .so 允许被加载; SONAME 去掉版本号, 包里只需要一个文件。
#
# 用法:
#   TOOL_HOME=/opt/ohos-cmdline/command-line-tools bash tooling/python/build-native-deps.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_HOME="${TOOL_HOME:-/opt/ohos-cmdline/command-line-tools}"
WORK="${WORK:-$HOME/ohos-py-deps}"
PREFIX="${PREFIX:-$WORK/prefix}"

NATIVE="$TOOL_HOME/sdk/default/openharmony/native"
SYSROOT="$NATIVE/sysroot"
CLANG="$NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang"
CLANGXX="$NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang++"
LLVM_BIN="$NATIVE/llvm/bin"

OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.15}"
SQLITE_VERSION="${SQLITE_VERSION:-3.45.3}"
BZIP2_VERSION="${BZIP2_VERSION:-1.0.8}"
XZ_VERSION="${XZ_VERSION:-5.4.6}"

[ -x "$CLANG" ] || { echo "ERROR: 找不到 OHOS clang: $CLANG" >&2; exit 1; }
mkdir -p "$WORK" "$PREFIX/include" "$PREFIX/lib"

export CC="$CLANG"
export CXX="$CLANGXX"
export AR="$LLVM_BIN/llvm-ar"
export RANLIB="$LLVM_BIN/llvm-ranlib"
export STRIP="$LLVM_BIN/llvm-strip"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
unset CFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true

fetch() {  # url, outfile
  [ -s "$2" ] || curl -L --retry 3 -m 900 -o "$2" "$1"
}

unpack_dir() {  # tarball, 期望的目录名
  local tb="$1" want="$2"
  [ -d "$want" ] && return 0
  tar xzf "$tb"
  # 注意: 不能用 `tar tzf | head -1` —— head 提前关闭管道会让 tar 收到 SIGPIPE,
  # 在 `set -o pipefail` 下整条命令以 141 失败(踩过)。
  local listing got
  listing="$(tar tzf "$tb")" || return 1
  got="${listing%%/*}"
  [ "$got" = "$want" ] || mv "$got" "$want"
}

# ---------------- OpenSSL ----------------
echo "== OpenSSL $OPENSSL_VERSION"
cd "$WORK"
fetch "https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-$OPENSSL_VERSION" "openssl-$OPENSSL_VERSION.tar.gz"
unpack_dir "openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION"
cd "openssl-$OPENSSL_VERSION"
if [ ! -f Makefile ]; then
  ./Configure linux-aarch64 \
    --prefix="$PREFIX" --openssldir="$PREFIX/ssl" \
    shared no-tests \
    --with-rand-seed=getrandom \
    -D__MUSL__ \
    "--sysroot=$SYSROOT -O2 -fPIC -fuse-ld=lld -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0" \
    > "$WORK/openssl-configure.log" 2>&1
fi
make -j"$(nproc)" > "$WORK/openssl-build.log" 2>&1
make install_sw > "$WORK/openssl-install.log" 2>&1
# SONAME 已经是 libssl.so.3 / libcrypto.so.3, 保持原样(设备按名字找)
ls -l "$PREFIX/lib"/libssl.so* "$PREFIX/lib"/libcrypto.so* | awk '{print $5, $9}'

# ---------------- SQLite ----------------
# 官方 amalgamation 下载站(www.sqlite.org)在本网络经常 TLS 断连, 改为从 GitHub 镜像
# 取源码再用仓库自带的 make 目标生成 sqlite3.c(需要 tclsh)。
echo "== SQLite $SQLITE_VERSION"
cd "$WORK"
SQLITE_TAG="version-$SQLITE_VERSION"
SQLITE_DIR="sqlite-$SQLITE_TAG"
if [ ! -d "$SQLITE_DIR" ]; then
  fetch "https://codeload.github.com/sqlite/sqlite/tar.gz/refs/tags/$SQLITE_TAG" "$SQLITE_TAG.tar.gz"
  unpack_dir "$SQLITE_TAG.tar.gz" "$SQLITE_DIR"
fi
if [ ! -f "$SQLITE_DIR/sqlite3.c" ]; then
  # 生成 amalgamation 只需要 tclsh, 不需要目标编译器; 用宿主 gcc 过掉 configure 的
  # "能否运行编译产物" 探测(用 OHOS 交叉编译器时 configure 会判定无法运行而失败)。
  ( cd "$SQLITE_DIR" && CC=gcc CFLAGS="-O0" ./configure > "$WORK/sqlite-configure.log" 2>&1 && \
    make sqlite3.c > "$WORK/sqlite-amalgamation.log" 2>&1 )
fi
"$CC" --sysroot="$SYSROOT" -O2 -fPIC -shared -Wl,-soname,libsqlite3.so \
  -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_ENABLE_FTS5 \
  -o "$PREFIX/lib/libsqlite3.so" "$SQLITE_DIR/sqlite3.c"
cp "$SQLITE_DIR/sqlite3.h" "$PREFIX/include/"
[ -f "$SQLITE_DIR/sqlite3ext.h" ] && cp "$SQLITE_DIR/sqlite3ext.h" "$PREFIX/include/" || true
"$STRIP" --strip-unneeded "$PREFIX/lib/libsqlite3.so"
ls -l "$PREFIX/lib/libsqlite3.so" | awk '{print $5, $9}'

# ---------------- bzip2 ----------------
echo "== bzip2 $BZIP2_VERSION"
cd "$WORK"
BZ="bzip2-$BZIP2_VERSION"
if [ ! -d "$BZ" ]; then
  fetch "https://sourceware.org/pub/bzip2/$BZ.tar.gz" "$BZ.tar.gz"
  tar xzf "$BZ.tar.gz"
fi
"$CC" --sysroot="$SYSROOT" -O2 -fPIC -shared -Wl,-soname,libbz2.so \
  -D_FILE_OFFSET_BITS=64 -o "$PREFIX/lib/libbz2.so" \
  "$BZ/blocksort.c" "$BZ/huffman.c" "$BZ/crctable.c" "$BZ/randtable.c" "$BZ/compress.c" \
  "$BZ/decompress.c" "$BZ/bzlib.c"
cp "$BZ/bzlib.h" "$PREFIX/include/"
"$STRIP" --strip-unneeded "$PREFIX/lib/libbz2.so"
ls -l "$PREFIX/lib/libbz2.so" | awk '{print $5, $9}'

# ---------------- xz / liblzma ----------------
echo "== xz $XZ_VERSION"
cd "$WORK"
XZ="xz-$XZ_VERSION"
if [ ! -d "$XZ" ]; then
  fetch "https://codeload.github.com/tukaani-project/xz/tar.gz/refs/tags/v$XZ_VERSION" "$XZ.tar.gz"
  tar xzf "$XZ.tar.gz"
  listing="$(tar tzf "$XZ.tar.gz")" || exit 1
  got="${listing%%/*}"
  [ "$got" = "$XZ" ] || mv "$got" "$XZ"
fi
cd "$XZ"
# GitHub 的 release tarball 不含生成的 configure, 先用 autotools 生成
if [ ! -x ./configure ]; then
  autoreconf -fi > "$WORK/xz-autogen.log" 2>&1
fi
if [ ! -f Makefile ]; then
  ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu \
    --prefix="$PREFIX" --disable-static --enable-shared \
    --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
    --disable-scripts --disable-nls --disable-doc \
    CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="--sysroot=$SYSROOT -O2 -fPIC" LDFLAGS="--sysroot=$SYSROOT -fuse-ld=lld" \
    > "$WORK/xz-configure.log" 2>&1
fi
make -j"$(nproc)" > "$WORK/xz-build.log" 2>&1
make install > "$WORK/xz-install.log" 2>&1
ls -l "$PREFIX/lib"/liblzma.so* | awk '{print $5, $9}'

echo "== 完成: $PREFIX"
ls "$PREFIX/include" | tr '\n' ' '; echo
ls "$PREFIX/lib" | tr '\n' ' '; echo
