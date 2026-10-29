#!/bin/bash
# build_glibc.sh — 给 aarch64-linux-ohos 交叉编译一份"不做文件映射"的 glibc 2.39
#
# 目标产物(见 install 阶段):一份能当 guest 运行时用的
#     lib/ld-linux-aarch64.so.1 + lib/libc.so.6
# 和上游 glibc 的唯一实质差别是:它的动态链接器**不再把库文件 mmap 进地址空间**,
# 而是"匿名预留 → pread 读入 → mprotect 给权限"(与 feature/bsh_main/src/main/cpp/elfloader 装
# guest 的做法一致)。起因是这台 HarmonyOS 设备的沙箱:把"非系统文件当可执行体"
# (execve / file-backed 的可执行 mmap)交给 seccomp 用户态通知处理 —— 表现就是
# "是否运行 xxx"确认框;用户拒绝 = EACCES = glibc 报 "failed to map segment"。
# 细节与踩过的坑见 scripts/glibc-ohos/README.md。
#
# 阶段:src | headers | patch | configure | build | install | pack | all
#   每个阶段幂等,可单独重跑;源码在 build/glibc/glibc-2.39,构建在 build/glibc/b。
#   install = 唯一交付动作:把运行时拷进 bundle libs(feature/bsh_main/libs/arm64-v8a/,随 HAP)。
#   pack    = 额外的**按需**产物:用宿主 aarch64 交叉 gcc 编几个探针程序
#             (scripts/glibc-ohos/probe/),打成 rawfile/tools/glibc-ohos.tar。
#             这个 tar 现在**不再随包发给设备**(验收已过,见 README 的
#             「验证方式速查」/§7);要重跑验收就自己跑 pack、把 tar 推上去解开。
#
# 用法:./scripts/build_glibc.sh [src|headers|patch|configure|build|install|pack|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"

# ── 版本 / 校验 ────────────────────────────────────────────
GLIBC_VER="2.39"
GLIBC_TGZ="$ROOT/thirdparty/glibc-${GLIBC_VER}.tar.gz"
GLIBC_SHA256="97f84f3b7588cd54093a6f6389b0c1a81e70d99708d74963a2e3eab7c7dc942d"
GLIBC_URL="https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.gz"

# ── 目录 ───────────────────────────────────────────────────
GLIBC_BUILD="$ROOT/build/glibc"
GLIBC_SRC="$GLIBC_BUILD/glibc-${GLIBC_VER}"
GLIBC_OBJ="$GLIBC_BUILD/b"
KH="$GLIBC_BUILD/kheaders/usr/include"      # 只含 Linux UAPI 头的 sysroot
GLIBC_OUT="$GLIBC_BUILD/out"                # 交付根:$OUT/lib/{ld-linux,libc.so.6}
HAP_LIBS_DIR="$ROOT/feature/bsh_main/libs/arm64-v8a"      # bundle libs(随 HAP 打包;guest 的 ld.so 从这里找)
PATCH_DIR="$SCRIPT_DIR/glibc-ohos/patches"
PROBE_SRC="$SCRIPT_DIR/glibc-ohos/probe"
RAW_TOOLS="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools"
PROBE_TAR="$RAW_TOOLS/glibc-ohos.tar"

# ── 工具链 ─────────────────────────────────────────────────
# 为什么不是 OHOS SDK 的 clang:clang(15 和宿主的 18 都一样)编不了 glibc 2.39 ——
#   1) configure 要求 __GNUC__ >= 6,clang 自称 4;用 -fgnuc-version=12.3 骗过去后,
#   2) bits/floatn-common.h 无条件 #define __HAVE_FLOAT32 1,而 clang 根本没有
#      _Float32/_Float64 类型(连 clang 18 也没有)→ stdlib.h 直接编不过;
#   3) configure 还硬性要求 asm 标签重定向(asm("sym") 改内置函数),clang 不支持。
# 换成宿主自带的 aarch64-linux-gnu-gcc(Ubuntu 24.04,GCC 13)—— 它就**是** glibc 2.39
# 的原厂编译器,目标 ABI 与 OHOS 无关(纯 Linux/aarch64),设备侧只认 ABI 不认编译器。
CROSS_GCC="${CROSS_GCC:-aarch64-linux-gnu-gcc}"
CROSS_GXX="${CROSS_GXX:-aarch64-linux-gnu-g++}"

mkdir -p "$GLIBC_BUILD"

