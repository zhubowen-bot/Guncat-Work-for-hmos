#!/bin/bash
# build_testprogs.sh — 编 8 个「同一份源码 × 不同 ABI」的验收程序，打成一个 tar 进 rawfiles
#
# 组合矩阵（只做 64 位）：
#
#   arch     libc    链接      工具链                       运行时走谁
#   ------   -----   ------   --------------------------   --------------------------------
#   x86_64   glibc   dynamic  宿主 gcc -m64                box64（box64 自己模拟 glibc）
#   x86_64   glibc   static   宿主 gcc -m64 -static         box64
#   x86_64   musl    dynamic  x86_64-linux-musl-gcc        box64（wrappedlibcmusl.c）
#   x86_64   musl    static   同上 + -static               box64
#   aarch64  musl    dynamic  aarch64-linux-musl-gcc       elfloader（同 ISA 直跳）
#   aarch64  musl    static   同上 + -static-pie           elfloader
#   aarch64  glibc   dynamic  宿主 aarch64-linux-gnu-gcc   elfloader + bundle 里自编的 glibc
#   aarch64  glibc   static   同上 + -static               elfloader（自带 libc，不需要运行时）
#
# 每个组合编三个文件（都在 testprogs/ 下）：
#   <combo>                 主验收程序（全套用例，见 main.c）
#   libtgreet-<combo>.so    配套共享库（greet() 返回 42）—— dlopen 与"exec 依赖 .so 的
#                           ELF"两条路都要用它
#   dlhost-<combo>          动态链接上面那个库的小程序（DT_NEEDED），供 exec 用例
#                           ★ 即使是 static 组合，这两个也**动态**编：它们自己就是
#                             "动态链接"的样本，静态编出来就没意义了。
#
# 产物：
#   1) feature/bsh_main/src/main/resources/rawfile/tools/testprogs.tar（顶层目录名 testprogs/）；
#      首次启动由 shell.cpp 的 initResource() 解到 $HOME/testprogs。
#   2) feature/bsh_main/libs/arm64-v8a/ld-musl-aarch64.so.1 —— aarch64 musl 动态那只的解释器，
#      随 HAP 进 bundle libs（procmgr 只从那里按 basename 找解释器）。
#      aarch64 glibc 动态那只要的解释器与 libc 由 build_glibc.sh 装进同一个目录。
#
# 用法：./scripts/build_testprogs.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

SRC="$ROOT/feature/bsh_main/src/main/cpp/programs/testx64/main.c"
LIB_SRC="$ROOT/feature/bsh_main/src/main/cpp/programs/testx64/greet.c"
HOST_SRC="$ROOT/feature/bsh_main/src/main/cpp/programs/testx64/dlhost.c"
STAGE="$ROOT/build/testprogs"
PKG="$STAGE/testprogs"
OUT="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/testprogs.tar"
HAP_LIBS_DIR="$ROOT/feature/bsh_main/libs/arm64-v8a"

# 公共编译参数。刻意不带 -g：这些 elf 要打进 HAP，调试信息在设备上没用却让包变大。
CFLAGS_COMMON="-O2 -Wall -Wextra -Wno-unused-parameter -Wno-unused-result"
LDLIBS_COMMON="-lpthread -lm"

COMBOS="x86_64-glibc-dynamic x86_64-glibc-static \
        x86_64-musl-dynamic  x86_64-musl-static \
        aarch64-musl-dynamic aarch64-musl-static \
        aarch64-glibc-dynamic aarch64-glibc-static \
        aarch64-glibc-dynamic-nopie"

