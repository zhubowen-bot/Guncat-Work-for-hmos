// tty/shim.c — client-side interception of the pty API
//
// A sandboxed client cannot open /dev/ptmx, so every entry point that would
// touch a real pty is rerouted to the out-of-process tty server over a Unix
// domain socket. The server answers with real file descriptors (passed back with
// SCM_RIGHTS), and those are returned to the caller as if it had opened them
// locally. The fds are ordinary socketpair ends, so read()/write() work on them
// with no further interception -- which is why nothing here hooks read(): the
// server holds the far end of both socketpairs and runs the line discipline
// itself, the moment input arrives.
//
// What the client gets is not a tty, though, so the tty-flavoured calls are
// answered here. They fall into two groups. The ones that ask which terminal an
// fd is (isatty, ttyname, TIOCGPTN, the byte routing of open()) are answered
// from the local fd table and, where that table has nothing to say -- which is
// what an exec leaves behind -- by asking the service which pty the descriptor
// is again; see identify(). The ones that describe terminal state -- termios,
// window size, foreground process group -- are asked of the server, which owns
// that state because it is the only process that can act on it: it is the one
// that sees every keystroke and the one that raises the signals.
//
// Everything that is not pty-related falls through to the real libc function.

#include "constant.h"
#include "intercept.h"
#include "rpc.h"
#include "sock_operation.h"

#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>
/* login_tty() is declared here, not in pty.h. */
#include <utmp.h>

/* The paths this shim and the service have to agree on live in constant.h; SHIM_MAX_FD is
 * this file's own business -- how many descriptors the table above can hold. */
#define SHIM_MAX_FD   256

#ifdef INT_WARP
/* -Wl,--wrap=<name> has the linker provide the original function under
 * __real_<name>, but the compiler still needs a declaration to reference it. */
extern int __real_open(const char *, int, ...);
extern int __real_close(int);
extern int __real_dup(int);
extern int __real_dup2(int, int);
extern int __real_dup3(int, int, int);
extern int __real_fcntl(int, int, ...);
extern int __real_ioctl(int, unsigned long, ...);
extern int __real_isatty(int);
extern int __real_tcgetattr(int, struct termios *);
extern int __real_tcsetattr(int, int, const struct termios *);
extern pid_t __real_tcgetpgrp(int);
extern int __real_tcsetpgrp(int, pid_t);
extern int __real_grantpt(int);
extern int __real_unlockpt(int);
extern char *__real_ptsname(int);
extern char *__real_ttyname(int);
extern int __real_ttyname_r(int, char *, size_t);
#endif

/* Resolves the real libc function, once. Under INT_PRELOAD this is a
 * dlsym(RTLD_NEXT); under INT_WARP it is the linker-provided __real_<name>.
 * IEC_REAL already performs the assignment, so use this as a plain statement:
 * writing "ptr = IEC_REAL(ptr, name)" would assign ptr twice without a sequence
 * point between them. */
#define RESOLVE(ptr, name) IEC_REAL(ptr, name)

static int (*real_open)(const char *, int, ...);
static int (*real_close)(int);
static int (*real_dup)(int);
static int (*real_dup2)(int, int);
static int (*real_dup3)(int, int, int);
static int (*real_fcntl)(int, int, ...);
static int (*real_ioctl)(int, unsigned long, ...);
static int (*real_isatty)(int);
static int (*real_tcgetattr)(int, struct termios *);
static int (*real_tcsetattr)(int, int, const struct termios *);
static pid_t (*real_tcgetpgrp)(int);
static int (*real_tcsetpgrp)(int, pid_t);
static int (*real_grantpt)(int);
static int (*real_unlockpt)(int);
static char *(*real_ptsname)(int);
static char *(*real_ttyname)(int);
static int (*real_ttyname_r)(int, char *, size_t);

#define IEC_TTY_ENV   "IEC_TTY_PTS"

