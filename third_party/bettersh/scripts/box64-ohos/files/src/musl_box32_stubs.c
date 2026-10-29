/* OHOS_PATCH_BOX32_LINK_STUBS
 *
 * Link-time stubs for the BOX32 build on HarmonyOS musl.
 *
 * 两组:
 *
 * 1) box32_malloc/calloc/realloc/free/strdup
 *    上游放在 mallochook.c. 因为 patch_13 把 mallochook.c 替换成
 *    诊断 passthrough 版了, 这里补回 BOX32 用到的几个.
 *
 *    WARNING: 真正的 BOX32 期望这组分配器从 <4GB 可达池里返回内存,
 *    保证 32-bit guest 指针 (to_ptrv 截断后) 仍指向真实 host 内存.
 *    这里直接走 libc malloc, host 指针可能 >4GB, 跑 i386 ELF 时
 *    guest 访问会 SIGSEGV. 链接 OK, 运行未必 OK, 后续需要做低 4GB
 *    mmap pool 才能稳定运行.
 *
 * 2) OHOS musl 不提供的 libc 函数:
 *      getprotobyname_r / getprotobynumber_r  -- glibc GNU 扩展
 *      __res_state                            -- glibc resolver TLS getter
 *      __chk_fail                             -- glibc FORTIFY abort helper
 *      getcontext / makecontext / swapcontext -- 这版 OHOS musl 没编
 */

#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <netdb.h>
#include <errno.h>
#include <resolv.h>
#include <ucontext.h>

/* ---- 1) box32_* allocators -- NOT here, see patch 28 ----------- *
 *
 * box32_malloc / calloc / realloc / free / strdup / memalign /
 * malloc_usable_size 都由 patch 28 在 src/musl_compat.c 里实现
 * (低 4GB heap allocator). 这里如果再定义一份, 会和 patch 28 强
 * 符号冲突, ld.lld 报 duplicate symbol.
 */

/* ---- 2) glibc-only libc functions ------------------------------ */

/* getprotoby*_r: emulate via non-_r variants. 真正的可重入语义没法
 * 用纯 musl 实现, 这里只满足链接和大多数单线程调用. */
int getprotobyname_r(const char* name,
                     struct protoent* result_buf,
                     char* buf, size_t buflen,
                     struct protoent** result)
{
    (void)result_buf; (void)buf; (void)buflen;
    struct protoent* p = getprotobyname(name);
    if (!p) { *result = NULL; return ENOENT; }
    *result = p;   /* points to libc-internal static; not thread-safe */
    return 0;
}

int getprotobynumber_r(int proto,
                       struct protoent* result_buf,
                       char* buf, size_t buflen,
                       struct protoent** result)
{
    (void)result_buf; (void)buf; (void)buflen;
    struct protoent* p = getprotobynumber(proto);
    if (!p) { *result = NULL; return ENOENT; }
    *result = p;
    return 0;
}

/* __res_state: glibc 返回 TLS resolver state. 这里给一个静态 buffer,
 * 不依赖 musl 的 _res 是否实际链接得到 (有些 musl 配置里 _res 也
 * 可能解析不出). 大多数 box64 调用方只是读取指针, 不真正用里面
 * 的字段. */
struct __res_state* __res_state(void)
{
    static struct __res_state ohos_res_state;  /* zero-initialized */
    return &ohos_res_state;
}

/* __chk_fail: FORTIFY 抛弃路径, 直接 abort. */
__attribute__((noreturn))
void __chk_fail(void)
{
    fprintf(stderr, "*** buffer overflow detected (__chk_fail stub) ***\n");
    abort();
}

/* ucontext: 这版 OHOS musl 没编. 调到就退出, 路径稀少 (基本只有
 * wrappedexpat 的协程式 XML_ParseBuffer 才走). */
int getcontext(ucontext_t* ucp)
{
    (void)ucp;
    fprintf(stderr, "BOX64/OHOS: getcontext() not supported on this musl\n");
    errno = ENOSYS;
    return -1;
}

void makecontext(ucontext_t* ucp, void (*func)(void), int argc, ...)
{
    (void)ucp; (void)func; (void)argc;
    fprintf(stderr, "BOX64/OHOS: makecontext() not supported on this musl\n");
}

int swapcontext(ucontext_t* oucp, const ucontext_t* ucp)
{
    (void)oucp; (void)ucp;
    fprintf(stderr, "BOX64/OHOS: swapcontext() not supported on this musl\n");
    errno = ENOSYS;
    return -1;
}
