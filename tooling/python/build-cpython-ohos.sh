!/usr/bin/env bash
# Guncat Work: 交叉编译原生 CPython(3.12) 为 HarmonyOS aarch64 动态库 + 可打包的标准库。
#
# 产物:
#   entry/libs/arm64-v8a/libpython3.12.so         (运行期 dlopen)
#   entry/src/main/resources/rawfile/python/python312.zip   (纯 Python 标准库)
#   entry/src/main/resources/rawfile/python/lib-dynload/*.so (C 扩展模块)
#
# 为什么需要编译包装器: CPython 的 configure 会拿 `$CC --print-multiarch` 的结果
# (OHOS clang 返回 aarch64-linux-ohos) 跟按编译特性推导出的平台三元组
# (aarch64-linux-gnu) 比对, 不一致直接报 "internal configure error for the platform
# triplet"。包装器只把 `--print-multiarch` 的答案对齐成 gnu, 实际编译仍是 OHOS 目标。
#
# 用法:
#   TOOL_HOME=/opt/ohos-cmdline/command-line-tools \
#   BUILD_PYTHON=/opt/py312/bin/python3.12 \
#   bash tooling/python/build-cpython-ohos.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$HERE/../.." && pwd)}"
TOOL_HOME="${TOOL_HOME:-/opt/ohos-cmdline/command-line-tools}"
PY_VERSION="${PY_VERSION:-3.12.15}"
WORK="${WORK:-$HOME/cpython-ohos}"
BUILD_PYTHON="${BUILD_PYTHON:-/opt/py312/bin/python3.12}"

NATIVE="$TOOL_HOME/sdk/default/openharmony/native"
SYSROOT="$NATIVE/sysroot"
CLANG="$NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang"
CLANGXX="$NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang++"
LLVM_BIN="$NATIVE/llvm/bin"

[ -x "$CLANG" ] || { echo "ERROR: 找不到 OHOS clang: $CLANG" >&2; exit 1; }
[ -x "$BUILD_PYTHON" ] || { echo "ERROR: 需要同版本的宿主 python(build-python): $BUILD_PYTHON" >&2; exit 1; }

mkdir -p "$WORK/toolchain"
# ---- 编译器包装器(只为对齐 --print-multiarch) ----
for kind in cc cxx; do
  real="$CLANG"; [ "$kind" = "cxx" ] && real="$CLANGXX"
  cat > "$WORK/toolchain/ohos-$kind" <<EOF
#!/bin/sh
case "\$1" in
  --print-multiarch) echo aarch64-linux-gnu; exit 0 ;;
esac
exec "$real" "\$@"
EOF
  chmod +x "$WORK/toolchain/ohos-$kind"
done

cd "$WORK"
if [ ! -d "Python-$PY_VERSION" ]; then
  if [ ! -s "Python-$PY_VERSION.tgz" ]; then
    echo "== 下载 Python $PY_VERSION"
    curl -L --retry 3 -m 900 -o "Python-$PY_VERSION.tgz" \
      "https://www.python.org/ftp/python/$PY_VERSION/Python-$PY_VERSION.tgz"
  fi
  tar xzf "Python-$PY_VERSION.tgz"
fi

cd "Python-$PY_VERSION"
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true

export CC="$WORK/toolchain/ohos-cc"
export CXX="$WORK/toolchain/ohos-cxx"
export AR="$LLVM_BIN/llvm-ar"
export RANLIB="$LLVM_BIN/llvm-ranlib"
export STRIP="$LLVM_BIN/llvm-strip"
export CFLAGS="--sysroot=$SYSROOT -O2 -fPIC -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
export CXXFLAGS="--sysroot=$SYSROOT -O2 -fPIC"
export LDFLAGS="--sysroot=$SYSROOT -fuse-ld=lld"

echo "== configure (host=aarch64-linux-gnu, CC=OHOS clang)"
# 交叉编译时 configure 不能探测设备文件/运行时行为, 这些答案按 Linux 默认值给死
export ac_cv_file__dev_ptmx=no
export ac_cv_file__dev_ptc=no
export ac_cv_buggy_getaddrinfo=no
export ac_cv_little_endian_double=yes

