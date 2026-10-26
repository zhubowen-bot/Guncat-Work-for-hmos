# Shell 工具：设备内真 Linux（QEMU TCI 解释执行）

> 一句话：`shell(command, cwd?, timeout_ms?, stdin?)` 在设备上跑一条**真的 Linux 命令**，
> 返回退出码与 stdout/stderr；它的工作目录**就是**当前会话工作区 —— 与 `read_file` / `write_file` /
> `edit` 操作的是同一批文件，不是副本。

## 1. 硬约束决定了架构

| 约束 | 后果 |
| --- | --- |
| 手机拿不到 JIT 需要的受限权限（可执行内存） | QEMU 必须用 `--enable-tcg-interpreter`（TCI）构建：逐条解释执行字节码，不生成机器码 |
| HarmonyOS 应用不能 fork/exec 子进程 | QEMU 以动态库形式（`libqemu-system-aarch64-tci.so`）被 dlopen，在应用进程的一个线程里跑 `qemu_system_entry()` |
| ArkTS 不能开 unix domain socket，也不该解析终端转义 | **命令协议不走串口**：命令与结果全部走 virtio-9p 共享目录，串口只留作内核日志排障 |
| shell 必须和其它工具看到同一批文件（本项目的硬要求） | 宿主把 `filesDir/workspaces` 整棵目录用 virtio-9p 注入客人，客人在执行命令前 `bind mount` 到 `/workspace` |

## 2. 组件与调用链

```
ArkTS 工具层
  HarnessTools.dispatch('shell')
    └─ LinuxShellService.run()            ← 串行队列、参数校验、超时、输出截断
         ├─ ensureBoot()                 ← 首启: 释放镜像 → 启动 QEMU → 等 9p 就绪标记
         │    ├─ libguncatvm.so (native) ← dlopen libqemu-system-aarch64-tci.so
         │    │    ├─ QEMU 线程          ← qemu_system_entry(argc, argv)
         │    │    └─ 串口线程           ← unix socket 读内核日志 → 环形缓冲(serialTail)
         │    └─ ensureImages()          ← rawfile → filesDir/linux/vm/(按 versionCode 缓存)
         ├─ 写任务到 filesDir/linux/ipc/<会话>/in/<id>/
         └─ 轮询 filesDir/linux/ipc/<会话>/out/<id>/done
                     ▲                    │
                     │ 9p 共享            ▼
            ┌────────────────────────────────────────────┐
            │ 客人 Alpine (busybox, 无 OpenRC)           │
            │  /etc/guncat-setup  : 挂 proc/sys/dev、DHCP、挂两个 9p │
            │  /usr/local/bin/guncat-agent : 轮询 in/*/ready        │
            │      执行 → 写 out/<id>/{stdout,stderr,code,done}     │
            │  /workspace → bind mount 到 /mnt/workspaces/<会话>    │
            └────────────────────────────────────────────┘
```

涉及文件：

| 文件 | 作用 |
| --- | --- |
| `entry/src/main/cpp/vm/guncat_vm.cpp` | N-API 桥：`startVM` / `status` / `serialTail` / `onData` / `onExit` / `sendInput` |
| `entry/src/main/ets/service/LinuxShellService.ts` | ArkTS 侧：镜像释放、QEMU 参数、任务下发、轮询、结果整形 |
| `tooling/linux-vm/guest/guncat-setup` | 客人 sysinit：伪文件系统、DHCP、两个 9p 挂载 |
| `tooling/linux-vm/guest/guncat-agent` | 客人任务代理：认领任务、切换 `/workspace`、执行、回写结果 |
| `tooling/linux-vm/build-libqemu-tci.sh` | 交叉编译 TCI 版 QEMU |
| `tooling/linux-vm/build-rootfs.sh` | 生成定制 Alpine 镜像 |
| `entry/src/main/resources/rawfile/vm/*` | 内核、根文件系统、ROM、键盘映射 |

