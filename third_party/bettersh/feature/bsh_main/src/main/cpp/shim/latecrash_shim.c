/* latecrash.so —— 迟到安装的致命信号处理器。
 * 为什么需要"迟到"：Chromium 在自己的 main 里 sigaction(SIGSEGV/SIGBUS/...)，
 * 而 LD_PRELOAD 的 constructor 跑在它之前 ⇒ 正常写法会被它覆盖掉。
 * 这里 constructor 只起一个 detached 线程，睡几秒后再把处理器抢回来。
 * 触发时打印 pc/lr/sp/fault/x8，并把 /proc/self/maps 落盘，便于回宿主符号化。 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

static void dump_maps(void) {
    const char *p = getenv("BSH_LATECRASH_MAPS");
    if (!p) p = "/data/storage/el2/base/haps/tablet/files/late-crash.maps";
    int in = open("/proc/self/maps", O_RDONLY);
    if (in < 0) return;
    int out = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) { close(in); return; }
    char buf[8192];
    ssize_t n;
    while ((n = read(in, buf, sizeof buf)) > 0) write(out, buf, (size_t)n);
    close(in); close(out);
}

static void handler(int sig, siginfo_t *si, void *uc_) {
    ucontext_t *uc = (ucontext_t *)uc_;
    char buf[512];
    int n = snprintf(buf, sizeof buf,
        "\n[latecrash] sig=%d(%s) fault=%p pc=%p lr=%p sp=%p x0=%p x1=%p x8=%lld\n",
        sig, strsignal(sig), si ? si->si_addr : 0,
        (void *)uc->uc_mcontext.pc, (void *)uc->uc_mcontext.regs[30],
        (void *)uc->uc_mcontext.sp, (void *)uc->uc_mcontext.regs[0],
        (void *)uc->uc_mcontext.regs[1], (long long)uc->uc_mcontext.regs[8]);
    if (n > 0) write(2, buf, (size_t)n);
    dump_maps();
    _exit(128 + sig);
}

static void install(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, 0);
    sigaction(SIGBUS,  &sa, 0);
    sigaction(SIGILL,  &sa, 0);
    sigaction(SIGABRT, &sa, 0);
}

static void *worker(void *unused) {
    (void)unused;
    /* Chromium 会在 main 里覆盖信号处理器，而崩溃发生在 ~3s，所以不能只装一次：
     * 每 500ms 重装一次、连续 20 次（覆盖 0~10s 窗口），总能抢在崩溃之前的那一次。 */
    for (int i = 0; i < 20; i++) {
        install();
        usleep(500000);
    }
    return 0;
}

__attribute__((constructor)) static void lc_init(void) {
    /* 默认不启用：它会把 SIGSEGV 处理器从「别人的」抢过来，只适合调试期。
     * 由 procmgr 的 guest 环境或启动器设 BSH_LATECRASH=1 打开。 */
    if (!getenv("BSH_LATECRASH")) return;
    pthread_t t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &a, worker, 0) != 0) write(2, "[latecrash] thread failed\n", 27);
    pthread_attr_destroy(&a);
}
