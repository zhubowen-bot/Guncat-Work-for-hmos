// shim/dlopen_shim.c — 让资源根(noexec)里的 .so 也能被 dlopen
//
// **症状**（2026-10-03 实测）：
//   pip 把 numpy 装进 $SYSROOT/python/lib/python3.12/site-packages/ 之后
//       import numpy
//     → "Error loading shared library .../_multiarray_umath.cpython-312-aarch64-linux-gnu.so:
//        No such file or directory"
//   文件明明在（ls/stat 都看得到），`ctypes.CDLL` 直接开同一条路径报 "No error information"。
//   而**同一个 so 放进 bundle libs**（/data/storage/el1/bundle/libs/arm64/）就能正常打开。
//   两者只差一点：app 数据目录（el2，资源根就在那里）**不给文件映射 PROT_EXEC** ——
//   内核/沙箱在 mmap 那一步就拒了，而任何动态加载器除了 mmap 没别的路可走。
//
// **为什么不能把文件搬过去**：bundle libs 是只读的（安装时写入），运行期塞不进东西。
// 于是只剩换加载器这一条：本 shim 把 dlopen 截下来，交给 `elfloader/elf_dl.cpp` 那个
// **进程内**装载器 —— 它把段读进匿名内存（不要求文件可执行）、自己走 RELA 重定位、
// 未定义符号从 `dlsym(RTLD_DEFAULT)` 兜（宿主里已加载的 libpython/libc/libc++ 都在）。
//
// 该补的两件事已经在 elf_dl.cpp 里补好：`DT_INIT`/`DT_INIT_ARRAY` 的执行（numpy 的
// 扩展有 2 个 init_array 项）。而 TLS 不用管 —— 本工具链走 **EMUTLS**
// （`__emutls_get_address` + `__emutls_v.*`，无 PT_TLS、无 TLS 重定位），
// 那套东西就是普通符号+普通重定位，elf_dl 天生支持。
//
// **用法**：只给 libpython.so 加
//     -Wl,--wrap=dlopen,--wrap=dlsym,--wrap=dlclose
//   （见 scripts/build_python.sh）。**不动** shim-wrap-flags.sh 的通用清单 ——
//   别的命令 so 没有"要加载资源根里的 .so"这个需求，不该被牵连进来。
//
// **语义差别**（如实记着）：
//   * RTLD_LOCAL/GLOBAL 不分：所有经我们加载的对象进同一张表、彼此可见。CPython 打开
//     扩展用的是 RTLD_LOCAL，我们做不到那么细（也没必要：numpy 的扩展本来就互相引用）。
//   * dlclose 不真卸：只让 handle 失效，段不 munmap（构造函数已经跑过，指针可能还被别人拿着）。
//   * 析构函数（DT_FINI/DT_FINI_ARRAY）不跑。
//   * 只处理"系统加载器失败"这一种情形 —— 能正常打开的一律走原生路径，行为不变。
//
// 诊断：BSH_DLOPEN_TRACE=1 时，每次成功转到 elf_dl 都打一行；失败**总是**打一行
// （否则只剩 CPython 那句 "No such file or directory"，什么都看不出来）。
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "elf_loader.h"     // elf_dlopen_mem / elf_dlsym / elf_dl_owns_handle / elf_dl_set_prefer_sym

/* 真实现由链接器的 `--wrap` 生成（对 libc 的直接引用，与搜索序无关） */
extern void *__real_dlopen(const char *, int);
extern void *__real_dlsym(void *, const char *);
extern int   __real_dlclose(void *);

static int trace_on(void)
{
    const char *v = getenv("BSH_DLOPEN_TRACE");
    return v && *v && v[0] != '0';
}

/* 读整个文件到内存（调用方 free）。 */
static void *read_all(const char *path, size_t *len_out)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 64) { close(fd); return NULL; }
    size_t len = (size_t)st.st_size;
    unsigned char *buf = (unsigned char *)malloc(len);
    if (!buf) { close(fd); return NULL; }
    size_t got = 0;
    while (got < len) {
        ssize_t r = read(fd, buf + got, len - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    if (got != len) { free(buf); return NULL; }
    *len_out = len;
    return buf;
}

static int ends_with(const char *s, const char *suf)
{
    size_t ls = strlen(s), lf = strlen(suf);
    return ls >= lf && strcmp(s + ls - lf, suf) == 0;
}

/* 把 PEP 600 的 `<dist>.libs/` 目录里那些库先装进来。
 *
 * 为什么需要：PyPI 上给 musl 编的轮子（numpy 的 musllinux 版就是）把 C++ 运行时与
 * BLAS 一起塞在 `<dist>.libs/` 里 —— `libstdc++-<hash>.so.6.0.33`、`libgcc_s-*.so.1`、
 * `libscipy_openblas64_-*.so`，并靠 RPATH 指过去。这些名字系统里一个都没有，
 * 不先把它们装进全局命名空间，`dlsym(RTLD_DEFAULT)` 就什么也解析不出来。
 *
 * 为什么用"扫目录"而不是读 RPATH：读 RPATH 得解析目标 so 的 PT_DYNAMIC，而这一层
 * 手里只有**路径**（镜像在 elf_dl 那边，函数签名里没带出来）；而 `.libs` 的位置是
 * PEP 600 定死的 —— 就在包目录的**兄弟**位置。从 so 所在目录向上找 4 级，每级看一眼
 * 有没有 `*.libs/`，两种情况（扩展在 `<pkg>/` 还是 `<pkg>/<sub>/`）都能覆盖。
 *
 * ⚠ 这些库同样落在 noexec 的资源根里，所以也必须由 elf_dl 装载，而不是 dlopen。
 */
static void preload_pep600_libs(const char *so_path)
{
    char dir[4096];
    size_t n = strlen(so_path);
    if (n >= sizeof dir) return;
    memcpy(dir, so_path, n + 1);

    for (int up = 0; up < 4; up++) {
        char *slash = strrchr(dir, '/');
        if (!slash) return;
        *slash = '\0';                                  /* 退到上一级 */

        DIR *d = opendir(dir);
        if (!d) continue;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (e->d_name[0] == '.' || !ends_with(e->d_name, ".libs")) continue;
            char ldir[4096];
            snprintf(ldir, sizeof ldir, "%s/%s", dir, e->d_name);
            DIR *ld = opendir(ldir);
            if (!ld) continue;
            struct dirent *le;
            while ((le = readdir(ld)) != NULL) {
                if (le->d_name[0] == '.') continue;
                if (!ends_with(le->d_name, ".so") && !strstr(le->d_name, ".so."))
                    continue;
                char lib[4096];
                snprintf(lib, sizeof lib, "%s/%s", ldir, le->d_name);
                size_t llen = 0;
                void *buf = read_all(lib, &llen);
                if (!buf) continue;
                if (trace_on())
                    fprintf(stderr, "[dlopen] 预装 wheel 自带库 %s\n", lib);
                elf_dlopen_mem(buf, llen, le->d_name);
                free(buf);
            }
            closedir(ld);
        }
        closedir(d);
    }
}

