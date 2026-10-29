# box64-ohos —— 把 box64 编成 OHOS 上可 dlopen 的 `libbox64.so`

配套脚本：`scripts/build_box64.sh`
上游：`https://github.com/ptitSeb/box64.git`，**钉死 commit `befc90de1ce4214ac720b2f1c154b8c896d7d202`**
（= v0.4.3-3-37，与 `/workspace/dev/HarmonyBox` 的 HEAD 相同）。
目标：在**不能 exec** 的 HAP 沙箱里跑 **x86_64 Linux ELF**（box64 是 x86_64→ARM64 的 dynarec）。

> 补丁集最初是 HarmonyBox `patches.sh` 的逐字副本（`scripts/patch_box64.sh`，6334 行、
> sed/python 就地改）。**2026-10-03 重构成现在这个样子**：新文件走 `files/` 覆盖，
> 对上游文件的就地修改拆成一条一个 `.patch`，由 `patch -p1` 顺序应用。
> 等价性已按「树级逐字节比对」验证过（见 §7），旧脚本已删除。

---

## 1. 目录布局

```
scripts/build_box64.sh            构建入口：clone → 复位 → 铺 files/ → 打补丁 → configure → ninja → 交付
scripts/box64-ohos/
├── README.md                     本文件
├── patches/series                补丁清单（逐行一个文件名，# 注释行会被跳过）
├── patches/NNNN-*.patch          35 条，`patch -p1` 应用，顺序即依赖顺序
├── files/                        我们自己的新文件，按 box64 源码树镜像摆放，构建时整份覆盖（14 个）
└── vendor/                       musl-fts / musl-obstack 的上游源码 + LICENSE（**仅供溯源**，见 §5）
```

构建脚本第 2 步只做两件事：

```bash
cp -a "$SPEC_DIR/files/." "$BOX64_SRC_DIR/"                  # 1) 新文件整份覆盖
while read -r line; do patch -p1 --forward --batch ... ; done < patches/series   # 2) 一次一条
```

`files/` 与 `patches/` **不交叉**：凡是「我们新建、之后又被别的补丁改」的文件
（`musl_compat.c`、`box64_path_remap.c`、`box64_spawn.c`），后续改动已折进最终内容，
对应补丁条目不存在。

---

## 2. 补丁清单

顺序即应用顺序。`原编号` = 旧单体脚本里的 `patch_NN`，方便回溯。

### 2.1 musl 能力缺口（编译期就能挂）

| # | 目标文件 | 干什么 | 原编号 |
|---|---|---|---|
| 0001 | `src/os/os_linux.c` | 用 `#ifdef` 包住 `mallopt(M_ARENA_TEST/M_ARENA_MAX/M_MMAP_THRESHOLD)` —— 这三个是 glibc ptmalloc 私有常量，musl 没有 | 01 |
| 0002 | `src/libtools/signals.c` | 给 `PTHREAD_ERRORCHECK/RECURSIVE_MUTEX_INITIALIZER_NP` 补 fallback（glibc 私有静态初始化器） | 02 |
| 0003 | `src/include/myalign.h` | `__sigset_t` → `sigset_t`（musl 不暴露无标签的 `__sigset_t`） | 04 |
| 0004 | `src/libtools/threads.c` | 删掉 box64 自写的 `_pthread_cleanup_push/pop` 前向声明（与 musl `<pthread.h>` 声明冲突） | 05 |
| 0005 | `src/wrapped/wrappedlibdl.c` | 补 `RTLD_DL_LINKMAP/RTLD_DL_SYMENT`（glibc 的 `dlinfo` 请求码；musl 无 `dlinfo`） | 08 |

### 2.2 绕开「host 自己 wrap 的 dl*」这条死路

musl 主程序里 box64 那些 `dlsym(RTLD_NEXT/ NULL, …)` 拿不到东西（拿到 NULL，
一调用就弹 0），几处互相咬着的修法分别成条：

| # | 目标文件 | 干什么 | 原编号 |
|---|---|---|---|
| 0009 | `src/custommem.c` | `dlsym(RTLD_NEXT,"__curbrk")` → `cur_brk = NULL`（musl 没有 `__curbrk`；主程序用 `RTLD_NEXT` 本身是 UB） | 15 |
| 0010 | `libtools/libdl.c`、`os/os_linux.c`、`wrapped/wrappedlibdl.c` | 文件里所有 `RTLD_NEXT` → `RTLD_DEFAULT`（全局搜索能拿到 musl 的真实现） | 16 |
| 0011 | `src/box64context.c` | 不做 `dlopen(NULL, RTLD_NOW\|RTLD_GLOBAL)` 自引用（会命中自己 EXPORT 的 wrap → 自递归） | 17 |
| 0012 | `src/libtools/threads.c` | 3 处 `dlsym(NULL,…)` 置 NULL；注释掉 `dlvsym(...,"GLIBC_2.x")` 与 `_pthread_cleanup_*_defer`／`pthread_cond_clockwait` 探测（musl 全无） | 18 |
| 0013 | `src/wrapped/wrappedlibc.c` | 把 `PRE_INIT` 展开出来的 `dlopen(NULL,…)` 中和成空宏（同一个自递归 trampoline 问题） | 19 |
| 0014 | `src/libtools/libdl.c` | `dlopen/dlsym/dlclose` 的转发 shim 改 `static` unused —— host 侧改走 musl PLT 的真实现 | 20 |

### 2.3 64 位 wrappers 的 musl 兼容

