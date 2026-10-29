// tty/bsh_tty.cpp — 会话软 tty 状态实现(宿主侧,唯一真相)
//
// 见 bsh_tty.h 头注释。状态只有一份:mmap(MAP_SHARED) 出来的 PtyTtyState。
// 宿主 shell 用它转发输入信号、同步窗口尺寸;命令 so 经 procmgr 的 control
// socket(CMD TTY)读写同一份 —— 所以这里**不再有 fd 维度**(那部分由命令 so
// 自己的 tty_shim 本地维护)。
#include "bsh_tty.h"

#include <termios.h>
#include <unistd.h>

#include <atomic>
#include <csignal>
#include <cstring>
#include <sys/mman.h>

namespace {

struct PtyTtyState {
    struct termios tio;
    uint16_t rows = 24;
    uint16_t cols = 80;
    pid_t fg_pgrp = 0;
};

// 会话共享状态(MAP_SHARED):fork 出的命令继承同一映射。**每个 sid 一份** ——
// 两个会话的 termios/winsize/前台组互不相干(见 bsh_tty.h 的 BSH_SID_MAX)。
// 指针为 null = 那个会话还没建(或建失败),取值时退化到进程内那份。
PtyTtyState* g_shared[BSH_SID_MAX];

void InitDefaultTermios(struct termios* t) {
    memset(t, 0, sizeof(*t));
    t->c_iflag = ICRNL | IXON;
    t->c_oflag = OPOST | ONLCR;
    t->c_cflag = B38400 | CS8 | CREAD;
    t->c_lflag = ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ISIG | IEXTEN;
    t->c_cc[VINTR]  = 3;    // Ctrl+C
    t->c_cc[VQUIT]  = 28;
    t->c_cc[VERASE] = 127;  // DEL
    t->c_cc[VKILL]  = 21;
    t->c_cc[VEOF]   = 4;
    t->c_cc[VMIN]   = 1;
    t->c_cc[VTIME]  = 0;
    t->c_cc[VSUSP]  = 26;
    t->c_cc[VSTART] = 17;
    t->c_cc[VSTOP]  = 19;
}

// 前端 xterm 最近一次报告的实际网格尺寸(跨线程,原子读)。按 sid 分,因为每个窗口
// 的网格是各自的;这个值只在 init_shared(rows==0)时当初始值用一次。
struct TtySize {
    std::atomic<uint16_t> rows{24};
    std::atomic<uint16_t> cols{80};
};
TtySize g_size[BSH_SID_MAX];

// sid 越界或那一份没建时的进程内退路:功能可用,只是不跨进程共享
PtyTtyState* Fallback() {
    static PtyTtyState s;
    static bool init = false;
    if (!init) {
        init = true;
        InitDefaultTermios(&s.tio);
        s.fg_pgrp = getpgrp();
    }
    return &s;
}

PtyTtyState* S(int sid) {
    if (sid < 0 || sid >= BSH_SID_MAX) return Fallback();
    return g_shared[sid] ? g_shared[sid] : Fallback();
}

}  // namespace

