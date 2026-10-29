// procmgr/caps.cpp — 启动时探测宿主能力(fork / exec / jit)
//
// 为什么要探:同样是鸿蒙沙箱,不同设备/不同发行渠道差别很大 —— 平板上可能拿得到
// 可写可执行内存,手机被应用市场策略挡掉;有的环境允许真 execve,有的只能
// fork + dlopen。这些差异直接决定"起一个程序"该走哪条路(procmgr 的
// kSoMain / kElf,以及预留的 kQemu),所以在进程创建入口处**先探一次**、
// 把结论缓存下来给决策用,而不是等到运行期踩坑再回溯。
//
// 时机:StartControlSocket 之后(它要求在任何 fork 之前完成)、任何实际 spawn
// 之前。幂等,重复调用只探一次。
//
// 每一项都尽量给出"能不能"之外的细节,便于设备差异排查:
//   fork —— 真 fork + waitpid 一次(procmgr 一切进程创建都建立在它之上);
//   exec —— 在 fork 出的子进程里 exec 系统 shell 一次:成功的话镜像被换掉、
//           子进程按 -c "exit 0" 退出,父进程从管道里读不到任何字节;失败则
//           errno 写进管道。这样"能不能"是二值的,不用靠猜错误码;
//   jit  —— 依次试五条拿可执行内存的路,记下第一条成功的:
//             1) 匿名 RWX      2) memfd + mmap(PROT_EXEC)      3) RW + mprotect(EXEC)
//             4) RW + prctl(jit,0) + mprotect(RWX) + prctl(jit,1)
//             5) 同 4 但目标 PROT_READ|PROT_EXEC
//           走哪条路是有意义的:将来给 guest 造可执行页(copy-on-write 段、
//           data-relro 之外的映射)要照抄能成功的那种。
//           第 4/5 条是 elfloader 真正走的路(jit_toggle + mprotect_final 的
//           Mode A,见 elfloader/elf_loader.cpp),早期版本漏了它,于是在"只有
//           prctl 这条路能过"的设备上会误报 jit=0 —— 判据漏了一条,结论就不
//           可用,所以宁可多试两条。
//
// 注意 jit 只探**映射是否成功**,不真的跳过去执行:后者若被内核拦住会直接
// SIGSEGV 掉整个进程,不适合当启动期探测(现有 elfloader 已经在用匿名 RWX,
// 所以在本机这条判据是够用的)。
#include "procmgr.h"

#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001
#endif
extern "C" int memfd_create(const char* name, unsigned int flags);

#undef LOG_TAG
#define LOG_TAG "BSH_ProcMgr"
#include <hilog/log.h>