| # | 目标文件 | 干什么 | 原编号 |
|---|---|---|---|
| 0006 | `src/wrapped/wrappedlibc.c` | wrappers 总 prologue：ctype/pthread 声明、`__compar_d_fn_t`、NP 宏 fallback；在 `wrappercallback.h` 前后 `#undef`/`#define` 一批 `stat64→stat` 类宏（musl 用宏把它们映射到同一符号，会和 wrapper 表撞名）；把 `lock.__data.__owner/__count/__lock` 读成 0 | 09 |
| 0007 | `src/wrapped/wrappedlibc.c` | `#define _GNU_SOURCE` + `<sched.h>`（musl 的 `CLONE_*` 受它保护）+ 手写 `__ctype_b/tolower/toupper_loc` 声明 | 10 |
| 0008 | `src/mallochook.c` | **整文件替换**：把 box64 的内存池钩子换成 libc 直通（71 行替代 1136 行）。原本是为定位启动期 100% CPU 自旋的**诊断手段**，后来一直沿用；换回上游实现需要真机重验 | 13 |

> 0008 的取舍是**有意的**（决策记录见 `build/box64-patch-refactor-plan.md` §9）：
> 直通版牺牲了 box64 自己的分配器性能，换来的是"内存分配不再是我们自己的代码"。

### 2.4 BOX32（i386 guest 支持；`-DBOX32=ON`）

当前配置带着 BOX32 一起编，所以这一组全在。核心矛盾：host musl 的堆在高地址，
截断成 32 位再喂回 host 就成野指针 —— 所以要有"低 4GB 堆"和成对的代理。

| # | 目标文件 | 干什么 | 原编号 |
|---|---|---|---|
| 0015 | `src/include/myalign32.h` | 补 `__uid_t/__gid_t/__pid_t/__fsblkcnt64_t/__fsfilcnt64_t`（glibc `bits/types.h` 私有；这个头被 `*32*` 多文件 include） | 21 |
| 0016 | `src/libtools/signal32.c` | 同类 typedef + `__SI_SIGFAULT_ADDL` 空定义 + `_sifields`→`__si_fields`（musl 的 `siginfo_t` 联合叫别的名字） | 22 |
| 0017 | `src/libtools/libc_net32.c` | 注释掉 `dst->__glibc_unused_qhook/rhook`（glibc `__res_state` 末尾的废弃回调字段） | 23 |
| 0018 | `src/libtools/threads32.c` | 删 cleanup_push/pop 声明（同 0004）+ `((struct __pthread_mutex_s*)…)->__kind` 整个表达式 → 常量 `0` | 24 |
| 0019 | `src/libtools/myalign32.c` | obstack 32↔64 字段搬运改 `(void)0`（musl-obstack 把 `chunkfun/freefun/temp` 做成匿名 union，字段名对不上） | 25 |
| 0020 | `src/wrapped32/wrappedlibc.c` | BOX32 版 wrappers 的 prologue + `*64` 宏 + `glob_t.gl_flags` / `posix_spawn_file_actions_t.__{allocated,used}` no-op（镜像 0006/0007） | 26 |
| 0021 | `src/include/box32.h` | 关掉 `TEST_ABORT`：`to_ptr*` 命中 >4GB 只 warn 不 abort（OHOS 拿不到 `personality(ADDR_LIMIT_32BIT)`，严格 abort 太容易踩） | 31 |
| 0022 | `src/include/box32.h` | `to_*()` 改 `noinline` + warning 带 `__builtin_return_address(0)`（诊断：让截断点可定位） | 32 |
| 0023 | `src/elfs/elfloader32.c` | 给 `stdout/stderr/stdin` 预填 globdata（glibc 2.34+ i386 用 `R_386_GLOB_DAT` 而不是 `R_386_COPY`） | 33 |
| 0024 | `src/wrapped32/wrappedlibc.c`、`wrappedlibc_private.h` | `my32_*` 分配族全部改走 `box32_*` 低 4GB 堆（`GO/GOW` → `GOM/GOWM`） | 34 |
| 0025 | `rebuild_wrappers_32.py`、`src/wrapped32/wrappedlibc.c`、`wrappedlibc_private.h` | `io_convert32/io_convert_from` 改为转发到 `box32_io_*` 的 1024 槽动态 `FILE*` 代理表；`my32_fclose` 配套 | 35 |
| 0026 | `src/custommem.c` | `box_mmap32_hard_search_ohos`：ARM64 内核不认 `MAP_32BIT`，改用 `MAP_FIXED_NOREPLACE` 从 `0x40000000` 起 64KB 步长扫（避开 `box32` 堆的 `[0x10000000,0x20000000)`） | 36 |

> 0025 改的是**生成器**（`rebuild_wrappers_32.py`），生成物
> `src/wrapped32/generated/*` 由 CMake 构建期重跑它产出，**不进补丁**（见 §6）。

### 2.5 .so 化

| # | 目标文件 | 干什么 | 原编号 |
|---|---|---|---|
| 0027 | `src/main.c` | `main` → `box64_main`（.so 里不能有 `main`，且要被 `box64_so_entry.c` 转发） | 52 |
| 0035 | `CMakeLists.txt` | `add_executable` → `add_library(box64 SHARED)` + 所有新增源文件的 `target_sources` 注册（含 `bsh_box64_entry.c`）+ `OUTPUT_NAME box64`/`PREFIX lib` + `C_VISIBILITY_PRESET default`。**只有这一条动 CMakeLists**，因此它与其它补丁无顺序关系 | 53+03/06/07/12/27/65/80 的追加 |

### 2.6 路径重映射（HAP 里 `/tmp` 不可写、symlink 被拒）

