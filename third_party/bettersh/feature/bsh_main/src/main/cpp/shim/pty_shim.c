// shim/pty_shim.c — 沙箱里用 socketpair 冒充 pts，让 guest 能"自己开一路伪终端"。
//
// 为什么要有这个文件
// ──────────────────
// 沙箱不给真 pty：open("/dev/ptmx") 在宿主进程、命令 so、guest 三层都是 EACCES。
// 于是 guest 里"posix_openpt → grantpt/unlockpt/ptsname → open(slave) → setsid +
// TIOCSCTTY → 在 slave 上跑 TUI"这条路走不通（验收程序里那条
// 「pty：guest 自建伪终端 + 设控制终端」就是唯一挂掉的一项）。
//
// 这一版不跟沙箱较劲去要真 pty，而是**用一对 socketpair 冒充 pts 的两端**：
//   * open("/dev/ptmx") 建一对 AF_UNIX SOCK_STREAM，master 那一端返回给调用者；
//     另一端先攥着，等 open("/dev/pts/N") 时 dup 出去；
//   * 数据通路就是 socketpair 本身（master 写 slave 读、反之亦然）；
//   * slave 端登记成"这是个 tty 的 fd"（shim/tty_shim.c 的 bsh_tty_mark_fd），于是
//     isatty/tcgetattr/ioctl(TIOCGWINSZ) 直接复用现成的软 tty 语义，不必在这里
//     再实现一套 termios。
//
// 生效开关
// ────────
// 只有环境变量 **BSH_FAKE_PTY** 非空时，open("/dev/ptmx") 才走假实现。
//   * 本机（x86_64）有真 /dev/ptmx，不设开关就落回真的 —— 否则本机测不出假路径；
//   * guest 沙箱里真 ptmx 打不开，所以要由 procmgr 给 guest 导出 BSH_FAKE_PTY=1
//     （与它已经导出 BSH_TTY_STDIO 是同一个位置、同一个道理）。这一条在本文件
//     范围外，改 procmgr 时别忘了。
// /dev/pts/<N> 不需要开关：只有 N 是我们分配出来的才接手，别人的 N 一律落回真
// open（内核会照旧拒掉），所以对没碰过假 pty 的程序完全透明。
//
// 与真 pty 的差别（v1 明确放弃的语义，别当成 bug）
// ──────────────────────────────────────────────
//   * **假 pty 没有自己的行规程 / termios / winsize**。slave 上的
//     tcgetattr/tcsetattr/TIOCGWINSZ 走的是**会话那份软 tty**（主进程的远端状态，
//     经 control socket）—— 所以在 slave 上设 raw 模式不会只影响这一路 pty，
//     它改的是整个会话的终端属性。这是 v1 最大的取舍：换来了"不必再实现一套
//     termios + 行规程"。
//   * **O_NOCTTY 不生效**。合并进 guest shim 后唯一的 open 入口（open_shim.c）
//     只把**路径**交给钩子，拿不到 flags。所以只要进程是会话组长、且还没有控制
//     终端，打开我们的 slave 就**一定**把它记成控制终端；真 pty 在 O_NOCTTY 时会
//     跳过这一步。
//   * **不是设备节点**：没有真实的 /dev/pts/N 路径，只有本模块的内部登记项；
//     stat/fstat 在那个 fd 上看到的是 socket，不是字符设备，dev/rdev 也对不上。
//   * **每次打开 slave 只是 dup 唯一的一端**：真 pty 允许多次 open 同一 slave，
//     这里各次打开共享同一个 socket 端；而且我们始终攥着那一端，所以"关掉所有
//     slave → master 读到 EOF"这条不成立（反方向成立：close(master) → slave 读到
//     EOF，见 close 那段）。
//   * **dup/fcntl(F_DUPFD) 出来的副本不登记 pts 号**：isatty 仍为真（tty_shim 只按
//     fd 记身份），但 ttyname 认不出号。
//   * **静态链接的 guest 依然吃不到**（LD_PRELOAD 对静态二进制无效），与 fs_shim
//     同一条限制。
//
// 编译：本文件同时给两种宿主用
//   * guest shim（-DBSH_SHIM_MERGED_OPEN，与 tty_shim.c/fs_shim.c/open_shim.c 一起）——
//     此时 open/openat/isatty/ioctl/ttyname 的**定义**让给 tty_shim.c 与 open_shim.c，
//     本文件只提供 bsh_pty_* 钩子 + grantpt/unlockpt/ptsname/ptsname_r/close；
//   * 本机自测（不加那个宏，单独编成 .so 预载）——此时本文件是完整的一份，
//     自己导出 open/openat/isatty/ioctl/ttyname/ttyname_r。
//   flags 相关的小差异（O_NOCTTY 忽略）两种模式一致。

#define _GNU_SOURCE 1

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <termios.h>
#include <unistd.h>

#include "shim_wrap.h"   /* BSH_PLAIN / BSH_EXPORT / BSH_REAL 三个模式宏 */

// shim/tty_shim.c 提供的钩子：把 fd 登记成（/撤销）"会话 tty"。合并进 guest shim 时
// 一定有定义；本机单独编 pty_shim.so 时没有 —— 用弱符号，取不到就只靠本模块自己的表。
// 为什么用弱符号而不是直接 extern：tty_shim.c 也被编进命令 so（vim/mksh/…），那些
// so 里没有 pty 模块，直接 extern 会在链接期报未定义。
extern void bsh_tty_mark_fd(int fd, int on) __attribute__((weak));

// ───────────────────────────── 规格常量 ─────────────────────────────

// 同时存在的假 pty 上限。终端场景个位数足够；满了就 ENOSPC，不去动态分配（省得引入
// 一把锁/释放路径，v1 不值得）。
#define BSH_PTY_MAX 64

// fd → pts 号的映射表长度。fd 号只在进程内有意义，本表也只在进程内用。
// 取 256 与 shim/tty_shim.c 的 SHIM_MAX_FDS 对齐：两边都装不下的 fd 会被放弃登记。
#define BSH_FD_MAX 256

// ───────────────────────────── 进程内状态 ─────────────────────────────
//
// 全部是进程内静态状态：fd 号、pts 号、控制终端都只在 guest 进程内有意义。
// 不做线程安全（与 fs_shim 的静态缓存同一个口径：预载层假设单线程初始化，
// 真并发 open 本来就少见）。