namespace bsh {
namespace procmgr {
namespace {

HostCapabilities g_caps;    // 零初始化:全 false、route "none"
bool g_probed = false;

// 探针用的页大小;只为了验证"能不能映射",不关心实际用途
const size_t kProbeLen = 4096;

/* fork:判据用**管道**而不是 waitpid。
 * 宿主是 Chromium/ArkWeb 系进程,运行时自带 SIGCHLD 收割者,会把这里的子进程
 * 先收走,waitpid 于是返回 ECHILD —— 那是探测方法的假阴性,不是 fork 不可用
 * (实测第一版就报成了 fork=0,而同一时刻 procmgr 正在正常 fork 出 tar 子进程)。
 * 子进程先往管道写一个字节再退出,父进程读到了就说明"fork 成功且子进程真的跑
 * 起来了",与谁来回收无关。 */
bool ProbeFork() {
    int pfd[2];
    if (pipe(pfd) != 0) {
        g_caps.fork = false;
        return false;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        g_caps.fork = false;
        return false;
    }
    if (pid == 0) {
        close(pfd[0]);
        char b = 'f';
        ssize_t w = write(pfd[1], &b, 1);
        (void)w;
        _exit(0);            // 子进程立刻走,不留任何副作用
    }
    close(pfd[1]);
    char b = 0;
    ssize_t n = read(pfd[0], &b, 1);
    close(pfd[0]);
    int st = 0;
    waitpid(pid, &st, 0);    // 尽力回收;被运行时的收割者抢先也无妨
    g_caps.fork = (n == 1 && b == 'f');
    return g_caps.fork;
}

/* exec:必须放在子进程里试 —— 一旦 execve 成功,当前镜像就没了。
 * 用系统 shell 当靶子(它一定存在);带上 -c "exit 0" 是为了 exec 成功时
 * 那个子进程能自己干净退出,不会挂在 read(stdin) 上。 */
void ProbeExec() {
    int pfd[2];
    if (pipe(pfd) != 0) {
        g_caps.exec = false;
        g_caps.exec_errno = errno;
        return;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        g_caps.exec = false;
        g_caps.exec_errno = errno;
        return;
    }
    if (pid == 0) {
        close(pfd[0]);
        char* const argv[] = { (char*)"sh", (char*)"-c", (char*)"exit 0", nullptr };
        char* const envp[] = { nullptr };
        execve("/system/bin/sh", argv, envp);
        int e = errno;                       // 走到这里说明没换成镜像
        ssize_t w = write(pfd[1], &e, sizeof e);
        (void)w;
        _exit(0);
    }
    close(pfd[1]);
    int err = 0;
    ssize_t n = read(pfd[0], &err, sizeof err);
    close(pfd[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    if (n == (ssize_t)sizeof err) {
        g_caps.exec = false;                 // 写回了 errno = execve 失败
        g_caps.exec_errno = err;
    } else {
        g_caps.exec = true;                  // 管道空 = 镜像被换掉过
        g_caps.exec_errno = 0;
    }
}

/* jit:五条路依次试,第一条成功的记进 jit_route。
 * 顺序按"代价/通用性"排:匿名 RWX 最直接;不行退 memfd(有的内核只禁匿名
 * 可写可执行);再不行试"先 RW 再 mprotect 加 EXEC"(能绕开部分 W^X 策略);
 * 最后两条带上 elfloader 用的 prctl(jit) 开关。 */

/* 鸿蒙的 JIT 开关:elfloader 就是把可执行页这么要出来的(elf_loader.cpp 的
 * jit_toggle / mprotect_final Mode A),探测必须照着试一遍 —— 只试裸 mprotect
 * 会在这种设备上误报不可用。(命名带上 probe_ 前缀:elfloader 里有个同名
 * 非 static 符号,两边都进 libentry.so,重名会撞链接。) */
const long kJitPrctlOpt = 0x6a6974L;   /* ASCII 'jit' */
int probe_jit_toggle(int on) { return prctl(kJitPrctlOpt, 0, on, 0, 0); }

/* 匿名 RW → mprotect(prot)。toggle 为真时按 elfloader 的顺序在前后各关/开一次
 * JIT 开关。 */
bool ProbeAnonMprotect(int prot, bool toggle, const char* route) {
    void* r = mmap(nullptr, kProbeLen, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (r == MAP_FAILED) {
        g_caps.jit_errno = errno;
        return false;
    }
    if (toggle) probe_jit_toggle(0);
    int rc = mprotect(r, kProbeLen, prot);
    int e = errno;
    if (toggle) probe_jit_toggle(1);
    if (rc != 0) {
        g_caps.jit_errno = e;
        munmap(r, kProbeLen);
        return false;
    }
    munmap(r, kProbeLen);
    g_caps.jit = true;
    g_caps.jit_route = route;
    return true;
}

void ProbeJit() {
    void* p = mmap(nullptr, kProbeLen, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p != MAP_FAILED) {
        munmap(p, kProbeLen);
        g_caps.jit = true;
        g_caps.jit_route = "anon-rwx";
        return;
    }
    g_caps.jit_errno = errno;

    int fd = memfd_create("bsh-jit-probe", MFD_CLOEXEC);
    if (fd >= 0) {
        if (ftruncate(fd, (off_t)kProbeLen) == 0) {
            void* q = mmap(nullptr, kProbeLen, PROT_READ | PROT_EXEC,
                           MAP_PRIVATE, fd, 0);
            if (q != MAP_FAILED) {
                munmap(q, kProbeLen);
                close(fd);
                g_caps.jit = true;
                g_caps.jit_route = "memfd";
                return;
            }
            g_caps.jit_errno = errno;
        } else {
            g_caps.jit_errno = errno;
        }
        close(fd);
    } else {
        g_caps.jit_errno = errno;
    }

    if (ProbeAnonMprotect(PROT_READ | PROT_WRITE | PROT_EXEC, false, "mprotect"))
        return;
    if (ProbeAnonMprotect(PROT_READ | PROT_WRITE | PROT_EXEC, true, "prctl-rwx"))
        return;
    if (ProbeAnonMprotect(PROT_READ | PROT_EXEC, true, "prctl-rx"))
        return;

    g_caps.jit = false;
    g_caps.jit_route = "none";
}

}  // namespace

void ProbeCapabilities() {
    if (g_probed) return;
    g_probed = true;

    ProbeFork();
    ProbeExec();
    ProbeJit();

    OH_LOG_INFO(LOG_APP,
                "caps: fork=%{public}d exec=%{public}d(errno=%{public}d) "
                "jit=%{public}d(route=%{public}s errno=%{public}d)",
                g_caps.fork ? 1 : 0,
                g_caps.exec ? 1 : 0, g_caps.exec_errno,
                g_caps.jit ? 1 : 0, g_caps.jit_route, g_caps.jit_errno);
}

const HostCapabilities& Capabilities() {
    return g_caps;
}

}  // namespace procmgr
}  // namespace bsh
