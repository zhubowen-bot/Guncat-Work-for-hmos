# glibc-ohos — 一份"不做文件映射"的 glibc,给这台 HarmonyOS 设备当 guest 运行时

产物:`build/glibc/out/lib/{ld-linux-aarch64.so.1, libc.so.6}`(由 `scripts/build_glibc.sh`
编出,**install 阶段直接交付进 bundle libs** `feature/bsh_main/libs/arm64-v8a/`,随 HAP 走 ——
设备侧就这一份,`procmgr` 只从那里按 basename 找解释器 / 塞 `LD_LIBRARY_PATH`)。
唯一实质改动:**动态链接器不再把库文件 mmap 进地址空间**,改成
"匿名预留 → `pread` 读入 → `mprotect` 给权限",和 `feature/bsh_main/src/main/cpp/elfloader`
装 guest 的做法一致。目的见下面第 1 条。

```
scripts/glibc-ohos/
├── README.md             ← 本文件:症状 → 根因 → 修法
├── patches/              ← 对 glibc 2.39 的改动(build_glibc.sh patch 阶段打)
│   ├── 0001-dl-map-segments-no-file-mapping.patch
│   ├── 0002-rseq-registration-noop.patch
│   └── 0003-clone3-enosys-no-syscall.patch
└── probe/                ← 自证程序(按需:build_glibc.sh pack → glibc-ohos.tar,自己推上设备)
    ├── hello.c           动态 guest,退出码 7
    ├── dlopen_probe.c    dlopen + /proc/self/maps 判据 + Seccomp 状态
    └── libgreet.c        被 dlopen 的那个库
```

阶段(`scripts/build_glibc.sh [src|headers|patch|configure|build|install|pack|all]`):

| 阶段 | 干什么 |
| --- | --- |
| src | 下载 glibc 2.39(钉 sha256)解到 `build/glibc/glibc-2.39` |
| headers | 造一份只含 Linux UAPI 头的 `build/glibc/kheaders` |
| patch | 打 `patches/*.patch`(正反向 dry-run 判幂等) |
| configure/build | 交叉 configure + `make -j`(日志 `build/glibc/make.log`) |
| install | 挑出 `ld-linux-aarch64.so.1` + `libc.so.6` → `build/glibc/out/lib`,**并交付到 bundle libs**(`feature/bsh_main/libs/arm64-v8a/`,随 HAP 走;设备侧的唯一来源) |
| pack | 按需:编 `probe/*.c` 并打 `rawfile/tools/glibc-ohos.tar`(只有三个探针 ELF,运行时不在里面)。**不随包发**(要重跑验收就自己推到设备上解开) |

---

## 1. 弹"是否运行 xxx"确认框 / 库放 `$HOME` 加载不了

**症状**
- 动态 glibc guest 一起服务就弹"是否运行 xxx"的确认框;拒绝后 guest 报
  `error while loading shared libraries: libc.so.6: cannot open shared object file`
  或 `failed to map segment from shared object`。
- 把同一对 `ld-linux-aarch64.so.1` + `libc.so.6` 放进 bundle libs(随 HAP 的
  `feature/bsh_main/libs/arm64-v8a`)能跑,放 `$HOME`(noexec)必失败。
- 探针实测(`mmapprobe`):同一个文件 `mmap(PROT_READ)` 放行,
  `mmap(PROT_READ|PROT_EXEC)` / `mprotect(RO→RX)` 被拒。

**根因**
设备沙箱把"把非系统文件当可执行体"交给 **seccomp 用户态通知**处理
(`/proc/self/status` 里 `Seccomp: 2` + 1 个 filter):`execve` 和 **file-backed 的
可执行 mmap** 都要用户点确认。glibc 的 ld.so 干的恰恰是后者 —— `-strace` 实测:

