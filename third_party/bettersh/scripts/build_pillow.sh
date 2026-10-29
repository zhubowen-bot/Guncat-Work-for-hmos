#!/bin/bash
# build_pillow.sh — 交叉编译 Pillow(matplotlib 的硬依赖;C 代码最多)
#
# 产物:
#   feature/bsh_main/libs/<abi>/PIL___{_imaging,_imagingft,_imagingmath,_imagingmorph}.so
#   feature/bsh_main/libs/<abi>/libjpeg.so            本脚本一并带上的外部依赖(设备系统里没有)
#   rawfile/tools/pillow.tar               纯 Python 部分(src/PIL/*.py)
#
# 做法与 build_contourpy.sh/build_kiwisolver.sh 一致:不跑 setup.py,直接 clang 编。
# 特性宏自己给(没编进去的编解码器 Pillow 会自动降级):
#   _imaging      : -DHAVE_LIBJPEG -DHAVE_LIBZ   (libImaging/*.c 69 个 + src/_imaging.c)
#   _imagingft    : -DHAVE_LIBFREETYPE          (freetype 已在 feature/bsh_main/libs)
#   _imagingmath / _imagingmorph : 无外部依赖
#   跳过 cms/webp/avif/tiff(缺库;Pillow 不依赖它们也能跑)
#
# 前置:
#   - scripts/build_python.sh 已跑;feature/bsh_main/libs 里有 libfreetype.so(build_qt.sh 带来的)
#   - ohos-extra 提供 jpeglib.h 与 libjpeg.so(thirdparty/ohos-extra)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PKG="PIL"
VER="${PILLOW_VER:-12.3.0}"
SRC_ROOT="${PYSRC_DIR:-$ROOT/thirdparty/pysrc}"
SRC="$SRC_ROOT/pillow-$VER"
TAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/pillow.tar"
PY_SRC="${PY_SRC:-$BUILD_DIR/python/src/Python-3.12.14}"
PY_BUILD="${PY_BUILD:-$BUILD_DIR/python/cpython-build}"
PY_SERIES="${PY_SERIES:-3.12}"
B="$BUILD_DIR/pillow"
EXTRA="$ROOT/thirdparty/ohos-extra/additional-packages"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT"

mkdir -p "$SRC_ROOT" "$B" "$HAP_LIBS_DIR" "$(dirname "$TAR")"

# ── 0. 源码 ──────────────────────────────────────────────
if [ ! -d "$SRC" ]; then
    log "下载 pillow $VER sdist"
    tgz="$SRC_ROOT/pillow-$VER.tar.gz"
    [ -s "$tgz" ] || curl -sL --retry 3 --max-time 900 -o "$tgz" \
        "$(curl -sL --max-time 60 "https://pypi.org/pypi/pillow/$VER/json" \
            | python3 -c 'import json,sys;print([u["url"] for u in json.load(sys.stdin)["urls"] if u["packagetype"]=="sdist"][0])')" \
        || err "下载失败"
    tar xzf "$tgz" -C "$SRC_ROOT"
fi
[ -f "$SRC/src/_imaging.c" ] || err "源码结构异常: $SRC/src/_imaging.c"

# ── 1. 外部依赖:jpeg 随包(freetype/zlib 系统或已随包)────────
[ -f "$EXTRA/include/jpeglib.h" ] && [ -f "$EXTRA/lib/libjpeg.so" ] \
    || err "缺 jpeglib.h / libjpeg.so(thirdparty/ohos-extra)"
cp -f "$EXTRA/lib/libjpeg.so" "$HAP_LIBS_DIR/libjpeg.so"
[ -f "$HAP_LIBS_DIR/libfreetype.so" ] \
    || err "缺 $HAP_LIBS_DIR/libfreetype.so(先跑 scripts/build_qt.sh,它会把 ohos-extra 那批带进来)"

