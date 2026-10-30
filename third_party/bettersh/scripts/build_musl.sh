#!/bin/bash
# build_musl.sh — 给 aarch64 交叉编一份"不做文件映射"的 musl 1.2.2 动态加载器
#
# 目标产物(见 install 阶段):
#     build/musl/out/lib/ld-musl-aarch64.so.1   (外加 libc.so → 它的相对软链)
# musl 的 libc.so **本身就是**它的动态链接器(同一个文件),所以"改 musl 的加载器"
# 就是改 ldso/dynlink.c 的 map_library():把库段从"file mmap"换成
# "匿名预留 → pread 读入 → mprotect 给权限",和 feature/bsh_main/src/main/cpp/elfloader 装
# guest 的做法一致。起因是这台 HarmonyOS 设备的沙箱:把"非系统文件当可执行体"
# (execve / file-backed 的可执行 mmap)交给 seccomp 用户态通知处理 —— 表现就是
# "是否运行 xxx"确认框;用户拒绝 = EACCES/EPERM = musl 报
# "Error loading shared library ...: Permission denied / Operation not permitted"。
# 细节与踩过的坑见 scripts/musl-ohos/README.md。
#
# 版本为什么钉 1.2.2:设备上 aarch64 动态 guest 的解释器以前是从工具链
# (ElfLoaderDemo/tools/aarch64-linux-musl-cross,musl.cc 2021-11-23)拷来的原厂
# libc.so,它自报 "1.2.2-git-50-gb76f37fd" —— 就是 1.2.2 之后的第 50 个 git 提交。
# musl 不做符号版本化,1.2.2 的 release tarball 与它 ABI 兼容(musl.libc.org 的
# release tarball 最稳,而且能钉 sha256);编完 install 阶段会和工具链那份对一遍
# 导出的动态符号,少东西就告警。
#
# 阶段:src | patch | configure | build | install | pack | all
#   每个阶段幂等,可单独重跑;源码在 build/musl/musl-1.2.2,构建在 build/musl/b
#   (musl 的 configure 支持 out-of-tree:会在 b/ 里生成 config.mak 并软链 Makefile)。
#   install = 唯一产物动作:挑出 lib/libc.so 当 ld-musl-aarch64.so.1 放进 out/lib,
#             **并交付到 bundle libs**(feature/bsh_main/libs/arm64-v8a/,随 HAP 走;设备侧的唯一来源,
#             它会替换掉原来从工具链拷来的原厂那份)。
#   pack    = 按需:把 out/lib 摆成一份 qemu 的 LD_PREFIX 形状并打 tar
#             (build/musl/prefix/,build/musl/musl-ohos-prefix.tar),方便复跑验证。
#
# 用法:./scripts/build_musl.sh [src|patch|configure|build|install|pack|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"

# ── 版本 / 校验 ────────────────────────────────────────────
MUSL_VER="1.2.2"
MUSL_TGZ="$ROOT/thirdparty/musl-${MUSL_VER}.tar.gz"
MUSL_SHA256="9b969322012d796dc23dda27a35866034fa67d8fb67e0e2c45c913c3d43219dd"
MUSL_URL="https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz"

# ── 目录 ───────────────────────────────────────────────────
MUSL_BUILD="$ROOT/build/musl"
MUSL_SRC="$MUSL_BUILD/musl-${MUSL_VER}"
MUSL_OBJ="$MUSL_BUILD/b"
MUSL_OUT="$MUSL_BUILD/out"                  # 交付根:$MUSL_OUT/lib/ld-musl-aarch64.so.1
PATCH_DIR="$SCRIPT_DIR/musl-ohos/patches"

# ── 工具链 ─────────────────────────────────────────────────
# 用**工具链自带的那份 aarch64-linux-musl-gcc** 去编 musl 本身(自举):它本来就是
# 为 musl 目标配的 GCC 11.2.1,产物是纯 aarch64-linux-musl ABI,和设备只认 ABI 的
# 口径一致;顺带保证"编出来的 libc.so 和工具链链接期依赖的东西同源"。
MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
MUSL_CC="${MUSL_CC:-$MUSL_TC/bin/aarch64-linux-musl-gcc}"
CROSS_COMPILE="aarch64-linux-musl-"
# musl 的 Makefile 直接用 $(CROSS_COMPILE)ar、$(CROSS_COMPILE)ranlib……,PATH 里得
# 能找到它们(不然 make 到 libm.a 就 "aarch64-linux-musl-ar: No such file")。
export PATH="$MUSL_TC/bin:$PATH"

