// shim/tty_shim.c — 编译进"全屏型"命令 so(如 libvim.so),让命令以为自己在真 tty 上。
//
// 与命令 so 的其余部分一样,这里**不链接宿主**。拆成两半:
//
//   1) fd 身份(本地):哪些 fd 是会话 tty。fd 号只在进程内有意义,主进程无从判断,
//      所以这张表必须在本地 —— 它由 procmgr spawn 时设的 BSH_TTY_STDIO 环境变量
//      懒加载初始化(procmgr 判断 stdio 是软 tty 时才设),open("/dev/tty") 与
//      fcntl(F_DUPFD) 产生的副本在这里登记。
//   2) 语义状态(远端):termios/winsize/前台进程组只有主进程一份真相,读写经
//      control socket(bsh_client.h 的 bsh_tty_remote_*)。这样命令 so 就不必
//      链接 libentry,编它也不要求先跑过一次 build_hap。
//
// 链接要求(见 scripts/build_vim.sh):
//   -Wl,-Bsymbolic-functions → so 内部对 isatty/tcgetattr/... 的调用绑定到本文件实现;
//   tty_shim.o 与命令对象一同参与 -shared 链接。
//
// 拦截点:isatty/tcgetattr/tcsetattr/ioctl/tcgetpgrp/tcsetpgrp/open/fcntl。
// 未登记为 tty 的 fd 一律回落原始 syscall。
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <sys/syscall.h>

#include "bsh_client.h"
#include "shim_wrap.h"

#define SHIM_MAX_FDS 256

static unsigned char g_is_tty[SHIM_MAX_FDS];
static int g_inited = 0;

/* 首次使用时初始化:procmgr 若把 stdio 接成了软 tty(pty slave 或 westterm 的
 * 伪 pty socket),会设 BSH_TTY_STDIO —— 据此把 0/1/2 登记为 tty。
 * 重定向到文件/管道的场合不设该变量,于是 isatty 保持为假(与真 tty 语义一致)。 */
static void shim_init(void) {
    if (g_inited) return;
    g_inited = 1;
    const char* v = getenv("BSH_TTY_STDIO");
    if (v && *v) g_is_tty[0] = g_is_tty[1] = g_is_tty[2] = 1;
}

/* 假 pty slave 的本地 termios（定义在文件尾那一段）；先声明，因为 tcgetattr/tcsetattr
 * 要在前面用到。返回 1 = 这个 fd 归它管。 */
static int fp_tcgetattr(int fd, struct termios* t);
static int fp_tcsetattr(int fd, const struct termios* t);

static int is_tty_fd(int fd) {
    shim_init();
    return fd >= 0 && fd < SHIM_MAX_FDS && g_is_tty[fd];
}

static void mark_tty_fd(int fd, int on) {
    shim_init();
    if (fd >= 0 && fd < SHIM_MAX_FDS) g_is_tty[fd] = on ? 1 : 0;
}

/* 兜底一律走原始 syscall:绕开 libc,避免符号递归 */
static long raw_ioctl(int fd, unsigned long req, void* arg) {
    return syscall(SYS_ioctl, fd, req, arg);
}

/* 收 NULL 参数时用来判断的辅助：glibc 把若干入口的指针标成 __nonnull，直接写
 * `!p` 会触发 -Wnonnull-compare；改成调用一个不内联的小函数，警告消失、检查还在。 */
static __attribute__((noinline)) int bsh_null_ptr(const void* p) { return p == NULL; }

/* pty 模块(shim/pty_shim.c)的钩子。用**弱符号**：tty_shim.c 也被编进命令 so
 * (vim/mksh/…)，那些 so 里没有 pty 模块，直接 extern 会在链接期报未定义；这里取不
 * 到就当"没有 pty 支持"跳过。合并进 guest shim 时（build_shim.sh）它们有定义。
 * 详见 shim/pty_shim.c 的头注释。 */
