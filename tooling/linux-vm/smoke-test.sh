#!/usr/bin/env bash
# Guncat Work: 客人镜像 + 命令协议的离线自检（不需要真机、不需要 TCI 版 QEMU）。
#
# 用宿主机的 qemu-system-aarch64（x86 主机上就是 TCG 模拟 aarch64）按应用里的**同一套参数**
# 引导镜像，然后走一遍文件式命令协议，验证：
#   1) 内核能引导、/init → busybox init → guncat-setup 挂载两个 9p 共享
#   2) guncat-agent 写出 .ready 并开始轮询任务
#   3) 命令执行 / stdout / stderr / 退出码 / 超时(137) / cwd / 管道
#   4) 目录一致性: 客人在 /workspace 里写的文件，宿主侧会话工作区立即可见（同一批文件）
#   5) 工作区不被 9p 元数据污染（不应出现 .virtfs_metadata）
#
# 用法:
#   bash tooling/linux-vm/smoke-test.sh
#   前置: apt install qemu-system-arm
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$HERE/../.." && pwd)}"
RAW="$PROJ/entry/src/main/resources/rawfile/vm"
WORK="${WORK:-/tmp/guncat-vm-smoke}"
CONV="smoke-conv"

QEMU="${QEMU:-qemu-system-aarch64}"
command -v "$QEMU" >/dev/null 2>&1 || { echo "ERROR: 需要宿主机 qemu-system-aarch64（apt install qemu-system-arm）" >&2; exit 2; }
[ -f "$RAW/kernel_aarch64" ] || { echo "ERROR: 缺 $RAW/kernel_aarch64（先跑 fetch-assets.sh）" >&2; exit 2; }
[ -f "$RAW/rootfs_guncat.qcow2" ] || { echo "ERROR: 缺 $RAW/rootfs_guncat.qcow2（先跑 build-rootfs.sh）" >&2; exit 2; }

fail=0
pass() { echo "  OK  $1"; }
bad()  { echo "  FAIL $1"; fail=1; }

