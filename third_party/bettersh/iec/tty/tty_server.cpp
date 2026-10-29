// tty/tty_server.cpp — TtyServer implementation
//
// Faking a pty, with the server standing in the middle of the data path.
//
// The sandboxed client cannot open /dev/ptmx, so the pair it gets is built out
// of two socketpairs instead of one:
//
//   pair A:  A[0] -> the client, in the role of the master
//            A[1] -> us
//   pair B:  B[0] -> us
//            B[1] -> the client, in the role of the slave, handed over the
//                    first time it opens /dev/pts/<n>
//
// Keeping an end of each pair is the whole point: every byte crosses this
// process, so the line discipline the kernel would otherwise run between the two
// ends lives here, next to the termios, the window size and the foreground
// process group it needs.
//
//   read(A[1]) -> input filter  -> B[0]    ICRNL, ISIG, canonical lines, ECHO
//   read(B[0]) -> output filter -> A[1]    OPOST|ONLCR
//
// That is what driving the filters from the client's read() hooks could not do:
// input was only processed once somebody read the terminal, so ^C could not
// interrupt a program that was not reading its stdin, and nothing was echoed
// while nobody read. Here the input is processed when it arrives, and the
// signals come from the process that knows the foreground group.
//
// Nothing on this side ever blocks. One thread serves every pty, so a blocking
// write to a full socket would stall the loop and freeze every terminal at once;
// bytes that do not fit wait in a per-pty queue while the fd is watched for
// POLLOUT. The queues double as flow control: once one grows past kQueueMax its
// source fd leaves the poll set and the peer's write blocks, which is what a real
// pty does with a full buffer.
//
// EOF travels the same road as the data:
//   read(A[1]) == 0  -> close B[0], so the program sees EOF on its stdin
//   read(B[0]) == 0  -> close A[1], so the terminal sees EOF on the master
// and a terminal that goes away hangs its program up on the way out, the way a
// real pty does.
#include "tty_server.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>

#include "logger/logger.h"
#include "proc.h"

