#!/bin/bash
# build_qtwl_demo.sh — Qt6 wayland 示例客户端(feature/bsh_main/src/main/cpp/programs/qtwl_demo)两种交付形态
#
#   so  : 命令 so —— 编成 feature/bsh_main/libs/<abi>/libqtwl-demo.so(命令表 qtwl-demo → 入口 main),
#         随 HAP 打包,在 shell 会话里直接当命令跑。
#   app : 可执行 —— 编成 PIE 的 qtwl-demo,连它 NEEDED 闭包里的 Qt 库、QPA/shell/图形集成
#         插件、8 个"顶掉 OHOS 同名系统库"的桩库一起组装到一个目录,strip 后打成
#         feature/bsh_main/src/main/resources/rawfile/tools/qtapp.tar;设备端由 shell.cpp 的 UnpackRes
#         解到 <sysroot>/qtapp,再交给 elfloader 起。
#
# 用法:./scripts/build_qtwl_demo.sh [so|app|all]   (默认 all)
#
# 前置(require_common 那几条):demo 源码、Qt 构建树(scripts/build_qt.sh)、waymony
#   sysroot-ext(scripts/build_wayland.sh)。缺前置时的策略:
#     - 显式指定单个模式 → err 退出(报错里带上到底缺哪个文件);
#     - all 模式 → 只 warn 并跳过该模式 —— 两个模式的依赖集合并不相同(so 还要 host Qt、
#       还要 Qt 的 toolchain 文件),而且**两种产物都是等所有检查/编译都过了才落盘**
#       (tar 先写 .new 再 mv),所以 all 半途失败不会毁掉上一次已部署的 tar/so。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

MODE="${1:-all}"

QT_SRC_DIR="${QT_SRC_DIR:-$ROOT/thirdparty/qt-src}"
QT_BUILD="$QT_SRC_DIR/qtbase/build-target"
QT_HOST="$QT_SRC_DIR/qtbase/build-host"
DEMO_SRC="$ROOT/feature/bsh_main/src/main/cpp/programs/qtwl_demo"
SYSX="$SYSROOT_EXT/usr"                       # waymony 扩展 sysroot(wayland-client 头/库)
SYSX_LIB="$SYSROOT_EXT_LIB"
SYSROOT_LIB="$SYSROOT/usr/lib/$TARGET"        # SDK sysroot 的 aarch64-linux-ohos
LLVM_LIB="$OHOS_SDK/native/llvm/lib/$TARGET"  # SDK 自带的 libc++_shared 等运行时
BUILD_DEMO="$BUILD_DIR/qtwl-demo"             # so 模式的 cmake 构建目录
APPDIR="$BUILD_DIR/qtapp"                     # app 模式的组装目录(平铺)
STUBGEN="$BUILD_DIR/qtstubs"                  # app 模式桩库的中间产物(.c/.syms)
OUT_SO="$HAP_LIBS_DIR/libqtwl-demo.so"
OUT_TAR="$ROOT/feature/bsh_main/src/main/resources/rawfile/tools/qtapp.tar"
MUSL_TC="${MUSL_TOOLCHAIN:-/workspace/dev/elfloader/ElfLoaderDemo/tools/aarch64-linux-musl-cross}"
MUSL_CC="$MUSL_TC/bin/aarch64-linux-musl-gcc"

READELF="$CLANG_DIR/llvm-readelf"
NM="$CLANG_DIR/llvm-nm"
STRIP="$CLANG_DIR/llvm-strip"

# 8 个"顶掉 OHOS 同名系统库"的桩库。**文件名必须和系统库完全同名**才顶得掉:
# 设备上 <sysroot>/qtapp 在 ld.so 搜索序里先于 /system/lib64(-rpath=$ORIGIN),
# 同名文件一放进去,OHOS 那份就永远不会被加载。
STUB_LIBS=(
    libhilog_ndk.z.so        # Qt6Core 的 OHOS 日志后端
    libace_napi.z.so         # 符号最多的一个(45 个),Qt 会 dlopen 它
    libdeviceinfo_ndk.z.so   # QSysInfo
    libohenvironment.so      # QStandardPaths 的用户目录
    libohfileuri.so          # file:// URI
    libtime_service_ndk.so   # 时区
    libEGL.so                # Qt6Gui/Widgets/WaylandClient 的 NEEDED
    libGLESv3.so
)

