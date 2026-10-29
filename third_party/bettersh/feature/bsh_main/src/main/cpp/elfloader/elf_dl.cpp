// elf_dl.cpp — minimal in-process dynamic linker for arbitrary aarch64 .so.
//
// Maps a shared object from memory (elf_map_image), parses its PT_DYNAMIC,
// applies RELA relocations (RELATIVE / GLOB_DAT / JUMP_SLOT / ABS*), and
// resolves undefined symbols first from previously loaded objects and then
// from the host process's own libc via dlsym(RTLD_DEFAULT) -- so a .so that
// depends only on common libc functions runs inside the sandbox without
// exec or filesystem access.
//
// Scope notes: static TLS / TLSDESC / IRELATIVE are reported as unsupported;
// constructors (.init_array) are not run yet.

#include "elf_loader.h"

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

/* TLSDESC resolver 的入口（汇编外壳，定义在文件后半）。除 x0 外不改任何寄存器，
 * 见 bsh_tlsdesc_entry 上面那段说明。 */
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
    /* ── TLS（PT_TLS）───────────────────────────────────────────────
     * 为什么会有这块：正常 musl/glibc 工具链（Rust、GCC、用 thread_local 的 C++）
     * 产出的 .so 带真 TLS，重定位里会出现 R_AARCH64_TLSDESC；而 OHOS clang 走
     * EMUTLS（无 PT_TLS、无 TLS 重定位），所以 python 那条路上一直没踩到。
     * 模板就在映射进来的镜像里（`.tdata` 属于某个 PT_LOAD），装载期直接指过去；
     * tls_filesz 之后的 `.tbss` 部分要靠每个线程的块自己清零。 */
    uintptr_t tls_tmpl;      /* = base + PT_TLS.p_vaddr（指向映射后的模板） */
    size_t tls_filesz;
    size_t tls_memsz;
    size_t tls_align;
    int tls_key_ok;          /* -1 未初始化；0 创建失败；1 可用 */
    pthread_key_t tls_key;   /* 每线程一块（析构器 free） */
};

DlObj g_objs[32];

/* ── 首选符号解析器（由宿主安装，见 elf_loader.h）─────────────────────────
 *
 * 为什么需要：宿主进程的**全局作用域**里可能存在与宿主库**同名但不是同一个实现**
 * 的符号，而 `dlsym(RTLD_DEFAULT)` 会先命中先加载的那个。
 *
 * 实测（2026-10-04，node 原生扩展）：应用自己链了鸿蒙的 `libace_napi.z.so`
 * （导出 190 个 `napi_*`），那是给 ArkTS 用的 N-API 实现；`libnode.so` 也导出
 * `napi_*`（145 个）。两者名字完全一样，而 libace_napi 是应用启动时就加载的、
 * libnode.so 是后来才 dlopen 的 —— 于是 addon 的 `napi_create_function` 被解析到
 * **libace_napi 的实现**上，拿 node 的 env 指针去调它：返回码是废的
 * （实测 status=10 "An exception is blocking"），下一个调用直接崩。
 *
 * 修法：让宿主在自己身上先找一遍。宿主就是"把 elf_dl 链进去的那个命令 so"
 * （dlopen_shim.c 用 dladdr+dlopen 拿到自己的 handle 再装上这个钩子）。
 * 没装钩子时行为与从前完全一致。
 *
 * ⚠ 这个变量在匿名 namespace 里（只有本 TU 用），而**设置它的函数必须定义在
 *   namespace 外面**（否则内部链接 + 没人调用 = 被优化掉，宿主的引用就变成
 *   未定义符号、整个 so dlopen 不进来 —— 实测踩过）。那个函数定义在 namespace
 *   收尾之后，同一个 TU 里照样能访问这个变量。 */
static void *(*g_prefer_sym)(const char *name) = NULL;

/* 诊断输出分两档：
 *   elog() = 出错（加载失败 / 符号没解析到 / 不支持的重定位）—— **无条件**打。
 *            否则调用方只能看到一句 "No such file or directory"（CPython 的 dlopen
 *            兜底就是这么糊），没法查。
 *   dlog() = 过程（装载成功、构造函数个数、依赖预载）—— 只在 BSH_ELFDL_TRACE=1 时打。
 *            这一档必须能关：elf_dl 现在编进了 libpython.so，默认打日志会污染
 *            `python -c "import numpy"` 的正常输出。 */
