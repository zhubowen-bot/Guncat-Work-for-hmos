#!/bin/bash
# build_mksh.sh — 把 mksh(OHOS third_party,R59c)移植为 libmksh.so
#
# 编译定义与源清单取自 OHOS mksh 的 BUILD.gn("sh" 可执行目标),再按命令 so
# 模式聚合:16 个源 + exec_shim.o(exec 委托,--wrap exec*) + tty_shim.c
# (isatty/tcgetattr/ioctl → 宿主 bsh_tty_*),链接 -Bsymbolic-functions,
# 并把宿主 libentry.so 作为显式依赖(DT_NEEDED)解析 bsh_tty_*(同 libvim)。
# 产物:feature/bsh_main/libs/arm64-v8a/libmksh.so(导出 main;命令表 sh→libmksh.so)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/thirdparty/mksh"
TC_DIR="$ROOT/feature/bsh_main/src/main/cpp"
BUILD="$ROOT/build/mksh"
OUTDIR="$ROOT/feature/bsh_main/libs/arm64-v8a"
OUT="$OUTDIR/libmksh.so"
JOBS="${JOBS:-$(nproc)}"

MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
OHOS_SDK="${OHOS_SDK:-/apps/harmony/sdk/default/openharmony}"
OHOS_CLANG="$OHOS_SDK/native/llvm/bin/clang"
NM=""; READELF=""
CC=""
if [ -n "${MKSH_CC:-}" ]; then
    CC="$MKSH_CC"
elif [ -x "$OHOS_CLANG" ]; then
    CC="$OHOS_CLANG --target=aarch64-linux-ohos --sysroot=$OHOS_SDK/native/sysroot -fuse-ld=lld"
    NM="$OHOS_SDK/native/llvm/bin/llvm-nm"
    READELF="$OHOS_SDK/native/llvm/bin/llvm-readelf"
else
    CC="$MUSL_TC/bin/aarch64-linux-musl-gcc"
    NM="$MUSL_TC/bin/aarch64-linux-musl-nm"
    READELF="$MUSL_TC/bin/aarch64-linux-musl-readelf"
fi
[ -n "$CC" ] || { echo "编译器不可用(设 MKSH_CC 或用 OHOS SDK/musl-cross)"; exit 1; }
[ -f "$SRC/main.c" ] || { echo "缺源码:$SRC(先 git submodule update --init)"; exit 1; }

# tty 与 exec 委托都经 control socket 问 procmgr(bsh_client),命令 so 不链接宿主

