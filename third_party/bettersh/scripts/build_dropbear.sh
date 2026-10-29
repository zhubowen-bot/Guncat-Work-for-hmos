#!/bin/bash
# build_dropbear.sh — 把 dropbear 编译为 libsshcore.so(命令 so 多调用)
#
# 形态:用 dropbear 的 dropbearmulti(server / client / keygen / convert / scp
# 五合一),它自己按 argv[0] 分发(dbmulti.c 认 "ssh"→dbclient、
# "ssh-keygen"→dropbearkey)。我们把唯一的 main 改名 bsh_dropbear_main,
# 命令表里逐条命令指向同一个 so + 这个入口。
#
# 为什么编成 .so:沙箱没有真 exec,命令 so 由 procmgr fork 后 dlopen 再调入口符号
# (见 README「如何新增一个命令 so」)。dropbear 需要起进程的地方(会话 shell、
# scp 调 ssh、ProxyCommand)统一经 shim/exec_shim.c 的 exec 委托交回 procmgr。
#
# 沙箱适配一共三处,都不改上游语义(详见 docs/ssh-port.md):
#   1. scripts/dropbear-ohos.patch —— 服务端会话 pty 改 socketpair。沙箱里
#      /dev/tty、/dev/ptmx 都是 EACCES,openpty() 同样失败,而 dropbear 的
#      pty_allocate()/pty_setowner() 在失败路径上会直接 dropbear_exit。
#      patch 打在**源码副本**上,子模块保持干净。
#   2. ssh/sandbox_compat.c —— getpass()。ohos libc 没有它,而 dropbear 无条件调用。
#   3. ssh/pwshim.c —— getpwuid()/getpwnam()。沙箱 /etc/passwd 里没有当前 uid,
#      靠符号遮蔽给 dropbear 一个合成条目(配合 -Bsymbolic-functions)。
#
# 几个绕不开的构建点:
#   - out-of-tree 构建(build/dropbear):子模块保持干净;
#   - configure 必须给 aarch64-unknown-linux-musl:dropbear 自带的 config.sub
#     不认 "ohos"(报 OS 'ohos' not recognized);
#   - localoptions.h 里声明 getpass:ohos 头文件里没有它,而 src/options.h(含该文件)
#     在 includes.h 里早于 <unistd.h>;
#   - DROPBEAR_REEXEC=0:沙箱里 argv[0] 不是可执行文件,fexecve 自我重启必然失败;
#   - bundled libtomcrypt/libtommath 要靠 LTM_CFLAGS 带上 -fPIC,否则它的静态库
#     不能链进 .so(libtommath 的规则用的是 LTM_CFLAGS,不是 CFLAGS)。
#
# 产物 libsshcore.so → $ROOT/feature/bsh_main/libs/arm64-v8a/,随 HAP 打包。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/env.sh"
# shim 家族（见 feature/bsh_main/src/main/cpp/shim/README.md）：沙箱拒绝 symlink(2)，命令 so 侧
# 统一用 -DBSH_SHIM_WRAP + -Wl,--wrap=（链接期替换；真实现=链接器生成的 __real_<名>）。
# 不能用 RTLD_NEXT：命令 so 是主进程 dlopen 进来的、排在搜索序末尾，拿不到真实现。
source "$SCRIPT_DIR/shim-wrap-flags.sh"


SRC_SUBMODULE="$ROOT/thirdparty/dropbear"    # 只读子模块
SRC="$ROOT/build/dropbear-src"               # 打过 patch 的源码副本
BUILD="$ROOT/build/dropbear"                 # out-of-tree 构建目录
PATCH="$ROOT/scripts/dropbear-ohos.patch"
OUTDIR="$ROOT/feature/bsh_main/libs/arm64-v8a"
OUT="$OUTDIR/libsshcore.so"
TC_DIR="$ROOT/feature/bsh_main/src/main/cpp"
JOBS="${JOBS:-$(nproc)}"

MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
OHOS_SDK="${OHOS_SDK:-/apps/harmony/sdk/default/openharmony}"
OHOS_CLANG="$OHOS_SDK/native/llvm/bin/clang"

# config.sub 认识的 host triple:ohos 不在其中,用 musl 代过(ABI 由 CC 的
# --target/--sysroot 决定,这里的 --host 只影响 autoconf 的探测假设)
case "$NATIVE_ARCH" in
    arm64-v8a) CONFIG_HOST="aarch64-unknown-linux-musl" ;;
    x86_64)    CONFIG_HOST="x86_64-unknown-linux-musl" ;;
    *) err "NATIVE_ARCH=$NATIVE_ARCH 不支持" ;;
esac

CC=""; NM=""; READELF=""; OBJCOPY=""
if [ -n "${DROPBEAR_CC:-}" ]; then
    CC="$DROPBEAR_CC"
    NM="${DROPBEAR_NM:-nm}"; READELF="${DROPBEAR_READELF:-readelf}"
    OBJCOPY="${DROPBEAR_OBJCOPY:-objcopy}"