| # | 目标文件 | 干什么 | 原编号 |
|---|---|---|---|
| 0029 | `src/wrapped/wrappedlibc.c`、`wrappedlibc_private.h` | v1：`my_open64`/`my_lstat` 注入 `box64_remap_path()`，`/tmp` → `TMPDIR/box64-tmp`；`bind/connect` 的 `sockaddr_un` 改写；另加 `my_mkdir/chdir/openat/…` 一组包装器 | 65 |
| 0030 | 同上 | v2：懒加载规则 `${WINEPREFIX}/dosdevices/c:` → `${WINEPREFIX}/drive_c`；`symlink` 在 HAP 上直接伪造成功（沙箱给 EPERM）；再补 8 个包装器 | 66 |
| 0031 | `src/wrapped/wrappedlibc.c` | v3：v1 只改了 `my_open64`，这里补 `my_open`（32/64 混用的路径会漏网） | 67 |

函数体在 `files/src/box64_path_remap.c`，这三条只负责把它接到 wrappers 上。

### 2.7 self-exec / mmap / 日志

| # | 目标文件 | 干什么 | 原编号 |
|---|---|---|---|
| 0033 | `src/core.c`、`src/wrapped/wrappedlibc.c`、`src/wrapped32/wrappedlibc.c` | 把 ~14 处 self-exec 调用点改成 `box64_self_execv/execve/posix_spawn{,p}`，收口到 `files/src/box64_spawn.c` 的三态调度器（native / fork / sock 委托给 procmgr） | 81 |
| 0028 | `src/wrapped/wrappedlibc.c` | `my_mmap64` 的 `MAP_FIXED_NOREPLACE` 回退：HAP 的 seccomp 用 `SECCOMP_RET_ERRNO(ENOSYS)` 静默拒绝带这个 flag 的 mmap，去掉重试并按需 `munmap` 模拟 NOREPLACE 语义 | 62 |
| 0032 | `src/wrapped/wrappedlibc.c` | 替换 0028 的回退块：按 `prot==0`（探测 → HINT + EEXIST）/ `prot!=0`（真分配 → `MAP_FIXED`）分流 | 72 |
| 0034 | `src/wrapped/wrappedlibc.c` | 日志门：把 bring-up 期刷屏的 `[mmap-noreplace]` 之类按 `BOX64_LOG` 分级，fatal 仍无条件打印 | 82 |

---

## 3. `files/` —— 我们自己的新文件（14 个）

| 文件 | 作用 | 来源 |
|---|---|---|
| `src/include/fts.h`、`src/musl_fts.c` | musl 没有 `fts(3)`（目录遍历）；`fts.h` 满足 `#include <fts.h>`，`musl_fts.c` 提供实现（CMake 里编进 box64） | void-linux/musl-fts（见 `vendor/`） |
| `src/include/obstack.h`、`src/musl_obstack.c` | 同上，GNU obstack | void-linux/musl-obstack |
| `src/include/error.h`、`src/musl_error.c` | GNU `<error.h>` 的最小实现（`error()`/`error_at_line()` + 3 个数据符号） | 我们自己写的 |
| `src/include/config.h` | 手写的最小 autotools 风格 `HAVE_*` 集合 —— 上面两个库顶部 `#include <config.h>`，但我们是 cmake 构建、没有 configure 产物 | 我们自己写的 |
| `src/musl_compat.c` | glibc-only 运行期符号的 weak 兜底（`__libc_malloc` 族、`dlinfo`、`qsort_r`(TLS 跳板)、`glob64`、`scandirat`、`obstack_printf`、`__ctype_*_loc` 的 ctor 建表…）+ **box32 低 4GB 分配器**（`box32_malloc/free/realloc` 族，256MB mmap 在 `[0x10000000,0x20000000)`）+ **box32 io 代理表**（`box32_io_*`，1024 槽） | 由旧脚本的 12/28/35 三段拼成 |
| `src/musl_box32_stubs.c` | BOX32 链接期缺的符号：`getprotobyname_r/number_r`、`__res_state`、`__chk_fail`、`getcontext/makecontext/swapcontext`（ucontext 那三个调到即报错退出） | 旧 27 |
| `src/sigsys_fallback.c` | 装 SIGSYS handler，把被 seccomp 拒掉的 syscall 返回值寄存器改成 `-ENOSYS`（否则默认是 kill）；ctor 自动装一次 | 旧 50 |
| `src/box64_so_entry.c` | 导出 `box64_run(argc, argv, env)`（重装 SIGSYS handler 后转发 `box64_main`）—— HAP 侧 `dlsym` 的契约入口 | 旧 51 |
| `src/box64_path_remap.c` | proot 风格的单向路径改写：`/tmp`、`/dev`、Wine 的 `dosdevices/c:` 等；`box64_remap_path()` 被 wrappers 调用 | 旧 65+66+68 |
| `src/box64_spawn.c` | 三态 spawn 调度器（native / fork / **sock 委托 procmgr**）+ `SCM_RIGHTS` 传 fd + 日志分级 helper | 旧 80+82+83 |
| `src/bsh_box64_entry.c` | procmgr 的入口包装：`int(*)(int,char**)` → `box64_run(argc, argv, environ)`，并显式 `visibility("default")`（CMake 全局 `-fvisibility=hidden` 会盖掉 target 上的设置） | 原由 build 脚本 heredoc 生成，现固化在这里 |

> `bsh_box64_entry.c` 与它的 CMake 注册过去写在 `build_box64.sh` 第 3 步里 ——
> 现在统一归 `files/` + `0035-cmake-ohos-sources.patch`，构建脚本不再生成任何源码。

---

## 4. 构建流程

