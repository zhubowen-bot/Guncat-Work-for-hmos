#!/bin/bash
# build_qt.sh — 交叉编译 Qt wayland 客户端栈（qtbase，含 Qt6WaylandClient + libqwayland）
#
# 前置：scripts/fetch_qt_src.sh 已拉取源码（thirdparty/qt-src/qtbase，官方原版）
# 产物（build-target/）：
#   lib/libQt6{Core,Gui,Widgets,WaylandClient}.so    AArch64
#   plugins/platforms/libqwayland.so                  wayland QPA 插件
#   plugins/wayland-shell-integration/libxdg-shell.so xdg-shell 集成
#   lib/cmake/Qt6/qt.toolchain.cmake                  后续编译 qtwl-demo 用
#
# 第 6 段会把库与插件平铺复制到 feature/bsh_main/libs/<abi>/（唯一会被 hvigor 打进 HAP
# 且运行时可加载的目录；子目录会被丢掉），toolchain 文件留在 build-target。
#
# 关键约束（踩坑记录，勿改）：
#   1. cmake/ninja 必须用 SDK 自带（build-tools/cmake/bin）——env.sh 为规避 SDK
#      非 GNU diff 把 /usr/bin 前置，会令 cmake 解析到系统版（3.28.3）导致 configure
#      的 openssl/EGL/node-api 检测全部失败；SDK 自带 cmake（3.28.2）正常。
#   2. CMAKE_FIND_ROOT_PATH 必须同时含：
#        - ohos-extra/additional-packages（freetype/fontconfig/ICU/napi/openssl 头）
#        - waymony 的 sysroot-ext（libwayland-client/cursor 等）
#   3. 必须 clean configure：增量 configure 的 feature 缓存会让 FEATURE_wayland
#      残留 OFF（qtbase 的 wayland feature 默认关），clean 后 ON。
#   4. Qt 6.12 的 libQt6WaylandClient.so 由 qtbase 构建（qtwayland 只剩 compositor/插件）。
#   5. patch 应用检测用文件 grep（勿用 git apply --check：qtbase 为 blob:none 部分
#      克隆，git 操作触发 promisor fetch，会导致随后的 configure openssl 头检测失败）。
#
# 用法：./scripts/build_qt.sh [--force] [--no-clean] [--jobs N]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

QT_SRC_DIR="${QT_SRC_DIR:-$ROOT/thirdparty/qt-src}"
QT_BASE="$QT_SRC_DIR/qtbase"
BUILD_DIR_QT="$QT_BASE/build-target"

# ── Qt 专用环境（qt-ohos 验证过）──────────────────────────
QT_SDK="${QT_SDK:-$OHOS_SDK}"
QT_HOST="${QT_HOST:-$QT_SRC_DIR/qtbase/build-host}"
QT_EXTRA="${QT_EXTRA:-$ROOT/thirdparty/ohos-extra/additional-packages}"
QT_SYSX="${QT_SYSX:-$ROOT/build/sysroot-ext-$NATIVE_ARCH/usr}"
QT_PATCH="$SCRIPT_DIR/qtbase-ohos.patch"

FORCE=0; CLEAN=1; JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"
for arg in "$@"; do
    case "$arg" in
        --force)  FORCE=1 ;;
        --no-clean) CLEAN=0 ;;
        --jobs)   JOBS="$2"; shift ;;
        *) echo "未知参数: $arg"; exit 2 ;;
    esac
done

[ -f "$QT_BASE/CMakeLists.txt" ] || err "Qt 源码缺失: $QT_BASE（先运行 scripts/fetch_qt_src.sh）"
[ -f "$QT_PATCH" ] || err "patch 缺失: $QT_PATCH"
[ -d "$QT_SDK/native" ] || err "Qt SDK 缺失: $QT_SDK（需 API 23 = native 6.1.0.31）"
[ -d "$QT_EXTRA/include" ] || err "ohos-extra 缺失: $QT_EXTRA（thirdparty/ohos-extra）"
[ -d "$QT_SYSX/include" ] || err "waymony sysroot-ext 缺失: $QT_SYSX（先运行 build_wayland.sh）"

# env.sh 为规避 SDK 非 GNU diff 把 /usr/bin 前置，会令 cmake/ninja 解析到系统版；
# Qt 构建须用 SDK 自带 cmake/ninja（与 qt-ohos 构建环境一致）
export PATH="$OHOS_SDK/native/build-tools/cmake/bin:$PATH"

