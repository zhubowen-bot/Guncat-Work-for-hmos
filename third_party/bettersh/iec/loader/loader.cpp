// loader.cpp — in-process ELF loader.
//
// Port basis (see loader.h for attribution): segment mapping follows
// loadelf_anon() of https://github.com/MikhailProg/elf as used by Termony
// (build-hnp/elf-loader), plus Termony's jit.patch: an executable mprotect
// is wrapped by prctl(0x6a6974 /* 'jit' */, 0, {0,1}) which is how the
// HarmonyOS W^X kernel lets an app turn anonymous pages executable.
//
// Difference from the original: the original loader replaces the whole
// process image and never returns (guest exit() ends the process).  This
// port keeps the host alive: the guest runs on a dedicated stack and, when
// it executes `ret` (freestanding guest), control returns to elf_switch_to_guest
// and back to the caller.  Guests that call exit_group still terminate the
// whole process, so they should be run in a forked child (elf_run_mem_in_child).

#include "loader.h"


#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <ucontext.h>
#include <unistd.h>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

/* aarch64 Linux/OHOS syscall numbers used only via libc below. */
#define JIT_PRCTL_OPT 0x6a6974L /* ASCII 'jit': HarmonyOS JIT-enable toggle */

extern "C" char **environ;

/* Host-context save slot used by elf/guest_switch.S (one in-process guest at
 * a time, guarded by g_inproc_lock; see the asm comment for why it is not
 * per-thread TLS).  Written/read only from assembly.  Hidden so the shared
 * library can address it PC-relative without a GOT entry. */
extern "C" {
__attribute__((visibility("hidden")))
volatile unsigned long elf_host_ctx[2] = {0, 0};
}

/* Serializes in-process guest runs (see elf_host_ctx above).  Fork-based
 * child runs use per-process copies and need no lock. */
pthread_mutex_t g_inproc_lock = PTHREAD_MUTEX_INITIALIZER;

namespace {

using u8 = uint8_t;
using u64 = uint64_t;

/* --- crash reporting for the forked-child runner ----------------------- */

static void raw_write_str(const char *s)
{
    while (*s) {
        (void)write(2, s, 1);
        s++;
    }
}

static void raw_write_hex(unsigned long v)
{
    char b[17];
    static const char d[] = "0123456789abcdef";
    b[0] = '0';
    b[1] = 'x';
    for (int i = 15; i >= 2; i--) {
        b[i] = d[v & 0xf];
        v >>= 4;
    }
    (void)write(2, b, 16);
}

static void fault_handler(int sig, siginfo_t *si, void *uctx)
{
    unsigned long pc = 0, fault = 0;
    ucontext_t *uc = (ucontext_t *)uctx;
#if defined(__aarch64__)
    (void)si;
    pc = uc->uc_mcontext.pc;
    fault = uc->uc_mcontext.fault_address;
#elif defined(__x86_64__)
    pc = (unsigned long)uc->uc_mcontext.gregs[REG_RIP];
    fault = (unsigned long)(uintptr_t)si->si_addr;
#endif
    raw_write_str("[elf] fault: ");
    raw_write_str(sig == SIGSEGV ? "SIGSEGV"
                  : sig == SIGBUS ? "SIGBUS"
                                   : "SIGABRT");
    raw_write_str(" pc=");
    raw_write_hex(pc);
    raw_write_str(" addr=");
    raw_write_hex(fault);
    raw_write_str("\n");
    _exit(128 + sig);
}

/* Crash forensics. The three guest runners install this themselves; the
 * wrapper at the end of the file is what procmgr uses (BSH_FAULT_TRACE=1, see
 * ChildRunSoMain). Note that it replaces the process's existing SIGSEGV
 * handler -- V8's stack-overflow fallback and node's crash reporter use their
 * own handlers, and V8's chains to the previous one for non-stack faults, so
 * enabling this usually gives both. Because it inserts itself into someone
 * else's signal chain, it is off by default and only installed for debugging. */
static void arm_fault_handlers(void)
{
    /* Why the handler gets its own stack: when a guest crashes, the original
     * stack is often exactly what is broken (overflow, sp pointing at an
     * unmapped page). Running the handler on that stack faults a second time
     * and the kernel silently SIGKILLs the process -- which looks like
     * "rc=139 with not a single line of output". */
    static char altstack[64 * 1024] __attribute__((aligned(16)));
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp = altstack;
    ss.ss_size = sizeof altstack;
    ss.ss_flags = 0;
    sigaltstack(&ss, nullptr);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = fault_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGBUS, &sa, nullptr);
    sigaction(SIGABRT, &sa, nullptr);
    sigaction(SIGILL, &sa, nullptr);   /* a_crash() and friends raise SIGILL */
}

/* --- helpers ------------------------------------------------------------ */

/* Recover the host auxv: try /proc/self/auxv first (exact, no layout
 * assumptions), fall back to a curated getauxval() list.  Returns count. */
size_t read_host_auxv(Elf64_auxv_t *out, size_t cap)
{
    int fd = open("/proc/self/auxv", O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, out, cap * sizeof(Elf64_auxv_t));
        close(fd);
        if (n > 0) return (size_t)n / sizeof(Elf64_auxv_t);
    }
    static const int kTypes[] = {
        AT_PAGESZ, AT_FLAGS, AT_UID, AT_EUID, AT_GID, AT_EGID,
        AT_SECURE, AT_RANDOM, AT_HWCAP, AT_HWCAP2,
    };
    size_t c = 0;
    for (size_t i = 0; i < sizeof(kTypes) / sizeof(kTypes[0]) && c + 1 < cap;
         i++) {
        unsigned long v = getauxval((unsigned long)kTypes[i]);
        if (v != 0 || kTypes[i] == AT_SECURE || kTypes[i] == AT_PAGESZ) {
            out[c].a_type = (Elf64_Xword)kTypes[i];
            out[c].a_un.a_val = (Elf64_Xword)v;
            c++;
        }
    }
    return c;
}

