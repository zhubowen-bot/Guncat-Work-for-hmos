#!/usr/bin/env bash
# Guncat Work: 交叉编译 matplotlib（含 freetype / qhull / kiwisolver / contourpy）
#
# 依赖已有：numpy（build-numpy-ohos.sh）、zlib/libpng/libjpeg（build-pillow-ohos.sh）。
# matplotlib 3.9 用 meson + pybind11，构建期还要 setuptools_scm（版本号）。
#
# 踩过的坑：
#   1. freetype 的 GitHub tarball 带 `git submodule` 检查，必须用 savannah 的 release 包；
#      并且要 `--without-brotli --without-harfbuzz --without-bzip2`（否则缺 brotli 头）。
#   2. qhull 用 cmake 编（CMake ≥4 需要 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`），
#      并补一个 `qhull.pc` 别名；配置 matplotlib 时加 `-Dsystem-freetype=true -Dsystem-qhull=true`，
#      否则 meson 会去下载 subproject（网络不通就失败）。
#   3. kiwisolver 构建期依赖 `cppy`（纯 Python），contourpy 依赖 `meson-python` ——
#      都要装进**目标** python 的 site 目录（setup.py 在 qemu 下跑）。
#   4. matplotlib 的 meson.build 第 4 行用 `run_command(python3 -m setuptools_scm)` 取版本；
#      构建机上没有该包时，直接把这行换成字面版本号最省事。
#
# 用法: bash tooling/python/build-matplotlib-ohos.sh [版本, 默认 3.9.2]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
VER="${1:-3.9.2}"
WORK="${WORK:-$HOME/ohos-py-mpl}"
NP="${NPWORK:-$HOME/ohos-py-np}"
IMG="${IMGWORK:-$HOME/ohos-py-img}"
TC="${TC:-/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native}"
CLANG="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang"
CLANGXX="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang++"
STRIP="$TC/llvm/bin/llvm-strip"
LIBS="$PROJ/entry/libs/arm64-v8a"
ROOTFS="$NP/alpine-a64"
PREFIX="$IMG/prefix"
PYINC="${PYINC:-/root/cpython-ohos/dest/usr/local/include/python3.12}"
PYLIB="${PYLIB:-/root/cpython-ohos/dest/usr/local/lib}"

mkdir -p "$WORK"

# ---------- 1) freetype ----------
if [ ! -f "$PREFIX/lib/libfreetype.so" ]; then
  cd "$WORK"
  [ -d freetype-2.13.3 ] || { curl -sL -o ft.tar.xz \
      "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz"; tar xf ft.tar.xz; }
  ( cd freetype-2.13.3 && CC="$CLANG" AR="$TC/llvm/bin/llvm-ar" RANLIB="$TC/llvm/bin/llvm-ranlib" \
      ./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu --prefix="$PREFIX" \
      --without-harfbuzz --without-brotli --without-bzip2 \
      CPPFLAGS="--sysroot=$TC/sysroot -I$PREFIX/include" \
      CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC" \
      LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld -L$PREFIX/lib" \
      && make -j"$(nproc)" && make install )
fi

# ---------- 2) qhull ----------
if [ ! -f "$PREFIX/lib/libqhull_r.so" ]; then
  cd "$WORK"
  [ -d qhull-8.0.2 ] || { curl -sL -o qhull.tar.gz \
      "https://codeload.github.com/qhull/qhull/tar.gz/refs/tags/v8.0.2"; tar xzf qhull.tar.gz; }
  ( cd qhull-8.0.2 && rm -rf build-ohos && mkdir build-ohos && cd build-ohos && \
    cmake .. -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
      -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="$CLANGXX" \
      -DCMAKE_SYSROOT="$TC/sysroot" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="--sysroot=$TC/sysroot -O2 -fPIC" \
      -DCMAKE_CXX_FLAGS="--sysroot=$TC/sysroot -O2 -fPIC" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_STATIC_LIBS=OFF -DBUILD_SHARED_LIBS=ON && \
    make -j"$(nproc)" && make install )
  # matplotlib 找的是 qhull_r; 再补一个 qhull.pc 别名以防其它包要 qhull
  sed 's/Name: qhull_r/Name: qhull/' "$PREFIX/lib/pkgconfig/qhull_r.pc" > "$PREFIX/lib/pkgconfig/qhull.pc" || true
fi

# ---------- 3) kiwisolver / contourpy ----------
pip_target() {  # 包名
  python3 -m pip download "$1" --no-deps --only-binary=:all: --python-version 3.12 \
    --implementation py --abi none --platform any --quiet -d "$WORK/whl"
  python3 - "$WORK/whl" "$ROOTFS/py/site" <<'PY'
import sys, zipfile, glob
for w in glob.glob(sys.argv[1] + '/*.whl'):
    with zipfile.ZipFile(w) as z:
        z.extractall(sys.argv[2])
PY
}
pip_target cppy
pip_target meson-python

