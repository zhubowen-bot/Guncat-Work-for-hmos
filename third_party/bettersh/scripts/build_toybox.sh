#!/bin/bash
# build_libtoybox.sh — 把 toybox 编译为 libtoybox.so(单 so 多 applet)
# toybox 是 multicall 二进制:编成 .so,main 改名 bsh_toybox_main,
# 命令分发靠 argv[0](applet 名)。
# 产物 libtoybox.so → $ROOT/feature/bsh_main/libs/arm64-v8a/,随 HAP 打包,
# shell 命令表把它注册给 ls/cat 等。
#
# 用法: scripts/build_toybox_so.sh
# 工具链:TOYBOX_CC 显式 → OHOS SDK clang(默认,开源用户仅需 DevEco)→ musl-cross 兜底
# 源码:thirdparty/toybox 是 submodule(保持干净)—— 构建时复制到 $BUILD_DIR/toybox-src,
#       再把 toybox-ohos/patches/ 里的补丁打进副本(见那里 0001 的说明:clear 要多发 \e[3J)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/env.sh"
# 上游源码（submodule，保持干净）+ 我们的**工作副本**。
#
# 为什么要副本：我们要给 toys/other/clear.c 打补丁（见 toybox-ohos/patches/ 里的说明），
# 而 thirdparty/toybox 是 submodule —— 就地改会让 `git status` 一直显示
# "modified: thirdparty/toybox"，容易和别的改动混在一起。所以照 build_musl.sh 的做法：
# 把源码复制到 build/ 下（gitignored），补丁只打副本。`cp -a` 保留 mtime，
# 于是 make 仍是增量的，不会因为这次复制整体重编。
TOYBOX_SRC="$SCRIPT_DIR/../thirdparty/toybox"
SRC="$BUILD_DIR/toybox-src"
PATCH_DIR="$SCRIPT_DIR/toybox-ohos/patches"

OHOS_SDK="${OHOS_SDK:-/apps/harmony/sdk/default/openharmony}"
OHOS_CLANG="$OHOS_SDK/native/llvm/bin/clang"
MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"

CC=""; EXTRA=""; NM=""; READELF=""
if [ -n "${TOYBOX_CC:-}" ]; then
    CC="$TOYBOX_CC"; EXTRA=""
elif [ -x "$OHOS_CLANG" ]; then
    CC="$OHOS_CLANG"
    EXTRA="--target=aarch64-linux-ohos --sysroot=$OHOS_SDK/native/sysroot -fuse-ld=lld"
    NM="$OHOS_SDK/native/llvm/bin/llvm-nm"
    READELF="$OHOS_SDK/native/llvm/bin/llvm-readelf"
else
    CC="$MUSL_TC/bin/aarch64-linux-musl-gcc"; EXTRA=""
    NM="$MUSL_TC/bin/aarch64-linux-musl-nm"
    READELF="$MUSL_TC/bin/aarch64-linux-musl-readelf"
fi
[ -x "$CC" ] || { echo "编译器不可用: $CC(设 TOYBOX_CC)"; exit 1; }
HOSTCC="${HOSTCC:-cc}"

OUT="$ROOT/feature/bsh_main/libs/arm64-v8a/libtoybox.so"
echo "编译器: $CC"

[ -d "$TOYBOX_SRC" ] || { echo "缺源码: $TOYBOX_SRC（submodule 没拉？git submodule update --init）"; exit 1; }

echo "==> 铺源码副本 → $SRC"
mkdir -p "$SRC"
# 上一次构建留下的产物里，toybox / toybox-aarch64-linux-ohos 是 **0555**（make 装出来的
# 可执行文件），cp -a 覆盖它会被内核拒掉（Permission denied）—— 于是"重跑一次就挂，
# 得先 rm -rf build/toybox-src"。先把自己的产物删掉再铺：它们本来就会被重建。
rm -f "$SRC/toybox" "$SRC/toybox-aarch64-linux-ohos"
cp -a "$TOYBOX_SRC/." "$SRC/"