# 关掉依赖外部库/需要 fork 的扩展: 沙箱里要么没有库, 要么用不上(numpy/pandas 要另编)。
# 必须在 configure 之前写 —— Modules/Setup 是 config.status 在 configure 阶段用
# Setup.stdlib + Setup.local 合成的; 之后写只在某些构建顺序下碰巧生效, 重编会把
# _locale 又拉进来(实机踩过: _localemodule 找 textdomain 直接构建失败)。
cat > Modules/Setup.local <<'EOF'
*disabled*
_locale
_ctypes
_curses
_curses_panel
readline
_tkinter
_sqlite3
_dbm
_gdbm
_ndbm
_bz2
_lzma
_uuid
nis
ossaudiodev
spwd
_crypt
_multiprocessing
EOF

# 不传 --with-openssl: sysroot 里没有 OpenSSL 头, configure 会自动跳过 _ssl(_hashlib 同理)
./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu \
  --enable-shared --without-ensurepip --disable-ipv6 --disable-test-modules \
  --with-build-python="$BUILD_PYTHON" --with-computed-gotos > "$WORK/configure.log" 2>&1

echo "== make -j$(nproc)  (第一遍: 正常构建)"
make -j"$(nproc)" > "$WORK/build.log" 2>&1

# ---- 第二遍: 让 C 扩展显式依赖 libpython ----
# 设备上扩展是通过 dlopen 从应用 lib 目录加载的; 若它自己只有 NEEDED libc.so,
# PyModuleDef_Init 之类只能去"全局符号作用域"找 —— 而鸿蒙上找不到(实机报
# `Error relocating ... math...so: PyModuleDef_Init: symbol not found`)。
# 给扩展加上 DT_NEEDED libpython 后, 加载器会先装 libpython 再直接绑定符号;
# 同时把 libpython 的 SONAME 规范成 libpython3.12.so, 包里只需要一个文件。
echo "== 重链 libpython(SONAME=libpython3.12.so) 与全部扩展"
# EXT_SUFFIX 必须取**目标构建**的值(cpython-312-aarch64-linux-gnu.so),
# 不能用宿主 python 的 sysconfig(x86_64), 否则 rm 不到任何模块、等于没重链。
EXT_SUFFIX="$(grep -m1 '^EXT_SUFFIX=' Makefile | cut -d= -f2 | tr -d ' \t')"
[ -n "$EXT_SUFFIX" ] || { echo "ERROR: Makefile 里没找到 EXT_SUFFIX" >&2; exit 1; }
# 重新链接 libpython, 让 SONAME 与文件名一致(libpython3.12.so), 扩展的 DT_NEEDED 才对得上。
# 不用 patchelf: 它在本项目上改出过损坏的 .dynstr(加载时报
# "Error loading shared library osix_spawn_…", 名字整体错位一个字节)。
rm -f libpython3.12.so libpython3.12.so.1.0
make libpython3.12.so INSTSONAME=libpython3.12.so LDLIBRARY=libpython3.12.so \
  BLDSHARED="\$(CC) -shared \$(PY_CORE_LDFLAGS) -Wl,-soname,libpython3.12.so" \
  >> "$WORK/build.log" 2>&1
