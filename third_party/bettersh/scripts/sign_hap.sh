#!/bin/bash
# sign_hap.sh — 签名 HAP（未签名 → 已签名）
#
# 签名材料直接读**仓库根的 build-profile.json5**（app.signingConfigs）：material 里的
# `C:/...` 路径先转成 /mnt/c/...，再用 sign.js 解密 DevEco 加密口令 → hap-sign-tool.jar
# 本地签名。
#
# 用哪一项签名（build-profile.json5 里默认有 release / debug 两条）：
#   * 缺省用 debug —— 普通调试部署用它；release 证书签出来的包设备不信任、hdc 装不上
#     （build_test.sh 开头那段注释有记）。
#   * 换法：环境变量 SIGN_CFG_NAME=release，或第二个位置参数。
#   * 换配置文件：环境变量 SIGN_PROFILE_FILE=/path/to/build-profile.json5。
#
# 用法：
#   scripts/sign_hap.sh                          # 签当前 product 的 unsigned，用 debug
#   scripts/sign_hap.sh <unsigned.hap> release   # 指定输入 + release
#   SIGN_CFG_NAME=release scripts/sign_hap.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# 默认用仓库根那份；env.sh 里的 BUILD_PROFILE_FILE 指向另一份（Windows 侧），这里不跟随。
SIGN_PROFILE_FILE="${SIGN_PROFILE_FILE:-$ROOT/build-profile.json5}"

HAP_UNSIGNED="${1:-$HAP_OUT_DIR/$BSH_PRODUCT-default-unsigned.hap}"
HAP_SIGNED="${HAP_SIGNED:-$HAP_OUT_DIR/$BSH_PRODUCT-default-signed.hap}"
SIGN_CFG_NAME="${2:-${SIGN_CFG_NAME:-debug}}"

[ -f "$SIGN_PROFILE_FILE" ] || err "缺少签名配置: $SIGN_PROFILE_FILE"
command -v java  >/dev/null || err "java 未安装"
command -v node  >/dev/null || err "node 未安装（解密签名口令用）"
[ -f "$HAP_UNSIGNED" ] || err "未签名 HAP 不存在: $HAP_UNSIGNED（先运行 build_hap.sh）"

export HAP_SIGN_JAR="${HAP_SIGN_JAR:-$OHOS_SDK/toolchains/lib/hap-sign-tool.jar}"

log "=== 签名 HAP ==="
log "  profile : $SIGN_PROFILE_FILE"
log "  config  : $SIGN_CFG_NAME"
log "  unsigned: $HAP_UNSIGNED"
log "  signed  : $HAP_SIGNED"
python3 "$SCRIPT_DIR/sign_hap.py" "$SIGN_PROFILE_FILE" "$HAP_UNSIGNED" "$HAP_SIGNED" "$SIGN_CFG_NAME"

[ -f "$HAP_SIGNED" ] || err "签名未产出文件"
log "✅ sign_hap.sh 完成: $HAP_SIGNED ($(du -h "$HAP_SIGNED" | cut -f1))"
