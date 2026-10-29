/*
 * musl_compat.c — glibc-private symbol stubs for OHOS musl.
 *
 * All implementations are weak so that any future OHOS NDK update which
 * adds a real symbol will silently override these.
 */
#define _GNU_SOURCE
#define BOX64_OHOS_MUSL_COMPAT 1

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *memalign(size_t, size_t);  /* not in <stdlib.h> on musl */

/* ------------------------------------------------------------------
 * glibc-private __libc_* malloc family
 * ------------------------------------------------------------------ */
__attribute__((weak)) void *__libc_malloc (size_t s)            { return malloc(s); }
__attribute__((weak)) void  __libc_free   (void *p)             { free(p); }
__attribute__((weak)) void *__libc_calloc (size_t n, size_t s)  { return calloc(n, s); }
__attribute__((weak)) void *__libc_realloc(void *p, size_t s)   { return realloc(p, s); }
__attribute__((weak)) void *__libc_memalign(size_t a, size_t s) { return memalign(a, s); }
__attribute__((weak)) void *__libc_valloc (size_t s)
{
    return memalign(sysconf(_SC_PAGESIZE), s);
}
__attribute__((weak)) void *__libc_pvalloc(size_t s)
{
    long pg = sysconf(_SC_PAGESIZE);
    size_t r = (s + pg - 1) & ~(pg - 1);
    return memalign(pg, r);
}

/* ------------------------------------------------------------------
 * pthread NP extensions
 * ------------------------------------------------------------------ */
