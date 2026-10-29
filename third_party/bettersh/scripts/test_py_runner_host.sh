#!/usr/bin/env bash
# 宿主侧 py_runner 协议测试入口（不需要 HarmonyOS 设备）。
#
# 被测：iec/exec/py_runner.cpp（runner）与 iec/scripts/optional/python_entry.c（客户端）。
# 真正的编译与断言在 iec/tests/py_runner/run.py；这里只是从 scripts/ 给一个固定入口，
# 方便本地和 CI 调用。
#
#   bash scripts/test_py_runner_host.sh
#   bash scripts/test_py_runner_host.sh --keep
#
# 依赖：x86_64 Linux（含 WSL）上的 gcc/g++、python3、宿主 libpython 共享库。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_TEST="${SCRIPT_DIR}/../iec/tests/py_runner/run.sh"

if [[ ! -f "${RUNNER_TEST}" ]]; then
    echo "test_py_runner_host.sh: 找不到 ${RUNNER_TEST}" >&2
    exit 1
fi

exec bash "${RUNNER_TEST}" "$@"
