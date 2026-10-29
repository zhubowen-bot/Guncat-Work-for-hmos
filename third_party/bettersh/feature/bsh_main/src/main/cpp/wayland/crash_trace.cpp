// crash_trace.cpp —— host 侧崩溃取证：把现场写进 $SYSROOT/host-crash.log
//
// ── 为什么要有这个 ──────────────────────────────────────────────────────
// OHOS 自己的 DfxSignalHandler 会把现场落到 /data/log/faultlog/temp/cppcrash-*.json，
// 而那个目录 shell 读不了（Permission denied），`hidumper -s 1201 -a -p Faultlogger`
// 也取不出来，设备上更没有 gdb —— 于是"某某线程为什么崩"这件事长期只能靠推断。
// guest 侧早有对应的报告器（shim/compat_shim.c 的 cr_reporter），这里补 host 侧：
// 把 pc/lr/fpwalk 用 dladdr 反查成 ".so+偏移"，写进资源根下的 host-crash.log
// （资源根是 777，hdc 读得到）。
//
// 三个讲究：
//   * 单独的信号栈（SA_ONSTACK）：崩的时候原栈往往正是坏的；
//   * fd 在**装的时候**就开好，handler 里只 write（async-signal-safe），不调 open/malloc；
//   * 打完**交回系统原来的 handler**（restore + raise）—— 我们只是"多说一句"，
//     不该把系统自己的 minidump 上报顶掉。
//
// ── 它抓到的第一个案子（值得记着，因为它极难从现象反推）────────────────
// wayland/data_device.cpp 的 mgr_bind 里把资源 destructor 写成了
// `[](wl_resource* res) { wl_resource_destroy(res); }` —— 资源自己销毁自己。
// libwayland 的 wl_resource_destroy → destroy_resource() 里有
// `if (resource->destroy) resource->destroy(resource);` 且**不会清** destroy，
// 于是无限自我递归直到栈耗尽。现象是"fault 永远落在栈保护页下方"，faultlogger
// 会误报成 stack-buffer-overflow，而**加多大栈都没用**。现场见 build/vscode/STATUS.md。

// dladdr 要 _GNU_SOURCE（compat_shim.c 里那份 guest 报告器也是这么开的）
#define _GNU_SOURCE
#include "crash_trace.h"

#include <dlfcn.h>
#include <stdio.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

#include "../common/bsh_paths.h"

#undef LOG_TAG
#define LOG_TAG "BSH_CrashTrace"
#include <hilog/log.h>

namespace {

int g_crashFd = -1;
struct sigaction g_oldSa[3];
const int g_traced[3] = { SIGSEGV, SIGBUS, SIGABRT };

void ctPut(const char* s)
{
    if (g_crashFd < 0) return;
    ssize_t w = write(g_crashFd, s, strlen(s));
    (void)w;
}

void ctHex(unsigned long v)
{
    char b[19];
    b[0] = '0'; b[1] = 'x';
    for (int i = 17; i >= 2; i--) { b[i] = "0123456789abcdef"[v & 0xf]; v >>= 4; }
    b[18] = 0;
    ctPut(b);
}

void ctFrame(const char* tag, unsigned long a)
{
    ctPut(tag);
    ctHex(a);
    Dl_info di;
    if (a && dladdr((void*)a, &di) && di.dli_fname) {
        ctPut(" in=");
        ctPut(di.dli_fname);
        ctPut("+");
        ctHex(a - (unsigned long)(uintptr_t)di.dli_fbase);
        if (di.dli_sname) { ctPut(" sym="); ctPut(di.dli_sname); }
    }
    ctPut("\n");
}

void ctHandler(int sig, siginfo_t* si, void* uctx)
{
    ctPut("\n=== host crash ===\n");
    ctPut("signal=");
    ctHex((unsigned long)sig);
    ctPut(" fault=");
    ctHex((unsigned long)(uintptr_t)(si ? si->si_addr : nullptr));
    ctPut("\n");
    if (uctx) {
        ucontext_t* uc = (ucontext_t*)uctx;
        ctFrame("pc=", (unsigned long)uc->uc_mcontext.pc);
        ctFrame("lr=", (unsigned long)uc->uc_mcontext.regs[30]);
        ctPut("sp=");
        ctHex((unsigned long)uc->uc_mcontext.sp);
        ctPut("\n-- fpwalk --\n");
        unsigned long fp = (unsigned long)uc->uc_mcontext.regs[29];
        for (int i = 0; i < 32 && fp; i++) {
            unsigned long* fr = (unsigned long*)(uintptr_t)fp;
            unsigned long next = fr[0], lr = fr[1];
            ctFrame("  ", lr);
            if (next <= fp) break;
            fp = next;
        }
        ctPut("-- stackwords --\n");
        unsigned long* sp = (unsigned long*)(uintptr_t)uc->uc_mcontext.sp;
        for (int i = 0; i < 32; i++) ctFrame("  ", sp[i]);
    }
    ctPut("=== end ===\n");

    for (int i = 0; i < 3; i++) {
        if (g_traced[i] == sig) {
            sigaction(sig, &g_oldSa[i], nullptr);
            raise(sig);
            break;
        }
    }
    _exit(128 + sig);
}

}  // namespace

void InstallHostCrashTrace(void)
{
    if (g_crashFd >= 0) return;   // 幂等

    // 用访问器而不是 getenv("BSH_SYSROOT")：合成器启动时那个环境变量**还没设**
    // （.bshrc 是会话开始后才 source 的），用 getenv 会退化成相对路径、落到不可写的
    // cwd —— 实测这么白跑过一轮。bsh_sysroot() 有编译期默认值兜底，并会自己 setenv。
    char path[512];
    snprintf(path, sizeof path, "%s/host-crash.log", bsh_sysroot());
    g_crashFd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (g_crashFd < 0) return;

    static char altstack[256 * 1024] __attribute__((aligned(16)));
    stack_t ss;
    ss.ss_sp = altstack;
    ss.ss_size = sizeof altstack;
    ss.ss_flags = 0;
    sigaltstack(&ss, nullptr);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = ctHandler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &g_oldSa[0]);
    sigaction(SIGBUS,  &sa, &g_oldSa[1]);
    sigaction(SIGABRT, &sa, &g_oldSa[2]);
    OH_LOG_INFO(LOG_APP, "crash trace armed -> %{public}s", path);
}
