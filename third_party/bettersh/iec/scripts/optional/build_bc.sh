#!/bin/bash
# build_bc.sh — GNU bc 1.07.1 编成 IEC 命令 so（libbccmd.so，入口 iec_bc_main）。
#
# 两个坑：
#   1) bc 的 Makefile 在编 bc 之前会先编一个 aarch64 的 `fbc`，再**在本机运行**它，
#      把 libmath.b 编译成 libmath.h。交叉编译时这一步必然失败（目标二进制跑不起来）。
#      这里改为用宿主编译器另编一份原生 bc，用它生成 libmath.h，再回到交叉树继续。
#   2) 入口改名同样放在目标文件上（llvm-objcopy --redefine-sym），不塞进 configure 的
#      CFLAGS —— 否则 configure 的测试程序也会被改名。
#
# bc 默认不依赖 readline（--with-readline 是可选），所以产物只 NEEDED libc.so。
#
# Output: platform/ohos/har/libs/arm64-v8a/libbccmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

[ -x "$CLANG" ] || command -v "$CLANG" >/dev/null 2>&1 \
	|| iec_err "clang not found: $CLANG（检查 scripts/env.sh 的 OHOS_SDK）"
[ -d "$SYSROOT" ] || iec_err "OHOS sysroot not found: $SYSROOT（检查 scripts/env.sh 的 OHOS_SDK）"

VER="1.07.1"
TAR="$IEC_THIRDPARTY/bc-$VER.tar.gz"
SRC="$IEC_THIRDPARTY/bc-$VER"
WORK="$IEC_ROOT/build/bc"
HOST="$WORK/host"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

mkdir -p "$WORK" "$OUT_DIR"
if [ ! -s "$TAR" ]; then
	curl -L --retry 3 -m 600 -o "$TAR" "https://ftp.gnu.org/gnu/bc/bc-$VER.tar.gz" \
		|| curl -L --retry 3 -m 600 -o "$TAR" "https://mirrors.kernel.org/gnu/bc/bc-$VER.tar.gz" \
		|| iec_err "bc download failed"
fi
[ -d "$SRC" ] || tar xzf "$TAR" -C "$IEC_THIRDPARTY"

# 1) 目标 libbc.a + bc 目标文件
cd "$SRC"
[ -f Makefile ] || ./configure --host=aarch64-linux-ohos --build=x86_64-pc-linux-gnu \
	CC="$CC_TARGET" CFLAGS="-O2 -fPIC" LDFLAGS="-fuse-ld=lld" > "$WORK/configure.log" 2>&1
make -C lib CFLAGS="-O2 -fPIC" > "$WORK/lib.log" 2>&1 \
	|| { tail -30 "$WORK/lib.log" >&2; iec_err "bc lib build failed"; }

# 2) libmath.h：用宿主原生 bc 生成（见文件头注释）
if [ ! -s bc/libmath.h ] || ! grep -q '^"{' bc/libmath.h; then
	rm -rf "$HOST"
	mkdir -p "$HOST"
	tar xzf "$TAR" -C "$HOST"
	(
		cd "$HOST/bc-$VER"
		./configure --quiet > "$WORK/host-configure.log" 2>&1
		make -C lib > "$WORK/host-lib.log" 2>&1
		make -C bc > "$WORK/host-bc.log" 2>&1 \
			|| { tail -20 "$WORK/host-bc.log" >&2; iec_err "host bc build failed"; }
		cp bc/libmath.h "$SRC/bc/libmath.h"
	)
fi
[ -s bc/libmath.h ] || iec_err "bc libmath.h was not generated"

# 3) bc 本体
make -C bc CFLAGS="-O2 -fPIC" > "$WORK/bc.log" 2>&1 \
	|| { tail -30 "$WORK/bc.log" >&2; iec_err "bc build failed"; }

# 4) 链接成命令 so
[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"
"$CLANG_DIR/llvm-objcopy" --redefine-sym main=iec_bc_main bc/main.o "$WORK/bc_main.o"

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

mapfile -t OBJS < <(ls bc/*.o | grep -v '/main\.o$')
$CC_TARGET -shared -o "$OUT_DIR/libbccmd.so" "$WORK/bc_main.o" "${OBJS[@]}" lib/libbc.a \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libbccmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libbccmd.so" \
	| grep ' iec_bc_main$' >/dev/null || iec_err "bc: entry iec_bc_main is not exported"
iec_log "done: $OUT_DIR/libbccmd.so"
