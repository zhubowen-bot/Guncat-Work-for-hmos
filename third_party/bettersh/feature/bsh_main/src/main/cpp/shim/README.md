# shim/ — shim 家族（guest 侧 preload + 命令 so 侧链接期，同一批源码）

给**沙箱里缺东西**的程序用的一层拦截。同一份源码有两种用法：

- **guest 侧**：`LD_PRELOAD`。guest 是别人的二进制，只能预载 —— procmgr 按 guest 的
  PT_INTERP 挑对应 libc 那份设进去（见 `procmgr.cpp` 的 ChildRunElf），产物
  `libbshguest-{musl,glibc}.so` 随 HAP 进 bundle libs。
- **命令 so 侧**：链接期把 `.o` 编进去 + `-Wl,-Bsymbolic-functions`（toybox/vim/mksh…
  各自 build 脚本里那几行）。**注意**：命令 so 是 dlopen 进来的、排在搜索序末尾，
  `dlsym(RTLD_NEXT)` 会拿到 NULL —— 所以 fs_shim 目前**只用于 guest 侧**（见 §0）。

四个模块：

| 模块 | 补什么 | 为什么必须有 |
| --- | --- | --- |
| `fs_shim.c` | 用户态**符号链接**模拟：`foo -> /target` 表示成普通文件 `foo.BSH_SYMLINK`（内容就是目标串），把 libc 里碰路径的入口拦下来翻译 | 沙箱拒绝 `symlink(2)`（三层、所有可写目录，errno=13），`tar` 解包含软链、`npm`/`pip`/`venv` 建软链全靠它 |
| `tty_shim.c` | 软 tty 语义（`isatty`/`tcgetattr`/`tcsetattr`/`ioctl`/`fcntl`/`open("/dev/tty")`，termios/winsize 的真相在主进程，经 control socket 读写） | 会话终端是 softpty（socketpair），直接看 fd 的话 `isatty` 恒 0 |
| `pty_shim.c` | 假 pts：`open("/dev/ptmx")` → socketpair 当 master，`ptsname` 给 `/dev/pts/N`，开 slave 拿另一端并登记成 tty；`TIOCGPTN`/`TIOCSPTLCK`/`TIOCSCTTY` 一套假实现 | 沙箱三层都拿不到真 `/dev/ptmx`（EACCES），guest 里想自己开伪终端（tmux / `script` / 自写 TUI）只能靠它 |
| `exec_shim.c` | **exec 委托**：拦 `execve`/`execv`/`execvp`/`execvpe`/`execl*`/`posix_spawn(p)`，把"起一个程序"交给 procmgr（进程只能由它创建），成功就 `_exit(子进程退出码)` | 沙箱里 guest 调 execve 一律 EACCES。**一份源码两种被调用方式**（见 `shim_wrap.h`）：guest 侧（`LD_PRELOAD`，要 `BSH_EXEC_SHIM`）与命令 so 侧（`-DBSH_SHIM_WRAP` + `-Wl,--wrap=`，链接期改名）的**失败语义已经统一**：都返回 -1 并把 errno 摆好（2026-10-03 改）。原先命令 so 侧是"失败即 `_exit(127)`"—— 那会掐死 CPython subprocess 的 PATH 搜索，`pip install` 就崩在 `uname -rs` 上，见 §9 |
| `dlopen_shim.c` | **dlopen 兜底**：`dlopen` 栽了就改用 elfloader 的进程内装载器（`elfloader/elf_dl.cpp`）把那个 .so 读进内存自己映射 | 资源根（el2）是 noexec ⇒ pip 装在那里的 C 扩展，系统加载器报 "No such file or directory"（文件明明在）。见 §9 |
| `netif_shim.c` | `getifaddrs`：返回一份"只有 lo + eth0"的假表（eth0 带真 MAC） | 沙箱不给 NETLINK raw socket ⇒ Electron 的 `os.networkInterfaces()` 抛 `EACCES`；后续 VS Code 还会用它挑"非内部、MAC 非全零"的网卡做 machineId。**已并入本家族**（原来只是独立 preload） |
| `latecrash_shim.c` | 迟到安装的致命信号处理器（constructor 起 detached 线程，每 500 ms 重装一次、连装 20 次） | Chromium 在 main 里 `sigaction` 会覆盖别人的处理器，正常写法只能拿到退出码、拿不到 pc。**要 `BSH_LATECRASH=1` 才启用**（默认不装，免得抢走别人对崩溃的处理） |
| `netif_shim.c` | `getifaddrs`：返回一份"只有 lo"的假表 | 沙箱不给 NETLINK raw socket ⇒ Electron 的 `os.networkInterfaces()` 抛 `EACCES(13)`。**它不在上面那份 shim .so 里**：入口是 libuv，而 libuv 静态链进 Electron 二进制，必须靠 `LD_PRELOAD` 才能抢到 `getifaddrs`；编法见 `scripts/pack_vscode.sh` 的 3.5c（`libnetiffix.so`），由 vscode 启动器设 `LD_PRELOAD`（见 STATUS §60） |

```
entry/src/main/cpp/shim/
├── README.md               ← 本文件:症状 → 表示法 → 拦截清单 → 已知限制
├── fs_shim.c               ← 软链模拟本体（+ fs_shim_selftest.c：真软链 vs 模拟，逐字节对拍）
├── pty_shim.c              ← 假 pts 本体（要 BSH_FAKE_PTY 才启用；+ pty_shim_selftest.c）
├── exec_shim.c             ← exec 委托（guest 侧要 BSH_EXEC_SHIM；命令 so 侧 -DBSH_SHIM_WRAP）
├── tty_shim.c              ← 软 tty 语义（命令 so 也编它）
└── open_shim.c             ← 合并 open 的唯一入口（tty 钩子 → 软链解析）
```

三个开关（都由 procmgr 在给自己起的 guest 上设，见 ChildRunElf）：
`BSH_TTY_STDIO`（ForkChild 按"stdio 是不是 socket"判定）、`BSH_FAKE_PTY`、`BSH_EXEC_SHIM`。
另有一个**数据变量** `BSH_GUEST_EXE`（同上，见 §3.1b）和三个排查开关
`BSH_SHIM_TRACE`、`BSH_SHIM_VERBOSE`（装载横幅，见 §5.0）。
另有一个**语义开关** `BSH_SHIM_LINK_STRICT`（§5.7）。
还有一个**数据变量** `BSH_SESSION`（`common/bsh_paths.h`）：本进程属于哪个终端会话
（0 = 主窗口的 bsh，>0 = `bshutil newtab` 开的 tab）。procmgr 在 fork 子进程时按
`SpawnRequest.sid` 注入，`tty_shim` 与 exec 委托从它读出会话号，塞进 `CMD TTY` /
`CMD SIGNAL` 请求 —— 每个会话的 termios/winsize/前台进程是**分开的**
（见 `tty/bsh_tty.h` 的 `BSH_SID_MAX`），不带这个号就会把 tab B 里 vim 的网格尺寸
问到 tab A 头上。缺席一律按 0 处理（宿主自己发的请求、code-server 那些 guest 都是
这种），所以这条不改变任何既有行为。

编与装：`scripts/build_shim.sh`（两份 —— musl/glibc，各自 libc 的 .so 不能互换），
产物进 `entry/libs/arm64-v8a/libbshguest-{musl,glibc}.so` 随 HAP 走。

---

## 0. 命令 so 侧：用 `-Wl,--wrap=`（已接上）

`libtoybox.so` / `libmksh.so` / `libvim.so` / `libpython.so` / `libnode.so` / `libzipcmd.so` /
`libsshcore.so` / `libwestterm.so` / `libclangbsh.so` / `liblld.so` 现在都带上了这套 shim，
设备实测（自检里的"命令 so 侧"两条）：

```
$ toybox ln -s .q-t .q-s && toybox ls -l .q-s && toybox readlink .q-s && toybox cat .q-s
lrwxrwxrwx 1 20020252 20020252 4 2026-09-30 14:50 .q-s -> .q-t
.q-t
y
```

**与 guest 侧的区别只在"怎么被调用"**（这正是 `shim_wrap.h` 讲的那两种模式）：

| | guest 侧 | 命令 so 侧 |
|---|---|---|
| 装配 | `LD_PRELOAD`（procmgr 按 PT_INTERP 挑 libc 那份） | 链接期把 `.o` 编进去 + `-DBSH_SHIM_WRAP` |
| 拦截 | 符号插入（导出 `open`/`stat`/…） | `-Wl,--wrap=<名>`（导出 `__wrap_*`） |
| 真实现 | `dlsym(RTLD_NEXT, …)` | 链接器生成的 `__real_*`（对 libc 直接引用） |

为什么命令 so 侧**不能**用符号插入 + RTLD_NEXT：命令 so 是主进程 `dlopen` 进来的、
排在全局搜索序**末尾**，"下一个"之后什么都没有 → `dlsym` 返回 NULL → 每个入口都退化成
`ENOSYS`（实测症状：编进 libtoybox 后每个文件操作都报 `Function not implemented`）。
`--wrap` 是链接期替换，跟搜索序无关 —— 与 `shim/exec_shim.c`（带 `-DBSH_SHIM_WRAP`）
处理 exec 家族是同一招。