/* ------------------------------------------------------------------ */
/* fd table                                                            */
/*                                                                     */
/* The client keeps only the mapping it cannot ask for: which pts a fd  */
/* came from. Master and slave side of one pts share the number, so the */
/* distinction is kept per fd, not per pts.                            */
/* ------------------------------------------------------------------ */

struct shim_fd {
    int state;
    int is_master;
    int pts_n;
};

/* A fd is one of the service's ptys, known not to be, or not asked about yet. The
 * third state is what keeps identify()'s question to one per fd: tty questions are
 * asked in loops -- stdio asks whether a descriptor is a terminal before it decides
 * how to buffer, readline asks again on every line -- so a round trip per call would
 * be paid by every program with one of these hooks on its path. */
enum { kFdUnasked = 0, kFdOurs, kFdNotOurs };

static struct shim_fd g_fd[SHIM_MAX_FD];

/* Returns the pts number behind an fd, or -1 if this fd is not one of ours. */
static int pts_of(int fd) {
    if (fd < 0 || fd >= SHIM_MAX_FD || g_fd[fd].state != kFdOurs) return -1;
    return g_fd[fd].pts_n;
}

/* Finds an fd in this process that is already bound to the given pts, so that
 * open("/dev/pts/<n>") can be answered with a dup instead of a round trip. A
 * shell reopens its terminal by name in every process it spawns, and the server
 * has long since given its copy of the slave away. */
static int fd_for_pts(int pts_n, int want_master) {
    int fd;
    for (fd = 0; fd < SHIM_MAX_FD; fd++) {
        if (g_fd[fd].state != kFdOurs) continue;
        if (g_fd[fd].pts_n != pts_n) continue;
        if (g_fd[fd].is_master == want_master) return fd;
    }
    return -1;
}

static void tty_set(int fd, int pts_n, int is_master) {
    if (fd < 0 || fd >= SHIM_MAX_FD) return;
    g_fd[fd].state = kFdOurs;
    g_fd[fd].is_master = is_master;
    g_fd[fd].pts_n = pts_n;
}

static void tty_clear(int fd) {
    if (fd >= 0 && fd < SHIM_MAX_FD) memset(&g_fd[fd], 0, sizeof g_fd[fd]);
}

/* dup2() makes a second name for the same tty; keep the table in sync so that
 * isatty(0)/tcgetattr(0) work in the shell child after login_tty(). */
static void tty_copy(int from, int to) {
    if (from < 0 || from >= SHIM_MAX_FD || to < 0 || to >= SHIM_MAX_FD) return;
    if (g_fd[from].state != kFdOurs) return;
    g_fd[to] = g_fd[from];
}

/* forkpty()'s child almost always execs something else, and this table does not
 * survive an exec. login_tty() records the pts number in the environment, and
 * this constructor rebuilds the mapping for fds 0..2 in the new image, so that
 * the shell still sees a tty. The terminal state itself is on the server and
 * needs no rebuilding. */
__attribute__((constructor))
static void shim_resume_from_exec(void) {
    const char *env = getenv(IEC_TTY_ENV);
    int n, fd;

    if (!env || *env < '0' || *env > '9') return;
    n = atoi(env);
    for (fd = STDIN_FILENO; fd <= STDERR_FILENO; fd++) {
        if (fcntl(fd, F_GETFD) < 0) continue;
        tty_set(fd, n, 0);
    }
}

/* ------------------------------------------------------------------ */
/* Server round trip                                                   */
/*                                                                     */
/* The round trip itself is in common/rpc.c, shared with exec/shim.c.  */
/* What is left here is the binding to the tty service's socket, so    */
/* that the call sites below keep reading as a plain rpc_call().       */
/* ------------------------------------------------------------------ */

static uint32_t body_get32(const uint8_t *p) { return iec_get32(p); }

static void body_put32(uint8_t *p, uint32_t v) { iec_put32(p, v); }

static int rpc_call(uint32_t op, const void *body, uint32_t len,
                    void *out, uint32_t out_max, uint32_t *out_len) {
    return iec_rpc_call(TTY_SOCK_PATH, op, body, len, out, out_max, out_len);
}

