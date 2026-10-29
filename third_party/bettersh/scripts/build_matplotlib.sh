#!/bin/bash
# build_matplotlib.sh — 交叉编译 matplotlib 本体(纯 Python 为主 + 6 个 C/C++ 扩展)
#
# 产物:
#   feature/bsh_main/libs/<abi>/matplotlib__{ft2font,_c_internal_utils,_image,_path}.so
#   feature/bsh_main/libs/<abi>/matplotlib__backends___backend_agg.so   (_qhull 跳过,见下)
#   rawfile/tools/matplotlib.tar   site-packages/matplotlib/(纯 Python + mpl-data 字体)
#
# 做法同 build_pillow.sh / build_contourpy.sh:直接 clang++ 编,特性宏自己给。
#   ft2font 需要 freetype(feature/bsh_main/libs 里已有 libfreetype.so);_backend_agg 需要
#   matplotlib 自带的 agg(extern/agg24-svn/include)。跳过 _tkagg(无 tk)。
#   mpl-data 里只留字体 + matplotlibrc + stylelib:images/(测试图) 9.8M 里占大头。
#
# numpy C-API 的符号约定(这里是最容易踩的一处):
#   每个扩展必须定义**自己的一份** PyArray_API —— 靠唯一符号
#   -DPY_ARRAY_UNIQUE_SYMBOL=MPL_<扩展名>_ARRAY_API;定义它的 TU 不能带
#   NO_IMPORT_ARRAY、其余 TU 必须带。py_converters.cpp 被多个扩展共用,所以
#   **每个扩展要有独立的对象目录**,py_converters.o 不能跨扩展复用。
#   _image 例外:它走 pybind11,pybind11 会把 numpy 头吞进 NO_IMPORT_ARRAY 里,
#   连 wrapper 的 import_array() 也被宏挡掉 → 由 gen_api_tu() 现生成定义 TU。
#   具体实现见下方 gen_api_tu() / link()。
# 前置:scripts/build_python.sh 已跑;feature/bsh_main/libs 有 libfreetype.so(build_qt.sh 带来)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# 版本:3.9.4 而不是最新 —— 3.10+ 的 src/ft2font.h 变成**无条件** include <raqm.h>
# (文本整形库,ohos-extra 里没有 raqm/harfbuzz/fribidi,补编代价很大);3.9.4 不依赖 raqm。
# 想要更新版就得先把 fribidi + harfbuzz + raqm 编出来。
PKG="matplotlib"
VER="${MPL_VER:-3.9.4}"
SRC_ROOT="${PYSRC_DIR:-$ROOT/thirdparty/pysrc}"
SRC="$SRC_ROOT/$PKG-$VER"
TAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/matplotlib.tar"
PY_SRC="${PY_SRC:-$BUILD_DIR/python/src/Python-3.12.14}"
PY_BUILD="${PY_BUILD:-$BUILD_DIR/python/cpython-build}"
PY_SERIES="${PY_SERIES:-3.12}"
B="$BUILD_DIR/matplotlib"
EXTRA="$ROOT/thirdparty/ohos-extra/additional-packages"
CC_TARGET="$CLANGXX --target=$TARGET --sysroot=$SYSROOT"

mkdir -p "$SRC_ROOT" "$B" "$HAP_LIBS_DIR" "$(dirname "$TAR")"

# ── 0. 源码 ──────────────────────────────────────────────
if [ ! -d "$SRC" ]; then
    log "下载 matplotlib $VER sdist"
    tgz="$SRC_ROOT/$PKG-$VER.tar.gz"
    [ -s "$tgz" ] || curl -sL --retry 3 --max-time 900 -o "$tgz" \
        "$(curl -sL --max-time 60 "https://pypi.org/pypi/$PKG/$VER/json" \
            | python3 -c 'import json,sys;print([u["url"] for u in json.load(sys.stdin)["urls"] if u["packagetype"]=="sdist"][0])')" \
        || err "下载失败"
    tar xzf "$tgz" -C "$SRC_ROOT"