# ── 2. 编译 ──────────────────────────────────────────────
INC="-I$PY_BUILD -I$PY_SRC/Include -I$SRC/src -I$SRC/src/libImaging \
-I$EXTRA/include -I$EXTRA/include/freetype2"
CFLAGS="-O2 -fPIC -D__MUSL__=1 -DOHOS_NDK -w"
log "=== 编译 libImaging($(ls "$SRC"/src/libImaging/*.c | wc -l) 个)+ 各扩展 ==="
rm -rf "$B/obj"; mkdir -p "$B/obj/libImaging"
compile_one() { # <src> <outdir>
    local f="$1" d="$2" o
    o="$d/$(basename "${f%.c}").o"
    $CC_TARGET $CFLAGS $INC ${3:-} -c "$f" -o "$o" 2>>"$B/compile.log" \
        || { tail -20 "$B/compile.log" >&2; err "编译失败: $f"; }
}
# libImaging 的编解码器源码用特性宏做 `#ifdef` 门(Pillow 的 setup.py 也是同一套宏):
#   JpegDecode.c / ZipDecode.c 没拿到宏就编成空实现 —— JPEG/ZIP 支持会**静默消失**,
#   所以这里必须和扩展本身用同一组宏。
# _imaging 的源码 = Pillow 的 src/*.c 核心(含 path.c/outline.c/encode.c/decode.c …)
#                            + src/libImaging/*.c
# 只编 _imaging.c 会漏掉 path.c 等 → PyPath_Flatten 之类符号 undefined,设备上
# dlopen 直接报 "error relocating PIL___imaging.so: PyPath_Flatten: symbol not found"。
# 排除项:_imaging* 各自成扩展;display.c 依赖 X11(Pillow 的 setup.py 无 X11 时也去掉)。
FEAT="-DHAVE_LIBJPEG -DHAVE_LIBZ"
: > "$B/compile.log"      # 追加式日志,先清空,免得 tail 出上一轮的旧错误
for f in "$SRC"/src/libImaging/*.c; do compile_one "$f" "$B/obj/libImaging" "$FEAT"; done
CORE_DIR="$B/obj/core"; mkdir -p "$CORE_DIR"
# _imaging 的源码白名单 = Pillow setup.py 的 srcs 去掉:各 *_<ext>.c(自己成扩展)、
# _avif.c/_webp.c(缺库)、display.c(依赖 X11)。漏一个就是今天这个坑:
# path.c 没编进去 → PyPath_Flatten undefined → 设备上 dlopen 报 relocating 错误。
for f in _imaging.c decode.c encode.c map.c outline.c path.c; do
    if [ "$f" = "_imaging.c" ]; then
        compile_one "$SRC/src/$f" "$CORE_DIR" "$FEAT -DPILLOW_VERSION=\"$VER\""
    else
        compile_one "$SRC/src/$f" "$CORE_DIR" "$FEAT"
    fi
done
compile_one "$SRC/src/_imagingft.c"    "$B/obj" "-DHAVE_LIBFREETYPE"
compile_one "$SRC/src/_imagingmath.c"  "$B/obj"
compile_one "$SRC/src/_imagingmorph.c" "$B/obj"

# ── 3. 链接各扩展(平铺名 = 模块路径点换双下划线)──────────
log "=== 链接扩展 ==="
link_ext() { # <模块名(含前导下划线)> [额外库...]
    local mod="$1"; shift
    local flat="$HAP_LIBS_DIR/${PKG}__${mod}.so"
    # 对象名与源文件一一对应(src/_imaging.c → obj/_imaging.o);libImaging 只进 _imaging
    local objs
    if [ "$mod" = "_imaging" ]; then
        # 核心 src/*.c(含 path.c)+ libImaging/*.c 一起进 _imaging
        objs=("$B"/obj/core/*.o "$B"/obj/libImaging/*.o)
        [ -f "$B/obj/core/_imaging.o" ] || err "缺 $B/obj/core/_imaging.o"
    else
        objs=("$B/obj/${mod}.o")
        [ -f "$B/obj/${mod}.o" ] || err "找不到 $B/obj/${mod}.o(编译阶段没产出?)"
    fi
    $CC_TARGET -shared -o "$flat" "${objs[@]}" \
        -L"$HAP_LIBS_DIR" -lpython -L"$EXTRA/lib" -Wl,--unresolved-symbols=ignore-all "$@" \
        || err "链接 $mod 失败"
    log "  → $(basename "$flat") ($(du -h "$flat" | cut -f1))"
}
link_ext _imaging      -ljpeg -lz -lfreetype
link_ext _imagingft    -lfreetype
link_ext _imagingmath
link_ext _imagingmorph

# ── 4. 纯 Python 部分 → tar ──────────────────────────────
log "=== 打包纯 Python 部分 → $TAR ==="
RT="$B/rt"; SP="$RT/python/lib/python$PY_SERIES/site-packages"
rm -rf "$RT"; mkdir -p "$SP"
cp -a "$SRC/src/$PKG" "$SP/" || err "复制 src/$PKG 失败"
find "$RT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
tar -C "$RT" -cf "$TAR" python

# ── 5. 校验 ──────────────────────────────────────────────
for m in _imaging _imagingft _imagingmath _imagingmorph; do
    so="$HAP_LIBS_DIR/${PKG}__${m}.so"
    "$CLANG_DIR/llvm-readelf" -h "$so" > "$B/.arch" 2>/dev/null || true
    grep -q AArch64 "$B/.arch" || err "$so 非 AArch64"
    "$CLANG_DIR/llvm-nm" -D "$so" > "$B/.syms" 2>/dev/null || true
    grep -qE " (T|W) PyInit_${m}\$" "$B/.syms" || err "$so 未导出 PyInit_${m}"
    "$CLANG_DIR/llvm-readelf" -d "$so" > "$B/.dyn" 2>/dev/null || true
    grep -q "Shared library: \[libpython.so\]" "$B/.dyn" || err "$so 缺 NEEDED libpython.so"
    # 外部库依赖必须在包内(设备系统里没有 libjpeg.so)
    for dep in $(sed -n 's/.*Shared library: \[\(lib[jf][^]]*\)\].*/\1/p' "$B/.dyn"); do
        [ -f "$HAP_LIBS_DIR/$dep" ] || [ -f "$SYSROOT/usr/lib/$TARGET/$dep" ] \
            || err "$so 依赖 $dep,包内没有(要一并随包)"
    done
