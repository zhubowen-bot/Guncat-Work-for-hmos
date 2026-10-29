/*
 * test.c — box64 / elfloader 功能验收（同一份源码 × 8 种 ABI 组合）
 *
 * 每个测试一个 BEGIN..END 块，PASS/FAIL/INFO 计数，任何一项崩了不影响后面继续跑。
 * 退出码 = fail>0 ? 1 : 0（子模式固定 42，见下面 --child）。
 *
 * 组合矩阵（见 scripts/build_testprogs.sh）：
 *   arch     libc    链接      执行者
 *   x86_64   glibc   dynamic   box64
 *   x86_64   glibc   static    box64
 *   x86_64   musl    dynamic   box64
 *   x86_64   musl    static    box64
 *   aarch64  musl    dynamic   elfloader
 *   aarch64  musl    static    elfloader
 *   aarch64  glibc   dynamic   elfloader
 *   aarch64  glibc   static    elfloader
 *
 * 用法：
 *   ./<combo>                跑全套（默认）
 *   ./<combo> --child        子模式：只打印身份、退出 42
 *                            （exec 自己时用它，否则无限递归）
 *
 * 为什么 --child 只打印不跑全套：exec 的验法是"父 fork，子 exec 自己带 --child，
 * 父拿退出码"；子进程再跑一遍全套就自己 exec 自己，递归到天荒地老。
 *
 * 测试的取向：**能测出"哪一类调用在当前执行者下不通"比"全绿"更有用** ——
 * 8 种组合本来就处在不同环境（同一个 guest 里，x86 走 box64 解释、aarch64 走
 * elfloader 进程内装载），所以不少用例只做 INFO 记录（比如 tty / JIT 这类
 * 依赖沙箱的），只有"逻辑上必须成立却不成立"的才记 FAIL。
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* 可选头：不同 libc 版本差异较大，缺了就让对应用例降级成 INFO */
#if defined(__has_include)
#  if __has_include(<sys/auxv.h>)
#    include <sys/auxv.h>
#    define HAVE_AUXV 1
#  endif
#  if __has_include(<sys/random.h>)
#    include <sys/random.h>
#    define HAVE_GETRANDOM 1
#  endif
#  if __has_include(<sys/ioctl.h>)
#    include <sys/ioctl.h>
#    define HAVE_IOCTL 1
#  endif
#  if __has_include(<termios.h>)
#    include <termios.h>
#    define HAVE_TERMIOS 1
#  endif
#  if __has_include(<sys/mman.h>)
#    include <sys/mman.h>
#    define HAVE_MMAN 1
#  endif
#  if __has_include(<sys/resource.h>)
#    include <sys/resource.h>
#    define HAVE_RLIMIT 1
#  endif
#endif

static int g_total = 0, g_pass = 0, g_fail = 0, g_skip = 0;

#define BEGIN(name) do { g_total++; \
    printf("\n┌─[ %s ]\n", name); fflush(stdout); } while(0)
