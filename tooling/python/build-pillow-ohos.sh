#!/usr/bin/env bash
# Guncat Work: 交叉编译 Pillow（依赖 zlib / libjpeg-turbo / libpng）
#
# 关键点（踩过的坑都写在这）：
#   1. Pillow 的 setup.py 会把 **host** 的 /usr/include、/usr/lib 加进编译/链接命令，
#      交叉编译时会把 glibc 头文件和 x86 库拖进来，报
#      `bits/libc-header-start.h not found` / `--fix-cortex-a53-843419 is only supported on
#      AArch64 targets`。解法是加 `--disable-platform-guessing`（setup.py 自带开关），
#      一次清掉所有 host 路径。
#   2. setup.py 必须在**目标 python**（qemu 下）里跑，这样它用目标 sysconfig 计算 ABI 后缀；
#      编译器仍是 host 上的交叉 clang（由 CC/LDSHARED 指定）。
#   3. 目标 python 需要 setuptools（纯 Python 轮子，解到 $ROOTFS/py/site）。
#   4. 产物按双层布局打包：.py → extras.zip，.so → entry/libs/arm64-v8a/PIL/；
#      依赖库 libjpeg.so.62 / libpng16.so.16 也随包。
#
# 用法: bash tooling/python/build-pillow-ohos.sh [版本, 默认 11.0.0]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
VER="${1:-11.0.0}"
WORK="${WORK:-$HOME/ohos-py-img}"
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

# ---------- 1) zlib / libpng / libjpeg-turbo ----------
if [ ! -f "$PREFIX/include/zlib.h" ]; then
  cd "$WORK"
  [ -d zlib-1.3.1 ] || { curl -sL -o zlib.tar.gz \
      "https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v1.3.1"; tar xzf zlib.tar.gz; }
  ( cd zlib-1.3.1 && CC="$CLANG" AR="$TC/llvm/bin/llvm-ar" RANLIB="$TC/llvm/bin/llvm-ranlib" \
      CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC" LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld" \
      ./configure --prefix="$PREFIX" --shared && make -j"$(nproc)" && make install )
fi
if [ ! -f "$PREFIX/include/png.h" ]; then
  cd "$WORK"
  [ -d libpng-1.6.44 ] || { curl -sL -o png.tar.gz \
      "https://codeload.github.com/pnggroup/libpng/tar.gz/refs/tags/v1.6.44"; tar xzf png.tar.gz; }
  ( cd libpng-1.6.44 && CC="$CLANG" AR="$TC/llvm/bin/llvm-ar" RANLIB="$TC/llvm/bin/llvm-ranlib" \
      CPPFLAGS="--sysroot=$TC/sysroot -I$PREFIX/include" \
      CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC" \
      LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld -L$PREFIX/lib" \
      ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix="$PREFIX" --disable-static \
      && make -j"$(nproc)" && make install )
fi
if [ ! -f "$PREFIX/lib/libjpeg.so" ]; then
  cd "$WORK"
  [ -d libjpeg-turbo-3.0.4 ] || { curl -sL -o jpeg.tar.gz \
      "https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/refs/tags/3.0.4"; tar xzf jpeg.tar.gz; }
  rm -rf libjpeg-turbo-3.0.4/build-ohos && mkdir -p libjpeg-turbo-3.0.4/build-ohos
  ( cd libjpeg-turbo-3.0.4/build-ohos && cmake .. -DCMAKE_SYSTEM_NAME=Linux \
      -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER="$CLANG" \
      -DCMAKE_SYSROOT="$TC/sysroot" -DCMAKE_C_FLAGS="--sysroot=$TC/sysroot -O2 -fPIC" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DENABLE_SHARED=ON -DENABLE_STATIC=OFF \
      -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DCMAKE_BUILD_TYPE=Release \
      && make -j"$(nproc)" && make install )
fi

# ---------- 2) 目标侧 setuptools（纯 Python） ----------
if [ ! -d "$ROOTFS/py/site/setuptools" ]; then
  python3 -m pip download setuptools --no-deps --only-binary=:all: --python-version 3.12 \
    --implementation py --abi none --platform any -d "$WORK/tgt-whl" --quiet
  python3 - "$WORK/tgt-whl" "$ROOTFS/py/site" <<'PY'
import sys, zipfile, glob
for w in glob.glob(sys.argv[1] + '/*.whl'):
    with zipfile.ZipFile(w) as z:
        z.extractall(sys.argv[2])
PY
fi

# ---------- 3) Pillow ----------
cd "$WORK"
if [ ! -d "Pillow-$VER" ]; then
  curl -sL -o "pillow-$VER.tar.gz" "https://codeload.github.com/python-pillow/Pillow/tar.gz/refs/tags/$VER"
  tar xzf "pillow-$VER.tar.gz"
fi
cd "Pillow-$VER"
export CC="$CLANG"
export LDSHARED="$CLANG --sysroot=$TC/sysroot -shared -fuse-ld=lld"
export CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC -I$PYINC -I$PREFIX/include"
export LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld -L$PREFIX/lib -L$PYLIB"
export JPEG_ROOT="$PREFIX" PNG_ROOT="$PREFIX" ZLIB_ROOT="$PREFIX" MAX_CONCURRENCY="$(nproc)"
rm -rf build
"$ROOTFS/run-python.sh" setup.py build_ext --inplace --disable-platform-guessing

# ---------- 4) 打包（双层布局） ----------
rm -rf "$LIBS/PIL" && mkdir -p "$LIBS/PIL"
cp -f src/PIL/*.so "$LIBS/PIL/"
cp -f "$PREFIX/lib/libjpeg.so.62".* "$LIBS/libjpeg.so.62"
cp -f "$PREFIX/lib/libpng16.so.16".* "$LIBS/libpng16.so.16"
"$STRIP" --strip-unneeded "$LIBS/PIL"/*.so "$LIBS/libjpeg.so.62" "$LIBS/libpng16.so.16" 2>/dev/null || true

EXTRAS="$WORK/extras-src"
mkdir -p "$EXTRAS"
rm -rf "$EXTRAS/PIL" && cp -r src/PIL "$EXTRAS/PIL"
find "$EXTRAS/PIL" -name '*.so' -delete
find "$EXTRAS/PIL" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
echo "PIL 纯 Python 部分已放到 $EXTRAS/PIL —— 需要合并进 rawfile/python/extras.zip"

echo "== 产物"
du -sm "$LIBS/PIL" | awk '{print "PIL .so:", $1, "MB"}'
ls "$LIBS"/libjpeg.so.62 "$LIBS"/libpng16.so.16 | head -2