# ══════════════════════════════════════════════════════════
# 前置检查:need 只 warn 不退出,由下面的 case 决定 err 还是跳过
# (all 模式不该因为一个模式的依赖缺失就报废另一个模式的产物)。
# ══════════════════════════════════════════════════════════
need() {   # $1=路径 $2=说明
    [ -e "$1" ] && return 0
    warn "缺 $2:$1"
    return 1
}

# 两种模式的共用前置
require_common() {
    need "$DEMO_SRC/main.cpp" "demo 源码(feature/bsh_main/src/main/cpp/programs/qtwl_demo/main.cpp)" || return 1
    need "$QT_BUILD/lib/cmake/Qt6/Qt6Config.cmake" "Qt 构建树(先跑 scripts/build_qt.sh)" || return 1
    need "$SYSX/include" "waymony sysroot-ext(先跑 scripts/build_wayland.sh)" || return 1
}

# so 模式:靠 Qt 生成的 toolchain 文件交叉编译,host 工具(moc/rcc/…)从 QT_HOST_PATH 取
require_so() {
    require_common || return 1
    need "$QT_BUILD/lib/cmake/Qt6/qt.toolchain.cmake" "qt.toolchain.cmake" || return 1
    need "$QT_HOST/lib/cmake/Qt6" "host Qt(build_qt.sh 第 1 段;QT_HOST_PATH 要用)" || return 1
    # SDK 自带 cmake/ninja:env.sh 把 /usr/bin 前置(规避 SDK 那个对不存在的文件也
    # 返回 0 的 diff),不显式指定会解析到系统版 —— 见 build_qt.sh 的踩坑记录。
    need "$OHOS_SDK/native/build-tools/cmake/bin/cmake" "SDK cmake" || return 1
    need "$OHOS_SDK/native/build-tools/cmake/bin/ninja" "SDK ninja" || return 1
}

# app 模式:直接用 SDK clang 编可执行文件,桩库用 musl 交叉 gcc 编
require_app() {
    # 桩库链的是 GLESv3/EGL 那套名字、解释器钉死 /lib/ld-musl-aarch64.so.1,x86_64 得另做一套
    [ "$TARGET" = aarch64-linux-ohos ] || err "app 模式只支持 arm64-v8a(现在 NATIVE_ARCH=$NATIVE_ARCH)"
    require_common || return 1
    need "$SYSX_LIB/libwayland-client.so" "sysroot-ext 里的 wayland-client" || return 1
    need "$SYSROOT_LIB/libEGL.so" "SDK sysroot 的库目录(桩库要按它算 Qt 引用了哪些符号)" || return 1
    need "$MUSL_CC" "aarch64 musl 交叉编译器(可用 MUSL_TOOLCHAIN 覆盖)" || return 1
    need "$QT_BUILD/plugins/platforms/libqwayland.so" "QPA 插件(platforms)" || return 1
    need "$QT_BUILD/plugins/wayland-shell-integration/libxdg-shell.so" "xdg-shell 插件" || return 1
    need "$QT_BUILD/plugins/wayland-graphics-integration-client" "wayland 图形集成插件" || return 1
    # 桩库的符号表就是拿这几个库的未定义符号和系统库求交算出来的(见 gen_stubs),
    # 缺任何一个都会默默生成一个空桩库,表现是设备上加载期报 unresolved
    local q
    for q in libQt6Core libQt6Gui libQt6Widgets libQt6WaylandClient; do
        need "$QT_BUILD/lib/$q.so" "$q(桩库要按它的未定义符号算)" || return 1
    done
}