## 3. 目录一致性（本项目的硬要求）

宿主的会话工作区是 `filesDir/workspaces/<会话 id>`。VM 启动时传两个 `-fsdev`：

| mount_tag | 宿主路径 | 客人挂载点 | 用途 |
| --- | --- | --- | --- |
| `workspaces` | `filesDir/workspaces` | `/mnt/workspaces` | 全部会话的工作区（**就是工具读写的那个目录**） |
| `guncatipc` | `filesDir/linux/ipc` | `/mnt/guncat-ipc` | 任务下发 / 结果回传（**故意放在工作区外**，不污染文件树） |

`guncat-agent` 在执行每条命令前做一次：

```sh
[ "$(cat /run/guncat/workspace.current)" = "$conv" ] || {
  umount /workspace 2>/dev/null
  mount --bind "/mnt/workspaces/$conv" /workspace
  echo "$conv" > /run/guncat/workspace.current
}
cd "/workspace/$cwd" && sh "$cmd"
```

于是：

- shell 里的 `pwd` 是 `/workspace`（相对路径与 `read_file` 的 `path` 参数一一对应）；
- `cd ..` 只会到 `/`，看不到别的会话（工作区之间的隔离靠 bind mount 目标实现，一台 VM 服务所有会话）；
- shell 写的文件，`read_file` 下一次就能读到；`write_file` 写的文件，shell 里 `cat` 就能看到 —— 因为中间没有拷贝；
- 9p 用 `security_model=none`（**不是** `mapped-file`）：客人写入的文件在宿主侧直接归应用进程所有，
  app 沙箱权限模型不变；而 `mapped-file` 会在每个目录里写 `.virtfs_metadata`，把工作区弄脏
  （`list_files` 与运行时快照都会看到）。共享目录本来就是应用私有，不需要保留 guest uid/gid。

**自检方法**（真机）：让模型执行 `shell(command="echo hi > same-dir.txt")`，紧接着 `read_file("same-dir.txt")`；
再反过来 `write_file("from-tool.txt","ok")`，然后 `shell(command="cat from-tool.txt")`。两条都要通。

**不需要真机的离线自检**：`bash tooling/linux-vm/smoke-test.sh` —— 用宿主机的 `qemu-system-aarch64`
按应用里的同一套参数（同一镜像、同一 9p tag、同一 `security_model=none`）引导一遍，然后跑全套协议断言：
`.ready`、两个 9p 挂载、`pwd`/`cwd`、stdout/stderr/退出码、超时 137、管道与 `for`，以及"客人写的文件
在宿主工作区里立即可见、且没有 `.virtfs_metadata` 污染"。改镜像或改协议后先跑它，再上真机。

**与 subagent 的边界**：子代理的工具面里**不含** `shell`。子代理的工作区写入隔离只重定向"路径参数"，
约束不了 shell 命令里的任意重定向/`rm`/`mv`，留着它等于给子代理留一条越界写入的后门
（见 `SubagentService.excludedTools()`）。

## 4. 命令协议（文件即接口）

宿主 → 客人（`filesDir/linux/ipc/<会话>/in/<任务 id>/`）：

| 文件 | 必填 | 含义 |
| --- | --- | --- |
| `cmd` | ✅ | shell 脚本正文，客人用 `/bin/sh <cmd>` 执行 |
| `cwd` |  | 相对工作区的子目录，缺省为工作区根 |
| `timeout` |  | 秒数（客人用 busybox `timeout -s KILL`），缺省 60 |
| `stdin` |  | 命令的标准输入内容（缺省 `/dev/null`） |
| `ready` | ✅ | **最后**创建；出现即表示请求完整，客人开始执行 |

> **跨域桥 `npy`**：客人里的 `npy` 会往 `…/call/<id>/` 写同样形状的请求（`code`/`argv`/`cwd`/`timeout`/`stdin`/`ready`），
> 宿主在执行 shell 任务的同时轮询这个目录，用**原生 CPython** 执行后把结果写回 `…/out/<id>/`。
> 于是 `npy gen.py | jq ...` 这种管道里的 Python 段也是原生速度（详见 [native-python.md](native-python.md)）。