```bash
./scripts/build_box64.sh                 # 完整重建（默认先 git reset --hard + clean -fdx）
./scripts/build_box64.sh --no-reset      # 复用已就绪的源码树（认标记 .bsh-box64-patched 或 files/src/musl_compat.c）
./scripts/build_box64.sh --jobs 8
```

> `--no-reset` **不会**重新应用补丁 —— 改了补丁集就用默认路径（复位后重打）。

1. `git clone`（或复用）`thirdparty/box64`，检出钉死的 commit；
2. **复位**：`git reset --hard` + `git clean -fdx`（顺手还原 CMake 构建期重写的
   `src/wrapped*/generated/*` 与 `src/emu/x64printer.c`，以及上一步留下的标记文件）；
3. 铺 `files/` → 按 `patches/series` 逐条 `patch -p1 --forward --batch` → `touch .bsh-box64-patched`；
4. SDK cmake（`-DBOX32=ON -DARM_DYNAREC=ON -DBUILD_SHARED_LIBS=ON -DNOLOADADDR=1`）→ `ninja box64`；
5. 校验：AArch64、导出符号（`bsh_box64_entry`、`box64_run`）、NEEDED；
6. 交付到 `feature/bsh_main/libs/arm64-v8a/libbox64.so`（随 HAP 打包；hvigor 会 strip）。

---

## 5. `vendor/`

`vendor/musl-fts`、`vendor/musl-obstack` = 上游源码 + LICENSE，**只为溯源与许可**。
它们的内容已经固化进 `files/src/musl_{fts,obstack}.c` 与 `files/src/include/{fts,obstack}.h`，
**构建不再联网 clone**（旧脚本会 `git clone` 到 `build/box64/thirdparty/`）。

---

## 6. 已删除 / 不再维护的东西

| 项 | 处置 | 依据 |
|---|---|---|
| `patch_63`（wine KUSER_SHARED_DATA 留洞）、`patch_84_v2`（文件 W\|X mmap → anon+pread）、`patch_86_pe`（PE 区 mprotect 直通）、`patch_87`（PE 区匿名 RWX） | **删除** | A/B 实测：停用与启用两版，6 个组合同步日志归一化后**逐字节一致**（§8）。我们跑的是 x86_64 **Linux** ELF，不跑 Wine |
| `patch_85`（prereserve 冲突重试） | **删除** | 锚点字符串写错（找 `..._FALLBACK END`，实际标记是 `..._FALLBACK_V2 END`），**从未生效过**，删掉零行为变化 |
| `patch_68_path_remap_trace`、`patch_86_sock_send_diag` | 删除 | 定义在旧脚本里但**从未被调用**（纯 trace/dump） |
| `patch_12` 里被 28/35 覆盖的部分 | 折进 `files/src/musl_compat.c` | 同一文件的后继修改不再单独成条 |
| 旧脚本 `scripts/patch_box64.sh` | 删除 | 已被本目录取代；历史见 git |

---

## 7. 怎么验证这次重构没改行为

生成器是 `build/regen_box64_patches.sh`（**一次性工具，不入库**；它靠 `patch_box64.sh`
底部 `BSH_BOX64_SERIES_ONLY=1` 的守卫来逐组调用旧函数；旧脚本删掉后它就不能再跑了）。

它的自校验（`VERIFY=1`）做的正是这件事 —— 两棵树都从同一个 pristine commit 出发：

* **参照**：跑旧单体脚本 + 旧 build 脚本第 3 步（写 `bsh_box64_entry.c` 与它的 CMake 注册）；
* **候选**：`cp -a files/.` + 按 `series` 顺序 `patch -p1`；

然后 `git diff` 两棵树，要求**完全一致**。2026-10-03 实测：

```
[regen] ✅ 两棵树完全一致（）
```

（`generated/*` 与 `x64printer.c` 两边都没跑过 cmake，所以不需要额外排除。）

**注意：`libbox64.so` 本身不是逐字节可复现的。** 同一棵源码树、同一份补丁集连编两次，
sha256 不同（实测 `52d8506b…` vs `e8a9f171…`），但**文件大小、section 布局、导出符号地址
完全一致**（`box64_run@0x11b0f20`、`bsh_box64_entry@0x11b2f28`）。原因还没查清
（怀疑与构建期生成物或并行编译顺序有关；`PYTHONHASHSEED` 已排除，但那次实验的生成器
调用参数不对，结论不硬）。

⇒ 判断"这份 .so 是不是同一份"**别用 sha256**，用导出符号地址 + §8 的真机日志。

---

## 8. 真机验收（2026-10-03）

`rawfile/tools/autorun.sh` 跑 6 个组合（x86_64 × {musl,glibc} × {dynamic,static} +
aarch64-musl × {dynamic,static} 回归），release 构建模式 + `debug-jit` 签名，
SN `3QC0225617000597`。

**wine/PE 组 A/B**（停用 vs 启用 `63/84v2/86_pe/87`）：6 份日志归一化后逐字节一致
→ 删除。原始日志留档在 `build/experiment/{nowine,withwine}/`。

**重构后的回归**（新流程重编的 `libbox64.so` + 重打 HAP + 重装 + 同一份 autorun）：
6 份日志与重构前的「停用版」**逐字节一致**（`build/experiment/refactor/`），
导出符号地址也完全相同（`box64_run@0x11b0f20`、`bsh_box64_entry@0x11b2f28`）
→ 这次重构没有改变任何行为。

**既有问题（三组都一样，与本次删除/重构无关，另行处理）**：

