#!/usr/bin/env bash
# Guncat Work: 交叉编译 scipy（OpenBLAS/LAPACK + Fortran）
#
# 这是整条流水线里最麻烦的一环，踩过的坑全部固化在这里：
#   1. OHOS SDK 没有 Fortran 编译器 → 用 Ubuntu 的 gfortran-aarch64-linux-gnu(GCC 15)；
#   2. OpenBLAS 用 TARGET=ARMV8 + OHOS clang + 交叉 gfortran 编译，产出**含 LAPACK** 的静态库，
#      再链成 OHOS 可用的 libopenblas.so（LAPACK 只需要 2 个 libgfortran 符号，见 gfortran-shim.c）；
#   3. scipy 的 meson 交叉文件里 fc 必须指向**包装器**（ohos-fc）：编译用 gfortran、链接用 OHOS clang，
#      否则产物会 DT_NEEDED glibc 版 libgfortran，在 musl 上加载即失败；
#   4. 包装器要给 cython/f2py/pythran 加 `-P`：meson 的 cwd 在 scipy 源码树里，
#      不加的话 `import signal` 会命中 scipy/signal 而不是标准库（真的踩过）；
#   5. numpy 的 .pxd 必须复制进 build 根，否则 `cimport numpy` 找不到；
#   6. ARPACK 需要 -fallow-argument-mismatch，但 clang 不认这个参数，包装器里要过滤；
#   7. 运行期还需要三个小替身：
#      - libgfortran.so.5：scipy 少数模块 DT_NEEDED 它，但只需要 16 个 _gfortran_* 符号；
#      - libgcc_s.so.1：用 OHOS 自带 libunwind + 自实现的 soft-float 转换函数（gcc-softfloat-shim.c）；
#      - libmvec.so.1：glibc 的向量数学库，用标量实现补齐（libmvec-stub.c）。
#
# 用法: bash tooling/python/build-scipy-ohos.sh [版本, 默认 1.14.1]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
VER="${1:-1.14.1}"
WORK="${WORK:-$HOME/ohos-py-scipy}"
NP="${NPWORK:-$HOME/ohos-py-np}"
TC="${TC:-/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native}"
CLANG="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang"
STRIP="$TC/llvm/bin/llvm-strip"
LIBS="$PROJ/entry/libs/arm64-v8a"
ROOTFS="$NP/alpine-a64"
PYINC="${PYINC:-/root/cpython-ohos/dest/usr/local/include/python3.12}"
PYLIB="${PYLIB:-/root/cpython-ohos/dest/usr/local/lib}"
GF=/usr/bin/aarch64-linux-gnu-gfortran
OPENBLAS="$WORK/openblas-prefix"

mkdir -p "$WORK" "$WORK/bin"

# ---------- 1) 交叉 Fortran ----------
command -v "$GF" >/dev/null || { echo "缺少交叉 gfortran: apt-get install gfortran-aarch64-linux-gnu" >&2; exit 2; }

# ---------- 2) OpenBLAS(libopenblas.so) ----------
if [ ! -f "$OPENBLAS/lib/libopenblas.so" ]; then
  cd "$WORK"
  [ -d OpenBLAS-0.3.28 ] || { curl -sL -o ob.tar.gz \
      "https://codeload.github.com/OpenMathLib/OpenBLAS/tar.gz/refs/tags/v0.3.28"; tar xzf ob.tar.gz; }
  cd OpenBLAS-0.3.28
  make -j"$(nproc)" TARGET=ARMV8 BINARY=64 \
    CC="$CLANG --sysroot=$TC/sysroot" FC="$GF" HOSTCC=gcc \
    AR="$TC/llvm/bin/llvm-ar" RANLIB="$TC/llvm/bin/llvm-ranlib" \
    CFLAGS="-O2 -fPIC" FFLAGS="-O2 -fPIC" \
    NOFORTRAN=0 NO_LAPACK=0 NO_SHARED=1 BUILD_WITHOUT_LAPACKE=1 || true
  "$CLANG" --sysroot="$TC/sysroot" -c -O2 -fPIC -o "$WORK/gfortran-shim.o" "$HERE/gfortran-shim.c"
  "$CLANG" --sysroot="$TC/sysroot" -shared -fuse-ld=lld -o libopenblas.so \
    -Wl,--whole-archive libopenblas_armv8p-r0.3.28.a -Wl,--no-whole-archive \
    "$WORK/gfortran-shim.o" -lm -Wl,-soname,libopenblas.so
  mkdir -p "$OPENBLAS/lib/pkgconfig" "$OPENBLAS/include"
  cp -f libopenblas.so "$OPENBLAS/lib/"
  cp -f cblas.h "$OPENBLAS/include/" 2>/dev/null || true
  cat > "$OPENBLAS/lib/pkgconfig/openblas.pc" <<EOF