#define PASS(...)   do { g_pass++; \
    printf("│  [PASS] "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define FAIL(...)   do { g_fail++; \
    printf("│  [FAIL] "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define SKIP(...)   do { g_skip++; \
    printf("│  [SKIP] "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define INFO(...)   do { \
    printf("│  [INFO] "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define NOTE(...)   do { INFO(__VA_ARGS__); } while(0)   /* 只补充说明，不判分 */
#define END()       do { printf("└─\n"); fflush(stdout); } while(0)

/* 由构建脚本传入（见 scripts/build_testprogs.sh）：本次编出来的是哪一种组合。
 * __x86_64__ / __GLIBC__ 这类内建宏只能判出 arch 与 libc，判不出静态还是动态，
 * 所以"静态/动态"这一维由脚本显式给，运行时直接打出来便于八份输出互相对照。 */
#ifndef BSH_TEST_COMBO
#define BSH_TEST_COMBO "unknown（未由构建脚本传入 -DBSH_TEST_COMBO）"
#endif
/* 静态链接的组合：dlopen 在"完全静态"的 glibc/musl 上本来就不支持，
 * 那一条失败不算 bug（脚本按链接方式传进来）。 */
#ifndef BSH_TEST_STATIC
#define BSH_TEST_STATIC 0
#endif

/* 本程序自己的路径与所在目录：exec/dlopen 那几组要用它拼兄弟文件路径
 * （<dir>/dlhost-<combo>、<dir>/libtgreet-<combo>.so）。 */
static char g_dir[PATH_MAX] = ".";
static char g_self[PATH_MAX] = "";

static void init_self_paths(const char *argv0) {
    if (argv0 && argv0[0]) {
        if (realpath(argv0, g_self) == NULL) {   /* /proc 上可能没有,退化成原样 */
            snprintf(g_self, sizeof g_self, "%s", argv0);
        }
    }
    char *slash = strrchr(g_self, '/');
    if (slash && slash != g_self) {
        size_t n = (size_t)(slash - g_self);
        if (n < sizeof g_dir) { memcpy(g_dir, g_self, n); g_dir[n] = 0; }
    } else if (slash == g_self) {
        snprintf(g_dir, sizeof g_dir, "/");
    } else {
        /* 裸名字（PATH 命中）：用 cwd，autorun 里都是绝对路径，走不到这里 */
        if (getcwd(g_dir, sizeof g_dir) == NULL) snprintf(g_dir, sizeof g_dir, ".");
        snprintf(g_self, sizeof g_self, "%s/%s", g_dir, argv0 ? argv0 : "?");
    }
}

/* 拼一个兄弟文件路径：sibling(buf, n, "dlhost-%s", combo) → "<dir>/dlhost-<combo>" */
static const char *sibling(char *buf, size_t n, const char *fmt, ...) {
    int k = snprintf(buf, n, "%s/", g_dir);
    if (k < 0 || (size_t)k >= n) return buf;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf + k, n - (size_t)k, fmt, ap);
    va_end(ap);
    return buf;
}

/* ---------------- tests: 基础 ---------------- */

static void t_stdio(void) {
    BEGIN("stdio");
    printf("│  hello via printf\n");
    fputs("│  hello via fputs(stdout)\n", stdout);
    fputs("│  hello via fputs(stderr)\n", stderr);
    PASS("stdout/stderr 都能写");
    END();
}

static void t_args(int argc, char **argv) {
    BEGIN("argv");
    INFO("argc=%d", argc);
    for (int i = 0; i < argc; i++) INFO("argv[%d]=%s", i, argv[i]);
    INFO("/proc/self/exe → %s", g_self);
    PASS("argv 解析");
    END();
}

static void t_env(void) {
    BEGIN("env");
    const char *p = getenv("PATH"), *h = getenv("HOME");
    INFO("PATH=%s", p ? p : "(unset)");
    INFO("HOME=%s", h ? h : "(unset)");
    INFO("LD_LIBRARY_PATH=%s", getenv("LD_LIBRARY_PATH") ? getenv("LD_LIBRARY_PATH") : "(unset)");
    /* LD_PRELOAD 是 guest 侧 shim（tty/软链模拟）的载体，procmgr 会按 PT_INTERP 挑
     * 对应 libc 那份塞进来。它到底有没有到、到的是哪份，是排查 shim 不生效的第一现场。 */
    INFO("LD_PRELOAD=%s", getenv("LD_PRELOAD") ? getenv("LD_PRELOAD") : "(unset)");
    INFO("BSH_TTY_STDIO=%s", getenv("BSH_TTY_STDIO") ? getenv("BSH_TTY_STDIO") : "(unset)");
    INFO("GLIBC_TUNABLES=%s", getenv("GLIBC_TUNABLES") ? getenv("GLIBC_TUNABLES") : "(unset)");
    PASS("getenv");
    END();
}

static void t_uname(void) {
    BEGIN("uname");
    struct utsname u;
    if (uname(&u) != 0) { FAIL("uname: %s", strerror(errno)); END(); return; }
    INFO("sysname  = %s", u.sysname);
    INFO("nodename = %s", u.nodename);
    INFO("release  = %s", u.release);
    INFO("version  = %s", u.version);
    INFO("machine  = %s", u.machine);
    PASS("uname");
    END();
}

static void t_ids(void) {
    BEGIN("pid/uid");
    INFO("pid=%d ppid=%d uid=%d gid=%d",
         (int)getpid(), (int)getppid(), (int)getuid(), (int)getgid());
    PASS("身份系列调用");
    END();
}

static void t_time(void) {
    BEGIN("time");
    INFO("time()  = %ld", (long)time(NULL));
    struct timeval tv; gettimeofday(&tv, NULL);
    INFO("gtod    = %ld.%06ld", (long)tv.tv_sec, (long)tv.tv_usec);
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    INFO("MONO    = %ld.%09ld", (long)ts.tv_sec, (long)ts.tv_nsec);
    clock_gettime(CLOCK_REALTIME, &ts);
    INFO("REAL    = %ld.%09ld", (long)ts.tv_sec, (long)ts.tv_nsec);
    PASS("time/gettimeofday/clock_gettime");
    END();
}

static void t_malloc(void) {
    BEGIN("malloc");
    void *p1 = malloc(64), *p2 = malloc(4096), *p3 = malloc(1 << 20);
    if (!p1 || !p2 || !p3) { FAIL("malloc NULL"); END(); return; }
    INFO("64=%p 4K=%p 1M=%p", p1, p2, p3);
    memset(p1, 0xab, 64);
    memset(p2, 0xcd, 4096);
    memset(p3, 0xef, 1 << 20);
    if (((unsigned char*)p3)[(1<<20)-1] != 0xef) {
        FAIL("内容校验失败"); free(p1); free(p2); free(p3); END(); return;
    }
    free(p1); free(p2); free(p3);

    char *s = malloc(16); strcpy(s, "abc");
    s = realloc(s, 1024);
    if (strcmp(s, "abc") != 0) { FAIL("realloc 丢内容"); free(s); END(); return; }
    free(s);
    PASS("malloc/free/realloc");
    END();
}

static void t_str(void) {
    BEGIN("string");
    char buf[64];
    strcpy(buf, "hello"); strcat(buf, ", world");
    INFO("strcpy/cat: %s", buf);
    int n = snprintf(buf, sizeof(buf), "n=%d s=%s f=%.2f", 42, "abc", 3.14);
    INFO("snprintf %d: %s", n, buf);
    if (!strstr(buf, "abc")) { FAIL("strstr"); END(); return; }
    PASS("字符串系列");
    END();
}

static void t_math(void) {
    BEGIN("libm");
    INFO("sqrt(2)    = %.10f", sqrt(2.0));
    INFO("sin(π/2)   = %.10f", sin(M_PI/2));
    INFO("exp(1)     = %.10f", exp(1.0));
    INFO("log(e)     = %.10f", log(M_E));
    INFO("pow(2,10)  = %.10f", pow(2.0, 10.0));
    if (fabs(sqrt(2.0) - 1.41421356) > 1e-6) { FAIL("sqrt(2)"); END(); return; }
    PASS("libm 基础函数");
    END();
}

static void t_fpu(void) {
    BEGIN("fpu");
    double s = 0;
    for (int i = 1; i <= 1000; i++) s += 1.0 / (double)i;
    INFO("Σ(1/i) double = %.10f", s);
    float fs = 0;
    for (int i = 1; i <= 1000; i++) fs += 1.0f / (float)i;
    INFO("Σ(1/i) float  = %.6f", fs);
    if (fabs(s - 7.4854708606) > 1e-6) { FAIL("double 不准"); END(); return; }
    PASS("FPU 浮点");
    END();
}

static void t_sysconf(void) {
    BEGIN("sysconf/rlimit");
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN), pg = sysconf(_SC_PAGESIZE);
    INFO("nprocessors_onln=%ld pagesize=%ld getpagesize=%d", ncpu, pg, getpagesize());
    long of = -1;
#ifdef HAVE_RLIMIT
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        of = (long)rl.rlim_cur;
        INFO("RLIMIT_NOFILE cur=%ld max=%ld", (long)rl.rlim_cur, (long)rl.rlim_max);
    } else {
        INFO("getrlimit(NOFILE) 失败: %s", strerror(errno));
    }
#else
    of = sysconf(_SC_OPEN_MAX);
    INFO("OPEN_MAX=%ld（无 sys/resource.h，走 sysconf）", of);
#endif
    INFO("fd 上限（两处取到的值应当一致）= %ld", of);
    if (pg <= 0) { FAIL("pagesize 不合理"); END(); return; }
    PASS("sysconf/getrlimit");
    END();
}

/* ---------------- tests: 文件与目录 ---------------- */

static void t_file(void) {
    BEGIN("file_io");
    const char *path = "test_tmp.txt";
    const char *want = "hello from guest\n第二行 utf-8\n";
    FILE *f = fopen(path, "w");
    if (!f) { FAIL("fopen w: %s", strerror(errno)); END(); return; }
    fwrite(want, 1, strlen(want), f); fclose(f);

    struct stat st;
    if (stat(path, &st) != 0) { FAIL("stat"); END(); return; }
    INFO("size=%ld", (long)st.st_size);

    f = fopen(path, "r");
    char buf[256] = {0};
    size_t r = fread(buf, 1, sizeof(buf)-1, f); fclose(f);
    INFO("read %zu", r);

    if (strcmp(buf, want) != 0) {
        FAIL("内容不一致"); INFO("got: %s", buf);
        unlink(path); END(); return;
    }
    unlink(path);
    PASS("fopen/fwrite/stat/fread/unlink");
    END();
}

static void t_fs(void) {
    BEGIN("fs: mkdir/chdir/rename/readdir/rmdir");
    char base[PATH_MAX], sub[PATH_MAX], old[PATH_MAX];
    if (getcwd(old, sizeof old) == NULL) { FAIL("getcwd: %s", strerror(errno)); END(); return; }
    snprintf(base, sizeof base, "%s/zzfs", g_dir);
    snprintf(sub,  sizeof sub,  "%s/zzfs/sub", g_dir);

    if (mkdir(base, 0755) != 0 && errno != EEXIST) { FAIL("mkdir: %s", strerror(errno)); END(); return; }
    if (mkdir(sub, 0755) != 0 && errno != EEXIST)  { FAIL("mkdir sub: %s", strerror(errno)); END(); return; }
    INFO("mkdir %s ok", base);

    if (chdir(sub) != 0) { FAIL("chdir: %s", strerror(errno)); END(); return; }
    char now[PATH_MAX];
    if (getcwd(now, sizeof now) == NULL) { FAIL("getcwd(2): %s", strerror(errno)); END(); return; }
    INFO("cwd 现在 = %s", now);

    FILE *f = fopen("a.txt", "w");
    if (!f) { FAIL("fopen in cwd: %s", strerror(errno)); chdir(old); END(); return; }
    fputs("xyz", f); fclose(f);

    if (rename("a.txt", "b.txt") != 0) { FAIL("rename: %s", strerror(errno)); chdir(old); END(); return; }
    int seen = 0;
    DIR *d = opendir(".");
    if (!d) { FAIL("opendir: %s", strerror(errno)); chdir(old); END(); return; }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) if (strcmp(e->d_name, "b.txt") == 0) seen = 1;
    closedir(d);
    if (!seen) { FAIL("readdir 没看到 b.txt"); chdir(old); END(); return; }
    INFO("rename + readdir ok");

    unlink("b.txt");
    chdir(old);
    rmdir(sub); rmdir(base);
    PASS("mkdir/chdir/getcwd/rename/readdir/rmdir");
    END();
}

/* 符号链接 / 硬链接。
 *
 * 判据就是"能不能创建出来" —— 沙箱若拒绝，这一项就该记 FAIL：那是**能力缺口**，
 * 不是"环境差异"。第一版把它记成了 INFO + PASS("调用已发出")，等于用一句"我发过
 * 这个调用"换了个绿点，正是要避免的自欺。
 * 失败时额外确认一次"链接到底有没有被建出来"（lstat），免得把"报错了但其实建了"
 * 或"报错了也确实没建"混在一起。 */
static void t_symlink(void) {
    BEGIN("symlink / hardlink");
    /* 变量名别叫 link —— 那是 <unistd.h> 里的函数，会把下面的 link() 调用遮住 */
    char slink[PATH_MAX], hard[PATH_MAX], target[PATH_MAX];
    snprintf(slink,  sizeof slink,  "%s/zzlink", g_dir);
    snprintf(hard,   sizeof hard,   "%s/zzhard", g_dir);
    snprintf(target, sizeof target, "%s/zztarget", g_dir);

    unlink(slink);
    unlink(hard);
    FILE *f = fopen(target, "w");
    if (!f) { FAIL("建目标文件: %s", strerror(errno)); END(); return; }
    fputs("through-link", f); fclose(f);

    /* ── 符号链接 ── */
    int sym_ok = (symlink(target, slink) == 0);
    if (!sym_ok) {
        struct stat probe;
        int exists = (lstat(slink, &probe) == 0);
        INFO("symlink(%s -> %s) 失败: %s", slink, target, strerror(errno));
        INFO("lstat 复核：链接%s建出来", exists ? "**居然**被" : "确实没有被");
        FAIL("创建符号链接被沙箱拒绝（能力缺口，见上一行的 errno）");
    } else {
        struct stat lst;
        int ok = 1;
        if (lstat(slink, &lst) != 0)         { FAIL("lstat: %s", strerror(errno)); ok = 0; }
        else if (!S_ISLNK(lst.st_mode))      { FAIL("lstat 说它不是符号链接"); ok = 0; }
        else INFO("lstat: 是符号链接（mode=%o）", (unsigned)lst.st_mode & 07777);

        char got[PATH_MAX] = {0};
        ssize_t n = readlink(slink, got, sizeof got - 1);
        if (n <= 0) { FAIL("readlink: %s", strerror(errno)); ok = 0; }
        else INFO("readlink → %s", got);

        struct stat st;
        if (stat(slink, &st) != 0) { FAIL("stat(跟随链接): %s", strerror(errno)); ok = 0; }
        else {
            FILE *g = fopen(slink, "r");
            char buf[64] = {0};
            if (g) { if (fread(buf, 1, sizeof buf - 1, g) > 0) INFO("经链接读到: %s", buf); fclose(g); }
            if (strcmp(buf, "through-link") != 0) { FAIL("经链接读到的内容不对: '%s'", buf); ok = 0; }
        }
        if (ok) PASS("symlink/lstat/readlink/stat 全部正确");
    }

    /* ── 硬链接（同一道闸：tar 解包时的 "can't link xxx -> xxx Permission denied"）── */
    if (link(target, hard) != 0) {
        INFO("link(%s -> %s) 失败: %s", target, hard, strerror(errno));
        FAIL("创建硬链接被沙箱拒绝（能力缺口）");
    } else {
        struct stat st1, st2;
        if (stat(target, &st1) == 0 && stat(hard, &st2) == 0 && st1.st_ino == st2.st_ino)
            PASS("硬链接：同一个 inode");
        else
            FAIL("硬链接建出来了但 inode 不同（怎么做到的？）");
        unlink(hard);
    }

    if (sym_ok) unlink(slink);
    unlink(target);
    END();
}

static void t_getrandom(void) {
    BEGIN("getrandom");
#ifdef HAVE_GETRANDOM
    unsigned char b[16] = {0};
    ssize_t n = getrandom(b, sizeof b, 0);
    if (n < 0) {
        NOTE("getrandom 失败: %s（沙箱可能拦，不计分）", strerror(errno));
        END(); return;
    }
    INFO("拿到 %zd 字节: %02x%02x%02x%02x…", n, b[0], b[1], b[2], b[3]);
    PASS("getrandom");
#else
    SKIP("没有 <sys/random.h>");
#endif
    END();
}

static void t_socketpair(void) {
    BEGIN("socketpair(AF_UNIX)");
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        SKIP("socketpair 建不出来: %s（本项没验成）", strerror(errno));
        END(); return;
    }
    const char *msg = "ping";
    char buf[16] = {0};
    if (write(sv[0], msg, 4) != 4) { FAIL("write: %s", strerror(errno)); close(sv[0]); close(sv[1]); END(); return; }
    ssize_t r = read(sv[1], buf, sizeof buf - 1);
    close(sv[0]); close(sv[1]);
    if (r == 4 && strcmp(buf, msg) == 0) PASS("socketpair 读写往返");
    else                                 FAIL("socketpair 读回 %zd 字节 '%s'", r, buf);
    END();
}

/* ---------------- tests: 进程 ---------------- */

static volatile sig_atomic_t g_sig = 0;
static void on_sig_handler(int s) { g_sig = s; }

static void t_signal(void) {
    BEGIN("signal");
    struct sigaction sa = {0};
    sa.sa_handler = on_sig_handler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGUSR1, &sa, NULL) != 0) { FAIL("sigaction: %s", strerror(errno)); END(); return; }
    kill(getpid(), SIGUSR1);
    for (int i = 0; i < 200 && g_sig == 0; i++) usleep(1000);
    if (g_sig != SIGUSR1) { FAIL("信号未送达"); END(); return; }
    INFO("got signal %d (%s)", g_sig, strsignal(g_sig));
    PASS("sigaction + kill + handler");
    END();
}

