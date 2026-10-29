// shim.c — LD_PRELOAD shim: route dlopen/dlsym/dlclose to elf_dl.
//
// Optional: this shim is not built by the current CMake/Makefile targets; it
// depends on the in-memory dlopen fallback in elf_dl.cpp.
//
// Build:
//   aarch64:  clang -shared -fPIC -O2 shim.c -o libdlopen_shim.so \
//                 -L. -l:elf_loader_arm.a -ldl -lpthread
//   x86_64:   clang -shared -fPIC -O2 shim.c -o libdlopen_shim.so \
//                 -L. -l:elf_loader_x86.a -ldl -lpthread
//
// Usage:
//   LD_PRELOAD=./libdlopen_shim.so ./target_binary ...
//
// Controls:
//   SHIM_TRACE=1              print every routing decision
//   SHIM_FORCE_MEM=1          route every readable ELF path to elf_dl (on by default)
//   SHIM_PASSTHROUGH=/libfoo  colon-separated substring allowlist; these paths use real dlopen

#define _GNU_SOURCE
#include "loader.h"
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* --- real implementation pointers (the libc originals from dlsym(RTLD_NEXT)) --- */
typedef void *(*dlopen_fn)(const char *, int);
typedef void *(*dlsym_fn )(void *, const char *);
typedef int   (*dlclose_fn)(void *);
typedef char *(*dlerror_fn)(void);

static dlopen_fn   real_dlopen;
static dlsym_fn    real_dlsym;
static dlclose_fn  real_dlclose;
static dlerror_fn  real_dlerror;

static int trace_on(void) {
    const char *v = getenv("SHIM_TRACE");
    return v && v[0] && v[0] != '0';
}
static void slog(const char *fmt, ...) {
    if (!trace_on()) return;
    va_list ap; va_start(ap, fmt);
    fputs("[shim] ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

/* --- preferred symbol resolver: look in the host's own symbol table first --- */
static void *host_handle;  /* dlopen(NULL, RTLD_NOW) -- the host executable itself */
static void *prefer_sym(const char *name) {
    if (!host_handle) return NULL;
    /* use the real dlsym to avoid recursion */
    return real_dlsym ? real_dlsym(host_handle, name) : NULL;
}

__attribute__((constructor))
static void shim_init(void) {
    /* 1. capture the real implementations */
    real_dlopen  = (dlopen_fn )dlsym(RTLD_NEXT, "dlopen");
    real_dlsym   = (dlsym_fn  )dlsym(RTLD_NEXT, "dlsym");
    real_dlclose = (dlclose_fn)dlsym(RTLD_NEXT, "dlclose");
    real_dlerror = (dlerror_fn)dlsym(RTLD_NEXT, "dlerror");

    /* 2. install the "preferred symbol resolver": when elf_dl resolves an
     *    undefined symbol in a loaded .so, let it look in the host first.
     *    This keeps a host-exported symbol (e.g. libnode's own napi_*) from
     *    being shadowed by an earlier-loaded implementation of the same name. */
    if (real_dlopen) host_handle = real_dlopen(NULL, RTLD_NOW);
    elf_dl_set_prefer_sym(prefer_sym);

    slog("init ok (host_handle=%p)", host_handle);
}

/* --- decide whether this path goes through the in-memory loader --- */
static int path_in_passthrough(const char *path) {
    const char *list = getenv("SHIM_PASSTHROUGH");
    if (!list || !*list) return 0;
    const char *p = list;
    while (*p) {
        const char *q = strchr(p, ':');
        size_t n = q ? (size_t)(q - p) : strlen(p);
        if (n && strstr(path, (char[1024]){0}) != NULL) {
            /* keep it simple: copy, then compare */
        }
        if (n) {
            char buf[512];
            if (n >= sizeof(buf)) n = sizeof(buf) - 1;
            memcpy(buf, p, n); buf[n] = 0;
            if (strstr(path, buf)) return 1;
        }
        if (!q) break;
        p = q + 1;
    }
    return 0;
}

static int is_elf_file(const char *path, void **out, size_t *outlen) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(Elf64_Ehdr)) {
        close(fd); return 0;
    }
    size_t n = (size_t)st.st_size;
    void *buf = malloc(n);
    if (!buf) { close(fd); return 0; }
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (char*)buf + got, n - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    if (got != n) { free(buf); return 0; }
    const unsigned char *e = (const unsigned char *)buf;
    if (memcmp(e, "\x7f""ELF", 4) != 0 || e[4] != ELFCLASS64) {
        free(buf); return 0;
    }
    *out = buf; *outlen = n;
    return 1;
}

/* --- exported dlopen/dlsym/dlclose/dlerror --- */
void *dlopen(const char *path, int flags) {
    if (!path) {
        /* dlopen(NULL) -- return the host's own handle; use the real implementation */
        return real_dlopen ? real_dlopen(NULL, flags) : NULL;
    }

    if (path_in_passthrough(path)) {
        slog("passthrough: %s", path);
        return real_dlopen(path, flags);
    }

    /* Only intercept calls that look like a file path. Name lookups (e.g.
     * "libm.so.6") keep using the real implementation, so we do not compete
     * with the system library resolver; to force an in-memory .so, use an
     * absolute or relative path. */
    int looks_like_path = (path[0] == '/' || (path[0] == '.' && path[1] == '/')
                           || (path[0] == '.' && path[1] == '.' && path[2] == '/'));
    const char *force = getenv("SHIM_FORCE_MEM");
    int force_mem = force && force[0] == '1';

    if (!looks_like_path && !force_mem) {
        slog("name lookup -> real_dlopen: %s", path);
        return real_dlopen(path, flags);
    }

    void *img = NULL; size_t img_len = 0;
    if (!is_elf_file(path, &img, &img_len)) {
        slog("not an ELF file / unreadable -> real_dlopen: %s", path);
        return real_dlopen(path, flags);
    }

    void *h = elf_dlopen_mem(img, img_len, path);
    free(img);  /* elf_dlopen_mem has already copied the segments into its own anonymous pages */
    if (!h) {
        slog("elf_dlopen_mem FAILED -> fallback real_dlopen: %s", path);
        return real_dlopen(path, flags);
    }
    slog("elf_dlopen_mem ok: %s -> %p", path, h);
    return h;
}

void *dlsym(void *handle, const char *name) {
    /* special handles such as RTLD_DEFAULT / RTLD_NEXT are not ours */
    if (handle && elf_dl_owns_handle(handle)) {
        void *p = elf_dlsym(handle, name);
        slog("dlsym(ours %p, %s) = %p", handle, name ? name : "(null)", p);
        return p;
    }
    return real_dlsym ? real_dlsym(handle, name) : NULL;
}

int dlclose(void *handle) {
    if (handle && elf_dl_owns_handle(handle)) {
        /* elf_dl has no real unload yet (it releases the image but pthread_key
         * destructors run at thread exit); most hosts do not dlclose before
         * exiting. Return 0 to satisfy the caller. */
        slog("dlclose(ours %p) -> noop", handle);
        return 0;
    }
    return real_dlclose ? real_dlclose(handle) : -1;
}

char *dlerror(void) {
    /* elf_dl does not keep an error string; just clear the real implementation's
     * pending error. */
    return real_dlerror ? real_dlerror() : NULL;
}