rm -f Modules/*"$EXT_SUFFIX"
make -j"$(nproc)" sharedmods \
  BLDSHARED="\$(CC) -shared \$(PY_CORE_LDFLAGS) -L$PWD -Wl,--no-as-needed -lpython3.12" \
  >> "$WORK/build.log" 2>&1
echo "== make install (DESTDIR)"
rm -rf "$WORK/dest"
make install DESTDIR="$WORK/dest" > "$WORK/install.log" 2>&1

DEST="$WORK/dest"
LIBDIR="$(find "$DEST" -name 'libpython3.12.so*' -path '*/lib/*' | head -1)"
STDLIB="$(find "$DEST" -type d -name 'python3.12' -path '*/lib/*' | head -1)"
[ -n "$LIBDIR" ] && [ -n "$STDLIB" ] || { echo "ERROR: 没找到 libpython / 标准库目录" >&2; exit 1; }
LIBDIR="$(dirname "$LIBDIR")"

echo "== 打包"
LIBS="$PROJ/entry/libs/arm64-v8a"
PYRAW="$PROJ/entry/src/main/resources/rawfile/python"
mkdir -p "$LIBS" "$PYRAW"

# 1) libpython: 以 dlopen 用的名字落盘(SONAME 已经是 libpython3.12.so)
LIBFILE="$LIBDIR/libpython3.12.so"
[ -f "$LIBFILE" ] || LIBFILE="$LIBDIR/libpython3.12.so.1.0"
cp -f "$LIBFILE" "$LIBS/libpython3.12.so"
"$STRIP" --strip-unneeded "$LIBS/libpython3.12.so" 2>/dev/null || true

# 2) 标准库 zip(不含 lib-dynload / 测试 / 演示 / 打包工具)
#    用 -0 存储(不压缩): zipimport 解压要依赖 zlib 扩展模块, 而它在 lib-dynload 里,
#    启动早期若 zlib 加载失败整个解释器就起不来。存储模式让 zipimport 直接 mmap 读取,
#    既去掉了这个依赖, 也省掉每个模块的 inflate; HAP 自身是 zip, 会再压一次, 体积几乎不涨。
rm -f "$PYRAW/python312.zip"
( cd "$STDLIB" && zip -qr0 "$PYRAW/python312.zip" . \
    -x 'test/*' -x 'idlelib/*' -x 'turtledemo/*' -x 'tkinter/*' -x 'lib2to3/*' \
    -x 'ensurepip/*' -x 'lib-dynload/*' -x '__pycache__/*' -x '*.pyc' -x 'config-*/*' )

# 3) C 扩展模块: 必须放进 entry/libs/<abi>/ —— 只有应用 lib 目录下的 .so 才能在设备上被
#    dlopen(数据目录里的 ELF 会被 linker/沙箱拒绝)。它们同时是 CPython 的 import 目标,
#    运行期由 PythonService 把该目录并进 PYTHONPATH(见 guncat_py.cpp 的 dladdr 逻辑)。
rm -f "$LIBS"/*.cpython-312-*.so
cp -f "$STDLIB"/lib-dynload/*"$EXT_SUFFIX" "$LIBS/" 2>/dev/null || cp -f "$STDLIB"/lib-dynload/*.so "$LIBS/" 2>/dev/null || true
for f in "$LIBS"/*.cpython-312-*.so; do
  [ -f "$f" ] && "$STRIP" --strip-unneeded "$f" || true
done
# 旧布局(rawfile 里解压)留下的目录清掉, 避免两份
rm -rf "$PYRAW/lib-dynload"
rm -f "$PYRAW/dynload-list.json"

# 4) libz.so: zlib / binascii 两个扩展 NEEDED libz.so, 而系统里没有可用的实现,
#    所以自带一份(和 CPython 一起编, 版本固定)。
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
if [ ! -d "$WORK/zlib-$ZLIB_VERSION" ]; then
  [ -s "$WORK/zlib-$ZLIB_VERSION.tar.gz" ] || curl -L --retry 3 -m 600 \
    -o "$WORK/zlib-$ZLIB_VERSION.tar.gz" \
    "https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v$ZLIB_VERSION"
  tar xzf "$WORK/zlib-$ZLIB_VERSION.tar.gz" -C "$WORK"
fi
ZL="$WORK/zlib-$ZLIB_VERSION"
"$CC" --sysroot="$SYSROOT" -O2 -fPIC -shared -Wl,-soname,libz.so -o "$LIBS/libz.so" \
  "$ZL/adler32.c" "$ZL/compress.c" "$ZL/crc32.c" "$ZL/deflate.c" "$ZL/gzclose.c" \
  "$ZL/gzlib.c" "$ZL/gzread.c" "$ZL/gzwrite.c" "$ZL/inflate.c" "$ZL/infback.c" \
  "$ZL/inftrees.c" "$ZL/inffast.c" "$ZL/trees.c" "$ZL/uncompr.c" "$ZL/zutil.c" 2>/dev/null
"$STRIP" --strip-unneeded "$LIBS/libz.so" 2>/dev/null || true

echo "== 产物"

ls -lh "$LIBS/libpython3.12.so" \
       "$PROJ/entry/src/main/resources/rawfile/python/python312.zip" | awk '{print $5, $9}'
echo "扩展模块: $(ls "$LIBS"/*.cpython-312-*.so 2>/dev/null | wc -l) 个 (在 libs/arm64-v8a/)"
