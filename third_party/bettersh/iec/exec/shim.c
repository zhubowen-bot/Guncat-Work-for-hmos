// exec/shim.c — interception of the exec family
//
// The same idea as the pty hooks next door: the sandboxed client hands the call
// to the out-of-process server instead of doing it itself. The server forks, and
// the program runs there with the caller's stdio, handed over as SCM_RIGHTS.
//
// A successful execve() never returns: it replaces the calling process's image.
// Here the image is not replaced -- the program that runs is the server's child --
// so the honest equivalent is a stand-in: this process waits for that child to
// end and then leaves with the same status, which is what makes the caller's
// waitpid() report what the real program did. See the end of exec_common().

#include "constant.h"
#include "intercept.h"
#include "rpc.h"
#include "sock_operation.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* The environment of this process. <unistd.h> declares it only under
 * _GNU_SOURCE, which the build sets; spelled out here so that the inheritance
 * below does not rest on a build flag. */
extern char **environ;

/* The exec service listens on its own socket, not the tty service's: a client reaches a
 * service by connecting to it, so the two paths differ. The path itself is in
 * constant.h, where the server reads the same one. */

/* Exit status for the stand-in when the child's ending never reached it -- the
 * server died, or answered something that is not a status. 127 is the shell's
 * "command not found", so it reads as a failure to any caller, which is the only
 * honest thing to report when the real status is unknown. */
#define EXEC_STATUS_LOST 127

/* How often the stand-in asks the server whether the child has exited. Tens of
 * milliseconds: quick enough that a command in a terminal feels immediate, and
 * slow enough that waiting costs no measurable work. A busy loop would peg a core
 * for the whole lifetime of the program, which may be hours. */
#define EXEC_WAIT_INTERVAL_MS 50

/* ----------------------------------------------------------------------- */
/* Server round trip                                                       */
/*                                                                         */
/* The round trip lives in common/rpc.c, shared with tty/shim.c; these are */
/* the thin bindings to it, so the call sites below stay readable. Both     */
/* variants are bound because both are used: the exec request carries the   */
/* caller's stdio to the server, and the wait request is a plain one that   */
/* takes a fixed-size reply. Only what this shim actually uses is bound --  */
/* a wrapper that nothing calls is exactly the unused-function warning this */
/* file had.                                                               */
/* ----------------------------------------------------------------------- */

static void body_put32(uint8_t *p, uint32_t v) { iec_put32(p, v); }

/* OP_EXECUTE is the one request in this program that sends fds. The reply body is
 * the remote pid, copied into out, or empty when the server started nothing. */
static int rpc_call_fds(uint32_t op, const void *body, uint32_t len,
                        const int *fds, int nfds,
                        void *out, uint32_t out_max, uint32_t *out_len) {
    return iec_rpc_call_fds(EXEC_SOCK_PATH, op, body, len, fds, nfds, out, out_max, out_len);
}

/* OP_WAIT sends nothing but a pid, so it needs no fds. */
static int rpc_call(uint32_t op, const void *body, uint32_t len,
                    void *out, uint32_t out_max, uint32_t *out_len) {
    return iec_rpc_call(EXEC_SOCK_PATH, op, body, len, out, out_max, out_len);
}

/* Diagnostics must not go through stdio here. The client is free to have forked
 * before calling exec, and at that moment another thread can hold a stdio lock
 * that does not exist in this process, which would make fprintf() deadlock
 * instead of printing -- the same reason the Spawn child in exec_server.cpp
 * reports with write(2). */
static void report(const char *msg) {
    if (write(STDERR_FILENO, msg, strlen(msg))) {}
}

/* Collects a NULL-terminated varargs argument list into argv, which must have
 * room for max entries including the terminator. */
static void va_to_argv(const char *arg0, va_list ap, char *argv[], int max) {
    int i = 0;

    if (arg0 && i < max - 1) argv[i++] = (char *)arg0;
    for (;;) {
        char *arg = va_arg(ap, char *);
        if (!arg) break;
        if (i < max - 1) argv[i++] = arg;
    }
    argv[i] = NULL;
}

