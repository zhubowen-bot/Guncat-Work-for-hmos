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
| `sh` / `mksh` | `libmksh.so` | `main`（`sh` 是补 `-U` 的包装器） |
| `toybox` 及 70+ applet（`ls/cat/grep/sed/awk/find/xargs/…`） | `libtoybox.so` | `bsh_toybox_main` |
| `tar` / `bsdtar` | `libbsdtar.so` | `iec_bsdtar_main` |
| `unzip` | `libbsdunzip.so` | `iec_bsdunzip_main` |
| `cpio` / `bsdcpio` | `libbsdcpio.so` | `iec_bsdcpio_main` |
| `zip` | `libzipcmd.so` | `iec_zip_main` |
| `git` / `git-upload-pack` / `git-receive-pack` / `git-upload-archive` | `libgit.so` | `iec_git_main` |
| `git-remote-http` / `git-remote-https` | `libgit-remote-http.so` | `iec_git_remote_http_main` |
| `ssh` / `scp` / `ssh-keygen` / `dbclient` / `dropbearkey` / `dropbearconvert` / `dropbear` | `libdropbear.so` | `iec_dropbear_main` |
| `sftp` | `libsftpcmd.so` | `iec_sftp_main` |
| `nc` | `libnc.so` | `iec_nc_main` |
| `hexdump` / `hd` | `libhexdump.so` | `iec_hexdump_main` |
| `diff`（后端是随包 git） | `libdiff.so` | `iec_diff_main` |
| `jq` | `libjqcmd.so` | `iec_jq_main` |
| `curl` | `libcurlcmd.so` | `iec_curl_main` |
| `bc` | `libbccmd.so` | `iec_bc_main` |
| `node` / `nodejs` | `libnode.so` | `iec_node_main` |
| `npm` | `libnode.so` | `iec_npm_main` |
| `npx` | `libnode.so` | `iec_npx_main` |
| `python3` / `python` | `libpycmd.so` + `libpython3.12.so` | `iec_python_main` |

上表与 `IecRuntime.writeLaunchers()` 的 `add(...)` 完全一致；每个命令只在对应 `.so` 存在时注册
（`hasSo()`），所以不会出现“命令在、库不在”的误导性 dlopen 错误。

`python3` 走独立解释器进程：应用启动时 `startPyRunner()`（NAPI）在 **CPython 尚未初始化**
的进程里 fork 一个常驻 runner，runner 自己从不加载 libpython；每个请求再由它 fork 一个
孙进程，孙进程才 `dlopen libpython3.12.so` 并跑 `Py_BytesMain`。`libpycmd.so` 只是 UDS
客户端（`NEEDED` 只有 libc），负责把 argv/stdin/env 发过去、把 stdout/stderr/退出码收回来。

`node` 的 `npm` / `npx` 需要 npm 的纯 JS 树：`deps/npm` 打成 `rawfile/tools/npm.tar.gz`
（约 2.6MB），首次启动由 `unpackResource()`（HAR 里的 `libarchive.so.13`）解到
`<sysroot>/npm`；`iec_npm_main` 拼出的命令行是 `<sysroot>/npm/bin/npm-cli.js`。
`libnode.so` 本身 NEEDED `libc.so` 与 `libc++_shared.so`。

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

`python3` / `python` 的 launcher 指向 Guncat 自带的 `libpycmd.so`（入口 `iec_python_main`），
后者把请求转给常驻 python runner；runner 再 fork 的孙进程才 `dlopen libpython3.12.so` 并跑
`Py_BytesMain`。所以只要 `libpython3.12.so` 在包里，shell 里就能起同一个解释器；
`PYTHONHOME`/`PYTHONPATH` 由 `IecShellService` 传入。

## 语义