elif [ -x "$OHOS_CLANG" ]; then
    CC="$OHOS_CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"
    NM="$OHOS_SDK/native/llvm/bin/llvm-nm"
    READELF="$OHOS_SDK/native/llvm/bin/llvm-readelf"
    OBJCOPY="$OHOS_SDK/native/llvm/bin/llvm-objcopy"
else
    CC="$MUSL_TC/bin/aarch64-linux-musl-gcc"
    NM="$MUSL_TC/bin/aarch64-linux-musl-nm"
    READELF="$MUSL_TC/bin/aarch64-linux-musl-readelf"
    OBJCOPY="$MUSL_TC/bin/aarch64-linux-musl-objcopy"
fi
[ -n "$CC" ] || err "编译器不可用(设 DROPBEAR_CC,或用 OHOS SDK / MUSL_TOOLCHAIN)"
[ -f "$SRC_SUBMODULE/configure" ] || err "缺源码: $SRC_SUBMODULE(先 git submodule update --init thirdparty/dropbear)"
[ -f "$PATCH" ] || err "缺 patch: $PATCH"
[ -x "$OBJCOPY" ] || err "缺 objcopy: $OBJCOPY"
echo "编译器: $CC"

echo "==> 复制源码并打 patch"
rm -rf "$SRC" "$BUILD"
mkdir -p "$SRC" "$BUILD"
# .git 在子模块里是个指针文件,不必带进副本
( cd "$SRC_SUBMODULE" && tar -cf - --exclude=.git . ) | ( cd "$SRC" && tar -xf - )
patch -p1 -d "$SRC" -i "$PATCH" > "$BUILD/patch.log" 2>&1 \
    || { cat "$BUILD/patch.log" >&2; err "patch 应用失败(上游代码变了?)"; }

# dropbear 认 build 目录下的 localoptions.h(见它的 Makefile.in / src/options.h)
cat > "$BUILD/localoptions.h" <<'EOF'
/* BetterSH 沙箱本地裁剪(见 docs/ssh-port.md) */

/* 沙箱里 argv[0] 不是可执行文件,dropbear 的 fexecve(argv[0]) 自我重启必然失败 */
#define DROPBEAR_REEXEC 0

/* scp 内部调起的 ssh 客户端:必须是命令名,这样 exec 委托才认得出、
 * 交回 procmgr 起 dbclient(默认值 /usr/bin/dbclient 在这里不存在) */
#define DROPBEAR_PATH_SSH_PROGRAM "ssh"

/* 没有 sftp-server(默认路径 /usr/libexec/sftp-server 也不存在),别对外声称支持 */
#define DROPBEAR_SFTPSERVER 0

/* 服务端 checkusername() 会用 getusershell() 的清单校验 pw_shell。沙箱里
 * /etc/shells 不存在,dropbear 的 compat.c 会回退到这个编译期常量(默认
 * "/bin/sh","/bin/csh")—— 而我们的会话 shell 是命令表里的裸名字 sh
 * (见 ssh/pwshim.c 的 BSH_SSH_SHELL),所以把清单设成同一个名字。 */
#define COMPAT_USER_SHELLS "sh"

/* ohos libc 没有 getpass(),而 dropbear 无条件调用它;实现在 ssh/sandbox_compat.c。
 * 声明必须在这里:src/options.h(含本文件)在 includes.h 里早于 <unistd.h>。 */
char *getpass(const char *);
EOF

# DEBUG_TRACE=1 才认 `-v`(它的 case 'v' 在 #if DEBUG_TRACE 里),TRACE 也只在
# debug_trace>0 时输出 —— 平时没有任何额外噪音。默认开,便于用户自查
# (`ssh -v ...` 会打出加载了哪个私钥路径、server-sig-algs 过滤了哪些 key);
# 设 DROPBEAR_DEBUG_TRACE=0 可关掉。
# DEBUG_TRACE 是**编译期**等级:宏 DEBUG1/DEBUG2/DEBUG3/TRACE/TRACE2 各自要求
# >=1/2/3/4/5(见 src/debug.h),不够就整个编译掉 —— dropbear 绝大多数日志用的是
# TRACE(要 4),只开 1 的话它们根本不在二进制里。运行时还要把 -v 重复到同一等级
# (见 dbutil.c 的 dropbear_tracelevel)。这里开到 5 把各级都编进来,噪音由运行时的
# -v 数量控制,平时一条都不打。设 DROPBEAR_DEBUG_TRACE=0 可完全关掉。
if [ "${DROPBEAR_DEBUG_TRACE:-1}" != "0" ]; then
    echo '#define DEBUG_TRACE 5' >> "$BUILD/localoptions.h"
fi