echo "==> 打我们的补丁（幂等；只打副本，submodule 保持干净）"
for p in "$PATCH_DIR"/*.patch; do
    [ -e "$p" ] || continue
    if patch -p1 -d "$SRC" --dry-run --silent < "$p" >/dev/null 2>&1; then
        echo "    $(basename "$p")"
        patch -p1 -d "$SRC" < "$p" >/dev/null
    elif patch -p1 -R -d "$SRC" --dry-run --silent < "$p" >/dev/null 2>&1; then
        echo "    $(basename "$p")：已是打过补丁的状态，跳过"
    else
        echo "    补丁既不能正向也不能反向应用（副本被改过？）: $p" >&2
        exit 1
    fi
done

cd "$SRC"
echo "==> configure toybox (defconfig + 需要的 applet)"
[ -f .config ] || make defconfig HOSTCC="$HOSTCC" >/dev/null
# 命令表里注册的 applet 必须在 .config 打开;defconfig 默认关掉 gzip(压缩侧)。
# 逐个尝试打开(符号不存在=该版本没有这个 toy,自然跳过)。改 .config 后
# make 会重编受影响的玩具。
# AWK/TR/STTY 这一组是补漏:命令表里一直登记着它们,但 defconfig 没开 ——
# 于是 `awk`/`tr`/`stty` 解析到 libtoybox.so 后得到一句
# "toybox: Unknown command xxx"(实测踩过,`tr` 出现在自检脚本里)。
for sym in MOUNT UMOUNT GZIP GUNZIP ZCAT WGET PING NETSTAT IFCONFIG \
           AWK TR STTY; do
    grep -q "^# CONFIG_${sym} is not set" .config && \
        sed -i "s/^# CONFIG_${sym} is not set/CONFIG_${sym}=y/" .config || true
done
# 关掉沙箱里用不到、且在 ohos sysroot 下编不过的 toy:它们依赖 utmp/utxent 与
# shadow(getspnam)接口,ohos 的 utmpx.h/shadow.h 只是空壳(没有这些声明)
# → implicit declaration 被当 error,整个 make 直接失败。
for sym in LOGIN SULOGIN NOLOGIN W WHO USERS LAST LASTLOG UPTIME UTMPDUMP \
           SU AC PASSWD CHSH CHFN CRYPTPW; do
    grep -q "^CONFIG_${sym}=y" .config && \
        sed -i "s/^CONFIG_${sym}=y/# CONFIG_${sym} is not set/" .config || true
done

echo "==> build objects (-fPIC, $EXTRA)"
# -Wno-implicit-function-declaration/-Wno-int-conversion 是兜底:上面那批 toy 之外
# 还可能有零星 toy 调 ohos 没实现的接口(utmpx 一族),不兜住的话 make 会整棵挂掉。
# 这些 toy 都不在命令表里,编进去也不会被执行。
make generated/unstripped/toybox \
    HOSTCC="$HOSTCC" CC="$CC" \
    CFLAGS="-fPIC -O2 $EXTRA -Wno-implicit-function-declaration -Wno-int-conversion" \
    >/dev/null

OBJDIR=generated/unstripped/obj
[ -d "$OBJDIR" ] || OBJDIR=generated/obj

echo "==> relink as shared library"
PM_DIR="$ROOT/feature/bsh_main/src/main/cpp/procmgr"
SHIM_DIR="$ROOT/feature/bsh_main/src/main/cpp/shim"
# exec 委托层(shim/exec_shim.c,与 guest 侧同一份源码):命令 so 内 exec*/posix_spawn →
# 经 control socket 交 procmgr 创建进程。命令 so 只能走 --wrap(链接期替换),所以这里
# 带 -DBSH_SHIM_WRAP;清单见 scripts/shim-wrap-flags.sh 的 $SHIM_WRAP_FLAGS（fs/tty/exec 一份）。
"$CC" $EXTRA -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_DIR" -I"$PM_DIR" \
    -c "$SHIM_DIR/exec_shim.c" -o "$SRC/generated/exec_shim.o"
"$CC" $EXTRA -O2 -fPIC -I"$PM_DIR" -c "$PM_DIR/bsh_client.c" -o "$SRC/generated/bsh_client.o"

# 符号链接的用户态模拟（见 feature/bsh_main/src/main/cpp/shim/README.md）：沙箱拒绝 symlink(2)，
# toybox 的 ln/cp/mv/tar/ls/pwd 全受影响。与 guest 侧是同一份源码，区别在"怎么被调用"：
# 命令 so 用 -DBSH_SHIM_WRAP + -Wl,--wrap=（链接期替换，与 shim/exec_shim.c 同一招），
# 真实现是链接器给的 __real_<名>；不能用 RTLD_NEXT（命令 so 排在搜索序末尾拿到 NULL）。
# 命令 so 都链同一套 shim（fs + tty + open_shim），清单也就只有一份 —— 见
# scripts/shim-wrap-flags.sh 里"清单必须与 .o 对应"那段。
source "$SCRIPT_DIR/shim-wrap-flags.sh"
"$CC" $EXTRA -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_SRC_DIR" \
    -c "$SHIM_SRC_DIR/fs_shim.c" -o "$SRC/generated/fs_shim.o"
"$CC" $EXTRA -O2 -fPIC -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -I"$SHIM_SRC_DIR" -I"$PM_DIR" \
    -c "$SHIM_SRC_DIR/tty_shim.c" -o "$SRC/generated/tty_shim.o"
"$CC" $EXTRA -O2 -fPIC -DBSH_SHIM_WRAP -I"$SHIM_SRC_DIR" \
    -c "$SHIM_SRC_DIR/open_shim.c" -o "$SRC/generated/open_shim.o"

# main.c 改名单独编译:进入命令时 toybox 按 argv[0] 分发 applet
"$CC" $EXTRA -O2 -fPIC -I. -I generated -c main.c -o generated/main_custom.o \
    -Dmain=bsh_toybox_main -DTOYBOX_VERSION='"0.8.14"'

OBJS=""
for o in "$OBJDIR"/*.o; do
    case "$o" in */main.o) ;; *) OBJS="$OBJS $o" ;; esac
done
mkdir -p "$(dirname "$OUT")"
# shellcheck disable=SC2086
"$CC" $EXTRA -shared -o "$OUT" $OBJS generated/main_custom.o \
    generated/exec_shim.o generated/bsh_client.o \
    generated/fs_shim.o generated/tty_shim.o generated/open_shim.o \
    -Wl,-soname,libtoybox.so \
    $SHIM_WRAP_FLAGS

echo "==> $OUT"
"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME' || true
"$NM" -D "$OUT" | grep 'bsh_toybox_main$' || echo "warn: bsh_toybox_main 未导出"