# ══════════════════════════════════════════════════════════
# so 模式:命令 so(Qt 的 cmake 工程 + qt.toolchain.cmake)
# ══════════════════════════════════════════════════════════
do_so() {
    log "════ so 模式:编译命令 so → $OUT_SO ════"
    export PATH="$OHOS_SDK/native/build-tools/cmake/bin:$PATH"
    local CMAKE
    CMAKE="$(command -v cmake)"
    [ -n "$CMAKE" ] || err "PATH 里没有 cmake(需 SDK build-tools/cmake/bin)"

    log "=== 配置 qtwl-demo → $BUILD_DEMO ==="
    rm -rf "$BUILD_DEMO"
    "$CMAKE" -S "$DEMO_SRC" -B "$BUILD_DEMO" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$QT_BUILD/lib/cmake/Qt6/qt.toolchain.cmake" \
        -DCMAKE_PREFIX_PATH="$QT_BUILD" \
        -DQT_HOST_PATH="$QT_HOST" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DWAYMONY_SYSX="$SYSX" \
        > "$BUILD_DEMO-configure.log" 2>&1 \
        || { tail -25 "$BUILD_DEMO-configure.log" >&2; err "configure 失败(日志 $BUILD_DEMO-configure.log)"; }

    log "=== 编译 ==="
    "$CMAKE" --build "$BUILD_DEMO" --parallel "$JOBS" > "$BUILD_DEMO-build.log" 2>&1 \
        || { tail -25 "$BUILD_DEMO-build.log" >&2; err "编译失败(日志 $BUILD_DEMO-build.log)"; }

    local SO
    SO="$(find "$BUILD_DEMO" -maxdepth 2 -name 'libqtwl-demo.so' -o -maxdepth 2 -name '*.so' | head -1)"
    [ -n "$SO" ] || err "没找到产物 so(看 $BUILD_DEMO)"
    mkdir -p "$HAP_LIBS_DIR"
    cp -f "$SO" "$OUT_SO" || err "复制到 $HAP_LIBS_DIR 失败"

    # ── 校验:命令表要按 AArch64 的 so 加载,且必须导出 main ──
    "$READELF" -h "$OUT_SO" > "$BUILD_DEMO/.arch" 2>/dev/null || true
    grep -q AArch64 "$BUILD_DEMO/.arch" || err "$OUT_SO 非 AArch64"
    rm -f "$BUILD_DEMO/.arch"
    "$NM" -D "$OUT_SO" > "$BUILD_DEMO/.syms" 2>/dev/null || true
    grep -qE " (T|W) main$" "$BUILD_DEMO/.syms" || err "$OUT_SO 未导出 main(命令表要用)"
    rm -f "$BUILD_DEMO/.syms"
    log "✅ 产物: $OUT_SO ($(du -h "$OUT_SO" | cut -f1))"
    "$READELF" -d "$OUT_SO" 2>/dev/null | grep -E "NEEDED|SONAME" || true
    log "运行(qtwl-demo 需要会话已设的):"
    log "  QT_QPA_PLATFORM=wayland   QT_PLUGIN_PATH=<设备上的 libs/arm64>(平扫插件)"
    log "  WAYLAND_DISPLAY/XDG_RUNTIME_DIR 由 shell.cpp 会话环境提供"
}

# ══════════════════════════════════════════════════════════
# app 模式:可执行文件 + 依赖闭包 + 桩库 → 平铺目录 → tar
# ══════════════════════════════════════════════════════════

