#!/bin/bash
# shim-wrap-flags.sh — 命令 so 链接时要用的一串 `-Wl,--wrap=`（**一份清单，别处各抄一遍**）
#
# 为什么用 --wrap（而不是符号插入）：命令 so 是主进程 dlopen 进来的、排在全局搜索序
# **末尾**，`dlsym(RTLD_NEXT)` 之后没有对象 → 拿不到真实现（实测把 fs_shim 原样编进
# libtoybox 后，每个文件操作都变成 ENOSYS：`Function not implemented`）。
# `--wrap=<名>` 是**链接期**替换：该 so 自己对这些符号的引用被改写成 `__wrap_<名>`，
# 真实现由链接器生成 `__real_<名>`（对 libc 的直接引用，与搜索序无关）。与
# shim/exec_shim.c（带 -DBSH_SHIM_WRAP）处理 exec 家族是同一招。
#
# ⚠⚠ `--wrap=<名>` 要求 `__wrap_<名>` **必须在这个 so 的链接里存在**，否则不是"静默
# 失效"而是 **dlopen 直接失败**（整个命令用不了）。实测两种踩法：
#   - toybox 只链了 fs_shim，却把 tty 的 isatty 也 wrap：
#       `Error relocating libtoybox.so: __wrap_isatty: symbol not found`
#   - 把 glibc 专属名字（open64/…_chk/__xstat）也 wrap（musl 分支里没定义它们）：
#     libvim.so 上 11 个未定义 `__wrap_*`；
#   - **清单根本没传进链接行**（脚本改漏了）：定义都在、也没有未定义 `__wrap_*`，
#     但我们的兜底引用 `__real_*` **没人改回真名** → dlopen 报 `__real_lstat: symbol
#     not found`（zip/unzip/sshcore/python 四个就这么漏过去过）。
#     所以判据要看两条：`nm -D -u <so> | grep -E '__wrap_|__real_'` **都必须为空** ——
#     scripts/build_hap.sh 在打包前会统一查这一条，不通过就不让打包。
# 所以规矩是：**命令 so 都链同一套 shim（fs + tty + open_shim），清单也就只有这一份** ——
# 清单与 .o 永远一起出现，上面那类错误不可能再发生。
#
# todo
# 唯一的例外曾是 **westterm**：它自己那份 `tty/bsh_pty.c` 定义了 `__wrap_ioctl`
# （weston-terminal 的 pty 用），与 tty_shim 的 ioctl 入口会撞。现在 weston-terminal
# 改成 **guest 可执行**（不再走命令 so / dlopen 这条链），它只在自己的链接行里
# `--wrap=forkpty,ioctl,read`，**不使用**这份清单，所以冲突面自然消失。
#
# 用法：
#     source "$SCRIPT_DIR/shim-wrap-flags.sh"
#     $CC ... -DBSH_SHIM_WRAP -DBSH_SHIM_MERGED_OPEN -c "$SHIM_SRC_DIR/{fs,tty,open}_shim.c" ...
#     $CC ... -shared ... "$FS_OBJ" "$TTY_OBJ" "$OPEN_OBJ" $SHIM_WRAP_FLAGS ...
#   （-DBSH_SHIM_MERGED_OPEN：tty 与 fs 都想定义 open，让两边让位、由 open_shim.c 提供唯一入口）

# shim 源码目录（各脚本不用再自己拼）
SHIM_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../feature/bsh_main/src/main/cpp/shim" && pwd)"

_shim_flags() {   # 符号列表 → -Wl,--wrap= 串
    local out="" s
    for s in $1; do out="$out -Wl,--wrap=$s"; done
    printf '%s' "$out"
}

# 全部入口 = fs_shim ∪ tty_shim（`open` 两组都有，去重后只列一次；它由 open_shim.c 定义）
#
# 注：fs_shim 在 **glibc** 下还多一批入口（open64/openat64/readdir64/fopen64/freopen64、
# `__*_chk`、`__open_2/__open64_2/__openat_2/__openat64_2`、`__xstat/__lxstat`）。当前
# **没有** glibc 链的命令 so（命令 so 全是 OHOS/musl），所以不列进来 —— 真要加 glibc 链的
# 命令 so 时，把那批名字补进下面这个列表即可。
SHIM_WRAP_FLAGS="$(_shim_flags "
symlink symlinkat readlink readlinkat lstat stat fstatat
open openat unlink unlinkat rename renameat
access faccessat realpath link linkat opendir readdir scandir
fopen freopen
syscall
isatty tcgetattr tcsetattr ioctl fcntl tcgetpgrp tcsetpgrp ttyname ttyname_r
")"

# exec 家族与退出口：入口在 shim/exec_shim.c（编译时带 -DBSH_SHIM_WRAP）。
#   execve/execv/execvp/execl/execlp  —— 内部 exec 别的程序（python -c 的 subprocess、
#                                        toybox timeout/xargs、clang 起 cc1…）
#   execvpe/posix_spawn/posix_spawnp  —— 同类入口，定义都在，wrap 了也不会没定义
#   exit                              —— 退出码透传（见 exec_shim.c 里 __wrap_exit 的注释：
#                                        guest 调 libc exit() 会把退出码丢成 0）
SHIM_WRAP_FLAGS="$SHIM_WRAP_FLAGS$(_shim_flags "
execve execv execvp execvpe execl execlp posix_spawn posix_spawnp exit
")"
