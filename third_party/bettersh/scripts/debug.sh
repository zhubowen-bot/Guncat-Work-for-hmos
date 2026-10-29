#!/bin/bash
# 串行跑各阶段：每阶段改 stage.txt → 重打 HAP → 全量卸载重装 → 强制重启 → 轮询 end → 存结果
cd /workspace/dev/BetterSH
source scripts/env.sh
# 设备：$1 > DEVICE_SN > hdc 列出的第一个（不再写死序列号）
T="${1:-${DEVICE_SN:-}}"
[ -n "$T" ] || T="$("$HDC" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$' | grep -v '^[[:space:]]*$' | head -1 || true)"
P=/data/app/el2/100/base/com.yiyan.bettersh/haps/tablet/files

# 打包 → 安装 → 启动 
./scripts/build_hap.sh 2>&1 | tail -4
# 调试部署用 build-profile.json5 里的 debug 签名（release 证书签的包装不上机）
SIGN_CFG_NAME=debug ./scripts/sign_hap.sh 2>&1 | tail -4
./scripts/deploy_hap.sh 2>&1 | tail -4
"$HDC" -t $T shell aa start -a EntryAbility -b com.yiyan.bettersh 2>&1 | tail -4

# 轮询 autorun
for i in $(seq 1 120); do
    r=$("$HDC" -t "$T" shell "grep -qFx '===end===' '$P/home/autorun.log' 2>/dev/null && echo YES || echo NO" | tr -d ' \r')
    if [ "$r" = "YES" ]; then
        echo "第 $i 轮: 检测到结束信号"
        break
    else
        echo "第 $i 轮: 未检测到"
    fi
    sleep 10
done

if [ "$r" != "YES" ]; then
    echo "120 轮仍未检测到结束信号"
    exit
fi

"$HDC" -t $T shell cat "$P/home/autorun.log" 2>&1

echo "ALL DONE"
