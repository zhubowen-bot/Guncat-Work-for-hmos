#!/bin/bash
# run_testprogs_host.sh — 在开发机上把 8 个组合全跑一遍（WSL 本地 + qemu-user 模拟）
#
# 为什么要有它：设备那一圈很贵（重打 HAP ~1 分钟 + 部署 ~1 分钟 + 自检），而**测试
# 程序本身**的毛病（写错的断言、越界、把返回值当 errno……）不该拿设备去撞。先在本地
# 把 8 个组合跑成 0 FAIL，上设备就只剩"沙箱相关的判据"值得看。
#
# 与设备侧的两处差别（不知道就会误读结果）：
#   1) **执行方式不同**：x86_64 在这里是原生执行，aarch64 是 qemu-user 模拟；设备上
#      x86 走 box64、aarch64 走 elfloader。所以哪几条判据没意义要看备注：程序里用
#      环境变量 BSH_TEST_NATIVE=1 区分，把 auxv/jit/maps 三条"沙箱判据"改成转储或
#      跳过（不判分），其余用例（fs/symlink/pty/线程/fork/dlopen/exec…）照常断言 ——
#      这些在本地跑通代表"程序逻辑对"，在设备上跑通才代表"沙箱里能用"。
#   2) **解释器路径**：x86_64 musl 那两组合的 PT_INTERP 是 /lib/ld-musl-x86_64.so.1，
#      本地没有（也不往 /lib 里塞东西），所以在本目录**重新链一份**、把解释器指到
#      工具链里的绝对路径。aarch64 四只交给 qemu 的 QEMU_LD_PREFIX —— 注意不能用
#      命令行的 -L：嵌套 exec 时是内核按 binfmt 重新拉起 qemu，命令行参数传不下去，
#      只有环境变量能传。
#
# 用法：./scripts/run_testprogs_host.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# env.sh 开头就是 `set -euo pipefail`（构建脚本要 fail-fast）；本脚本要**故意**接住
# 非 0 退出码（测试程序正常退出就是 42、grep 没匹配也是 1），所以取到它导出的变量之后
# 立刻把 -e 关掉 —— 不然第一条测试跑完，脚本就以它的退出码"成功"退出了，后面 7 个
# 组合一个都不跑，日志上还看不出来（踩过）。
source "$SCRIPT_DIR/env.sh"
set +e

SRC="$ROOT/feature/bsh_main/src/main/cpp/programs/testx64/main.c"
LIB_SRC="$ROOT/feature/bsh_main/src/main/cpp/programs/testx64/greet.c"
HOST_SRC="$ROOT/feature/bsh_main/src/main/cpp/programs/testx64/dlhost.c"
PKG="$ROOT/build/testprogs/testprogs"
HOST="$ROOT/build/testprogs-host"
OUTD="$HOST/out"

CFLAGS_COMMON="-O2 -Wall -Wextra -Wno-unused-parameter -Wno-unused-result"
LDLIBS_COMMON="-lpthread -lm"
X86_64_MUSL_TC="${X86_64_MUSL_TOOLCHAIN:-$ROOT/thirdparty/x86_64-linux-musl-cross}"
X86_64_MUSL_CC="$X86_64_MUSL_TC/bin/x86_64-linux-musl-gcc"
AARCH64_MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
QEMU="${QEMU_AARCH64:-qemu-aarch64-static}"
command -v "$QEMU" >/dev/null || QEMU=qemu-aarch64

X86_COMBOS="x86_64-glibc-dynamic x86_64-glibc-static x86_64-musl-dynamic x86_64-musl-static"
A64_COMBOS="aarch64-musl-dynamic aarch64-musl-static aarch64-glibc-dynamic aarch64-glibc-static \
           aarch64-glibc-dynamic-nopie"

# ── 1) 先把设备用的那套产物编出来（也是本脚本的输入） ──────────────
# 源码比产物新就重编 —— 不重编会踩"拿旧二进制当新结论"的坑（第一次就是这么被
# 骗过去的：加了 BSH_TEST_NATIVE 的改动没编进去，aarch64 四只全报 maps FAIL）。
if [ ! -f "$PKG/aarch64-glibc-dynamic" ] \
   || [ "$SRC" -nt "$PKG/aarch64-glibc-dynamic" ] \
   || [ "$LIB_SRC" -nt "$PKG/aarch64-glibc-dynamic" ] \
   || [ "$HOST_SRC" -nt "$PKG/aarch64-glibc-dynamic" ]; then
    bash "$SCRIPT_DIR/build_testprogs.sh" >/dev/null || exit 1
fi

# ── 2) 本地副本：x86_64 musl 的 4 个动态件改指解释器到工具链绝对路径 ──
MUSL_LD="$X86_64_MUSL_TC/x86_64-linux-musl/lib/libc.so"
[ -f "$MUSL_LD" ] || { echo "缺 x86_64 musl 加载器：$MUSL_LD" >&2; exit 1; }
rm -rf "$HOST"
mkdir -p "$OUTD"
cp -r "$PKG" "$HOST/tp"
TP="$HOST/tp"

# 需要改的：两个动态 dlhost（不分静态/动态组合，它们本身就是动态编的）
#          + 动态那只主程序。静态只没有 PT_INTERP，不用动。
for c in x86_64-musl-dynamic x86_64-musl-static; do
    "$X86_64_MUSL_CC" $CFLAGS_COMMON -DBSH_TEST_COMBO="\"$c\"" \
        "$HOST_SRC" -o "$TP/dlhost-$c" -L"$TP" -ltgreet-$c -Wl,-rpath,'$ORIGIN' \
        -Wl,--dynamic-linker="$MUSL_LD" $LDLIBS_COMMON || exit 1
