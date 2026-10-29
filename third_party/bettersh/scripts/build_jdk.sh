#!/bin/bash
# build_jdk.sh — 把 OpenJDK 21 (jdk21u) 交叉编译到 aarch64-linux-ohos(musl)
#
# 目标：给 BetterSH 产出一份能在 OHOS 设备上跑的 JDK 镜像
#       （java / javac / jar + lib/modules + lib/server/libjvm.so）。
#
# 阶段：src | sysroot | stubs | patches | configure | build | launcher | install | pack | all
#   每个阶段幂等，可单独重跑；stamp 落在 build/jdk/。
#   launcher = 编我们自己的入口 so（scripts/jdk-ohos/bsh_java_entry.cc）→
#              feature/bsh_main/libs/<arch>/libjdk.so。
#   install  = 把该随 HAP 走的 .so 拷进 feature/bsh_main/libs/<arch>/（bundle libs，$HOME 是
#              noexec 放不了 .so），再编 launcher，最后重新生成只含 $HOME 数据的
#              jdk21-ohos.tar。
#
# 与本项目其它 build_*.sh 同一形态：**这里产出 feature/bsh_main/libs 下的预编译 so，
# build_hap.sh 只负责打包** —— 于是"只编 JDK"和"只编 HAP"互不依赖。
#
# 与其它 build_*.sh 不同的是：这里要编的不是一个 .so，而是一整棵 JDK。
# 三个"不这样就不行"的前提，细节见 scripts/jdk-ohos/README.md：
#   1) SDK clang 自带 ohos 驱动，libc++ 头与 arch 头目录会自动进搜索路径；
#   2) OHOS sysroot 里没有 libc++ 运行时 → 目标链接一律 -nostdlib++，
#      C++ ABI 符号由我们自己的 libcxxabi_shim.so 补；
#   3) cups / fontconfig / X11 / alsa 四个依赖 configure 阶段就必须找到头，
#      前三个只 dlopen（写 stub 头即可），alsa 要被真链接（要头 + 桩库）。
#
# 用法：./scripts/build_jdk.sh [src|sysroot|stubs|patches|configure|build|launcher|install|pack|all]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"

# ── 版本 / 校验 ────────────────────────────────────────────
JDK_TAG="jdk-21.0.5-ga"
JDK_VER="21.0.5"
JDK_TGZ="$ROOT/thirdparty/jdk21u-${JDK_VER}-ga.tar.gz"
JDK_TGZ_SHA256="1dcf54fe0d4263a0fb95290a77dac9e4ff81761ed234daadfbab781f1779bf0b"
JDK_TGZ_URL="https://codeload.github.com/openjdk/jdk21u/tar.gz/refs/tags/${JDK_TAG}"

# ── 目录 ───────────────────────────────────────────────────
JDK_BUILD="$ROOT/build/jdk"
JDK_SRC="$JDK_BUILD/jdk21u-${JDK_TAG}"
SYSROOT_RW="$JDK_BUILD/sysroot-rw"
STUBS="$JDK_BUILD/stubs"          # 生成出的 stub 头/库（含从宿主拷来的 alsa 头）
JDK_LIBS="$JDK_BUILD/jdk-libs"    # libcxxabi_shim.so / libasound.so 桩
TOOLCHAIN="$JDK_BUILD/toolchain"  # CC/CXX 包装脚本
SPEC_DIR="$SCRIPT_DIR/jdk-ohos"   # 我们自己的 stub 源码 + patch
STUB_SRC="$SPEC_DIR/stubs"
PATCH_DIR="$SPEC_DIR/patches"

CONF_NAME="ohos-aarch64-server-release"
BUILD_OUT="$JDK_SRC/build/$CONF_NAME"
IMAGE_DIR="$BUILD_OUT/images/jdk"

RAW_TOOLS="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools"
RAW_TAR="$RAW_TOOLS/jdk21-ohos.tar"

BOOT_JDK="${BOOT_JDK:-/usr/lib/jvm/java-21-openjdk-amd64}"

# 目标侧库目录：SDK clang 在 --target=aarch64-linux-ohos 下就认这个目录，
# 显式写进 -L 是为了让"哪来的 libc.so/libz.so"一眼可见。
TARGET_LIB="$SYSROOT_RW/usr/lib/$TARGET"

mkdir -p "$JDK_BUILD"

# ── 公用编译/链接选项 ──────────────────────────────────────
# 说明：
#   -DMUSL_LIBC 其实由 flags-cflags.m4 在 target libc = musl 时自动加，
#   这里显式带上只为让补丁里的 #ifdef 一眼可追溯（值相同，不会重复定义）。
#   -D__MUSL__ 是我们自己的标记，补丁里用不到它，留着给将来的外部代码。
#   -fno-emulated-tls：**必须**。OHOS SDK 的 clang 对 *-ohos 三元组默认用
#   模拟 TLS（__emutls_v.* / __emutls_get_address），而 hotspot 的
#   os_cpu/linux_aarch64/threadLS_linux_aarch64.S 是手写的 native TLS 访问
#   （:tlsdesc:_ZN6Thread12_thr_currentE）。两边不对齐的结果是 libjvm.so 里
#   留下一个未定义的 _ZN6Thread12_thr_currentE + 一条 R_AARCH64_TLSDESC
#   重定位，dlopen 直接失败。加这个开关让 C++ 侧也用 native TLS。
#   -rtlib=compiler-rt -unwindlib=none：OHOS sysroot 没有 gcc 风格的
#   libgcc*/crtbeginS.o，SDK clang 自带 libclang_rt.builtins.a + clang_rt.crtbegin.o。
COMMON_FLAGS="--target=$TARGET --sysroot=$SYSROOT_RW -fPIC -fno-emulated-tls \
-DMUSL_LIBC -D__MUSL__ -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBCPP_HAS_MUSL_LIBC"

