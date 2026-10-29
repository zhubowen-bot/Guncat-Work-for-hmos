#!/bin/bash
# build_box64.sh — 交叉编译 box64 为 OHOS arm64 的命令 so（libbox64.so）
#
# 目标：在不能 exec 的沙箱里跑 **x86_64** Linux ELF。box64 是 x86_64→ARM64 的动态
# 翻译器（dynarec）。
#
# 与 HarmonyBox 的关系：编译方式（cmake 开关、补丁来源）照搬
# /workspace/dev/HarmonyBox/build.sh。补丁集在 scripts/box64-ohos/（原来是它的
# patches.sh 逐字副本 scripts/patch_box64.sh，2026-10-03 重构成「新文件覆盖 +
# 一条一个 patch 文件」，见该目录的 README.md）。本脚本与之的差别：
#   1) 源码由本脚本自己 git clone 到 thirdparty/box64（已在 .gitignore 里），
#      不是 git submodule —— 与 Qt 那条线（fetch_qt_src.sh + build_qt.sh）同一路子；
#   2) 产物直接落到 feature/bsh_main/libs/arm64-v8a/（$HAP_LIBS_DIR，唯一会被打进 HAP 且
#      运行时可加载的目录）；
#   3) 多编一层入口包装 bsh_box64_entry —— 我们的 procmgr 入口约定是
#      int(*)(int,char**)（见 procmgr.cpp 的 EntryFn），而 box64_run 是三参数
#      (argc, argv, env)。
#
# 补丁集布局（scripts/box64-ohos/）：
#   files/            我们自己的新文件，按源码树镜像摆放，构建时整份覆盖
#   patches/series    清单；patches/NNNN-*.patch 是对上游文件的就地修改（patch -p1）
#   vendor/           musl-fts / musl-obstack 的上游源码与 LICENSE（**仅供溯源**：
#                     它们的内容已经固化进 files/src/{musl_fts.c,musl_obstack.c}
#                     与 files/src/include/{fts.h,obstack.h}，构建不再联网 clone）
#
# 前置：OHOS SDK（env.sh 的 $OHOS_SDK）。首次运行需要网络（clone box64 本体）；
#       打完补丁之后就不再需要网络。
#
# 产物：$HAP_LIBS_DIR/libbox64.so
#
# 用法：./scripts/build_box64.sh [--no-reset] [--jobs N]
#   --no-reset  **只复用现有源码树，不重新铺文件/打补丁**（认标记文件
#               `.bsh-box64-patched` 或 files/ 里的 musl_compat.c 在不在）。
#               改了补丁集要重打，走默认路径（会 git reset --hard + clean -fdx）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

BOX64_SRC_DIR="${BOX64_SRC_DIR:-$ROOT/thirdparty/box64}"
# shim 源码目录：fs_shim.c 会被**同一份源码**编进 libbox64.so（`-DBSH_SHIM_BOX64`），
# 让 box64 的 guest 也拿到软链模拟等语义。见 scripts/box64-ohos/README.md「box64 内置 shim」。
SHIM_SRC_DIR="$ROOT/feature/bsh_main/src/main/cpp/shim"
# procmgr 目录：tty shim 要用它的 RPC 客户端（bsh_client.c/.h，纯 socket）——
# termios/winsize 的真相在主进程那边。见 README「box64 内置 shim」。
PROCMGR_SRC_DIR="$ROOT/feature/bsh_main/src/main/cpp/procmgr"
BOX64_REPO="${BOX64_REPO:-https://github.com/ptitSeb/box64.git}"
# 钉死版本：补丁集是贴着这个 commit 写的，换版本必然大量失配。
# 与 /workspace/dev/HarmonyBox/box64 的 HEAD 完全相同（v0.4.3-3-37-gbefc90de1）。
BOX64_COMMIT="${BOX64_COMMIT:-befc90de1ce4214ac720b2f1c154b8c896d7d202}"

BUILD_DIR_B="$ROOT/build/box64"
BOX64_BUILD="$BUILD_DIR_B/build"

RESET=1; JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-reset) RESET=0 ;;
        --jobs)     JOBS="$2"; shift ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done

# SDK 自带 cmake/ninja：env.sh 为规避 SDK 的非 GNU diff 把 /usr/bin 前置，
# 不显式指定会解析到系统版（见 build_qt.sh 的踩坑记录）。
SDK_CMAKE="$OHOS_SDK/native/build-tools/cmake/bin/cmake"
SDK_NINJA="$OHOS_SDK/native/build-tools/cmake/bin/ninja"
OHOS_TOOLCHAIN="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake"
for f in "$SDK_CMAKE" "$SDK_NINJA" "$OHOS_TOOLCHAIN"; do
    [ -e "$f" ] || err "缺 $f（检查 OHOS_SDK=$OHOS_SDK）"
done

mkdir -p "$BUILD_DIR_B"

# ── 1. 源码：克隆 / 检出到钉死的 commit ─────────────────────
if [ ! -d "$BOX64_SRC_DIR/.git" ]; then
    log "克隆 box64 → $BOX64_SRC_DIR"
    git clone "$BOX64_REPO" "$BOX64_SRC_DIR" || err "clone box64 失败（网络？）"
