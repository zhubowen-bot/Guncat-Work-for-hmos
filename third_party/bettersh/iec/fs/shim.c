// fs_shim.c — user-space "symlink" emulation (LD_PRELOAD build) for sandboxes that forbid symlink(2).
//
// Why this file exists
// ──────────────────
// This HarmonyOS device's sandbox **forbids creating symbolic links**: symlink()/symlinkat() are
// rejected in the host process, in command .so's, and in guests (all three layers), in every
// writable directory (errno=13 EACCES, occasionally ENOENT). Re-checking with lstat after a
// failure confirms the link really was not created (it returns ENOENT). Hard links are allowed
// (link() succeeds and both names share one inode). So operations such as "untar an archive
// containing symlinks", "npm/pip install creates symlinks", or "python venv creates the
// bin/python3 symlink" are bound to fail on this device — it is not a permissions
// misconfiguration, the capability simply does not exist at this layer.
//
// Representation (a spec defined by this project, not Linux semantics)
// ────────────────────────────────────────────
//   "symlink foo -> /target/path" is represented on the real filesystem as an **ordinary file**:
//       foo.IEC_SYMLINK      content = the target path string (no trailing NUL, length 1..4095)
//   The real name foo **does not exist**. The benefit is that one link occupies exactly one real
//   directory entry and does not collide with anything, so listing a directory only needs to
//   "rename" entries, never to "hide" anything — this is what makes the readdir implementation
//   below so lightweight (see the readdir section).
//
// How it takes effect
// ────────
// Loaded via LD_PRELOAD, exporting entries with the same names as libc. **Paths that do not
// concern us are passed through verbatim** to the real libc implementation (resolved once via
// dlsym(RTLD_NEXT, ...) and cached), so programs that never touch our links see no difference.
//
// Known limitations (stated honestly, not worked around)
// ──────────────────────────
//   * In a **statically linked** musl guest, dlsym(RTLD_NEXT) is unavailable (no dynamic symbol
//     table), and this module is entirely inert there; dynamic guests (musl dynamic / glibc)
//     and host processes work normally.
//   * Directory walks that bypass readdir cannot see the renaming: glibc's scandir/fts/glob and
//     the musl equivalents call **directly within the library**, so LD_PRELOAD cannot intercept
//     them, and they will treat *.IEC_SYMLINK as an ordinary file. See README "known limitations".
//   * *at entries with a real dirfd (not AT_FDCWD) rely on /proc/self/fd/<n>/ normalization; when
//     procfs is unavailable they are passed through verbatim (simulated links in intermediate
//     directories are then not expanded).
//
// Build: see README.md (must compile with both glibc and musl, -std=gnu11)

#define _GNU_SOURCE 1

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>

#include "intercept.h"
#include <stdarg.h>
#include <stddef.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

// ───────────────────────────── spec constants ─────────────────────────────

// Suffix of the marker file. The link's own name = name without the suffix; the marker file's name = name plus the suffix.
#define IEC_SUFFIX     ".IEC_SYMLINK"
#define IEC_SUFFIX_LEN (sizeof(IEC_SUFFIX) - 1)

// A second marker, for mode changes the kernel refuses (chmod on a file owned by
// the file-manager service, for example). Its content is the mode in octal, e.g.
// "0755"; the file it belongs to is its name without this suffix. See the
// "emulated chmod" section below.
#define IEC_CHMOD_SUFFIX     ".IEC_CHMOD"
#define IEC_CHMOD_SUFFIX_LEN (sizeof(IEC_CHMOD_SUFFIX) - 1)

// Upper bound on the target string length. Real symlink(2) on Linux likewise reports
// "target length > PATH_MAX-1 → ENAMETOOLONG" (measured: 4095 works, 5999 gives
// ENAMETOOLONG); the same limit is used here.
#define IEC_MAX_TARGET 4095

// Upper bound on expansion hops. The kernel's real symlink limit is 40; the spec requires 8, deliberately stricter.
#define IEC_MAX_HOPS 8

// Path buffer length. PATH_MAX=4096 and the longest path string is 4095, so 4096 is exactly
// one PATH_MAX; any intermediate result that overflows is treated as ENAMETOOLONG — the kernel
// cannot store a longer path either, so the behavior matches.
#define IEC_BUF 4096

// "Has a simulated link appeared in this session?" box64 mode (`-DIEC_SHIM_BOX64`) uses it as a
// **fast-path gate**: every open/stat would otherwise have to lstat each component to discover
// marker files, which is not cheap; when the process has never created or seen a marker (the vast
// majority of processes and of the time) the whole layer is skipped. Once it happens the flag is
// set to 1 and stays set — it has nothing to do with "whether a link exists in the kernel right
// now", it is just a conservative heuristic.
// Non-box64 builds set it too (no readers; the compiler may warn set-but-unused, which is harmless).
static int g_marker_seen = 0;

// ─────────────────────────── obtaining the real implementations ───────────────────────────
//
// Each entry resolves the real implementation once, on first use, and caches it in a static
// (`IEC_REAL(ptr, name)`, see shim_wrap.h). If it cannot be resolved (e.g. a static process)
// the entry reports ENOSYS instead of calling itself (which would recurse forever).
//
// How it is resolved depends on how this module is assembled — the two modes described in
// shim_wrap.h:
//
//   guest side (LD_PRELOAD, symbol interposition): `dlsym(RTLD_NEXT, …)` — preloading places
//     this .so **first** in the search order, so "the next one" is libc. Measured to work.
//
//   command .so side (`-Wl,--wrap=`, link-time replacement): the real implementation is the
//     linker-generated `__real_<name>` (a direct reference to libc, independent of search
//     order). The thin `shim_real_*` wrappers below wrap `__real_<name>` in a shape matching
//     the function-pointer type (variadic ones such as openat/fopen must be wrapped in a
//     layer before their address can be taken and called as-is). **RTLD_NEXT must not be
//     used**: command .so's are dlopen'ed by the main process and sit at the end of the
//     global search order, so there is nothing after "the next one" → NULL → every entry
//     degrades to ENOSYS (measured: after linking into libtoybox, every file operation
//     reported "Function not implemented").

static int (*r_openat)(int, const char*, int, ...);
static int (*r_fstatat)(int, const char*, struct stat*, int);
static int (*r_fstat)(int, struct stat*);
static int (*r_stat)(const char*, struct stat*);
static int (*r_lstat)(const char*, struct stat*);
static int (*r_chmod)(const char*, mode_t);
static int (*r_fchmod)(int, mode_t);
static int (*r_fchmodat)(int, const char*, mode_t, int);
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
static int (*r_utimensat)(int, const char*, const struct timespec[2], int);

#ifdef INT_WARP
/* Command .so mode: the real implementation is the linker-provided __real_<name>. Variadic
 * ones (the openat/fopen family) must be wrapped in a same-signature function to take their address. */
#include <stdarg.h>
extern int __real_openat(int, const char*, int, ...);
extern int __real_fstatat(int, const char*, struct stat*, int);
extern int __real_fstat(int, struct stat*);
extern int __real_stat(const char*, struct stat*);
extern int __real_lstat(const char*, struct stat*);
extern int __real_chmod(const char*, mode_t);
extern int __real_fchmod(int, mode_t);
extern int __real_fchmodat(int, const char*, mode_t, int);
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
extern int __real_utimensat(int, const char*, const struct timespec[2], int);

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
static int shim_real_utimensat(int d, const char* p, const struct timespec t[2], int f) {
    return __real_utimensat(d, p, t, f);
}

/* The two stdio functions (fopen/freopen) are library functions too, so they also go through __real_* */
extern FILE* __real_fopen(const char*, const char*);
extern FILE* __real_freopen(const char*, const char*, FILE*);
static FILE* shim_real_fopen(const char* p, const char* m) { return __real_fopen(p, m); }
static FILE* shim_real_freopen(const char* p, const char* m, FILE* s) { return __real_freopen(p, m, s); }
#endif

// glibc marks the path argument of stat/lstat/opendir as __nonnull, which makes a direct
// "!path" test trigger -Wnonnull-compare. The preload layer really can receive a
// manually constructed NULL from elsewhere, so this defense must stay; testing it in a small
// non-inlined function removes the warning without letting the check be optimized away.
static __attribute__((noinline)) int iec_is_null(const void* p) { return p == NULL; }

// ─────────────────────────── name / string-building helpers ───────────────────────────

// Look only at the **last component** (basename): does it end with our suffix?
// The name must be longer than the suffix itself — ".IEC_SYMLINK" alone is not a link (stripping the suffix leaves an empty name).
static int name_has_suffix(const char* path) {
    const char* base = strrchr(path, '/');
    base = base ? base + 1 : path;
    size_t n = strlen(base);
    if (n <= IEC_SUFFIX_LEN) return 0;
    return memcmp(base + n - IEC_SUFFIX_LEN, IEC_SUFFIX, IEC_SUFFIX_LEN) == 0;
}