1. x86_64 **static** 两个组合在 `[signal]` 块 SIGSEGV（rc=139）——该块只做
   `sigaction(SIGUSR1)` + `kill(getpid())` + handler。
2. x86_64 **dynamic** 两个组合跑完全套后卡在最后一块 `t_exec_self_inplace()`
   （原地 exec 自己替换镜像），只能靠 `toybox timeout` 收场（rc=124）。
3. x86_64 组合从来不是"全绿"：`symlink` 的用户态模拟只做在 elfloader 的 shim 里，
   box64 这条路没有 → `symlink/lstat/readlink/pty/auxv(ENTRY=0x0)` 一直是 FAIL。

---

## 9. 踩坑记录

* **`patch -p1` 而不是 `git apply`**：box64 源码落在本仓库工作区（`thirdparty/box64`，
  gitignored），`git apply` 会从仓库根解析路径，可能"返回 0 却一个 hunk 都没打上"
  （同 `scripts/jdk-ohos/README.md` 的 P0）。
* **生成物绝不能进补丁**：CMake 构建期 `rebuild_wrappers{,_32}.py` 会重写
  `src/wrapped/generated/*`、`src/wrapped32/generated/*`、`src/emu/x64printer.c`
  （后者的文件头写着 "automatically generated by rebuild_wrappers.py"，但在
  `generated/` 之外，最容易漏）。判别法：干净构建后 `git diff --name-only` 里凡是
  旧补丁脚本从未提及的文件就是生成物 —— 实测正好 8 个。
* **`patch_85` 的教训**：它的 guard 找 `OHOS_PATCH_MAP_FIXED_WX_FALLBACK END`，
  而 `84_v2` 写进去的标记是 `..._FALLBACK_V2 END`，两个字符串互不包含 →
  每次静默 "(skip) patch 84 not applied yet"，一年都没人发现。改多补丁形态之后，
  补丁应用失败会直接 `err` 退出，不再有这种"静默跳过"。
* **`cp -a` 覆盖只读文件会 Permission denied**：生成 `vendor/` 时踩到
  （上游 checkout 的文件是 444）；现在先 `rm -rf` 再按名单 `cp`（只留 4 个源文件 + 许可）。
* **逐条 `patch -R --dry-run` 判"已打过"在本系列不可用**：35 条里有 10 条以上改同一个
  文件（`src/wrapped/wrappedlibc.c` 被 0006/0007/0013/0028…0034 反复改），后一条会把
  前一条的部分行再改一遍 —— 实测 35 条里有 **11 条**反向试打失败，会被误判成"没打过"
  再打一遍然后报错。幂等改成一个标记文件（`.bsh-box64-patched`，`git clean -fdx` 会删）。

---

## 10. 升级 box64 版本怎么办

补丁全部贴着 `befc90de1` 写，**换版本必然大量失配**。步骤：

1. 改 `scripts/build_box64.sh` 里的 `BOX64_COMMIT`；
2. 逐条试打：`cd thirdparty/box64 && patch -p1 --dry-run < ../scripts/box64-ohos/patches/NNNN-*.patch`
   （或直接跑构建脚本，看它是哪一条 `err`）；
3. 冲突按补丁头部的说明（原语义见 git 历史里的 `scripts/patch_box64.sh`）手工 rebase，
   重新生成该条的上下文；
4. `files/` 里的新文件多数与版本无关，但 `src/wrapped2/wrappedlibc_private.h` 相关的
   包装器改动（0024/0025/0029/0030）依赖上游的 `GO/GOW` 宏表，最容易失配；
5. 重新跑 §7 的等价性流程没有意义（参照系已经变了），改为直接真机跑 §8 的 6 个组合。

---

## 11. box64 内置 shim（0036 / 0037）—— 让 **guest** 也拿到软链模拟

### 为什么要有这一节

沙箱禁 `symlink(2)`，elfloader 那侧的解法是 `feature/bsh_main/src/main/cpp/shim/` 那套用户态软链
（`foo -> t` 表示成普通文件 `foo.BSH_SYMLINK`）。但**那套 shim 到不了 box64 的 guest**：

* guest 侧（LD_PRELOAD）要 `exec` 才有 ld.so —— box64 沙箱里没有；
* 命令 so 侧（`-Wl,--wrap=`）只改写**本 so 自己**的符号引用，而 guest 的 libc 调用走的是
  box64 的 wrapped-libc 层（`my_*`），静态 guest 更是直接发裸 `syscall`。

结果就是 `scripts/box64-ohos/README.md` 之前记的那句"软链模拟只做在 elfloader 里"——
testprogs 的 x86_64 组合里 `symlink/lstat/readlink/stat` 四条一直 FAIL。

### 做法：同一份源码，第三种装配模式

`shim/shim_wrap.h` 里加了 `-DBSH_SHIM_BOX64`：

| 模式 | `BSH_EXPORT(name)` | `BSH_REAL(ptr, name)` |
|---|---|---|
| guest 预载 | `name`（符号插入） | `dlsym(RTLD_NEXT, name)` |
| 命令 so | `__wrap_name` | 链接器给的 `__real_name` |
| **box64 内部** | `bsh_fs_##name` | **直接引用 `name`**（box64 就活在宿主进程里，不存在搜索序问题） |

于是 `shim/fs_shim.c` **原样**编进 `libbox64.so`，box64 的 `my_*` 显式调用 `bsh_fs_*`：

* 编译：`scripts/build_box64.sh` 传 `-DBSH_SHIM_DIR=<主仓库>/feature/bsh_main/src/main/cpp/shim`，
  CMake（0035 末尾那段）把它 `target_sources` 进来并加 `target_include_directories`；