/* ----------------------------------------------------------------------- */
/* Signal forwarding                                                       */
/*                                                                         */
/* A terminal sends ^C, ^Z and a window-size change to the process group   */
/* it holds in the foreground, and the process the caller's shell put in   */
/* that group is this stand-in. The program it stands in for runs on the   */
/* server, in the server's own process group and session, so the kernel    */
/* never delivers any of those signals to it -- and a kill() aimed at this */
/* process does not reach it either, which is what makes this worth doing  */
/* rather than leaving it to the process group. They are caught here and   */
/* asked for over OP_SIGNAL instead. Without that, ^C ends the stand-in    */
/* and leaves the program running with nobody waiting for it.              */
/*                                                                         */
/* Catching them is also what keeps the stand-in alive: the default action */
/* of every signal below but SIGCONT and SIGWINCH is to end this process.  */
/* Ending it is the wrong answer in general -- whether the program dies is */
/* the program's business, and one that ignores SIGINT is supposed to      */
/* survive a ^C -- so the stand-in ends when, and only when, OP_WAIT says  */
/* the program ended.                                                      */
/* ----------------------------------------------------------------------- */

/* One flag per signal, indexed by signal number. A handler may do nothing but set
 * one of these: every other way of getting the signal out of the process -- a
 * socket call, malloc, anything stdio -- is not async-signal-safe, so the
 * forwarding itself is left to the main loop, which reads these flags.
 *
 * A flag rather than a count, deliberately. Signals that arrive again before the
 * loop gets to them become one delivery to the program at the other end, and for
 * this set that loses nothing: a second SIGWINCH asks for the same size as the
 * first, and a program being interrupted does not act twice as interrupted. A
 * count would need a ceiling to stay defined and would not make any of the seven
 * behave differently. What has to hold is the other direction -- a signal that
 * arrives is never dropped -- and a flag gives that. */
static volatile sig_atomic_t g_raised[NSIG];

static void on_signal(int sig) {
    g_raised[sig] = 1;
}

/* What the stand-in catches, in the order it forwards them. What a terminal can
 * send, and nothing else: SIGTSTP and SIGCONT because job control is the shell's
 * view of this process, SIGWINCH because the program owns the terminal's size
 * wherever it runs, and the four that end a foreground job. SIGKILL and SIGSTOP
 * cannot be caught at all, so a stand-in killed with either does leave its program
 * behind; see the note in ExecServer::onTick() for where that would be cleaned
 * up, and why it is not done here. */
static const int g_forwarded[] = {
    SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGCONT, SIGWINCH,
};
#define FORWARDED_COUNT ((int)(sizeof g_forwarded / sizeof g_forwarded[0]))

/* OP_SIGNAL: [4 bytes remote pid][4 bytes signo], empty reply. */
static void forward_signal(uint32_t remote_pid, int sig) {
    uint8_t req[8];

    body_put32(req, remote_pid);
    body_put32(req + 4, (uint32_t)sig);
    /* A failure is reported and nothing more: this process must not die of it,
     * because the program decides when this ends. If the server really is gone,
     * the next OP_WAIT fails and takes the normal lost-status way out. */
    if (rpc_call(OP_SIGNAL, req, sizeof req, NULL, 0, NULL) < 0)
        report("[shim] exec: could not forward a signal\n");
}

/* Passes on every signal caught since the previous call, and stops this process
 * if one of them was SIGTSTP. */
static void forward_pending(uint32_t remote_pid) {
    int i;

    for (i = 0; i < FORWARDED_COUNT; i++) {
        int sig = g_forwarded[i];

        if (!g_raised[sig]) continue;
        g_raised[sig] = 0;
        forward_signal(remote_pid, sig);

        if (sig == SIGTSTP) {
            /* The program has been stopped, and this process has to stop too:
             * job control is the shell's waitpid() reporting WIFSTOPPED, and a
             * shell that saw this process still running after ^Z would take the
             * stop for a failure. Stopping is the default action of the signal,
             * so the handler has to be out of the way for it to happen at all --
             * left in place, raise() would run it, set a flag and return.
             *
             * The kernel has the last word: a stop signal aimed at a member of an
             * orphaned process group is discarded rather than honoured, so that a
             * job no shell could ever resume is not left stopped. A stand-in in
             * that position (today's case: a session leader with no shell above
             * it) therefore goes on running here while the program it forwarded
             * the stop to does stop, and there is nothing this side can do about
             * it -- the discarding happens on delivery, without an error. */
            signal(SIGTSTP, SIG_DFL);
            raise(SIGTSTP);
            /* Back, so a SIGCONT resumed this process and its handler has already
             * run; SIGCONT follows SIGTSTP in the list, so the flag it set is
             * forwarded by the rest of this pass. The handler goes back in so
             * that a second ^Z stops this process again. */
            signal(SIGTSTP, on_signal);
        }
    }
}

