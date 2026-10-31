# 真机验收清单（shell / IEC）

> [← 返回 README](../../README.md)

> 适用：**HarmonyOS arm64 真机 / 2in1**，应用版本 7.0.0（`com.bowenapp.guncataibeta`）。
> 目标：只装一次包，逐项确认 `shell` 工具确实跑在 IEC 原生执行核上——随包命令、mksh 64 位算术、
> CA、`python3` 独立 runner、npm 解包、git 硬链接 shim 都生效。
>
> 本仓库 CI **不接触设备**，`scripts/check-all.sh` 只跑宿主侧的纯逻辑/构建检查；下面每一项
> 都需要在真机上手工执行。

## 1. 安装与触发

### 1.1 HAP 路径

| 项 | 值 |
| --- | --- |
| 签名包 | `entry/build/default/outputs/default/entry-default-signed.hap` |
| 大小 | 约 452.7 MB（约 432 MiB；精确字节数随构建与签名变化） |
| 包名 | `com.bowenapp.guncataibeta` |
| Ability | `EntryAbility` |

必须装 **signed** 包；`entry-default-unsigned.hap` 不能直接 `hdc install`。重新构建时用：

```bash
hvigorw --no-daemon assembleHap --mode module -p product=default
```

构建细节（HAR、`libs/arm64-v8a`、签名）见 [IEC 执行核](../architecture/iec-runtime.md#构建)。

### 1.2 安装

```bash
hdc list targets
hdc -t <序列号> install -r entry/build/default/outputs/default/entry-default-signed.hap
```

- `<序列号>` 换成 `hdc list targets` 输出的那一串；只有一台设备时可以省略 `-t`。
- 覆盖安装（`-r`）会保留应用沙箱，也就保留旧的 launcher、`<sysroot>/npm` 与解包完成标记。
  **第一次验收，或从旧 IEC 包升级时**，先卸载再装，确保 launcher 与 npm 树按当前包重新生成：

```bash
hdc -t <序列号> uninstall com.bowenapp.guncataibeta
```

> 卸载会清掉应用沙箱里的工作区、会话与配置；需要保留就先备份。

### 1.3 触发内置自检

`IecShellService.selfTest()` **没有 NAPI 或调试 UI 入口**。它唯一的调用点是
`EntryAbility.onCreate()`：启动参数里出现 `iecSelfTest` 时执行一次，结果写 hilog。
`onNewWant()` 不处理这个参数，所以必须**冷启动**，不能在已运行的实例上再 `aa start`：

```bash
hdc -t <序列号> shell aa force-stop com.bowenapp.guncataibeta
hdc -t <序列号> shell aa start -a EntryAbility -b com.bowenapp.guncataibeta --ps iecSelfTest 1
```

`--ps <key> <value>` 传字符串参数。自检整体有 60 秒工具超时，跑完后 dump 日志
（`hilog -x` 输出完即退出）：

```bash
hdc -t <序列号> shell hilog -x > iec-selftest.log
```

Windows PowerShell：

```powershell
Select-String -Path .\iec-selftest.log -Pattern 'IecSelfTest' -Context 0,120
```

bash：

```bash
grep -A 120 IecSelfTest iec-selftest.log
```

期望看到（时间、路径以实际为准）：

```text
... IecSelfTest ... starting
... IecSelfTest ... RESULT
[exit 0 · 12.34s · cwd .]
IEC_OK
Linux
<filesDir>/workspaces/__iec_selftest
...
SELFTEST DONE
```

> shell 工具只回显命令的**输出**，不回显命令行本身，所以正文第一行是 `IEC_OK`（`echo IEC_OK`
> 的结果），不是 `echo IEC_OK`。`pwd` 打的是会话工作区：`<filesDir>` 是应用沙箱的
> `context.filesDir`（随模块/设备而变），不是 IEC 的 `<sysroot>`（后者见 2.2）。

判读规则：

- **`SELFTEST DONE` 必须出现**。没有它说明整组命令没跑完（60 秒超时、进程被杀等）。
- 头部 `[exit 0 · …s · cwd .]` 只代表最后一条 `echo` 成功，**不代表全过**；逐行看 `[FAIL]`。
- PATH 段应有 **19 行 `ok   <命令>`**（19 个命令，见 3.1）。
- 只有 `starting` 没有 `RESULT`：先等满 60 秒；仍没有就看 hilog 的 `IecRuntime` / `IecShell`。
- 连 `starting` 都没有：启动走了 `onNewWant`（应用没被真正停掉），重做 `aa force-stop` 后再启动。

### 1.4 其余检查怎么执行

自检覆盖第 3 节列出的项；第 4 节的补充项要让模型在**工作模式**调用 `shell` 工具执行。提示词示例：

```text
请用 shell 依次执行下面的检查命令，保留完整 stdout/stderr 和退出码，不要省略失败项。
```

> 不要用 `hdc shell` 复跑这些命令：那是设备 shell 用户，通常读不到应用沙箱（el2），
> PATH 里也没有 `<sysroot>/bin`，结果不代表内置 `shell` 工具。自检和下面的命令都在
> **应用进程内**执行，才能看到同一套 launcher、socket 和 `/etc` 映射。

## 2. 排障坐标

后面的“失败时看哪里”都指向这里的 tag 和路径。

### 2.1 hilog

| tag | 记录什么 |
| --- | --- |
| `IecRuntime` | 运行核启动、launcher 写入、stale 进程清理、CA 铺设、exec 启动失败 |
| `IecShell` | 单条命令的 Python 环境准备、输出落盘（spill）失败 |
| `IecSelfTest` | 自检开始、完整结果、异常 |

domain 均为 `0x0000`。dump 全部日志：

```bash
hdc -t <序列号> shell hilog -x > iec-hilog.log
```

再按 tag 过滤（PowerShell 用 `Select-String -Path .\iec-hilog.log -Pattern 'IecRuntime'`）。

### 2.2 设备内路径（应用沙箱视图）

| 路径 | 说明 |
| --- | --- |
| `/data/storage/el2/base/files` | `<sysroot>`，launcher、`tmp`、`etc`、`npm` 都在它下面 |
| `<sysroot>/bin/` | 每个命令一个 launcher；`command -v` 应指向这里 |
| `<sysroot>/session-tmp/<会话>/` | `$TMPDIR` 的真实目录；`/tmp` 刻意不提供（映射只覆盖 open/opendir） |
| `<sysroot>/etc/passwd`、`<sysroot>/etc/group` | `id` 的数据源，按真实 uid/gid 生成 |
| `/data/storage/el2/base/files/etc/ssl/certs/cacert.pem` | CA bundle（`<sysroot>/etc/ssl/certs/cacert.pem`），`GIT_SSL_CAINFO` / `SSL_CERT_FILE` / `CURL_CA_BUNDLE` 都指向它 |
| `/data/storage/el2/base/files/iec-exec.sock` | IEC exec 服务 socket（`<sysroot>/iec-exec.sock`，编译期常量） |
| `/data/storage/el2/base/files/py-runner.sock` | `python3` 常驻 runner 的 UDS（`<sysroot>/py-runner.sock`） |
| `/data/storage/el2/base/files/npm/.unpack-complete` | npm 解包完成标记；**整棵 JS 树解完才写** |
| `/data/storage/el2/base/files/npm/bin/npm-cli.js` | npm 入口；只有它还不够，必须同时有完成标记 |

这些路径在应用沙箱内，`hdc shell` 一般访问不到；用模型执行
`ls -l /data/storage/el2/base/files/...` 查看。

### 2.3 HAP 内容

命令 so 缺失时，最直接的确认方式是看包里有没有对应 `.so`：

```bash
unzip -l entry/build/default/outputs/default/entry-default-signed.hap \
  | grep -E 'lib(mksh|toybox|bsdtar|bsdunzip|bsdcpio|zipcmd|git|git-remote-http|dropbear|node|pycmd|python3.12|sftpcmd|diff|jqcmd|curlcmd|bccmd|nc|hexdump|iec_server)\.so'
```

Windows 上用 `Select-String` 代替 `grep`，或直接在 Git Bash 里跑。

## 3. 自检已覆盖项

下面命令与 `IecShellService.selfTest()` 的段一一对应，可先用 1.3 的 hilog 结果对照，
再单独复跑失败项。命令均由模型通过 `shell` 工具执行。

### 3.1 PATH 枚举

| 项目 | 检查命令 | 期望输出 | 失败时看哪里 |
| --- | --- | --- | --- |
| PATH（19 个命令） | `for c in dd md5sum od nproc jq curl bc nc hexdump diff sftp node npm tar unzip zip git ssh python3; do if command -v "$c" >/dev/null 2>&1; then echo "ok   $c"; else echo "[FAIL] $c not found"; fi; done` | 19 行 `ok   <命令>`；**没有 `[FAIL]`**。想核对绝对路径时单独跑 `command -v <命令>`，应指向 `/data/storage/el2/base/files/bin/<命令>` | hilog `IecRuntime` 的 `launchers written, failures=N`；`ls -l <sysroot>/bin`；按 2.3 查 HAP 里对应的 `.so`。缺某个 `.so` 时只有该命令不注册，属预期降级 |

> PATH 只证明 launcher 已注册，不证明命令能跑；`git`、`python3`、`node`、`npm`、`jq`、
> `curl`、`bc`、`nc`、`hexdump`、`diff`、`sftp` 由下面的实际执行项覆盖。

### 3.2 其余自检项

| 项目 | 检查命令 | 期望输出 | 失败时看哪里 |
| --- | --- | --- | --- |
| mksh 64 位算术 | `v=$((2000000000+2000000000)); echo "2000000000+2000000000=$v"` | `2000000000+2000000000=4000000000`；若为 `-294967296` 说明是 32 位算术，并追加 `[FAIL] arithmetic (expect 4000000000)` | hilog `IecRuntime`；确认 `libmksh.so` 是当前包（重编时带 64 位算术选项） |
| 工作目录 | `echo "PWD=$PWD"; pwd; /bin/pwd; ls -ld .; echo rel > _rel.txt && cat _rel.txt` | `PWD`/`pwd`/`/bin/pwd` 都是会话工作区；`rel` 打印 `rel`，`rel rc=0` | 若 `pwd` 为 `/` 或 `_rel.txt` 创建失败，检查 `IecRuntime` 的 `cwd` 守卫与 NCP cwd 路由 |
| `$TMPDIR` 可写 / `/tmp` 不存在 | `echo x > "$TMPDIR/_t" && cat "$TMPDIR/_t" && rm -f "$TMPDIR/_t" \|\| echo "[FAIL] TMPDIR write"; [ -e /tmp ] && echo "[FAIL] /tmp should be absent" \|\| echo "ok /tmp absent"` | 打印 `x`；随后 `ok /tmp absent`；`$TMPDIR` 落在 `<sysroot>/session-tmp/<会话>` | hilog `IecRuntime`；`ls -ld "$TMPDIR"`；若 `/tmp` 仍存在，看 `removed legacy /tmp mirror` 日志 |
| `id` / `whoami` / `logname` | `id; id -un; whoami; logname` | `id` 含 `uid=<应用真实 uid> gid=<gid>`，用户名 `guncat`；三条名字命令都输出 `guncat`；没有 `[FAIL] id` | `<sysroot>/etc/passwd`、`<sysroot>/etc/group`；`/bin/id` 兜底包装器；hilog `IecRuntime` 的 `cannot read uid` / `uid/gid unavailable` |
| CA bundle | `echo "GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-<empty>}"; [ -n "$GIT_SSL_CAINFO" ] && [ -f "$GIT_SSL_CAINFO" ] \|\| echo "[FAIL] CA bundle"` | `GIT_SSL_CAINFO=/data/storage/el2/base/files/etc/ssl/certs/cacert.pem`，且没有 `[FAIL] CA bundle`；`SSL_CERT_FILE`、`CURL_CA_BUNDLE` 同值（单独 `echo` 可确认）。要确认大小非 0 再加 `ls -l "$GIT_SSL_CAINFO"` | hilog `IecRuntime` 的 `ca bundle install failed`；确认 `<sysroot>/etc/ssl/certs/` 可写 |
| git 走 https | `out=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote https://github.com/git/git.git HEAD 2>&1); rc=$?; echo "$out" \| head -3; echo "git ls-remote rc=$rc (网络失败不算自检失败)"` | 前 3 行含一个 40 位 commit 加 `HEAD`，末尾 `git ls-remote rc=0 (网络失败不算自检失败)`。网络不通时 `rc=124/128` 只记录，**不判 `[FAIL]`** | 证书报错先看 CA 行；`Could not resolve host` 查设备网络；hilog `IecRuntime` |
| `timeout` 收命令树 | `st=$(date +%s); out=$(timeout 1 sh -c 'sleep 4 & wait' 2>&1); rc=$?; en=$(date +%s); echo "timeout rc=$rc elapsed=$((en-st))"` | `timeout rc=124 elapsed` ≤ 3；没有 `[FAIL] timeout`。挂住说明子 job / `OP_SIGNAL_JOB` 没生效，`$(...)` 在等孙进程握住 stdout | hilog `[exec] signal job`；确认装的是当前包（`libtoybox.so` 与 `libiec_server.so` 同批构建） |
| 嵌套 `timeout` | `out=$(timeout 1 timeout 5 sleep 4 2>&1); echo "outer rc=$?"`；`out=$(timeout 5 timeout 1 sleep 4 2>&1); echo "inner rc=$?"` | 两者 elapsed ≤ 3、rc=124；内层会换 pgrp，外层先按 ppid 级联再杀直接子进程 | hilog；确认 `libtoybox.so` 含 0002 补丁 |
| 20k~60k 输出落盘 | `seq 1 8000`（约 38KB） | 结果正文只保留前 20k 字符，末尾 `.spill/iec-…-stdout.log` 路径可 `read_file` 读回；不应出现“落盘失败” | `IecShell.spill failed`；确认 `WORK_SHELL_HEAD_CHARS` 与 `spill()` 阈值一致 |
| python3 退出码 | `timeout 10 python3 -c "import sys; sys.exit(7)"; echo "rc=$? (expect 7)"; timeout 10 python3 -c "print(1+1)"` | 先 `rc=7 (expect 7)`，再输出 `2`；没有 `Fatal Python error` | `rc=127` 且 stderr 有 `cannot reach the interpreter runner` → 看 5 的 runner 行；`ModuleNotFoundError`/找不到标准库 → `PYTHONHOME`/`PYTHONPATH`（hilog `IecShell`） |
| jq | `printf '{"a":1}\n' \| jq -r .a` | `1` | hilog `IecRuntime`；按 2.3 确认 `libjqcmd.so` 在包内 |
| curl | `curl --version \| head -1` | 以 `curl 8.22.0` 开头（构建固定 8.22.0） | hilog `IecRuntime`；`libcurlcmd.so` |
| bc | `echo '1+1' \| bc` | `2` | hilog `IecRuntime`；`libbccmd.so` |
| nc | `{ nc -h 2>&1; nc 2>&1; } \| head -1` | 含 `usage: nc` 的一行（自编 nc 没有 `-h` 也走 usage） | hilog `IecRuntime`；`libnc.so` |
| hexdump | `printf AB \| hexdump -C` | 两行：首行 `00000000  41 42` + 按 16 字节补空格 + `\|AB\|`（`\|` 在第 60 列），第二行 `00000002`（最终偏移）。**不是**旧的 `00000000  41 42 \|AB\|` 单空格/无末行格式 | hilog `IecRuntime`；`libhexdump.so` |
| base64 | `printf AB \| base64` | `QUI=`；二进制结果提示让模型用 `base64`，这个命令必须在 PATH 里 | `libtoybox.so`；`<sysroot>/bin/base64` launcher |
| xargs | `printf 'a b\nc\n' \| xargs -I{} echo '[{}]'`（`-I {}` 同）；`xargs -P3 -I{} ...`；`printf 'a b\0c\0' \| xargs -0 -n1 echo base`；`xargs -a FILE -n1 ...`；`xargs -n1 sh -c 'echo A'` | `-I` 两行 `[a b]`、`[c]`；无占位符时追加输入行；`-0` 输出 `base a b`、`base c` 两组；`-a` 读完全部行；`sh -c` 正常输出 `A`（没有 `Unknown option 'c'`） | `libtoybox.so` 的 `0003-xargs-insert.patch`；NEWTOY 选项串必须以 `^` 开头（`"^I:…"`），否则命令自身的 `-c`/`-n` 会被 xargs 当成自己的选项 |
| tar bz2/xz | `tar xjf a.tar.bz2`；`tar xJf a.tar.xz`；`tar xf a.tar.xz`（自动识别）；`tar cjf b.tar.bz2 dir` | 解包出原文件；`tar cjf` 可创建；`tar cJf` 仍报不支持，用 `tar cf - dir \| xz > b.tar.xz` | `libbsdtar.so`/`libarchive.a` 需在禁用 `posix_spawnp`/`vfork` 后重建；`<sysroot>/bin/xz`、`bzip2` 是 Python 过滤器 |
| rename 覆盖软链 | `echo target > t; ln -s t l; sed -i 's/target/changed/' l; cat t; cat l` | `cat t` 仍为 `target`；`cat l` 为 `changed`，且 `l` 已变成普通文件（`ls -l l` 无 `->`）；`mv file link` 同理。目标文件不变、软链被替换 | `libtoybox.so`/`libbsdtar.so` 的 fs shim `rename`；确认“普通文件→软链名”先删 marker 再 rename 到可见名 |
| git 路径与模板 | `git init r; cd r; git config user.email a@b; git config user.name a; echo u > '中.txt'; git add .; git commit -qm u` | 没有 `templates not found` 警告；`git status`/`log --name-only` 原样显示 `中.txt`（不是 `\344\270\255.txt`） | 会话 `~/.gitconfig` 的 `core.quotepath=false`；`GIT_TEMPLATE_DIR=<sysroot>/etc/git-templates`；`IecShellService.seedGitConfig` |
| head 负行数 | `printf 'a\nb\nc\n' \| head -n -1`；`head -n -2`；无尾换行 | `a`、`b`；`a`；`printf 'a\nb' \| head -n -1` → `a` | `libtoybox.so`；`head.c` 的负行数分支 |
| awk 内部执行 | `awk 'BEGIN{print system("echo hi")}'`；`awk 'BEGIN{"echo hi" \| getline l; print l}'`；`awk 'BEGIN{print "x" \| "cat"}'` | `hi` + `0`；`hi`；`x`。shim 的 `system/popen/pclose` 包装经 exec 服务执行，退出码透传 | `libtoybox.so`；确认链接里有 `--wrap=system/popen/pclose`。`python3` 的 `os.system` 仍不可用（libpython 内部 exec），用 `subprocess` |
| zip | `zip -qr out.zip dir`；`zip -qr out.zip dir -x 'dir/skip/*'`；`-x '*.log'` | 可创建/列出；`-x` 命中的目录整棵跳过、文件不重复入包；没有 `[FAIL] zip -x` | `libzipcmd.so`（`zip_entry.c`）；`-x` 后的参数全部是排除模式，必须先生成模式再遍历路径 |
| diff 退出码 | `printf 'a\n' > "$TMPDIR/_d1"; printf 'b\n' > "$TMPDIR/_d2"; timeout 10 diff -u "$TMPDIR/_d1" "$TMPDIR/_d2"; echo "diff rc=$? (expect 1)"` | 依次为 `diff --git a/.../_d1 b/.../_d2`、`index …`、`--- a/.../_d1`、`+++ b/.../_d2`、`@@ -1 +1 @@`、`-a`、`+b`，末行 `diff rc=1 (expect 1)`（有差异是正确结果）；同文件 `rc=0`；操作数不存在 `rc=2`；`diff -r dir1 dir2` 也递归比较并返回 1 | hilog `IecRuntime`；`libdiff.so`；后端是随包 git，不是 GNU diffutils |
| 长参数 | `s=$(python3 -c "print('x'*40000)"); /bin/echo "$s" \| wc -c` | `40001`；执行核的 exec 请求不再被 32KiB 栈缓冲截断（放不下时按需分配） | `[shim] exec: request is too long`；确认 `libtoybox.so`/`libmksh.so` 与当前 `exec/shim.c` 同批构建 |
| sftp | `{ sftp -V 2>&1; sftp -h 2>&1; sftp 2>&1; } \| head -1` | OpenSSH 9.9p2 的第一行是 `unknown option -- V`；单独跑 `sftp -h`/无参时以 `usage: sftp ...` 开头。关键是没有 `command not found` | hilog `IecRuntime`；`libsftpcmd.so`。这里只有**客户端**，没有 sftp-server |
| scp | `command -v scp` | `/data/storage/el2/base/files/bin/scp`（dropbear 的 scp 客户端） | hilog `IecRuntime`；`libdropbear.so` 的 launcher |
| node | `node -v` | `v22.19.0` | hilog `IecRuntime`；`libnode.so`。可加 `node -p "process.execArgv"` 看是否自动 `--jitless`（见 6） |
| npm | `npm -v` | `10.9.3`（Node 22.19.0 自带版本） | 版本能打出来说明 `npm-cli.js` 路径与 launcher 都对；`MODULE_NOT_FOUND` 见 5 的 npm 行；标记文件 `<sysroot>/npm/.unpack-complete` |

## 4. 自检未覆盖项（必须补）

自检不跑 SIGKILL、git clone、npm install 和 `run_python` 隔离，这四项单独验。

| 项目 | 检查命令 | 期望输出 | 失败时看哪里 |
| --- | --- | --- | --- |
| SIGKILL 后恢复 | `python3 -c "import os, signal; os.kill(os.getpid(), signal.SIGKILL)"; echo "rc=$?"; python3 -c "print('alive')"` | 第一次可能显示 `Killed`，随后 `rc=137`（128+9）；第二次输出 `alive`。被杀的是当次孙进程，runner 不受影响 | 若第二次 127/超时：`<sysroot>/py-runner.sock`、hilog `IecShell`/`IecRuntime`；若整个 shell 会话消失，说明 runner 被连带杀掉，重装当前包 |
| git clone（默认，不加 `--no-hardlinks`） | `echo "strict=$IEC_SHIM_LINK_STRICT"; rm -rf "$TMPDIR/_src" "$TMPDIR/_dst" && mkdir "$TMPDIR/_src" && cd "$TMPDIR/_src" && git init -q && echo x > a.txt && git -c user.name=t -c user.email=t@e add a.txt && git -c user.name=t -c user.email=t@e commit -qm i && cd "$TMPDIR" && git clone _src _dst && cat _dst/a.txt` | 先 `strict=1`，再 `Cloning into '_dst'...`，最后 `x`，退出码 0；**不能出现 `fatal: hardlink different from source...`** | 出现该 fatal → `IEC_SHIM_LINK_STRICT` 未生效（空/0），多半装的是旧包；`strict=1` 仍失败再看 hilog `IecRuntime` 与 git 版本 |
| npm install（可选，需网络） | `mkdir -p "$TMPDIR/_npm" && cd "$TMPDIR/_npm" && npm init -y >/dev/null && npm install --no-audit --no-fund left-pad && rm -rf "$TMPDIR/_npm"` | `added 1 package`，退出码 0 | `MODULE_NOT_FOUND`/`Cannot find module .../npm-cli.js` → npm 树是半解包，见 5；网络/registry 错误不算失败，可跳过此项 |
| `run_python` 与 `python3` 互不干扰 | ① `run_python`：`import sys; sys.path.insert(0, '/tmp/_rp_only'); print('run_python ok')`；② `python3 -c "import sys; print('/tmp/_rp_only' in sys.path)"`；③ `python3 -c "print('python3 ok')"` | ① `run_python ok`；② `False`；③ `python3 ok`。两者各在自己的进程里，模块搜索路径/解释器状态不互相泄漏 | ② 为 `True` 说明状态被串了；③ 失败或挂起 → runner 被 `run_python` 影响，看 `<sysroot>/py-runner.sock` 与 hilog `IecShell` |

> SIGKILL 项的第一条命令**本来就该被杀**，看到 `Killed`/`rc=137` 是成功标志；整条命令的
> 最终退出码由末尾的 `echo` 决定，不能只看工具头的 `[exit 0]`。

## 5. 故障对照表

| 症状 | 最可能原因 | 下一步 |
| --- | --- | --- |
| 任意命令 `command not found`；或 `cannot start .../bin/sh` | 对应 `.so` 没打进 HAP / launcher 没注册；`<sysroot>/bin` 不可写；装的是旧包 | 看 hilog `IecRuntime` 的 `launchers written, failures=N`；`ls -l <sysroot>/bin`；按 2.3 解包 HAP 确认 `.so`；重装当前 signed 包 |
| `shell` 工具直接报“shell 后端未初始化” | `EntryAbility` 没有把 `IecShellService.run` 注入 `HarnessTools.shellBackendHook`（不是当前构建，或启动早期异常） | 确认装的是本仓库当前 HAP；冷启动；hilog 搜 `shellBackendHook` 相关错误 |
| `IEC 运行核加载失败` / `运行核无法启动命令` | 非 arm64 设备（x86_64 模拟器）；`libiec_server.so`/NAPI 没加载；命令 so 缺失 | 换 arm64 真机/2in1；hilog `IecRuntime` 看原始异常；按 2.3 查包 |
| `python3` 返回非 0，stderr 为 `python3: cannot reach the interpreter runner (...): ...` | `startPyRunner()` 没起来，或 `<sysroot>/py-runner.sock` 不存在/不可连。当前客户端固定返回 **127**；旧构建或外层包装可能显示 2，按同一原因查 | 冷启动应用；hilog 搜 `python runner: failed`；用 shell `ls -l /data/storage/el2/base/files/py-runner.sock`；仍失败重装 |
| `python3` 报 `Fatal Python error`、`ModuleNotFoundError`（标准库） | `PythonService.ensureRuntime()` 失败，`PYTHONHOME`/`PYTHONPATH` 没传进 runner；`<sysroot>/python` 未解出 | hilog `IecShell` 的 `python runtime unavailable`；检查 `<sysroot>/python`；冷启动让 ensureRuntime 重跑 |
| `npm` 报 `MODULE_NOT_FOUND` / `Cannot find module '.../npm/bin/npm-cli.js'` | npm 树是半解包：入口文件在、其余文件缺失；旧逻辑只看入口，当前按 `.unpack-complete` 判断 | 在 shell 里 `rm -rf /data/storage/el2/base/files/npm`，然后**冷启动**应用（解包只在启动时做）；重启后确认 `.unpack-complete` 与 `npm/bin/npm-cli.js` 都在 |
| `git clone` 报 `fatal: hardlink different from source at '.../objects/...'` | `IEC_SHIM_LINK_STRICT` 没生效（为空/0），fs shim 仍用“复制”冒充硬链接，git 校验 inode 失败 | `echo $IEC_SHIM_LINK_STRICT` 应为 `1`；为空说明装的是旧包或环境被绕过；重装当前包 |
| `git`/`curl` https 报证书错误（`SSL certificate problem`、`server certificate verification failed`） | CA 没铺到 `<sysroot>/etc/ssl/certs/cacert.pem`，或 `GIT_SSL_CAINFO`/`SSL_CERT_FILE`/`CURL_CA_BUNDLE` 未注入 | `echo "$GIT_SSL_CAINFO"; ls -l "$GIT_SSL_CAINFO"`；hilog `IecRuntime` 的 `ca bundle install failed`；重装/冷启动；确认设备时间正确 |
| `git ls-remote` 超时或 `Could not resolve host` | 设备网络/DNS/代理问题，不是 shell 缺陷 | 先用 `curl -I https://github.com` 或浏览器确认网络；自检本身也把网络失败排除在 `[FAIL]` 之外 |
| `diff` 输出不是传统 normal diff，或某些选项不认 | `diff` 后端是随包 git（`git diff --no-index`），只做 `-u`/`-U n`/`-q`/`-s` 的转发 | 这是已知实现；需要 normal diff 用 `git diff --no-index`；缺文件返回 2 是对齐 GNU 的行为 |
| `sftp` 连不上/`subsystem request failed` | 包里只有 sftp **客户端**，没有 sftp-server；目标主机也没开 sftp 子系统 | 换一个有 sftp-server 的远端；本机不提供 sftp 服务，这不是安装失败 |
| `node` 很慢，或 `process.execArgv` 里有 `--jitless` | 设备拿不到可写可执行内存，`iec_node_entry` 自动降级到 V8 纯解释器 | 预期行为，见 6；功能不受影响，只是慢；确认不是偶发 OOM |
| 命令输出里有 `�`，但内容其实是二进制 | 二进制检测看“非法 UTF-8”与 NUL 字节；既不含 NUL、又是纯 ASCII 的字节序列仍会被当作文本 | 预期限制；把输出重定向到文件再 `download_file`/`base64`，不要直接读 |
| 自检没有 `SELFTEST DONE` | 60 秒超时、应用被杀，或启动走了 `onNewWant`（自检没执行） | 先 `aa force-stop` 再 `aa start ... --ps iecSelfTest 1`；看 hilog `IecSelfTest` 是否有 `starting`；必要时重试一次 |

## 6. 已知限制

- **node 无 JIT 时自动 `--jitless`**：`iec_node_entry` 会探测可写可执行内存，拿不到就加
  `--jitless --no-expose-wasm`，走 V8 纯解释器。功能完整但明显更慢；用
  `node -p "process.execArgv"` 可确认。这是预期降级，不是安装问题。
- **不含 NUL 的纯 ASCII 二进制输出可能不被识别为 binary**：`IecRuntime` 在解码出现非法
  UTF-8（`U+FFFD`）或原始字节含 NUL 时置 `binary=true`；既无 NUL 又是纯 ASCII 的字节会被
  当文本。二进制请重定向到文件或 `base64`。
- **`diff` 是 git 后端**：输出是 unified 格式，只支持 `-u` / `-U n` / `-q` / `-s` 的转发；
  不是 GNU diffutils 的完整选项集。
- **`sftp` 只含客户端**：没有 sftp-server，不能拿手机当 sftp 服务端。
- **没有真 pty / job control**：依赖终端的交互式 TUI 不适用；`&` 可以起后台进程，但不能
  `Ctrl+Z`/`fg`/`bg`。这是 `shell` 工具本来的非交互定位。
- **命令 so 只有 arm64-v8a**：x86_64 模拟器上 IEC 的 NAPI 会加载失败，表现为
  “运行核加载失败”，没有 QEMU 回退。
- **`/etc` 是 shim 映射**：落到 `<sysroot>/etc`，不是系统根目录；`/tmp` 刻意不提供
  （映射只覆盖 `open`/`opendir`），临时文件用 `$TMPDIR`（`<sysroot>/session-tmp/<会话>`）
  或 `mktemp ./x.XXXXXX`；其它绝对路径不保证存在。
- **真机无法自动化**：本仓库 CI 不跑设备，`scripts/check-all.sh` 也不覆盖真机；自检只在
  冷启动时执行一次，且不覆盖 SIGKILL、git clone、npm install、`run_python` 隔离，所以第 4 节
  必须手工补。

## 7. 相关文档

- [IEC 执行核：结构、随包命令 so、语义与构建](../architecture/iec-runtime.md)
- [常见问题与排障](faq.md)
- [贡献指南：三层验证怎么跑](../../CONTRIBUTING.md)
- 宿主侧一键检查：`bash scripts/check-all.sh`（不接触设备）