struct targ { int id; int64_t sum; };
static void *worker(void *p) {
    struct targ *a = p; int64_t s = 0;
    for (int64_t i = 0; i < 100000; i++) s += i;
    a->sum = s; return NULL;
}

static void t_pthread(void) {
    BEGIN("pthread");
    enum { N = 4 };
    pthread_t th[N]; struct targ a[N];
    for (int i = 0; i < N; i++) {
        a[i].id = i; a[i].sum = -1;
        if (pthread_create(&th[i], NULL, worker, &a[i]) != 0) {
            FAIL("pthread_create %d: %s", i, strerror(errno)); END(); return;
        }
    }
    INFO("created %d threads", N);
    for (int i = 0; i < N; i++) {
        pthread_join(th[i], NULL);
        if (a[i].sum != INT64_C(4999950000)) { FAIL("th %d 计算错", i); END(); return; }
    }
    INFO("每个线程 Σ0..99999 = %" PRId64, a[0].sum);
    PASS("pthread create/join");
    END();
}

static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;
static long g_cnt = 0;
static void *incr(void *_) { (void)_;
    for (int i = 0; i < 50000; i++) {
        pthread_mutex_lock(&g_mtx); g_cnt++; pthread_mutex_unlock(&g_mtx);
    }
    return NULL;
}

