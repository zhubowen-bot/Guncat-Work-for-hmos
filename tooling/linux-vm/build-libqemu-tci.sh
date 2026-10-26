#!/usr/bin/env bash
# Guncat Work: 交叉编译 TCG 解释器(TCI)版 QEMU —— 无 JIT、无受限权限。
#
# 产物: libqemu-system-aarch64-tci.so / libqemu-img.so / libslirp.so.0
# 用法: TOOL_HOME=/opt/ohos-cmdline/command-line-tools bash build-libqemu-tci.sh
#       FORCE=1 强制重编全部依赖库; FORCE_QEMU=1 只强制重编 QEMU
#
# 配方来自 HiSH (MIT License, Copyright (c) 2025 hackeris) 的 deps/ 目录,
# 仅改为不依赖 HiSH 工程结构、统一走 QEMU_TCI=1 构建, 并做了受限网络的下载源替换。
#
# 增量: 依赖库编好一次就记 .built-<pkg> 标记, 重跑不会再编(zstd/zlib/pcre2/glib/pixman
#       合计约十分钟, QEMU 本体才是大头)。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_HOME="${TOOL_HOME:-/opt/ohos-cmdline/command-line-tools}"
WORK="${WORK:-$HOME/hish-tci-build}"
FORCE="${FORCE:-0}"
FORCE_QEMU="${FORCE_QEMU:-0}"

OHOS_SDK_HOME="$TOOL_HOME/sdk/default/openharmony"
CLANG="$OHOS_SDK_HOME/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
if [ ! -x "$CLANG" ]; then
  echo "ERROR: 找不到 HarmonyOS aarch64 clang: $CLANG" >&2
  echo "       请设置 TOOL_HOME 指向 HarmonyOS Command Line Tools 解压目录" >&2
  exit 1
fi

export DEVECO_SDK_HOME="$TOOL_HOME/sdk"
export OHOS_SDK_HOME
export OHOS_ARCH=aarch64
export OHOS_ABI=arm64-v8a
export QEMU_TCI=1

echo "== toolchain: $($CLANG --version | head -1)"
echo "== work dir : $WORK"

mkdir -p "$WORK"
# 只同步配方文件, 保留已下载的源码与已编好的 buildroot
mkdir -p "$WORK/deps"
cp -r "$HERE/deps/." "$WORK/deps/"
cd "$WORK/deps"

build_pkg() {
  pkg="$1"
  marker=".built-$pkg"
  if [ "$FORCE" != "1" ] && [ -f "$marker" ]; then
    echo "===== [$pkg] 已构建, 跳过 (FORCE=1 可重编)"
    return 0
  fi
  echo "===== [$pkg] build start"
  make -C "$pkg"
  touch "$marker"
  echo "===== [$pkg] ok"
}

for pkg in zstd zlib pcre2 libglib pixman; do
  build_pkg "$pkg"
done

if [ "$FORCE_QEMU" = "1" ]; then
  rm -f .built-libqemu
fi
echo "===== [libqemu] build start (TCI)"
make -C libqemu
touch .built-libqemu
echo "===== [libqemu] ok"

echo "===== artifacts in $WORK/deps/output"
ls -l "$WORK/deps/output"
