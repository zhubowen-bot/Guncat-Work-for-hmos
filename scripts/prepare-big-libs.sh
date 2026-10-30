#!/usr/bin/env bash
# prepare-big-libs.sh — 从 *.xz 还原体积超过 GitHub 单文件上限的随包库。
#
# 为什么有大文件是压缩态：GitHub 拒绝 >100MB 的单文件，libnode.so 有 108MB。
# 仓库里存的是 libnode.so.xz（约 23MB），克隆后、打包 HAP 前跑一次本脚本即可；
# 已经有 .so 的（比如刚跑过 build_node.sh）不会被覆盖。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/third_party/bettersh/iec/platform/ohos/har/libs/arm64-v8a"

restore() {
    local name="$1"
    if [[ -f "$LIB/$name" ]]; then
        return 0
    fi
    if [[ ! -f "$LIB/$name.xz" ]]; then
        echo "prepare-big-libs: 既没有 $name 也没有 $name.xz（$LIB）" >&2
        return 1
    fi
    if ! command -v xz >/dev/null 2>&1; then
        echo "prepare-big-libs: 需要 xz 解压 $name.xz" >&2
        return 1
    fi
    xz -dc "$LIB/$name.xz" > "$LIB/$name.tmp"
    mv "$LIB/$name.tmp" "$LIB/$name"
    echo "prepare-big-libs: 已还原 $name"
}

restore libnode.so
