# IEC 执行核集成：收尾状态

## 0. 结论

`shell` 工具已完全切到 IEC 原生执行核，**QEMU 回退已删除**。随包命令集从
"mksh + toybox" 扩到 **libarchive 四件套 + git + ssh/scp + python3**；
node 因宿主工具链（GCC 15）编不过，单独列为已知缺口。

## 1. 已删除的旧实现（省 ~94MB）

| 项 | 说明 |
| --- | --- |
| `entry/src/main/cpp/vm/guncat_vm.cpp`、`types/libguncatvm/` | QEMU 桥与 NAPI |
| `entry/libs/arm64-v8a/libqemu-system-aarch64-tci.so`（42.7MB）、`libslirp.so.0` | 虚拟机运行库 |
| `entry/src/main/resources/rawfile/vm/`（49.2MB） | 内核、rootfs、efi rom、keymaps、guest 脚本 |
| `entry/src/main/ets/service/LinuxShellService.ts` | QEMU 后端 |
| `tooling/linux-vm/`、`docs/architecture/linux-shell.md` | 构建链与文档 |
| `HarnessTools` 里的回退分支 | 钩子为空时直接报"shell 后端未初始化" |

`Constants` 里的 `WORK_LINUX_*` 一并移除。HAP 里已确认没有 `qemu`/`slirp`/`rawfile/vm`。

## 2. 已随包的命令 so

位置 `third_party/bettersh/iec/platform/ohos/har/libs/arm64-v8a/`，hvigor 合进 HAP 的
`libs/arm64-v8a/`；`IecRuntime` 只在 `.so` 存在时注册 launcher。

| 命令 | so | 入口 | 验证 |
| --- | --- | --- | --- |
| `sh` / `mksh` | `libmksh.so` | `main` | 真机通过 |
| 70+ toybox 命令 | `libtoybox.so` | `bsh_toybox_main` | 真机通过（含 `seq/stat/cmp/diff`） |
| `tar` / `bsdtar` | `libbsdtar.so`（906K） | `iec_bsdtar_main` | 符号已核 |
| `unzip` | `libbsdunzip.so`（299K） | `iec_bsdunzip_main` | 符号已核 |
| `cpio` / `bsdcpio` | `libbsdcpio.so`（874K） | `iec_bsdcpio_main` | 符号已核 |
| `zip` | `libzipcmd.so`（422K） | `iec_zip_main` | 脚本断言 |
| `git` | `libgit.so`（4.5M） | `iec_git_main` | 符号已核 |
| `git-remote-http(s)` | `libgit-remote-http.so`（7.9M） | `iec_git_remote_http_main` | 脚本断言 |
| `ssh/scp/ssh-keygen/dropbear` | `libdropbear.so`（508K） | `iec_dropbear_main` | 符号已核 |
| `python3` / `python` | `libpycmd.so`（13K）+ `libpython3.12.so` | `iec_python_main` | 待真机验证 |

所有命令 so 的 `NEEDED` 只有 `libc.so`（libpycmd 额外需要 `libpython3.12.so`）。

### 2.1 python3 的关键修复

旧 launcher 直接指向 `libpython3.12.so` 的 `Py_BytesMain`。shell 命令是 fork 出来的，
子进程继承了应用进程里**已初始化**的 CPython（`run_python` 的），再初始化一次会在
`pyinit_core_reconfigure` 崩溃（表现：`-V/-h` 能跑，`-c`/脚本/stdin 必崩，且退出码 0）。

现在 launcher 指向 `libpycmd.so`：先给当前线程挂一个 tstate
（`PyThreadState_New(PyInterpreterState_Main())` + `PyThreadState_Swap`），再
`Py_FinalizeEx()` 把继承的运行时归零，最后走 `Py_BytesMain`；收尾失败会返回 1 并
打到 stderr。父进程不受影响（写时复制）。这个变体在 host 的 fork 场景里验证通过
（直接 `AfterFork+Finalize` 会 SIGABRT）。

## 3. 并发与边角

- **并发上限 8**（`IecRuntime.MAX_RUNS`）：超出的排队，不丢请求。
- **超时不再泄漏会话**：`execTerminate` 后等进程真正退出（最多 3s）再 `execRelease`。
- **二进制输出**：检测到非法 UTF-8 时工具结果标记并提示改走"重定向到文件/base64"，
  不再把乱码当内容。
- **孤儿进程**：新增 `execKillStale()`（NAPI），启动时按 `IEC_JOB` 环境变量扫描 `/proc`，
  杀掉上次运行遗留的命令进程；`ensure()` 里调用并记录数量。
- **launcher 目录**：每次启动先清空再按实际存在的 `.so` 重建，旧 launcher 不会残留。

## 4. 没完成的：node

`libnode.so` **没有产出**。卡在宿主工具链，不是脚本问题：

- node v22.19.0 的宿主侧 V8 torque 在 **GCC 15** 下编译失败
  （`std::formatter<subrange>` / `ranges::input_range` 不满足），`node2.log` 里有 20 个错误；
- node 的 `configure` 只接受 Python 3.8–3.13，系统只有 3.14（已临时放宽并通过 configure），
  真正的构建仍死在 GCC 15。

要编出来需要 GCC ≤13（或换 node 24 的 V8）。当前 `node/npm/npx` 不注册 launcher，
shell 里执行会干净地报 `command not found`；`run_js` 仍是可用的 JS 通道。

## 5. 待真机验证（由用户执行，不再自动连设备）

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.bowenapp.guncataibeta --ps iecSelfTest 1
hdc shell hilog -x | grep -A 30 IecSelfTest
```

自检会依次跑 `uname -s`、`pwd`、`seq`、`tar`、`git --version`、`ssh -V`、`node -v`（预期
not found）、`python3 -c`。重点看：

1. `--- python` 段应输出 `3.12.15 <cwd>`，不再 `Fatal Python error`；
2. `--- tar` 应有 `t.tar` 的 `ls -l` 行；
3. `--- git` 应有 `git version 2.56.0`；
4. `--- ssh` 应有 `Dropbear ssh` 版本行。

## 6. 许可

`THIRD_PARTY_NOTICES.md` 第 1 节已重写：IEC/BetterSH（MIT）、mksh（MirOS）、toybox（0BSD）、
libarchive（BSD-2）、git（GPL-2.0，附源码 tag 与构建脚本）、dropbear（MIT）、Node.js（MIT，
暂未分发）。`LICENSES/` 与 `rawfile/licenses/` 已同步；QEMU/HiSH/libslirp 的声明与原文已删。
