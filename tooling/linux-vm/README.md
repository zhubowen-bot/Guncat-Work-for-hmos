# Linux VM 构建链（shell 工具）

`shell` 工具在设备上跑的是**真的 Linux**：QEMU 全系统虚拟机 + Alpine 用户态，只是把 QEMU 编译成
**TCG 字节码解释器（TCI）**，运行时不再生成机器码 —— 所以不需要 JIT 所需的受限权限，手机与上架包都能用。

三样产物需要先在 Linux 侧编好（Windows 上通过 WSL2 做）：

| 产物 | 落地位置 | 大小 |
| --- | --- | --- |
| `libqemu-system-aarch64-tci.so` / `libslirp.so.0` | `entry/libs/arm64-v8a/` | ≈43MB |
| `rootfs_guncat.qcow2`（定制过的 Alpine 根文件系统） | `entry/src/main/resources/rawfile/vm/` | ≈36MB |
| `kernel_aarch64` | `entry/src/main/resources/rawfile/vm/` | ≈12MB |

> `libqemu-img.so`（快照/镜像管理用）本工程不需要，不打包。
> 上面这些二进制**已随仓库提供**（git 压缩后合计约 21MB：QEMU ≈8MB、镜像 ≈7MB、内核 ≈5MB、slirp ≈1MB），
> 所以 clone 下来直接能构建出带 `shell` 的 HAP；只有换工具链 / 改镜像 / 换 QEMU 版本时才需要重跑本节流程。

## 0. 环境

```bash
# WSL2 Ubuntu（或任意 Ubuntu 22.04+）
sudo apt install -y build-essential cmake curl wget unzip python3 libncurses-dev git flex bison \
    autoconf libcurl4-openssl-dev tcl gettext zip pigz meson ninja-build pkg-config perl texinfo gawk patch file qemu-utils
```

还需要 **HarmonyOS Command Line Tools（Linux 版）**：从
<https://developer.huawei.com/consumer/cn/download/> 下载 `commandline-tools-linux-x64-*.zip`，解压后：

```bash
export TOOL_HOME=/opt/ohos-cmdline/command-line-tools     # 指向解压出来的 command-line-tools 目录
# 只解 sdk/default/openharmony/native 也够（约 2.6GB）
```

校验工具链：

```bash
$TOOL_HOME/sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang --version
```

## 1. 取内核与 Alpine 底座

```bash
bash tooling/linux-vm/fetch-assets.sh
```

会下载：

- 内核 `kernel_aarch64`（Huawei/HiSH 的 linux-config 发布物，已带 virtio-9p / virtio-net / ext4）
- Alpine 3.22 aarch64 底座 `rootfs_aarch64.qcow2`（HiSH 发布物，128GiB 稀疏 ext4，busybox + apk）

## 2. 编 TCI 版 QEMU

```bash
TOOL_HOME=/opt/ohos-cmdline/command-line-tools \
WORK=$HOME/hish-tci-build \
bash tooling/linux-vm/build-libqemu-tci.sh
```

要点：

- 走 `--enable-tcg-interpreter`（`QEMU_TCI=1`），产物名带 `-tci` 后缀，与 JIT 版区分。
- 依赖库（zstd/zlib/pcre2/glib/pixman）编一次会留 `.built-*` 标记，重跑只编 QEMU；`FORCE=1` 可全量重编，
  `FORCE_QEMU=1` 只重编 QEMU。
- zlib 与 pcre2 通过改写 `buildroot` 里的 `.pc` 强制**静态链接**，产物只依赖 `libc` + `libslirp`
  （`llvm-readelf -d` 可验证），避免往 HAP 里塞同名 `.so` 遮蔽系统库。
- 编完自动 `llvm-strip --strip-all`：58MB → 约 42MB。
- 网络受限时不必改源码：`deps/` 里的配方已把 github.com 直链换成 `codeload.github.com`，
  glib 的 `proxy-libintl` 子项目也改成直接解包（meson 默认用 git clone，会失败）。

产物在 `$WORK/deps/output/`：

```bash
mkdir -p entry/libs/arm64-v8a
cp $WORK/deps/output/libqemu-system-aarch64-tci.so \
   $WORK/deps/output/libslirp.so.0 entry/libs/arm64-v8a/
```

## 3. 生成定制根文件系统

```bash
BASE=$HOME/hish-tci-build/alpine-base.qcow2 \
WORK=$HOME/rootfs-build \
bash tooling/linux-vm/build-rootfs.sh
```

脚本做的事（见 `guest/`）：

- 注入 `/etc/guncat-setup`（挂载 proc/sys/devtmpfs、起 DHCP、挂载两个 virtio-9p 共享）
- 注入 `/usr/local/bin/guncat-agent`（轮询任务通道并执行命令，把结果写回）
- 重写 `/etc/inittab`：**不启动 OpenRC**（TCI 下每个服务脚本都是纯开销），只留 sysinit + agent + 串口控制台
- 输出 `entry/src/main/resources/rawfile/vm/rootfs_guncat.qcow2`

## 4. 验证产物（不需要真机）

```bash
# 0) 最有用的一条: 用宿主机的 qemu-system-aarch64 引导同一镜像, 跑全套协议断言
bash tooling/linux-vm/smoke-test.sh          # 需要 apt install qemu-system-arm

# 1) 确认是解释器构建: 二进制里应能查到 tcg/tci.c, 且没有 aarch64 JIT 后端
strings entry/libs/arm64-v8a/libqemu-system-aarch64-tci.so | grep -m1 'tcg/tci.c'

# 2) 依赖只剩 libc + libslirp, 且不需要可执行栈
$TOOL_HOME/sdk/default/openharmony/native/llvm/bin/llvm-readelf -d \
  entry/libs/arm64-v8a/libqemu-system-aarch64-tci.so | grep NEEDED
$TOOL_HOME/sdk/default/openharmony/native/llvm/bin/llvm-readelf -l \
  entry/libs/arm64-v8a/libqemu-system-aarch64-tci.so | grep GNU_STACK   # 应为 RW

# 3) 镜像能挂载、注入文件都在
qemu-img convert -O raw entry/src/main/resources/rawfile/vm/rootfs_guncat.qcow2 /tmp/r.raw
sudo mount -o loop,ro /tmp/r.raw /mnt && ls /mnt/etc/guncat-setup /mnt/usr/local/bin/guncat-agent && sudo umount /mnt
```

## 5. 真机自检

装到设备后在工作模式里让模型跑一句 `shell(command="uname -a && ls")`。首次调用会冷启动 VM
（TCI 解释执行，数十秒），结果里的 `[exit 0 · …]` 就是客人侧真实退出码。若报「引导超时」，
工具会附带串口日志尾部；常见原因是镜像没打进 HAP 或缺 `-tci` 版 QEMU（`libguncatvm.so` 的
`isAvailable()` 会直接说明）。

## 授权

`deps/` 下的构建配方与 guest 侧的挂载/终端约定改编自 [HiSH](https://github.com/harmoninux/HiSH)
（MIT License, Copyright (c) 2025 hackeris）；QEMU 本体为 GPLv2，作为独立 `.so` 动态加载。
