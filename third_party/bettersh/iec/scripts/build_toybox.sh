#!/bin/bash
# build_toybox.sh — build toybox against IEC's fs/tty/exec shims.
#
# Toybox is a multicall binary: it is built as one shared object, with main()
# renamed to bsh_toybox_main, and dispatches on argv[0]. Under IEC the shell and
# its children are the ones linked with IEC's shims, so toybox has to use the
# same set:
#
#   * fs/shim.c   — .IEC_SYMLINK emulation for ln/cp/mv/tar/ls;
#   * tty/shim.c  — the fake pty, and the /dev/tty mapping;
#   * exec/shim.c — exec family delegated to the exec service.
#
# The merged open() (IEC_SHIM_MERGED_OPEN) is required because both the fs and
# tty modules take over open(2); tty/shim.c provides the single entry point and
# calls iec_fs_do_open() for paths that are not a pty.
#
# Usage:
#   scripts/build_toybox.sh
#   TOYBOX_SRC=/path/to/toybox scripts/build_toybox.sh
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libtoybox.so
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"

TOYBOX_SRC="${TOYBOX_SRC:-$ROOT/thirdparty/toybox}"
PATCH_DIR="${TOYBOX_PATCH_DIR:-$ROOT/scripts/toybox-ohos/patches}"
SRC="$ROOT/build/toybox-iec"
OUTDIR="$ROOT/platform/ohos/har/libs/arm64-v8a"
OUT="$OUTDIR/libtoybox.so"

[ -f "$TOYBOX_SRC/Makefile" ] || iec_clone_if_missing "$TOYBOX_SRC" "${IEC_TOYBOX_REPO:-}"

CC=""; EXTRA=""
if [ -n "${TOYBOX_CC:-}" ]; then
	CC="$TOYBOX_CC"
else
	[ -x "$CLANG" ] || iec_err "$CLANG not found (set TOYBOX_CC or CLANG)"
	CC="$CLANG"
	EXTRA="--target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"
fi
NM="${NM:-$CLANG_DIR/llvm-nm}"
READELF="${READELF:-$CLANG_DIR/llvm-readelf}"
HOSTCC="${HOSTCC:-cc}"

echo "==> copy sources -> $SRC" >&2
# Rebuild the working copy from scratch: a previous run can leave a .git entry
# of a different kind (file vs directory) and cp -a then refuses to overwrite it.
rm -rf "$SRC"
mkdir -p "$SRC"
cp -a "$TOYBOX_SRC/." "$SRC/"

if [ -d "$PATCH_DIR" ]; then
	echo "==> apply patches" >&2
	for p in "$PATCH_DIR"/*.patch; do
		[ -e "$p" ] || continue
		if patch -p1 -d "$SRC" --dry-run --silent < "$p" >/dev/null 2>&1; then
			echo "    $(basename "$p")" >&2
			patch -p1 -d "$SRC" < "$p" >/dev/null
		elif patch -p1 -R -d "$SRC" --dry-run --silent < "$p" >/dev/null 2>&1; then
			echo "    $(basename "$p"): already applied" >&2
		else
			echo "    can neither apply nor reverse: $p" >&2
			exit 1
		fi
	done
fi

cd "$SRC"
echo "==> configure toybox" >&2
[ -f .config ] || make defconfig HOSTCC="$HOSTCC" >/dev/null

# Applets the shell may reach: enable the ones defconfig leaves off (gzip is
# compressed output, and awk/tr/stty are used by scripts), and disable the ones
# that need utmp/shadow interfaces the OHOS sysroot does not declare.
for sym in MOUNT UMOUNT GZIP GUNZIP ZCAT WGET PING NETSTAT IFCONFIG \
           AWK TR STTY; do
	grep -q "^# CONFIG_${sym} is not set" .config &&
		sed -i "s/^# CONFIG_${sym} is not set/CONFIG_${sym}=y/" .config || true
done
for sym in LOGIN SULOGIN NOLOGIN W WHO USERS LAST LASTLOG UPTIME UTMPDUMP \
           SU AC PASSWD CHSH CHFN CRYPTPW; do
	grep -q "^CONFIG_${sym}=y" .config &&
		sed -i "s/^CONFIG_${sym}=y/# CONFIG_${sym} is not set/" .config || true
done

echo "==> build objects (-fPIC)" >&2
make generated/unstripped/toybox \
	HOSTCC="$HOSTCC" CC="$CC" \
	CFLAGS="-fPIC -O2 $EXTRA -Wno-implicit-function-declaration -Wno-int-conversion" \
	>/dev/null

OBJDIR=generated/unstripped/obj
[ -d "$OBJDIR" ] || OBJDIR=generated/obj

# Shims are compiled with the same CC/target as the objects.
SHIM_CFLAGS=(-fPIC -O2 -D_GNU_SOURCE -I "$ROOT" -I "$ROOT/common")
echo "==> build IEC shims" >&2
$CC $EXTRA "${SHIM_CFLAGS[@]}" -DINT_WARP -DIEC_SHIM_MERGED_OPEN \
	-c "$ROOT/tty/shim.c" -o generated/iec_tty_shim.o
$CC $EXTRA "${SHIM_CFLAGS[@]}" -DINT_WARP -DIEC_SHIM_MERGED_OPEN \
	-c "$ROOT/fs/shim.c" -o generated/iec_fs_shim.o
$CC $EXTRA "${SHIM_CFLAGS[@]}" -DINT_WARP \
	-c "$ROOT/exec/shim.c" -o generated/iec_exec_shim.o
$CC $EXTRA "${SHIM_CFLAGS[@]}" -c "$ROOT/common/rpc.c" \
	-o generated/iec_rpc.o
$CC $EXTRA "${SHIM_CFLAGS[@]}" -c "$ROOT/common/sock_client.c" \
	-o generated/iec_sock_client.o
$CC $EXTRA "${SHIM_CFLAGS[@]}" -c "$ROOT/compat/exit_wrap.c" \
	-o generated/exit_wrap.o

# main.c has to be compiled separately so the entry can be renamed; toybox
# dispatches applets from argv[0].
$CC $EXTRA -O2 -fPIC -I. -I generated -c main.c -o generated/main_custom.o \
	-Dmain=bsh_toybox_main -DTOYBOX_VERSION='"0.8.14"'

# Every symbol the shims replace, plus the ones open(2) needs. The merged fs/tty
# build has one open(), so it is listed once.
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

OBJS=""
for o in "$OBJDIR"/*.o; do
	case "$o" in */main.o) ;; *) OBJS="$OBJS $o" ;; esac
done

echo "==> link $OUT" >&2
mkdir -p "$OUTDIR"
# shellcheck disable=SC2086
$CC $EXTRA -shared -o "$OUT" $OBJS generated/main_custom.o \
	generated/iec_tty_shim.o generated/iec_fs_shim.o \
	generated/iec_exec_shim.o generated/iec_rpc.o \
	generated/iec_sock_client.o generated/exit_wrap.o \
	-Wl,-soname,libtoybox.so "${WRAP_FLAGS[@]}"

"$NM" -D "$OUT" | grep 'bsh_toybox_main$' >/dev/null || {
	echo "error: bsh_toybox_main is not exported" >&2
	exit 1
}
if "$NM" -D -u "$OUT" | grep -E '__wrap_|__real_' >/dev/null; then
	echo "error: unresolved __wrap_/__real_ symbols" >&2
	exit 1
fi

"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME' >&2
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))" >&2
