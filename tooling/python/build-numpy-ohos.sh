#!/usr/bin/env bash
# Guncat Work: 交叉编译 numpy(CPython 3.12 / aarch64-harmonyos) 并打包进应用 libs。
#
# 为什么要这么绕: numpy 2.x 用 meson 构建, meson.build 需要"能在构建机上运行的目标解释器"
# 做内省(取 sysconfig/头文件路径)。OHOS SDK 的 sysroot 不含运行时加载器, 所以直接跑交叉编出的
# aarch64 python 会失败。这里的做法是:
#   1. 用一份 Alpine minirootfs 当 `-L` 根, 让 qemu-user 能跑我们的 aarch64 python;
#   2. 把该 python 包成 wrapper, 写进 meson cross file 的 [binaries] python/cython;
#   3. 用 numpy 自带的 vendored meson(1.5.2) 构建 —— 系统 meson 缺 numpy 的 features 模块;
#   4. 产物直接进 entry/libs/arm64-v8a/numpy(设备上只有应用 lib 目录可 dlopen,
#      而启动器会把 libDir 并进 PYTHONPATH, 所以 `import numpy` 直接可用)。
#
# 前置:
#   * tooling/python/build-cpython-ohos.sh 已经产出 /root/cpython-ohos/dest 与 entry/libs 里的 libpython;
#   * 安装了 qemu-user(package qemu-user)、pkg-config、ninja、cython>=3。
#
# 用法: bash tooling/python/build-numpy-ohos.sh [numpy 版本, 默认 2.1.3]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
NP_VER="${1:-2.1.3}"
WORK="${WORK:-$HOME/ohos-py-np}"
TC="${TC:-/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native}"
CLANG="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang"
CLANGXX="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang++"
STRIP="$TC/llvm/bin/llvm-strip"
LIBS="$PROJ/entry/libs/arm64-v8a"
PYDEST="${PYDEST:-/root/cpython-ohos/dest/usr/local}"
ROOTFS="$WORK/alpine-a64"

echo "== numpy $NP_VER -> $LIBS/numpy"

# ---------- 1) Alpine 根 + 可运行的目标 python ----------
mkdir -p "$WORK"
if [ ! -x "$ROOTFS/lib/ld-musl-aarch64.so.1" ]; then
  rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
  curl -sL -o "$WORK/alpine-mini.tar.gz" \
    https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz
  tar xzf "$WORK/alpine-mini.tar.gz" -C "$ROOTFS"
