/* trace_shim.c —— 系统调用打点（只记**失败**的，日志才小得能看）
 *
 * 为什么要它：`code --ozone-platform=wayland` 崩在 Chromium 的 GPU/合成器初始化里，
 * 日志侧（--v=1/--v=3/定向 vmodule）已经穷尽 —— 始终只有 7 行，最后一行停在
 * ozone_platform_wayland.cc:278。也就是说崩在"不打日志的地方"。
 * 那就换个维度看：**把会失败的系统调用记下来**。如果崩因是"某个调用被沙箱拒绝"，
 * 崩前最后几条失败记录会直接指出来。
 *
 * 只记 rc<0 的：正常路径一条都不打，所以这个 shim 常开也不吵。
 * 开关 BSH_TRACE_SYS=1（未设就完全不工作，连 dlsym 都不做）。
 *
 * 覆盖面的实话：glibc 内部走的是 INTERNAL_SYSCALL（不经过 PLT），所以这里拦不到
 * glibc 自己的系统调用；能拦到的是 guest 程序直接调 syscall()/mmap()/mprotect()/
 * memfd_create() 的那部分 —— 对着"GPU 初始化"这个方向够用，因为我们关心的是
 * JIT（mmap/mprotect PROT_EXEC）和被拒的新式调用。
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

static int on(void) {
    static int cached = -1;
    if (cached < 0) cached = getenv("BSH_TRACE_SYS") ? 1 : 0;
    return cached;
}

static void t(const char *fmt, ...) {
    if (!on()) return;
    char buf[320];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > 0) { ssize_t w = write(2, buf, (size_t)n); (void)w; }
}

int mprotect(void *addr, size_t len, int prot) {
    static int (*real)(void *, size_t, int);
    if (!real) real = dlsym(RTLD_NEXT, "mprotect");
    int rc = real(addr, len, prot);
    if (rc < 0 && (prot & PROT_EXEC))
        t("[trace] mprotect(%p,%zu,prot=0x%x) 失败 errno=%d(%s)\n",
          addr, len, prot, errno, strerror(errno));
    return rc;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    static void *(*real)(void *, size_t, int, int, int, off_t);
    if (!real) real = dlsym(RTLD_NEXT, "mmap");
    void *rc = real(addr, len, prot, flags, fd, off);
    if (rc == MAP_FAILED && (prot & PROT_EXEC))
        t("[trace] mmap(len=%zu,prot=0x%x,flags=0x%x) 失败 errno=%d(%s)\n",
          len, prot, flags, errno, strerror(errno));
    return rc;
}

int memfd_create(const char *name, unsigned int flags) {
    static int (*real)(const char *, unsigned int);
    if (!real) real = dlsym(RTLD_NEXT, "memfd_create");
    int rc = real(name, flags);
    if (rc < 0)
        t("[trace] memfd_create(\"%s\",0x%x) 失败 errno=%d(%s)\n",
          name ? name : "", flags, errno, strerror(errno));
    return rc;
}

/* 注：`syscall()` 的 wrap 在 fs_shim.c 里已经有了（它在那边做路径映射相关的事），
 * 一个 .so 只能有一份定义，所以这里不重复。要加"失败才打点"的话，去 fs_shim.c 那个
 * wrap 里加（用本文件同样的 on()/t() 思路）—— 本轮先不做，避免动那个大文件。 */