static int g_inited;
static int g_next_pts;                          // 下一个要分配的 pts 号，从 0 起
static int g_master_pts[BSH_FD_MAX];            // master fd  -> pts 号（-1 = 不是）
static int g_slave_pts[BSH_FD_MAX];             // slave  fd  -> pts 号（-1 = 不是）
static int g_ctty_fd;                           // 本进程的控制终端（一个 slave fd），-1 = 无
static char g_ptsname_buf[32];                  // ptsname(3) 的 per-进程静态缓冲

struct pty_ent {
    int used;
    int pts_n;
    int master_fd;   // socketpair 的 master 端；-1 = 已关闭
    int slave_fd;    // socketpair 的 slave 端（攥着的），open("/dev/pts/N") dup 它
    int slave_open;  // 是否已经有人打开过 slave（只影响 O_NOCTTY 那套语义，v1 不用）
    /* 行规程用：ONLCR 展开后一次读不完的余量，以及"上一个字节是不是 CR"
     * （跨两次 read 的 \r\n 不能重复插 CR）。都是惰性分配。 */
    char*  out;
    size_t out_len, out_cap;
    int    last_cr;
    /* ── 输入侧（ICRNL/ICANON/ECHO/行编辑）──
     * 这一路 pty 的 termios 由 slave 侧（tty_shim）写进 <sysroot>/.ptyterm-<id>；
     * 我们只在每次有输入时按 mtime 刷一次缓存 —— termios 改动极少，按键才几次。 */
    struct termios tio;
    long   tio_mtime;     // 0 = 还没读过
    char   line[4096];    // ICANON 的行缓冲
    size_t line_len;
};
static struct pty_ent g_pty[BSH_PTY_MAX];

// glibc 给 ptsname_r 的 buf 标了 __nonnull，直接写 `!buf` 会触发 -Wnonnull-compare。
// 预载层确实可能收到手工构造的 NULL，这层防御要留 —— 用一个不内联的小函数判断，
// 警告消失、检查也不会被优化掉（与 fs_shim.c 里 bsh_is_null 同一个套路）。
static __attribute__((noinline)) int bsh_null(const void* p) { return p == NULL; }

static void pty_init(void) {
    if (g_inited) return;
    g_inited = 1;
    g_next_pts = 0;
    g_ctty_fd = -1;
    for (int i = 0; i < BSH_FD_MAX; i++) {
        g_master_pts[i] = -1;
        g_slave_pts[i] = -1;
    }
    for (int i = 0; i < BSH_PTY_MAX; i++) {
        g_pty[i].master_fd = -1;
        g_pty[i].slave_fd = -1;
    }
}

// 假实现总开关。只有 BSH_FAKE_PTY 非空时才认 /dev/ptmx —— 见文件头。
static int fake_pty_enabled(void) {
    const char* v = getenv("BSH_FAKE_PTY");
    return v && *v;
}


// ─────────────────────────── 小工具 ───────────────────────────

static struct pty_ent* ent_by_pts(int n) {
    for (int i = 0; i < BSH_PTY_MAX; i++)
        if (g_pty[i].used && g_pty[i].pts_n == n) return &g_pty[i];
    return NULL;
}

// 按 master fd 找登记项（read/write 的行规程那两个入口要用）。
static struct pty_ent* ent_by_master(int fd) {
    if (fd < 0 || fd >= BSH_FD_MAX) return NULL;
    int n = g_master_pts[fd];
    return n < 0 ? NULL : ent_by_pts(n);
}

// "/dev/pts/<数字>"（数字后必须紧跟结尾，尾随 '/' 或别的字符都不认）。
// 认出来返回 1 并把号写进 *out，否则返回 0（交给真 open）。
static int parse_pts_path(const char* path, int* out) {
    static const char prefix[] = "/dev/pts/";
    if (!path || strncmp(path, prefix, sizeof prefix - 1) != 0) return 0;
    const char* d = path + (sizeof prefix - 1);
    if (*d < '0' || *d > '9') return 0;
    long v = 0;
    while (*d >= '0' && *d <= '9') {
        v = v * 10 + (*d - '0');
        if (v > 1000000) return 0;      // 数字失控就当不是我们的
        d++;
    }
    if (*d != '\0') return 0;
    *out = (int)v;
    return 1;
}

static int set_ctty(int fd) {
    g_ctty_fd = fd;
    return 0;
}

// ─────────────────── /dev/ptmx 与 /dev/pts/<N> 的创建/打开 ───────────────────

static int pty_create(void) {
    int sv[2];
    if (syscall(SYS_socketpair, AF_UNIX, SOCK_STREAM, 0, sv) != 0) return -1;
    // fd 表装不下就别登记半截：宁可失败（EMFILE）。
    if (sv[0] >= BSH_FD_MAX || sv[1] >= BSH_FD_MAX) {
        syscall(SYS_close, sv[0]);
        syscall(SYS_close, sv[1]);
        errno = EMFILE;
        return -1;
    }
    struct pty_ent* e = NULL;
    for (int i = 0; i < BSH_PTY_MAX; i++)
        if (!g_pty[i].used) { e = &g_pty[i]; break; }
    if (!e) {
        syscall(SYS_close, sv[0]);
        syscall(SYS_close, sv[1]);
        errno = ENOSPC;
        return -1;
    }
    e->used = 1;
    e->pts_n = g_next_pts++;
    e->master_fd = sv[0];
    e->slave_fd = sv[1];
    e->slave_open = 0;
    g_master_pts[sv[0]] = e->pts_n;
    return sv[0];
}

static int pty_open_slave(struct pty_ent* e) {
    if (e->slave_fd < 0) { errno = ENODEV; return -1; }
    // 每次 open 都 dup 攥着的那一端：dup 共享同一 socket，读写互通。
    int fd = (int)syscall(SYS_dup, e->slave_fd);
    if (fd < 0) return -1;
    if (fd >= BSH_FD_MAX) {
        syscall(SYS_close, fd);
        errno = EMFILE;
        return -1;
    }
    e->slave_open = 1;
    g_slave_pts[fd] = e->pts_n;
    // 复用软 tty 语义：登记成 tty fd 之后，isatty/tcgetattr/ioctl(TIOCGWINSZ) 就都通了。
    if (bsh_tty_mark_fd) bsh_tty_mark_fd(fd, 1);
    // 会话组长第一次打开 tty → 自动成为控制终端（真 pty 的默认行为）。
    // ⚠ O_NOCTTY 在这里拿不到 flags，所以无法遵守 —— 见文件头取舍。
    if (g_ctty_fd < 0 && syscall(SYS_getsid, 0) == (long)syscall(SYS_getpid))
        set_ctty(fd);
    return fd;
}