规矩：**命令 so 都链同一套 shim（fs + tty + open_shim），清单也只有一份**
（`scripts/shim-wrap-flags.sh` 的 `$SHIM_WRAP_FLAGS`）。清单与 `.o` 永远一起出现，
"清单与实现不匹配"这类错误就不可能发生。

三个实测踩到的坑（都写进清单文件的注释）：

1. **wrap 一个没人定义的名字 → dlopen 直接失败**（`Error relocating libtoybox.so:
   __wrap_isatty: symbol not found`）。这正是"必须都链同一套"的由来：早先 toybox 只链
   fs_shim，却 wrap 了 tty 的 `isatty`。
2. **glibc 专属的名字不能 wrap**（`open64`/`readdir64`/`__*_chk`/`__xstat`…）：`fs_shim.c`
   的 musl 分支根本没定义它们（`#ifdef __GLIBC__` 挡着）→ 同样症状（libvim.so 上 11 个
   未定义）。要加 glibc 链的命令 so 时，把那批名字补进清单即可。
3. **清单没传进链接行**（最隐蔽）：定义都在、也没有未定义 `__wrap_*`，但我们的兜底
   引用 `__real_*` 没人改回真名 → `__real_lstat: symbol not found`。**zip / unzip /
   sshcore / python 四个就这样漏过去过**（改脚本时缩进没对上，flag 没插进去）。
   判据要看两条：`nm -D -u <so> | grep -E '__wrap_|__real_'` **都必须为空**。
   `scripts/build_hap.sh` 打包前会统一查这一条，不通过就不让打包。

唯一的例外是 **westerm**：它自己那份 `tty/bsh_pty.c` 已经定义了 `__wrap_ioctl`
（weston-terminal 的 pty 用），与 tty_shim 的 ioctl 入口**重复定义**。所以它编
`tty_shim.c` 时带 `-DBSH_SHIM_NO_IOCTL` 关掉那一个入口（代价：westerm 里用 ioctl
查**会话**窗口大小不再被接管），其余照用，清单不变。

---


## 1. 症状:这台设备上建不了符号链接

**症状**
- `symlink()` / `symlinkat()` 一律失败:宿主进程、命令 so、guest 三层,所有可写目录
  都一样,`errno = 13 (EACCES)`,偶尔 `ENOENT`;失败后 `lstat` 复核确认链接**确实
  没建出来**(返回 ENOENT)。
- 硬链接是**允许**的:`link()` 成功,两个名字指向同一个 inode。
- 于是解包/安装类操作必挂:`tar` 还原软链、`npm` 建 `node_modules/.bin`、
  `python -m venv` 建 `bin/python3`、`pip` 的 wheel 布局,全都失败。

**根因**:不是权限配错 —— 沙箱在系统调用这一层就没给"创建符号链接"这个能力。
`fs_shim` 不去跟它较劲(也绕不过去),而是**换一种表示法**把它模拟出来。

## 2. 表示法(本项目定的规格,不是 Linux 的语义)

| 想要的 | 真实文件系统上是什么 |
| --- | --- |
| 软链接 `foo -> /target/path` | 普通文件 **`foo.BSH_SYMLINK`**,内容 = `/target/path`(不含结尾 NUL,长度 1..4095) |
| `foo` | **不存在** |

也就是说:链接本身的名字是去掉后缀的那个,标记文件就是链接本体的"盘上表示"。

**这条表示法最重要的推论**:一个链接只对应**一个**真实目录项,而且它的名字**一定
不与任何真实文件重名**(真重名的话 `symlink()` 会先给 `EEXIST`)。所以列目录时只要
"把 `X.BSH_SYMLINK` 改名成 `X` 并标成 `DT_LNK`",**不需要隐藏任何东西** —— 这一点
直接决定了 `readdir` 能做到几乎零成本(见 §3.2)。

4096 那一串数字不是拍脑袋的:Linux 上 `symlink()` 的目标串 > `PATH_MAX-1` 同样是
`ENAMETOOLONG`(实测 4095 能建、5999 给 `ENAMETOOLONG`),目标为空则是 `ENOENT`。
这里照抄同一个界。

## 3. 拦截清单

原则:**不关我们事的路径一律原样透传**给真实现(`dlsym(RTLD_NEXT, ...)` 取一次、
缓存在静态里)。所以对没碰过模拟链接的程序,预载与否完全无差别。

### 3.1 路径型入口

| 入口 | 做了什么 | 状态 |
| --- | --- | --- |
| `symlink` / `symlinkat` | 建 `<link>.BSH_SYMLINK`,内容 = 目标串。真实 link 名已存在 → `EEXIST`;标记已存在 → `EEXIST`(靠 `O_CREAT\|O_EXCL` 原子拿到);目标为空 → `ENOENT`;目标 >4095 → `ENAMETOOLONG` | ✅ 全做 |
| `readlink` / `readlinkat` | 命中标记 → 内容写进 buf、返回长度、**不补 NUL**、超长静默截断(全按 `readlink(2)`);中间组件会解析,最后一段不跟随 | ✅ 全做 |
| `lstat` / `__lxstat` / `__xstat` / `fstatat(AT_SYMLINK_NOFOLLOW)` | 伪造 `S_IFLNK \| 0777`、`size` = 目标串长度、`st_nlink` 沿用标记文件(硬链接后正好是 2)、`st_blocks = 0`、`st_blksize = 4096`(后两项对齐真快符号链接的实测值);`st_ino/st_dev/时间戳` 用标记文件的 | ✅ 全做 |
| `stat` / `fstatat(0)` | 整条路径递归展开后再丢给真 `stat`。上限 8 跳,超 → `ELOOP`;目标不存在 → `ENOENT` | ✅ 全做 |
| `open` / `openat` / `open64` / `openat64` | 跟随展开后再开;`O_NOFOLLOW` + 最后一段是模拟链接 → `ELOOP`;`O_PATH\|O_NOFOLLOW` 则把标记文件当"链接的 inode"交出去 | ✅ 全做 |
| `__open_2` / `__openat_2` / `__open64_2` / `__openat64_2` | fortify 包装,接回本模块(见 §5.1) | ✅ 全做(glibc) |
| `unlink` / `unlinkat` | 删 `<name>.BSH_SYMLINK`;没有标记则真 unlink | ✅ 全做 |
| `rename` / `renameat` | 四种组合分别处理(链接→链接名 / 链接→普通名 / 普通→链接名 / 普通→普通名),见 §5.4 | ✅ 全做 |
| `access` / `faccessat` | 跟随展开后判目标;`AT_SYMLINK_NOFOLLOW` 时链接自身恒 0777 且存在 → 直接放行 | ✅ 全做 |
| `realpath` / `__realpath_chk` | 展开模拟链接后交给真 `realpath`("逐段必须存在"那段权威检查不外自己实现) | ✅ 全做 |
| `link` / `linkat` | 对标记文件再建一个硬链接(两边同一 inode);带 `AT_SYMLINK_FOLLOW` 时跟随到目标本体再建 | ✅ 全做 |
| `opendir` | 展开后交给真 `opendir` | ✅ 全做 |
| `readdir` / `readdir64` | 就地改真 `readdir` 返回的那条记录,见 §3.2 | ✅ 全做 |
| `__readlink_chk` / `__readlinkat_chk` | fortify 包装,接回本模块 | ✅ 全做(glibc) |

glibc 的 `__xstat` / `__lxstat` 是 2.33 之前编译的程序才用的兼容入口;64 位 ABI 下
版本号只是个形式,直接按新结构转回 `stat` / `lstat` 即可。

### 3.1b `/proc/self/exe` 的替身（`BSH_GUEST_EXE`）

**症状**：guest 是"别人的二进制"、由 elfloader 在**宿主进程里**装载执行，所以内核看到的
`/proc/self/exe` 是宿主 `appspawn`，不是 guest 自己。程序自省（找自己的安装目录、重新
exec 自己、读自己的镜像校验和）全靠这条路径，拿到的却是宿主 —— 轻则 `$ORIGIN` 算错，
重则 exec 出 appspawn 自己。

**表示法**：真值由 procmgr 在装载前放进环境变量 `BSH_GUEST_EXE`（见 `procmgr.cpp` 的
`ChildRunElf`：`realpath(path)`，子进程视角的绝对路径）；shim 只做**符号层**的替换。
未设这个变量（命令 so 侧、宿主自己跑、box64/qemu 跑 x86 guest）时整层失效、全走原样。

| 入口 | 行为 |
| --- | --- |
| `readlink(" /proc/self/exe")` | 直接返回 `BSH_GUEST_EXE`（不补 NUL、超长截断、`bufsiz==0` → `EINVAL`，全按 `readlink(2)`） |
| `stat` / `open` / `openat` / `access` / `faccessat` / `realpath` / `fopen` / `freopen` | 在 `resolve_simlinks()` 顶部把 `/proc/self/exe`（含 `/proc/self/exe/…` 子路径）换成真值，再走原来的解析 |
| `lstat` / `fstatat(AT_SYMLINK_NOFOLLOW)` | **不替换**：真 procfs 对它给的就是"魔法链接"形状（`S_IFLNK\|0777`、`size=0`、dev/ino 属于 procfs），直通真实现才忠实 |
| `unlink` / `rename` / `link` | **不替换**：真 Linux 对 `/proc/self/exe` 的 unlink 就是 `EPERM`，替换了反而会去删 guest 自己的镜像（这也是为什么这一层挂在 `resolve_simlinks`/`do_readlink`，而不是 `norm_at`） |