* **不复制源码**：shim 只有一份，两个消费者共用（改一个 bug 两边都受益）。

### 挂钩点（`my_*` → `bsh_fs_*`）

| 补丁 | 挂了哪些入口 |
|---|---|
| `0036-shim-fs-hooks.patch` | `my_lstat`、`my_stat`、`my_fstatat`、`my_readlink`、`my_readlinkat`、`my_open`/`my_open64`（在 path remap 之后再逐段展开标记）、`my_symlink`/`my_symlinkat`（把 0030 的"假成功"换成真标记文件） |
| `0037-shim-fs-hooks2.patch` | `my_fopen`/`my_fopen64`（fopen 不走 open 符号，必须单独接）、`my_unlink`、`my_rename`、`my_access`、`my_faccessat`、`my_opendir`、`my_readdir`（列目录时把 `x.BSH_SYMLINK` 就地改回 `x`） |
| `0038-shim-fs-syscall.patch` | **静态 guest 的裸 syscall**（`src/emu/x64syscall.c`）：`case 88 symlink`、`case 87 unlink`、`case 257 openat`（原来直接发宿主 syscall，绕过 path remap 与软链展开） |
| `0039-shim-uname.patch` | `my_uname` + syscall `case 63`：`sysname` 报 `"Linux"`（内核报 `"HarmonyOS"`，工具链的 `isLinux()` 会走错分支）；`BSH_UNAME_REAL` 可看真值 |
| `0040-shim-openat.patch` | `my_openat` 补上软链展开 —— 静态 glibc guest 的 `fopen` 走 `openat`，不补这处就"读穿链接得到空内容" |

> `my_symlink` 的旧实现（`return 0` 的假成功）在 0036 里被替换掉，注释一并更新 ——
> 被它坑出来的三条 FAIL 就是这么来的。

### 0041：禁掉 box64 对 guest 镜像的"文件可执行映射"（消掉弹窗）

**症状**：跑任何 x86_64 guest，系统都会弹一次「是否运行 <guest 文件>」确认框；不点的话
30 秒后按拒绝，guest 仍然能跑（所以以前一直没当致命问题）。

**根因**：`src/elfs/elfloader.c` 的 `AllocLoadElfMemory()` 对每个 `PT_LOAD` 段先试
"从文件 `mmap`"（`MAP_PRIVATE|MAP_FIXED`，PF_X 段带 `PROT_EXEC`，`:321`）。这一步就是
**"把非系统文件映射成可执行"**，正是 OHOS seccomp 用户确认闸拦的动作（见
`scripts/glibc-ohos/README.md` §8）→ 弹窗 → 拒绝 = `EACCES` → box64 落到它自己的兜底路径
"匿名映射 + `fread`"（`:340`）继续把活干完。

**修法**：`try_mmap = 0;`（0041）—— 强制走兜底路径。语义完全等价（同一份字节、同样的段
权限、同样走 `setProtection_elf`），代价是加载时多一次内存拷贝。主镜像 / 解释器 / guest 的
`.so` 都经过这一个函数，所以一处改动全覆盖；顺带也不再怕 guest 落在 noexec 挂载上。

**怎么确认修好了**（2026-10-03 实测）：同一份 autorun（6 组合）**从 306 秒降到 7 秒**
（`build/experiment/shimfs/autorun.log` 09:38:05→09:43:11 vs `shimfs5/autorun.log`
10:54:29→10:54:36）—— 300 秒的差正好是"十来次 × 30 秒弹窗超时"。顺带把之前误判成
"卡在最后一块 `exec 自己替换镜像`（rc=124）"的现象也解释掉了：那不是死锁，就是这些
30 秒堆起来把 `toybox timeout 120` 撑爆了；现在两个 dynamic 组合都以 **rc=42** 正常收尾
（guest 自己 exec 自己、子模式退出 42 ✔），6 组合的**输出内容与改动前逐条一致**。

> 唯一还留在我们管不到的地方的是：**guest 自己**去 `mmap(文件, PROT_EXEC)`
> （`my_mmap64` → 宿主 mmap）。正常 Linux 程序极少这么干（加载器和 JIT 才做），
> 我们的 testprogs 也不做；真遇到时按同一招数在 `my_mmap64` 里改成匿名 + `pread`
> 即可（早先的 patch 84v2 就是那个思路，只是当时只在 `EINVAL` 上触发）。

### 0042：tty shim 也进 box64（P5）

**为什么需要**：会话终端是 socketpair，宿主这一侧 `isatty` 恒 0、`TCGETS`/`TIOCGWINSZ`
必失败 —— guest 里 vim/mksh 那一类"我是不是终端"的判断全走错分支（`/dev/tty` 也是）。

**做了什么**（同一套 box64 模式，`shim/tty_shim.c` + `procmgr/bsh_client.c` 一起编进来）：

