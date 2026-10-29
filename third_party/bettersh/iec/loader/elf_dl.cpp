// loader/elf_dl.cpp — in-process dynamic linker for aarch64 shared objects.
//
// A .so that lives in the application's data directory cannot be mapped with
// PROT_EXEC: the sandbox refuses the mmap step, which the caller sees as
// "No such file or directory". This loader maps the object into anonymous
// memory instead, applies its RELA relocations, and resolves undefined symbols
// first from objects already loaded here and then from the host process
// (dlsym(RTLD_DEFAULT)), so a .so that only needs common libc symbols can run
// without exec and without file-backed executable mappings.
//
// Scope and limits:
//   * aarch64 only;
//   * static TLS (R_AARCH64_TLS_TPREL64) and the general-dynamic
//     __tls_get_addr path are reported as unsupported;
//   * TLSDESC is supported through the assembly shell in tlsdesc.S;
//   * constructors (DT_INIT / DT_INIT_ARRAY) are run, destructors are not;
//   * dlclose() keeps the image mapped.
//
// The object is loaded through the public API at the bottom, which is what
// loader/wrap.c calls when the system loader refuses a path.

#include "loader.h"

#include <dlfcn.h>
#include <elf.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if !ELFLOADER_ARCH_ARM64
#error "loader/elf_dl.cpp currently implements the aarch64 relocation model"
#endif

// Defined in tlsdesc.S. It saves every register except x0, calls the C body
// below, and restores them; see the comment in that file for the measured
// reason the C ABI is not sufficient here.
extern "C" void bsh_tlsdesc_entry(void);

namespace {

pthread_mutex_t g_dl_lock = PTHREAD_MUTEX_INITIALIZER;

struct DlObj {
    uintptr_t base;
    size_t span;
    char soname[64];
    const Elf64_Sym *symtab;
    size_t nsym;
    const char *strtab;
    size_t strsz;
    const Elf64_Rela *rela;
    size_t nrela;
    const Elf64_Rela *jmprel;
    size_t njmprel;
    bool used;

    // TLS (PT_TLS). The template lives in the mapped image; each thread gets
    // its own zero-filled block, with the .tdata prefix copied in. The part
    // after tls_filesz is .tbss and stays zero.
    uintptr_t tls_tmpl;
    size_t tls_filesz;
    size_t tls_memsz;
    size_t tls_align;
    int tls_key_ok;
    pthread_key_t tls_key;
};

DlObj g_objs[32];

// Optional first-chance resolver installed by the host object. The host may
// export a symbol with the same name as one in the global scope but with a
// different implementation (libnode's napi_* vs. libace_napi.z.so is the
// measured case). Asking the host first keeps the addon bound to the runtime
// that loaded it.
static void *(*g_prefer_sym)(const char *name) = NULL;

// eLog always prints; dLog is gated by IEC_ELFDL_TRACE because this file is
// linked into libpython.so and libnode.so and must not pollute normal output.
static int dl_trace_on(void)
{
    const char *v = getenv("IEC_ELFDL_TRACE");
    return v && *v && v[0] != '0';
}

static void elog(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

static void dlog(const char *fmt, ...)
{
    if (!dl_trace_on()) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

Elf64_Dyn *find_dynamic(uintptr_t base)
{
    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)base;
    const Elf64_Phdr *ph = (const Elf64_Phdr *)(base + eh->e_phoff);
    for (int i = 0; i < eh->e_phnum; i++)
        if (ph[i].p_type == PT_DYNAMIC)
            return (Elf64_Dyn *)(base + ph[i].p_vaddr);
    return nullptr;
}

// Bounded symbol count: use DT_HASH's nchain when present, otherwise a
// conservative cap that every lookup guards with DT_STRSZ.
void collect_symtab(DlObj *o, Elf64_Dyn *dyn)
{
    uintptr_t sym_va = 0, str_va = 0, strsz = 0, hash_va = 0;
    for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
        case DT_SYMTAB: sym_va = (uintptr_t)d->d_un.d_ptr; break;
        case DT_STRTAB: str_va = (uintptr_t)d->d_un.d_ptr; break;
        case DT_STRSZ: strsz = (uintptr_t)d->d_un.d_val; break;
        case DT_HASH: hash_va = (uintptr_t)d->d_un.d_ptr; break;
        default: break;
        }
    }
    o->symtab = (const Elf64_Sym *)(o->base + sym_va);
    o->strtab = (const char *)(o->base + str_va);
    o->strsz = strsz;
    if (hash_va) {
        const uint32_t *h = (const uint32_t *)(o->base + hash_va);
        o->nsym = h[1];
    } else {
        o->nsym = 1 << 20;
    }
}

