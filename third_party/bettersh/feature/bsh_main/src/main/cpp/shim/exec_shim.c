// shim/exec_shim.c — exec 委托（**一份源码、两种"被调用"方式**）
//
// 沙箱里 guest 调 execve 一律 EACCES（三层实测一致）。"起别的程序"这件事只能转交出去 ——
// 进程只有 procmgr 能创建（它才有进程表）。本文件就是那个转交层，同时服务两个消费者
// （与 tty/fs/pty 三个模块同一套路，见 shim/shim_wrap.h）：
//
//   ① guest 侧（LD_PRELOAD，符号插入）—— 由 procmgr 按 guest 的 PT_INTERP 挑对应 libc 的
//      那份 libbshguest-{musl,glibc}.so 预载（procmgr.cpp 的 ChildRunElf）。必须**遵守
//      execve 的返回语义**：委托失败要 `return -1` 并把 errno 摆好（guest 还得继续跑、
//      还得能打印 "No such file"）；只有委托成功才 `_exit(子进程退出码)`（等价于"镜像被
//      换掉了"）。开关是 BSH_EXEC_SHIM（procmgr 给自己起的 guest 设）。
//
//   ② 命令 so 侧（`-DBSH_SHIM_WRAP` + 链接期 `-Wl,--wrap=`）—— toybox / mksh / clang /
//      lld / vim / python / node / dropbear / zip / weston-terminal 各自把本文件编进自己
//      （连同 bsh_client.o）。它们由主进程 dlopen 进来、排在全局搜索序**末尾**，
//      `dlsym(RTLD_NEXT)` 之后没有对象，所以只能用链接期替换。
//      **失败语义两条路已经统一**：都返回 -1 并把 errno 摆好（2026-10-03 改）。
//      原先命令 so 侧是"委托失败即 _exit(127)"，那会掐死 CPython subprocess 的
//      PATH 搜索（它靠 ENOENT 逐个试候选），详见下面 delegate_once 的注释。
//      只有**成功**是不可返回的：那时本进程 `_exit(子进程退出码)`，等价于"镜像被换掉"。
//      另外命令 so 侧**只做一件事**：把"要跑什么"原样交给 procmgr（唯一例外是
//      "起自己"→命令名，见 resolve_target()）—— 类型判断（启动器 / #! 脚本 / ELF /
//      按 e_machine 分流）全在 procmgr 的 Resolve() 里做，见下面的 resolve_target()；
//      guest 侧同样不需要 —— procmgr 对两条路用同一套规则。
//
// 两条路**共有**的部分：fd 收集（新进程是 procmgr 在**主进程**里 fork 的，继承不到我们的
// fd 表，必须用 SCM_RIGHTS 显式传 —— 漏传的直接后果是 `a | b`、`ls > f`、xargs 全失效）、
// envp 透传（`FOO=1 prog` 的改动只出现在 envp 里）、以及 posix_spawn 的"中间进程"把戏。
//
// 语义差别（如实记着）：
//   - 调用 exec 的那个进程**不会变成**目标镜像：它请 procmgr 起了另一个进程、等它结束、
//     然后以它的退出码退出。对父进程（shell/脚本）而言退出码、fd 继承、cwd/环境都对，
//     所以管道、&&、$? 都对；做不到的是"exec 之后同一进程身份延续"（pid 变了）。
//   - 目标存在但装载失败（比如不是 ELF）：这里给出的是"子进程退出码"，而不是真 execve
//     那样的 ENOEXEC。
//   - 被信号打死的目标：只能拿到 128+sig（procmgr 的 waiter 如此），不是"自己也被同一个
//     信号打死"。
//
// 不做静态链接的 guest：LD_PRELOAD 对静态链接无效（那需要改 libc 或 seccomp —— 后者做过
// 一版，在 procmgr/guest_exec.cpp 里留着但不启用，见它的文件头）。
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "shim_wrap.h"      // BSH_EXPORT：wrap 模式下入口自动改名成 __wrap_*
#include "bsh_client.h"     // 经 control socket 向 procmgr 下单

/* fs_shim.c 的路径展开入口（把 `<name>.BSH_SYMLINK` 表示法展开成真路径）。
 * **弱引用**：qemu 那个 so 只链 exec_shim、不链 fs_shim（见 scripts/build_qemu.sh），
 * 强引用会变成未定义符号、整个 so dlopen 不进来；NULL 时跳过展开即可。 */
