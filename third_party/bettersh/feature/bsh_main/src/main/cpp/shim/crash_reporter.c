// crash_reporter.c —— guest 内的崩溃报告器（**musl 与 glibc 两份 shim 都要编**）
//
// 为什么要有：宿主的 elfloader 也装了 SIGSEGV handler（elf_loader.cpp 的
// arm_fault_handlers），但实测某些 guest（如 Qt）崩得"一声不响" —— 进程 rc=139、
// 日志一行没有。更麻烦的是**崩溃日志的落点**：OHOS 把 faultlog 写在
// /data/log/faultlog/temp/ 下，而那是 shell 读不到的目录，设备上也没有 gdb。
// 所以把报告做进 guest 自己进程里，直接写自己的 stderr（也就进了调用方重定向的那个文件）：
//   - 用独立信号栈（崩溃时原来的栈往往正是坏的）；
//   - 同时接 SIGSEGV/SIGILL/SIGBUS/SIGABRT；
//   - 用 dladdr 说出 pc/lr/每一帧落在哪个 .so 的哪个偏移 —— 没有调试器时这就是最有用的信息。
//
// ⚠ 这份**不能**留在 compat_shim.c 里：那个文件是"给老 musl 补缺的 libc 符号"
// （backtrace/renameat2/pthread_getname_np…），只编进 musl 那份，补到 glibc 上会遮蔽真实现。
// 而崩溃报告器两边都要 —— 实测 `code`（**glibc** guest）静默退出时一条 [crash] 都没有，
// 正是因为它只在 musl 那份里。于是一分为二（见 scripts/build_shim.sh）。
//
// 边界：静态链接的 guest 吃不到（LD_PRELOAD 对静态无效）。
//
// 除了打报告，它还顺手落一份**模块装载表**（$BSH_SYSROOT/guestphdr-<pid>.txt）——
// 匿名装载下 /proc/maps 与设备 unwinder 都指不出"某个地址属于哪个模块"，
// 而 dl_iterate_phdr 知道。见下面 cr_dump_phdr() 的说明。

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <link.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ucontext.h>

/* ── 模块装载表：给"匿名装载"下的地址归属用 ───────────────────────────────
 * 为什么需要：我们的 elfloader 是**匿名装载**（沙箱下唯一能走的路：匿名预留 +
 * pread + mprotect）。后果是"崩溃地址属于哪个模块"整个断掉了：
 *   - /proc/<pid>/maps 里找不到任何 `lib/vscode/code` / 闭包 .so 的条目；
 *   - 设备自带的 unwinder / dladdr 也拿不到模块名，hilog 里只剩
 *     `#00 pc 0000000000000001 ???`（实测）。
 * 但 guest 自己知道：dl_iterate_phdr() 给出每个模块的 dlpi_addr 与路径。
 * 把它 dump 到 $BSH_SYSROOT/guestphdr-<pid>.txt，就能把 hilog 里的 ELR 折成
 * "模块 + 偏移"（实测这台设备几乎没有 ASLR：三次独立运行的 ELR 完全相同，
 * 所以一份表可以反复用）。
 *
 * 门控：`BSH_GUEST_PHDR=1` 才在启动时 dump（免得平时往资源根里拉文件）；
 *       但**崩溃时无条件 dump 一份** —— 那时候最需要，成本也已经付了。 */
static int cr_phdr_cb(struct dl_phdr_info *info, size_t sz, void *data)
{
    (void)sz;
    int fd = *(int *)data;
    const char *n = (info->dlpi_name && *info->dlpi_name) ? info->dlpi_name : "(main)";

    /* 该模块所有 PT_LOAD 的 [lo, hi) 绝对区间：有了区间就能直接判"地址在不在里面" */
    unsigned long lo = ~0UL, hi = 0;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *p = &info->dlpi_phdr[i];
        if (p->p_type != PT_LOAD) continue;
        if ((unsigned long)p->p_vaddr < lo) lo = (unsigned long)p->p_vaddr;
        unsigned long e = (unsigned long)p->p_vaddr + (unsigned long)p->p_memsz;
        if (e > hi) hi = e;
    }
    if (lo == ~0UL) return 0;
    dprintf(fd, "%016lx %016lx %016lx %s\n",
            (unsigned long)info->dlpi_addr,
            (unsigned long)info->dlpi_addr + lo,
            (unsigned long)info->dlpi_addr + hi, n);
    return 0;
}

/* 写一份模块表；失败就静默放弃（旁路取证，绝不能影响 guest 启动） */
static void cr_dump_phdr(void)
{
    const char *root = getenv("BSH_SYSROOT");
    if (!root || !*root) return;
    char path[512];
    snprintf(path, sizeof path, "%s/guestphdr-%d.txt", root, (int)getpid());
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    dprintf(fd, "# pid=%d  (bias lo hi module)\n", (int)getpid());
    dl_iterate_phdr(cr_phdr_cb, &fd);
    close(fd);
}

