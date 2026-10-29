#!/usr/bin/env bash
# run.sh — hexdump 属性对拍入口（转给 run.py）。
#
#   bash third_party/bettersh/iec/tests/hexdump_fuzz/run.sh
#   bash .../run.sh --cases 50 --keep
#
# 宿主没有系统 hexdump 时退出 77（check-all.sh 记为 SKIP）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v python3 >/dev/null 2>&1 || {
    echo "hexdump_fuzz: 找不到 python3" >&2
    exit 2
}
exec python3 "$HERE/run.py" "$@"