extern const char* bsh_fs_resolve_path(const char* path, char* out, size_t outsz)
    __attribute__((weak));

// 单次委托最多带多少个 fd（与 procmgr 侧 cmsg 上限同值，见 bsh_client.h）
#define EXEC_MAX_FDS 16

/* ── 开关 ──────────────────────────────────────────────────────────────
 * 命令 so 没有开关可说：它内部 exec 别的程序只有委托这一条路。
 * guest 侧要开关：本模块被预载进**所有**动态 guest，包括那些本来就不 exec 的程序；
 * 而委托会把进程"换掉"（见上面的语义差别），万一某个程序的 exec 用法我们没覆盖到，
 * 打开它反而添乱。procmgr 在给自己起的 guest 上设这个变量（与 BSH_TTY_STDIO、
 * BSH_FAKE_PTY 同一处）；在宿主/qemu 上手动跑 guest 时不设 → 走原样，便于二分
 * 定位"是不是 shim 干的"。 */
#ifdef BSH_SHIM_WRAP
#define exec_shim_enabled() 1
#else
static int exec_shim_enabled(void) {
    const char* v = getenv("BSH_EXEC_SHIM");
    return v && *v && v[0] != '0';
}
#endif

/* ── 收集本进程"可继承"的 fd ───────────────────────────────────────────
 * 真 exec 会把带 FD_CLOEXEC 的 fd 关掉，委托也该照做。0/1/2 先收（顺序稳定，便于
 * procmgr 侧按原号摆好），其余枚举 /proc/self/fd，跳过目录 fd 自己。 */
static int collect_fds(int* fds, int max) {
    int n = 0;
    for (int v = 0; v <= 2 && n < max; v++) {
        int fl = fcntl(v, F_GETFD);
        if (fl < 0 || (fl & FD_CLOEXEC)) continue;
        fds[n++] = v;
    }
    DIR* d = opendir("/proc/self/fd");
    if (!d) return n;
    int dfd = dirfd(d);
    struct dirent* e;
    while ((e = readdir(d)) != NULL && n < max) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        int v = atoi(e->d_name);
        if (v <= 2 || v == dfd) continue;
        int fl = fcntl(v, F_GETFD);
        if (fl < 0 || (fl & FD_CLOEXEC)) continue;
        fds[n++] = v;
    }
    closedir(d);
    return n;
}

/* ── 模拟"exec 成功时内核替我们做的事"：关掉带 FD_CLOEXEC 的 fd ─────────
 *
 * 为什么非做不可：`subprocess` 判断"孩子已经成功起来了"靠的就是这个 —— 它在 fork 前
 * 建一根 error pipe 并标 CLOEXEC，子进程只有两种下场：出错时往里写错误码，或者
 * exec 成功、由内核把这根 fd 关掉。父进程读它，**读到 EOF 才认为孩子起来了**。
 *
 * 我们的"委托"不是真 exec：那个进程要等目标跑完才退出，于是 CLOEXEC 的 fd 也拖到
 * 那时才关。结果父进程卡在读 error pipe 上，孩子却在等父进程喂 stdin —— 死锁。
 * 实测：`Popen(['cat'], stdin=PIPE)` 直接卡在 Popen 构造里（连接口都没返回）。
 *
 * 所以：委托一成功（目标已经跑起来）就立刻做这一步。
 * 0/1/2 永远不动；不带 CLOEXEC 的也不动（它们本来就该被继承）。
 * 注意调用时机 —— 必须在 fd 已经通过 SCM_RIGHTS 交给 procmgr **之后**，
 * 否则会把该传的 fd 关掉。 */
static void close_cloexec_fds(void) {
    DIR* d = opendir("/proc/self/fd");
    if (!d) return;
    int dfd = dirfd(d);
    struct dirent* e;
    while ((e = readdir(d)) != NULL) {
        int fd = atoi(e->d_name);
        if (fd <= 2 || fd == dfd) continue;
        int fl = fcntl(fd, F_GETFD);
        if (fl < 0 || !(fl & FD_CLOEXEC)) continue;
        close(fd);
    }
    closedir(d);
}