/* Find the link-time virtual address of a symbol by scanning the section
 * symbol tables (SHT_SYMTAB / SHT_DYNSYM).  Returns 0 if not found. */
uintptr_t lookup_symbol_vaddr(const u8 *img, size_t len, const char *want)
{
    if (len < sizeof(Elf64_Ehdr)) return 0;
    Elf64_Ehdr eh;
    memcpy(&eh, img, sizeof(eh));
    if (eh.e_shoff == 0 || eh.e_shentsize < sizeof(Elf64_Shdr)) return 0;
    const size_t shnum = eh.e_shnum;
    if ((size_t)eh.e_shoff + shnum * (size_t)eh.e_shentsize > len) return 0;
    for (size_t i = 0; i < shnum; i++) {
        const Elf64_Shdr *sh =
            (const Elf64_Shdr *)(img + eh.e_shoff + i * eh.e_shentsize);
        if (sh->sh_type != SHT_SYMTAB && sh->sh_type != SHT_DYNSYM) continue;
        if ((size_t)sh->sh_link >= shnum) continue;
        const Elf64_Shdr *str =
            (const Elf64_Shdr *)(img + eh.e_shoff +
                                 (size_t)sh->sh_link * eh.e_shentsize);
        if ((size_t)sh->sh_offset + (size_t)sh->sh_size > len ||
            (size_t)str->sh_offset + (size_t)str->sh_size > len)
            continue;
        const size_t nsym = sh->sh_size / sizeof(Elf64_Sym);
        for (size_t s = 0; s < nsym; s++) {
            const Elf64_Sym *sym =
                (const Elf64_Sym *)(img + sh->sh_offset +
                                    s * sizeof(Elf64_Sym));
            if (sym->st_name == 0 || sym->st_value == 0) continue;
            if ((size_t)sym->st_name >= str->sh_size) continue;
            const char *nm =
                (const char *)(img + str->sh_offset + sym->st_name);
            if (strcmp(nm, want) == 0) return (uintptr_t)sym->st_value;
        }
    }
    return 0;
}