// 交给 shim/tty_shim.c 的 bsh_tty_maybe_open 调用的钩子：>=0 已处理，-2 不归我管。
int bsh_pty_maybe_open(const char* path) {
    if (!path) return -2;
    pty_init();
    if (strcmp(path, "/dev/ptmx") == 0) {
        if (!fake_pty_enabled()) return -2;     // 没开开关 → 落回真 open
        return pty_create();
    }
    int n;
    if (parse_pts_path(path, &n)) {
        struct pty_ent* e = ent_by_pts(n);
        if (!e) return -2;                      // 不是我们分配的号 → 真 open（内核照旧拒）
        return pty_open_slave(e);
    }
    return -2;
}

// shim/tty_shim.c 的 ioctl 调用它处理 pty 专有请求。返回 1 = 已处理（结果在 *res），
// 0 = 不归我管（调用者继续按自己的语义走）。
int bsh_pty_ioctl(int fd, unsigned long request, void* arg, int* res) {
    pty_init();
    int mp = (fd >= 0 && fd < BSH_FD_MAX) ? g_master_pts[fd] : -1;
    if (mp >= 0) {
        switch (request) {
#ifdef TIOCGPTN
        case TIOCGPTN:                          // 取 pts 号
            if (arg) *(unsigned int*)arg = (unsigned int)mp;
            *res = 0;
            return 1;
#endif
#ifdef TIOCSPTLCK
        case TIOCSPTLCK:                        // 假锁：永远成功
            *res = 0;
            return 1;
#endif
        default:
            return 0;
        }
    }
    int sp = (fd >= 0 && fd < BSH_FD_MAX) ? g_slave_pts[fd] : -1;
    if (sp >= 0) {
#ifdef TIOCSCTTY
        if (request == TIOCSCTTY) {             // 记下：本进程的控制终端 = 这个 slave
            *res = set_ctty(fd);
            return 1;
        }
#endif
        // TCGETS/TCSETS/TIOCGWINSZ/… 交给 tty_shim 的软 tty 语义（合并模式）或内核。
        return 0;
    }
    return 0;
}

// shim/tty_shim.c 的 ttyname_r 调用它填名字。
//   返回 1  = 是我们的 pty slave，名字写进 buf
//   返回 0  = 不是我们的 fd（调用者走别的兜底）
//   返回 -1 = 是我们的 pty，但 buf 装不下（ERANGE）
int bsh_pty_fd_name(int fd, char* buf, size_t n) {
    pty_init();
    if (fd < 0 || fd >= BSH_FD_MAX || g_slave_pts[fd] < 0) return 0;
    char tmp[32];
    int len = snprintf(tmp, sizeof tmp, "/dev/pts/%d", g_slave_pts[fd]);
    if (len <= 0 || (size_t)len + 1 > n) return -1;
    memcpy(buf, tmp, (size_t)len + 1);
    return 1;
}

// shim/tty_shim.c 的 isatty 兜底用：这个 fd 是不是我们的 pty slave。
int bsh_pty_is_slave(int fd) {
    pty_init();
    return fd >= 0 && fd < BSH_FD_MAX && g_slave_pts[fd] >= 0;
}

// shim/tty_shim.c 处理 open("/dev/tty") 时用：本进程记下的控制终端 fd，-1 = 没记。
int bsh_pty_ctty_fd(void) {
    pty_init();
    return g_ctty_fd;
}

// ─────────────────────────── grantpt / unlockpt / ptsname ───────────────────────────
//
// 对我们的假 master 直接成功/给出号码；别人的 fd 一律落回真 libc（本机真 pty 上
// grantpt 之类仍要走内核）。真实现：guest/命令 so 模式用 dlsym(RTLD_NEXT) 取一次并
// 缓存；box64 模式直接引用宿主符号（box64 就活在宿主进程里，没有搜索序问题）。
#ifdef BSH_SHIM_BOX64
#define REAL1(fn, sym) ((fn) != NULL ? (fn) : ((fn) = (__typeof__(fn))sym))
#else
#define REAL1(fn, sym) ((fn) != NULL ? (fn) : ((fn) = (__typeof__(fn))dlsym(RTLD_NEXT, #sym)))
#endif

int BSH_PLAIN(grantpt)(int fd) {
    pty_init();
    if (fd >= 0 && fd < BSH_FD_MAX && g_master_pts[fd] >= 0) return 0;   // 假成功
    static int (*real)(int);
    if (!REAL1(real, grantpt)) { errno = ENOSYS; return -1; }
    return real(fd);
}

int BSH_PLAIN(unlockpt)(int fd) {
    pty_init();
    if (fd >= 0 && fd < BSH_FD_MAX && g_master_pts[fd] >= 0) return 0;   // 假成功
    static int (*real)(int);
    if (!REAL1(real, unlockpt)) { errno = ENOSYS; return -1; }
    return real(fd);
}

char* BSH_PLAIN(ptsname)(int fd) {
    pty_init();
    if (fd >= 0 && fd < BSH_FD_MAX && g_master_pts[fd] >= 0) {
        snprintf(g_ptsname_buf, sizeof g_ptsname_buf, "/dev/pts/%d", g_master_pts[fd]);
        return g_ptsname_buf;
    }
    static char* (*real)(int);
    if (!REAL1(real, ptsname)) { errno = ENOSYS; return NULL; }
    return real(fd);
}

int BSH_PLAIN(ptsname_r)(int fd, char* buf, size_t n) {
    pty_init();
    if (fd >= 0 && fd < BSH_FD_MAX && g_master_pts[fd] >= 0) {
        char tmp[32];
        int len = snprintf(tmp, sizeof tmp, "/dev/pts/%d", g_master_pts[fd]);
        if (bsh_null(buf)) return EINVAL;        // 与真实现口径一致（glibc 返回错误号）
        if (len <= 0 || (size_t)len + 1 > n) return ERANGE;
        memcpy(buf, tmp, (size_t)len + 1);
        return 0;
    }
    static int (*real)(int, char*, size_t);
    if (!REAL1(real, ptsname_r)) return ENOSYS;
    return real(fd, buf, n);
}