# ── 1. 构建 host Qt（moc/qmake/qtwaylandscanner）工具 ──────────────
log "构建 host 版 → $QT_HOST（约 30 min）"
mkdir -p "$QT_HOST"
(
    cd "$QT_HOST" || exit 1
    ../configure -release -developer-build -opensource -confirm-license \
        -nomake examples -nomake tests -no-dbus >/dev/null || exit 1
    cmake --build . --parallel "$JOBS" >/dev/null || exit 1
) || err "host Qt 构建失败"

# ── 2. 应用 qtbase-ohos.patch（官方原版 → waymony 适配；已应用则跳过）──
# 检测用文件内容 grep（勿用 git apply --check：qtbase 为 blob:none 部分克隆，
# git 操作触发 promisor 网络 fetch，实测会导致随后的 configure 的 openssl 头
# 检测失败——脚本内 configure 必失败、手动 configure 成功，唯一差异即此 git 命令）
if ! grep -q 'NOT QNX AND NOT ANDROID' "$QT_BASE/src/gui/configure.cmake" 2>/dev/null; then
    git -C "$QT_BASE" apply "$QT_PATCH"
    log "qtbase-ohos.patch 已应用"
else
    log "qtbase-ohos.patch 已应用（跳过）"
fi

# ── 3. configure（clean 保证 feature 缓存正确）──────────────
if [ "$CLEAN" = 1 ] && [ -d "$BUILD_DIR_QT" ]; then
    rm -rf "$BUILD_DIR_QT"
fi
if [ ! -f "$BUILD_DIR_QT/CMakeCache.txt" ] || [ "$FORCE" = 1 ]; then
    mkdir -p "$BUILD_DIR_QT"
    log "=== configure qtbase（SDK $QT_SDK, FIND_ROOT_PATH=ohos-extra;sysroot-ext）==="
    (cd "$BUILD_DIR_QT" && ../configure \
        -developer-build -nomake tests -debug -no-dbus \
        -no-use-gold-linker -no-pch -openssl-runtime \
        -ohos-sdk "$QT_SDK" \
        -qt-host-path "$QT_HOST" \
        -verbose \
        -- "-DCMAKE_FIND_ROOT_PATH=$QT_EXTRA;$QT_SYSX") \
        || err "configure 失败（日志见 build-target/config.log）"
    # 校验 wayland feature 已开启（Qt 6.12 的 WaylandClient 由 qtbase 构建）
    if ! grep -q "FEATURE_wayland:BOOL=ON" "$BUILD_DIR_QT/CMakeCache.txt"; then
        err "FEATURE_wayland 未开启——请 clean 后重试（增量 configure 会残留 OFF）"
    fi
    log "✓ FEATURE_wayland=ON / wayland_client=ON"
else
    log "configure 已就绪（--force 重新配置）"
fi

# ── 4. 编译 ──────────────────────────────────────────────
log "=== 编译 qtbase（-j$JOBS，约 20-40 分钟）==="
(cd "$BUILD_DIR_QT" && cmake --build . --parallel "$JOBS") || err "编译失败"

# ── 5. 产物验证 ──────────────────────────────────────────
for f in lib/libQt6Core.so lib/libQt6Gui.so lib/libQt6Widgets.so \
         lib/libQt6WaylandClient.so plugins/platforms/libqwayland.so \
         plugins/wayland-shell-integration/libxdg-shell.so; do
    [ -f "$BUILD_DIR_QT/$f" ] || err "产物缺失: $f"
done
# 架构检查：经临时文件而非管道（set -o pipefail 下 grep -q 提前关管道 → SIGPIPE → 误报）
"$CLANG_DIR/llvm-readelf" -h "$BUILD_DIR_QT/lib/libQt6WaylandClient.so" 2>/dev/null \
    > "$BUILD_DIR_QT/.arch-check" || true
grep -q AArch64 "$BUILD_DIR_QT/.arch-check" \
    || err "libQt6WaylandClient.so 非 AArch64"
rm -f "$BUILD_DIR_QT/.arch-check"