static int dl_trace_on(void)
{
    const char *v = getenv("BSH_ELFDL_TRACE");
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

void dlog(const char *fmt, ...)
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
    const Elf64_Phdr *ph =
        (const Elf64_Phdr *)(base + eh->e_phoff);
    for (int i = 0; i < eh->e_phnum; i++)
        if (ph[i].p_type == PT_DYNAMIC)
            return (Elf64_Dyn *)(base + ph[i].p_vaddr);
    return nullptr;
}

/* Bounded symbol count: prefer DT_HASH nchain, else a safe linear walk. */
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
        o->nsym = h[1]; /* nchain */
    } else {
        o->nsym = 1 << 20; /* conservative cap; guarded by strsz in lookup */
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

/* Resolve symbol idx: local definition first, then host libc. */
uintptr_t resolve_sym(DlObj *o, size_t idx)
{
    if (idx >= o->nsym) return 0;
    const Elf64_Sym *s = &o->symtab[idx];
    if (s->st_shndx != SHN_UNDEF && s->st_value)
        return o->base + s->st_value;
    const char *nm = sym_name(o, idx);
    if (!nm) return 0;
    /* 先问宿主自己（它可能和全局作用域里的同名符号**不是同一个实现**，
     * 见 g_prefer_sym 的说明），再退回全局作用域。 */
    void *p = g_prefer_sym ? g_prefer_sym(nm) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, nm);
    /* 弱未定义符号解析不到是**合法**的（按 ELF 语义取 0），不算错误。
     * numpy 的 C++ 扩展里 `__register_frame_info`/`__deregister_frame_info` 就是这种：
     * 它们是 crtbeginS.o 的 .eh_frame 注册样板，设备上没有任何库导出它们，但也不被调用。
     * 见 apply_relocs 里对应的放行。 */
    if (!p && ELF64_ST_BIND(s->st_info) != STB_WEAK)
        elog("[dl] %s: unresolved symbol %s", o->soname, nm);
    return (uintptr_t)p;
}

/* ── TLS（PT_TLS / R_AARCH64_TLSDESC）──────────────────────────────────────
 *
 * 背景：真 TLS 的 .so（Rust 编的 napi-rs 扩展、GCC 编的、用 thread_local 的 C++）
 * 在 aarch64 上的默认模型是 **TLSDESC**，重定位里会有 R_AARCH64_TLSDESC。这条
 * 以前是 "unsupported JMPREL reloc type 1031"，整个 .so 装载失败。
 *
 * AArch64 的 TLSDESC 约定（glibc 的 __tlsdesc_static 是同一套）：
 *   GOT 里那 16 个字节是**描述符** { resolver, arg }；代码这样用：
 *       adrp/ldr x1 = resolver ; x0 = &描述符 ; blr x1
 *       mrs x1, tpidr_el0 ; add x0, x1, x0        ；x0 = 变量地址
 *   也就是 **resolver 返回的是"相对 TP 的偏移"**，调用方再把 TP 加上去。
 *   入口时 x0 = &描述符（第一个字），glibc 的静态 resolver 就是 `ldr x0,[x0,#8]; ret`。
 *
 * 我们这么用：arg 指向一条 {对象, TLS 块内偏移} 记录，resolver 在**当前线程**上取
 * 该对象的 TLS 块（没有就分配 + 拷模板），返回 `块 + 偏移 - TP` —— 调用方加上 TP
 * 之后正好落回我们的堆块。**这条路不需要宿主配合、也不用碰 musl 的 TLS 表**：
 * 每线程一块、按对象存，析构器 free，用 pthread_key 实现。
 *
 * ⚠⚠ **resolver 除 x0 外不许改任何寄存器** —— 这条不写在普通 C ABI 里，是最容易
 * 翻车的地方（实测 2026-10-04 花了几轮才定位到）。编译器会把 TP 缓存在一个**临时
 * 寄存器**里跨 resolver 调用继续用，例如 uuid.linux-arm64-musl.node 里：
 *      12284: mrs  x11, TPIDR_EL0      ; 把 TP 缓存进 x11
 *      12288: strb w10, [x11, x0]      ; 第一次 TLS 访问（x0 = resolver 返回值）
 *      ...
 *      12298: blr  x1                  ; 第二次调 resolver
 *      1229c: str  x8, [x11, x0]       ; ← x11 还是那个 TP！
 * 也就是说调用方**假定 x1..x18 都没被改**。而我们的 C 体要调 pthread_getspecific/
 * calloc/fprintf —— 按 AAPCS64 这些都可能糊掉 x1..x18 与 v0-v7/v16-v31，于是第二
 * 次访问就用一个被污染的基址，直接 SIGSEGV（崩溃现场 addr 恰好等于 resolver 的
 * 返回值，因为 x11 已经变成 0 了）。
 * glibc 的 __tlsdesc_dynamic 也是这个道理：它进函数先把 x1..x4 存起来再调
 * __tls_get_addr。
 * 所以真正的入口是下面那段汇编 bsh_tlsdesc_entry：把 x1..x18/x29/x30 与
 * q0-q7/q16-q31 全存下来，调 C 体，再原样恢复（**x0 是返回值，不恢复**）。
 *
 * 做不了的：`R_AARCH64_TLS_TPREL64`（编译期就写死 tp 偏移的 initial-exec 模型）——
 * 那要求把块放进当前线程的**静态 TLS 区**，musl 的 dlopen 都不给我们这个机会。
 * 遇到就明确报错，别让人以为是别的问题。 */