/* ── dlopen 之后补写一份模块表 ───────────────────────────────────────────
 * 启动时那份表只含"链接期就有的 NEEDED"；Chromium 还会在运行中 dlopen 一堆东西
 * （libEGL / libGLESv2 / SwiftShader …），而那些恰恰可能是崩的地方。
 * 这里拦一层 dlopen，返回后把表**覆盖重写**一遍 —— 于是"进程死前最后一份表"
 * 就是它最完整的模块视图。只在 BSH_GUEST_PHDR=1 时补写，默认行为不变。
 * ⚠ 必须防重入：dlsym(RTLD_NEXT, "dlopen") 自己会走 loader，可能再进 dlopen。 */
static int cr_dlopen_flag;
static void *(*cr_real_dlopen)(const char *, int);
static int cr_phdr_wanted = -1;

static int cr_want_phdr(void)
{
    if (cr_phdr_wanted < 0) {
        const char *v = getenv("BSH_GUEST_PHDR");
        cr_phdr_wanted = (v && *v && v[0] != '0') ? 1 : 0;
    }
    return cr_phdr_wanted;
}

void *dlopen(const char *file, int mode)
{
    if (!cr_real_dlopen) cr_real_dlopen = dlsym(RTLD_NEXT, "dlopen");
    if (!cr_real_dlopen) return NULL;
    if (cr_dlopen_flag) return cr_real_dlopen(file, mode);

    cr_dlopen_flag = 1;
    void *h = cr_real_dlopen(file, mode);
    cr_dlopen_flag = 0;

    if (h && cr_want_phdr()) cr_dump_phdr();
    return h;
}

static void cr_put(const char *s)
{
    while (*s) { if (write(2, s, 1) < 0) return; s++; }
}

static void cr_hex(unsigned long v)
{
    char b[19];
    int i;
    b[0] = '0'; b[1] = 'x';
    for (i = 17; i >= 2; i--) { b[i] = "0123456789abcdef"[v & 0xf]; v >>= 4; }
    b[18] = 0;
    cr_put(b);
}

static void cr_reporter(int sig, siginfo_t *si, void *uctx)
{
    /* 崩的这一刻先把模块表落下来 —— 有它才能把下面的 pc/lr 折成"模块+偏移" */
    cr_dump_phdr();
    cr_put("\n[crash] signal=");
    cr_hex((unsigned long)sig);
    cr_put(" fault=");
    cr_hex((unsigned long)(uintptr_t)(si ? si->si_addr : 0));
    if (uctx) {
        ucontext_t *uc = (ucontext_t *)uctx;
        unsigned long pc = (unsigned long)uc->uc_mcontext.pc;
        cr_put(" pc=");
        cr_hex(pc);
        Dl_info di;
        if (pc && dladdr((void *)(uintptr_t)pc, &di) && di.dli_fname) {
            cr_put(" in=");
            cr_put(di.dli_fname);
            cr_put("+");
            cr_hex(pc - (unsigned long)(uintptr_t)di.dli_fbase);
        }
        /* 栈回溯:aarch64 的 x29 是帧指针链(编译时没省才有)。
         * Qt/libc++ 多半没留帧指针,所以下面同时打 lr 与栈顶若干字 —— 用 dladdr 反查
         * 它们的归属就能把调用链拼出来。 */
        cr_put("\n[crash] lr=");
        cr_hex((unsigned long)uc->uc_mcontext.regs[30]);
        {
            Dl_info li;
            unsigned long lr = (unsigned long)uc->uc_mcontext.regs[30];
            if (lr && dladdr((void *)(uintptr_t)lr, &li) && li.dli_fname) {
                cr_put(" in=");
                cr_put(li.dli_fname);
                cr_put("+");
                cr_hex(lr - (unsigned long)(uintptr_t)li.dli_fbase);
            }
        }
        cr_put(" sp=");
        cr_hex((unsigned long)uc->uc_mcontext.sp);
        cr_put("\n[crash] x0=");
        cr_hex((unsigned long)uc->uc_mcontext.regs[0]);
        cr_put(" x1=");
        cr_hex((unsigned long)uc->uc_mcontext.regs[1]);
        cr_put("\n[crash] stack:");
        {
            unsigned long *sp = (unsigned long *)(uintptr_t)uc->uc_mcontext.sp;
            for (int i = 0; i < 16; i++) {
                cr_put(" ");
                cr_hex(sp[i]);
            }
        }
        cr_put("\n[crash] fpwalk:");
        unsigned long fp = (unsigned long)uc->uc_mcontext.regs[29];
        for (int i = 0; i < 16 && fp; i++) {
            unsigned long *frame = (unsigned long *)(uintptr_t)fp;
            unsigned long next_fp = frame[0], lr = frame[1];
            cr_put(" ");
            cr_hex(lr);
            if (next_fp <= fp) break;
            fp = next_fp;
        }
    }
    cr_put("\n");
    (void)write(2, "\n", 1);
    _exit(128 + sig);
}

__attribute__((constructor)) static void cr_arm(void)
{
    if (getenv("BSH_GUEST_PHDR")) cr_dump_phdr();

    static char alt[128 * 1024] __attribute__((aligned(16)));
    stack_t ss;
    ss.ss_sp = alt;
    ss.ss_size = sizeof alt;
    ss.ss_flags = 0;
    sigaltstack(&ss, 0);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = cr_reporter;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, 0);
    sigaction(SIGBUS, &sa, 0);
    sigaction(SIGILL, &sa, 0);
    sigaction(SIGABRT, &sa, 0);
}