/* For the one request that carries a descriptor the other way: it is not in the
 * body, it rides along with it. */
static int rpc_call_fds(uint32_t op, const int *fds, int nfds,
                        void *out, uint32_t out_max, uint32_t *out_len) {
    return iec_rpc_call_fds(TTY_SOCK_PATH, op, NULL, 0, fds, nfds, out, out_max, out_len);
}

/* Which pty a descriptor is, asked of the service, for when the table does not
 * know.
 *
 * The table does not survive an exec, and the pts number can only be carried across
 * one in the environment (see shim_resume_from_exec) -- which covers the three
 * descriptors login_tty takes over and nothing else. A terminal left on some other
 * fd, or a program started with an environment that does not name the pts at all,
 * would otherwise see an ordinary socket where its terminal should be and answer
 * isatty() with no. So there is one more way to find out: the service still holds
 * the end it handed over, and the descriptor is that same socket object, so it can
 * name the pty again and the table can be rebuilt for this fd.
 *
 * Only a socket can be one of ours, which is worth checking here: it costs no round
 * trip, it is true of everything else a process holds -- a file, a pipe, a real
 * terminal -- for which the kernel has the answer anyway, and it keeps the question
 * off the path of programs that never had a pty. Whatever the answer turns out to
 * be it is remembered, so a fd is asked about once and not once per call. */
static int identify(int fd) {
    uint8_t resp[8];
    uint32_t len = 0;
    struct stat st;
    int n, is_master;

    int known = pts_of(fd);              /* the table may already know this fd */
    if (known >= 0) return known;
    if (fd < 0 || fd >= SHIM_MAX_FD) return -1;
    if (g_fd[fd].state == kFdNotOurs) return -1;

    if (fstat(fd, &st) != 0 || !S_ISSOCK(st.st_mode)) {
        g_fd[fd].state = kFdNotOurs;
        return -1;
    }

    /* Failing to reach the service is not an answer, so it is not remembered: the
     * next question can still be answered if the service is there by then. */
    if (rpc_call_fds(OP_IDENTIFY, &fd, 1, resp, sizeof resp, &len) < 0) return -1;
    if (len < sizeof resp) {            /* an empty reply is "not one of mine" */
        g_fd[fd].state = kFdNotOurs;
        return -1;
    }

    n = (int)body_get32(resp);
    is_master = (int)body_get32(resp + 4);
    tty_set(fd, n, is_master);
    return n;
}

static int rpc_fixed(uint32_t op, const uint8_t *req, uint32_t len,
                     void *out, uint32_t out_size) {
    return iec_rpc_fixed(TTY_SOCK_PATH, op, req, len, out, out_size);
}

static int rpc_take_fd(uint32_t op, const void *body, uint32_t len, uint32_t *out_word) {
    return iec_rpc_take_fd(TTY_SOCK_PATH, op, body, len, out_word);
}

/* ------------------------------------------------------------------ */
/* Terminal state, as held by the server                               */
/* ------------------------------------------------------------------ */

static void req_pts(uint8_t *req, int pts_n) {
    body_put32(req, (uint32_t)pts_n);
}

static int pts_tcgetattr(int pts_n, struct termios *tio) {
    uint8_t req[4];
    req_pts(req, pts_n);
    return rpc_fixed(OP_TCGETATTR, req, sizeof req, tio, sizeof *tio);
}

static int pts_tcsetattr(int pts_n, int actions, const struct termios *tio) {
    uint8_t req[8 + sizeof *tio];
    req_pts(req, pts_n);
    body_put32(req + 4, (uint32_t)actions);
    memcpy(req + 8, tio, sizeof *tio);
    return rpc_call(OP_TCSETATTR, req, sizeof req, NULL, 0, NULL);
}