namespace {

constexpr int kMaxPtys = 64;
// One canonical line, as much as the client-side emulation used to hold.
constexpr size_t kLineMax = 4096;
// Ceiling on either per-pty queue. Reaching it stops the source from being read
// at all, so this is a bound on how far the program may run ahead of the
// terminal, not just a buffer limit.
constexpr size_t kQueueMax = 64 * 1024;

struct Pty {
    bool used = false;
    int pts_n = 0;
    int term_fd = -1;    // A[1], our end of the terminal side
    int app_fd = -1;     // B[0], our end of the program side
    int slave_fd = -1;   // B[1], ours only until OPENPTS hands it to the client
    // The ends handed to the client, remembered by the inode of the socket each one
    // is. That is the part of them that outlives their fd numbers: the same socket
    // object reports the same inode however it is numbered now, however often it has
    // been dup'd, and across an exec. It is what OP_IDENTIFY matches on when a client
    // has lost which pty one of its descriptors is.
    ino_t ino_master = 0;   // A[0], the end the client holds as its master
    ino_t ino_slave = 0;    // B[1], the end it holds as its slave
    bool term_eof = false;
    bool app_eof = false;
    pid_t fg_pgrp = 0;   // foreground process group of this pty, for signals
    pid_t fg_sid = 0;    // session that group belongs to, as reported by the client
    termios tio {};
    winsize ws {};
    std::vector<uint8_t> line;     // canonical input not yet released
    std::vector<uint8_t> to_app;   // filtered input waiting for room on app_fd
    std::vector<uint8_t> to_term;  // echo and program output waiting on term_fd
};

Pty g_pty[kMaxPtys];
int g_next_pts = 0;

// The inode of a socket, or 0 when there is none to be had. A socketpair gives each
// of its ends an inode of its own, and every name for one end -- a dup, a descriptor
// that has been through SCM_RIGHTS, the same fd after an exec -- reports that one.
ino_t InodeOf(int fd) {
    struct stat st;
    return fstat(fd, &st) == 0 ? st.st_ino : 0;
}

Pty* allocPty() {
    for (int i = 0; i < kMaxPtys; i++)
        if (!g_pty[i].used) return &g_pty[i];
    return nullptr;
}

Pty* findByPts(int pts_n) {
    for (int i = 0; i < kMaxPtys; i++)
        if (g_pty[i].used && g_pty[i].pts_n == pts_n) return &g_pty[i];
    return nullptr;
}

enum class Role { None, Term, App };

// Maps a polled fd back to the pty that owns it. Closed ends carry -1, so a
// stale fd number can only ever be mistaken for a live one of the same pty.
Pty* ptyOwnedBy(int fd, Role& role) {
    for (int i = 0; i < kMaxPtys; i++) {
        Pty& e = g_pty[i];
        if (!e.used) continue;
        if (e.term_fd == fd) { role = Role::Term; return &e; }
        if (e.app_fd == fd)  { role = Role::App;  return &e; }
    }
    role = Role::None;
    return nullptr;
}

void closeFd(int& fd) {
    if (fd >= 0) close(fd);
    fd = -1;
}

// openpty() opens its slave blocking, and the client's end must stay that way:
// O_NONBLOCK lives on the open file description, and the two ends of a
// socketpair are separate descriptions, so this only affects our side.
void setNonBlock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

// What a fresh pty looks like, i.e. a plain cooked terminal.
void initTermios(Pty& e) {
    memset(&e.tio, 0, sizeof e.tio);
    e.tio.c_iflag = ICRNL | IXON;
    e.tio.c_oflag = OPOST | ONLCR;
    // The speed bits are not used by anything here, but a tty that reports
    // 0 baud is not what a program opening a pty expects to find.
    e.tio.c_cflag = CS8 | CREAD | CLOCAL | B38400;
    e.tio.c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN;
    // OHOS's musl fork keeps the speed fields under reserved names; the values
    // are not interpreted here, but a pty that reports 0 baud is not what a
    // program opening one expects.
#if defined(__OHOS__)
    e.tio.__c_ispeed = B38400;
    e.tio.__c_ospeed = B38400;
#else
    e.tio.c_ispeed = B38400;
    e.tio.c_ospeed = B38400;
#endif
    e.tio.c_cc[VMIN] = 1;
    e.tio.c_cc[VTIME] = 0;
    // The control characters matter as much as the flags: a zeroed struct would
    // leave VERASE at NUL and make every NUL byte an erase request.
    e.tio.c_cc[VINTR] = 0x03;    // ^C
    e.tio.c_cc[VQUIT] = 0x1c;    // ^\ -> SIGQUIT
    e.tio.c_cc[VERASE] = 0x7f;   // DEL
    e.tio.c_cc[VKILL] = 0x15;    // ^U
    e.tio.c_cc[VEOF] = 0x04;     // ^D
    e.tio.c_cc[VSUSP] = 0x1a;    // ^Z
    e.ws.ws_row = 24;
    e.ws.ws_col = 80;
}

// Pushes as much of q as the socket will take. False means the peer is gone,
// which is worth exactly as much as reading EOF from it.
bool drainQueue(int fd, std::vector<uint8_t>& q) {
    while (!q.empty()) {
        // MSG_NOSIGNAL, or a program that exits with input still in flight
        // would take the whole server down with SIGPIPE.
        ssize_t w = send(fd, q.data(), q.size(), MSG_NOSIGNAL);
        if (w > 0) {
            q.erase(q.begin(), q.begin() + w);
            continue;
        }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return true;  // POLLOUT will say when
        return false;
    }
    return true;
}

// Signals only ever go to a group we can vouch for. The number is whatever the
// client last passed to tcsetpgrp, and the terminal, the shell that started it
// and this agent's own shell are all one bad kill(-n) away, so it has to look
// like a foreground process group before it is used.
//
// Same session as the server is one shape that proves it. Being the leader of a
// session of its own is the other, and it is the one that matters in practice:
// login_tty() calls setsid() before the program execs, so a shell's foreground
// group is its own session and never the server's.
bool trustedFgPgrp(pid_t pgrp, pid_t sid) {
    if (pgrp <= 0) return false;
    if (pgrp == getpgrp() || pgrp == getpid()) return false;  // never signal ourselves
    if (getsid(pgrp) < 0) return false;                       // no such group any more
    /* Only groups in the session the client told us about.
     *
     * Two looser rules both fail here. "sid == getsid(0)" rejects everything,
     * because login_tty's setsid() gives the pty a session of its own, never the
     * server's. "sid == pgrp" accepts only a session leader, and a shell gives
     * each job its own group with setpgid -- that job is not a session leader,
     * so every Ctrl-C aimed at a running job would be dropped. */
    return sid > 0 && getsid(pgrp) == sid;
}

void signalFg(Pty& e, int sig) {
    if (trustedFgPgrp(e.fg_pgrp, e.fg_sid)) kill(-e.fg_pgrp, sig);
}

// ------------------------------------------------------------------
// Output side: what the program wrote, on its way to the terminal
// ------------------------------------------------------------------

void filterOutput(Pty& e, const uint8_t* in, size_t len) {
    const bool onlcr = (e.tio.c_oflag & OPOST) && (e.tio.c_oflag & ONLCR);

    if (!onlcr) {
        e.to_term.insert(e.to_term.end(), in, in + len);
        return;
    }
    for (size_t i = 0; i < len; i++) {
        if (in[i] == '\n') e.to_term.push_back('\r');
        e.to_term.push_back(in[i]);
    }
}

// ------------------------------------------------------------------
// Input side: what the terminal typed, on its way to the program
// ------------------------------------------------------------------

// Echo goes through the output filter, not straight to the terminal: the kernel
// puts echoed characters on the same output queue as the program's, which is
// what turns the echo of a return into CRLF.
void echoByte(Pty& e, unsigned char c) {
    uint8_t out[2];
    size_t n = 1;

    if ((e.tio.c_lflag & ECHOCTL) && c < 0x20 && c != '\t' && c != '\n') {
        out[0] = '^';
        out[1] = static_cast<uint8_t>(c + '@');
        n = 2;
    } else {
        out[0] = c;
    }
    filterOutput(e, out, n);
}

void echoErase(Pty& e) {
    static const uint8_t backspace_space_backspace[3] = {'\b', ' ', '\b'};
    filterOutput(e, backspace_space_backspace, sizeof backspace_space_backspace);
}

// Hands the assembled line to the program. Canonical mode means the program
// only ever sees complete lines, which is why it can block in read() until the
// user presses return and why the queue behind it needs no line boundaries.
void releaseLine(Pty& e) {
    e.to_app.insert(e.to_app.end(), e.line.begin(), e.line.end());
    e.line.clear();
}

void filterInput(Pty& e, const uint8_t* in, size_t len) {
    const bool canon = (e.tio.c_lflag & ICANON) != 0;
    const bool echo = (e.tio.c_lflag & ECHO) != 0;

    for (size_t i = 0; i < len; i++) {
        unsigned char c = in[i];

        if ((e.tio.c_iflag & ICRNL) && c == '\r') c = '\n';

        if ((e.tio.c_lflag & ISIG) &&
            (c == e.tio.c_cc[VINTR] || c == e.tio.c_cc[VQUIT] ||
             c == e.tio.c_cc[VSUSP])) {
            int sig = c == e.tio.c_cc[VINTR] ? SIGINT
                    : c == e.tio.c_cc[VQUIT] ? SIGQUIT
                                             : SIGTSTP;
            if (echo) echoByte(e, c);
            signalFg(e, sig);
            e.line.clear();  // the partly typed line goes with the signal
            continue;
        }

        if (canon && e.tio.c_cc[VERASE] != _POSIX_VDISABLE &&
            c == e.tio.c_cc[VERASE]) {
            if (!e.line.empty()) {
                e.line.pop_back();
                if (echo && (e.tio.c_lflag & ECHOE)) echoErase(e);
            }
            continue;
        }

        e.line.push_back(c);
        if (echo || (canon && (e.tio.c_lflag & ECHONL) && c == '\n'))
            echoByte(e, c);

        if (!canon || c == '\n') releaseLine(e);

        // A line that never ends must still make room for the rest of the
        // terminal: release what has piled up rather than grow without bound.
        if (e.line.size() >= kLineMax) releaseLine(e);
    }
}

// ------------------------------------------------------------------
// End of life for the two sides
// ------------------------------------------------------------------

// read(A[1]) == 0: the terminal is gone. The program is not getting any more
// input, and closing our end of the program pair is how it finds out.
void termGone(Pty& e) {
    // A real pty also hangs the session up at this point. Without it a shell
    // outlives its terminal and keeps running with nowhere to read or write,
    // which is what "closing the window leaves stray processes behind" looks
    // like from the outside.
    if (e.fg_pgrp > 0) signalFg(e, SIGHUP);

    e.term_eof = true;
    closeFd(e.term_fd);
    closeFd(e.app_fd);
    // An unclaimed slave can never be opened now that the master is gone.
    closeFd(e.slave_fd);
    e.app_eof = true;
    e.line.clear();
    e.to_app.clear();
    e.to_term.clear();
}

// read(B[0]) == 0, or a write that nobody is there to take: every copy of the
// slave is closed and the program side is finished.
void appGone(Pty& e) {
    e.app_eof = true;
    closeFd(e.app_fd);
    e.to_app.clear();
}

void flushToTerm(Pty& e) {
    if (e.term_fd >= 0 && !drainQueue(e.term_fd, e.to_term)) termGone(e);
}

void flushToApp(Pty& e) {
    if (e.app_fd >= 0 && !drainQueue(e.app_fd, e.to_app)) appGone(e);
}

void maybeReap(Pty& e) {
    // The master is held open just long enough for the terminal to collect the
    // output still queued behind it; closing it sooner would drop that.
    if (e.app_eof && e.to_term.empty()) closeFd(e.term_fd);
    if (e.term_fd < 0 && e.app_fd < 0 && e.slave_fd < 0) e = Pty();
}

// Every pty request names its pts in the first body word; the fd numbers the
// client holds mean nothing on this side. The size is checked exactly, so a
// truncated struct never reaches memcpy.
Pty* ptyOfRequest(const Packet& req, size_t body_len) {
    if (req.body.size() != body_len || body_len < 4) return nullptr;
    return findByPts(static_cast<int>(get32(req.body.data())));
}

}  // namespace

