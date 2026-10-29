#!/usr/bin/env bash
# build_host.sh — 在宿主（x86_64 Linux / WSL）上编译 mksh 回归用的两份二进制。
#
# 编译参数照抄 third_party/bettersh/iec/scripts/build_mksh.sh 的 DEFS（去掉
# OHOS clang/sysroot/wrap 相关部分），保证宿主二进制和随包 libmksh.so 走同一份
# 源码、同一套特性宏：
#   64 位算术版：带 -DMKSH_LEGACY_MODE（mksh_ari_t = long，LP64 下 64 位）；
#   32 位对照版：不带 -DMKSH_LEGACY_MODE（mksh_ari_t = int32_t）。
#
# 用法:
#   build_host.sh 64  [输出路径]   # 默认 /tmp/mksh64
#   build_host.sh 32  [输出路径]   # 默认 /tmp/mksh32
#   build_host.sh both             # 两份都编（默认路径）
#
# 退出码: 0 成功；77 没有 C 编译器（调用方可当作 SKIP）；其它为编译失败。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IEC_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SRC="${MKSH_SRC:-$IEC_ROOT/thirdparty/mksh}"

CC="${CC:-cc}"
if ! command -v "$CC" >/dev/null 2>&1; then
	echo "build_host.sh: 找不到 C 编译器 ($CC)，跳过 mksh 宿主编译" >&2
	exit 77
fi
[ -f "$SRC/main.c" ] || {
	echo "build_host.sh: mksh 源码不完整: $SRC/main.c 不存在" >&2
	exit 1
}

# 与 scripts/build_mksh.sh 的 DEFS 保持一致。宿主是 glibc/Linux，这些 HAVE_*
# 探测结果同样成立；MKSH_BUILD_R 固定，避免宿主与随包版本字符串不一致。
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

SRCS=(
	edit.c eval.c exec.c expr.c funcs.c histrap.c jobs.c lalloc.c lex.c
	main.c misc.c shf.c strlcpy.c syn.c tree.c var.c
)

build_one() {
	local variant="$1" out="$2"
	local -a extra=()
	case "$variant" in
	64) extra=(-DMKSH_LEGACY_MODE) ;;
	32) extra=() ;;
	*) echo "build_host.sh: 未知变体 $variant（应为 64 或 32）" >&2; return 2 ;;
	esac
	local -a files=()
	local f
	for f in "${SRCS[@]}"; do
		files+=("$SRC/$f")
	done
	echo "==> 编译 mksh${variant}: $out" >&2
	"$CC" -O2 -fwrapv -Wall -Wno-deprecated-declarations -I "$SRC" \
		"${DEFS[@]}" "${extra[@]}" "${files[@]}" -o "$out"
}

case "${1:-both}" in
64) build_one 64 "${2:-/tmp/mksh64}" ;;
32) build_one 32 "${2:-/tmp/mksh32}" ;;
both)
	build_one 64 "${2:-/tmp/mksh64}"
	build_one 32 "${3:-/tmp/mksh32}"
	;;
*)
	echo "用法: $0 {64|32|both} [输出路径]" >&2
	exit 2
	;;
esac
