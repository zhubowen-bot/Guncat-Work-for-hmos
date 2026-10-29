#!/usr/bin/env bash
# run.sh — toybox applet 解析交叉验证入口。
#
# 用仓库里的同一份 toybox 源码（third_party/bettersh/iec/thirdparty/toybox）
# 在宿主 x86_64 上 `make defconfig && make`，把产物放到 /tmp/toybox-host（或
# $TOYBOX_HOST），再交给 check.py 复刻 ArkTS 的解析与 launcher 优先级。
#
#   bash third_party/bettersh/iec/tests/toybox_parse/run.sh
#   TOYBOX_HOST=/tmp/my-toybox bash .../run.sh
#   TOYBOX_PARSE_FORCE_BUILD=1 bash .../run.sh   # 强制重编
#
# 源码/产物时间戳没变时直接复用已有二进制；不会改动仓库里的 toybox 源树
# （复制到临时目录再构建）。不连设备、不需要 HarmonyOS SDK、不访问网络。
#
# 依赖：bash、python3、cc、make、tar。缺少时退出 77（check-all.sh 记为 SKIP）；
# 构建失败退出 2；断言失败由 check.py 返回 1。
#
# 用 defconfig 而不是设备脚本那套 applet 开关：宿主版本只用来验证**解析器**，
# 不要求 applet 集合与设备完全一致。两套 config 的差异见 README.md。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IEC_ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$IEC_ROOT/thirdparty/toybox"
BIN="${TOYBOX_HOST:-/tmp/toybox-host}"

for tool in python3 cc make tar; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "toybox_parse: 找不到 $tool" >&2
        exit 77
    }
done
[ -f "$SRC/Makefile" ] || {
    echo "toybox_parse: 找不到 toybox 源码 $SRC" >&2
    exit 2
}

needs_build=0
if [ ! -x "$BIN" ]; then
    needs_build=1
elif [ "${TOYBOX_PARSE_FORCE_BUILD:-0}" = "1" ]; then
    needs_build=1
else
    # 只看向宿主构建真正有意义的输入；generated/ 与 .config 是上次设备构建的
    # 残留，构建时会在临时副本里重新生成，不参与判定。
    newer="$(find "$SRC/toys" "$SRC/lib" "$SRC/kconfig" \
        "$SRC/Makefile" "$SRC/Config.in" "$SRC/main.c" "$SRC/toys.h" \
        -newer "$BIN" -print -quit 2>/dev/null || true)"
    [ -n "$newer" ] && needs_build=1
fi

if [ "$needs_build" = "1" ]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/toybox_parse.XXXXXX")" || exit 2
    cleanup() { rm -rf "$WORK"; }
    trap cleanup EXIT
    mkdir -p "$WORK/src"
    echo "==> 复制 toybox 源码到 $WORK/src" >&2
    tar -C "$SRC" --exclude=./.git --exclude=./generated --exclude=./.config \
        -cf - . | tar -C "$WORK/src" -xf -

    jobs="${TOYBOX_PARSE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
    cd "$WORK/src"
    echo "==> make defconfig" >&2
    if ! make defconfig HOSTCC="${HOSTCC:-cc}" >"$WORK/defconfig.log" 2>&1; then
        echo "toybox_parse: make defconfig 失败：" >&2
        tail -n 40 "$WORK/defconfig.log" >&2 || true
        exit 2
    fi
    echo "==> make -j$jobs（宿主 x86_64）" >&2
    if ! make -j"$jobs" HOSTCC="${HOSTCC:-cc}" >"$WORK/build.log" 2>&1; then
        echo "toybox_parse: toybox 构建失败：" >&2
        tail -n 60 "$WORK/build.log" >&2 || true
        exit 2
    fi
    [ -x toybox ] || {
        echo "toybox_parse: 构建结束但没找到 toybox" >&2
        exit 2
    }
    mkdir -p "$(dirname "$BIN")"
    install -m 0755 toybox "$BIN.tmp.$$"
    mv -f "$BIN.tmp.$$" "$BIN"
    echo "==> 产物: $BIN" >&2
else
    echo "==> 复用 $BIN（源码未更新；强制重编用 TOYBOX_PARSE_FORCE_BUILD=1）" >&2
fi

export TOYBOX_HOST="$BIN"
exec python3 "$HERE/check.py" "$@"