# 按 NEEDED 闭包拷库。只认 NEEDED:Qt 的 .so 里写死的是库名,ld.so 在 qtapp 目录里
# 找不到就会去 /system/lib64 找 OHOS 那份(然后拉进整条 OHOS 服务链),所以闭包必须补齐。
copy_needed_closure() {
    local search_dirs=(
        "$QT_BUILD/lib"
        "$HAP_LIBS_DIR"                                     # build_qt.sh 第 6 段的平铺产物
        "$ROOT/thirdparty/ohos-extra/additional-packages/lib"
        "$LLVM_LIB"
        "$SYSX_LIB"
    )
    declare -A seen
    MISSING=""
    resolve() {
        local name="$1"
        [ -n "${seen[$name]:-}" ] && return
        seen[$name]=1
        # 设备上的 musl libc/ldso 由系统提供(和 ld-musl-aarch64.so.1 同一份),
        # 拷进来反而会和会话里那份打架
        case "$name" in
            libc.so|libc.so.6|libdl.so*|libm.so*|libpthread.so*|librt.so*|ld-musl*|ld-linux*) return;;
        esac
        # 这 8 个名字一律归自己的桩库管(见 STUB_LIBS):绝不能从搜索目录里拷到同名真库,
        # 那会把整条 OHOS 服务链拖进来 —— 桩库的全部意义就是躲开它。
        local s
        for s in "${STUB_LIBS[@]}"; do
            [ "$name" = "$s" ] && return
        done
        local p="" d
        for d in "${search_dirs[@]}"; do
            if [ -f "$d/$name" ]; then p="$d/$name"; break; fi
        done
        if [ -z "$p" ]; then MISSING="$MISSING $name"; return; fi
        cp -f "$p" "$APPDIR/$name"
        local n
        for n in $("$READELF" -d "$p" 2>/dev/null | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}'); do
            resolve "$n"
        done
    }

    local f n
    for f in "$APPDIR/qtwl-demo" "$APPDIR/libqwayland.so" "$APPDIR/libxdg-shell.so" "$APPDIR/plugins-probe/"*.so; do
        [ -f "$f" ] || continue
        for n in $("$READELF" -d "$f" 2>/dev/null | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}'); do
            resolve "$n"
        done
    done
    # 找不到的多半是 /system/lib64 里的 OHOS 库 —— 桩库就是为了不依赖它们,
    # 真漏了会在设备上表现为 "Error loading shared library";所以只提示不失败。
    warn "闭包里本机找不到的 NEEDED(可能指望 /system/lib64):${MISSING:- 无}"
}