static void t_mutex(void) {
    BEGIN("pthread_mutex");
    enum { N = 4 };
    pthread_t th[N]; g_cnt = 0;
    for (int i = 0; i < N; i++) pthread_create(&th[i], NULL, incr, NULL);
    for (int i = 0; i < N; i++) pthread_join(th[i], NULL);
    INFO("cnt=%ld 期望=%d", g_cnt, N * 50000);
    if (g_cnt == (long)N * 50000) PASS("mutex 正确序列化");
    else                          FAIL("mutex race");
    END();
}

/* fork + pipe：子进程写、退出码 33，父进程读回并 waitpid 校验 */
static void t_fork_pipe(void) {
    BEGIN("fork + pipe + waitpid");
    int p[2];
    if (pipe(p) != 0) { FAIL("pipe: %s", strerror(errno)); END(); return; }
    pid_t pid = fork();
    if (pid < 0) { FAIL("fork: %s", strerror(errno)); close(p[0]); close(p[1]); END(); return; }
    if (pid == 0) {
        close(p[0]);
        const char *m = "child-wrote-this";
        ssize_t w = write(p[1], m, strlen(m));
        close(p[1]);
        _exit(w == (ssize_t)strlen(m) ? 33 : 34);
    }
    close(p[1]);
    char buf[64] = {0};
    ssize_t r = read(p[0], buf, sizeof buf - 1);
    close(p[0]);
    int st = 0;
    if (waitpid(pid, &st, 0) != pid) { FAIL("waitpid: %s", strerror(errno)); END(); return; }
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    INFO("子进程 pid=%d 退出码=%d，管道收到 %zd 字节 '%s'", (int)pid, code, r, buf);
    if (code == 33 && strcmp(buf, "child-wrote-this") == 0) PASS("fork/pipe/waitpid 全通");
    else                                                    FAIL("子进程退出码或管道内容不对");
    END();
}

/* MAP_SHARED|ANON + fork：子进程写、父进程要看得见（跨进程共享映射） */
static void t_shmem_fork(void) {
    BEGIN("mmap(MAP_SHARED|ANON) + fork");
#ifdef HAVE_MMAN
    int *sh = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (sh == MAP_FAILED) {
        SKIP("mmap(MAP_SHARED|ANON) 建不出来: %s（本项没验成）", strerror(errno));
        END(); return;
    }
    *sh = 111;
    pid_t pid = fork();
    if (pid < 0) { FAIL("fork: %s", strerror(errno)); munmap(sh, 4096); END(); return; }
    if (pid == 0) { *sh = 222; _exit(0); }
    int st = 0;
    waitpid(pid, &st, 0);
    INFO("父进程看到 *sh=%d（期望 222）", *sh);
    if (*sh == 222) PASS("共享匿名映射跨 fork 可见");
    else            FAIL("共享映射没被子进程改动可见");
    munmap(sh, 4096);
#else
    NOTE("没有 <sys/mman.h>，跳过");
#endif
    END();
}

/* ---------------- tests: 加载器 / 动态链接 ---------------- */

/* readlink /proc/self/exe；顺带把 $ORIGIN 类的自省信息打出来 */
static void t_proc_self(void) {
    BEGIN("/proc/self");
    char exe[PATH_MAX] = {0};
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n > 0) INFO("/proc/self/exe → %s", exe);
    else       INFO("readlink(/proc/self/exe) 失败: %s", strerror(errno));

    FILE *f = fopen("/proc/self/status", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof line, f)) {
            if (!strncmp(line, "Seccomp:", 8) || !strncmp(line, "NoNewPrivs:", 11)) {
                line[strcspn(line, "\n")] = 0;
                INFO("%s", line);
            }
        }
        fclose(f);
    } else {
        INFO("读不到 /proc/self/status: %s", strerror(errno));
    }
    PASS("/proc 自省");
    END();
}

/* auxv：我们的执行者是自己把 ELF 装进内存再跳的，AT_PHDR/AT_BASE/AT_ENTRY/
 * AT_EXECFN 必须自己造（elfloader 里 push_auxv 那段），这里正好验一遍。
 *
 * 判据是**自洽性**，不是"值该等于多少"：AT_PAGESZ 必须等于本进程的页大小、
 * AT_PHDR 与 AT_ENTRY 必须非 0。这三条在任何正确起进程的地方都成立（内核、qemu、
 * 我们的 elfloader），所以不需要知道自己在哪种执行者下 —— 值本身照原样打出来，
 * 谁要更细的比对（比如 AT_BASE 是不是我们装载解释器的基址）自己看。
 * 顺序：先打值、再判自洽，判完把结论写清楚。 */