void trace(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

void trace(const char *fmt, ...)
{
    // [elf] informational line (errors still go through error() unconditionally)
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
}

void error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

size_t page_size()
{
    static size_t ps = (size_t)sysconf(_SC_PAGESIZE);
    return ps ? ps : 4096;
}

#define ROUND_PG(x) (((x) + (page_size() - 1)) & ~(page_size() - 1))
#define TRUNC_PG(x) ((x) & ~(page_size() - 1))

int pf_to_prot(uint32_t pf)
{
    return ((pf & PF_R) ? PROT_READ : 0) | ((pf & PF_W) ? PROT_WRITE : 0) |
           ((pf & PF_X) ? PROT_EXEC : 0);
}

__attribute__((unused))
int jit_toggle(int on)
{
#if defined(ELFLOADER_ARCH_ARM64) && defined(ELFLOADER_OHOS)
    return prctl(JIT_PRCTL_OPT, 0, on, 0, 0);
#else
    /* Only the HarmonyOS arm64 kernel gates anonymous executable pages this
     * way; elsewhere mprotect(PROT_EXEC) needs no surrounding toggle. */
    (void)on;
    return 0;
#endif
}

/* mprotect that tolerates the HarmonyOS W^X/JIT policy.  Mode A mirrors
 * Termony jit.patch exactly; if it fails we fall back to a plain mprotect
 * and to the reversed prctl order, logging every attempt for on-device
 * tuning.  Returns 0 on success, -1 if all variants failed. */
int mprotect_final(void *addr, size_t n, int prot, const char *what)
{
    if (!(prot & PROT_EXEC)) {
        int rc = mprotect(addr, n, prot);
        if (rc != 0) error("[elf] mprotect(%s) failed: %s", what, strerror(errno));
        return rc;
    }

#if defined(ELFLOADER_ARCH_ARM64) && defined(ELFLOADER_OHOS)
    int rc, e1 = 0, e2 = 0;

    /* Mode A: jit.patch order  (prctl(...,0,0) -> mprotect -> prctl(...,0,1)) */
    jit_toggle(0);
    rc = mprotect(addr, n, prot);
    jit_toggle(1);
    if (rc == 0) return 0;
    e1 = errno;

    /* Mode B: plain mprotect, no toggle. */
    rc = mprotect(addr, n, prot);
    if (rc == 0) {
        trace("[elf] exec mprotect(%s): plain OK (jit toggle unneeded)", what);
        return 0;
    }
    e2 = errno;

    /* Mode C: reversed order. */
    jit_toggle(1);
    rc = mprotect(addr, n, prot);
    jit_toggle(0);
    if (rc == 0) {
        trace("[elf] exec mprotect(%s): reversed-toggle OK", what);
        return 0;
    }

    error("[elf] mprotect(PROT_EXEC, %s) failed: A=%s B=%s C=%s", what,
          strerror(e1), strerror(e2), strerror(errno));
    return -1;
#else
    int rc = mprotect(addr, n, prot);
    if (rc != 0)
        error("[elf] mprotect(PROT_EXEC, %s) failed: %s", what, strerror(errno));
    return rc;
#endif
}

struct LoadInfo {
    bool dyn;
    uintptr_t base; /* load bias / region base */
    uintptr_t region_lo;
    uintptr_t region_hi;
    uintptr_t entry;
    Elf64_Ehdr eh;
};

/* Map every PT_LOAD of an in-memory ELF into fresh anonymous pages.
 * Returns 0 on success (info populated), -1 on error (nothing left mapped
 * that the caller must clean up). */
int load_segments(const u8 *img, size_t len, LoadInfo *info)
{
    const size_t ps = page_size();
    Elf64_Ehdr eh;
    memcpy(&eh, img, sizeof(eh));

    if (len < sizeof(eh) || memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0 ||
        eh.e_ident[EI_CLASS] != ELFCLASS64 ||
        eh.e_ident[EI_DATA] != ELFDATA2LSB ||
        eh.e_ident[EI_VERSION] != EV_CURRENT || eh.e_machine != ELFLOADER_EM_EXPECTED ||
        (eh.e_type != ET_EXEC && eh.e_type != ET_DYN) || eh.e_phnum == 0) {
        error("[elf] bad ELF header (need little-endian host-architecture EXEC/DYN)");
        return -1;
    }
    if (eh.e_phentsize != sizeof(Elf64_Phdr) ||
        (size_t)eh.e_phoff + (size_t)eh.e_phnum * sizeof(Elf64_Phdr) > len) {
        error("[elf] bad program header table");
        return -1;
    }

    const bool dyn = eh.e_type == ET_DYN;
    const Elf64_Phdr *ph = (const Elf64_Phdr *)(img + eh.e_phoff);
    /* A non-PIE program with PT_INTERP (ET_EXEC) is dynamic too: the
     * interpreter owns its exit/_Exit, so it must not get the static guest's
     * exit stub (see the exit-stub section below). */
    bool has_interp = false;
    for (int i = 0; i < eh.e_phnum; i++) {
        if (ph[i].p_type == PT_INTERP) { has_interp = true; break; }
    }
    uintptr_t exit_vaddr = 0, exit_impl_vaddr = 0; /* patched below */

    uintptr_t minva = (uintptr_t)-1, maxva = 0;
    for (int i = 0; i < eh.e_phnum; i++) {
        if (ph[i].p_type != PT_LOAD) continue;
        if (ph[i].p_vaddr < minva) minva = ph[i].p_vaddr;
        if (ph[i].p_vaddr + ph[i].p_memsz > maxva)
            maxva = ph[i].p_vaddr + ph[i].p_memsz;
    }
    minva = TRUNC_PG(minva);
    maxva = ROUND_PG(maxva);
    const size_t size = maxva - minva;
    if (size == 0) {
        error("[elf] no loadable segments");
        return -1;
    }

    /* Reserve the whole image range first (like loadelf_anon) so we know a
     * contiguous window exists, then drop it and re-map per segment. */
    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
    void *hint = dyn ? nullptr : (void *)minva;
    if (!dyn) flags |= MAP_FIXED_NOREPLACE;
    void *base = mmap(hint, size, PROT_NONE, flags, -1, 0);
    if (base == MAP_FAILED) {
        if (!dyn && (errno == EINVAL || errno == ENOSYS)) {
            /* Kernel without MAP_FIXED_NOREPLACE: plain MAP_FIXED probe. */
            base = mmap((void *)minva, size, PROT_NONE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        }
        if (base == MAP_FAILED) {
            error("[elf] reserve %s image range [%#lx,+%#zx) failed: %s",
                  dyn ? "dyn" : "fixed", (unsigned long)(dyn ? 0 : minva),
                  size, strerror(errno));
            return -1;
        }
    }
    uintptr_t region = (uintptr_t)base;
    munmap(base, size);

    struct MapEnt {
        uintptr_t a;
        size_t n;
    };
    MapEnt *ents = (MapEnt *)calloc((size_t)eh.e_phnum, sizeof(MapEnt));
    int nents = 0;

    /* Re-map each PT_LOAD writable, copy its file image, remember bounds. */
    for (int i = 0; i < eh.e_phnum; i++) {
        const Elf64_Phdr &p = ph[i];
        if (p.p_type != PT_LOAD) continue;
        const size_t off = (size_t)p.p_vaddr & (ps - 1);
        uintptr_t start = (dyn ? region : 0) + TRUNC_PG(p.p_vaddr);
        const size_t sz = ROUND_PG(p.p_memsz + off);
        void *seg = mmap((void *)start, sz, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        if (seg == MAP_FAILED) {
            error("[elf] mmap segment %d @%#lx failed: %s", i,
                  (unsigned long)start, strerror(errno));
            goto fail;
        }
        ents[nents].a = start;
        ents[nents].n = sz;
        nents++;
        if (p.p_filesz > 0) {
            if ((size_t)p.p_offset + (size_t)p.p_filesz > len) {
                error("[elf] truncated segment %d in image", i);
                goto fail;
            }
            memcpy((u8 *)seg + off, img + p.p_offset, p.p_filesz);
        }

        /* Diagnostic (BSH_ELF_TRACE=1): the .bss tail after p_filesz is defined
         * to be zero. Scan it for the first non-zero byte and also dump the
         * first 16 bytes of the initialized part. Reason: clang crashed under
         * ninja while walking a signal-registration table in .bss
         * (ldr w0,[x1,#152], index from a .bss counter); the table/counter was
         * suspected to be dirty. This line either confirms or rules that out. */
        if (getenv("BSH_ELF_TRACE")) {
            const u8 *initp = (const u8 *)seg + off;
            size_t initn = p.p_filesz < 16 ? (size_t)p.p_filesz : 16;
            fprintf(stdout, "[elf] seg%d vaddr=%#lx memsz=%#zx filesz=%#zx init[",
                    i, (unsigned long)p.p_vaddr, (size_t)p.p_memsz, (size_t)p.p_filesz);
            for (size_t k = 0; k < initn; k++) fprintf(stdout, "%02x", initp[k]);
            fputs("]", stdout);
            if (p.p_memsz > p.p_filesz) {
                const u8 *z = (const u8 *)seg + off + p.p_filesz;
                size_t zn = ROUND_PG(p.p_memsz + off) - (off + p.p_filesz);
                size_t k = 0;
                while (k < zn && z[k] == 0) k++;
                fprintf(stdout, " bss@%#lx size=%#zx first_nonzero=%s%zu",
                        (unsigned long)(start + off + p.p_filesz), zn,
                        (k < zn) ? "at " : "(none) ", k);
            }
            fputc('\n', stdout);
            fflush(stdout);
        }
    }

    /* On the OHOS musl port the normal libc exit() cleanup aborts inside
     * the child (emutls/allocator refuses a small malloc with EINVAL during
     * the atexit phase -- verified by malloc wrappers).  Redirect the guest's
     * `exit` so a normally-returning program ends with a clean exit_group(code)
     * and the child's exit status is preserved.
     *
     * Do not jump straight to _Exit: by definition it does not flush stdio, so
     * any output still buffered in the guest is lost (measured: the second
     * printf in a static guest disappeared that way). When a flush entry point
     * is available, inject a small stub that saves the exit code, flushes all
     * streams, and then calls _Exit:
     *
     *     sub sp, sp, #16
     *     str w0, [sp, #12]      // save the exit code
     *     mov w0, #0
     *     bl  <flush>            // __stdio_exit or fflush(NULL): flush all streams
     *     ldr w0, [sp, #12]      // restore the exit code
     *     add sp, sp, #16
     *     b   <_Exit>
     *
     * The stub lives in a new page after the image (hint = maxva; the kernel
     * picks the address, so MAP_FIXED is not needed). It is written and then
     * made RX under the W^X policy. If neither flush entry point is available,
     * fall back to the old direct jump to _Exit.
     * Only applied to static (ET_EXEC) guests -- never to a dynamic main or its
     * interpreter/libc image. */
    exit_vaddr = lookup_symbol_vaddr(img, len, "exit");
    exit_impl_vaddr = lookup_symbol_vaddr(img, len, "_Exit");
    if (!exit_impl_vaddr) exit_impl_vaddr = lookup_symbol_vaddr(img, len, "_exit");
    if (!dyn && !has_interp && exit_vaddr && exit_impl_vaddr) {
        uintptr_t from = (dyn ? region : 0) + exit_vaddr;
        uintptr_t to = (dyn ? region : 0) + exit_impl_vaddr;

        /* Inject the exit stub. Prefer musl's __stdio_exit: it takes no
         * arguments and flushes every stream. If it is missing, try
         * _IO_cleanup (glibc static), then fflush(NULL); if none is available,
         * skip the stub and keep the old behaviour. The device's clang sysroot
         * is our own musl whose libc.a is incomplete -- measured: no fflush,
         * but __stdio_exit is there, so all of them are worth trying. */
        uintptr_t flush_vaddr = lookup_symbol_vaddr(img, len, "__stdio_exit");
        if (!flush_vaddr) flush_vaddr = lookup_symbol_vaddr(img, len, "_IO_cleanup");
        if (!flush_vaddr) flush_vaddr = lookup_symbol_vaddr(img, len, "fflush");
        trace("[elf] exit stub: flush vaddr=%#lx maxva=%#lx",
              (unsigned long)flush_vaddr, (unsigned long)maxva);
        if (flush_vaddr) {
            void *stub = mmap((void *)maxva, 4096, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (stub == MAP_FAILED) {
                error("[elf] exit stub mmap @%#lx failed: %s",
                      (unsigned long)maxva, strerror(errno));
            } else {
                uint8_t *pg = (uint8_t *)stub;
                uintptr_t sa = (uintptr_t)pg;
#if defined(ELFLOADER_ARCH_ARM64)
                uint32_t *p = (uint32_t *)pg;
                *p++ = 0xD10043FFu;  /* sub sp, sp, #16        */
                *p++ = 0xB9000FE0u;  /* str w0, [sp, #12]      */
                *p++ = 0x52800000u;  /* mov w0, #0             */
                int64_t d1 = (int64_t)((dyn ? region : 0) + flush_vaddr) -
                             (int64_t)(sa + 12);
                *p++ = 0x94000000u | ((uint32_t)(d1 >> 2) & 0x03FFFFFFu); /* bl flush */
                *p++ = 0xB9400FE0u;  /* ldr w0, [sp, #12]      */
                *p++ = 0x910043FFu;  /* add sp, sp, #16        */
                int64_t d2 = (int64_t)to - (int64_t)(sa + 24);
                *p++ = 0x14000000u | ((uint32_t)(d2 >> 2) & 0x03FFFFFFu); /* b _Exit */
                __builtin___clear_cache((char *)pg, (char *)p);
#elif defined(ELFLOADER_ARCH_X86_64)
                /* Call flush(NULL), then tail-call _Exit(saved_code).
                 *   push rdi            ; save exit code, keep 16-byte alignment
                 *   xor  edi, edi       ; flush(NULL)
                 *   call rel32 flush
                 *   pop  rdi            ; restore exit code
                 *   jmp  rel32 _Exit
                 */
                uint8_t *p = pg;
                *p++ = 0x57;                              /* push rdi */
                *p++ = 0x31; *p++ = 0xFF;                 /* xor edi,edi */
                *p++ = 0xE8;                              /* call rel32 */
                {
                    int64_t rel = (int64_t)((dyn ? region : 0) + flush_vaddr) -
                                  (int64_t)(sa + (uintptr_t)(p - pg) + 4);
                    int32_t r32 = (int32_t)rel;
                    memcpy(p, &r32, 4);
                    p += 4;
                }
                *p++ = 0x5F;                              /* pop rdi */
                *p++ = 0xE9;                              /* jmp rel32 */
                {
                    int64_t rel = (int64_t)to -
                                  (int64_t)(sa + (uintptr_t)(p - pg) + 4);
                    int32_t r32 = (int32_t)rel;
                    memcpy(p, &r32, 4);
                    p += 4;
                }
                __builtin___clear_cache((char *)pg, (char *)p);
#endif
                if (mprotect_final(pg, 4096, PROT_READ | PROT_EXEC, "exit-stub") == 0) {
                    to = sa;
                    trace("[elf] exit stub @%#lx: flush@%#lx then _Exit@%#lx",
                          (unsigned long)sa,
                          (unsigned long)((dyn ? region : 0) + flush_vaddr),
                          (unsigned long)((dyn ? region : 0) + exit_impl_vaddr));
                } else {
                    munmap(pg, 4096);
                }
            }
        }

#if defined(ELFLOADER_ARCH_ARM64)
        int64_t delta = (int64_t)to - (int64_t)from;
        if ((delta & 3) == 0 && delta >= -(1LL << 27) && delta < (1LL << 27)) {
            for (int e = 0; e < nents; e++) {
                if (from >= ents[e].a && from + 4 <= ents[e].a + ents[e].n) {
                    uint32_t insn =
                        0x14000000u | ((uint32_t)(delta >> 2) & 0x03ffffffu);
                    *(volatile uint32_t *)from = insn; /* b <stub|_Exit> */
                    trace("[elf] patched exit@%#lx -> b %#lx(+%ld)",
                          (unsigned long)from, (unsigned long)to, (long)delta);
                    break;
                }
            }
        }
#elif defined(ELFLOADER_ARCH_X86_64)
        int64_t delta = (int64_t)to - (int64_t)(from + 5);
        if (delta >= INT32_MIN && delta <= INT32_MAX) {
            for (int e = 0; e < nents; e++) {
                if (from >= ents[e].a && from + 5 <= ents[e].a + ents[e].n) {
                    uint8_t *p = (uint8_t *)from;
                    p[0] = 0xE9; /* jmp rel32 */
                    int32_t d32 = (int32_t)delta;
                    memcpy(p + 1, &d32, 4);
                    trace("[elf] patched exit@%#lx -> jmp %#lx(+%ld)",
                          (unsigned long)from, (unsigned long)to, (long)delta);
                    break;
                }
            }
        }
#endif
    }

    /* Set final protections (wrapping exec ones with the JIT toggle) and
     * flush the instruction cache for executable ranges. */
    for (int i = 0; i < eh.e_phnum; i++) {
        const Elf64_Phdr &p = ph[i];
        if (p.p_type != PT_LOAD) continue;
        const size_t off = (size_t)p.p_vaddr & (ps - 1);
        uintptr_t start = (dyn ? region : 0) + TRUNC_PG(p.p_vaddr);
        const size_t sz = ROUND_PG(p.p_memsz + off);
        const int prot = pf_to_prot(p.p_flags);
        char what[64];
        snprintf(what, sizeof(what), "seg%d(%c%c%c)", i,
                 (p.p_flags & PF_R) ? 'r' : '-',
                 (p.p_flags & PF_W) ? 'w' : '-',
                 (p.p_flags & PF_X) ? 'x' : '-');
        if (mprotect_final((void *)start, sz, prot, what) != 0) goto fail;
        if (prot & PROT_EXEC)
            __builtin___clear_cache((char *)start, (char *)(start + sz));
    }

    info->dyn = dyn;
    info->base = dyn ? region : minva;
    info->region_lo = dyn ? region : minva;
    info->region_hi = dyn ? region + size : maxva;
    info->entry = eh.e_entry + (dyn ? region : 0);
    info->eh = eh;
    free(ents);
    return 0;

fail:
    while (nents > 0) {
        nents--;
        munmap((void *)ents[nents].a, ents[nents].n);
    }
    free(ents);
    error("[elf] load aborted");
    return -1;
}

/* Build a fresh 16-byte-aligned process-start stack (argc/argv/envp/auxv)
 * on a dedicated mapping.  Returns sp, or 0 on error (nothing leaked). */
uintptr_t make_guest_stack(int argc, char *const argv[], const LoadInfo &li,
                           void **out_map, size_t *out_map_len,
                           uintptr_t bridge, uintptr_t at_base_override)
{
    const size_t ps = page_size();
    const size_t cap = (size_t)4 << 20; /* 4 MiB guest stack */
    size_t map_len = cap + ps;
    u8 *map = (u8 *)mmap(nullptr, map_len, PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (map == MAP_FAILED) {
        error("[elf] guest stack mmap failed: %s", strerror(errno));
        return 0;
    }
    if (mprotect(map, cap, PROT_READ | PROT_WRITE) != 0) {
        error("[elf] guest stack mprotect failed: %s", strerror(errno));
        munmap(map, map_len);
        return 0;
    }
    u64 *sp = (u64 *)(map + cap);

    auto push = [&sp](u64 v) { *--sp = v; };
    auto push_auxv = [&push](u64 type, u64 val) {
        push(val); /* pairs are (type@low, val@high) in ascending memory */
        push(type);
    };

    /* Copy the host auxv (exact from /proc/self/auxv, getauxval fallback),
     * patching entries that must describe the guest image.  Pointers into
     * host memory (AT_RANDOM, AT_EXECFN...) stay valid because fork shares
     * the address space (child runs). */
    char **ep = environ;
    size_t nenv = 0;
    if (ep) {
        while (ep[nenv]) nenv++;
        if (nenv >= 1024) nenv = 0; /* paranoid */
    }

    Elf64_auxv_t host[512];
    size_t naux = read_host_auxv(host, 512);
    bool host_has_base = false;
    bool host_has_phdr = false, host_has_phnum = false;
    bool host_has_phent = false, host_has_entry = false;
    /* The four identity entries; together with the "secure bitmap" below this
     * is one concern, not four separate ones. */
    bool host_has_uid = false, host_has_euid = false;
    bool host_has_gid = false, host_has_egid = false;
    size_t non_null = 0;
    for (size_t i = 0; i < naux; i++) {
        switch (host[i].a_type) {
        case AT_BASE:  host_has_base = true;  break;
        case AT_PHDR:  host_has_phdr = true;  break;
        case AT_PHNUM: host_has_phnum = true; break;
        case AT_PHENT: host_has_phent = true; break;
        case AT_ENTRY: host_has_entry = true; break;
        case AT_UID:   host_has_uid = true;   break;
        case AT_EUID:  host_has_euid = true;  break;
        case AT_GID:   host_has_gid = true;   break;
        case AT_EGID:  host_has_egid = true;  break;
        default: break;
        }
        if (host[i].a_type != AT_NULL) non_null++;
    }
    /* The host auxv may be missing some of these entries (measured: a release
     * sandbox's /proc/self/auxv had only PAGESZ/SECURE/RANDOM/HWCAP/HWCAP2,
     * no AT_PHDR family) -- and the guest musl (both static-PIE and ld-musl)
     * must use AT_PHDR/AT_PHNUM/AT_PHENT to find its own program headers and
     * then locate _DYNAMIC for bootstrap relocation. When they are missing it
     * computes a garbage pointer and faults on the first instruction
     * (measured fault addr=0x220, PC inside __dls2's relocation loop).
     * So synthesize whatever is missing -- the same pattern as AT_BASE.
     *
     * The same pattern owes two more entries, both root causes of LD_PRELOAD
     * silently not working (settled 2026-10-02):
     *
     * (1) AT_UID/AT_EUID/AT_GID/AT_EGID must appear in the auxv. musl's __dls3
     *     uses a "present bitmap" to decide whether it is secure:
     *         libc.secure = ((aux[0]&0x7800)!=0x7800 || aux[AT_UID]!=aux[AT_EUID] || …)
     *     decode_vec() fills aux[0] with a bitmap of which types appeared, and
     *     0x7800 is exactly AT_UID(11)/AT_EUID(12)/AT_GID(13)/AT_EGID(14).
     *     A sandbox auxv without them leaves the bitmap incomplete, musl
     *     decides it is secure, and silently drops LD_PRELOAD and
     *     LD_LIBRARY_PATH (load_preload() does not report load failures).
     *     The symptom is "environment right, file present, shim just does not
     *     take effect". Use this process's real uid/gid (all four are equal).
     *
     * (2) Force AT_SECURE to 0 for the guest. The local LSM marks appspawn
     *     processes secureexec (measured AT_SECURE=1 in the host auxv), and
     *     libc drops all LD_* variables as soon as it sees that (glibc's
     *     __libc_enable_secure, musl's libc.secure). AT_SECURE exists to stop
     *     a privileged process from being influenced by an external
     *     environment; here guest and host have the same uid and the same
     *     environment (set by procmgr in the same process), so there is no
     *     privilege boundary -- copying the host value only kills the shim. */
    size_t synth = (host_has_base ? 0 : 1) + (host_has_phdr ? 0 : 1) +
                   (host_has_phnum ? 0 : 1) + (host_has_phent ? 0 : 1) +
                   (host_has_entry ? 0 : 1) + (host_has_uid ? 0 : 1) +
                   (host_has_euid ? 0 : 1) + (host_has_gid ? 0 : 1) +
                   (host_has_egid ? 0 : 1);
    /* auxv pair count (each pair = 2 words), including the final AT_NULL. */
    size_t aux_pairs = non_null + synth + (bridge ? 1 : 0) + 1;
    /* Total 64-bit words to push; argc is the final word.  The kernel-style
     * layout must contain NO padding inside argc/argv/env/auxv, so any
     * alignment padding is reserved as one unused word at the very top of
     * the stack (never read by argv/env/auxv scanners). */
    size_t total_words = 2 * aux_pairs + 1 + nenv + 1 + (size_t)argc + 1;
    if (total_words & 1) sp = (u64 *)((uintptr_t)sp - 8);

    /* Push auxv with AT_NULL at the TOP (highest address): scanners walk up
     * from the env terminator and must see every entry before AT_NULL. */
    push_auxv(AT_NULL, 0);
    for (size_t i = 0; i < naux; i++) {
        u64 type = (u64)host[i].a_type;
        if (type == AT_NULL) continue;
        u64 val = (u64)host[i].a_un.a_val;
        switch (type) {
        case AT_PHDR:
            val = (u64)(li.base + li.eh.e_phoff);
            break;
        case AT_PHNUM:
            val = (u64)li.eh.e_phnum;
            break;
        case AT_PHENT:
            val = (u64)li.eh.e_phentsize;
            break;
        case AT_ENTRY:
            val = li.entry;
            break;
        case AT_EXECFN:
            if (argv && argv[0]) val = (u64)(uintptr_t)argv[0];
            break;
        case AT_SECURE:
            val = 0; /* see (2) above: same uid as the host, secure only kills LD_PRELOAD */
            break;
        case AT_BASE: /* interpreter base (0 for static guests) */
            val = at_base_override;
            break;
        default:
            break;
        }
        push_auxv(type, val);
    }
    if (!host_has_phdr)
        push_auxv(AT_PHDR, (u64)(li.base + li.eh.e_phoff));
    if (!host_has_phnum)
        push_auxv(AT_PHNUM, (u64)li.eh.e_phnum);
    if (!host_has_phent)
        push_auxv(AT_PHENT, (u64)li.eh.e_phentsize);
    if (!host_has_entry)
        push_auxv(AT_ENTRY, (u64)li.entry);
    if (!host_has_base)
        push_auxv(AT_BASE, at_base_override); /* musl ld.so needs AT_BASE */
    /* The four identity entries: synthesize the missing ones from this
     * process's real uid/gid (see (1) above). */
    if (!host_has_uid)  push_auxv(AT_UID,  (u64)getuid());
    if (!host_has_euid) push_auxv(AT_EUID, (u64)geteuid());
    if (!host_has_gid)  push_auxv(AT_GID,  (u64)getgid());
    if (!host_has_egid) push_auxv(AT_EGID, (u64)getegid());
    if (bridge) push_auxv(AT_GUEST_BRIDGE, bridge);

    /* env NULL terminator, then envp entries (reversed so envp[0] is the
     * lowest), then argv NULL terminator and argv. */
    push(0);
    for (size_t i = nenv; i > 0; i--) push((u64)(uintptr_t)ep[i - 1]);
    /* argv terminator + argv (pushed reversed so argv[0] is lowest) */
    push(0);
    for (int i = argc; i > 0; i--) push((u64)(uintptr_t)argv[i - 1]);

    push((u64)argc);

    *out_map = map;
    *out_map_len = map_len;
    return (uintptr_t)sp;
}

} /* namespace */

/* The exported shell: arm_fault_handlers, used by the guest runners below,
 * lives in the anonymous namespace (internal linkage), so procmgr in another
 * translation unit cannot see it. Export it under a different name -- using
 * the same name would make the three calls inside the anonymous namespace see
 * both declarations and clang reports "call is ambiguous" (measured). */
void elf_arm_fault_handlers(void) { arm_fault_handlers(); }

/* implemented in elf/guest_switch.S */
extern "C" long elf_switch_to_guest(void *entry, void *guest_sp);

int elf_run_mem(const void *img, size_t len, int argc, char *const argv[])
{
    return elf_run_mem_ex(img, len, argc, argv, nullptr);
}

int elf_run_mem_ex(const void *img, size_t len, int argc, char *const argv[],
                   const struct ElfGuestBridge *bridge)
{
    if (!img || len < sizeof(Elf64_Ehdr)) {
        error("[elf] run_mem: empty image");
        return -1;
    }

    /* In-process guest execution is serialized (see elf_host_ctx). */
    pthread_mutex_lock(&g_inproc_lock);

    LoadInfo li;
    if (load_segments((const u8 *)img, len, &li) != 0) {
        pthread_mutex_unlock(&g_inproc_lock);
        return -1;
    }
    trace("[elf] loaded %s entry=%#lx region=[%#lx,%#lx)%s",
          li.dyn ? "ET_DYN" : "ET_EXEC", (unsigned long)li.entry,
          (unsigned long)li.region_lo, (unsigned long)li.region_hi,
          bridge ? " (bridge armed)" : "");

    void *stk_map = nullptr;
    size_t stk_len = 0;
    uintptr_t sp =
        make_guest_stack(argc, argv, li, &stk_map, &stk_len,
                         (uintptr_t)bridge, 0);
    if (!sp) {
        munmap((void *)li.region_lo, li.region_hi - li.region_lo);
        pthread_mutex_unlock(&g_inproc_lock);
        return -1;
    }
    trace("[elf] calling guest entry=%#lx sp=%#lx", (unsigned long)li.entry,
          (unsigned long)sp);
    fflush(stdout);
    fflush(stderr);

    /* Run the guest with asynchronous signals blocked: while sp points at
     * the guest stack, any host signal handler (timer / GC safepoint / ...)
     * would run on the guest stack and corrupt host state.
     *
     * Note: synchronous fault signals must NOT be blocked
     * (SIGSEGV/SIGBUS/SIGILL/SIGABRT). A synchronous signal means "this
     * instruction caused it and it has to be handled right here"; blocking it
     * does not defer delivery -- the kernel applies the default action and
     * kills the process, so our forensics handler (OnSigFault) never runs.
     * The measured symptom was "guest rc=139 with not a single log line"; two
     * days of debugging ended here. Once these four are removed from the
     * blocked set, a guest crash prints "[bsh] FAULT ... pc=... mapping: ...". */
    sigset_t all, old;
    sigfillset(&all);
    sigdelset(&all, SIGSEGV);
    sigdelset(&all, SIGBUS);
    sigdelset(&all, SIGILL);
    sigdelset(&all, SIGABRT);
    sigprocmask(SIG_BLOCK, &all, &old);

    long rc = elf_switch_to_guest((void *)li.entry, (void *)sp);

    sigprocmask(SIG_SETMASK, &old, nullptr);

    trace("[elf] guest returned rc=%ld", rc);
    munmap(stk_map, stk_len);
    munmap((void *)li.region_lo, li.region_hi - li.region_lo);
    pthread_mutex_unlock(&g_inproc_lock);
    return rc == 0 ? 0 : -1;
}

int elf_map_image(const void *img, size_t len, uintptr_t *base, size_t *span)
{
    if (!img || len < sizeof(Elf64_Ehdr)) return -1;
    LoadInfo li;
    if (load_segments((const u8 *)img, len, &li) != 0) return -1;
    *base = li.region_lo;
    *span = li.region_hi - li.region_lo;
    return 0;
}

int elf_run_file(const char *path, int argc, char *const argv[])
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        error("[elf] open %s: %s", path, strerror(errno));
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        error("[elf] fstat %s: %s", path, strerror(errno));
        close(fd);
        return -1;
    }
    if (st.st_size <= 0) {
        error("[elf] empty file: %s", path);
        close(fd);
        return -1;
    }
    size_t len = (size_t)st.st_size;
    u8 *buf = (u8 *)malloc(len);
    if (!buf) {
        close(fd);
        error("[elf] oom reading %s", path);
        return -1;
    }
    size_t got = 0;
    while (got < len) {
        ssize_t r = read(fd, buf + got, len - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    if (got != len) {
        free(buf);
        error("[elf] short read on %s", path);
        return -1;
    }
    int rc = elf_run_mem(buf, len, argc, argv);
    free(buf);
    return rc;
}

int elf_probe_fork(void)
{
    fflush(nullptr);
    pid_t pid = fork();
    if (pid < 0) {
        error("[elf] probe: fork not permitted: %s", strerror(errno));
        return 0;
    }
    if (pid == 0) {
        /* child: exercise a minimal syscall path, then die quietly */
        _exit(0);
    }
    int st = 0;
    while (waitpid(pid, &st, 0) < 0) {
        if (errno != EINTR) {
            error("[elf] probe: waitpid failed: %s", strerror(errno));
            return -1;
        }
    }
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
        trace("[elf] probe: fork OK (child exited 0)");
        return 1;
    }
    trace("[elf] probe: fork child did not exit 0 (st=%#x)", st);
    return 0;
}

int elf_run_mem_in_child(const void *img, size_t len, int argc,
                         char *const argv[])
{
    fflush(nullptr);
    pid_t pid = fork();
    if (pid < 0) {
        error("[elf] child-run: fork failed: %s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        /* Child.  If the guest calls exit_group it kills only this child. */
        arm_fault_handlers();
        int rc = elf_run_mem(img, len, argc, argv);
        fprintf(stdout, "[elf] child: guest returned rc=%d\n", rc);
        fflush(stdout);
        _exit(rc < 0 ? 127 : (rc & 0xff));
    }
    int st = 0;
    while (waitpid(pid, &st, 0) < 0) {
        if (errno != EINTR) {
            error("[elf] child-run: waitpid failed: %s", strerror(errno));
            return -1;
        }
    }
    if (WIFEXITED(st)) {
        trace("[elf] child exited with status %d", WEXITSTATUS(st));
        return WEXITSTATUS(st);
    }
    trace("[elf] child terminated abnormally (st=%#x)", st);
    return -1;
}

/* Run a dynamically-linked ELF main via interpreter hand-off in a child. */
int elf_run_dyn_child(const void *main_img, size_t main_len,
                      const void *ldso_img, size_t ldso_len,
                      int argc, char *const argv[])
{
    fflush(nullptr);
    pid_t pid = fork();
    if (pid < 0) {
        error("[elf] dyn-child: fork failed: %s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        arm_fault_handlers();
        LoadInfo m, l;
        if (load_segments((const u8 *)main_img, main_len, &m) != 0 || !m.dyn) {
            error("[elf] dyn-child: main not a loadable ET_DYN");
            _exit(127);
        }
        if (load_segments((const u8 *)ldso_img, ldso_len, &l) != 0 ||
            !l.dyn) {
            error("[elf] dyn-child: loader not a loadable ET_DYN");
            _exit(127);
        }
        trace("[elf] dyn: main base=%#lx entry=%#lx ldso base=%#lx entry=%#lx",
              (unsigned long)m.base, (unsigned long)m.entry,
              (unsigned long)l.base, (unsigned long)l.entry);
        void *smap = nullptr;
        size_t slen = 0;
        uintptr_t sp =
            make_guest_stack(argc, argv, m, &smap, &slen, 0, l.base);
        if (!sp) _exit(126);
        trace("[elf] dyn: jumping to ld.so entry=%#lx sp=%#lx",
              (unsigned long)l.entry, (unsigned long)sp);
        fflush(stdout);
        fflush(stderr);
        /* NOTE: signals stay unblocked in the child so the fault handler
         * can report a guest crash pc; the child is isolated anyway. */
        long rc = elf_switch_to_guest((void *)l.entry, (void *)sp);
        fprintf(stdout, "[elf] dyn: loader returned rc=%ld\n", rc);
        fflush(stdout);
        _exit(rc == 0 ? 0 : 125);
    }
    int st = 0;
    while (waitpid(pid, &st, 0) < 0) {
        if (errno != EINTR) {
            error("[elf] dyn-child: waitpid failed: %s", strerror(errno));
            return -1;
        }
    }
    if (WIFEXITED(st)) {
        trace("[elf] dyn child exited with status %d", WEXITSTATUS(st));
        return WEXITSTATUS(st);
    }
    trace("[elf] dyn child terminated abnormally (st=%#x)", st);
    return -1;
}

/* BetterSH integration: run a dynamically-linked ELF (interpreter hand-off)
 * directly in the CURRENT process (caller is already a forked child, so no
 * second fork).  Mirrors the child section of elf_run_dyn_child.  If the
 * guest calls exit_group it terminates this process; if it returns, the
 * mappings are cleaned up and rc is returned. */
extern "C" int elf_run_dyn_inproc(const void *main_img, size_t main_len,
                                  const void *ldso_img, size_t ldso_len,
                                  int argc, char *const argv[])
{
    arm_fault_handlers();
    LoadInfo m, l;
    /* The main image may be ET_EXEC: a non-PIE dynamic program (an official
     * release binary built with PIE off, such as kimi-code / SDK cmake) needs
     * the interpreter for relocation just like a PIE one -- the kernel also
     * starts the interpreter first for ET_EXEC + PT_INTERP and hands it
     * AT_ENTRY. Before this fix the check required !m.dyn, so such binaries
     * fell to the static path and faulted with pc=0 as soon as the guest
     * started (see ElfReadInterp in procmgr). */
    if (load_segments((const u8 *)main_img, main_len, &m) != 0)
        return -1;
    if (load_segments((const u8 *)ldso_img, ldso_len, &l) != 0 || !l.dyn) {
        munmap((void *)m.region_lo, m.region_hi - m.region_lo);
        return -1;
    }
    void *smap = nullptr;
    size_t slen = 0;
    uintptr_t sp =
        make_guest_stack(argc, argv, m, &smap, &slen, 0, l.base);
    if (!sp) {
        munmap((void *)m.region_lo, m.region_hi - m.region_lo);
        munmap((void *)l.region_lo, l.region_hi - l.region_lo);
        return -1;
    }
    fflush(stdout);
    fflush(stderr);
    long rc = elf_switch_to_guest((void *)l.entry, (void *)sp);
    munmap(smap, slen);
    munmap((void *)m.region_lo, m.region_hi - m.region_lo);
    munmap((void *)l.region_lo, l.region_hi - l.region_lo);
    return rc == 0 ? 0 : -1;
}

/* elf_switch_to_guest is implemented in guest_switch_x86_64.S or
 * guest_switch_aarch64.S, selected by the build. */
