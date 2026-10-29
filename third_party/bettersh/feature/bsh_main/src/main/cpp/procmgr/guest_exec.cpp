// ⚠️⚠️ 暂时不使用（2026-09-30）⚠️⚠️
//
// 本文件是"用 seccomp TRAP 拦 execve 再委托"的那一版实现，**现在已经不启用**：
//   - 已从 CMakeLists.txt 移除（不参与编译），procmgr 里对 InstallGuestExecDelegate()
//     的调用也删了；
//   - 取而代之的是同一份 shim 家族里的 entry/src/main/cpp/shim/exec_shim.c ——
//     用 LD_PRELOAD 拦 execve/execv/execvp/…/posix_spawn，与 tty/fs/pty 三个模块
//     同一种做法（procmgr 按 guest 的 PT_INTERP 预载对应 libc 的那份 .so）
//
// ---------------------------------------------------------------------------
// procmgr/guest_exec.cpp — guest 内部 exec 的委托层（seccomp TRAP）
//
// 背景：沙箱里没有真 exec —— guest（elfloader 装起来的二进制）调 execve 一律
// EACCES（三层实测一致：宿主进程 / 命令 so / guest 都是）。而"能 exec"是 shell、
// 脚本、构建工具的基本功，所以得把它还回去。
//
// 做法：procmgr 在**跳进 guest 之前**给这个子进程装一条 seccomp 过滤器，只拦
// execve/execveat → SECCOMP_RET_TRAP。SIGSYS handler 从 ucontext 里取 aarch64 的
// x0..x4（路径 / argv / envp / flags），把请求经 control socket 交给 procmgr
// （进程只能由 procmgr 创建 —— 它才有进程表），等它跑完，再 _exit(它的退出码)。
//
// 语义差别（必须知道，别指望它和真 exec 一模一样）：
//   - 调用 execve 的那个进程**不会变成**目标镜像：它请 procmgr 起一个进程、等它
//     结束、然后用它的退出码退出。对父进程（shell / 脚本）来说退出码与 fd 继承都
//     一样，所以管道、&&、$? 都对；做不到的是"exec 之后同一进程身份延续"（pid 变了）。
//   - 目标不存在 / 不可执行：handler **改 ucontext 让 syscall 返回 errno**，让 guest
//     继续跑（它该看到 ENOENT 而不是被杀）。这一条是整套机制里最容易翻车的地方 ——
//     返回值和返回地址都在寄存器里，改错了就是崩或者死循环。
//   - 被信号打死的目标：我们只能拿到 128+sig 这个码（procmgr 的 waiter 就是这么算
//     的），所以调用方看到的是"退出码"而不是"自己被同一个信号打死"。
//   - vfork/clone(CLONE_VFORK|CLONE_VM) 出来的进程里调 execve（glibc 的 posix_spawn
//     在某些路径上这么做）：信号帧落在父进程的栈上，我们只读、最后 _exit，不回父进程，
//     实践上没问题；但这条没有专门的测试覆盖。
//
// 信号上下文里的纪律：**不 malloc、不用 stdio**（handler 可能打断 malloc 中间态，
// 再进去就死锁），所以下面的协议拼装/解析全部用栈上的固定缓冲与裸 syscall，而不是
// 复用 bsh_client.c（它内部 malloc）。协议本身与 ctrl_socket.cpp 里那份一致。
#define _GNU_SOURCE   /* ucontext 里的 uc_mcontext.regs / SYS_SECCOMP / CMSG_* 都要它 */

#include "guest_exec.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>      /* 只用 snprintf(write 进栈缓冲,不碰 stdio 流,handler 里安全) */
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <ucontext.h>
#include <unistd.h>

#include <hilog/log.h>

/* 内核在 SIGSYS 的 si_code 里放的这个值:OHOS 这份 sysroot 的 <linux/seccomp.h>
 * 没带它(内核 UAPI 里是 #define SYS_SECCOMP 1),自己补上。 */
#ifndef SYS_SECCOMP
#define SYS_SECCOMP 1
#endif