__attribute__((weak))
int pthread_attr_setaffinity_np(pthread_attr_t *a, size_t s, const void *c)
{ (void)a;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_attr_getaffinity_np(const pthread_attr_t *a, size_t s, void *c)
{ (void)a;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_getaffinity_np(pthread_t t, size_t s, void *c)
{ (void)t;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_setaffinity_np(pthread_t t, size_t s, const void *c)
{ (void)t;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_getattr_default_np(pthread_attr_t *a)
{ (void)a; return ENOSYS; }

__attribute__((weak))
int pthread_setattr_default_np(pthread_attr_t *a)
{ (void)a; return ENOSYS; }

__attribute__((weak))
int pthread_mutexattr_getrobust(const pthread_mutexattr_t *a, int *r)
{ (void)a; if (r) *r = 0; return 0; }

__attribute__((weak))
int pthread_mutexattr_setrobust(pthread_mutexattr_t *a, int r)
{ (void)a;(void)r; return 0; }

__attribute__((weak))
int pthread_mutexattr_getprioceiling(const pthread_mutexattr_t *a, int *p)
{ (void)a; if (p) *p = 0; return 0; }

__attribute__((weak))
int pthread_mutexattr_setprioceiling(pthread_mutexattr_t *a, int p)
{ (void)a;(void)p; return ENOSYS; }

/* ------------------------------------------------------------------
 * dlinfo — musl doesn't ship one. Return ENOSYS.
 * ------------------------------------------------------------------ */
__attribute__((weak))
int dlinfo(void *handle, int request, void *info)
{
    (void)handle; (void)request; (void)info;
    errno = ENOSYS;
    return -1;
}

/* ------------------------------------------------------------------
 * qsort_r — thread-local trampoline to qsort
 * ------------------------------------------------------------------ */
typedef int (*qsort_r_compar_t)(const void *, const void *, void *);
static __thread qsort_r_compar_t g_qr_compar;
static __thread void            *g_qr_arg;

static int qsort_r_thunk(const void *a, const void *b)
{
    return g_qr_compar(a, b, g_qr_arg);
}

__attribute__((weak))
void qsort_r(void *base, size_t nmemb, size_t size,
             qsort_r_compar_t compar, void *arg)
{
    g_qr_compar = compar;
    g_qr_arg    = arg;
    qsort(base, nmemb, size, qsort_r_thunk);
}

/* ------------------------------------------------------------------
 * glob64 / globfree64 — on musl, off64_t == off_t, just forward.
 * ------------------------------------------------------------------ */
extern int  glob (const char *, int, int (*)(const char *, int), void *);
extern void globfree(void *);

__attribute__((weak))
int glob64(const char *pat, int flags,
           int (*errfunc)(const char *, int), void *pglob)
{
    return glob(pat, flags, errfunc, pglob);
}

__attribute__((weak))
void globfree64(void *pglob) { globfree(pglob); }

/* ------------------------------------------------------------------
 * scandirat / scandirat64
 * ------------------------------------------------------------------ */
__attribute__((weak))
int scandirat(int dirfd, const char *dirp,
              struct dirent ***namelist,
              int (*filter)(const struct dirent *),
              int (*compar)(const struct dirent **,
                            const struct dirent **))
{
    int fd = openat(dirfd, dirp, O_RDONLY | O_DIRECTORY);
    if (fd < 0) return -1;
    DIR *d = fdopendir(fd);
    if (!d) { close(fd); return -1; }

    struct dirent **list = NULL;
    int n = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (filter && !filter(e)) continue;
        struct dirent *copy = (struct dirent *)malloc(sizeof(*e));
        if (!copy) { closedir(d); free(list); return -1; }
        memcpy(copy, e, sizeof(*e));
        if (n == cap) {
            cap = cap ? cap * 2 : 16;
            list = (struct dirent **)realloc(list, cap * sizeof(*list));
        }
        list[n++] = copy;
    }
    closedir(d);
    if (compar) {
        qsort(list, n, sizeof(*list),
              (int (*)(const void *, const void *))compar);
    }
    *namelist = list;
    return n;
}

__attribute__((weak))
int scandirat64(int dirfd, const char *dirp,
                struct dirent ***namelist,
                int (*filter)(const struct dirent *),
                int (*compar)(const struct dirent **,
                              const struct dirent **))
{
    return scandirat(dirfd, dirp, namelist, filter, compar);
}

/* ------------------------------------------------------------------
 * obstack_printf / obstack_vprintf — musl-obstack 不提供
 * ------------------------------------------------------------------ */
struct obstack;
extern void _obstack_grow_box(struct obstack *o, const void *data, size_t n);
/* (real implementation below uses obstack_grow which is a macro; include the
 *  obstack header for it.) */
#include "obstack.h"

__attribute__((weak))
int obstack_vprintf(struct obstack *obs, const char *fmt, va_list ap)
{
    char small[2048];
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(small, sizeof(small), fmt, ap);
    if (n >= 0 && (size_t)n < sizeof(small)) {
        obstack_grow(obs, small, n);
    } else if (n >= 0) {
        char *big = (char *)malloc(n + 1);
        if (big) {
            vsnprintf(big, n + 1, fmt, ap2);
            obstack_grow(obs, big, n);
            free(big);
        }
    }
    va_end(ap2);
    return n;
}

__attribute__((weak))
int obstack_printf(struct obstack *obs, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = obstack_vprintf(obs, fmt, ap);
    va_end(ap);
    return n;
}

/* ------------------------------------------------------------------
 * __ctype_b_loc / __ctype_tolower_loc / __ctype_toupper_loc
 * Allocate 384-entry tables; return pointer offset by +128 so callers
 * can index in [-128, 255] like glibc does.
 * ------------------------------------------------------------------ */
#define BOX_ISupper  0x0100
#define BOX_ISlower  0x0200
#define BOX_ISalpha  0x0400
#define BOX_ISdigit  0x0800
#define BOX_ISxdigit 0x1000
#define BOX_ISspace  0x2000
#define BOX_ISprint  0x4000
#define BOX_ISgraph  0x8000
#define BOX_ISblank  0x0001
#define BOX_IScntrl  0x0002
#define BOX_ISpunct  0x0004
#define BOX_ISalnum  0x0008

static unsigned short box_ctype_b      [384];
static int            box_ctype_tolower[384];
static int            box_ctype_toupper[384];

static const unsigned short *box_ctype_b_ptr       = box_ctype_b       + 128;
static const int            *box_ctype_tolower_ptr = box_ctype_tolower + 128;
static const int            *box_ctype_toupper_ptr = box_ctype_toupper + 128;

__attribute__((constructor(102)))
static void box_init_ctype_tables(void)
{
    for (int c = 0; c < 256; c++) {
        unsigned short f = 0;
        if (c == ' ' || c == '\t')      f |= BOX_ISblank;
        if (c >= 0x09 && c <= 0x0D)     f |= BOX_ISspace;
        if (c == ' ')                   f |= BOX_ISspace;
        if (c < 0x20 || c == 0x7F)      f |= BOX_IScntrl;
        if (c >= 'A' && c <= 'Z')       f |= BOX_ISupper | BOX_ISalpha | BOX_ISalnum | BOX_ISprint | BOX_ISgraph;
        if (c >= 'a' && c <= 'z')       f |= BOX_ISlower | BOX_ISalpha | BOX_ISalnum | BOX_ISprint | BOX_ISgraph;
        if (c >= '0' && c <= '9')       f |= BOX_ISdigit | BOX_ISalnum | BOX_ISxdigit | BOX_ISprint | BOX_ISgraph;
        if ((c >= 'a' && c <= 'f') ||
            (c >= 'A' && c <= 'F'))     f |= BOX_ISxdigit;
        if (c >= 0x21 && c <= 0x7E && !(f & BOX_ISalnum))
            f |= BOX_ISpunct | BOX_ISprint | BOX_ISgraph;
        if (c == ' ')                   f |= BOX_ISprint;

        box_ctype_b      [c + 128] = f;
        box_ctype_tolower[c + 128] = (c >= 'A' && c <= 'Z') ? (c + 32) : c;
        box_ctype_toupper[c + 128] = (c >= 'a' && c <= 'z') ? (c - 32) : c;
    }
}

__attribute__((weak))
const unsigned short **__ctype_b_loc(void)
{
    return (const unsigned short **)&box_ctype_b_ptr;
}

__attribute__((weak))
const int **__ctype_tolower_loc(void)
{
    return (const int **)&box_ctype_tolower_ptr;
}

__attribute__((weak))
const int **__ctype_toupper_loc(void)
{
    return (const int **)&box_ctype_toupper_ptr;
}

/* ------------------------------------------------------------------
 * Misc math helpers some box64 code may reference
 * ------------------------------------------------------------------ */
__attribute__((weak)) int isnanf (float x) { return __builtin_isnan(x); }
__attribute__((weak)) int isinff (float x) { return __builtin_isinf(x); }
__attribute__((weak)) int finitef(float x) { return __builtin_isfinite(x); }

__attribute__((weak)) double      exp10 (double x)      { return pow (10.0,  x); }
__attribute__((weak)) float       exp10f(float x)       { return powf(10.0f, x); }
__attribute__((weak)) long double exp10l(long double x) { return powl(10.0L, x); }

/* ============================================================
 * OHOS_PATCH_BOX32_LOW4GB_V2
 * BOX32 低 4GB allocator 全套 (patch 28)
 *
 * 提供 debug.h 引用的全部 7 个 box32_* 入口:
 *   box32_malloc / calloc / realloc / free
 *   box32_memalign / box32_strdup / box32_malloc_usable_size
 *
 * 上层 box64 通过 actual_* 宏在 BOX32 模式下自动路由到这里,
 * 不需要单独 hook box_malloc.
 * ============================================================ */
#include <sys/mman.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 前向声明: realloc 内部调 free, free 定义在 realloc 之后,
 * 没有这组 decl 编译器会按 implicit int 推断, 等读到真定义就
 * 报 conflicting types. */
void* box32_malloc(size_t size);
void* box32_calloc(size_t n, size_t s);
void* box32_realloc(void* old, size_t size);
void  box32_free(void* p);
void* box32_memalign(size_t align, size_t size);
char* box32_strdup(const char* s);
size_t box32_malloc_usable_size(void* p);

#define BOX32_HEAP_BASE   ((uintptr_t)0x10000000UL)  /* 256MB 起 */
#define BOX32_HEAP_SIZE   ((size_t)0x10000000UL)     /* 256MB 大小 */
#define BOX32_ALIGN       16
#define BOX32_CANARY      0xB032B032u

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

typedef struct box32_hdr {
    uint32_t size;       /* user-visible size */
    uint32_t canary;     /* BOX32_CANARY 表示 in-use */
} box32_hdr_t;

static unsigned char* g_box32_base = NULL;
static unsigned char* g_box32_pos  = NULL;
static unsigned char* g_box32_end  = NULL;
static unsigned char* g_box32_last = NULL;
static pthread_mutex_t g_box32_mu  = PTHREAD_MUTEX_INITIALIZER;

static void box32_heap_init_locked(void) {
    if (g_box32_base) return;

    void* p = mmap((void*)BOX32_HEAP_BASE, BOX32_HEAP_SIZE,
                   PROT_READ|PROT_WRITE,
                   MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE, -1, 0);

    if (p != (void*)BOX32_HEAP_BASE) {
        if (p != MAP_FAILED) munmap(p, BOX32_HEAP_SIZE);
        for (uintptr_t hint = 0x10000000UL; hint < 0x80000000UL;
             hint += 0x10000000UL) {
            p = mmap((void*)hint, BOX32_HEAP_SIZE, PROT_READ|PROT_WRITE,
                     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
            if (p != MAP_FAILED &&
                (uintptr_t)p + BOX32_HEAP_SIZE <= 0x100000000UL) goto ok;
            if (p != MAP_FAILED) munmap(p, BOX32_HEAP_SIZE);
        }
        fprintf(stderr,
            "OHOS box32: cannot reserve low-4GB heap (%zuMB)\n",
            (size_t)(BOX32_HEAP_SIZE >> 20));
        abort();
    }
ok:
    g_box32_base = (unsigned char*)p;
    g_box32_pos  = g_box32_base;
    g_box32_end  = g_box32_base + BOX32_HEAP_SIZE;
    g_box32_last = NULL;
    fprintf(stderr,
        "OHOS box32: low-4GB heap @%p..%p (%zuMB)\n",
        g_box32_base, g_box32_end,
        (size_t)(BOX32_HEAP_SIZE >> 20));
}

static void* box32_alloc_aligned_locked(size_t user_size, size_t align) {
    if (align < BOX32_ALIGN) align = BOX32_ALIGN;
    /* 当前 pos 之后, 找到 user 对齐位置 */
    uintptr_t hdr_pos = (uintptr_t)g_box32_pos;
    uintptr_t user_pos = (hdr_pos + sizeof(box32_hdr_t) + (align - 1))
                         & ~(uintptr_t)(align - 1);
    uintptr_t end_pos = user_pos + user_size;
    end_pos = (end_pos + (BOX32_ALIGN - 1)) & ~(uintptr_t)(BOX32_ALIGN - 1);

    if (end_pos > (uintptr_t)g_box32_end) return NULL;

    box32_hdr_t* h = (box32_hdr_t*)(user_pos - sizeof(box32_hdr_t));
    h->size   = (uint32_t)user_size;
    h->canary = BOX32_CANARY;

    g_box32_pos  = (unsigned char*)end_pos;
    g_box32_last = (unsigned char*)user_pos;
    return (void*)user_pos;
}

static int box32_free_locked(void* user) {
    if (!user) return 1;
    if ((unsigned char*)user < g_box32_base ||
        (unsigned char*)user >= g_box32_end) return 0;

    box32_hdr_t* h = (box32_hdr_t*)((unsigned char*)user - sizeof(box32_hdr_t));
    if (h->canary != BOX32_CANARY) {
        fprintf(stderr, "OHOS box32: bad free %p (canary=0x%x)\n",
                user, h->canary);
        return 1;
    }

    /* LIFO 复用: 仅回退最后一次 */
    if ((unsigned char*)user == g_box32_last) {
        g_box32_pos  = (unsigned char*)h;
        g_box32_last = NULL;
    }
    h->canary = 0xDEADDEAD;
    return 1;
}

void* box32_malloc(size_t size) {
    if (!size) size = 1;
    pthread_mutex_lock(&g_box32_mu);
    if (!g_box32_base) box32_heap_init_locked();
    void* p = box32_alloc_aligned_locked(size, BOX32_ALIGN);
    pthread_mutex_unlock(&g_box32_mu);
    if (!p) {
        fprintf(stderr,
            "OHOS box32: low-4GB heap exhausted (want=%zu, used=%zuMB/%zuMB)\n",
            size,
            (size_t)((g_box32_pos - g_box32_base) >> 20),
            (size_t)(BOX32_HEAP_SIZE >> 20));
    }
    return p;
}

void* box32_calloc(size_t n, size_t s) {
    size_t total = n * s;
    void* p = box32_malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void* box32_memalign(size_t align, size_t size) {
    if (align < BOX32_ALIGN) align = BOX32_ALIGN;
    /* power-of-2 检查 */
    if (align & (align - 1)) {
        size_t a = BOX32_ALIGN;
        while (a < align) a <<= 1;
        align = a;
    }
    if (!size) size = 1;
    pthread_mutex_lock(&g_box32_mu);
    if (!g_box32_base) box32_heap_init_locked();
    void* p = box32_alloc_aligned_locked(size, align);
    pthread_mutex_unlock(&g_box32_mu);
    return p;
}

void* box32_realloc(void* old, size_t size) {
    if (!old)  return box32_malloc(size);
    if (!size) { box32_free(old); return NULL; }

    pthread_mutex_lock(&g_box32_mu);
    box32_hdr_t* h = (box32_hdr_t*)((unsigned char*)old - sizeof(box32_hdr_t));
    if (h->canary != BOX32_CANARY) {
        pthread_mutex_unlock(&g_box32_mu);
        fprintf(stderr, "OHOS box32: bad realloc %p\n", old);
        return NULL;
    }
    size_t old_size = h->size;

    /* 缩容 / 等容: 原地 */
    if (size <= old_size) {
        h->size = (uint32_t)size;
        pthread_mutex_unlock(&g_box32_mu);
        return old;
    }

    /* 扩容: 如果是最后一次分配且尾部够空间, 原地扩 */
    if ((unsigned char*)old == g_box32_last) {
        uintptr_t new_end = (uintptr_t)old + size;
        new_end = (new_end + (BOX32_ALIGN - 1)) & ~(uintptr_t)(BOX32_ALIGN - 1);
        if (new_end <= (uintptr_t)g_box32_end) {
            g_box32_pos = (unsigned char*)new_end;
            h->size = (uint32_t)size;
            pthread_mutex_unlock(&g_box32_mu);
            return old;
        }
    }

    /* 否则: 新分配 + 拷贝 + 释放旧 */
    void* np = box32_alloc_aligned_locked(size, BOX32_ALIGN);
    pthread_mutex_unlock(&g_box32_mu);
    if (!np) return NULL;
    memcpy(np, old, old_size);
    box32_free(old);
    return np;
}

void box32_free(void* p) {
    if (!p) return;
    pthread_mutex_lock(&g_box32_mu);
    box32_free_locked(p);
    pthread_mutex_unlock(&g_box32_mu);
}

char* box32_strdup(const char* s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char* p = (char*)box32_malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

size_t box32_malloc_usable_size(void* p) {
    if (!p) return 0;
    if ((unsigned char*)p < g_box32_base ||
        (unsigned char*)p >= g_box32_end) return 0;
    box32_hdr_t* h = (box32_hdr_t*)((unsigned char*)p - sizeof(box32_hdr_t));
    if (h->canary != BOX32_CANARY) return 0;
    return h->size;
}
/* OHOS_PATCH_BOX32_LOW4GB_V2 END */
/* OHOS_PATCH_BOX32_IOMAP START */
/* ============================================================
 * OHOS_PATCH_BOX32_IOMAP — box32 动态 FILE* 双向代理
 *
 * box64 上游 wrapper32 用 io_convert32/io_convert_from 处理
 * stdin/stderr/stdout 三个全局 FILE*. 但 fopen 返回的动态
 * FILE* 是 host musl 高位地址, 没法用 to_ptrv 直接截断后
 * 让 guest 持有 (guest 后续 fwrite/fclose 时拿截断地址回头喂
 * host musl 必然 SIGSEGV).
 *
 * 解决: 维护一张固定大小的双向表
 *   slot[i] = host_FILE*       (低 4GB 的 4 字节 ID 给 guest)
 *   guest_id = (uint32_t)slot_addr  (其实就是 &slot[i] 的低 32 位)
 *
 * guest 视角拿到的 FILE* = &slot[i] (低 4GB heap 地址),
 * 一旦回到 wrapper, io_convert32 反查 slot 数组拿到 host*.
 *
 * 用 1024 槽够用 (test 程序最多开 10 个 FILE*; 实际负载里
 * 也很少超过几十). 超了 abort 提示扩容.
 * ============================================================ */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

extern void* box32_malloc(size_t);
extern void  box32_free(void*);

#define BOX32_IOMAP_CAP 1024

/* 每个 slot 是低 4GB 上 4 字节, 内容存 host* 高位低 32 位 (其实只是
 * 给 guest 自己 deref *fp 至少看到点东西的占位; 主要 routing 逻辑
 * 不依赖 slot 内容, 而是 slot 地址). */
typedef struct {
    void*   host;       /* host FILE*; NULL 表示空槽 */
    void*   guest_slot; /* 低 4GB 的 4 字节 slot 地址 */
} box32_iomap_entry_t;

static box32_iomap_entry_t g_iomap[BOX32_IOMAP_CAP];
static int                 g_iomap_used = 0;
static pthread_mutex_t     g_iomap_mu = PTHREAD_MUTEX_INITIALIZER;

/* host -> guest: 找已注册槽, 没有就分配新槽 */
void* box32_io_from_host(void* host) {
    if (!host) return NULL;
    /* stdin/stderr/stdout 走特例 (调用方 io_convert_from 已先匹配),
     * 这里仍兜底保护一次: 三个全局直接返回固定低值 1/2/3 占位.
     * box64 上游 my__IO_2_1_*_ 默认 1/2/3, 这与 patch 33 globdata
     * prefill 写入的值一致. */
    if (host == stdin)  return (void*)(uintptr_t)2;
    if (host == stdout) return (void*)(uintptr_t)3;
    if (host == stderr) return (void*)(uintptr_t)1;

    pthread_mutex_lock(&g_iomap_mu);
    /* 查重 */
    for (int i = 0; i < BOX32_IOMAP_CAP; ++i) {
        if (g_iomap[i].host == host) {
            void* gs = g_iomap[i].guest_slot;
            pthread_mutex_unlock(&g_iomap_mu);
            return gs;
        }
    }
    /* 新分配 */
    if (g_iomap_used >= BOX32_IOMAP_CAP) {
        pthread_mutex_unlock(&g_iomap_mu);
        fprintf(stderr,
            "OHOS box32 iomap exhausted (%d slots). Increase BOX32_IOMAP_CAP.\n",
            BOX32_IOMAP_CAP);
        abort();
    }
    int idx = -1;
    for (int i = 0; i < BOX32_IOMAP_CAP; ++i) {
        if (!g_iomap[i].host) { idx = i; break; }
    }
    if (idx < 0) {
        pthread_mutex_unlock(&g_iomap_mu);
        abort();   /* unreachable */
    }
    void* slot = box32_malloc(4);
    if (!slot) {
        pthread_mutex_unlock(&g_iomap_mu);
        return NULL;
    }
    /* slot 内容: 写 host 高位地址的低 32 位作为 marker.
     * guest 真去 deref *fp 不会立刻 segfault (slot 是低 4GB 可读),
     * 但内容是垃圾 -- 假定 guest 不会 walk FILE 内部字段.
     * 如果将来需要支持, 改成 memcpy 一份 i386 FILE 镜像即可. */
    *(uint32_t*)slot = (uint32_t)((uintptr_t)host & 0xFFFFFFFFu);

    g_iomap[idx].host       = host;
    g_iomap[idx].guest_slot = slot;
    g_iomap_used++;

    pthread_mutex_unlock(&g_iomap_mu);
    return slot;
}

/* guest -> host: 反查槽 */
void* box32_io_to_host(void* guest) {
    if (!guest) return NULL;
    /* 特例: 1/2/3 表示 stderr/stdin/stdout (与 my__IO_2_1_*_ 默认值
     * 和 patch 33 prefill 一致). 注意上游 wrapper 调用顺序是先 my__IO
     * 比较再走我们这里, 所以这层兜底在动态 slot 不命中时才生效. */
    uintptr_t v = (uintptr_t)guest;
    if (v == 1) return stderr;
    if (v == 2) return stdin;
    if (v == 3) return stdout;

    pthread_mutex_lock(&g_iomap_mu);
    for (int i = 0; i < BOX32_IOMAP_CAP; ++i) {
        if (g_iomap[i].guest_slot == guest) {
            void* h = g_iomap[i].host;
            pthread_mutex_unlock(&g_iomap_mu);
            return h;
        }
    }
    pthread_mutex_unlock(&g_iomap_mu);
    /* 没注册过 -- 当成已经是 host* (兼容老路径) */
    return guest;
}

/* fclose 调: 释放 slot, 返回真正的 host FILE* 给 host fclose */
void* box32_io_unregister(void* guest) {
    if (!guest) return NULL;
    uintptr_t v = (uintptr_t)guest;
    if (v == 1) return stderr;
    if (v == 2) return stdin;
    if (v == 3) return stdout;

    pthread_mutex_lock(&g_iomap_mu);
    for (int i = 0; i < BOX32_IOMAP_CAP; ++i) {
        if (g_iomap[i].guest_slot == guest) {
            void* h = g_iomap[i].host;
            box32_free(g_iomap[i].guest_slot);
            g_iomap[i].host       = NULL;
            g_iomap[i].guest_slot = NULL;
            g_iomap_used--;
            pthread_mutex_unlock(&g_iomap_mu);
            return h;
        }
    }
    pthread_mutex_unlock(&g_iomap_mu);
    return guest;
}
/* OHOS_PATCH_BOX32_IOMAP END */