# 8 个桩库。为什么要有它们:
#   SDK 编出来的 Qt 里,libQt6Core 依赖 libhilog/napi/deviceinfo/ohenvironment/ohfileuri/
#   time_service,libQt6Gui 依赖 libEGL/libGLESv3。设备上这些系统库自身挂着整条 OHOS
#   服务链(libsurface/libbegetutil/libsamgr_proxy/…),被拖进来后又要一堆 OHOS libc
#   专有符号(__cfi_*/fdsan_*/dlns_*)。而我们的路径(wayland + raster)根本不该走到它们,
#   于是干脆放一份**同名**的最小实现把系统那份顶掉:
#     - OHOS 那几个:按 SDK 头文件的真实签名给合理实现(用户目录指 $HOME、OS 名返回字面量、
#       hilog 转 stderr);
#     - napi(45 个)/EGL(18 个)/GLESv3(2 个):机械生成兜底实现,统一返回失败/NULL,
#       让调用方走错误分支(egl* 返回 0 → Qt 认为"没有 EGL",退回 SHM/raster)。
gen_stubs() {
    rm -rf "$STUBGEN"; mkdir -p "$STUBGEN"

    # Qt 侧所有未定义符号(一次算好,后面每个系统库与它求交:只有 Qt 真引用的才要兜底)
    local q
    for q in "$QT_BUILD/lib/libQt6Core.so" "$QT_BUILD/lib/libQt6Gui.so" \
             "$QT_BUILD/lib/libQt6Widgets.so" "$QT_BUILD/lib/libQt6WaylandClient.so"; do
        "$NM" -D -u "$q" 2>/dev/null | awk '{print $2}'
    done | sort -u > "$STUBGEN/.qtu"
    log "Qt 侧未定义符号:$(wc -l < "$STUBGEN/.qtu") 个"

    local lib ret
    for lib in libace_napi.z libEGL libGLESv3; do
        case "$lib" in
            libace_napi.z) ret=1 ;;    # napi_* → 1(napi_invalid_arg),别假装成功
            *)             ret=0 ;;    # egl*/gl* → NULL/FALSE,让 Qt 认为"没有 EGL"
        esac
        "$NM" -D --defined-only "$SYSROOT_LIB/$lib.so" 2>/dev/null | awk '{print $3}' \
            | sort -u > "$STUBGEN/$lib.syms"
        # 只要合法标识符:版本后缀之类的东西原样写进 C 会编不过
        comm -12 "$STUBGEN/.qtu" "$STUBGEN/$lib.syms" \
            | awk '/^[A-Za-z_][A-Za-z0-9_]*$/' > "$STUBGEN/$lib.use"
        local n_use n_raw
        n_use="$(wc -l < "$STUBGEN/$lib.use")"
        n_raw="$(comm -12 "$STUBGEN/.qtu" "$STUBGEN/$lib.syms" | wc -l)"
        [ "$n_use" = "$n_raw" ] || warn "$lib 有 $(($n_raw - $n_use)) 个非法标识符被丢弃"

        {
            echo "/* 自动生成:$lib 的兜底实现(Qt 引用其中 $n_use 个符号)。"
            echo " * 只为让 ld.so 在加载期能解析;每次被调用都打一行,便于看 Qt 死前调了谁。"
            echo " * 参数一律忽略(arm64 多传参数无害),返回值统一 $ret。 */"
            echo '#include <unistd.h>'
            echo 'static void sdbg(const char *s) { while (*s) { if (write(2, s, 1) < 0) return; s++; } }'
        } > "$STUBGEN/$lib.c"
        # 用 awk 生成,不用 sed:符号名要同时出现在**函数名**和调试串里,而 sed 替换串里
        # 的 & 是"整个匹配"、\n 是换行 —— 写不对就会生成 `long &(void)` 这种废码,
        # 而且编译错误还会被 head 吞掉,只有上一次的旧 .so 留在目录里,很难发现。
        awk -v lib="$lib" -v ret="$ret" \
            '{ printf "long %s(void) { sdbg(\"[stub-%s] %s\\n\"); return %s; }\n", $1, lib, $1, ret }' \
            "$STUBGEN/$lib.use" >> "$STUBGEN/$lib.c"
        "$MUSL_CC" -O1 -fPIC -shared -Wl,-soname,"$lib.so" -Wno-strict-prototypes \
            "$STUBGEN/$lib.c" -o "$APPDIR/$lib.so" > "$STUBGEN/$lib.log" 2>&1 \
            || { tail -5 "$STUBGEN/$lib.log" >&2; err "生成桩库 $lib.so 失败"; }
        log "  桩库 $lib.so:$n_use 个符号"
    done

    # 手写的 5 个(按 SDK 头文件里的真实签名)
    cat > "$STUBGEN/libhilog_ndk.z.c" <<'EOF'
/* hilog:转 stderr。Qt6Core 的 OHOS 日志后端会调到它,qDebug 才有地方去。 */
#include <stdarg.h>
#include <stdio.h>
#include <stddef.h>
int OH_LOG_Print(int type, int level, unsigned int domain, const char *tag,
                 const char *fmt, ...);
int OH_LOG_PrintMsg(int type, int level, unsigned int domain, const char *tag,
                    const char *message);
/* OHOS 的 hilog 格式串里带 %{public}/%{private} 前缀(vfprintf 不认识,会整段吞掉),
 * 先把它洗成普通 % 再交给 vfprintf —— 否则 Qt 的日志只剩一个空 "[tag] "。
 * 这段不能省:它是 Qt 日志唯一能看到的地方(app 模式下 stderr 就是会话终端)。 */
