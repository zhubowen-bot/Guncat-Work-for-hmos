#!/bin/bash
# fetch_pyqt.sh — 下载 PyQt6 / PyQt6-sip 源码(sdist)
#
# 产物(thirdparty/pyqt6-src/，已在 .gitignore 里)：
#   pyqt6-6.11.0/        PyQt6 sdist 解压（.sip 描述文件与 qpy/ 手写部分）
#   pyqt6_sip-13.9.1/    PyQt6-sip sdist 解压（运行时 sip 模块的 C 源）
#   *.tar.gz             原始 sdist（缓存，重跑不重复下载）
#
# Python 头文件/libpython 不从这里取：直接用本仓库 build_python.sh 的构建树
# （build/python/…）—— 版本与 ABI 跟设备上真正在跑的那份完全一致，
# 比外部预编译包更可靠。build_pyqt.sh 会去那里取 include 与 libpython3.12.a。
#
# 版本锁定：PyQt6 6.11.0 / PyQt6-sip 13.9.1（配 Qt 6.12 + CPython 3.12）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

PYQT_SRC_DIR="$ROOT/thirdparty/pyqt6-src"
PYQT6_VER="${PYQT6_VER:-6.11.0}"
SIP_VER="${SIP_VER:-13.9.1}"
# 与 build_pyqt.sh 一致：Python 头/库来源
PY_SRC="${PY_SRC:-$BUILD_DIR/python/src/Python-3.12.14}"
PY_BUILD="${PY_BUILD:-$BUILD_DIR/python/cpython-build}"

mkdir -p "$PYQT_SRC_DIR"

# ── 1. 前置：Python 头/库（build_python.sh 的产物）─────────
[ -f "$PY_SRC/Include/Python.h" ] \
    || err "缺 Python 头：$PY_SRC/Include/Python.h（先运行 scripts/build_python.sh）"
[ -f "$PY_BUILD/pyconfig.h" ] \
    || err "缺 pyconfig.h：$PY_BUILD（先运行 scripts/build_python.sh）"

# ── 2. 前置：host sip-build（PyQt-builder）───────────────
# 只用它生成绑定代码（--no-compile），所以运行它的 python 版本必须与目标一致：
# 生成物里的 include/ABI 判断来自 *运行它的* python 的 sysconfig —— 光看 PATH 上
# 有没有 python3.12 不算数（sip-build 可能来自别的 venv/pyenv），要读它的 shebang。
if ! command -v sip-build >/dev/null 2>&1; then
    err "缺 sip-build（pip install 'sip==6.15.3' PyQt-builder，或用 python3.12 建 venv）"
fi
SIP_BUILD_BIN="$(command -v sip-build)"
SIP_RUN_PY="$(sed -n '1s|^#!\([^ ]*\).*|\1|p' "$SIP_BUILD_BIN")"
sip_ver="$("$SIP_BUILD_BIN" --version 2>/dev/null || echo '?')"
py_ver="$("${SIP_RUN_PY:-python3}" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?')"
log "sip-build $sip_ver（运行它的 python：$py_ver）"
[ "$py_ver" = "3.12" ] || warn "sip-build 跑在 python $py_ver 上，但目标是 3.12 —— 生成的绑定可能按 $py_ver 的 sysconfig 来。建议：
      python3.12 -m venv ~/.venvs/pyqt && ~/.venvs/pyqt/bin/pip install 'sip==6.15.3' PyQt-builder
      然后把 ~/.venvs/pyqt/bin 放到 PATH 前面再跑本脚本"

# ── 3. 下载 PyPI sdist ───────────────────────────────────
PYPI_JSON="https://pypi.org/pypi"
fetch_sdist() { # <name> <ver> <解压后目录名>
    local name="$1" ver="$2" dir="$3"
    local tgz="$PYQT_SRC_DIR/$name-$ver.tar.gz"
    if [ ! -s "$tgz" ]; then
        log "下载 $name $ver sdist"
        local url
        url="$(curl -sL --retry 3 --connect-timeout 20 --max-time 120 "$PYPI_JSON/$name/$ver/json" \
            | python3 -c 'import json,sys
urls=[u["url"] for u in json.load(sys.stdin)["urls"] if u["packagetype"]=="sdist"]
print(urls[0] if urls else "")')" || true
        [ -n "$url" ] || err "取不到 $name $ver 的 sdist 地址（版本号写错？）"
        curl -sL --retry 3 --connect-timeout 20 --max-time 600 -o "$tgz" "$url" \
            || err "$name 下载失败：$url"
    fi
    [ -s "$tgz" ] || err "$tgz 为空"
    [ -d "$PYQT_SRC_DIR/$dir" ] || tar xzf "$tgz" -C "$PYQT_SRC_DIR"
    # 解压失败不吞掉：直接看目录在不在
    [ -d "$PYQT_SRC_DIR/$dir" ] || err "解压后没有 $dir（$tgz 坏了？）"
}

fetch_sdist PyQt6     "$PYQT6_VER" "pyqt6-$PYQT6_VER"
fetch_sdist PyQt6-sip "$SIP_VER"   "pyqt6_sip-$SIP_VER"

# PyQt6 的 sip 只生成一次；清掉旧 build/ 会让下次 build_pyqt.sh 重新生成
[ -f "$PYQT_SRC_DIR/pyqt6-$PYQT6_VER/pyproject.toml" ] \
    || err "PyQt6 源码结构异常：缺 pyproject.toml"
[ -f "$PYQT_SRC_DIR/pyqt6_sip-$SIP_VER/sip.h" ] \
    || err "PyQt6-sip 源码结构异常：缺 sip.h"

log "✅ PyQt 源码就绪：$PYQT_SRC_DIR"
