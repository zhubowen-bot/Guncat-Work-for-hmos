#!/bin/bash
# build_sftp.sh — OpenSSH 9.9p2 的 sftp 客户端编成 IEC 命令 so
# （libsftpcmd.so，入口 iec_sftp_main）。
#
# 三处交叉编译适配（都在脚本里自动做，不改上游源码）：
#   1) openssh 自带的 config.sub 不认识 `*-linux-ohos`，--host 用
#      aarch64-linux-gnu；真正的目标三元组由 CC 的 --target 决定。
#   2) configure 默认给 configure 出来的 SYS_RDOMAIN_LINUX / SSH_TUN_LINUX；
#      SSH_TUN_LINUX 会让 openbsd-compat/port-net.c 去 include <linux/if.h>，
#      而 OHOS 的 linux/socket.h 无条件定义 sockaddr_storage，与 sys/socket.h
#      冲突（redefinition）。sftp 不需要 tun，直接在 config.h 里关掉。
#   3) 默认的 hardening 会加 -fPIE，PIE 目标文件不能链进 .so
#      （R_AARCH64_ADR_PREL_PG_HI21 / recompile with -fPIC）。
#      用 --without-hardening + CFLAGS=-fPIC 重编。
#
# Output: platform/ohos/har/libs/arm64-v8a/libsftpcmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

VER="9.9p2"
TAR="$IEC_THIRDPARTY/openssh-$VER.tar.gz"
SRC="$IEC_THIRDPARTY/openssh-$VER"
WORK="$IEC_ROOT/build/sftp"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

mkdir -p "$WORK" "$OUT_DIR"
if [ ! -s "$TAR" ]; then
	curl -L --retry 3 -m 600 -o "$TAR" \
		"https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-$VER.tar.gz" \
		|| iec_err "openssh download failed"
fi
[ -d "$SRC" ] || tar xzf "$TAR" -C "$IEC_THIRDPARTY"

[ -f "$IEC_OPENSSL_DIR/lib/libssl.a" ] || iec_err "openssl is missing (run build_openssl.sh first)"
[ -f "$IEC_DEPS_LIB/libz.a" ] || iec_err "zlib is missing (run build_zlib.sh first)"

cd "$SRC"
if [ ! -f Makefile ]; then
	./configure --host=aarch64-linux-gnu --build=x86_64-pc-linux-gnu \
		--prefix="$WORK/prefix" \
		--with-ssl-dir="$IEC_OPENSSL_DIR" --with-zlib="$IEC_DEPS_DIR/usr" \
		--without-openssl-header-check --without-hardening \
		--without-pam --without-shadow --without-selinux --without-audit \
		--disable-etc-default-login --disable-strip \
		CC="$CC_TARGET" \
		CFLAGS="-O2 -fPIC -I$IEC_OPENSSL_DIR/include -I$IEC_DEPS_INC" \
		LDFLAGS="-fuse-ld=lld -L$IEC_OPENSSL_DIR/lib -L$IEC_DEPS_LIB" \
		> "$WORK/configure.log" 2>&1 \
		|| { tail -30 "$WORK/configure.log" >&2; iec_err "openssh configure failed"; }
	sed -i 's|^#define SSH_TUN_LINUX 1|/* #undef SSH_TUN_LINUX */|' config.h
fi

make -j"${JOBS:-8}" sftp > "$WORK/make.log" 2>&1 \
	|| { tail -30 "$WORK/make.log" >&2; iec_err "sftp build failed"; }
[ -x sftp ] || iec_err "sftp was not built"

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"
"$CLANG_DIR/llvm-objcopy" --redefine-sym main=iec_sftp_main sftp.o "$WORK/sftp_main.o"

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT_DIR/libsftpcmd.so" "$WORK/sftp_main.o" \
	sftp-usergroup.o progressmeter.o sftp-common.o sftp-client.o sftp-glob.o \
	libssh.a openbsd-compat/libopenbsd-compat.a \
	"$IEC_OPENSSL_DIR/lib/libssl.a" "$IEC_OPENSSL_DIR/lib/libcrypto.a" \
	"$IEC_DEPS_LIB/libz.a" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libsftpcmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libsftpcmd.so" \
	| grep ' iec_sftp_main$' >/dev/null || iec_err "sftp: entry iec_sftp_main is not exported"
iec_log "done: $OUT_DIR/libsftpcmd.so"
