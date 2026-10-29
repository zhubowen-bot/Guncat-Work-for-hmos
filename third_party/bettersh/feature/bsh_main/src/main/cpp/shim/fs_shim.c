// fs_shim.c — 用户态"符号链接"模拟(LD_PRELOAD 版),给禁止 symlink(2) 的沙箱用。
//
// 为什么要有这个文件
// ──────────────────
// 这台 HarmonyOS 设备的沙箱**禁止创建符号链接**:symlink()/symlinkat() 在宿主进程、
// 命令 so、guest 三层、所有可写目录里都被拒(errno=13 EACCES,偶尔 ENOENT),
// 失败后用 lstat 复核,链接确实没建出来(返回 ENOENT)。硬链接是允许的(link() 成功、
// 两边同一个 inode)。所以 "tar 解包含软链""npm/pip 装包建软链""python 的 venv 建
// bin/python3 软链" 这类操作在设备里必然失败 —— 不是权限配错,是这一层能力就没有。
//
// 表示法(本项目自己定的规格,不是 Linux 的语义)
// ────────────────────────────────────────────
//   "软链接 foo -> /target/path" 在真实文件系统上表现为一个**普通文件**:
//       foo.BSH_SYMLINK      内容 = 目标路径串(不含结尾 NUL,长度 1..4095)
//   而 foo 这个真实名字**不存在**。好处是目录里一个链接只占一个真实目录项、不重名,
//   所以列举目录时只需"改名",不需要"隐藏"任何东西 —— 这一点决定了 readdir 的实现
//   可以非常轻(见下面 readdir 那一段)。
//
// 生效方式
// ────────
// 以 LD_PRELOAD 载入,导出与 libc 同名的入口。**不关我们事的路径一律原样透传**给
// 真正的 libc 实现(经 dlsym(RTLD_NEXT, ...) 取一次并缓存),这样对没碰过我们链接的
// 程序是完全透明的。
//
// 已知限制(照实写,不试图绕)
// ──────────────────────────
//   * musl **静态**链接的 guest 里 dlsym(RTLD_NEXT) 不可用(没有动态符号表),
//     本模块在那里整只失效;动态 guest(musl 动态 / glibc)与宿主进程正常。
//   * 绕过 readdir 的目录遍历看不到改名:glibc 的 scandir/fts/glob、musl 的同名函数
//     内部走的是**库内直接调用**,LD_PRELOAD 拦不到,它们会把 *.BSH_SYMLINK 当成普通
//     文件。详见 README「已知限制」。
//   * 带真实 dirfd(非 AT_FDCWD)的 *at 入口靠 /proc/self/fd/<n>/ 规范化,没有 procfs
//     时直接透传(此时中间目录里的模拟链接不会被展开)。
//
// 编译:见 README.md(glibc 与 musl 都要能过,-std=gnu11)

#define _GNU_SOURCE 1

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>

#include "shim_wrap.h"
#include <stdarg.h>
#include <stddef.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

// ───────────────────────────── 规格常量 ─────────────────────────────

// 标记文件的后缀。链接本身的名字 = 去掉后缀;标记文件的名字 = 加后缀。
#define BSH_SUFFIX     ".BSH_SYMLINK"
#define BSH_SUFFIX_LEN (sizeof(BSH_SUFFIX) - 1)

// 目标串长度上限。真 symlink(2) 在 Linux 上也是"target 长度 > PATH_MAX-1 →
// ENAMETOOLONG"(实测 4095 可以、5999 给 ENAMETOOLONG),这里取同一个界。
#define BSH_MAX_TARGET 4095

// 展开跳数上限。内核的真符号链接上限是 40;规格要求 8,故意更严。
#define BSH_MAX_HOPS 8

// 路径缓冲长度。PATH_MAX=4096、路径串最长 4095,取 4096 正好一个 PATH_MAX;
// 任何超出的中间结果都按 ENAMETOOLONG 处理 —— 内核也存不下更长的路径,口径一致。
#define BSH_BUF 4096

// "本会话里出现过模拟链接吗"。box64 模式（`-DBSH_SHIM_BOX64`）拿它做**快路径门**：
// 每次 open/stat 都要逐组件 lstat 一遍才能知道有没有标记文件，代价不小；进程从没建过、
// 也没见过标记时（绝大多数进程、绝大多数时间）整层直接跳过。一旦发生过就置 1 并保持 ——
// 与"内核里现在有没有链接"无关，只是保守的启发式。
// 非 box64 模式也照样置位（没有读者，编译器可能提示 set-but-unused，无害）。
static int g_marker_seen = 0;

// ─────────────────────────── 真实现的取用 ───────────────────────────
//
// 每个入口第一次用到时取一次真实现并缓存在静态里（`BSH_REAL(ptr, name)`，见
// shim_wrap.h）。取不到(例如静态进程)就当 ENOSYS 报错,而不是去调自己(那会无限递归)。
//
// 取法取决于本模块怎么被装配，这正是 shim_wrap.h 讲的那两种模式：
//
//   guest 侧（LD_PRELOAD，符号插入）：`dlsym(RTLD_NEXT, …)` —— 预载把本 .so 放在
//     搜索序**最前**，"下一个"才是 libc。已实测可用。
//
//   命令 so 侧（`-Wl,--wrap=`，链接期替换）：真实现是链接器生成的 `__real_<名>`
//     （对 libc 的直接引用，跟搜索序无关）。下面 `shim_real_*` 那一组薄包装就是把
//     `__real_<名>` 包成与函数指针类型一致的形状（openat/fopen 这些可变参数的必须包
//     一层才能取地址后按原样调）。**不能用 RTLD_NEXT**：命令 so 是主进程 dlopen 进来
//     的、排在全局搜索序末尾，"下一个"之后什么都没有 → 返回 NULL → 每个入口都退化成
//     ENOSYS（实测：编进 libtoybox 后每个文件操作都报 "Function not implemented"）。

static int (*r_openat)(int, const char*, int, ...);
static int (*r_fstatat)(int, const char*, struct stat*, int);
static int (*r_stat)(const char*, struct stat*);
static int (*r_lstat)(const char*, struct stat*);
static ssize_t (*r_readlink)(const char*, char*, size_t);
static ssize_t (*r_readlinkat)(int, const char*, char*, size_t);
static int (*r_symlink)(const char*, const char*);
static int (*r_symlinkat)(const char*, int, const char*);
static int (*r_unlinkat)(int, const char*, int);
static int (*r_rename)(const char*, const char*);
static int (*r_faccessat)(int, const char*, int, int);
static char* (*r_realpath)(const char*, char*);
static DIR* (*r_opendir)(const char*);
static struct dirent* (*r_readdir)(DIR*);
static int (*r_scandir)(const char*, struct dirent***,
                        int (*)(const struct dirent*),
                        int (*)(const struct dirent**, const struct dirent**));
static long (*r_syscall)(long, ...);
static int (*r_linkat)(int, const char*, int, const char*, int);

#ifdef BSH_SHIM_WRAP
/* 命令 so 模式：真实现 = 链接器给的 __real_<名>。可变参数的（openat/fopen 一族）
 * 必须包一层同签名函数才能取地址。 */
#include <stdarg.h>
extern int __real_openat(int, const char*, int, ...);
extern int __real_fstatat(int, const char*, struct stat*, int);
extern int __real_stat(const char*, struct stat*);
extern int __real_lstat(const char*, struct stat*);
extern ssize_t __real_readlink(const char*, char*, size_t);
extern ssize_t __real_readlinkat(int, const char*, char*, size_t);
extern int __real_symlink(const char*, const char*);
extern int __real_symlinkat(const char*, int, const char*);
extern int __real_unlinkat(int, const char*, int);
extern int __real_rename(const char*, const char*);
extern int __real_faccessat(int, const char*, int, int);
extern char* __real_realpath(const char*, char*);
extern DIR* __real_opendir(const char*);
extern struct dirent* __real_readdir(DIR*);
extern int __real_scandir(const char*, struct dirent***,
                          int (*)(const struct dirent*),
                          int (*)(const struct dirent**, const struct dirent**));
extern long __real_syscall(long, ...);
extern int __real_linkat(int, const char*, int, const char*, int);

static int shim_real_openat(int dirfd, const char* p, int flags, ...) {
    va_list ap; va_start(ap, flags);
    int mode = va_arg(ap, int);
    va_end(ap);
    return __real_openat(dirfd, p, flags, mode);
}
static int shim_real_fstatat(int d, const char* p, struct stat* st, int f) { return __real_fstatat(d, p, st, f); }
static int shim_real_stat(const char* p, struct stat* st) { return __real_stat(p, st); }
static int shim_real_lstat(const char* p, struct stat* st) { return __real_lstat(p, st); }
static ssize_t shim_real_readlink(const char* p, char* b, size_t n) { return __real_readlink(p, b, n); }
static ssize_t shim_real_readlinkat(int d, const char* p, char* b, size_t n) { return __real_readlinkat(d, p, b, n); }
static int shim_real_symlink(const char* t, const char* l) { return __real_symlink(t, l); }
static int shim_real_symlinkat(const char* t, int d, const char* l) { return __real_symlinkat(t, d, l); }
static int shim_real_unlinkat(int d, const char* p, int f) { return __real_unlinkat(d, p, f); }
static int shim_real_rename(const char* a, const char* b) { return __real_rename(a, b); }
static int shim_real_faccessat(int d, const char* p, int m, int f) { return __real_faccessat(d, p, m, f); }
static char* shim_real_realpath(const char* p, char* r) { return __real_realpath(p, r); }
static DIR* shim_real_opendir(const char* p) { return __real_opendir(p); }
static struct dirent* shim_real_readdir(DIR* d) { return __real_readdir(d); }
static int shim_real_scandir(const char* p, struct dirent*** l,
                             int (*f)(const struct dirent*),
                             int (*c)(const struct dirent**, const struct dirent**)) {
    return __real_scandir(p, l, f, c);
}
static long shim_real_syscall(long n, ...) {
    va_list ap; va_start(ap, n);
    long a1 = va_arg(ap, long), a2 = va_arg(ap, long), a3 = va_arg(ap, long);
    long a4 = va_arg(ap, long), a5 = va_arg(ap, long), a6 = va_arg(ap, long);
    va_end(ap);
    return __real_syscall(n, a1, a2, a3, a4, a5, a6);
}
static int shim_real_linkat(int od, const char* op, int nd, const char* np, int f) { return __real_linkat(od, op, nd, np, f); }

