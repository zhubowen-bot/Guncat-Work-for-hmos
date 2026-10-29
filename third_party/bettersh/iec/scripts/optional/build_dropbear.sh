#!/bin/bash
# build_dropbear.sh — build dropbear as an IEC shared object.
#
# dropbear's "multi" program carries the server, client, key tools and scp in
# one binary and dispatches on argv[0]. This script keeps that shape: one
# libdropbear.so, one entry (iec_dropbear_main), and launchers named ssh,
# dbclient, scp, ssh-keygen, dropbearkey, dropbearconvert and dropbear.
#
# The sandbox adaptations are the same ones the parent tree uses, but the IEC
# versions of the shims:
#   * scripts/dropbear-ohos.patch (parent tree) turns the server session pty
#     into a socketpair;
#   * misc/getpass.c provides getpass() and the fatal-signal report;
#   * misc/account.c provides the synthetic passwd entries and the identity
#     switch short-circuits.
#
# Build notes:
#   - out-of-tree so the submodule stays clean;
#   - configure gets an aarch64-unknown-linux-musl host because dropbear's
#     config.sub does not know "ohos";
#   - localoptions.h declares getpass before <unistd.h>, disables the
#     fexecve self-restart, and names the bare shell "sh";
#   - the bundled libtomcrypt/libtommath need -fPIC through LTM_CFLAGS.
#
# Usage:
#   scripts/optional/build_dropbear.sh
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libdropbear.so
# Entry:
#   iec_dropbear_main (arity 2)
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

SRC_SUBMODULE="${DROPBEAR_SRC:-$IEC_ROOT/thirdparty/dropbear}"
SRC="${DROPBEAR_SRC_COPY:-$IEC_ROOT/build/dropbear-src}"
BUILD="${DROPBEAR_BUILD:-$IEC_ROOT/build/dropbear}"
PATCH="${DROPBEAR_PATCH:-$IEC_ROOT/scripts/dropbear-ohos.patch}"
OUTDIR="${OUTDIR:-$IEC_ROOT/platform/ohos/har/libs/arm64-v8a}"
OUT="$OUTDIR/libdropbear.so"

NM="${NM:-$CLANG_DIR/llvm-nm}"
READELF="${READELF:-$CLANG_DIR/llvm-readelf}"
OBJCOPY="${OBJCOPY:-$CLANG_DIR/llvm-objcopy}"

case "$NATIVE_ARCH" in
	arm64-v8a) CONFIG_HOST="aarch64-unknown-linux-musl" ;;
	x86_64)    CONFIG_HOST="x86_64-unknown-linux-musl" ;;
	*) echo "unsupported NATIVE_ARCH=$NATIVE_ARCH" >&2; exit 1 ;;
esac

CC="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

log() { echo "=== $* ===" >&2; }
err() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$SRC_SUBMODULE/configure" ] || \
	iec_clone_if_missing "$SRC_SUBMODULE" "${IEC_DROPBEAR_REPO:-}"
[ -f "$SRC_SUBMODULE/configure" ] || err "missing dropbear sources: $SRC_SUBMODULE"
[ -f "$PATCH" ] || err "missing patch: $PATCH"
[ -x "$OBJCOPY" ] || err "missing objcopy: $OBJCOPY"

log "copy sources and apply the sandbox patch"
rm -rf "$SRC" "$BUILD"
mkdir -p "$SRC" "$BUILD"
(cd "$SRC_SUBMODULE" && tar -cf - --exclude=.git .) | (cd "$SRC" && tar -xf -)
patch -p1 -d "$SRC" -i "$PATCH" > "$BUILD/patch.log" 2>&1 \
	|| { cat "$BUILD/patch.log" >&2; err "patch failed (see $BUILD/patch.log)"; }

cat > "$BUILD/localoptions.h" <<'EOF'
/* IEC sandbox options */

/* argv[0] is not an executable here, so dropbear's fexecve self-restart fails. */
#define DROPBEAR_REEXEC 0

/* scp starts the client by a bare name; the IEC launcher is named ssh. */
#define DROPBEAR_PATH_SSH_PROGRAM "ssh"

/* There is no sftp-server, and the default path does not exist. */
#define DROPBEAR_SFTPSERVER 0