struct TlsDescRec {
    DlObj *obj;
    size_t off;
};

/* 当前线程上这个对象的 TLS 块；没有就分配并拷模板。 */
void *tls_block_for(DlObj *o)
{
    if (o->tls_memsz == 0) return nullptr;
    if (o->tls_key_ok == 0) {          /* 0=还没建过（DlObj 是 memset 出来的） */
        o->tls_key_ok = (pthread_key_create(&o->tls_key, free) == 0) ? 1 : 2;
        if (o->tls_key_ok != 1)
            elog("[dl] %s: pthread_key_create 失败，TLS 用不了", o->soname);
    }
    if (o->tls_key_ok != 1) return nullptr;
    void *p = pthread_getspecific(o->tls_key);
    if (p) return p;
    p = calloc(1, o->tls_memsz);            /* calloc：.tbss 那截正好是 0 */
    if (!p) return nullptr;
    if (o->tls_filesz) memcpy(p, (const void *)o->tls_tmpl, o->tls_filesz);
    if (pthread_setspecific(o->tls_key, p) != 0) { free(p); return nullptr; }
    return p;
}

/* 从 ELF 头里读出 PT_TLS。**必须在调用方释放镜像缓冲之前做**（我们在装载期调用），
 * 模板指针指向映射后的镜像（`.tdata` 属于某个 PT_LOAD，已经拷进去了）。 */
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
    /* 弱未定义符号可以解析成 0，不能因此判失败（ELF 语义；numpy 扩展的
     * __register_frame_info 就靠这条活下来，见 resolve_sym 的说明）。 */
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
            val = resolve_sym(o, sidx);
            if (!val && sidx && !weak_ok(sidx)) return -1;
            *(uint64_t *)where = val + (uintptr_t)r->r_addend;
            return 0;
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
            /* 描述符 = {resolver, arg}。偏移取 addend；有符号时（非符号索引 0）
             * 还要加上 TLS 符号的 st_value —— 对 TLS 符号来说那也是个块内偏移。 */
            size_t off = (size_t)r->r_addend;
            if (sidx && sidx < o->nsym) off += (size_t)o->symtab[sidx].st_value;
            TlsDescRec *rec = (TlsDescRec *)malloc(sizeof(TlsDescRec));
            if (!rec) { elog("[dl] %s: TLSDESC 记录分配失败", o->soname); return -1; }
            rec->obj = o;
            rec->off = off;
            uintptr_t *slot = (uintptr_t *)where;
            slot[0] = (uintptr_t)&bsh_tlsdesc_entry;   /* 汇编外壳，见其上面那段说明 */
            slot[1] = (uintptr_t)rec;
            dlog("[dl] %s: TLSDESC off=%zu slot=%#lx", o->soname, off,
                 (unsigned long)where);
            return 0;
        }
        case R_AARCH64_TLS_TPREL64:
            /* initial-exec 模型：编译期就把 tp 偏移写死了，要求块在**静态 TLS 区**里。
             * 我们是自己 dlopen 的、musl 不知道这个模块，没有那个位置可用 —— 明确报出来。 */
            elog("[dl] %s: 不支持 static TLS(R_AARCH64_TLS_TPREL64) —— 该库需要 "
                 "-ftls-model=global-dynamic/-fPIC 重编", o->soname);
            return -1;
        case R_AARCH64_TLS_DTPMOD64:
        case R_AARCH64_TLS_DTPREL64:
            /* 这两个是"给 __tls_get_addr 用的 tls_index"的初始化，要走 musl 的模块表。
             * 目前没遇到的库（aarch64 默认产 TLSDESC），真遇到再说 —— 先报清楚。 */
            elog("[dl] %s: 不支持 GD 模型的 __tls_get_addr 路径(reloc %u)", o->soname, type);
            return -1;
        default:
            elog("[dl] %s: unsupported %s reloc type %u", o->soname, kind,
                 type);
            return -1;
        }
    };
    for (size_t i = 0; i < o->nrela; i++)
        if (apply_one(&o->rela[i], "RELA") != 0) return -1;
    for (size_t i = 0; i < o->njmprel; i++)
        if (apply_one(&o->jmprel[i], "JMPREL") != 0) return -1;
    return 0;
}