/* ── 委托取证 ──────────────────────────────────────────────────────────
 * 目的：查"为什么 ninja 起 clang 崩、python 起同一个 clang 不崩"。
 * 已在 procmgr 侧确认两边逐字一致（见 ctrl_socket.cpp 的 create-recv 与
 * procmgr.cpp 的 spawn-detail），所以差异只可能在**调用方**，也就是这里 ——
 * 这个进程收集了哪些 fd、把什么 cmd/argv 交出去。
 *
 * ⚠ 写文件而不是 stderr：目标崩溃时 stderr 里的东西常常跟着一起丢（ninja 还用
 * file_actions 把子进程输出接到它自己的管道上，而我们忽略了 file_actions，
 * 那些输出谁也看不到）。落盘才留得住证据。
 * 开关：BSH_EXEC_SHIM_TRACE=1；路径默认 $HOME/execshim.log，可用
 * BSH_EXEC_SHIM_LOG 覆盖。 */
static void tlog(const char *fmt, ...)
{
    const char *on = getenv("BSH_EXEC_SHIM_TRACE");
    if (!on || !*on || on[0] == '0') return;
    char path[512];
    const char *p = getenv("BSH_EXEC_SHIM_LOG");
    if (p && *p) {
        snprintf(path, sizeof path, "%s", p);
    } else {
        const char *home = getenv("HOME");
        snprintf(path, sizeof path, "%s/execshim.log", (home && *home) ? home : "/tmp");
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char buf[2048];
    int n = snprintf(buf, sizeof buf, "[pid %d] ", (int)getpid());
    va_list ap;
    va_start(ap, fmt);
    n += vsnprintf(buf + n, sizeof buf - (size_t)n, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof buf - 2) n = (int)sizeof buf - 2;
    if (n < 0) n = 0;
    buf[n++] = '\n';
    ssize_t w = write(fd, buf, (size_t)n);
    (void)w;
    close(fd);
}

/* 把 fd 列表转成 "[3->/dev/null 4->pipe:[123]]" 这种可读串 */
static void tlog_fds(const char *what, const int *fds, int n)
{
    char s[1024];
    int off = 0;
    off += snprintf(s + off, sizeof s - (size_t)off, "%s: n=%d", what, n);
    for (int i = 0; i < n && off < (int)sizeof s - 80; i++) {
        char tgt[128] = {0};
        char lnk[64];
        snprintf(lnk, sizeof lnk, "/proc/self/fd/%d", fds[i]);
        ssize_t r = readlink(lnk, tgt, sizeof tgt - 1);
        if (r < 0) r = 0;
        tgt[r] = 0;
        int fl = fcntl(fds[i], F_GETFD);
        off += snprintf(s + off, sizeof s - (size_t)off, " %d%s->%s",
                        fds[i], (fl >= 0 && (fl & FD_CLOEXEC)) ? "c" : "", tgt);
    }
    tlog("%s", s);
}

/* ── 公共：委托一次 ─────────────────────────────────────────────────────
 * 成功把子进程退出码写进 *code 并返回 0；失败返回 -1（说明在 bsh_client_last_error()）。
 * 两条路对"失败"的处理不同（一个是 _exit(127)，一个是摆 errno 返回 -1），所以这里
 * 只做公共动作，策略留给调用方。 */
static int spawn_delegated(const char* cmd, char* const argv[],
                           char* const envp[], int* code) {
    /* 目标可能是"用户态软链"（`<name>.BSH_SYMLINK` 表示法，见 fs_shim.c）：
     * 调用方（shell 做 PATH 查找时）有 fs_shim、看得见它，而 **procmgr 没有** ——
     * 它按真路径 stat 会 ENOENT，于是报成 "not found"、shell 再报 126。
     * 实测：npm 的 `node_modules/.bin/*` 全是软链，任何带 install 脚本的包
     * （bufferutil 的 node-gyp-build）都死在这一步。
     * 所以在**调用方进程里**先把路径展开成真路径再交出去 —— 约定只有 fs_shim 那一份实现。
     * 弱引用是必须的：不链 fs_shim 的命令 so（qemu）里这个符号是 NULL，跳过即可，
     * 否则会变成未定义符号、整个 so dlopen 不进来。 */
    char link_buf[4096];
    if (bsh_fs_resolve_path) cmd = bsh_fs_resolve_path(cmd, link_buf, sizeof link_buf);

    /* argv 为空时用目标名兜底：真 execve 允许 argv=NULL（内核当空表），服务端也有一层
     * 兜底，这里先补上，免得 NULL 一路传下去。 */
    char* argv_fallback[2];
    if (!argv || !argv[0]) {
        argv_fallback[0] = (char*)cmd;
        argv_fallback[1] = NULL;
        argv = argv_fallback;
    }
    int fds[EXEC_MAX_FDS];
    int nfds = collect_fds(fds, EXEC_MAX_FDS);

    tlog("delegate: cmd=%s argv0=%s nfds=%d", cmd,
         (argv && argv[0]) ? argv[0] : "(null)", nfds);
    tlog_fds("  collected fds", fds, nfds);

    /* envp 就是 execve 的第三个参数：调用方要**这一份**环境，而不是我们这个进程自己的
     * environ。envp 为 NULL（= execv/execvp）时传 NULL，让客户端用调用方的 environ。
     *
     * 这里是**两段式**（不是一次 bsh_spawnv_sync_…）：
     *   ① 只创建、不等 —— 目标已经开始跑；
     *   ② 关掉自己的 CLOEXEC fd（上面那段解释为什么）；
     *   ③ 再单独等退出码。
     * 用一次性的同步版本会在第 ① 步就阻塞到目标退出，死锁就是这么来的。 */
    int pid = -1;
    if (bsh_spawnv_async_fdmap_env(cmd, (char* const*)argv, envp,
                                   fds, fds, nfds, &pid) != 0) {
        tlog("delegate FAILED: %s (%s)", cmd, bsh_client_last_error());
        return -1;
    }
    tlog("delegate ok: cmd=%s pid=%d", cmd, pid);

    close_cloexec_fds();

    int code_out = -1;
    if (bsh_wait_pid(pid, &code_out) != 0) {
        tlog("wait FAILED: pid=%d (%s)", pid, bsh_client_last_error());
        return -1;
    }
    tlog("wait ok: pid=%d code=%d", pid, code_out);
    *code = code_out;
    return 0;
}

/* ══════════════════════ 命令 so 侧（wrap） ══════════════════════ */
#ifdef BSH_SHIM_WRAP

/* 判定 argv 含 "-cc1"/"-cc1as"（clang driver → 编译器后端/集成汇编器） */
static int argv_has_cc1(char* const argv[]) {
    for (int i = 1; argv && argv[i]; i++)
        if (strcmp(argv[i], "-cc1") == 0 || strcmp(argv[i], "-cc1as") == 0)
            return 1;
    return 0;
}

/* file 是否就是当前进程自身可执行（clang driver 起 cc1 时 file=getMainExecutable，
 * 在鸿蒙 app 进程里 = /proc/self/exe = /system/bin/appspawn）。比只看 argv 更严，
 * 避免把"参数里恰好带 -cc1"的其它命令误判为 clang。
 * ⚠ guest 侧不再走这里：guest 的 /proc/self/exe 由 fs_shim 的 BSH_GUEST_EXE 替身回答，
 *   指向它自己，所以 guest 里的 clang 起 cc1 是**真路径**，不需要这段特判。 */
static int is_self_exe(const char* file) {
    if (!file || !*file) return 0;
    char self[512];
    ssize_t n = readlink("/proc/self/exe", self, sizeof(self) - 1);
    if (n <= 0) return 0;
    self[n] = 0;
    return strcmp(file, self) == 0;
}

/* 这一层**不判断类型** —— "要跑的东西是启动器 / #! 脚本 / ELF / 命令名"是 procmgr 的
 * Resolve() 的事（它拿到路径后按自己的顺序判）。客户端跟着学一遍只会两边不同步：
 * 这个文件被烤进十几个命令 so（mksh/toybox/vim/python/node/zip/dropbear/qemu…），
 * 改一次要重编一圈。所以这里只做**归一**：
 *   - 普通情况：把 file **原样**交出去（绝对路径是路径，裸名是裸名，procmgr 自己按
 *     PATH 找、自己认 #! 与 #BSHSO）；
 *   - 唯一的例外是"起自己"（见 resolve_target 里的注释）。 */

/* 归一"要跑什么"给 procmgr。**只归一，不分类**：类型判断（启动器 / #! 脚本 / ELF /
 * hnp 真 execve / 按 e_machine 分流）全在 procmgr 的 Resolve() 里做，客户端把
 * 文件原样告诉它就够了。
 *
 * 唯一的例外：**"起自己"**。clang 的 driver 会用 /proc/self/exe + -cc1 再起一个自己，
 * 而沙箱里 /proc/self/exe 指向宿主的 appspawn —— procmgr 拿到那条路径不可能知道
 * "这其实是 clang"。所以这里把"自己"翻译成**命令名**交出去（"把要执行的文件和命令
 * 告诉 procmgr"里的"命令"就是这个用法）。这是翻译，不是分类。 */
static void resolve_target(const char* file, char* const argv[],
                           char* out, size_t outsz) {
    out[0] = '\0';
    if (!file || !*file) return;
    if (is_self_exe(file) && argv_has_cc1(argv)) {
        snprintf(out, outsz, "%s", "clang");
        return;
    }
    snprintf(out, outsz, "%s", file);
}

/* 委托一次（**不退出**）：成功把子进程退出码写进 *code 并返回 0；失败返回 errno(>0)。
 *
 * ⚠ 2026-10-03 改：原来这条路上"失败即 _exit(127)"。那对**自己会做 PATH 搜索**的调用方
 * 是致命的 —— CPython 的 subprocess 逐个 execve(PATH[i]/cmd)，靠 ENOENT 继续试下一个；
 * 第一个候选（$HOME/<cmd>，通常并不存在）被 _exit(127) 掉之后，它再也没机会试到
 * $SYSROOT/bin/<cmd>，`pip install` 就崩在 distro 模块的 `uname -rs` 上（实测：
 * `uname -rs` 在 shell 里 rc=0，在 python 的 subprocess 里永远是 127）。
 * 真 execve 本来就该返回 -1；"命令 so 侧没有退路"这条老规矩只对**成功**成立
 * （成功 = 换掉自己，那才是不可返回的语义）。 */
static int delegate_once(const char* file, char* const argv[], char* const envp[]) {
    char cmd[1024];
    resolve_target(file, argv, cmd, sizeof cmd);
    if (!cmd[0]) return ENOENT;

    /* 带 '/' 的路径先看一眼在不在：不存在就直接 ENOENT，不必打扰 procmgr。
     * 为什么必须在**这里**判：procmgr 对"路径不存在"和"存在但不是 ELF"给的是同一句
     * "not executable"，我们只能把它映射成 EACCES —— 而 CPython 的 PATH 搜索对
     * ENOENT 继续、对其余 errno 直接中止（`_posixsubprocess.c` 的 child_exec）。
     * 裸名（无 '/'）**不**做这一步：那是 procmgr 查命令表/PATH 的事，在这里 stat
     * 只会相对 cwd 看一眼，反而把 `execvp("ls")` 这种正确用法误判成不存在。
     * stat 走的是本 so 里的 fs_shim，模拟软链也能正确解析。 */
    if (file && strchr(file, '/')) {
        struct stat st;
        if (stat(file, &st) != 0 && (errno == ENOENT || errno == ENOTDIR))
            return errno;
    }

    int code = 0;
    if (spawn_delegated(cmd, argv, envp, &code) == 0) {
        fflush(NULL);
        _exit(code & 0xFF);           /* 成功：等价于"镜像被换掉了" */
    }

    /* 委托没成。这一行**必须打**：调用方从返回值只能看到一个 errno，真正的原因
     * （control socket 连不上 / 服务端 MSG / fd 传不过去）只在客户端的错误串里。
     * 错误映射与 guest 侧同口径：文案带 "not found" 就算 ENOENT。 */
    const char* err = bsh_client_last_error();
    fprintf(stderr, "%s: cannot exec: %s\n", file ? file : "(null)",
            (err && *err) ? err : "unknown");
    fflush(NULL);
    if (err && (strstr(err, "not found") || strstr(err, "no such"))) return ENOENT;
    return EACCES;
}

/* 供 execve 家族共用：失败返回 -1 并摆好 errno（成功不返回）。 */
static int exec_common(const char* file, char* const argv[], char* const envp[]) {
    errno = delegate_once(file, argv, envp);
    return -1;
}

/* ══════════════════════ guest 侧（LD_PRELOAD） ══════════════════════ */
#else

/* 委托成功就"换掉自己"：把 stdio 刷干净，再用子进程的退出码退出。 */
static void finish_and_exit(int code) {
    fflush(NULL);
    _exit(code & 0xFF);
}

/* 委托一次，成功把退出码写进 *code 并返回 0；失败返回 errno(>0)。
 * 与命令 so 那条路最大的区别：失败要**原样返回 -1 并摆好 errno**，让 guest 能继续跑。 */
static int delegate_exec(const char* file, char* const argv[],
                         char* const envp[], int* code) {
    if (!file || !*file) return ENOENT;

    /* 目标先探一下：不存在要给出**和真 execve 一样**的 errno（guest 里 `./没有这个`
     * 必须报 ENOENT 而不是别的）。这里走 libc 的 stat，会被同一份 shim 里的 fs_shim
     * 接住，于是"指向模拟软链的路径"也能正确解析。
     *
     * 但**只有"确实不存在"才据此下结论**。实测（2026-10-01，cmake→ninja→clang）：
     * 沙箱里 guest 对 `/bin` 整个目录没有 search 权限，`stat("/bin/sh")` 直接给
     * EACCES —— 而 procmgr 恰恰有一条为它准备的规则：**系统 bin 目录下的 basename
     * 命中命令表就按命令起**（`/bin/sh` → libmksh.so，见 procmgr.cpp 步骤 3.5，
     * 它纯按名字判，不碰文件系统）。在这里返回 EACCES，等于把 ninja / make /
     * python 用 `/bin/sh -c <cmd>` 跑命令的能力一刀切掉：症状就是每条命令都
     * `FAILED: [code=127]`、日志里只剩一行 "posix_spawn failed: /bin/sh"。
     * 所以 EACCES/EPERM 这类"看不到"的失败一律往下走，交给 procmgr 判；真目录、
     * 真没权限的，procmgr 会给它自己的答复（"not executable" → EACCES，语义不变）。 */
    struct stat st;
    if (stat(file, &st) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) {
            if (getenv("BSH_EXEC_SHIM_TRACE"))
                fprintf(stderr, "[shim] exec: stat(%s) failed: %s\n",
                        file, strerror(errno));
            return errno;
        }
        if (getenv("BSH_EXEC_SHIM_TRACE"))
            fprintf(stderr, "[shim] exec: stat(%s) failed: %s → 仍交 procmgr 判\n",
                    file, strerror(errno));
    } else if (getenv("BSH_EXEC_SHIM_TRACE")) {
        fprintf(stderr, "[shim] exec: stat(%s) ok mode=%o\n", file,
                (unsigned)st.st_mode);
    }

    /* 先规整成"真实路径"再交出去：/proc/self/exe 这类虚拟路径必须经 fs_shim 换成本体
     * —— procmgr 是在**宿主进程**里解析路径的，它看到的 /proc 是宿主的那个（= appspawn），
     * 把我们看到的字面量直接传下去，它就会起错程序。realpath 走的是本 .so 自己的入口
     * （预载的符号），所以同样吃到替身那一层。裸命令名（无 '/'）不规整，交给 procmgr
     * 查命令表/PATH；realpath 失败（例如指向模拟软链的中间目录不存在）也按原样传。 */
    char real[4096];
    const char* use = file;
    if (strchr(file, '/') && realpath(file, real)) use = real;

    int rc = spawn_delegated(use, argv, envp, code);
    if (rc != 0 && use != file) {
        /* 规整过的路径被拒了 → 回退到调用方原样给的路径再试一次。
         * procmgr 那条"系统 bin 的 basename 命中命令表"是按**字面前缀**判的
         * （`/bin/`、`/usr/bin/`…），realpath 一旦把 `/bin/sh` 展开成别的落点，
         * 规则就再也匹配不上。同一条路还兜住"模拟软链展开后被当成别的东西"的情况。 */
        if (getenv("BSH_EXEC_SHIM_TRACE"))
            fprintf(stderr, "[shim] exec: %s 被拒，回退原字面路径 %s\n", use, file);
        rc = spawn_delegated(file, argv, envp, code);
        use = file;
    }

    if (rc != 0) {
        /* 委托没成：服务端的错误文案里带 "not found" 就报 ENOENT，其余当 EACCES。
         * （和 guest_exec.cpp 那版一个口径；那条路能拿到更精确的 MSG，这里是现成的
         * 客户端 API，只能这样近似。）
         *
         * 这一行**必须打**：调用方从返回值只能看到一个 errno，真正的原因（control
         * socket 连不上 / 服务端 MSG / fd 传不过去）只在客户端的错误串里。没有它，
         * posix_spawn 那条路就是"子进程静默 _exit(127)、日志里一个字都没有" ——
         * 2026-10-01 cmake→ninja→clang 就栽在这种沉默上，查了一整轮。 */
        const char* msg = bsh_client_last_error();
        fprintf(stderr, "[shim] exec delegate failed: %s: %s\n", use,
                (msg && *msg) ? msg : "(no detail)");
        fflush(NULL);
        if (msg && (strstr(msg, "not found") || strstr(msg, "no such"))) return ENOENT;
        return EACCES;
    }
    return 0;
}

