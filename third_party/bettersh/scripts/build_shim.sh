#!/bin/bash
# build_shim.sh — 编**guest 侧**的 preload shim（`feature/bsh_main/src/main/cpp/shim/`）
#
# 背景：沙箱缺了几样本该有的东西（禁止 symlink、拿不到 ptmx、guest 看不到 tty、
# guest 不能 exec）。命令 so 是靠"把 shim 编进自己"（链接期 + -Bsymbolic-functions）
# 拿到这些能力的；**guest 是别人的二进制，只能预载** —— 于是把同一套拦截做成独立的
# .so，由 procmgr 按 guest 的解释器挑对应 libc 那份、设成 LD_PRELOAD
# （见 procmgr.cpp 的 ChildRunElf）。
#
# 模块（都在 feature/bsh_main/src/main/cpp/shim/）：
#   tty_shim.c   isatty/tcgetattr/tcsetattr/ioctl/fcntl/open("/dev/tty") 的软 tty 语义
#   fs_shim.c    符号链接的用户态模拟（.BSH_SYMLINK 表示法）
#   pty_shim.c   假 pts（socketpair 当 master/slave；要 BSH_FAKE_PTY 才启用）
#   exec_shim.c  exec 委托（拦 execve/execv/execvp/…/posix_spawn，转给 procmgr；
#                要 BSH_EXEC_SHIM 才启用）
#   open_shim.c  tty 与 fs 两个模块都接管 open，这里是**唯一**入口（先 /dev/tty 钩子、
#                再做软链解析）—— 两边各自把定义让出去（-DBSH_SHIM_MERGED_OPEN）
#   compat_shim.c 补我们那份 musl(1.2.2)还没有、而现代二进制会引用的 libc 符号
#                （backtrace / pthread_getname_np / renameat2 / pthread_cond_clockwait…）。
#                **只编进 musl 那份**：glibc 自己就有,补上去会遮蔽真实现。
#   crash_reporter.c  guest 崩了就把 pc/lr/fpwalk 打到自己的 stderr（没有调试器时唯一
#                拿得到证据的路子）。**两份都要编** —— 它原来长在 compat_shim.c 里，
#                于是只对 musl guest 生效；实测 `code`(glibc guest) 静默退出时
#                一条 [crash] 都没有，正是这个原因。
#
# ⚠ 要编**两份**：musl 的 .so 和 glibc 的 .so **不能互换**（libc ABI、以及 musl 的 ld
#   只认 musl 的 .so）。挑哪份由 guest 的 PT_INTERP 决定：
#     /lib/ld-musl-aarch64.so.1   → libbshguest-musl.so
#     /lib/ld-linux-aarch64.so.1  → libbshguest-glibc.so
#   两份都随 HAP 进 bundle libs（LD_PRELOAD 写绝对路径，加载走我们补过的"匿名装载"）。
#
# 静态链接的 guest 吃不到（LD_PRELOAD 对静态无效）—— 这轮明确不管。
#
# 用法：./scripts/build_shim.sh [build|install|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"
CPP_DIR="$ROOT/feature/bsh_main/src/main/cpp"
SHIM_DIR="$CPP_DIR/shim"
OUT_DIR="$ROOT/build/shim"
HAP_LIBS_DIR="$ROOT/feature/bsh_main/libs/arm64-v8a"

TTY_SRC="$SHIM_DIR/tty_shim.c"
CLIENT_SRC="$CPP_DIR/procmgr/bsh_client.c"
FS_SRC="$SHIM_DIR/fs_shim.c"
PTY_SRC="$SHIM_DIR/pty_shim.c"
EXEC_SRC="$SHIM_DIR/exec_shim.c"
OPEN_SRC="$SHIM_DIR/open_shim.c"
COMPAT_SRC="$SHIM_DIR/compat_shim.c"   # 只进 musl 那份(见 do_build 里的说明)
CRASH_SRC="$SHIM_DIR/crash_reporter.c" # 两份都要(见文件头)
NETIF_SRC="$SHIM_DIR/netif_shim.c"         # getifaddrs 兜底（沙箱无 netlink raw socket）
TRACE_SRC="$SHIM_DIR/trace_shim.c"     # 系统调用打点(只记失败的);要 BSH_TRACE_SYS=1
LATECRASH_SRC="$SHIM_DIR/latecrash_shim.c" # 迟到安装的致命信号处理器；**要 BSH_LATECRASH=1 才启用**
# ⚠ xkbpath_shim.c 不并进来：它拦的入口(stat/lstat/access/faccessat/open/openat/opendir)
#    与 fs_shim.c 完全重叠，直接加会重复定义。它的路径映射要折进 fs_shim 的入口。

AARCH64_MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
MUSL_CC="$AARCH64_MUSL_TC/bin/aarch64-linux-musl-gcc"
GLIBC_CC="${AARCH64_GLIBC_CC:-aarch64-linux-gnu-gcc}"

CFLAGS="-O2 -Wall -Wextra -Wno-unused-parameter -fPIC"
LDLIBS="-ldl -lpthread"