/* stdio 那两个（fopen/freopen）也是库函数，同样走 __real_* */
extern FILE* __real_fopen(const char*, const char*);
extern FILE* __real_freopen(const char*, const char*, FILE*);
static FILE* shim_real_fopen(const char* p, const char* m) { return __real_fopen(p, m); }
static FILE* shim_real_freopen(const char* p, const char* m, FILE* s) { return __real_freopen(p, m, s); }
#endif

// glibc 给 stat/lstat/opendir 的 path 标的 __nonnull,让 "直接写 !path" 触发
// -Wnonnull-compare。预载层确实可能收到别处手工构造的 NULL,这层防御要留;
// 用一个不内联的小函数做判断,警告就没有了,检查也不会被优化掉。
static __attribute__((noinline)) int bsh_is_null(const void* p) { return p == NULL; }

// ─────────────────────────── 名字 / 拼串小工具 ───────────────────────────

// 只看**最后一段**(basename):是否以我们的后缀结尾。
// 要求名字比后缀本身长 —— ".BSH_SYMLINK" 单独一个名字不是链接(去掉后缀是空名)。
static int name_has_suffix(const char* path) {
    const char* base = strrchr(path, '/');
    base = base ? base + 1 : path;
    size_t n = strlen(base);
    if (n <= BSH_SUFFIX_LEN) return 0;
    return memcmp(base + n - BSH_SUFFIX_LEN, BSH_SUFFIX, BSH_SUFFIX_LEN) == 0;
}