CFLAGS_EXTRA="$COMMON_FLAGS -I$STUBS/include -L$TARGET_LIB -rtlib=compiler-rt -unwindlib=none"
CXXFLAGS_EXTRA="$COMMON_FLAGS -I$STUBS/include -stdlib=libc++ -nostdlib++ \
-L$TARGET_LIB -rtlib=compiler-rt -unwindlib=none"
LDFLAGS_EXTRA="--target=$TARGET --sysroot=$SYSROOT_RW -fuse-ld=lld \
-L$TARGET_LIB -rtlib=compiler-rt -unwindlib=none -nostdlib++ \
-L$JDK_LIBS -lcxxabi_shim"

# ══════════════════════════════════════════════════════════
# 阶段 1：src —— 下载 / 校验 / 解压
# ══════════════════════════════════════════════════════════
do_src() {
    if [ -f "$JDK_SRC/make/autoconf/configure.ac" ]; then
        log "源码已就绪：$JDK_SRC"
    else
        if [ ! -s "$JDK_TGZ" ]; then
            log "下载 $JDK_TGZ_URL"
            # env.sh 检测到宿主代理时会 export http_proxy/https_proxy
            curl -S -L --connect-timeout 20 --max-time 3600 -C - \
                 "$JDK_TGZ_URL" -o "$JDK_TGZ" \
                || err "下载失败（代理？见 scripts/env.sh 的 BSH_PROXY_HOST/PORT）"
        fi
        log "校验 sha256"
        echo "$JDK_TGZ_SHA256  $JDK_TGZ" | sha256sum -c - >&2 \
            || err "$JDK_TGZ 校验失败，删掉重下"
        log "解压到 $JDK_BUILD"
        tar -xzf "$JDK_TGZ" -C "$JDK_BUILD"
        [ -f "$JDK_SRC/make/autoconf/configure.ac" ] \
            || err "解压后找不到 $JDK_SRC/make/autoconf/configure.ac"
    fi
    log "  版本：$(grep -E '^DEFAULT_VERSION_(FEATURE|INTERIM|PATCH|EXTRA1)=' \
                       "$JDK_SRC/make/conf/version-numbers.conf" | tr '\n' ' ')"
    log "✅ src"
}

# ══════════════════════════════════════════════════════════
# 阶段 2：sysroot —— 可写副本 + arch 头/CRT 搜索路径补丁
# ══════════════════════════════════════════════════════════
# 实测：直接用只读 SDK sysroot 也能编（SDK clang 会自动把
# sysroot/usr/include/aarch64-linux-ohos 加进搜索路径）。这一阶段是"廉价保险"，
# 换 SDK 版本 / 换工具链时最容易踩的就是这三样，先建好省得回头查。
do_sysroot() {
    local SENTINEL="$SYSROOT_RW/.bsh-sysroot-ok"

    if [ ! -d "$SYSROOT_RW" ]; then
        log "复制可写 sysroot：$SYSROOT → $SYSROOT_RW"
        rm -rf "$SYSROOT_RW.tmp"
        cp -a "$SYSROOT" "$SYSROOT_RW.tmp"
        mv -T "$SYSROOT_RW.tmp" "$SYSROOT_RW"
    fi

    local INC="$SYSROOT_RW/usr/include"
    local LIBDIR="$SYSROOT_RW/usr/lib/$TARGET"

    # 1) arch 专有头目录的顶层别名。musl 的 limits.h 直接 #include <bits/alltypes.h>，
    #    而 OHOS 把它放在 usr/include/<triple>/ 子目录下。
    for d in bits asm; do
        if [ ! -e "$INC/$d" ] && [ -d "$INC/$TARGET/$d" ]; then
            ln -sfn "$TARGET/$d" "$INC/$d"
        fi
    done

    # 2) CRT 目标文件：SDK clang 在 sysroot/usr/lib/<triple>/ 下找得到，
    #    这里再往 sysroot/usr/lib/ 放一层同名符号链接（同一份文件，不会顶错）。
    local CRT_LIB="$SYSROOT_RW/usr/lib"
    for f in crt1.o Scrt1.o crti.o crtn.o; do
        if [ -f "$LIBDIR/$f" ] && [ ! -e "$CRT_LIB/$f" ]; then
            ln -sfn "$TARGET/$f" "$CRT_LIB/$f"
        fi
    done
    if [ ! -f "$LIBDIR/Scrt1.o" ] && [ -f "$LIBDIR/crt1.o" ]; then
        cp "$LIBDIR/crt1.o" "$LIBDIR/Scrt1.o"
    fi

    # 3) 缺的公共库别名（musl 把 pthread/dl/rt/resolv 并进 libc；OHOS sysroot 里
    #    这几个 .a 已经存在，这里只是兜底，不覆盖已有文件）。
    for lib in libc.so libm.so; do
        if [ -e "$LIBDIR/$lib" ] && [ ! -e "$CRT_LIB/$lib" ]; then
            ln -sfn "$TARGET/$lib" "$CRT_LIB/$lib"
        fi
    done

    if [ ! -f "$SENTINEL" ]; then
        { echo "src=$SYSROOT"; echo "date=$(date -Is)";
          echo "clang=$($CLANG --version | head -1)"; } > "$SENTINEL"
    fi
    log "  可写 sysroot：$SYSROOT_RW ($(du -sh "$SYSROOT_RW" | cut -f1))"
    log "  include/bits -> $(readlink "$INC/bits" 2>/dev/null || echo '(无需)')"
    log "✅ sysroot"
}