```
mmap(NULL, 1892224, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_DENYWRITE, -1, 0)   ← 预留
mmap(0x…, 1826688, PROT_EXEC|PROT_READ, MAP_PRIVATE|…|MAP_FIXED, fd, 0)          ← 代码段:文件 + r-x
mmap(0x…,   20480, PROT_READ|PROT_WRITE, MAP_PRIVATE|…|MAP_FIXED, fd, 0x19d000)  ← 数据段
```

第二行就是"文件映射 + 可执行" → 触发闸;而 noexec 挂载($HOME)上它本来就该失败,
这也解释了为什么以前的绕法是把 glibc 运行时塞进 bundle libs。

**修法**(`patches/0001-dl-map-segments-no-file-mapping.patch`,只动
`elf/dl-map-segments.h`)

- `_dl_map_segment()`:整块地址区间改成 `MAP_ANONYMOUS|PROT_NONE` 预留,不再
  `MAP_FILE` + `fd`;
- 新增 `_dl_read_segment()`:逐段 `mprotect(PROT_READ|PROT_WRITE)` →
  `pread64_nocancel(fd, …, c->mapoff + done)` 把文件镜像读进去 →
  `mprotect(c->prot)`(代码段到这一步才变 `r-x`);段尾超出文件的部分、以及最后
  一段的 bss 尾巴,落在全新匿名页上本来就是 0,不用额外补零;
- 固定地址的对象(ld.so 直接跑非 PIE 程序那条路)没人替它预留,块内
  `mprotect` 失败时用 `MAP_FIXED|MAP_ANONYMOUS` 就地补一块。

副作用:地址空间里不再有 `libc.so.6` 的文件映射,`/proc/self/maps` 里搜库名应该
**一条都搜不到**(`dlopen_probe` 会把这件事打出来)。

**aarch64 上必须补一句 icache 清理**:段内容是 `pread` 写进去的,可能还停在
D-cache 里,直接当代码执行有取到旧指令的风险。`__builtin___clear_cache` 会引入对
libgcc `__clear_cache` 的依赖(rtld 里不方便),所以补丁里内联了
`dc cvau` / `dsb ish` / `ic ivau` / `isb` 这一串(等价物)。

**`__pread64_nocancel` 要先声明**:`dl-load.c` 里 `not-cancel.h` 排在
`dl-map-segments.h` **之后**,直接用会变成"隐式声明 int()"→ 和后面
`__typeof (__pread64)` 的声明冲突报错。补丁里在文件开头自己
`#include <not-cancel.h>`(有 include guard,重复引用无害)。

**别漏了第一个段**:上游的 `_dl_map_segment()` 是把**整个文件镜像**从
`c->mapoff` 映射 `maplength` 字节,所以第一个段顺带就有了;改成只预留地址之后,
第一个段(ELF 头 + 代码)没人往里填 —— 表现是 `_dl_start` 一开始执行就 SIGSEGV 在
对象基址上(`si_addr` = 映射基址 + 0x238)。现在在 ET_DYN 分支里显式补一次
`_dl_read_segment(第一个段)`(下面那个循环是从 `postmap` 标签进的,跳过它)。

**匿名页变成 `r-x` 可能要 HarmonyOS 的 jit 开关**:这台设备的 W^X 只在
`prctl(0x6a6974 /* 'jit' */, 0, 0)` 打开时才允许把匿名页设成可执行
(elfloader 的 `mprotect_final` 就在做这套)。所以补丁里包了一层
`_dl_mprotect()`:先直球 `mprotect`,带 `PROT_EXEC` 且失败时再开 jit 重试一次。
**开关值是 0=开、1=关**(和 elfloader 的 `jit_toggle()` 一致)。这个值写反过一次
(拿 `1` 当"开门"),后果:**等于从没开过门** —— 需要把匿名页设成 `r-x` 的那次
`mprotect` 照样失败,调用者看到 `cannot change memory protections`。实测(同一份
tar、同一台设备,只换 `ld.so`)就是设备侧 glibc 动态的 `hdc` 起不来:
`libpthread.so.0: cannot change memory protections` rc=127,`LD_PRELOAD` 里的
`libbshguest-glibc.so` 也被丢弃;换成 `0` 之后同一个 `hdc` 直接 `Ver: 3.2.0f` rc=0。
改这个值时要连着 `scripts/glibc-ohos/patches/0001-*.patch` 一起改(重新生成补丁,
不要手改行数),再 `build` 加 `install`;反汇编 `ld.so` 可以自证:
`prctl('jit',0,0) → mprotect → prctl('jit',0,1)`。
原生 Linux 上那个 prctl 返回 EINVAL,重试还是失败,行为与原来一致。失败时返回的是
`DL_MAP_SEGMENTS_ERROR_MPROTECT`("cannot change memory protections"),
好和沙箱拒绝文件映射时的 "failed to map segment from shared object" 区分开。

