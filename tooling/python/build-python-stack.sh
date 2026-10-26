#!/usr/bin/env bash
# Guncat Work: 一键重建整套原生 Python 技术栈（CPython + 全部三方库 + 打包 + 自检）
#
# 每一步都是幂等的：产物已存在就跳过（用 FORCE=1 可强制重编某一层）。
#
#   bash tooling/python/build-python-stack.sh              # 从头补齐所有缺失的层
#   FORCE=1 bash tooling/python/build-python-stack.sh mpl  # 只重编 matplotlib 相关
#
# 阶段划分：
#   deps     OpenSSL / SQLite / bzip2 / xz（CPython 的 C 依赖）
#   cpython  交叉编译 CPython 3.12
#   pure     21+ 个纯 Python 包 → site-packages.zip
#   numpy    numpy 2.1.3          → libs/numpy + extras
#   pandas   pandas 2.2.3 + libffi/_ctypes
#   pillow   Pillow 11 + libpng/libjpeg-turbo
#   mpl      matplotlib 3.9 + freetype/qhull/kiwisolver/contourpy
#   lxml     lxml 5.3 + libxml2/libxslt
#   crypto   PyCryptodome 3.21
#   misc     regex / psutil
#   extras   把各库的 .py 汇总进 rawfile/python/extras.zip
#   verify   用 qemu 按真机布局跑一遍自检
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
LIBS="$PROJ/entry/libs/arm64-v8a"
RAW="$PROJ/entry/src/main/resources/rawfile/python"
EXTRAS="${EXTRAS:-/root/extras}"
ROOTFS="${GUNCAT_ROOTFS:-$HOME/alpine-a64}"
WANT="${1:-all}"

run() {  # 名字 脚本
  local name="$1" script="$2"
  if [ "$WANT" != "all" ] && [ "$WANT" != "$name" ]; then
    return 0
  fi
  echo
  echo "=============================================================="
  echo "== $name"
  echo "=============================================================="
  bash "$HERE/$script"
}

has() { [ -e "$1" ]; }

# ---------- 1. 基础依赖 + CPython ----------
if [ "$WANT" = "all" ] || [ "$WANT" = "deps" ] || [ "$WANT" = "cpython" ]; then
  if ! has "$LIBS/libpython3.12.so" || [ "${FORCE:-0}" = "1" ]; then
    run deps build-native-deps.sh
    run cpython build-cpython-ohos.sh
  else
    echo "== cpython: 已存在，跳过"
  fi
fi

# ---------- 2. 纯 Python 包 ----------
if [ "$WANT" = "all" ] || [ "$WANT" = "pure" ]; then
  run pure vendor-pure.sh
  mkdir -p "$EXTRAS"
  # vendor 脚本会把带数据文件的包单独放这里
  if [ -d "$PROJ/../ohos-py-vendor/extras-pkgs" ]; then
    cp -r "$PROJ/../ohos-py-vendor/extras-pkgs/." "$EXTRAS/" 2>/dev/null || true
  fi
fi

# ---------- 3. C / C++ 扩展 ----------
for stage in numpy:build-numpy-ohos.sh pandas:build-pandas-ohos.sh \
             pillow:build-pillow-ohos.sh mpl:build-matplotlib-ohos.sh \
             lxml:build-lxml-ohos.sh crypto:build-pycryptodome-ohos.sh \
             misc:build-misc-ohos.sh; do
  name="${stage%%:*}"; script="${stage##*:}"
  if [ "$WANT" = "all" ] || [ "$WANT" = "$name" ]; then
    run "$name" "$script"
  fi
done

# ---------- 4. 汇总 extras.zip ----------
if [ "$WANT" = "all" ] || [ "$WANT" = "extras" ]; then
  echo
  echo "== extras: 汇总 $EXTRAS"
  # sitecustomize 必须在 extras（真实目录），不能进 zip
  cp -f "$HERE/local-pkgs/sitecustomize.py" "$EXTRAS/sitecustomize.py"
  find "$EXTRAS" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  rm -f "$RAW/extras.zip"
  ( cd "$EXTRAS" && zip -qr0 "$RAW/extras.zip" . )
  ls -lh "$RAW/extras.zip" | awk '{print "   extras.zip:", $5}'
fi

# ---------- 5. 自检 ----------
if [ "$WANT" = "all" ] || [ "$WANT" = "verify" ]; then
  echo
  echo "== verify: qemu 按真机布局自检"
  SSL_CERT_FILE="$RAW/cacert.pem" bash "$HERE/run-verify-stack.sh" "$ROOTFS"
fi

echo
echo "完成。产物：$LIBS 与 $RAW"