static void bsh_vprint(const char *fmt, va_list ap)
{
    char buf[4096];
    size_t o = 0;
    const char *p;
    for (p = fmt; p && *p && o + 8 < sizeof buf; ) {
        if (p[0] == '%' && p[1] == '{') {
            const char *e = p + 2;
            while (*e && *e != '}') e++;
            if (*e == '}') { buf[o++] = '%'; p = e + 1; continue; }
        }
        buf[o++] = *p++;
    }
    buf[o] = 0;
    vfprintf(stderr, buf, ap);
}
int OH_LOG_Print(int type, int level, unsigned int domain, const char *tag,
                 const char *fmt, ...)
{
    (void)type; (void)level; (void)domain;
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[%s] ", tag ? tag : "?");
    bsh_vprint(fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    return 0;
}
int OH_LOG_PrintMsg(int type, int level, unsigned int domain, const char *tag,
                    const char *message)
{
    (void)type; (void)level; (void)domain;
    fprintf(stderr, "[%s] %s\n", tag ? tag : "?", message ? message : "");
    return 0;
}
EOF

    cat > "$STUBGEN/libdeviceinfo_ndk.z.c" <<'EOF'
/* deviceinfo:Qt 拿它填 QSysInfo。返回字面量(不能返回 NULL,Qt 会当字符串用)。 */
const char *OH_GetOSFullName(void) { return "OpenHarmony"; }
const char *OH_GetDistributionOSReleaseType(void) { return "phone"; }
EOF

    cat > "$STUBGEN/libohenvironment.c" <<'EOF'
/* environment:用户目录。指到 $HOME(和会话家目录一致),Qt 的 QStandardPaths 才有落点。 */
#include <stdlib.h>
#include <string.h>
static char *dup_home(void)
{
    const char *h = getenv("HOME");
    return strdup((h && *h) ? h : "/data/storage/el2/base/haps/entry/files/home");
}
int OH_Environment_GetUserDocumentDir(char **result);
int OH_Environment_GetUserDownloadDir(char **result);
int OH_Environment_GetUserDesktopDir(char **result);
int OH_Environment_GetUserDocumentDir(char **result) { if (result) *result = dup_home(); return 0; }
int OH_Environment_GetUserDownloadDir(char **result) { if (result) *result = dup_home(); return 0; }
int OH_Environment_GetUserDesktopDir(char **result)  { if (result) *result = dup_home(); return 0; }
EOF

    cat > "$STUBGEN/libohfileuri.c" <<'EOF'
/* fileuri:file:// URI。直接把入参复制回去(我们不需要真 URI)。 */
#include <stdlib.h>
#include <string.h>
int OH_FileUri_GetUriFromPath(const char *path, unsigned int length, char **result);
int OH_FileUri_GetUriFromPath(const char *path, unsigned int length, char **result)
{
    (void)length;
    if (!result) return -1;
    *result = path ? strdup(path) : NULL;
    return 0;
}
EOF

    cat > "$STUBGEN/libtime_service_ndk.c" <<'EOF'
/* time_service:时区。填 "UTC" —— 沙箱里 tzdata 未必齐,UTC 永远安全。 */
#include <string.h>
int OH_TimeService_GetTimeZone(char *timeZone, unsigned int len);
int OH_TimeService_GetTimeZone(char *timeZone, unsigned int len)
{
    if (!timeZone || len < 4) return -1;
    strcpy(timeZone, "UTC");
    return 0;
}
EOF

    for lib in libhilog_ndk.z libdeviceinfo_ndk.z libohenvironment libohfileuri libtime_service_ndk; do
        "$MUSL_CC" -O1 -fPIC -shared -Wl,-soname,"$lib.so" "$STUBGEN/$lib.c" -o "$APPDIR/$lib.so" \
            > "$STUBGEN/$lib.log" 2>&1 \
            || { tail -5 "$STUBGEN/$lib.log" >&2; err "生成桩库 $lib.so 失败"; }
        log "  桩库 $lib.so:手写($(du -h "$APPDIR/$lib.so" | cut -f1))"
    done
}

arch_of() { "$READELF" -h "$1" 2>/dev/null | awk '/Machine:/{print $2}'; }