* `mksh -o utf8-mode -c "<command>"` 执行；管道/重定向/通配符都是 mksh 的真语义。
* `cwd` 是工作区内的相对路径，服务端会拒绝不存在的目录（不会静默回退）。NCP 渠道的
  exec 请求 cwd 不会真正应用（子进程会停在 `/`），所以 `IecRuntime.run` 在脚本前先
  `[ -d <cwd> ]` 校验再 `cd`；fork 渠道重复 `cd` 无副作用。`pwd`、相对路径写入与
  `read_file` 因此保持一致。
* 环境：`IecShellService` 显式给 `PATH=<sysroot>/bin:<sysroot>/usr/bin:/usr/bin:/bin`、
  `HOME=<sysroot>/home/<会话>`、`TMPDIR=<sysroot>/session-tmp/<会话>`、`USER=LOGNAME=guncat`、
  `PAGER=GIT_PAGER=cat`。**PATH 必须给**——IEC 起进程不会替我们拼 PATH，而应用进程自己的
  环境里没有 launcher 目录，不给就是 `command not found`。`HOME`/`TMPDIR` 按会话分目录，
  避免 A 会话的 `~/.gitconfig`、`~/.ssh` 与临时文件串到 B 会话；两者都在工作区外，
  `read_file` 看不见。
* UTF-8：工具自身以 `mksh -o utf8-mode` 启动；`/bin/sh` 写成一层薄包装
  （`exec /bin/mksh -U "$@"`），所以 `sh -c`、`sh script.sh` 与 `#!/bin/sh` 脚本也统一
  按字符处理，`${#中文}`=2、切片按字符。直接 `mksh script.sh` 仍默认按字节，需要
  `mksh -U` 或脚本里 `set -U`；`set +U` 可退回字节语义。`printf` 是 toybox 外部命令，
  **字段宽度仍按字节**（`printf '%5s' 中文` 不会补空格），对齐用 awk/python。
* Python：launcher `python3`/`python` 指向 `libpycmd.so`（`iec_python_main`），由常驻
  python runner 的子进程 `dlopen libpython3.12.so` 并跑 `Py_BytesMain`；每次调用前把
  `PYTHONHOME`/`PYTHONPATH`（stdlib zip + site-packages + extras + bundle libs）传进去，
  所以 shell 里的 `python3 script.py` 与 `run_python` 是同一份解释器、同一份标准库。
  首次调用会等 `PythonService.ensureRuntime()` 把 stdlib 解出来。
* 超时由引擎线程强制（先 TERM 后 KILL），不依赖 ArkTS 轮询；`timeout_ms`
  上限沿用 `Constants.WORK_SHELL_MAX_TIMEOUT_MS`。
* 输出超过 `WORK_SHELL_MAX_OUTPUT_BYTES` 时整段落 `.spill/`，返回里给相对路径。
* 输出含非法 UTF-8 或 NUL 字节（图片/压缩包）时返回 `binary=true`，工具结果会明确提示改用
  "重定向到文件"或 `base64`，不把乱码当内容。
* 并发：最多 8 条命令同时跑（`IecRuntime.MAX_RUNS`），超出的排队；每条命令最多占
  5 个线程（stdin feeder、两条 reader、waiter、watchdog）与 8MB 输出缓冲，所以必须有上限。
* 作业级取消：每个会话的命令带 `IEC_JOB`，取消时按 job 杀整棵树（管道里的每个
  进程、后台子进程都在内），不会留孤儿。

## 验收

> 逐项安装、自检、补充检查与故障对照见 [真机验收清单](../guides/device-verification.md)。
> 本节保留自检脚本的逐段说明。

### 真机自检 `iecSelfTest`

设备在线时，用 Want 参数触发一次自检（不需要模型、不需要 UI 操作；**由你执行**）：

```bash
hdc shell aa force-stop com.bowenapp.guncataibeta
hdc shell aa start -a EntryAbility -b com.bowenapp.guncataibeta --ps iecSelfTest 1
hdc shell hilog -x | grep -A 120 IecSelfTest
```

> `onNewWant()` 不处理 `iecSelfTest`，必须在应用未运行时冷启动；否则自检不会执行。

