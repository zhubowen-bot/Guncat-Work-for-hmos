#!/bin/bash
# build_llvm_so.sh — 把 LLVM(clang/lld)so 化,供 shell 的 clang/ld.lld 命令
#   1) cmake 配置 LLVM(仅 AArch64 后端,clang;lld)→ Release、LLVM_USE_HOST_TOOLS=ON、
#      显式 LLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-musl;
#   2) ninja clang / lld;
#   3) 用 ninja -t commands 提取最终链接命令行;
#   4) 把可执行输出改成 .so:去掉 -o bin/X,追加
#      exec_shim.o command_map.o + --wrap=execvp/execv/execve/posix_spawn
#      + -static-libstdc++ -static-libgcc -shared -soname → libclangbsh.so / liblld.so;
#   5) strip、查 NEEDED(应仅 libc)与导出 main / __wrap_*。
# 产物:feature/bsh_main/libs/arm64-v8a/libclangbsh.so、liblld.so
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/shim-wrap-flags.sh"   # shim 家族的 --wrap 清单
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$SCRIPT_DIR/../thirdparty/third_party_llvm-project"
BUILD="$ROOT/build/llvm-cross"
NATIVE_BUILD="$ROOT/build/llvm-native"
OUTDIR="$ROOT/feature/bsh_main/libs/arm64-v8a"
SH="$(cd "$ROOT/feature/bsh_main/src/main/cpp/shell" && pwd)"

# 工具链(musl-cross 交叉编译 target aarch64;宿主工具用系统编译器生成)
TRIPLE="aarch64-linux-musl"
MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
CROSS_GCC="$MUSL_TC/bin/aarch64-linux-musl-gcc"
CROSS_GXX="$MUSL_TC/bin/aarch64-linux-musl-g++"
HOST_CXX="${HOST_CXX:-c++}"
[ -x "$CROSS_GCC" ] || { echo "需要 aarch64 musl 交叉工具链:$CROSS_GCC(设 MUSL_TOOLCHAIN)"; exit 1; }

echo "==> 0) native host tools (llvm-tblgen/llvm-config, 须在 x86 宿主运行)"
NATIVE_BUILD="$ROOT/build/llvm-native"
mkdir -p "$NATIVE_BUILD"
cmake -S "$SRC/llvm" -B "$NATIVE_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_TARGETS_TO_BUILD="X86" \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF >/dev/null
ninja -C "$NATIVE_BUILD" llvm-tblgen llvm-config clang-tblgen >/dev/null
NATIVE_BIN="$NATIVE_BUILD/bin"

echo "==> configure LLVM (cross target=$TRIPLE)"
mkdir -p "$BUILD"
cmake -S "$SRC/llvm" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CROSS_GCC" \
    -DCMAKE_CXX_COMPILER="$CROSS_GXX" \
    -DCMAKE_C_COMPILER_WORKS=1 -DCMAKE_CXX_COMPILER_WORKS=1 \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD="AArch64" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$TRIPLE" \
    -DLLVM_TABLEGEN="$NATIVE_BIN/llvm-tblgen" \
    -DCLANG_TABLEGEN="$NATIVE_BIN/clang-tblgen" \
    -DLLVM_CONFIG_PATH="$NATIVE_BIN/llvm-config" \
    -DLLVM_USE_HOST_TOOLS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF \
    >/dev/null

echo "==> build clang & lld"
ninja -C "$BUILD" clang lld

echo "==> bake clang entry wrapper (device -resource-dir)"
# clang 以 dlopen+main 运行在宿主 app 进程内,编译期默认资源目录(相对其"可执行
# 路径")在设备上不存在。这里生成包装 main:调用真正 driver main 前,若命令行未
# 显式给 -resource-dir,则补上设备端解包后的内置头文件目录(filesDir/clang-res,
# 与 shell initResource() 解包产物一致)。cc1 阶段由 driver 透传该目录,故 -cc1
# 及 exec 委托(exec_shim,argc 可能传 0)再入均覆盖。
cat > "$BUILD/bsh_clang_entry.c" <<'EOF'
#include <stdlib.h>
#include <string.h>

#define BSH_RESOURCE_DIR "/data/storage/el2/base/haps/entry/files/clang-res"
#define BSH_SYSROOT      "/data/storage/el2/base/haps/entry/files/musl"

extern int clang_driver_main(int argc, char **argv);

/* 参数是否已由用户给出(前缀 / 精确) */
static int arg_starts(int n, char **argv, const char *pfx) {
    for (int i = 1; i < n; i++)
        if (strncmp(argv[i], pfx, strlen(pfx)) == 0) return 1;
    return 0;
}
static int arg_has(int n, char **argv, const char *s) {
    for (int i = 1; i < n; i++)
        if (strcmp(argv[i], s) == 0) return 1;
    return 0;
}