# ── configure 参数 ─────────────────────────────────────────
# --with-headers=$KH     只给内核 UAPI 头;不用 OHOS sysroot(它没有 asm/ 那一层,
#                        而且要避免 musl 的头被带进来)
# -U_FORTIFY_SOURCE      Ubuntu 的 GCC 在 -O* 时会由 spec **自动**注入
#                        -D_FORTIFY_SOURCE=3,而 glibc 自己只加 -Wp,-U_FORTIFY_SOURCE
#                        (spec 不认这种写法)→ _FORTIFY_SOURCE=3 生效后
#                        misc/bits/syslog.h 会把 syslog 变成 always_inline 的
#                        _chk 包装,misc/syslog.c 的 strong_alias 随即报
#                        "inlining failed in call to always_inline 'syslog'"。
CONFIGURE_ARGS=(
    --build=x86_64-linux-gnu
    --host=aarch64-linux-gnu
    --prefix=/usr
    # 不写死 libdir 的话(64 位目标默认 lib64)slibdir 会跟着变成 /lib64,
    # 产物就去 /lib64、/usr/lib64 找库,和设备/常规 aarch64 布局都不符。
    # 钉成 /usr/lib 后 sysdeps/gnu/configure 会把 slibdir/rtlddir 落回 /lib。
    --libdir=/usr/lib
    # aarch64 的 glibc 默认 slibdir=/lib64(上游 aarch64 走 Fedora 那套布局),
    # 这里钉回常规的 /lib —— ld.so 内建的默认搜索路径就落在这儿。
    libc_cv_slibdir=/lib
    libc_cv_rtlddir=/lib
    --with-headers="$KH"
    --enable-shared
    --disable-profile
    --disable-werror
    --without-gd
    --without-selinux
    --disable-nscd
    --enable-kernel=4.19
)

# ══════════════════════════════════════════════════════════════════
# src:下载 + 校验 + 解包
# ══════════════════════════════════════════════════════════════════
do_src() {
    mkdir -p "$ROOT/thirdparty"
    if [ -f "$GLIBC_TGZ" ] && echo "$GLIBC_SHA256  $GLIBC_TGZ" | sha256sum -c --quiet 2>/dev/null; then
        log "已有校验通过的压缩包:$GLIBC_TGZ"
    else
        log "下载 glibc ${GLIBC_VER}($(basename "$GLIBC_URL"))"
        curl -L -C - --connect-timeout 20 --max-time 1800 -sS "$GLIBC_URL" -o "$GLIBC_TGZ"
        echo "$GLIBC_SHA256  $GLIBC_TGZ" | sha256sum -c - \
            || err "sha256 不匹配(删除 $GLIBC_TGZ 重试)"
    fi
    if [ ! -d "$GLIBC_SRC" ]; then
        log "解包 → $GLIBC_SRC"
        tar -xzf "$GLIBC_TGZ" -C "$GLIBC_BUILD"
    fi
}

# ══════════════════════════════════════════════════════════════════
# headers:造一份"只有内核 UAPI"的 include 目录
# ══════════════════════════════════════════════════════════════════
# glibc 只需要内核头(不需要任何 libc 头,它自己的头就是编译对象)。挑法:
#   - 首选宿主的 linux-libc-dev-arm64-cross(dpkg -L 列出它拥有的顶层目录);
#   - 没有 dpkg 就退回 OHOS sysroot 里的 linux/ + aarch64-linux-ohos/asm。
do_headers() {
    if [ -f "$KH/linux/version.h" ] && [ -d "$KH/asm" ]; then
        log "内核头已就绪:$KH"
        return 0
    fi
    rm -rf "$(dirname "$(dirname "$KH")")"
    mkdir -p "$KH"
    local d
    if dpkg -s linux-libc-dev-arm64-cross >/dev/null 2>&1; then
        log "从 linux-libc-dev-arm64-cross 取内核 UAPI 头"
        for d in $(dpkg -L linux-libc-dev-arm64-cross | grep "/include/" \
                   | sed 's|.*/include/||' | cut -d/ -f1 | sort -u); do
            [ -e "/usr/aarch64-linux-gnu/include/$d" ] \
                && cp -a "/usr/aarch64-linux-gnu/include/$d" "$KH/"
        done
    else
        warn "没装 linux-libc-dev-arm64-cross,退回 OHOS sysroot 的头"
        cp -a "$SYSROOT/usr/include/linux" "$KH/"
        cp -a "$SYSROOT/usr/include/asm-generic" "$KH/"
        mkdir -p "$KH/asm"
        cp -a "$SYSROOT/usr/include/aarch64-linux-ohos/asm/." "$KH/asm/"
    fi
    [ -f "$KH/linux/version.h" ] || err "内核头不完整:$KH"
    log "内核头就绪:$(grep -h LINUX_VERSION_CODE "$KH/linux/version.h" | head -1) → $KH"
}

