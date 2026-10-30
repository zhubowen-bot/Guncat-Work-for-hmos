#!/usr/bin/env bash
# run.sh — diff 属性/边界对拍入口（转给 run.py）。
#
#   bash third_party/bettersh/iec/tests/diff_fuzz/run.sh
#   bash .../run.sh --pairs 20 --keep
#
# 宿主没有 git 时退出 77（check-all.sh 记为 SKIP）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v python3 >/dev/null 2>&1 || {
    echo "diff_fuzz: 找不到 python3" >&2
    exit 2
}
command -v git >/dev/null 2>&1 || {
    echo "diff_fuzz: 找不到 git" >&2
    exit 77
}
exec python3 "$HERE/run.py" "$@"