**边界（照实写）**：
1. guest 的 **ld.so 内部**读 `/proc/self/exe` 去算 `$ORIGIN`，`LD_PRELOAD` 拦不到 ——
   `ChildRunElf` 里"把 guest 同目录加进 `LD_LIBRARY_PATH`"那条兜底仍然必须留着；
2. 静态链接的 guest 没有 preload，吃不到替身；
3. box64/qemu 的 x86 guest 自己模拟 syscall，也不吃。

**怎么验**：`entry/src/main/cpp/programs/selfexe/main.c`（编成
`testprogs/selfexe-aarch64-{musl,glibc}-dynamic`），8 条用例 = readlink / stat / lstat /
open / fopen / access+realpath / fork 后再读 / fork+execv 自己，末行 `selfexe: PASS=n FAIL=n`。
另有两个排查用子模式：`--open <path>`、`--dlopen <path>`（后者能拿到 `dlerror()` 文案，
在"预载静默失败"那类故障里是唯一线索）。

**调试开关**：`BSH_SHIM_TRACE=1` 让这一层把关键判定打到 stderr（默认零成本，只在
`virt_exe_*` 与 `do_readlink`/`stat` 几处各加一次 getenv 缓存判断）。第一版替身有个
**use-after-return**（把路径拷进局部数组再把指针交出去），glibc 下侥幸能用、musl 下
栈一被覆盖就变成"不匹配" —— 症状是"glibc guest 全过、musl guest 一条不生效"，就是靠
这个开关定下来的。

### 3.2 `readdir`:不改 getdents64 的记录,只改一条记录的两个字段

任务最容易做错的一条。这里的做法是**不碰 `getdents64`**:

`glibc` 与 `musl` 的 `readdir` 都是"指针指进 DIR 自己的 getdents 缓冲 →
`dirp->offset += d_reclen` → 返回"。下一次调用从**新的 offset** 取记录,`d_reclen`
不被我们改动,所以**就地改当前这条记录的 `d_name`(截断掉后缀)和 `d_type`(= `DT_LNK`)**
对后续记录是零影响 —— 既不会把 dir 流搞坏,也不用自己解析变长记录、自己管缓冲、
自己存 `struct dirent`(那就得连带实现 `telldir`/`seekdir`/`rewinddir`/`dirfd`/`closedir`,
还得给每个 DIR\* 配一块返回缓冲去维持 POSIX 的生命周期语义)。

返回的指针仍指向 libc 自己的存储,生命周期语义与原来完全一致;跨目录流交替 `readdir`
也安全(每条流各改各的缓冲)。`syscall(getdents64)` 那条路我们不碰。

自测里有一条压力用例专门证明这一点:造 **2000 个普通文件 + 200 个链接**(2200 个目录项,
≈53KB,远超一次 `getdents64` 的缓冲),再全量 `readdir`,排序后算条目数、`DT_LNK` 计数
和名字的 FNV 校验和 —— 真软链与模拟两种跑法给出**同一个数**
(`entries=2208 overflow=0 links=207 checksum=f17b200b2699b05d`)。任何缓冲/记录长度
处理错了,这里立刻对不上。

## 4. 递归解析:两条刻意的设计决定

**① 不自己折叠 `.` / `..`。** 只做字符串拼接,把结果原样交给内核。理由是内核才是权威:
实测 `stat("nodir/../x")` 真实现给的是 `ENOENT`(因为 `nodir` 不存在),而自己把 `..`
弹掉会变成 `stat("x")`、可能反而成功。`resolve_simlinks()` 里一个 `..` 都没特殊处理。

**② 只处理模拟链接,真符号链接原样留给内核。** 解析出来的串仍可能含真符号链接
(比如 `/bin` → `usr/bin`),那不用管,内核会接着解析。

跳数上限 8(内核真链接是 40),超 → `ELOOP`;目标为空或 >4095 → `ENAMETOOLONG`。

## 5. 坑(都是实测踩出来的,按踩到的顺序)

### 5.0 预载压根没被载进来:libc 的 "secure" 判定(2026-10-02 定案)

**这个坑排在第一位,因为它不是"拦错了",而是"根本没上岗"** —— 前面几条都假定 shim
已经在进程里了,这条说的是它进不来的情形。

**症状**:同一个 `aarch64-musl-dynamic` guest,在设备上 **24 过 / 6 挂**,而且挂的正好是
shim 负责的每一档 —— 软链、硬链、pty、exec(依赖 .so / 自己 / 兄弟),报的全是**内核层**
的 errno(`symlink` 被拒、`open("/dev/ptmx")` EACCES、`execv` 返回 EACCES)。可是:

- `LD_PRELOAD` 明明在 guest 的环境里(测试程序自己印出来的,路径也对);
- 文件也在(`/data/storage/el1/bundle/libs/arm64/libbshguest-musl.so`,能被 stat 到);
- shim 的未定义符号全部能解析(`nm -D -u` 对着 `ld-musl-*.so.1` 一条不差);
- 同一批源码编出来的**命令 so**(把 shim 链接期编进去的那些)一切正常。

**根因**:musl 的 `__dls3` 判自己是不是以提升权限运行的:

```c
libc.secure = ((aux[0]&0x7800)!=0x7800 || aux[AT_UID]!=aux[AT_EUID]
               || aux[AT_GID]!=aux[AT_EGID] || aux[AT_SECURE]);
if (!libc.secure) {                     /* ← 只有不 secure 才读 LD_* */
    env_path    = getenv("LD_LIBRARY_PATH");
    env_preload = getenv("LD_PRELOAD");
}
```

`decode_vec()` 把 `aux[0]` 填成"**哪些 auxv 类型出现过**"的位图,而 `0x7800` 恰好就是
`AT_UID(11)/AT_EUID(12)/AT_GID(13)/AT_EGID(14)` 这四位。两条都能踩:

1. **宿主沙箱的 auxv 可能缺这四个身份项** → 位图凑不齐 → 直接判 secure(即使 uid 全是
   一样的);而 elfloader 的启动栈是**照抄宿主 auxv**再改写镜像相关的几项,缺的没补。
2. **`AT_SECURE` 本身可能是 1** —— 这台设备的 LSM 会把 appspawn 出来的进程标成
   secureexec(实测宿主 `cat /proc/self/auxv` 里 `0x17(AT_SECURE)=1`),照抄就一起抄进来了。

于是 `load_preload()` **被跳过/静默失败**:musl 对预载失败不返回值、不打印(源码注释
见 `build/musl/musl-1.2.2/ldso/dynlink.c` 里我们自己那几段),症状就是"环境对、文件在、
拦截全不生效"。glibc 不吃这套位图启发式(它只看 `AT_SECURE`,而且我们那份 glibc 的
`ld-linux` 也是自编的),所以**前一段时间 glibc guest 的 shim 是好的、musl guest 一条
不生效** —— 这个"半边好半边坏"的对比正是当初把方向带偏的原因。

**修法**(都在 `entry/src/main/cpp/elfloader/elf_loader.cpp` 的 `make_guest_stack`,
沿用原有的"缺什么补什么"套路):

- `AT_UID/AT_EUID/AT_GID/AT_EGID` 缺了就按本进程 `getuid()/geteuid()/getgid()/getegid()`
  补上(四个本来就相等,顺带满足 uid/euid 一致性检查);
- `AT_SECURE` 对 guest **强制写 0**:guest 与宿主同 uid、env 也是同一个进程里的 procmgr
  设的,不存在 `AT_SECURE` 要防的"被提升权限的进程受外部 env 影响",照抄只是把 shim 一起
  误杀。

**结果**:同一档 24/6 → **29/1**,仅剩硬链接(沙箱真拒 `link(2)`,见 §6 已知限制)。

**怎么一眼看出是不是这个病**:给 shim 里加一行装载横幅(`open_shim.c` 的
`bsh_shim_banner`,要 `BSH_SHIM_VERBOSE=1`)。它把"没载上"和"载上了但没拦住"分开 ——
这两个病因的表现**一模一样**,而分清它们要重打一次包、装一次包。设备侧自检
(`autorun.sh`)现在每次都带这一行。

### 5.1 `realpath` 被 `_FORTIFY_SOURCE` 改写成 `__realpath_chk`

**症状**:自测里只有 `realpath(link)` 对不上 —— 真软链那遍返回目标路径,预载这遍
返回 `NULL / ENOENT`,而 `stat`/`open`/`readlink` 全都一致。

