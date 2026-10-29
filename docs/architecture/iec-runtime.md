# IEC 原生执行核（设备内 shell 后端）

## 为什么换

原来的 `shell` 工具是一台跑在应用进程里的 QEMU 虚拟机（Alpine + 内核，TCI 解释执行）：
不需要 JIT 权限，但**每条命令都在逐条解释**，重命令动辄数秒到数十秒；而且它与原生
CPython 分属两个世界——两个文件系统、两套进程模型。

现在换成 **IEC**（`third_party/bettersh/iec`）：命令编成 HarmonyOS 原生 `.so`，
`fork` 之后直接跑；不需要虚拟机，也不需要 JIT 权限。shell、`python3`、`git`
等都在**同一个文件系统、同一个进程创建入口**下。

## 结构

```
entry/src/main/ets/service/IecRuntime.ets      启动 IEC 服务、铺 launcher、跑命令
entry/src/main/ets/service/IecShellService.ets  shell 工具的实现（参数校验/格式化/spill）
entry/src/main/ets/entryability/EntryAbility.ets 启动时把实现挂到 HarnessTools.shellBackendHook
entry/src/main/ets/service/HarnessTools.ts     只负责调用钩子；钩子为空时报配置错误（没有 QEMU 回退）
third_party/bettersh/                          vendored BetterSH + IEC（见 VENDOR.md）
```

`.ets` / `.ts` 的边界是刻意的：IEC 的入口是 ArkTS（`Index.ets`），而 TS 文件不能
import ArkTS 文件。于是把实现放在 `.ets`，由 `EntryAbility.ets` 注入到
`HarnessTools`（TS）的静态钩子上——TS 只依赖一个函数类型，不依赖 ArkTS 模块。

## 构建

```bash
ohpm install --all
# 用 DevEco 自带的 node（系统 node 25 与 hvigor 不兼容）
hvigorw --no-daemon assembleHap --mode module -p product=default
```

根 `build-profile.json5` 里把 `iec` 声明为本地模块（`srcPath` 指向 vendored HAR），
`entry/oh-package.json5` 用 `file:` 依赖它的 ArkTS 入口。HAP 里会带上
`libs/arm64-v8a/libiec_server.so`。

## 随包的命令 so

完整命令集都在 HAR 的 `libs/arm64-v8a/`（hvigor 会把它们的合进 HAP 的
`libs/arm64-v8a/`），一个 `.so` 缺失时对应 launcher **不注册**，命令干净地报
`command not found`，不会出现"命令在、库不在"的误导性 dlopen 错误。

| 命令 | so | 入口 |
| --- | --- | --- |
| `sh` / `mksh` | `libmksh.so` | `main` |
| `ls/cat/grep/sed/awk/find/xargs/…`（70+） | `libtoybox.so` | `bsh_toybox_main` |
| `tar/bsdtar`、`unzip`、`cpio`、`zip` | `libbsdtar.so` / `libbsdunzip.so` / `libbsdcpio.so` / `libzipcmd.so` | `iec_bsdtar_main` 等 |
| `git`（含 https） | `libgit.so` / `libgit-remote-http.so` | `iec_git_main` / `iec_git_remote_http_main` |
| `ssh/scp/ssh-keygen/…` | `libdropbear.so` | `iec_dropbear_main` |
| `sftp` | `libsftpcmd.so` | `iec_sftp_main` |
| `nc` | `libnc.so` | `iec_nc_main` |
| `hexdump` / `hd` | `libhexdump.so` | `iec_hexdump_main` |
| `diff`（后端是随包 git） | `libdiff.so` | `iec_diff_main` |
| `jq` | `libjqcmd.so` | `iec_jq_main` |
| `curl` | `libcurlcmd.so` | `iec_curl_main` |
| `bc` | `libbccmd.so` | `iec_bc_main` |
| `node/npm/npx`（条件产物） | `libnode.so` | `iec_node_main` / `iec_npm_main` / `iec_npx_main` |
| `python3` / `python` | `libpycmd.so`（Guncat 自带） | `iec_python_main` |

`python3` 走独立解释器进程：应用启动时 `startPyRunner()`（NAPI）在 **CPython 尚未初始化**
的进程里 fork 一个常驻 runner，runner 自己从不加载 libpython；每个请求再由它 fork 一个
孙进程，孙进程才 `dlopen libpython3.12.so` 并跑 `Py_BytesMain`。`libpycmd.so` 只是 UDS
客户端（`NEEDED` 只有 libc），负责把 argv/stdin/env 发过去、把 stdout/stderr/退出码收回来。

这样：被 SIGKILL 只影响那一次请求，runner 不受影响；`sys.exit(n)` 的退出码原样回传；
子进程的 CPython 永远是干净的，不继承 `run_python` 的解释器状态。