DEFS=(
  -DMKSH_ASSUME_UTF8 -DMKSH_DONT_EMIT_IDSTRING -DMKSH_BUILDSH -D_GNU_SOURCE
  -DSETUID_CAN_FAIL_WITH_EAGAIN
  -DHAVE_STRING_POOLING=2
  -DHAVE_ATTRIBUTE_BOUNDED=0 -DHAVE_ATTRIBUTE_FORMAT=1 -DHAVE_ATTRIBUTE_NORETURN=1
  -DHAVE_ATTRIBUTE_PURE=1 -DHAVE_ATTRIBUTE_UNUSED=1 -DHAVE_ATTRIBUTE_USED=1
  -DHAVE_SYS_TIME_H=1 -DHAVE_TIME_H=1 -DHAVE_BOTH_TIME_H=1
  -DHAVE_SYS_BSDTYPES_H=0 -DHAVE_SYS_FILE_H=1 -DHAVE_SYS_MKDEV_H=0 -DHAVE_SYS_MMAN_H=1
  -DHAVE_SYS_PARAM_H=1 -DHAVE_SYS_RESOURCE_H=1 -DHAVE_SYS_SELECT_H=1 -DHAVE_SYS_SYSMACROS_H=1
  -DHAVE_BSTRING_H=0 -DHAVE_GRP_H=1 -DHAVE_IO_H=0 -DHAVE_LIBGEN_H=1 -DHAVE_LIBUTIL_H=0
  -DHAVE_PATHS_H=1 -DHAVE_STDINT_H=1 -DHAVE_STRINGS_H=1 -DHAVE_TERMIOS_H=1
  -DHAVE_ULIMIT_H=1 -DHAVE_VALUES_H=1
  -DHAVE_CAN_INTTYPES=1 -DHAVE_CAN_UCBINTS=1 -DHAVE_CAN_INT8TYPE=1 -DHAVE_CAN_UCBINT8=1
  -DHAVE_RLIM_T=1 -DHAVE_SIG_T=1 -DHAVE_SYS_ERRLIST=1
  -DHAVE_FLOCK=1 -DHAVE_LOCK_FCNTL=1 -DHAVE_GETRUSAGE=1 -DHAVE_GETSID=1 -DHAVE_GETTIMEOFDAY=1
  -DHAVE_KILLPG=1 -DHAVE_MEMMOVE=1 -DHAVE_MKNOD=0 -DHAVE_MMAP=1 -DHAVE_FTRUNCATE=1
  -DHAVE_NICE=1 -DHAVE_REVOKE=0 -DHAVE_SETLOCALE_CTYPE=1 -DHAVE_LANGINFO_CODESET=1
  -DHAVE_SELECT=1 -DHAVE_SETRESUGID=1 -DHAVE_SETGROUPS=1 -DHAVE_STRERROR=1 -DHAVE_STRSIGNAL=0
  -DHAVE_STRLCPY=0
  -DHAVE_FLOCK_DECL=1 -DHAVE_REVOKE_DECL=1 -DHAVE_SYS_ERRLIST_DECL=1 -DHAVE_SYS_SIGLIST_DECL=1
  -DHAVE_PERSISTENT_HISTORY=1
  -DMKSH_UNLIMITED -DMKSH_BUILD_R=593
)
SRCS=(edit.c eval.c exec.c expr.c funcs.c histrap.c jobs.c lalloc.c lex.c
      main.c misc.c shf.c strlcpy.c syn.c tree.c var.c)

mkdir -p "$BUILD"
rm -f "$BUILD"/*.o 2>/dev/null || true
echo "==> 编译 mksh 源 + 委托/shim(${CC%% *})"
# 顺序编译(约 16 个 TU,量小不并行)
for f in "${SRCS[@]}"; do
    $CC -O2 -fPIC -fwrapv -Wall -Wno-deprecated-declarations -I "$SRC" \
        "${DEFS[@]}" -c "$SRC/$f" -o "$BUILD/${f%.c}.o" \
        || { echo "编译失败:$f"; exit 1; }
done
$CC -O2 -fPIC -DBSH_SHIM_WRAP -I"$TC_DIR/shim" -I"$TC_DIR/procmgr" -c "$TC_DIR/shim/exec_shim.c" -o "$BUILD/exec_shim.o"
$CC -O2 -fPIC -I"$TC_DIR/procmgr" -c "$TC_DIR/procmgr/bsh_client.c" -o "$BUILD/bsh_client.o"
# shim 家族（见 feature/bsh_main/src/main/cpp/shim/README.md）：命令 so 侧一律走
# -DBSH_SHIM_WRAP + -Wl,--wrap=（链接期替换；真实现=链接器给的 __real_<名>），
# 而不是符号插入 —— 命令 so 排在全局搜索序末尾，RTLD_NEXT 拿不到真实现。
# tty_shim 与 fs_shim 都要接管 open，只能有一个定义 → -DBSH_SHIM_MERGED_OPEN 让两边
# 让位，由 open_shim.c 提供唯一入口。
source "$SCRIPT_DIR/shim-wrap-flags.sh"
SHIM_DIR="$SHIM_SRC_DIR"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_DIR" -I"$TC_DIR/procmgr" -c "$SHIM_DIR/tty_shim.c" -o "$BUILD/tty_shim.o"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_DIR" -I"$TC_DIR/tty" -c "$SHIM_DIR/fs_shim.c" -o "$BUILD/fs_shim.o"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_DIR" -c "$SHIM_DIR/open_shim.c" -o "$BUILD/open_shim.o"

echo "==> 聚合 $OUT"
mkdir -p "$OUTDIR"
$CC -shared -o "$OUT" "$BUILD"/*.o \
    -Wl,-soname,libmksh.so \
    $SHIM_WRAP_FLAGS

echo "==> 校验"
"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME'
"$NM" -D "$OUT" | grep -E ' main$' || { echo "warn: main 未导出"; exit 1; }
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"
