#!/usr/bin/env bash
# Guncat Work: 交叉编译 regex 与 psutil（两个"小而常用"的 C 扩展）
#
# regex  —— 支持 \p{Han} / \p{Emoji} / \p{Nd} 等 Unicode 属性正则、可变长度后顾、\X 字素簇，
#           正好补上标准库 re 的短板。Apache-2.0。
# psutil  —— 进程 / 内存 / 磁盘 / 线程数等系统信息。BSD-3-Clause。
#
# 唯一的坑：**psutil 的 setup.py 会再起一个 qemu 进程**跑它编出来的测试程序，
# 嵌套调用不带 `-L`，必须设 QEMU_LD_PREFIX，否则报
#   qemu-aarch64: Could not open '/lib/ld-musl-aarch64.so.1'
#
# 用法: bash tooling/python/build-misc-ohos.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
NP="${NPWORK:-$HOME/ohos-py-np}"
TC="${TC:-/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony/native}"
CLANG="$TC/llvm/bin/aarch64-unknown-linux-ohos-clang"
STRIP="$TC/llvm/bin/llvm-strip"
LIBS="$PROJ/entry/libs/arm64-v8a"
ROOTFS="$NP/alpine-a64"
WORK="${WORK:-$HOME/ohos-py-misc}"
PYINC="${PYINC:-/root/cpython-ohos/dest/usr/local/include/python3.12}"
PYLIB="${PYLIB:-/root/cpython-ohos/dest/usr/local/lib}"
EXTRAS="${EXTRAS:-/root/extras}"

mkdir -p "$WORK" "$EXTRAS"

fetch() {  # 包名 版本
  local pkg="$1" ver="$2"
  cd "$WORK"
  [ -d "$pkg-$ver" ] && return 0
  local url
  url=$(curl -s "https://pypi.org/pypi/$pkg/$ver/json" | python3 -c \
    "import sys,json;d=json.load(sys.stdin);print([u['url'] for u in d['urls'] if u['packagetype']=='sdist'][0])")
  curl -sL -o "$pkg-$ver.tar.gz" "$url"
  tar xzf "$pkg-$ver.tar.gz"
}

build_ext() {  # 目录
  cd "$1"
  export CC="$CLANG"
  export LDSHARED="$CLANG --sysroot=$TC/sysroot -shared -fuse-ld=lld"
  export CFLAGS="--sysroot=$TC/sysroot -O2 -fPIC -I$PYINC"
  export LDFLAGS="--sysroot=$TC/sysroot -fuse-ld=lld -L$PYLIB"
  export QEMU_LD_PREFIX="$ROOTFS"     # psutil 会嵌套起 qemu
  rm -rf build
  "$ROOTFS/run-python.sh" setup.py build_ext --inplace
}

# ---------- regex ----------
fetch regex 2024.11.6
build_ext "$WORK/regex-2024.11.6"
rm -rf "$LIBS/regex" && mkdir -p "$LIBS/regex"
cp -f "$WORK"/regex-2024.11.6/regex_3/_regex*.so "$LIBS/regex/"
rm -rf "$EXTRAS/regex" && mkdir -p "$EXTRAS/regex"
cp -f "$WORK"/regex-2024.11.6/regex_3/__init__.py \
      "$WORK"/regex-2024.11.6/regex_3/_regex_core.py \
      "$WORK"/regex-2024.11.6/regex_3/regex.py "$EXTRAS/regex/"

# ---------- psutil ----------
fetch psutil 6.1.0
build_ext "$WORK/psutil-6.1.0"
rm -rf "$LIBS/psutil" && mkdir -p "$LIBS/psutil"
cp -f "$WORK"/psutil-6.1.0/psutil/*.so "$LIBS/psutil/"
rm -rf "$EXTRAS/psutil" && cp -r "$WORK/psutil-6.1.0/psutil" "$EXTRAS/psutil"
find "$EXTRAS/psutil" -name '*.so' -delete

find "$LIBS/regex" "$LIBS/psutil" -name '*.so' -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true

echo "== 产物"
find "$LIBS/regex" "$LIBS/psutil" -name '*.so' | wc -l
echo "== .py 已放到 $EXTRAS/{regex,psutil}"