# ══════════════════════════════════════════════════════════
# 阶段 3：stubs —— stub 头 + ala stub 库 + C++ ABI 垫片
# ══════════════════════════════════════════════════════════
do_stubs() {
    mkdir -p "$STUBS/include" "$STUBS/x11/include" "$STUBS/x11/lib" "$JDK_LIBS"

    # 3a) 我们自己的 stub 头（cups / fontconfig / x11），
    #     源码在 scripts/jdk-ohos/stubs/，这里只是随阶段同步过去。
    rm -rf "$STUBS/include/cups" "$STUBS/include/fontconfig"
    cp -a "$STUB_SRC/include/cups" "$STUBS/include/"
    cp -a "$STUB_SRC/include/fontconfig" "$STUBS/include/"
    cp -a "$STUB_SRC/x11/include/X11" "$STUBS/x11/include/"

    # 3b) alsa：libjsound 真的会 -lasound，近百个 snd_* 符号和 SND_* 常量，
    #     手写桩等于复刻 alsa-lib 公共 API。直接用宿主 alsa-lib 的头
    #     （纯 C 声明，实测能在 OHOS 工具链下过编译），只用它编译、不随产物分发。
    local ALSA_SRC="${ALSA_HEADER_DIR:-/usr/include}/alsa"
    [ -f "$ALSA_SRC/asoundlib.h" ] \
        || err "缺 ALSA 头：$ALSA_SRC/asoundlib.h（安装 libasound2-dev，或设 ALSA_HEADER_DIR）"
    rm -rf "$STUBS/include/alsa"
    cp -a "$ALSA_SRC" "$STUBS/include/alsa"

    # 3c) C++ ABI 垫片（异常/operator new/RTTI 元对象），详见源码注释。
    local ARCH_INC="-I$SYSROOT_RW/usr/include/$TARGET"
    log "编译 libcxxabi_shim.so"
    "$CLANG" --target="$TARGET" --sysroot="$SYSROOT_RW" $ARCH_INC \
        -c -fPIC -o "$STUBS/eh_stubs.o" "$STUB_SRC/eh_stubs.c" \
        || err "eh_stubs.c 编译失败"
    # -nostdlib：sysroot 没有 gcc 风格 crt*.o / libgcc，而垫片是自包含的共享库，
    # 只需要 -lc。
    "$CLANGXX" --target="$TARGET" --sysroot="$SYSROOT_RW" $ARCH_INC \
        -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
        -nostdlib -L"$SYSROOT_RW/usr/lib/$TARGET" \
        -o "$JDK_LIBS/libcxxabi_shim.so" \
        "$STUB_SRC/cxxabi_shim.cpp" "$STUBS/eh_stubs.o" \
        -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -lc \
        || err "libcxxabi_shim.so 编译失败"

    # 3d) libasound.so 桩：configure 认出 ALSA 后 libjsound 会 -lasound，
    #     而 OHOS 没有 alsa。先出一个只含占位符号的版本让链接能过；
    #     真正的 snd_* 符号表要等 libjsound.so 编出来才知道（见 do_build）。
    #     已经有带完整符号表的版本就别覆盖它（重跑 stubs 不该让产物退化）。
    if [ -f "$JDK_LIBS/libasound.so" ]; then
        log "libasound.so 已存在（$(du -h "$JDK_LIBS/libasound.so" | cut -f1)），保留"
    else
        log "生成 libasound.so 占位桩（build 阶段会用真实符号表重出）"
        make_alsa_stub
    fi

    local NM="$CLANG_DIR/llvm-nm"
    log "  libcxxabi_shim.so 导出符号：$("$NM" -D --defined-only "$JDK_LIBS/libcxxabi_shim.so" | wc -l)"
    log "  libcxxabi_shim.so ($(du -h "$JDK_LIBS/libcxxabi_shim.so" | cut -f1)) / libasound.so ($(du -h "$JDK_LIBS/libasound.so" | cut -f1))"
    log "✅ stubs"
}