# app 模式的收尾自检:tar 里该有的都在、可执行文件和桩库都对得上设备要求
verify_app() {
    local l v LIST
    [ "$(arch_of "$APPDIR/qtwl-demo")" = AArch64 ] || err "$APPDIR/qtwl-demo 不是 AArch64"
    for l in "${STUB_LIBS[@]}"; do
        [ "$(arch_of "$APPDIR/$l")" = AArch64 ] || err "桩库 $l 不是 AArch64"
    done
    # elfloader 只在 ET_DYN 上读 PT_INTERP,所以这里必须是 PIE + musl 解释器
    "$READELF" -l "$APPDIR/qtwl-demo" | grep -q "Requesting program interpreter: /lib/ld-musl-aarch64.so.1" \
        || err "qtwl-demo 的 PT_INTERP 不是 /lib/ld-musl-aarch64.so.1(elfloader 起不来)"

    LIST="$(tar -tf "$OUT_TAR")"
    for v in qtwl-demo libQt6Core.so libQt6Gui.so libQt6Widgets.so \
             libqwayland.so libxdg-shell.so "${STUB_LIBS[@]}" \
             plugins-probe/libqt-plugin-wayland-egl.so; do
        grep -qx "./$v" <<< "$LIST" || err "tar 里缺 $v"
    done
    log "✅ tar 自检通过:$OUT_TAR ($(du -h "$OUT_TAR" | cut -f1),$(wc -l <<< "$LIST") 个条目)"
}