# ── 6. 复制到 HAP 库目录 ────────────────────────────────────
# feature/bsh_main/libs/<abi>/ 是唯一会被 hvigor 打进 HAP 且运行时可加载的目录：
# HAP 内 libs/<abi>/ → 设备侧 /data/storage/el1/bundle/libs/arm64/，命令 so 的
# DT_NEEDED 由那里解析。实测 hvigor 只收这一层目录下的 *.so（子目录会被丢掉），
# 所以插件也平铺进来，由调用方按名字给路径（如 QT_QPA_PLATFORM_PLUGIN_PATH）。
QT_LIBS=(libQt6Core.so libQt6Gui.so libQt6Widgets.so libQt6WaylandClient.so)
QT_PLUGINS=(platforms/libqwayland.so wayland-shell-integration/libxdg-shell.so)
# Qt 库的外部依赖里有几个**设备系统里没有**（SDK sysroot 里查不到），必须一起
# 随包，否则运行期 dlopen 直接失败：fontconfig/png16/freetype（图形/字体）、
# ICU 三个（Qt6Core 硬依赖）。它们来自 ohos-extra，SONAME 与 NEEDED 完全一致。
QT_EXTRA_LIBS=(libfontconfig.so libfreetype.so libexpat.so libpng16.so
               libicudata.so libicui18n.so libicuuc.so)

log "=== 6) 复制到 $HAP_LIBS_DIR ==="
mkdir -p "$HAP_LIBS_DIR"
for f in "${QT_LIBS[@]}"; do
    cp -f "$BUILD_DIR_QT/lib/$f" "$HAP_LIBS_DIR/" || err "复制 $f 失败"
done
for p in "${QT_PLUGINS[@]}"; do
    cp -f "$BUILD_DIR_QT/plugins/$p" "$HAP_LIBS_DIR/$(basename "$p")" \
        || err "复制插件 $p 失败"
done
for f in "${QT_EXTRA_LIBS[@]}"; do
    cp -f "$QT_EXTRA/lib/$f" "$HAP_LIBS_DIR/" || err "复制 $f 失败（ohos-extra 里没有？）"
done
# 集合自检：Qt 库之间按 NEEDED 互相引用，清单里少一个就是运行期 undefined symbol
for f in "${QT_LIBS[@]}"; do
    for n in $("$CLANG_DIR/llvm-readelf" -d "$HAP_LIBS_DIR/$f" 2>/dev/null \
               | sed -n 's/.*Shared library: \[\(libQt6[^]]*\)\].*/\1/p' | sort -u); do
        printf '%s\n' "${QT_LIBS[@]}" | grep -qx "$n" \
            || err "$f 依赖 $n，但它不在 QT_LIBS 清单里（把它加进清单）"
    done
done
# 依赖闭包自检：已随包的每个 Qt 相关库，其 NEEDED 必须能在（包内 or SDK sysroot）
# 找到。SDK sysroot 就是设备 /system/lib64 的镜像，所以这条等价于"设备上能解析"。
# 不这么做的话，漏一个库要到设备上跑起来才炸。
SYSROOT_LIB="$QT_SDK/native/sysroot/usr/lib/aarch64-linux-ohos"
MISSING=""
for f in "$HAP_LIBS_DIR"/libQt6*.so "$HAP_LIBS_DIR"/libqwayland.so \
         "$HAP_LIBS_DIR"/libxdg-shell.so "$HAP_LIBS_DIR"/libqtwl-demo.so \
         "$HAP_LIBS_DIR"/libfontconfig.so "$HAP_LIBS_DIR"/libfreetype.so \
         "$HAP_LIBS_DIR"/libexpat.so "$HAP_LIBS_DIR"/libpng16.so \
         "$HAP_LIBS_DIR"/libicu*.so; do
    [ -f "$f" ] || continue
    for n in $("$CLANG_DIR/llvm-readelf" -d "$f" 2>/dev/null \
               | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
        case "$n" in
            libc++_shared.so) continue ;;   # hvigor 打 native 库时自动带上(HAP 里已有)
        esac
        [ -e "$HAP_LIBS_DIR/$n" ] && continue
        [ -e "$SYSROOT_LIB/$n" ] && continue
        MISSING="$MISSING $(basename "$f")→$n"
    done
done
[ -z "$MISSING" ] \
    || err "以下依赖包内和设备系统都没有，运行期会 dlopen 失败：$MISSING"

log "✅ Qt wayland 栈编译完成: $BUILD_DIR_QT"
log "  工具链: $BUILD_DIR_QT/lib/cmake/Qt6/qt.toolchain.cmake（编译 qtwl-demo 用）"
log "已复制到 $HAP_LIBS_DIR:"
log "  库  : ${QT_LIBS[*]}"
log "  插件: libqwayland.so libxdg-shell.so（原 plugins/ 下带类别目录，这里平铺）"
log "  注: hvigor 打包时会 strip libs/ 下的 .so（HAP 内会小很多），此处保留 debug 信息"
