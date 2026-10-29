#!/usr/bin/env bash
# 宿主侧 py_runner 协议测试入口。
#
# 只依赖 x86_64 Linux（含 WSL）上的 gcc/g++、python3 和宿主的 libpython 共享库；
# 不连设备、不需要 HarmonyOS SDK。编译与断言全部在 run.py 里。
#
#   ./run.sh                        # 自动探测 libpython（优先 3.12）
#   IEC_PY_LIBPYTHON=/path ./run.sh # 指定 libpython
#   ./run.sh --keep                 # 保留临时编译目录
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
    echo "run.sh: 需要 python3" >&2
    exit 1
fi
if ! command -v cc >/dev/null 2>&1 || ! command -v c++ >/dev/null 2>&1; then
    echo "run.sh: 需要 C/C++ 编译器（cc / c++）" >&2
    exit 1
fi

exec python3 run.py "$@"
