#!/bin/bash
# build_test.sh — 设备自测的固定入口：**release 构建模式 + `debug-jit` 签名**（+ 部署/拉起）。
#
# 为什么要有这么个脚本（签名不是随便挑的）：
#   1) 设备自测要能横向比，**每次的签名必须一样**。而 HAP 里的 `app.debug`（由 hvigor 的
#      buildMode 决定）会改变文件沙箱的严格度 —— 同一个 guest：debug 构建
#      （`app.debug=true`）30 过 / 0 挂，release 构建（`false`）29 过 / 1 挂，差的正是
#      硬链接那一档（非 debug 应用不给 `link(2)`）。两种混着测，等于每次都在比不同的东西。
#   2) 真正的 `release` signingConfig 签出来的包 **hdc 装不上**：
#      `code:9568322 signature verification failed due to not trusted app source`
#      （发布型 profile 设备不信任）—— 所以"release 构建模式"只能用 debug 类型的 profile 验证。
#   3) `debug-jit` 正好两者都满足：debug 类型 profile（能装）+ `ALLOW_WRITABLE_CODE_MEMORY`
#      这条 restricted ACL（`bshutil caps` 报 `jit=yes route=anon-rwx`）。
#
# 用法：
#   scripts/build_test.sh                    # 出包 → 部署 → 拉起（autorun 自检随之开始）
#   WAIT=1 scripts/build_test.sh             # 再等自检跑到主体结束并打印结果（wait_autorun.sh）
#   SKIP_DEPLOY=1 scripts/build_test.sh      # 只要包，不碰设备
#   scripts/build_test.sh <serial|ip:port>   # 指定设备（默认 DEVICE_SN / hdc 第一个）
#   SIGN_CFG_NAME=xxx scripts/build_test.sh  # 特殊情况才换（换之前先读本文件开头）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

SIGN_CFG_NAME="${SIGN_CFG_NAME:-debug-jit}"
OUT_DIR="${OUT_DIR:-$ROOT/build/release}"
DEV="${1:-${DEVICE_SN:-}}"
# build_release.sh 默认读仓库根的 build-profile.json5（那份里的调试项叫 debug，不叫 debug-jit）；
# 自测固定要的 `debug-jit` 这条材料在 env.sh 指的那份 BUILD_PROFILE_FILE 里，所以这里显式把
# 签名材料指过去，别让 build_release 的默认值把它换掉。
SIGN_PROFILE_FILE="${SIGN_PROFILE_FILE:-$BUILD_PROFILE_FILE}"

log "=== 设备自测构建：release 模式 + $SIGN_CFG_NAME 签名 ==="
SKIP_APP=1 SIGN_CFG_NAME="$SIGN_CFG_NAME" SIGN_PROFILE_FILE="$SIGN_PROFILE_FILE" OUT_DIR="$OUT_DIR" "$SCRIPT_DIR/build_release.sh"

HAP="$(ls -t "$OUT_DIR"/BetterSH-*-"$SIGN_CFG_NAME".hap 2>/dev/null | head -1 || true)"
[ -n "$HAP" ] || err "没找到签好的 HAP：$OUT_DIR/BetterSH-*-$SIGN_CFG_NAME.hap"
log "  产物: $HAP"

if [ "${SKIP_DEPLOY:-0}" = "1" ]; then
    warn "SKIP_DEPLOY=1：跳过部署/拉起"
    exit 0
fi

HAP_SIGNED="$HAP" "$SCRIPT_DIR/deploy_hap.sh" "$DEV"

# 拉起应用：autorun.sh 是"启动即自检"，只有重启应用才会重跑一遍。
# 设备号取 deploy 之后重新解析一次（上面那个 DEV 可能是空的，交给 hdc 默认）。
[ -n "$DEV" ] || DEV="$("$HDC" list targets 2>/dev/null | tr -d '\r' \
    | grep -vE '^[[:space:]]*$|^\[Empty\]$' | head -1 || true)"
[ -n "$DEV" ] || err "拉起应用需要设备号，但 hdc 没列出设备"
"$HDC" -t "$DEV" shell "aa force-stop $BUNDLE_NAME" >/dev/null 2>&1 || true
"$HDC" -t "$DEV" shell "aa start -a $ENTRY_ABILITY -b $BUNDLE_NAME"
log "已拉起 $BUNDLE_NAME（自检在后台跑，日志 $BUNDLE_NAME files/home/autorun.log）"

if [ "${WAIT:-0}" = "1" ]; then
    "$SCRIPT_DIR/wait_autorun.sh"
fi