static pid_t pts_tcgetpgrp(int pts_n) {
    uint8_t req[4], resp[4];
    req_pts(req, pts_n);
    if (rpc_fixed(OP_TCGETPGRP, req, sizeof req, resp, sizeof resp) < 0) return -1;
    return (pid_t)body_get32(resp);
}

static int pts_tcsetpgrp(int pts_n, pid_t pgrp) {
    uint8_t req[12];
    req_pts(req, pts_n);
    body_put32(req + 4, (uint32_t)pgrp);
    /* Also report the session this group lives in. A shell gives each job its
     * own process group with setpgid, but the job stays in the shell's session,
     * so the group is not a session leader and the server has no other way to
     * tell a legitimate job group from a stale number. */
    body_put32(req + 8, (uint32_t)getsid(0));
    return rpc_call(OP_TCSETPGRP, req, sizeof req, NULL, 0, NULL);
}

/* A program that starts with one of our terminals on stdin is the terminal's
 * foreground program: its shell has just started it, in the foreground. The
 * server owns that number and is the only process that can act on it, so it has
 * to be told -- an interactive shell (mksh) waits for tcgetpgrp(0) to name its
 * own group before it reads a line, and if its group is behind a stand-in pid it
 * spins on that question forever. That is what a shell started from a shell used
 * to do. Nothing else in this process says so, and this runs before main(). */
__attribute__((constructor))
static void shim_claim_foreground(void) {
    int n;

    if (fcntl(STDIN_FILENO, F_GETFD) < 0) return;
    n = identify(STDIN_FILENO);
    if (n < 0) return;
    pts_tcsetpgrp(n, getpgrp());
}

static int pts_getwinsz(int pts_n, struct winsize *ws) {
    uint8_t req[4];
    req_pts(req, pts_n);
    return rpc_fixed(OP_GETWINSZ, req, sizeof req, ws, sizeof *ws);
}

static int pts_setwinsz(int pts_n, const struct winsize *ws) {
    uint8_t req[4 + sizeof *ws];
    req_pts(req, pts_n);
    memcpy(req + 4, ws, sizeof *ws);
    return rpc_call(OP_SETWINSZ, req, sizeof req, NULL, 0, NULL);
}

/* ------------------------------------------------------------------ */
/* Hooks                                                               */
/* ------------------------------------------------------------------ */

/* Provided by the fs shim (preload build): resolve simulated symlinks before
 * the real open. Weak so builds without that module simply skip it. */
extern int iec_fs_do_open(int dirfd, const char* path, int flags, mode_t mode)
    __attribute__((weak));

int IEC_EXPORT(open)(const char *path, int flags, ...) {
    uint32_t pts_n = 0;
    int fd;

    /* open() is declared __nonnull, so path is never NULL here. */
    if (strcmp(path, "/dev/tty") == 0) {
        const char *env = getenv(IEC_TTY_ENV);
        int n = (env && *env >= '0' && *env <= '9') ? atoi(env) : -1;
        int local = (n >= 0) ? fd_for_pts(n, 0) : -1;

        if (local < 0) {
            int i;
            for (i = 0; i < SHIM_MAX_FD; i++) {
                if (g_fd[i].state != kFdOurs || g_fd[i].is_master) continue;
                local = i;
                n = g_fd[i].pts_n;
                break;
            }
        }
        if (local < 0) {
            errno = ENXIO;
            return -1;
        }
        fd = dup(local);
        if (fd < 0) return -1;
        tty_set(fd, n, 0);
        return fd;
    }
    if (strcmp(path, PTMX_PATH) == 0) {
        fd = rpc_take_fd(OP_OPENPTMX, NULL, 0, &pts_n);
        if (fd < 0) return -1;
        tty_set(fd, (int)pts_n, 1);
        return fd;
    }
    if (strncmp(path, PTS_PREFIX, PTS_PREFIX_LEN) == 0) {
        const char *num = path + PTS_PREFIX_LEN;
        uint8_t req[4];
        int n, local;

        if (*num < '0' || *num > '9') {
            errno = ENODEV;
            return -1;
        }
        n = atoi(num);

        /* If this process already holds the slave end, dup it: the server gave
         * its own copy away on the first open and has no second one. */
        local = fd_for_pts(n, 0);
        if (local >= 0) {
            fd = dup(local);
            if (fd >= 0) tty_set(fd, n, 0);
            return fd;
        }

        body_put32(req, (uint32_t)n);
        fd = rpc_take_fd(OP_OPENPTS, req, sizeof req, NULL);
        if (fd < 0) return -1;
        tty_set(fd, n, 0);
        return fd;
    }

    /* Not a pty path: let the fs shim resolve simulated symlinks first. */
    if (iec_fs_do_open) {
        mode_t mode = 0;
        if (flags & O_CREAT) {
            va_list ap;
            va_start(ap, flags);
            mode = (mode_t)va_arg(ap, int);
            va_end(ap);
        }
        return iec_fs_do_open(AT_FDCWD, path, flags, mode);
    }

    /* No fs shim in this build: let the real open() have it. */
    RESOLVE(real_open, open);
    if (flags & O_CREAT) {
        va_list ap;
        mode_t mode;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return real_open(path, flags, mode);
    }
    return real_open(path, flags);
}