do_app() {
    log "════ app 模式:可执行文件 + 依赖闭包 + 桩库 → $OUT_TAR ════"

    # 同名桩库只能待在这个 tar 里。要是混进 feature/bsh_main/libs/<abi>(HAP 的 libs 平铺目录,
    # 整套会话都能 dlopen 到),就会把 OHOS 系统库全局遮蔽掉 —— 那是事故。
    local s
    for s in "${STUB_LIBS[@]}"; do
        [ -e "$HAP_LIBS_DIR/$s" ] && err "别把桩库放进 $HAP_LIBS_DIR($s 在):会遮蔽系统库"
    done

    rm -rf "$APPDIR"; mkdir -p "$APPDIR"

    # ── 1. 可执行文件 ──────────────────────────────────────
    # 必须 PIE/ET_DYN:elfloader 只在 ET_DYN 上读 PT_INTERP;
    # --dynamic-linker 指向设备上的 musl ldso(build_musl.sh 交付的那份,不做文件映射);
    # -rpath=$ORIGIN 让同目录的 .so 优先于 /system/lib64(桩库能顶掉系统库的前提)。
    log "=== 编译 qtwl-demo(ET_DYN/PIE) ==="
    "$CLANGXX" --target="$TARGET" --sysroot="$SYSROOT" \
        -fPIE -pie -O1 -g0 -std=c++17 \
        -I"$QT_BUILD/include" -I"$QT_BUILD/include/QtCore" -I"$QT_BUILD/include/QtGui" \
        -I"$QT_BUILD/include/QtWidgets" -I"$SYSX/include" \
        "$DEMO_SRC/main.cpp" -o "$APPDIR/qtwl-demo" \
        -L"$QT_BUILD/lib" -lQt6Widgets -lQt6Gui -lQt6Core \
        -L"$SYSX_LIB" -lwayland-client \
        -Wl,-rpath,'$ORIGIN' -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 \
        || err "编译 qtwl-demo(PIE)失败"
    log "  interp: $("$READELF" -l "$APPDIR/qtwl-demo" | awk '/interpreter/{print $NF}')"

    # ── 2. 插件 ────────────────────────────────────────────
    # 平铺放顶层:设备侧 shell.cpp 把 QT_PLUGIN_PATH 指到 qtapp 目录,Qt 按目录平扫
    # (见 shell.cpp 的 qtapp 环境块),不按 platforms/ 这种插件目录约定找。
    # 图形集成那份单独放 plugins-probe/,只作探针用。
    log "=== 拷插件 ==="
    cp -f "$QT_BUILD/plugins/platforms/libqwayland.so" "$APPDIR/" || err "拷 libqwayland.so 失败"
    cp -f "$QT_BUILD/plugins/wayland-shell-integration/libxdg-shell.so" "$APPDIR/" || err "拷 libxdg-shell.so 失败"
    mkdir -p "$APPDIR/plugins-probe"
    cp -f "$QT_BUILD/plugins/wayland-graphics-integration-client/"*.so "$APPDIR/plugins-probe/" \
        || err "拷 wayland-graphics-integration-client 插件失败"

    # ── 3. 依赖闭包 ────────────────────────────────────────
    log "=== 按 NEEDED 闭包拷 Qt 依赖 ==="
    copy_needed_closure

    # ── 4. 桩库 ────────────────────────────────────────────
    log "=== 生成 $((${#STUB_LIBS[@]})) 个系统库桩 ==="
    gen_stubs

    # ── 5. strip ───────────────────────────────────────────
    # 必须 strip:Qt 是 -g 编出来的,不 strip 时这个闭包 ~550MB(libQt6Core 102MB、
    # libQt6Gui 191MB),打进 HAP 的 rawfile 后设备端解包要几分钟、还容易撞资源上限;
    # strip 后 ~100MB。--strip-unneeded 只删不影响动态链接的符号(.dynsym 保留),
    # 功能不变 —— device 上还能正常 dlopen/链接。
    log "=== strip(-unneeded) ==="
    local f
    for f in "$APPDIR"/*.so "$APPDIR/qtwl-demo" "$APPDIR/plugins-probe/"*.so; do
        [ -f "$f" ] || continue
        "$STRIP" --strip-unneeded "$f" 2>/dev/null || true
    done

    # ── 6. 打包 ────────────────────────────────────────────
    # tar 里是**平铺目录**(顶层直接是 qtwl-demo + 所有 .so,"." 起头),
    # 因为 UnpackRes 只是把 tar 解到 <sysroot>/qtapp 就完事,不会做路径重定位;
    # 平铺 + rpath=$ORIGIN 才让 ld.so 找到同目录的依赖。
    # 先写 .new 再 mv:all 模式下 app 前置缺失/中途失败时,上一次已部署的 tar 原封不动
    # (UnpackRes 会把半成品 tar 解成一个残目录,而它只是"解包"那一步的事)。
    log "=== 打包 → $OUT_TAR ==="
    mkdir -p "$(dirname "$OUT_TAR")"
    tar -cf "$OUT_TAR.new" -C "$APPDIR" . || err "打 tar 失败"
    mv -f "$OUT_TAR.new" "$OUT_TAR"

    verify_app

    log "目录清单($(du -sh "$APPDIR" | cut -f1),strip 前 ~550MB):"
    (cd "$APPDIR" && ls -la | awk 'NR>3{printf "  %10d  %s\n", $5, $9}')
    log "qtwl-demo 的 NEEDED:"
    "$READELF" -d "$APPDIR/qtwl-demo" | awk '/NEEDED|RUNPATH/{print "  "$0}'
    log "运行(shell.cpp 已代设):QT_QPA_PLATFORM=wayland QT_PLUGIN_PATH=<sysroot>/qtapp"
    log "  WAYLAND_DISPLAY/XDG_RUNTIME_DIR 由会话环境提供;stderr 就是会话终端(桩库的日志也走它)"
}

# ══════════════════════════════════════════════════════════
# 分发
# ══════════════════════════════════════════════════════════
case "$MODE" in
    so)
        require_so || err "so 模式前置缺失(见上面 warn 的那几行)"
        do_so
        ;;
    app)
        require_app || err "app 模式前置缺失(见上面 warn 的那几行)"
        do_app
        ;;
    all)
        built=""
        # 前置缺失只跳过该模式:两个模式的依赖集合不同,不该互相连坐
        if require_so; then do_so; built="$built so"; else warn "跳过 so 模式(前置缺失)"; fi
        if require_app; then do_app; built="$built app"; else warn "跳过 app 模式(前置缺失)"; fi
        [ -n "$built" ] || err "so/app 都没跑成(前置缺失),本次什么都没做,已有产物未动"
        log "✅ all 完成:$built"
        ;;
    *)
        err "未知模式:$MODE(可用 so|app|all)"
        ;;
esac