/* 把磁盘上的 .so 读进内存，交给进程内加载器。
 * open/read/fstat 走的是本 so 里的 fs_shim（模拟软链也能解析）。 */
static void *load_from_file(const char *path)
{
    /* 先把 wheel 自带的那批库（libstdc++/libgcc_s/OpenBLAS…）装进来，见上 */
    preload_pep600_libs(path);

    size_t len = 0;
    void *buf = read_all(path, &len);
    if (!buf) return NULL;
    const char *slash = strrchr(path, '/');
    /* elf_map_image 是把段**拷进**匿名映射的，所以出来之后这块内存就能还了 */
    void *h = elf_dlopen_mem(buf, len, slash ? slash + 1 : path);
    free(buf);
    return h;
}

/* ── 宿主自己的符号作用域 ────────────────────────────────────────────────
 *
 * 本文件是**编进宿主 so**的（libpython.so / libnode.so），所以 `dladdr` 自己身上
 * 一个函数就能拿到宿主的路径；再 `dlopen` 一次拿它当作用域 —— musl 认"已经加载"，
 * 返回同一个 handle（引用计数 +1，不会重跑构造）。
 *
 * 为什么需要：应用的全局作用域里可能有与宿主**同名但不同实现**的符号。
 * 实测 node：应用链了鸿蒙的 libace_napi.z.so（190 个 napi_*，给 ArkTS 用），
 * libnode.so 也导出 napi_*（145 个）；`dlsym(RTLD_DEFAULT)` 先命中前者，于是 addon
 * 的 napi_create_function 落到**别人的实现**上（返回码废、下一个调用就崩）。
 * 装上这个钩子后，addon 的符号先在宿主身上找，再退回全局作用域。
 *
 * 只在需要时才 dlopen（首次解析符号时），失败就当没这个钩子，行为退化成从前那样。 */

/* 前向声明：下面拿 dlopen 包装自己的地址当锚点，而它的定义在文件末尾。 */
void *__wrap_dlopen(const char *filename, int flags);

static void *host_scope(void)
{
    static void *h = NULL;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        Dl_info di;
        if (dladdr((void *)(uintptr_t)&__wrap_dlopen, &di) && di.dli_fname) {
            h = __real_dlopen(di.dli_fname, RTLD_NOW | RTLD_GLOBAL);
            if (trace_on())
                fprintf(stderr, "[dlopen] 宿主作用域 %s → %p\n", di.dli_fname, h);
        }
    }
    return h;
}

static void *prefer_from_host(const char *name)
{
    void *h = host_scope();
    return h ? __real_dlsym(h, name) : NULL;
}

/* 装载之前先把钩子装上：elf_dl 申请重定位时要用。构造器时机 = 本 so 被加载时，
 * 早于任何一次 dlopen。 */
__attribute__((constructor)) static void dlopen_shim_ctor(void)
{
    elf_dl_set_prefer_sym(prefer_from_host);
}

void *__wrap_dlopen(const char *filename, int flags)
{
    /* filename == NULL 是"取主程序自己的 handle"，没有"换个加载器"的余地 */
    if (!filename) return __real_dlopen(filename, flags);

    void *h = __real_dlopen(filename, flags);
    if (h) return h;

    /* 系统加载器失败。先把它的话留住 —— 下面再调 dlopen/dlerror 会把它冲掉。 */
    char syserr[256];
    const char *e = dlerror();
    snprintf(syserr, sizeof syserr, "%s", e ? e : "(no dlerror)");

    h = load_from_file(filename);
    if (h) {
        if (trace_on())
            fprintf(stderr, "[dlopen] %s: 系统 loader 失败(%s) → 已由 elf_dl 装载\n",
                    filename, syserr);
        return h;
    }
    fprintf(stderr, "[dlopen] %s: 系统 loader 失败(%s)，elf_dl 也没能装上\n",
            filename, syserr);
    return NULL;
}

void *__wrap_dlsym(void *handle, const char *name)
{
    if (elf_dl_owns_handle(handle)) return elf_dlsym(handle, name);
    return __real_dlsym(handle, name);
}

int __wrap_dlclose(void *handle)
{
    if (elf_dl_owns_handle(handle)) return 0;   /* 见文件头：不真卸 */
    return __real_dlclose(handle);
}
