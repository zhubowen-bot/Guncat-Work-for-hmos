#!/bin/bash
# wait_autorun.sh — 等设备上的自检跑完并取回日志(轮询,不盲等)。
#
# 之前是「部署完 sleep 250 再读」—— 白等四五分钟。改成每 15 秒看一眼日志里有没有
# 结束标记,有就立刻返回。
#
# 认哪个标记:两个版本的自检脚本收尾写法不同,都得认(认漏了就是"跑到最后等不到")——
#   - autorun-all.sh v4:正文结束打 `=== autorun 结果: PASS=n FAIL=n ===`,最后 `=== autorun END ===`
#   - 旧的小自检:       `=== 主体结束 … ===`(box64 那一档在它**之后**) + 宿主 shell 收尾的
#                       `=== autorun 结束 rc=N ===`
# ⚠ 只认其中一种会**永远等不到** —— 旧版里 box64 档会卡死,收尾那行根本不会出现,
#   所以"主体结束"是那时的主要判据;v4 则只有 END 那两个。
#
# 用法: ./scripts/wait_autorun.sh [最多轮数] [本地输出文件]
#   默认 40 轮 × 15s ≈ 10 分钟上限。成功把整份日志打出来并 exit 0;超时 exit 1。
#   ⚠ v4 全量自检比旧版长得多(编译链一档就 180s、各命令 so 各 30s),轮数要跟着放宽:
#     WAIT_TRIES=120 scripts/wait_autorun.sh 之类。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

TRIES="${1:-${WAIT_TRIES:-40}}"
LOCAL="${2:-/tmp/autorun.log}"
# 设备侧日志路径里的两层都与构建变体相关：bundleName 随发行变体换，
# haps/<模块名> 随分包换(tablet / phone) —— 别写死，否则换一个变体就"日志永远读不到"。
DEV_LOG="/data/app/el2/100/base/${BSH_DEV_BUNDLE:-com.yiyan.bettersh}/haps/${BSH_PRODUCT:-tablet}/files/home/autorun.log"

for i in $(seq 1 "$TRIES"); do
    SN="$("$HDC" list targets 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' \
          | grep -v '^\[Empty\]$' | head -1 || true)"
    if [ -n "$SN" ]; then
        "$HDC" -t "$SN" shell "cat $DEV_LOG" > "$LOCAL" 2>/dev/null || true
        if grep -qE "主体结束|autorun 结束 rc=|autorun 结果: PASS=|^=== autorun END ===" "$LOCAL" 2>/dev/null; then
            echo "wait_autorun: 第 $i 轮拿到日志($LOCAL)"
            # 整段打印:autorun.sh 自己打到 stdout 的本来就不多(guest 的输出都被它重定向到
            # 各自的 d1.log/m1.log 里去了),过滤反而会把 caps 的 jit=yes 这种关键行滤掉。
            echo "──────── autorun.log ────────"
            tr -d '\r' < "$LOCAL" | grep -av '^[[:space:]]*$' || true
            echo "────────────────────────────"
            exit 0
        fi
    fi
    sleep 15
done
echo "wait_autorun: ${TRIES} 轮内没等到结束标记(设备掉线?自检卡在某一档?)" >&2
exit 1
