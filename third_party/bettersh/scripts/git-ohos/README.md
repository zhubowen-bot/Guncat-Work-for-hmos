# git-ohos — 让 git 在 BetterSH 里跑起来的补丁层

这个目录只放**上游补不了、必须我们兜底**的东西。git 是标准 Linux 程序，绝大多数
交叉编译问题靠 `build_git.sh` 里的 make 变量就解决了；这里只留一处 libc 差异。

## `pthread_cancel_stub.c` — musl 只声明、不实现的 pthread 取消 API

**症状**：编译全过，链接期炸：

```
ld.lld: error: undefined symbol: pthread_setcancelstate
>>> referenced by run-command.o:(start_command) in archive libgit.a
```

**原因**：`run-command.c` 在 fork 前后把当前线程的取消状态关掉再恢复
（`atfork_prepare` / `atfork_parent`，`#ifndef NO_PTHREADS` 那一支）。而 **musl 根本
不实现线程取消** —— OHOS 的 `pthread.h` 里那几行 `extern` 声明是从 glibc 抄过来的
门面，`libc.so` 里对应的符号一个都没有：

```
$ llvm-nm -D --defined-only <sysroot>/usr/lib/aarch64-linux-ohos/libc.so \
    | grep pthread_setcancelstate
（空）
```

`NO_PTHREADS=YesPlease` 能绕开（那支改成 `sigprocmask`），但会把 git 的多线程索引、
`git grep -j`、`index-pack --threads` 一起关掉 —— 为了两个 no-op 函数放弃线程不值当。

**做法**：另编一个 `.o` 定义这两个函数，经 git 的 `LDFLAGS_APPEND` 钩子参与链接。
返回 0 不是"权宜的假实现"：这两个函数的作用是改变**本线程的取消状态**，而 musl 里
压根不存在"取消"（`pthread_cancel` 也是 no-op），所以"禁止取消"与"恢复取消"都是无事
发生，成功返回就是这个 libc 下唯一说得通的答案。

**为什么不做成头文件里的 `static inline` + `-include`**：OHOS 的 `pthread.h` 已经把这
几个名字 `extern` 声明过了，同签名再写 `static inline` 会撞 `static declaration follows
non-static declaration`。

**加新符号的原则**：只定义链接期真正缺的。多定义的会**遮蔽 libc**（对象文件优先于库），
少定义则链接报错；每加一个都要在设备上把 git 的基本命令重跑一遍。

## 构建（`scripts/build_git.sh`）

一次 `scripts/build_git.sh all` 走三段：`deps`（静态 libcurl）→ `build`（git）→
`pack`（`dist/pkgs/git.tar.zst`）。几个非默认的 make 变量与它们的理由：

| 变量 | 为什么 |
| --- | --- |
| `NO_REGEX=NeedsStartEnd` | musl 的 `regex.h` 没有 `REG_STARTEND`，git 会 `#error` 让你显式选：走它自带的 `compat/regex` |
| `NO_RUST=YesPlease` | 2.54 起 git 有一部分 Rust 重写（`cargo build libgitcore.a`）。我们不需要，也不该为它引入 rust 工具链 |
| `SKIP_DASHED_BUILT_INS=YesPlease` | 内建命令在**同一个进程里**派发，根本不会 exec `git-<cmd>`。不装那 100 多个副本，包小一大截 |
| `NO_INSTALL_HARDLINKS=YesPlease` | 上游默认硬链/软链。pkg 的 `bsh_tar.c` 只认普通文件与目录，链接一律要展成真文件 |
| `NO_GETTEXT` / `NO_ICONV` / `NO_PERL` / `NO_PYTHON` / `NO_TCLTK` / `NO_EXPAT` | 省体积，也免掉设备上根本不存在的依赖（iconv/perl/python/GUI）。`NO_EXPAT` 只影响 `git http-push` 与 dummy HTTP |
| `CFLAGS` 里的 `-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0` | OHOS 的 `sys/select.h` 把 `FD_SET` 展开成 `__fd_chk`（OHOS musl 私有），bundle 里那份 **vanilla musl 1.2.2** 没这个符号 → 运行期 `Error relocating`。与 `build_devtools.sh` 同源 |
| `LDFLAGS` 里的 `-Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1` | procmgr 按 `PT_INTERP` 的 basename 去 bundle libs 找 loader |
| `CURL_CONFIG=<build/curl/bin/curl-config>`（桩） | git 只用它问 `--vernum`，问到一个 ≥ 072200 的值才会把 `imap-send` 接到 curl 上；真实的 `--cflags/--libs` 由命令行显式给，不依赖这个桩 |