namespace bsh {
namespace procmgr {
namespace {

constexpr size_t kReqCap  = 32 * 1024;   // 请求缓冲（栈上）
constexpr size_t kRespCap = 16 * 1024;   // 响应缓冲（栈上）
constexpr int    kMaxFds  = 16;          // 与 procmgr 侧 cmsg 上限同值
constexpr int    kMaxArgs = 512;         // argv/envp 各自的上限（防野指针打转）

/* 安装时抓下来的 socket 路径：handler 里不能信 getenv（guest 可能改过环境） */
char g_sock_path[192];
bool g_installed = false;

/* ---------- 无 malloc 的小工具（信号上下文里只能用这些） ---------- */

struct Buf {
    char*  p;
    size_t cap;
    size_t len;
    bool   ovf;
};

void bput(Buf* b, const char* s, size_t n) {
    if (b->ovf) return;
    if (b->len + n > b->cap) { b->ovf = true; return; }
    memcpy(b->p + b->len, s, n);
    b->len += n;
}
void bputs(Buf* b, const char* s) { bput(b, s, strlen(s)); }
void bputc(Buf* b, char c) { bput(b, &c, 1); }
/* 协议是"一行一个 KEY 值"，值里不能有换行 —— 有换行的参数直接拒绝（宁可不委托，
 * 也不能把协议拼坏：一个换行就能让 procmgr 收到伪造的字段） */
bool bputline(Buf* b, const char* key, const char* val) {
    if (!val) return true;
    if (strchr(val, '\n')) return false;
    bputs(b, key); bputc(b, ' '); bputs(b, val); bputc(b, '\n');
    return true;
}

/* 4 字节大端长度 + body；带 SCM_RIGHTS 时一并送出 */
bool SendFrame(int fd, const char* body, size_t len, const int* fds, int nfds) {
    uint8_t hdr[4] = { (uint8_t)(len >> 24), (uint8_t)(len >> 16),
                       (uint8_t)(len >> 8),  (uint8_t)len };
    struct iovec iov[2] = { { hdr, 4 }, { (void*)body, len } };
    uint8_t cbuf[CMSG_SPACE(sizeof(int) * kMaxFds)];
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = iov;
    msg.msg_iovlen = 2;
    if (nfds > 0) {
        memset(cbuf, 0, sizeof cbuf);
        msg.msg_control = cbuf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)nfds);
        struct cmsghdr* c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)nfds);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * (size_t)nfds);
    }
    size_t sent = 0;
    size_t total = 4 + len;
    for (;;) {
        ssize_t w = sendmsg(fd, &msg, 0);
        if (w < 0) { if (errno == EINTR) continue; return false; }
        sent += (size_t)w;
        if (sent >= total) return true;
        /* 半截写入：把已写掉的部分从 iovec 里切掉再继续 */
        size_t skip = sent;
        if (skip < 4) { iov[0].iov_base = hdr + skip; iov[0].iov_len = 4 - skip; }
        else { iov[0].iov_len = 0; iov[1].iov_base = (void*)(body + (skip - 4)); iov[1].iov_len = len - (skip - 4); }
        msg.msg_control = nullptr;
        msg.msg_controllen = 0;
    }
}

bool ReadExact(int fd, void* dst, size_t n) {
    uint8_t* p = (uint8_t*)dst;
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, p + got, n - got, 0);
        if (r == 0) return false;
        if (r < 0) { if (errno == EINTR) continue; return false; }
        got += (size_t)r;
    }
    return true;
}

bool ReadFrame(int fd, char* out, size_t cap) {
    uint8_t hdr[4];
    if (!ReadExact(fd, hdr, 4)) return false;
    uint32_t total = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                     ((uint32_t)hdr[2] << 8) | (uint32_t)hdr[3];
    if (total >= cap) return false;
    if (!ReadExact(fd, out, total)) return false;
    out[total] = '\0';
    return true;
}

const char* LineValue(const char* resp, const char* key, size_t* vlen) {
    size_t kl = strlen(key);
    for (const char* p = resp; *p; ) {
        if (strncmp(p, key, kl) == 0 && p[kl] == ' ') {
            const char* v = p + kl + 1;
            const char* nl = strchr(v, '\n');
            *vlen = nl ? (size_t)(nl - v) : strlen(v);
            return v;
        }
        const char* nl = strchr(p, '\n');
        if (!nl) break;
        p = nl + 1;
    }
    return nullptr;
}

int ConnectCtrl() {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    size_t n = strlen(g_sock_path);
    if (n >= sizeof sa.sun_path) { close(fd); return -1; }
    memcpy(sa.sun_path, g_sock_path, n + 1);
    if (connect(fd, (struct sockaddr*)&sa, sizeof sa) != 0) { close(fd); return -1; }
    return fd;
}

/* 收集要带过去的 fd：枚举 /proc/self/fd（getdents64 直读静态缓冲，不走 opendir ——
 * 那会 malloc）。跳过：目录 fd 自己、带 FD_CLOEXEC 的（真 exec 会关掉它们，emulation
 * 也该关）。返回个数；一个都没有时返回 0。 */
