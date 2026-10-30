#!/usr/bin/env bash
# run.sh — nc 属性 / 边界测试入口。
#
# 在 x86_64 Linux（含 WSL）上把 cmd_nc.c + wrap.c 编成普通可执行文件，
# 只用 127.0.0.1 回环跑大流量、半关闭、并发、超时、端口复用、用法错误、
# 二进制安全与信号中断。不连设备、不需要 HarmonyOS SDK、不访问外部网络。
#
#   bash third_party/bettersh/iec/tests/nc_fuzz/run.sh
#   NC_FUZZ_SRC=<dir> bash .../run.sh    # 指定别的源码目录
#
# 依赖：cc、python3、bash。全部通过退出 0，失败退出 1；缺少依赖退出 77
# （check-all.sh 记为 SKIP）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${NC_FUZZ_SRC:-$(cd "$HERE/../../scripts/optional" && pwd)}"

command -v cc >/dev/null 2>&1 || { echo "nc_fuzz: 找不到 cc" >&2; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "nc_fuzz: 找不到 python3" >&2; exit 77; }
[ -f "$SRC/cmd_nc.c" ] || { echo "nc_fuzz: 找不到 $SRC/cmd_nc.c" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nc_fuzz.XXXXXX")" || exit 2
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# 与设备侧一致：源码本身没有 main，这里用 wrap.c 转发。
cc -std=gnu11 -O1 -g -Wall -Wextra -D_GNU_SOURCE \
    -o "$TMP/nc" "$SRC/cmd_nc.c" "$HERE/wrap.c" || {
    echo "nc_fuzz: 编译失败" >&2
    exit 2
}

python3 "$HERE/run.py" "$TMP/nc"
exit $?