void collect_relocs(DlObj *o, Elf64_Dyn *dyn)
{
    for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
        case DT_RELA:
            o->rela = (const Elf64_Rela *)(o->base + d->d_un.d_ptr);
            break;
        case DT_RELASZ:
            o->nrela = (size_t)d->d_un.d_val / sizeof(Elf64_Rela);
            break;
        case DT_JMPREL:
            o->jmprel = (const Elf64_Rela *)(o->base + d->d_un.d_ptr);
            break;
        case DT_PLTRELSZ:
            o->njmprel = (size_t)d->d_un.d_val / sizeof(Elf64_Rela);
            break;
        case DT_SONAME: {
            const char *s = o->strtab + d->d_un.d_val;
            snprintf(o->soname, sizeof(o->soname), "%s", s);
            break;
        }
        default:
            break;
        }
    }
}

const char *sym_name(const DlObj *o, size_t idx)
{
    if (idx >= o->nsym) return nullptr;
    const Elf64_Sym *s = &o->symtab[idx];
    if (s->st_name == 0 || (size_t)s->st_name >= o->strsz) return nullptr;
    return o->strtab + s->st_name;
}

// Resolve symbol idx: a local definition first, then the host, then the global
// scope. A weak undefined symbol may legitimately resolve to 0.
uintptr_t resolve_sym(DlObj *o, size_t idx)
{
    if (idx >= o->nsym) return 0;
    const Elf64_Sym *s = &o->symtab[idx];
    if (s->st_shndx != SHN_UNDEF && s->st_value)
        return o->base + s->st_value;

    const char *nm = sym_name(o, idx);
    if (!nm) return 0;

    void *p = g_prefer_sym ? g_prefer_sym(nm) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, nm);
    if (!p && ELF64_ST_BIND(s->st_info) != STB_WEAK)
        elog("[dl] %s: unresolved symbol %s", o->soname, nm);
    return (uintptr_t)p;
}

// ── TLS ────────────────────────────────────────────────────────────────────
//
// AArch64 uses TLSDESC by default: the GOT slot is a {resolver, arg} pair,
// the resolver returns an offset relative to the thread pointer, and the
// caller adds TP. Our arg points at a {object, offset} record; the C body
// below finds or allocates the current thread's block for that object.
//
// The resolver must not clobber any register except x0. This is not part of
// the normal C ABI: the caller keeps TP in a temporary register across the
// call. The assembly shell in tlsdesc.S saves and restores x1..x18, x29, x30,
// v0-v7 and v16-v31 around the C body.
//
// R_AARCH64_TLS_TPREL64 (initial-exec) would require a slot in the static TLS
// area owned by the real dynamic linker; that is not available to an object
// loaded here, so it is reported as an error.

struct TlsDescRec {
    DlObj *obj;
    size_t off;
};

void *tls_block_for(DlObj *o)
{
    if (o->tls_memsz == 0) return nullptr;
    if (o->tls_key_ok == 0) {
        o->tls_key_ok = (pthread_key_create(&o->tls_key, free) == 0) ? 1 : 2;
        if (o->tls_key_ok != 1)
            elog("[dl] %s: pthread_key_create failed; TLS is unavailable", o->soname);
    }
    if (o->tls_key_ok != 1) return nullptr;

    void *p = pthread_getspecific(o->tls_key);
    if (p) return p;

    p = calloc(1, o->tls_memsz);
    if (!p) return nullptr;
    if (o->tls_filesz) memcpy(p, (const void *)o->tls_tmpl, o->tls_filesz);
    if (pthread_setspecific(o->tls_key, p) != 0) {
        free(p);
        return nullptr;
    }
    return p;
}

// PT_TLS has to be read from the caller's image buffer, because that buffer is
// released after elf_dlopen_mem() returns. The template pointer itself points
// into the mapped image (the .tdata bytes belong to a PT_LOAD segment).
void collect_tls(DlObj *o, const void *img)
{
    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)img;
    if (eh->e_phoff == 0 || eh->e_phnum == 0) return;
    const Elf64_Phdr *ph = (const Elf64_Phdr *)((const char *)img + eh->e_phoff);
    for (int i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type != PT_TLS) continue;
        o->tls_tmpl = o->base + ph[i].p_vaddr;
        o->tls_filesz = (size_t)ph[i].p_filesz;
        o->tls_memsz = (size_t)ph[i].p_memsz;
        o->tls_align = ph[i].p_align ? (size_t)ph[i].p_align : 8;
        dlog("[dl] %s: PT_TLS filesz=%zu memsz=%zu align=%zu",
             o->soname, o->tls_filesz, o->tls_memsz, o->tls_align);
        return;
    }
}

