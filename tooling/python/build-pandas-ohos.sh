#!/usr/bin/env bash
# Guncat Work: 交叉编译 pandas（并顺带补上 ctypes / libffi）
#
# 依赖 numpy（先跑 build-numpy-ohos.sh）。复用同一套 qemu + Alpine rootfs 基建，
# 主要多出两件事：
#   1. pandas 的 `pandas/errors/__init__.py` 里 import ctypes —— 我们的 CPython 当初
#      因为缺 libffi 把 `_ctypes` 关掉了。这里交叉编 libffi，再手工编出 `_ctypes` 扩展；
#   2. pandas 用 Cython，`cimport numpy` 需要 numpy 的 .pxd。host 侧 cython 找不到，
#      于是把 numpy 的 pxd 树复制到 pandas 源码根的 numpy/ 目录下（Cython 会搜当前目录）。
#
# 用法: bash tooling/python/build-pandas-ohos.sh [版本, 默认 2.2.3]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
PD_VER="${1:-2.2.3}"
WORK="${WORK:-$HOME/ohos-py-pd}"
NP="${NPWORK:-$HOME/ohos-py-np}"
TC="${TC:-/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native}"
CLANG="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang"
AR="$TC/llvm/bin/llvm-ar"
RANLIB="$TC/llvm/bin/llvm-ranlib"
STRIP="$TC/llvm/bin/llvm-strip"
LIBS="$PROJ/entry/libs/arm64-v8a"
CPYSRC="${CPYSRC:-/root/cpython-ohos/Python-3.12.15}"
PYDEST="${PYDEST:-/root/cpython-ohos/dest/usr/local}"
ROOTFS="$NP/alpine-a64"

echo "== pandas $PD_VER"

# ---------- 1) libffi ----------
if [ ! -f /root/libffi-prefix/lib/libffi.so.8.1.4 ]; then
  cd /root
  [ -d libffi-3.4.6 ] || { curl -sL -o libffi.tar.gz \
      "https://codeload.github.com/libffi/libffi/tar.gz/refs/tags/v3.4.6"; tar xzf libffi.tar.gz; }
  cd libffi-3.4.6
  [ -x ./configure ] || ./autogen.sh > /root/libffi-autogen.log 2>&1 || autoreconf -fi >> /root/libffi-autogen.log 2>&1
  # libffi 的 config.sub 不认 ohos, 用 aarch64-linux-gnu 让它过校验, 实际编译器仍是 OHOS clang
  ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix=/root/libffi-prefix \
    --disable-static --enable-shared \
    CC="$CLANG" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC" LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld"
  make -j"$(nproc)" || true
  make install
fi

# ---------- 2) _ctypes 扩展 ----------
FFIINC=$(dirname "$(find /root/libffi-prefix -name ffi.h | head -1)")
CTYPES_SO="$WORK/_ctypes.cpython-312-aarch64-linux-gnu.so"
"$CLANG" --sysroot="$TC/sysroot" -shared -fPIC -O2 \
  -I"$CPYSRC" -I"$CPYSRC/Include" -I"$CPYSRC/Include/internal" \
  -I"$CPYSRC/Modules/_ctypes" -I"$FFIINC" \
  -o "$CTYPES_SO" \
  "$CPYSRC/Modules/_ctypes/_ctypes.c" "$CPYSRC/Modules/_ctypes/callbacks.c" \
  "$CPYSRC/Modules/_ctypes/callproc.c" "$CPYSRC/Modules/_ctypes/cfield.c" \
  "$CPYSRC/Modules/_ctypes/malloc_closure.c" "$CPYSRC/Modules/_ctypes/stgdict.c" \
  -L/root/libffi-prefix/lib -lffi -L"$PYDEST/lib" -Wl,--no-as-needed -lpython3.12

# ---------- 3) pandas ----------
mkdir -p "$WORK" && cd "$WORK"
if [ ! -d "pandas-$PD_VER" ]; then
  URL=$(curl -s "https://pypi.org/pypi/pandas/$PD_VER/json" | python3 -c \
    "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
  curl -sL -o "pandas-$PD_VER.tar.gz" "$URL"
  tar xzf "pandas-$PD_VER.tar.gz"
fi
cd "pandas-$PD_VER"

# versioneer 是 sdist 构建期依赖(纯 Python)
python3 -m pip install -q --break-system-packages versioneer 2>/dev/null || true

# Cython 的 `cimport numpy` 在 host 侧找不到 pxd —— 把 numpy 的 pxd 树放到源码根
if [ -d "$ROOTFS/libs/numpy" ]; then
  mkdir -p numpy
  ( cd "$ROOTFS/libs/numpy" && find . -name '*.pxd' | while read -r f; do
      mkdir -p "$WORK/pandas-$PD_VER/numpy/$(dirname "$f")"
      cp -f "$ROOTFS/libs/numpy/$f" "$WORK/pandas-$PD_VER/numpy/$f"
    done )
fi

rm -rf builddir
PKG_CONFIG_LIBDIR="$NP/pkgconfig" PKG_CONFIG_PATH="$NP/pkgconfig" PKG_CONFIG_ALLOW_CROSS=1 \
meson setup builddir --cross-file "$NP/cross2.txt" \
  --prefix="$WORK/prefix" -Dbuildtype=release
ninja -C builddir -j "$(nproc)"
rm -rf "$WORK/dest"
DESTDIR="$WORK/dest" meson install -C builddir

# ---------- 4) 打包 ----------
SP=$(find "$WORK/dest" -type d -name site-packages | head -1)
rm -rf "$LIBS/pandas"
cp -rL "$SP/pandas" "$LIBS/pandas"
rm -rf "$LIBS/pandas/tests" "$LIBS/pandas/io/tests" "$LIBS/pandas/plotting/tests" 2>/dev/null || true
find "$LIBS/pandas" -name '*.so' -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true
cp -f "$CTYPES_SO" "$LIBS/"
cp -f /root/libffi-prefix/lib/libffi.so.8.1.4 "$LIBS/libffi.so.8"
"$STRIP" --strip-unneeded "$LIBS/libffi.so.8" 2>/dev/null || true

echo "== 产物"
du -sm "$LIBS/pandas" | awk '{print "pandas:", $1, "MB"}'
ls -l "$LIBS/libffi.so.8" "$LIBS/_ctypes.cpython-312-aarch64-linux-gnu.so" | awk '{print $5, $9}'
echo "== 自检(qemu)"
"$ROOTFS/run-python.sh" -c "
import ctypes, pandas as pd, numpy as np
print('ctypes sqrt:', ctypes.CDLL('libm.so').sqrt(9.0) if False else 'ok')
df = pd.DataFrame({'a': [1, 1, 2], 'b': [1.0, 2.0, 3.0]})
print('pandas', pd.__version__, '| groupby', df.groupby('a')['b'].sum().to_dict())
"
