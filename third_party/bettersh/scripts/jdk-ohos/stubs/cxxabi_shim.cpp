/*
 * cxxabi_shim.cpp — BetterSH 自带的 C++ ABI 垫片（给 OHOS 上的 JDK）
 *
 * 为什么需要：
 *   OHOS SDK 的 sysroot 里没有任何 libc++ 运行时（既没有 libc++.so，也没有
 *   libc++abi.so / libunwind.so）。JDK 的目标端链接统一走
 *   `-stdlib=libc++ -nostdlib++`，于是所有 C++ ABI 符号（异常、operator new、
 *   RTTI 元对象）都成了悬空引用。这个 .so 就是拿来做最后一块拼图的：
 *   它只提供符号、不做实现——真跑异常路径就 abort，这在本场景里可接受，
 *   JDK 目标端代码基本不用异常做控制流。
 *
 * 构建方式见 scripts/build_jdk.sh 的 stubs 阶段：
 *   -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti -nostdlib
 *   -Wl,-soname,libcxxabi_shim.so -lc
 *
 * 符号清单是照着"链接 libjvm.so / libjli.so / java 可执行文件时到底缺哪些"定下来的。
 */

#include <stdlib.h>
#include <stddef.h>
#include <dlfcn.h>

#define BSH_EXPORT __attribute__((visibility("default")))

extern "C" {

/* ── 纯虚函数被调用：直接死 ───────────────────────────────── */
BSH_EXPORT void __cxa_pure_virtual(void) { abort(); }

/* ── 静态局部变量的线程安全初始化 ─────────────────────────
 * 用一个最小的标志位实现。宁可弱也不要复杂：JDK 目标端不会并发首次进入
 * 同一个 <clinit>。 */
typedef struct { int done; int waiters; } BshGuard;

BSH_EXPORT int  __cxa_guard_acquire(BshGuard* g) { if (g->done) return 0; g->done = 1; return 1; }
BSH_EXPORT void __cxa_guard_release(BshGuard* g) { g->done = 1; }
BSH_EXPORT void __cxa_guard_abort(BshGuard* g)   { g->done = 0; }

/* ── 异常分发 ──────────────────────────────────────────────
 * 不做真正的 unwinding：定位是"让链接器闭嘴"，真走到这里就 abort。 */
BSH_EXPORT void* __cxa_begin_catch(void* exc) { return exc; }
BSH_EXPORT void  __cxa_end_catch(void) {}
BSH_EXPORT void  __cxa_rethrow(void) { abort(); }
BSH_EXPORT void* __cxa_allocate_exception(size_t size) { return malloc(size); }
BSH_EXPORT void  __cxa_free_exception(void* exc) { free(exc); }
BSH_EXPORT void  __cxa_throw(void* exc, void* type, void (*dtor)(void*)) {
    (void)exc; (void)type; (void)dtor;
    abort();
}

/* __cxa_demangle：调用方拿它做栈回溯美化。返回 -2（invalid mangled name），
 * 调用方会退回用原始符号名，功能不受影响。 */
BSH_EXPORT char* __cxa_demangle(const char* mangled, char* buf, size_t* len, int* status) {
    (void)mangled; (void)buf; (void)len;
    if (status != NULL) *status = -2;
    return NULL;
}

/* __cxa_thread_atexit：libc++abi 的 thread_local 析构登记入口。
 * 它**不在** libc 里（musl/glibc 只有 __cxa_thread_atexit_impl），而我们没链
 * libc++abi；不补的话，任何用到 thread_local 非平凡析构的 .so —— libjvm.so
 * 就是 —— dlopen 时会直接 "symbol not found" 失败。
 * 有 impl 就转发（正常路径），没有就退化成不登记：线程退出时不跑析构，
 * 只泄漏不崩。 */
typedef int (*BshThreadAtexitImpl)(void (*)(void*), void*, void*);

BSH_EXPORT int __cxa_thread_atexit(void (*func)(void*), void* obj, void* dso_handle) {
    static BshThreadAtexitImpl impl = NULL;
    static int looked_up = 0;
    if (!looked_up) {
        impl = (BshThreadAtexitImpl)dlsym(RTLD_DEFAULT, "__cxa_thread_atexit_impl");
        looked_up = 1;
    }
    if (impl != NULL) {
        return impl(func, obj, dso_handle);
    }
    return 0;
}

/* RTTI vtable 里的占位析构函数（下面 asm 会引用这个符号名）。 */
BSH_EXPORT void bsh_cxxabi_shim_stub_dtor(void) { }

} /* extern "C" */

/* ── std::nothrow 与它的 operator new ───────────────────────
 * 注意不能加 extern "C"：这几个是 C++ 名字修饰（_ZnwmRKSt9nothrow_t 等），
 * 加了就变成 C 符号，链不到调用点上。 */