/* 供上面几个入口共用：成功不返回，失败返回 -1 并摆好 errno。 */
static int exec_common(const char* file, char* const argv[], char* const envp[]) {
    if (!exec_shim_enabled()) {     /* 没开：让调用方拿 ENOSYS，而不是悄悄不动 */
        errno = ENOSYS;
        return -1;
    }
    int code = 0;
    int err = delegate_exec(file, argv, envp, &code);
    if (err != 0) {
        errno = err;
        return -1;
    }
    finish_and_exit(code);
    return -1;                      /* 不达 */
}

#endif  /* BSH_SHIM_WRAP */

/* ── execl/execlp 的可变参数收集（两条路共用） ───────────────────────── */
static void va_to_argv(const char* arg0, va_list ap, char** argv, int cap) {
    int n = 0;
    argv[n++] = (char*)arg0;
    while (n < cap - 1) {
        char* a = va_arg(ap, char*);
        argv[n++] = a;
        if (!a) break;
    }
    argv[cap - 1] = NULL;
}

/* ── execve 家族 ─────────────────────────────────────────────────────── */
#ifdef BSH_SHIM_WRAP

int BSH_EXPORT(execve)(const char* path, char* const argv[], char* const envp[]) {
    return exec_common(path, argv, envp);
}

int BSH_EXPORT(execv)(const char* path, char* const argv[]) {
    return exec_common(path, argv, NULL);   /* NULL = 用调用方 environ（客户端兜底） */
}

