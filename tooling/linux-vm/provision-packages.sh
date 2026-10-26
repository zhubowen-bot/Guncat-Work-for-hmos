#!/usr/bin/env bash
# Guncat Work: 给客人镜像预装 Alpine 包(默认 python3 + pip + jq)。
#
# 做法: 用宿主机的 qemu-system-aarch64 引导**待发布的镜像**，走我们自己的文件式命令协议
# （与 LinuxShellService 完全相同的 in/out + ready/done），在客人内部跑真正的 `apk add`，
# 然后关机并把改好的 qcow2 覆盖回 rawfile。比在宿主上手工解 apk 可靠：
# 依赖解析、post-install 脚本、字节码编译都由 apk 自己完成。
#
# 用法:
#   bash tooling/linux-vm/provision-packages.sh                 # 默认装 python3 py3-pip jq ca-certificates
#   PACKAGES="python3 py3-pip py3-numpy" bash ...               # 自定义
# 前置: apt install qemu-system-arm
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$HERE/../.." && pwd)}"
RAW="$PROJ/entry/src/main/resources/rawfile/vm"
WORK="${WORK:-/tmp/guncat-vm-provision}"
CONV="provision"
QEMU="${QEMU:-qemu-system-aarch64}"
PACKAGES="${PACKAGES:-python3 py3-pip jq ca-certificates}"
IDLE_SHUTDOWN_SEC="${IDLE_SHUTDOWN_SEC:-900}"

command -v "$QEMU" >/dev/null 2>&1 || { echo "ERROR: 需要宿主机 qemu-system-aarch64（apt install qemu-system-arm）" >&2; exit 2; }
[ -f "$RAW/kernel_aarch64" ] || { echo "ERROR: 缺 kernel_aarch64" >&2; exit 2; }
[ -f "$RAW/rootfs_guncat.qcow2" ] || { echo "ERROR: 缺 rootfs_guncat.qcow2" >&2; exit 2; }

cleanup() {
  [ -n "${VM_PID:-}" ] && kill "$VM_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK/vm/keymaps" "$WORK/workspaces/$CONV" "$WORK/ipc"
cp "$RAW/kernel_aarch64" "$WORK/vm/"
cp "$RAW/efi-virtio.rom" "$WORK/vm/"
cp "$RAW/keymaps/en-us" "$WORK/vm/keymaps/"
# 在副本上操作: 万一中途失败, 不会毁掉可用的镜像
cp "$RAW/rootfs_guncat.qcow2" "$WORK/rootfs.qcow2"

echo "== 引导镜像"
"$QEMU" \
  -machine virt,acpi=on,gic-version=max,iommu=none,its=off,usb=off,virtualization=off \
  -cpu max,pauth-impdef=on,sve=off,pmu=off -accel tcg,thread=single -smp 1 -m 2048 \
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
  -netdev user,id=eth0 -device virtio-net-pci-non-transitional,netdev=eth0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci-non-transitional,rng=rng0 \
  -serial file:"$WORK/serial.log" -display none -monitor none -no-reboot > "$WORK/qemu.out" 2>&1 &
VM_PID=$!

for _ in $(seq 1 900); do [ -f "$WORK/ipc/.ready" ] && break; sleep 0.1; done
[ -f "$WORK/ipc/.ready" ] || { echo "ERROR: 客人未就绪"; tail -20 "$WORK/serial.log"; exit 1; }
echo "== 客人就绪"

run_job() {  # id, cmd, timeout
  local id="$1" cmd="$2" tmo="${3:-900}"
  local req="$WORK/ipc/$CONV/in/$id" out="$WORK/ipc/$CONV/out/$id"
  mkdir -p "$req"
  printf '%s\n' "$cmd" > "$req/cmd"
  printf '%s' "$tmo" > "$req/timeout"
  : > "$req/ready"
  for _ in $(seq 1 $((tmo * 10 + 600))); do [ -f "$out/done" ] && break; sleep 0.1; done
  echo "--- [$id] exit=$(cat "$out/code" 2>/dev/null)"
  [ -s "$out/stdout" ] && tail -25 "$out/stdout"
  [ -s "$out/stderr" ] && { echo "--- stderr:"; tail -15 "$out/stderr"; }
}

echo "== 网络自检"
run_job net 'ip -4 addr show eth0 | grep inet; cat /etc/resolv.conf | head -3' 60

echo "== 预装: $PACKAGES"
run_job apk "apk add --no-cache $PACKAGES" "$IDLE_SHUTDOWN_SEC"

# Alpine 给 pip 打了 PEP 668 的 EXTERNALLY-MANAGED 标记, 默认 `pip install` 会直接报错。
# shell 工具里"装个库"应该是一句话的事, 所以写全局 pip.conf: 放开系统包 + 国内默认走清华源。
run_job pipconf 'cat > /etc/pip.conf <<EOF
[global]
break-system-packages = true
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
EOF
cat /etc/pip.conf' 60

echo "== 验证"
run_job verify 'python3 -V; python3 -m pip --version; python3 -c "import json,sqlite3,ssl,hashlib,decimal; print(\"stdlib ok\")"; jq --version' 120
run_job pipinstall 'python3 -m pip install --no-cache-dir --quiet six && python3 -c "import six; print(\"pip install ok\", six.__version__)"' 300

echo "== 收尾"
# 先让客人 sync, 再给 QEMU 发 SIGTERM(它会走正常收尾, 设备缓存会刷盘)。
# 不用 poweroff 任务: 客人一 poweroff, agent 来不及写 done, 宿主只能干等超时。
run_job sync 'sync; echo synced' 120
kill "$VM_PID" 2>/dev/null
for _ in $(seq 1 30); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 0.2; done
kill -9 "$VM_PID" 2>/dev/null
sleep 1

# 只有 apk 成功才覆盖正式镜像
if [ "$(cat "$WORK/ipc/$CONV/out/apk/code" 2>/dev/null)" = "0" ]; then
  # 装机过程是 SIGTERM 收尾的, ext4 日志可能还脏: 先 fsck, 再压成压缩 qcow2
  # (压缩簇由 QEMU 透明解压; 我们的 QEMU 静态链了 zlib, 支持读压缩簇)。
  echo "== 整理文件系统并压缩镜像"
  qemu-img convert -f qcow2 -O raw "$WORK/rootfs.qcow2" "$WORK/clean.raw"
  e2fsck -f -y "$WORK/clean.raw" > "$WORK/fsck.log" 2>&1 || true
  qemu-img convert -f raw -O qcow2 -o compat=1.1,lazy_refcounts=on -c \
    "$WORK/clean.raw" "$RAW/rootfs_guncat.qcow2"
  rm -f "$WORK/clean.raw"
  qemu-img info "$RAW/rootfs_guncat.qcow2" | awk 'NR<=4'
  ls -lh "$RAW/rootfs_guncat.qcow2" | awk '{print "镜像大小:", $5}'
  echo "== 完成: $RAW/rootfs_guncat.qcow2"
  echo
  echo "提醒: 镜像内容变了 —— 请把 entry/src/main/ets/common/Constants.ts 里的"
  echo "      WORK_LINUX_IMAGE_REV 改成新值(如 $(date +%Y-%m-%d)-python3), 否则已装设备不会重新释放镜像。"
else
  echo "ERROR: apk add 失败, 未覆盖镜像(见 $WORK/ipc/$CONV/out/apk/stderr)" >&2
  exit 1
fi
