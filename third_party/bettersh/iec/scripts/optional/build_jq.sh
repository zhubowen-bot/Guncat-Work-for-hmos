#!/bin/bash
# build_jq.sh — jq 1.7.1 编成 IEC 命令 so（libjqcmd.so，入口 iec_jq_main）。
#
# 依赖：静态 oniguruma（本脚本一起编）、IEC 的 fs/tty/exec shim（复用
# build_extra_commands.sh 产出的 shim 对象）、宿主 autoconf/automake/libtool。
#
# Output: platform/ohos/har/libs/arm64-v8a/libjqcmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

JQ_VER="1.7.1"
ONIG_VER="6.9.9"
WORK="$IEC_ROOT/build/jq"
PREFIX="$WORK/prefix"
SRC="$WORK/jq-src"
OUT="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

mkdir -p "$WORK"
cd "$WORK"

[ -f jq.tar.gz ] || curl -L --retry 3 -m 600 -o jq.tar.gz \
	"https://codeload.github.com/jqlang/jq/tar.gz/refs/tags/jq-$JQ_VER"
[ -f onig.tar.gz ] || curl -L --retry 3 -m 600 -o onig.tar.gz \
	"https://codeload.github.com/kkos/oniguruma/tar.gz/refs/tags/v$ONIG_VER"
[ -d jq-src ] || { tar xzf jq.tar.gz && mv "jq-jq-$JQ_VER" jq-src; }
[ -d onig-src ] || { tar xzf onig.tar.gz && mv "oniguruma-$ONIG_VER" onig-src; }

# 1) oniguruma（静态、PIC）
if [ ! -f "$PREFIX/lib/libonig.a" ]; then
	cd "$WORK/onig-src"
	[ -f configure ] || autoreconf -fi > "$WORK/onig-autoreconf.log" 2>&1
	./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu \
		--prefix="$PREFIX" --disable-shared --enable-static \
		CC="$CC_TARGET" CFLAGS="-O2 -fPIC" > "$WORK/onig-configure.log" 2>&1
	make -j"${JOBS:-8}" > "$WORK/onig-make.log" 2>&1
	make install > "$WORK/onig-install.log" 2>&1
fi
[ -f "$PREFIX/lib/libonig.a" ] || iec_err "oniguruma build failed"

# 2) jq 的 libjq.a（PIC）
cd "$SRC"
[ -f configure ] || autoreconf -fi > "$WORK/jq-autoreconf.log" 2>&1
if [ ! -f Makefile ]; then
	./configure --host=aarch64-linux-gnu --build=x86_64-linux-gnu \
		--prefix="$PREFIX" --with-oniguruma="$PREFIX" \
		--disable-docs --disable-maintainer-mode --enable-static --disable-shared \
		CC="$CC_TARGET" CFLAGS="-O2 -fPIC" > "$WORK/jq-configure.log" 2>&1
fi
# builtin.inc 只是 sed；version.h/config_opts.inc 由 make 规则生成。
[ -f src/builtin.inc ] || sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$/\\n"/' \
	src/builtin.jq > src/builtin.inc
make src/version.h src/config_opts.inc > "$WORK/jq-gen.log" 2>&1
printf '#define JQ_VERSION "%s"\n' "$JQ_VER" > src/version.h
make -j"${JOBS:-8}" libjq.la > "$WORK/jq-make.log" 2>&1
[ -f .libs/libjq.a ] || iec_err "libjq build failed"

# 3) 链接成命令 so（复用 extra-cmds 的 shim 对象）
[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"
OBJ="$WORK/jq_main.o"
$CC_TARGET -O2 -fPIC -I. -Isrc -I"$PREFIX/include" -Dmain=iec_jq_main -D_GNU_SOURCE \
	-c src/main.c -o "$OBJ"

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT/libjqcmd.so" "$OBJ" .libs/libjq.a "$PREFIX/lib/libonig.a" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	-Wl,-soname,libjqcmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT/libjqcmd.so" | grep ' iec_jq_main$' >/dev/null \
	|| iec_err "jq: entry iec_jq_main is not exported"
iec_log "done: $OUT/libjqcmd.so"
