// misc/getpass.c — terminal password prompt and fatal-signal reporting.
//
// The IEC sandbox's libc has no getpass(), while dropbear's cli-auth.c calls it
// unconditionally (it is not behind HAVE_GETPASS). Without this the client can
// only authenticate through $DROPBEAR_PASSWORD.
//
// The pty here is a socketpair with no kernel line discipline (no ICANON), so
// the prompt reads bytes itself, handles backspace, and treats both \r and \n
// as the end of the line.
//
// The constructor at the bottom also makes stderr line-buffered and installs a
// minimal fatal-signal handler. A server started by the exec service is a forked
// child; when it crashes there is nowhere else to look, and a redirected stderr
// is fully buffered -- the last lines are exactly the ones that matter. Frames
// are printed relative to the handler so llvm-symbolizer can resolve them
// against the object this file is linked into.
#include <errno.h>
#include <execinfo.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#define IEC_GETPASS_MAX 256

char* getpass(const char* prompt) {
    static char buf[IEC_GETPASS_MAX];
    size_t n = 0;
    struct termios oldt, newt;
    int have_tio = (tcgetattr(STDIN_FILENO, &oldt) == 0);

    if (*prompt) {
        ssize_t w = write(STDERR_FILENO, prompt, strlen(prompt));
        (void)w;
    }
    if (have_tio) {
        newt = oldt;
        newt.c_lflag &= ~(tcflag_t)ECHO;
        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &newt) != 0) have_tio = 0;
    }

    for (;;) {
        char c;
        ssize_t r = read(STDIN_FILENO, &c, 1);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;                      /* a real error: keep what was read */
        }
        if (r == 0) break;               /* EOF */
        if (c == '\n' || c == '\r') break;
        if (c == 0x7f || c == 0x08) {    /* backspace */
            if (n > 0) n--;
            continue;
        }
        if ((unsigned char)c < 0x20) continue;   /* drop other control bytes */
        if (n < IEC_GETPASS_MAX - 1) buf[n++] = c;
    }
    buf[n] = '\0';

    if (have_tio) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &oldt);
    }
    {
        ssize_t w = write(STDERR_FILENO, "\n", 1);
        (void)w;
    }
    return buf;
}

/* Fatal signal: print the signal, the fault address and every frame relative to
 * this handler. The offset is enough for llvm-symbolizer to name the function
 * when pointed at the object, and it avoids dladdr() (and _GNU_SOURCE). */
static void IecFatalHandler(int sig, siginfo_t* si, void* uc) {
    (void)uc;
    void* bt[40];
    int n = backtrace(bt, sizeof bt / sizeof bt[0]);
    unsigned long anchor = (unsigned long)(uintptr_t)&IecFatalHandler;
    char buf[192];
    int len = snprintf(buf, sizeof buf,
                       "\n[IEC] FATAL signal %d addr=%p anchor=%p frames=%d\n",
                       sig, si ? si->si_addr : NULL, (void*)anchor, n);
    if (len > 0) { ssize_t w = write(2, buf, (size_t)len); (void)w; }
    for (int i = 0; i < n; i++) {
        long delta = (long)(uintptr_t)bt[i] - (long)anchor;
        len = snprintf(buf, sizeof buf, "[IEC]   #%d %p delta=%+ld\n",
                       i, bt[i], delta);
        if (len > 0) { ssize_t w = write(2, buf, (size_t)len); (void)w; }
    }
    _exit(139);
}

/* A stack overflow can exhaust the stack the handler would run on, leaving
 * nothing behind. An alternate stack lets SA_ONSTACK switch away from it. */
static char g_alt_stack[64 * 1024];

__attribute__((constructor))
static void IecSandboxInit(void) {
    setvbuf(stderr, NULL, _IOLBF, 0);

    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp = g_alt_stack;
    ss.ss_size = sizeof g_alt_stack;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = IecFatalHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
    sigaction(SIGSYS,  &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
}