int main(int argc, char **argv) {
    (void)argc; /* 调用方可能传 0(exec 委托);一律按 NULL 结尾扫描 argv */
    int n = 0;
    while (argv && argv[n]) n++;

    /* cc1/cc1as:driver 已把所需参数放在命令行,包装不得再插手 */
    if (arg_has(n, argv, "-cc1") || arg_has(n, argv, "-cc1as"))
        return clang_driver_main(n, argv);

    /* 默认参数:资源目录 + 设备端 musl sysroot + 静态链接 + lld
     * (用户显式给了同名参数则不重复插;与旧工程顶层注入行为一致,
     *  这里放在入口 → 顶层与 mksh 内嵌套调用都覆盖)
     * 用 -static-pie 而不是 -static:后者产出的 ET_EXEC 必须落在链接时定下的
     * 固定基址(约 0x200000),而宿主应用进程里那块地址可能已被占用,loader
     * 只能报 "reserve fixed image range ... File exists" 而放弃(ET_EXEC 有
     * 绝对量,搬不动)。static PIE 是 ET_DYN,loader 会映射到任意空闲地址,
     * 由 musl 的 rcrt1.o 自行完成重定位。 */
    static const char *defs[] = {
        "-resource-dir=" BSH_RESOURCE_DIR,
        "--sysroot=" BSH_SYSROOT,
        "-static-pie",
        "-fuse-ld=lld",
    };
    const char *pfx[] = { "-resource-dir", "--sysroot", "-static", "-fuse-ld" };
    const char *add[4];
    int m = 0;
    for (int k = 0; k < 4; k++) {
        if (k == 3 && arg_has(n, argv, "-shared")) continue;   /* -shared 时不加 -static-pie */
        if (arg_starts(n, argv, pfx[k])) continue;
        add[m++] = defs[k];
    }
    if (m == 0) return clang_driver_main(n, argv);

    char **na = (char **)malloc(sizeof(*na) * ((size_t)n + (size_t)m + 1));
    if (!na) return clang_driver_main(n, argv);
    na[0] = argv[0];
    int w = 1;
    for (int k = 0; k < m; k++) na[w++] = (char *)add[k];
    for (int i = 1; i < n; i++) na[w++] = argv[i];
    na[w] = NULL;
    int rc = clang_driver_main(w, na);
    free(na);
    return rc;
}
EOF
"$CROSS_GCC" -O2 -c "$BUILD/bsh_clang_entry.c" -o "$BUILD/bsh_clang_entry.o"

echo "==> aggregate as shared objects"
# exec 委托对象 + control socket 客户端(exec_shim 经它向 procmgr 下单)
"$CROSS_GCC" -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_SRC_DIR" -I"$SH/../procmgr" -c "$SHIM_SRC_DIR/exec_shim.c" -o "$BUILD/exec_shim.o"
"$CROSS_GCC" -O2 -fPIC -I"$SH/../procmgr" -c "$SH/../procmgr/bsh_client.c" -o "$BUILD/bsh_client.o"
# shim 家族：软链模拟（clang 建 .o/.so 会用到）+ 软 tty（彩色诊断靠 isatty）。
# 命令 so 都链同一套，wrap 清单只有一份。
"$CROSS_GCC" -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_SRC_DIR" -c "$SHIM_SRC_DIR/fs_shim.c" -o "$BUILD/fs_shim.o"
"$CROSS_GCC" -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_SRC_DIR" -I"$SH/../procmgr" -c "$SHIM_SRC_DIR/tty_shim.c" -o "$BUILD/tty_shim.o"
"$CROSS_GCC" -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_SRC_DIR" -c "$SHIM_SRC_DIR/open_shim.c" -o "$BUILD/open_shim.o"

# 把 clang driver 真正的 main 改名为 clang_driver_main(避免与包装 main 冲突;
# 该改名只影响最终 .so 内符号,不重新触发 ninja 重建)
CLANG_DRIVER_O="$BUILD/tools/clang/tools/driver/CMakeFiles/clang.dir/clang-driver.cpp.o"
if [ -f "$CLANG_DRIVER_O" ]; then
    "$MUSL_TC/bin/aarch64-linux-musl-objcopy" --redefine-sym main=clang_driver_main "$CLANG_DRIVER_O"
else
    echo "warn: 未找到 driver.cpp.o,跳过 main 改名(可能链接冲突)"
fi

extract_and_agg() {
    local bin="$1" out="$2" outbin="${3:-$1}" extra_objs="${4:-}"
    # 取 ninja 链接行(含交叉 g++ 的最后一行为真正链接;行形如 ': && g++ … && :')
    local line
    line="$(ninja -C "$BUILD" -t commands "bin/$bin" 2>/dev/null | grep -F 'aarch64-linux-musl-g++' | tail -1)"
    [ -n "$line" ] || { echo "warn: 未找到 $bin 链接行"; return 1; }
    line="${line#*: && }"; line="${line%% && *}"
    line="${line// -o bin\/$outbin/}"
    ( cd "$BUILD" && eval "$line '$BUILD/exec_shim.o' '$BUILD/bsh_client.o' '$BUILD/fs_shim.o' '$BUILD/tty_shim.o' '$BUILD/open_shim.o' $extra_objs \
        $SHIM_WRAP_FLAGS \
        -static-libstdc++ -static-libgcc -shared -Wl,-soname,"$(basename "$out")" \
        -o "$out"" )
    echo "==> $out"
    "$MUSL_TC/bin/aarch64-linux-musl-readelf" -d "$out" | grep -E 'NEEDED|SONAME' || true
    "$MUSL_TC/bin/aarch64-linux-musl-nm" -D "$out" | grep -E ' main$|clang_driver_main' || echo "warn: main 未导出"
}
mkdir -p "$OUTDIR"
extract_and_agg clang "$OUTDIR/libclangbsh.so" clang-15 "'$BUILD/bsh_clang_entry.o'"
extract_and_agg lld "$OUTDIR/liblld.so" lld
echo "==> done. 核对上方 NEEDED/导出;若 so 缺符号再校准。"

echo "==> pack clang resource (builtin headers) as rawfile/tools/clang-res.tar"
RESVER="$(basename "$(ls -d "$BUILD"/lib/clang/*/ 2>/dev/null | head -1)" 2>/dev/null || true)"
[ -n "$RESVER" ] || RESVER="15.0.0"
mkdir -p "$ROOT/feature/bsh_main/src/main/resources/rawfile/tools"
tar -C "$BUILD/lib/clang/$RESVER" -cf "$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/clang-res.tar" include
echo "==> clang-res.tar($RESVER): $(du -h "$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/clang-res.tar" | cut -f1)"