// Compute the marker file name from the link name: if it already carries the suffix use it
// as-is, otherwise append the suffix.
// On failure (too long for the kernel to store this path) return -1 / ENAMETOOLONG.
static int marker_name(const char* path, char* out, size_t outsz) {
    size_t n = strlen(path);
    if (name_has_suffix(path)) {
        if (n + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
        memcpy(out, path, n + 1);
        return 0;
    }
    if (n + IEC_SUFFIX_LEN + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
    memcpy(out, path, n);
    memcpy(out + n, IEC_SUFFIX, IEC_SUFFIX_LEN + 1);
    return 0;
}

static int cat_raw(char* buf, size_t* len, size_t cap, const char* s, size_t slen) {
    if (*len + slen + 1 > cap) return -1;
    memcpy(buf + *len, s, slen);
    *len += slen;
    buf[*len] = 0;
    return 0;
}

// Append a '/' if needed. **Do not append** when len==0 — a relative path must not become absolute just because of string concatenation.
static int cat_sep(char* buf, size_t* len, size_t cap) {
    if (*len == 0 || buf[*len - 1] == '/') return 0;
    if (*len + 2 > cap) return -1;
    buf[(*len)++] = '/';
    buf[*len] = 0;
    return 0;
}

// Naive concatenation out = dir + "/" + base (does not resolve a trailing '/' already present in dir).
static int join2(const char* dir, const char* base, char* out, size_t outsz) {
    size_t nl = 0;
    out[0] = 0;
    if (cat_raw(out, &nl, outsz, dir, strlen(dir)) < 0) return -1;
    if (cat_sep(out, &nl, outsz) < 0) return -1;
    if (cat_raw(out, &nl, outsz, base, strlen(base)) < 0) return -1;
    return 0;
}

// Split path into "directory part + last component". Returns -1 when the last component is
// empty (trailing slash) or the whole path is empty; the caller then passes through verbatim
// (leaving the kernel's own semantics untouched).
static int split_last(const char* path, char* dir, size_t dirsz, const char** base) {
    const char* s = strrchr(path, '/');
    if (!s) {
        if (*path == 0) return -1;
        if (strlen(".") + 1 > dirsz) return -1;
        strcpy(dir, ".");
        *base = path;
        return 0;
    }
    if (s[1] == 0) return -1;                    // trailing slash
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

// ─────────────────────────── reading the marker file ───────────────────────────

// Read the marker file contents (which are the target string). On success return the length
// (1..4095) with out NUL-terminated.
// Empty content or more than 4095 → ENAMETOOLONG (the representation is corrupt, not a link).
static ssize_t read_marker(const char* marker, char* out, size_t outsz) {
    int (*fa)(int, const char*, int, ...) = IEC_REAL(r_openat, openat);
    if (!fa) { errno = ENOSYS; return -1; }
    int fd = fa(AT_FDCWD, marker, O_RDONLY | O_CLOEXEC | O_NOFOLLOW, 0);
    if (fd < 0) return -1;
    char tmp[IEC_MAX_TARGET + 1];
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
    if (n == 0 || n > IEC_MAX_TARGET) { errno = ENAMETOOLONG; return -1; }
    if ((size_t)n + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
    memcpy(out, tmp, (size_t)n);
    out[n] = 0;
    return n;
}

// ─────────────────────── "is this path one of our links?" ───────────────────────
//
// Cheap and unambiguous criteria (the two rules from the spec):
//   a) the last component itself ends with .IEC_SYMLINK and is a **regular file** → the marker file is that path itself;
//   b) otherwise <path>.IEC_SYMLINK is a regular file → that is the marker file.
// Returns 1 (yes, marker filled in), 0 (no), -1 (error, errno set).
//
// Only regular files count: a directory or a real symlink with the same name is not our
// marker, so the user's own files are never swallowed.
// If both a) and b) hold (a real file coexists with a same-named marker), the marker wins —
// that is an invalid state our symlink() would reject, and if it really occurs we treat it as
// "link semantics first".
static int is_simlink(const char* path, char* marker, size_t markersz) {
    int (*fl)(const char*, struct stat*) = IEC_REAL(r_lstat, lstat);
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

    char m[IEC_BUF];
    if (marker_name(path, m, sizeof m) < 0) {
        // Appending the suffix would exceed PATH_MAX → such a marker file cannot possibly
        // exist in the kernel, so this is "not a link", not "an error".
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

// ─────────────────────────── (dirfd, path) normalization ───────────────────────────

static int resolve_simlinks(const char* path, char* out, size_t outsz);

// Is /proc/self/fd available (used to turn a real dirfd into a path that can be resolved)? Probed only once.
static int proc_available(void) {
    static int cached = -1;
    if (cached < 0) {
        int (*fl)(const char*, struct stat*) = IEC_REAL(r_lstat, lstat);
        struct stat st;
        cached = (fl && fl("/proc/self/fd", &st) == 0) ? 1 : 0;
    }
    return cached;
}

// Turn (dirfd, path) into a self-contained path for later resolution.
// Returns 0 on success (out filled in), 1 if it cannot be normalized (caller should pass
// through verbatim), -1 on error.
// Note: relative paths with AT_FDCWD are **not** expanded via chdir — they stay relative and
// are resolved by the kernel against the current working directory, exactly as without preloading.
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

// ─────────────────── /proc/self/exe substitute (IEC_GUEST_EXE) ───────────────────
//
// A guest is "somebody else's binary", loaded and executed by the elfloader **inside the host
// process**, so the /proc/self/exe the kernel shows is the host's appspawn, not the guest
// itself. Yet "introspecting who I am" depends entirely on it: finding one's own installation
// directory (the other half of $ORIGIN), re-exec'ing oneself, reading one's own image
// checksum…
// Without a fix, programs like the device-side hdc that "read /proc/self/exe and then
// fork/exec themselves" are doomed in this sandbox (measured: touching this path gets the
// process killed by the sandbox with SIGSYS(31), rc=159, not even producing output).
//
// The real value is placed in the IEC_GUEST_EXE environment variable by procmgr before
// loading (see ChildRunElf in procmgr.cpp); here we only do a **symbol-layer** substitution:
// every path entry taken over by this shim (readlink/stat/lstat/open/access/fopen/realpath…)
// translates this path to the real value.
// When IEC_GUEST_EXE is unset (command .so side, the host running itself, a guest under qemu)
// this whole layer is inert and everything passes through verbatim.
//
// Boundaries (stated honestly, not worked around):
//   1) a guest's **ld.so internals** read /proc/self/exe to compute $ORIGIN, which LD_PRELOAD
//      cannot intercept — so procmgr's fallback of "adding the guest's own directory to
//      LD_LIBRARY_PATH" must remain;
//   2) a statically linked guest has no preload and cannot benefit from this substitute;
//   3) unlink/rename/link **do not** substitute: on real Linux, unlinking /proc/self/exe is
//      EPERM, and substituting would instead delete the guest's own image (they go through
//      last_component_cand/norm_at, while this layer only takes effect in resolve_simlinks and
//      do_readlink — precisely for this reason).
#define IEC_EXE_PATH "/proc/self/exe"

/* ── Optional tracing (IEC_SHIM_TRACE=1)────────────────────────────────────────────
 * The most frustrating failure mode in this layer is "looks like it should take effect but
 * doesn't", and there is no return value to inspect. Turning this switch on dumps the key
 * decisions to stderr (when preloaded, that is the guest's stderr, i.e. the terminal).
 * When the variable is unset there is only one getenv on first use, then a cache. */
static int iec_trace_on(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("IEC_SHIM_TRACE");
        cached = (v && *v && v[0] != '0') ? 1 : 0;
    }
    return cached;
}

static void iec_trace(const char* fmt, ...) {
    if (!iec_trace_on()) return;
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

/* Read the real value once and cache it (the environment variable does not change over the process lifetime). An empty string counts as unset. */
static const char* guest_exe(void) {
    static const char* cached;
    static int inited;
    if (!inited) {
        const char* v = getenv("IEC_GUEST_EXE");
        cached = (v && *v) ? v : NULL;
        inited = 1;
    }
    return cached;
}

/* Is path /proc/self/exe (or a subpath /proc/self/exe/…)?
 * On match: *rest points at the remaining part **inside the caller's own string** (the
 * "/…" suffix for a subpath, otherwise ""), and 1 is returned; otherwise 0.
 * ⚠ **Never** copy path into a local array and hand out a pointer into it — that is
 *   use-after-return: it happens to work under glibc, but under musl the stack gets
 *   overwritten and the comparison silently fails, with the symptom "all glibc guests pass,
 *   not a single musl guest takes effect" (measured). Compare against the original string.
 * A trailing '/' is always treated as "it is itself" (in the kernel "/proc/self/exe/" on a
 * file gives ENOTDIR; here we use the more practical semantics). */
static int virt_exe_split(const char* path, const char** rest) {
    if (!path || path[0] != '/') return 0;
    static const char kPre[] = IEC_EXE_PATH;
    const size_t kl = sizeof(kPre) - 1;
    if (strncmp(path, kPre, kl) != 0) return 0;
    const char* p = path + kl;
    if (*p == '\0') { *rest = ""; return 1; }
    if (*p != '/') return 0;                 // "/proc/self/exeXXX" is not it
    const char* q = p;
    while (*q == '/') q++;
    if (*q == '\0') { *rest = ""; return 1; } // only a trailing slash
    *rest = p;                                // "/…" (the remainder, including the leading '/')
    return 1;
}

/* Replace /proc/self/exe[subpath] with the guest's real value (+ remainder). Returns 1 on
 * match, 0 if it is not this path, -1 if the name is too long (errno=ENAMETOOLONG). */
static int virt_exe_path(const char* path, char* out, size_t outsz) {
    const char* gx = guest_exe();
    if (!gx) return 0;
    const char* rest;
    if (!virt_exe_split(path, &rest)) return 0;
    int n = snprintf(out, outsz, "%s%s", gx, rest);
    if (n < 0 || (size_t)n >= outsz) { errno = ENAMETOOLONG; return -1; }
    return 1;
}

/* Accept only "/proc/self/exe" itself (no subpath) — readlink wants the "link target", and a subpath is not a link. */
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

/* Fabricated "symlink" stat — **no longer used**, kept here for one reason only: to explain
 * why it is unnecessary.
 * In real procfs /proc/self/exe is a **magic link**, and lstat returns the same shape no
 * matter what it points to (mode=S_IFLNK|0777, size=0, nlink=1, dev/ino belonging to procfs).
 * So passing through to the real lstat is already correct; synthesizing one would instead
 * replace st_dev/st_ino with those of the "underlying file" (measured on a real Linux host:
 * the kernel reports the procfs ino, and the two differ). The first version implemented a
 * synthetic version, which turned out to be less faithful than the real implementation, so it
 * was removed. */

// ─────────────────────────── recursive resolution ───────────────────────────
//
// Walk component by component: for each component, first check whether it is a simulated
// link; if so, splice its target into the pending string and start over.
// Key design: **do not fold "." / ".." ourselves**; only concatenate and hand the result to
// the kernel unchanged.
//   Rationale: the kernel is authoritative. For example, stat("nodir/../x") gives ENOENT in
//   the real implementation (because nodir does not exist), whereas popping ".." ourselves
//   would turn it into stat("x"), which might succeed. Leave ".." in the string as-is and the
//   kernel will resolve it in the proper order.
// Both the target length and the hop count are bounded; exceeding them yields ENAMETOOLONG /
// ELOOP respectively (the same errno as real links).
/* ── path mapping table ────────────────────────────────────────────────────────────
 * Rewrites absolute paths that guests have "hard-coded at compile time but do not exist in
 * the sandbox's read-only root" to our directories.
 * Currently there is only one entry:
 *   /usr/share/X11/xkb — libxkbcommon hard-codes its include path to this (measured: it does
 *   **not** honor XKB_CONFIG_ROOT). The guest's / is the read-only app root, the directory
 *   does not exist → "failed to add default include path" → then it dereferences null in
 *   xkb_context_include_path_*, SIGSEGV(139), and the process dies in about 3 seconds.
 * It lives here (rather than in a separate preload) because this function is the common entry
 * point for whole paths.
 * When adding entries note: `to_rel` is a path relative to $IEC_SYSROOT. */
static const struct { const char* from; const char* to_rel; } kPathMap[] = {
    /* Matched in order, first hit returns — put specific entries first and the fallback last */
    /* The system bin prefixes the exec server rewrites into FAKE_SYSROOT. A
     * shell searches PATH itself (stat/access before exec), so without these
     * entries a bare command name never reaches the exec service: the shell
     * reports "inaccessible or not found" although the launcher is present in
     * the fake root. The entries also make `ls /bin` show that root. */
    { "/bin", "bin" },
    { "/sbin", "sbin" },
    { "/usr/bin", "usr/bin" },
    { "/usr/local/bin", "usr/local/bin" },
    { "/usr/sbin", "usr/sbin" },
    { "/system/bin", "system/bin" },
    { "/vendor/bin", "vendor/bin" },
    { "/system/lib", "system/lib" },
    { "/data/app/bin", "data/app/bin" },
    { "/usr/share/X11/xkb", "usr/share/x11/xkb" },
    /* Guests have **no real root filesystem**; absolute paths such as `/usr/...` do not exist
     * on the host. Debs installed by apt are full of these: code-server's
     * `usr/bin/code-server` contains
     *     exec /usr/lib/code-server/bin/code-server "$@"
     * mksh stats the path itself before exec'ing, and if the mapping is missing it only
     * reports "inaccessible or not found" — execve is never even reached (so procmgr's
     * fallback cannot help either).
     * This entry covers all of /usr/...; it is the coarsest, hence last. */
    { "/usr", "usr" },
};

static const char* map_path(const char* path, char* buf, size_t bufsz) {
    const char* root = getenv("IEC_SYSROOT");
    if (!root || !*root || !path) return path;
    for (size_t i = 0; i < sizeof kPathMap / sizeof kPathMap[0]; i++) {
        size_t n = strlen(kPathMap[i].from);
        if (strncmp(path, kPathMap[i].from, n) != 0) continue;
        if (path[n] != '\0' && path[n] != '/') continue;   /* don't match /usr/share/X11/xkbevil by accident */
        snprintf(buf, bufsz, "%s/%s%s", root, kPathMap[i].to_rel, path + n);
        iec_trace("[shim] map_path: %s -> %s\n", path, buf);
        return buf;
    }
    return path;
}

static int resolve_simlinks(const char* path, char* out, size_t outsz) {
    /* Go through the path mapping table first (see kPathMap), then apply the /proc/self/exe
     * substitute and resolve symlinks. */
    char mapped[IEC_BUF];
    {
        const char* mp = map_path(path, mapped, sizeof mapped);
        if (mp != path) path = mp;
    }
    /* The /proc/self/exe substitute (see the section above): first translate to the guest's
     * real value, then resolve symlinks as usual.
     * It lives here because this function is the common entry point for whole paths —
     * stat/realpath/open/access/fopen all go through it. */
    char virt[IEC_BUF];
    {
        int vr = virt_exe_path(path, virt, sizeof virt);
        iec_trace("[shim] resolve_simlinks(%s) virt=%d\n", path, vr);
        if (vr < 0) return -1;
        if (vr == 1) path = virt;
    }
    char work[IEC_BUF];
    size_t plen = strlen(path);
    if (plen >= sizeof work) { errno = ENAMETOOLONG; return -1; }
    memcpy(work, path, plen + 1);

    unsigned hops = 0;
    for (;;) {
        char acc[IEC_BUF];              // accepted prefix (the link's containing directory is exactly this)
        size_t acclen = 0;
        acc[0] = 0;
        // An absolute path's prefix starts at "/" — without this, "/bin/sh" would be built as
        // "bin/sh" (cat_sep deliberately does not add '/' when len==0, for relative paths).
        if (work[0] == '/') { acc[0] = '/'; acc[1] = 0; acclen = 1; }

        const char* p = work;
        int restart = 0;
        while (*p) {
            while (*p == '/') p++;
            if (!*p) break;
            const char* seg = p;
            while (*p && *p != '/') p++;
            size_t seglen = (size_t)(p - seg);

            char cand[IEC_BUF];         // acc + "/" + seg
            size_t cl = 0;
            cand[0] = 0;
            if (cat_raw(cand, &cl, sizeof cand, acc, acclen) < 0 ||
                cat_sep(cand, &cl, sizeof cand) < 0 ||
                cat_raw(cand, &cl, sizeof cand, seg, seglen) < 0) {
                errno = ENAMETOOLONG;
                return -1;
            }

            char marker[IEC_BUF];
            int r = is_simlink(cand, marker, sizeof marker);
            if (r < 0) return -1;
            if (r == 0) {
                memcpy(acc, cand, cl + 1);
                acclen = cl;
                continue;
            }

            // Hit a simulated link: append the remaining part to its target and resolve from scratch.
            char target[IEC_BUF];
            ssize_t tl = read_marker(marker, target, sizeof target);
            if (tl < 0) return -1;
            if (++hops > IEC_MAX_HOPS) { errno = ELOOP; return -1; }

            char next[IEC_BUF];
            size_t nl = 0;
            next[0] = 0;
            int bad;
            if (target[0] == '/') {
                bad = cat_raw(next, &nl, sizeof next, target, (size_t)tl) < 0;
            } else {
                // Relative target: relative to the link's **containing directory** (that is acc;
                // an empty acc means the start of a relative path)
                bad = cat_raw(next, &nl, sizeof next, acc, acclen) < 0 ||
                      cat_sep(next, &nl, sizeof next) < 0 ||
                      cat_raw(next, &nl, sizeof next, target, (size_t)tl) < 0;
            }
            // p points at the part after the link ('\0' or '/...'); splice it back unchanged
            size_t restlen = strlen(p);
            if (!bad && restlen) bad = cat_raw(next, &nl, sizeof next, p, restlen) < 0;
            if (bad) { errno = ENAMETOOLONG; return -1; }

            memcpy(work, next, nl + 1);
            restart = 1;
            break;
        }

        if (!restart) {
            // Preserve trailing-slash semantics (stat("dir/") and stat("dir") are not equivalent in the kernel)
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

// Resolve a whole path (dirfd version). changed=0 means our links were not involved and the
// caller should pass through verbatim; changed=1 means out holds the resolved result.
static int resolve_at(int dirfd, const char* path, char* out, size_t outsz, int* changed) {
    char norm[IEC_BUF];
    int nr = norm_at(dirfd, path, norm, sizeof norm);
    if (nr != 0) return nr;                       // 1=pass through, -1=error

    char res[IEC_BUF];
    if (resolve_simlinks(norm, res, sizeof res) < 0) return -1;
    if (strcmp(res, norm) == 0) { *changed = 0; return 0; }
    if (strlen(res) + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
    strcpy(out, res);
    *changed = 1;
    return 0;
}

// Candidate path with "the last component not followed": preceding components are expanded
// through simulated links while the last component is left untouched.
// readlink / lstat / open(O_NOFOLLOW) / unlink / rename are all built on this view.
// Returns 0 (success, is_link=m filled in), 1 (cannot normalize, should pass through), -1 (error).
static int last_component_cand(int dirfd, const char* path,
                               char* cand, size_t candsz,
                               char* marker, size_t markersz, int* is_link) {
    char norm[IEC_BUF];
    int nr = norm_at(dirfd, path, norm, sizeof norm);
    if (nr != 0) return nr;

    char dir[IEC_BUF];
    const char* base;
    if (split_last(norm, dir, sizeof dir, &base) < 0) return 1;

    char dirr[IEC_BUF];
    if (resolve_simlinks(dir, dirr, sizeof dirr) < 0) return -1;
    if (join2(dirr, base, cand, candsz) < 0) { errno = ENAMETOOLONG; return -1; }

    int r = is_simlink(cand, marker, markersz);
    if (r < 0) return -1;
    *is_link = r;
    return 0;
}

// ─────────────────────────── struct stat for a fabricated link ───────────────────────────

// lstat of a real symlink: mode=S_IFLNK|0777, size=target string length, nlink=hard-link count,
// blocks=0 (a fast symlink occupies no disk blocks), blksize=4096. Everything is matched item
// by item here; st_dev/st_ino/owner/timestamps are taken from the marker file itself (it is
// what represents this link's inode).
static int fill_link_stat(const char* marker, struct stat* buf) {
    int (*fl)(const char*, struct stat*) = IEC_REAL(r_lstat, lstat);
    if (!fl) { errno = ENOSYS; return -1; }
    struct stat real;
    if (fl(marker, &real) != 0) return -1;

    char target[IEC_BUF];
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

// Create a link: write a marker file whose content is the target string. Semantics match real symlink(2):
//   the real link name already exists → EEXIST (real symlink also gives EEXIST, regardless of file or directory)
//   the marker file already exists    → EEXIST (obtained atomically via O_CREAT|O_EXCL)
//   empty target                      → ENOENT (measured: Linux symlink("") gives ENOENT)
//   target > 4095                     → ENAMETOOLONG (same as Linux)
// Missing directory / read-only / no permission etc. are all reported by the real open with
// the same errno as the kernel.
static int do_symlink(int dirfd, const char* target, const char* linkpath) {
    if (!target || !linkpath) { errno = EFAULT; return -1; }
    size_t tl = strlen(target);
    if (tl == 0) { errno = ENOENT; return -1; }
    if (tl > IEC_MAX_TARGET) { errno = ENAMETOOLONG; return -1; }

    // The link name (and its containing directory) may itself involve simulated links — fix up
    // the location first, then create the marker.
    char cand[IEC_BUF], oldmarker[IEC_BUF];
    int isl = 0;
    int r = last_component_cand(dirfd, linkpath, cand, sizeof cand,
                                oldmarker, sizeof oldmarker, &isl);
    if (r > 0) {
        // Cannot normalize (real dirfd + no procfs): fall back to the real symlink, which at
        // least is not semantically wrong.
        int (*fs)(const char*, const char*) = IEC_REAL(r_symlink, symlink);
        if (!fs) { errno = ENOSYS; return -1; }
        return fs(target, linkpath);
    }
    if (r < 0) return -1;
    if (isl) { errno = EEXIST; return -1; }

    int (*fl)(const char*, struct stat*) = IEC_REAL(r_lstat, lstat);
    if (!fl) { errno = ENOSYS; return -1; }
    struct stat st;
    if (fl(cand, &st) == 0) { errno = EEXIST; return -1; }

    char marker[IEC_BUF];
    if (marker_name(cand, marker, sizeof marker) < 0) return -1;

    int (*fa)(int, const char*, int, ...) = IEC_REAL(r_openat, openat);
    if (!fa) { errno = ENOSYS; return -1; }
    int fd = fa(AT_FDCWD, marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;                        // already exists naturally means EEXIST

    size_t off = 0;
    while (off < tl) {
        ssize_t w = write(fd, target + off, tl - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            close(fd);
            int (*fu)(int, const char*, int) = IEC_REAL(r_unlinkat, unlinkat);
            if (fu) fu(AT_FDCWD, marker, 0);       // don't leave half a link behind
            errno = saved;
            return -1;
        }
        off += (size_t)w;
    }
    close(fd);
    g_marker_seen = 1;
    return 0;
}

int IEC_EXPORT(symlink)(const char* target, const char* linkpath) {
    return do_symlink(AT_FDCWD, target, linkpath);
}

int IEC_EXPORT(symlinkat)(const char* target, int dirfd, const char* linkpath) {
    return do_symlink(dirfd, target, linkpath);
}

// ─────────────────────────── readlink / readlinkat ───────────────────────────
//
// readlink does not follow the **last component**, but intermediate components are resolved
// (kernel behavior). Therefore: expand the directory part to a real path, then test whether
// "<dir>/<base>" is one of our links.
// Return the length, do not append NUL, silently truncate when too long — all per readlink(2).
static ssize_t do_readlink(int dirfd, const char* path, char* buf, size_t bufsiz) {
    if (!path || !buf) { errno = EFAULT; return -1; }
    /* /proc/self/exe: the "link target" reported to the caller is the guest's real path.
     * Preserve readlink(2) semantics: no NUL terminator, silently truncate when too long,
     * EINVAL when bufsiz==0. */
    iec_trace("[shim] do_readlink(%s) dirfd=%d\n", path, dirfd);
    if (dirfd == AT_FDCWD) {
        char virt[IEC_BUF];
        int vr = virt_exe_self(path, virt, sizeof virt);
        iec_trace("[shim]   virt_exe_self=%d\n", vr);
        if (vr < 0) return -1;
        if (vr == 1) {
            if (bufsiz == 0) { errno = EINVAL; return -1; }
            size_t n = strlen(virt);
            if (n > bufsiz) n = bufsiz;
            memcpy(buf, virt, n);
            return (ssize_t)n;
        }
    }
    char cand[IEC_BUF], marker[IEC_BUF];
    int isl = 0;
    int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
    if (r < 0) return -1;
    if (r > 0) {
        ssize_t (*fr)(int, const char*, char*, size_t) = IEC_REAL(r_readlinkat, readlinkat);
        if (!fr) { errno = ENOSYS; return -1; }
        return fr(dirfd, path, buf, bufsiz);
    }
    if (isl) {
        if (bufsiz == 0) { errno = EINVAL; return -1; }   // measured: real readlink gives EINVAL
        char target[IEC_BUF];
        ssize_t tl = read_marker(marker, target, sizeof target);
        if (tl < 0) return -1;
        size_t n = (size_t)tl < bufsiz ? (size_t)tl : bufsiz;
        memcpy(buf, target, n);
        return (ssize_t)n;
    }
    ssize_t (*fr)(const char*, char*, size_t) = IEC_REAL(r_readlink, readlink);
    if (!fr) { errno = ENOSYS; return -1; }
    return fr(cand, buf, bufsiz);
}

ssize_t IEC_EXPORT(readlink)(const char* path, char* buf, size_t bufsiz) {
    return do_readlink(AT_FDCWD, path, buf, bufsiz);
}

ssize_t IEC_EXPORT(readlinkat)(int dirfd, const char* path, char* buf, size_t bufsiz) {
    return do_readlink(dirfd, path, buf, bufsiz);
}

// ─────────────────────────── emulated chmod (.IEC_CHMOD) ───────────────────────────
//
// The sandbox refuses chmod on files it does not own: /storage/Users/... is
// presented as owned by the file-manager service, so chmod returns EPERM even
// though the directory is writable. A sidecar file keeps the mode instead:
//
//     chmod foo 0755          where the kernel says EPERM
//     -> foo.IEC_CHMOD        content "0755"
//
// Reads (stat/lstat/fstatat/fstat/faccessat) patch the mode from the sidecar when
// it exists, so tools that inspect the executable bit see the change. The real
// open/read/write path is deliberately untouched: this emulates metadata, not
// access control. Marker creation is best effort; when even that fails the
// original chmod errno is returned.

static int chmod_marker_name(const char* path, char* out, size_t outsz) {
    size_t n = strlen(path);
    while (n > 1 && path[n - 1] == '/') n--;           /* "dir/" and "dir" name the same file */
    if (n + IEC_CHMOD_SUFFIX_LEN + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
    memcpy(out, path, n);
    memcpy(out + n, IEC_CHMOD_SUFFIX, IEC_CHMOD_SUFFIX_LEN + 1);
    return 0;
}

static int is_chmod_marker_name(const char* name) {
    size_t n = strlen(name);
    return n > IEC_CHMOD_SUFFIX_LEN &&
           memcmp(name + n - IEC_CHMOD_SUFFIX_LEN, IEC_CHMOD_SUFFIX,
                  IEC_CHMOD_SUFFIX_LEN) == 0;
}

static int read_chmod_marker(const char* path, mode_t* out) {
    char marker[IEC_BUF];
    if (chmod_marker_name(path, marker, sizeof marker) < 0) return 0;

    int (*fo)(int, const char*, int, ...) = IEC_REAL(r_openat, openat);
    if (!fo) return 0;
    int fd = fo(AT_FDCWD, marker, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return 0;

    char buf[16];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = '\0';

    char* end = NULL;
    unsigned long m = strtoul(buf, &end, 8);
    if (end == buf || m > 07777) return 0;
    *out = (mode_t)m;
    return 1;
}

static int write_chmod_marker(const char* path, mode_t mode) {
    char marker[IEC_BUF];
    if (chmod_marker_name(path, marker, sizeof marker) < 0) return -1;

    int (*fo)(int, const char*, int, ...) = IEC_REAL(r_openat, openat);
    if (!fo) { errno = ENOSYS; return -1; }
    int fd = fo(AT_FDCWD, marker,
                O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;

    char buf[8];
    int len = snprintf(buf, sizeof buf, "%04o", (unsigned)(mode & 07777));
    ssize_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, buf + off, (size_t)(len - off));
        if (w <= 0) { int e = errno; close(fd); errno = e; return -1; }
        off += w;
    }
    if (close(fd) != 0) return -1;
    return 0;
}

static void remove_chmod_marker(const char* path) {
    char marker[IEC_BUF];
    if (chmod_marker_name(path, marker, sizeof marker) < 0) return;
    int (*fu)(int, const char*, int) = IEC_REAL(r_unlinkat, unlinkat);
    if (fu) fu(AT_FDCWD, marker, 0);
}

static void apply_chmod_marker(const char* path, struct stat* st) {
    if (!st || S_ISLNK(st->st_mode)) return;
    mode_t mode;
    if (!read_chmod_marker(path, &mode)) return;
    st->st_mode = (st->st_mode & ~(mode_t)07777) | mode;
}

// Path behind an fd, used by fchmod/fstat. Returns -1 for pipes, sockets and
// anything else that does not name a file; "(deleted)" is stripped so a marker
// is not created next to a name that no longer exists.
static int fd_path(int fd, char* out, size_t outsz) {
    char proc[64];
    int n = snprintf(proc, sizeof proc, "/proc/self/fd/%d", fd);
    if (n < 0 || (size_t)n >= sizeof proc) return -1;

    ssize_t (*frl)(const char*, char*, size_t) = IEC_REAL(r_readlink, readlink);
    if (!frl) return -1;
    ssize_t len = frl(proc, out, outsz - 1);
    if (len <= 0 || (size_t)len >= outsz) return -1;
    out[len] = '\0';
    if (out[0] != '/') return -1;

    static const char kDeleted[] = " (deleted)";
    const size_t dl = sizeof kDeleted - 1;
    if ((size_t)len > dl && memcmp(out + len - dl, kDeleted, dl) == 0)
        out[len - dl] = '\0';
    return 0;
}

// Absolute form of (dirfd, path), for creating/looking up a marker with
// AT_FDCWD. Relative names with AT_FDCWD are resolved against getcwd().
static int make_abs_at(int dirfd, const char* path, char* out, size_t outsz) {
    if (path[0] == '/') {
        size_t n = strlen(path);
        if (n + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
        memcpy(out, path, n + 1);
        return 0;
    }

    char dir[IEC_BUF];
    if (dirfd == AT_FDCWD) {
        if (!getcwd(dir, sizeof dir)) return -1;
    } else {
        if (fd_path(dirfd, dir, sizeof dir) != 0) return -1;
    }

    int n = snprintf(out, outsz, "%s/%s", dir, path);
    if (n < 0 || (size_t)n >= outsz) { errno = ENAMETOOLONG; return -1; }
    return 0;
}

static void apply_chmod_marker_at(int dirfd, const char* path, int changed,
                                  const char* resolved, struct stat* st) {
    if (changed) {
        apply_chmod_marker(resolved, st);
        return;
    }
    char abs[IEC_BUF];
    if (make_abs_at(dirfd, path, abs, sizeof abs) == 0) apply_chmod_marker(abs, st);
}

static int chmod_may_emulate(int e) {
    switch (e) {
        case EPERM:
        case EACCES:
        case EROFS:
        case EOPNOTSUPP:
        case ENOSYS:
            return 1;
        default:
            return 0;
    }
}

int IEC_EXPORT(chmod)(const char* path, mode_t mode) {
    if (iec_is_null(path)) { errno = EFAULT; return -1; }

    char res[IEC_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    const char* target = (r == 0 && changed) ? res : path;

    int (*fc)(const char*, mode_t) = IEC_REAL(r_chmod, chmod);
    if (!fc) { errno = ENOSYS; return -1; }

    if (fc(target, mode) == 0) {
        remove_chmod_marker(target);
        return 0;
    }

    const int saved = errno;
    if (!chmod_may_emulate(saved)) { errno = saved; return -1; }

    char abs[IEC_BUF];
    if (make_abs_at(AT_FDCWD, target, abs, sizeof abs) != 0 ||
        write_chmod_marker(abs, mode) != 0) {
        errno = saved;
        return -1;
    }
    return 0;
}

int IEC_EXPORT(fchmod)(int fd, mode_t mode) {
    int (*fc)(int, mode_t) = IEC_REAL(r_fchmod, fchmod);
    if (!fc) { errno = ENOSYS; return -1; }

    if (fc(fd, mode) == 0) {
        char path[IEC_BUF];
        if (fd_path(fd, path, sizeof path) == 0) remove_chmod_marker(path);
        return 0;
    }

    const int saved = errno;
    if (!chmod_may_emulate(saved)) { errno = saved; return -1; }

    char path[IEC_BUF];
    if (fd_path(fd, path, sizeof path) != 0 || write_chmod_marker(path, mode) != 0) {
        errno = saved;
        return -1;
    }
    return 0;
}

int IEC_EXPORT(fchmodat)(int dirfd, const char* path, mode_t mode, int flags) {
    if (iec_is_null(path)) { errno = EFAULT; return -1; }
    int (*fc)(int, const char*, mode_t, int) = IEC_REAL(r_fchmodat, fchmodat);
    if (!fc) { errno = ENOSYS; return -1; }

    // chmod has no "do not follow" form on Linux; leave the flags to the real
    // implementation (it reports EOPNOTSUPP) rather than inventing semantics.
    if (flags != 0) return fc(dirfd, path, mode, flags);

    char res[IEC_BUF];
    int changed = 0;
    int r = resolve_at(dirfd, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    const char* target = (r == 0 && changed) ? res : path;

    int rc = changed ? fc(AT_FDCWD, res, mode, 0) : fc(dirfd, path, mode, 0);
    if (rc == 0) {
        remove_chmod_marker(target);
        return 0;
    }

    const int saved = errno;
    if (!chmod_may_emulate(saved)) { errno = saved; return -1; }

    char abs[IEC_BUF];
    if (make_abs_at(dirfd, target, abs, sizeof abs) != 0 ||
        write_chmod_marker(abs, mode) != 0) {
        errno = saved;
        return -1;
    }
    return 0;
}

// ─────────────────────────── lstat / stat / fstatat ───────────────────────────

// archive_write_disk() restores timestamps with utimensat(..., AT_SYMLINK_NOFOLLOW) after
// creating a symlink. Our link is a marker file, so following the target would update the
// wrong inode; set the marker's own timestamps instead. This is what lets a symlink entry
// extract without "Can't restore time".
int IEC_EXPORT(utimensat)(int dirfd, const char* path,
                          const struct timespec times[2], int flags) {
    if (!path) { errno = EFAULT; return -1; }

    int (*fu)(int, const char*, const struct timespec[2], int) =
        IEC_REAL(r_utimensat, utimensat);
    if (!fu) { errno = ENOSYS; return -1; }

    char cand[IEC_BUF], marker[IEC_BUF];
    int isl = 0;
    int r = last_component_cand(dirfd, path, cand, sizeof cand,
                                marker, sizeof marker, &isl);
    if (r < 0) return -1;
    if (r == 0 && isl) return fu(AT_FDCWD, marker, times, 0);

    char res[IEC_BUF];
    int changed = 0;
    int rr = resolve_at(dirfd, path, res, sizeof res, &changed);
    if (rr < 0) return -1;
    if (changed) return fu(AT_FDCWD, res, times, flags);
    return fu(dirfd, path, times, flags);
}

int IEC_EXPORT(lstat)(const char* path, struct stat* buf) {
    if (iec_is_null(path) || iec_is_null(buf)) { errno = EFAULT; return -1; }
    // /proc/self/exe is **not substituted here**: real procfs already reports the "magic link"
    // shape (S_IFLNK|0777, size=0, dev/ino belonging to procfs), identical regardless of the
    // target, so passing through to the real implementation is the faithful choice.
    // The first version synthesized one here, which instead turned dev/ino into those of the
    // underlying file (see the comment above).
    // The last component is not followed, but **preceding components are** — real lstat does
    // the same (the link in lstat("/a/link/x") is resolved by the kernel).
    char cand[IEC_BUF], marker[IEC_BUF];
    int isl = 0;
    int r = last_component_cand(AT_FDCWD, path, cand, sizeof cand, marker, sizeof marker, &isl);
    if (r < 0) return -1;
    if (r == 0 && isl) return fill_link_stat(marker, buf);
    int (*fl)(const char*, struct stat*) = IEC_REAL(r_lstat, lstat);
    if (!fl) { errno = ENOSYS; return -1; }
    int rc = (r > 0) ? fl(path, buf) : fl(cand, buf);
    if (rc == 0) apply_chmod_marker_at(AT_FDCWD, path, r == 0, cand, buf);
    return rc;
}

int IEC_EXPORT(stat)(const char* path, struct stat* buf) {
    if (iec_is_null(path) || iec_is_null(buf)) { errno = EFAULT; return -1; }
    iec_trace("[shim] stat(%s)\n", path);
    char res[IEC_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    int (*fs)(const char*, struct stat*) = IEC_REAL(r_stat, stat);
    if (!fs) { errno = ENOSYS; return -1; }
    int rc = fs(changed ? res : path, buf);
    if (rc == 0) apply_chmod_marker_at(AT_FDCWD, path, changed, res, buf);
    return rc;
}

int IEC_EXPORT(fstatat)(int dirfd, const char* path, struct stat* buf, int flags) {
    if (iec_is_null(path) || iec_is_null(buf)) { errno = EFAULT; return -1; }
#ifdef AT_SYMLINK_NOFOLLOW
    if (flags & AT_SYMLINK_NOFOLLOW) {
        // /proc/self/exe is not substituted (same reason as lstat: real procfs's magic-link shape is already correct)
        char cand[IEC_BUF], marker[IEC_BUF];
        int isl = 0;
        int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
        if (r < 0) return -1;
        if (r == 0 && isl) return fill_link_stat(marker, buf);
        int (*ff)(int, const char*, struct stat*, int) = IEC_REAL(r_fstatat, fstatat);
        if (!ff) { errno = ENOSYS; return -1; }
        int rc = (r > 0) ? ff(dirfd, path, buf, flags) : ff(AT_FDCWD, cand, buf, flags);
        if (rc == 0) apply_chmod_marker_at(dirfd, path, r == 0, cand, buf);
        return rc;
    }
#endif
    char res[IEC_BUF];
    int changed = 0;
    int r = resolve_at(dirfd, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    int (*ff)(int, const char*, struct stat*, int) = IEC_REAL(r_fstatat, fstatat);
    if (!ff) { errno = ENOSYS; return -1; }
    int rc = (r > 0 || !changed) ? ff(dirfd, path, buf, flags) : ff(AT_FDCWD, res, buf, flags);
    if (rc == 0) apply_chmod_marker_at(dirfd, path, changed, res, buf);
    return rc;
}

// The fd variant matters after a chmod on a file that is already open: tools ask
// fstat() for the mode they just set (toybox's cp -p does).
int IEC_EXPORT(fstat)(int fd, struct stat* buf) {
    if (iec_is_null(buf)) { errno = EFAULT; return -1; }
    int (*ff)(int, struct stat*) = IEC_REAL(r_fstat, fstat);
    if (!ff) { errno = ENOSYS; return -1; }
    int rc = ff(fd, buf);
    if (rc == 0) {
        char path[IEC_BUF];
        if (fd_path(fd, path, sizeof path) == 0) apply_chmod_marker(path, buf);
    }
    return rc;
}

// ─────────────────────────── open / openat ───────────────────────────
//
// By default the path is resolved with following; with O_NOFOLLOW the last component is not
// followed, and if that last component is one of our links → ELOOP (real open on a symlink +
// O_NOFOLLOW also gives ELOOP).
// O_PATH|O_NOFOLLOW is the exception: the real implementation **succeeds** and points the fd
// at the link itself, so here the marker file is handed out (its attributes are covered by
// lstat; we do not intercept fstat on the fd, see README).
//
// Non-static with the iec_ prefix: when merged with the tty module into the same guest shim,
// the unified open() in open_shim.c calls it (both modules want to take over open, so there
// can be only one entry point).
int iec_fs_do_open(int dirfd, const char* path, int flags, mode_t mode) {
    if (!path) { errno = EFAULT; return -1; }
    int (*fa)(int, const char*, int, ...) = IEC_REAL(r_openat, openat);
    if (!fa) { errno = ENOSYS; return -1; }

    if (flags & O_NOFOLLOW) {
        char cand[IEC_BUF], marker[IEC_BUF];
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

    char res[IEC_BUF];
    int changed = 0;
    int cr = resolve_at(dirfd, path, res, sizeof res, &changed);
    if (cr < 0) return -1;
    if (cr > 0 || !changed) return fa(dirfd, path, flags, mode);
    return fa(AT_FDCWD, res, flags, mode);
}

#ifndef IEC_SHIM_MERGED_OPEN
/* When merged with the tty module into the same guest shim (-DIEC_SHIM_MERGED_OPEN), this
 * entry is yielded to the unified implementation in shim/open_shim.c (it first consults the
 * /dev/tty hook, then calls iec_fs_do_open below). Both modules take over open, and a .so can
 * contain only one definition. */
int IEC_EXPORT(open)(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return iec_fs_do_open(AT_FDCWD, path, flags, mode);
}
#endif

int IEC_EXPORT(openat)(int dirfd, const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return iec_fs_do_open(dirfd, path, flags, mode);
}

#ifdef __GLIBC__
int IEC_EXPORT(open64)(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return iec_fs_do_open(AT_FDCWD, path, flags, mode);
}

int IEC_EXPORT(openat64)(int dirfd, const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return iec_fs_do_open(dirfd, path, flags, mode);
}
#endif

// ─────────────────────────── unlink / unlinkat ───────────────────────────

static int do_unlink(int dirfd, const char* path, int atflags) {
    if (!path) { errno = EFAULT; return -1; }
    int (*fu)(int, const char*, int) = IEC_REAL(r_unlinkat, unlinkat);
    if (!fu) { errno = ENOSYS; return -1; }

    // Deleting a link = deleting its marker file. The last component is not followed; preceding components expand as usual.
    char cand[IEC_BUF], marker[IEC_BUF];
    int isl = 0;
    int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
    if (r < 0) return -1;
    if (r > 0) return fu(dirfd, path, atflags);
    if (isl) return fu(AT_FDCWD, marker, 0);

    int rc = fu(AT_FDCWD, cand, atflags);
    if (rc == 0) remove_chmod_marker(cand);   /* a deleted file must not keep its mode sidecar */
    return rc;
}

int IEC_EXPORT(unlink)(const char* path) {
    return do_unlink(AT_FDCWD, path, 0);
}

int IEC_EXPORT(unlinkat)(int dirfd, const char* path, int atflags) {
    return do_unlink(dirfd, path, atflags);
}

// ─────────────────────────── rename / renameat ───────────────────────────
//
// Renaming a link = renaming its marker file; landing on a link name = landing on its marker file name.
//
// The four combinations must be handled separately, otherwise a "real file and marker file with
// the same name" shadow is left behind in the same directory:
//   link → link name      rename(marker, marker) directly
//   link → ordinary name  first delete any real file already at the destination (real rename
//                         has replace semantics), then rename the marker to <newname>.IEC_SYMLINK
//   ordinary → link name  first delete the marker at the destination (real rename would
//                         overwrite that link with the source file), then do the real rename —
//                         otherwise it becomes a fake link whose content is treated as the target string
//   ordinary → ordinary   pass through verbatim
// Move the mode sidecar with its file. A destination sidecar is removed first:
// it described the file that is being replaced, not the one arriving.
static void move_chmod_marker(const char* oldp, const char* newp) {
    char om[IEC_BUF], nm[IEC_BUF];
    if (chmod_marker_name(oldp, om, sizeof om) < 0 ||
        chmod_marker_name(newp, nm, sizeof nm) < 0) return;

    int (*fu)(int, const char*, int) = IEC_REAL(r_unlinkat, unlinkat);
    int (*fr)(const char*, const char*) = IEC_REAL(r_rename, rename);
    int (*fs)(int, const char*, struct stat*, int) = IEC_REAL(r_fstatat, fstatat);
    if (!fu || !fr || !fs) return;

    fu(AT_FDCWD, nm, 0);
    struct stat st;
    if (fs(AT_FDCWD, om, &st, AT_SYMLINK_NOFOLLOW) == 0) fr(om, nm);
}

static int do_rename(int od, const char* oldp, int nd, const char* newp) {
    if (!oldp || !newp) { errno = EFAULT; return -1; }
    int (*fr)(const char*, const char*) = IEC_REAL(r_rename, rename);
    if (!fr) { errno = ENOSYS; return -1; }
    int (*fu)(int, const char*, int) = IEC_REAL(r_unlinkat, unlinkat);

    char ocand[IEC_BUF], omark[IEC_BUF];
    int oisl = 0;
    int or_ = last_component_cand(od, oldp, ocand, sizeof ocand, omark, sizeof omark, &oisl);
    if (or_ < 0) return -1;

    char ncand[IEC_BUF], nmark[IEC_BUF];
    int nisl = 0;
    int nr_ = last_component_cand(nd, newp, ncand, sizeof ncand, nmark, sizeof nmark, &nisl);
    if (nr_ < 0) return -1;

    if (or_ > 0 || nr_ > 0) return fr(oldp, newp);   // cannot normalize → real rename

    if (!oisl && !nisl) {                            // no links involved → real rename
        int rc = fr(ocand, ncand);
        if (rc == 0) move_chmod_marker(ocand, ncand);
        return rc;
    }

    if (fu) {
        if (oisl && !nisl) fu(AT_FDCWD, ncand, 0);   // remove the real same-named file at the destination
        if (!oisl && nisl) fu(AT_FDCWD, nmark, 0);   // remove the link at the destination
    }

    const char* src = oisl ? omark : ocand;
    char dst[IEC_BUF];
    if (marker_name(ncand, dst, sizeof dst) < 0) return -1;
    int rc = fr(src, dst);
    if (rc == 0) {
        // The visible destination is a link (or the source was one): a mode
        // sidecar belongs to neither, so drop both leftovers.
        remove_chmod_marker(ncand);
        remove_chmod_marker(ocand);
    }
    return rc;
}

int IEC_EXPORT(rename)(const char* oldpath, const char* newpath) {
    return do_rename(AT_FDCWD, oldpath, AT_FDCWD, newpath);
}

int IEC_EXPORT(renameat)(int olddirfd, const char* oldpath, int newdirfd, const char* newpath) {
    return do_rename(olddirfd, oldpath, newdirfd, newpath);
}

// ─────────────────────────── access / faccessat ───────────────────────────
//
// access() is answered by the kernel from the mode bits, but some filesystems
// grant access independently: the file-manager service behind /storage/Users
// lets open() succeed where access() says EACCES (the files are "owned" by the
// service and the app is not in its group). When the mode check refuses R/W,
// ask the filesystem what open() actually does. That is the same authority the
// caller will use, and it needs no path prefix or invented ownership.

static int access_probe_one(const char* abs, const struct stat* st, int bit) {
    int flags;
    if (bit == R_OK) {
        flags = O_RDONLY | O_CLOEXEC;
#ifdef O_DIRECTORY
        if (S_ISDIR(st->st_mode)) flags |= O_DIRECTORY;
#endif
    } else if (bit == W_OK && S_ISREG(st->st_mode)) {
        // O_NONBLOCK so a FIFO cannot hang the probe; no O_TRUNC, so the file
        // is not modified.
        flags = O_WRONLY | O_CLOEXEC | O_NONBLOCK;
    } else {
        return 0;   /* W_OK on a directory cannot be tested with open() */
    }

    int (*fo)(int, const char*, int, ...) = IEC_REAL(r_openat, openat);
    if (!fo) return 0;
    const int fd = fo(AT_FDCWD, abs, flags, 0);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

static int access_probe(const char* abs, int mode) {
    struct stat st;
    int (*fs)(int, const char*, struct stat*, int) = IEC_REAL(r_fstatat, fstatat);
    if (!fs || fs(AT_FDCWD, abs, &st, 0) != 0) return 0;

    if ((mode & R_OK) && !access_probe_one(abs, &st, R_OK)) return 0;
    if ((mode & W_OK) && !access_probe_one(abs, &st, W_OK)) return 0;
    return 1;
}

static int do_access(int dirfd, const char* path, int mode, int flags) {
    if (!path) { errno = EFAULT; return -1; }
    int (*ff)(int, const char*, int, int) = IEC_REAL(r_faccessat, faccessat);
    if (!ff) { errno = ENOSYS; return -1; }

    int call_dirfd = dirfd;
    const char* call_path = path;
    int call_flags = flags;
    char abs[IEC_BUF];
    int have_abs = 0;
    char res[IEC_BUF];

#ifdef AT_SYMLINK_NOFOLLOW
    if (flags & AT_SYMLINK_NOFOLLOW) {
        char cand[IEC_BUF], marker[IEC_BUF];
        int isl = 0;
        int r = last_component_cand(dirfd, path, cand, sizeof cand, marker, sizeof marker, &isl);
        if (r < 0) return -1;
        // A link's own permissions are always 0777 and it always exists.
        if (r == 0 && isl) return 0;
        if (r == 0) {
            call_dirfd = AT_FDCWD;
            call_path = cand;
            have_abs = make_abs_at(AT_FDCWD, cand, abs, sizeof abs) == 0;
        } else {
            have_abs = make_abs_at(dirfd, path, abs, sizeof abs) == 0;
        }
    } else
#endif
    {
        int changed = 0;
        int r = resolve_at(dirfd, path, res, sizeof res, &changed);
        if (r < 0) return -1;
        if (r == 0 && changed) {
            call_dirfd = AT_FDCWD;
            call_path = res;
            call_flags = 0;
            have_abs = make_abs_at(AT_FDCWD, res, abs, sizeof abs) == 0;
        } else {
            have_abs = make_abs_at(dirfd, path, abs, sizeof abs) == 0;
        }
    }

    int effective = mode;
    if ((mode & X_OK) && have_abs) {
        mode_t marker_mode;
        if (read_chmod_marker(abs, &marker_mode)) {
            if ((marker_mode & 0111) == 0) { errno = EACCES; return -1; }
            effective &= ~X_OK;   /* the emulated execute bit is satisfied */
        }
    }
    if (mode != F_OK && effective == 0) return 0;

    const int rc = ff(call_dirfd, call_path, effective, call_flags);
    if (rc == 0) return 0;

    const int saved = errno;
    if (have_abs && (saved == EACCES || saved == EPERM) &&
        (effective & (R_OK | W_OK)) && access_probe(abs, effective))
        return 0;

    errno = saved;
    return -1;
}

int IEC_EXPORT(access)(const char* path, int mode) {
    return do_access(AT_FDCWD, path, mode, 0);
}

int IEC_EXPORT(faccessat)(int dirfd, const char* path, int mode, int flags) {
    return do_access(dirfd, path, mode, flags);
}

// ─────────────────────────── realpath ───────────────────────────
//
// After expanding simulated links, hand the result to the real realpath for normalization and
// the "every component must exist" check — we deliberately do not implement that part ourselves
// (concatenation of relative targets, ordering of ".."), for the same reason as resolve_simlinks.
char* IEC_EXPORT(realpath)(const char* path, char* resolved) {
    if (!path) { errno = EFAULT; return NULL; }
    char res[IEC_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return NULL;
    char* (*fr)(const char*, char*) = IEC_REAL(r_realpath, realpath);
    if (!fr) { errno = ENOSYS; return NULL; }
    return fr(changed ? res : path, resolved);
}

// ──────────── glibc's _FORTIFY_SOURCE wrappers (__*_chk / __*_2) ────────────
//
// With _FORTIFY_SOURCE enabled (the default for Ubuntu's gcc at -O2, and common with OHOS's
// clang), calls to realpath()/open()/readlink() in programs are **rewritten by the compiler**
// into these wrappers that validate buffer lengths. If we do not intercept them, those calls
// bypass this module and go straight into libc — measured: realpath(link) in a program became
// __realpath_chk, our realpath was never called, and simulated links therefore gave ENOENT
// from realpath. Here they are routed back to this module's implementations (the buffer-length
// checks are guaranteed by the compiler on the caller side; if it really is an out-of-bounds
// call, the real implementation reports an error itself).
#ifdef __GLIBC__
ssize_t IEC_EXPORT(__readlink_chk)(const char* path, char* buf, size_t len, size_t buflen) {
    (void)buflen;
    return readlink(path, buf, len);
}

ssize_t IEC_EXPORT(__readlinkat_chk)(int dirfd, const char* path, char* buf, size_t len, size_t buflen) {
    (void)buflen;
    return readlinkat(dirfd, path, buf, len);
}

char* IEC_EXPORT(__realpath_chk)(const char* path, char* resolved, size_t resolvedlen) {
    (void)resolvedlen;
    return realpath(path, resolved);
}

int IEC_EXPORT(__open_2)(const char* path, int flags) { return iec_fs_do_open(AT_FDCWD, path, flags, 0); }
int IEC_EXPORT(__open64_2)(const char* path, int flags) { return iec_fs_do_open(AT_FDCWD, path, flags, 0); }
int IEC_EXPORT(__openat_2)(int dirfd, const char* path, int flags) { return iec_fs_do_open(dirfd, path, flags, 0); }
int IEC_EXPORT(__openat64_2)(int dirfd, const char* path, int flags) { return iec_fs_do_open(dirfd, path, flags, 0); }
#endif

// ─────────────────────────── opendir / readdir ───────────────────────────
//
// The representation only affects **directory entry names**, not the real number of entries in
// the directory (foo does not exist, only foo.IEC_SYMLINK), so listing a directory only needs
// "rename + fix d_type" and never needs to hide any entry — which means there is no need at all
// to parse getdents64 records/buffers ourselves.
//
// The approach is to modify in place the record returned by the real readdir: glibc's and
// musl's readdir both "point into the DIR's own getdents buffer, then do dirp->offset +=
// d_reclen" and return, taking the next entry from the new offset. Therefore modifying
// d_name/d_type of **the current record** has zero effect on subsequent records (d_reclen is
// untouched) and cannot corrupt the dir stream. The returned pointer still points into libc's
// own storage, with the same lifetime semantics as before (valid until the next readdir on the
// same DIR); alternating readdir across directory streams is also safe.
static void unmark_dirent(struct dirent* e) {
    size_t n = strlen(e->d_name);
    if (n <= IEC_SUFFIX_LEN) return;
    if (memcmp(e->d_name + n - IEC_SUFFIX_LEN, IEC_SUFFIX, IEC_SUFFIX_LEN) != 0) return;
    e->d_name[n - IEC_SUFFIX_LEN] = 0;
    e->d_type = DT_LNK;
}

DIR* IEC_EXPORT(opendir)(const char* path) {
    if (iec_is_null(path)) { errno = EFAULT; return NULL; }
    char res[IEC_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return NULL;
    DIR* (*fo)(const char*) = IEC_REAL(r_opendir, opendir);
    if (!fo) { errno = ENOSYS; return NULL; }
    return fo(changed ? res : path);
}

struct dirent* IEC_EXPORT(readdir)(DIR* dirp) {
    struct dirent* (*fr)(DIR*) = IEC_REAL(r_readdir, readdir);
    if (!fr) { errno = ENOSYS; return NULL; }
    for (;;) {
        struct dirent* e = fr(dirp);
        if (!e) return NULL;
        if (is_chmod_marker_name(e->d_name)) continue;   /* metadata, not a user entry */
        unmark_dirent(e);
        return e;
    }
}

#ifdef __GLIBC__
struct dirent64* readdir64(DIR* dirp) {
    return (struct dirent64*)readdir(dirp);
}
#endif

// ── scandir: libuv's readdir goes through it, so it needs a separate interception layer ─────────────────────────
//
// Why it must be intercepted: libuv's uv__fs_scandir() (deps/uv/src/unix/fs.c:552) calls libc's
// **scandir()**, and its internal opendir/readdir happen inside libc — link-time --wrap only
// rewrites references in "the objects we link", and cannot reach inside libc → the marker is
// neither renamed nor hidden, and callers directly see `x.IEC_SYMLINK` (measured with node's
// readdirSync).
// So here: first resolve the directory path through simulated links (the path itself may be a
// link), then rename each entry of the result array (unmark_dirent, the same mechanism as readdir).
int IEC_EXPORT(scandir)(const char* path, struct dirent*** namelist,
                        int (*filter)(const struct dirent*),
                        int (*compar)(const struct dirent**, const struct dirent**)) {
    if (iec_is_null(path)) { errno = EFAULT; return -1; }
    char res[IEC_BUF];
    int changed = 0;
    int r = resolve_at(AT_FDCWD, path, res, sizeof res, &changed);
    if (r < 0) return -1;
    int (*fsc)(const char*, struct dirent***, int (*)(const struct dirent*),
               int (*)(const struct dirent**, const struct dirent**)) = IEC_REAL(r_scandir, scandir);
    if (!fsc) { errno = ENOSYS; return -1; }
    int n = fsc(changed ? res : path, namelist, filter, compar);
    if (n > 0 && !iec_is_null(namelist) && *namelist) {
        int kept = 0;
        for (int i = 0; i < n; i++) {
            struct dirent* e = (*namelist)[i];
            if (e && is_chmod_marker_name(e->d_name)) {
                free(e);                              /* hidden metadata file */
                continue;
            }
            if (e) unmark_dirent(e);
            (*namelist)[kept++] = e;
        }
        n = kept;
    }
    return n;
}

// ── the syscall layer must intercept two numbers: statx and io_uring_setup ─────────────────────
//
// (1) statx — a semantic problem
// The root cause is in these lines: libuv's stat/lstat go through **statx** — uv__fs_statx() →
// uv__statx() (deps/uv/src/unix/linux-syscalls.c:245) uses a **bare syscall(__NR_statx, …)**,
// bypassing libc symbols, so --wrap=stat / --wrap=lstat cannot reach it at all. This is the
// cause of "node cannot see simulated symlinks" (the guest side uses symbol interposition, so it
// is fine — measured with the same shim: ls works, node does not).
// Handling: always report ENOSYS for statx. libuv has a no_statx cache (fs.c:1517), so after
// one ENOSYS it **permanently** falls back to lstat/fstatat, and those are wrapped and perform
// simulated-symlink resolution ✓.
//
// (2) io_uring_setup(425) — **kills the process**
// libuv also makes a bare call when initializing the io_uring backend: uv__io_uring_setup()
// (linux.c:430) → `syscall(__NR_io_uring_setup, entries, params)`. And **the HarmonyOS sandbox
// uses SECCOMP_RET_TRAP for this number** — measured in the kernel log (hmsecpt in
// `hilog -t kmsg`):
//     [hmsecpt:59]sig=0 arch=0xc00000b7 syscall=425 compat=0 ip=0 code=0x30000
// i.e. every probe throws a **SIGSYS** at the process. Normally the OnSigSys handler installed
// by procmgr in the child downgrades it to ENOSYS (see procmgr.cpp), but **in the node process
// that handler gets replaced by V8**: v8::base::debug::EnableInProcessStackDumping() installs
// SIGSYS with
//     action.sa_flags = SA_RESETHAND | SA_SIGINFO | SA_ONSTACK;
// — **with SA_RESETHAND**, so after the first SIGSYS the disposition resets to SIG_DFL, and the
// next hit performs the default action: **core dump and die**. Measured symptom: kimi-code's
// interactive TUI dies silently after about 2 seconds, exit code 159 (128+SIGSYS), core dump
// (type=0), while the "launcher" node process in the same batch survives because its probe
// happens before V8 installs the handler.
// Handling: always report ENOSYS for io_uring_setup as well. On the libuv side,
//     ringfd = uv__io_uring_setup(entries, &params); if (ringfd == -1) return;
// — a **clean fallback** to epoll/thread pool, which is the existing path for "the kernel has
// no io_uring".
// This eliminates SIGSYS at the source, no longer depending on whether any handler is still
// installed (and incidentally procmgr's OnSigSys no longer needs to catch hdc's similar probe).
//
// All other numbers are forwarded unchanged (all variadic arguments are read out and forwarded;
// extra arguments are harmless to syscall).
long IEC_EXPORT(syscall)(long number, ...) {
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
    long (*fsy)(long, ...) = IEC_REAL(r_syscall, syscall);
    if (!fsy) { errno = ENOSYS; return -1; }
    return fsy(number, a1, a2, a3, a4, a5, a6);
}

// ─────────────────────────── link / linkat ───────────────────────────
//
// Two cases:
//   1) source/target is a **simulated symlink** (a .IEC_SYMLINK marker file) — create another
//      hard link to the marker file, so "another name points to the same link" (both share one
//      inode) and even lstat's st_nlink matches;
//   2) a hard link between real files — hand it straight to the kernel.
//
// But that kernel path is disabled for **non-debug apps**: measured on release builds
// (app.debug=false; this project's self-test uses release mode + debug-jit signing), it always
// gives EACCES. Yet hard links are used quite a bit in toolchains: node's atomic write is
// link(tmp,final)+unlink(tmp), dsh's session persistence is wired the same way —
//     EACCES: permission denied, link '…session.v4.jsonl.zstd.<hash>.tmp' -> '…session.v4.jsonl.zstd'
// — and npm/git's hard-link optimizations likewise. So a fallback layer is added below that
// only runs **when the real link fails**: copy.
//
// Semantic trade-off: a copy is not a hard link (different inodes, st_nlink is 1), but for the
// "temporary file → final name" family of uses the observable effect is the same (the final name
// has the content, the original name still exists, and the caller unlinks the original
// afterwards). When the source is a symlink, **the link itself** must be copied (readlink +
// symlinkat), not its target — that is the existing semantics of link(2). In debug builds or
// ordinary environments this branch is never reached and behavior is unchanged.
//
// ── Exception: with IEC_SHIM_LINK_STRICT=1 **no fallback** is done ────────────────────────────────
// Some callers **verify link semantics** (rather than just wanting the effect): after link() in
// a local git clone, git compares st_ino/st_dev with lstat and, finding it did not get the same
// inode, does
//     fatal: hardlink different from source at '…/objects/xx/yyy'
// and dies — it expects "link failed, I will fall back to copying myself". For such callers the
// fallback is a lie. Setting this variable returns the kernel's original errno unchanged (all
// four git launchers set it).
static int iec_link_strict(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("IEC_SHIM_LINK_STRICT");
        cached = (v && *v && v[0] != '0') ? 1 : 0;
    }
    return cached;
}

static int link_or_copy(int od, const char* oldp, int nd, const char* newp, int flags) {
    int (*fl)(int, const char*, int, const char*, int) = IEC_REAL(r_linkat, linkat);
    if (fl && fl(od, oldp, nd, newp, flags) == 0) return 0;
    int le = errno;
    if (fl && le != EACCES && le != EPERM && le != EMLINK && le != EOPNOTSUPP && le != ENOSYS) {
        errno = le;
        return -1;
    }
    if (iec_link_strict()) { errno = le; return -1; }

    /* ---- fallback: copy ---- */
    static int (*fs)(int, const char*, struct stat*, int);
    if (!fs) fs = IEC_REAL(r_fstatat, fstatat);
    struct stat st;
    if (!fs || fs(od, oldp, &st, AT_SYMLINK_NOFOLLOW) != 0) { errno = le; return -1; }

    if (S_ISLNK(st.st_mode)) {
        static ssize_t (*frl)(int, const char*, char*, size_t);
        static int (*fsl)(const char*, int, const char*);
        if (!frl) frl = IEC_REAL(r_readlinkat, readlinkat);
        if (!fsl) fsl = IEC_REAL(r_symlinkat, symlinkat);
        if (!frl || !fsl) { errno = ENOSYS; return -1; }
        char tgt[IEC_BUF];
        ssize_t n = frl(od, oldp, tgt, sizeof tgt);
        if (n < 0) return -1;
        return fsl(tgt, nd, newp);
    }

    static int (*fop)(int, const char*, int, ...);
    if (!fop) fop = IEC_REAL(r_openat, openat);
    if (!fop) { errno = ENOSYS; return -1; }
    int src = fop(od, oldp, O_RDONLY | O_CLOEXEC);
    if (src < 0) return -1;
    int dst = fop(nd, newp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, (mode_t)(st.st_mode & 07777));
    if (dst < 0) { int e = errno; close(src); errno = e; return -1; }
    /* O_CREAT's mode is trimmed by umask; restore it explicitly. Call the real
     * fchmod: the wrapper below is this shim's own and would consult the chmod
     * policy for an operation the fallback has to complete. */
    int (*ffchmod)(int, mode_t) = IEC_REAL(r_fchmod, fchmod);
    if (ffchmod) ffchmod(dst, (mode_t)(st.st_mode & 07777));
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
        // Follow: the link is expanded to its target, and the new name points at the target itself
        char res[IEC_BUF];
        int changed = 0;
        int r = resolve_at(od, oldp, res, sizeof res, &changed);
        if (r < 0) return -1;
        if (r > 0) return link_or_copy(od, oldp, nd, newp, flags);
        return link_or_copy(AT_FDCWD, changed ? res : oldp, nd, newp, flags & ~AT_SYMLINK_FOLLOW);
    }
#endif
    char ocand[IEC_BUF], omark[IEC_BUF];
    int oisl = 0;
    int or_ = last_component_cand(od, oldp, ocand, sizeof ocand, omark, sizeof omark, &oisl);
    if (or_ < 0) return -1;
    if (or_ > 0) return link_or_copy(od, oldp, nd, newp, flags);
    if (!oisl) return link_or_copy(AT_FDCWD, ocand, nd, newp, flags);

    char ncand[IEC_BUF], nmark[IEC_BUF];
    int nisl = 0;
    int nr_ = last_component_cand(nd, newp, ncand, sizeof ncand, nmark, sizeof nmark, &nisl);
    if (nr_ < 0) return -1;
    if (nr_ > 0) return link_or_copy(od, oldp, nd, newp, flags);

    char dst[IEC_BUF];
    if (marker_name(ncand, dst, sizeof dst) < 0) return -1;
    return link_or_copy(AT_FDCWD, omark, AT_FDCWD, dst, 0);
}

int IEC_EXPORT(link)(const char* oldpath, const char* newpath) {
    return do_link(AT_FDCWD, oldpath, AT_FDCWD, newpath, 0);
}

int IEC_EXPORT(linkat)(int olddirfd, const char* oldpath, int newdirfd, const char* newpath, int flags) {
    return do_link(olddirfd, oldpath, newdirfd, newpath, flags);
}

// ─────────────────── glibc's legacy compatibility entries (__xstat / __lxstat) ───────────────────
//
// Programs built before glibc 2.33 call __xstat/__lxstat (with a version number) instead of
// stat/lstat. On the 64-bit ABI the version number is merely nominal, so simply forward to our
// own stat/lstat with the new structure.
// musl has neither symbol and does not need them (musl exports stat/lstat directly).
#ifdef __GLIBC__
int IEC_EXPORT(__lxstat)(int ver, const char* path, struct stat* buf) {
    (void)ver;
    return lstat(path, buf);
}

int IEC_EXPORT(__xstat)(int ver, const char* path, struct stat* buf) {
    (void)ver;
    return stat(path, buf);
}
#endif

// ─────────────────────────── stdio layers (FILE*) ───────────────────────────
//
// Why this must be intercepted separately: **syscall paths inside the library cannot be reached
// by symbol interposition**. musl's fopen calls its internal sys_open() directly, and glibc's
// fopen goes through _IO_file_open → __open_nocancel() — neither is "a call to the open symbol",
// so the earlier open/openat interception does nothing for fopen.
// Measured symptom: in a guest the symlink was created and lstat/readlink/stat were all
// correct, but the first fopen for its content returned empty (README §3.3).
//
// The fix is direct: our own fopen **first resolves the path to a real path**, then hands the
// resolved path to the real fopen (RTLD_NEXT). That way it does not matter how the library
// issues syscalls internally; the path is already correct.
static FILE* (*r_fopen)(const char*, const char*);
static FILE* (*r_freopen)(const char*, const char*, FILE*);

static FILE* do_fopen(const char* path, const char* mode) {
    if (iec_is_null(path) || iec_is_null(mode)) { errno = EFAULT; return NULL; }
    FILE* (*ff)(const char*, const char*) = IEC_REAL(r_fopen, fopen);
    if (!ff) { errno = ENOSYS; return NULL; }
    char res[IEC_BUF];
    if (resolve_simlinks(path, res, sizeof res) == 0 && strcmp(res, path) != 0)
        return ff(res, mode);
    return ff(path, mode);
}

FILE* IEC_EXPORT(fopen)(const char* path, const char* mode) {
    return do_fopen(path, mode);
}

FILE* IEC_EXPORT(freopen)(const char* path, const char* mode, FILE* stream) {
    FILE* (*ff)(const char*, const char*, FILE*) = IEC_REAL(r_freopen, freopen);
    if (!ff) { errno = ENOSYS; return NULL; }
    if (iec_is_null(path)) return ff(path, mode, stream);
    char res[IEC_BUF];
    if (resolve_simlinks(path, res, sizeof res) == 0 && strcmp(res, path) != 0)
        return ff(res, mode, stream);
    return ff(path, mode, stream);
}

#ifdef __GLIBC__
FILE* IEC_EXPORT(fopen64)(const char* path, const char* mode) { return do_fopen(path, mode); }
FILE* IEC_EXPORT(freopen64)(const char* path, const char* mode, FILE* stream) {
    return freopen(path, mode, stream);
}
#endif

// ─────────────────── box64 internal mode (-DIEC_SHIM_BOX64) ───────────────────────
//
// The two **additional** entries required by box64's hooked `my_*` functions (not libc symbols;
// exported only in this mode):
//
//   iec_fs_active()        Diagnostic: has a marker appeared in this process? (**No** fast-path
//                          gate — the marker may have been created by a previous process, e.g.
//                          a python venv extracted from a tar in the resource bundle, so path
//                          expansion must run every time; the cost is exactly the same as on the
//                          elfloader side).
//   iec_fs_resolve_path()  **Path expansion only**, no file access: expand the simulated links
//                          in path segment by segment into out; when no marker is hit, return
//                          path unchanged (the caller pays only one pointer comparison).
//                          box64's my_open/my_stat use it — those entries also need box64's own
//                          path remap, so calling this module's open/stat directly is awkward.
//
// Note the return-value semantics: returning `path` means "unchanged", returning `out` means
// "changed" (out is the caller's stack buffer, whose lifetime the caller guarantees). Expansion
// failure (ENAMETOOLONG/ELOOP) also returns path — consistent with "transparent", leaving the
// real error for the real implementation downstream to report.
#ifdef IEC_SHIM_BOX64
int iec_fs_active(void) { return g_marker_seen != 0; }
#endif

/* Path expansion entry: expand the simulated links in path segment by segment into out; when
 * no marker is hit, return path unchanged (the caller pays only one pointer comparison).
 * Returning `path` means "unchanged", returning `out` means "changed" (out is the caller's
 * stack buffer, whose lifetime the caller guarantees). Expansion failure (ENAMETOOLONG/ELOOP)
 * also returns path — consistent with "transparent", leaving the real error for the real
 * implementation downstream to report.
 *
 * Who uses it (which is why it is **not inside any ifdef**):
 *   - box64's my_open/my_stat (-DIEC_SHIM_BOX64) — those entries also need box64's own path
 *     remap, so calling this module's open/stat directly is awkward;
 *   - **exec_shim** (since 2026-10-04): the exec target path is handed to procmgr, which does
 *     not have fs_shim, so stat'ing the real path would give ENOENT. npm's
 *     `node_modules/.bin/...` are all simulated symlinks, and any package with an install
 *     script hits this (measured: `code 126` + "cannot exec: …/node-gyp-build: not found").
 *     exec_shim uses a **weak reference** as a fallback: it is NULL when this module's .so is
 *     not linked in. */
const char* iec_fs_resolve_path(const char* path, char* out, size_t outsz) {
    if (!path || !*path || !out || !outsz) return path;
    if (resolve_simlinks(path, out, outsz) != 0) return path;
    return out;
}