# ── 工具链 ────────────────────────────────────────────────
# 1) x86_64 glibc：宿主就是 x86_64 + glibc，直接用系统 gcc（带 -m64 明确位宽）
HOST_GCC="gcc -m64"
# 2) x86_64 musl：musl.cc 的交叉工具链，按需下载到 thirdparty/（已 gitignore）
X86_64_MUSL_TC="${X86_64_MUSL_TOOLCHAIN:-$ROOT/thirdparty/x86_64-linux-musl-cross}"
# 3) aarch64 musl：与 build_sysroot.sh 用同一套（默认指向 ElfLoaderDemo 里那份）
AARCH64_MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
# 4) aarch64 glibc：宿主自带的交叉 gcc（和 build_glibc.sh 编运行时用的是同一个 ——
#    它俩版本必须对得上：宿主交叉 glibc 是 2.39，我们自编的运行时也是 2.39，
#    否则动态那只会在运行期报 "version `GLIBC_2.xx' not found"）。
AARCH64_GLIBC_CC="${AARCH64_GLIBC_CC:-aarch64-linux-gnu-gcc}"

if [ ! -x "$X86_64_MUSL_TC/bin/x86_64-linux-musl-gcc" ]; then
    TGZ="$ROOT/thirdparty/x86_64-linux-musl-cross.tgz"
    URL="https://musl.cc/x86_64-linux-musl-cross.tgz"
    mkdir -p "$ROOT/thirdparty"
    # 这份压缩包 ~108MB，走宿主机代理实测会被中途掐断（curl 18: transfer closed
    # with N bytes remaining），所以必须能断点续传、并且失败了自动接着续。
    # 已经下全了就跳过：curl -C - 对"已完整"的文件会拿到 416 而报错，
    # 下面那个重试循环会空转 12 次再失败，所以先判一次完整性。
    if [ -f "$TGZ" ] && tar -tzf "$TGZ" >/dev/null 2>&1; then
        log "已有完整的压缩包，跳过下载：$TGZ"
    else
        log "下载 x86_64 musl 交叉工具链（musl.cc，约 108MB，支持续传）"
        n=0
        while :; do
            n=$((n + 1))
            if curl -L -C - --connect-timeout 20 --max-time 1800 -sS "$URL" -o "$TGZ"; then
                break
            fi
            [ "$n" -ge 12 ] && err "连续 $n 次下载失败（可删掉 $TGZ 重跑，或手动下载后放到该路径）"
            log "下载中断，续传重试（第 $n 次，已收到 $(du -h "$TGZ" 2>/dev/null | cut -f1)）"
            sleep 3
        done
    fi
    # 完整性自检：半截的压缩包解出来是残的，宁可在这里就停
    tar -tzf "$TGZ" >/dev/null 2>&1 || err "压缩包不完整或损坏：$TGZ（删掉它重跑）"
    tar -xzf "$TGZ" -C "$ROOT/thirdparty" || err "解压 $TGZ 失败"
fi
X86_64_MUSL_CC="$X86_64_MUSL_TC/bin/x86_64-linux-musl-gcc"
AARCH64_MUSL_CC="$AARCH64_MUSL_TC/bin/aarch64-linux-musl-gcc"

[ -f "$SRC" ] || err "缺源码：$SRC"
[ -f "$LIB_SRC" ] || err "缺源码：$LIB_SRC"
[ -f "$HOST_SRC" ] || err "缺源码：$HOST_SRC"
[ -x "$X86_64_MUSL_CC" ] || err "缺工具链：$X86_64_MUSL_CC"
[ -x "$AARCH64_MUSL_CC" ] || err "缺工具链：$AARCH64_MUSL_CC（设 MUSL_TOOLCHAIN）"
command -v "${AARCH64_GLIBC_CC%% *}" >/dev/null || err "缺工具链：$AARCH64_GLIBC_CC（apt install gcc-aarch64-linux-gnu）"

READELF="$CLANG_DIR/llvm-readelf"
[ -x "$READELF" ] || READELF="readelf"

rm -rf "$STAGE"
mkdir -p "$PKG"

# 组合名 → 编译器
cc_for() {
    case "$1" in
        x86_64-glibc-*)  echo "$HOST_GCC" ;;
        x86_64-musl-*)   echo "$X86_64_MUSL_CC" ;;
        aarch64-musl-*)  echo "$AARCH64_MUSL_CC" ;;
        aarch64-glibc-*) echo "$AARCH64_GLIBC_CC" ;;
        *) err "不认识的组合：$1" ;;
    esac
}