TtyServer::TtyServer(const std::string& path) : SockServer(path) {
    using namespace std::placeholders;
    registerHandler(OP_PING,       std::bind(&TtyServer::onPing, this, _1, _2));
    registerHandler(OP_PONG,       std::bind(&TtyServer::onPong, this, _1, _2));
    registerHandler(OP_FORKPTY,    std::bind(&TtyServer::onForkpty, this, _1, _2));
    registerHandler(OP_OPENPTMX,   std::bind(&TtyServer::onOpenPtmx, this, _1, _2));
    registerHandler(OP_OPENPTS,    std::bind(&TtyServer::onOpenPts, this, _1, _2));
    registerHandler(OP_TCGETATTR,  std::bind(&TtyServer::onTcgetattr, this, _1, _2));
    registerHandler(OP_TCSETATTR,  std::bind(&TtyServer::onTcsetattr, this, _1, _2));
    registerHandler(OP_TCGETPGRP,  std::bind(&TtyServer::onTcgetpgrp, this, _1, _2));
    registerHandler(OP_TCSETPGRP,  std::bind(&TtyServer::onTcsetpgrp, this, _1, _2));
    registerHandler(OP_GETWINSZ,   std::bind(&TtyServer::onGetWinsz, this, _1, _2));
    registerHandler(OP_SETWINSZ,   std::bind(&TtyServer::onSetWinsz, this, _1, _2));
    registerHandler(OP_IDENTIFY,   std::bind(&TtyServer::onIdentify, this, _1, _2));
}