done
"$X86_64_MUSL_CC" $CFLAGS_COMMON -Wl,--dynamic-linker="$MUSL_LD" \
    -DBSH_TEST_COMBO='"x86_64-musl-dynamic"' -DBSH_TEST_STATIC=0 \
    "$SRC" -o "$TP/x86_64-musl-dynamic" $LDLIBS_COMMON || exit 1

# ── 3) qemu 的前缀目录：/lib/ld-musl-aarch64.so.1 与 /lib/ld-linux-aarch64.so.1 ──
# musl 那份优先用**我们自己编的**（build_musl.sh 的产物，就是随 HAP 发到设备上的
# 那一份）—— 本机跑的就该是线上那份；没有才退回工具链原厂，好让"还没编 musl"的
# 环境也能跑。
mkdir -p "$HOST/prefix-musl/lib" "$HOST/prefix-glibc/lib"
MUSL_LD_SHIP="$ROOT/build/musl/out/lib/ld-musl-aarch64.so.1"
if [ -f "$MUSL_LD_SHIP" ]; then
    cp -f "$MUSL_LD_SHIP" "$HOST/prefix-musl/lib/ld-musl-aarch64.so.1"
    echo "（musl 前缀用自编的那份：$MUSL_LD_SHIP）"
else
    cp -f "$AARCH64_MUSL_TC/aarch64-linux-musl/lib/libc.so" "$HOST/prefix-musl/lib/ld-musl-aarch64.so.1"
    echo "（musl 前缀用工具链原厂那份：先跑 scripts/build_musl.sh install 才会用上自编的）"
fi
ln -sf ld-musl-aarch64.so.1 "$HOST/prefix-musl/lib/libc.so"
GLIBC_RT="$ROOT/build/glibc/out/lib"
[ -f "$GLIBC_RT/libc.so.6" ] || GLIBC_RT="$ROOT/feature/bsh_main/libs/arm64-v8a"   # 兜底：随 HAP 那份
for f in libc.so.6 ld-linux-aarch64.so.1; do
    [ -f "$GLIBC_RT/$f" ] || { echo "缺 glibc 运行时 $f（先跑 scripts/build_glibc.sh all）" >&2; exit 1; }
    cp -f "$GLIBC_RT/$f" "$HOST/prefix-glibc/lib/$f"
done
chmod 755 "$HOST/prefix-glibc/lib/ld-linux-aarch64.so.1"

# ── 4) 跑 ─────────────────────────────────────────────────
# 程序**不知道**自己在哪跑（也不该知道）：判据全是"能不能做到"那种，与执行者无关。
# 唯一与环境有关的那些事实（比如 guest 镜像是不是文件映射）程序只照原样打出来
# （FACT 行 + INFO），判不判由外层决定 —— 设备侧自检会 grep 那行，这里不看。
# stdin 接 /dev/null：和 autorun 一个口径，免得哪个用例等输入把整轮挂住。
# 退出码 0 或 42 都算成功 —— 42 是最后那条"直接 exec 自己"成功后的子模式退出码。
run_one() {
    local combo="$1" runner="$2" prefix="${3:-}"
    local log="$OUTD/$combo.log" cmd
    # 用 script(1) 给被测程序一路**真 pty**：否则 0/1/2 全是 /dev/null + 日志文件，
    # "会话是不是终端"那一项根本没有可验对象、只能 SKIP —— 那是脚本自己造成的空档，
    # 不该记在程序头上（第一版就是这么一个 SKIP）。script -e 会把子进程退出码带回来。
    if [ -n "$prefix" ]; then
        cmd="QEMU_LD_PREFIX='$prefix' '$TP/$combo'"
    else
        cmd="'$TP/$combo'"
    fi
    if command -v script >/dev/null 2>&1; then
        timeout 300 script -qec "$cmd" /dev/null > "$log" 2>&1 < /dev/null
    else
        echo "（没有 script(1)，本次没有 pty，"会话 tty" 那项会 SKIP）" >&2
        timeout 300 sh -c "$cmd" > "$log" 2>&1 < /dev/null
    fi
    local rc=$?
    local line; line=$(grep -a 'blocks=' "$log" | head -1)
    printf '%-22s rc=%-4s %s\n' "$combo" "$rc" "${line:-（没跑到汇总行）}"
    grep -a '\[FAIL\]' "$log" | tr -d '\r' | sed 's/^/        /'
    local fails; fails=$(grep -ac '\[FAIL\]' "$log")
    FAILS=$((FAILS + fails))
}

FAILS=0
echo "=== x86_64（原生执行）==="
for c in $X86_COMBOS; do run_one "$c" ""; done
echo
echo "=== aarch64（qemu-user 模拟）==="
for c in $A64_COMBOS; do
    case "$c" in
        *-musl-*) run_one "$c" "$QEMU" "$HOST/prefix-musl" ;;
        *)        run_one "$c" "$QEMU" "$HOST/prefix-glibc" ;;
    esac
done
echo
if [ "$FAILS" -eq 0 ]; then
    echo "✅ 9 个组合本地全过（0 FAIL；SKIP 表示"这一项本地不适用/没验成"，见各日志）"
else
    echo "❌ 共 $FAILS 条 FAIL，日志在 $OUTD/"
    exit 1
fi