// ─────────────────── posix_openpt / openpty / forkpty ───────────────────
//
// 为什么补这三个：上面那套假 pts 原本只有一个入口 —— **应用自己 open("/dev/ptmx")**
// （open_shim → bsh_pty_maybe_open）。而 node-pty（VS Code 的集成终端）用的是 forkpty(3)：
//
//     node-pty → forkpty() → glibc 的 openpty() → getpt() → __open("/dev/ptmx")
//
// 最后那一步是 **glibc 内部调用**（hidden alias，不走 PLT），LD_PRELOAD 与
// `-Wl,--wrap=` 都拦不到 → 直接落到内核 → EACCES → openpty 失败 → forkpty 返回 -1 →
// node-pty 抛 "A native exception occurred during launch (forkpty(3) failed.)"。
// 同理，应用自己调 posix_openpt() 也不生效 —— glibc 的实现内部同样是那次拦不到的 open。
//
// 所以把这三个入口也接管过来：调用方看到的是我们的符号，内部再驱动上面那套假 pts。
// 开关仍是 BSH_FAKE_PTY —— 没开就落回真实现（本机有真 /dev/ptmx，本机自测照旧走内核）。
//
// ⚠ 只走 LD_PRELOAD 符号插入，**不要**加进 scripts/shim-wrap-flags.sh 那份共用清单：
//   pty_shim.c 只链进 libbshguest-{musl,glibc}.so（没有任何命令 so 链它），加到那份
//   清单里会让命令 so 出现未定义的 `__wrap_posix_openpt`，dlopen 直接失败。

int BSH_PLAIN(posix_openpt)(int oflag) {
    pty_init();
    if (fake_pty_enabled()) {
        int fd = pty_create();
        if (fd >= 0) {
            // 真实现把这两个标志带在 master 上，照做；走 syscall 免得绕回本层钩子。
            if (oflag & O_CLOEXEC) syscall(SYS_fcntl, fd, F_SETFD, FD_CLOEXEC);
            if (oflag & O_NONBLOCK) {
                long fl = syscall(SYS_fcntl, fd, F_GETFL, 0);
                if (fl >= 0) syscall(SYS_fcntl, fd, F_SETFL, fl | O_NONBLOCK);
            }
            return fd;
        }
        return -1;                              // pty_create 已经把 errno 设好
    }
    static int (*real)(int);
    if (!REAL1(real, posix_openpt)) { errno = ENOSYS; return -1; }
    return real(oflag);
}

// openpty：照真实现那套顺序走一遍（getpt → grantpt → unlockpt → ptsname → open(slave)），
// 只是每一步都落在我们的假 pts 上。
int BSH_PLAIN(openpty)(int* amaster, int* aslave, char* name,
                       const struct termios* termp, const struct winsize* winp) {
    pty_init();
    if (!fake_pty_enabled()) {
        static int (*real)(int*, int*, char*, const struct termios*, const struct winsize*);
        if (!REAL1(real, openpty)) { errno = ENOSYS; return -1; }
        return real(amaster, aslave, name, termp, winp);
    }
    /* termp / winp 刻意**不套用**：假 pty 没有自己的行规程，slave 上的 tcsetattr /
     * TIOCSWINSZ 走的是**整个会话**那份软 tty（见文件头"与真 pty 的差别"）。而
     * node-pty 传进来的正是它要的 raw 模式与终端尺寸 —— 照套会把用户自己的会话改成
     * raw、尺寸也跟着被改。真实现的 tcsetattr 只影响这一路 pty，我们没有"这一路"，
     * 所以宁可不做：调用方要尺寸时按 TIOCGWINSZ 读到的仍是会话尺寸。 */
    (void)termp;
    (void)winp;

    int master = pty_create();
    if (master < 0) return -1;
    char nm[32];
    snprintf(nm, sizeof nm, "/dev/pts/%d", g_master_pts[master]);
    int slave = bsh_pty_maybe_open(nm);         // 直接驱动钩子，不再绕一层 open
    if (slave < 0) {
        int e = errno;
        close(master);                          // 我们的 close 钩子会回收这个 pty 登记项
        errno = e;
        return -1;
    }
    if (amaster) *amaster = master;
    if (aslave) *aslave = slave;
    if (name) strcpy(name, nm);                 // 与真实现同契约：调用方保证缓冲够大
    return 0;
}

// forkpty = openpty + fork + login_tty。
pid_t BSH_PLAIN(forkpty)(int* amaster, char* name,
                         const struct termios* termp, const struct winsize* winp) {
    pty_init();
    if (!fake_pty_enabled()) {
        static pid_t (*real)(int*, char*, const struct termios*, const struct winsize*);
        if (!REAL1(real, forkpty)) { errno = ENOSYS; return -1; }
        return real(amaster, name, termp, winp);
    }
    int master = -1, slave = -1;
    if (openpty(&master, &slave, name, termp, winp) != 0) return -1;

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        close(master);
        close(slave);
        errno = e;
        return -1;
    }
    if (pid == 0) {
        /* 子进程：照 login_tty(3) 的语义摆好控制终端与 stdio。
         * 顺序照抄：setsid → ioctl(TIOCSCTTY) → dup2 到 0/1/2。
         * 注意先记下 pts 号：close(slave) 会被我们的 close 钩子把登记项清掉。 */
        int n = (slave >= 0 && slave < BSH_FD_MAX) ? g_slave_pts[slave] : -1;
        close(master);
        syscall(SYS_setsid);
#ifdef TIOCSCTTY
        ioctl(slave, TIOCSCTTY, 0);             // 我们的 ioctl 钩子记下控制终端；失败不致命
#endif
        dup2(slave, 0);
        dup2(slave, 1);
        dup2(slave, 2);
        if (slave > 2) close(slave);
        /* 真 pty 下这三个 fd 就是 slave，isatty 为真。我们的登记是按 fd 号做的，
         * dup2 出来的 0/1/2 不会被自动认成 slave，所以显式补一遍（含控制终端 ——
         * 上面 close(slave) 已经把它清掉了）。 */
        if (n >= 0) {
            for (int fd = 0; fd <= 2; fd++) {
                g_slave_pts[fd] = n;
                if (bsh_tty_mark_fd) bsh_tty_mark_fd(fd, 1);
            }
            set_ctty(0);
            /* 告诉 exec 之后那个进程（经 exec 委托另起的）"你的 0/1/2 是假 pty 的
             * slave" —— 它需要据此把 ICRNL/ICANON/ECHO 那套行规程接上（见 tty_shim.c
             * 的 fake-pty 那一段）。为什么要走环境变量：exec 委托是 procmgr **另起**
             * 一个进程，不是我们这个 fork 出来的子进程，所以内存里的登记表带不过去。 */
            setenv("BSH_FAKE_PTY_FDS", "0,1,2", 1);
            char idbuf[24];
            snprintf(idbuf, sizeof idbuf, "%d", n);
            setenv("BSH_FAKE_PTY_ID", idbuf, 1);
        }
        return 0;
    }
    close(slave);                               // 父进程只留 master
    if (amaster) *amaster = master;
    return pid;
}