cd "$WORK"
[ -d kiwisolver-1.4.7 ] || { URL=$(curl -s https://pypi.org/pypi/kiwisolver/1.4.7/json | \
    python3 -c "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])"); \
    curl -sL -o kiwi.tar.gz "$URL"; tar xzf kiwi.tar.gz; }
( cd kiwisolver-1.4.7 && rm -rf build && \
  CC="$CLANG" CXX="$CLANGXX" LDSHARED="$CLANGXX --sysroot=$TC/sysroot -shared -fuse-ld=lld" \
  CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC -I$PYINC" CXXFLAGS="--sysroot=$TC/sysroot -O2 -fPIC -I$PYINC" \
  LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld -L$PYLIB" \
  "$ROOTFS/run-python.sh" setup.py build_ext --inplace )

if [ ! -d contourpy-1.3.1 ]; then
  URL=$(curl -s https://pypi.org/pypi/contourpy/1.3.1/json | \
    python3 -c "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
  curl -sL -o cp.tar.gz "$URL"; tar xzf cp.tar.gz
fi
( cd contourpy-1.3.1 && rm -rf builddir && \
  PKG_CONFIG_LIBDIR="$NP/pkgconfig:$ROOTFS/py/site/pybind11/share/pkgconfig" \
  PKG_CONFIG_ALLOW_CROSS=1 meson setup builddir --cross-file "$NP/cross2.txt" \
    --prefix="$WORK/cp-prefix" -Dbuildtype=release && \
  ninja -C builddir -j"$(nproc)" && DESTDIR="$WORK/cp-dest" meson install -C builddir )

# ---------- 4) matplotlib ----------
cd "$WORK"
if [ ! -d "matplotlib-$VER" ]; then
  URL=$(curl -s "https://pypi.org/pypi/matplotlib/$VER/json" | \
    python3 -c "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
  curl -sL -o "mpl.tar.gz" "$URL"; tar xzf mpl.tar.gz
fi
cd "matplotlib-$VER"
python3 - <<PY
import pathlib, re
p = pathlib.Path('meson.build'); t = p.read_text()
t = re.sub(r"version:\s*run_command\([^\n]*setuptools_scm[^\n]*\.stdout\(\)\.strip\(\),", "version: '$VER',", t)
p.write_text(t)
PY
rm -rf builddir
PKG_CONFIG_LIBDIR="$NP/pkgconfig:$PREFIX/lib/pkgconfig:$ROOTFS/py/site/pybind11/share/pkgconfig" \
PKG_CONFIG_ALLOW_CROSS=1 meson setup builddir --cross-file "$NP/cross2.txt" \
  --prefix="$WORK/mpl-prefix" -Dbuildtype=release \
  -Dsystem-freetype=true -Dsystem-qhull=true
ninja -C builddir -j"$(nproc)"
rm -rf "$WORK/mpl-dest"
DESTDIR="$WORK/mpl-dest" meson install -C builddir

# ---------- 5) 打包（双层布局） ----------
SP=$(find "$WORK/mpl-dest" -type d -name site-packages | head -1)
rm -rf "$LIBS/matplotlib" && mkdir -p "$LIBS/matplotlib"
( cd "$SP/matplotlib" && find . -name '*.so' | while read -r f; do
    mkdir -p "$LIBS/matplotlib/$(dirname "$f")"; cp -f "$SP/matplotlib/$f" "$LIBS/matplotlib/$f"; done )
rm -rf "$LIBS/kiwisolver" "$LIBS/contourpy"
mkdir -p "$LIBS/kiwisolver" "$LIBS/contourpy"
cp -f "$WORK"/kiwisolver-1.4.7/py/kiwisolver/*.so "$LIBS/kiwisolver/"
cp -f "$WORK"/cp-dest/*/lib/python3.12/site-packages/contourpy/*.so "$LIBS/contourpy/" 2>/dev/null || \
  cp -f "$WORK"/cp-prefix/lib/python3.12/site-packages/contourpy/*.so "$LIBS/contourpy/"
cp -f "$PREFIX"/lib/libfreetype.so.6.* "$LIBS/libfreetype.so.6"
cp -f "$PREFIX"/lib/libqhull_r.so.8.* "$LIBS/libqhull_r.so.8"
"$STRIP" --strip-unneeded "$LIBS"/matplotlib/**/*.so "$LIBS"/kiwisolver/*.so "$LIBS"/contourpy/*.so \
  "$LIBS/libfreetype.so.6" "$LIBS/libqhull_r.so.8" 2>/dev/null || true

echo "== 产物"
du -sm "$LIBS/matplotlib" "$LIBS/kiwisolver" "$LIBS/contourpy" | awk '{print $2, $1"MB"}'
echo "== matplotlib 的 .py 与 mpl-data 需要合并进 rawfile/python/extras.zip"