int BSH_EXPORT(execvp)(const char* file, char* const argv[]) {
    return exec_common(file, argv, NULL);
}

int BSH_EXPORT(execvpe)(const char* file, char* const argv[], char* const envp[]) {
    return exec_common(file, argv, envp);
}

int BSH_EXPORT(execl)(const char* path, const char* arg0, ...) {
    char* argv[64];
    va_list ap;
    va_start(ap, arg0);
    va_to_argv(arg0, ap, argv, 64);
    va_end(ap);
    return exec_common(path, argv, NULL);
}

int BSH_EXPORT(execlp)(const char* file, const char* arg0, ...) {
    char* argv[64];
    va_list ap;
    va_start(ap, arg0);
    va_to_argv(arg0, ap, argv, 64);
    va_end(ap);
    return exec_common(file, argv, NULL);
}

#else

int BSH_EXPORT(execve)(const char* path, char* const argv[], char* const envp[]) {
    return exec_common(path, argv, envp);
}

int BSH_EXPORT(execv)(const char* path, char* const argv[]) {
    extern char** environ;
    return exec_common(path, argv, environ);
}

/* execvp/execvpe 的 PATH 查找交给 procmgr 做（它按"命令表优先、再 PATH"解析，
 * 与宿主 shell 的委托同一条路），这里只把 file 原样传下去。 */
