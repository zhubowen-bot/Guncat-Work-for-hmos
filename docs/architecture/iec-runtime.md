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
entry/src/main/ets/service/HarnessTools.ts     只负责调用钩子；钩子为空时退回 QEMU 后端
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

## 运行前提：命令 so

IEC 只负责"起进程"，**命令本身是 `.so`**。仓库里没有这些产物（它们是交叉编译的
二进制），需要先构建：

```bash
cd third_party/bettersh
git submodule update --init thirdparty/toybox thirdparty/mksh   # 需要时
./scripts/build_toybox.sh     # feature/bsh_main/libs/arm64-v8a/libtoybox.so
./scripts/build_mksh.sh       # .../libmksh.so
# 可选：build_dropbear.sh / build_git.sh / build_zip.sh / build_node.sh …
```

把产物拷到 `entry/libs/arm64-v8a/` 再重装 HAP。`IecRuntime.writeLaunchers()` 会在
首次启动时把 `bin/<命令>` 的启动器写进资源根（`/data/storage/el2/base/files/bin`），
指向 `libs/arm64/<so>`；**so 不在时只是那条命令失败**，不影响其它命令。

`python3` / `python` 的 launcher 指向 Guncat 自带的 `libpython3.12.so`
（入口 `Py_BytesMain`，已确认导出）。所以只要那个 `.so` 在包里，shell 里就能起
同一个解释器；`PYTHONHOME` 等环境变量由调用方在 `env` 里给。

## 语义

* `sh -c "<command>"` 执行；管道/重定向/通配符都是 mksh 的真语义。
* `cwd` 是工作区内的相对路径，服务端会拒绝不存在的目录（不会静默回退）。
* 超时由引擎线程强制（先 TERM 后 KILL），不依赖 ArkTS 轮询；`timeout_ms`
  上限沿用 `Constants.WORK_SHELL_MAX_TIMEOUT_MS`。
* 输出超过 `WORK_SHELL_MAX_OUTPUT_BYTES` 时整段落 `.spill/`，返回里给相对路径。
* 作业级取消：每个会话的命令带 `IEC_JOB`，取消时按 job 杀整棵树（管道里的每个
  进程、后台子进程都在内），不会留孤儿。

## 回退

把 `EntryAbility.onCreate` 里的 `HarnessTools.shellBackendHook = ...` 一行去掉
（或置 `null`），`shell` 工具就回到原来的 QEMU 后端；`LinuxShellService` 没有删。

## 已知边界

* 没有真 pty：依赖终端的程序（交互式 TUI）不适用，shell 工具本来就是非交互的。
* 没有 job control（Ctrl+Z/fg/bg）；后台进程用 `&` 可以，但不能挂起。
* `exec` 的 socket 路径是 IEC 的编译期常量（`/data/storage/el2/base/files/iec-exec.sock`），
  与 `startIecServer()` 的默认值一致；改路径要同时改 `common/constant.h`。
* 命令 so 只构建了 arm64-v8a；x86_64 模拟器上 IEC 的 NAPI 会加载失败，
  `shell` 工具会退回错误提示（QEMU 后端仍在）。