cleanup() {
  [ -n "${VM_PID:-}" ] && kill "$VM_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK/vm/keymaps" "$WORK/workspaces/$CONV/data" "$WORK/ipc"
cp "$RAW/kernel_aarch64" "$WORK/vm/"
cp "$RAW/efi-virtio.rom" "$WORK/vm/"
cp "$RAW/keymaps/en-us" "$WORK/vm/keymaps/"
cp "$RAW/rootfs_guncat.qcow2" "$WORK/rootfs.qcow2"
echo "hello-from-host" > "$WORK/workspaces/$CONV/data/a.txt"

echo "== 引导镜像(宿主 $($QEMU --version | awk 'NR==1{print $4}'))"
"$QEMU" \
  -machine virt,acpi=on,gic-version=max,iommu=none,its=off,usb=off,virtualization=off \
  -cpu max,pauth-impdef=on,sve=off,pmu=off -accel tcg,thread=single -smp 1 -m 2048 \
  -kernel "$WORK/vm/kernel_aarch64" \
  -append "root=/dev/sda rw rootfstype=ext4 rootwait console=ttyAMA0 consoleblank=0 loglevel=4 init=/init mitigations=off audit=0 random.trust_cpu=on elevator=noop skew_tick=1 nmi_watchdog=0 panic=1" \
  -rtc base=utc,clock=host -L "$WORK/vm" \
  -drive if=none,format=qcow2,file="$WORK/rootfs.qcow2",id=hd0,cache=writeback,aio=threads,discard=unmap \
  -device virtio-scsi-pci-non-transitional,id=scsi0,num_queues=1 \
  -device scsi-hd,drive=hd0,bus=scsi0.0,logical_block_size=4096,physical_block_size=4096,rotation_rate=1,bootindex=1 \
  -fsdev local,security_model=none,id=fsdev0,path="$WORK/workspaces" \
  -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=workspaces \
  -fsdev local,security_model=none,id=fsdev1,path="$WORK/ipc" \
  -device virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=guncatipc \
  -netdev user,id=eth0 -device virtio-net-pci-non-transitional,netdev=eth0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci-non-transitional,rng=rng0 \
  -serial file:"$WORK/serial.log" -display none -monitor none -no-reboot > "$WORK/qemu.out" 2>&1 &
VM_PID=$!

for _ in $(seq 1 900); do [ -f "$WORK/ipc/.ready" ] && break; sleep 0.1; done
if [ -f "$WORK/ipc/.ready" ]; then
  pass "客人就绪($(grep -c . "$WORK/ipc/.ready") 行状态)"
else
  bad "客人未就绪; 串口尾部:"; tail -20 "$WORK/serial.log" 2>/dev/null
  exit 1
fi
grep -q 'workspaces_mounted=1' "$WORK/ipc/.ready" && pass "workspaces 9p 已挂载" || bad "workspaces 9p 未挂载"
grep -q 'ipc_mounted=1' "$WORK/ipc/.ready" && pass "guncatipc 9p 已挂载" || bad "guncatipc 9p 未挂载"

run_job() {  # id, cmd, cwd, timeout
  local id="$1" cmd="$2" cwd="${3:-}" tmo="${4:-20}"
  local req="$WORK/ipc/$CONV/in/$id" out="$WORK/ipc/$CONV/out/$id"
  mkdir -p "$req"
  printf '%s\n' "$cmd" > "$req/cmd"
  [ -n "$cwd" ] && printf '%s' "$cwd" > "$req/cwd"
  printf '%s' "$tmo" > "$req/timeout"
  : > "$req/ready"
  for _ in $(seq 1 600); do [ -f "$out/done" ] && break; sleep 0.1; done
}

expect() {  # 描述, 期望, 实际
  if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 (期望 [$2] 实际 [$3])"; fi
}

expect_grep() {  # 描述, 正则, 文件
  if grep -qE "$2" "$3" 2>/dev/null; then pass "$1"; else bad "$1 (在 $3 里没找到 /$2/)"; fi
}

echo "== 命令协议"
run_job j1 'pwd; uname -srm; cat data/a.txt'
expect "pwd 是工作区" "/workspace" "$(head -1 "$WORK/ipc/$CONV/out/j1/stdout")"
expect "能读到宿主放进来的文件" "hello-from-host" "$(sed -n 3p "$WORK/ipc/$CONV/out/j1/stdout")"

run_job j2 'echo written-by-guest > out.txt; mkdir -p sub && cd sub && pwd'
expect "退出码 0" "0" "$(cat "$WORK/ipc/$CONV/out/j2/code")"
expect "cwd 生效" "/workspace/sub" "$(cat "$WORK/ipc/$CONV/out/j2/stdout")"

echo "== 目录一致性(关键)"
expect "客人写的文件在宿主工作区里可见" "written-by-guest" "$(cat "$WORK/workspaces/$CONV/out.txt" 2>/dev/null)"
if [ -e "$WORK/workspaces/$CONV/.virtfs_metadata" ] || [ -e "$WORK/workspaces/$CONV/sub/.virtfs_metadata" ]; then
  bad "工作区被 9p 元数据污染(.virtfs_metadata)"
else
  pass "工作区没有被 9p 元数据污染"
fi

echo "== 错误语义"
run_job j3 'echo err >&2; exit 3'
expect "退出码透传" "3" "$(cat "$WORK/ipc/$CONV/out/j3/code")"
expect "stderr 分开捕获" "err" "$(cat "$WORK/ipc/$CONV/out/j3/stderr")"
run_job j4 'sleep 30' '' 2
expect "超时被杀(137)" "137" "$(cat "$WORK/ipc/$CONV/out/j4/code")"
run_job j5 'cat a.txt' 'data'
expect "cwd 参数生效" "hello-from-host" "$(cat "$WORK/ipc/$CONV/out/j5/stdout")"
run_job j6 'echo hi | tr a-z A-Z; for f in *.txt; do echo "f=$f"; done'
expect "管道与 for 循环可用" "HI" "$(head -1 "$WORK/ipc/$CONV/out/j6/stdout")"

echo "== 预装工具"
run_job j7 'python3 -c "import sys,json,sqlite3,ssl; print(\"py\", sys.version.split()[0])"; python3 -m pip --version; jq -nc "{a:1}"'
expect_grep "Python 3 可用(含 ssl/sqlite3/json)" '^py 3\.12' "$WORK/ipc/$CONV/out/j7/stdout"
expect_grep "pip 可用" '^pip 25\.' "$WORK/ipc/$CONV/out/j7/stdout"
expect_grep "jq 可用" '^\{"a":1\}$' "$WORK/ipc/$CONV/out/j7/stdout"
run_job j8 'command -v npy'
expect "npy 跨域桥已装" "/usr/local/bin/npy" "$(head -1 "$WORK/ipc/$CONV/out/j8/stdout")"

echo
if [ "$fail" -eq 0 ]; then echo "== 全部通过"; else echo "== 有失败项(串口日志: $WORK/serial.log)"; fi
exit "$fail"