# 生成 libasound.so 桩。
#   $1 = 可选。给一个 ELF（libjsound.so）就从中抓出所有未定义的 snd_* 符号，
#        把它们定义成空函数（weak，真 libasound 在的话会被顶掉）。
# 为什么这么做而不手写：libjsound 引用了近百个 snd_* 以及若干 SND_* 常量，
# 手写桩等于复刻 alsa-lib 公共 API，错一个就 dlopen 失败。从真实产物反推
# 既准确又不会随 JDK 版本漂移。
make_alsa_stub() {
    local ref="${1:-}"
    local arch_inc="-I$SYSROOT_RW/usr/include/$TARGET"
    local src="$STUBS/asound_stub.c"
    local syms=""
    if [ -n "$ref" ] && [ -f "$ref" ]; then
        syms="$("$CLANG_DIR/llvm-nm" -D -u "$ref" 2>/dev/null \
                | awk '{print $NF}' | grep '^snd_' | sort -u || true)"
    fi
    {
        echo '/* 由 scripts/build_jdk.sh 的 make_alsa_stub 生成，不要手改。 */'
        echo '/* OHOS 上没有 alsa，但 libjsound.so 会 DT_NEEDED libasound.so 并引用 */'
        echo '/* 一批 snd_* 函数；这些空定义让 libjsound.so 能被 dlopen 起来。 */'
        echo '/* 真去调用声音 API 才会出问题，headless 用不到。 */'
        echo 'void bsh_alsa_stub(void) {}'
        for s in $syms; do
            printf '__attribute__((weak)) void %s(void) {}\n' "$s"
        done
    } > "$src"
    "$CLANG" --target="$TARGET" --sysroot="$SYSROOT_RW" $arch_inc \
        -shared -fPIC -nostdlib -L"$SYSROOT_RW/usr/lib/$TARGET" \
        -o "$JDK_LIBS/libasound.so" "$src" \
        -fuse-ld=lld -Wl,-soname,libasound.so -lc \
        || err "libasound.so 桩编译失败（$src）"
    local n=0
    [ -n "$syms" ] && n="$(printf '%s\n' "$syms" | wc -l)"
    log "    libasound.so 桩：$n 个 snd_* 空定义"
}

# ══════════════════════════════════════════════════════════
# 阶段 4：patches —— 应用 scripts/jdk-ohos/patches/series
# ══════════════════════════════════════════════════════════
# 用 GNU patch 而不是 git apply：源码在 BetterSH 这个 git 仓库的 build/ 下，
# git apply 会把路径解析到仓库根，可能"返回 0 却一个 hunk 都没打上"。
do_patches() {
    [ -d "$JDK_SRC/src" ] || err "缺源码，先跑 src 阶段"
    [ -f "$PATCH_DIR/series" ] || err "缺 $PATCH_DIR/series"

    local applied=0 skipped=0 total=0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        total=$((total + 1))
        local p="$PATCH_DIR/$line"
        [ -f "$p" ] || err "series 里列了不存在的补丁：$line"

        # 幂等：能 --reverse --dry-run 就说明已经打过了
        if (cd "$JDK_SRC" && patch -p1 -R --dry-run --force < "$p" >/dev/null 2>&1); then
            log "  [skip] $line（已应用）"
            skipped=$((skipped + 1))
            continue
        fi
        if (cd "$JDK_SRC" && patch -p1 --forward --batch --no-backup-if-mismatch < "$p") >&2; then
            log "  [ok]   $line"
            applied=$((applied + 1))
        else
            err "补丁失败：$line（源码可能已和 jdk-21.0.5-ga 分叉）"
        fi
    done < "$PATCH_DIR/series"
    log "  共 $total 条：本次应用 $applied，跳过 $skipped"
    log "✅ patches"
}