do_build() {
    for f in "$TTY_SRC" "$CLIENT_SRC" "$FS_SRC" "$PTY_SRC" "$EXEC_SRC" "$OPEN_SRC" "$COMPAT_SRC" "$CRASH_SRC" "$NETIF_SRC" "$LATECRASH_SRC" "$TRACE_SRC"; do
        [ -f "$f" ] || err "缺源码：$f"
    done
    [ -x "$MUSL_CC" ] || err "缺工具链：$MUSL_CC（设 MUSL_TOOLCHAIN）"
    command -v "$GLIBC_CC" >/dev/null || err "缺工具链：$GLIBC_CC（apt install gcc-aarch64-linux-gnu）"

    # tty/fs/exec 三个模块都要接管 open 或 exec 家族，一个 .so 只能有一份定义：
    # -DBSH_SHIM_MERGED_OPEN 让 tty_shim.c 与 fs_shim.c 的 open 让位给 open_shim.c。
    local srcs=("$TTY_SRC" "$CLIENT_SRC" "$FS_SRC" "$PTY_SRC" "$EXEC_SRC" "$OPEN_SRC" "$CRASH_SRC" "$NETIF_SRC" "$LATECRASH_SRC" "$TRACE_SRC")
    local defs="-DBSH_SHIM_MERGED_OPEN"
    log "源码：$(basename -a "${srcs[@]}" | tr '\n' ' ')（合并 open）"

    mkdir -p "$OUT_DIR"
    local soc cc
    for v in musl glibc; do
        if [ "$v" = musl ]; then soc="libbshguest-musl.so"; cc="$MUSL_CC"; else soc="libbshguest-glibc.so"; cc="$GLIBC_CC"; fi
        # compat_shim.c 只进 musl 那份：glibc 自己就有 backtrace/renameat2/… 补上去会遮蔽真的
        local use=("${srcs[@]}")
        [ "$v" = musl ] && use+=("$COMPAT_SRC")
        log "编译 $soc（$cc）"
        # -I procmgr：tty_shim.c / exec_shim.c 都要 include bsh_client.h
        "$cc" $CFLAGS $defs -I"$SHIM_DIR" -I"$CPP_DIR/procmgr" -shared -Wl,-soname,"$soc" \
            "${use[@]}" -o "$OUT_DIR/$soc" $LDLIBS \
            > "$OUT_DIR/$soc.log" 2>&1 || { tail -20 "$OUT_DIR/$soc.log" >&2; err "$soc 编译失败"; }
        file "$OUT_DIR/$soc" | sed 's/^/    /'
    done

    # 自检：被预载的入口确实导出了。
    # ⚠ 走临时文件而不是管道：env.sh 开着 `set -o pipefail`，`readelf | grep -q` 里
    #   grep 一找到就退出，readelf 拿到 SIGPIPE(141) → 整条管道判失败，于是**明明
    #   有符号也报"没导出"**（本仓库在 build_testprogs.sh / glibc-ohos / musl-ohos
    #   都踩过同一个坑）。
    local re="$CLANG_DIR/llvm-readelf"; [ -x "$re" ] || re="readelf"
    local syms="$OUT_DIR/.syms"
    for v in musl glibc; do
        local so
        if [ "$v" = musl ]; then so="$OUT_DIR/libbshguest-musl.so"; else so="$OUT_DIR/libbshguest-glibc.so"; fi
        "$re" --dyn-syms "$so" > "$syms" 2>/dev/null || err "readelf 失败：$so"
        for sym in isatty tcgetattr tcsetattr ioctl open fcntl read write readv writev \
                   symlink readlink lstat unlink opendir readdir \
                   grantpt unlockpt ptsname posix_openpt openpty forkpty \
                   execve execv execvp execvpe execl execlp posix_spawn posix_spawnp; do
            grep -q " $sym\$" "$syms" || err "$so 没导出 $sym（预载就不生效了）"
        done
        if [ "$v" = musl ]; then
            # compat_shim 的四个代表符号:少了它们,现代二进制(如 Qt)会在加载期就报
            # symbol not found
            for sym in renameat2 pthread_getname_np pthread_cond_clockwait backtrace; do
                grep -q " $sym\$" "$syms" || err "$so 没导出 $sym（compat_shim.c 没编进去？）"
            done
        fi
        # 反向的一道闸：shim 里**不该有未定义的自家符号**。跨文件误用 static 帮助函数
        # 在编译期只是警告，链接期留下未定义符号，直到 dlopen 才炸 —— 而那时报的是
        # "某个命令用不了"（实测踩过：tty_shim 用了 pty_shim 的 static bsh_null，
        # libmksh.so 直接 dlopen 失败，终端里连 sh 都起不来）。
        local undef
        # ⚠ 末尾的 `|| true` 不能省：本仓库开着 pipefail，最后一个 grep 没匹配到就整条
        #   管道失败，set -e 会让脚本**静默退出**（本仓库在好几处踩过同一个坑）。
        undef="$(grep -E ' UND ' "$syms" | awk '{print $NF}' | grep -E '^bsh_' | sort -u | tr '\n' ' ' || true)"
        [ -z "$undef" ] || err "$so 有未定义的自家符号：$undef"
    done
    rm -f "$syms"
    log "自检：两份都导出了 tty/fs/pty/exec 四组入口，且没有未定义的自家符号"
    log "产物：$OUT_DIR"
}

do_install() {
    [ -f "$OUT_DIR/libbshguest-musl.so" ] || err "先跑 build"
    mkdir -p "$HAP_LIBS_DIR"
    cp -f "$OUT_DIR/libbshguest-musl.so" "$OUT_DIR/libbshguest-glibc.so" "$HAP_LIBS_DIR/"
    chmod 755 "$HAP_LIBS_DIR"/libbshguest-*.so
    log "已装进 bundle libs：$HAP_LIBS_DIR/libbshguest-{musl,glibc}.so"
    log "（procmgr 会按 guest 的 PT_INTERP 挑对应那份设成 LD_PRELOAD）"
}

case "$PHASE" in
    build)   do_build ;;
    install) do_install ;;
    all)     do_build; do_install ;;
    *)       err "未知阶段：$PHASE（可用：build|install|all）" ;;
esac
