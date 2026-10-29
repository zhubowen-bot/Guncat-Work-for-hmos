// entry/src/main/cpp/tty/bsh_pty.c
// --wrap=forkpty:
// 沙箱无真 pty → socketpair 替代:master 留 westerm 读写,slave 作子进程 0/1/2;
// 子进程随后 execl(shell) 由 __wrap_execl 委托 BetterSH 主进程(mksh),
// slave fd 经 FDREF/SCM_RIGHTS 送达作为其 stdio → 终端管道闭环。
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#include "common/bsh_paths.h"

/* 共享 winsize 文件:weston-terminal(客户端)经 ioctl(TIOCSWINSZ) 更新 pty 行列;
 * guest shell(spawn 子进程)注册伪 tty 时读同一文件 → 行列一致,输出不再按
 * 固定 80x24 回绕。shell 总在建窗/ioctl 之后 spawn,读到即最新值。
 * 路径来自 common/bsh_paths.h(与宿主同一份定义);本文件被编进 libwestterm.so,
 * 所以那个脚本要给 -I 到 cpp 根。 */
#define BSH_WS_DEF_ROWS 24
#define BSH_WS_DEF_COLS 80

static int bsh_ws_read(uint16_t* rows, uint16_t* cols) {
    int fd = open(bsh_ws_file_path(), O_RDWR | O_CREAT, 0644);
    if (fd < 0) return -1;
    uint8_t buf[4] = {0};
    ssize_t n = read(fd, buf, sizeof buf);
    close(fd);
    if (n == (ssize_t)sizeof buf) {
        *rows = (uint16_t)(buf[0] | (buf[1] << 8));
        *cols = (uint16_t)(buf[2] | (buf[3] << 8));
        return 0;
    }
    return -1;
}

static int bsh_ws_write(uint16_t rows, uint16_t cols) {
    int fd = open(bsh_ws_file_path(), O_RDWR | O_CREAT, 0644);
    if (fd < 0) return -1;
    uint8_t buf[4];
    buf[0] = (uint8_t)(rows & 0xff); buf[1] = (uint8_t)(rows >> 8);
    buf[2] = (uint8_t)(cols & 0xff); buf[3] = (uint8_t)(cols >> 8);
    ssize_t n = write(fd, buf, sizeof buf);
    if (n != (ssize_t)sizeof buf) { close(fd); return -1; }
    close(fd);
    return 0;
}

/* 导出给主进程(softpty register_standalone)读取当前共享行列 */
int bsh_tty_shared_ws(uint16_t* rows, uint16_t* cols) {
    if (bsh_ws_read(rows, cols) == 0) return 0;
    *rows = BSH_WS_DEF_ROWS;
    *cols = BSH_WS_DEF_COLS;
    return 0;
}

/* weston-terminal 对 pty master 的 winsize 更新 → 落共享文件 */
extern int __real_ioctl(int fd, unsigned long req, ...);
int __wrap_ioctl(int fd, unsigned long req, ...) {
    (void)fd;
    va_list ap;
    va_start(ap, req);
    void* arg = va_arg(ap, void*);
    va_end(ap);
    if (req == TIOCSWINSZ) {
        struct winsize* ws = (struct winsize*)arg;
        if (ws && ws->ws_row > 0 && ws->ws_col > 0) {
            bsh_ws_write((uint16_t)ws->ws_row, (uint16_t)ws->ws_col);
            return 0;   // 模拟 pty 更新成功
        }
        return 0;
    }
    if (req == TIOCGWINSZ) {
        struct winsize* ws = (struct winsize*)arg;
        if (ws) {
            uint16_t r, c;
            if (bsh_ws_read(&r, &c) != 0) { r = BSH_WS_DEF_ROWS; c = BSH_WS_DEF_COLS; }
            ws->ws_row = r;
            ws->ws_col = c;
            return 0;
        }
        return 0;
    }
    return __real_ioctl(fd, req, arg);
}