int IEC_EXPORT(close)(int fd) {
    tty_clear(fd);
    RESOLVE(real_close, close);
    return real_close(fd);
}

/* Duplicating a tty fd has to carry the table entry over, otherwise the copy is
 * an anonymous socket again. This is not a corner case: bash keeps its terminal
 * in fd 255 with dup2(dup(stderr), 255) while setting up job control, and every
 * later tcgetpgrp()/tcsetpgrp()/isatty() on that fd would otherwise fail with
 * ENOTTY. */
int IEC_EXPORT(dup)(int oldfd) {
    int fd;
    RESOLVE(real_dup, dup);
    fd = real_dup(oldfd);
    if (fd >= 0) tty_copy(oldfd, fd);
    return fd;
}

int IEC_EXPORT(dup2)(int oldfd, int newfd) {
    int fd;
    RESOLVE(real_dup2, dup2);
    fd = real_dup2(oldfd, newfd);
    if (fd >= 0) {
        tty_clear(fd);
        tty_copy(oldfd, fd);
    }
    return fd;
}

int IEC_EXPORT(dup3)(int oldfd, int newfd, int flags) {
    int fd;
    RESOLVE(real_dup3, dup3);
    fd = real_dup3(oldfd, newfd, flags);
    if (fd >= 0) {
        tty_clear(fd);
        tty_copy(oldfd, fd);
    }
    return fd;
}

int IEC_EXPORT(fcntl)(int fd, int cmd, ...) {
    va_list ap;
    void *arg;
    int r;

    va_start(ap, cmd);
    arg = va_arg(ap, void *);
    va_end(ap);

    RESOLVE(real_fcntl, fcntl);
    r = real_fcntl(fd, cmd, arg);

    /* fcntl(F_DUPFD) is the other way a program makes a second name for a fd. */
    if (r >= 0 && (cmd == F_DUPFD
#ifdef F_DUPFD_CLOEXEC
                   || cmd == F_DUPFD_CLOEXEC
#endif
                   ))
        tty_copy(fd, r);
    return r;
}

int IEC_EXPORT(isatty)(int fd) {
    if (identify(fd) >= 0) return 1;
    RESOLVE(real_isatty, isatty);
    return real_isatty(fd);
}

/* ttyname()/ttyname_r() also have to be hooked on their own: glibc implements
 * them on top of the internal __isatty (which issues __ioctl(TCGETS) itself), so
 * with only isatty()/ioctl() hooked they still report ENOTTY. A shell asks for
 * the terminal name while setting up job control and disables job control when
 * it cannot get one ("cannot set terminal process group"). */
char *IEC_EXPORT(ttyname)(int fd) {
    static char buf[32];
    int n = identify(fd);

    if (n < 0) {
        RESOLVE(real_ttyname, ttyname);
        return real_ttyname(fd);
    }
    snprintf(buf, sizeof buf, "/dev/pts/%d", n);
    return buf;
}