int CollectFds(int* fds, int max) {
    int n = 0;
    int dfd = (int)syscall(SYS_openat, AT_FDCWD, "/proc/self/fd",
                           O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) {
        for (int v = 0; v <= 2 && n < max; v++) fds[n++] = v;
        return n;
    }
    static char dirbuf[8192];
    for (;;) {
        long got = syscall(SYS_getdents64, dfd, dirbuf, sizeof dirbuf);
        if (got <= 0) break;
        for (long off = 0; off < got; ) {
            struct linux_dirent64 {
                uint64_t d_ino; int64_t d_off; uint16_t d_reclen;
                unsigned char d_type; char d_name[];
            };
            auto* d = (struct linux_dirent64*)(dirbuf + off);
            off += d->d_reclen;
            if (d->d_name[0] < '0' || d->d_name[0] > '9') continue;   // "." / ".."
            int v = atoi(d->d_name);
            if (v < 0 || v == dfd) continue;
            int fl = fcntl(v, F_GETFD);
            if (fl < 0 || (fl & FD_CLOEXEC)) continue;
            if (n < max) fds[n++] = v;
        }
    }
    close(dfd);
    return n;
}

/* 委托一次 exec。成功返回 0 并把子进程退出码写进 *code；失败返回 errno（>0）。 */
int DelegateExec(const char* path, char* const argv[], char* const envp[],
                 const char* cwd, int* code) {
    int fds[kMaxFds];
    int nfds = CollectFds(fds, kMaxFds);
    if (nfds > kMaxFds) nfds = kMaxFds;

    char body[kReqCap];
    Buf b = { body, sizeof body, 0, false };
    bputs(&b, "CMD CREATE\nPROTO_VER 1\nREQ_ID 1\n");
    if (!bputline(&b, "EXE", path)) return ENAMETOOLONG;
    bputs(&b, "WAIT 1\n");
    bputline(&b, "CWD", cwd);
    if (argv) {
        for (int i = 0; argv[i] && i < kMaxArgs; i++)
            if (!bputline(&b, "ARG", argv[i])) return ENAMETOOLONG;
    }
    /* envp：服务端的 ENV 是"叠加在继承环境之上"（ctrl_socket 里是 push_back +
     * ApplyEnv），而典型调用方传的是自己那份完整 environ，所以叠加 ≈ 替换。
     * 真要做"清空再设"得加协议字段，先不做（记在注释里，免得以后有人以为是精确语义）。 */
    if (envp) {
        for (int i = 0; envp[i] && i < kMaxArgs; i++)
            if (!bputline(&b, "ENV", envp[i])) return ENAMETOOLONG;
    }
    char num[24];
    for (int i = 0; i < nfds; i++) {
        snprintf(num, sizeof num, "%d", fds[i]);   // snprintf: 不 malloc
        if (!bputline(&b, "FDREF", num)) return E2BIG;
    }
    bputs(&b, "END");
    if (b.ovf) return E2BIG;    // 命令行太长：让 guest 看到 E2BIG,别拼半截请求

    int fd = ConnectCtrl();
    if (fd < 0) return EIO;

    int ret = EIO;
    char resp[kRespCap];
    if (SendFrame(fd, body, b.len, fds, nfds) && ReadFrame(fd, resp, sizeof resp)) {
        size_t vlen = 0;
        if (LineValue(resp, "STATUS", &vlen) && vlen >= 2 && resp[0] && strstr(resp, "STATUS ok")) {
            const char* v = LineValue(resp, "EXIT_CODE", &vlen);
            *code = v ? atoi(v) : 0;
            ret = 0;
        } else {
            const char* m = LineValue(resp, "MSG", &vlen);
            if (m && vlen) {
                /* 给一条能对上号的 errno：目标不存在 → ENOENT，其余 → EACCES */
                if (strstr(m, "not found") || strstr(m, "no such")) ret = ENOENT;
                else ret = EACCES;
            }
        }
    }
    close(fd);
    return ret;
}

/* ---------- SIGSYS：把 execve 换成"请 procmgr 起进程" ---------- */

