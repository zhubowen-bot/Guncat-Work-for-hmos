#!/bin/bash
# pack_ohos_sdk_prune.sh — 把 OHOS command-line-tools 里的 `sdk/default/openharmony`
# 裁成一个能给 pkg 发的包（`ohos-sdk-prune`）。
#
# 为什么值得裁（2026-10-02 实测，见 README「在 qemu 下编 C++ 库…」那一节同一批数据）：
#   原 zip 1788 MiB → 只打 openharmony（zstd -19）597 MiB → 再裁 392 MiB。
#   裁掉的是**自举用不到的**：docs、lldb 全家、LLVM 开发工具（clang-tidy/opt/llc…）、
#   非本机目标的运行时（arm32 / x86_64 的 clang-rt 与 libc++）、LLVM 的 python。
#
# 这个脚本在"能发出去"这个约束下还多做了三件事：
#   1) **去符号链接**：`pkg` 的 tar 解包器（programs/pkg/bsh_tar.c）只认普通文件/目录，
#      沙箱里也建不出软链。所以把需要留的别名（clang / clang++ / ld.lld / llvm-ranlib…）
#      展开成**真文件的副本**，其余别名直接删。副本靠 `--long=27` 的 zstd 窗口去重，
#      压缩后基本不涨。
#   2) **补 glibc ABI 闭包**：SDK 的 aarch64 clang 是 glibc 二进制，NEEDED 里有
#      libc.so.6/libm.so.6/libpthread.so.0/librt.so.1/libdl.so.2/libgcc_s.so.1，
#      而 SDK 自己和当前 HAP **都没带**这些（HAP 只有 ld-linux + libc.so.6）。
#      放进 `native/llvm/lib/`，因为 clang 的 RUNPATH 正是 `$ORIGIN/../lib`，不用设
#      LD_LIBRARY_PATH 就能被 ld.so 找到。
#   3) **自检**：扫 llvm/bin 里每个可执行文件的 NEEDED，凡是既不在本树
#      `native/llvm/lib`、又不属于 glibc 闭包/系统 soname 的，直接报错退出 ——
#      免得打出一个"装上去才发现缺库"的包。
#
# ⚠ 保留 glibc 的 `libLLVM*/libclang*/libLTO*` 吗：**不留**。实测 llvm/bin 下的工具
#   全是静态链接进 LLVM 的（NEEDED 里只有 glibc），那些 .so 只有"外部程序链 LLVM C API"
#   才用得上；留着的代价是 ~310 MiB。要改这个决定，删掉下面 DROP_LIBS 那几行即可。
#
# 用法：
#   scripts/pack_ohos_sdk_prune.sh [zip 路径]
#   产出：dist/pkgs/ohos-sdk-prune.tar.zst（+ 打印 size/sha256，供 index.json 用）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZIP="${1:-/mnt/c/Users/suwan/Downloads/commandline-tools-linux-arm64-26.0.0.851.zip}"
BENCH="$ROOT/build/clt"
SRC_TREE="$BENCH/x/command-line-tools/sdk/default/openharmony"
PKG="$BENCH/pkg/opt/ohos-sdk"
DEST="$PKG/openharmony"
OUT_DIR="$ROOT/dist/pkgs"
OUT="$OUT_DIR/ohos-sdk-prune.tar.zst"
JOBS="$(nproc)"

[ -f "$ZIP" ] || err "找不到 zip：$ZIP"
command -v zstd >/dev/null || err "缺 zstd（apt install zstd）"

# ── 只解 openharmony 子树（一次；已有就复用）──────────────────────────────
if [ ! -d "$SRC_TREE" ]; then
    log "=== 解压 sdk/default/openharmony（只要这棵子树）==="
    mkdir -p "$BENCH"
    unzip -q "$ZIP" 'command-line-tools/sdk/default/openharmony/*' -d "$BENCH/x"
fi
[ -d "$SRC_TREE" ] || err "解压后找不到 $SRC_TREE"

# ── 组装包树（硬链接复制，秒级；后面改的是副本的目录项）─────────────────
log "=== 组装 $PKG ==="
rm -rf "$BENCH/pkg"
mkdir -p "$PKG"
cp -al "$SRC_TREE" "$DEST"