/* 输出 ONLCR:weston 终端通过 read(master) 读 guest 输出;socket 伪 pty 无内核
 * OPOST/ONLCR,guest 只写 \n → weston 只下移不回行首 → 输出错位。
 * wrap read 仅对 pty master fd 生效,把 \n(前面无 \r)扩展为 \r\n。
 *
 * 注意 EAGAIN/EINTR 的处理:master 在《terminal_run》里被设成 O_NONBLOCK,
 * epoll 报可读但这次 read 仍可能空手而归;而 weston 的 io_handler 把 len<0
 * 一律当作读错误 → terminal_destroy → display_exit,整个 westterm 会"正常"
 * 退出(code=0、窗口空白)。所以这两种情况必须与真错误区分开。 */
static int g_ptyMfd = -1;      // __wrap_forkpty 记录的 master fd
static char g_pend[8192];
static int  g_pendLen = 0;
static int  g_lastCr = 0;

extern ssize_t __real_read(int fd, void* buf, size_t count);
ssize_t __wrap_read(int fd, void* buf, size_t count) {
    if (fd != g_ptyMfd)
        return __real_read(fd, buf, count);
    while (g_pendLen == 0) {
        char tmp[4096];
        ssize_t r = __real_read(fd, tmp, sizeof tmp);
        if (r < 0) {
            if (errno == EINTR) continue;                          // 被信号打断:重试
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;  // 暂无数据(非错误)
            return r;                                              // 真错误:交给上层
        }
        if (r == 0) return 0;   // EOF
        for (ssize_t i = 0; i < r; i++) {
            unsigned char c = (unsigned char)tmp[i];
            if (c == '\n' && !g_lastCr) {
                if (g_pendLen + 2 <= (int)sizeof g_pend) {
                    g_pend[g_pendLen++] = '\r';
                    g_pend[g_pendLen++] = '\n';
                }
            } else {
                if (g_pendLen + 1 <= (int)sizeof g_pend)
                    g_pend[g_pendLen++] = (char)c;
            }
            g_lastCr = (c == '\r');
        }
    }
    size_t take = (size_t)g_pendLen < count ? (size_t)g_pendLen : count;
    memcpy(buf, g_pend, take);
    memmove(g_pend, g_pend + take, (size_t)g_pendLen - take);
    g_pendLen -= (int)take;
    return (ssize_t)take;
}

pid_t __wrap_forkpty(int* amaster, char* name,
                     const struct termios* tp, const struct winsize* wp) {
    (void)name; (void)tp;
    if (wp && wp->ws_row > 0 && wp->ws_col > 0)
        bsh_ws_write((uint16_t)wp->ws_row, (uint16_t)wp->ws_col);   // forkpty 初始 winsize
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) < 0)
        return -1;

    /* slave 再复制一份到**高位 fd**,子进程用它做 dup2。
     *
     * 为什么不用 sv[1] 本身(实测踩过的坑):westterm 链接了 cairo/fontconfig/
     * xkbcommon/libwayland 一堆库,它们(或其 atfork 逻辑)在 fork 前后也在**低位
     * fd 区间**反复分配/复用 fd。结果是同一个 fd 号在父进程里还是 socketpair 的
     * socket、到子进程就成了别的东西(实测拿到的是管道),dup2 之后 mksh 的 stdio
     * 根本不是那个伪 pty → slave 端无人持有 → master 立刻 EPOLLHUP → westterm
     * 销毁终端并退出(表现为窗口空白、退出码 0)。
     * 挪到 200 以上的高位号就避开了那片被争抢的区域。 */
    int sv1_hi = fcntl(sv[1], F_DUPFD_CLOEXEC, 200);
    if (sv1_hi < 0) sv1_hi = sv[1];   /* 退化:至少不比原来差 */

    pid_t pid = fork();
    if (pid < 0) {
        close(sv[0]);
        close(sv[1]);
        if (sv1_hi != sv[1]) close(sv1_hi);
        return -1;
    }
    if (pid == 0) {
        // child:slave → 0/1/2;随后原代码 execl → __wrap_execl 委托
        close(sv[0]);
        dup2(sv1_hi, 0);
        dup2(sv1_hi, 1);
        dup2(sv1_hi, 2);
        if (sv1_hi > 2) close(sv1_hi);
        return 0;
    }
    close(sv[1]);
    if (sv1_hi != sv[1]) close(sv1_hi);
    g_ptyMfd = sv[0];
    g_pendLen = 0;
    g_lastCr = 0;
    if (amaster) *amaster = sv[0];
    return pid;
}