bool TtyServer::onPing(const Packet& req, Reply& reply) {
    reply.body = req.body;
    return true;
}

bool TtyServer::onPong(const Packet& req, Reply& reply) {
    // The client never sends a pong; this only occupies the op number.
    (void)req;
    (void)reply;
    return true;
}

bool TtyServer::onForkpty(const Packet& req, Reply& reply) {
    // Reserved: the shim builds forkpty() out of openpty() + fork() + login_tty()
    // on the client side, so this is not called.
    (void)req;
    putStr(reply.body, "Not implemented for now!\n");
    return true;
}

bool TtyServer::onOpenPtmx(const Packet& req, Reply& reply) {
    (void)req;

    int a[2] = {-1, -1};
    int b[2] = {-1, -1};

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, a) < 0) {
        Logger::GetInstance()->LogE("[server] socketpair: %s", strerror(errno));
        return false;
    }
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, b) < 0) {
        Logger::GetInstance()->LogE("[server] socketpair: %s", strerror(errno));
        close(a[0]);
        close(a[1]);
        return false;
    }

    Pty* e = allocPty();
    if (!e) {
        Logger::GetInstance()->LogE("[server] openptmx: out of pty slots");
        close(a[0]); close(a[1]);
        close(b[0]); close(b[1]);
        return false;
    }

    setNonBlock(a[1]);
    setNonBlock(b[0]);

    e->used = true;
    e->pts_n = g_next_pts++;
    e->term_fd = a[1];
    e->app_fd = b[0];
    e->slave_fd = b[1];
    // No foreground group until the client names one: the number would have to
    // come from the client's process table, and guessing it is how a signal
    // ends up in the wrong process. login_tty() names the real one right away.
    e->fg_pgrp = 0;
    e->term_eof = false;
    e->app_eof = false;
    e->ino_master = 0;
    e->ino_slave = 0;
    e->line.clear();
    e->to_app.clear();
    e->to_term.clear();
    initTermios(*e);

    // The client needs the pts number to build "/dev/pts/<n>" later.
    put32(reply.body, static_cast<uint32_t>(e->pts_n));
    // Read before the framework closes it: this is the only moment at which the end
    // the client is about to hold is still here to be named, and its inode is what
    // lets the service recognize that descriptor again (see onIdentify).
    e->ino_master = InodeOf(a[0]);
    // The framework closes a[0] once the kernel has taken its own reference.
    reply.fds.push_back(a[0]);

    Logger::GetInstance()->LogI("[server] /dev/ptmx -> pts/%d (master handed over)", e->pts_n);
    return true;
}