**根因**:Ubuntu 的 gcc 在 `-O2` 下由 spec **默认**注入 `-D_FORTIFY_SOURCE=3`
(和 `scripts/glibc-ohos/README.md` §5 是同一个东西),`_FORTIFY_SOURCE` 会把
`realpath(path, buf)`(buf 是已知大小的数组)改写成 `__realpath_chk(path, buf, sizeof buf)`。
`nm -D` 一看就明白:自测二进制里引的是 `__realpath_chk@GLIBC_2.4`,**压根没有 `realpath`**。
我们只导出了 `realpath`,于是那处调用绕过 shim 直进 libc —— `link1` 这个真名本来就不存在
(存在的是 `link1.BSH_SYMLINK`),当然 `ENOENT`。

**修法**:补上 `__realpath_chk`、`__readlink_chk`、`__readlinkat_chk`、
`__open_2`/`__open64_2`/`__openat_2`/`__openat64_2`,全部接回本模块自己的实现。
OHOS 的 clang 也常开 fortify,所以这不是只为了过 host 自测。

**排查方法**:碰到"某一个入口就是没被拦到"的怪事,先 `nm -D <测试二进制> | grep <名字>`,
确认引用的到底是不是你以为的那个符号。

### 5.2 绝对路径丢掉开头的 `/`

**症状**:`stat(link)` 对,`stat(linkAbs)`(目标是 `/bin/sh`)给 `ENOENT`。

**根因**:解析循环里已接受的**前缀** `acc` 从空串起步;拼接用的 `cat_sep()` 是故意
"len==0 时不补 `/`"的(否则相对路径 `foo` 会被拼成 `/foo`)。两条合起来,`/bin/sh`
的第一段 `bin` 就拼成了 `bin` —— 相对路径了。

**修法**:待解析串以 `/` 开头时,前缀直接预置成 `"/"`。

### 5.3 `lstat` 忘了解析中间组件

**症状**:`open("dirlink/inner")` 正常,`lstat("dirlink/inner")` 却 `ENOENT`
(`dirlink` 是指向 `sub` 的模拟链接)。

**根因**:`stat`/`open`/`realpath` 走的是完整解析,而 `lstat` 一开始图快、直接拿原串
去判"是不是标记文件" → 只看 `dirlink/inner.BSH_SYMLINK`,当然没有,于是回落真 `lstat`,
而真 `lstat` 不认识 `dirlink`。

**修法**:`lstat` 也走"目录部分展开 + 最后一段不跟随"那一套(真 `lstat` 也会解析中间
组件:path 里的 `link` 是被内核跟随的)。

**这个坑的指纹很好认**:**同一个路径,`open`/`stat` 对、`lstat`/`readlink` 错** ——
说明有实现只做了"最后一段"的判定,没做目录部分的解析。

### 5.4 `rename` 会留下"影子真实文件"

**症状**:把链接 rename 到**已存在的真实文件**上之后,目录里同时有真实的 `x` 和标记
`x.BSH_SYMLINK`,于是 `readdir` 吐出**两条同名项**(一条 `DT_REG`、一条 `DT_LNK`),
和真软链那遍对不上。

**根因**:真 `rename()` 是**替换**语义;我们只是把标记文件改名成 `x.BSH_SYMLINK`,
原来那个真实 `x` 没人动。

**修法**:`rename` 按四种组合分开:
- 链接 → 链接名:直接 `rename(标记, 标记)`;
- 链接 → 普通名:先删掉目标位置上已有的真实同名文件,再 `rename(标记, <新名>.BSH_SYMLINK)`;
- 普通 → 链接名:先删掉目标位置上的标记,再做真 `rename`(否则会变成"内容被当成目标串的假链接");
- 普通 → 普通名:原样透传。

顺带一个必然的残留:删除是"先删后 rename",不像内核那样原子。真链接那遍是原子的,
预载这遍有个极小的窗口 —— 只影响并发,登记在案。

### 5.5 glibc 的 `__nonnull` 让防御性 NULL 检查变成警告

`stat`/`lstat`/`opendir` 的 path 被 glibc 标了 `__nonnull`,直接写 `if (!path)` 会报
`-Wnonnull-compare`。预载层确实可能收到别处手工构造的 NULL,这层防御要留,所以改成
调用一个不内联的小函数来判断,警告消失、检查也还在。

### 5.6 `readlink("link/")` 真实现给的是 `ENOENT`,不是 `EINVAL`

尾斜杠的路径我们直接透传给真 `readlink`;实测(主机 x86_64 / glibc 2.39)真软链上
`readlink("s1/")` 也是 `ENOENT`,**恰好一致**。别自作聪明去特判成 `EINVAL`。

### 5.7 `link(2)` 的兜底是"善意的谎言",`BSH_SHIM_LINK_STRICT` 用来关掉它

release 构建下沙箱拒掉 `link(2)`(EACCES)。`link_or_copy()` 为此加了一层兜底:真
`linkat` 失败、且 errno 属于"这台机器不让做"那一类(EACCES/EPERM/EMLINK/EOPNOTSUPP/
ENOSYS)时,**退化成复制并返回 0**。这对"临时文件 → 终名"那一族用法(只要终名有内容,
原名随后自己 unlink)是够的,node 的原子写、dsh 的会话持久化都靠它。

但有一类调用方会**核对 link 的语义**,兜底对它就是谎言。最典型的是 git 的本地克隆:
`copy_or_link_directory()` 在 `link()` **成功返回**之后还会 `lstat` 比
`st_mode/st_ino/st_dev/st_size`,发现自己拿到的不是同一个 inode 就

```
fatal: hardlink different from source at '…/.git/objects/xx/yyyy'
```

直接 die —— 它预期的是"link 失败,我自己退化成复制"。所以加了
`BSH_SHIM_LINK_STRICT=1`:设了就不做兜底,把内核的原始 errno 原样返回。
pkg 的 `git` 包在四个启动器里都设了它(见 `scripts/git-ohos/README.md`)。

**排查顺序上的教训**:这个故障是在补上 `git-upload-pack` 启动器之后才露出来的 ——
在此之前 git 更早一步就死在"找不到 git-upload-pack"上了,`clone_local` 根本没走到。
两个是各自独立的缺口,别把先出现的那个当成全部。

## 6. 已知限制(照实写,不试图绕)

| 限制 | 说明 |
| --- | --- |
| **musl 静态进程完全失效** | 静态链接的 guest 没有动态符号表,`dlsym(RTLD_NEXT, ...)` 取不到真实现,本模块整只不起作用。动态 guest(musl 动态 / glibc)与宿主进程正常。**这一条不打算解决。** |
| **硬链接不是真硬链接** | 沙箱在 **release 构建**下把 `link(2)` 一并拒了(实测 `EACCES`:该 HAP 的 `app.debug=false`,非 debug 应用的文件沙箱更严;**debug 构建**同一段代码是过的,报"同一个 inode")。本模块**只做"复制"兜底,不做语义模拟** —— 硬链接是"**同一个 inode 有两个名字**",没有目标路径可存,拿标记文件顶多骗过读路径的那几个调用,`st_ino`/`st_nlink` 一致、"改一个另一个也跟着变"这些语义一个都给不了,骗出来的东西比缺着更危险。于是按调用方分两类:**只要效果**的(node 的原子写)吃兜底;**要核语义**的(git 会比 `st_ino`)用 `BSH_SHIM_LINK_STRICT=1` 关掉兜底(§5.7)。guest 自检里这一档照实报(debug 构建 PASS,release 构建 FAIL 并注明"能力缺口")。 |
| **`fopen`/`freopen` 曾绕过本模块（已修）** | musl 的 `fopen` 直接调内部 `sys_open`、glibc 走 `_IO_file_open→__open_nocancel`，都不是"调 `open` 这个符号"，拦不住 → `fopen(链接)` 读到空。现在本模块自己实现了 `fopen/fopen64/freopen/freopen64`：先把路径解析成真实路径，再交给 RTLD_NEXT 的真 fopen。**同类隐患**：任何"库内部直接走 syscall 的路径处理"都拦不到（见下一条）。 |
| **没有"前后台进程组"** | `tcgetpgrp`/`ioctl(TIOCGPGRP)` 一律回答**"问的人就是前台"**（`getpgrp()`），`tcsetpgrp` 照旧把值远写给宿主（宿主转发信号时要用）。理由：软 tty 没有内核那套按终端停/续进程组的机制，"你不是前台"这句话我们兑现不了，而 mksh 的 `j_change()` 恰恰会拿它做死循环判断 —— `while(1){ if (tcgetpgrp(tty)==本组) break; kill(0,SIGTTIN); }`。照实回远端存的值，第一个交互 shell 会把它自己的 pgrp 写进去，同一会话里第二个交互 shell 一问就"发现自己不是前台" → `kill(0, SIGTTIN)` 把**整个进程组**停住 → 终端假死（实测：`sh -i` 起来后永不返回，连外面的脚本一起卡住）。所以这一条不是"缩水"，是假 tty 唯一自洽的答案：每个进程都认为自己在前台，谁也不去抢。 |
| **假 pts 的语义缩水** | `pty_shim.c` 给的是 socketpair 模拟：没有自己的行规程/termios/winsize（slave 上的 `tcgetattr/tcsetattr/TIOCGWINSZ` 走的是会话那份远端软 tty）；不是设备节点（`fstat` 报 socket）；`O_NOCTTY` 不生效；始终攥着 slave 端，所以"关光 slave → master 读到 EOF"不成立（反方向成立）；`dup`/`F_DUPFD` 副本不登记 pts 号。要 `BSH_FAKE_PTY` 才启用（否则落回真 ptmx，宿主/qemu 上照常走真实现）。 |
| **`scandir` / `fts` / `glob` 看不到改名** | 这些函数内部走的是**库内直接调用**(glibc 的 `__readdir`、musl 的直接调用),`LD_PRELOAD` 拦不到,它们会把 `X.BSH_SYMLINK` 当成普通文件。直接调 `readdir` 的程序(`ls`、自写的遍历)正常。 |
| 真实 dirfd(非 `AT_FDCWD`)靠 procfs | 相对路径 + 真实 dirfd 时会拼成 `/proc/self/fd/<n>/<path>` 再解析;没有 procfs 就**直接透传**(此时中间目录里的模拟链接不展开)。用 procfs 之后,**非法 dirfd 的 errno 是 `ENOENT` 而不是 `EBADF`**。`AT_FDCWD` 与绝对路径不受影响。 |
| `O_PATH \| O_NOFOLLOW` 拿到的 fd | 我们交出去的是标记文件,它的 `fstat(fd)` 会报普通文件而不是 `S_IFLNK`(没有拦 `fstat`,fd 无法反查它代表哪个链接)。 |
| 不带 `AT_SYMLINK_NOFOLLOW` 的 `faccessat` + `AT_EACCESS` | 透传给真实现,由它自己处理,本模块不额外加工。 |
| 命名冲突 | 后缀 `.BSH_SYMLINK` 是保留的:任何以它结尾的普通文件都会被当成链接。这是表示法的代价,换来的是一眼可辨、不与正常文件重名。 |
| 性能 | 每个路径型调用都要**逐层组件**探一次 `<组件>.BSH_SYMLINK`(路径 N 层就多 N 次 `lstat`)。终端场景无所谓,海量小文件遍历会明显变慢;真要优化可以加"目录里没有标记文件"的缓存,但那会引入失效问题,暂时不做。 |
| 与真软链接共存 | 同一个目录里真软链接和模拟链接可以并存,互不干扰。 |