/* execve(2) closes every descriptor with FD_CLOEXEC; this route never execs,
 * because the program runs in a child of the server. The close has to happen
 * here instead. The descriptor that matters is run-command's exec-notify pipe:
 * git's parent blocks reading it until EOF, and without the close the stand-in
 * keeps the write end open, so the parent waits forever while the helper waits
 * for a command that is never sent. Only descriptors above stderr are touched,
 * and the service connection has no close-on-exec flag, so it survives. */
static void close_cloexec_fds(void) {
    long max = sysconf(_SC_OPEN_MAX);
    int fd;

    if (max < 0 || max > 4096) max = 4096;
    for (fd = STDERR_FILENO + 1; fd < max; fd++) {
        int flags = fcntl(fd, F_GETFD);
        if (flags >= 0 && (flags & FD_CLOEXEC)) close(fd);
    }
}

/* execve(2) resets every caught signal to its default disposition; only an
 * ignored signal stays ignored. This route does not exec, so the host's
 * handlers would otherwise survive into a process that is not the host: the
 * app runtime's shutdown and crash handlers are the ones that matter, because
 * they assert that they run in the main process and abort the stand-in with
 * SIGTRAP when they do not. Reset them here, then install the handlers this
 * side needs. */
static void reset_signal_handlers(void) {
    int sig;

    for (sig = 1; sig < NSIG; sig++) {
        struct sigaction old, dfl;
        if (sigaction(sig, NULL, &old) != 0) continue;
        if (old.sa_handler == SIG_IGN || old.sa_handler == SIG_DFL) continue;
        memset(&dfl, 0, sizeof dfl);
        dfl.sa_handler = SIG_DFL;
        sigemptyset(&dfl.sa_mask);
        sigaction(sig, &dfl, NULL);
    }
}

/* Becomes the remote program's stand-in, and never returns.
 *
 * There is no way to hand a process's exit to another process, so the closest
 * thing to "this process was replaced" is for this one to wait for the child and
 * then leave with its status. Polling is what makes that a stand-in rather than a
 * duplicate: the child is alive the whole time, and the status arrives only once it
 * has ended.
 *
 * Signals, on the other hand, are not left to the status: they are caught and
 * forwarded as they arrive (see above), which makes waiting for the program the
 * only way this process can end. */
__attribute__((noreturn)) static void become_stand_in(uint32_t remote_pid) {
    /* OP_WAIT: [4 bytes pid] -> [4 bytes state][4 bytes status]. state is 1 once
     * the child has ended, and only then does status mean anything; see onWait()
     * in exec_server.cpp for how the two words are produced. */
    enum { WAIT_ANSWER = 8 };
    const struct timespec interval = { 0, EXEC_WAIT_INTERVAL_MS * 1000000L };
    uint8_t answer[WAIT_ANSWER];
    uint8_t req[4];
    uint32_t len, state, status;
    struct timespec left, rem;
    int i;

    /* execve's dispositions first, so the host's handlers cannot run in this
     * process; see reset_signal_handlers(). */
    reset_signal_handlers();

    /* Before the first request goes out: a ^C arriving in between would end this
     * process through the default action, which is the ending this whole section
     * exists to prevent. */
    for (i = 0; i < FORWARDED_COUNT; i++)
        signal(g_forwarded[i], on_signal);

    body_put32(req, remote_pid);
    for (;;) {
        /* Ahead of the question below, so a signal caught during the sleep is
         * passed on at once rather than a round later. */
        forward_pending(remote_pid);

        len = 0;
        if (rpc_call(OP_WAIT, req, sizeof req, answer, sizeof answer, &len) < 0 ||
            len < WAIT_ANSWER) {
            /* Without the server there is nothing left to learn about the child,
             * and exiting 0 would claim a success nobody observed. */
            report("[shim] exec: lost the child's exit status\n");
            _exit(EXEC_STATUS_LOST);
        }
        state = iec_get32(answer);
        status = iec_get32(answer + 4);
        if (state == 1) break;

        /* A signal that interrupts the sleep is not an event in itself; what
         * matters is that the interval is not spent twice or skipped. Sleeping the
         * remainder keeps both true, where re-asking at once would spin if the
         * signals kept coming, and sleeping the whole interval again would make the
         * polling slow down for no reason. */
        left = interval;
        while (nanosleep(&left, &rem) < 0 && errno == EINTR) left = rem;
    }

    if (WIFEXITED(status))
        _exit(WEXITSTATUS(status));

    if (WIFSIGNALED(status)) {
        int sig = WTERMSIG(status);
        /* Die of the same signal. An ordinary exit with 128 + sig would be
         * indistinguishable from the program having called exit(128 + sig), and
         * callers really do branch on that difference. Restoring SIG_DFL first is
         * what makes that work for the signals above: a handler is installed for
         * them, and raise() would otherwise run it, set a flag and return, leaving
         * this process alive for good. */
        signal(sig, SIG_DFL);
        raise(sig);
        /* Reached only when the signal could not end this process -- it was
         * blocked or ignored. The status still has to be reported somehow, so the
         * shell's rendering of a signal death is used after all. */
        _exit(128 + sig);
    }

    /* Neither an exit nor a signal death: not a state the server can produce, so
     * there is nothing to copy. */
    _exit(EXEC_STATUS_LOST);
}