客人 → 宿主（`…/out/<任务 id>/`）：

| 文件 | 含义 |
| --- | --- |
| `started` / `finished` | 起止时间戳（秒） |
| `stdout` / `stderr` | 原始输出（不做任何转义） |
| `code` | 退出码（`timeout` 杀掉的为 137；busybox timeout 也可能给 124） |
| `done` | 执行完毕标记 |

为什么不复用 QEMU 的 `-serial`：串口是终端语义（回显、提示符、ANSI 转义、二进制转义），
用它做机器可读的 RPC 需要一层脆弱的 demarcation；而 9p 已经是共享文件系统，写文件 +
轮询 `done` 是零解析、零转义的。宿主轮询间隔 120ms，对 TCI 秒级的命令开销可以忽略。

## 5. 生命周期与开销

| 阶段 | 行为 |
| --- | --- |
| 首次调用 | 释放镜像（压缩 qcow2 约 37MB，按 `versionCode` + `WORK_LINUX_IMAGE_REV` 缓存到 `filesDir/linux/vm/`）→ 启动 QEMU → 轮询 `ipc/.ready`（上限 180s） |
| 引导完成 | 客人 `guncat-setup` 挂完 9p，`guncat-agent` 写 `.ready` 后开始轮询任务 |
| 后续调用 | 直接下发任务，只有 9p 往返 + 命令本身的开销 |
| 空闲 10 分钟 | 宿主下发 `sync; poweroff -f`，QEMU（带 `-no-reboot`）退出，释放 2GB 内存 |
| 进程退出 | QEMU 线程随进程结束；下次启动清掉旧 `.ready` 重新引导 |

资源：`-m 2048`、`-smp 1`、`-accel tcg,thread=single`（TCI 不支持多线程 TCG）、无显示设备
（`-display none`）、无 QMP/monitor、网络走 slirp 用户态（出站可用，不监听宿主端口）。

**为什么是 1 核**：TCI 没有多线程 TCG，`-smp N` 的多个 vCPU 只会轮流跑在同一个宿主线程上，
对"一条命令跑完"的模型没有收益，只多出 TCG 上下文切换开销；要真并行得上 JIT，而 JIT 需要受限权限。
**为什么是 2GB**：手机普遍 12GB+，`apk add`、`pip install`、解大压缩包都吃内存；空闲 10 分钟自动关机，
不长期占着。

## 5.1 预装软件

镜像里**已预装**常用工具（见 `tooling/linux-vm/provision-packages.sh`）：

| 包 | 用途 |
| --- | --- |
| `python3`（3.12） | 数据处理、脚本、算法试算 —— 模型最常用的"真程序" |
| `py3-pip` | `pip install` 第三方库（如 `requests`、`openpyxl`） |
| `jq` | JSON 切分/筛选（配合 `cat data.json \| jq ...`） |
| `ca-certificates` | HTTPS 证书链（pip / curl / apk 都依赖） |

装包是**用镜像自己装自己**：`provision-packages.sh` 用宿主 qemu 引导待发布镜像，走同一套命令协议
在客人内部 `apk add`，再关机回写 qcow2 —— 依赖解析与 post-install 触发器都由 apk 完成，不是在宿主
手工解包。要加包就改 `PACKAGES` 重跑一次（例如 `PACKAGES="python3 py3-pip py3-numpy pandas"`）。

## 6. 安全边界（明确写清楚）

- 客人里是 **root**：能改 VM 内的 `/etc`、能 `poweroff`。这些改动落在应用沙箱里的 `rootfs_guncat.qcow2`，
  出问题删掉该文件重启应用即可回到出厂状态（`ensureImages` 会重新释放）。