fi
if [ "$(git -C "$BOX64_SRC_DIR" rev-parse HEAD 2>/dev/null || true)" != "$BOX64_COMMIT" ]; then
    log "检出 box64 @ ${BOX64_COMMIT:0:7}"
    git -C "$BOX64_SRC_DIR" fetch --depth 1 origin "$BOX64_COMMIT" || true
    git -C "$BOX64_SRC_DIR" checkout -f "$BOX64_COMMIT" \
        || err "checkout $BOX64_COMMIT 失败"
fi

# 每次重建都先把源码恢复成干净状态：补丁是就地 patch，幂等判断只能防重复，防不了
# 半途失败留下的中间态（而且 CMake 构建期还会重写 src/wrapped*/generated/* 与
# src/emu/x64printer.c，reset --hard 顺手把它们还原）。
if [ "$RESET" = 1 ]; then
    log "复位源码（git clean -fdx）"
    git -C "$BOX64_SRC_DIR" reset --hard "$BOX64_COMMIT" >/dev/null
    git -C "$BOX64_SRC_DIR" clean -fdx >/dev/null
fi

# ── 2. 铺新文件 + 应用补丁系列 ─────────────────────────────
# 二八分：
#   files/   我们自己的新文件（musl_compat.c、box64_spawn.c、path_remap.c、fts/obstack/error.h …），
#            按源码树镜像摆放，整份覆盖进去 —— 不做成补丁，因为我们本来就是它们的主人；
#   patches/ 对**上游文件**的就地修改，一条一个 patch，清单见 patches/series。
# 两者都贴着 $BOX64_COMMIT 写（见 scripts/box64-ohos/README.md），换版本必然大量失配。
SPEC_DIR="$SCRIPT_DIR/box64-ohos"
PATCH_STAMP="$BOX64_SRC_DIR/.bsh-box64-patched"
log "=== 2) 铺新文件（box64-ohos/files/）+ 应用补丁系列（patches/series）==="
[ -d "$SPEC_DIR/files" ] || err "缺 $SPEC_DIR/files"
[ -f "$SPEC_DIR/patches/series" ] || err "缺 $SPEC_DIR/patches/series"

# 幂等靠**一个标记文件**，不是逐条 `patch -R --dry-run`：
# 这个系列里有 10 条以上改同一个文件（wrappedlibc.c 被 0006/0007/0013/0028…0034 反复改），
# 后一条会把前一条的部分行再改一遍，于是"反向试打"对其中 11 条判不出来（实测），
# 会误判成"没打过"重打一遍 → 直接失败。标记文件由本步骤打完时 touch，
# 复位分支的 `git clean -fdx` 会把它删掉，所以"复位 → 重打"这条路依然正确。
if [ "$RESET" = 0 ] && { [ -f "$PATCH_STAMP" ] || [ -f "$BOX64_SRC_DIR/src/musl_compat.c" ]; }; then
    # 第二个探针是给"升级到本版之前就已经打好的树"留的：那时还没有标记文件，
    # 但 files/ 里的 musl_compat.c 一定在。
    log "  复用已就绪的源码树（--no-reset），跳过铺文件与打补丁"
else
    cp -a "$SPEC_DIR/files/." "$BOX64_SRC_DIR/"
    APPLIED=0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        p="$SPEC_DIR/patches/$line"
        [ -f "$p" ] || err "series 里列了不存在的补丁：$line"
        (cd "$BOX64_SRC_DIR" && patch -p1 --forward --batch --no-backup-if-mismatch < "$p") \
            >> "$BUILD_DIR_B/patch.log" 2>&1 \
            || { tail -20 "$BUILD_DIR_B/patch.log" >&2
                 err "补丁失败：$line（源码已和 $BOX64_COMMIT 分叉？或树是半打状态，跑一次不带 --no-reset 的完整构建）"; }
        APPLIED=$((APPLIED+1))
    done < "$SPEC_DIR/patches/series"
    log "  补丁：本次应用 $APPLIED 条"
    touch "$PATCH_STAMP"
fi

# 入口包装 bsh_box64_entry.c（procmgr 约定 int(*)(int,char**)）与它的 CMake 注册
# 都由 files/ + 0035-cmake-ohos-sources.patch 提供，这里不再生成任何源码。

# ── 3. configure ──────────────────────────────────────────
# 开关与 HarmonyBox build.sh 逐项一致（含 BOX32：i386 guest 支持）。整套补丁集本来就
# 是带着 BOX32 一起维护的，先按"完整"编，跑通后再决定要不要裁。
WARN_FLAGS=$(
    cat <<'EOF' | tr '\n' ' '
-Wno-macro-redefined
-Wno-unused-command-line-argument
-Wno-format
-Wno-format-security
-Wno-error=format-security
-Wno-deprecated-declarations
-Wno-unused-function
-Wno-unused-variable
-Wno-unused-but-set-variable
-Wno-int-conversion
-Wno-error=int-conversion
-Wno-incompatible-pointer-types
-Wno-implicit-function-declaration
-Wno-string-plus-int
-Wno-array-bounds
-Wno-ignored-pragmas
EOF
)