void OnSigsys(int sig, siginfo_t* si, void* uctx) {
    (void)sig;
    if (!si || si->si_code != SYS_SECCOMP) {
        /* 不是我们那条闸（别的 seccomp 过滤器/SIGSYS）：按默认处理，别把别人的信号吞掉 */
        signal(SIGSYS, SIG_DFL);
        raise(SIGSYS);
        return;
    }
    auto* uc = (ucontext_t*)uctx;
    unsigned long* r = uc->uc_mcontext.regs;      // aarch64: regs[0..30] = x0..x30
    long nr = (long)r[8];                         // x8 = syscall number

    const char* path = nullptr;
    char* const* argv = nullptr;
    char* const* envp = nullptr;
    int dirfd = AT_FDCWD;
    if (nr == SYS_execve) {
        path = (const char*)r[0];
        argv = (char* const*)r[1];
        envp = (char* const*)r[2];
    } else if (nr == SYS_execveat) {
        dirfd = (int)r[0];
        path = (const char*)r[1];
        argv = (char* const*)r[2];
        envp = (char* const*)r[3];
    } else {
        r[0] = (unsigned long)(long)-ENOSYS;
        return;
    }

    /* 路径补全：相对路径按**当前** cwd 解析（execve 的规矩）；execveat 带 dirfd 时
     * 借 /proc/self/fd/<dirfd> 表达（这样不用去猜 dirfd 指向哪个目录）。 */
    char full[4096];
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd) == nullptr) cwd[0] = '\0';
    if (!path || !*path) {
        r[0] = (unsigned long)(long)-ENOENT;
        return;
    }
    if (path[0] == '/') {
        snprintf(full, sizeof full, "%s", path);
    } else if (dirfd != AT_FDCWD) {
        snprintf(full, sizeof full, "/proc/self/fd/%d/%s", dirfd, path);
    } else {
        snprintf(full, sizeof full, "%s/%s", cwd, path);
    }

    /* 目标不可用就别委托了 —— 让 guest 看到和真 exec 一样的 errno */
    struct stat st;
    if (syscall(SYS_newfstatat, AT_FDCWD, full, &st, 0) != 0) {
        r[0] = (unsigned long)(long)-errno;
        return;
    }

    int code = 0;
    int err = DelegateExec(full, argv, envp, cwd, &code);
    if (err != 0) {
        r[0] = (unsigned long)(long)-err;   // 回到 guest，它看到 execve 失败
        return;
    }
    _exit(code & 0xFF);                      // 委托成功：本进程不再返回
}

bool InstallFilter() {
    struct sock_filter insns[] = {
        /* 只放行我们的架构，别的一律杀掉（防止用别的 ABI 的号绕过） */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        /* execve → TRAP */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_execve, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP),
        /* execveat → TRAP */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_execveat, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP),
        /* 其余一概放行（沙箱那道闸还在后面，不受影响） */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = { (unsigned short)(sizeof insns / sizeof insns[0]), insns };
    /* NO_NEW_PRIVS：非特权进程装过滤器必须先声明这个。副作用是本次进程内不再能吃
     * setuid 提权 —— 这个沙箱里本来也没有。 */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return false;
    if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog) != 0) return false;
    return true;
}

}  // namespace

bool InstallGuestExecDelegate() {
    if (g_installed) return true;
    /* 探测结果落一行文件:$HOME/guest-exec.log。为什么要文件而不是只打 hilog:
     * 自检脚本在应用里跑,读不了 hilog;失败时"到底是 seccomp 被拒还是别处"必须能一眼
     * 看出来(实测这行就是排查第一现场)。每次 kElf spawn 追加一行,量很小。 */
    auto note = [](const char* what, int err) {
        const char* home = getenv("HOME");
        if (!home || !*home) return;
        char p[512];
        snprintf(p, sizeof p, "%s/guest-exec.log", home);
        int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
        char line[256];
        int n = snprintf(line, sizeof line, "%s errno=%d (%s)\n", what, err, strerror(err));
        if (n > 0) { ssize_t w = write(fd, line, (size_t)n); (void)w; }
        close(fd);
    };

    const char* sock = getenv("BSH_CTRL_SOCK");
    if (!sock || !*sock) {
        OH_LOG_INFO(LOG_APP, "guest-exec: 没有 BSH_CTRL_SOCK，不装委托层");
        note("skip: no BSH_CTRL_SOCK", 0);
        return false;
    }
    /* 先探测 seccomp 能不能装：装了过滤器再发现不行就没法回退了（NO_NEW_PRIVS 是
     * 一次性的），不如失败就放弃，让 guest 继续按"没有 exec"跑 —— 也就是现在的行为。 */
    errno = 0;
    if (!InstallFilter()) {
        int e = errno;
        OH_LOG_INFO(LOG_APP, "guest-exec: 装 seccomp 过滤器失败(errno=%{public}d %{public}s)，"
                             "guest 内 exec 仍不可用", e, strerror(e));
        note("skip: seccomp install failed", e);
        return false;
    }
    snprintf(g_sock_path, sizeof g_sock_path, "%s", sock);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = OnSigsys;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSYS, &sa, nullptr) != 0) {
        int e = errno;
        OH_LOG_INFO(LOG_APP, "guest-exec: sigaction(SIGSYS) 失败 errno=%{public}d", e);
        note("skip: sigaction failed", e);
        return false;
    }
    g_installed = true;
    OH_LOG_INFO(LOG_APP, "guest-exec: 委托层已就绪（execve/execveat → procmgr）");
    note("ok", 0);
    return true;
}

}  // namespace procmgr
}  // namespace bsh