自检由一组**互不阻断**的段组成：每段先打印 `--- 名称`，某项失败只追加一行
`[FAIL] ...`，后面的段照常执行；每个可能阻塞的命令都套 `timeout 10`，整组以
60s 工具超时兜底。末行固定为 `SELFTEST DONE`——看到它才说明整组确实跑完了
（是否有失败再逐行看 `[FAIL]`）。因为最后一条是 `echo`，工具返回头应是
`[exit 0 · …s · cwd .]`，这不代表所有段都通过。

| 段 | 执行内容 | 期望值 |
| --- | --- | --- |
| 基线 | `uname -s`、`pwd` | `Linux`；工作区绝对路径（`<filesDir>/workspaces/__iec_selftest` 一类） |
| PATH | `command -v` 枚举 `dd md5sum od nproc jq curl bc nc hexdump diff sftp node npm tar unzip zip git ssh python3` | 每个都打 `ok   <名字>`（`ok` 后 3 个空格）；缺失时单独一行 `[FAIL] <名字> not found`，不中断后续段 |
| mksh 64 位算术 | `v=$((2000000000+2000000000)); echo "2000000000+2000000000=$v"` | `2000000000+2000000000=4000000000`（32 位会溢出成负数，并追加 `[FAIL] arithmetic`） |
| `$TMPDIR` + `/tmp` 不存在 + `id` | `echo x > "$TMPDIR/_t" && cat "$TMPDIR/_t" && rm -f "$TMPDIR/_t"`；`[ -e /tmp ] && echo "[FAIL] /tmp should be absent"`；`id; id -un` | 打印 `x`；`ok /tmp absent`；`id` 含 `uid=<真实 uid>`、`id -un` 为 `guncat`，没有 `[FAIL]` |
| CA + git 网络 | `echo "GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-<empty>}"`；`[ -n "$GIT_SSL_CAINFO" ] && [ -f "$GIT_SSL_CAINFO" ]`；`GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/git/git.git HEAD` | `GIT_SSL_CAINFO=` 指向存在的 `…/etc/ssl/certs/cacert.pem`；git 输出前 3 行含 40 位 commit，末行 `git ls-remote rc=0 (网络失败不算自检失败)`（网络不通时 `rc=124/128` 只记录，**不判自检失败**） |
| python3 | `python3 -c "import sys; sys.exit(7)"`；`python3 -c "print(1+1)"` | `rc=7 (expect 7)`（退出码原样透传）；`2` |
| jq | `printf '{"a":1}\n' \| jq -r .a` | `1` |
| curl | `curl --version \| head -1` | 以 `curl 8.22.0` 开头 |
| bc | `echo '1+1' \| bc` | `2` |
| nc | `nc -h` / 无参，取 usage 首行 | 含 `usage: nc`（自编 nc 没有 `-h` 也走 usage） |
| hexdump | `printf AB \| hexdump -C` | 首行 `00000000  41 42` + 补齐空格 + `\|AB\|`（`\|` 在第 60 列），第二行 `00000002`（最终偏移） |
| diff | `$TMPDIR/_d1`=a、`$TMPDIR/_d2`=b，`diff -u` | git 前缀 + unified diff（`-a` / `+b`），末行 `diff rc=1 (expect 1)`（有差异是正确结果） |
| sftp | `sftp -V` / `sftp -h` / 无参，取首行 | OpenSSH sftp 的 `unknown option -- V` 或 `usage: sftp ...`（没有 `-V` 属正常） |
| node/npm | `node -v`、`npm -v` | `v22.19.0` 与 `10.9.3`（npm 有版本号说明 `npm-cli.js` 解包与 launcher 都对） |
| 清理 | `rm -f "$TMPDIR/_t" "$TMPDIR/_d1" "$TMPDIR/_d2" t.txt t.tar` | 无输出；随后 `SELFTEST DONE` |