prefix=$OPENBLAS
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: openblas
Description: OpenBLAS (cross-built for OpenHarmony)
Version: 0.3.28
Libs: -L\${libdir} -lopenblas
Cflags: -I\${includedir}
EOF
  cp -f "$OPENBLAS/lib/pkgconfig/openblas.pc" "$OPENBLAS/lib/pkgconfig/blas.pc"
  sed 's/Name: openblas/Name: lapack/' "$OPENBLAS/lib/pkgconfig/openblas.pc" \
    > "$OPENBLAS/lib/pkgconfig/lapack.pc"
fi

# ---------- 3) 运行期替身库 ----------
build_stub_libs() {
  "$CLANG" --sysroot="$TC/sysroot" -c -O2 -fPIC -o "$WORK/gfortran-rt-stub.o" "$HERE/gfortran-rt-stub.c"
  "$CLANG" --sysroot="$TC/sysroot" -shared -fuse-ld=lld -o "$WORK/libgfortran.so.5" \
    -Wl,--whole-archive "$WORK/gfortran-rt-stub.o" -Wl,--no-whole-archive \
    -Wl,-soname,libgfortran.so.5 -lm

  "$CLANG" --sysroot="$TC/sysroot" -c -O2 -fPIC -o "$WORK/gcc-softfloat-shim.o" "$HERE/gcc-softfloat-shim.c"
  "$CLANG" --sysroot="$TC/sysroot" -shared -fuse-ld=lld -o "$WORK/libgcc_s.so.1" \
    -Wl,--whole-archive "$TC/llvm/lib/aarch64-linux-ohos/libunwind.a" -Wl,--no-whole-archive \
    "$WORK/gcc-softfloat-shim.o" -Wl,-soname,libgcc_s.so.1

  "$CLANG" --sysroot="$TC/sysroot" -shared -fuse-ld=lld -O2 -fPIC -o "$WORK/libmvec.so.1" \
    "$HERE/libmvec-stub.c" -lm -Wl,-soname,libmvec.so.1
}
build_stub_libs

# ---------- 4) 工具包装器 ----------
cat > "$WORK/bin/ohos-fc" <<'EOS'
#!/bin/bash
# 编译走 gfortran, 链接走 OHOS clang(避免 DT_NEEDED glibc 版 libgfortran)
TC=/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native
GF=/usr/bin/aarch64-linux-gnu-gfortran
CLANG="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang"
compile_only=0; srcs=(); others=()
for a in "$@"; do
  case "$a" in
    -c|-S|-E|-fsyntax-only) compile_only=1; others+=("$a") ;;
    -fallow-argument-mismatch|-fno-second-underscore|-frecursive|-fimplicit-none) ;;
    *.f|*.f90|*.f95|*.f03|*.f08|*.F|*.F90|*.for) srcs+=("$a") ;;
    *) others+=("$a") ;;
  esac
done
[ "$compile_only" = "1" ] || [ ${#srcs[@]} -eq 0 ] && exec "$GF" "$@"
tmp=$(mktemp -d); objs=()
for s in "${srcs[@]}"; do
  o="$tmp/$(basename "$s").o"
  "$GF" -c -fPIC -fallow-argument-mismatch "$s" -o "$o" || exit 1
  objs+=("$o")
done
exec "$CLANG" --sysroot="$TC/sysroot" -fuse-ld=lld -Wl,--allow-shlib-undefined \
  "${others[@]}" "${objs[@]}" RT_STUB -lm
EOS
sed -i "s|RT_STUB|$WORK/gfortran-rt-stub.o|" "$WORK/bin/ohos-fc"
chmod +x "$WORK/bin/ohos-fc"
for tool in f2py pythran; do
  case $tool in
    f2py) line='exec "'"$ROOTFS"'/run-python.sh" -P -m numpy.f2py "$@"' ;;
    pythran) line='exec "'"$ROOTFS"'/run-python.sh" -P -c "import sys; from pythran.run import run; sys.argv=[\"pythran\"]+sys.argv[1:]; run()" "$@"' ;;
  esac
  printf '#!/bin/sh\ncd /\n%s\n' "$line" > "$WORK/bin/$tool"
  chmod +x "$WORK/bin/$tool"
done