extern int bsh_pty_maybe_open(const char* path) __attribute__((weak));
extern int bsh_pty_ioctl(int fd, unsigned long request, void* arg, int* res) __attribute__((weak));
extern int bsh_pty_fd_name(int fd, char* buf, size_t n) __attribute__((weak));
extern int bsh_pty_is_slave(int fd) __attribute__((weak));
extern int bsh_pty_ctty_fd(void) __attribute__((weak));
/* master 侧行规程（ONLCR + ISIG）的钩子，定义在 pty_shim.c。命令 so 里没有 pty 模块，
 * 所以是弱符号：取不到就说明本进程没有假 pty master，直通即可。 */
extern int bsh_pty_is_master_fd(int fd) __attribute__((weak));
extern ssize_t bsh_pty_master_read(int fd, void* buf, size_t n,
                                   ssize_t (*real)(int, void*, size_t)) __attribute__((weak));
extern ssize_t bsh_pty_master_write(int fd, const void* buf, size_t n,
                                    ssize_t (*real)(int, const void*, size_t)) __attribute__((weak));

/* 反向导出：pty 模块打开假 pts 的 slave 后，把该 fd 交来这里登记成 tty —— 这样
 * isatty/tcgetattr/ioctl(TIOCGWINSZ) 就直接复用本文件已有的软 tty 语义，不必再实现
 * 一套（这是"假 pts"最省事的地方，也是它与真 pty 的差别之一，见 pty_shim.c）。 */
void bsh_tty_mark_fd(int fd, int on) {
    mark_tty_fd(fd, on);
}

/* /dev/tty 特例的钩子：返回 >=0 表示"我处理了，fd 在这"；返回 -2 表示"不归我管，
 * 走正常 open 流程"。
 *
 * 为什么单独抽出来：guest shim 里 tty 模块与 fs（软链模拟）模块都要接管 open，
 * 只能有一个 open 入口 —— 合并入口在 shim/open_shim.c，它先问这个钩子、
 * 再交给 fs 模块的解析（见 scripts/build_shim.sh 的 -DBSH_SHIM_MERGED_OPEN）。
 *
 * /dev/ptmx 与 /dev/pts/<N> 也在这里转给 pty 模块：open_shim.c 只把路径递进来，
 * 拿不到 flags —— 所以 O_NOCTTY 在这里无法遵守（见 pty_shim.c 的取舍）。 */
int bsh_tty_maybe_open(const char* path) {
    if (path && strcmp(path, "/dev/tty") == 0) {
        // 控制终端语义:优先用 pty 模块记下的控制终端（setsid 之后 open slave 得到的
        // 那个），没有再退回到"复制 stdin"（既有语义，命令 so 靠它）。
        int src = -1;
        if (bsh_pty_ctty_fd) src = bsh_pty_ctty_fd();
        if (src < 0 && is_tty_fd(0)) src = 0;
        if (src >= 0) {
            int cp = (int)syscall(SYS_fcntl, src, F_DUPFD, 0);
            if (cp >= 0) { mark_tty_fd(cp, 1); return cp; }
        }
        // 没有控制终端：落到下面/后面的链路（guest 里真 open 会失败，与内核一致）。
    }
    if (bsh_pty_maybe_open) {
        int r = bsh_pty_maybe_open(path);
        if (r != -2) return r;
    }
    return -2;
}

