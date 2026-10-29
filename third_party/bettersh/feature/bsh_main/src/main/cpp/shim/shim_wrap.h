// shim/shim_wrap.h — 同一份 shim 源码的两种"被调用"方式
//
// shim 家族（tty/fs/pty/exec/open）要服务两种消费者，它们的"怎么被调用"完全不同：
//
//   guest 侧（LD_PRELOAD）：靠**符号插入** —— 我们导出 `open`/`stat`/… 这些名字，
//     ld.so 把 guest 里对它们的引用交给我们。真实现用 `dlsym(RTLD_NEXT, …)` 取
//     （预载把本 .so 放在搜索序**最前**，"下一个"就是 libc）。
//
//   命令 so 侧（链接期编进 libtoybox.so 等）：用 **`-Wl,--wrap=<名>`** —— 链接器把
//     该 so **自己**对这些符号的引用改写成 `__wrap_<名>`，真实现则由链接器生成
//     `__real_<名>`（对 libc 的直接引用）。这与 `shim/exec_shim.c`（带 `-DBSH_SHIM_WRAP`）
//     处理 exec 家族是同一招，也是命令 so 唯一靠谱的招：它由主进程 `dlopen` 进来、排在全局搜索序
//     **末尾**，`dlsym(RTLD_NEXT, …)` 之后没有对象 → 返回 NULL（实测把 fs_shim 原样
//     编进 libtoybox 后，每个文件操作都变成 ENOSYS，"Function not implemented"）；
//     而 `--wrap` 是链接期的直接引用，跟搜索序无关。
//
// 所以导出名按模式切一下就够了：`-DBSH_SHIM_WRAP` 让入口变成 `__wrap_*`。
// 各命令 so 的构建脚本从 scripts/shim-wrap-flags.sh 取 `-Wl,--wrap=…` 列表（一份清单，
// 免得七处各写一遍）。
#pragma once

#if defined(BSH_SHIM_BOX64)
// ── 第三种消费者：box64 内部（`-DBSH_SHIM_BOX64`，见 scripts/box64-ohos/）──────
//
// box64 要修的不是"box64 自己怎么调 libc"，而是"**guest 程序看到的 libc 语义**"：
// 那条路走 box64 自己的 wrapped-libc 层（`my_open`/`my_lstat`/…）和
// `src/emu/x64syscall.c` 的 syscall 分发。所以既不能用符号插入，也不能用
// `-Wl,--wrap=`（wrap 只改写**本 so 自己**的符号引用，碰不到 guest 那一侧），
// 而是把本模块编进 libbox64.so，由 box64 的 `my_*` **显式调用**下面这些入口：
//
//   入口加前缀：既避免和宿主 libc 同名（会撞），也避免和 box64 自己的 `my_*` 撞；
//   真实现直接写符号名即可 —— box64 本来就活在宿主进程里，不存在"搜索序"问题，
//   等价于 wrap 模式的 `__real_<name>`。
//
// ⚠ 前缀**按模块**给（CMake 里 `set_source_files_properties` 各配一个）：
//   fs_shim.c  → bsh_fs_     tty_shim.c → bsh_tty_
//   少了这一层就会撞 —— 两个模块都定义了 `open`（实测链接期
//   "duplicate symbol bsh_fs_open"）。没配前缀时用中性默认值，至少不会撞 libc。
#ifndef BSH_SHIM_PREFIX
#define BSH_SHIM_PREFIX bsh_shim_
#endif
#define BSH_SHIM_CAT_(a, b) a##b
#define BSH_SHIM_CAT(a, b)  BSH_SHIM_CAT_(a, b)
#define BSH_EXPORT(name) BSH_SHIM_CAT(BSH_SHIM_PREFIX, name)
#define BSH_REAL(ptr, name) ((ptr) != NULL ? (ptr) : ((ptr) = (__typeof__(ptr))name))
#elif defined(BSH_SHIM_WRAP)
#define BSH_EXPORT(name) __wrap_##name
#define BSH_REAL(ptr, name) ((ptr) != NULL ? (ptr) : ((ptr) = (__typeof__(ptr))shim_real_##name))
#else
#define BSH_EXPORT(name) name
#define BSH_REAL(ptr, name) ((ptr) != NULL ? (ptr) : ((ptr) = (__typeof__(ptr))dlsym(RTLD_NEXT, #name)))
#endif

// ── BSH_PLAIN：给"本来就写真名"的入口用（pty_shim.c 的 grantpt/unlockpt/ptsname/
// ptsname_r/close —— 它们靠 LD_PRELOAD 符号插入，所以写的是真名而不是 BSH_EXPORT）。
//
// box64 模式必须把它们也加上前缀：否则 libbox64.so 会导出 `grantpt`/`close` 这些名字，
// **插到宿主 libc 上**，影响整个进程（连主进程自己那些调用也会被改），正是我们一直
// 避免的全局副作用。其余两种模式保持真名不变。
#if defined(BSH_SHIM_BOX64)
#define BSH_PLAIN(name) BSH_SHIM_CAT(BSH_SHIM_PREFIX, name)
#else
#define BSH_PLAIN(name) name
#endif