# ══════════════════════════════════════════════════════════
# 阶段 5：configure
# ══════════════════════════════════════════════════════════
do_configure() {
    [ -d "$JDK_SRC/src" ] || err "缺源码，先跑 src 阶段"
    autoconf --version >/dev/null 2>&1 || err "缺 autoconf（用它生成真正的 configure）"

    # CC/CXX 用包装脚本：configure 会往命令行里拼标志，多词变量不稳
    # （build_node.sh / build_python.sh 也踩过同一个坑）。
    mkdir -p "$TOOLCHAIN"
    local LLVM="$CLANG_DIR"
    cat > "$TOOLCHAIN/ohos-cc" <<EOF
#!/bin/sh
exec "$LLVM/clang" --target=$TARGET --sysroot=$SYSROOT_RW "\$@"
EOF
    cat > "$TOOLCHAIN/ohos-cxx" <<EOF
#!/bin/sh
exec "$LLVM/clang++" --target=$TARGET --sysroot=$SYSROOT_RW "\$@"
EOF
    for t in ar:llvm-ar ranlib:llvm-ranlib strip:llvm-strip objcopy:llvm-objcopy \
             nm:llvm-nm objdump:llvm-objdump readelf:llvm-readelf; do
        cat > "$TOOLCHAIN/ohos-${t%%:*}" <<EOF
#!/bin/sh
exec "$LLVM/${t##*:}" "\$@"
EOF
    done
    cat > "$TOOLCHAIN/ohos-ld" <<EOF
#!/bin/sh
exec "$LLVM/ld.lld" "\$@"
EOF
    chmod +x "$TOOLCHAIN"/ohos-*

    # 宿主侧 build 工具（buildjdk）用系统 clang："build 与 host 必须同族"，
    # 但没必要跟 target 同版本 —— 这里用 Ubuntu 的 clang-18。
    local BUILD_CC BUILD_CXX
    BUILD_CC="${BUILD_CC_HOST:-$(command -v clang-18 || command -v clang)}"
    BUILD_CXX="${BUILD_CXX_HOST:-$(command -v clang++-18 || command -v clang++)}"

    # 让宿主 pkg-config 彻底闭嘴：lib-alsa.m4 / lib-fontconfig.m4 在没给
    # --with-*-include 时会跑 PKG_CHECK_MODULES，命中宿主 .pc 后可能把宿主
    # glibc 的 -I 带进目标编译。四个依赖全部显式指定，就不需要 pkg-config 了。
    export PKG_CONFIG_LIBDIR="$JDK_BUILD/pkgconfig-empty"
    mkdir -p "$PKG_CONFIG_LIBDIR"
    export PATH="$TOOLCHAIN:$PATH"

    log "configure（日志 $JDK_BUILD/configure.log）"
    cd "$JDK_SRC"
    set +e
    bash configure \
        --with-conf-name="$CONF_NAME" \
        --openjdk-target=aarch64-unknown-linux-musl \
        --with-jvm-variants=server \
        --with-debug-level=release \
        --with-native-debug-symbols=none \
        --with-boot-jdk="$BOOT_JDK" \
        --with-toolchain-type=clang \
        --with-extra-cflags="$CFLAGS_EXTRA" \
        --with-extra-cxxflags="$CXXFLAGS_EXTRA" \
        --with-extra-ldflags="$LDFLAGS_EXTRA" \
        --with-cups-include="$STUBS/include" \
        --with-fontconfig-include="$STUBS/include" \
        --with-alsa-include="$STUBS/include" \
        --with-alsa-lib="$JDK_LIBS" \
        --x-includes="$STUBS/x11/include" \
        --x-libraries="$STUBS/x11/lib" \
        --with-freetype=bundled \
        --with-libjpeg=bundled \
        --with-giflib=bundled \
        --with-libpng=bundled \
        --with-lcms=bundled \
        --with-harfbuzz=bundled \
        --with-zlib=bundled \
        --enable-headless-only \
        --disable-warnings-as-errors \
        CC="$TOOLCHAIN/ohos-cc" \
        CXX="$TOOLCHAIN/ohos-cxx" \
        CPP="$TOOLCHAIN/ohos-cc -E" \
        CXXCPP="$TOOLCHAIN/ohos-cxx -E" \
        AR="$TOOLCHAIN/ohos-ar" \
        STRIP="$TOOLCHAIN/ohos-strip" \
        NM="$TOOLCHAIN/ohos-nm" \
        OBJCOPY="$TOOLCHAIN/ohos-objcopy" \
        BUILD_CC="$BUILD_CC" \
        BUILD_CXX="$BUILD_CXX" \
        > "$JDK_BUILD/configure.log" 2>&1
    local rc=$?
    set -e

    # 把 configure 的总结段留一份好读的副本（每阶段重跑都刷新）。
    # 注意首跑是 "A new configuration has been successfully created in"，
    # 重跑（输出目录已存在）会变成 "The existing configuration has been
    # successfully updated in"，两种都要匹配。
    awk '/configuration has been successfully (created|updated) in/,0' "$JDK_BUILD/configure.log" \
        > "$JDK_BUILD/configure-summary.txt" || true
    [ -s "$JDK_BUILD/configure-summary.txt" ] \
        || warn "没能从 configure.log 里切出总结段（看 $JDK_BUILD/configure.log）"
    if [ $rc -ne 0 ]; then
        tail -60 "$JDK_BUILD/configure.log" >&2
        grep -nE "^\*|error:|configure: error" "$JDK_BUILD/configure.log" \
            | tail -20 >&2 || true
        err "configure 失败（全文 $JDK_BUILD/configure.log）"
    fi
    log "  配置目录：$BUILD_OUT"
    log "  Boot JDK / Toolchain / Target / CFLAGS 见 $JDK_BUILD/configure-summary.txt"
    log "✅ configure"
}