extern "C" {

int bsh_tty_session_tcgetattr(int sid, struct termios* t) {
    if (!t) return -1;
    *t = S(sid)->tio;
    return 0;
}

int bsh_tty_session_tcsetattr(int sid, const struct termios* t) {
    if (!t) return -1;
    S(sid)->tio = *t;
    return 0;
}

int bsh_tty_session_get_winsize(int sid, uint16_t* rows, uint16_t* cols) {
    PtyTtyState* s = S(sid);
    if (rows) *rows = s->rows;
    if (cols) *cols = s->cols;
    return 0;
}

int bsh_tty_session_set_winsize(int sid, uint16_t rows, uint16_t cols) {
    PtyTtyState* s = S(sid);
    if (rows > 0) s->rows = rows;
    if (cols > 0) s->cols = cols;
    return 0;
}

int bsh_tty_session_get_pgrp(int sid) {
    PtyTtyState* s = S(sid);
    return s->fg_pgrp > 0 ? s->fg_pgrp : (int)getpid();
}

int bsh_tty_session_set_pgrp(int sid, int pgrp) {
    S(sid)->fg_pgrp = pgrp;
    return 0;
}

void bsh_tty_session_reset_pgrp(int sid) {
    /* 只对 bsh 会话(0)有意义:别的会话是独立进程里的 shell 在管自己的前台组
     * (经 tty_shim → pgrp_set 报上来),宿主"当前进程组"和它没关系。 */
    if (sid != 0 || !g_shared[0]) return;
    g_shared[0]->fg_pgrp = getpgrp();
}

void bsh_tty_set_shell_size(int sid, uint16_t rows, uint16_t cols) {
    if (sid < 0 || sid >= BSH_SID_MAX) return;
    if (rows > 0) g_size[sid].rows.store(rows);
    if (cols > 0) g_size[sid].cols.store(cols);
    if (g_shared[sid]) {
        if (rows > 0) g_shared[sid]->rows = rows;
        if (cols > 0) g_shared[sid]->cols = cols;
    }
}

void bsh_tty_init_shared(int sid, uint16_t rows, uint16_t cols) {
    if (sid < 0 || sid >= BSH_SID_MAX) return;
    if (g_shared[sid]) return;
    void* m = mmap(nullptr, sizeof(PtyTtyState), PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return;   // 退化到进程内状态
    PtyTtyState* s = static_cast<PtyTtyState*>(m);
    InitDefaultTermios(&s->tio);
    s->rows = rows > 0 ? rows : g_size[sid].rows.load();
    s->cols = cols > 0 ? cols : g_size[sid].cols.load();
    s->fg_pgrp = getpgrp();
    g_shared[sid] = s;
}

int bsh_tty_forward_sig(int sid, unsigned char c, int fallback_pid) {
    if (sid < 0 || sid >= BSH_SID_MAX || !g_shared[sid]) return 0;
    PtyTtyState* sh = g_shared[sid];
    if (!(sh->tio.c_lflag & ISIG)) return 0;
    int sig = 0;
    if (c == sh->tio.c_cc[VINTR])      sig = SIGINT;
    else if (c == sh->tio.c_cc[VQUIT]) sig = SIGQUIT;
    else if (c == sh->tio.c_cc[VSUSP]) sig = SIGTSTP;
    if (!sig) return 0;
    pid_t fg = sh->fg_pgrp;
    int sent = 0;
    // 前台进程组要发,fallback_pid 也要发 —— 两个指向的不是同一个进程:
    // 交互式 shell(mksh)会把自己的直接子进程设为前台组,但那个子进程只是"委托
    // 中间体"(它阻塞在 control socket 上等 procmgr 的响应);真正干活的是 procmgr
    // 在主进程里 fork 出来的那个(procmgr 的 hook 把它记成 fallback_pid)。
    // 只发进程组 → 中间体死了、真进程还在;只发 fallback → 中间体会残留。
    if (fg > 1 && fg != getpgrp()) { kill(-fg, sig); sent = 1; }
    if (fallback_pid > 0 && fallback_pid != fg) { kill(fallback_pid, sig); sent = 1; }
    return sent;
}

void bsh_tty_forward_winch(int sid, int fallback_pid) {
    if (sid < 0 || sid >= BSH_SID_MAX || !g_shared[sid]) return;
    // 双目标与 bsh_tty_forward_sig 同理:前台进程组里的"委托中间体"和
    // procmgr 真正 fork 出来的那个进程不是同一个,两个都要发。
    pid_t fg = g_shared[sid]->fg_pgrp;
    if (fg > 1 && fg != getpgrp()) kill(-fg, SIGWINCH);
    if (fallback_pid > 0 && fallback_pid != fg) kill(fallback_pid, SIGWINCH);
}

unsigned char bsh_tty_input_translate(int sid, unsigned char c) {
    struct termios t;
    if (bsh_tty_session_tcgetattr(sid, &t) != 0) return c;
    if ((t.c_iflag & ICRNL) && c == '\r') return '\n';
    return c;
}

}  // extern "C"