fi
[ -f "$SRC/src/ft2font_wrapper.cpp" ] || err "源码结构异常: $SRC/src"

# ── 1. 前置 ──────────────────────────────────────────────
[ -f "$PY_SRC/Include/Python.h" ] || err "缺目标 Python 头(先跑 scripts/build_python.sh)"
[ -f "$HAP_LIBS_DIR/libfreetype.so" ] || err "缺 $HAP_LIBS_DIR/libfreetype.so(先跑 scripts/build_qt.sh)"
[ -f "$EXTRA/include/ft2build.h" ] || err "缺 ohos-extra 的 ft2build.h"
# _image 扩展走 pybind11(与 contourpy 共用宿主机装的那份)
PYBIND_INC="$(python3 -c 'import pybind11;print(pybind11.get_include())' 2>/dev/null || true)"
[ -n "$PYBIND_INC" ] || err "缺 pybind11:
      python3.12 -m venv ~/.venvs/numpy && ~/.venvs/numpy/bin/pip install 'pybind11>=2.13.2'
      export PATH=~/.venvs/numpy/bin:\$PATH"

# matplotlib 的 C 扩展用 numpy 的 C API。必须用**构建后**的头:numpy/_core/include/
# numpy/{__multiarray_api.h,numpyconfig.h} 是 numpy 构建期生成的,源码树里没有。
NUMPY_INC="$(find "$BUILD_DIR/numpy-$NATIVE_ARCH/build-install" \
    -path '*numpy/_core/include/numpy/arrayobject.h' -print -quit 2>/dev/null)"
NUMPY_INC="${NUMPY_INC%/numpy/arrayobject.h}"
[ -n "$NUMPY_INC" ] && [ -f "$NUMPY_INC/numpy/arrayobject.h" ] \
    || err "缺 numpy 构建后的头(先跑 scripts/build_numpy.sh)"

INC="-I$PY_BUILD -I$PY_SRC/Include -I$SRC -I$SRC/src -I$PYBIND_INC \
-I$NUMPY_INC -I$SRC/extern -I$SRC/extern/agg24-svn/include \
-I$EXTRA/include -I$EXTRA/include/freetype2"
CFLAGS="-O2 -fPIC -std=c++17 -D__MUSL__=1 -DOHOS_NDK -w"