/* dropbear validates pw_shell against getusershell(); /etc/shells is absent,
 * so it falls back to this list. The account shim uses the same bare name. */
#define COMPAT_USER_SHELLS "sh"

/* The sandbox libc has no getpass(); misc/getpass.c defines it. The declaration
 * has to be here because src/options.h is included before <unistd.h>. */
char *getpass(const char *);
EOF

if [ "${DROPBEAR_DEBUG_TRACE:-1}" != "0" ]; then
	echo '#define DEBUG_TRACE 5' >> "$BUILD/localoptions.h"
fi

cd "$BUILD"
log "configure"
LTM_CFLAGS="-O3 -funroll-loops -fPIC" \
"$SRC/configure" \
	--enable-bundled-libtom \
	--disable-harden --disable-zlib --disable-syslog --disable-shadow \
	--disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
	--disable-loginfunc --disable-pututline --disable-pututxline \
	CC="$CC" CFLAGS="-fPIC -O2" \
	--host="$CONFIG_HOST" \
	> "$BUILD/configure.log" 2>&1 \
	|| { tail -25 "$BUILD/configure.log" >&2; err "configure failed (see $BUILD/configure.log)"; }

log "build IEC shims and sandbox shims"
SHIM_CFLAGS=(-O2 -fPIC -DINT_WARP -D_GNU_SOURCE -I "$IEC_ROOT" -I "$IEC_ROOT/common")
$CC "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/tty/shim.c" -o "$BUILD/iec_tty_shim.o"
$CC "${SHIM_CFLAGS[@]}" -DIEC_SHIM_MERGED_OPEN -c "$IEC_ROOT/fs/shim.c" -o "$BUILD/iec_fs_shim.o"
$CC "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/exec/shim.c" -o "$BUILD/iec_exec_shim.o"
$CC "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/rpc.c" -o "$BUILD/iec_rpc.o"
$CC "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/sock_client.c" -o "$BUILD/iec_sock_client.o"
$CC "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/misc/getpass.c" -o "$BUILD/iec_getpass.o"
$CC "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/misc/account.c" -o "$BUILD/iec_account.o"
$CC "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/compat/exit_wrap.c" -o "$BUILD/exit_wrap.o"

log "make (MULTI=1)"
make -j"$JOBS" MULTI=1 \
	PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" \
	LIBS="$BUILD/iec_getpass.o" \
	> "$BUILD/make.log" 2>&1 \
	|| { tail -30 "$BUILD/make.log" >&2; err "make failed (see $BUILD/make.log)"; }

log "rename main -> iec_dropbear_main"
"$OBJCOPY" --redefine-sym main=iec_dropbear_main \
	"$BUILD/obj/dbmulti.o" "$BUILD/obj/dbmulti_iec.o"
rm -f "$BUILD/obj/dbmulti.o"

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

log "link $OUT"
mkdir -p "$OUTDIR"
$CC -shared -o "$OUT" \
	"$BUILD"/obj/*.o \
	"$BUILD"/iec_tty_shim.o "$BUILD"/iec_fs_shim.o \
	"$BUILD"/iec_exec_shim.o "$BUILD"/iec_rpc.o "$BUILD"/iec_sock_client.o \
	"$BUILD"/iec_getpass.o "$BUILD"/iec_account.o "$BUILD"/exit_wrap.o \
	"$BUILD"/libtomcrypt/libtomcrypt.a "$BUILD"/libtommath/libtommath.a \
	-Wl,-soname,libdropbear.so \
	"${WRAP_FLAGS[@]}" \
	-Wl,-Bsymbolic-functions \
	-lpthread \
	> "$BUILD/link.log" 2>&1 \
	|| { tail -30 "$BUILD/link.log" >&2; err "link failed (see $BUILD/link.log)"; }

"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME' >&2
"$NM" -D --defined-only "$OUT" | grep ' iec_dropbear_main$' >/dev/null \
	|| err "iec_dropbear_main is not exported"
# The shims must be the definitions dropbear binds to (see -Bsymbolic-functions).
for sym in getpwuid getpwnam getpass; do
	"$NM" -D --defined-only "$OUT" | grep " $sym$" >/dev/null \
		|| err "$sym is not defined by the object"
done

log "done: $OUT ($(du -h "$OUT" | cut -f1))"