// ─────────────────── 最小行规程：ONLCR（输出）+ ISIG（输入）───────────────────
//
// 假 pty 中间是 socketpair，没有内核行规程，于是两件"终端本该干的事"都得自己补：
//
//   1) **ONLCR（输出方向）**：真 pty 的终端驱动会把程序写出的 '\n' 补成 "\r\n"
//      （opost + onlcr 默认就是开的）。少了它，接收端只换行不回列 —— 现象就是
//      "输出之后第二行没有回到最左边"。
//   2) **ISIG（输入方向）**：真 pty 会把 VINTR(^C) / VQUIT(^\) / VSUSP(^Z) 这些控制
//      字符**吃掉**并换成信号。少了它，0x03 只是个普通字节被送给程序 —— 现象就是
//      "python 跑着按 Ctrl+C 没反应"。
//
// 两件事都放在 **master 这一侧**做，理由是：假 pty 的登记表（哪个 fd 是 master、
// 子进程组是谁）只在本进程这份状态里；而输出方向 slave→master 在 master 这边正好
// 是 read，一处就能翻完 —— slave 那一侧通常是 mksh/python 这类**命令 so**，它们
// 根本没链 pty 模块。
//
// 代价：一次 read 进来展开后可能超过调用方给的缓冲，所以要给每个 pty 备一份"没交付
// 完的余量"（struct pty_ent 的 out/out_len）。
//
// ⚠ 这一层被预载进**整个 guest 进程**，read/write 是热路径 —— 所以第一件事是最便宜
//   的判断（fd 是不是我们的 master），不命中立刻转真实现。
// ⚠ libuv（node 的 I/O 层）走的是 **readv/writev**，所以四个入口都要接，只接
//   read/write 会漏掉。

// 真正干活的进程是 procmgr fork 出来的、不在我们这个进程组里（见 procmgr.h）。
// 弱声明：本机单独编 pty_shim.so 自测时没有 bsh_client，取不到就只发进程组。
extern int bsh_procmgr_signal_fg(int sig) __attribute__((weak));

#define BSH_LD_CHUNK 8192

static int ent_out_reserve(struct pty_ent* e, size_t need) {
    if (e->out_cap >= need) return 1;
    size_t cap = e->out_cap ? e->out_cap : 256;
    while (cap < need) cap *= 2;
    char* p = (char*)realloc(e->out, cap);
    if (!p) return 0;
    e->out = p;
    e->out_cap = cap;
    return 1;
}

// fd 是不是我们建的假 pty 的 master；是就把登记项写进 **e（顺带 pty_init）。
static int is_master_fd(int fd, struct pty_ent** e) {
    pty_init();
    if (fd < 0 || fd >= BSH_FD_MAX) return 0;
    if (g_master_pts[fd] < 0) return 0;
    struct pty_ent* p = ent_by_master(fd);
    if (!p) return 0;
    *e = p;
    return 1;
}

/* 带 ONLCR 的读。语义与真 read 一致：返回交付给调用方的字节数（<= n），
 * 0 = EOF，-1 = 出错（errno 已设）。 */
static ssize_t ld_read(int fd, void* buf, size_t n, ssize_t (*real)(int, void*, size_t),
                       struct pty_ent* e) {
    char* p = (char*)buf;

    if (e->out_len) {                            // 先把上次没交付完的给出去
        size_t k = e->out_len < n ? e->out_len : n;
        memcpy(p, e->out, k);
        memmove(e->out, e->out + k, e->out_len - k);
        e->out_len -= k;
        return (ssize_t)k;
    }
    if (n == 0) return 0;

    char tmp[BSH_LD_CHUNK];
    size_t want = n < sizeof tmp ? n : sizeof tmp;
    ssize_t r = real(fd, tmp, want);
    if (r <= 0) return r;

    /* 先数展开后要多少字节：'\n' 且前一个字节不是 '\r' 才补 CR
     * （跨两次 read 的 \r\n 靠 e->last_cr 认出来，不能重复插）。 */
    int prev_cr = e->last_cr;
    size_t need = 0;
    for (ssize_t i = 0; i < r; i++) {
        need += (tmp[i] == '\n' && !prev_cr) ? 2 : 1;
        prev_cr = (tmp[i] == '\r');
    }

    if (need <= n) {                             // 装得下：直接翻进调用方的缓冲
        size_t o = 0;
        int prev = e->last_cr;
        for (ssize_t i = 0; i < r; i++) {
            if (tmp[i] == '\n' && !prev) p[o++] = '\r';
            p[o++] = tmp[i];
            prev = (tmp[i] == '\r');
        }
        e->last_cr = prev;
        return (ssize_t)o;
    }

    /* 装不下：整段翻进余量缓冲，只交付前 n 字节。
     * 分配失败就退化成"原样返回"——宁可少补一个 CR，也不能丢数据。 */
    if (!ent_out_reserve(e, need)) return r;
    size_t o = 0;
    int prev = e->last_cr;
    for (ssize_t i = 0; i < r; i++) {
        if (tmp[i] == '\n' && !prev) e->out[o++] = '\r';
        e->out[o++] = tmp[i];
        prev = (tmp[i] == '\r');
    }
    e->out_len = o;
    e->last_cr = prev;
    size_t k = o < n ? o : n;
    memcpy(p, e->out, k);
    memmove(e->out, e->out + k, o - k);
    e->out_len = o - k;
    return (ssize_t)k;
}

