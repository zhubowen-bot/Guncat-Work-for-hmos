// ssh/sandbox_compat.c — 给 dropbear 补的沙箱缺口
//
// BetterSH 沙箱的 libc 比普通 Linux 少几样 dropbear 依赖的东西,这里在
// libsshcore.so 内部补齐。之所以放在我们自己的目标文件里(而不是改 dropbear
// 源码):配合链接期的 -Bsymbolic-functions,dropbear 自己对这些符号的调用会绑到
// 本实现,既不改上游、也不会影响宿主进程里别的库。
//
// 目前一项:
//   getpass() —— ohos libc 没有这个符号,而 dropbear 的 cli-auth.c 是**无条件**
//   调用它的(不受 HAVE_GETPASS 保护),所以必须同时提供声明(见构建脚本生成的
//   localoptions.h)与实现,否则 dbclient 只能靠 $DROPBEAR_PASSWORD 做密码认证。
//
// 注意:我们的 pty 是 socketpair(无内核行规程、无 ICANON),所以这里必须自己
// 按字节收行、自己处理退格,并且把 \r 与 \n 都当行尾。
#include <errno.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

/* 崩溃现场诊断用(见文件末尾的崩溃处理器) */
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>

#define BSH_GETPASS_MAX 256

char* getpass(const char* prompt) {
    static char buf[BSH_GETPASS_MAX];
    size_t n = 0;
    struct termios oldt, newt;
    int have_tio = (tcgetattr(STDIN_FILENO, &oldt) == 0);

    if (prompt && *prompt) {
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
            break;                      /* 真错误:把已读到的当结果 */
        }
        if (r == 0) break;               /* EOF */
        if (c == '\n' || c == '\r') break;
        if (c == 0x7f || c == 0x08) {    /* 退格 */
            if (n > 0) n--;
            continue;
        }
        if ((unsigned char)c < 0x20) continue;   /* 其余控制字符丢弃 */
        if (n < BSH_GETPASS_MAX - 1) buf[n++] = c;
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

/* ---- 崩溃现场:让日志保得住,并留下信号 + 调用栈 ----
 * 服务端是 fork 出来的子进程,崩了之后没有别的地方可查(设备上 faultlog 目录
 * 读不到),而 stderr 重定向到文件时是全缓冲的,缓冲区里最后几行恰恰是最关键
 * 的现场。这里在 dlopen(进程刚起来、还没有任何 stderr 输出)时:
 *   1) 把 stderr 改成行缓冲,每行立刻落盘;
 *   2) 装一个最小崩溃处理器 —— 打印信号号、出错地址和每层栈帧**相对本函数的
 *      偏移**。偏移可以直接用 llvm-symbolizer 对着 libsshcore.so 还原成函数名
 *      (本函数在符号表里的地址用 llvm-nm 一查就有,不用 dladdr,省掉 _GNU_SOURCE)。 */
static void BshFatalHandler(int sig, siginfo_t* si, void* uc) {
    (void)uc;
    void* bt[40];
    int n = backtrace(bt, sizeof bt / sizeof bt[0]);
    unsigned long anchor = (unsigned long)(uintptr_t)&BshFatalHandler;
    char buf[192];
    int len = snprintf(buf, sizeof buf,
                       "\n[BSH] FATAL signal %d addr=%p anchor=%p frames=%d\n",
                       sig, si ? si->si_addr : NULL, (void*)anchor, n);
    if (len > 0) { ssize_t w = write(2, buf, (size_t)len); (void)w; }
    for (int i = 0; i < n; i++) {
        long delta = (long)(uintptr_t)bt[i] - (long)anchor;
        len = snprintf(buf, sizeof buf, "[BSH]   #%d %p delta=%+ld\n",
                       i, bt[i], delta);
        if (len > 0) { ssize_t w = write(2, buf, (size_t)len); (void)w; }
    }
    _exit(139);
}

/* 备用信号栈:如果是栈溢出,信号处理函数若还跑在已经耗尽的原栈上,会自己
 * 先死掉 —— 现场什么都留不下。给它一块独立的栈,SA_ONSTACK 才会切过去。 */
static char g_alt_stack[64 * 1024];

__attribute__((constructor))
static void BshSandboxInit(void) {
    setvbuf(stderr, NULL, _IOLBF, 0);

    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp = g_alt_stack;
    ss.ss_size = sizeof g_alt_stack;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = BshFatalHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
    sigaction(SIGSYS,  &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
}