log "=== 3) configure（BOX32=ON, SHARED, OHOS_ARCH=$NATIVE_ARCH）==="
rm -rf "$BOX64_BUILD"
mkdir -p "$BOX64_BUILD"
(
    cd "$BOX64_BUILD" || exit 1
    "$SDK_CMAKE" "$BOX64_SRC_DIR" \
        -GNinja \
        -DCMAKE_MAKE_PROGRAM="$SDK_NINJA" \
        -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
        -DOHOS_ARCH="$NATIVE_ARCH" \
        -DOHOS_PLATFORM=OHOS \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DARM_DYNAREC=ON \
        -DBOX32=ON \
        -DGENERIC_ARM=1 \
        -DNOLOADADDR=1 \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS="$WARN_FLAGS" \
        -DCMAKE_CXX_FLAGS="$WARN_FLAGS" \
        -DBSH_SHIM_DIR="$SHIM_SRC_DIR" \
        -DBSH_PROCMGR_DIR="$PROCMGR_SRC_DIR" \
        > "$BUILD_DIR_B/configure.log" 2>&1
) || { tail -30 "$BUILD_DIR_B/configure.log" >&2; err "configure 失败（$BUILD_DIR_B/configure.log）"; }

# ── 4. 编 ────────────────────────────────────────────────
log "=== 4) ninja box64 -j$JOBS（耗时较长）==="
(cd "$BOX64_BUILD" && "$SDK_NINJA" box64 -j"$JOBS" > "$BUILD_DIR_B/build.log" 2>&1) \
    || { tail -40 "$BUILD_DIR_B/build.log" >&2; err "编译失败（$BUILD_DIR_B/build.log）"; }

# ── 5. 产物校验 ───────────────────────────────────────────
SO="$BOX64_BUILD/libbox64.so"
[ -f "$SO" ] || SO="$(find "$BOX64_BUILD" -maxdepth 3 -name 'libbox64.so' -type f | head -1)"
[ -n "$SO" ] && [ -f "$SO" ] || {
    echo "构建目录里的 .so 实际产物：" >&2
    find "$BOX64_BUILD" -maxdepth 3 -type f \( -name '*.so' -o -name 'box64' \) | sed 's/^/    /' >&2
    err "找不到 libbox64.so"
}

READELF="$CLANG_DIR/llvm-readelf"
NM="$CLANG_DIR/llvm-nm"
# 架构检查走临时文件而非管道：set -o pipefail 下 grep -q 提前关管道会 SIGPIPE 误报
"$READELF" -h "$SO" > "$BUILD_DIR_B/.arch-check" 2>/dev/null || true
grep -q AArch64 "$BUILD_DIR_B/.arch-check" || err "libbox64.so 非 AArch64"
rm -f "$BUILD_DIR_B/.arch-check"

# 导出符号：procmgr 要 dlsym 的只有 bsh_box64_entry 这一个（box64_run 是它内部调的）。
# 别把 box64_main / box64_install_sigsys_fallback 当成必须导出的 —— 它们是内部符号，
# 上游也没让它们出去（CMakeLists 的全局 -fvisibility=hidden）：
# 前者只被 box64_so_entry.c 引用，后者被它调用并另有 constructor 兜底。
EXPORTS="$("$NM" -D --defined-only "$SO" 2>/dev/null \
    | grep -wE 'bsh_box64_entry|box64_run' || true)"
for want in bsh_box64_entry box64_run; do
    printf '%s\n' "$EXPORTS" | grep -qw "$want" \
        || err "导出符号缺 $want（bsh_box64_entry 少了 __attribute__((visibility(\"default\")))? 见 scripts/box64-ohos/files/src/bsh_box64_entry.c）"
done
log "导出符号："; printf '%s\n' "$EXPORTS" | sed 's/^/    /' >&2

# NEEDED 自检：只应依赖 libc；其它依赖要靠包内 libs/ 解析，多一条都要先确认设备上有
NEEDED="$("$READELF" -d "$SO" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | sort -u)"
log "NEEDED："; printf '%s\n' "$NEEDED" | sed 's/^/    /' >&2

# ── 6. 交付 ──────────────────────────────────────────────
log "=== 6) 复制到 $HAP_LIBS_DIR ==="
mkdir -p "$HAP_LIBS_DIR"
cp -f "$SO" "$HAP_LIBS_DIR/libbox64.so" || err "复制失败"
log "✅ libbox64.so → $HAP_LIBS_DIR/libbox64.so ($(du -h "$HAP_LIBS_DIR/libbox64.so" | cut -f1))"
log "   注：hvigor 打包时会 strip libs/ 下的 .so（HAP 内会小很多），此处保留 debug 信息"
log "   下一步：终端里跑 box64 <x86_64 程序>（命令表见 procmgr/command_map.c）"