## 7. 编译与验证速查

```bash
# 预载用的两份 .so(guest 侧)——正式的编法就这一条:
./scripts/build_shim.sh          # → entry/libs/arm64-v8a/libbshguest-{musl,glibc}.so

# 单模块自测(在 entry/src/main/cpp/shim/ 下跑)
cd entry/src/main/cpp/shim

# 编(两条都用 -std=gnu11;glibc 与 musl 都要能过)
gcc -O2 -std=gnu11 -shared -fPIC -o /tmp/fs_shim/libfs_shim.so fs_shim.c -ldl
gcc -O2 -std=gnu11 -o /tmp/fs_shim/selftest fs_shim_selftest.c

# 验收:同一场景两遍,输出必须逐字节一致
#   ① 不预载 = 真符号链接   ② 预载 = 模拟链接
cd /tmp/fs_shim && ./selftest > /tmp/a.txt \
  && LD_PRELOAD=/tmp/fs_shim/libfs_shim.so ./selftest > /tmp/b.txt \
  && diff /tmp/a.txt /tmp/b.txt && echo 一致

# 假 pts 自测(BSH_FAKE_PTY 才启用假实现,否则走真 /dev/ptmx)
gcc -O2 -std=gnu11 -shared -fPIC -o /tmp/ptyshim/libpty_shim.so pty_shim.c -ldl
gcc -O2 -std=gnu11 -o /tmp/ptyshim/selftest pty_shim_selftest.c
cd /tmp/ptyshim && BSH_FAKE_PTY=1 LD_PRELOAD=./libpty_shim.so ./selftest

# musl 兼容性(本机没有 x86 musl-gcc 时,用仓库里那份 aarch64 交叉工具链做编译检查)
TC=ElfLoaderDemo/tools/aarch64-linux-musl-cross/bin    # 在 ElfLoaderDemo 仓库里
$TC/aarch64-linux-musl-gcc -O2 -std=gnu11 -Wall -Wextra -fPIC -c fs_shim.c -o /dev/null
```

自测覆盖:建链接 → `lstat`(认 `S_IFLNK`)→ `readlink` → `stat`/`open` 穿过去读内容 →
`opendir`+`readdir`(看 `d_type` 与名字,含 2200 项目录的压力用例)→ `unlink` →
`EEXIST` 重复建(对链接名 / 真实文件 / 真实目录)→ 空目标与超长目标 →
`O_NOFOLLOW` → 悬空目标(`stat` → `ENOENT`,`lstat` 仍成功)→ `access` →
`readlink` 的 `bufsiz=0` → 链式链接 → 相对目标与 `..` → 中间目录是链接 →
`fstatat` 两态 → `realpath` →
`link` 出第二个名字(nlink=2)→ `rename` 链接(含 rename 到已存在的真实文件上)→
自环 → `ELOOP`。

自测自己 `mkdtemp` 一个临时目录、`chdir` 进去、跑完递归删掉,**不碰仓库**;
输出里不出现临时目录名(要打绝对路径处会把前缀剥掉),也不 `strerror()`
(glibc 与 musl 的措辞不同,那会让差异与 libc 有关、与 shim 无关)。

## 8. 与真 `symlink(2)` 对齐的 errno 一览

| 场景 | 真实现(实测) | 本模块 |
| --- | --- | --- |
| `symlink` 到已存在的名字 | `EEXIST` | 同 |
| `symlink` 目标为空 | `ENOENT` | 同 |
| `symlink` 目标 > 4095 | `ENAMETOOLONG` | 同 |
| `symlink` 父目录不存在 | `ENOENT` | 同(由真 `open` 给出) |
| `stat` / `open` 悬空链接 | `ENOENT` | 同 |
| `lstat` 悬空链接 | 成功,`S_IFLNK` | 同 |
| 链接自环 / 跳数超限 | `ELOOP` | 同(内核 40 跳,本模块 8 跳) |
| `open(link, O_NOFOLLOW)` | `ELOOP` | 同 |
| `stat("a/../b")` 且 `a` 不存在 | `ENOENT` | 同(不折叠 `..`,由内核判) |
| `readlink("link/")` | `ENOENT` | 同(透传) |
| `readlink(link, buf, 0)` | `EINVAL` | 同 |
| 标记文件内容为空 / >4095 | — | `ENAMETOOLONG`(表示法被破坏) |

---

## 9. dlopen 兜底：资源根（noexec）里的 .so 怎么装

**症状**（2026-10-03，pip + numpy）：

```
$ pip install numpy            # 本地 wheel，装到 site-packages，一切正常
$ python -c "import numpy"
ImportError: Error loading shared library
  .../site-packages/numpy/_core/_multiarray_umath.cpython-312-aarch64-linux-gnu.so:
  No such file or directory
```

文件**在**（`ls`/`stat`/`read` 都正常，pip 刚写的）。同一个 so 放进 **bundle libs**
（`/data/storage/el1/bundle/libs/arm64/`）却能正常打开 —— 两者只差一点：

| 位置 | 文件映射带 PROT_EXEC？ |
| --- | --- |
| bundle libs（el1，只读，安装时写入） | ✅ 可以 |
| 资源根（el2 应用数据目录，可写） | ❌ 内核/沙箱在 `mmap` 那一步就拒 |

而**任何**动态加载器除了 `mmap` 没有第二条路。所以这不是"权限没配对"，是"这条能力在 el2
上根本不存在"—— 和 `symlink(2)`（§1）同一类问题，只能换实现。

**做法**：把 `dlopen` 截下来，交给 `elfloader/elf_dl.cpp` 那个**进程内**装载器：

1. `__real_dlopen` 先试 —— 系统能开的照旧走原生路径，行为不变；
2. 失败才读文件 → `elf_dlopen_mem()`：段读进**匿名**内存（不要求文件可执行）→ 自己走
   RELA 重定位 → 未定义符号从 `dlsym(RTLD_DEFAULT)` 兜；
3. `dlsym`/`dlclose` 用 `elf_dl_owns_handle()` 分流：系统 handle 走真实现，我们的走 `elf_dlsym`。

只给 **libpython.so** 加 `-Wl,--wrap=dlopen,--wrap=dlsym,--wrap=dlclose`
（`scripts/build_python.sh`），**不动** §0 那份通用清单 —— 别的命令 so 没这个需求，
不该被牵连。

**接上这条路要补的三件事**（都在 `elf_dl.cpp`；它原本只是给 guest 用的雏形）：

