#!/usr/bin/env bash
# Guncat Work: 取 Linux VM 的基础素材(内核 + Alpine 底座镜像)。
#
# 用法: bash tooling/linux-vm/fetch-assets.sh
#   PROJ=/path/to/repo      指定工程根(默认自动推断)
#   WORK=$HOME/hish-tci-build  底座镜像落在这里, 供 build-rootfs.sh 使用
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$HERE/../.." && pwd)}"
WORK="${WORK:-$HOME/hish-tci-build}"
RAW="$PROJ/entry/src/main/resources/rawfile/vm"

KERNEL_URL="${KERNEL_URL:-https://github.com/harmoninux/linux-config/releases/download/kernel-20260228/kernel_aarch64}"
ALPINE_URL="${ALPINE_URL:-https://github.com/harmoninux/linux-config/releases/download/alpine-20251205/rootfs_aarch64.qcow2}"

mkdir -p "$RAW" "$WORK"

fetch() {
  url="$1"
  dst="$2"
  if [ -s "$dst" ]; then
    echo "== 已存在, 跳过: $dst"
    return 0
  fi
  echo "== 下载 $url"
  curl -L --retry 3 --retry-delay 2 -o "$dst.part" "$url"
  mv "$dst.part" "$dst"
  ls -l "$dst"
}

fetch "$KERNEL_URL" "$RAW/kernel_aarch64"
fetch "$ALPINE_URL" "$WORK/alpine-base.qcow2"

echo "== 完成"
echo "   内核     : $RAW/kernel_aarch64"
echo "   Alpine 底座: $WORK/alpine-base.qcow2  (下一步交给 build-rootfs.sh)"
