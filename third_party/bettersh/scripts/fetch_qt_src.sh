#!/bin/bash
# fetch_qt_src.sh — 拉取 qt-ohos 对应版本的 Qt 源码（qtbase + qtwayland，官方原版）
#
# 版本固定（对应 /workspace/dev/qt-ohos/qt-ohos 工作树 HEAD）：
#   qtbase    682d16763cf16a6c47e016af68c24946d232312b  (v6.12.0-beta1-395)
#   qtwayland 58518ecabfe4d1b371c1b2748196849976b6ecbe  (v6.12.0-beta3)
#
# 产物：$QT_SRC_DIR/{qtbase,qtwayland} —— 官方原版（未应用 qt-ohos 本地修改）。
# qt-ohos 的本地适配（OHOS 平台/wayland 构建 + PyQt6 protected→public 头 patch）
# 在 scripts/qtbase-ohos.patch / scripts/qtwayland-ohos.patch，构建前应用。
#
# 用法：./scripts/fetch_qt_src.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

QT_SRC_DIR="${QT_SRC_DIR:-$ROOT/thirdparty/qt-src}"
QT_BASE_COMMIT="682d16763cf16a6c47e016af68c24946d232312b"
QT_WAYLAND_COMMIT="58518ecabfe4d1b371c1b2748196849976b6ecbe"

mkdir -p "$QT_SRC_DIR"

# 下载 ohos-extra（Qt 三方库附加包；已就绪则跳过）
QT_EXTRA_DIR="$ROOT/thirdparty/ohos-extra/additional-packages"
if [ ! -d "$QT_EXTRA_DIR/include" ]; then
    log "下载官方附加包 → thirdparty/ohos-extra"
    _extra_zip="$ROOT/thirdparty/ohos-extra.zip"
    curl -sL --connect-timeout 20 --max-time 600 \
        "https://drive.google.com/uc?export=download&id=1muyUjBPS8B0CLEoLAhtGgxNY6C6W7TTl&confirm=t" \
        -o "$_extra_zip" || err "ohos-extra 下载失败"
    echo "fe3b77744659922977efd926b54a2534ff142f6a  $_extra_zip" | sha1sum -c - \
        || err "ohos-extra sha1 校验失败"
    mkdir -p "$ROOT/thirdparty/ohos-extra"
    unzip -o -q "$_extra_zip" -d "$ROOT/thirdparty/ohos-extra"
    rm -f "$_extra_zip"
    [ -d "$QT_EXTRA_DIR/include" ] || err "ohos-extra 解压异常: $QT_EXTRA_DIR"
fi
unset QT_EXTRA_DIR

fetch_mod() {
    local name="$1" commit="$2"
    local dir="$QT_SRC_DIR/$name"
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
        log "$name 已就绪（$commit）"
        return
    fi
    if [ ! -d "$dir/.git" ]; then
        log "克隆 $name（blob:none 部分克隆）..."
        git clone --filter=blob:none --no-checkout \
            "https://github.com/qt/$name.git" "$dir"
    fi
    log "checkout $name @ $commit"
    (cd "$dir" && git fetch origin "$commit" && git checkout "$commit")
}

fetch_mod qtbase "$QT_BASE_COMMIT"
fetch_mod qtwayland "$QT_WAYLAND_COMMIT"
log "✅ Qt 源码就绪: $QT_SRC_DIR（构建前应用 scripts/qtbase-ohos.patch / qtwayland-ohos.patch）"
