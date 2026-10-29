#!/bin/bash
# build_qemu.sh — 交叉编译 qemu-user(linux-user)为 OHOS arm64 的命令 so
#
# 目标:在不能 exec 的沙箱里执行 Linux ELF。qemu-user 走"用户态仿真":把 guest
# 的 syscall 翻成宿主 syscall,可执行页只映射成宿主 READ;配上解释器后端
# (--enable-tcg-interpreter,TCI)后连翻译出的代码也不用生成 —— 所以**全程不
# 需要可写可执行内存**,这是无 JIT 设备(拿不到 ALLOW_WRITABLE_CODE_MEMORY 时)
# 唯一可行的执行路径。与 elfloader 的分工:elfloader 是同 ISA 直接跳执行(要 JIT、
# 最快),qemu 是解释/仿真(有无 JIT 都能跑、也能跑异构 guest);procmgr 按启动期
# 探到的 jit 能力在两者间选(见 procmgr/caps.cpp)。
#
# 只做 .so 形态,不产出可执行文件:沙箱不让我们 exec,而 exe 形态又必须静态链接 +
# 直跳执行(只有拿得到 JIT 的设备才能用),没有保留价值。
#
# 依赖链(全部静态 .a,装到 $SYSROOT_EXT):
#   pcre2(glib 的正则)→ glib(qemu 的核心依赖)→ qemu
#   zlib/libffi 已在 sysroot-ext(见 build_weston_deps.sh)
#
# 上游与补丁:
#   thirdparty/qemu 钉 v10.1.5;scripts/qemu-ohos-patches/ 是 10 个补丁
#   (前 9 个来源为 Termony 的 qemu-vroot 配方,顺序应用、有先后依赖,不可单独挑打;
#    0010 是 BetterSH 自己的:让 guest 的 execve 改走 libc,好被 --wrap 拦下)。
#   其中:0001 移植、0004/0007 用 prctl(PRCTL_SET_JITFORT) 放行 W^X、
#   0006 是 vroot(把 guest 的 / 重定位到 -L 前缀 + 伪造 root)、0008/0009 /dev 与挂载。
#
# 产物:
#   build/qemu/{pcre2,glib} 依赖构建目录;build/qemu/so-src 打过补丁的源码副本;
#   build/qemu/so-out/*.so 中间产物,并连同 glib/intl 复制进 $HAP_LIBS_DIR
#   (bundle libs,随包交付,见 build_qemu_so 末尾)。
#
# 用法: scripts/build_qemu.sh [deps|so|all]   默认 all;各阶段带 stamp,可重复跑。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/env.sh"

PHASE="${1:-all}"

SRC_PCRE2="$ROOT/thirdparty/pcre2"
SRC_GLIB="$ROOT/thirdparty/glib"
SRC_QEMU="$ROOT/thirdparty/qemu"
PATCH_DIR="$SCRIPT_DIR/qemu-ohos-patches"

BUILD_DIR_Q="$ROOT/build/qemu"
DEPS_PREFIX="$SYSROOT_EXT/usr"
mkdir -p "$BUILD_DIR_Q" "$SYSROOT_EXT_INC" "$SYSROOT_EXT_LIB" "$SYSROOT_EXT_PC"

# 用 SDK 里带 target 的包装器:meson/cmake/qemu 的 configure 都对多词 CC 支持不佳
OHOS_SDK="${OHOS_SDK:-/apps/harmony/sdk/default/openharmony}"
CROSS_CC="$OHOS_SDK/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
CROSS_CXX="$OHOS_SDK/native/llvm/bin/aarch64-unknown-linux-ohos-clang++"
CROSS_AR="$OHOS_SDK/native/llvm/bin/llvm-ar"
CROSS_STRIP="$OHOS_SDK/native/llvm/bin/llvm-strip"
CROSS_RANLIB="$OHOS_SDK/native/llvm/bin/llvm-ranlib"
[ -x "$CROSS_CC" ] || err "缺交叉编译器: $CROSS_CC"

# 交叉编译公共环境:让 pkg-config 只认 sysroot-ext,别串到宿主库
export PKG_CONFIG="pkg-config"
export PKG_CONFIG_LIBDIR="$SYSROOT_EXT_PC:$SYSROOT_EXT_LIB/pkgconfig:$SYSROOT/usr/lib/pkgconfig"
# 刻意不设 PKG_CONFIG_SYSROOT_DIR:本仓库 sysroot-ext 里的 .pc 用的都是**绝对
# prefix**(见 build_weston_deps.sh 产出的 cairo.pc),再叠一个 sysroot 目录会把
# 路径拼成 .../usr/usr/include 这种双份。所以下面 pcre2/glib 也一律用绝对
# prefix 直接安装,不借道 DESTDIR。
export AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" STRIP="$CROSS_STRIP"