static const char *const g_kept[] = { "LD_PRELOAD", "PATH" };
#define KEPT_COUNT ((int)(sizeof g_kept / sizeof g_kept[0]))

/* Whether the environment names the variable. The '=' is part of the match, so
 * that "PATH=" counts as stated -- an empty value is a statement about the
 * program's search path, not an omission -- while "PATHOLOGY=1" does not. */
static int env_states(char *const env[], const char *name) {
    size_t n = strlen(name);
    size_t i;

    for (i = 0; env && env[i]; i++)
        if (strncmp(env[i], name, n) == 0 && env[i][n] == '=') return 1;
    return 0;
}

/* Which entries of g_kept this request has to put back, one bit per entry.
 *
 * A mask rather than a count, because the two places that need the answer are far
 * apart in exec_common(): the header is written before the strings and carries
 * their number, the strings themselves are written afterwards. Deciding once here
 * is what keeps the number and the entries from being able to disagree.
 *
 * An entry this process does not have is not a candidate: there is nothing to put
 * back. */
static unsigned kept_mask(char *const env[]) {
    unsigned mask = 0;
    int i;

    for (i = 0; i < KEPT_COUNT; i++)
        if (!env_states(env, g_kept[i]) && getenv(g_kept[i])) mask |= 1u << i;
    return mask;
}