| 补什么 | 为什么 |
| --- | --- |
| `DT_INIT` + `DT_INIT_ARRAY` 执行 | numpy 的扩展带 2 个构造项（类型/表注册），不跑则 import "成功"但一用就崩。两者地址语义不同：`DT_INIT` 是链接期 vaddr、要加 base；`DT_INIT_ARRAY` 的元素**已被 RELATIVE 重定位改成绝对地址** |
| 依赖预加载 `preload_needed()` | `dlsym(RTLD_DEFAULT)` 只看**已加载**的对象。numpy 的 C++ 扩展 NEEDED `libc++_shared.so`，而它平时不在主进程里 ⇒ `__register_frame_info` / `__cxa_*` / `_Unwind_Resume` 全没人提供。做法是把 DT_NEEDED 逐个 `dlopen(..., RTLD_GLOBAL)`（打不开的当"本来就在"，静默略过） |
| **弱符号放行** | 上一条之后仍报 `unresolved symbol __register_frame_info` —— 它是**弱**未定义（`nm` 显示 `w`），ELF 语义允许取 0。`resolve_sym` / `apply_relocs` 原来一律判失败，现在按 `ELF64_ST_BIND(...) == STB_WEAK` 放行 |

**没做的两件事**（实测都不需要）：

* **TLS**：本工具链走 **EMUTLS**（`__emutls_get_address` + `__emutls_v.*`，无 `PT_TLS`、
  无 TLS 重定位）—— 那套东西就是普通符号 + 普通重定位，elf_dl 天生支持。
  `llvm-readelf -l` 看 `_multiarray_umath` 的 TLS 段数就是 0。
* **IRELATIVE / ifunc**：那个 so 的重定位只有 `RELATIVE`/`JUMP_SLOT`/`GLOB_DAT`/`ABS64`，
  现有实现全覆盖。

**日志**：`BSH_ELFDL_TRACE=1` 打开过程输出（装载成功、构造数、依赖预载）；**出错路径永远打**
（`elog`）—— 否则调用方只剩 CPython 那句 "No such file or directory"，什么都看不出来。
`BSH_DLOPEN_TRACE=1` 打"哪个 so 从系统 loader 转到了 elf_dl"；失败**总是**打。

**已知语义差别**：`RTLD_LOCAL`/`RTLD_GLOBAL` 不分（都进同一张表、彼此可见）、
`dlclose` 不真卸（段不 munmap）、析构函数（`DT_FINI*`）不跑。

**实测**（`pip install` 本地 numpy wheel 之后）：

```
$ python -c "import numpy; print(numpy.__version__)"              → 2.5.3
$ python -c "import numpy; print(numpy.array([1,2,3]).sum())"     → 6
$ python -c "import numpy; print(numpy.linalg.det(...))"          → -2.0000000000000004
$ python -c "import numpy; print(numpy.fft.fft([1.,0.,0.,0.]))"   → [1.+0.j 1.+0.j 1.+0.j 1.+0.j]
```

每个扩展在 `BSH_DLOPEN_TRACE=1` 下都能看到
`系统 loader 失败(...) → 已由 elf_dl 装载`。

### 9.1 同一批改动里修掉的邻居问题：exec 失败语义

`pip install` 最初崩在 `uname -rs`（rc 127）。根因不在 pip：命令 so 侧的 `exec_shim`
在委托失败时 `_exit(127)`，而**真 `execve` 应当返回 -1 + errno**。CPython 的 subprocess
靠 `ENOENT` 逐个试 PATH 候选，第一个候选 `$HOME/uname`（并不存在）被 `_exit(127)` 掉之后，
它再没机会试到 `$SYSROOT/bin/uname`。

改成两条路统一语义（失败返回 -1 并摆 errno，只有**成功**才 `_exit` —— 成功等于"镜像被换掉"，
那才是不可返回的），并在 procmgr 侧把"路径不存在"单独报成 `not found`（shim 据此映射 ENOENT）。

⚠ **改这个文件要重编所有链它的命令 so**：toybox / mksh / vim / python / node / zip /
dropbear / qemu（`grep -ln exec_shim scripts/*.sh` 可查全）。

### 9.2 平台 tag 伪装与 musllinux 轮子（实验，默认关）

设备真实的平台名是 `harmonyos-HongMeng Kernel <版本>-aarch64`（`sysconfig.get_platform()`
读的是 `os.uname()`），PyPI 上自然没有这种轮子。但 CPython 的 `sysconfig.get_platform()`
认 cross-build 用的环境变量 `_PYTHON_HOST_PLATFORM`，而 packaging 的平台 tag 正是从那儿
取的（packaging 26.2 的 `_linux_platforms()`：名字不以 `linux_` 开头就原样 yield 那一个）。
所以**一个环境变量就能伪装**：

```
export BSH_PIP_FAKE_PLATFORM=musllinux_1_2_aarch64
```

实现在 `scripts/sitecustomize.py`（跟着 pip.tar 走）。另一条路 `PIP_PLATFORM` 走不通 ——
pip 26 直接拒绝："Can not use any platform or abi specific options unless installing via
'--target'"。

**还有半步**：装进来的 wheel 里，扩展名是**构建它的那台 python 的 EXT_SUFFIX**
（Alpine 的是 `…cpython-312-aarch64-linux-musl.so`），而本机 CPython 只认
`.cpython-312-aarch64-linux-gnu.so` / `.abi3.so` / `.so` —— 不处理就是
"`No module named '…'`，文件明明在"。sitecustomize 在开关打开时会把另一套后缀也加进
`EXTENSION_SUFFIXES`，并**换掉 `FileFinder` 的 path hook**（后半句必须做：FileFinder 是
bootstrap 时按当时那份后缀列表构造并缓存的，光改列表不生效）。

**实测结果**：

| 包 | 结果 |
| --- | --- |
| `markupsafe-3.0.4`（纯 C） | ✅ `escape('<b>&')` → `&lt;b&gt;&amp;` |
| `msgpack-1.2.3`（纯 C） | ✅ `packb`/`unpackb` 往返正确 |
| `numpy-2.5.3`（C++） | ❌ `unresolved symbol _ZTVN10__cxxabiv120__si_class_type_infoE` |

**C++ 那条为什么不行**：Alpine 的轮子用 **libstdc++**（`libstdc++-<hash>.so.6.0.33`，随
wheel 放在 `numpy.libs/` 里），未定义的符号是 `std::__cxx11::basic_string` 那一族；OHOS 这边
是 **libc++**（`std::__1::…`）—— 两者 ABI 不通用。真要救得给 elf_dl 补两件事（**都还没做**）：

1. **跨对象符号查找**：`resolve_sym` 只调 `dlsym(RTLD_DEFAULT)`，而**经 elf_dl 装载的对象
   不在系统链接器的全局作用域里** —— 于是 `.libs` 里那些库就算装进来了也看不见。
   （`dlopen_shim.c` 的 `preload_pep600_libs()` 已经把 PEP 600 的 `<dist>.libs/` 扫出来交给
   elf_dl 了，卡的就是这一步。）
2. **`DT_GNU_HASH`**：现在只解析 `DT_HASH`，没有它就把符号数拍成 `1<<20` 的保守上限 ——
   而现代编译器产物（含 libstdc++）大多只有 GNU_HASH，符号查找会落空。

即便都补上，也还得把 libstdc++ / libgfortran / OpenBLAS 一整套 Alpine 库在 OHOS 上跑起来，
成功率不高。所以**主线仍然是自己交叉编 wheel**（`NUMPY_LAYOUT=wheel`，只依赖设备本来就有的
libc++）。伪装这条路的实际价值在**纯 C 的包** —— 那类轮子拿来就能用。

---

## 10. npm 的原生扩展（`.node`）—— 与 pip 同源，但多两个坑

python 那条路（§9）打通之后，node 这边看起来只差"把同一套对象链进 libnode.so"。实测
（2026-10-04）确实如此，但路上多出两个**只有 node 才会踩到**的问题。三个结论按发现顺序记：

### 10.1 宿主作用域优先 —— 撞上了鸿蒙自己的 NAPI 实现

**症状**：`--wrap=dlopen` 那套装好后，`.node` 能被装载了（trace 里能看到
`系统 loader 失败(…) → 已由 elf_dl 装载`），但 addon 的初始化跑不对：

```
[napi] napi_get_version -> 0 ver=8          ← 怪：node 18 的 NAPI 版本是 9
[napi] napi_create_function -> 10 fn=0      ← 10 = napi_pending_exception
[napi] create_function: code=10 msg="An exception is blocking"
  require ok, keys= []                      ← 注册"成功"了，但 exports 是空的
```

**根因**：**符号撞车**。应用自己链了鸿蒙的 `libace_napi.z.so`（ArkTS 的 N-API 实现，
导出 190 个 `napi_*`）；`libnode.so` 也导出 145 个。`procmgr` 用 `RTLD_GLOBAL` 加载命令 so，
所以两者在同一个全局作用域里，而 **libace_napi 在应用启动时就加载了、libnode 是后来 dlopen
的** —— `dlsym(RTLD_DEFAULT, "napi_create_function")` 先命中**前者**。
拿 node 的 `napi_env*` 去调 libace_napi 的实现，返回码自然是废的（`ver=8` 就是它的版本），
下一个调用（`napi_is_exception_pending` 会解引用 env）直接把进程打崩（`sig=7 pc=0x1`）。

**修法**：给 elf_dl 加一个"**首选符号解析器**"钩子（`elf_dl_set_prefer_sym`），
`dlopen_shim.c` 在装载时把自己所在的 so 注册进去：