# 裁掉的东西。分三档，出问题好回溯：
PRUNE_LIST='
native/docs
native/llvm/python3
native/llvm/bin/python
native/llvm/bin/clang-check
native/llvm/bin/clang-tidy
native/llvm/bin/clangd
native/llvm/bin/opt
native/llvm/bin/llc
native/llvm/bin/dsymutil
native/llvm/bin/llvm-dwp
native/llvm/bin/lldb
native/llvm/bin/lldb-argdumper
native/llvm/bin/lldb-server
native/llvm/bin/lldb-vscode
native/llvm/bin/lldb.sh
native/llvm/bin/llvm-cfi-verify
native/llvm/bin/sancov
native/llvm/bin/sanstats
native/llvm/lib/libpython3.12.so.1.0
native/llvm/lib/liblldb.so
native/llvm/lib/liblldb.so.15
native/llvm/lib/liblldb.so.15.0.4
native/llvm/lib/liblldbIntelFeatures.so
native/llvm/lib/liblldbIntelFeatures.so.15
native/llvm/lib/libompd.so
native/llvm/lib/libclang-cpp.so
native/llvm/lib/libclang-cpp.so.15
native/llvm/lib/libclang.so
native/llvm/lib/libclang.so.15
native/llvm/lib/libclang.so.15.0.4
native/llvm/lib/libLLVM-15.so
native/llvm/lib/libLLVM-15.0.4.so
native/llvm/lib/libLLVM.so
native/llvm/lib/libLTO.so
native/llvm/lib/libLTO.so.15
native/llvm/lib/libRemarks.so
native/llvm/lib/libRemarks.so.15
native/llvm/lib/libomp.so
native/llvm/lib/libgomp.so
native/llvm/lib/libiomp5.so
native/llvm/lib/libomptarget.so
native/llvm/lib/libomptarget.so.15
native/llvm/lib/clang/15.0.4/lib/arm-linux-ohos
native/llvm/lib/clang/15.0.4/lib/x86_64-linux-ohos
native/llvm/lib/clang/15.0.4/lib/x86_64-unknown-linux-gnu
native/llvm/lib/arm-linux-ohos
native/llvm/lib/x86_64-linux-ohos
native/llvm/bin/clang-cl
native/llvm/bin/clang-cpp
native/llvm/bin/ld64.lld
native/llvm/bin/lld-link
native/llvm/bin/llvm-addr2line
'
while read -r p; do
    case "$p" in \#*|"") continue;; esac
    rm -rf "${DEST:?}/$p"
done <<< "$PRUNE_LIST"

# ── 去符号链接：需要的展开成真副本，其余删掉 ─────────────────────────────
# 判据是"谁在构建流程里被按名字调用"：CMake/hvigor 会叫 clang / clang++ / ld.lld；
# ar/ranlib 由 CMake 的 ar 变量或 `ar s` 路径走到；readelf/strip 给调试脚本用。
log "=== 展开需要的别名（真副本），删掉其余符号链接 ==="
KEEP_COPY="clang clang++ ld.lld llvm-ranlib llvm-readelf llvm-strip"
for name in $KEEP_COPY; do
    f="$DEST/native/llvm/bin/$name"
    [ -L "$f" ] || continue
    target="$(readlink "$f")"
    rm -f "$f"
    cp -f "$DEST/native/llvm/bin/$target" "$f"
done
# 剩下的符号链接一律删（沙箱建不出、解包器也不认）
find "$DEST" -type l -print -delete | sed 's/^/    删除软链: /'

