// elf_loader.cpp — in-process ELF loader for ElfLoaderDemo.
//
// Port basis (see elf_loader.h for attribution): segment mapping follows
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

#include "elf_loader.h"


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
extern "C" __attribute__((visibility("hidden")))
volatile unsigned long elf_host_ctx[2] = {0, 0};

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
    (void)si;
    unsigned long pc = 0, fault = 0;
    ucontext_t *uc = (ucontext_t *)uctx;
#if defined(__aarch64__)
    pc = uc->uc_mcontext.pc;
    fault = uc->uc_mcontext.fault_address;
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

/* 崩溃取证。三个 guest runner 自己会调;给 procmgr 用的是文件末尾那个
 * elf_arm_fault_handlers 壳(BSH_FAULT_TRACE=1,见 ChildRunSoMain)。
 * 注意它**取代**进程原有的 SIGSEGV 处理 —— V8 的栈溢出兜底、node 的崩溃报告都靠
 * 各自的 handler,而 V8 那个在非栈溢出时会链到我们这份,所以开着通常两边都有。
 * 正因为它会插进别人的信号链,默认不装,只在排查时开。 */
static void arm_fault_handlers(void)
{
    /* 为什么给 handler 单独一个栈:guest 崩溃时**原来的栈往往正是坏的**
     * (爆栈、sp 指向没映射的地方),在坏栈上跑 handler 会二次故障,内核直接
     * 静默 SIGKILL —— 现象就是"进程 rc=139 但一行日志都没有"。 */
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
    sigaction(SIGILL, &sa, nullptr);   /* a_crash() 之类是非法指令,以前没接住 */
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
    // [elf] 信息行(错误仍经 error() 恒显)
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

int jit_toggle(int on)
{
    return prctl(JIT_PRCTL_OPT, 0, on, 0, 0);
}

/* mprotect that tolerates the HarmonyOS W^X/JIT policy.  Mode A mirrors
 * Termony jit.patch exactly; if it fails we fall back to a plain mprotect
 * and to the reversed prctl order, logging every attempt for on-device
 * tuning.  Returns 0 on success, -1 if all variants failed. */
int mprotect_final(void *addr, size_t n, int prot, const char *what)
{
    int rc, e1 = 0, e2 = 0;

    if (!(prot & PROT_EXEC)) {
        rc = mprotect(addr, n, prot);
        if (rc != 0) error("[elf] mprotect(%s) failed: %s", what, strerror(errno));
        return rc;
    }

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
        eh.e_ident[EI_VERSION] != EV_CURRENT || eh.e_machine != EM_AARCH64 ||
        (eh.e_type != ET_EXEC && eh.e_type != ET_DYN) || eh.e_phnum == 0) {
        error("[elf] bad ELF header (need little-endian aarch64 EXEC/DYN)");
        return -1;
    }
    if (eh.e_phentsize != sizeof(Elf64_Phdr) ||
        (size_t)eh.e_phoff + (size_t)eh.e_phnum * sizeof(Elf64_Phdr) > len) {
        error("[elf] bad program header table");
        return -1;
    }

    const bool dyn = eh.e_type == ET_DYN;
    const Elf64_Phdr *ph = (const Elf64_Phdr *)(img + eh.e_phoff);
    /* 带 PT_INTERP 的非 PIE 程序(ET_EXEC)同样**是动态的**:它的 exit/_Exit 由解释器
     * 接管,不能按静态 guest 去打退出桩(见下面 exit stub 那段)。 */
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

        /* 排查用（BSH_ELF_TRACE=1）：.bss 那截（p_filesz 之后）按定义应当是 0，
         * 这里扫一遍报出第一个非零字节的位置；顺便把已初始化部分的前 16 字节也打出来。
         * 起因：clang 在 ninja 环境下崩在"遍历 .bss 里的信号注册表"（ldr w0,[x1,#152]，
         * 索引来自 .bss 的计数器），怀疑那份表/计数器脏。这一行能一刀切地证否或证实。 */
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
     * 注意不能直接跳到 _Exit:它按定义不冲刷 stdio,guest 缓冲里没刷出的输出会
     * 整段丢掉(实测:静态 guest 里第二行 printf 就这么没了)。所以能拿到冲刷入口
     * 时注入一个小桩,先把退出码存起来、刷一遍所有流,再 _Exit:
     *
     *     sub sp, sp, #16
     *     str w0, [sp, #12]      // 保存退出码
     *     mov w0, #0
     *     bl  <flush>            // __stdio_exit 或 fflush(NULL):刷所有流
     *     ldr w0, [sp, #12]      // 还原退出码
     *     add sp, sp, #16
     *     b   <_Exit>
     *
     * 桩放在镜像后面的新页里(hint = maxva,内核自己找位置,所以不必 MAP_FIXED),
     * 写完再按 W^X 策略改成 RX。两个冲刷入口都拿不到才退回直接跳 _Exit 的老行为。
     * Only applied to static (ET_EXEC) guests -- never to a dynamic main or its
     * interpreter/libc image. */
    exit_vaddr = lookup_symbol_vaddr(img, len, "exit");
    exit_impl_vaddr = lookup_symbol_vaddr(img, len, "_Exit");
    if (!exit_impl_vaddr) exit_impl_vaddr = lookup_symbol_vaddr(img, len, "_exit");
    if (!dyn && !has_interp && exit_vaddr && exit_impl_vaddr) {
        uintptr_t from = (dyn ? region : 0) + exit_vaddr;
        uintptr_t to = (dyn ? region : 0) + exit_impl_vaddr;

        /* 注入退出桩(先找 musl 的 __stdio_exit:它不带参数、冲刷所有流;拿不到
         * 再退 fflush(NULL);都没有就跳过,保持老行为)。设备端 clang 的 sysroot
         * 是我们自建的 musl,其 libc.a 符号不全 —— 实测那里没有 fflush,但有
         * __stdio_exit,所以两者都要试。 */
        uintptr_t flush_vaddr = lookup_symbol_vaddr(img, len, "__stdio_exit");
        if (!flush_vaddr) flush_vaddr = lookup_symbol_vaddr(img, len, "fflush");
        trace("[elf] exit stub: flush vaddr=%#lx maxva=%#lx",
              (unsigned long)flush_vaddr, (unsigned long)maxva);
        if (flush_vaddr) {
            uint32_t *pg = (uint32_t *)mmap((void *)maxva, 4096, PROT_READ | PROT_WRITE,
                                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (pg == MAP_FAILED) {
                error("[elf] exit stub mmap @%#lx failed: %s",
                      (unsigned long)maxva, strerror(errno));
            } else {
                uintptr_t sa = (uintptr_t)pg;
                uint32_t *p = pg;
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
    /* 身份四项：单独看，和下面的"secure 位图"是一件事。 */
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
    /* 宿主 auxv 里**可能缺**这几个项（实测 release 构建的沙箱里 /proc/self/auxv 只有
     * PAGESZ/SECURE/RANDOM/HWCAP/HWCAP2 几项，没有 AT_PHDR 一家）—— 而 guest 的 musl
     * （static-PIE 与 ld-musl 都是）**必须**靠 AT_PHDR/AT_PHNUM/AT_PHENT 找到自己的程序头，
     * 再定位 _DYNAMIC 去做自举重定位。缺了就算出垃圾指针，第一条就 SIGSEGV
     * （实测 fault addr=0x220，PC 落在 __dls2 的重定位循环里）。
     * 所以缺什么补什么 —— 和 AT_BASE 的处理同一个套路。
     *
     * 同一个套路还欠两笔账，都是 LD_PRELOAD 死活不生效的根因（2026-10-02 定案）：
     *
     * ① AT_UID/AT_EUID/AT_GID/AT_EGID 必须**在 auxv 里出现**。musl 的 __dls3 用
     *    "present 位图"判自己是不是 secure：
     *        libc.secure = ((aux[0]&0x7800)!=0x7800 || aux[AT_UID]!=aux[AT_EUID] || …)
     *    decode_vec() 把 aux[0] 填成"哪些类型出现过"的位图，而 0x7800 恰好就是
     *    AT_UID(11)/AT_EUID(12)/AT_GID(13)/AT_EGID(14) 这四位。宿主沙箱的 auxv 少了
     *    它们 → 位图凑不齐 → musl 认定 secure → **静默丢掉 LD_PRELOAD 与
     *    LD_LIBRARY_PATH**（load_preload() 对加载失败不报错、不打印），症状就是
     *    "环境对、文件在、shim 就是不生效"。值取本进程真实 uid/gid（四个本来就相等）。
     *
     * ② AT_SECURE 对 guest 强制写 0。本机 LSM 会把 appspawn 出来的进程标成
     *    secureexec（实测宿主 auxv 里 AT_SECURE=1），而 libc 一旦看到它就把 LD_* 全丢
     *    （glibc 的 __libc_enable_secure、musl 的 libc.secure 一个道理）。AT_SECURE 要防
     *    的是"被提升权限的进程受外部 env 影响"，而这里 guest 与宿主**同一个 uid、同一套
     *    env（就是同一个进程里的 procmgr 设的）**，根本没有跨权限边界 —— 对我们纯粹是
     *    误伤，所以照抄宿主只会把 shim 一起误杀。 */
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
            val = 0; /* 见上面 ②：guest 与我们同 uid，secure 只会误杀 LD_PRELOAD */
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
    /* 身份四项：宿主缺了就按本进程真实 uid/gid 补上（见上面 ①）。 */
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

/* 对外导出的一层壳:下面那几个 guest runner 用的 arm_fault_handlers 在**匿名
 * namespace** 里(内部链接),procmgr 在另一个 TU 里看不到它。这里换一个名字导出
 * (同名的话匿名 namespace 里那三处调用会同时看到内外的两个声明,clang 直接报
 * "call is ambiguous" —— 实测踩过)。 */
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
     * ⚠ 但**同步故障信号不能屏蔽**（SIGSEGV/SIGBUS/SIGILL/SIGABRT）：同步信号的语义是
     * "这条指令引发的、必须当场处理"，屏蔽它不等于延后投递 —— 内核会直接按默认动作把
     * 进程杀掉，我们的取证 handler（OnSigFault）连一次都进不去。实测现象就是
     * "guest rc=139 且一行日志都没有"，查了两天全卡在这里。这四个从屏蔽集里摘掉之后，
     * guest 一崩就能打出 "[bsh] FAULT ... pc=... 所在映射: ..."。 */
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
    /* 主镜像允许 ET_EXEC:非 PIE 的动态程序(关掉 PIE 的官方发行二进制,如 kimi-code /
     * SDK 的 cmake)和 PIE 一样要靠解释器做重定位 —— 内核遇到 ET_EXEC + PT_INTERP
     * 也是先起解释器再把 AT_ENTRY 交给它。补丁前这里要求 !m.dyn,于是这类二进制
     * 只能落到静态路径,一进 guest 就 pc=0(见 procmgr 的 ElfReadInterp)。 */
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

#if !defined(__aarch64__)
/* x86_64 目标无 guest_switch.S(aarch64 汇编):stub 保证链接通过(不支持跑 arm guest) */
extern "C" long elf_switch_to_guest(void*, void*) { return -1; }
#endif