cd "$BUILD"
echo "==> configure"
# --disable-* 一串:沙箱没有 syslogd / shadow / utmp / wtmp / lastlog,
# ohos sysroot 里这些符号基本是空壳(缺 getspnam/login/pututxline/updwtmp…)
LTM_CFLAGS="-O3 -funroll-loops -fPIC" \
"$SRC/configure" \
    --enable-bundled-libtom \
    --disable-harden --disable-zlib --disable-syslog --disable-shadow \
    --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
    --disable-loginfunc --disable-pututline --disable-pututxline \
    CC="$CC" CFLAGS="-fPIC -O2" \
    --host="$CONFIG_HOST" \
    > "$BUILD/configure.log" 2>&1 \
    || { tail -25 "$BUILD/configure.log" >&2; err "configure 失败($BUILD/configure.log)"; }
grep -E "^configure: (Using|WARNING)" "$BUILD/configure.log" >&2 || true

echo "==> 编译公共对象(exec 委托 / tty shim / 沙箱补丁)"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_SRC_DIR" -I"$TC_DIR/procmgr" -c "$SHIM_SRC_DIR/exec_shim.c" -o "$BUILD/exec_shim.o"
$CC -O2 -fPIC -I"$TC_DIR/procmgr" -c "$TC_DIR/procmgr/bsh_client.c" -o "$BUILD/bsh_client.o"
FS_OBJ="$BUILD/fs_shim.o"
OPEN_OBJ="$BUILD/open_shim.o"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_SRC_DIR" -c "$SHIM_SRC_DIR/fs_shim.c" -o "$FS_OBJ"
$CC -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_SRC_DIR" -c "$SHIM_SRC_DIR/open_shim.c" -o "$OPEN_OBJ"

$CC -O2 -fPIC -I"$TC_DIR/procmgr" -I"$TC_DIR/tty" \
    -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -c "$SHIM_SRC_DIR/tty_shim.c" -o "$BUILD/tty_shim.o"
$CC -O2 -fPIC -c "$TC_DIR/ssh/sandbox_compat.c" -o "$BUILD/sandbox_compat.o"
$CC -O2 -fPIC -I"$TC_DIR" -c "$TC_DIR/ssh/pwshim.c" -o "$BUILD/pwshim.o"

echo "==> make(MULTI=1 五合一)"
# sandbox_compat.o 经 LIBS 塞进链接:dropbear 的目标文件引用了 getpass(它是无条件
# 调用的,不受 HAVE_GETPASS 保护),不补上就过不了链接。make 顺带产出的 dropbearmulti
# 可执行文件只是副产品,不随包发。LIBS 在 Makefile 里是 `LIBS+=`(configure 没探测到
# 要追加的东西),命令行覆盖不会丢东西。
make -j"$JOBS" MULTI=1 \
     PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" \
     LIBS="$BUILD/sandbox_compat.o" \
     > "$BUILD/make.log" 2>&1 \
    || { tail -30 "$BUILD/make.log" >&2; err "make 失败($BUILD/make.log)"; }

echo "==> 入口改名: main → bsh_dropbear_main"
"$OBJCOPY" --redefine-sym main=bsh_dropbear_main \
    "$BUILD/obj/dbmulti.o" "$BUILD/obj/dbmulti_bsh.o"
rm -f "$BUILD/obj/dbmulti.o"     # 免得下面的通配把它再链进去

echo "==> 聚合 $OUT"
mkdir -p "$OUTDIR"
# obj/*.o 就是 MULTIOBJS 的全集(五合一的并集,Makefile 已 sort 去重);
# 未定义符号故意留着:getsid 之类在 dlopen 时从进程全局作用域解析。
$CC -shared -o "$OUT" \
    "$BUILD"/obj/*.o \
    "$BUILD"/exec_shim.o "$BUILD"/bsh_client.o \
    "$BUILD"/tty_shim.o "$FS_OBJ" "$OPEN_OBJ" "$BUILD"/sandbox_compat.o "$BUILD"/pwshim.o \
    "$BUILD"/libtomcrypt/libtomcrypt.a "$BUILD"/libtommath/libtommath.a \
    -Wl,-soname,libsshcore.so \
    $SHIM_WRAP_FLAGS \
    -Wl,-Bsymbolic-functions \
    > "$BUILD/link.log" 2>&1 \
    || { tail -30 "$BUILD/link.log" >&2; err "链接失败($BUILD/link.log)"; }

echo "==> 校验"
"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME' || true
"$NM" -D --defined-only "$OUT" | grep -E ' bsh_dropbear_main$' \
    || err "bsh_dropbear_main 未导出"
# 遮蔽是否生效:这两个符号必须由本 so 定义(否则 passwd 兜底没接上)
"$NM" -D --defined-only "$OUT" | grep -E ' (getpwuid|getpwnam|getpass)$' || true
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"