# ── glibc ABI 闭包：放进 native/llvm/bin/ ────────────────────────────────
# ⚠ 放 `llvm/lib/` 靠 clang 的 RUNPATH($ORIGIN/../lib) **在我们这个沙箱里不成立**：
#   guest 的 `/proc/self/exe` 是宿主 appspawn(elfloader 不改它)，ld.so 算出来的 $ORIGIN
#   指向宿主目录 —— 设备上实测就是
#       clang: error while loading shared libraries: libpthread.so.0: cannot open
#   （fs_shim 的 /proc/self/exe 替身救不了这一步：ld.so 自己读它，LD_PRELOAD 拦不到）。
#   能用的那条路是 LD_LIBRARY_PATH —— procmgr 在 ChildRunElf 里会把 **guest 自己所在
#   目录** 塞进 LD_LIBRARY_PATH，所以闭包跟 clang 放同一个目录，ld.so 一定找得到。
# libc.so.6/ld-linux 用随 HAP 走的那份（bundle libs 里也有同名文件，一致）；
# libm/libpthread/librt/libdl 来自我们自编的 glibc 构建；libgcc_s 必须是 **glibc 版**
# （musl 那份的 NEEDED 是 `libc.so`，在设备上会被解析成 musl libc —— 一个进程里塞两个
# libc 必炸）。
log "=== 补 glibc ABI 闭包到 native/llvm/bin/ ==="
GLIBC_B="$ROOT/build/glibc/b"
GCC_CROSS="$(ls -d /usr/lib/gcc-cross/aarch64-linux-gnu/* 2>/dev/null | tail -1 || true)"
ARM_LIBGCC="/usr/aarch64-linux-gnu/lib/libgcc_s.so.1"
L="$DEST/native/llvm/bin"
cp -fL "$ROOT/feature/bsh_main/libs/arm64-v8a/ld-linux-aarch64.so.1" "$L/" 2>/dev/null || warn "缺 ld-linux（靠 HAP 提供）"
cp -fL "$ROOT/feature/bsh_main/libs/arm64-v8a/libc.so.6"            "$L/" 2>/dev/null || warn "缺 libc.so.6（靠 HAP 提供）"
for p in math/libm.so.6 nptl/libpthread.so.0 rt/librt.so.1 dlfcn/libdl.so.2; do
    [ -e "$GLIBC_B/$p" ] && cp -fL "$GLIBC_B/$p" "$L/" || warn "缺 glibc 件 $p"
done
[ -f "$ARM_LIBGCC" ] || [ -n "$GCC_CROSS" ] || err "找不到 aarch64 的 glibc 版 libgcc_s.so.1"
if [ -f "$ARM_LIBGCC" ]; then cp -fL "$ARM_LIBGCC" "$L/"; else
    err "请自行提供 glibc 版 libgcc_s.so.1（musl 那份不能用）"; fi

# ── 自检：llvm/bin 每个可执行文件的 NEEDED 都必须落在本树里 ──────────────
log "=== 自检：动态依赖是否齐 ==="
RE="$OHOS_SDK/native/llvm/bin/llvm-readelf"
[ -x "$RE" ] || RE="$(command -v readelf)"
bad=0
for exe in "$DEST"/native/llvm/bin/*; do
    [ -f "$exe" ] || continue
    file -b "$exe" | grep -q ELF || continue
    while read -r lib; do
        [ -n "$lib" ] || continue
        if [ -e "$L/$lib" ] || [ -e "$DEST/native/llvm/bin/$lib" ]; then continue; fi
        echo "    [!] $(basename "$exe") 需要 $lib —— 本树里没有" >&2
        bad=1
    done < <("$RE" -d "$exe" 2>/dev/null \
             | awk '/NEEDED/{gsub(/[\[\]]/,"",$NF); print $NF}' \
             | grep -Ev '^(libc\.so\.6|ld-linux-aarch64\.so\.1)$')
done
[ "$bad" = "0" ] || err "有工具缺依赖（见上）—— 先补齐再打包"
log "自检通过：llvm/bin 下工具的动态依赖都能在本树里找到"

# ── 打 tar.zst ───────────────────────────────────────────────────────────
log "=== 打包（zstd -19 --long=27 -T$JOBS，长窗口用来给 clang/clang++ 这类副本去重）==="
mkdir -p "$OUT_DIR"
tar -C "$BENCH/pkg" -c opt | zstd -q -f -19 --long=27 -T"$JOBS" -o "$OUT"

RAW=$(du -sb "$PKG" | cut -f1)
log "包内未压缩 $(numfmt --to=iec "$RAW")  →  $OUT $(numfmt --to=iec "$(stat -c%s "$OUT")")"
echo
echo "index.json 需要的两项："
echo "  \"file\"   : $(basename "$OUT")"
echo "  \"size\"   : $(stat -c%s "$OUT")"
echo "  \"sha256\" : $(sha256sum "$OUT" | cut -d' ' -f1)"