## 2. 启动即被 SIGSYS 杀掉(rseq)

**症状**:guest 连 `main` 都进不去,进程无声退出;单独探针跑 `rseq`(aarch64 = 293)
得到 159(SIGSYS)。

**根因**:glibc 2.39 启动时**无条件**注册 `rseq`(`__libc_start_main` →
`dl-tls_init_tp.c` → `rseq_register_current_thread`),而这个沙箱对 `rseq`
直接 SIGSYS 杀,不给返回值。原来靠 `GLIBC_TUNABLES=glibc.pthread.rseq=0`
(见 `procmgr.cpp` 的 `ForkChild`)绕。

**修法**(`patches/0002-rseq-registration-noop.patch`,`sysdeps/unix/sysv/linux/
rseq-internal.h`):注册函数直接不调 syscall,`cpu_id` 置
`RSEQ_CPU_ID_REGISTRATION_FAILED`,语义等价于"内核不支持 rseq" ——
`__rseq_size` 保持 0,新线程也不会继承 `ATTR_FLAG_DO_RSEQ`
(否则会撞上 `pthread_create.c` 里的 `__libc_fatal`)。依赖 rseq 的库看到
`__rseq_size == 0` 会自己退回 syscall 路径。于是运行期**不再需要**那个环境变量。

## 3. 线程创建被 SIGSYS 打死(clone3)

**症状**:动态 glibc guest 其它用例全过,一进 `pthread_create` 整只进程被打掉
(rc=159=128+31,即 SIGSYS),`pthread create/join`、`pthread_mutex` 两项直接没了。

**根因**:glibc 2.39 起线程创建先试 `clone3`(aarch64 = 435);这台沙箱的 seccomp
对**没放行的号不给返回值,直接 SIGSYS**,而不是返回 `ENOSYS`。而 glibc 只在
`clone3` 返回 `errno == ENOSYS` 时才回退 `clone`(`sysdeps/unix/sysv/linux/
clone-internal.c` 的 `__clone3_internal`:`--enable-kernel=4.19` 让
`__ASSUME_CLONE3=0`,走的是"首调失败即置 `clone3_supported=0`"那条路)。
唯一能用 `rseq` 那个套路("被 SIGSYS 打死"→"优雅回退")化解的入口,就是让
`__clone3` 自己冒充"内核不支持"。

**修法**(`patches/0003-clone3-enosys-no-syscall.patch`,
`sysdeps/unix/sysv/linux/aarch64/clone3.S`):`ENTRY(__clone3)` 一进来就
`mov x0, #-ENOSYS; b .Lsyscall_error` —— **连 syscall 都不发**,直接返回
`-1`/`errno=ENOSYS`。上层 `__clone_internal` 看到 `ENOSYS` 就走
`__clone_internal_fallback` → `__clone`(aarch64 = 220 号),线程创建照常。
语义等价于"老内核没有 clone3",不再需要任何环境变量。

**改的是 `.S` 不是 `.c`(坑)**:任务直觉会去找
`sysdeps/unix/sysv/linux/clone3.c`,但那份源码只是个 `/* An empty placeholder. */` ——
`misc` 目录的 `sysdep_routines += clone3` 解析时,`aarch64/clone3.S` 先命中
(见 `build/glibc/make.log`:`aarch64/clone3.S -c → misc/clone3.o`),`.c` 永远轮不上。
改 `.c` 一眼看上去改了、编出来一点没变。