# numpy C-API 的符号约定(照抄 matplotlib 自己的 src/meson.build:173):
#   每个扩展一个唯一符号 -DPY_ARRAY_UNIQUE_SYMBOL=MPL_<扩展名点换下划线>_ARRAY_API;
#   该符号由"不带 NO_IMPORT_ARRAY 的那个 TU"定义 —— 也就是各扩展的 *_wrapper.cpp
#   (py_converters.cpp / ft2font.cpp / _backend_agg.cpp 都在源码里自己
#   `#define NO_IMPORT_ARRAY`,所以定义只能来自 wrapper)。
#   → 每个扩展必须有**独立**对象目录,py_converters.o 不能跨扩展共用。
log "=== 编译 matplotlib 扩展 ($NATIVE_ARCH) ==="
rm -rf "$B/obj"; mkdir -p "$B/obj"
comp() { # <扩展> <源文件> [额外 flag...]  —— 额外 flag 逐个作为 argv(可含空格)
    local mod="$1" f="$2"; shift 2
    local d="$B/obj/$mod"; mkdir -p "$d"
    local o="$d/$(basename "${f%.cpp}").o"
    [ -f "$o" ] && { echo "$o"; return 0; }
    $CC_TARGET $CFLAGS $INC "$@" -c "$SRC/src/$f" -o "$o" 2>>"$B/compile-$mod.log" \
        || { tail -20 "$B/compile-$mod.log" >&2; err "编译失败: $f ($mod)"; }
    echo "$o"
}
gen_api_tu() { # <扩展> 生成并编译"定义 PyArray_API + 初始化"的小 TU    local mod="$1"
    local d="$B/obj/$mod"; mkdir -p "$d"
    local src="$d/bsh_numpy_api.cpp"; local o="$d/bsh_numpy_api.o"
    [ -f "$o" ] && { echo "$o"; return 0; }
    cat > "$src" <<EOF
/* build 期生成:pybind11 版扩展(如 _image)把 numpy 头包在 NO_IMPORT_ARRAY 下,而且
   matplotlib 自己那行 import_array() 也被 pybind11 泄漏的宏挡掉,所以这里统一:
   1) 定义 PyArray_API(-D PY_ARRAY_UNIQUE_SYMBOL 由命令行给,本 TU 不带 NO_IMPORT_ARRAY);
   2) 提供 bsh_numpy_import_array() 给 wrapper 调用(wrapper 里 import_array() 被宏重定向到此);
   3) 构造函数里再兜一次,保证 dlopen(import)时 API 指针已填好。 */
#include "numpy/arrayobject.h"
extern "C" int bsh_numpy_import_array(void) { return _import_array() < 0 ? -1 : 0; }
__attribute__((constructor)) static void bsh_numpy_api_init(void) { (void)bsh_numpy_import_array(); }
EOF
    $CC_TARGET $CFLAGS $INC -DPY_ARRAY_UNIQUE_SYMBOL=MPL_${mod}_ARRAY_API \
        -c "$src" -o "$o" 2>>"$B/compile-$mod.log" \
        || { tail -20 "$B/compile-$mod.log" >&2; err "编译 numpy API TU 失败 ($mod)"; }
    echo "$o"
}
agg_objs() { # 编译 matplotlib 自带的 AGG(extern/agg24-svn/src/*.cpp),只编一次
    local d="$B/obj/agg"; mkdir -p "$d"
    local o
    for f in "$SRC"/extern/agg24-svn/src/*.cpp; do
        o="$d/$(basename "${f%.cpp}").o"
        [ -f "$o" ] && continue
        $CC_TARGET $CFLAGS $INC -c "$f" -o "$o" 2>>"$B/compile-agg.log" \
            || { tail -20 "$B/compile-agg.log" >&2; err "编译 AGG 失败: $f"; }
    done
    echo "$d"/*.o
}
link() { # [--api-tu] [--agg] <平铺名后缀> <库...> -- 源文件列表(`+` = 定义 PyArray_API 的 TU)
    local api_tu=0 agg=0
    [ "$1" = "--api-tu" ] && { api_tu=1; shift; }
    [ "$1" = "--agg" ] && { agg=1; shift; }
    local mod="$1"; shift
    local libs=(); while [ "$1" != "--" ]; do libs+=("$1"); shift; done; shift
    local api="-DPY_ARRAY_UNIQUE_SYMBOL=MPL_${mod}_ARRAY_API"
    # wrapper 里那行 import_array() 改调我们的函数(pybind11 泄漏 NO_IMPORT_ARRAY 后,
    # numpy 的 import_array 宏在该 TU 里已不存在)
    local redirect='-Dimport_array()=({extern int bsh_numpy_import_array(void);(void)bsh_numpy_import_array();})'
    local ftdef='-DFREETYPE_BUILD_TYPE="system"'
    local objs=() f extra=()
    [ "$api_tu" = 1 ] && objs+=("$(gen_api_tu "$mod")")
    # AGG 是头文件为主 + 少量 src/*.cpp(_path/_image/_backend_agg 都要:
    # 少了就是设备上 "error relocating matplotlib__path.so: agg::vcgen_contour…")
    [ "$agg" = 1 ] && objs+=($(agg_objs))
    for f in "$@"; do
        case "$f" in
            +*) f="${f#+}"; extra=("$api") ;;                      # 定义 PyArray_API
            *)  extra=("$api" -DNO_IMPORT_ARRAY) ;;                # 只声明
        esac
        if [ "$api_tu" = 1 ]; then
            case "$f" in *_wrapper.cpp|ft2font.cpp|_backend_agg.cpp) extra+=("$redirect" "$ftdef") ;; esac
        fi
        objs+=("$(comp "$mod" "$f" "${extra[@]}")")
    done
    local flat="$HAP_LIBS_DIR/${mod}.so"
    $CC_TARGET -shared -o "$flat" "${objs[@]}" \
        -L"$HAP_LIBS_DIR" -lpython -Wl,--unresolved-symbols=ignore-all "${libs[@]}" \
        || err "链接 $mod 失败"
    log "  → $(basename "$flat") ($(du -h "$flat" | cut -f1))"
}
link matplotlib___c_internal_utils   -- _c_internal_utils.cpp
# _image 走 pybind11(它自己吞了 numpy 头的导入权)→ 由生成的 TU 定义并初始化 API
# --agg:_path/_image/_backend_agg 都要 AGG 的 src/*.cpp,否则设备上 dlopen 报
#   "error relocating matplotlib__path.so: agg::vcgen_contour… symbol not found"
link --api-tu --agg matplotlib___image -- _image_wrapper.cpp py_converters.cpp py_converters_11.cpp
link --agg matplotlib___path          -- +_path_wrapper.cpp py_converters.cpp
# 注:_qhull 跳过 —— sdist 的 extern/ 里只有 agg24-svn,qhull 是构建期 submodule,
# 它只服务 matplotlib.tri 的三角剖分,pyplot 用不到。
link --api-tu --agg matplotlib__ft2font      -lfreetype -- ft2font_wrapper.cpp ft2font.cpp py_converters.cpp
link --api-tu --agg matplotlib__backends___backend_agg -- _backend_agg_wrapper.cpp _backend_agg.cpp py_converters.cpp py_converters_11.cpp

# 未定义符号校验:ignore-all 会掩盖"漏编源文件"(如 pillow 的 path.c、这里的 AGG),
# 这里把它在执行期之前揪出来。允许来源:libpython(Py*/_Py*)、随包或设备上有的
# libc/libm/libz/libjpeg/libfreetype。
syssym() { local l; for l in "$@"; do [ -f "$l" ] && "$CLANG_DIR/llvm-nm" -D --defined-only "$l" 2>/dev/null | awk '{print $3}'; done; }
# C++ 运行库:hvigor 打 native 库时会自动带上 libc++_shared.so;用**它真正打进 HAP 的
# 那一份**(feature/bsh_main/build 的中间产物)最可靠 —— SDK 里 find 到的可能是 32 位 arm 版。
CXXRT="$(find "$ROOT/feature/bsh_main/build" -path "*cmake/default/obj/$NATIVE_ARCH/libc++_shared.so" -print -quit 2>/dev/null)"
[ -n "$CXXRT" ] || CXXRT="$(find "$OHOS_SDK/native" -path "*$TARGET/libc++_shared.so" -print -quit 2>/dev/null)"
CXXUNW="$(find "$OHOS_SDK/native" -name 'libunwind.so' -print -quit 2>/dev/null)"
{ syssym "$HAP_LIBS_DIR/libpython.so" "$SYSROOT/usr/lib/$TARGET/libc.so" \
         "$SYSROOT/usr/lib/$TARGET/libm.so" "$SYSROOT/usr/lib/$TARGET/libz.so" \
         "$HAP_LIBS_DIR/libjpeg.so" "$HAP_LIBS_DIR/libfreetype.so" \
         "$CXXRT" "$CXXUNW"; } | sort -u > "$B/known-syms.txt"