| 位置 | 改动 |
|---|---|
| `shim_wrap.h` | box64 模式的前缀改成**按模块可配**（`BSH_SHIM_PREFIX`，CMake 里 `set_source_files_properties` 给 `fs_shim.c`→`bsh_fs_`、`tty_shim.c`→`bsh_tty_`）。原先写死 `bsh_fs_` 会撞名 —— 两个模块都定义了 `open`，链接期直接 `duplicate symbol bsh_fs_open` |
| `wrappedlibc.c` | 新增 `my_isatty`/`my_tcgetattr`/`my_tcsetattr`（转 `bsh_tty_*`）；aarch64 上**补了一个 `my_ioctl`**（上游那份被 `#ifdef PPC64LE` 包着，aarch64 的 ioctl 本来是直通宿主的）；`my_fcntl64` 改走 `bsh_tty_fcntl`（`F_DUPFD` 时把副本也登记成 tty）；`my_open`/`my_open64`/`my_openat` 开头先问 `bsh_tty_maybe_open()`（处理 `/dev/tty`，不归它管时返回 -2 照旧落下去） |
| `wrappedlibc_private.h` | `GOW(isatty,iFi)` → `GOM(isatty,iFEi)`、`GOW(tcgetattr,iFip)` → `GOM(...iFEip)`、`GO(tcsetattr,iFiip)` → `GOM(...iFEiip)`；`GOWM(ioctl, iFEiLp)` 本来就写着 my 版本，现在 aarch64 上终于解析得到 |
| CMake（0035） | `tty_shim.c` + `bsh_client.c` 一起编译，include 目录加上 `procmgr/`（`bsh_client.*` 纯 socket，无额外依赖） |

procmgr 侧**不用改**：`BSH_TTY_STDIO`（ForkChild 按 stdio 是不是 socket 设）与
`BSH_CTRL_SOCK` 都已经给所有子进程设好了。

**验证到哪一步了**（2026-10-03）：

* **接线已证**：临时在 `my_isatty` 里打了一行 trace，自检日志里确实出现在 0/1/2 三个 fd 上
  （`[tty] my_isatty(0) = 0  BSH_TTY_STDIO=(unset)`）→ hook 真的被调到，不是静默走宿主。
  （trace 已撤。）
* **harness 里验不出"是终端"那条路**：autorun 把 guest 的 stdio 重定向到文件，`BSH_TTY_STDIO`
  因此没设，`isatty=0` 恰恰是**正确答案**（testprogs 的 tty 块按设计 SKIP）。
  要看到 `isatty(0)=1` 必须在**交互终端**里跑（那里 stdio 是会话 socketpair）。
* 判据：在 BetterSH 终端里跑 `./x86_64-musl-dynamic`，看输出末尾的
  `tty（会话给的 stdio）` 块 —— 期望 `isatty(0/1/2) = 1`、`tcgetattr(0) ok`、
  `TIOCGWINSZ(0) = N 行 × N 列`、`PASS isatty(0)=1 且 tcgetattr(0) 成功`；
  `open("/dev/tty")` 也应成功（0042 的 open 钩子）。

### 0043：假 pts 也进 box64（P6，用户拍板"只做 A"）

**先说结论**：**真 pty 在这个沙箱里拿不到**。同一轮自检里两个上下文正好对照 ——
x86_64（box64 的 `open()` 直达宿主，没有任何 shim 拦 `/dev/ptmx`）拿到 `EACCES`，
而 aarch64（elfloader guest shim，编了 `pty_shim.c`）能拿到 fd —— 后者是**用户态的
socketpair 假 pts**，不是内核 pty。procmgr 走同一条路也不会有不同结果：它和子进程同属
一个应用进程族，seccomp 过滤器 fork 继承、LSM 上下文相同。所以"procmgr 侧开真 pty +
`SCM_RIGHTS` 传回来"这条路**不成立**（原先的 P6 方案就是建立在它之上的，我漏看了文档里
"三层都拿不到 `/dev/ptmx`"那句）。

于是按用户决定做 A：**把 `pty_shim.c` 也编进 box64**，让 x86_64 guest 与 aarch64 guest
拿到同一份、同语义的假 pts。

| 位置 | 改动 |
|---|---|
| `shim/shim_wrap.h` | 新增 `BSH_PLAIN(name)`：box64 模式下把这些"本来写真名"的入口也加上前缀（其余模式保持真名）。不加的话 libbox64.so 会导出 `grantpt`/`close` 这些名字，**插到宿主 libc 上** |
| `shim/pty_shim.c` | `grantpt/unlockpt/ptsname/ptsname_r/close` 改用 `BSH_PLAIN`；`REAL1` 宏按模式切（box64 直接引用宿主符号）；补 `#include "shim_wrap.h"` |
| `shim/tty_shim.c` | `ttyname()` 里对**自己** `ttyname_r` 的调用改成 `BSH_EXPORT(ttyname_r)`（box64 模式下它叫 `bsh_tty_ttyname_r`，裸写会落到宿主 libc → `ttyname=(null)`） |
| CMake（0035） | `pty_shim.c` 以 `BSH_SHIM_PREFIX=bsh_pty_` + **`BSH_SHIM_MERGED_OPEN`** 编译（后者必须带，见下） |
| `wrappedlibc.c`（0043） | 新增 `my_grantpt`/`my_unlockpt`/`my_ptsname`/`my_ptsname_r`/`my_ttyname`/`my_ttyname_r`/`my_close`；表项 `GO/GOW` → `GOM`（否则它们直通宿主，对假 master 只报 ENOTTY） |
| `procmgr.cpp` | `ForkChild` 里加 `setenv("BSH_FAKE_PTY","1")` —— 假 pts 的总开关。elfloader 那条路本来就有（LD_PRELOAD 段里设），box64 这条 kSoMain 路没有 LD_PRELOAD，得靠这里 |

**踩到的两个坑**（都值得记）：

1. **`pty_shim.c` 末尾那段"本机自测用"的替身必须排除**：它定义的是**真名**
   （`open`/`openat`/`ioctl`/`isatty`/`ttyname`/`ttyname_r`），编进 libbox64.so 后会在
   **so 内部**插到宿主同名符号上 —— box64 自己的 `open`/`ioctl` 调用全被劫走。实测症状：
   x86_64 四个组合**全部 SIGSEGV**（日志恰好停在 tty 块）。带 `-DBSH_SHIM_MERGED_OPEN`
   让那段整段不编就好了。
