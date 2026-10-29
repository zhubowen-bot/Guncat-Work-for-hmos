#!/bin/bash
# wait_device.sh — 等设备回线。
#
# 背景:设备用的是 **Windows 侧 USB 连接**(hdc.exe 经 WSL interop 调用),
# 会偶发掉线;掉线后重新插拔 USB 才能回来。所以部署前先在这里等,不要裸跑
# 一次性 `hdc list targets` 就判死。
#
# 用法:
#   ./scripts/wait_device.sh [超时秒数]      # 默认 600;超时退出码 1
#   SERIAL=xxx ./scripts/wait_device.sh     # 只等指定序列号
#
# 成功时把序列号打到 stdout(直接喂给 deploy_hap.sh)。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

TIMEOUT="${1:-600}"
WANT="${SERIAL:-}"
elapsed=0
while :; do
    hit="$("$HDC" list targets 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' \
           | grep -v '^\[Empty\]$' | head -1 || true)"
    if [ -n "$hit" ]; then
        if [ -z "$WANT" ] || [ "$hit" = "$WANT" ]; then
            echo "$hit"
            exit 0
        fi
    fi
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "wait_device: ${TIMEOUT}s 内没等到设备(${WANT:-任意})" >&2
        exit 1
    fi
    if [ $((elapsed % 15)) -eq 0 ]; then
        echo "wait_device: 等待设备回线…(已 ${elapsed}s;掉线请重新插拔 USB)" >&2
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done
