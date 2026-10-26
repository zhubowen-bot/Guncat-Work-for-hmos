#!/usr/bin/env bash
# Guncat Work: 在 qemu 里按"真机布局"跑一遍技术栈自检
#
# 真机布局有两条硬约束（详见 docs/architecture/python-third-party.md）：
#   1. 只有应用 lib 目录（entry/libs/arm64-v8a）里的 .so 能被 dlopen；
#   2. .py 必须来自可读的普通目录/zip（hvigor 打包时会把 libs 里的 .py 丢掉）。
# 所以自检时：extras.zip 解到临时目录，libs 只提供 .so，PYTHONPATH 顺序
#   stdlib.zip : site-packages.zip : <extras 解压目录> : <libs>
#
# 用法: bash tooling/python/run-verify-stack.sh [rootfs, 默认 $HOME/ohos-py-np/alpine-a64]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
ROOTFS="${1:-${GUNCAT_ROOTFS:-$HOME/alpine-a64}}"
[ -d "$ROOTFS" ] || ROOTFS="$HOME/ohos-py-np/alpine-a64"
LIBS="$PROJ/entry/libs/arm64-v8a"
RAW="$PROJ/entry/src/main/resources/rawfile/python"
TMP="${TMPDIR:-/tmp}/guncat-stack-$$"

[ -d "$ROOTFS" ] || { echo "找不到 Alpine rootfs: $ROOTFS" >&2; exit 2; }
[ -f "$LIBS/libpython3.12.so" ] || { echo "找不到目标 libpython: $LIBS" >&2; exit 2; }

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/data" "$TMP/fonts"
cp -f "$RAW"/fonts/*.otf "$TMP/fonts/" 2>/dev/null || true
cd "$TMP"
( cd "$TMP/data" && unzip -q "$RAW/extras.zip" )

GUNCAT_FONT_DIR="$TMP/fonts" \
PYTHONPATH="$RAW/python312.zip:$RAW/site-packages.zip:$TMP/data:$LIBS" \
PYTHONHOME="$ROOTFS/usr/local" \
LD_LIBRARY_PATH="$ROOTFS/usr/local/lib:$LIBS" \
LD_PRELOAD="$( [ -f "$ROOTFS/libs/libexecinfo_stub.so" ] && echo "$ROOTFS/libs/libexecinfo_stub.so" || echo "$LIBS/libexecinfo_stub.so" )" \
QEMU_LD_PREFIX="$ROOTFS" \
qemu-aarch64 -L "$ROOTFS" "$ROOTFS/usr/local/bin/python3.12" "$HERE/verify-python-stack.py"