int BSH_EXPORT(execvp)(const char* file, char* const argv[]) {
    extern char** environ;
    return exec_common(file, argv, environ);
}

int BSH_EXPORT(execvpe)(const char* file, char* const argv[], char* const envp[]) {
    return exec_common(file, argv, envp);
}

int BSH_EXPORT(execl)(const char* path, const char* arg0, ...) {
    char* argv[64];
    va_list ap;
    va_start(ap, arg0);
    va_to_argv(arg0, ap, argv, 64);
    va_end(ap);
    extern char** environ;
    return exec_common(path, argv, environ);
}

int BSH_EXPORT(execlp)(const char* file, const char* arg0, ...) {
    char* argv[64];
    va_list ap;
    va_start(ap, arg0);
    va_to_argv(arg0, ap, argv, 64);
    va_end(ap);
    extern char** environ;
    return exec_common(file, argv, environ);
}

#endif  /* BSH_SHIM_WRAP */

/* ── posix_spawn ──────────────────────────────────────────────────────
 *
 * 语义是"父立即返回 pid，孙由调用方 waitpid"。真正的孙由 procmgr 创建（父是主进程），
 * 拿不回可 wait 的 pid —— 所以这里自己 fork 一个中间进程"扮演"那个子进程：它委托完
 * 带着退出码退出，调用方 waitpid 拿到的退出码因此是对的。
 * file_actions/attrp 不解释：用它们的程序暂时吃不到那部分语义。 */