done
# 特性宏是否真的生效:JPEG/ZIP 解码器的符号要在 _imaging 里(缺了说明又编成空实现)
"$CLANG_DIR/llvm-nm" -D "$HAP_LIBS_DIR/${PKG}___imaging.so" > "$B/.imgsyms" 2>/dev/null || true
for sym in JpegDecoder ZipDecoder; do
    grep -qi "$sym" "$B/.imgsyms" || err "_imaging 里没有 $sym —— $FEAT 没生效(JPEG/ZIP 会静默失效)"
done
rm -f "$B/.imgsyms"
rm -f "$B/.arch" "$B/.syms" "$B/.dyn"
tar -tf "$TAR" > "$B/list.txt"
nso="$(grep -c '\.so$' "$B/list.txt" || true)"
[ "$nso" = "0" ] || err "tar 里混进了 $nso 个 .so"
grep -qx "python/lib/python$PY_SERIES/site-packages/$PKG/Image.py" "$B/list.txt" \
    || err "tar 里缺 PIL/Image.py"

log "✅ 扩展 4 个 + $HAP_LIBS_DIR/libjpeg.so"
log "✅ $TAR ($(du -h "$TAR" | cut -f1)) —— site-packages/PIL/"
log "接线:shell.cpp initResource 加一条"
log "  UnpackRes(\"tools/pillow.tar\", home, home + \"/python/lib/python$PY_SERIES/site-packages/$PKG/Image.py\")"