/* ── 输入的 termios：从 slave 侧写的共享文件里刷新 ──────────────────
 *
 * 为什么要共享文件：ICANON/ECHO/ICRNL 这些开关由**程序**（mksh、python）通过
 * tcsetattr 改，而那是 slave 侧那个**进程**（exec 委托另起的）的事；master 是另一个
 * 进程，看不到它的内存。两边靠 <sysroot>/.ptyterm-<id> 一个 64 字节文件对齐
 * （同 bsh-ws.bin 的套路）。按键很少，刷一次的代价可以忽略。 */
static void ld_refresh_tio(struct pty_ent* e) {
    const char* root = getenv("BSH_SYSROOT");
    if (!root || !*root) return;
    char path[512];
    snprintf(path, sizeof path, "%s/.ptyterm-%d", root, e->pts_n);
    struct stat st;
    if (stat(path, &st) != 0) {
        /* 程序**从没配置过**这一路 pty：那就不接管行编辑与回显，只做 ICRNL（见 ld_write）。
         *
         * 为什么不用真 pty 的默认值（ICANON|ECHO）：那样 shell 会**双重回显** ——
         * mksh 的行编辑器自己会回显它读到的每个字节，而它并不会来告诉我们"别回显"
         * （实测：它既不调 tcgetattr/tcsetattr，也不调 ioctl(TCSETS)，我们的钩子一次
         * 都没被调用过）。真终端里这件事由 termios 对齐，我们这里没得对齐，就不猜。 */
        if (e->tio_mtime != -1) {
            /* 铺一份真 pty 的默认值 —— **ISIG 与 c_cc 需要它**（见 ld_write：ISIG 不受
             * "有没有配置文件"影响），只有 ICANON/ECHO 那两项由 tio_mtime 关掉。 */
            memset(&e->tio, 0, sizeof e->tio);
            e->tio.c_iflag = ICRNL | IXON;
            e->tio.c_oflag = OPOST | ONLCR;
            e->tio.c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | IEXTEN;
            e->tio.c_cc[VINTR] = 003;   e->tio.c_cc[VQUIT] = 034;
            e->tio.c_cc[VERASE] = 0177; e->tio.c_cc[VKILL] = 025;
            e->tio.c_cc[VEOF] = 004;    e->tio.c_cc[VWERASE] = 027;
            e->tio.c_cc[VSUSP] = 032;
        }
        e->tio_mtime = -1;                       // -1 = "没配置过"
        return;
    }
    if (st.st_mtime == e->tio_mtime) return;      // 没变
    int f = open(path, O_RDONLY);
    if (f < 0) return;
    struct termios t;
    ssize_t r = read(f, &t, sizeof t);
    close(f);
    if (r == (ssize_t)sizeof t) { e->tio = t; e->tio_mtime = st.st_mtime; }
}

/* 回显字节塞进输出队列（就是 ONLCR 那条队列，读端会先拿到它）。 */
static void ld_echo(struct pty_ent* e, const char* s, size_t n) {
    if (n == 0) return;
    if (!ent_out_reserve(e, e->out_len + n)) return;
    memcpy(e->out + e->out_len, s, n);
    e->out_len += n;
}

/* 处理一个从 master 送进来的输入字节；返回 1 = 攒够一行（在 *olen 里，指向 e->line）。 */
static int ld_feed(struct pty_ent* e, unsigned char c, size_t* olen) {
    struct termios* t = &e->tio;
    unsigned char ch = c;
    if ((t->c_iflag & ICRNL) && ch == '\r') ch = '\n';     /* xterm.js 的回车是 CR */
    if ((t->c_iflag & ISTRIP)) ch &= 0x7f;

    if (ch == t->c_cc[VERASE]) {                            /* 退格 */
        if (e->line_len) {
            e->line_len--;
            if (t->c_lflag & ECHOE) ld_echo(e, "\b \b", 3);
            else if (t->c_lflag & ECHO) ld_echo(e, "\b", 1);
        }
        return 0;
    }
    if (ch == t->c_cc[VKILL]) {                             /* 整行删掉 */
        if (t->c_lflag & ECHOKE) { for (size_t i = 0; i < e->line_len; i++) ld_echo(e, "\b \b", 3); }
        else if (t->c_lflag & ECHOK) ld_echo(e, "\r\n", 2);
        e->line_len = 0;
        return 0;
    }
    if (ch == t->c_cc[VWERASE]) {                           /* 删一个词 */
        while (e->line_len && e->line[e->line_len - 1] == ' ') { e->line_len--; ld_echo(e, "\b \b", 3); }
        while (e->line_len && e->line[e->line_len - 1] != ' ') { e->line_len--; ld_echo(e, "\b \b", 3); }
        return 0;
    }
    if (ch == t->c_cc[VEOF]) {                              /* ^D：把手上这行交出去（空行则丢，见下） */
        if (e->line_len) { *olen = e->line_len; e->line_len = 0; return 1; }
        return 0;                                           /* 空行的 VEOF 需要让读端拿到 EOF —— 本架构做不到，见文件头 */
    }
    if (ch == '\n') {
        if (e->line_len < sizeof e->line) e->line[e->line_len++] = '\n';
        if (t->c_lflag & ECHO) ld_echo(e, "\r\n", 2);
        *olen = e->line_len;
        e->line_len = 0;
        return 1;
    }
    if (ch == t->c_cc[VLNEXT]) return 0;
    if (e->line_len < sizeof e->line) e->line[e->line_len++] = (char)ch;
    if (t->c_lflag & ECHO) ld_echo(e, (const char*)&ch, 1);
    return 0;
}

