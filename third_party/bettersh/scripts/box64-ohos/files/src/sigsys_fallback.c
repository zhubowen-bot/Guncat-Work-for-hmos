/* BOX64_OHOS_SIGSYS — patch 50
 *
 * SIGSYS fallback for HarmonyOS seccomp white-list policy.
 * 把被 seccomp 拦下的 syscall 伪造成 -ENOSYS 让 libc 走 fallback.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <ucontext.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

/* OHOS_PATCH_LOG_GATE */
#include <stdlib.h>
static int ohos_sigsys_log_level(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BOX64_LOG");
        cached = (v && *v) ? atoi(v) : 0;
        if (cached < 0) cached = 0;
    }
    return cached;
}

static void box64_sigsys_handler(int sig, siginfo_t *info, void *ucontext) {
    (void)sig;
    ucontext_t *uc = (ucontext_t*)ucontext;
    int nr = info->si_syscall;
#if defined(__aarch64__)
    uc->uc_mcontext.regs[0] = (unsigned long)(-ENOSYS);
#elif defined(__x86_64__)
    uc->uc_mcontext.gregs[REG_RAX] = (greg_t)(-ENOSYS);
#elif defined(__arm__)
    uc->uc_mcontext.arm_r0 = (unsigned long)(-ENOSYS);
#endif
    char msg[96];
    int n = snprintf(msg, sizeof(msg),
                     "[box64] SIGSYS caught: nr=%d -> ENOSYS\n", nr);
    if (n > 0) (void)!write(2, msg, (size_t)n);
}

void box64_install_sigsys_fallback(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = box64_sigsys_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSYS, &sa, NULL) != 0) {
        const char *e = "[box64] WARN: install SIGSYS handler failed\n";
        (void)!write(2, e, strlen(e));
    } else {
        if (ohos_sigsys_log_level() >= 1) {
            const char *m = "[box64] SIGSYS fallback installed\n";
            (void)!write(2, m, strlen(m));
        }
    }
}

__attribute__((constructor(101)))
static void box64_sigsys_ctor(void) {
    box64_install_sigsys_fallback();
}