# ─────────────────────────────────────────────────────────
# 阶段 1:pcre2(glib 的正则后端;关掉它自己的 JIT —— 无 JIT 环境用不了)
# ─────────────────────────────────────────────────────────
build_pcre2() {
    local stamp="$SYSROOT_EXT_LIB/.stamp-qemu-pcre2"
    [ -f "$stamp" ] && { log "pcre2 已构建,跳过"; return; }
    log "构建 pcre2 ..."
    local bd="$BUILD_DIR_Q/pcre2"
    rm -rf "$bd"
    cmake -G Ninja -S "$SRC_PCRE2" -B "$bd" \
        -DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake" \
        -DOHOS_ARCH=arm64-v8a \
        -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
        -DCMAKE_INSTALL_LIBDIR="lib/$TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
        -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_32=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_SUPPORT_JIT=OFF \
        > "$BUILD_DIR_Q/pcre2-configure.log" 2>&1 \
        || { tail -25 "$BUILD_DIR_Q/pcre2-configure.log" >&2; err "pcre2 configure 失败"; }
    ninja -C "$bd" > "$BUILD_DIR_Q/pcre2-build.log" 2>&1 \
        || { tail -25 "$BUILD_DIR_Q/pcre2-build.log" >&2; err "pcre2 构建失败"; }
    ninja -C "$bd" install > "$BUILD_DIR_Q/pcre2-install.log" 2>&1 \
        || { tail -25 "$BUILD_DIR_Q/pcre2-install.log" >&2; err "pcre2 安装失败"; }
    touch "$stamp"
    log "pcre2 OK → $SYSROOT_EXT_LIB/libpcre2-8.a"
}

# ─────────────────────────────────────────────────────────
# 阶段 2:glib(qemu 的核心依赖;静态+动态都装,后者给别的组件用)
# ─────────────────────────────────────────────────────────
build_glib() {
    local stamp="$SYSROOT_EXT_LIB/.stamp-qemu-glib"
    [ -f "$stamp" ] && { log "glib 已构建,跳过"; return; }
    log "构建 glib ..."
    local bd="$BUILD_DIR_Q/glib"
    local cross="$BUILD_DIR_Q/glib-cross.txt"
    rm -rf "$bd"
    cat > "$cross" <<EOF
[binaries]
c = '$CROSS_CC'
cpp = '$CROSS_CXX'
ar = '$CROSS_AR'
strip = '$CROSS_STRIP'
pkgconfig = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
    meson setup "$bd" "$SRC_GLIB" --cross-file "$cross" \
        --prefix="$DEPS_PREFIX" --libdir="lib/$TARGET" --default-library=both \
        -Dselinux=disabled -Dinstalled_tests=false -Ddtrace=disabled \
        -Dsystemtap=disabled -Dlibelf=disabled -Dlibmount=disabled \
        -Dsysprof=disabled -Dman-pages=disabled -Dtests=false \
        > "$BUILD_DIR_Q/glib-configure.log" 2>&1 \
        || { tail -30 "$BUILD_DIR_Q/glib-configure.log" >&2; err "glib configure 失败"; }
    ninja -C "$bd" > "$BUILD_DIR_Q/glib-build.log" 2>&1 \
        || { tail -30 "$BUILD_DIR_Q/glib-build.log" >&2; err "glib 构建失败"; }
    # 同 pcre2:绝对 prefix 直接装,不借道 DESTDIR
    ninja -C "$bd" install > "$BUILD_DIR_Q/glib-install.log" 2>&1 \
        || { tail -30 "$BUILD_DIR_Q/glib-install.log" >&2; err "glib 安装失败"; }
    touch "$stamp"
    log "glib OK → $SYSROOT_EXT_LIB/libglib-2.0.a"
}