/* 输入方向（master 写 → slave 读）：ICRNL + ISIG + ICANON + ECHO + 行编辑。
 *
 * 返回**消费掉的调用方字节数**（默认 n）—— 被吃掉的控制字符也算消费（真终端就是这个
 * 语义：INTR 不会交给程序，但调用方认为它写出去了），否则调用方会拿同一段缓冲无限重试。
 *
 * ⚠ ISIG **只发给 procmgr 记下的那个"真正干活的进程"**，不发给 forkpty 子进程的组：
 *   那个组里是交互式 shell 与"委托中间体"，发过去等于把 shell 打死（实测：按完 Ctrl+C
 *   整个终端没声了）。真终端里 SIGINT 落在"作业的进程组"上、shell 不挨那一下，而我们
 *   分不出哪个组是"作业组"。没有前台进程时**原样透传**，让读的人自己解释这个字节。
 * ⚠ ^Z（VSUSP）刻意不当控制字符：作业控制需要 pgrp 与信号能落到作业上，本架构做不到
 *   （见上一条），发 SIGTSTP 只会让委托进程停住、而 shell 还在等它结束 —— 终端假死。 */
static ssize_t ld_write(int fd, const void* buf, size_t n,
                        ssize_t (*real)(int, const void*, size_t), struct pty_ent* e) {
    const unsigned char* b = (const unsigned char*)buf;
    ld_refresh_tio(e);
    struct termios* t = &e->tio;

    /* ⚠ 只有 ICANON/ECHO 按需（程序没配置过 → 不接管，见上）；
     *   **ISIG 必须一直开** —— 它直接用真 pty 的默认值即可，而且没什么可"配置"的：
     *   把它也挂到"有没有配置文件"上，等于让 Ctrl+C 在没人写那个文件时彻底失效
     *   （实测踩过：一改完 Ctrl+C 就没反应了）。 */
    int canon   = (e->tio_mtime > 0) && (t->c_lflag & ICANON);
    int isig    = (t->c_lflag & ISIG) != 0;

    /* 先扫一遍：有没有要变信号的控制字符 */
    int sigs[8], nsig = 0;
    for (size_t i = 0; i < n && isig; i++) {
        int sig = 0;
        if (b[i] == t->c_cc[VINTR])      sig = SIGINT;
        else if (b[i] == t->c_cc[VQUIT]) sig = SIGQUIT;
        if (sig && nsig < (int)(sizeof sigs / sizeof sigs[0])) sigs[nsig++] = sig;
    }
    int fg_ok = 0;
    for (int i = 0; i < nsig; i++)
        if (bsh_procmgr_signal_fg && bsh_procmgr_signal_fg(sigs[i])) fg_ok = 1;

    /* 原始模式：直通（含 ICRNL），不做行编辑、不代回显（那种模式下程序自己管） */
    if (!canon) {
        if (isig && fg_ok) {
            char stackbuf[256];
            char* f = n <= sizeof stackbuf ? stackbuf : (char*)malloc(n);
            if (f) {
                size_t o = 0;
                for (size_t i = 0; i < n; i++) {
                    if (isig && (b[i] == t->c_cc[VINTR] || b[i] == t->c_cc[VQUIT])) continue;
                    f[o++] = (char)b[i];
                }
                if (o) real(fd, f, o);
                if (f != stackbuf) free(f);
                return (ssize_t)n;
            }
        }
        /* ICRNL 无条件做：xterm.js 的回车是 CR，而**所有**读端（stdio 的 fgets/
         * scanf、python 的 input()）都指望拿到完整的一行 —— 直通 CR 它们会一直等。
         * mksh 两种都认（LF/CR 都当回车），所以这一条对谁都不亏。 */
        char stackbuf[256];
        char* f = n <= sizeof stackbuf ? stackbuf : (char*)malloc(n);
        if (!f) return real(fd, buf, n);
        size_t o = 0;
        for (size_t i = 0; i < n; i++) f[o++] = (b[i] == '\r') ? '\n' : (char)b[i];
        ssize_t w = real(fd, f, o);
        if (f != stackbuf) free(f);
        return w < 0 ? -1 : (ssize_t)n;
    }

    /* 规范模式：逐字节过行规程，攒够一行才写进 socketpair（读端拿到的就是整行） */
    for (size_t i = 0; i < n; i++) {
        if (isig && (b[i] == t->c_cc[VINTR] || b[i] == t->c_cc[VQUIT])) {
            if (fg_ok) continue;                 /* 信号已交给真正干活的进程 → 吃掉 */
            /* 没有前台进程：原样交给读端（比如就停在提示符上） */
        }
        size_t olen = 0;
        if (ld_feed(e, b[i], &olen)) {
            ssize_t w = real(fd, e->line, olen);
            if (w < 0) return -1;
        }
    }
    return (ssize_t)n;
}


/* ── 四个入口 ────────────────────────────────────────────────────────────
 *
 * master 侧（本文件）负责**全部输入处理**与 ONLCR：
 *   输入：ICRNL / ISIG / ICANON / ECHO / 行编辑  ← 为什么在 master 侧见上面那段
 *   输出：ONLCR
 *
 * 为什么不把入口放 tty_shim：那里要同时服务"命令 so"（靠 --wrap）与 guest（靠
 * LD_PRELOAD）两种 fds，而 master 只可能出现在 guest/box64 这两种形态里（命令 so
 * 根本没链 pty 模块）。所以入口放这儿最省事，也不会和 tty_shim 的定义撞
 * （guest shim 里两份源码编进同一个 .so，同名入口会**重复定义**）。
 *
 * 本机自测（不带 -DBSH_SHIM_MERGED_OPEN）时下面那几个 open/close 才由本文件自己提供。 */

ssize_t BSH_PLAIN(read)(int fd, void* buf, size_t n) {
    static ssize_t (*real)(int, void*, size_t);
    if (!REAL1(real, read)) { errno = ENOSYS; return -1; }
    struct pty_ent* e;
    if (!is_master_fd(fd, &e)) return real(fd, buf, n);
    return ld_read(fd, buf, n, real, e);
}

ssize_t BSH_PLAIN(write)(int fd, const void* buf, size_t n) {
    static ssize_t (*real)(int, const void*, size_t);
    if (!REAL1(real, write)) { errno = ENOSYS; return -1; }
    struct pty_ent* e;
    if (!is_master_fd(fd, &e)) return real(fd, buf, n);
    return ld_write(fd, buf, n, real, e);
}

/* readv/writev 那条路要先摊平到一块缓冲，再交给 ld_read/ld_write —— 它们要的是
 * "读写一条缓冲"的真实现，所以这里给两个裸 syscall 的适配器（类型也对得上）。 */