static void t_auxv(void) {
    BEGIN("auxv");
#ifdef HAVE_AUXV
    unsigned long phdr = getauxval(AT_PHDR), base = getauxval(AT_BASE);
    unsigned long entry = getauxval(AT_ENTRY), page = getauxval(AT_PAGESZ);
    unsigned long execfn = getauxval(AT_EXECFN);
    INFO("AT_PAGESZ = %lu（本进程 getpagesize()=%d）", page, getpagesize());
    INFO("AT_PHDR   = 0x%lx", phdr);
    INFO("AT_BASE   = 0x%lx（解释器装载基址）", base);
    INFO("AT_ENTRY  = 0x%lx", entry);
    if (execfn) INFO("AT_EXECFN = %s", (const char *)execfn);
    else        INFO("AT_EXECFN = (空)");
    if (page == (unsigned long)getpagesize() && phdr && entry)
        PASS("auxv 自洽：页大小对得上、PHDR/ENTRY 非 0");
    else
        FAIL("auxv 不自洽：PAGESZ=%lu getpagesize=%d PHDR=0x%lx ENTRY=0x%lx",
             page, getpagesize(), phdr, entry);
#else
    SKIP("没有 <sys/auxv.h>");
#endif
    END();
}

/* 匿名可执行内存（JIT）：匿名页写机器码 → mprotect 成 r-x → 跳进去执行。
 *
 * 判据全是"能不能做到"，与自己在哪儿执行无关：
 *   mmap 匿名页 → 写 → mprotect(RX) → 调用，返回 42 就算过。
 * 唯一需要小心的是**跳进去那一下可能把进程打死**（某些执行者不允许执行刚写的内存，
 * 不是返回错误而是直接崩）。所以把它放进 **fork 出来的子进程**里做，父进程只看
 * 子进程的下场：正常退出 42 = 能；被信号打死 = 不能（把信号号打出来）。这样既不用
 * 猜环境，也不会因为一个用例崩掉就丢掉后面所有用例的结论。 */
static void t_jit(void) {
    BEGIN("jit: anon mmap → 写机器码 → mprotect(RX) → 调用");
#if defined(HAVE_MMAN) && (defined(__aarch64__) || defined(__x86_64__))
#  if defined(__aarch64__)
    static const unsigned int code[] = { 0x52800540u /* mov w0,#42 */,
                                         0xD65F03C0u /* ret        */ };
#  else
    static const unsigned char code[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, /* mov eax,42 */
                                          0xC3 };                       /* ret        */
#  endif
    unsigned char *mem = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) {
        FAIL("匿名 mmap 失败: %s（拿不到可写页，后面所有 JIT 都无从谈起）", strerror(errno));
        END(); return;
    }
    memcpy(mem, code, sizeof code);
    INFO("已把 %zu 字节机器码写进匿名页 %p", sizeof code, (void *)mem);

    if (mprotect(mem, 4096, PROT_READ | PROT_EXEC) != 0) {
        INFO("mprotect(RW→RX) 失败: %s", strerror(errno));
        munmap(mem, 4096);
        FAIL("拿不到匿名可执行内存 → 这个执行者跑不了 JIT（V8/qemu-TCG 之类都要它）");
        END(); return;
    }
    INFO("mprotect(RW→RX) 成功");

    pid_t pid = fork();
    if (pid < 0) {
        FAIL("fork: %s", strerror(errno));
    } else if (pid == 0) {
        int (*fn)(void) = (int (*)(void))(void *)mem;
        _exit(fn() == 42 ? 42 : 43);      /* 42=调用成功；43=返回值不对 */
    } else {
        int st = 0;
        if (waitpid(pid, &st, 0) != pid) {
            FAIL("waitpid: %s", strerror(errno));
        } else if (WIFSIGNALED(st)) {
            FAIL("跳进新写的代码被信号 %d (%s) 打死 → 这个执行者不能执行刚写入的内存",
                 WTERMSIG(st), strsignal(WTERMSIG(st)));
        } else if (WEXITSTATUS(st) == 42) {
            PASS("匿名可执行内存可写可调用（JIT 可用）");
        } else {
            FAIL("调出来的返回值不对（子进程退出码 %d）", WEXITSTATUS(st));
        }
    }
    munmap(mem, 4096);
#else
    SKIP("该平台/头文件不支持");
#endif
    END();
}

/* dlopen + dlsym：库是同组合编出来的兄弟文件 libtgreet-<combo>.so */
static void t_dlopen(void) {
    BEGIN("dlopen + dlsym");
    char lib[PATH_MAX];
    sibling(lib, sizeof lib, "libtgreet-" BSH_TEST_COMBO ".so");

    struct stat st;
    if (stat(lib, &st) != 0) {
        SKIP("%s 不在（tar 没解全？）: %s", lib, strerror(errno));
        END(); return;
    }
    void *h = dlopen(lib, RTLD_NOW);
    if (!h) {
        const char *e = dlerror();
        if (BSH_TEST_STATIC) {
            /* 完全静态链接的程序本来就没有动态加载器（glibc 能勉强 dlopen 一部分，
             * musl 不行）—— 那是 libc 的设计，不是我们的能力缺口 */
            SKIP("本组合是静态链接：%s", e ? e : "?");
        } else {
            FAIL("dlopen(%s): %s", lib, e ? e : "?");
        }
        END(); return;
    }
    INFO("dlopen 成功，句柄=%p", h);
    int (*greet)(const char *) = (int (*)(const char *))dlsym(h, "greet");
    if (!greet) { FAIL("dlsym(greet): %s", dlerror()); dlclose(h); END(); return; }
    int r = greet("guest");
    INFO("greet(\"guest\") → %d（期望 42）", r);
    void *yes = dlsym(h, "tgreet_yes");   /* 顺带验一个数据符号 */
    INFO("dlsym(\"tgreet_yes\") → %p", yes);
    if (r == 42) PASS("dlopen + dlsym(函数) + 调用");
    else         FAIL("greet 返回值不对");
    dlclose(h);
    END();
}

/* exec 一个"动态链接了 .so"的 ELF：兄弟文件 dlhost-<combo>（DT_NEEDED 指向
 * libtgreet-<combo>.so），靠 LD_LIBRARY_PATH 指到本目录让它找得到库。 */
static void t_exec_dyn_with_so(void) {
    BEGIN("exec 一个依赖 .so 的动态 ELF");
    char host[PATH_MAX];
    sibling(host, sizeof host, "dlhost-" BSH_TEST_COMBO);
    struct stat st;
    if (stat(host, &st) != 0) {
        SKIP("%s 不在: %s", host, strerror(errno));
        END(); return;
    }

    pid_t pid = fork();
    if (pid < 0) { FAIL("fork: %s", strerror(errno)); END(); return; }
    if (pid == 0) {
        /* 子进程：把库目录塞进 LD_LIBRARY_PATH 再 exec（父进程的环境不动） */
        char ld[PATH_MAX * 2];
        const char *old = getenv("LD_LIBRARY_PATH");
        snprintf(ld, sizeof ld, "%s%s%s", g_dir, (old && *old) ? ":" : "", (old && *old) ? old : "");
        setenv("LD_LIBRARY_PATH", ld, 1);
        char *const av[] = { host, NULL };
        execv(host, av);
        INFO("execv(%s) 返回了，errno=%d (%s)", host, errno, strerror(errno));
        _exit(126);
    }
    int st2 = 0;
    if (waitpid(pid, &st2, 0) != pid) { FAIL("waitpid: %s", strerror(errno)); END(); return; }
    int code = WIFEXITED(st2) ? WEXITSTATUS(st2) : -1;
    INFO("子进程 %s 退出码=%d（期望 42 = dlhost 里 greet() 的返回值）", host, code);
    if (code == 42) PASS("exec 动态 ELF + 由它自己加载 .so 全通");
    else            FAIL("exec 依赖 .so 的 ELF 失败（退出码 %d；126=execv 返回了）", code);
    END();
}