`SELFTEST DONE` 之前的任一行 `[FAIL]` 都对应上表某一项；PATH 段的 `ok   <名字>` 行数应为 19。
自检只读/临时写 `$TMPDIR` 与工作区内的 `t.txt`/`t.tar`（跑完即删），不碰用户数据。

## 回退

**没有 QEMU 回退**：QEMU 桥、内核、rootfs 镜像、`libqemu`/`libslirp` 都已从仓库移除
（约 94MB）。`shell` 后端没接上时，工具会明确报"shell 后端未初始化"，而不是静默
换一个慢速实现。

## 已知边界

* 没有真 pty：依赖终端的程序（交互式 TUI）不适用，shell 工具本来就是非交互的。
* 没有 job control（Ctrl+Z/fg/bg）；后台进程用 `&` 可以，但不能挂起。
* `:` / `exec` 的重定向失败会按 POSIX 特殊内建语义**直接终止整条非交互脚本**，
  `set +e` / `if` / `||` / `for` 都拦不住。探测可写性用 `printf '' > f 2>/dev/null`
  再看 `$?`；关键清理/落盘段放进函数或子 shell。
* `umask` 被平台文件系统忽略：新文件恒 666、新目录 775，`umask 077` 无效；
  `chmod` 本身可用（fs shim 用 `.IEC_CHMOD` 旁路记录）。敏感文件必须显式
  `chmod 600` 并用 `stat -c %a` 复核。
* `flock` 不可用：toybox 只接受 fd 形式，且锁系统调用在沙箱里被拒绝；
  互斥用 `mkdir lockdir`（成功即持锁，`rmdir` 释放）。
* `ulimit` 是空实现：mksh 编译时没有 `HAVE_SETRLIMIT`，`c_ulimit` 被定义成
  `c_true`，所以查询无输出、设置恒成功。
* `id` / `whoami` / `logname` 都依赖 `<sysroot>/etc/passwd`（用户 `guncat`），uid/gid
  在启动时从 `/proc/self/status` 读取，读不到则用 `process.uid` 与 sysroot 的
  `st_uid`/`st_gid`；另外 `/bin/id`、`/bin/whoami`、`/bin/logname` 是带兜底的包装器：
  先试 toybox 真实现，失败时用 mksh 的 `USER_ID`/`KSHEGID` 输出。取 uid/gid 仍可用
  `stat -c %u/%g`（toybox 的 `whoami`/`logname` 本质都是 `id -un`）。
* `df` 的容量列可用，`Mounted on` 列来自沙箱的 `/proc/mounts`，是伪值。
* `/tmp` **刻意不提供**：fs shim 的路径映射只覆盖 `open`/`opendir`，`stat`/`chdir`/`mkdir`
  会落到宿主只读根，保留 `<sysroot>/tmp` 只会得到“`test -d /tmp` 为真、`cd /tmp` 失败”
  的半挂载。启动时删除旧版本留下的 `<sysroot>/tmp`；临时文件用 `$TMPDIR`
  （`<sysroot>/session-tmp/<会话>`）或 `mktemp ./x.XXXXXX`。
* `getconf ARG_MAX` = 131072（128KB）：`rm *` 遇到大量长文件名或 `xargs` 大批量会
  `E2BIG`，改用 `find ... -exec ... +` 或分组处理。
* 硬链接会被沙箱拒绝（`IEC_SHIM_LINK_STRICT=1` 让 `git clone` 正确回退到复制）；
  `chown` 返回 `Operation not permitted`。
* 管道退出码默认只取最后一条，要全链路判断用 `set -o pipefail`。
* `exec` 的 socket 路径是 IEC 的编译期常量（`/data/storage/el2/base/files/iec-exec.sock`），
  与 `startIecServer()` 的默认值一致；改路径要同时改 `common/constant.h`。
* 命令 so 只构建了 arm64-v8a；x86_64 模拟器上 IEC 的 NAPI 会加载失败，
  `shell` 工具会报"运行核加载失败"（没有回退实现）。