static ssize_t raw_read(int fd, void* buf, size_t n)  { return (ssize_t)syscall(SYS_read, fd, buf, n); }
static ssize_t raw_write(int fd, const void* buf, size_t n) { return (ssize_t)syscall(SYS_write, fd, buf, n); }

ssize_t BSH_PLAIN(readv)(int fd, const struct iovec* iov, int iovcnt) {
    static ssize_t (*real)(int, const struct iovec*, int);
    if (!REAL1(real, readv)) { errno = ENOSYS; return -1; }
    struct pty_ent* e;
    if (!is_master_fd(fd, &e) || iovcnt <= 0) return real(fd, iov, iovcnt);
    if (iovcnt == 1) return ld_read(fd, iov[0].iov_base, iov[0].iov_len, raw_read, e);
    size_t total = 0;
    for (int i = 0; i < iovcnt; i++) total += iov[i].iov_len;
    if (!total) return 0;
    if (total > BSH_LD_CHUNK) total = BSH_LD_CHUNK;
    char* tmp = (char*)malloc(total);
    if (!tmp) return real(fd, iov, iovcnt);
    ssize_t r = ld_read(fd, tmp, total, raw_read, e);
    if (r > 0) {
        size_t off = 0;
        for (int i = 0; i < iovcnt && off < (size_t)r; i++) {
            size_t k = iov[i].iov_len;
            if (k > (size_t)r - off) k = (size_t)r - off;
            memcpy(iov[i].iov_base, tmp + off, k);
            off += k;
        }
    }
    free(tmp);
    return r;
}

ssize_t BSH_PLAIN(writev)(int fd, const struct iovec* iov, int iovcnt) {
    static ssize_t (*real)(int, const struct iovec*, int);
    if (!REAL1(real, writev)) { errno = ENOSYS; return -1; }
    struct pty_ent* e;
    if (!is_master_fd(fd, &e) || iovcnt <= 0) return real(fd, iov, iovcnt);
    if (iovcnt == 1) return ld_write(fd, iov[0].iov_base, iov[0].iov_len, raw_write, e);
    size_t total = 0;
    for (int i = 0; i < iovcnt; i++) total += iov[i].iov_len;
    if (!total) return 0;
    char* tmp = (char*)malloc(total);
    if (!tmp) return real(fd, iov, iovcnt);
    size_t off = 0;
    for (int i = 0; i < iovcnt; i++) { memcpy(tmp + off, iov[i].iov_base, iov[i].iov_len); off += iov[i].iov_len; }
    ssize_t r = ld_write(fd, tmp, total, raw_write, e);
    free(tmp);
    return r;
}


// ─────────────────────── 本机自测用：完整的一份 shim ───────────────────────
//
// 合并进 guest shim 时（-DBSH_SHIM_MERGED_OPEN），下面的 libc 同名入口都让位：
//   open/openat  → shim/open_shim.c（它再问 bsh_tty_maybe_open → 本模块）
//   isatty/ioctl/ttyname(_r) → shim/tty_shim.c（它调用本模块的 bsh_pty_* 钩子）

#ifndef BSH_SHIM_MERGED_OPEN

// ioctl 的第二个参数：musl 声明成 int，glibc 声明成 unsigned long（同 tty_shim.c）。
#ifdef __GLIBC__
typedef unsigned long bsh_pty_req_t;
#else
typedef int bsh_pty_req_t;
#endif

// /dev/tty：有控制终端就 dup 它；没有就 ENXIO（与真 open("/dev/tty") 无控制终端时
// 的行为一致）。合并模式下这段逻辑在 tty_shim.c 里，这里只是本机自测的替身。
static int standalone_open_devtty(void) {
    pty_init();
    if (g_ctty_fd >= 0) {
        int cp = (int)syscall(SYS_fcntl, g_ctty_fd, F_DUPFD, 0);
        if (cp >= 0) {
            if (cp < BSH_FD_MAX) g_slave_pts[cp] = g_slave_pts[g_ctty_fd];
            return cp;
        }
    }
    errno = ENXIO;
    return -1;
}

int open(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (!bsh_null(path) && strcmp(path, "/dev/tty") == 0) return standalone_open_devtty();
    int r = bsh_pty_maybe_open(path);
    if (r != -2) return r;
    return (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
}

int openat(int dirfd, const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (dirfd == AT_FDCWD) {
        if (!bsh_null(path) && strcmp(path, "/dev/tty") == 0) return standalone_open_devtty();
        int r = bsh_pty_maybe_open(path);
        if (r != -2) return r;
    }
    return (int)syscall(SYS_openat, dirfd, path, flags, mode);
}

#ifdef __GLIBC__
int open64(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (!bsh_null(path) && strcmp(path, "/dev/tty") == 0) return standalone_open_devtty();
    int r = bsh_pty_maybe_open(path);
    if (r != -2) return r;
    return (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
}

int openat64(int dirfd, const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (dirfd == AT_FDCWD) {
        int r = bsh_pty_maybe_open(path);
        if (r != -2) return r;
    }
    return (int)syscall(SYS_openat, dirfd, path, flags, mode);
}
#endif

int isatty(int fd) {
    pty_init();
    if (g_slave_pts[fd] >= 0) return 1;
    struct termios t;
    return (int)syscall(SYS_ioctl, fd, TCGETS, &t) == 0 ? 1 : 0;
}

int ioctl(int fd, bsh_pty_req_t request, ...) {
    va_list ap;
    va_start(ap, request);
    void* arg = va_arg(ap, void*);
    va_end(ap);
    int res = 0;
    if (bsh_pty_ioctl(fd, (unsigned long)request, arg, &res)) return res;
    return (int)syscall(SYS_ioctl, fd, request, arg);
}

int ttyname_r(int fd, char* buf, size_t n) {
    int r = bsh_pty_fd_name(fd, buf, n);
    if (r == 1) return 0;
    if (r == -1) return ERANGE;
    static int (*real)(int, char*, size_t);
    if (!REAL1(real, "ttyname_r")) { errno = ENOSYS; return ENOSYS; }
    return real(fd, buf, n);
}

char* ttyname(int fd) {
    static char buf[64];
    if (ttyname_r(fd, buf, sizeof buf) == 0) return buf;
    return NULL;
}

#endif  // !BSH_SHIM_MERGED_OPEN
