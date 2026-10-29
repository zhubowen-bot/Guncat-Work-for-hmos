# IEC 执行核集成：收尾状态

## 0. 结论

`shell` 工具已完全切到 IEC 原生执行核，**QEMU 虚拟机回退已删除**。随包命令集已覆盖
**mksh + toybox + libarchive 四件套 + git + ssh/scp/sftp + jq/curl/bc + nc/hexdump/diff +
node/npm/npx + python3**，不再有“node 编不出来”的缺口。命令 → `.so` → 入口的完整表见
[iec-runtime.md](iec-runtime.md#随包的命令-so)。

## 1. 已删除的旧实现（历史记录）

| 项 | 说明 |
| --- | --- |
| `entry/src/main/cpp/vm/guncat_vm.cpp`、`types/libguncatvm/` | 旧 QEMU 桥与 NAPI |
| `entry/libs/arm64-v8a/libqemu-system-aarch64-tci.so`、`libslirp.so.0` | 旧虚拟机运行库 |
| `entry/src/main/resources/rawfile/vm/` | 旧内核、rootfs、efi rom、keymaps、guest 脚本 |
| `entry/src/main/ets/service/LinuxShellService.ts` | 旧 QEMU 后端 |
| `tooling/linux-vm/`、`docs/architecture/linux-shell.md` | 旧构建链与文档 |
| `HarnessTools` 里的回退分支 | 钩子为空时直接报“shell 后端未初始化” |

`Constants` 里的 `WORK_LINUX_*` 一并移除；HAP 里已确认没有 `qemu` / `slirp` / `rawfile/vm`。
这些名字只应出现在历史文档（`docs/releases/`、`native-python.md`、
`jit-permission-application.md`、`ALIGNMENT_STATUS.md`、`CHANGELOG.md` 的旧版本小节）里。

## 2. 已随包的命令 so

位置 `third_party/bettersh/iec/platform/ohos/har/libs/arm64-v8a/`，hvigor 合进 HAP 的
`libs/arm64-v8a/`；`IecRuntime` 只在 `.so` 存在时注册 launcher。解包当前 HAP 核对，
下表所有 `.so` 均在包内（命令 so 与 Python 扩展同目录分发；当前签名 HAP 的
`libs/arm64-v8a/` 共 534 个随包文件，其中 516 个是 `.so`，其余是带版本号的运行库）。

| 命令 | so | 入口 | 状态 |
| --- | --- | --- | --- |
| `sh` / `mksh` | `libmksh.so` | `main` | 真机通过 |
| 70+ toybox applet | `libtoybox.so` | `bsh_toybox_main` | 真机通过 |
| `tar` / `bsdtar` | `libbsdtar.so` | `iec_bsdtar_main` | 已在包 |
| `unzip` | `libbsdunzip.so` | `iec_bsdunzip_main` | 已在包 |
| `cpio` / `bsdcpio` | `libbsdcpio.so` | `iec_bsdcpio_main` | 已在包 |
| `zip` | `libzipcmd.so` | `iec_zip_main` | 已在包 |
| `git` 及 upload/receive/archive | `libgit.so` | `iec_git_main` | 已在包 |
| `git-remote-http(s)` | `libgit-remote-http.so` | `iec_git_remote_http_main` | 已在包 |
| `ssh` / `scp` / key 工具 | `libdropbear.so` | `iec_dropbear_main` | 真机通过 |
| `sftp` | `libsftpcmd.so` | `iec_sftp_main` | 已在包 |
| `jq` | `libjqcmd.so` | `iec_jq_main` | 已在包 |
| `curl` | `libcurlcmd.so` | `iec_curl_main` | 已在包 |
| `bc` | `libbccmd.so` | `iec_bc_main` | 已在包 |
| `nc` | `libnc.so` | `iec_nc_main` | 已在包 |
| `hexdump` / `hd` | `libhexdump.so` | `iec_hexdump_main` | 已在包 |
| `diff` | `libdiff.so` | `iec_diff_main` | 已在包 |
| `node` / `nodejs` | `libnode.so`（node 22.19） | `iec_node_main` | 已在包 |
| `npm` / `npx` | `libnode.so` + `rawfile/tools/npm.tar.gz` | `iec_npm_main` / `iec_npx_main` | 已在包 |
| `python3` / `python` | `libpycmd.so` + `libpython3.12.so` | `iec_python_main` | 待真机复验 |

### 2.1 python3：独立 runner，不继承应用进程的解释器

`python3` 不直接在 shell 子进程里调 `Py_BytesMain`。应用启动时 `startPyRunner()`
（NAPI）在 **CPython 尚未初始化**的进程里 fork 一个常驻 runner；runner 自己从不加载
libpython。每个 shell 请求由 runner 再 fork 一个孙进程，孙进程才 `dlopen
libpython3.12.so` 并跑 `Py_BytesMain`。

`libpycmd.so` 只是 UDS 客户端（`NEEDED` 只有 libc），负责把 argv/stdin/env 发过去、
把 stdout/stderr/退出码收回来。这样被 SIGKILL 只影响当次请求，runner 不受影响；
`sys.exit(n)` 的退出码原样回传；子进程的 CPython 永远干净，不会在
`pyinit_core_reconfigure` 崩溃。`PYTHONHOME`/`PYTHONPATH` 由 `IecShellService` 传入。

## 3. 并发与边角

- **并发上限 8**（`IecRuntime.MAX_RUNS`）：超出的排队，不丢请求。
- **超时不再泄漏会话**：`execTerminate`（job 级 SIGKILL）后在后台异步重试 `execRelease`（每 500ms，最多 30 次），`finally` 不阻塞等待。
- **二进制输出**：检测到非法 UTF-8 时工具结果标记并提示改走“重定向到文件/base64”。
- **孤儿进程**：`execKillStale()`（NAPI）启动时按 `IEC_JOB` 扫描 `/proc`，杀掉上次运行
  遗留的命令进程。
- **launcher 目录**：每次启动先清空再按实际存在的 `.so` 重建，旧 launcher 不会残留。
- **npm 解包**：`rawfile/tools/npm.tar.gz` 首次启动解到 `<sysroot>/npm`，之后按
  `<sysroot>/npm/.unpack-complete` 完成标记跳过。不能只看 `npm/bin/npm-cli.js`：
  它是 tar 里第 12 个条目（共 2697 个），首次解包被强停会留下半棵树，只按入口
  判断就会永久跳过解包。

## 4. 体积

当前签名 HAP 约 452.7 MB（约 432 MiB；精确字节数随构建与签名变化）。主要构成：
`libnode.so`（约 108MB）、CPython + numpy/scipy/
pandas/matplotlib 等运行库、命令 so 与技能资源。`libnode.so` 是可选能力，但当前
**默认随包**；若要瘦身，可在构建时排除它，`node`/`npm`/`npx` 会干净地报
`command not found`，其余命令不受影响。

## 5. 待真机验证（由用户执行，不再自动连设备）

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa force-stop com.bowenapp.guncataibeta
hdc shell aa start -a EntryAbility -b com.bowenapp.guncataibeta --ps iecSelfTest 1
hdc shell hilog -x | grep -A 120 IecSelfTest
```

自检分 8 组、共 13 个 `---` 段，互不阻断（每段先打印 `--- 名称`，失败只追加
`[FAIL]`，末行 `SELFTEST DONE`）：PATH 枚举（19 个命令）、mksh 64 位算术、`/tmp` 与 `id`、
CA/git https、python3 退出码、jq/curl/bc/nc/hexdump/diff/sftp、node/npm、清理。

重点看：

1. 每段不应出现 `[FAIL]`；PATH 段应逐个打印 `ok   <命令>`；
2. `--- mksh 64-bit arithmetic` 的 `$((2000000000+2000000000))` 应打印 `2000000000+2000000000=4000000000`；
3. `--- python3` 的 `sys.exit(7)` 之后应打印 `rc=7 (expect 7)`，且不出现 `Fatal Python error`；
4. `--- jq` 应为 `1`，`--- bc` 应为 `2`，`--- diff` 的末行应为 `diff rc=1 (expect 1)`；
5. `--- node/npm` 应分别输出 `v22.19.0`、`10.9.3`。

完整清单、期望输出与故障对照见 [真机验收清单](../guides/device-verification.md)。

## 6. 许可

`THIRD_PARTY_NOTICES.md` 第 1 节：IEC/BetterSH（MIT）、mksh（MirOS）、toybox（0BSD）、
libarchive（BSD-2）、git（GPL-2.0，附源码 tag 与构建脚本）、dropbear（MIT）、
OpenSSH sftp（BSD）、jq（MIT）、curl（curl）、bc（GPL-3.0-or-later）、Node.js（MIT）。
`LICENSES/` 与 `rawfile/licenses/` 已同步；QEMU/HiSH/libslirp 的声明与原文已删。