```c
/* dlopen_shim.c：dladdr 拿到宿主 so 的路径 → dlopen 它（musl 认已加载，返回同一 handle）
   → 之后每个未定义符号都先在宿主身上找，找不到再退回 RTLD_DEFAULT */
[dlopen] 宿主作用域 /data/storage/el1/bundle/libs/arm64/libnode.so → 0x…
```

修好后的实测（同一个 addon，只换了 libnode.so）：

```
[napi] napi_get_version -> 0 ver=9     ← 现在才是 node 的
[napi] napi_create_function -> 0 fn=0x…
  keys= [ 'hello' ]      hello() = napi-demo: hello
  sum([1,2,3,4]) = 10    放进 node_modules 按包名 require 连跑三轮也正常
```

⚠ **实现上有个坑**：`elf_dl_set_prefer_sym` **必须定义在匿名 namespace 之外**。第一版写在了
里面 —— 内部链接 + 本 TU 没人调用 → `-O2` 直接把它删了 → 宿主里留下一个
`U elf_dl_set_prefer_sym`，**整个 libnode.so dlopen 不进来**（node 命令全废）。
`build_hap.sh` 的那道 `__wrap_/__real_` 自查**查不到这类未定义符号**，所以这类改动后
最好顺手 `llvm-nm -D -u <so> | grep -v '^ *U \(dl\|pthread\|m\|c\|gcc\)'` 扫一眼。

### 10.2 exec 的目标路径要先解开"用户态软链"

**症状**：`.node` 能加载了，但 `npm install` 任何带 install 脚本的包都失败：

```
npm error command sh -c node-gyp-build
npm error /…/node_modules/.bin/node-gyp-build: cannot exec: …: not found   ← 我们报的
npm error sh: /…/node_modules/.bin/node-gyp-build: No such file or directory
（code 126）
```

**根因**：`node_modules/.bin/*` 是 **npm 建的软链**，在这个沙箱里被 fs_shim 表示成
`<name>.BSH_SYMLINK`（§1）。做 PATH 查找的 **shell 有 fs_shim、看得见它**；而路径最终交给
**procmgr**，procmgr 没有 fs_shim、按真路径 `stat` → ENOENT → "not found" → shell 报 126。

**修法**：在**调用方进程里**先把路径展开再交出去 —— `exec_shim.c` 的 `spawn_delegated()`
开头调 fs_shim 的 `bsh_fs_resolve_path()`（这个函数本来只有 box64 模式用，现在无条件编）。
约定仍然只有 fs_shim 那一份实现。⚠ 用**弱引用**：qemu 那个 so 只链 exec_shim、不链 fs_shim，
强引用会变成未定义符号、整个 so 加载不进来。

修好后 `node-gyp-build` 真的跑起来了（于是暴露了 10.3）。

### 10.3 还没做的：真 TLS（`R_AARCH64_TLSDESC`）

拿**第三方真实预编译** addon 试（`@napi-rs/uuid-linux-arm64-musl`，Rust），卡在：

```
[dl] uuid.linux-arm64-musl.node: unsupported JMPREL reloc type 1031   ← R_AARCH64_TLSDESC
[dl] uuid.linux-arm64-musl.node: relocation failed
```

它的重定位全貌：`RELATIVE 505 / JUMP_SLOT 55 / GLOB_DAT 7 / TLSDESC 9`，另有 `PT_TLS`
(`filesz 0x28`、`memsz 0x98`)。**python 那批没踩到**是因为 OHOS clang 走 **EMUTLS**
（`__emutls_get_address` + `__emutls_v.*`，无 PT_TLS、无 TLS 重定位），而正常 musl/glibc
工具链（Rust、GCC、以及用 `thread_local` 的 C++）产的是真 TLS。

**可行路径**（还没动）：TLSDESC 的调用约定是"把描述符地址给 resolver、resolver 返回
**TP 相对**偏移"，而 aarch64 上 TP 就是 `tpidr_el0`。所以我们可以：
1. 按 `PT_TLS` 为每个对象、每个线程要一块堆内存（`pthread_key_create` + 析构器），
   装载时把 TLS 模板拷进去；
2. `R_AARCH64_TLSDESC` 的槽写成 `{resolver = 我们的小桩, arg = {对象, 偏移}}`；
3. 桩里返回 `堆块 + 偏移 - tp` —— 调用方随后做 `tp + 返回值`，正好落回堆块。
   （要 `mrs x?, tpidr_el0` 读 TP，就是一小段汇编。）
这条路**不需要**宿主配合，也不用碰 musl 的 TLS 表。**但 `TPREL`/`initial-exec` 那类
（编译期就写死 tp 偏移的）仍然做不了** —— 那要求我们能把 TLS 块放进当前线程的静态 TLS 区，
而 musl 的 dlopen 从来不给我们这个机会。真遇到只能报错说清楚。

另外两处**已知缺口**（与 TLS 无关，但同样挡着"装真实 npm 包"）：
* **预编译挑不中**：`node-gyp-build` 按 `prebuilds/<platform>-<arch>/` + 文件名里的
  `glibc`/`musl` 标签挑；`libc` 它用 `isAlpine()`（只看 `/etc/alpine-release`）判，
  所以我们这儿被判成 **glibc**。bufferutil 干脆没发 linux-arm64（只有 darwin/linux-x64/win32），
  于是回退 `node-gyp rebuild` → 设备上没有 node-gyp。
* **现场编译**：要 `node headers` + `node-gyp`。headers 照 python-headers 的套路打个包即可
  （`npm config set nodedir=$SYSROOT/node-headers`），node-gyp 是纯 JS（随 npm 树走），
  但它的构建要 `make`（devtools 包有）+ 我们的 `cc-ohos` 包装，还得过 GYP 那一堆探测。

---

## 11. npm 现场编原生扩展（node-gyp 链）—— 一路打到底的七件事

`npm install --build-from-source <包>` 这条链比 pip 长得多（node → node-gyp →
gyp 生成的 Makefile → make → sh → 编译器），一路上撞到七个**互相独立**的问题。
逐个记，附证据与修法 —— 每一个都值得单独记一笔，因为它们都在这条链之外也会咬人。

### 11.1 `SearchPath` 用的是 procmgr 自己的 PATH，不是调用方的

**症状**：`node-gyp` 明明在调用方的 PATH 上（`@npmcli/run-script/lib/node-gyp-bin/node-gyp`，
设备上确认两个文件都在），npm 却报
```
npm error code ENOENT ... syscall: 'spawn node-gyp'   ← 裸名
```

**根因**：`Resolve()` 为裸名做 PATH 查找时读的是 **procmgr 进程自己的 `environ`**，
而调用方（npm）在 `req.env` 里换了 PATH（给生命周期脚本前插 `node_modules/.bin` 与它自带的
node-gyp-bin）。

**修法**：新增 `RequestPath(req)` —— `req.env` 里有 `PATH=` 就用它（`req.env` 是覆盖项，
见 `ApplyEnv`），没有才回落到 procmgr 自己的。`SearchPath(name, path_env)` 改成收两条。

### 11.2 `/bin/sh` 这类标准路径要落到命令表

**症状**：构建系统把 `SHELL` 写死成 `/bin/sh`（gyp 的 Makefile、autotools、meson 都是），
于是 exec `/bin/sh` 直接打到内核 —— 设备上的 `/bin` 是**系统**的、我们不可访问，
结果要么 EACCES，要么（把 SHELL 指到我们的启动器时）内核 ENOEXEC → 启动器被**当 shell
脚本逐行解释**，报出启动器自身的三个字段：
```
/bin/sh[2]: .../libmksh.so: can't execute: Permission denied
/bin/sh[3]: main: inaccessible or not found
/bin/sh[4]: 2: inaccessible or not found
```

**修法**：`Resolve()` 在路径归一之后加一条 —— 路径形如 `<标准前缀>/<名字>`
（`/bin`、`/usr/bin`、`/sbin`、`/usr/sbin`、`/usr/local/bin`）、且名字在命令表里，
就按命令表起（`/bin/echo` 实测直接可用）。

### 11.3 `__fd_chk`：OHOS musl 私有符号，我们的 musl 没有

**症状**：动态链接的 guest 一装载就报
```
Error relocating make: __fd_chk: symbol not found
```
**根因**：OHOS 的 `sys/select.h` **无条件**把 `FD_SET`/`FD_CLR` 展开成 `__fd_chk(fd)`
（它的越界检查）；而 bundle 里的 `ld-musl-aarch64.so.1` 是 **vanilla 1.2.2**，没这个符号。
动态链接期不查未定义符号 ⇒ 编译链接都过、运行期才炸。用 OHOS SDK 头文件编出来的**任何
东西**都会踩（make/ninja、cc-ohos 编的扩展、pip 现场编的 C 扩展）。

**修法**：`scripts/build_musl.sh` 的 patch 阶段新增 `src/misc/__fd_chk.c`
（musl 的 Makefile 用 `$(wildcard src/*/*.c)`，丢进去就自动编进来；全局符号默认导出）。
语义等价实现：`fd` 不在 `[0, FD_SETSIZE)` 就 `abort()`。
另外 `build_devtools.sh` 与 cc-ohos 包装脚本都额外关掉 fortify（`-U_FORTIFY_SOURCE`），
少引一批 OHOS 私有的 `__*_chk`。