#ifndef BSH_SHIM_MERGED_OPEN
int BSH_EXPORT(open)(const char* path, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    int t = bsh_tty_maybe_open(path);
    if (t != -2) return t;
    return (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
}
#endif

int BSH_EXPORT(fcntl)(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    long arg = va_arg(ap, long);
    va_end(ap);
    if (cmd == F_DUPFD) {
        int cp = (int)syscall(SYS_fcntl, fd, cmd, arg);
        if (cp >= 0 && is_tty_fd(fd)) mark_tty_fd(cp, 1);
        return cp;
    }
    return (int)syscall(SYS_fcntl, fd, cmd, arg);
}

int BSH_EXPORT(isatty)(int fd) {
    if (is_tty_fd(fd)) return 1;
    // 假 pts 的 slave：pty 模块会把它登记进上面的表；这里再问一句，防的是登记失败
    // （fd 超出本地表）时 isatty 仍能给出正确回答。
    if (bsh_pty_is_slave && bsh_pty_is_slave(fd)) return 1;
    struct termios t;
    return raw_ioctl(fd, TCGETS, &t) == 0 ? 1 : 0;
}

int BSH_EXPORT(tcgetattr)(int fd, struct termios* t) {
    /* 假 pty 的 slave 有自己的 termios（本进程内）—— 优先于"会话那份"，否则
     * mksh 一进它的行编辑器就会把用户自己的 BetterSH 终端设成 raw。 */
    if (fp_tcgetattr(fd, t)) return 0;
    if (is_tty_fd(fd)) return bsh_tty_remote_tcgetattr(t, sizeof *t);
    return (int)raw_ioctl(fd, TCGETS, t);
}

int BSH_EXPORT(tcsetattr)(int fd, int when, const struct termios* t) {
    if (fp_tcsetattr(fd, t)) return 0;
    if (is_tty_fd(fd)) return bsh_tty_remote_tcsetattr(t, sizeof *t);
    unsigned long req = (when == TCSANOW)   ? TCSETS  :
                        (when == TCSADRAIN) ? TCSETSW : TCSETSF;
    return (int)raw_ioctl(fd, req, (void*)t);
}

/* ioctl 的第二个参数：musl 声明成 `int`，glibc 声明成 `unsigned long` —— 同一份源码
 * 要能编出两份 guest shim（musl/glibc，见 scripts/build_shim.sh），所以按头
 * 文件选类型。aarch64 上实参都走同一个寄存器，差别只在函数签名。 */
#ifdef __GLIBC__
typedef unsigned long bsh_ioctl_req_t;
#else
typedef int bsh_ioctl_req_t;
#endif

/* ⚠ 唯一的例外开关：westerm 自己那份 tty/bsh_pty.c 已经定义了 __wrap_ioctl（它的 pty
 * 实现），两边都想提供 ioctl 会**重复定义**（实测 `duplicate symbol: __wrap_ioctl`）。
 * 那个构建脚本用 -DBSH_SHIM_NO_IOCTL 关掉这里的入口 —— 代价是 westerm 里对
 * ioctl(TCGETS/TIOCGWINSZ) 的**会话**查询不再被接管（它自己那份 ioctl 只管它的 pty fd），
 * 其余（isatty/tcgetattr/tcsetattr/fcntl/…）照常生效。除它以外的命令 so 都不带这个宏。 */
#ifndef BSH_SHIM_NO_IOCTL
int BSH_EXPORT(ioctl)(int fd, bsh_ioctl_req_t request, ...) {
    va_list ap;
    va_start(ap, request);
    void* arg = va_arg(ap, void*);
    va_end(ap);

    /* 假 pty 的 termios 查询/设置也要在这里接一手：**很多程序不走 tcgetattr/tcsetattr,
     * 而是直接 ioctl(TCGETS/TCSETS)** —— mksh 的行编辑器就是（实测：只挂 tcgetattr/
     * tcsetattr 的钩子时，它一次都没被调用过，于是 mksh 的 raw 请求落到了**会话**那份
     * termios 上，既改坏了用户自己的终端，又让我们这边继续按 cooked 回显 → 命令行被
     * 回显两遍）。 */
    switch (request) {
    case TCGETS:  if (fp_tcgetattr(fd, (struct termios*)arg)) return 0; break;
    case TCSETS:
    case TCSETSW:
    case TCSETSF: if (fp_tcsetattr(fd, (const struct termios*)arg)) return 0; break;
    default: break;
    }

    // 假 pts 的专有请求先问 pty 模块（TIOCGPTN/TIOCSPTLCK 在 master 上、TIOCSCTTY 在
    // slave 上）。放在 is_tty_fd 之前是必须的：slave 已被登记成 tty，而 TIOCSCTTY
    // 不在下面的 switch 里，先走这里才不会掉进 default 被当成"软 pty 不支持"。
    if (bsh_pty_ioctl) {
        int pres = 0;
        if (bsh_pty_ioctl(fd, (unsigned long)request, arg, &pres)) return pres;
    }

    if (is_tty_fd(fd)) {
        switch (request) {
        case TIOCGWINSZ: {
            struct winsize* ws = (struct winsize*)arg;
            unsigned short r = 0, c = 0;
            if (bsh_tty_remote_get_winsize(&r, &c) < 0) return -1;
            ws->ws_row = r;
            ws->ws_col = c;
            ws->ws_xpixel = 0;
            ws->ws_ypixel = 0;
            return 0;
        }
        case TIOCSWINSZ: {
            struct winsize* ws = (struct winsize*)arg;
            return bsh_tty_remote_set_winsize(ws->ws_row, ws->ws_col);
        }
        case TCGETS: {
            struct termios* t = (struct termios*)arg;
            return bsh_tty_remote_tcgetattr(t, sizeof *t);
        }
        case TCSETS:
        case TCSETSW:
        case TCSETSF: {
            const struct termios* t = (const struct termios*)arg;
            return bsh_tty_remote_tcsetattr(t, sizeof *t);
        }
        case TIOCGPGRP: {
            /* 与 tcgetpgrp 同一条理由(见那里的注释):软 tty 不兑现"你不是前台",
             * 一律回答"问的人就是前台"。mksh 直接用 tcgetpgrp(),但别的程序(以及
             * musl 内部某些路径)会走 ioctl(TIOCGPGRP),两条入口必须一致,否则
             * 只堵住一半。 */
            *(pid_t*)arg = (pid_t)syscall(SYS_getpgid, 0);
            return 0;
        }
        case TIOCSPGRP:
            return bsh_tty_remote_set_pgrp(*(int*)arg);
        default:
            errno = ENOTTY;   /* 软 pty 不支持的 ioctl */
            return -1;
        }
    }
    return (int)raw_ioctl(fd, request, arg);
}
#endif  /* BSH_SHIM_NO_IOCTL */

pid_t BSH_EXPORT(tcgetpgrp)(int fd) {
    if (is_tty_fd(fd)) {
        /* 软 tty 没有内核那套"前后台进程组"模型,所以"谁是前台"只能给一个诚实的
         * 答案:**问的人就是前台**(自己的进程组)。
         *
         * 为什么不能照实回远端存的那个值 —— mksh 的 j_change()(jobs.c:359)里有:
         *     while (1) { if (tcgetpgrp(tty) == 本进程组) break; kill(0, SIGTTIN); }
         * 也就是说"终端的前台组不是我"会**把自己整个进程组 SIGTTIN 停住**、等被交给
         * 终端。而我们的 tcsetpgrp 是假成功的:第一个交互 shell 会把它自己的 pgrp 写
         * 进会话状态,于是同一会话里**第二个**交互 shell 一问就发现"我不是前台" →
         * kill(0, SIGTTIN) → 连应用进程组一起停住,终端假死(实测:mksh -i 起来之后
         * 再也不返回,外面的脚本也跟着卡住)。
         *
         * 我们没法真的按终端停/续一组进程,也就没法兑现"你不是前台"这句话,所以不
         * 说它。**写**那一侧(tcsetpgrp)照旧远写:宿主转发信号时还要用那个值。
         * 这也是"没有真实 pid 归属的假 tty"唯一自洽的语义 —— 每个进程都认为自己在
         * 前台,谁都不会去抢。 */
        return (pid_t)syscall(SYS_getpgid, 0);
    }
    pid_t p;
    return raw_ioctl(fd, TIOCGPGRP, &p) == 0 ? p : (pid_t)-1;
}

int BSH_EXPORT(tcsetpgrp)(int fd, pid_t pgrp) {
    if (is_tty_fd(fd)) return bsh_tty_remote_set_pgrp((int)pgrp);
    return (int)raw_ioctl(fd, TIOCSPGRP, &pgrp);
}

/* ttyname/ttyname_r —— 只为"假 pts 的 slave 也要报出 /dev/pts/<N>"这件事加。
 *
 * 为什么兜底不 dlsym(RTLD_NEXT)：tty_shim.c 也被编进命令 so，那些 so 不链接 -ldl；
 * 本文件从头到尾只用裸 syscall（见文件头注释），所以真 tty 的兜底改成读
 * /proc/self/fd/<n> 的设备路径 —— 不依赖 procfs 的场合退化成 ENOTTY，与"没接管
 * ttyname 时 libc 也拿它没辙"同一量级。
 *
 * 注意软 tty（BSH_TTY_STDIO 登记的 socketpair）不是真设备，raw_ioctl(TCGETS) 会失败，
 * 于是返回 ENOTTY / NULL —— 与改动前 libc 的行为一致，不改变既有语义。 */
int BSH_EXPORT(ttyname_r)(int fd, char* buf, size_t n) {
    if (bsh_pty_fd_name) {
        int r = bsh_pty_fd_name(fd, buf, n);
        if (r == 1) return 0;
        if (r == -1) return ERANGE;   /* 是我们的 pty，但缓冲装不下 */
    }
    struct termios t;
    if (raw_ioctl(fd, TCGETS, &t) != 0) return ENOTTY;
    char proc[48];
    int len = snprintf(proc, sizeof proc, "/proc/self/fd/%d", fd);
    if (len <= 0 || (size_t)len >= sizeof proc) return ENOTTY;
    char tmp[128];
    long k = syscall(SYS_readlinkat, AT_FDCWD, proc, tmp, sizeof tmp - 1);
    if (k <= 0) return ENODEV;
    tmp[k] = 0;
    // glibc 给 buf 标了 __nonnull，直接写 `!buf` 会触发 -Wnonnull-compare；
    // 用一个不内联的小函数做判断（与 shim/fs_shim.c 的 bsh_is_null 同套路）。
    if (bsh_null_ptr(buf)) return EINVAL;
    if ((size_t)k + 1 > n) return ERANGE;
    memcpy(buf, tmp, (size_t)k + 1);
    return 0;
}

char* BSH_EXPORT(ttyname)(int fd) {
    static char buf[128];
    /* 自调必须走 BSH_EXPORT：box64 模式下本模块的 ttyname_r 叫 bsh_tty_ttyname_r，
     * 直接写 `ttyname_r(...)` 会落到**宿主 libc** 上（对假 pts 的 slave 只会 ENOTTY，
     * 症状是 ttyname=(null)）。另两种模式下展开成 ttyname_r / __wrap_ttyname_r，都自洽。 */
    return BSH_EXPORT(ttyname_r)(fd, buf, sizeof buf) == 0 ? buf : NULL;
}

/* ═══════════════ 假 pty 的 termios（slave 侧只"记"，不处理）═══════════════
 *
 * 认领方式：环境变量 BSH_FAKE_PTY_FDS / BSH_FAKE_PTY_ID（由 pty_shim.c 的 forkpty
 * 子进程在 exec 前设好）。为什么用环境变量：exec 委托是 procmgr **另起**一个进程，
 * 不是 forkpty 那个子进程，内存里的登记表带不过去。
 *
 * 分工（长理由见 pty_shim.c 里"输入处理"那一段）：
 *   - **输入处理（ICRNL/ICANON/ECHO/行编辑）在 master 侧**：只有那里能看见"用户敲的
 *     字节"，而且**与读端用什么机制无关** —— stdio 的 fgets/scanf（python 的 input()
 *     也是）走的是 libc **内部**的 read，我们在 slave 侧包装 read 根本碰不到（实测
 *     就是走到这一步发现路不通的）。
 *   - **termios 的真相在 slave 侧**：程序 tcsetattr 改的就是它自己这份，master 看不见。
 * 两边靠一个小文件共享：`<sysroot>/.ptyterm-<id>`（与 bsh-ws.bin 同一个套路），内容
 * 就是一个 struct termios。谁写谁读都一样。
 *
 * 附带修掉一个真 bug：以前假 pty 的 slave 上 tcsetattr 会借道**会话**那份 termios，
 * 于是 mksh 一进自己的行编辑器就把用户自己的 BetterSH 终端设成 raw。现在它只碰这个文件。
 */

#define BSH_FP_MAX 4

static int g_fp_fd[BSH_FP_MAX];      /* -1 = 这一格没用 */
static int g_fp_id = -1;
static int g_fp_inited;

/* 真 pty 的默认 termios（Linux 那套：ICRNL|IXON / OPOST|ONLCR /
 * ISIG|ICANON|ECHO|ECHOE|ECHOK|ECHOCTL|IEXTEN）。 */
static void fp_default_tio(struct termios* t) {
    memset(t, 0, sizeof *t);
    t->c_iflag = ICRNL | IXON | IUTF8;
    t->c_oflag = OPOST | ONLCR;
    t->c_cflag = CS8 | CREAD | HUPCL;
    t->c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | IEXTEN;
    t->c_cc[VINTR]    = 003;
    t->c_cc[VQUIT]    = 034;
    t->c_cc[VERASE]   = 0177;
    t->c_cc[VKILL]    = 025;
    t->c_cc[VEOF]     = 004;
    t->c_cc[VTIME]    = 0;
    t->c_cc[VMIN]     = 1;
    t->c_cc[VSTART]   = 021;
    t->c_cc[VSTOP]    = 023;
    t->c_cc[VSUSP]    = 032;
    t->c_cc[VREPRINT] = 022;
    t->c_cc[VWERASE]  = 027;
    t->c_cc[VLNEXT]   = 026;
}

static void fp_init(void) {
    if (g_fp_inited) return;
    g_fp_inited = 1;
    for (int i = 0; i < BSH_FP_MAX; i++) g_fp_fd[i] = -1;
    const char* v = getenv("BSH_FAKE_PTY_FDS");
    if (!v || !*v) return;
    const char* p = v;
    while (*p) {
        while (*p == ',' || *p == ' ') p++;
        if (*p < '0' || *p > '9') break;
        int fd = 0;
        while (*p >= '0' && *p <= '9') fd = fd * 10 + (*p++ - '0');
        if (fd >= 0 && fd < BSH_FP_MAX) g_fp_fd[fd] = fd;
    }
    const char* id = getenv("BSH_FAKE_PTY_ID");
    if (id && *id) g_fp_id = atoi(id);
}

static int fp_owned(int fd) {
    fp_init();
    return fd >= 0 && fd < BSH_FP_MAX && g_fp_fd[fd] >= 0 && g_fp_id >= 0;
}

/* 共享文件路径；拿不到 sysroot 或 id 时返回 NULL（那时就退化成"没有假 pty"）。 */
static int fp_path(char* buf, size_t n) {
    const char* root = getenv("BSH_SYSROOT");
    if (!root || !*root || g_fp_id < 0) return 0;
    snprintf(buf, n, "%s/.ptyterm-%d", root, g_fp_id);
    return 1;
}

/* 一律走裸 syscall：本文件里 open/read/write 都是被 --wrap 改写的名字，直接写会绕到
 * 别的 shim 上；这里只是读写一个自己的小文件，不该惊动它们。 */
static int fp_tcgetattr(int fd, struct termios* t) {
    if (!fp_owned(fd) || t == NULL) return 0;
    char path[512];
    if (!fp_path(path, sizeof path)) return 0;
    int f = (int)syscall(SYS_openat, AT_FDCWD, path, O_RDONLY, 0);
    if (f < 0) { fp_default_tio(t); return 1; }          /* 文件还没建 → 给默认 */
    ssize_t r = (ssize_t)syscall(SYS_read, f, t, sizeof *t);
    syscall(SYS_close, f);
    if (r != (ssize_t)sizeof *t) fp_default_tio(t);
    return 1;
}

static int fp_tcsetattr(int fd, const struct termios* t) {
    if (!fp_owned(fd) || t == NULL) return 0;
    char path[512];
    if (!fp_path(path, sizeof path)) return 0;
    int f = (int)syscall(SYS_openat, AT_FDCWD, path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (f < 0) return 0;
    syscall(SYS_write, f, t, sizeof *t);
    syscall(SYS_close, f);
    return 1;
}
