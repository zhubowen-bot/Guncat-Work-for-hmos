#!/bin/bash
# deploy_hap.sh — 安装签名 HAP 到设备
# 参考 blender-harmonyos/tools/deploy_hap.sh。
# 用法：
#   ./scripts/deploy_hap.sh <ip:port>  网络调试(tconn)
#   ./scripts/deploy_hap.sh <serial>   USB 设备(按序列号 -t)
#   ./scripts/deploy_hap.sh            无参:从 hdc list targets 自动取第一个设备
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

HAP_SIGNED="${HAP_SIGNED:-$HAP_OUT_DIR/$BSH_PRODUCT-default-signed.hap}"
BUNDLE="${BUNDLE_NAME:-com.yiyan.bettersh}"

# 设备:参数 > DEVICE_SN > hdc list targets 第一个
DEVICE="${1:-${DEVICE_SN:-}}"
if [ -z "$DEVICE" ]; then
  DEVICE="$("$HDC" list targets 2>/dev/null | grep -v '^\s*$' | head -1 | tr -d '\r ' || true)"
  if printf '%s' "$DEVICE" | grep -q 'Empty'; then DEVICE=""; fi
fi
[ -n "$DEVICE" ] || err "未指定设备且 hdc 未列出任何设备(传 <ip:port>/<serial> 或设 DEVICE_SN)"

[ -f "$HAP_SIGNED" ] || err "签名 HAP 不存在: $HAP_SIGNED（先运行 build_hap.sh）"

log "=== 部署 HAP → $DEVICE ==="
log "  bundle: $BUNDLE"
log "  hap   : $HAP_SIGNED"
log "  hdc   : $HDC"

# 1/2 设备可达(网络:tconn 等待授权;USB:直接 -t 探测)
if [[ "$DEVICE" == *:* ]]; then
  "$HDC" tconn "$DEVICE" >/dev/null 2>&1 || true
  _ready() { "$HDC" -t "$DEVICE" shell echo __ok__ 2>/dev/null | grep -q "^__ok__"; }
else
  _ready() { "$HDC" -t "$DEVICE" shell echo __ok__ 2>/dev/null | grep -q "^__ok__"; }
fi
warned=0
ok=0
for i in $(seq 1 60); do
  if _ready; then
    log "设备已连接（第 ${i}s 探测成功）"
    ok=1
    break
  fi
  if [ "$warned" -eq 0 ]; then
    log "请在设备上点击『允许』授权 USB/网络调试..."
    warned=1
  fi
  sleep 1
done
[ "$ok" -eq 1 ] || err "等待设备就绪超时: $DEVICE"

# 2/2 安装(先卸载旧的,容忍失败)
"$HDC" -t "$DEVICE" shell bm uninstall -n "$BUNDLE" >/dev/null 2>&1 || true
# Windows hdc 只能访问 Windows 路径:先拷到 /mnt/c/tmp
SEND_SRC="$HAP_SIGNED"
if [[ "$HDC" == *.exe ]]; then
  mkdir -p /mnt/c/tmp
  cp -f "$HAP_SIGNED" /mnt/c/tmp/bettersh-deploy.hap
  SEND_SRC='C:\tmp\bettersh-deploy.hap'
fi
"$HDC" -t "$DEVICE" file send "$SEND_SRC" /data/local/tmp/bettersh.hap
"$HDC" -t "$DEVICE" shell bm install -p /data/local/tmp/bettersh.hap -r
log "✅ 安装完成。启动: hdc -t $DEVICE shell aa start -a EntryAbility -b $BUNDLE"