static int spawn_via_middle(pid_t* pid, const char* file,
                            char* const argv[], char* const envp[]) {
    pid_t p = fork();
    if (p < 0) return errno;
    if (p == 0) {
#ifdef BSH_SHIM_WRAP
        /* 命令 so 侧：delegate_once 成功就 _exit（不返回），失败才带着 errno 回来。
         * 中间进程只能用退出码表达结果，所以把原因打成一行再 _exit(127)。 */
        int err = delegate_once(file, argv, envp);
        fprintf(stderr, "[shim] posix_spawn failed: %s (errno=%d %s)\n",
                file ? file : "(null)", err, strerror(err));
        fflush(NULL);
        errno = err;
        _exit(127);
#else
        int code = 0;
        int err = delegate_exec(file, argv, envp, &code);
        if (err != 0) {
            /* 这里**只能**_exit(127)（调用方拿到的就是一个退出码），所以至少要留下
             * "是哪个文件、为什么" —— 否则调用方（ninja/make/…）只会报一句
             * `FAILED: [code=127]`，日志里什么都没有（2026-10-01 就是这么栽的）。 */
            fprintf(stderr, "[shim] posix_spawn failed: %s (errno=%d %s)\n",
                    file ? file : "(null)", err, strerror(err));
            fflush(NULL);
            errno = err;
            _exit(127);
        }
        finish_and_exit(code);
#endif
    }
    if (pid) *pid = p;
    return 0;
}