# 静态那几只用什么 flag。为什么 aarch64-musl 用 -static-pie 而不是 -static：
# musl 的 -static 在 aarch64 上给 ET_EXEC，而我们的执行者对 ET_EXEC 与 ET_DYN(PIE)
# 是两条不同的装载路径（前者固定基址、后者要重定位），一直用 -static-pie 是为了
# 让"静态"这一格顺带覆盖 PIE 那条路；glibc 的 -static 给 ET_EXEC，正好覆盖另一条。
static_flags_for() {
    case "$1" in
        aarch64-musl-static) echo "-static-pie" ;;
        *-static)            echo "-static" ;;
        *)                   echo "" ;;
    esac
}

# ── 1) 编译 9 组 × 3 个文件 ────────────────────────────────
log "=== 1) 编译 9 个组合（每组：主程序 + 配套 so + dlhost） → $PKG ==="
for combo in $COMBOS; do
    cc=$(cc_for "$combo")
    case "$combo" in
        *-dynamic)        extra="";          is_static=0 ;;
        # -no-pie：动态但**非 PIE**（ET_EXEC + PT_INTERP）。这一格是给"内核遇到
        #   ET_EXEC + PT_INTERP 也要先起解释器"这条语义加回归用的 —— 官方发行的大号
        #   二进制（kimi-code、SDK 的 cmake）大多是这种，曾经被我们判成静态 guest
        #   直接跳 _start，GOT 全 0，一进去 pc=0。
        *-dynamic-nopie)  extra="-no-pie";   is_static=0 ;;
        *-static)         extra=$(static_flags_for "$combo"); is_static=1 ;;
    esac
    log "  [BUILD] $combo   ($cc $extra)"

    # 主程序：-DBSH_TEST_COMBO 让程序知道自己是哪一种（打印用），
    # -DBSH_TEST_STATIC 让 dlopen 那条在静态组合上按"已知限制"处理而不是记 FAIL。
    if ! $cc $CFLAGS_COMMON $extra \
             -DBSH_TEST_COMBO="\"$combo\"" -DBSH_TEST_STATIC=$is_static \
             "$SRC" -o "$PKG/$combo" $LDLIBS_COMMON > "$STAGE/$combo.log" 2>&1; then
        tail -20 "$STAGE/$combo.log" >&2
        err "$combo 编译失败（日志 $STAGE/$combo.log）"
    fi

    # 配套 .so：**永远动态编**（.so 本身就是动态的东西）。显式给 -soname，
    # 否则链接 dlhost 时会把"链接期的文件名"写进 DT_NEEDED，运行期就找不到了。
    if ! $cc $CFLAGS_COMMON -shared -fPIC -Wl,-soname,libtgreet-$combo.so \
             "$LIB_SRC" -o "$PKG/libtgreet-$combo.so" > "$STAGE/$combo.so.log" 2>&1; then
        tail -20 "$STAGE/$combo.so.log" >&2
        err "libtgreet-$combo.so 编译失败"
    fi

    # dlhost：链接期把库写进 DT_NEEDED，运行期由 guest 的动态链接器装载。
    # RPATH=$ORIGIN 是兜底（库就在同一个目录），正常情况下由父进程设的
    # LD_LIBRARY_PATH 找到 —— 两条都能找到才算"动态链接器被配置对了"。
    if ! $cc $CFLAGS_COMMON -DBSH_TEST_COMBO="\"$combo\"" \
             "$HOST_SRC" -o "$PKG/dlhost-$combo" \
             -L"$PKG" -ltgreet-$combo -Wl,-rpath,'$ORIGIN' $LDLIBS_COMMON \
             > "$STAGE/$combo.dlhost.log" 2>&1; then
        tail -20 "$STAGE/$combo.dlhost.log" >&2
        err "dlhost-$combo 编译失败"
    fi
done