mkdir -p "$MUSL_BUILD"

# ══════════════════════════════════════════════════════════════════
# src:下载 + 校验 + 解包
# ══════════════════════════════════════════════════════════════════
do_src() {
    mkdir -p "$ROOT/thirdparty"
    if [ -f "$MUSL_TGZ" ] && echo "$MUSL_SHA256  $MUSL_TGZ" | sha256sum -c --quiet 2>/dev/null; then
        log "已有校验通过的压缩包:$MUSL_TGZ"
    else
        log "下载 musl ${MUSL_VER}($(basename "$MUSL_URL"))"
        curl -L -C - --connect-timeout 20 --max-time 1800 -sS "$MUSL_URL" -o "$MUSL_TGZ"
        echo "$MUSL_SHA256  $MUSL_TGZ" | sha256sum -c - \
            || err "sha256 不匹配(删掉 $MUSL_TGZ 重试)"
    fi
    if [ ! -d "$MUSL_SRC" ]; then
        log "解包 → $MUSL_SRC"
        tar -xzf "$MUSL_TGZ" -C "$MUSL_BUILD"
    fi
    # 和工具链那份对个版本:1.2.2 release 与 1.2.2-git-* 的 ABI 兼容,mismatch 只提醒
    if [ -f "$MUSL_TC/aarch64-linux-musl/lib/libc.so" ]; then
        local tcver
        tcver=$(strings -a "$MUSL_TC/aarch64-linux-musl/lib/libc.so" \
                | grep -m1 -oE '^1\.2\.[0-9]+(-git[^ ]*)?$' || true)
        [ -n "$tcver" ] && log "工具链自带的 musl 版本:$tcver(我们编 $MUSL_VER)"
    fi
}