namespace std {
struct nothrow_t { };
BSH_EXPORT extern const nothrow_t nothrow;
const nothrow_t nothrow = { };
}

BSH_EXPORT void* operator new(size_t n, const std::nothrow_t&) noexcept { return malloc(n); }
BSH_EXPORT void* operator new[](size_t n, const std::nothrow_t&) noexcept { return malloc(n); }

/* ── RTTI 元对象 ────────────────────────────────────────────
 * JDK 目标端会引用 std::type_info 与 __cxxabiv1 那几个 type_info 子类的
 * vtable / typeinfo 符号。用 C++ 数据定义会被优化掉，所以直接在 .data 里
 * 按 Itanium ABI 的布局铺出来。
 *
 * 布局（AArch64，指针 8 字节）：
 *   typeinfo : [vptr][name]        （name 指向 .asciz 的改名串）
 *   vtable   : [offset-to-top=0][指向自身 typeinfo][dtor1][dtor2]
 *
 * 刻意做"简化版"：type_info 自身的 vptr 留 0，派生 type_info 也复用
 * std::type_info 的 vtable —— 这些对象在本场景只作占位符，没人会通过它们
 * 做 dynamic_cast 或虚析构。
 */
#define BSH_TYPEINFO(SYM, TYPENAME)                                          \
    __asm__(".pushsection .data\n"                                           \
            ".balign 8\n"                                                    \
            ".Lbsh_tname_" SYM ":\n"                                         \
            ".asciz \"" TYPENAME "\"\n"                                      \
            ".balign 8\n"                                                    \
            ".globl " SYM "\n"                                               \
            ".type " SYM ", @object\n"                                       \
            SYM ":\n"                                                        \
            ".xword 0\n"                       /* vptr（占位） */            \
            ".xword .Lbsh_tname_" SYM "\n"     /* name      */               \
            ".size " SYM ", . - " SYM "\n"                                   \
            ".popsection\n");

#define BSH_VTABLE(SYM, TI, DTOR)                                            \
    __asm__(".pushsection .data\n"                                           \
            ".balign 8\n"                                                    \
            ".globl " SYM "\n"                                               \
            ".type " SYM ", @object\n"                                       \
            SYM ":\n"                                                        \
            ".xword 0\n"                       /* offset-to-top */          \
            ".xword " TI "\n"                  /* 指向 typeinfo  */          \
            ".xword " DTOR "\n"                /* dtor1 */                   \
            ".xword " DTOR "\n"                /* dtor2 */                   \
            ".size " SYM ", . - " SYM "\n"                                   \
            ".popsection\n");

BSH_TYPEINFO("_ZTISt9type_info", "St9type_info")
BSH_VTABLE("_ZTVSt9type_info", "_ZTISt9type_info", "bsh_cxxabi_shim_stub_dtor")

BSH_TYPEINFO("_ZTIN10__cxxabiv117__class_type_infoE",
             "N10__cxxabiv117__class_type_infoE")
BSH_VTABLE("_ZTVN10__cxxabiv117__class_type_infoE",
           "_ZTIN10__cxxabiv117__class_type_infoE", "bsh_cxxabi_shim_stub_dtor")

BSH_TYPEINFO("_ZTIN10__cxxabiv120__si_class_type_infoE",
             "N10__cxxabiv120__si_class_type_infoE")
BSH_VTABLE("_ZTVN10__cxxabiv120__si_class_type_infoE",
           "_ZTIN10__cxxabiv120__si_class_type_infoE", "bsh_cxxabi_shim_stub_dtor")

BSH_TYPEINFO("_ZTIN10__cxxabiv121__vmi_class_type_infoE",
             "N10__cxxabiv121__vmi_class_type_infoE")
BSH_VTABLE("_ZTVN10__cxxabiv121__vmi_class_type_infoE",
           "_ZTIN10__cxxabiv121__vmi_class_type_infoE", "bsh_cxxabi_shim_stub_dtor")

BSH_TYPEINFO("_ZTIN10__cxxabiv123__fundamental_type_infoE",
             "N10__cxxabiv123__fundamental_type_infoE")
BSH_VTABLE("_ZTVN10__cxxabiv123__fundamental_type_infoE",
           "_ZTIN10__cxxabiv123__fundamental_type_infoE", "bsh_cxxabi_shim_stub_dtor")

BSH_TYPEINFO("_ZTIN10__cxxabiv119__pointer_type_infoE",
             "N10__cxxabiv119__pointer_type_infoE")
BSH_VTABLE("_ZTVN10__cxxabiv119__pointer_type_infoE",
           "_ZTIN10__cxxabiv119__pointer_type_infoE", "bsh_cxxabi_shim_stub_dtor")

#undef BSH_TYPEINFO
#undef BSH_VTABLE