**留下的一段死代码**:早退之后,函数体原来的 `mov x8, #435; svc #0` 仍在,但不可达
(反汇编复核:`__clone3` 头两条就是 `mov x0, #-38` / `b __syscall_error`)。要的是
"运行期不再发出 435 号",不是"`svc` 指令从二进制里消失"。

**host 上的验证要认 `Unknown syscall 435`**:qemu-user **没实现 clone3**,它把 435
当未知号并返回 `ENOSYS`,所以**在 qemu 里打补丁前后都会优雅回退、pthread 本来就能过**
—— 本地复现不出沙箱的 SIGSYS。能用 strace 看的是"435 号有没有被发出去":
`qemu-aarch64 -strace ... | grep -c "Unknown syscall 435"` 打补丁后,主进程 0 次;
补丁前主进程会各发 1 次。注意测试程序最后会 exec `aarch64-glibc-static`,那只
是**静态链接宿主交叉 glibc**(不是我们自编的运行时),里面仍有 clone3,所以总量
不会归零 —— 要看的是**主 pid** 那几行。

## 4. clang 编不了 glibc 2.39 → 用宿主 GCC 13

OHOS SDK 的 clang 15(宿主的 clang 18 也一样)有三个硬障碍:

1. `configure` 要求 `__GNUC__ >= 6`,clang 自称 4 → 用
   `-fgnuc-version=12.3` 骗过去之后;
2. `bits/floatn-common.h` **无条件** `#define __HAVE_FLOAT32 1`,而 clang 根本没
   有 `_Float32`/`_Float64` 类型(实测 clang 15/18 都不认识)→ `stdlib.h` 直接编不过;
3. `configure` 硬性要求 asm 标签重定向(`asm("sym")` 改内置函数)支持,clang 没有。

所以改用宿主自带的 `aarch64-linux-gnu-gcc`(Ubuntu 24.04 / GCC 13)—— 它正是
glibc 2.39 的原厂编译器,产物是纯 aarch64 Linux ABI 的 .so,设备只认 ABI。

## 5. `inlining failed in call to 'always_inline' 'syslog'`

**症状**:`misc/syslog.c` 在 `ldbl_strong_alias (__syslog, syslog)` 上报
`error: inlining failed in call to 'always_inline' 'syslog'`。

**根因**:Ubuntu 的 GCC 在 `-O*` 下由 spec **自动**注入 `-D_FORTIFY_SOURCE=3`
(`gcc -dumpspecs` 里的 `*distro_defaults_cpp`),而 glibc 自己只加了
`-Wp,-U_FORTIFY_SOURCE` —— spec 的 `%{!U_FORTIFY_SOURCE:…}` 不认这种写法,于是
FORTIFY 生效,`bits/syslog-decl.h` 把 `syslog` 变成 `always_inline` 的
`__syslog_chk` 包装,后面的 strong alias 就编不过了。

**修法**:configure 的 `CFLAGS` 里加**真正的** `-U_FORTIFY_SOURCE`(spec 检测的是
命令行上有没有这个选项,和位置无关)。

## 6. `asm/errno.h` 找不到(内核头从哪来)

**症状**:`make` 早期就大面积 `fatal error: 'asm/errno.h' file not found`
(源头是 OHOS sysroot 的 `linux/errno.h`)。

**根因**:glibc 编译时是 `-nostdinc`,只认 `--with-headers` 指的那个目录;OHOS
sysroot 把 arch 那一层放在 `usr/include/aarch64-linux-ohos/asm/`,不在
`usr/include/asm/`。而且直接把整个 OHOS sysroot 当 `--with-headers` 会把 musl
的头也带进来。

**修法**:`build_glibc.sh` 的 `headers` 阶段造一份**只含内核 UAPI**的目录:优先用
`linux-libc-dev-arm64-cross`(`dpkg -L` 列出它拥有的顶层目录,整目录拷),没有
dpkg 就退回 OHOS sysroot 的 `linux/` + `asm-generic/` + `aarch64-linux-ohos/asm/`。