# ---------- 5) scipy ----------
cd "$WORK"
if [ ! -d "scipy-$VER" ]; then
  URL=$(curl -s "https://pypi.org/pypi/scipy/$VER/json" | \
    python3 -c "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
  curl -sL -o "scipy.tar.gz" "$URL"; tar xzf scipy.tar.gz
fi
cd "scipy-$VER"
cat > "$WORK/scipy-cross.txt" <<EOF
[binaries]
c = '$CLANG'
cpp = '$TC/llvm/bin/aarch64-unknown-linux-ohos-clang++'
ar = '$TC/llvm/bin/llvm-ar'
ranlib = '$TC/llvm/bin/llvm-ranlib'
strip = '$STRIP'
fortran = '$WORK/bin/ohos-fc'
fc = '$WORK/bin/ohos-fc'
pkgconfig = 'pkg-config'
python = '$ROOTFS/run-python.sh'

[built-in options]
c_args = ['--sysroot=$TC/sysroot', '-O2', '-fPIC', '-I$PYINC', '-I$OPENBLAS/include']
cpp_args = ['--sysroot=$TC/sysroot', '-O2', '-fPIC', '-I$PYINC', '-I$OPENBLAS/include']
fortran_args = ['-fPIC', '-fallow-argument-mismatch', '-fno-strict-aliasing']
c_link_args = ['--sysroot=$TC/sysroot', '-fuse-ld=lld', '-L$PYLIB', '-L$OPENBLAS/lib', '-Wl,--allow-shlib-undefined']
cpp_link_args = ['--sysroot=$TC/sysroot', '-fuse-ld=lld', '-L$PYLIB', '-L$OPENBLAS/lib', '-Wl,--allow-shlib-undefined']
fortran_link_args = ['-L$PYLIB', '-L$OPENBLAS/lib', '-lopenblas', '-lm', '-Wl,--allow-shlib-undefined']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

rm -rf builddir
PATH="$WORK/bin:$PATH" PKG_CONFIG_LIBDIR="$OPENBLAS/lib/pkgconfig:$ROOTFS/py/site/pybind11/share/pkgconfig" \
PKG_CONFIG_ALLOW_CROSS=1 meson setup builddir --cross-file "$WORK/scipy-cross.txt" \
  --prefix="$WORK/scipy-prefix" -Dbuildtype=release -Doptimization=2 -Dfortran_std=none \
  -Dblas=openblas -Dlapack=openblas
# numpy 的 pxd 必须在 build 根, 否则 cython 的 cimport numpy 失败
mkdir -p builddir/numpy
( cd "$ROOTFS/libs/numpy" && find . -name '*.pxd' | while read -r f; do
    mkdir -p "$WORK/scipy-$VER/builddir/numpy/$(dirname "$f")"
    cp -f "$ROOTFS/libs/numpy/$f" "$WORK/scipy-$VER/builddir/numpy/$f"; done )
PATH="$WORK/bin:$PATH" ninja -C builddir -j"$(nproc)"
rm -rf "$WORK/scipy-dest"
PATH="$WORK/bin:$PATH" DESTDIR="$WORK/scipy-dest" meson install -C builddir

# ---------- 6) 打包 ----------
SP=$(find "$WORK/scipy-dest" -type d -name site-packages | head -1)
rm -rf "$LIBS/scipy" && mkdir -p "$LIBS/scipy"
( cd "$SP/scipy" && find . -name '*.so' | while read -r f; do
    mkdir -p "$LIBS/scipy/$(dirname "$f")"; cp -f "$SP/scipy/$f" "$LIBS/scipy/$f"; done )
find "$LIBS/scipy" -name '*.so' -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true
cp -f "$OPENBLAS/lib/libopenblas.so" "$LIBS/"
cp -f "$WORK/libgfortran.so.5" "$WORK/libgcc_s.so.1" "$WORK/libmvec.so.1" "$LIBS/"
for f in "$LIBS/libopenblas.so" "$LIBS/libgfortran.so.5" "$LIBS/libgcc_s.so.1" "$LIBS/libmvec.so.1"; do
  "$STRIP" --strip-unneeded "$f" 2>/dev/null || true
done

echo "== 产物"
du -sm "$LIBS/scipy" | awk '{print "scipy .so:", $1, "MB"}'
ls -l "$LIBS"/libopenblas.so "$LIBS"/libgfortran.so.5 "$LIBS"/libgcc_s.so.1 "$LIBS"/libmvec.so.1 | awk '{print $5, $9}'
echo "== scipy 的 .py 需要合并进 rawfile/python/extras.zip"
