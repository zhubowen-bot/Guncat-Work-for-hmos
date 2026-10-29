#!/bin/bash
# build_kiwisolver.sh — 交叉编译 kiwisolver(matplotlib 的硬依赖,C++ 扩展)
#
# 产物:
#   feature/bsh_main/libs/<abi>/kiwisolver___cext.so   扩展(平铺;kiwisolver._cext → 双下划线命名)
#   rawfile/tools/kiwisolver.tar            纯 Python 部分(py/kiwisolver/*.py)
#
# 为什么要"自己编"而不跑 setup.py:它的构建是 setuptools + cppy,交叉时 include
# 路径由**宿主** python 的 sysconfig 决定(会先命中 /usr/include/python3.12,那
# 份 pyconfig.h 还会去 include 不存在的 aarch64-linux-gnu/…)。直接调 clang++ 能
# 把目标头放在最前面,和 build_pyqt.sh 编 sip 模块同一个思路。
#
# 前置:
#   - scripts/build_python.sh 已跑(目标 python 的 include/pyconfig)
#   - host python3(与目标同系列)里装了 cppy(纯 Python):
#       python3.12 -m venv ~/.venvs/numpy && ~/.venvs/numpy/bin/pip install cppy
#       export PATH=~/.venvs/numpy/bin:$PATH      # 脚本按 PATH 取 python3
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PKG="kiwisolver"
VER="${KIWI_VER:-1.5.1}"
SRC_ROOT="${PYSRC_DIR:-$ROOT/thirdparty/pysrc}"
SRC="$SRC_ROOT/$PKG-$VER"
TAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/kiwisolver.tar"
FLAT="$HAP_LIBS_DIR/kiwisolver___cext.so"     # 模块名 kiwisolver._cext → 点换双下划线
PY_SRC="${PY_SRC:-$BUILD_DIR/python/src/Python-3.12.14}"
PY_BUILD="${PY_BUILD:-$BUILD_DIR/python/cpython-build}"
PY_SERIES="${PY_SERIES:-3.12}"
B="$BUILD_DIR/$PKG"
CC_TARGET="$CLANGXX --target=$TARGET --sysroot=$SYSROOT"

mkdir -p "$SRC_ROOT" "$B" "$HAP_LIBS_DIR" "$(dirname "$TAR")"

# ── 0. 源码(sdist,缓存)──────────────────────────────────
if [ ! -d "$SRC" ]; then
    log "下载 $PKG $VER sdist"
    tgz="$SRC_ROOT/$PKG-$VER.tar.gz"
    [ -s "$tgz" ] || curl -sL --retry 3 --max-time 600 -o "$tgz" \
        "$(curl -sL --max-time 60 "https://pypi.org/pypi/$PKG/$VER/json" \
            | python3 -c 'import json,sys;print([u["url"] for u in json.load(sys.stdin)["urls"] if u["packagetype"]=="sdist"][0])')" \
        || err "下载失败"
    tar xzf "$tgz" -C "$SRC_ROOT"
fi
[ -f "$SRC/py/src/kiwisolver.cpp" ] || err "源码结构异常: $SRC/py/src"

# ── 1. 前置 ──────────────────────────────────────────────
[ -f "$PY_SRC/Include/Python.h" ] || err "缺目标 Python 头(先跑 scripts/build_python.sh)"
[ -f "$PY_BUILD/pyconfig.h" ] || err "缺 pyconfig.h(先跑 scripts/build_python.sh)"
CPPY_INC="$(python3 -c 'import cppy;print(cppy.get_include())' 2>/dev/null || true)"
[ -n "$CPPY_INC" ] || err "缺 cppy(纯 Python 构建依赖):
      python3.12 -m venv ~/.venvs/numpy && ~/.venvs/numpy/bin/pip install cppy
      export PATH=~/.venvs/numpy/bin:\$PATH"
log "cppy include: $CPPY_INC"

# ── 2. 编译 + 链接 ───────────────────────────────────────
log "=== 编译 $PKG ($NATIVE_ARCH) ==="
INC="-I$PY_BUILD -I$PY_SRC/Include -I$CPPY_INC -I$SRC/py/src -I$SRC"
CFLAGS="-O2 -fPIC -std=c++17 -D__MUSL__=1 -DOHOS_NDK -Wno-deprecated-declarations"
rm -rf "$B/obj"; mkdir -p "$B/obj"
for f in "$SRC"/py/src/*.cpp; do
    o="$B/obj/$(basename "${f%.cpp}").o"
    $CC_TARGET $CFLAGS $INC -c "$f" -o "$o" 2>>"$B/compile.log" \
        || { tail -20 "$B/compile.log" >&2; err "编译失败: $f"; }
done
# 扩展模块:显式 NEEDED libpython.so(RTLD_LOCAL 下必须,同 build_pyqt.sh)
$CC_TARGET -shared -o "$FLAT" "$B"/obj/*.o \
    -L"$HAP_LIBS_DIR" -lpython -Wl,--unresolved-symbols=ignore-all \
    || err "链接失败"

# ── 3. 纯 Python 部分 → tar ──────────────────────────────
log "=== 打包纯 Python 部分 → $TAR ==="
RT="$B/rt"
SP="$RT/python/lib/python$PY_SERIES/site-packages"
rm -rf "$RT"; mkdir -p "$SP"
cp -a "$SRC/py/$PKG" "$SP/" || err "复制 py/$PKG 失败"
find "$RT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
tar -C "$RT" -cf "$TAR" python

# ── 4. 校验 ──────────────────────────────────────────────
"$CLANG_DIR/llvm-readelf" -h "$FLAT" > "$B/.arch" 2>/dev/null || true
grep -q AArch64 "$B/.arch" || err "$FLAT 非 AArch64"
"$CLANG_DIR/llvm-nm" -D "$FLAT" > "$B/.syms" 2>/dev/null || true
grep -qE " (T|W) PyInit__cext\$" "$B/.syms" || err "未导出 PyInit__cext(import 会失败)"
"$CLANG_DIR/llvm-readelf" -d "$FLAT" > "$B/.dyn" 2>/dev/null || true
grep -q "Shared library: \[libpython.so\]" "$B/.dyn" \
    || err "缺 NEEDED libpython.so —— import 时报 undefined symbol"
rm -f "$B/.arch" "$B/.syms" "$B/.dyn"
# tar 清单先落文件:别用 `tar | grep -q`(pipefail 下 SIGPIPE 会误报)
tar -tf "$TAR" > "$B/list.txt"
nso="$(grep -c '\.so$' "$B/list.txt" || true)"
[ "$nso" = "0" ] || err "tar 里混进了 $nso 个 .so(会被解到 noexec 的 \$HOME)"
grep -qx "python/lib/python$PY_SERIES/site-packages/$PKG/_cext.pyi" "$B/list.txt" \
    || warn "tar 里没有 $PKG/_cext.pyi(只是少类型提示,不影响运行)"

log "✅ $FLAT ($(du -h "$FLAT" | cut -f1))"
log "✅ $TAR ($(du -h "$TAR" | cut -f1)) —— site-packages/$PKG/(纯 Python)"
log "接线:shell.cpp initResource 加一条"
log "  UnpackRes(\"tools/$PKG.tar\", home, home + \"/python/lib/python$PY_SERIES/site-packages/$PKG/__init__.py\")"