重建（需要 Linux 版 OHOS SDK；本机在 WSL 的 `/opt/ohos-cmdline/...`）：

```bash
export OHOS_SDK=/opt/ohos-cmdline/command-line-tools/sdk/default/openharmony
tools/build-iec-runtime.sh          # zlib → openssl → pcre2 → curl → libarchive → git → dropbear
                                    # 再编 nc/hexdump/diff、jq、curl、bc、sftp
tools/build-iec-runtime.sh node     # V8，最久
```

GitHub 直连在 WSL 里通常不通（`codeload.github.com` 可以）：`pcre2` / `git` / `dropbear`
源码要先在 Windows 侧 clone 到 `third_party/bettersh/iec/thirdparty/`。

`python3` / `python` 的 launcher 指向 Guncat 自带的 `libpython3.12.so`
（入口 `Py_BytesMain`）。所以只要那个 `.so` 在包里，shell 里就能起同一个解释器；
`PYTHONHOME`/`PYTHONPATH` 由 `IecShellService` 传入。

## 语义

* `sh -c "<command>"` 执行；管道/重定向/通配符都是 mksh 的真语义。
* `cwd` 是工作区内的相对路径，服务端会拒绝不存在的目录（不会静默回退）。
* 环境：`IecShellService` 显式给 `PATH=<sysroot>/bin:<sysroot>/usr/bin:/usr/bin:/bin`、
  `HOME=<sysroot>/home`、`TMPDIR=<sysroot>/tmp`。**PATH 必须给**——IEC 起进程不会替
  我们拼 PATH，而应用进程自己的环境里没有 launcher 目录，不给就是 `command not found`。
* Python：launcher `python3`/`python` 指向 Guncat 的 `libpython3.12.so`（`Py_BytesMain`），
  并在每次调用前把 `PYTHONHOME`/`PYTHONPATH`（stdlib zip + site-packages + extras +
  bundle libs）传进去，所以 shell 里的 `python3 script.py` 与 `run_python` 是同一份解释器、
  同一份标准库。首次调用会等 `PythonService.ensureRuntime()` 把 stdlib 解出来。
* 超时由引擎线程强制（先 TERM 后 KILL），不依赖 ArkTS 轮询；`timeout_ms`
  上限沿用 `Constants.WORK_SHELL_MAX_TIMEOUT_MS`。
* 输出超过 `WORK_SHELL_MAX_OUTPUT_BYTES` 时整段落 `.spill/`，返回里给相对路径。
* 输出含非法 UTF-8（图片/压缩包）时返回 `binary=true`，工具结果会明确提示改用
  "重定向到文件"或 `base64`，不把乱码当内容。
* 并发：最多 8 条命令同时跑（`IecRuntime.MAX_RUNS`），超出的排队；每条命令独占
  4 个管道线程与 8MB 输出缓冲，所以必须有上限。
* 作业级取消：每个会话的命令带 `IEC_JOB`，取消时按 job 杀整棵树（管道里的每个
  进程、后台子进程都在内），不会留孤儿。

## 验收

设备在线时，用 Want 参数触发一次自检（不需要模型、不需要 UI 操作；**由你执行**）：

```bash
hdc shell aa start -a EntryAbility -b com.bowenapp.guncataibeta --ps iecSelfTest 1
hdc shell hilog -x | grep -A 20 IecSelfTest
```

会依次执行 `uname -s`、`pwd`、`seq 1 3`、`tar -cf`、`python3 -c "print(sys.version...)"`，
把整段输出打到 `IecSelfTest` 标签下。返回里带 `[exit 0 · …s · cwd …]` 就说明
shell → mksh → toybox → exec 服务整条链是通的；`python` 段有版本号说明解释器
launcher 与 `PYTHONHOME` 也对。

## 回退

**没有 QEMU 回退**：QEMU 桥、内核、rootfs 镜像、`libqemu`/`libslirp` 都已从仓库移除
（约 94MB）。`shell` 后端没接上时，工具会明确报"shell 后端未初始化"，而不是静默
换一个慢速实现。

## 已知边界

* 没有真 pty：依赖终端的程序（交互式 TUI）不适用，shell 工具本来就是非交互的。
* 没有 job control（Ctrl+Z/fg/bg）；后台进程用 `&` 可以，但不能挂起。
* `exec` 的 socket 路径是 IEC 的编译期常量（`/data/storage/el2/base/files/iec-exec.sock`），
  与 `startIecServer()` 的默认值一致；改路径要同时改 `common/constant.h`。
* 命令 so 只构建了 arm64-v8a；x86_64 模拟器上 IEC 的 NAPI 会加载失败，
  `shell` 工具会报"运行核加载失败"（没有回退实现）。
