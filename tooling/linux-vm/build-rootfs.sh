#!/usr/bin/env bash
# Guncat Work: 生成随 HAP 打包的 Linux 根文件系统镜像(rootfs_guncat.qcow2)。
#
# 底座: HiSH 的 Alpine aarch64 qcow2 (Alpine 3.22, busybox + apk, 128GiB 稀疏 ext4)。
# 注入: Guncat 的 sysinit / 任务代理 / inittab —— 去掉 OpenRC, 让 TCI 下的启动尽量短。
#
# 用法:
#   BASE=~/alpine-base.qcow2 bash build-rootfs.sh
#   OUT=... qcow2 输出路径(默认写到本项目 rawfile/vm/rootfs_guncat.qcow2)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST="$HERE/guest"
BASE="${BASE:-$HOME/hish-tci-build/alpine-base.qcow2}"
PROJ="${PROJ:-$(cd "$HERE/../.." && pwd)}"
OUT="${OUT:-$PROJ/entry/src/main/resources/rawfile/vm/rootfs_guncat.qcow2}"
WORK="${WORK:-$HOME/rootfs-build}"
MNT="$WORK/mnt"

[ -f "$BASE" ] || { echo "ERROR: 底座镜像不存在: $BASE" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK" "$MNT"
cp "$BASE" "$WORK/base.qcow2"
cd "$WORK"

echo "== 1/6 qcow2 -> raw"
qemu-img convert -O raw base.qcow2 rootfs.raw

echo "== 2/6 挂载"
mount -o loop rootfs.raw "$MNT"
cleanup() {
  sync
  umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "== 3/6 注入 Guncat 系统文件"
install -m 0755 "$GUEST/guncat-setup" "$MNT/etc/guncat-setup"
install -m 0755 "$GUEST/guncat-agent" "$MNT/usr/local/bin/guncat-agent"

# inittab: 只保留 Guncat 需要的动作, 不启动 OpenRC
cat > "$MNT/etc/inittab" <<'EOF'
# Guncat Linux VM: busybox init 配置
# 刻意不启动 OpenRC —— TCI 解释执行下服务脚本是纯开销。
::sysinit:/etc/guncat-setup
::respawn:/usr/local/bin/guncat-agent

# 串口控制台(宿主可读取, 也是人工排障入口); root 免密自动登录
ttyAMA0::respawn:/sbin/getty -L 0 ttyAMA0 ansi -n -l /usr/sbin/autologin

::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

# fstab: 伪文件系统与两个 9p 共享(9p 的显式挂载在 guncat-setup 里带重试做)
cat > "$MNT/etc/fstab" <<'EOF'
# /dev/sda 是内核参数 root=/dev/sda 指定的根, 已由内核挂载
proc     /proc     proc     defaults,nosuid,nodev,noexec   0 0
sysfs    /sys      sysfs    defaults,nosuid,nodev,noexec   0 0
devpts   /dev/pts  devpts   gid=5,mode=620                 0 0
tmpfs    /tmp      tmpfs    defaults,nosuid,nodev,mode=1777,size=256M 0 0
tmpfs    /run      tmpfs    defaults,nosuid,nodev,mode=0755,size=64M  0 0
tmpfs    /dev/shm  tmpfs    defaults,nosuid,nodev,mode=1777,size=128M 0 0
workspaces  /mnt/workspaces  9p  trans=virtio,version=9p2000.L,msize=262144  0 0
guncatipc   /mnt/guncat-ipc  9p  trans=virtio,version=9p2000.L,msize=262144  0 0
EOF

# 统一 shell 环境标识, 并准备 HOME
mkdir -p "$MNT/root" "$MNT/workspace" "$MNT/mnt/workspaces" "$MNT/mnt/guncat-ipc"
cat > "$MNT/etc/profile.d/guncat.sh" <<'EOF'
export PS1='guncat:\w\$ '
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TERM="${TERM:-xterm}"
EOF

# 主机名与 hosts/DNS 兜底(udhcpc 会覆盖 resolv.conf)
echo guncat-linux > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" <<'EOF'
127.0.0.1   localhost guncat-linux
::1         localhost
EOF
cat > "$MNT/etc/resolv.conf" <<'EOF'
nameserver 10.0.2.3
nameserver 223.5.5.5
EOF

# 关掉对 TCI 毫无意义/拖慢启动的东西
rm -f "$MNT/etc/init.d/guncat-agent" 2>/dev/null || true
mkdir -p "$MNT/etc/modprobe.d"

echo "== 4/6 校验注入结果"
test -x "$MNT/etc/guncat-setup"
test -x "$MNT/usr/local/bin/guncat-agent"
grep -q guncat-agent "$MNT/etc/inittab"
echo "   inittab/fstab/agent 就绪; busybox 可用: $(chroot "$MNT" /bin/busybox 2>/dev/null | awk 'NR==1' || true)"

echo "== 5/6 卸载"
cleanup
trap - EXIT

echo "== 6/6 raw -> qcow2"
qemu-img convert -f raw -O qcow2 -o compat=1.1,lazy_refcounts=on rootfs.raw "$OUT"
qemu-img info "$OUT" | awk 'NR<=6'
ls -l "$OUT"
echo "== done: $OUT"
echo "提醒: 镜像内容变了 —— 请把 entry/src/main/ets/common/Constants.ts 里的 WORK_LINUX_IMAGE_REV"
echo "      改成新值, 否则已装设备不会重新释放镜像。"