# ══════════════════════════════════════════════════════════════════
# patch:打我们自己的改动(幂等;已经打过就跳过)
# ══════════════════════════════════════════════════════════════════
do_patch() {
    [ -d "$MUSL_SRC" ] || err "源码不在 $MUSL_SRC(先跑 src)"
    local p
    for p in "$PATCH_DIR"/*.patch; do
        [ -e "$p" ] || continue
        if patch -p1 -d "$MUSL_SRC" --dry-run --silent < "$p" >/dev/null 2>&1; then
            log "打补丁:$(basename "$p")"
            patch -p1 -d "$MUSL_SRC" < "$p" >/dev/null
        elif patch -p1 -R -d "$MUSL_SRC" --dry-run --silent < "$p" >/dev/null 2>&1; then
            log "已是打过补丁的状态,跳过:$(basename "$p")"
        else
            err "补丁既不能正向也不能反向应用(源码被改过?):$p"
        fi
    done

    # 新增文件不走 patch：给 musl 补一个 **OHOS 私有的** `__fd_chk`。
    #
    # 为什么需要（2026-10-04 定位）：OHOS 的 `sys/select.h` **无条件**把 FD_SET/FD_CLR
    # 展开成 `__fd_chk(fd)`（它的越界检查）。用 OHOS SDK 头文件编出来的**任何东西**
    # —— make/ninja、cc-ohos 编的 node 原生扩展、pip 现场编的 C 扩展 —— 都会引它。
    # 动态链接期不查未定义符号，所以编译链接都过，**运行期才炸**：
    #     Error relocating make: __fd_chk: symbol not found
    # （实测 node-gyp 现场编原生扩展时 make 死在这一行。）
    # musl 的 Makefile 用 `$(wildcard src/*/*.c)`，新文件丢进源码树就会自动编进来；
    # musl 默认导出所有全局符号，所以放进 libc.so(= 我们的 ld-musl-aarch64.so.1) 里
    # 就能被所有 guest 看见。
    local fdchk="$MUSL_SRC/src/misc/__fd_chk.c"
    if [ ! -f "$fdchk" ]; then
        cat > "$fdchk" <<'FDCHK_EOF'
/* OHOS 的 musl 在 FD_SET/FD_CLR 里插的越界检查（见它的 sys/select.h）。
 * 我们是 vanilla musl 1.2.2，没有这个符号；补一个语义等价的实现：
 * fd 超出 [0, FD_SETSIZE) 就 abort —— 与 OHOS 的行为一致。 */
#include <sys/select.h>
#include <stdlib.h>

void __fd_chk(int fd)
{
	if (fd < 0 || fd >= FD_SETSIZE) abort();
}
FDCHK_EOF
        log "新增 src/misc/__fd_chk.c（OHOS FD_SET/FD_CLR 用的私有符号）"
    else
        log "__fd_chk.c 已在（跳过）"
    fi
}

# ══════════════════════════════════════════════════════════════════
# configure(out-of-tree;musl 会在构建目录里生成 config.mak + 软链 Makefile)
# ══════════════════════════════════════════════════════════════════
do_configure() {
    [ -d "$MUSL_SRC" ] || err "源码不在 $MUSL_SRC(先跑 src)"
    [ -x "$MUSL_CC" ] || err "缺交叉编译器:$MUSL_CC(可用 MUSL_TOOLCHAIN/MUSL_CC 覆盖)"
    rm -rf "$MUSL_OBJ"
    mkdir -p "$MUSL_OBJ"
    log "configure(CC=$MUSL_CC)"
    (
        cd "$MUSL_OBJ"
        # --syslibdir=/lib:解释器安装路径钉成 /lib/ld-musl-aarch64.so.1,与
        #   PT_INTERP 里写的路径一致(设备上 procmgr 按 basename 找)。
        # --disable-static:我们只要那份能当解释器用的 libc.so,不编 libc.a。
        CC="$MUSL_CC" CROSS_COMPILE="$CROSS_COMPILE" \
            "$MUSL_SRC/configure" \
                --target=aarch64-linux-musl \
                --prefix=/usr \
                --syslibdir=/lib \
                --disable-static
    )
}

# ══════════════════════════════════════════════════════════════════
# build
# ══════════════════════════════════════════════════════════════════
do_build() {
    [ -f "$MUSL_OBJ/config.mak" ] || err "还没 configure(先跑 configure)"
    log "make -j$JOBS(日志落在 $MUSL_BUILD/make.log)"
    # 只回显最后几行,而且截断 —— make 会把整条 libc.so 的链接命令行打出来(几千字符)
    (cd "$MUSL_OBJ" && make -j"$JOBS") 2>&1 | tee "$MUSL_BUILD/make.log" | tail -5 | cut -c1-160
    [ -f "$MUSL_OBJ/lib/libc.so" ] || err "make 结束但没有 lib/libc.so,看 $MUSL_BUILD/make.log"
}

# ══════════════════════════════════════════════════════════════════
# install:挑出要交付的那一个文件
# ══════════════════════════════════════════════════════════════════
# lib/libc.so 就是"libc + ldso"合体(gcc 显式 -Wl,-e,_dlstart),直接当
# ld-musl-aarch64.so.1 用;libc.so 再做个相对软链(工具链布局也是这个形状:
# lib/ld-musl-aarch64.so.1 -> /lib/libc.so)。
do_install() {
    local libc="$MUSL_OBJ/lib/libc.so"
    [ -f "$libc" ] || err "没有 $libc(先跑 build)"
    rm -rf "$MUSL_OUT"
    mkdir -p "$MUSL_OUT/lib"
    cp "$libc" "$MUSL_OUT/lib/ld-musl-aarch64.so.1"
    chmod 755 "$MUSL_OUT/lib/ld-musl-aarch64.so.1"
    ln -sf ld-musl-aarch64.so.1 "$MUSL_OUT/lib/libc.so"
    file "$MUSL_OUT/lib/ld-musl-aarch64.so.1" | sed 's/^/  /'
    log "加载器已就绪:$MUSL_OUT/lib"

    # ── 自检:它得能被当解释器用 ────────────────────────────────
    # 1) ET_DYN,入口非 0 且对着 _dlstart(ldso 的入口;它是 hidden 的,所以只在
    #    .symtab 里,不在 .dynsym);
    # 2) 导出 __libc_start_main / dlopen / dlsym(dlopen 那条路要有东西可调)。
    # 走临时文件而不是管道:env.sh 开了 set -o pipefail,`readelf | grep -q` 里
    # grep 提前退出会把 readelf 弄成 SIGPIPE(141),整条管道就"失败"了(踩过)。
    local syms="$MUSL_BUILD/.syms"
    readelf -sW "$MUSL_OUT/lib/ld-musl-aarch64.so.1" > "$syms" || err "readelf -s 失败"
    local typ entry
    typ=$(readelf -h "$MUSL_OUT/lib/ld-musl-aarch64.so.1" | sed -n 's/.*Type: *\([A-Z_]*\).*/\1/p')
    entry=$(readelf -h "$MUSL_OUT/lib/ld-musl-aarch64.so.1" | sed -n 's/.*Entry point address: *//p')
    [ "$typ" = "DYN" ] || err "新编的加载器不是 ET_DYN($typ)"
    grep -q " _dlstart$" "$syms" || err "加载器里没找到 _dlstart(不像 musl 的 ldso)"
    grep -q " __libc_start_main$" "$syms" || err "加载器里没找到 __libc_start_main(不像完整 libc)"
    grep -q " dlopen$" "$syms" || err "加载器里没导出 dlopen"
    grep -q " dlsym$" "$syms" || err "加载器里没导出 dlsym"
    printf '    %-24s %s\n' "类型/入口" "$typ @ $entry" >&2
    log "自检:ET_DYN,入口指向 _dlstart,导出 __libc_start_main/dlopen/dlsym"

    # ── 和工具链那份比一比对外的动态符号(1.2.2 release vs 1.2.2-git-50)───────
    # 只提醒不失败:musl 不做符号版本化,少的那几个如果不被工具链编出来的程序用到
    # 就没事(run_testprogs_host.sh 那 8 个组合会真的跑一遍给出定论)。
    local tclib="$MUSL_TC/aarch64-linux-musl/lib/libc.so"
    if [ -f "$tclib" ]; then
        local missing
        missing=$(comm -23 \
            <(nm -D --defined-only "$tclib" 2>/dev/null | awk '{print $NF}' | sort -u) \
            <(nm -D --defined-only "$MUSL_OUT/lib/ld-musl-aarch64.so.1" 2>/dev/null | awk '{print $NF}' | sort -u) \
            || true)
        if [ -z "$missing" ]; then
            log "符号对比:工具链那份导出的动态符号,我们这份一个不缺"
        else
            warn "工具链那份有、我们这份没有的动态符号(共 $(echo "$missing" | wc -l) 个):"
            echo "$missing" | sed 's/^/    /' >&2
        fi
    fi

    # ── 交付到 bundle libs(feature/bsh_main/libs/arm64-v8a/,随 HAP 打包) ──────────────
    # 与 build_glibc.sh 的 install 一个道理:**唯一**去处就是 bundle libs ——
    # procmgr 只从那里按 PT_INTERP 的 basename 找解释器(见 procmgr.cpp 的
    # ChildRunElf),放 $HOME 是 noexec、放别处不算签名包内容,一样过不了那道闸。
    # 这份会**替换**掉原来从工具链拷来的原厂 ld-musl(那份用文件映射加载 .so,
    # 在沙箱里 dlopen 必然失败)。想回到原厂那份就重跑旧流程或从工具链再拷。
    HAP_LIBS_DIR="$ROOT/feature/bsh_main/libs/arm64-v8a"
    mkdir -p "$HAP_LIBS_DIR"
    cp -f "$MUSL_OUT/lib/ld-musl-aarch64.so.1" "$HAP_LIBS_DIR/ld-musl-aarch64.so.1"
    chmod 755 "$HAP_LIBS_DIR/ld-musl-aarch64.so.1"
    log "已装进 bundle libs:$HAP_LIBS_DIR/ld-musl-aarch64.so.1"
}

# ══════════════════════════════════════════════════════════════════
# pack:把 out/lib 摆成 qemu LD_PREFIX 的形状(prefix/lib/...)并打 tar
#   本机验证就是 QEMU_LD_PREFIX=<prefix> qemu-aarch64-static ...
# ══════════════════════════════════════════════════════════════════
do_pack() {
    [ -f "$MUSL_OUT/lib/ld-musl-aarch64.so.1" ] || err "先跑 install"
    local stage="$MUSL_BUILD/prefix" tar="$MUSL_BUILD/musl-ohos-prefix.tar"
    rm -rf "$stage"
    mkdir -p "$stage/lib"
    cp -f "$MUSL_OUT/lib/ld-musl-aarch64.so.1" "$stage/lib/ld-musl-aarch64.so.1"
    ln -sf ld-musl-aarch64.so.1 "$stage/lib/libc.so"
    (cd "$MUSL_BUILD" && tar -cf "$tar" prefix)
    log "qemu 前缀:$stage"
    log "前缀 tar:$tar($(du -h "$tar" | cut -f1))"
}

case "$PHASE" in
    src)       do_src ;;
    patch)     do_patch ;;
    configure) do_configure ;;
    build)     do_build ;;
    install)   do_install ;;
    pack)      do_pack ;;
    all)       do_src; do_patch; do_configure; do_build; do_install; do_pack ;;
    *)         err "未知阶段:$PHASE(可用:src|patch|configure|build|install|pack|all)" ;;
esac