/* 先把 DT_NEEDED 里**能从系统找到的**依赖 dlopen 进来（RTLD_GLOBAL）。
 *
 * 为什么必须做：`resolve_sym` 兜底用的是 `dlsym(RTLD_DEFAULT)` —— 它只看**已经加载**
 * 的对象。而 C++ 扩展（numpy 的 `_multiarray_umath` 就是）NEEDED `libc++_shared.so`，
 * 那个库平时并不在主进程里，于是 `__register_frame_info` 这类符号谁也提供不了。
 * 实测报错：`do_dlsym failed: Symbol not found: __register_frame_info`。
 *
 * 打不开的（`libpython.so` 不在搜索路径、`libc.so` 由 musl 直接提供…）就当已经在场，
 * 静默略过 —— 它们本来就在全局命名空间里。
 */
void preload_needed(DlObj *o, Elf64_Dyn *dyn)
{
    if (!o->strtab) return;
    for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
        if (d->d_tag != DT_NEEDED) continue;
        const char *nm = o->strtab + d->d_un.d_val;
        if (!nm || !*nm) continue;
        void *h = dlopen(nm, RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            dlog("[dl] %s: 预加载依赖 %s ok", o->soname, nm);
        } else {
            /* 多数情况是"本来就在"，不当错误；trace 时才有必要看 */
            dlog("[dl] %s: 依赖 %s 不经 dlopen（按已在场处理）", o->soname, nm);
        }
    }
}

/* 跑构造函数：DT_INIT + DT_INIT_ARRAY。
 *
 * 必须做，且必须在重定位之后：numpy 的 `_multiarray_umath` 带 2 个 init_array 项，
 * 里面是它自己的类型/表注册，不跑的话 import 能"成功"但一用就崩。
 *
 * 两个标签的地址语义不同，别混：
 *   DT_INIT       给的是**链接期虚拟地址**，要自己加 base；
 *   DT_INIT_ARRAY 指向的数组元素已经被 RELATIVE 重定位改成**绝对地址**了
 *                 （上面 apply_relocs 干的），直接用。
 */
void run_init(DlObj *o, Elf64_Dyn *dyn)
{
    uintptr_t init = 0, arr = 0;
    size_t arrsz = 0;
    for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
        case DT_INIT:        init = (uintptr_t)d->d_un.d_ptr; break;
        case DT_INIT_ARRAY:  arr = (uintptr_t)d->d_un.d_ptr; break;
        case DT_INIT_ARRAYSZ: arrsz = (size_t)d->d_un.d_val; break;
        default: break;
        }
    }
    if (init) {
        dlog("[dl] %s: DT_INIT %#lx → 调用", o->soname, (unsigned long)(o->base + init));
        ((void (*)(void))(o->base + init))();
        dlog("[dl] %s: DT_INIT 返回", o->soname);
    }
    if (arr && arrsz) {
        const uintptr_t *a = (const uintptr_t *)(o->base + arr);
        size_t n = arrsz / sizeof(uintptr_t);
        dlog("[dl] %s: %zu 个 init_array", o->soname, n);
        for (size_t i = 0; i < n; i++) {
            if (!a[i]) continue;
            dlog("[dl] %s: init_array[%zu] = %#lx → 调用", o->soname, i,
                 (unsigned long)a[i]);
            ((void (*)(void))a[i])();
            dlog("[dl] %s: init_array[%zu] 返回", o->soname, i);
        }
    }
}

} /* namespace */

