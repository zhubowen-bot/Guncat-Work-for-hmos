#!/bin/bash
# build_mksh.sh — build mksh against IEC's tty/exec shims.
#
# A shell run by the IEC services has to be linked with the same shims as the
# client that created its pty: isatty(0)/tcgetattr(0) are answered by
# tty/shim.c, which rebuilds its fd table from IEC_TTY_PTS in a constructor, and
# execve() is delegated by exec/shim.c. A shell linked with another runtime's
# shims sees the IEC pty as a plain socket and fails with
#
#   sh: can't find tty fd: Permission denied
#
# because /dev/tty is not openable in the sandbox and its isatty(0) is false.
#
# Usage:
#   scripts/build_mksh.sh
#   MKSH_SRC=/path/to/mksh scripts/build_mksh.sh
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libmksh.so
# The iec HAR packs libs/<abi> together with its CMake-built objects, so the
# library lands in the application's bundle libs as /data/.../libs/arm64/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"

SRC="${MKSH_SRC:-$ROOT/thirdparty/mksh}"
BUILD="$ROOT/build/mksh-iec"
OUTDIR="$ROOT/platform/ohos/har/libs/arm64-v8a"
OUT="$OUTDIR/libmksh.so"

[ -f "$SRC/main.c" ] || iec_clone_if_missing "$SRC" "${IEC_MKSH_REPO:-}"

if [ -n "${MKSH_CC:-}" ]; then
	CC="$MKSH_CC"
else
	[ -x "$CLANG" ] || iec_err "$CLANG not found (set MKSH_CC or CLANG)"
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"
fi
NM="${NM:-$CLANG_DIR/llvm-nm}"
READELF="${READELF:-$CLANG_DIR/llvm-readelf}"

# The same definitions BetterSH's shell build uses, taken from the OHOS mksh
# BUILD.gn. They describe the C library the shell is compiled against.
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

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty
       execve execv execvp execvpe execl execlp execle
       exit)
WRAP_FLAGS=()
for name in "${WRAPS[@]}"; do
	WRAP_FLAGS+=("-Wl,--wrap=$name")
done

mkdir -p "$BUILD" "$OUTDIR"
rm -f "$BUILD"/*.o 2>/dev/null || true

echo "==> mksh sources: $SRC" >&2
for f in "${SRCS[@]}"; do
	$CC -O2 -fPIC -fwrapv -Wall -Wno-deprecated-declarations -I "$SRC" \
		"${DEFS[@]}" -c "$SRC/$f" -o "$BUILD/${f%.c}.o" \
		|| { echo "compile failed: $f" >&2; exit 1; }
done

# IEC's client side. fs/shim.c is deliberately absent: it defines open() as
# well, and without IEC_SHIM_MERGED_OPEN the two definitions would collide. The
# tty shim already passes non-pty opens through to libc.
SHIM_CFLAGS=(-O2 -fPIC -DINT_WARP -D_GNU_SOURCE -I "$ROOT" -I "$ROOT/common")
$CC "${SHIM_CFLAGS[@]}" -c "$ROOT/tty/shim.c" -o "$BUILD/iec_tty_shim.o"
# The shell stats PATH entries itself (before exec), so it needs the fs shim's
# /bin -> FAKE_SYSROOT mapping as much as the exec shim. Both modules take over
# open(2); IEC_SHIM_MERGED_OPEN yields the entry to tty/shim.c, which calls
# iec_fs_do_open() for non-pty paths.
$CC "${SHIM_CFLAGS[@]}" -DIEC_SHIM_MERGED_OPEN -c "$ROOT/fs/shim.c" -o "$BUILD/iec_fs_shim.o"
$CC "${SHIM_CFLAGS[@]}" -c "$ROOT/exec/shim.c" -o "$BUILD/iec_exec_shim.o"
$CC "${SHIM_CFLAGS[@]}" -c "$ROOT/common/rpc.c" -o "$BUILD/iec_rpc.o"
$CC "${SHIM_CFLAGS[@]}" -c "$ROOT/common/sock_client.c" -o "$BUILD/iec_sock_client.o"
$CC -O2 -fPIC -c "$ROOT/compat/exit_wrap.c" -o "$BUILD/exit_wrap.o"

echo "==> link $OUT" >&2
$CC -shared -o "$OUT" "$BUILD"/*.o \
	-Wl,-soname,libmksh.so "${WRAP_FLAGS[@]}"

# A missing entry point or an unresolved wrap reference is only discovered when
# the launcher tries to start the shell, so both are checked here.
"$NM" -D "$OUT" | grep -E ' main$' >/dev/null || {
	echo "error: main is not exported" >&2
	exit 1
}
if "$NM" -D -u "$OUT" | grep -E '__wrap_|__real_' >/dev/null; then
	echo "error: unresolved __wrap_/__real_ symbols" >&2
	exit 1
fi

"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME' >&2
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))" >&2