# ══════════════════════════════════════════════════════════
# 阶段 6：build
# ══════════════════════════════════════════════════════════
do_build() {
    [ -f "$BUILD_OUT/spec.gmk" ] || err "缺 $BUILD_OUT/spec.gmk，先跑 configure 阶段"
    log "make images JOBS=$JOBS（日志 $JDK_BUILD/make.log）"
    cd "$JDK_SRC"
    set +e
    nohup make images JOBS="$JOBS" CONF="$CONF_NAME" \
        > "$JDK_BUILD/make.log" 2>&1
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        grep -nE "error:|Error [0-9]+|\*\*\* " "$JDK_BUILD/make.log" | tail -30 >&2 || true
        err "make images 失败（全文 $JDK_BUILD/make.log）"
    fi
    [ -d "$IMAGE_DIR" ] || err "make 成功但找不到镜像：$IMAGE_DIR"

    # 目标端依赖补全：make 不会把这两个库放进镜像，但产物真的需要它们。
    #   libcxxabi_shim.so：所有 .so / 可执行文件都 DT_NEEDED 它（见 --with-extra-ldflags）；
    #     lib/ 下的 .so 都有 RPATH=$ORIGIN，放 lib/ 就能被找到。
    #   libasound.so 桩：libjsound.so 的 DT_NEEDED。到这一步 libjsound.so 已经
    #     编出来了，正好从它身上反推需要哪些 snd_* 空定义（见 make_alsa_stub）。
    log "  从 libjsound.so 反推 ALSA 符号表，重出 libasound.so 桩"
    make_alsa_stub "$IMAGE_DIR/lib/libjsound.so"
    cp -f "$JDK_LIBS/libcxxabi_shim.so" "$IMAGE_DIR/lib/"
    cp -f "$JDK_LIBS/libasound.so"      "$IMAGE_DIR/lib/"
    log "  补入 lib/libcxxabi_shim.so ($(du -h "$JDK_LIBS/libcxxabi_shim.so" | cut -f1)) 与 lib/libasound.so 桩"

    log "镜像：$IMAGE_DIR ($(du -sh "$IMAGE_DIR" | cut -f1))"
    for f in bin/java bin/javac bin/jar lib/server/libjvm.so lib/modules \
             lib/libjli.so lib/libjava.so lib/libnet.so lib/libnio.so lib/libzip.so \
             lib/libcxxabi_shim.so lib/libasound.so; do
        if [ -e "$IMAGE_DIR/$f" ]; then
            log "    $f  $(du -h "$IMAGE_DIR/$f" | cut -f1)"
        else
            warn "    缺 $f"
        fi
    done
    local RE="$CLANG_DIR/llvm-readelf"
    log "  架构/依赖核对："
    "$RE" -h "$IMAGE_DIR/lib/server/libjvm.so" | grep -E "Machine" | sed 's/^/    /' >&2
    "$RE" -d "$IMAGE_DIR/lib/server/libjvm.so" | grep -E "NEEDED|SONAME" | sed 's/^/    /' >&2
    "$RE" -d "$IMAGE_DIR/lib/libjsound.so" | grep -E "NEEDED" | sed 's/^/    /' >&2
    log "✅ build"
}

# ══════════════════════════════════════════════════════════
# 阶段 8：install —— 把该随 HAP 走的 .so 拷进 bundle libs，再重新打 tar
# ══════════════════════════════════════════════════════════
#
# 为什么要拆成"两条腿"：
#   应用数据目录 $HOME(/data/storage/el2/base/haps/entry/files)是 **noexec** ——
#   实测从那里 dlopen 一份 .so 直接 `Permission denied`。所以 JDK 的 .so 只能
#   随 HAP 进 `feature/bsh_main/libs/arm64-v8a/`(运行时 = /data/storage/el1/bundle/libs/arm64,
#   exec 允许、且在 loader 的搜索路径里)；剩下的大块数据(lib/modules 135M、
#   conf/、tzdb.dat、ct.sym…)照旧解包到 $HOME/jdk21。launcher 侧对应地把
#   java.home 指 $HOME/jdk21、SUN_BOOT_LIBRARY_PATH/java.library.path 指 bundle libs。
#
# 为什么这份清单是"精选"而不是全部 39 个：
#   * libfreetype.so 与 feature/bsh_main/libs 里 Qt 带来的那一份**同名**,不能带;
#     连带 libfontmanager.so 也不带(它 NEEDED libfreetype.so,留着会去绑 Qt 那份)。
#   * 其余 java.desktop 的 native 库(libawt*/libjawt/liblcms/libmlib_image/
#     libjavajpeg/libjsound+libasound)在 headless + 我们支持的命令里一次都没被
#     加载(实测见 README 的「运行期踩坑」),不带。
#   * libjsig.so 不带:它实现的是"标准 signal chaining",OHOS 上那套不起作用,
#     信号转发由 launcher 直接接 libc 的 sigchain 完成(见 README)。
BUNDLE_LIBS_KEEP="
libjvm.so
libcxxabi_shim.so
libjava.so libjimage.so libzip.so libverify.so
libnet.so libnio.so libjli.so libsyslookup.so
libj2pkcs11.so libextnet.so librmi.so libjaas.so
libj2gss.so libj2pcsc.so lible.so libprefs.so
libmanagement.so libmanagement_ext.so libmanagement_agent.so
libinstrument.so libdt_socket.so libattach.so libjdwp.so libsaproc.so
"