bool TtyServer::onOpenPts(const Packet& req, Reply& reply) {
    if (req.body.size() < 4) return false;

    int pts_n = static_cast<int>(get32(req.body.data()));
    Pty* e = findByPts(pts_n);
    if (!e) {
        Logger::GetInstance()->LogW("[server] openpts: pts/%d not found", pts_n);
        return false;
    }
    if (e->slave_fd < 0) {
        Logger::GetInstance()->LogW("[server] openpts: pts/%d slave already handed over", pts_n);
        return false;
    }

    // Read here for the same reason as the master's in onOpenPtmx: this is the last
    // moment at which the end the client is about to hold is still on this side.
    e->ino_slave = InodeOf(e->slave_fd);
    reply.fds.push_back(e->slave_fd);
    // Transferred, not copied: a second copy here would keep the master from
    // ever seeing the program exit. The client reopens by name with a local dup
    // of the fd it already has.
    e->slave_fd = -1;

    Logger::GetInstance()->LogI("[server] /dev/pts/%d -> slave handed over", pts_n);
    return true;
}

bool TtyServer::onTcgetattr(const Packet& req, Reply& reply) {
    Pty* e = ptyOfRequest(req, 4);
    if (!e) return false;

    const uint8_t* raw = reinterpret_cast<const uint8_t*>(&e->tio);
    reply.body.insert(reply.body.end(), raw, raw + sizeof e->tio);
    return true;
}

bool TtyServer::onTcsetattr(const Packet& req, Reply& reply) {
    Pty* e = ptyOfRequest(req, 8 + sizeof(termios));
    if (!e) return false;

    // The action only chooses which queue to discard, and input is drained
    // continuously here, so TCSANOW/TCSADRAIN/TCSAFLUSH all land in one place.
    memcpy(&e->tio, req.body.data() + 8, sizeof e->tio);
    return true;
}