bad=0
for so in "$HAP_LIBS_DIR"/matplotlib*.so; do
    for u in $("$CLANG_DIR/llvm-nm" -D "$so" | awk '$1=="U"{print $2}' | sed 's/@.*//' | sort -u); do
        grep -qx "$u" "$B/known-syms.txt" || { warn "$(basename "$so"): 未定义且不在已知库里 → $u"; bad=1; }
    done
done
[ "$bad" = 0 ] || err "有未定义符号(多半漏编了源文件或漏带库)"

# ── 3. 纯 Python + mpl-data → tar ────────────────────────
log "=== 打包 site-packages/matplotlib(纯 Python + mpl-data)→ $TAR ==="
RT="$B/rt"; SP="$RT/python/lib/python$PY_SERIES/site-packages"
rm -rf "$RT"; mkdir -p "$SP"
cp -a "$SRC/lib/$PKG" "$SP/" || err "复制 lib/$PKG 失败"
# _version.py 由 setuptools_scm 在构建期生成,sdist 里**没有** —— 缺了它
# matplotlib/__init__.py 里那行 `from matplotlib import _version` 会报
# "cannot import name '_version' from partially initialized module 'matplotlib'"
# (缺子模块伪装成循环导入)。按生成物的格式补上。
cat > "$SP/$PKG/_version.py" <<EOF
# 由 scripts/build_matplotlib.sh 生成(setuptools_scm 的产物,sdist 不含)
__version__ = version = '$VER'
__version_tuple__ = version_tuple = ($(printf '%s' "$VER" | tr '.' ', '))
__commit_id__ = commit_id = None
EOF
grep -q "$VER" "$SP/$PKG/_version.py" || err "生成 _version.py 失败"
# mpl-data:只留字体/配置/样式(images/ 是测试图,占大头);tests/ 里有几十 MB 基线图
rm -rf "$SP/$PKG/mpl-data/images" "$SP/$PKG/mpl-data/plot_directive" \
       "$SP/$PKG/mpl-data/sample_data" 2>/dev/null || true
