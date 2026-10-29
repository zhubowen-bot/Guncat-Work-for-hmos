// shim/compat_shim.c — 给"我们随包的 musl"补几个它还没有的 libc 符号
//
// 为什么需要:guest 用的运行时就我们自编的 **musl 1.2.2**(带"匿名装载"补丁),而现代
// 二进制会引用 1.2.3/1.2.4 才加进来的函数。少一个符号,ld.so 就在**加载期**报
// `symbol not found` 并让整个 .so 起不来 —— 实测 Qt 6.12 的 libQt6Core 一次缺 4 个
// (backtrace / pthread_getname_np / renameat2 / pthread_cond_clockwait),窗口自然起不来。
//
// 只编进 **musl** 那份额(glibc 自己就有这些,补上去反而会遮蔽真实现,见 build_shim.sh)。
//
// 取舍:这些是"能用就行"的实现,不是 musl 上游那套的等价物:
//   - backtrace 只报"拿不到",返回 0(Qt 只拿它打崩溃日志);
//   - pthread_cond_clockwait 忽略 clockid 直接转 timedwait(我们的 musl 只有 REALTIME
//     版本;选 MONOTONIC 的调用方在极端情况下会等久一点,不会错乱);
//   - renameat2 是真转发(内核支持,只是 musl 1.2.2 没包一层)。
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>
#include <sys/syscall.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#ifndef SYS_renameat2
#define SYS_renameat2 276   /* arm64/generic */
#endif

int renameat2(int olddirfd, const char *oldpath,
              int newdirfd, const char *newpath, unsigned int flags)
{
    return (int)syscall(SYS_renameat2, olddirfd, oldpath, newdirfd, newpath, flags);
}

int pthread_getname_np(pthread_t thread, char *name, size_t len)
{
    (void)thread;
    if (name == NULL) return EINVAL;
    if (len == 0) return ERANGE;
    name[0] = '\0';          /* "没有名字"是可接受的结果,别让调用方拿到脏内存 */
    return 0;
}

int pthread_setname_np(pthread_t thread, const char *name)
{
    (void)thread;
    (void)name;
    return 0;
}

int pthread_cond_clockwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                           clockid_t clockid, const struct timespec *abstime)
{
    (void)clockid;
    return pthread_cond_timedwait(cond, mutex, abstime);
}

int backtrace(void **buffer, int size)
{
    (void)buffer;
    (void)size;
    return 0;
}

char **backtrace_symbols(void *const *buffer, int size)
{
    (void)buffer;
    (void)size;
    return NULL;
}

void backtrace_symbols_fd(void *const *buffer, int size, int fd)
{
    (void)buffer;
    (void)size;
    (void)fd;
}

/* ── 下面这些也是"新 musl 才有",但实现是真干活,不是占位 ───────────────── */

/* musl 1.2.5 起才有;OHOS 编的 libexpat 等会引用它(我们那份 1.2.2 没有)。
 * 用 musl 1.2.2 就有的 getentropy 拼出来(单次上限 256 字节)。 */
void arc4random_buf(void *buf, size_t n)
{
    unsigned char *p = (unsigned char *)buf;
    while (n > 0) {
        size_t chunk = n > 256 ? 256 : n;
        if (getentropy(p, chunk) != 0) break;
        p += chunk;
        n -= chunk;
    }
}

unsigned int arc4random(void)
{
    unsigned int v = 0;
    arc4random_buf(&v, sizeof v);
    return v;
}

/* 无偏取模(拒绝采样),语义与 BSD/musl 一致 */
unsigned int arc4random_uniform(unsigned int upper_bound)
{
    if (upper_bound < 2) return 0;
    unsigned int min = (unsigned int)(-upper_bound) % upper_bound;
    unsigned int r;
    do { r = arc4random(); } while (r < min);
    return r % upper_bound;
}

/* musl 1.2.5 起才有。用线程局部的比较器转调 qsort —— 简单且线程安全。 */
static __thread void *g_qsort_arg;
static __thread int (*g_qsort_cmp)(const void *, const void *, void *);

static int qsort_r_tramp(const void *a, const void *b)
{
    return g_qsort_cmp(a, b, g_qsort_arg);
}

void qsort_r(void *base, size_t nmemb, size_t size,
             int (*compar)(const void *, const void *, void *), void *arg)
{
    g_qsort_arg = arg;
    g_qsort_cmp = compar;
    qsort(base, nmemb, size, qsort_r_tramp);
}

/* musl 1.2.4 起才有;忽略 clockid,退回 timedlock(同 pthread_cond_clockwait 的取舍) */
int pthread_mutex_clocklock(pthread_mutex_t *mutex, clockid_t clockid,
                            const struct timespec *abstime)
{
    (void)clockid;
    return pthread_mutex_timedlock(mutex, abstime);
}
