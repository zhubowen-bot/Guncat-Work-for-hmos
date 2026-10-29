// tty/softpty.cpp — 软伪终端实现
#include "softpty.h"

#include <cstring>
#include <unistd.h>

namespace bsh {

static void InitDefaultTermios(struct termios* t) {
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

bool PseudoTtyCreate(PseudoTty* p) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0)
        return false;
    p->master = sv[0];
    p->slave  = sv[1];
    InitDefaultTermios(&p->tio);
    return true;
}

void PseudoTtyClose(PseudoTty* p) {
    if (p->master >= 0) { ::close(p->master); p->master = -1; }
    if (p->slave  >= 0) { ::close(p->slave);  p->slave  = -1; }
}

void PseudoTtySetSize(PseudoTty* p, uint16_t rows, uint16_t cols) {
    p->ws.ws_row = rows;
    p->ws.ws_col = cols;
}

void PseudoTtyGetSize(const PseudoTty* p, uint16_t* rows, uint16_t* cols) {
    *rows = p->ws.ws_row;
    *cols = p->ws.ws_col;
}

}  // namespace bsh