### 11.4 make/ninja 必须**动态**链接，否则吃不到 shim

**症状**：make 起来了、也进了 recipe，但报
```
make: /bin/sh: Permission denied        ← 内核给的 EACCES
```
**根因**：`build_devtools.sh` 原来用 `-static`。静态 guest 没有 PT_INTERP ⇒ procmgr
的 `ChildRunElf` 那段"按 PT_INTERP 挑 shim 预载"直接跳过（`[elf] loaded ET_EXEC` 就是它）
⇒ **make 里根本没有 shim** ⇒ 它的 execvp 直接打到内核。

**修法**：改成动态（`-Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1`，与其它 guest 一致）。
动态之后 LD_PRELOAD 生效，make 的 recipe 正常跑（实测 `T-ok` 打出来了，execshim.log
里也能看到它的委托记录）。**这条对所有 guest 都成立：要 shim 就别静态链。**

### 11.5 node 的 N-API 撞上鸿蒙的 NAPI 实现 —— 见 §10.1
### 11.6 `.bin` 软链的 exec —— 见 §10.2
### 11.7 TLSDESC（真 TLS）—— 见 §10.3

### 11.8 最后一米：**GNU make 的 SHELL 从不来自环境**（已修）

上面七件事都修完之后，`npm install --build-from-source bufferutil` 仍然停在：

```
node-gyp ✓ → configure ✓ → make ✓ → recipe 的 shell 起来了 ✓
→ 编 .o 那一步：make: /bin/sh: Permission denied
                make: *** [bufferutil.target.mk:111: .../bufferutil.o] Error 127
```

排查过程中**同时排除了三个看着很像的假设**（记下来，免得下次再走一遍）：

| 假设 | 怎么否掉的 |
| --- | --- |
| musl 的 `system()`/`popen()` 在库内 exec、LD_PRELOAD 拦不到 | 写了个最小 guest（同为动态 musl）实测：`system()` ✓、`execvp("/bin/sh")` ✓ 都正常 |
| `/bin/sh` 不可达 | 同上；而且 `python3` 的 `os.system`/`os.popen`/`subprocess` 三种都通 |
| node-gyp 的上下文特殊（PATH 里插了 `node_gyp_bins`、调用方是 node…） | 用 `make -C build` 在**我们 shell / node / node-gyp 的 env** 三种调用方下各跑一次 —— 失败一模一样，**只跟那个 makefile 有关** |

**真因**：**GNU make 从不从环境取 `SHELL`**（手册原话 "Unlike most variables, the variable
SHELL is never set from the environment"），默认写死 `/bin/sh` —— 而沙箱里的 `/bin` 是系统的、
我们不可访问。gyp 生成的 recipe 里那些带引号的命令（`exact_echo`、`do_cmd`）必须经 shell 跑，
于是每次都在"起 recipe 的 shell"这一步死掉。注意 `sh`/`which sh` 全都是好的 —— 因为那些走
procmgr；make 这一条是它自己按 `/bin/sh` 去 exec。

**修法**（`.bshrc` 一行）：

```sh
export MAKEFLAGS=SHELL=$BSH_SYSROOT/bin/sh
```

`MAKEFLAGS` 里的变量赋值等价于**命令行定义**，会传给子 make，优先级还高于 makefile 里的
`SHELL :=`（gyp 本来也不设）。

**验收**（2026-10-04，设备上实测）：

```
$ npm install --no-audit --no-fund --build-from-source bufferutil
  added 2 packages in 8s                          ← 编译 + 链接 + 拷贝
$ ls node_modules/bufferutil/build/Release/
  bufferutil.node  15256 bytes                    ← 设备上编出来的（包内预编译只有
                                                    darwin/linux-x64/win32）
$ node -e 'bu.mask(src,mask,out,0,4)'
  mask -> 11223344                                ← 与手算 XOR 完全一致
$ npm install --build-from-source utf-8-validate && node -e 'v(Buffer.from([0x41]))'
  valid(0x41)=true  valid(0xC0)=false             ← 语义也对
$ npm install left-pad && node -e 'require("left-pad")(4,8)'
  4                                               ← 纯 JS 包回归正常
```

### 11.8b 顺带修好的：裸 `clang`（自检第 3 档回归）

跑全量自检时冒出来一条新 FAIL：`clang hello.c` → `'stdio.h' file not found`。

**不是这一轮改坏的**，是"把 clang 从命令 so 换成 pkg 的 ohos-sdk-prune"留下的口径差：
自检那句是**裸 `clang`**，而 PATH 上排前面的是 SDK 的 `llvm/bin/clang`，它的默认 target 是
`aarch64-unknown-linux-gnu`（不是 ohos）→ 连 `stdio.h` 都找不到；单独补 `--sysroot` 又会
卡在 musl 的 `bits/alltypes.h`。只有 `--target=aarch64-linux-ohos` + `--sysroot` 一起给才对。
（历史上这条没暴露，是因为那时 SDK 没装、这一档直接走 `clang 未安装 → 跳过` 的分支。）

**修法**：`WriteCcWrapper` 多生成两个**同名**包装 `$SYSROOT/bin/{clang,clang++}`（就是
cc-ohos 那串参数），并把 `$SYSROOT/bin` 在 PATH 里排到 SDK 的 `llvm/bin` 之前。
实测三条路径（裸 `clang`、显式 `--sysroot`、`cc-ohos`）都编出 14000 字节的产物。

**回归**：全量自检 `PASS=62 FAIL=2`（那两条是既有的 x86_64 静态组合），比改动前的
`PASS=59 FAIL=2` 多三项 —— 因为这一档现在真的跑了（而不是跳过）。

### 11.9 这一轮新增/改动的文件

| 文件 | 改动 |
| --- | --- |
| `procmgr/procmgr.cpp` | `RequestPath()`（11.1）、标准路径→命令表（11.2） |
| `shim/exec_shim.c` | 委托前先解用户态软链（§10.2，弱引用 `bsh_fs_resolve_path`） |
| `shim/fs_shim.c` | `bsh_fs_resolve_path()` 移出 `#ifdef BSH_SHIM_BOX64`，无条件编 |
| `shim/dlopen_shim.c` | 宿主作用域优先（§10.1） |
| `elfloader/elf_dl.cpp` | 首选符号解析器；PT_TLS + TLSDESC 的 C 体 `bsh_tlsdesc_resolver_c`（§10.3） |
| `elfloader/tlsdesc.S` | **新文件**：TLSDESC resolver 的汇编外壳 `bsh_tlsdesc_entry`（除 x0 外所有寄存器都保住）。与 `guest_switch.S` 同待遇、单独成文件；`build_node.sh` 与 `build_python.sh` 都要编它 —— **落下就是未定义符号，整个 so dlopen 不进来** |
| `shell/shell.cpp` | `.bshrc` 加 `npm_config_nodedir`、`MAKEFLAGS=SHELL=…`、PATH 顺序；cc-ohos 关 fortify；新增同名 `clang`/`clang++` 包装（§11.8b） |
| `scripts/build_devtools.sh` | 动态链接（11.4）+ 关 fortify（11.3）+ 版本 1.0.1 |
| `scripts/build_musl.sh` | 新增 `src/misc/__fd_chk.c`（11.3） |
| `scripts/build_node.sh` | 重链时链入 dlopen 兜底那套（§10 开头） |

---

## 附：路径映射表 `kPathMap`（fs_shim.c，2026-10-07 新增）

有些程序把**系统路径硬编码在代码里**，而 guest 的 `/` 是只读 app 根、那些路径并不存在。
`fs_shim.c` 顶部的 `kPathMap[]` 就是给这种情况的替身表，目前只有一项：

```c
static const struct { const char* from; const char* to_rel; } kPathMap[] = {
    { "/usr/share/X11/xkb", "usr/share/x11/xkb" },   /* to_rel 相对 $BSH_SYSROOT */
};
```

应用位置：`resolve_simlinks()` 的开头（本函数是**整条路径的公共入口**，
`stat/realpath/open/access/fopen` 都从它下面过），排在已有的 `/proc/self/exe` 替身之前。
边界判断是 `path[n] != '\0' && path[n] != '/'`，避免误伤 `/usr/share/X11/xkbevil` 这类前缀；
带 `bsh_trace`，设 `BSH_SHIM_TRACE=1` 可见 `map_path: … -> …`。

**为什么需要它**：libxkbcommon 把 include path 硬编码成 `/usr/share/X11/xkb`，
实测**不认** `XKB_CONFIG_ROOT`。目录不存在 → `failed to add default include path` →
随后在 `xkb_context_include_path_*` 里踩空 → **SIGSEGV(139)**，进程约 3 秒就死。
这一条曾被误以为是 Electron 的问题，绕了很多轮（见 `build/vscode/STATUS.md` §70/§71）。

**加项注意**：`kPathMap` 只做**前缀替换**（不改相对路径、不做 realpath）；若以后要映射
`/bin/sh`、`/usr/bin/env` 这类，同样加一行即可 —— 但要注意 `exec` 家族走的是
`exec_shim.c`，那里需要单独处理（`fs_shim` 管不到 execve 的参数）。
