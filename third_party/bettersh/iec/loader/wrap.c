// loader/wrap.c — link-time wrapper that routes dlopen() to elf_dl.
//
// Why this exists: the application's data directory is noexec, so the system
// loader refuses to mmap a .so there with PROT_EXEC and reports it as
// "No such file or directory" (Python's numpy extension and Node's native
// addons are the measured cases). The in-process loader in elf_dl.cpp maps
// segments into anonymous memory and resolves the relocations itself.
//
// This file is the command-object side of that loader. A command .so is
// dlopen()ed by the host and sits at the end of the global search order, so
// dlsym(RTLD_NEXT) cannot find the real implementation. The build therefore
// links it with
//
//     -Wl,--wrap=dlopen,--wrap=dlsym,--wrap=dlclose
//
// which turns the command object's references into __wrap_* and gives the
// linker-generated originals the __real_* names.
//
// Semantics, stated honestly:
//   * the real loader is always tried first; anything it can open is unchanged;
//   * RTLD_LOCAL and RTLD_GLOBAL are not distinguished here -- all objects
//     loaded through elf_dl share one symbol table;
//   * dlclose() on such a handle only invalidates it; the mapping stays;
//   * destructors (DT_FINI / DT_FINI_ARRAY) are not run.
//
// Controls:
//   IEC_DLOPEN_TRACE=1   print every successful fallback (failures always print)
//   IEC_ELFDL_TRACE=1    print elf_dl's own diagnostics

#define _GNU_SOURCE
#include "loader.h"

#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern void *__real_dlopen(const char *filename, int flags);
extern void *__real_dlsym(void *handle, const char *name);
extern int __real_dlclose(void *handle);

static int trace_on(void)
{
    const char *v = getenv("IEC_DLOPEN_TRACE");
    return v && *v && v[0] != '0';
}

static void *read_all(const char *path, size_t *len_out)
{
    int fd = open(path, O_RDONLY);
    struct stat st;
    size_t len, got = 0;
    unsigned char *buf;

    if (fd < 0) return NULL;
    if (fstat(fd, &st) != 0 || st.st_size < 64) {
        close(fd);
        return NULL;
    }
    len = (size_t)st.st_size;
    buf = (unsigned char *)malloc(len);
    if (!buf) {
        close(fd);
        return NULL;
    }
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n <= 0) break;
        got += (size_t)n;
    }
    close(fd);
    if (got != len) {
        free(buf);
        return NULL;
    }
    *len_out = len;
    return buf;
}

static int ends_with(const char *s, const char *suffix)
{
    size_t ls = strlen(s), lf = strlen(suffix);
    return ls >= lf && strcmp(s + ls - lf, suffix) == 0;
}

// Preload the libraries a PEP 600 wheel keeps next to its extension, in a
// sibling <dist>.libs/ directory. Those names (libstdc++-<hash>.so.6,
// libgcc_s-<hash>.so.1, libscipy_openblas64_-<hash>.so) do not exist in the
// system, and RPATH cannot help because the loader never gets to map them.
// They are in the same noexec tree, so they must go through elf_dl too.
static void preload_pep600_libs(const char *so_path)
{
    char dir[4096];
    size_t n = strlen(so_path);
    if (n >= sizeof dir) return;
    memcpy(dir, so_path, n + 1);

    for (int up = 0; up < 4; up++) {
        char *slash = strrchr(dir, '/');
        DIR *d;
        struct dirent *e;

        if (!slash) return;
        *slash = '\0';
        d = opendir(dir);
        if (!d) continue;

        while ((e = readdir(d)) != NULL) {
            char libdir[4096];
            DIR *ld;
            struct dirent *le;

            if (e->d_name[0] == '.' || !ends_with(e->d_name, ".libs")) continue;
            snprintf(libdir, sizeof libdir, "%s/%s", dir, e->d_name);
            ld = opendir(libdir);
            if (!ld) continue;

            while ((le = readdir(ld)) != NULL) {
                char lib[4096];
                size_t len = 0;
                void *buf;

                if (le->d_name[0] == '.') continue;
                if (!ends_with(le->d_name, ".so") &&
                    !strstr(le->d_name, ".so."))
                    continue;
                snprintf(lib, sizeof lib, "%s/%s", libdir, le->d_name);
                buf = read_all(lib, &len);
                if (!buf) continue;
                if (trace_on())
                    fprintf(stderr, "[dlopen] preload wheel library %s\n", lib);
                elf_dlopen_mem(buf, len, le->d_name);
                free(buf);
            }
            closedir(ld);
        }
        closedir(d);
    }
}

static void *load_from_file(const char *path)
{
    size_t len = 0;
    void *buf;
    const char *slash;
    void *h;

    preload_pep600_libs(path);
    buf = read_all(path, &len);
    if (!buf) return NULL;
    slash = strrchr(path, '/');
    h = elf_dlopen_mem(buf, len, slash ? slash + 1 : path);
    free(buf);
    return h;
}

// The host's own symbol scope. libnode.so exports napi_* symbols that also
// exist in the application's libace_napi.z.so; dlsym(RTLD_DEFAULT) finds the
// first one loaded, which may be the wrong implementation. Opening the host
// object again (musl returns the same handle and bumps its refcount) lets the
// loader ask the host first.
void *__wrap_dlopen(const char *filename, int flags);

static void *host_scope(void)
{
    static void *h = NULL;
    static int tried = 0;

    if (!tried) {
        Dl_info di;
        tried = 1;
        if (dladdr((void *)(uintptr_t)&__wrap_dlopen, &di) && di.dli_fname) {
            h = __real_dlopen(di.dli_fname, RTLD_NOW | RTLD_GLOBAL);
            if (trace_on())
                fprintf(stderr, "[dlopen] host scope %s -> %p\n",
                        di.dli_fname, h);
        }
    }
    return h;
}

static void *prefer_from_host(const char *name)
{
    void *h = host_scope();
    return h ? __real_dlsym(h, name) : NULL;
}

__attribute__((constructor)) static void dlopen_shim_ctor(void)
{
    elf_dl_set_prefer_sym(prefer_from_host);
}

void *__wrap_dlopen(const char *filename, int flags)
{
    void *h;
    char syserr[256];
    const char *e;

    if (!filename) return __real_dlopen(filename, flags);

    h = __real_dlopen(filename, flags);
    if (h) return h;

    // Capture the real error before calling anything else that may clear it.
    e = dlerror();
    snprintf(syserr, sizeof syserr, "%s", e ? e : "(no dlerror)");

    h = load_from_file(filename);
    if (h) {
        if (trace_on())
            fprintf(stderr, "[dlopen] %s: system loader failed (%s); "
                            "loaded by elf_dl\n", filename, syserr);
        return h;
    }

    fprintf(stderr, "[dlopen] %s: system loader failed (%s); "
                    "elf_dl could not load it either\n", filename, syserr);
    return NULL;
}

void *__wrap_dlsym(void *handle, const char *name)
{
    if (elf_dl_owns_handle(handle)) return elf_dlsym(handle, name);
    return __real_dlsym(handle, name);
}

int __wrap_dlclose(void *handle)
{
    if (elf_dl_owns_handle(handle)) return 0;
    return __real_dlclose(handle);
}
