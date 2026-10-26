/* Guncat Work: 让 glibc 版 libgfortran 能在 OHOS(musl) 上跑起来的补充桩。
 *
 * 交叉编译 scipy 时, Fortran 目标文件会 DT_NEEDED libgfortran.so.5。我们手里只有
 * Ubuntu 的 aarch64 libgfortran.a(glibc 版), 它缺 13 个 musl 没有的符号:
 *   - _gfortrani_async_*  : Fortran 异步 I/O 内部函数(定义在 async.o, 那份目标文件用了
 *                           静态 TLS 模型, 无法链进共享库, 只能在这里给空实现)
 *   - __ctype_b_loc       : glibc 的 ctype 表访问器
 *   - __isoc23_sscanf     : glibc 2.38+ 的 sscanf 别名
 *   - __aarch64_cas8_sync / __aarch64_swp4_sync : libgcc 的 ARM 原子助手
 *
 * 这些全在"格式化 I/O / 异步 I/O"路径上, 数值计算(scipy 的 linalg/special/optimize)不会走到;
 * 给最小可用实现即可, 目的是让动态链接器能加载, 而不是复刻 glibc 行为。
 */

#include <stdarg.h>
#include <stddef.h>
#include <pthread.h>
#include <stdio.h>

/* ---------- Fortran 异步 I/O: 空实现 ---------- */
void _gfortrani_init_async_unit(void *unit) { (void)unit; }
int _gfortrani_async_close(void) { return 0; }
int _gfortrani_async_wait(void) { return 0; }
int _gfortrani_async_wait_id(int id) { (void)id; return 0; }
void _gfortrani_collect_async_errors(void) { }
void _gfortrani_enqueue_data_transfer_init(void *a, void *b) { (void)a; (void)b; }
void _gfortrani_enqueue_done(void *a) { (void)a; }
void _gfortrani_enqueue_done_id(int id) { (void)id; }
void _gfortrani_enqueue_transfer(void *a, void *b, void *c) { (void)a; (void)b; (void)c; }

/* ---------- glibc ctype 表 ---------- */
/* glibc 的位定义: _ISbit(0..7) = 1<<(bit+8), _ISbit(8..11) = 1<<(bit-8) */
#define G_ISblank  0x0001
#define G_IScntrl  0x0002
#define G_ISpunct  0x0004
#define G_ISalnum  0x0008
#define G_ISupper  0x0100
#define G_ISlower  0x0200
#define G_ISalpha  0x0400
#define G_ISdigit  0x0800
#define G_ISxdigit 0x1000
#define G_ISspace  0x2000
#define G_ISprint  0x4000
#define G_ISgraph  0x8000

static unsigned short g_ctype[384];
static int g_ctype_ready = 0;

static void g_ctype_fill(void)
{
    int c;
    for (c = 0; c < 384; c++) {
        int ch = c - 128;
        unsigned short f = 0;
        if (ch >= 0 && ch < 128) {
            if (ch >= 'A' && ch <= 'Z') f |= G_ISupper | G_ISalpha | G_ISalnum | G_ISprint | G_ISgraph;
            if (ch >= 'a' && ch <= 'z') f |= G_ISlower | G_ISalpha | G_ISalnum | G_ISprint | G_ISgraph;
            if (ch >= '0' && ch <= '9') f |= G_ISdigit | G_ISalnum | G_ISxdigit | G_ISprint | G_ISgraph;
            if ((ch >= 'A' && ch <= 'F') || (ch >= 'a' && ch <= 'f')) f |= G_ISxdigit;
            if (ch == ' ' || ch == '\t') f |= G_ISblank | G_ISspace;
            if (ch == '\n' || ch == '\r' || ch == '\v' || ch == '\f') f |= G_ISspace;
            if (ch < 32 || ch == 127) f |= G_IScntrl;
            if (ch > 32 && ch < 127 && !(f & (G_ISalnum))) f |= G_ISpunct | G_ISprint | G_ISgraph;
            if (ch == ' ') f |= G_ISprint | G_ISgraph;
        }
        g_ctype[c] = f;
    }
    g_ctype_ready = 1;
}

const unsigned short **__ctype_b_loc(void)
{
    static unsigned short *table = 0;
    if (!g_ctype_ready) {
        g_ctype_fill();
    }
    table = &g_ctype[128];
    return (const unsigned short **)&table;
}

int __isoc23_sscanf(const char *str, const char *format, ...)
{
    va_list ap;
    int rc;
    va_start(ap, format);
    rc = vsscanf(str, format, ap);
    va_end(ap);
    return rc;
}

/* ---------- libgcc 的 ARM 原子助手 ---------- */
unsigned long long __aarch64_cas8_sync(unsigned long long expected, void *ptr,
                                       unsigned long long desired)
{
    unsigned long long old = __atomic_load_n((unsigned long long *)ptr, __ATOMIC_ACQUIRE);
    while (old == expected) {
        if (__atomic_compare_exchange_n((unsigned long long *)ptr, &old, desired, 0,
                                        __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
            return expected;
        }
    }
    return old;
}

unsigned int __aarch64_swp4_sync(unsigned int desired, void *ptr)
{
    return __atomic_exchange_n((unsigned int *)ptr, desired, __ATOMIC_SEQ_CST);
}

/* glibc 的 fork 处理器登记; musl 只提供 pthread_atfork。直接转发即可。 */
int __register_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void),
                      void *dso_handle)
{
    (void)dso_handle;
    return pthread_atfork(prepare, parent, child);
}

/* ---------- 其余 glibc 专有符号(musl 没有) ---------- */
/* fenv 的"异常开关"扩展: 只影响浮点异常陷阱, 数值计算不依赖它。 */
int feenableexcept(int mask) { (void)mask; return 0; }
int fedisableexcept(int mask) { (void)mask; return 0; }
int fegetexcept(void) { return 0; }

/* long double 版 Bessel; musl 未提供。Fortran 的 BESSEL_JN 会用到, scipy 走自己的 special。 */
long double jnl(int n, long double x) { (void)n; (void)x; return 0.0L; }
long double ynl(int n, long double x) { (void)n; (void)x; return 0.0L; }

/* Fortran 异步 I/O 的 TLS 指针: async.o 用了静态 TLS 模型无法进共享库, 这里给一个空的。 */
__thread void *thread_unit __attribute__((visibility("hidden"))) = 0;