## 7. ld.so 去 `/lib64` 找库

**症状**:host 上 `qemu-aarch64 -L <out> ./hello` 报
`libc.so.6: cannot open shared object file`,而库就在 `<out>/lib/`。

**根因**:aarch64 的 glibc 上游默认 `slibdir=/lib64`(`sysdeps/unix/sysv/linux/
aarch64/configure.ac` 里 `LIBC_SLIBDIR_RTLDDIR([lib64], [lib])`),于是 ld.so
内建搜索路径是 `/lib64:/usr/lib64`。

**修法**:configure 参数钉 `--libdir=/usr/lib` 且 `libc_cv_slibdir=/lib`
`libc_cv_rtlddir=/lib` → 搜索路径回到 `/lib:/usr/lib`。

---

## 8. 自检脚本别放"会弹框"的探针(弹框会把**整个应用**冻住)

**症状**:`autorun.sh` 跑到 `mmapprobe <file> rx` 那一格就停住,日志几分钟不再增长
(实测停在 `[elf] calling guest entry=…`),后面所有步骤都跑不到。

**根因**:文件映射成可执行会触发 seccomp 用户态通知,系统弹"是否运行 xxx"确认框;
**弹框期间整个应用进程被冻住**(不只是发起 syscall 的那个子进程),自检脚本自己
也就停在那儿了 —— 没人点就一直冻。

**修法**:自检脚本里只留不会弹框的探针。要证明"闸还在",用两种不弹框的办法:
一是别的只读探针(`mmapprobe <file> ro` 是放行的那一格),二是引用已有结论 ——
一次真机实测里三格 exec 映射全 `errno=13`,
`rseq`(293)返回 159(SIGSYS),这就是"闸还在"的证据。
现在的 `tools/autorun.sh` 按这个纪律写:只跑不会弹框的探针(glibc 那两个要重跑
验收时按需把 tar 推上去解开,见「验证方式速查」)。

---

## 验证方式速查

```bash
# 编(各阶段幂等,可单独重跑)
./scripts/build_glibc.sh all

# host:qemu 快速迭代(样本 + 我们的运行时放同一层前缀)
qemu-aarch64 -L build/glibc/out /tmp/glibcprobe/hello-new          # 期望 rc=7
qemu-aarch64 -strace -L build/glibc/out /tmp/glibcprobe/hello-new  # 判据:无 MAP_FILE 的可执行 mmap

# 设备(当前口径):运行时随 HAP 进 bundle libs,不需要任何 rawfile tar ——
#   重打 HAP → 部署 → 会话自检写 $HOME/autorun.log;取日志 bash scripts/wait_autorun.sh 60 /tmp/x.log
# 想重跑探针:./scripts/build_glibc.sh pack 出 tools/glibc-ohos.tar,自己推到
#   设备上解开(改 elfloader/运行时的时候才需要),再在终端里跑 hello / dlopen_probe。
```

## 与上游的差异清单(改动都在这三个 patch 里)

| 文件 | 改了什么 | 为什么 |
| --- | --- | --- |
| `elf/dl-map-segments.h` | 段内容改 pread 读入匿名页,不再文件映射 | 沙箱拦 file-backed 可执行映射;noexec 挂载 |
| `sysdeps/unix/sysv/linux/rseq-internal.h` | rseq 注册变空操作 | 沙箱对 rseq 直接 SIGSYS |
| `sysdeps/unix/sysv/linux/aarch64/clone3.S` | `__clone3` 不发 syscall,直接 ENOSYS | 沙箱对 clone3 直接 SIGSYS;逼 `__clone_internal` 回退 `clone` |

configure 侧的差异(不是 patch,写在 `build_glibc.sh` 里):`--libdir=/usr/lib`、
`libc_cv_slibdir=/lib`、`libc_cv_rtlddir=/lib`、`CFLAGS=-U_FORTIFY_SOURCE`。