# aarch64 动态那只的加载器：musl 的 libc.so 同时就是它的动态链接器（ld-musl）。
# procmgr 读 PT_INTERP 拿到 /lib/ld-musl-aarch64.so.1，再按 **basename** 在 bundle
# libs 找（procmgr.cpp 的 ChildRunElf，唯一来源）。
#
# 这份**不再从这里拷**：改由 scripts/build_musl.sh 的 install 阶段交付 —— 那是我们
# 自编的"不做文件映射"版（原厂那份用文件映射加载 .so，在沙箱里 dlopen 必然失败）。
# 这里只做存在性检查并给出该跑哪条命令，免得有人以为本脚本会顺手把它接上。
if [ ! -f "$HAP_LIBS_DIR/ld-musl-aarch64.so.1" ]; then
    err "缺 $HAP_LIBS_DIR/ld-musl-aarch64.so.1 —— 先跑 scripts/build_musl.sh install"
fi
log "musl 加载器（已由 build_musl.sh 交付）：$HAP_LIBS_DIR/ld-musl-aarch64.so.1"

# ── 1b) /proc/self/exe 自测（只做 aarch64 动态这两只）────────────────────────
# 它测的是 guest 侧 shim 里"BSH_GUEST_EXE 替身"那一层（见 shim/fs_shim.c 与
# shim/README.md）。替身靠 LD_PRELOAD 生效，所以静态组合、以及跨 ISA 的 x86 组合
# （box64/qemu 自己模拟 syscall）都吃不到 —— 编出来只会得到一排"已知不支持"的
# FAIL，反而干扰判读。故只编这两只。
SELFEXE_SRC="$ROOT/feature/bsh_main/src/main/cpp/programs/selfexe/main.c"
SELFEXE_COMBOS="aarch64-musl-dynamic aarch64-glibc-dynamic"
log "=== 1b) /proc/self/exe 自测（aarch64 动态 ×2）→ $PKG ==="
[ -f "$SELFEXE_SRC" ] || err "缺源码：$SELFEXE_SRC"
for combo in $SELFEXE_COMBOS; do
    cc=$(cc_for "$combo")
    log "  [BUILD] selfexe-$combo   ($cc)"
    if ! $cc $CFLAGS_COMMON -DBSH_TEST_COMBO="\"$combo\"" \
             "$SELFEXE_SRC" -o "$PKG/selfexe-$combo" $LDLIBS_COMMON \
             > "$STAGE/selfexe-$combo.log" 2>&1; then
        tail -20 "$STAGE/selfexe-$combo.log" >&2
        err "selfexe-$combo 编译失败（日志 $STAGE/selfexe-$combo.log）"
    fi
done

