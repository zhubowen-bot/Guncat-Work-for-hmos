#!/bin/bash
# build_extra_commands.sh — 编 nc / hexdump / diff 三个命令 so。
#
# 三者都链接同一套 IEC shim（fs + tty + exec），因此文件系统、终端判断与 exec
# 都走沙箱语义；产物 NEEDED 只有 libc.so。
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libnc.so       (iec_nc_main)
#   platform/ohos/har/libs/arm64-v8a/libhexdump.so  (iec_hexdump_main)
#   platform/ohos/har/libs/arm64-v8a/libdiff.so     (iec_diff_main)
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

BUILD="$IEC_ROOT/build/extra-cmds"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT_DIR"

SHIM_CFLAGS=(-O2 -fPIC -DINT_WARP -D_GNU_SOURCE -I "$IEC_ROOT" -I "$IEC_ROOT/common")
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/tty/shim.c" -o "$BUILD/iec_tty_shim.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -DIEC_SHIM_MERGED_OPEN -c "$IEC_ROOT/fs/shim.c" -o "$BUILD/iec_fs_shim.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/exec/shim.c" -o "$BUILD/iec_exec_shim.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/rpc.c" -o "$BUILD/iec_rpc.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/sock_client.c" -o "$BUILD/iec_sock_client.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/compat/exit_wrap.c" -o "$BUILD/exit_wrap.o"

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

SHIM_OBJS=("$BUILD/iec_tty_shim.o" "$BUILD/iec_fs_shim.o" "$BUILD/iec_exec_shim.o"
           "$BUILD/iec_rpc.o" "$BUILD/iec_sock_client.o" "$BUILD/exit_wrap.o")

build_cmd() {
	local name="$1" src="$2" entry="$3"
	local out="$OUT_DIR/lib${name}.so"
	local obj="$BUILD/${name}.o"
	$CC_TARGET -O2 -fPIC -D_GNU_SOURCE -I "$IEC_ROOT" -I "$IEC_ROOT/common" \
		-c "$IEC_ROOT/scripts/optional/$src" -o "$obj"
	$CC_TARGET -shared -o "$out" "$obj" "${SHIM_OBJS[@]}" \
		-Wl,-soname,"lib${name}.so" -Wl,-Bsymbolic-functions \
		"${WRAP_FLAGS[@]}" -lpthread -ldl -lm
	"$CLANG_DIR/llvm-nm" -D --defined-only "$out" | grep " ${entry}$" >/dev/null \
		|| iec_err "$name: entry $entry is not exported"
	"$CLANG_DIR/llvm-readelf" -d "$out" | grep -E 'NEEDED|SONAME' >&2 || true
	iec_log "done: $out"
}

build_cmd nc      cmd_nc.c      iec_nc_main
build_cmd hexdump cmd_hexdump.c iec_hexdump_main
build_cmd diff    cmd_diff.c    iec_diff_main