int BSH_EXPORT(posix_spawn)(pid_t* pid, const char* file,
                            const void* file_actions, const void* attrp,
                            char* const argv[], char* const envp[]) {
    (void)file_actions; (void)attrp;
#ifndef BSH_SHIM_WRAP
    if (!exec_shim_enabled()) return ENOSYS;
#endif
    return spawn_via_middle(pid, file, argv, envp);
}

int BSH_EXPORT(posix_spawnp)(pid_t* pid, const char* file,
                             const void* file_actions, const void* attrp,
                             char* const argv[], char* const envp[]) {
    return BSH_EXPORT(posix_spawn)(pid, file, file_actions, attrp, argv, envp);
}

#ifdef BSH_SHIM_WRAP
/* ── 退出码透传：把 guest 的 exit() 换成 fflush + _Exit(code) ──────────────
 *
 * 2026-09-28 加。判别探针实测（自检日志第 6 节）：
 *     sh -c 'exit 7'            → rc=0（期望 7）      sh -c false        → 0
 *     python3 -c 'sys.exit(7)'  → rc=0                python3 os._exit(7) → 7 ✓
 *     toybox false（entry 正常 return）→ rc=1 ✓
 * 也就是「guest 调 libc exit()」这条路上退出码整段丢成 0；直接 _exit() 反而没事。
 *
 * 原因与 elfloader（kElf 那条路）里已经处理过的是同一类：命令 so 跑在 procmgr fork
 * 出来的子进程里，而**宿主主进程在 fork 之前就注册了一堆 atexit**（ArkTS/NAPI 运行时
 * 的收尾）。guest 一调 exit(n)，这些 handler 就跑起来，进程最后以 0 收场，
 * 真正的退出码被丢在中间。
 *
 * 必须先 fflush(NULL) 再 _Exit：直接 _Exit 会丢掉还在 stdio 缓冲里的输出。
 * 这个入口只有命令 so 需要（guest 侧由 elfloader 注入的 exit 桩负责），所以留在
 * BSH_SHIM_WRAP 里。 */
void __wrap_exit(int code)
{
    fflush(NULL);
    _Exit(code & 0xFF);
}
#endif