# launcher（java / javac / jar 三个入口）—— 我们自己写的那层，编成独立 so。
#
# 为什么由**本脚本**编、而不是 HAR 的 CMake：让"编 HAP"和"编 JDK"彻底解耦。
# 两边各自的产物边界很清楚：
#   本脚本负责 → feature/bsh_main/libs/arm64-v8a/{26 个 JDK .so, libjdk.so} + rawfile/tools/jdk21-ohos.tar
#   build_hap.sh 只负责 → 把 feature/bsh_main/libs 与 rawfile 打进 HAP（它不编译任何 JDK 相关源码）
# 于是"只编 JDK"、"只编 HAP"都能单独跑：前者不需要 HAP 工具链跑一遍，后者也不需要
# 重编 OpenJDK（只要 feature/bsh_main/libs 里的东西在）。这与 node 那条线同一形态
# （build_node.sh 产出 libnode.so，feature/bsh_main/libs 里等着被 HAP 打包）。
do_launcher() {
    local lm="$SPEC_DIR/bsh_java_entry.cc"
    [ -f "$lm" ] || err "缺 launcher 源码：$lm"
    mkdir -p "$HAP_LIBS_DIR"
    log "编 launcher → $HAP_LIBS_DIR/libjdk.so"
    # 只依赖 libc/libdl：JDK 的 libjvm.so 是运行期从 bundle libs dlopen 的，
    # 不在链接期出现（jni.h 用 scripts/jdk-ohos/jni/ 里那份从 JDK 镜像拷来的头）。
    "$CLANGXX" --target="$TARGET" --sysroot="$SYSROOT" \
        -O2 -fPIC -std=c++17 -shared \
        -I "$SPEC_DIR/jni" \
        -o "$HAP_LIBS_DIR/libjdk.so" "$lm" \
        -Wl,-soname,libjdk.so -ldl \
        || err "libjdk.so 编译失败"
    chmod 755 "$HAP_LIBS_DIR/libjdk.so"
    local NM="$CLANG_DIR/llvm-nm"
    local n
    n=$("$NM" -D --defined-only "$HAP_LIBS_DIR/libjdk.so" 2>/dev/null \
        | grep -cE ' T bsh_(java|javac|jar)_main$')
    [ "$n" = 3 ] || err "libjdk.so 没导出三个入口符号（只找到 $n 个）"
    log "  三个入口符号齐：bsh_java_main / bsh_javac_main / bsh_jar_main"
    log "✅ launcher（$(du -h "$HAP_LIBS_DIR/libjdk.so" | cut -f1)）"
}

do_install() {
    [ -d "$IMAGE_DIR" ] || err "缺镜像 $IMAGE_DIR，先跑 build 阶段"
    mkdir -p "$HAP_LIBS_DIR"
    log "部署 JDK 的 .so → $HAP_LIBS_DIR（bundle libs，随 HAP 打包）"
    local name src
    for name in $BUNDLE_LIBS_KEEP; do
        src="$IMAGE_DIR/lib/$name"
        [ -f "$src" ] || src="$IMAGE_DIR/lib/server/$name"
        [ -f "$src" ] || err "镜像里找不到 $name（$IMAGE_DIR/lib 与 lib/server 都没有）"
        cp -f "$src" "$HAP_LIBS_DIR/$name"
        chmod 755 "$HAP_LIBS_DIR/$name"
    done
    log "  带了 $(echo $BUNDLE_LIBS_KEEP | wc -w) 个：$(echo $BUNDLE_LIBS_KEEP | tr -s ' \n' ' ')"
    log "  没带的 13 个（镜像里共 39 个）："
    log "    java.desktop/声音：libawt.so libawt_headless.so libjawt.so liblcms.so"
    log "      libmlib_image.so libjavajpeg.so libjsound.so libasound.so"
    log "    同名冲突：libfreetype.so（Qt 也有一份）；连带 libfontmanager.so"
    log "      （它 NEEDED libfreetype，留着会去绑 Qt 那份）"
    log "    libjsig.so ×2（lib/ 与 lib/server/：标准 signal chaining，OHOS 上不用它）"
    log "    libsctp.so（com.sun.nio.sctp 用，CLI 场景不需要）"
    # 产物自检：架构对不对、NEEDED 能不能在同一个目录里自洽（libjvm.so 的
    # RPATH=$ORIGIN 是它找到 libcxxabi_shim.so 的唯一依据，平铺之后才成立）。
    local RE="$CLANG_DIR/llvm-readelf" deps
    deps=$("$RE" -d "$HAP_LIBS_DIR/libjvm.so" 2>/dev/null | grep -E 'NEEDED' \
           | sed 's/.*\[//;s/\]//' | tr '\n' ' ')
    log "  libjvm.so NEEDED：$deps"
    "$RE" -h "$HAP_LIBS_DIR/libjvm.so" | grep -E 'Machine' | sed 's/^/  /' >&2
    do_launcher
    log "✅ install(bundle libs + launcher)"

    do_pack
}