# ══════════════════════════════════════════════════════════════════
# patch:打我们自己的改动(幂等;已经打过就跳过)
# ══════════════════════════════════════════════════════════════════
do_patch() {
    local p
    for p in "$PATCH_DIR"/*.patch; do
        [ -e "$p" ] || continue
        if patch -p1 -d "$GLIBC_SRC" --dry-run --silent < "$p" >/dev/null 2>&1; then
            log "打补丁:$(basename "$p")"
            patch -p1 -d "$GLIBC_SRC" < "$p" >/dev/null
        elif patch -p1 -R -d "$GLIBC_SRC" --dry-run --silent < "$p" >/dev/null 2>&1; then
            log "已是打过补丁的状态,跳过:$(basename "$p")"
        else
            err "补丁既不能正向也不能反向应用(源码被改过?):$p"
        fi
    done
}

# ══════════════════════════════════════════════════════════════════
# configure
# ══════════════════════════════════════════════════════════════════
do_configure() {
    do_headers
    [ -d "$GLIBC_SRC" ] || err "源码不在 $GLIBC_SRC(先跑 src)"
    rm -rf "$GLIBC_OBJ"
    mkdir -p "$GLIBC_OBJ"
    log "configure(CC=$CROSS_GCC)"
    (
        cd "$GLIBC_OBJ"
        CC="$CROSS_GCC" CXX="$CROSS_GXX" BUILD_CC=gcc BUILD_CXX=g++ \
        CFLAGS="-O2 -g0 -U_FORTIFY_SOURCE" \
            "$GLIBC_SRC/configure" "${CONFIGURE_ARGS[@]}"
    )
}

# ══════════════════════════════════════════════════════════════════
# build
# ══════════════════════════════════════════════════════════════════
do_build() {
    [ -f "$GLIBC_OBJ/Makefile" ] || err "还没 configure(先跑 configure)"
    log "make -j$JOBS(日志落在 $GLIBC_BUILD/make.log)"
    (cd "$GLIBC_OBJ" && make -j"$JOBS") 2>&1 | tee "$GLIBC_BUILD/make.log" | tail -5
    [ -f "$GLIBC_OBJ/libc.so.6" ] || err "make 结束但没有 libc.so.6,看 $GLIBC_BUILD/make.log"
}

# ══════════════════════════════════════════════════════════════════
# install:挑出要交付的那两个文件
# ══════════════════════════════════════════════════════════════════
# 只交 libc.so.6 + ld.so —— guest 要的其它库(libm/libpthread …)在 2.39 里都是
# libc.so.6 的一部分(空壳 so),用不着。名字按设备侧 ld.so 的真名放。
do_install() {
    local rtld="$GLIBC_OBJ/elf/ld.so"
    [ -f "$GLIBC_OBJ/libc.so.6" ] || err "没有 $GLIBC_OBJ/libc.so.6(先跑 build)"
    [ -f "$rtld" ] || err "没有 $rtld(先跑 build)"
    rm -rf "$GLIBC_OUT"
    mkdir -p "$GLIBC_OUT/lib"
    cp "$GLIBC_OBJ/libc.so.6" "$GLIBC_OUT/lib/libc.so.6"
    cp "$rtld" "$GLIBC_OUT/lib/ld-linux-aarch64.so.1"
    chmod 755 "$GLIBC_OUT/lib/ld-linux-aarch64.so.1"
    file "$GLIBC_OUT/lib/ld-linux-aarch64.so.1" "$GLIBC_OUT/lib/libc.so.6" | sed 's/^/  /'
    log "运行时已就绪:$GLIBC_OUT/lib"

    # ── 运行时交付到 bundle libs(feature/bsh_main/libs/<abi>/,随 HAP 打包) ────────────
    # **唯一**去处:bundle libs。guest 的 ld.so 靠 procmgr 塞进 LD_LIBRARY_PATH 的
    # bundle libs 路径找到 libc.so.6,解释器也从这里按 basename 取(见 procmgr.cpp 的
    # ChildRunElf)。放 bundle 而不是 $HOME,是因为 $HOME 下的文件"映射成可执行"被策略
    # 拒绝(见 scripts/glibc-ohos/README.md),而 bundle libs 是允许的。
    # ($GLIBC_OUT/lib 那份只是本脚本的中间产物,方便人工比对/单独取用。)
    mkdir -p "$HAP_LIBS_DIR"
    cp -f "$GLIBC_OUT/lib/libc.so.6"            "$HAP_LIBS_DIR/"
    cp -f "$GLIBC_OUT/lib/ld-linux-aarch64.so.1" "$HAP_LIBS_DIR/"
    chmod 755 "$HAP_LIBS_DIR/libc.so.6" "$HAP_LIBS_DIR/ld-linux-aarch64.so.1"
    # ── 顺带把 glibc 的"分家库"与 C++ 运行时也装进 bundle libs ──────────────────
    # 为什么必须有：Ubuntu 的 .deb 里**拿不到**这几件 —— 它们的真身在发行版的 libc6，
    # 而我们刻意不用发行版 libc6（会和自编这份 libc.so.6 对不上：GLIBC_PRIVATE 的符号集
    # 与内部结构都绑版本）。可 libm.so.6 是**独立**共享库（glibc 2.34 只把
    # libpthread/libdl/librt 合进 libc，没合 libm），实测 VS Code 那套闭包里有 53 个
    # ELF NEEDED 它；`update-mime-database` 还额外要 libgcc_s.so.1。
    # 所以从**自编构建树**里取（与 libc.so.6 同源），libstdc++/libgcc_s 取交叉工具链
    # （同为 glibc 2.39 口径）—— 与 scripts/pack_vscode.sh 里那份映射一致。
    # `cp -L`：构建树里这些是软链（libm.so.6 -> libm.so），要拷的是真文件。
    local -A EXTRA=(
        [libm.so.6]="$GLIBC_OBJ/math/libm.so.6"
        [libpthread.so.0]="$GLIBC_OBJ/nptl/libpthread.so.0"
        [libdl.so.2]="$GLIBC_OBJ/dlfcn/libdl.so.2"
        [librt.so.1]="$GLIBC_OBJ/rt/librt.so.1"
        [libutil.so.1]="$GLIBC_OBJ/login/libutil.so.1"
        [libresolv.so.2]="$GLIBC_OBJ/resolv/libresolv.so.2"
        [libanl.so.1]="$GLIBC_OBJ/resolv/libanl.so.1"
        [libnsl.so.1]="$GLIBC_OBJ/nis/libnsl.so.1"
        [libstdc++.so.6]="/usr/aarch64-linux-gnu/lib/libstdc++.so.6"
        [libgcc_s.so.1]="/usr/aarch64-linux-gnu/lib/libgcc_s.so.1"
    )
    local n_extra=0
    for dst in "${!EXTRA[@]}"; do
        if [ ! -e "${EXTRA[$dst]}" ]; then warn "缺 ${EXTRA[$dst]}（跳过 $dst）"; continue; fi
        cp -Lf "${EXTRA[$dst]}" "$HAP_LIBS_DIR/$dst"
        chmod 755 "$HAP_LIBS_DIR/$dst"
        n_extra=$((n_extra + 1))
    done
    log "已装进 bundle libs（$HAP_LIBS_DIR）：libc.so.6、ld-linux-aarch64.so.1 + $n_extra 个 glibc/C++ 分家库"
}

# ══════════════════════════════════════════════════════════════════
# pack:编探针 + 打 tar(按需;打完自己推到设备上解到 $HOME/glibc-ohos 用)
#   为什么默认不再随包:验收(见 README §验收)已经过了,探针只在改 elfloader/
#   运行时的时候才需要重跑;常驻一份 tar 会让每个安装包白白多背几 MB。
# ══════════════════════════════════════════════════════════════════
do_pack() {
    [ -f "$GLIBC_OUT/lib/libc.so.6" ] || err "先跑 install"
    local stage="$GLIBC_BUILD/probe-out"
    rm -rf "$stage"
    mkdir -p "$stage"
    log "编探针(-O2,动态链接,与 install 出的那对运行时配套)"
    # -Wl,-dynamic-linker 显式写成设备上的绝对路径(默认就是这个值,写上为了自明)
    "$CROSS_GCC" -O2 -o "$stage/hello" "$PROBE_SRC/hello.c"
    "$CROSS_GCC" -O2 -shared -fPIC -o "$stage/libgreet.so" "$PROBE_SRC/libgreet.c"
    "$CROSS_GCC" -O2 -o "$stage/dlopen_probe" "$PROBE_SRC/dlopen_probe.c" -ldl
    # 运行时**不放进 tar** —— 它随 HAP 去了 bundle libs,是设备侧的唯一样本;
    # 探针只留三个 ELF,验证的是"guest 自己在 $HOME(noexec)下也能被加载"。
    readelf -l "$stage/hello" | grep -A1 INTERP | sed 's/^/  /'
    (cd "$stage" && tar -cf "$PROBE_TAR" .)
    log "探针 tar:$PROBE_TAR($(du -h "$PROBE_TAR" | cut -f1))"
}

case "$PHASE" in
    src)       do_src ;;
    headers)   do_headers ;;
    patch)     do_patch ;;
    configure) do_configure ;;
    build)     do_build ;;
    install)   do_install ;;
    pack)      do_pack ;;
    all)       do_src; do_headers; do_patch; do_configure; do_build; do_install; do_pack ;;
    *)         err "未知阶段:$PHASE(可用:src|headers|patch|configure|build|install|pack|all)" ;;
esac