- 客人能看到的宿主文件只有 `/mnt/workspaces/<本会话>`（bind 目标）与 `/mnt/guncat-ipc`（命令通道）。
  别的会话的工作区在同一台 VM 的 `/mnt/workspaces/` 下，但代理只会把 `/workspace` 绑到当前会话。
- 没有新增系统权限：9p 是 QEMU 进程内的文件访问，网络是 slirp（只需要应用已有的 `INTERNET`）。
- 危险命令（`rm -rf`、`apk add`、`curl | sh`）在 VM 内执行，影响面是虚拟机，不是宿主 app 沙箱 ——
  但 VM 能写工作区，所以对工作区仍然是真实破坏，提示词里要求模型谨慎使用。

## 7. 排障手册

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 工具返回「本机无法运行 Linux VM: 无法加载 QEMU 运行库」 | HAP 里没打进 `libqemu-system-aarch64-tci.so`（非 arm64 构建也会这样） | 按 `tooling/linux-vm/README.md` 编译并放进 `entry/libs/arm64-v8a/` |
| 「Linux VM 在引导完成前退出了」+ 串口日志 | 内核/镜像缺失、参数不兼容 | 看日志尾部；典型是 `root=/dev/sda` 对不上或 9p 挂不上的 `guncat: … mount failed` |
| 「引导超时」但串口有登录提示 | `guncat-agent` 没跑起来（`.ready` 没写） | 确认镜像里 `/usr/local/bin/guncat-agent` 可执行、`/etc/inittab` 含 `::respawn:` 行 |
| 命令一直超时、`out/stdout` 空 | `/workspace` bind 失败或 `cwd` 指向不存在目录 | 代理会回退到 `/workspace`；检查 `/mnt/workspaces/<会话>` 是否存在 |
| `apk add` 失败 | 无网络/DNS | 客人跑 `ip a; cat /etc/resolv.conf`；slirp 下应为 `10.0.2.15` / `10.0.2.3` |
| 输出被截断 | 超 `WORK_SHELL_MAX_OUTPUT_BYTES`(60KB) | 结果里会给出工作区 `.spill/shell-*.log` 路径，用 `read_file` 读回 |
| 应用直接闪退（无工具结果） | QEMU 与 App **同进程**（与 HiSH 相同的设计），若 QEMU 在参数/镜像层面硬失败会走到自己的 `exit()` | 参数是固定的、镜像在启动前已校验长度，正常不会触发；怀疑时先跑 `smoke-test.sh` 验镜像，再看是否漏打了 `libslirp.so.0` |

## 8. 维护

- **换内核 / 换根文件系统**：`bash tooling/linux-vm/fetch-assets.sh` 取新素材 → `build-rootfs.sh` 重新注入 →
  `provision-packages.sh` 装包并压缩 → 重新打包。**改完镜像必须把 `Constants.WORK_LINUX_IMAGE_REV` 换个值**，
  否则已装设备（同 versionCode）不会重新释放镜像。
- **镜像为什么是压缩 qcow2**：同一份内容未压缩 117MB、压缩后 37MB。压缩版让 HAP 少 80MB、设备侧占用也少 80MB；
  代价是 `qemu-img` 里 `-c` 的簇在读时要解压，而我们的 QEMU 静态链了 zlib（已确认 `.so` 内有 inflate 且
  qcow2 驱动正常），这部分开销相对 TCI 的解释执行可以忽略。
- **改命令协议**：`guncat-agent` 与 `LinuxShellService` 必须同步改（协议是"文件即接口"，没有版本协商；
  两者在同一个 HAP 里发布，不需要向后兼容）。
- **改 QEMU 参数**：集中在 `LinuxShellService.buildQemuArgs()`；`thread=multi` 在 TCI 下会启动失败。
- **升级工具链**：`deps/` 的配方对 HarmonyOS SDK 版本不敏感；换 SDK 只需重新设置 `TOOL_HOME` 全量编一次（`FORCE=1`）。