# ══════════════════════════════════════════════════════════
# 阶段 7：pack —— 把 $HOME 那部分数据打成一个 tar 随 HAP 走
# ══════════════════════════════════════════════════════════
do_pack() {
    [ -d "$IMAGE_DIR" ] || err "缺镜像 $IMAGE_DIR，先跑 build 阶段"
    mkdir -p "$RAW_TOOLS"
    log "打包 $RAW_TAR"
    # tar 顶层在镜像里叫 jdk/，但设备侧要落到 <资源根>/jdk21（launcher 的
    # JAVA_HOME 按这个写），所以用 --transform 改名。
    #
    # --dereference --hard-dereference 两个都必须有：镜像里 legal/<module>/
    # {LICENSE,ASSEMBLY_EXCEPTION,ADDITIONAL_LICENSE_INFO} 共 205 个是**指向
    # ../java.base/* 的符号链接**，而应用沙箱**不允许创建符号链接、也不允许
    # 创建硬链接**（EPERM）。
    #   只 --dereference：GNU tar 会发现"这些链接最后指向同一个 inode"，
    #   于是改成记**硬链接**（`hr--r--r-- … link to …`）—— 设备上照样建不了。
    #   两个一起：全部落成普通文件，多花约 2M。
    # 不解引用的话 toybox tar 会逐个报 `can't link …: Permission denied` 并以
    # rc=1 结束 —— UnpackRes 把非 0 当失败，资源总标记就永远写不上，于是每次会话都
    # 重解一遍（实测踩过）。
    #
    # 排除的东西都是设备端用不到的：
    #   lib/src.zip  52M —— JDK 源码，只有 IDE 看源码时才用
    #   jmods/       79M —— 只有 jlink 做自定义运行时才需要
    #   demo/ man/   6.6M —— 示例与 man page
    #   lib/*.so、lib/server/*.so —— 那些随 HAP 进 bundle libs（见 do_install），
    #       从 $HOME 解出来也 dlopen 不了（noexec）
    # 保留 lib/ct.sym（11M）：javac 的 --release 功能靠它。
    rm -f "$RAW_TAR"
    tar -C "$BUILD_OUT/images" --format=ustar \
        --dereference --hard-dereference \
        --transform='s,^jdk,jdk21,' \
        --exclude='jdk/lib/src.zip' \
        --exclude='jdk/jmods' \
        --exclude='jdk/demo' \
        --exclude='jdk/man' \
        --exclude='jdk/lib/*.so' \
        --exclude='jdk/lib/server/*.so' \
        -cf "$RAW_TAR" jdk || err "打 tar 失败"
    # 打完之后自检:顶层必须是 jdk21/、不能有符号链接/硬链接条目、不能带 .so。
    # 注意先把清单落盘再 grep:直接 `tar -tf | grep -q` 会因为 grep 命中即退出、
    # tar 收到 SIGPIPE 而以 141 结束(pipefail 下整条管道算失败),那是个假警报。
    local bad=0 list="$JDK_BUILD/tar-list.txt" vlist="$JDK_BUILD/tar-vlist.txt"
    tar -tf "$RAW_TAR" > "$list" || err "读 tar 清单失败"
    tar -tvf "$RAW_TAR" > "$vlist" || err "读 tar 详细清单失败"
    grep -q '^jdk21/lib/modules$' "$list" || { warn "  tar 里没有 jdk21/lib/modules"; bad=1; }
    if grep -qE '^[lh]' "$vlist"; then
        warn "  tar 里还有链接条目(符号/硬链接,设备侧建不了):"
        grep -E '^[lh]' "$vlist" | head -3 | sed 's/^/    /' >&2
        bad=1
    fi
    if grep -qE '^jdk21/lib/(server/)?[^/]+\.so$' "$list"; then
        warn "  tar 里还带着 .so(它们应当只走 bundle libs)"; bad=1
    fi
    [ "$bad" -eq 0 ] || err "tar 自检没过"
    log "✅ $RAW_TAR ($(du -h "$RAW_TAR" | cut -f1), $(tar -tf "$RAW_TAR" | wc -l) 项)"
    log "   （gzip 后约 $(gzip -c "$RAW_TAR" | wc -c | awk '{printf "%.0fM", $1/1048576}')，本阶段仍出未压缩 tar 以跟仓库里其它 rawfile tar 一致）"
    log "   设备侧的环境变量由 launcher（scripts/jdk-ohos/bsh_java_entry.cc）导出："
    log "     JAVA_HOME             = $HOME/jdk21（java.home，定位 lib/modules 等数据）"
    log "     SUN_BOOT_LIBRARY_PATH = bundle libs（hotspot 的 dll_dir）"
    log "       ⚠ 0003 补丁让 dll_dir 直接取这个环境变量；指错会报"
    log '         "Unable to load jimage library"。JDK 的 .so 已平铺进 bundle libs，'
    log "         所以这里给的是 bundle libs 的绝对路径，不是 \$JAVA_HOME/lib。"
    log "     java.library.path     = bundle libs（System.loadLibrary 的搜索路径）"
    log "     LD_LIBRARY_PATH       = bundle libs（只是保险：musl 在进程启动时就缓存了"
    log "         搜索路径，launcher 里 setenv 对它无效；真正靠得住的是 libjvm.so 的"
    log "         RPATH=\$ORIGIN —— 平铺到同一个目录后它才找得到 libcxxabi_shim.so）"
    log "✅ pack"
}

case "$PHASE" in
    src)       do_src ;;
    sysroot)   do_sysroot ;;
    stubs)     do_stubs ;;
    patches)   do_patches ;;
    configure) do_configure ;;
    build)     do_build ;;
    pack)      do_pack ;;
    install)   do_install ;;
    launcher)  do_launcher ;;
    all)       do_src; do_sysroot; do_stubs; do_patches; do_configure; do_build; do_install ;;
    *)         err "用法: $0 [src|sysroot|stubs|patches|configure|build|pack|install|all]" ;;
esac
log "✅ build_jdk.sh 完成（阶段 $PHASE）"