fi
mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/lib" "$ROOTFS/usr/local/include" "$ROOTFS/py/site" "$ROOTFS/libs"
cp -f "$PYDEST/bin/python3.12" "$ROOTFS/usr/local/bin/" 2>/dev/null || true
cp -Lf "$PYDEST/lib/libpython3.12.so" "$ROOTFS/usr/local/lib/" 2>/dev/null || true
cp -r "$PYDEST/include/python3.12" "$ROOTFS/usr/local/include/" 2>/dev/null || true
cp -f "$PROJ/entry/src/main/resources/rawfile/python/python312.zip" "$ROOTFS/py/" 2>/dev/null || true
cp -f "$LIBS"/*.cpython-312-aarch64-linux-gnu.so "$ROOTFS/libs/" 2>/dev/null || true

# Alpine musl 没有 backtrace(OHOS libc 有), 给 qemu 验证用的存根
if [ ! -f "$ROOTFS/libs/libexecinfo_stub.so" ]; then
  cat > "$WORK/stub.c" <<'EOF'
#include <stddef.h>
int backtrace(void **b, int s) { (void) b; (void) s; return 0; }
char **backtrace_symbols(void *const *b, int s) { (void) b; (void) s; return NULL; }
void backtrace_symbols_fd(void *const *b, int s, int fd) { (void) b; (void) s; (void) fd; }
EOF
  "$CLANG" --sysroot="$TC/sysroot" -shared -fPIC -O1 -o "$ROOTFS/libs/libexecinfo_stub.so" "$WORK/stub.c"
fi

cat > "$ROOTFS/run-python.sh" <<EOF
#!/bin/sh
export PYTHONHOME=$ROOTFS/usr/local
export PYTHONPATH=$ROOTFS/py/python312.zip:$ROOTFS/py/site:$ROOTFS/libs
export LD_LIBRARY_PATH=$ROOTFS/usr/local/lib:$ROOTFS/libs
export LD_PRELOAD=$ROOTFS/libs/libexecinfo_stub.so
exec qemu-aarch64 -L $ROOTFS $ROOTFS/usr/local/bin/python3.12 "\$@"
EOF
cat > "$ROOTFS/run-cython.sh" <<EOF
#!/bin/sh
export PYTHONHOME=$ROOTFS/usr/local
export PYTHONPATH=$ROOTFS/py/python312.zip:$ROOTFS/py/site:$ROOTFS/libs
export LD_LIBRARY_PATH=$ROOTFS/usr/local/lib:$ROOTFS/libs
export LD_PRELOAD=$ROOTFS/libs/libexecinfo_stub.so
exec qemu-aarch64 -L $ROOTFS $ROOTFS/usr/local/bin/python3.12 -m cython "\$@"
EOF
chmod +x "$ROOTFS"/run-python.sh "$ROOTFS"/run-cython.sh

# 目标侧 cython(纯 Python 轮子)
if [ ! -d "$ROOTFS/py/site/Cython" ]; then
  python3 -m pip download cython --no-deps --only-binary=:all: --python-version 3.12 \
    --implementation py --abi none --platform any -d "$WORK/cython-whl" --quiet
  python3 - "$WORK/cython-whl" "$ROOTFS/py/site" <<'PY'
import sys, zipfile, glob
for w in glob.glob(sys.argv[1] + '/*.whl'):
    with zipfile.ZipFile(w) as z:
        z.extractall(sys.argv[2])
PY
fi

# ---------- 2) 目标 python 的 pkg-config ----------
mkdir -p "$WORK/pkgconfig"
cat > "$WORK/pkgconfig/python-3.12.pc" <<EOF
prefix=$PYDEST
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include/python3.12

Name: Python
Description: Python library
Version: 3.12
Libs: -L\${libdir} -lpython3.12
Cflags: -I\${includedir}
EOF
for n in python3 python3-embed python-3.12-embed; do cp -f "$WORK/pkgconfig/python-3.12.pc" "$WORK/pkgconfig/$n.pc"; done

# ---------- 3) cross file ----------
cat > "$WORK/cross-numpy.txt" <<EOF
[binaries]
c = '$CLANG'
cpp = '$CLANGXX'
ar = '$TC/llvm/bin/llvm-ar'
strip = '$STRIP'
pkgconfig = '/usr/bin/pkg-config'
python = '$ROOTFS/run-python.sh'
cython = '$ROOTFS/run-cython.sh'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
longdouble_format = 'IEEE_QUAD_LE'
EOF

# ---------- 4) 源码 + 构建 ----------
cd "$WORK"
if [ ! -d "numpy-$NP_VER" ]; then
  URL=$(curl -s "https://pypi.org/pypi/numpy/$NP_VER/json" | python3 -c \
    "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
  curl -sL -o "numpy-$NP_VER.tar.gz" "$URL"
  tar xzf "numpy-$NP_VER.tar.gz"
fi
cd "numpy-$NP_VER"
MV="vendored-meson/meson/meson.py"
rm -rf builddir
PKG_CONFIG_LIBDIR="$WORK/pkgconfig" PKG_CONFIG_PATH="$WORK/pkgconfig" PKG_CONFIG_ALLOW_CROSS=1 \
python3 "$MV" setup builddir --cross-file "$WORK/cross-numpy.txt" \
  --prefix="$WORK/prefix" -Dbuildtype=release \
  -Dblas=none -Dlapack=none -Dallow-noblas=true
python3 "$MV" compile -C builddir -j "$(nproc)"
rm -rf "$WORK/dest"
DESTDIR="$WORK/dest" python3 "$MV" install -C builddir || true

# ---------- 5) 打包 ----------
SP=$(find "$WORK/dest" -type d -name site-packages | head -1)
rm -rf "$LIBS/numpy"
cp -r "$SP/numpy" "$LIBS/numpy"
rm -rf "$LIBS/numpy/tests" "$LIBS/numpy"/*/tests "$LIBS/numpy/f2py" 2>/dev/null || true
find "$LIBS/numpy" -name '*.pyx' -delete 2>/dev/null || true
find "$LIBS/numpy" -name '*.pxd' -delete 2>/dev/null || true
find "$LIBS/numpy" -name '*.so' -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true
# numpy.fft 是 C++(pocketfft), 需要 libc++ 运行时
cp -f "$TC/llvm/lib/aarch64-linux-ohos/libc++_shared.so" "$LIBS/"
"$STRIP" --strip-unneeded "$LIBS/libc++_shared.so" 2>/dev/null || true

echo "== 产物"
du -sm "$LIBS/numpy" | awk '{print "numpy:", $1, "MB"}'
ls -l "$LIBS/libc++_shared.so" | awk '{print "libc++_shared.so:", $5}'
echo "== 自检(在 qemu 里 import)"
"$ROOTFS/run-python.sh" -c "
import numpy as np
a = np.arange(12).reshape(3, 4)
print('numpy', np.__version__, '| sum', int(a.sum()), '| fft', len(np.fft.fft(np.arange(8))))
"