// 由链接名算出标记文件名:本身已经带后缀就用它,否则加后缀。
// 失败(太长,内核存不下这个路径)返回 -1 / ENAMETOOLONG。
static int marker_name(const char* path, char* out, size_t outsz) {
    size_t n = strlen(path);
    if (name_has_suffix(path)) {
        if (n + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
        memcpy(out, path, n + 1);
        return 0;
    }
    if (n + BSH_SUFFIX_LEN + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
    memcpy(out, path, n);
    memcpy(out + n, BSH_SUFFIX, BSH_SUFFIX_LEN + 1);
    return 0;
}

static int cat_raw(char* buf, size_t* len, size_t cap, const char* s, size_t slen) {
    if (*len + slen + 1 > cap) return -1;
    memcpy(buf + *len, s, slen);
    *len += slen;
    buf[*len] = 0;
    return 0;
}

// 按需补一个 '/'。len==0 时**不补** —— 相对路径不能因为拼串变成绝对路径。
static int cat_sep(char* buf, size_t* len, size_t cap) {
    if (*len == 0 || buf[*len - 1] == '/') return 0;
    if (*len + 2 > cap) return -1;
    buf[(*len)++] = '/';
    buf[*len] = 0;
    return 0;
}

// out = dir + "/" + base 的朴素拼接(不解析 dir 里已有的 '/' 结尾)。
static int join2(const char* dir, const char* base, char* out, size_t outsz) {
    size_t nl = 0;
    out[0] = 0;
    if (cat_raw(out, &nl, outsz, dir, strlen(dir)) < 0) return -1;
    if (cat_sep(out, &nl, outsz) < 0) return -1;
    if (cat_raw(out, &nl, outsz, base, strlen(base)) < 0) return -1;
    return 0;
}

// 把 path 切成"目录部分 + 最后一段"。最后一段为空(尾斜杠)或整个 path 为空时返回 -1,
// 调用者据此原样透传(不去改内核本来就有的语义)。
static int split_last(const char* path, char* dir, size_t dirsz, const char** base) {
    const char* s = strrchr(path, '/');
    if (!s) {
        if (*path == 0) return -1;
        if (strlen(".") + 1 > dirsz) return -1;
        strcpy(dir, ".");
        *base = path;
        return 0;
    }
    if (s[1] == 0) return -1;                    // 尾斜杠
    *base = s + 1;
    size_t dl = (size_t)(s - path);
    if (dl == 0) {
        if (dirsz < 2) return -1;
        strcpy(dir, "/");
        return 0;
    }
    if (dl + 1 > dirsz) return -1;
    memcpy(dir, path, dl);
    dir[dl] = 0;
    return 0;
}

// ─────────────────────────── 标记文件的读 ───────────────────────────

// 读标记文件内容(就是目标串)。成功返回长度(1..4095)且 out 已 NUL 收尾。
// 内容为空或超过 4095 → ENAMETOOLONG(表示法被破坏,不是链接)。
static ssize_t read_marker(const char* marker, char* out, size_t outsz) {
    int (*fa)(int, const char*, int, ...) = BSH_REAL(r_openat, openat);
    if (!fa) { errno = ENOSYS; return -1; }
    int fd = fa(AT_FDCWD, marker, O_RDONLY | O_CLOEXEC | O_NOFOLLOW, 0);
    if (fd < 0) return -1;
    char tmp[BSH_MAX_TARGET + 1];
    ssize_t n;
    for (;;) {
        n = read(fd, tmp, sizeof tmp);
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    int saved = errno;
    close(fd);
    errno = saved;
    if (n < 0) return -1;
    if (n == 0 || n > BSH_MAX_TARGET) { errno = ENAMETOOLONG; return -1; }
    if ((size_t)n + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
    memcpy(out, tmp, (size_t)n);
    out[n] = 0;
    return n;
}

// ─────────────────────── "这条路径是不是我们的链接" ───────────────────────
//
// 便宜且明确的判据(就是规格里那两条):
//   a) 最后一段本身以 .BSH_SYMLINK 结尾且是**普通文件** → 标记文件就是它自己;
//   b) 否则 <path>.BSH_SYMLINK 是普通文件 → 标记文件是那个。
// 返回 1(是,marker 已填)、0(不是)、-1(出错,errno 已设)。
//
// 只认普通文件:同名目录 / 真符号链接不算我们的标记,免得把用户自己的东西吞掉。
// 若 a) b) 同时成立(真实文件与标记同名共存)让标记优先 —— 那是我们的 symlink()
// 会拒绝的非法状态,真出现了按"链接语义优先"处理。
static int is_simlink(const char* path, char* marker, size_t markersz) {
    int (*fl)(const char*, struct stat*) = BSH_REAL(r_lstat, lstat);
    if (!fl) { errno = ENOSYS; return -1; }

    if (name_has_suffix(path)) {
        struct stat st;
        if (fl(path, &st) == 0 && S_ISREG(st.st_mode)) {
            if (strlen(path) + 1 > markersz) { errno = ENAMETOOLONG; return -1; }
            strcpy(marker, path);
            g_marker_seen = 1;
            return 1;
        }
    }

    char m[BSH_BUF];
    if (marker_name(path, m, sizeof m) < 0) {
        // 加后缀之后超出 PATH_MAX → 这个标记文件在内核里根本不可能存在,
        // 所以"不是链接",而不是"出错"。
        return 0;
    }
    struct stat st;
    if (fl(m, &st) == 0 && S_ISREG(st.st_mode)) {
        if (strlen(m) + 1 > markersz) { errno = ENAMETOOLONG; return -1; }
        strcpy(marker, m);
        g_marker_seen = 1;
        return 1;
    }
    return 0;
}

// ─────────────────────────── (dirfd, path) 规范化 ───────────────────────────

static int resolve_simlinks(const char* path, char* out, size_t outsz);

// /proc/self/fd 是否可用(用来把真实 dirfd 变成可解析的路径)。只探一次。
static int proc_available(void) {
    static int cached = -1;
    if (cached < 0) {
        int (*fl)(const char*, struct stat*) = BSH_REAL(r_lstat, lstat);
        struct stat st;
        cached = (fl && fl("/proc/self/fd", &st) == 0) ? 1 : 0;
    }
    return cached;
}

// 把 (dirfd, path) 变成一条自足的路径,供后面的解析用。
// 返回 0 成功(out 已填)、1 无法规范化(调用者应原样透传)、-1 出错。
// 注意:AT_FDCWD 的相对路径**不做** chdir 展开 —— 相对路径一直保持相对,
// 交给内核按当前工作目录解析,行为与不预载时完全一致。
static int norm_at(int dirfd, const char* path, char* out, size_t outsz) {
    if (path[0] == '/' || dirfd == AT_FDCWD) {
        size_t n = strlen(path);
        if (n + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
        memcpy(out, path, n + 1);
        return 0;
    }
    if (!proc_available()) return 1;
    int n = snprintf(out, outsz, "/proc/self/fd/%d/%s", dirfd, path);
    if (n < 0 || (size_t)n >= outsz) { errno = ENAMETOOLONG; return -1; }
    return 0;
}

// ─────────────────── /proc/self/exe 的替身（BSH_GUEST_EXE） ───────────────────
//
// guest 是"别人的二进制"，由 elfloader 在**宿主进程里**装载执行，所以内核看到的
// /proc/self/exe 是宿主的 appspawn，不是 guest 自己。而"自省自己是谁"这件事全靠它：
// 找自己的安装目录（$ORIGIN 的另一半）、重新 exec 自己、读自己的镜像校验和……
// 不修的话，像设备侧 hdc 那种"读 /proc/self/exe 再 fork/exec 自身"的程序在沙箱里必死
// （实测：一碰这条路径就被沙箱以 SIGSYS(31) 打杀，rc=159，连输出都没有）。
//
// 真值由 procmgr 在装载前放进环境变量 BSH_GUEST_EXE（见 procmgr.cpp 的 ChildRunElf），
// 这里只做**符号层**的替换：凡是被本 shim 接管的那批路径入口（readlink/stat/lstat/
// open/access/fopen/realpath…）看到这条路径就换成真值。
// 未设 BSH_GUEST_EXE（命令 so 侧、宿主自己跑、qemu 下跑 guest）时整层失效，全走原样。
//
// 边界（照实写，不试图绕）：
//   1) guest 的 **ld.so 内部**读 /proc/self/exe 去算 $ORIGIN，LD_PRELOAD 拦不到 ——
//      所以 procmgr 那边"把 guest 同目录加进 LD_LIBRARY_PATH"的兜底仍然必须保留；
//   2) 静态链接的 guest 没有 preload，吃不到这个替身；
//   3) unlink/rename/link **不做**替换：真 Linux 对 /proc/self/exe 的 unlink 就是 EPERM，
//      替换了反而会去删 guest 自己的镜像（它们走 last_component_cand/norm_at，本层只在
//      resolve_simlinks 与 do_readlink 生效，正是为此）。
#define BSH_EXE_PATH "/proc/self/exe"

/* ── 可选追踪（BSH_SHIM_TRACE=1）────────────────────────────────────────────
 * 这一层最烦的故障形态是"看着该生效、实际没生效"，而它又没有返回值可看。
 * 打开这个开关就把关键判定打到 stderr（被预载时进 guest 的 stderr，也就是终端）。
 * 不设变量时只有首次一次 getenv，之后走缓存。 */
static int bsh_trace_on(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BSH_SHIM_TRACE");
        cached = (v && *v && v[0] != '0') ? 1 : 0;
    }
    return cached;
}

static void bsh_trace(const char* fmt, ...) {
    if (!bsh_trace_on()) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > 0) {
        size_t len = ((size_t)n < sizeof buf) ? (size_t)n : sizeof buf - 1;
        ssize_t w = write(STDERR_FILENO, buf, len);
        (void)w;
    }
}

/* 取一次真值并缓存（环境变量在进程生命周期里不会变）。空串当没设。 */
static const char* guest_exe(void) {
    static const char* cached;
    static int inited;
    if (!inited) {
        const char* v = getenv("BSH_GUEST_EXE");
        cached = (v && *v) ? v : NULL;
        inited = 1;
    }
    return cached;
}

/* path 是不是 /proc/self/exe（或它的子路径 /proc/self/exe/…）。
 * 命中：*rest 指向**调用方那个字符串**里的余下部分（子路径时为 "/…"，否则为 ""），返回 1；
 * 不是它返回 0。
 * ⚠ 这里**绝不能**把 path 拷进局部数组再把指针交出去 —— 那是 use-after-return，
 *   glibc 下侥幸能用、musl 下栈一被覆盖就变成"不匹配"，症状是"glibc guest 全过、
 *   musl guest 一条都不生效"（实测踩过）。所以直接在原串上比对。
 * 尾随的 '/' 一律视作"就是它自己"（内核那边 "/proc/self/exe/" 对文件是 ENOTDIR，
 * 这里按更实用的语义处理）。 */
static int virt_exe_split(const char* path, const char** rest) {
    if (!path || path[0] != '/') return 0;
    static const char kPre[] = BSH_EXE_PATH;
    const size_t kl = sizeof(kPre) - 1;
    if (strncmp(path, kPre, kl) != 0) return 0;
    const char* p = path + kl;
    if (*p == '\0') { *rest = ""; return 1; }
    if (*p != '/') return 0;                 // "/proc/self/exeXXX" 不是它
    const char* q = p;
    while (*q == '/') q++;
    if (*q == '\0') { *rest = ""; return 1; } // 只有尾随斜杠
    *rest = p;                                // "/…"（余下部分，含前导 '/'）
    return 1;
}

/* 把 /proc/self/exe[子路径] 换成 guest 真值（+余下部分）。命中返回 1，不是它返回 0，
 * 名字太长返回 -1（errno=ENAMETOOLONG）。 */
static int virt_exe_path(const char* path, char* out, size_t outsz) {
    const char* gx = guest_exe();
    if (!gx) return 0;
    const char* rest;
    if (!virt_exe_split(path, &rest)) return 0;
    int n = snprintf(out, outsz, "%s%s", gx, rest);
    if (n < 0 || (size_t)n >= outsz) { errno = ENAMETOOLONG; return -1; }
    return 1;
}

/* 只认"/proc/self/exe"本身（不含子路径）——readlink 要的是"链接目标"，子路径不是链接。 */
static int virt_exe_self(const char* path, char* out, size_t outsz) {
    const char* gx = guest_exe();
    if (!gx) return 0;
    const char* rest;
    if (!virt_exe_split(path, &rest) || rest[0] != '\0') return 0;
    size_t n = strlen(gx);
    if (n + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
    memcpy(out, gx, n + 1);
    return 1;
}

/* 伪造的"符号链接" stat —— **不用了**，留在这里只有一个理由：说明为什么不需要。
 * 真 procfs 里 /proc/self/exe 是**魔法链接**，lstat 无论指向谁都是同一个形状
 * （mode=S_IFLNK|0777、size=0、nlink=1，dev/ino 属于 procfs）。所以直通真 lstat 就已经
 * 是对的；自己合成一份反而会把 st_dev/st_ino 换成"本体文件"的（本机实测真 Linux 给的是
 * procfs 的 ino，两者不同）。第一版实现写了个合成版本，后来发现不如真实现忠实，撤掉。 */

// ─────────────────────────── 递归解析 ───────────────────────────
//
// 逐段走:每一段都先看是不是模拟链接;是就把目标拼进待解析串,从头再来。
// 关键设计:**不自己折叠 "." / ".."**,只做拼接、把结果原样交给内核。
//   理由:内核是权威。比如 stat("nodir/../x") 真实现给 ENOENT(因为 nodir 不存在),
//   自己把 ".." 弹掉就变成 stat("x")、可能反而成功。让 ".." 原样留在串里,
//   内核自己会按它该有的顺序解析。
// 目标串长度、跳数都有上限;超了分别给 ENAMETOOLONG / ELOOP(和真链接同 errno)。
/* ── 路径映射表 ────────────────────────────────────────────────────────────
 * 把 guest 里「编译期被硬编码、而沙箱的只读根里并不存在」的绝对路径，改到我们的目录。
 * 目前只有一项：
 *   /usr/share/X11/xkb —— libxkbcommon 把 include path 硬编码成这个（实测**不认**
 *   XKB_CONFIG_ROOT）。guest 的 / 是只读 app 根，目录不存在 → "failed to add default
 *   include path" → 随后在 xkb_context_include_path_* 里踩空，SIGSEGV(139)，进程约 3 秒死。
 * 放在这里（而不是另做一个 preload）是因为本函数是整条路径的公共入口。
 * 加项时注意：`to_rel` 是相对 $BSH_SYSROOT 的路径。 */
static const struct { const char* from; const char* to_rel; } kPathMap[] = {
    /* 顺序匹配、命中即返回 —— 具体项放前面，兜底项放最后 */
    { "/usr/share/X11/xkb", "usr/share/x11/xkb" },
    /* guest 里**没有真正的根文件系统**，`/usr/...` 这种绝对路径在宿主上不存在。
     * apt 装的 deb 里大量这么写：code-server 的 `usr/bin/code-server` 就是
     *     exec /usr/lib/code-server/bin/code-server "$@"
     * mksh 在执行 exec 之前会自己 stat 一次路径，映不过去就只报
     * "inaccessible or not found"，连 execve 都到不了（procmgr 那层的回退也就够不着）。
     * 这一条兜住全部 /usr/**，粒度最粗所以放最后。 */
    { "/usr", "usr" },
};

static const char* map_path(const char* path, char* buf, size_t bufsz) {
    const char* root = getenv("BSH_SYSROOT");
    if (!root || !*root || !path) return path;
    for (size_t i = 0; i < sizeof kPathMap / sizeof kPathMap[0]; i++) {
        size_t n = strlen(kPathMap[i].from);
        if (strncmp(path, kPathMap[i].from, n) != 0) continue;
        if (path[n] != '\0' && path[n] != '/') continue;   /* /usr/share/X11/xkbevil 别误伤 */
        snprintf(buf, bufsz, "%s/%s%s", root, kPathMap[i].to_rel, path + n);
        bsh_trace("[shim] map_path: %s -> %s\n", path, buf);
        return buf;
    }
    return path;
}

static int resolve_simlinks(const char* path, char* out, size_t outsz) {
    /* 先过路径映射表（见 kPathMap），再做 /proc/self/exe 替身与软链解析。 */
    char mapped[BSH_BUF];
    {
        const char* mp = map_path(path, mapped, sizeof mapped);
        if (mp != path) path = mp;
    }
    /* /proc/self/exe 的替身（见上面那段）：先换成 guest 真值，再按老规矩解析软链。
     * 放在这里是因为本函数是"整条路径"的公共入口 —— stat/realpath/open/access/
     * fopen 都从它下面过。 */
    char virt[BSH_BUF];
    {
        int vr = virt_exe_path(path, virt, sizeof virt);
        bsh_trace("[shim] resolve_simlinks(%s) virt=%d\n", path, vr);
        if (vr < 0) return -1;
        if (vr == 1) path = virt;
    }
    char work[BSH_BUF];
    size_t plen = strlen(path);
    if (plen >= sizeof work) { errno = ENAMETOOLONG; return -1; }
    memcpy(work, path, plen + 1);

    unsigned hops = 0;
    for (;;) {
        char acc[BSH_BUF];              // 已接受的前缀(链接所在目录就是这个值)
        size_t acclen = 0;
        acc[0] = 0;
        // 绝对路径的前缀从 "/" 起步 —— 少了这一句,"/bin/sh" 会被拼成 "bin/sh"
        // (cat_sep 在 len==0 时故意不补 '/',那是为了相对路径)。
        if (work[0] == '/') { acc[0] = '/'; acc[1] = 0; acclen = 1; }

        const char* p = work;
        int restart = 0;
        while (*p) {
            while (*p == '/') p++;
            if (!*p) break;
            const char* seg = p;
            while (*p && *p != '/') p++;
            size_t seglen = (size_t)(p - seg);

            char cand[BSH_BUF];         // acc + "/" + seg
            size_t cl = 0;
            cand[0] = 0;
            if (cat_raw(cand, &cl, sizeof cand, acc, acclen) < 0 ||
                cat_sep(cand, &cl, sizeof cand) < 0 ||
                cat_raw(cand, &cl, sizeof cand, seg, seglen) < 0) {
                errno = ENAMETOOLONG;
                return -1;
            }

            char marker[BSH_BUF];
            int r = is_simlink(cand, marker, sizeof marker);
            if (r < 0) return -1;
            if (r == 0) {
                memcpy(acc, cand, cl + 1);
                acclen = cl;
                continue;
            }

            // 命中一个模拟链接:目标串接上剩余部分,重新从头解析。
            char target[BSH_BUF];
            ssize_t tl = read_marker(marker, target, sizeof target);
            if (tl < 0) return -1;
            if (++hops > BSH_MAX_HOPS) { errno = ELOOP; return -1; }

            char next[BSH_BUF];
            size_t nl = 0;
            next[0] = 0;
            int bad;
            if (target[0] == '/') {
                bad = cat_raw(next, &nl, sizeof next, target, (size_t)tl) < 0;
            } else {
                // 相对目标:相对于链接**所在目录**(就是 acc;acc 为空表示相对路径的开头)
                bad = cat_raw(next, &nl, sizeof next, acc, acclen) < 0 ||
                      cat_sep(next, &nl, sizeof next) < 0 ||
                      cat_raw(next, &nl, sizeof next, target, (size_t)tl) < 0;
            }
            // p 指着链接后面的那一段('\0' 或 '/...'),原样接回去
            size_t restlen = strlen(p);
            if (!bad && restlen) bad = cat_raw(next, &nl, sizeof next, p, restlen) < 0;
            if (bad) { errno = ENAMETOOLONG; return -1; }

            memcpy(work, next, nl + 1);
            restart = 1;
            break;
        }

        if (!restart) {
            // 保留尾斜杠语义(stat("dir/") 与 stat("dir") 在内核里不等价)
            size_t wl = strlen(work);
            if (wl > 1 && work[wl - 1] == '/') {
                if (cat_raw(acc, &acclen, sizeof acc, "/", 1) < 0) { errno = ENAMETOOLONG; return -1; }
            }
            if (acclen + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
            memcpy(out, acc, acclen + 1);
            return 0;
        }
    }
}

// 解析整条路径(dirfd 版本)。changed=0 表示没碰到我们的链接,调用者应原样透传;
// changed=1 表示 out 是解析结果。
static int resolve_at(int dirfd, const char* path, char* out, size_t outsz, int* changed) {
    char norm[BSH_BUF];
    int nr = norm_at(dirfd, path, norm, sizeof norm);
    if (nr != 0) return nr;                       // 1=透传, -1=错

    char res[BSH_BUF];
    if (resolve_simlinks(norm, res, sizeof res) < 0) return -1;
    if (strcmp(res, norm) == 0) { *changed = 0; return 0; }
    if (strlen(res) + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
    strcpy(out, res);
    *changed = 1;
    return 0;
}

// "最后一段不跟随"的候选路径:前面的组件按模拟链接展开,最后一段原样留着。
// readlink / lstat / open(O_NOFOLLOW) / unlink / rename 都建立在这个视图上。
// 返回 0(成功,is_link=m 已填)、1(无法规范化,应透传)、-1(错)。
static int last_component_cand(int dirfd, const char* path,
                               char* cand, size_t candsz,
                               char* marker, size_t markersz, int* is_link) {
    char norm[BSH_BUF];
    int nr = norm_at(dirfd, path, norm, sizeof norm);
    if (nr != 0) return nr;

    char dir[BSH_BUF];
    const char* base;
    if (split_last(norm, dir, sizeof dir, &base) < 0) return 1;

    char dirr[BSH_BUF];
    if (resolve_simlinks(dir, dirr, sizeof dirr) < 0) return -1;
    if (join2(dirr, base, cand, candsz) < 0) { errno = ENAMETOOLONG; return -1; }

    int r = is_simlink(cand, marker, markersz);
    if (r < 0) return -1;
    *is_link = r;
    return 0;
}

// ─────────────────────────── 伪造链接的 struct stat ───────────────────────────

// 真符号链接的 lstat:mode=S_IFLNK|0777、size=目标串长度、nlink=硬链接数、
// blocks=0(快符号链接不占磁盘块)、blksize=4096。这里逐项对齐,
// 除了 st_dev/st_ino/属主/时间戳沿用标记文件自己的(它就代表这个链接的 inode)。
static int fill_link_stat(const char* marker, struct stat* buf) {
    int (*fl)(const char*, struct stat*) = BSH_REAL(r_lstat, lstat);
    if (!fl) { errno = ENOSYS; return -1; }
    struct stat real;
    if (fl(marker, &real) != 0) return -1;

    char target[BSH_BUF];
    ssize_t tl = read_marker(marker, target, sizeof target);
    if (tl < 0) return -1;

    memcpy(buf, &real, sizeof real);
    buf->st_mode = S_IFLNK | 0777;
    buf->st_size = (off_t)tl;
    buf->st_blocks = 0;
    buf->st_blksize = 4096;
    return 0;
}

// ─────────────────────────── symlink / symlinkat ───────────────────────────

// 建链接:写一个内容为目标串的标记文件。语义对齐真 symlink(2):
//   真实 link 名已存在 → EEXIST(真 symlink 也是 EEXIST,不区分是文件还是目录)
//   标记文件已存在     → EEXIST(O_CREAT|O_EXCL 原子拿到的)
//   目标为空           → ENOENT(实测 Linux symlink("") 给 ENOENT)
//   目标 > 4095        → ENAMETOOLONG(同 Linux)
// 目录缺失 / 只读 / 无权限 等,都由真正的 open 给出与内核一致的 errno。
static int do_symlink(int dirfd, const char* target, const char* linkpath) {
    if (!target || !linkpath) { errno = EFAULT; return -1; }
    size_t tl = strlen(target);
    if (tl == 0) { errno = ENOENT; return -1; }
    if (tl > BSH_MAX_TARGET) { errno = ENAMETOOLONG; return -1; }

    // 链接名(和它所在的目录)里可能也有模拟链接 —— 先摆正位置,再建标记。
    char cand[BSH_BUF], oldmarker[BSH_BUF];
    int isl = 0;
    int r = last_component_cand(dirfd, linkpath, cand, sizeof cand,
                                oldmarker, sizeof oldmarker, &isl);
    if (r > 0) {
        // 规范化不了(真实 dirfd + 没有 procfs):退回真 symlink,至少语义上没做错。
        int (*fs)(const char*, const char*) = BSH_REAL(r_symlink, symlink);
        if (!fs) { errno = ENOSYS; return -1; }
        return fs(target, linkpath);
    }
    if (r < 0) return -1;
    if (isl) { errno = EEXIST; return -1; }

    int (*fl)(const char*, struct stat*) = BSH_REAL(r_lstat, lstat);
    if (!fl) { errno = ENOSYS; return -1; }
    struct stat st;
    if (fl(cand, &st) == 0) { errno = EEXIST; return -1; }

    char marker[BSH_BUF];
    if (marker_name(cand, marker, sizeof marker) < 0) return -1;

    int (*fa)(int, const char*, int, ...) = BSH_REAL(r_openat, openat);
    if (!fa) { errno = ENOSYS; return -1; }
    int fd = fa(AT_FDCWD, marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;                        // 已存在自然是 EEXIST

    size_t off = 0;
    while (off < tl) {
        ssize_t w = write(fd, target + off, tl - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            close(fd);
            int (*fu)(int, const char*, int) = BSH_REAL(r_unlinkat, unlinkat);
            if (fu) fu(AT_FDCWD, marker, 0);       // 别留半个链接
            errno = saved;
            return -1;
        }
        off += (size_t)w;
    }
    close(fd);
    g_marker_seen = 1;
    return 0;
}

int BSH_EXPORT(symlink)(const char* target, const char* linkpath) {
    return do_symlink(AT_FDCWD, target, linkpath);
}

int BSH_EXPORT(symlinkat)(const char* target, int dirfd, const char* linkpath) {
    return do_symlink(dirfd, target, linkpath);
}

// ─────────────────────────── readlink / readlinkat ───────────────────────────
//
// readlink 不跟随**最后一段**,但中间组件是要解析的(内核行为)。所以:
// 把目录部分展开成真实路径,再对 "<dir>/<base>" 判是不是我们的链接。
// 返回长度、不补 NUL、超长静默截断 —— 都按 readlink(2)。
static ssize_t do_readlink(int dirfd, const char* path, char* buf, size_t bufsiz) {
    if (!path || !buf) { errno = EFAULT; return -1; }
    /* /proc/self/exe：报告给调用方的"链接目标"就是 guest 的真实路径。
     * 保持 readlink(2) 的语义：不补 NUL、超长静默截断、bufsiz==0 给 EINVAL。 */
    bsh_trace("[shim] do_readlink(%s) dirfd=%d\n", path, dirfd);
    if (dirfd == AT_FDCWD) {
        char virt[BSH_BUF];
        int vr = virt_exe_self(path, virt, sizeof virt);
        bsh_trace("[shim]   virt_exe_self=%d\n", vr);
        if (vr < 0) return -1;
        if (vr == 1) {
            if (bufsiz == 0) { errno = EINVAL; return -1; }
            size_t n = strlen(virt);
            if (n > bufsiz) n = bufsiz;
            memcpy(buf, virt, n);
            return (ssize_t)n;
        }
    }
    char cand[BSH_BUF], marker[BSH_BUF];
    int isl = 0;
    int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
    if (r < 0) return -1;
    if (r > 0) {
        ssize_t (*fr)(int, const char*, char*, size_t) = BSH_REAL(r_readlinkat, readlinkat);
        if (!fr) { errno = ENOSYS; return -1; }
        return fr(dirfd, path, buf, bufsiz);
    }
    if (isl) {
        if (bufsiz == 0) { errno = EINVAL; return -1; }   // 实测真 readlink 给 EINVAL
        char target[BSH_BUF];
        ssize_t tl = read_marker(marker, target, sizeof target);
        if (tl < 0) return -1;
        size_t n = (size_t)tl < bufsiz ? (size_t)tl : bufsiz;
        memcpy(buf, target, n);
        return (ssize_t)n;
    }
    ssize_t (*fr)(const char*, char*, size_t) = BSH_REAL(r_readlink, readlink);
    if (!fr) { errno = ENOSYS; return -1; }
    return fr(cand, buf, bufsiz);
}

ssize_t BSH_EXPORT(readlink)(const char* path, char* buf, size_t bufsiz) {
    return do_readlink(AT_FDCWD, path, buf, bufsiz);
}

ssize_t BSH_EXPORT(readlinkat)(int dirfd, const char* path, char* buf, size_t bufsiz) {
    return do_readlink(dirfd, path, buf, bufsiz);
}

// ─────────────────────────── lstat / stat / fstatat ───────────────────────────

int BSH_EXPORT(lstat)(const char* path, struct stat* buf) {
    if (bsh_is_null(path) || bsh_is_null(buf)) { errno = EFAULT; return -1; }
    // /proc/self/exe **不在这里替换**：真 procfs 对它给的就是"魔法链接"的形状
    // （S_IFLNK|0777、size=0、dev/ino 属于 procfs），指向谁都一样，直通真实现才忠实。
    // 第一版这里合成了一份，反而把 dev/ino 变成了本体文件的（见上面那段注释）。
    // 最后一段不跟随,但**前面的组件要跟随** ——真 lstat 也是这样
    // (lstat("/a/link/x") 里的 link 会被内核解析)。
    char cand[BSH_BUF], marker[BSH_BUF];
    int isl = 0;
    int r = last_component_cand(AT_FDCWD, path, cand, sizeof cand, marker, sizeof marker, &isl);
    if (r < 0) return -1;
    if (r == 0 && isl) return fill_link_stat(marker, buf);
    int (*fl)(const char*, struct stat*) = BSH_REAL(r_lstat, lstat);
    if (!fl) { errno = ENOSYS; return -1; }
    if (r > 0) return fl(path, buf);
    return fl(cand, buf);
}

int BSH_EXPORT(stat)(const char* path, struct stat* buf) {
    if (bsh_is_null(path) || bsh_is_null(buf)) { errno = EFAULT; return -1; }
    bsh_trace("[shim] stat(%s)\n", path);
    char res[BSH_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    int (*fs)(const char*, struct stat*) = BSH_REAL(r_stat, stat);
    if (!fs) { errno = ENOSYS; return -1; }
    return fs(changed ? res : path, buf);
}

int BSH_EXPORT(fstatat)(int dirfd, const char* path, struct stat* buf, int flags) {
    if (bsh_is_null(path) || bsh_is_null(buf)) { errno = EFAULT; return -1; }
#ifdef AT_SYMLINK_NOFOLLOW
    if (flags & AT_SYMLINK_NOFOLLOW) {
        // /proc/self/exe 不替换（理由同 lstat：真 procfs 的魔法链接形状本来就对）
        char cand[BSH_BUF], marker[BSH_BUF];
        int isl = 0;
        int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
        if (r < 0) return -1;
        if (r == 0 && isl) return fill_link_stat(marker, buf);
        int (*ff)(int, const char*, struct stat*, int) = BSH_REAL(r_fstatat, fstatat);
        if (!ff) { errno = ENOSYS; return -1; }
        if (r > 0) return ff(dirfd, path, buf, flags);
        return ff(AT_FDCWD, cand, buf, flags);
    }
#endif
    char res[BSH_BUF];
    int changed = 0;
    int r = resolve_at(dirfd, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    int (*ff)(int, const char*, struct stat*, int) = BSH_REAL(r_fstatat, fstatat);
    if (!ff) { errno = ENOSYS; return -1; }
    if (r > 0 || !changed) return ff(dirfd, path, buf, flags);
    return ff(AT_FDCWD, res, buf, flags);
}

// ─────────────────────────── open / openat ───────────────────────────
//
// 默认跟随解析;O_NOFOLLOW 时"最后一段不跟随",而最后一段若是我们的链接 → ELOOP
// (真 open 对符号链接 + O_NOFOLLOW 也是 ELOOP)。
// O_PATH|O_NOFOLLOW 是个例外:真实现会**成功**并把 fd 指向链接本身,所以这里把
// 标记文件交出去(它的属性由 lstat 覆盖,fd 上的 fstat 我们不拦,见 README)。
//
// 非 static + bsh_ 前缀:与 tty 模块合并进同一个 guest shim 时,由 open_shim.c 里
// 那个统一的 open() 调用它(两个模块都想接管 open,只能有一个入口)。
int bsh_fs_do_open(int dirfd, const char* path, int flags, mode_t mode) {
    if (!path) { errno = EFAULT; return -1; }
    int (*fa)(int, const char*, int, ...) = BSH_REAL(r_openat, openat);
    if (!fa) { errno = ENOSYS; return -1; }

    if (flags & O_NOFOLLOW) {
        char cand[BSH_BUF], marker[BSH_BUF];
        int isl = 0;
        int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
        if (r < 0) return -1;
        if (r > 0) return fa(dirfd, path, flags, mode);
        if (isl) {
#ifdef O_PATH
            if (flags & O_PATH) return fa(AT_FDCWD, marker, flags, mode);
#endif
            errno = ELOOP;
            return -1;
        }
        return fa(AT_FDCWD, cand, flags, mode);
    }

    char res[BSH_BUF];
    int changed = 0;
    int cr = resolve_at(dirfd, path, res, sizeof res, &changed);
    if (cr < 0) return -1;
    if (cr > 0 || !changed) return fa(dirfd, path, flags, mode);
    return fa(AT_FDCWD, res, flags, mode);
}

#ifndef BSH_SHIM_MERGED_OPEN
/* 与 tty 模块合并进同一个 guest shim 时（-DBSH_SHIM_MERGED_OPEN），这个入口让给
 * shim/open_shim.c 里那个统一实现（它先问 /dev/tty 钩子、再调下面的
 * bsh_fs_do_open）。两个模块都要接管 open，一个 .so 里只能有一个定义。 */
int BSH_EXPORT(open)(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return bsh_fs_do_open(AT_FDCWD, path, flags, mode);
}
#endif

int BSH_EXPORT(openat)(int dirfd, const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return bsh_fs_do_open(dirfd, path, flags, mode);
}

#ifdef __GLIBC__
int BSH_EXPORT(open64)(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return bsh_fs_do_open(AT_FDCWD, path, flags, mode);
}

int BSH_EXPORT(openat64)(int dirfd, const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return bsh_fs_do_open(dirfd, path, flags, mode);
}
#endif

// ─────────────────────────── unlink / unlinkat ───────────────────────────

static int do_unlink(int dirfd, const char* path, int atflags) {
    if (!path) { errno = EFAULT; return -1; }
    int (*fu)(int, const char*, int) = BSH_REAL(r_unlinkat, unlinkat);
    if (!fu) { errno = ENOSYS; return -1; }

    // 删链接 = 删那个标记文件。最后一段不跟随,前面组件照常展开。
    char cand[BSH_BUF], marker[BSH_BUF];
    int isl = 0;
    int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
    if (r < 0) return -1;
    if (r > 0) return fu(dirfd, path, atflags);
    if (isl) return fu(AT_FDCWD, marker, 0);
    return fu(AT_FDCWD, cand, atflags);
}

int BSH_EXPORT(unlink)(const char* path) {
    return do_unlink(AT_FDCWD, path, 0);
}

int BSH_EXPORT(unlinkat)(int dirfd, const char* path, int atflags) {
    return do_unlink(dirfd, path, atflags);
}

// ─────────────────────────── rename / renameat ───────────────────────────
//
// 重命名链接 = 重命名那个标记文件;落到一个链接名上 = 落到它的标记文件名上。
//
// 四种组合要分开处理,否则会在同一目录里留下"真实文件与标记文件同名"的影子:
//   链接 → 链接名   直接 rename(标记, 标记)
//   链接 → 普通名   先删掉目标位置上已有的真实同名文件(真 rename 是替换语义),
//                   再把标记改名成 <新名>.BSH_SYMLINK
//   普通 → 链接名   先把目标位置的标记删掉(真 rename 会用源文件顶掉那个链接),
//                   再做真 rename —— 否则会变成"内容被当成目标串的假链接"
//   普通 → 普通名   原样透传
static int do_rename(int od, const char* oldp, int nd, const char* newp) {
    if (!oldp || !newp) { errno = EFAULT; return -1; }
    int (*fr)(const char*, const char*) = BSH_REAL(r_rename, rename);
    if (!fr) { errno = ENOSYS; return -1; }
    int (*fu)(int, const char*, int) = BSH_REAL(r_unlinkat, unlinkat);

    char ocand[BSH_BUF], omark[BSH_BUF];
    int oisl = 0;
    int or_ = last_component_cand(od, oldp, ocand, sizeof ocand, omark, sizeof omark, &oisl);
    if (or_ < 0) return -1;

    char ncand[BSH_BUF], nmark[BSH_BUF];
    int nisl = 0;
    int nr_ = last_component_cand(nd, newp, ncand, sizeof ncand, nmark, sizeof nmark, &nisl);
    if (nr_ < 0) return -1;

    if (or_ > 0 || nr_ > 0) return fr(oldp, newp);   // 规范化不了 → 真 rename
    if (!oisl && !nisl) return fr(ocand, ncand);     // 没碰链接 → 真 rename(命名空间已摆正)

    if (fu) {
        if (oisl && !nisl) fu(AT_FDCWD, ncand, 0);   // 清掉目标位置上的真实同名文件
        if (!oisl && nisl) fu(AT_FDCWD, nmark, 0);   // 清掉目标位置上的链接
    }

    const char* src = oisl ? omark : ocand;
    char dst[BSH_BUF];
    if (marker_name(ncand, dst, sizeof dst) < 0) return -1;
    return fr(src, dst);
}

int BSH_EXPORT(rename)(const char* oldpath, const char* newpath) {
    return do_rename(AT_FDCWD, oldpath, AT_FDCWD, newpath);
}

int BSH_EXPORT(renameat)(int olddirfd, const char* oldpath, int newdirfd, const char* newpath) {
    return do_rename(olddirfd, oldpath, newdirfd, newpath);
}

// ─────────────────────────── access / faccessat ───────────────────────────

static int do_access(int dirfd, const char* path, int mode, int flags) {
    if (!path) { errno = EFAULT; return -1; }
    int (*ff)(int, const char*, int, int) = BSH_REAL(r_faccessat, faccessat);
    if (!ff) { errno = ENOSYS; return -1; }

#ifdef AT_SYMLINK_NOFOLLOW
    if (flags & AT_SYMLINK_NOFOLLOW) {
        char cand[BSH_BUF], marker[BSH_BUF];
        int isl = 0;
        int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
        if (r < 0) return -1;
        if (r > 0) return ff(dirfd, path, mode, flags);
        // 链接自身权限恒为 0777 且一定存在 → F_OK/R_OK/W_OK/X_OK 都放行
        if (isl) return 0;
        return ff(AT_FDCWD, cand, mode, flags);
    }
#endif
    char res[BSH_BUF];
    int changed = 0;
    int r = resolve_at(dirfd, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    if (r > 0 || !changed) return ff(dirfd, path, mode, flags);
    return ff(AT_FDCWD, res, mode, 0);
}

int BSH_EXPORT(access)(const char* path, int mode) {
    return do_access(AT_FDCWD, path, mode, 0);
}

int BSH_EXPORT(faccessat)(int dirfd, const char* path, int mode, int flags) {
    return do_access(dirfd, path, mode, flags);
}

// ─────────────────────────── realpath ───────────────────────────
//
// 展开模拟链接之后交给真 realpath 做规范化和"逐段必须存在"的检查 ——
// 那一部分(相对目标的拼接、".." 的顺序)我们故意不自己实现,理由同 resolve_simlinks。
char* BSH_EXPORT(realpath)(const char* path, char* resolved) {
    if (!path) { errno = EFAULT; return NULL; }
    char res[BSH_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return NULL;
    char* (*fr)(const char*, char*) = BSH_REAL(r_realpath, realpath);
    if (!fr) { errno = ENOSYS; return NULL; }
    return fr(changed ? res : path, resolved);
}

// ──────────── glibc 的 _FORTIFY_SOURCE 包装(__*_chk / __*_2) ────────────
//
// 打开 _FORTIFY_SOURCE(Ubuntu 的 gcc 在 -O2 下**默认**开,OHOS 的 clang 也常见)之后,
// 程序里的 realpath()/open()/readlink() 会被**编译器改写成**这些带缓冲长度校验的包装
// 函数。不拦它们,那几处调用就绕过本模块直接进 libc —— 实测踩到过:程序里
// realpath(link) 变成 __realpath_chk,我们的 realpath 一次都没被调到,
// 于是模拟链接在 realpath 上给 ENOENT。这里把它们接回本模块的实现
// (缓冲长度检查在调用侧由编译器保证;真是越界调用,真实现自己也会报错)。
#ifdef __GLIBC__
ssize_t BSH_EXPORT(__readlink_chk)(const char* path, char* buf, size_t len, size_t buflen) {
    (void)buflen;
    return readlink(path, buf, len);
}

ssize_t BSH_EXPORT(__readlinkat_chk)(int dirfd, const char* path, char* buf, size_t len, size_t buflen) {
    (void)buflen;
    return readlinkat(dirfd, path, buf, len);
}

char* BSH_EXPORT(__realpath_chk)(const char* path, char* resolved, size_t resolvedlen) {
    (void)resolvedlen;
    return realpath(path, resolved);
}

int BSH_EXPORT(__open_2)(const char* path, int flags) { return bsh_fs_do_open(AT_FDCWD, path, flags, 0); }
int BSH_EXPORT(__open64_2)(const char* path, int flags) { return bsh_fs_do_open(AT_FDCWD, path, flags, 0); }
int BSH_EXPORT(__openat_2)(int dirfd, const char* path, int flags) { return bsh_fs_do_open(dirfd, path, flags, 0); }
int BSH_EXPORT(__openat64_2)(int dirfd, const char* path, int flags) { return bsh_fs_do_open(dirfd, path, flags, 0); }
#endif

// ─────────────────────────── opendir / readdir ───────────────────────────
//
// 表示法只影响**目录项的名字**,不影响目录里的真实项数(foo 不存在,只有
// foo.BSH_SYMLINK),所以列举目录这件事只需要"改名 + 改 d_type",
// 不需要隐藏任何项 —— 也就完全不需要自己去解析 getdents64 的记录/缓冲。
//
// 做法是就地改真 readdir 返回的那条记录:glibc 与 musl 的 readdir 都是"指针指进
// DIR 自己的 getdents 缓冲,然后 dirp->offset += d_reclen"就返回,下一条从新的
// offset 取。因此改**当前这条**的 d_name/d_type 对后续记录零影响(d_reclen 没动),
// 更不会把 dir 流搞坏。返回的指针仍指向 libc 自己的存储,生命周期语义与原来一致
// (下一次对同一 DIR 调 readdir 才失效),跨目录流交替 readdir 也是安全的。
static void unmark_dirent(struct dirent* e) {
    size_t n = strlen(e->d_name);
    if (n <= BSH_SUFFIX_LEN) return;
    if (memcmp(e->d_name + n - BSH_SUFFIX_LEN, BSH_SUFFIX, BSH_SUFFIX_LEN) != 0) return;
    e->d_name[n - BSH_SUFFIX_LEN] = 0;
    e->d_type = DT_LNK;
}

DIR* BSH_EXPORT(opendir)(const char* path) {
    if (bsh_is_null(path)) { errno = EFAULT; return NULL; }
    char res[BSH_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return NULL;
    DIR* (*fo)(const char*) = BSH_REAL(r_opendir, opendir);
    if (!fo) { errno = ENOSYS; return NULL; }
    return fo(changed ? res : path);
}

struct dirent* BSH_EXPORT(readdir)(DIR* dirp) {
    struct dirent* (*fr)(DIR*) = BSH_REAL(r_readdir, readdir);
    if (!fr) { errno = ENOSYS; return NULL; }
    struct dirent* e = fr(dirp);
    if (e) unmark_dirent(e);
    return e;
}

#ifdef __GLIBC__
struct dirent64* readdir64(DIR* dirp) {
    return (struct dirent64*)readdir(dirp);
}
#endif

// ── scandir:libuv 的 readdir 走的是它,得单独接一层 ─────────────────────────
//
// 为什么非接不可:libuv 的 uv__fs_scandir()(deps/uv/src/unix/fs.c:552)调的是 libc 的
// **scandir()**,而它内部的 opendir/readdir 发生在 libc 里 —— 链接期的 --wrap 只改写
// "我们链接的那些对象"里的引用,够不着 libc 内部 → 标记既不会被改名也不会被隐藏,
// 调用方会直接看见 `x.BSH_SYMLINK`(实测 node 的 readdirSync 就是这样)。
// 所以在这里:先把目录路径按模拟软链解析(路径本身可能就是链接),再把结果数组逐个
// 改名(unmark_dirent,与 readdir 同一套)。
int BSH_EXPORT(scandir)(const char* path, struct dirent*** namelist,
                        int (*filter)(const struct dirent*),
                        int (*compar)(const struct dirent**, const struct dirent**)) {
    if (bsh_is_null(path)) { errno = EFAULT; return -1; }
    char res[BSH_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    int (*fsc)(const char*, struct dirent***, int (*)(const struct dirent*),
               int (*)(const struct dirent**, const struct dirent**)) = BSH_REAL(r_scandir, scandir);
    if (!fsc) { errno = ENOSYS; return -1; }
    int n = fsc(changed ? res : path, namelist, filter, compar);
    if (n > 0 && namelist && *namelist) {
        for (int i = 0; i < n; i++)
            if ((*namelist)[i]) unmark_dirent((*namelist)[i]);
    }
    return n;
}

// ── syscall 这一层必须拦两个号:statx 与 io_uring_setup ─────────────────────
//
// (1) statx —— 语义问题
// 根因就在这几行:libuv 的 stat/lstat 走 **statx** —— uv__fs_statx() → uv__statx()
// (deps/uv/src/unix/linux-syscalls.c:245)里是**裸 syscall(__NR_statx, …)**,绕开了
// libc 符号,所以 --wrap=stat / --wrap=lstat 完全够不着它。"node 看不见模拟软链"
// 就是这一条(guest 侧是符号插入,所以没问题 —— 实测同一份 shim,ls 正常、node 不正常)。
// 处理:statx 一律判 ENOSYS。libuv 有 no_statx 缓存(fs.c:1517),一次 ENOSYS 之后就
// **永久**退回 lstat/fstatat,而那两个是被 wrap 的、会做模拟软链解析 ✓。
//
// (2) io_uring_setup(425) —— **会把进程打死**
// libuv 初始化 io_uring 后端时也会裸调:uv__io_uring_setup()(linux.c:430) →
// `syscall(__NR_io_uring_setup, entries, params)`。而**鸿蒙沙箱对这一号是
// SECCOMP_RET_TRAP** —— 内核日志(hilog -t kmsg 的 hmsecpt)实测:
//     [hmsecpt:59]sig=0 arch=0xc00000b7 syscall=425 compat=0 ip=0 code=0x30000
// 也就是每次探测都往进程投一个 **SIGSYS**。正常情况下 procmgr 在子进程里装的
// OnSigSys 会把它降级成 ENOSYS(见 procmgr.cpp),但**node 进程里那个 handler 会被
// V8 顶掉**:v8::base::debug::EnableInProcessStackDumping() 用
//     action.sa_flags = SA_RESETHAND | SA_SIGINFO | SA_ONSTACK;
// 装 SIGSYS —— **带 SA_RESETHAND**,于是第一次 SIGSYS 之后 SIGSYS 复位成 SIG_DFL,
// 再撞一次就按默认动作**core dump 打死**。实测症状:kimi-code 的交互 TUI 跑到
// 2 秒左右无声死掉、退出码 159(128+SIGSYS)、core dump(type=0),而同一批的
// "启动器"node 进程因为探测发生在 V8 装 handler 之前而幸存。
// 处理:io_uring_setup 也一律判 ENOSYS。libuv 那边是
//     ringfd = uv__io_uring_setup(entries, &params); if (ringfd == -1) return;
// ——**干净回退**到 epoll/线程池,正是"内核没有 io_uring"时的既有路径。
// 这样从根上不产生 SIGSYS,不再依赖任何 handler 是否还在(顺带也不必再靠
// procmgr 的 OnSigSys 兜 hdc 那个同类探测)。
//
// 其余号原样转发(可变参数全读出来再转发;多余参数对 syscall 无害)。
long BSH_EXPORT(syscall)(long number, ...) {
    va_list ap;
    va_start(ap, number);
    long a1 = va_arg(ap, long), a2 = va_arg(ap, long), a3 = va_arg(ap, long);
    long a4 = va_arg(ap, long), a5 = va_arg(ap, long), a6 = va_arg(ap, long);
    va_end(ap);
#ifdef __NR_statx
    if (number == __NR_statx) { errno = ENOSYS; return -1; }
#endif
#ifdef __NR_io_uring_setup
    if (number == __NR_io_uring_setup) { errno = ENOSYS; return -1; }
#endif
    long (*fsy)(long, ...) = BSH_REAL(r_syscall, syscall);
    if (!fsy) { errno = ENOSYS; return -1; }
    return fsy(number, a1, a2, a3, a4, a5, a6);
}

// ─────────────────────────── link / linkat ───────────────────────────
//
// 两种情形:
//   1) 源/目标是**模拟软链**(.BSH_SYMLINK 标记文件) —— 给标记文件再建一个硬链接,
//      于是"另一个名字指向同一个链接"(两边同一 inode),连 lstat 的 st_nlink 都对得上;
//   2) 真文件之间的硬链接 —— 直接交给内核。
//
// 但内核这条路在**非 debug 应用**下是关的:实测 release 构建(app.debug=false,本项目
// 自测用的就是 release 模式 + debug-jit 签名)一律 EACCES。而硬链接在工具链里用得不少:
// node 的原子写就是 link(tmp,final)+unlink(tmp),dsh 的会话持久化就是这么挂的 ——
//     EACCES: permission denied, link '…session.v4.jsonl.zstd.<hash>.tmp' -> '…session.v4.jsonl.zstd'
// npm/git 的硬链接优化同理。所以下面加一层**只在真 link 失败时**才走的兜底:复制。
//
// 语义取舍:复制不是硬链接(两边不同 inode、st_nlink 是 1),但对"临时文件 → 终名"这
// 一族用法,可观察效果一致(终名有内容、原名仍在,调用方随后 unlink 原名)。源是符号
// 链接时要连**链接本身**一起复制(readlink + symlinkat),不能跟随目标 —— 这是 link(2)
// 的既有语义。debug 构建/普通环境下列都不会走到,行为一字不变。
//
// ── 例外:BSH_SHIM_LINK_STRICT=1 时**不做兜底** ────────────────────────────────
// 有一部分调用方会**核对 link 的语义**(而不是只要效果):git 的本地克隆 link() 之后
// 用 lstat 比 st_ino/st_dev,发现自己拿到的不是同一个 inode 就
//     fatal: hardlink different from source at '…/objects/xx/yyy'
// 直接 die —— 它预期的是"link 失败,我自己退化成复制"。对这种调用方,兜底反而是
// 谎言。设了这个变量就把内核的原始 errno 原样返回(git 的四个启动器都设了它)。
static int bsh_link_strict(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BSH_SHIM_LINK_STRICT");
        cached = (v && *v && v[0] != '0') ? 1 : 0;
    }
    return cached;
}

static int link_or_copy(int od, const char* oldp, int nd, const char* newp, int flags) {
    int (*fl)(int, const char*, int, const char*, int) = BSH_REAL(r_linkat, linkat);
    if (fl && fl(od, oldp, nd, newp, flags) == 0) return 0;
    int le = errno;
    if (fl && le != EACCES && le != EPERM && le != EMLINK && le != EOPNOTSUPP && le != ENOSYS) {
        errno = le;
        return -1;
    }
    if (bsh_link_strict()) { errno = le; return -1; }

    /* ---- 兜底:复制 ---- */
    static int (*fs)(int, const char*, struct stat*, int);
    if (!fs) fs = BSH_REAL(r_fstatat, fstatat);
    struct stat st;
    if (!fs || fs(od, oldp, &st, AT_SYMLINK_NOFOLLOW) != 0) { errno = le; return -1; }

    if (S_ISLNK(st.st_mode)) {
        static ssize_t (*frl)(int, const char*, char*, size_t);
        static int (*fsl)(const char*, int, const char*);
        if (!frl) frl = BSH_REAL(r_readlinkat, readlinkat);
        if (!fsl) fsl = BSH_REAL(r_symlinkat, symlinkat);
        if (!frl || !fsl) { errno = ENOSYS; return -1; }
        char tgt[BSH_BUF];
        ssize_t n = frl(od, oldp, tgt, sizeof tgt);
        if (n < 0) return -1;
        return fsl(tgt, nd, newp);
    }

    static int (*fop)(int, const char*, int, ...);
    if (!fop) fop = BSH_REAL(r_openat, openat);
    if (!fop) { errno = ENOSYS; return -1; }
    int src = fop(od, oldp, O_RDONLY | O_CLOEXEC);
    if (src < 0) return -1;
    int dst = fop(nd, newp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, (mode_t)(st.st_mode & 07777));
    if (dst < 0) { int e = errno; close(src); errno = e; return -1; }
    fchmod(dst, (mode_t)(st.st_mode & 07777));   /* O_CREAT 的模式会被 umask 削,显式纠回来 */
    char buf[65536];
    int rc = 0;
    for (;;) {
        ssize_t r = read(src, buf, sizeof buf);
        if (r < 0) { rc = -1; break; }
        if (r == 0) break;
        size_t off = 0;
        while (off < (size_t)r) {
            ssize_t w = write(dst, buf + off, (size_t)r - off);
            if (w <= 0) { rc = -1; break; }
            off += (size_t)w;
        }
        if (rc < 0) break;
    }
    int se = errno;
    close(src);
    close(dst);
    errno = se;
    return rc;
}

static int do_link(int od, const char* oldp, int nd, const char* newp, int flags) {
    if (!oldp || !newp) { errno = EFAULT; return -1; }

#ifdef AT_SYMLINK_FOLLOW
    if (flags & AT_SYMLINK_FOLLOW) {
        // 跟随:链接被展开成目标,新名字指向目标本体
        char res[BSH_BUF];
        int changed = 0;
        int r = resolve_at(od, oldp, res, sizeof res, &changed);
        if (r < 0) return -1;
        if (r > 0) return link_or_copy(od, oldp, nd, newp, flags);
        return link_or_copy(AT_FDCWD, changed ? res : oldp, nd, newp, flags & ~AT_SYMLINK_FOLLOW);
    }
#endif
    char ocand[BSH_BUF], omark[BSH_BUF];
    int oisl = 0;
    int or_ = last_component_cand(od, oldp, ocand, sizeof ocand, omark, sizeof omark, &oisl);
    if (or_ < 0) return -1;
    if (or_ > 0) return link_or_copy(od, oldp, nd, newp, flags);
    if (!oisl) return link_or_copy(AT_FDCWD, ocand, nd, newp, flags);

    char ncand[BSH_BUF], nmark[BSH_BUF];
    int nisl = 0;
    int nr_ = last_component_cand(nd, newp, ncand, sizeof ncand, nmark, sizeof nmark, &nisl);
    if (nr_ < 0) return -1;
    if (nr_ > 0) return link_or_copy(od, oldp, nd, newp, flags);

    char dst[BSH_BUF];
    if (marker_name(ncand, dst, sizeof dst) < 0) return -1;
    return link_or_copy(AT_FDCWD, omark, AT_FDCWD, dst, 0);
}

int BSH_EXPORT(link)(const char* oldpath, const char* newpath) {
    return do_link(AT_FDCWD, oldpath, AT_FDCWD, newpath, 0);
}

int BSH_EXPORT(linkat)(int olddirfd, const char* oldpath, int newdirfd, const char* newpath, int flags) {
    return do_link(olddirfd, oldpath, newdirfd, newpath, flags);
}

// ─────────────────── glibc 的老兼容入口(__xstat / __lxstat) ───────────────────
//
// glibc 2.33 之前的程序会调 __xstat/__lxstat(带一个版本号)而不是 stat/lstat。
// 64 位 ABI 下版本号只是个形式,直接按新结构转给我们自己的 stat/lstat 即可。
// musl 没有这两个符号,也不需要(musl 直接导出 stat/lstat)。
#ifdef __GLIBC__
int BSH_EXPORT(__lxstat)(int ver, const char* path, struct stat* buf) {
    (void)ver;
    return lstat(path, buf);
}

int BSH_EXPORT(__xstat)(int ver, const char* path, struct stat* buf) {
    (void)ver;
    return stat(path, buf);
}
#endif

// ─────────────────────────── stdio 那几层(FILE*) ───────────────────────────
//
// 为什么必须单独拦：**库内部的 syscall 路径绕不开符号插入**。musl 的 fopen 直接调它
// 内部的 sys_open()，glibc 的 fopen 走 _IO_file_open → __open_nocancel() —— 都不是
// "调用 open 这个符号"，所以前面那些 open/openat 的拦截对 fopen 一点用没有。
// 实测症状：guest 里 symlink 建出来了、lstat/readlink/stat 都对，一 fopen 读内容就是
// 空（README §3.3）。
//
// 办法很直接：我们自己的 fopen **先把路径解析成真实路径**，再把解析后的路径交给
// 真正的 fopen（RTLD_NEXT）。这样库内部怎么走 syscall 都无所谓，路径已经是对的。
static FILE* (*r_fopen)(const char*, const char*);
static FILE* (*r_freopen)(const char*, const char*, FILE*);

static FILE* do_fopen(const char* path, const char* mode) {
    if (bsh_is_null(path) || bsh_is_null(mode)) { errno = EFAULT; return NULL; }
    FILE* (*ff)(const char*, const char*) = BSH_REAL(r_fopen, fopen);
    if (!ff) { errno = ENOSYS; return NULL; }
    char res[BSH_BUF];
    if (resolve_simlinks(path, res, sizeof res) == 0 && strcmp(res, path) != 0)
        return ff(res, mode);
    return ff(path, mode);
}

FILE* BSH_EXPORT(fopen)(const char* path, const char* mode) {
    return do_fopen(path, mode);
}

FILE* BSH_EXPORT(freopen)(const char* path, const char* mode, FILE* stream) {
    FILE* (*ff)(const char*, const char*, FILE*) = BSH_REAL(r_freopen, freopen);
    if (!ff) { errno = ENOSYS; return NULL; }
    if (bsh_is_null(path)) return ff(path, mode, stream);
    char res[BSH_BUF];
    if (resolve_simlinks(path, res, sizeof res) == 0 && strcmp(res, path) != 0)
        return ff(res, mode, stream);
    return ff(path, mode, stream);
}

#ifdef __GLIBC__
FILE* BSH_EXPORT(fopen64)(const char* path, const char* mode) { return do_fopen(path, mode); }
FILE* BSH_EXPORT(freopen64)(const char* path, const char* mode, FILE* stream) {
    return freopen(path, mode, stream);
}
#endif

// ─────────────────── box64 内部模式（-DBSH_SHIM_BOX64）───────────────────────
//
// box64 的 hooked `my_*` 需要的两个**附加**入口（不是 libc 符号，只在本模式导出）：
//
//   bsh_fs_active()        诊断用：本进程里出现过标记吗（**不做**快路径门 —— 标记可能是
//                          上一个进程建的，比如资源包里的 tar 解出来的 python venv，
//                          所以路径展开必须每次都做；代价与 elfloader 侧完全一样）。
//   bsh_fs_resolve_path()  只做**路径展开**、不碰文件：把 path 里的模拟链接逐段展开到
//                          out；没命中标记时原样返回 path（调用方只多一次指针比较）。
//                          box64 的 my_open/my_stat 用它——那些入口自己还要做
//                          box64 的 path remap，不方便直接调本模块的 open/stat。
//
// 注意返回值语义：返回 `path` 表示"没改"，返回 `out` 表示"改了"（out 是调用方的栈缓冲，
// 寿命由调用方保证）。展开失败（ENAMETOOLONG/ELOOP）也返回 path —— 与"透明"一致，
// 真错误交给后面的真实现去报。
#ifdef BSH_SHIM_BOX64
int bsh_fs_active(void) { return g_marker_seen != 0; }
#endif

/* 路径展开入口：把 path 里的模拟链接逐段展开到 out；没命中标记时原样返回 path
 * （调用方只多一次指针比较）。返回 `path` 表示"没改"，返回 `out` 表示"改了"
 * （out 是调用方的栈缓冲，寿命由调用方保证）。展开失败（ENAMETOOLONG/ELOOP）也返回
 * path —— 与"透明"一致，真错误交给后面的真实现去报。
 *
 * 谁在用（所以它**不在任何 ifdef 里**）：
 *   - box64 的 my_open/my_stat（-DBSH_SHIM_BOX64）—— 那些入口自己还要做 box64 的
 *     path remap，不方便直接调本模块的 open/stat；
 *   - **exec_shim**（2026-10-04 起）：exec 的目标路径要交给 procmgr，而 procmgr 没有
 *     fs_shim，按真路径 stat 会 ENOENT。npm 的 `node_modules/.bin/*` 全是模拟软链，
 *     任何带 install 脚本的包都撞上（实测 `code 126` + "cannot exec: …/node-gyp-build:
 *     not found"）。exec_shim 那边用**弱引用**兜底：不链本模块的 so 上它是 NULL。 */
const char* bsh_fs_resolve_path(const char* path, char* out, size_t outsz) {
    if (!path || !*path || !out || !outsz) return path;
    if (resolve_simlinks(path, out, outsz) != 0) return path;
    return out;
}