int apply_relocs(DlObj *o)
{
    auto weak_ok = [o](size_t sidx) -> int {
        return sidx < o->nsym &&
               ELF64_ST_BIND(o->symtab[sidx].st_info) == STB_WEAK;
    };

    auto apply_one = [o, &weak_ok](const Elf64_Rela *r, const char *kind) -> int {
        const uint32_t type = (uint32_t)(r->r_info & 0xffffffff);
        const size_t sidx = (size_t)(r->r_info >> 32);
        uintptr_t where = o->base + r->r_offset;
        uintptr_t val = 0;

        switch (type) {
        case R_AARCH64_RELATIVE:
            val = o->base + (uintptr_t)r->r_addend;
            *(uint64_t *)where = val;
            return 0;
        case R_AARCH64_GLOB_DAT:
        case R_AARCH64_JUMP_SLOT:
        case R_AARCH64_ABS64:
            val = resolve_sym(o, sidx);
            if (!val && sidx && !weak_ok(sidx)) return -1;
            *(uint64_t *)where = val + (uintptr_t)r->r_addend;
            return 0;
        case R_AARCH64_ABS32:
            val = resolve_sym(o, sidx);
            if (!val && sidx && !weak_ok(sidx)) return -1;
            *(uint32_t *)where = (uint32_t)(val + (uintptr_t)r->r_addend);
            return 0;
        case R_AARCH64_TLSDESC: {
            size_t off = (size_t)r->r_addend;
            if (sidx && sidx < o->nsym) off += (size_t)o->symtab[sidx].st_value;
            TlsDescRec *rec = (TlsDescRec *)malloc(sizeof(TlsDescRec));
            if (!rec) {
                elog("[dl] %s: cannot allocate a TLSDESC record", o->soname);
                return -1;
            }
            rec->obj = o;
            rec->off = off;
            uintptr_t *slot = (uintptr_t *)where;
            slot[0] = (uintptr_t)&bsh_tlsdesc_entry;
            slot[1] = (uintptr_t)rec;
            dlog("[dl] %s: TLSDESC off=%zu slot=%#lx", o->soname, off,
                 (unsigned long)where);
            return 0;
        }
        case R_AARCH64_TLS_TPREL64:
            elog("[dl] %s: static TLS (R_AARCH64_TLS_TPREL64) is not supported; "
                 "rebuild the object with -ftls-model=global-dynamic -fPIC",
                 o->soname);
            return -1;
        case R_AARCH64_TLS_DTPMOD64:
        case R_AARCH64_TLS_DTPREL64:
            elog("[dl] %s: the __tls_get_addr (general-dynamic) path is not "
                 "supported (reloc %u)", o->soname, type);
            return -1;
        default:
            elog("[dl] %s: unsupported %s reloc type %u", o->soname, kind, type);
            return -1;
        }
    };

    for (size_t i = 0; i < o->nrela; i++)
        if (apply_one(&o->rela[i], "RELA") != 0) return -1;
    for (size_t i = 0; i < o->njmprel; i++)
        if (apply_one(&o->jmprel[i], "JMPREL") != 0) return -1;
    return 0;
}

// Load the DT_NEEDED entries that the system loader can find, with RTLD_GLOBAL,
// so their symbols are visible to dlsym(RTLD_DEFAULT). A failure is not an
// error: the dependency may already be present (libc, libpython).
void preload_needed(DlObj *o, Elf64_Dyn *dyn)
{
    if (!o->strtab) return;
    for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
        if (d->d_tag != DT_NEEDED) continue;
        const char *nm = o->strtab + d->d_un.d_val;
        if (!nm || !*nm) continue;
        void *h = dlopen(nm, RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            dlog("[dl] %s: preloaded dependency %s", o->soname, nm);
        } else {
            dlog("[dl] %s: dependency %s is treated as already present",
                 o->soname, nm);
        }
    }
}

// DT_INIT is a link-time virtual address and needs base added. DT_INIT_ARRAY
// elements have already been made absolute by the RELATIVE relocations above.
void run_init(DlObj *o, Elf64_Dyn *dyn)
{
    uintptr_t init = 0, arr = 0;
    size_t arrsz = 0;
    for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
        case DT_INIT:         init = (uintptr_t)d->d_un.d_ptr; break;
        case DT_INIT_ARRAY:   arr = (uintptr_t)d->d_un.d_ptr; break;
        case DT_INIT_ARRAYSZ: arrsz = (size_t)d->d_un.d_val; break;
        default: break;
        }
    }
    if (init) {
        dlog("[dl] %s: calling DT_INIT %#lx", o->soname,
             (unsigned long)(o->base + init));
        ((void (*)(void))(o->base + init))();
    }
    if (arr && arrsz) {
        const uintptr_t *a = (const uintptr_t *)(o->base + arr);
        size_t n = arrsz / sizeof(uintptr_t);
        for (size_t i = 0; i < n; i++) {
            if (!a[i]) continue;
            dlog("[dl] %s: calling init_array[%zu] = %#lx", o->soname, i,
                 (unsigned long)a[i]);
            ((void (*)(void))a[i])();
        }
    }
}

}  // namespace