static int exec_common(enum CallMethod method, const char *file,
                       char *const argv[], char *const envp[]) {
    /* Compact request for OP_EXECUTE. Everything is length-delimited by the
     * packet itself plus NUL terminators, and the decoder checks the buffer end
     * as it walks, so a truncated or hostile request cannot run off it:
     *
     *   [0..3]   flags       bit0 = the caller waits for the child.
     *   [4..7]   call_method 
     *   [8..11]  argc
     *   [12..15] envc        entries in the env list below: the environment the
     *                        program is to start with, plus the variables put
     *                        back by kept_mask()
     *   [16..19] fd_count
     *   fd_count x [4 bytes target_fd]
     *   then NUL-terminated strings, in this order:
     *     file, cwd (empty means inherit)
     *     argc entries for argv, then envc entries for env
     *
     * The fds sent with the request (SCM_RIGHTS) are not named in the body; the
     * target list says, position by position, which fd each of them has to
     * become in the child. The list is not redundant: a descriptor that is
     * closed here -- a shell started with 0, 1 or 2 missing -- is left out
     * entirely, and then counting along the received fds would map stderr onto
     * stdout.
     */
    /* The request has to hold the whole environment, which is why this is far more
     * than the rest of the request needs: an interactive environment is a few
     * kilobytes -- PATH alone is over a thousand bytes of the one this was written
     * against -- and a request that does not fit fails the exec outright, so the
     * cost of a size that is too small is no shell at all for a command that works
     * everywhere else. 32 KiB is several times the largest environment seen on the
     * target and small enough to sit on the stack of a thread that is not the main
     * one. Overrunning it stays a defined failure: see the too_long arm below,
     * which reports it and fails the call with E2BIG. */
    enum { EXEC_REQ_MAX = 32768, EXEC_FLAG_WAIT = 1, EXEC_FLAG_STDIO = 2, EXEC_STDIO_FDS = 3,
           EXEC_PID_REPLY = 4, EXEC_FAIL_REPLY = 8 };
    uint8_t req[EXEC_REQ_MAX];
    uint8_t answer[EXEC_FAIL_REPLY];      /* the larger of the two OP_EXECUTE answers */
    uint32_t answer_len;
    int send_fds[EXEC_STDIO_FDS];
    uint32_t targets[EXEC_STDIO_FDS];
    int nfds = 0, fd;
    size_t off, argc = 0, envc = 0, i, len;
    char *const *env;                     /* the environment the request carries */
    char cwd[PATH_MAX];                   /* and the directory it is started in */
    unsigned kept;                        /* one bit per g_kept entry to put back */
    size_t kept_n = 0;                    /* how many entries that comes to */

    /* The environment the program is to start with: the one the call states, or this
     * process's own when the call states none. Both the four with no environment
     * argument and the NULL an 'e' call may pass land on the second arm -- POSIX
     * gives those three a way to state an environment and none to ask for an empty
     * one. */
    env = envp ? envp : (char *const *)environ;

    /* And the directory it is started in: this process's own, which is what every
     * relative name in the request already means here. An empty one is the server's,
     * and is what a getcwd() that fails leaves behind -- the directory was removed
     * under this process, or its path does not fit in PATH_MAX. */
    if (!getcwd(cwd, sizeof cwd)) cwd[0] = '\0';

    if (!file) {
        errno = ENOENT;
        return -1;
    }
    while (argv && argv[argc]) argc++;
    while (env && env[envc]) envc++;

    /* Which variables that environment has to be given, decided here because the
     * header below carries the count of them; the entries themselves are appended
     * further down. Zero when it already names every entry of g_kept, so an
     * ordinary request goes out exactly as it did before. */
    kept = kept_mask(env);
    for (i = 0; i < (size_t)KEPT_COUNT; i++) kept_n += (kept >> i) & 1u;

    /* The child is started on the server, so our own stdio -- the terminal this
     * exec was called from -- has to travel with the request; without it the
     * child writes to whatever the server was started with. A closed fd is
     * skipped, which is what the target list is for. */
    for (fd = STDIN_FILENO; fd <= STDERR_FILENO; fd++) {
        if (fcntl(fd, F_GETFD) < 0) continue;
        send_fds[nfds] = fd;
        targets[nfds] = (uint32_t)fd;
        nfds++;
    }

    /* The strings start after the header and the target list, so the offset of
     * every string below moves with fd_count. */
    off = 20 + 4 * (size_t)nfds;
    body_put32(req, EXEC_FLAG_WAIT | (nfds > 0 ? EXEC_FLAG_STDIO : 0u));
    body_put32(req + 4, (uint32_t)method);
    body_put32(req + 8, (uint32_t)argc);
    body_put32(req + 12, (uint32_t)(envc + kept_n));
    body_put32(req + 16, (uint32_t)nfds);
    for (i = 0; i < (size_t)nfds; i++) body_put32(req + 20 + 4 * i, targets[i]);

#define PUT_CSTR(s)                                     \
    do {                                                \
        len = strlen(s) + 1;                            \
        if (off + len > EXEC_REQ_MAX) goto too_long;    \
        memcpy(req + off, (s), len);                    \
        off += len;                                     \
    } while (0)

/* The same bounds check and the same buffer, for the one string here that is
 * built rather than copied whole: "NAME=VALUE". */
#define PUT_KEPT(name, value)                            \
    do {                                                 \
        size_t n = strlen(name);                         \
        len = n + 1 + strlen(value) + 1;                 \
        if (off + len > EXEC_REQ_MAX) goto too_long;     \
        memcpy(req + off, (name), n);                    \
        req[off + n] = '=';                              \
        memcpy(req + off + n + 1, (value), len - n - 1); \
        off += len;                                      \
    } while (0)

    PUT_CSTR(file);
    PUT_CSTR(cwd);                         /* empty means inherit; see above */
    for (i = 0; i < argc; i++) PUT_CSTR(argv[i]);
    for (i = 0; i < envc; i++) PUT_CSTR(env[i]);
    /* Last, so the caller's own order is what the program reads first. The mask is
     * what says which of them; getenv() cannot answer NULL for one it names, since
     * kept_mask() only sets a bit for a variable this process was given. */
    for (i = 0; i < (size_t)KEPT_COUNT; i++)
        if ((kept >> i) & 1u) PUT_KEPT(g_kept[i], getenv(g_kept[i]));
#undef PUT_KEPT
#undef PUT_CSTR

    /* The reply is the pid the server started the program under, or nothing at
     * all when nothing was started. Only a failure to start is answered with -1,
     * because that is the only case in which the caller's exec really failed.
     *
     * A refusal the server can name -- today, only a PATH search that matched
     * nothing -- is answered with the longer shape: no pid, then the errno the
     * caller's exec should fail with. That is how a missing program reaches the
     * caller as ENOENT, the errno POSIX gives for it, instead of the transport
     * error a bare "the request failed" would leave behind. */
    answer_len = 0;
    if (rpc_call_fds(OP_EXECUTE, req, (uint32_t)off, send_fds, nfds,
                     answer, sizeof answer, &answer_len) < 0)
        return -1;                     /* errno is already set by the rpc layer */

    if (answer_len >= EXEC_FAIL_REPLY) {
        errno = (int)iec_get32(answer + 4);
        /* 0 would mean the server refused without saying why, which is not a
         * state it produces; a defined failure still beats an undefined errno. */
        if (errno == 0) errno = EIO;
        return -1;
    }

    if (answer_len < EXEC_PID_REPLY) {
        /* No pid means there is no process to stand in for. The server only leaves
         * the body empty when it did not start one, so this is a failure too. */
        report("[shim] exec: the reply named no process\n");
        errno = EIO;
        return -1;
    }

    /* A program is running on the server, so this call succeeds from here on: what
     * is left is to take that program's place, which never returns. Close the
     * descriptors execve would have closed first; see close_cloexec_fds(). */
    close_cloexec_fds();
    become_stand_in(iec_get32(answer));

too_long:
    report("[shim] exec: request is too long\n");
    errno = E2BIG;
    return -1;
}