/* exec 自己：父 fork，子进程 exec 自己带 --child（子模式只打印并退出 42）。
 * 这条同时是"进程创建 + 参数传递 + 退出码回收"的端到端验证。 */
static void t_exec_self(void) {
    BEGIN("fork + exec 自己(--child)");
    pid_t pid = fork();
    if (pid < 0) { FAIL("fork: %s", strerror(errno)); END(); return; }
    if (pid == 0) {
        char *const av[] = { g_self, (char *)"--child", NULL };
        execv(g_self, av);
        INFO("execv(自己) 返回了，errno=%d (%s)", errno, strerror(errno));
        _exit(125);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) != pid) { FAIL("waitpid: %s", strerror(errno)); END(); return; }
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    INFO("子进程退出码=%d（期望 42；125=execv 返回了）", code);
    if (code == 42) PASS("exec 自己跑通（--child 正常）");
    else            FAIL("exec 自己失败：退出码 %d", code);
    END();
}

/* 直连 exec（不 fork）：只在**主进程最后**跑 —— 一旦成功当前镜像就被换掉，
 * 后面的测试不会再执行。失败时 execve 会返回并把 errno 打出来，正是我们要的信息。
 * 这里故意不带 --child 之外的东西：带上 --child 就是"换成子模式的自己"，不会递归。 */
static void t_exec_self_inplace(void) {
    BEGIN("直接 exec 自己（替换当前镜像，--child）");
    char *const av[] = { g_self, (char *)"--child", NULL };
    execv(g_self, av);
    INFO("execv(%s) 返回了，errno=%d (%s)", g_self, errno, strerror(errno));
    NOTE("→ 当前执行者下「直接换镜像」这条路不通；换进程只能用 fork(+委托)，见上面的用例");
    PASS("已探测（结果见 errno）");
    END();
}

/* exec 一个**同目录的兄弟程序**：挑"另一种链接方式"的那只 —— 本组合是 static 就挑
 * dynamic，反之挑 static。
 *
 * 为什么不是固定挑 static：静态那只不依赖解释器与 .so，是最"应该能成功"的 exec 目标，
 * 但**静态组合自己就是 static 那只**，固定挑 static 会挑到自己、只能跳过 —— 白白丢一条
 * 覆盖。反过来挑，两个方向就都有覆盖了（静态目标验"不靠解释器也能 exec"，动态目标验
 * "exec 一个要解释器+库的程序"，后者与 dlhost 那条不重复：那只是 .so，这只是主程序）。 */
static void t_exec_sibling_static(void) {
    BEGIN("exec 同目录的兄弟程序（另一种链接方式）");
    char name[128], path[PATH_MAX];
    /* aarch64-musl-dynamic → aarch64-musl-static；aarch64-musl-static → …-dynamic。
     * 组合名可能带一个 "…-nopie" 后缀（动态但非 PIE 那一格，见 build_testprogs.sh），
     * 它说的是"链接方式之外的另一个维度"，不参与 static/dynamic 的替换 —— 先摘掉，
     * 否则最后那个 '-' 会落在 nopie 上，拼出 aarch64-glibc-dynamic-static 这种不存在的名字。 */
    snprintf(name, sizeof name, "%s", BSH_TEST_COMBO);
    static const char kNopie[] = "-nopie";
    size_t nlen = strlen(name);
    if (nlen > sizeof(kNopie) - 1 &&
        strcmp(name + nlen - (sizeof(kNopie) - 1), kNopie) == 0)
        name[nlen - (sizeof(kNopie) - 1)] = '\0';
    char *dash = strrchr(name, '-');
    if (dash) snprintf(dash, sizeof name - (size_t)(dash - name),
                       BSH_TEST_STATIC ? "-dynamic" : "-static");
    sibling(path, sizeof path, "%s", name);

    struct stat st;
    if (stat(path, &st) != 0) {
        SKIP("%s 不在（兄弟文件没打进 tar？）: %s", path, strerror(errno));
        END(); return;
    }

    pid_t pid = fork();
    if (pid < 0) { FAIL("fork: %s", strerror(errno)); END(); return; }
    if (pid == 0) {
        char *const av[] = { path, (char *)"--child", NULL };
        execv(path, av);
        INFO("execv(%s) 返回了，errno=%d (%s)", path, errno, strerror(errno));
        _exit(124);
    }
    int st2 = 0;
    if (waitpid(pid, &st2, 0) != pid) { FAIL("waitpid: %s", strerror(errno)); END(); return; }
    int code = WIFEXITED(st2) ? WEXITSTATUS(st2) : -1;
    INFO("子进程 %s 退出码=%d（期望 42；124=execv 返回了）", name, code);
    if (code == 42) PASS("exec 兄弟程序跑通");
    else            FAIL("exec 兄弟程序失败（退出码 %d）", code);
    END();
}

/* ---------------- tests: 终端 ---------------- */

/* 会话给的 stdio 到底是不是终端。
 *
 * ⚠ 这一项**只在会话本身是交互式的时候才有判据**。自检（autorun）里 stdin 接
 *   /dev/null、stdout 接日志文件，压根没有 tty —— 那时"没检测到 tty"什么也说明
 *   不了，只能记 SKIP。第一版在这里记了 PASS("tty 探测已转储")，是个**空判**：
 *   它证明的只是"printf 能跑"。
 *
 * 背景：本应用的会话终端是**软 pty**（tty/softpty.cpp，socketpair 模拟），不是真的
 * /dev/pts 设备，所以内核的 isatty() 对 fd 0/1/2 一律返回 0。命令 so 与 guest 都靠
 * shim（shim/tty_shim.c，前者链接期编入、后者 LD_PRELOAD）把 isatty/tcgetattr 接管
 * 过来，开关是 BSH_TTY_STDIO（procmgr 按"stdio 是不是 socket"设）。
 * 所以：guest 带 shim 时会看到 isatty=1；没带（静态 guest）或 stdio 本来就不是终端
 * （自检里是 /dev/null + 日志文件）就是 0 —— 后者记 SKIP，没有可验的对象。
 */