bool TtyServer::onTcgetpgrp(const Packet& req, Reply& reply) {
    Pty* e = ptyOfRequest(req, 4);
    if (!e) return false;

    // Which group holds this terminal in the foreground depends on which side of the
    // socket is asking. This pty has a holder on each side -- the stand-in the client
    // built with login_tty, and the program the server runs on its stdio -- and they
    // are in different sessions, so the group the client named cannot describe a
    // caller from the other one. Such a caller is told its own group instead, which
    // is what login_tty would have given it on a real terminal: there the process
    // that calls it is made the foreground group itself.
    //
    // This is not a detail. An interactive shell asks this once while starting up and
    // takes "not my group" for an answer by stopping itself with kill(0, SIGTTIN) --
    // which is what the kernel would do to a background process that reads. With the
    // program in the server's process group, that stopped the server and every
    // session on it; see setpgid() in Spawn() for the other half of this.
    pid_t group = e->fg_pgrp;
    if (group > 0 && req.caller > 0) {
        const pid_t caller = static_cast<pid_t>(req.caller);

        // A program the exec server started is a direct child of this process
        // (the tty and exec services share it), while the stand-in that the
        // shell put in the foreground group is a child of the shell. The
        // program gets a process group of its own (see setpgid in Spawn), so
        // the stored group is never its own. Told that, an interactive shell
        // takes itself for a background job, stops reading and never prints a
        // prompt -- which is exactly what a nested "sh" looked like.
        const bool server_child = iec_parent_pid(caller) == getpid();
        if (server_child || getsid(caller) != getsid(group))
            group = getpgid(caller);
    }

    put32(reply.body, static_cast<uint32_t>(group));
    return true;
}

bool TtyServer::onTcsetpgrp(const Packet& req, Reply& reply) {
    // 8 bytes is the pre-session layout, where the client only sent the group;
    // 12 adds the session. ptyOfRequest insists on an exact length, so pass the
    // length we actually received and validate the layout here.
    if (req.body.size() < 8) return false;
    Pty* e = ptyOfRequest(req, req.body.size());
    if (!e) return false;

    e->fg_pgrp = static_cast<pid_t>(get32(req.body.data() + 4));
    e->fg_sid = req.body.size() >= 12
                    ? static_cast<pid_t>(get32(req.body.data() + 8)) : 0;
    return true;
}

bool TtyServer::onGetWinsz(const Packet& req, Reply& reply) {
    Pty* e = ptyOfRequest(req, 4);
    if (!e) return false;

    const uint8_t* raw = reinterpret_cast<const uint8_t*>(&e->ws);
    reply.body.insert(reply.body.end(), raw, raw + sizeof e->ws);
    return true;
}

bool TtyServer::onSetWinsz(const Packet& req, Reply& reply) {
    Pty* e = ptyOfRequest(req, 4 + sizeof(winsize));
    if (!e) return false;

    winsize ws;
    memcpy(&ws, req.body.data() + 4, sizeof ws);
    bool changed = ws.ws_row != e->ws.ws_row || ws.ws_col != e->ws.ws_col;
    // Stored before signalling: a program that handles SIGWINCH by asking for
    // the new size must not be able to see the old one.
    e->ws = ws;
    // The kernel tells the program its window changed instead of making it
    // poll, and a full-screen program that never hears about a resize is what a
    // terminal that cannot be resized looks like from the inside.
    if (changed) signalFg(*e, SIGWINCH);
    return true;
}