/* ------------------------------------------------------------------ */
/* Hooks                                                              */
/* ------------------------------------------------------------------ */

int IEC_EXPORT(execve)(const char *path, char *const argv[], char *const envp[]) {
    return exec_common(CALL_EXECVE, path, argv, envp);
}

int IEC_EXPORT(execv)(const char *path, char *const argv[]) {
    return exec_common(CALL_EXECV, path, argv, NULL);
}

int IEC_EXPORT(execvp)(const char *file, char *const argv[]) {
    return exec_common(CALL_EXECVP, file, argv, NULL);
}

int IEC_EXPORT(execvpe)(const char *file, char *const argv[], char *const envp[]) {
    return exec_common(CALL_EXECVPE, file, argv, envp);
}

int IEC_EXPORT(execl)(const char *path, const char *arg0, ...) {
    char *argv[64];
    va_list ap;

    va_start(ap, arg0);
    va_to_argv(arg0, ap, argv, 64);
    va_end(ap);
    return exec_common(CALL_EXECL, path, argv, NULL);
}

int IEC_EXPORT(execlp)(const char *file, const char *arg0, ...) {
    char *argv[64];
    va_list ap;

    va_start(ap, arg0);
    va_to_argv(arg0, ap, argv, 64);
    va_end(ap);
    return exec_common(CALL_EXECLP, file, argv, NULL);
}

/* execle is the odd one out: the environment follows the terminating NULL of the
 * argument list, so the varargs have to be walked before it can be read. */
int IEC_EXPORT(execle)(const char *path, const char *arg0, ...) {
    char *argv[64];
    char *const *envp;
    va_list ap;

    va_start(ap, arg0);
    va_to_argv(arg0, ap, argv, 64);
    envp = va_arg(ap, char *const *);
    va_end(ap);
    return exec_common(CALL_EXECLE, path, argv, envp);
}