/* ── TLSDESC resolver 的两个入口 ──────────────────────────────────────────
 *   bsh_tlsdesc_entry        汇编外壳，**单独一个文件**（同目录 tlsdesc.S，与
 *                            guest_switch.S 一个待遇）：除 x0 外所有寄存器都要
 *                            保住 —— 理由与实测证据见上面那段"⚠⚠ resolver 除 x0
 *                            外不许改任何寄存器"，也抄了一份在 tlsdesc.S 里。
 *                            两个链接脚本（build_node.sh / build_python.sh）
 *                            都要编它：落下就是未定义符号，整个 so dlopen 不进来。
 *   bsh_tlsdesc_resolver_c   C 体（下面），只做算术与取块，寄存器由外壳负责。 */
extern "C" uintptr_t bsh_tlsdesc_resolver_c(void *desc);   /* C 体，定义在下面 */

/* C 体：x0 = &描述符，返回"相对 TP 的偏移"。**只允许改 x0**（外壳已经保证了其余）。 */
extern "C" uintptr_t bsh_tlsdesc_resolver_c(void *desc)
{
    TlsDescRec *rec = ((TlsDescRec **)desc)[1];
    if (!rec) return 0;
    void *blk = tls_block_for(rec->obj);
    if (!blk) return 0;
    uintptr_t tp = (uintptr_t)__builtin_thread_pointer();
    uintptr_t ret = (uintptr_t)((char *)blk + rec->off) - tp;
    dlog("[dl] TLSDESC 命中 %s off=%zu blk=%p tp=%#lx → 返回 %#lx",
         rec->obj->soname, rec->off, blk, (unsigned long)tp, (unsigned long)ret);
    return ret;
}

/* 首选符号解析器的安装入口。**必须定义在匿名 namespace 之外**：它只被宿主
 * （dlopen_shim.c）调用，留在 namespace 里就是内部链接 + 本 TU 无人调用，
 * -O2 会把它整个删掉 —— 于是宿主的引用变成未定义符号，libnode.so/libpython.so
 * 直接 dlopen 不进来（实测踩过：libnode.so 里留了个 U elf_dl_set_prefer_sym）。
 * 变量 g_prefer_sym 虽然内部链接，但同一个 TU 里可以照常访问。 */
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
        elog("[dl] object table full");
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
    /* PT_TLS 要从**调用方给的镜像缓冲**里读（img 在返回后就被释放了），所以在这里做 */
    collect_tls(o, img);
    /* 依赖先摆进来（它们提供 C++ 运行时那类符号，见 preload_needed 的说明） */
    preload_needed(o, dyn);
    collect_relocs(o, dyn);
    if (apply_relocs(o) != 0) {
        elog("[dl] %s: relocation failed", o->soname);
        munmap((void *)o->base, o->span);
        return nullptr;
    }
    o->used = true;
    dlog("[dl] loaded %s base=%#lx span=%#zx syms=%zu", o->soname,
         (unsigned long)o->base, o->span, o->nsym);
    /* used 先置上再跑构造函数：万一某个构造函数回头 dlsym 自己，dlsym_impl 得认这个 handle */
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
        if (nm && strcmp(nm, name) == 0) return (void *)(o->base + s->st_value);
    }
    return nullptr;
}

/* Thread-safe wrappers around the registry. */
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

/* 这个 handle 是不是我们发的？—— dlopen shim 必须把"系统给的 handle"和"我们给的
 * handle"分开：对前者 dlsym/dlclose 要走真实现，对后者走 elf_dlsym。
 * 判据是"地址落在 g_objs 数组里"，零成本且稳定（那些条目是我们自己分配的）。 */
int elf_dl_owns_handle(void *handle)
{
    DlObj *o = (DlObj *)handle;
    return o >= g_objs && o < g_objs + (sizeof(g_objs) / sizeof(g_objs[0]));
}
