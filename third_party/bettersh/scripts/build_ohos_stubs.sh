#!/bin/bash
# build_ohos_stubs.sh — 为 box64 造 OHOS 上缺失的系统库「空 stub」
#
# 背景：box64 的 native wrapper 会按 x86 guest 记录的名字去 dlopen 一批"x86 世界里
# 常见"的系统库。OHOS 把这些功能合并进了 musl 的 libc（例如 resolver），既没有独立
# 的 libresolv.so，SDK sysroot 里也只有静态桩 libresolv.a。于是箱子里加载一个
# NEEDED 了 libresolv.so.2 的 guest 时，dlopen 直接失败。
#
# 办法：造一个**空**的共享库，只满足"文件存在 + 能 dlopen"两件事；符号查找由 box64
# 自己的 wrapper 接管。
#
# 产物：$HAP_LIBS_DIR/ 下每个名字一个真文件：
#         libresolv.so.2   与   libresolv.so。
#
# 用法：./scripts/build_ohos_stubs.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# 要造哪些空 stub，需要时往这里加。
# 加之前先确认 OHOS/Linux 两边都真的没有这个 .so —— 脚本下面有一条自检会拦
# （往 $HAP_LIBS_DIR 里塞一个和系统同名的空库，会把它**遮蔽**掉，那是事故）。
_STUB_LIBS=(
    "libresolv.so.2"
    "libresolv.so"
)

STAGE="$ROOT/build/ohos-stubs"
STUB_C="$STAGE/stub.c"

SYSROOT="$OHOS_SDK/native/sysroot"
CC="$OHOS_SDK/native/llvm/bin/clang"
READELF="$CLANG_DIR/llvm-readelf"
SYSROOT_LIB="$SYSROOT/usr/lib/$TARGET"          # aarch64-linux-ohos

[ -x "$CC" ] || err "缺编译器：$CC（检查 OHOS_SDK=$OHOS_SDK）"
[ -d "$SYSROOT_LIB" ] || err "缺 sysroot 库目录：$SYSROOT_LIB"

rm -rf "$STAGE"
mkdir -p "$STAGE"

# ── 1. 自检：这些名字必须是 OHOS 上真没有的 ──────────────────
log "=== 1) 确认这些库在 OHOS 上确实不存在 ==="
for name in "${_STUB_LIBS[@]}"; do
    if [ -e "$SYSROOT_LIB/$name" ]; then
        err "$name 在 sysroot 里已存在（$SYSROOT_LIB）—— 别 stub 它，会遮蔽真库"
    fi
    printf '    %-20s 系统里没有 ✓\n' "$name"
done

# ── 2. 生成空的 stub 源码 ─────────────────────────────────
# 内容为空（只有注释）是刻意的：这里不需要任何符号，只要一个合法的共享对象。
cat > "$STUB_C" <<'EOF'
/*
 * Empty stub shared library for OHOS.
 *
 * OHOS musl 把 resolver 等功能内置在 libc.so 里，没有独立的 libresolv.so，
 * 但 box64 加载 x86 程序时仍会去 dlopen libresolv.so.2。
 * 这个空 stub 只为满足存在性检查，符号查找由 box64 wrapper 处理。
 *
 * 由 scripts/build_ohos_stubs.sh 生成，勿手改。
 */
EOF

# ── 3. 编译 ───────────────────────────────────────────────
log "=== 2) 编译 → $STAGE ==="
for name in "${_STUB_LIBS[@]}"; do
    "$CC" --target="$TARGET" --sysroot="$SYSROOT" \
        -shared -fPIC -Wl,-soname,"$name" \
        -o "$STAGE/$name" "$STUB_C" > "$STAGE/$name.log" 2>&1 \
        || { tail -20 "$STAGE/$name.log" >&2; err "$name 编译失败"; }
    printf '    %-20s %s\n' "$name" "$(du -h "$STAGE/$name" | cut -f1)"
done

# ── 4. 校验 ───────────────────────────────────────────────
log "=== 3) 校验（架构 / SONAME）==="
for name in "${_STUB_LIBS[@]}"; do
    f="$STAGE/$name"
    # 走临时文件而非管道：set -o pipefail 下 grep -q 提前关管道会 SIGPIPE 误报
    "$READELF" -h "$f" > "$STAGE/.h" 2>/dev/null || err "readelf 失败：$name"
    grep -q AArch64 "$STAGE/.h" || err "$name 不是 AArch64"
    "$READELF" -d "$f" > "$STAGE/.d" 2>/dev/null || true
    got=$(sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p' "$STAGE/.d" | head -1)
    [ "$got" = "$name" ] || err "$name 的 SONAME 是 '$got'，与文件名不一致"
    nneed=$(grep -c 'NEEDED' "$STAGE/.d" || true)
    printf '    %-20s AArch64 ✓  SONAME=%s ✓  NEEDED=%s\n' "$name" "$got" "$nneed"
done
rm -f "$STAGE/.h" "$STAGE/.d"

# ── 5. 交付 ───────────────────────────────────────────────
# feature/bsh_main/libs/<abi>/ 是唯一会被 hvigor 打进 HAP 且运行时可加载的目录（详见
# build_qt.sh 第 6 段）。这里直接平铺进去，运行期和 libbox64.so 同处一个搜索路径。
log "=== 4) 复制到 $HAP_LIBS_DIR ==="
mkdir -p "$HAP_LIBS_DIR"
for name in "${_STUB_LIBS[@]}"; do
    cp -f "$STAGE/$name" "$HAP_LIBS_DIR/$name" || err "复制 $name 失败"
done
log "✅ 完成："
for name in "${_STUB_LIBS[@]}"; do
    log "   $HAP_LIBS_DIR/$name"
done
log "   注：这些是空库，只为让 box64 的 dlopen 不失败；符号由 box64 wrapper 提供"
