// shim/open_shim.c — guest shim 里**唯一**的 open 入口
//
// 为什么需要这个文件：guest shim 由两个模块拼起来，两边都想接管 `open` ——
//   shim/tty_shim.c         要处理 "/dev/tty"（控制终端语义：复制 stdin 并保留 tty 身份）
//   shim/fs_shim.c    要处理软链接模拟（.BSH_SYMLINK 表示法 + O_NOFOLLOW 的 ELOOP）
// 一个 .so 里只能有一个 open 定义，所以两边各自把实现往外让一步（`#ifndef
// BSH_SHIM_MERGED_OPEN`），由这里按顺序调：
//
//   1) 先问 tty 的钩子（只有 "/dev/tty" 且当前 fd 被登记为 tty 才接手）；
//   2) 否则交给 fs 模块的 bsh_fs_do_open()：它做软链解析，然后落到真实的 openat。
//
// 顺序不能反：/dev/tty 在沙箱里根本打不开（实测 EACCES/ENXIO），先让 tty 钩子接住
// 才不会掉进 fs 那套"路径不存在"的判断里。
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

#include "shim_wrap.h"

/* 装载横幅：`BSH_SHIM_VERBOSE=1` 时打一行，回答"shim 到底被载进来了没有"。
 *
 * 为什么需要：guest 侧 shim 走 LD_PRELOAD，而 musl 的 load_preload() 对加载失败是
 * **静默跳过**（不看返回值、不打印），宿主侧又只能证明"环境变量设了、文件在那儿"。
 * 于是"拦截全不生效"这个症状同时对应两种完全不同的病因 —— 压根没载上（libc 丢掉了
 * LD_PRELOAD / 装载失败）还是载上了但没拦住 —— 光看 guest 的输出分不出来，而分清
 * 这两件事要重打一次包、装一次包。这一行横幅把它们分开。
 * 默认不打印：每个 guest 都多一行 stderr 噪音不合适。放在 open_shim.c 是因为它
 * **两份（musl/glibc）都编**，一行横幅管两边。 */
__attribute__((constructor)) static void bsh_shim_banner(void)
{
    if (!getenv("BSH_SHIM_VERBOSE")) return;
    char buf[192];
    int n = snprintf(buf, sizeof buf,
                     "[shim] loaded pid=%ld fake_pty=%s exec_shim=%s tty_stdio=%s\n",
                     (long)getpid(),
                     getenv("BSH_FAKE_PTY") ? getenv("BSH_FAKE_PTY") : "-",
                     getenv("BSH_EXEC_SHIM") ? getenv("BSH_EXEC_SHIM") : "-",
                     getenv("BSH_TTY_STDIO") ? getenv("BSH_TTY_STDIO") : "-");
    if (n > (int)sizeof buf) n = (int)sizeof buf;   /* snprintf 返回"本可以写多长" */
    if (n > 0) (void)write(2, buf, (size_t)n);
}

/* shim/tty_shim.c：>=0 表示已处理；-2 表示不归它管 */
extern int bsh_tty_maybe_open(const char* path);
/* shim/fs_shim.c：软链解析 + 真 openat */
extern int bsh_fs_do_open(int dirfd, const char* path, int flags, mode_t mode);

int BSH_EXPORT(open)(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    int t = bsh_tty_maybe_open(path);
    if (t != -2) return t;
    return bsh_fs_do_open(AT_FDCWD, path, flags, mode);
}
