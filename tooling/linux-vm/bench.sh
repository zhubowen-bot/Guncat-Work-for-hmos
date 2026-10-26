#!/usr/bin/env bash
# Guncat Work: 客人侧固定负载基准（用于比较 TCI / JIT / 原生，以及验证优化效果）。
#
# 用法:
#   bash tooling/linux-vm/bench.sh                       # 用宿主默认 qemu(通常是 JIT 版)
#   QEMU=/root/tcibench/qemu-10.2.0/build-tci/qemu-system-aarch64 bash tooling/linux-vm/bench.sh
#
# 输出: 每条负载的墙钟秒数(CSV), 便于横向对比。
# 注意: 宿主机是 x86 时这里测的是"aarch64 客户机在 x86 上"的相对性能,
#       绝对值不能直接当手机数据, 但 TCI/JIT 的**倍率**可以横向参考。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$HERE/../.." && pwd)}"
RAW="$PROJ/entry/src/main/resources/rawfile/vm"
WORK="${WORK:-/tmp/guncat-vm-bench}"
CONV="bench"
QEMU="${QEMU:-qemu-system-aarch64}"
MEM="${MEM:-2048}"
LABEL="${LABEL:-$(basename "$(dirname "$QEMU")")}"
# NET=0: 跳过 -netdev user(某些 QEMU 构建没编 slirp); 这些负载不需要网络
NET="${NET:-1}"

command -v "$QEMU" >/dev/null 2>&1 || { echo "ERROR: 找不到 $QEMU" >&2; exit 2; }

NET_ARGS=()
if [ "$NET" = "1" ]; then
  NET_ARGS=(-netdev user,id=eth0 -device virtio-net-pci-non-transitional,netdev=eth0)
fi

cleanup() { [ -n "${VM_PID:-}" ] && kill "$VM_PID" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK/vm/keymaps" "$WORK/workspaces/$CONV" "$WORK/ipc"
cp "$RAW/kernel_aarch64" "$WORK/vm/"
cp "$RAW/efi-virtio.rom" "$WORK/vm/"
cp "$RAW/keymaps/en-us" "$WORK/vm/keymaps/"
cp "$RAW/rootfs_guncat.qcow2" "$WORK/rootfs.qcow2"

"$QEMU" \
  -machine virt,acpi=on,gic-version=max,iommu=none,its=off,usb=off,virtualization=off \
  -cpu max,pauth-impdef=on,sve=off,pmu=off -accel tcg,thread=single -smp 1 -m "$MEM" \
  -kernel "$WORK/vm/kernel_aarch64" \
  -append "root=/dev/sda rw rootfstype=ext4 rootwait console=ttyAMA0 consoleblank=0 loglevel=3 init=/init mitigations=off audit=0 random.trust_cpu=on elevator=noop skew_tick=1 nmi_watchdog=0 panic=1" \
  -rtc base=utc,clock=host -L "$WORK/vm" \
  -drive if=none,format=qcow2,file="$WORK/rootfs.qcow2",id=hd0,cache=writeback,aio=threads,discard=unmap \
  -device virtio-scsi-pci-non-transitional,id=scsi0,num_queues=1 \
  -device scsi-hd,drive=hd0,bus=scsi0.0,logical_block_size=4096,physical_block_size=4096,rotation_rate=1,bootindex=1 \
  -fsdev local,security_model=none,id=fsdev0,path="$WORK/workspaces" \
  -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=workspaces \
  -fsdev local,security_model=none,id=fsdev1,path="$WORK/ipc" \
  -device virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=guncatipc \
  "${NET_ARGS[@]}" \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci-non-transitional,rng=rng0 \
  -serial file:"$WORK/serial.log" -display none -monitor none -no-reboot > "$WORK/qemu.out" 2>&1 &
VM_PID=$!

for _ in $(seq 1 1800); do [ -f "$WORK/ipc/.ready" ] && break; sleep 0.1; done
[ -f "$WORK/ipc/.ready" ] || { echo "ERROR: 客人未就绪"; tail -20 "$WORK/serial.log"; exit 1; }

run_job() {  # id, cmd, timeout
  local id="$1" cmd="$2" tmo="${3:-900}"
  local req="$WORK/ipc/$CONV/in/$id" out="$WORK/ipc/$CONV/out/$id"
  mkdir -p "$req"
  printf '%s\n' "$cmd" > "$req/cmd"
  printf '%s' "$tmo" > "$req/timeout"
  : > "$req/ready"
  for _ in $(seq 1 $((tmo * 10 + 600))); do [ -f "$out/done" ] && break; sleep 0.1; done
  cat "$out/stdout" 2>/dev/null
}

# 每条负载: 名字|脚本(内部用 /proc/uptime 自测毫秒, 避免宿主观测误差)
bench() {
  local name="$1" body="$2" tmo="${3:-900}"
  local out
  out=$(run_job "b_$name" "s=\$(cut -d' ' -f1 /proc/uptime); $body; e=\$(cut -d' ' -f1 /proc/uptime); awk -v s=\"\$s\" -v e=\"\$e\" 'BEGIN{printf \"%.3f\", e-s}'" "$tmo")
  printf '%s,%s,%s\n' "$LABEL" "$name" "${out:-TIMEOUT}"
}

echo "backend,case,seconds"
bench py_startup      'python3 -c pass'
bench py_startup_S    'python3 -S -c pass'
bench py_loop_200k    'python3 -c "for i in range(200000): pass"'
bench py_sum_200k     'python3 -c "sum(range(200000))"'
bench py_import       'python3 -c "import json,re,collections,decimal"'
bench awk_loop_200k   'awk "BEGIN{for(i=0;i<200000;i++) s+=i}"'
bench sh_loop_1000    'i=0; while [ $i -lt 1000 ]; do i=$((i+1)); done'
bench pipe_200k       'yes | head -200000 | wc -l'
bench copy_50mb       'dd if=/dev/zero of=/tmp/z bs=1M count=50 2>/dev/null; sync'
bench tar_50mb        'tar cf /tmp/z.tar /tmp/z 2>/dev/null; rm -f /tmp/z /tmp/z.tar'

echo "== 完成($LABEL); 串口日志: $WORK/serial.log" >&2