int IEC_EXPORT(ttyname_r)(int fd, char *buf, size_t buflen) {
    int n = identify(fd);
    int len;

    if (n < 0) {
        RESOLVE(real_ttyname_r, ttyname_r);
        return real_ttyname_r(fd, buf, buflen);
    }
    len = snprintf(buf, buflen, "/dev/pts/%d", n);
    if (len < 0) return errno;
    if ((size_t)len >= buflen) return ERANGE;
    return 0;
}

int IEC_EXPORT(tcgetattr)(int fd, struct termios *tio) {
    int n = identify(fd);
    struct termios got;

    if (n < 0) {
        RESOLVE(real_tcgetattr, tcgetattr);
        return real_tcgetattr(fd, tio);
    }
    if (!tio) { errno = EFAULT; return -1; }
    if (pts_tcgetattr(n, &got) < 0) return -1;
    *tio = got;
    return 0;
}

int IEC_EXPORT(tcsetattr)(int fd, int actions, const struct termios *tio) {
    int n = identify(fd);

    if (n < 0) {
        RESOLVE(real_tcsetattr, tcsetattr);
        return real_tcsetattr(fd, actions, tio);
    }
    if (!tio) { errno = EFAULT; return -1; }
    return pts_tcsetattr(n, actions, tio);
}

/* tcgetpgrp()/tcsetpgrp() have to be hooked on their own: glibc implements them
 * with libc's internal __ioctl, which LD_PRELOAD cannot interpose, so the ioctl
 * hook below never sees these calls. A shell uses them to take the foreground,
 * and when they fail it prints "cannot set terminal process group" and gives up
 * job control entirely. */
pid_t IEC_EXPORT(tcgetpgrp)(int fd) {
    int n = identify(fd);

    if (n < 0) {
        RESOLVE(real_tcgetpgrp, tcgetpgrp);
        return real_tcgetpgrp(fd);
    }
    return pts_tcgetpgrp(n);
}

int IEC_EXPORT(tcsetpgrp)(int fd, pid_t pgrp) {
    int n = identify(fd);

    if (n < 0) {
        RESOLVE(real_tcsetpgrp, tcsetpgrp);
        return real_tcsetpgrp(fd, pgrp);
    }
    return pts_tcsetpgrp(n, pgrp);
}

int IEC_EXPORT(ioctl)(int fd, unsigned long request, ...) {
    int n = identify(fd);
    void *arg;
    va_list ap;

    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (n >= 0) {
        switch (request) {
        case TIOCGWINSZ:
            if (!arg) { errno = EFAULT; return -1; }
            return pts_getwinsz(n, arg);
        case TIOCSWINSZ:
            if (!arg) { errno = EFAULT; return -1; }
            return pts_setwinsz(n, arg);
        /* The ioctl spellings of the termios calls go to the same place. */
        case TCGETS:
            if (!arg) { errno = EFAULT; return -1; }
            return pts_tcgetattr(n, arg);
        case TCSETS:
        case TCSETSW:
        case TCSETSF:
            if (!arg) { errno = EFAULT; return -1; }
            return pts_tcsetattr(n, TCSANOW, arg);
#ifdef TIOCGPTN
        case TIOCGPTN:
            if (arg) *(int *)arg = n;
            return 0;
#endif
#ifdef TIOCSCTTY
        case TIOCSCTTY:
            return 0;  /* pretend we took it as the controlling terminal */
#endif
        /* For callers that issue these ioctls directly instead of going through
         * tcsetpgrp()/tcgetpgrp(); glibc's own wrappers bypass this hook. */
#ifdef TIOCSPGRP
        case TIOCSPGRP:
            if (!arg) { errno = EFAULT; return -1; }
            return pts_tcsetpgrp(n, *(const pid_t *)arg);
#endif
#ifdef TIOCGPGRP
        case TIOCGPGRP: {
            pid_t p;
            if (!arg) { errno = EFAULT; return -1; }
            p = pts_tcgetpgrp(n);
            if (p < 0) return -1;
            *(pid_t *)arg = p;
            return 0;
        }
#endif
        default:
            break;
        }
    }

    RESOLVE(real_ioctl, ioctl);
    return real_ioctl(fd, request, arg);
}