static void t_tty(void) {
    BEGIN("tty（会话给的 stdio）");
    int any_tty = 0;
    for (int fd = 0; fd <= 2; fd++) {
        int t = isatty(fd);
        if (t) any_tty = 1;
        INFO("isatty(%d) = %d", fd, t);
    }
#if defined(HAVE_TERMIOS)
    struct termios tio;
    if (tcgetattr(0, &tio) == 0) {
        INFO("tcgetattr(0) ok: iflag=0x%lx oflag=0x%lx cflag=0x%lx lflag=0x%lx",
             (unsigned long)tio.c_iflag, (unsigned long)tio.c_oflag,
             (unsigned long)tio.c_cflag, (unsigned long)tio.c_lflag);
    } else {
        INFO("tcgetattr(0) 失败: %s", strerror(errno));
    }
#endif
#if defined(HAVE_IOCTL) && defined(TIOCGWINSZ)
    struct winsize ws = {0, 0, 0, 0};
    if (ioctl(0, TIOCGWINSZ, &ws) == 0)
        INFO("TIOCGWINSZ(0) = %u 行 × %u 列", (unsigned)ws.ws_row, (unsigned)ws.ws_col);
    else
        INFO("TIOCGWINSZ(0) 失败: %s", strerror(errno));
#endif
    /* 有没有控制终端：mksh 那句 "no controlling tty" 就是这一条 */
    int tfd = open("/dev/tty", O_RDWR | O_NOCTTY);
    if (tfd >= 0) { INFO("open(\"/dev/tty\") ok, fd=%d", tfd); close(tfd); }
    else          INFO("open(\"/dev/tty\") 失败: %s", strerror(errno));

    char *tn = ttyname(0);
    INFO("ttyname(0) = %s", tn ? tn : "(null)");

    if (!any_tty) {
        SKIP("0/1/2 都不是终端 —— 这次没有可验的对象（判据本身见上面几行事实）");
    } else {
#if defined(HAVE_TERMIOS)
        if (tcgetattr(0, &tio) == 0) PASS("isatty(0)=1 且 tcgetattr(0) 成功");
        else                         FAIL("isatty(0)=1 但 tcgetattr 失败: %s", strerror(errno));
#else
        SKIP("没有 <termios.h>，验不了 termios");
#endif
    }
    END();
}

/* pty：guest **自己**能不能拿一路伪终端并把它设成控制终端。
 *
 * 为什么用这个当判据：会话给的 stdio 是宿主决定的（可能压根不是 tty），说明不了
 * guest 的能力；而"TUI 程序 / 终端复用器 / script 类工具"真正要的是这个 ——
 * 自己 openpt、设 ctty、在 slave 上 isatty/tcgetattr/ttyname/读窗口大小。
 *
 * 在 fork 出来的子进程里做：setsid 会脱离当前会话，留在本进程里会把后面的用例
 * （尤其 tty 与控制终端相关）搅乱。子进程用退出码带结论回来，输出仍走原来的
 * stdout（不去 dup2 到新 slave，免得诊断信息进了那个 pty 就看不见了）。 */
static void t_pty(void) {
    BEGIN("pty：guest 自建伪终端 + 设控制终端");
    int pid = fork();
    if (pid < 0) { FAIL("fork: %s", strerror(errno)); END(); return; }
    if (pid == 0) {
        int mfd = open("/dev/ptmx", O_RDWR | O_NOCTTY);
        if (mfd < 0) {
            printf("│  [INFO] open(/dev/ptmx) 失败: %s（沙箱不给 pty）\n", strerror(errno));
            fflush(stdout); _exit(2);
        }
        printf("│  [INFO] open(/dev/ptmx) ok, master fd=%d\n", mfd); fflush(stdout);
        if (grantpt(mfd) != 0)
            printf("│  [INFO] grantpt: %s\n", strerror(errno));
        if (unlockpt(mfd) != 0)
            printf("│  [INFO] unlockpt: %s\n", strerror(errno));
        char *sn = ptsname(mfd);
        if (!sn) {
            printf("│  [INFO] ptsname 失败: %s\n", strerror(errno)); fflush(stdout); _exit(3);
        }
        printf("│  [INFO] slave = %s\n", sn); fflush(stdout);
        if (setsid() < 0)
            printf("│  [INFO] setsid: %s\n", strerror(errno));
        /* 不带 O_NOCTTY 打开：会话组长第一次开 tty 时会自动成为控制终端 */
        int sfd = open(sn, O_RDWR);
        if (sfd < 0) {
            printf("│  [INFO] open(slave) 失败: %s\n", strerror(errno)); fflush(stdout); _exit(4);
        }
        int is = isatty(sfd);
#if defined(HAVE_TERMIOS)
        struct termios tio;
        int ga = (tcgetattr(sfd, &tio) == 0);
        int sa = (tcsetattr(sfd, TCSANOW, &tio) == 0);   /* 读回来再写回去，验可写 */
#else
        int ga = 0, sa = 0;
#endif
        char *tn = ttyname(sfd);
        int ct = open("/dev/tty", O_RDWR | O_NOCTTY);
        printf("│  [INFO] isatty(slave)=%d tcgetattr=%d tcsetattr=%d ttyname=%s"
               " open(/dev/tty)=%d%s%s\n",
               is, ga, sa, tn ? tn : "(null)", ct,
               ct < 0 ? " errno=" : "", ct < 0 ? strerror(errno) : "");
        if (ct >= 0) close(ct);
        fflush(stdout);
        int ok = is && ga && sa && tn && ct >= 0;
        if (ct < 0) {
            /* 有 slave 但没有控制终端：setsid+TIOCSCTTY 那一步没成 */
#if defined(TIOCSCTTY)
            if (ioctl(sfd, TIOCSCTTY, 0) != 0)
                printf("│  [INFO] ioctl(TIOCSCTTY) 失败: %s\n", strerror(errno));
            else
                printf("│  [INFO] ioctl(TIOCSCTTY) 成功（但之前 open 没拿到 ctty）\n");
#else
            printf("│  [INFO] 这个 libc 没定义 TIOCSCTTY，没法手动设控制终端\n");
#endif
            fflush(stdout);
        }
        /* 故意不 close(mfd)：关掉 pty master 会让内核给这个会话发 SIGHUP，
         * 子进程会以"被信号杀掉"收场（第一版就是这样，父进程看到 WIFEXITED=0，
         * 报了个假 FAIL —— 明明每一步都过了）。进程 _exit 时内核自己会收 fd。 */
        _exit(ok ? 0 : 5);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) != pid) { FAIL("waitpid: %s", strerror(errno)); END(); return; }
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    if (code == 0)       PASS("guest 能自建 pty 并设成控制终端");
    else if (code == 2)  FAIL("拿不到 pty：/dev/ptmx 被拒（guest 里跑不了任何 TUI）");
    else                 FAIL("pty 链路不完整（退出码 %d，上面每步的结果都打出来了）", code);
    END();
}

/* ---------------- tests: 地址空间自省 ---------------- */