2. **shim 内部自调要经 `BSH_EXPORT`**：`ttyname()` → `ttyname_r()` 在 box64 模式下
   名字对不上，落到宿主 libc，`ttyname(slave)` 返回 NULL（其余全对，就这一条 FAIL）。

**验收**（2026-10-03）：x86_64 两个 dynamic 组合的 pty 块现在与 aarch64 **一字不差**：

```
│  [INFO] open(/dev/ptmx) ok, master fd=5
│  [INFO] slave = /dev/pts/0
│  [INFO] isatty(slave)=1 tcgetattr=1 tcsetattr=1 ttyname=/dev/pts/0 open(/dev/tty)=8
│  [PASS] guest 能自建 pty 并设成控制终端
```

| 组合 | 之前 | 现在 |
|---|---|---|
| x86_64-musl-dynamic | 26 / 4 | **27 / 3** |
| x86_64-glibc-dynamic | 25 / 5 | **26 / 4** |
| aarch64-musl-dynamic（对照） | 29 / 1 | **29 / 1（逐字节一致）** |

剩下的 x86_64 FAIL 只有：`创建硬链接`（release 模式真禁 `link(2)`）、
`auxv ENTRY=0x0`、`子进程退出码或管道内容不对`、glibc 独有的 `exec 兄弟程序失败(139)`。

### 还没挂的（后续）

* **tty（P5）**：`isatty`/`tcgetattr`/`tcsetattr`/`ioctl`/`tcgetpgrp`/`ttyname` 现在全是
  `GO/GOW`（直通宿主）—— 而我们的会话终端是 socketpair，宿主看就是"不是 tty"。要做的是把
  `shim/tty_shim.c` 也用 `-DBSH_SHIM_BOX64` 编进来（同一招，入口前缀 `bsh_tty_*`），并把
  `procmgr/bsh_client.c` 一起编进去（它只依赖 socket，走 `BSH_CTRL_SOCK` RPC）。
  procmgr 侧不用改：`BSH_TTY_STDIO`（ForkChild 按 stdio 是不是 socket 设）与
  `BSH_CTRL_SOCK` 都已经给所有子进程设了。
  * ⚠ `isatty`/`tcgetattr`/`tcsetattr` 要改表项才能挂：`GOW(isatty,iFi)` → `GOM(isatty,iFEi)`，
    `GOW(tcgetattr,iFip)` → `GOM(...)`，`GO(tcsetattr,iFiip)` → `GOM(...)`。
  * ⚠ `my_ioctl` **只在 PPC64LE 下编**（`#ifdef` 包着，见 `wrappedlibc.c:1072`），aarch64 上
    ioctl 走的是 `GOW(ioctl, iFiLN)` 直通宿主 —— 想挂 tty 的 ioctl 得先给 aarch64 补一个
    `my_ioctl`（内部转 `bsh_tty_ioctl`，非 tty 再退宿主 ioctl）。
  * ⚠ `bsh_client.c` 把 `struct termios` 原样发过去、服务端硬校验长度；x86_64 guest 与
    aarch64 宿主都是 60 字节是**巧合**，挂之前要显式校验/转换。
* **pty（P6）**：按已定方向做"**真 pty**"—— procmgr 侧开真 pty，用 `SCM_RIGHTS` 把 fd 传回来
  （`files/src/box64_spawn.c` 里那条 fd 传递路径可以复用），而不是照搬 elfloader 的
  socketpair 假 pts。
* `unlinkat`/`renameat`/`scandir`/`link` 一族：表项还是 `GO/GOW`（直通宿主），要改成
  `GOM` 才能挂。
* `getdents64`（syscall 217）：静态 guest 的目录列举走 `syscallwrap` 表的裸 syscall，
  `x.BSH_SYMLINK` 会原样露出去；要按 guest 缓冲里的 dirent 布局就地改名。
* `statx`：建议一律 `ENOSYS`，逼 libuv 那类"裸 syscall statx"的调用方退回被 hook 的
  `lstat`/`fstatat`（fs_shim 在 elfloader 侧就是这么做的）。
* **x64syscall 的第二处 switch**（32 位 / BOX32 路径，`x64syscall.c:1197` 一带）还没挂。

### 验收（2026-10-03，P1–P4 实测）

`rawfile/tools/autorun.sh` 跑 6 组合，与 `build/experiment/refactor/` 的基线逐条比
（原始日志：`build/experiment/shimfs{2,3,4}/`）：

| 组合 | 基线 | 现在 | 软链块 |
|---|---|---|---|
| x86_64-musl-dynamic | 25 pass / 7 fail | **26 / 4** | ✅ `symlink/lstat/readlink/stat` 全 PASS |
| x86_64-glibc-dynamic | 24 / 8 | **25 / 5** | ✅ 同上 |
| x86_64-musl-static | 15 pass 后崩在 `[signal]` | 同（崩点不变） | ✅ 软链块全 PASS |
| x86_64-glibc-static | 同上 | 同 | ✅ 软链块全 PASS |
| aarch64-musl-dynamic | 29 / 1 | **29 / 1** | 无变化（elfloader 路径无回归） |
| aarch64-musl-static | 22 / 7 | **22 / 7** | 无变化 |

剩下的 x86_64 FAIL（都不是这次引入的）：`创建硬链接`（真沙箱缺口，release 模式禁 `link(2)`）、
`拿不到 pty`（P6）、`auxv 不自洽 ENTRY=0x0`、`子进程退出码或管道内容不对`、
`exec 兄弟程序失败(139)`（glibc 组合独有）。
