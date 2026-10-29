#!/bin/bash
# build_hap.sh — 构建 BetterSH HAP（hvigorw assembleHap）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

[ -x "$TOOL_HOME/bin/hvigorw" ] || err "hvigorw 未找到（$TOOL_HOME/bin/hvigorw）。请安装 DevEco command-line-tools 或设 TOOL_HOME。"

# ── 打包前的半成品自查 ────────────────────────────────────────────────
# bundle libs 里那些**用 -Wl,--wrap= 接 shim 的命令 so**（见 scripts/shim-wrap-flags.sh）
# 只要 wrap 清单与实际链进去的 .o 不匹配，就会出现未定义的 `__wrap_*`（引用被改写了，
# 但没人定义）或未定义的 `__real_*`（我们的兜底没被链接器改回真名）—— 两者都会让
# **dlopen 直接失败、整个命令用不了**，而编译期毫无提示。所以在这里统一拦一道：
# 宁可打包失败，也别把一个用不了的命令装到设备上（实测曾这样漏过去三个产物）。
log "=== 打包前自查：bundle libs 里有没有半成品命令 so ==="
_bad=0
for so in "$HAP_LIBS_DIR"/*.so; do
    [ -f "$so" ] || continue
    # 只认**以 __wrap_/__real_ 开头**的符号:用子串匹配会被 C++ 的 mangling 骗到 ——
    # libc++ 有个内部迭代器类型叫 `__wrap_iter`,它的名字会出现在
    # `_ZNSt4__n1...insertENS_11__wrap_iterIPKcEEc` 这类符号里,于是 libnode.so 被误判成
    # "半成品"(实测 Node 22 打包时拦了一次)。真要拦的是 `U __wrap_execve` 这种。
    und_names="$("$CLANG_DIR/llvm-nm" -D -u "$so" 2>/dev/null | awk '{print $NF}' | grep -E '^(__wrap_|__real_)' || true)"
    und="$(printf '%s' "$und_names" | grep -c . || true)"
    if [ "$und" != "0" ]; then
        echo "  [!] $(basename "$so")：$und 个未定义的 __wrap_/__real_ 符号（wrap 清单与 .o 不匹配）" >&2
        printf '%s\n' "$und_names" | head -5 | sed 's/^/      /' >&2
        _bad=1
    fi
done
[ "$_bad" = "0" ] || err "有半成品命令 so（见上）—— 对应的 build_*.sh 需要重跑；别打包"

cd "$ROOT"
log "=== 构建 HAP (product=$BSH_PRODUCT, $NATIVE_ARCH, buildMode=${BUILD_MODE:-debug}) ==="
"$TOOL_HOME/bin/hvigorw" assembleHap \
    --mode module \
    -p module="$BSH_PRODUCT@default" \
    -p product=default \
    -p buildMode="${BUILD_MODE:-debug}" \
    --no-daemon

log "✅ build_hap.sh 完成"
log "产物: $(ls -t "$HAP_OUT_DIR"/*.hap 2>/dev/null | head -1 || echo "见 product/$BSH_PRODUCT/build 目录")"