/* /proc/self/maps 里"文件映射 + 可执行"的行数。这是"会不会弹是否运行确认框"的
 * 判据：我们的执行者把 ELF 读进匿名页，所以 guest 自己的镜像**不该**出现
 * file-backed 的可执行映射。
 *
 * ⚠ 只数"guest 自己的东西"，判据是**路径**而不是名字：这个进程是 procmgr 从主进程
 *   fork 出来的，地址空间里本来就有宿主 app 的几百个映射（libQt6*、libclangbsh、
 *   python… 全是文件映射）。第一版没区分，报出 "901 个文件可执行映射"，看着像炸了，
 *   其实全是被继承的宿主库。第二版按名字匹配（ld-musl/libc.so.6/…）又踩到第二个
 *   坑：宿主 app 自己就映射着 /system/lib/ld-musl-aarch64.so.1（同名的系统库），
 *   那不是 guest 的镜像。
 *   真正的判据：guest 自己的镜像只可能来自两处 ——
 *     a) 它自己所在的目录（$HOME/testprogs/…，里面每个文件都可能是 guest 的镜像）；
 *     b) 随 HAP 的运行时目录，但**只算那三个运行时文件**（libc.so.6 /
 *        ld-linux-aarch64.so.1 / ld-musl-aarch64.so.1）—— 这个目录里还有宿主 app
 *        自己的库（libentry.so、libc++_shared.so、libwayland-server.so.0…），
 *        它们文件映射着是**正常**的，第一次按目录前缀一网打尽就把它们也报进来了。
 *   （顺便：guest 的运行时被我们装进匿名页后，名字根本不会出现在 maps 里 ——
 *     所以"名字还在"本身就等价于"它是文件映射"。）
 *
 * ⚠ 这一页**只报事实、不下判定**。"guest 的镜像该不该是文件映射"是**这台执行者的
 *   规矩**，不是程序自己能下的结论：设备沙箱里文件可执行映射会弹"是否运行 xxx"
 *   （所以我们的 elfloader 必须做成匿名），而普通 Linux 上文件映射本来就是常态
 *   （内核/ld.so 干的），qemu-user 也一样。程序若按其中一种规矩判，就写成"先知道
 *   自己在哪、再判卷"，那种 PASS/FAIL 没有意义。
 *   判据交给外层（知道自己在哪的那一层）：设备侧自检 grep 下面这行机器可读的事实，
 *   本地跑则不看。 */
static int path_is_guest_own(const char *path) {
    size_t dlen = strlen(g_dir);
    if (dlen > 1 && strncmp(path, g_dir, dlen) == 0) return 1;   /* guest 目录里的任何东西 */
    if (strstr(path, "/bundle/libs/")) {
        /* 只认那三个"只给 guest 用"的运行时；宿主自己的库不算 */
        static const char *rt[] = { "/libc.so.6", "/ld-linux-aarch64.so.1",
                                   "/ld-musl-aarch64.so.1" };
        for (unsigned i = 0; i < sizeof rt / sizeof rt[0]; i++)
            if (strstr(path, rt[i])) return 1;
    }
    return 0;
}

static void t_maps(void) {
    BEGIN("/proc/self/maps：guest 镜像的映射形态（事实，不判分）");
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) {
        SKIP("读不到 /proc/self/maps: %s", strerror(errno));
        END(); return;
    }
    char line[1024];
    int filex = 0, anonx = 0;
    while (fgets(line, sizeof line, f)) {
        /* 形如 "7f00-7f01 r-xp 00000000 fd:01 1234  /path/libx.so" */
        char perms[8] = {0};
        if (sscanf(line, "%*s %7s", perms) != 1) continue;
        if (perms[2] != 'x') continue;
        char *path = strchr(line, '/');
        if (!path) { anonx++; continue; }
        path[strcspn(path, "\n")] = 0;
        if (path_is_guest_own(path)) { filex++; INFO("[file+exec] %s", path); }
    }
    fclose(f);
    /* 这行是给外层自检 grep 的：格式别改（不带前缀、机器可读） */
    printf("FACT guest-file-exec-mappings=%d (anon-exec=%d)\n", filex, anonx);
    INFO("guest 自己的镜像里：文件可执行映射 %d 个，匿名可执行映射 %d 个", filex, anonx);
    INFO("→ 判据不在这里：设备沙箱要求这个数是 0（否则弹「是否运行 xxx」），");
    INFO("  普通 Linux/qemu 下它就是该有文件映射的。见 device 侧自检里的断言。");
    END();
}

/* ---------------- main ---------------- */

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    init_self_paths(argc > 0 ? argv[0] : NULL);

    /* 子模式：exec 自己时用它。只打印身份 + 退出 42，绝不跑全套（否则递归）。 */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--child") == 0) {
            printf("[child] combination=%s pid=%d ppid=%d dir=%s\n",
                   BSH_TEST_COMBO, (int)getpid(), (int)getppid(), g_dir);
            printf("[child] cwd 可读: ");
            FILE *f = fopen("/proc/self/stat", "r");
            printf("%s\n", f ? "是" : "否");
            if (f) fclose(f);
            fflush(stdout);
            return 42;
        }
    }

    printf("\n=================================================\n");
    printf("  combination: %s\n", BSH_TEST_COMBO);
    printf("-------------------------------------------------\n");
    printf("  guest functional test on HarmonyOS NEXT\n");
    printf("  built %s %s\n", __DATE__, __TIME__);
    printf("  ptr=%zu bytes\n", sizeof(void*));
#ifdef __x86_64__
    printf("  arch: x86_64\n");
#elif defined(__aarch64__)
    printf("  arch: aarch64\n");
#endif
#ifdef __GLIBC__
    printf("  libc: glibc %d.%d\n", __GLIBC__, __GLIBC_MINOR__);
#else
    printf("  libc: musl (or unknown)\n");
#endif
#if BSH_TEST_STATIC
    printf("  link: static\n");
#else
    printf("  link: dynamic\n");
#endif
    printf("  dir:  %s\n", g_dir);
    printf("=================================================\n");

    t_stdio();
    t_args(argc, argv);
    t_env();
    t_uname();
    t_ids();
    t_time();
    t_sysconf();
    t_malloc();
    t_str();
    t_math();
    t_fpu();
    t_file();
    t_fs();
    t_symlink();
    t_getrandom();
    t_socketpair();
    t_signal();
    t_pthread();
    t_mutex();
    t_fork_pipe();
    t_shmem_fork();
    t_proc_self();
    t_auxv();
    t_jit();
    t_maps();
    t_tty();
    t_pty();
    t_dlopen();
    t_exec_dyn_with_so();
    t_exec_self();
    t_exec_sibling_static();

    printf("\n=================================================\n");
    /* total 是"用例块"数，pass/fail/skip 是**判定条数** —— 个别块里有多条判定
     * （比如 symlink/hardlink 一块两条），所以 total 不必等于三者之和。 */
    printf("  blocks=%d  pass=%d  fail=%d  skip=%d\n",
           g_total, g_pass, g_fail, g_skip);
    /* 末尾再打一次组合名：八份输出连着跑时，靠这一行就能对上是谁的结果 */
    printf("  combination: %s\n", BSH_TEST_COMBO);
    printf("=================================================\n");

    /* 放最后：这一条一旦成功，当前镜像就被子模式的自己替换（后面的代码不再执行） */
    t_exec_self_inplace();

    fflush(stdout);
    return g_fail > 0 ? 1 : 0;
}
