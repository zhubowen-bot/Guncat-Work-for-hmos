#!/bin/bash
# build_curlcmd.sh — curl 命令行编成 IEC 命令 so（libcurlcmd.so，入口 iec_curl_main）。
#
# 复用 build_curl.sh 的 curl 构建树：libcurl.a 已经是 -fPIC 的静态库，命令行本身的
# 目标文件也在同一次 make 里生成。这里只做两件事：
#   1) 把 curl 的 main 改名成 iec_curl_main（llvm-objcopy --redefine-sym）；
#   2) 把工具对象 + libcurl.a + openssl/zlib 静态库 + IEC 的 fs/tty/exec shim
#      链成一个 .so。
#
# 为什么不用 -Dmain=iec_curl_main 重新 configure：curl 的 configure 会拿 CPPFLAGS/CFLAGS
# 编测试程序，-Dmain 会把测试程序的 main 也改名，导致 "C compiler cannot create
# executables"。改名放在链接前的目标文件上最省事，也不会污染 curl 的配置探测。
#
# Output: platform/ohos/har/libs/arm64-v8a/libcurlcmd.so
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

BLD="$IEC_ROOT/build/curl-build"
SRC="$BLD/src"
OUT_DIR="$IEC_ROOT/platform/ohos/har/libs/arm64-v8a"
SHIM_B="$IEC_ROOT/build/extra-cmds"
WORK="$IEC_ROOT/build/curlcmd"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"

# libcurl.a 不在就先跑依赖脚本（它同时会把 curl 命令行目标文件编出来）。
[ -f "$IEC_ROOT/build/curl/lib/libcurl.a" ] || "$IEC_ROOT/scripts/optional/build_curl.sh"
if [ ! -f "$SRC/curl-tool_main.o" ]; then
	make -C "$BLD" -j"${JOBS:-8}" > "$BLD/make.log" 2>&1 \
		|| { tail -30 "$BLD/make.log" >&2; iec_err "curl tool build failed"; }
fi

mkdir -p "$WORK" "$OUT_DIR"

# 1) main -> iec_curl_main
"$CLANG_DIR/llvm-objcopy" --redefine-sym main=iec_curl_main \
	"$SRC/curl-tool_main.o" "$WORK/curl_main.o"

# 2) 工具目标文件。排除：
#    - curl-tool_main.o（上面已改名）；
#    - libcurltool_la-*.o（src 里同时编了静态库，符号与上面重复）；
#    - curlinfo.o（另一个小工具的 main）。
mapfile -t OBJS < <(ls "$SRC"/*.o "$SRC"/toolx/*.o \
	| grep -vE '/(curl-tool_main|libcurltool_la-|curlinfo).*\.o$')

[ -f "$SHIM_B/iec_fs_shim.o" ] || "$IEC_ROOT/scripts/build_extra_commands.sh"

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
       chmod fchmod fchmodat
       open openat unlink unlinkat rename renameat access faccessat realpath
       link linkat opendir readdir scandir fopen freopen utimensat syscall
       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
       openpty login_tty forkpty execve execv execvp execvpe execl execlp execle exit)
WF=()
for n in "${WRAPS[@]}"; do WF+=("-Wl,--wrap=$n"); done

$CC_TARGET -shared -o "$OUT_DIR/libcurlcmd.so" "$WORK/curl_main.o" "${OBJS[@]}" \
	"$SHIM_B"/iec_tty_shim.o "$SHIM_B"/iec_fs_shim.o "$SHIM_B"/iec_exec_shim.o \
	"$SHIM_B"/iec_rpc.o "$SHIM_B"/iec_sock_client.o "$SHIM_B"/exit_wrap.o \
	"$IEC_ROOT/build/curl/lib/libcurl.a" \
	"$IEC_OPENSSL_DIR/lib/libssl.a" "$IEC_OPENSSL_DIR/lib/libcrypto.a" \
	"$IEC_DEPS_LIB/libz.a" \
	-Wl,-soname,libcurlcmd.so -Wl,-Bsymbolic-functions "${WF[@]}" -lpthread -ldl -lm

"$CLANG_DIR/llvm-nm" -D --defined-only "$OUT_DIR/libcurlcmd.so" \
	| grep ' iec_curl_main$' >/dev/null || iec_err "curl: entry iec_curl_main is not exported"
iec_log "done: $OUT_DIR/libcurlcmd.so"