# ─────────────────────────────────────────────────────────
# 阶段 3:qemu-user 本体(TCI + 动态 .so;只产出命令 so)
#
# 两处关键取舍:
#   1) --enable-tcg-interpreter:TCG 不再生成机器码,改由一个 C 解释循环执行 TCG
#      op,code-gen buffer 只申请 RW。于是**不需要可写可执行内存**,在 jit=0
#      (拿不到 ALLOW_WRITABLE_CODE_MEMORY)的设备上才起得来。代价是慢。
#   2) 不加 --static/--disable-pie:.so 要 PIC,并且 libc/glib 留给 dlopen 时由宿主
#      解析 —— dlopen 走的是普通文件映射,与"匿名可写可执行"无关,所以不受 JIT 限制。
# ─────────────────────────────────────────────────────────
build_qemu_so() {
    local src="$BUILD_DIR_Q/so-src"
    local out="$BUILD_DIR_Q/so-out"
    log "准备 TCI/.so 变体源码并打 patch"
    rm -rf "$src" "$out"
    mkdir -p "$src" "$out"
    ( cd "$SRC_QEMU" && tar -cf - --exclude=.git . ) | ( cd "$src" && tar -xf - )
    for p in "$PATCH_DIR"/[0-9][0-9][0-9][0-9]-*.patch; do
        patch -p1 -d "$src" -i "$p" >> "$BUILD_DIR_Q/patch.log" 2>&1 \
            || { tail -20 "$BUILD_DIR_Q/patch.log" >&2; err "patch 失败: $(basename "$p")"; }
    done

    log "configure(TCI)"
    ( cd "$src" && \
      ./configure \
        --target-list=aarch64-linux-user,x86_64-linux-user \
        --cross-prefix= --host-cc=cc \
        --cc="$CROSS_CC" --cxx="$CROSS_CXX" \
        --enable-tcg-interpreter \
        --disable-system --disable-tools --disable-docs \
        --without-default-features \
        --disable-libusb --disable-seccomp --disable-debug-info \
        --extra-cflags="-O2 -fPIC -D_UAPI_LINUX_VIRTIO_VSOCK_H -D_UAPI_LINUX_VIRTIO_TYPES_H -D_UAPI_LINUX_VIRTIO_RING_H -D_UAPI_LINUX_VIRTIO_PMEM_H -D_UAPI_LINUX_VIRTIO_NET_H -D_UAPI_LINUX_VIRTIO_IOMMU_H -D_UAPI_LINUX_VIRTIO_FS_H -D_UAPI_LINUX_VIRTIO_CONSOLE_H -D_UAPI_LINUX_VIRTIO_CONFIG_H -D_LINUX_SYSINFO_H -D__user= -D__force=" \
        -Db_staticpic=true \
        > "$BUILD_DIR_Q/so-configure.log" 2>&1 ) \
        || { tail -35 "$BUILD_DIR_Q/so-configure.log" >&2; err "TCI configure 失败($BUILD_DIR_Q/so-configure.log)"; }

    log "make(TCI;先按常规链接,只为拿到全部对象与真实链接行)"
    ( cd "$src" && make -j"$JOBS" qemu-aarch64 qemu-x86_64 > "$BUILD_DIR_Q/so-make.log" 2>&1 ) \
        || { tail -40 "$BUILD_DIR_Q/so-make.log" >&2; err "TCI 构建失败($BUILD_DIR_Q/so-make.log)"; }

    # procmgr 的统一入口约定是 int(*)(int,char**),而 qemu 的 linux-user main 是
    # 三参数 main(argc, argv, envp) —— linux-user 真要读环境变量(QEMU_* 选项、
    # PATH…),第三个参数是垃圾值会直接出事。所以:把原 main 改名为 qemu_main3,
    # 另编一层薄包装 qemu_entry(argc, argv) 把 environ 补上去。
    local wrap_c="$BUILD_DIR_Q/qemu_entry_wrapper.c"
    cat > "$wrap_c" <<'EOF'
/* procmgr 调入口符号的约定是 int(*)(int,char**);qemu 的 main 是三参数,
 * 这里把宿主 environ 补成第三个参数。 */
extern char** environ;
extern int qemu_main3(int argc, char** argv, char** envp);
int qemu_entry(int argc, char** argv) {
    return qemu_main3(argc, argv, environ);
}
EOF
    "$CROSS_CC" -O2 -fPIC -c "$wrap_c" -o "$out/qemu_entry_wrapper.o"

    # ── exec 委托:把 exec 家族也 wrap 给 shim(qemu 自己也要) ──────────────
    # 为什么:guest 的 execve 最终要落到"宿主侧起一个新进程"上,而应用数据目录是
    # noexec —— 内核直接 Permission denied(实测 native 构建里 cmake 起 ninja 就死在
    # 这句上)。wrap 之后经 control socket 回 procmgr 起进程,和其它命令 so 同一条路,
    # cmake→ninja→clang 这条链才走得通。
    # 注意:光在这里 wrap 还不够 —— 补丁 0010 把 qemu 里那两处 safe_execve(裸 syscall,
    # 拦不到)换成 libc 的 execve(),这一步才真正生效。
    local SHIM_OBJS="$out/exec_shim.o $out/bsh_client.o"
    local EXEC_WRAP="" s
    for s in execve execv execvp execvpe execl execlp posix_spawn posix_spawnp exit; do
        EXEC_WRAP="$EXEC_WRAP -Wl,--wrap=$s"
    done
    "$CROSS_CC" --target="$TARGET" --sysroot="$SYSROOT" -O2 -fPIC -DBSH_SHIM_WRAP \
        -I"$ROOT/feature/bsh_main/src/main/cpp/shim" -I"$ROOT/feature/bsh_main/src/main/cpp/procmgr" \
        -c "$ROOT/feature/bsh_main/src/main/cpp/shim/exec_shim.c" -o "$out/exec_shim.o" \
        || err "exec_shim.o 编译失败"
    "$CROSS_CC" --target="$TARGET" --sysroot="$SYSROOT" -O2 -fPIC \
        -I"$ROOT/feature/bsh_main/src/main/cpp/procmgr" \
        -c "$ROOT/feature/bsh_main/src/main/cpp/procmgr/bsh_client.c" -o "$out/bsh_client.o" \
        || err "bsh_client.o 编译失败"

    for t in aarch64 x86_64; do
        local mainobj="libqemu-$t-linux-user.a.p/linux-user_main.c.o"
        [ -f "$src/build/$mainobj" ] || err "找不到入口对象 $mainobj"
        cp "$src/build/$mainobj" "$out/qemu_${t}_main.o"
        "$OHOS_SDK/native/llvm/bin/llvm-objcopy" --redefine-sym main=qemu_main3 \
            "$out/qemu_${t}_main.o" || err "objcopy 改名 main 失败"
        # 取 ninja 的真实链接行,改造成共享库:换输出、去 --no-undefined/-pie/--as-needed,
        # 并把 qemu 的 main 对象换成"改名后的 main + 入口包装"
        local cmd newcmd
        cmd=$(ninja -C "$src/build" -t commands "qemu-$t" | tail -1)
        [ -n "$cmd" ] || err "取不到 qemu-$t 的链接命令"
        newcmd=$(printf '%s' "$cmd" | sed \
            -e "s| -o qemu-$t | -shared -Wl,-soname,libqemu-$t.so -o $out/libqemu-$t.so |" \
            -e "s|-Wl,--no-undefined||g" -e "s| -pie ||g" -e "s|-Wl,--as-needed||g" \
            -e "s|$mainobj|$out/qemu_${t}_main.o $out/qemu_entry_wrapper.o|")
        newcmd="$newcmd $SHIM_OBJS $EXEC_WRAP"
        log "重链 libqemu-$t.so(含 exec 委托 shim)"
        ( cd "$src/build" && eval "$newcmd" ) >> "$BUILD_DIR_Q/so-link.log" 2>&1 \
            || { tail -30 "$BUILD_DIR_Q/so-link.log" >&2; err "重链 libqemu-$t.so 失败($BUILD_DIR_Q/so-link.log)"; }
    done

    # 运行期依赖:libqemu-*.so 只 NEEDED glib/intl/libc,前两者随包带(bundle libs
    # 在宿主进程的搜索路径里,dlopen 时按 SONAME 解析)。libc 用系统的。
    local so_dir="$HAP_LIBS_DIR"
    mkdir -p "$so_dir"
    cp -f "$out"/libqemu-aarch64.so "$out"/libqemu-x86_64.so "$so_dir"/
    for so in libglib-2.0.so.0.8200.0 libintl.so.8; do
        cp -f "$SYSROOT_EXT_LIB/$so" "$so_dir/$so"
    done
    ( cd "$so_dir" && ln -sf libglib-2.0.so.0.8200.0 libglib-2.0.so.0 )

    # x86_64 guest 自己的运行期(musl 的 ldso+libc 是同一个文件,和 aarch64 那份
    # ld-musl-aarch64.so.1 同理)。box64 不需要它 —— box64 自带 libc 垫片
    # (wrappedlibcmusl.c);但**无 jit 设备上 x86_64 只能走 qemu**,而 qemu 是老实
    # 按 guest 的 PT_INTERP(/lib/ld-musl-x86_64.so.1)找解释器的,所以这份必须随包带。
    # shell.cpp 会把它们摆进 <sysroot>/qemu-root/lib 供 QEMU_LD_PREFIX 使用。
    local x64tc="${X86_64_MUSL_TOOLCHAIN:-$ROOT/thirdparty/x86_64-linux-musl-cross}"
    local x64libc="$x64tc/x86_64-linux-musl/lib/libc.so"
    if [ -f "$x64libc" ]; then
        cp -f "$x64libc" "$so_dir/ld-musl-x86_64.so.1"
        log "x86_64 musl 运行期已交付:$so_dir/ld-musl-x86_64.so.1"
    else
        warn "缺 $x64libc(qemu 跑 x86_64 **动态** guest 会报 /lib/ld-musl-x86_64.so.1 找不到;静态 guest 不受影响)"
    fi
    log "TCI/.so OK:"
    ls -la "$out"/*.so >&2
}

case "$PHASE" in
    deps) build_pcre2; build_glib ;;
    so)   build_pcre2; build_glib; build_qemu_so ;;
    all)  build_pcre2; build_glib; build_qemu_so ;;
    *)    err "用法: $0 [deps|so|all]" ;;
esac
log "✅ build_qemu.sh 完成(阶段 $PHASE)"
