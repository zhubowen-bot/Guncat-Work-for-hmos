#!/bin/bash
# build_fastfetch.sh — 把 fastfetch 移植为 libfastfetch.so(命令表 dlopen 运行)
#
#   FastfetchOnHarmonyOSShell(基于 fastfetch 2.64,已处理 utmpx/OS 识别等)。
#   1) 打 CMake 门补丁:CMAKE_SYSTEM_NAME=OHOS 视作 Linux(否则项目直接 FATAL);
#   2) OHOS NDK 工具链 cmake 配置:全关可选依赖、IS_MUSL=ON、-fPIC;
#   3) 编 libfastfetch(OBJECT)与 fastfetch(main 所在可执行目标);
#   4) clang --target=aarch64-linux-ohos -shared 聚合全部 .o → libfastfetch.so
#      (导出 main,NEEDED 仅 libc);
#   5) 拷入 feature/bsh_main/libs/arm64-v8a(随 HAP 打包;命令表 fastfetch→libfastfetch.so)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/thirdparty/fastfetch"
BUILD="$ROOT/build/fastfetch"
OUTDIR="$ROOT/feature/bsh_main/libs/arm64-v8a"
OUT="$OUTDIR/libfastfetch.so"
JOBS="${JOBS:-$(nproc)}"

OHOS_SDK="${OHOS_SDK:-/apps/harmony/sdk/default/openharmony}"
CMAKE_TOOLCHAIN="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake"
NINJA="$OHOS_SDK/native/build-tools/cmake/bin/ninja"
CLANG="$OHOS_SDK/native/llvm/bin/clang"
SYSROOT="$OHOS_SDK/native/sysroot"
NM="$OHOS_SDK/native/llvm/bin/llvm-nm"
READELF="$OHOS_SDK/native/llvm/bin/llvm-readelf"
CMAKE_BIN="${CMAKE:-$(command -v cmake || echo "$OHOS_SDK/native/build-tools/cmake/bin/cmake")}"

[ -f "$SRC/CMakeLists.txt" ] || { echo "缺源码:$SRC(先 git submodule update --init)"; exit 1; }
[ -f "$CMAKE_TOOLCHAIN" ] || { echo "缺 OHOS 工具链文件:$CMAKE_TOOLCHAIN"; exit 1; }
command -v python3 >/dev/null || { echo "需 python3(打 CMake 门补丁)"; exit 1; }

# 1) CMake 平台门补丁:OHOS → 按 Linux 处理(幂等,已打则跳过)
if ! grep -q 'STREQUAL "OHOS"' "$SRC/CMakeLists.txt"; then
    python3 - "$SRC/CMakeLists.txt" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = 'elseif("${CMAKE_SYSTEM_NAME}" STREQUAL "Linux")'
new = ('elseif("${CMAKE_SYSTEM_NAME}" STREQUAL "OHOS")\n'
       '    set(LINUX TRUE CACHE BOOL "OHOS treated as Linux" FORCE)\n'
       'elseif("${CMAKE_SYSTEM_NAME}" STREQUAL "Linux")')
assert old in s, "CMakeLists 平台分支结构变化,需手工适配"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
print("gate patched")
PY
fi

# 2) 配置(全关可选依赖,musl,Release,-fPIC)
OPTS=(-DENABLE_VULKAN=OFF -DENABLE_WAYLAND=OFF -DENABLE_XCB_RANDR=OFF
      -DENABLE_XCB=OFF -DENABLE_XRANDR=OFF -DENABLE_X11=OFF -DENABLE_DRM=OFF
      -DENABLE_DRM_AMDGPU=OFF -DENABLE_GIO=OFF -DENABLE_DCONF=OFF
      -DENABLE_DBUS=OFF -DENABLE_XFCONF=OFF -DENABLE_SQLITE3=OFF -DENABLE_RPM=OFF
      -DENABLE_IMAGEMAGICK7=OFF -DENABLE_IMAGEMAGICK6=OFF -DENABLE_CHAFA=OFF
      -DENABLE_ZLIB=OFF -DENABLE_EGL=OFF -DENABLE_GLX=OFF -DENABLE_OSMESA=OFF
      -DENABLE_OPENCL=OFF -DENABLE_PULSE=OFF -DENABLE_DDCUTIL=OFF
      -DENABLE_DIRECTX_HEADERS=OFF -DENABLE_ELF=OFF -DENABLE_LIBZFS=OFF
      -DENABLE_PCIACCESS=OFF -DBUILD_TESTS=OFF -DINSTALL_LICENSE=OFF
      -DIS_MUSL=ON -DENABLE_ASAN=OFF)
echo "==> configure (OHOS toolchain, all optional off)"
mkdir -p "$BUILD"
"$CMAKE_BIN" -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN" \
    -DCMAKE_BUILD_TYPE=Release "${OPTS[@]}" \
    -DCMAKE_C_FLAGS="-fPIC -O2 -D_GNU_SOURCE" > "$BUILD/cfg.log" 2>&1 \
    || { echo "cmake 配置失败,见 $BUILD/cfg.log"; exit 1; }

echo "==> build libfastfetch + fastfetch"
"$NINJA" -C "$BUILD" -j"$JOBS" libfastfetch fastfetch > "$BUILD/bld.log" 2>&1 \
    || { echo "编译失败,见 $BUILD/bld.log"; exit 1; }

# 3) 聚合 shared library:libfastfetch.dir 全部 .o + fastfetch.c(main)
echo "==> link libfastfetch.so"
OBJS="$(find "$BUILD/CMakeFiles/libfastfetch.dir" -name '*.o')"
MAIN="$BUILD/CMakeFiles/fastfetch.dir/src/fastfetch.c.o"
[ -f "$MAIN" ] || { echo "缺 main 对象:$MAIN"; exit 1; }
mkdir -p "$OUTDIR"
$CLANG --target=aarch64-linux-ohos --sysroot="$SYSROOT" -shared -o "$OUT" \
    $OBJS "$MAIN" -pthread -lm -lc

# 4) 校验
echo "==> 校验 $OUT"
"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME'
"$NM" -D "$OUT" | grep -E ' main$' || { echo "warn: main 未导出"; exit 1; }
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"