// Names the pty a descriptor belongs to, for a client whose shim has lost the
// mapping: an exec replaces the image and the fd table with it, and only the three
// descriptors login_tty takes over can have their pts number carried across one in
// the environment. A terminal left on any other fd, or a program started with an
// environment that does not name the pts at all, has no other way back.
//
// The descriptor arrives over SCM_RIGHTS, so it is the same socket object this
// service handed over -- whatever fd number names it now, however often it has been
// duplicated, and across an exec. What matches it is the inode of the end that was
// sent, which is that object's own and does not change. Two checks keep an unrelated
// descriptor from matching a record whose socket is long gone: it has to be a socket,
// and a socket this process made -- SO_PEERCRED reports the process that created it,
// not whoever holds the far end -- which is what rules out the client's own sockets
// and its connections here.
//
// An empty reply is "not one of mine"; eight bytes are [pts][is_master], which is
// what a shim needs to rebuild its entry, master and slave behaving differently. The
// received fd is not closed here: the framework closes what it handed to a handler.
bool TtyServer::onIdentify(const Packet& req, Reply& reply) {
    struct stat st;
    struct ucred cred;
    socklen_t cred_len = sizeof cred;

    if (req.fds.size() != 1) {
        Logger::GetInstance()->LogW("[server] identify: expected one fd, got %zu", req.fds.size());
        return false;
    }
    int fd = req.fds[0];

    if (fstat(fd, &st) != 0 || !S_ISSOCK(st.st_mode)) return true;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &cred_len) != 0 ||
        cred.pid != getpid())
        return true;

    for (int i = 0; i < kMaxPtys; i++) {
        Pty& e = g_pty[i];
        bool master;
        if (!e.used) continue;
        if (e.ino_master != 0 && st.st_ino == e.ino_master) master = true;
        else if (e.ino_slave != 0 && st.st_ino == e.ino_slave) master = false;
        else continue;
        put32(reply.body, static_cast<uint32_t>(e.pts_n));
        put32(reply.body, master ? 1u : 0u);
        return true;
    }
    return true;   // empty: not one of ours
}

void TtyServer::addPollFds(std::vector<pollfd>& fds) {
    for (int i = 0; i < kMaxPtys; i++) {
        Pty& e = g_pty[i];
        if (!e.used) continue;

        if (e.term_fd >= 0) {
            short ev = POLLIN;
            if (!e.to_term.empty()) ev = static_cast<short>(ev | POLLOUT);
            // Reading ahead of a queue that is already full would break the
            // backpressure: stop taking from the terminal until it drains.
            if (e.to_app.size() >= kQueueMax) ev = static_cast<short>(ev & ~POLLIN);
            fds.push_back(pollfd{e.term_fd, ev, 0});
        }
        if (e.app_fd >= 0) {
            short ev = POLLIN;
            if (!e.to_app.empty()) ev = static_cast<short>(ev | POLLOUT);
            if (e.to_term.size() >= kQueueMax) ev = static_cast<short>(ev & ~POLLIN);
            fds.push_back(pollfd{e.app_fd, ev, 0});
        }
    }
}

void TtyServer::pollEvent(int fd, short revents) {
    Role role = Role::None;
    Pty* e = ptyOwnedBy(fd, role);
    if (!e) return;

    if (role == Role::Term) {
        if (revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t buf[4096];
            while (e->to_app.size() < kQueueMax) {
                ssize_t r = read(fd, buf, sizeof buf);
                if (r > 0) {
                    filterInput(*e, buf, static_cast<size_t>(r));
                    continue;
                }
                if (r < 0 && errno == EINTR) continue;
                if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
                // r == 0, or a read error: the terminal side is finished.
                termGone(*e);
                break;
            }
        }
        if (e->term_fd >= 0 && (revents & POLLOUT)) flushToTerm(*e);
    } else {
        if (revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t buf[4096];
            while (e->to_term.size() < kQueueMax) {
                ssize_t r = read(fd, buf, sizeof buf);
                if (r > 0) {
                    filterOutput(*e, buf, static_cast<size_t>(r));
                    continue;
                }
                if (r < 0 && errno == EINTR) continue;
                if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
                appGone(*e);
                break;
            }
        }
        if (e->app_fd >= 0 && (revents & POLLOUT)) flushToApp(*e);
    }

    // Whatever the other direction is still owed goes out now: an input byte
    // has to reach the program in the same round it was typed, or a terminal
    // that is not being read would sit on the echo of its own keystrokes.
    flushToApp(*e);
    flushToTerm(*e);
    maybeReap(*e);
}