# ── 2) 自检 ─────────────────────────────────────────────────
# 每只都要和它名字声称的一致：dynamic 必须有 PT_INTERP，static 必须没有；
# 配套 .so 要有 -soname，dlhost 的 DT_NEEDED 里要有它。
# 走临时文件而非管道：set -o pipefail 下 grep -q 提前关管道会 SIGPIPE 误报。
log "=== 2) 自检（名字声称的链接方式 vs ELF 实际；配套 so/dlhost 的链接关系）==="
printf '    %-22s %-8s %-9s %-8s %s\n' "组合" "类型" "INTERP" "大小" "加载器" >&2
for combo in $COMBOS; do
    f="$PKG/$combo"
    [ -f "$f" ] || err "缺产物 $combo"
    "$READELF" -h "$f" > "$STAGE/.h" || err "readelf 失败: $combo"
    "$READELF" -l "$f" > "$STAGE/.l" || err "readelf -l 失败: $combo"
    etype=$(sed -n 's/.*Type: *\([A-Z_]*\).*/\1/p' "$STAGE/.h" | head -1)
    interp=$(sed -n 's/.*Requesting program interpreter: *\(.*\)\]/\1/p' "$STAGE/.l" | head -1)
    case "$combo" in
        *-dynamic) [ -n "$interp" ] || err "$combo 名为 dynamic 但没有 PT_INTERP" ;;
        # 这一格的要点就是"类型不能是 DYN"：否则它和 aarch64-glibc-dynamic 是同一件事，
        # 那条 ET_EXEC 的装载路径就没人覆盖了。
        *-dynamic-nopie)
            [ -n "$interp" ] || err "$combo 名为 dynamic-nopie 但没有 PT_INTERP"
            [ "$etype" = "EXEC" ] || err "$combo 名为 dynamic-nopie 但不是 ET_EXEC（得到 $etype）" ;;
        *-static)  [ -z "$interp" ] || err "$combo 名为 static 却有 PT_INTERP: $interp" ;;
    esac

    # 配套 so：必须有 SONAME，且与文件名一致
    "$READELF" -d "$PKG/libtgreet-$combo.so" > "$STAGE/.d" || err "readelf -d so 失败: $combo"
    grep -q "SONAME.*libtgreet-$combo.so" "$STAGE/.d" \
        || err "libtgreet-$combo.so 缺 -soname（dlhost 运行期会找不到它）"

    # dlhost：DT_NEEDED 必须指向那个 so（而不是链接期的绝对路径）
    "$READELF" -d "$PKG/dlhost-$combo" > "$STAGE/.d2" || err "readelf -d dlhost 失败: $combo"
    grep -q "NEEDED.*\blibtgreet-$combo.so\b" "$STAGE/.d2" \
        || { grep -E "NEEDED" "$STAGE/.d2" >&2; err "dlhost-$combo 的 DT_NEEDED 不对"; }

    printf '    %-22s %-8s %-9s %-8s %s\n' \
        "$combo" "$etype" "${interp:+有}" "$(du -h "$f" | cut -f1)" "${interp:-—}" >&2
done
rm -f "$STAGE/.h" "$STAGE/.l" "$STAGE/.d" "$STAGE/.d2"

# 1b) 那两只自测程序：名字里的 -dynamic 必须名副其实（有 PT_INTERP，shim 才装得上）
for combo in $SELFEXE_COMBOS; do
    f="$PKG/selfexe-$combo"
    [ -f "$f" ] || err "缺产物 selfexe-$combo"
    "$READELF" -l "$f" > "$STAGE/.l" || err "readelf -l 失败: selfexe-$combo"
    grep -q "Requesting program interpreter" "$STAGE/.l" \
        || err "selfexe-$combo 没有 PT_INTERP（LD_PRELOAD shim 装不上，替身不会生效）"
done
rm -f "$STAGE/.l"

# ── 3) 打包 ─────────────────────────────────────────────────
log "=== 3) 打包 → $OUT ==="
rm -f "$OUT"
# 顶层目录名就是 testprogs/，与 xkb.tar / weston-data.tar 的做法一致，
# 于是 initResource 把 dest 给 $HOME 即可。
( cd "$STAGE" && tar -cf "$OUT" testprogs )
log "✅ $OUT（$(du -h "$OUT" | cut -f1)，$(tar -tf "$OUT" | grep -c . ) 个成员）"

log "解到设备后（initResource 会做）在终端里这样跑："
log "  cd \$HOME/testprogs"
log "  ./x86_64-glibc-dynamic      # 前四个是 x86_64，procmgr 按 e_machine 自动走 box64"
log "  ./x86_64-glibc-static"
log "  ./x86_64-musl-dynamic"
log "  ./x86_64-musl-static"
log "  ./aarch64-musl-dynamic      # 后四个是 aarch64，走 elfloader"
log "  ./aarch64-musl-static"
log "  ./aarch64-glibc-dynamic     # 解释器/libc 来自 bundle 里自编的 glibc"
log "  ./aarch64-glibc-static"
log "  ./aarch64-glibc-dynamic-nopie   # 动态但非 PIE(ET_EXEC + PT_INTERP),官方发行二进制的形态"
log "  ./selfexe-aarch64-musl-dynamic   # /proc/self/exe 自测（替身只在动态 guest 上生效）"
log "  ./selfexe-aarch64-glibc-dynamic"
log "（想单独跑某一项：./<combo> --child 只打印身份并退出 42，是 exec 用例的子模式）"
