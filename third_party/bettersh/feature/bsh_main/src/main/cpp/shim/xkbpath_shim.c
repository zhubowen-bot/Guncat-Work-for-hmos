
/* ⚠ 已被 fs_shim.c 的 kPathMap 取代（2026-10-07）。
 * 本文件保留作为"独立 preload"这种办法的参考实现；**不要**把它加进 build_shim.sh
 * 的源列表 —— 它拦的入口(stat/lstat/access/faccessat/open/openat/opendir)与 fs_shim.c
 * 完全重叠，会重复定义。当前生效的映射在 fs_shim.c 顶部的 kPathMap[]。 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define SRC "/usr/share/X11/xkb"
static __thread char b1[PATH_MAX];
static const char *map(const char *p) {
    if (!p || strncmp(p, SRC, sizeof(SRC) - 1) != 0) return p;
    if (p[sizeof(SRC) - 1] != '\0' && p[sizeof(SRC) - 1] != '/') return p;
    const char *root = getenv("BSH_SYSROOT");
    if (!root || !*root) return p;
    snprintf(b1, sizeof b1, "%s/usr/share/x11/xkb%s", root, p + (sizeof(SRC) - 1));
    return b1;
}
#define NEXT(name, T) static T real_##name; if (!real_##name) real_##name = (T)dlsym(RTLD_NEXT, #name);

typedef int (*t_stat)(const char *, struct stat *);
typedef int (*t_stat64)(const char *, struct stat64 *);
typedef int (*t_access)(const char *, int);
typedef int (*t_faccessat)(int, const char *, int, int);
typedef int (*t_open)(const char *, int, ...);
typedef int (*t_openat)(int, const char *, int, ...);
typedef DIR *(*t_opendir)(const char *);

#define GETMODE(fl) mode_t md = 0; if ((fl) & O_CREAT) { va_list a; va_start(a, fl); md = va_arg(a, mode_t); va_end(a); }

int stat(const char *p, struct stat *s) { NEXT(stat, t_stat) return real_stat(map(p), s); }
int lstat(const char *p, struct stat *s) { NEXT(lstat, t_stat) return real_lstat(map(p), s); }
int stat64(const char *p, struct stat64 *s) { NEXT(stat64, t_stat64) return real_stat64(map(p), s); }
int lstat64(const char *p, struct stat64 *s) { NEXT(lstat64, t_stat64) return real_lstat64(map(p), s); }
int access(const char *p, int m) { NEXT(access, t_access) return real_access(map(p), m); }
int faccessat(int fd, const char *p, int m, int f) { NEXT(faccessat, t_faccessat) return real_faccessat(fd, map(p), m, f); }
int open(const char *p, int fl, ...) { NEXT(open, t_open) GETMODE(fl) return real_open(map(p), fl, md); }
int open64(const char *p, int fl, ...) { NEXT(open64, t_open) GETMODE(fl) return real_open64(map(p), fl, md); }
int openat(int fd, const char *p, int fl, ...) { NEXT(openat, t_openat) GETMODE(fl) return real_openat(fd, map(p), fl, md); }
int openat64(int fd, const char *p, int fl, ...) { NEXT(openat64, t_openat) GETMODE(fl) return real_openat64(fd, map(p), fl, md); }
DIR *opendir(const char *p) { NEXT(opendir, t_opendir) return real_opendir(map(p)); }