**为什么必须是动态链接的 musl 可执行**（不能 `-static`）：静态 guest 吃不到
`LD_PRELOAD` 的那套 shim（`[elf] loaded ET_EXEC`），git 内部所有 `exec`（`git-remote-https`
助手、hook、pager、`ssh`）会**直接打到内核** → 资源根是 noexec → `EACCES`。动态之后
exec 委托生效，顺带白拿 fs_shim 的 `BSH_SYMLINK` 用户态软链（sandbox 建不出真 symlink）。
第三方库反过来**必须静态**：多一个 guest `.so` 就多一处"装到设备上才发现加载不了"的风险。

## 装出来的布局

```
usr/bin/git                            启动器脚本（见下）
usr/bin/git-upload-pack                ┐ 同上的启动器，只是转发不同的子命令
usr/bin/git-receive-pack               ├ 见「缺口 1」
usr/bin/git-upload-archive             ┘
usr/libexec/git-core/git               真二进制
usr/libexec/git-core/git-remote-http   curl 传输助手（git 会 exec 它）
usr/libexec/git-core/git-remote-https  同一份二进制的副本
usr/libexec/git-core/git-{mergetool,submodule,request-pull,filter-branch,…}
                                       上游用 shell 写的子命令与被 source 的 shell 库
usr/libexec/git-core/mergetools/       `git mergetool` 的工具定义
usr/share/git-core/templates           `git init` 的模板
usr/share/git-core/cacert.pem          HTTPS 的 CA bundle（curl.se 的 Mozilla 根证书）
```

`usr/bin/git` 是**启动器脚本**而不是二进制，因为几件事只有运行期才知道路径：
`GIT_EXEC_PATH`（找 `git-remote-http`）、`GIT_TEMPLATE_DIR`、`GIT_SSL_CAINFO`
（设备上没有 `/etc/ssl/certs`）。编进二进制里的默认值是构建时的绝对前缀
`/usr/libexec/git-core`，与装到资源根下的实际位置对不上 —— 不设 `GIT_EXEC_PATH`，
`git clone https://…` 直接报 `unable to find remote helper for 'https'`。
启动器按 `$BSH_SYSROOT`（拿不到就按 `$0` 的上级目录推）算这几个值，与 code-server 的
启动器同一个套路。

## 两个只有回到真设备上才暴露的缺口

都是"本地 clone"这一条路上的，而且**是依次暴露的** —— 修掉第一个才走到第二个，
别把先出现的那个当成全部。

### 缺口 1：`git-upload-pack` 得在 `PATH` 上（不是 `GIT_EXEC_PATH`）

**症状**：`git clone <本地目录>`（不带 `--no-local`）报

```
git-upload-pack '/…/a/.git': git-upload-pack: inaccessible or not found
fatal: Could not read from remote repository.
```

（`inaccessible or not found` 是 **mksh** 的话，说明失败发生在 shell 的 exec 上。）

**原因**：本地传输是通过 shell 起的 —— `run_command` 里那一行长这样

```
/bin/sh -c 'git-upload-pack '\''/…/a/.git'\'''
```

所以这次 exec **由 shell 按 `PATH` 找名字**，跟 `GIT_EXEC_PATH` 一点关系没有。
上游正是为此把 `git-upload-pack` / `git-receive-pack` / `git-upload-archive` 装进
**bindir**（Makefile 的 `BINDIR_PROGRAMS_NO_X`），而我们又不带 exec-path 里那堆
`git-<cmd>` 副本（`SKIP_DASHED_BUILT_INS`），于是这里就空了。这三个都是内建命令
（`git upload-pack` 在同一进程里就能跑），所以启动器只转发。

**为什么 `git 2.56` 连本地 clone 也要起这个进程**：`builtin/clone.c` 里
`transport_get_remote_bundle_uri(transport)` 是**无条件**调的（bundle-URI 特性），
本地克隆也不例外。所以哪怕走的还是 `clone_local()` 那条复制路径，传输进程照样会起。