int IEC_EXPORT(getpt)(void) {
    return open(PTMX_PATH, O_RDWR | O_NOCTTY);
}

int IEC_EXPORT(grantpt)(int fd) {
    /* Nothing to do: the server already owns the "slave" and hands it over on
     * open("/dev/pts/<n>"). */
    if (identify(fd) >= 0) return 0;
    RESOLVE(real_grantpt, grantpt);
    return real_grantpt(fd);
}

int IEC_EXPORT(unlockpt)(int fd) {
    if (identify(fd) >= 0) return 0;
    RESOLVE(real_unlockpt, unlockpt);
    return real_unlockpt(fd);
}

char *IEC_EXPORT(ptsname)(int fd) {
    static char buf[32];
    int n = identify(fd);

    if (n < 0) {
        RESOLVE(real_ptsname, ptsname);
        return real_ptsname(fd);
    }
    snprintf(buf, sizeof buf, "/dev/pts/%d", n);
    return buf;
}

int IEC_EXPORT(openpty)(int *amaster, int *aslave, char *name,
                        const struct termios *termp, const struct winsize *winp) {
    int master, slave;
    char *pname;

    master = getpt();
    if (master < 0) return -1;

    if (grantpt(master) < 0 || unlockpt(master) < 0) {
        close(master);
        return -1;
    }

    pname = ptsname(master);
    if (!pname) {
        close(master);
        return -1;
    }

    slave = open(pname, O_RDWR | O_NOCTTY);
    if (slave < 0) {
        close(master);
        return -1;
    }

    if (name) strcpy(name, pname);
    if (termp) tcsetattr(slave, TCSAFLUSH, termp);
    if (winp) ioctl(slave, TIOCSWINSZ, winp);

    *amaster = master;
    *aslave = slave;
    return 0;
}

int IEC_EXPORT(login_tty)(int fd) {
    int n;

    if (setsid() < 0) return -1;
    if (ioctl(fd, TIOCSCTTY, NULL) < 0) return -1;
    if (dup2(fd, STDIN_FILENO) < 0) return -1;
    if (dup2(fd, STDOUT_FILENO) < 0) return -1;
    if (dup2(fd, STDERR_FILENO) < 0) return -1;

    n = identify(fd);
    if (n >= 0) {
        char v[16];
        snprintf(v, sizeof v, "%d", n);
        /* The child almost always execs right after this, and the table above
         * does not cross that boundary; leave the pts number where the next
         * image can find it (see shim_resume_from_exec). */
        setenv(IEC_TTY_ENV, v, 1);
        /* The server owns the foreground group and is the only process that can
         * raise a signal for this terminal, so setsid() -- which just gave this
         * process a group the server has never heard of -- has to be reported.
         * A real pty picks up the new session's group at this point as well;
         * without this, ^C would have nobody to signal. */
        tcsetpgrp(fd, getpgrp());
    }

    if (fd > STDERR_FILENO) close(fd);
    return 0;
}

/* forkpty = openpty + fork + login_tty */
pid_t IEC_EXPORT(forkpty)(int *amaster, char *name,
                          const struct termios *termp,
                          const struct winsize *winp) {
    int master = -1, slave = -1;
    pid_t pid;

    if (openpty(&master, &slave, name, termp, winp) < 0) return -1;

    pid = fork();
    if (pid < 0) {
        int saved = errno;
        close(master);
        close(slave);
        errno = saved;
        return -1;
    }
    if (pid == 0) {
        close(master);
        if (login_tty(slave) < 0) _exit(1);
        return 0;
    }

    *amaster = master;
    close(slave);
    return pid;
}