// The C body of the TLSDESC resolver. It may change x0 only; the assembly
// shell preserves every other register.
extern "C" uintptr_t bsh_tlsdesc_resolver_c(void *desc);
extern "C" uintptr_t bsh_tlsdesc_resolver_c(void *desc)
{
    TlsDescRec *rec = ((TlsDescRec **)desc)[1];
    if (!rec) return 0;
    void *blk = tls_block_for(rec->obj);
    if (!blk) return 0;
    uintptr_t tp = (uintptr_t)__builtin_thread_pointer();
    uintptr_t ret = (uintptr_t)((char *)blk + rec->off) - tp;
    dlog("[dl] TLSDESC %s off=%zu blk=%p tp=%#lx -> %#lx",
         rec->obj->soname, rec->off, blk, (unsigned long)tp,
         (unsigned long)ret);
    return ret;
}

// This entry point must live outside the anonymous namespace: it is called by
// loader/wrap.c, and an internal-linkage function with no caller in this
// translation unit would be removed by the optimiser.
void elf_dl_set_prefer_sym(void *(*fn)(const char *name))
{
    g_prefer_sym = fn;
}

static void *dlopen_mem_impl(const void *img, size_t len, const char *name)
{
    if (!img || len < sizeof(Elf64_Ehdr)) return nullptr;

    DlObj *o = nullptr;
    for (int i = 0; i < 32; i++) {
        if (!g_objs[i].used) {
            o = &g_objs[i];
            break;
        }
    }
    if (!o) {
        elog("[dl] object table is full");
        return nullptr;
    }

    memset(o, 0, sizeof(*o));
    if (elf_map_image(img, len, &o->base, &o->span) != 0) return nullptr;
    snprintf(o->soname, sizeof(o->soname), "%s", name ? name : "anon.so");

    Elf64_Dyn *dyn = find_dynamic(o->base);
    if (!dyn) {
        elog("[dl] %s: no PT_DYNAMIC", o->soname);
        munmap((void *)o->base, o->span);
        return nullptr;
    }

    collect_symtab(o, dyn);
    collect_tls(o, img);
    preload_needed(o, dyn);
    collect_relocs(o, dyn);

    if (apply_relocs(o) != 0) {
        elog("[dl] %s: relocation failed", o->soname);
        munmap((void *)o->base, o->span);
        return nullptr;
    }

    // Mark the object used before running constructors: a constructor may
    // dlsym() its own handle.
    o->used = true;
    dlog("[dl] loaded %s base=%#lx span=%#zx syms=%zu", o->soname,
         (unsigned long)o->base, o->span, o->nsym);
    run_init(o, dyn);
    return o;
}

static void *dlsym_impl(void *handle, const char *name)
{
    DlObj *o = (DlObj *)handle;
    if (!o || !o->used || !name) return nullptr;
    for (size_t i = 0; i < o->nsym; i++) {
        const Elf64_Sym *s = &o->symtab[i];
        if (s->st_shndx == SHN_UNDEF || s->st_value == 0) continue;
        if ((s->st_info & 0xf) == STT_GNU_IFUNC) continue;
        const char *nm = sym_name(o, i);
        if (nm && strcmp(nm, name) == 0)
            return (void *)(o->base + s->st_value);
    }
    return nullptr;
}

void *elf_dlopen_mem(const void *img, size_t len, const char *name)
{
    pthread_mutex_lock(&g_dl_lock);
    void *h = dlopen_mem_impl(img, len, name);
    pthread_mutex_unlock(&g_dl_lock);
    return h;
}

void *elf_dlsym(void *handle, const char *name)
{
    pthread_mutex_lock(&g_dl_lock);
    void *p = dlsym_impl(handle, name);
    pthread_mutex_unlock(&g_dl_lock);
    return p;
}

// Distinguishes a handle issued by this loader from a system handle. The
// former is a pointer into g_objs, which is stable for the process lifetime.
int elf_dl_owns_handle(void *handle)
{
    DlObj *o = (DlObj *)handle;
    return o >= g_objs && o < g_objs + (sizeof(g_objs) / sizeof(g_objs[0]));
}