find "$SP/$PKG" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true
find "$RT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
tar -C "$RT" -cf "$TAR" python

# ── 4. 校验 ──────────────────────────────────────────────
declare -A WANT=(
  [matplotlib___c_internal_utils]=_c_internal_utils
  [matplotlib___image]=_image
  [matplotlib___path]=_path
  [matplotlib__ft2font]=ft2font
  [matplotlib__backends___backend_agg]=_backend_agg
)
for flat in "${!WANT[@]}"; do
    so="$HAP_LIBS_DIR/$flat.so"; init="${WANT[$flat]}"
    [ -f "$so" ] || err "缺 $so"
    "$CLANG_DIR/llvm-readelf" -h "$so" > "$B/.arch" 2>/dev/null || true
    grep -q AArch64 "$B/.arch" || err "$so 非 AArch64"
    "$CLANG_DIR/llvm-nm" -D "$so" > "$B/.syms" 2>/dev/null || true
    grep -qE " (T|W) PyInit_${init}\$" "$B/.syms" || err "$so 未导出 PyInit_${init}"
    "$CLANG_DIR/llvm-readelf" -d "$so" > "$B/.dyn" 2>/dev/null || true
    grep -q "Shared library: \[libpython.so\]" "$B/.dyn" || err "$so 缺 NEEDED libpython.so"
done
rm -f "$B/.arch" "$B/.syms" "$B/.dyn"
tar -tf "$TAR" > "$B/list.txt"
nso="$(grep -c '\.so$' "$B/list.txt" || true)"
[ "$nso" = "0" ] || err "tar 里混进了 $nso 个 .so"
for p in matplotlib/__init__.py matplotlib/pyplot.py matplotlib/mpl-data/matplotlibrc; do
    grep -qx "python/lib/python$PY_SERIES/site-packages/$p" "$B/list.txt" || err "tar 里缺 $p"
done
# 默认字体必须在(mpl-data/fonts/ttf/DejaVuSans.ttf)
grep -q "mpl-data/fonts/ttf/DejaVuSans.ttf" "$B/list.txt" \
    || err "tar 里缺 mpl-data/fonts/ttf/DejaVuSans.ttf(默认字体)"
log "✅ 5 个扩展 + $TAR ($(du -h "$TAR" | cut -f1))"
log "接线:shell.cpp initResource 加一条"
log "  UnpackRes(\"tools/matplotlib.tar\", home, home + \"/python/lib/python$PY_SERIES/site-packages/matplotlib/__init__.py\")"
