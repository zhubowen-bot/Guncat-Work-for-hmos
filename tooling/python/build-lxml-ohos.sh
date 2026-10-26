#!/usr/bin/env bash
# Guncat Work: 交叉编译 lxml（依赖 libxml2 / libxslt）
#
# 两个必须知道的点：
#   1. **必须用 PyPI 的 sdist，不要用 GitHub tag**。GitHub 的源码树只有 .pyx，会用构建机上
#      的 Cython 现生成 C；Cython 3.3 生成的结果和 lxml 5.3 的代码不兼容，编译器报
#      `use of undeclared identifier '__pyx_empty_tuple'`。PyPI sdist 里带**已经生成好的 C**，
#      直接编就过。
#   2. libxml2 / libxslt 都是 autotools：GitHub tag 没有 configure，先 `autoreconf -fi`；
#      config.sub 不认 `ohos`，用 `--host=aarch64-linux-gnu` 混过去（实际编译器仍是 OHOS clang）。
#
# 用法: bash tooling/python/build-lxml-ohos.sh [lxml 版本, 默认 5.3.0]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
VER="${1:-5.3.0}"
WORK="${WORK:-$HOME/ohos-py-xml}"
NP="${NPWORK:-$HOME/ohos-py-np}"
TC="${TC:-/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native}"
CLANG="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang"
STRIP="$TC/llvm/bin/llvm-strip"
LIBS="$PROJ/entry/libs/arm64-v8a"
ROOTFS="$NP/alpine-a64"
PREFIX="$WORK/prefix"
PYINC="${PYINC:-/root/cpython-ohos/dest/usr/local/include/python3.12}"
PYLIB="${PYLIB:-/root/cpython-ohos/dest/usr/local/lib}"

mkdir -p "$WORK"

# ---------- 1) libxml2 ----------
if [ ! -f "$PREFIX/lib/libxml2.so" ]; then
  cd "$WORK"
  [ -d libxml2-2.13.5 ] || { curl -sL -o x2.tar.gz \
      "https://codeload.github.com/GNOME/libxml2/tar.gz/refs/tags/v2.13.5"; tar xzf x2.tar.gz; }
  ( cd libxml2-2.13.5 && [ -x ./configure ] || autoreconf -fi > /dev/null 2>&1
    CC="$CLANG" AR="$TC/llvm/bin/llvm-ar" RANLIB="$TC/llvm/bin/llvm-ranlib" \
    ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix="$PREFIX" \
      --disable-static --without-python --without-lzma \
      CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC" \
      LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld" \
    && make -j"$(nproc)" && make install )
fi

# ---------- 2) libxslt ----------
if [ ! -f "$PREFIX/lib/libxslt.so" ]; then
  cd "$WORK"
  [ -d libxslt-1.1.42 ] || { curl -sL -o xs.tar.gz \
      "https://codeload.github.com/GNOME/libxslt/tar.gz/refs/tags/v1.1.42"; tar xzf xs.tar.gz; }
  ( cd libxslt-1.1.42 && [ -x ./configure ] || autoreconf -fi > /dev/null 2>&1
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    CC="$CLANG" AR="$TC/llvm/bin/llvm-ar" RANLIB="$TC/llvm/bin/llvm-ranlib" \
    ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix="$PREFIX" \
      --disable-static --without-python --without-crypto --with-libxml-prefix="$PREFIX" \
      CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC -I$PREFIX/include" \
      LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld -L$PREFIX/lib" \
    && make -j"$(nproc)" && make install )
fi

# ---------- 3) lxml（用 PyPI sdist，自带生成的 C） ----------
cd "$WORK"
if [ ! -d "lxml-$VER" ]; then
  URL=$(curl -s "https://pypi.org/pypi/lxml/$VER/json" | \
    python3 -c "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
  curl -sL -o "lxml-$VER.tar.gz" "$URL"
  mkdir -p "lxml-$VER" && tar xzf "lxml-$VER.tar.gz" -C "lxml-$VER" --strip-components=1
fi
cd "lxml-$VER"
export CC="$CLANG"
export LDSHARED="$CLANG --sysroot=$TC/sysroot -shared -fuse-ld=lld"
export CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC -I$PYINC -I$PREFIX/include"
export LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld -L$PREFIX/lib -L$PYLIB"
export WITH_XML2_CONFIG="$PREFIX/bin/xml2-config"
export WITH_XSLT_CONFIG="$PREFIX/bin/xslt-config"
export LXML_NO_CYTHON=1
rm -rf build
"$ROOTFS/run-python.sh" setup.py build_ext --inplace

# ---------- 4) 打包 ----------
rm -rf "$LIBS/lxml" && mkdir -p "$LIBS/lxml"
( cd src/lxml && find . -name '*.so' | while read -r f; do
    mkdir -p "$LIBS/lxml/$(dirname "$f")"; cp -f "src/lxml/$f" "$LIBS/lxml/$f"; done )
find "$LIBS/lxml" -name '*.so' -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true
for lib in libxml2.so.2 libxslt.so.1 libexslt.so.0; do
  src=$(ls "$PREFIX/lib/$lib".* 2>/dev/null | head -1)
  [ -n "$src" ] && cp -f "$src" "$LIBS/$lib" && "$STRIP" --strip-unneeded "$LIBS/$lib" 2>/dev/null || true
done

echo "== 产物"
find "$LIBS/lxml" -name '*.so' | wc -l
ls -l "$LIBS"/libxml2.so.2 "$LIBS"/libxslt.so.1 "$LIBS"/libexslt.so.0 2>/dev/null | awk '{print $5, $9}'
echo "== lxml 的 .py 需要在 extras.zip 里（去掉 .c/.pxi/.pxd/includes 以减小体积）"