### 缺口 2：`link(2)` 被 shim 用"复制"兜底，而 git 会核对 inode

**症状**（补上缺口 1 之后才出现）：

```
fatal: hardlink different from source at 'a2/.git/objects/ce/013625030ba8dba906f756967f9e9ca394464a'
```

**原因**：release 构建下沙箱拒掉 `link(2)`（EACCES），fs_shim 于是退化成复制并返回 0；
而 git 的 `copy_or_link_directory()` 在 `link()` **成功返回**之后还要 `lstat` 比
`st_ino`/`st_dev`，一对不上就 die —— 它预期的是"link 失败，我自己退化成复制"。

**修法**：给 shim 加 `BSH_SHIM_LINK_STRICT=1`（不做兜底、把内核的 errno 原样返回），
四个启动器都设上。详见 `feature/bsh_main/src/main/cpp/shim/README.md` §5.7。

## 设备实测（`tablet` 变体，USB 连接）

```
$ git --version                     git version 2.56.0
$ git --exec-path                   <资源根>/usr/libexec/git-core
$ git init / add / commit / log / status / diff / branch / checkout / gc / config --global
                                    全部正常（含 alias、全局 user.name 写 ~/.gitconfig）
$ git ls-files -s                   100644 … f.txt / 120000 … lnk   ← 软链按符号链接入档
$ git clone a a2（默认 --local）    lnk 在副本里仍是 -> f.txt，cat 得到 hello
$ git clone --no-local a a3         同样正常（这条明确走 git-upload-pack）
$ git ls-remote https://github.com/…  正常拿到 refs
$ git clone --depth 1 https://github.com/octocat/Hello-World.git   约 2 秒
$ git fetch --unshallow             提交数 3，正常
```

补充两条环境事实（都不是 git 的问题，但排查时容易误判）：

- 设备上的 `python3` **没有 CA 存储**，`urllib` 直接访问 https 会
  `CERTIFICATE_VERIFY_FAILED`（pip 自带 certifi 所以没事）。看到这个**不代表设备没网** ——
  同一时刻 git 用它自带的 `cacert.pem` 是能通的。想单独探网络连通性别用它当探针。
- guest 里的 `access()` 行为**是对的**（不存在的路径返回假）。一度怀疑本地 clone 判错
  是它的问题，实测排除 —— 真正的原因是缺口 1。

## 重出版本

```sh
# 1) 改 GIT_VER / CURL_VER（build_git.sh 顶部）后：
GIT_REBUILD=1 scripts/build_git.sh all      # 产物 dist/pkgs/git.tar.zst
# 2) 传服务器 → 改两处 index.json（远端 + build/pkgserver/index.json 镜像）
scp dist/pkgs/git.tar.zst y1yan-server:data/docker_data/typecho/typecho/bsh-packages/
#    version / file / size / sha256（脚本末尾会把这四项打出来）
```

## 已知不做 / 没走过

- **不含** perl/python 写的子命令：`git-svn` / `git-p4` / `git-instaweb` /
  `git-send-email` / `git-cvsserver` / `git-archimport` / `git-cvsimport` /
  `git-cvsexportcommit`。上游 install 出来的是 `#!/bin/sh` 的壳（内容是 exec
  perl/python），设备上的 python 是命令 so、perl 根本没有 —— 按名字排除。注意
  **按 shebang 排不掉**，那些壳自己就是 `sh`。
- 不含服务端与其它独立程序：`git-http-backend`、`git-daemon`、`git-shell`、`scalar`、
  `git-remote-ftp(s)`、`git-http-fetch`、`git-imap-send`。
- 不含 man / html 文档（`git help <cmd>` 只能列命令，翻不了手册）。
- **作业控制与真软链**：`git clone` 一个含软链的仓库时，sandbox 建不出真 symlink，
  走的是 fs_shim 的 `BSH_SYMLINK` 用户态模拟；`core.symlinks` 相关的边角行为没有逐一验过。
- 版本跟着上游走（当前 2.56.0）；升级时重点复验 `NO_REGEX` / `NO_RUST` /
  `SKIP_DASHED_BUILT_INS` 这几个开关是否还在，以及 `LDFLAGS_APPEND` 钩子有没有改名。
