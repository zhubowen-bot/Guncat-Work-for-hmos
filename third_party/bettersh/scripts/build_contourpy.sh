#!/bin/bash
# build_contourpy.sh — 交叉编译 contourpy(matplotlib 的硬依赖,C++/pybind11 扩展)
#
# 产物:
#   feature/bsh_main/libs/<abi>/contourpy___contourpy.so   扩展(contourpy._contourpy → 双下划线)
#   rawfile/tools/contourpy.tar                 纯 Python 部分(lib/contourpy/*.py)
#
# 与 build_kiwisolver.sh 同一套做法:不跑 meson/setuptools,直接 clang++ 编 ——
# 交叉时那些构建系统会按**宿主** python 的 sysconfig 取 include,顺序上还会压过
# 我们给的目标头(编译期就报 aarch64-linux-gnu/…pyconfig.h 找不到)。
#
# 前置:
#   - scripts/build_python.sh 已跑(目标 python 的 include/pyconfig)
#   - host python3(与目标同系列)里有 pybind11(纯头文件):
#       python3.12 -m venv ~/.venvs/numpy && ~/.venvs/numpy/bin/pip install 'pybind11>=2.13.2'
#       export PATH=~/.venvs/numpy/bin:$PATH
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PKG="contourpy"
VER="${CONTOURPY_VER:-1.3.3}"
MODSUF="_contourpy"                             # contourpy._contourpy
SRC_ROOT="${PYSRC_DIR:-$ROOT/thirdparty/pysrc}"
SRC="$SRC_ROOT/$PKG-$VER"
TAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/contourpy.tar"
# 平铺名 = 模块路径的点换双下划线:contourpy._contourpy → contourpy___contourpy
# (2 个分隔下划线 + 模块名自带的 1 个;多/少一个都由 sitecustomize.py 的 finder 决定成败)
FLAT="$HAP_LIBS_DIR/${PKG}__${MODSUF}.so"
PY_SRC="${PY_SRC:-$BUILD_DIR/python/src/Python-3.12.14}"
PY_BUILD="${PY_BUILD:-$BUILD_DIR/python/cpython-build}"
PY_SERIES="${PY_SERIES:-3.12}"
B="$BUILD_DIR/$PKG"
CC_TARGET="$CLANGXX --target=$TARGET --sysroot=$SYSROOT"

mkdir -p "$SRC_ROOT" "$B" "$HAP_LIBS_DIR" "$(dirname "$TAR")"

# ── 0. 源码 ──────────────────────────────────────────────
if [ ! -d "$SRC" ]; then
    log "下载 $PKG $VER sdist"
    tgz="$SRC_ROOT/$PKG-$VER.tar.gz"
    [ -s "$tgz" ] || curl -sL --retry 3 --max-time 600 -o "$tgz" \
        "$(curl -sL --max-time 60 "https://pypi.org/pypi/$PKG/$VER/json" \
            | python3 -c 'import json,sys;print([u["url"] for u in json.load(sys.stdin)["urls"] if u["packagetype"]=="sdist"][0])')" \
        || err "下载失败"
    tar xzf "$tgz" -C "$SRC_ROOT"
fi
[ -n "$(ls "$SRC"/src/*.cpp 2>/dev/null)" ] || err "源码结构异常: $SRC/src"

# ── 1. 前置 ──────────────────────────────────────────────
[ -f "$PY_SRC/Include/Python.h" ] || err "缺目标 Python 头(先跑 scripts/build_python.sh)"
[ -f "$PY_BUILD/pyconfig.h" ] || err "缺 pyconfig.h(先跑 scripts/build_python.sh)"
PYBIND_INC="$(python3 -c 'import pybind11;print(pybind11.get_include())' 2>/dev/null || true)"
[ -n "$PYBIND_INC" ] || err "缺 pybind11:
      python3.12 -m venv ~/.venvs/numpy && ~/.venvs/numpy/bin/pip install 'pybind11>=2.13.2'
      export PATH=~/.venvs/numpy/bin:\$PATH"
log "pybind11 include: $PYBIND_INC"

# ── 2. 编译 + 链接 ───────────────────────────────────────
log "=== 编译 $PKG ($NATIVE_ARCH) ==="
INC="-I$PY_BUILD -I$PY_SRC/Include -I$PYBIND_INC -I$SRC/src"
CFLAGS="-O2 -fPIC -std=c++17 -D__MUSL__=1 -DOHOS_NDK -Wno-deprecated-declarations \
-fvisibility=hidden -Wno-unused-parameter"
rm -rf "$B/obj"; mkdir -p "$B/obj"
for f in "$SRC"/src/*.cpp; do
    o="$B/obj/$(basename "${f%.cpp}").o"
    $CC_TARGET $CFLAGS $INC -c "$f" -o "$o" 2>>"$B/compile.log" \
        || { tail -20 "$B/compile.log" >&2; err "编译失败: $f"; }
done
$CC_TARGET -shared -o "$FLAT" "$B"/obj/*.o \
    -L"$HAP_LIBS_DIR" -lpython -Wl,--unresolved-symbols=ignore-all \
    || err "链接失败"

# ── 3. 纯 Python 部分 → tar ──────────────────────────────
log "=== 打包纯 Python 部分 → $TAR ==="
RT="$B/rt"
SP="$RT/python/lib/python$PY_SERIES/site-packages"
rm -rf "$RT"; mkdir -p "$SP"
cp -a "$SRC/lib/$PKG" "$SP/" || err "复制 lib/$PKG 失败"
find "$RT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
tar -C "$RT" -cf "$TAR" python

# ── 4. 校验 ──────────────────────────────────────────────
"$CLANG_DIR/llvm-readelf" -h "$FLAT" > "$B/.arch" 2>/dev/null || true
grep -q AArch64 "$B/.arch" || err "$FLAT 非 AArch64"
"$CLANG_DIR/llvm-nm" -D "$FLAT" > "$B/.syms" 2>/dev/null || true
grep -qE " (T|W) PyInit_${MODSUF}\$" "$B/.syms" \
    || err "未导出 PyInit_${MODSUF}(import 会失败)"
"$CLANG_DIR/llvm-readelf" -d "$FLAT" > "$B/.dyn" 2>/dev/null || true
grep -q "Shared library: \[libpython.so\]" "$B/.dyn" \
    || err "缺 NEEDED libpython.so —— import 时报 undefined symbol"
rm -f "$B/.arch" "$B/.syms" "$B/.dyn"
tar -tf "$TAR" > "$B/list.txt"
nso="$(grep -c '\.so$' "$B/list.txt" || true)"
[ "$nso" = "0" ] || err "tar 里混进了 $nso 个 .so(会被解到 noexec 的 \$HOME)"

log "✅ $FLAT ($(du -h "$FLAT" | cut -f1))"
log "✅ $TAR ($(du -h "$TAR" | cut -f1)) —— site-packages/$PKG/(纯 Python)"
log "接线:shell.cpp initResource 加一条"
log "  UnpackRes(\"tools/$PKG.tar\", home, home + \"/python/lib/python$PY_SERIES/site-packages/$PKG/__init__.py\")"
