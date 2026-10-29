/*
 * eh_stubs.c — C 侧 C++ 运行时符号（给 OHOS 上的 JDK）
 *
 * 和 cxxabi_shim.cpp 是一套东西，拆开只是因为这几个符号用纯 C 定义更省事
 * （不需 C++ 编译，也不会被 -fno-rtti/-fno-exceptions 影响）。
 *
 * 同样只求"链接得上"：真进异常路径就 abort。
 */

#include <stdlib.h>

#define BSH_SYM __attribute__((visibility("default")))

/* Itanium C++ ABI 的 personality routine。正常实现要做 landing pad 派发，
 * 我们不做任何处理；走到这里说明有异常在跨帧传播，直接 abort。 */
BSH_SYM int __gxx_personality_v0(int version, int actions,
                                 unsigned long long exception_class,
                                 void* exception_object, void* context) {
    (void)version; (void)actions; (void)exception_class;
    (void)exception_object; (void)context;
    abort();
    return 0;
}

BSH_SYM void _Unwind_Resume(void* exc) { (void)exc; abort(); }

/* std::terminate() 的 mangled 名。 */
BSH_SYM void _ZSt9terminatev(void) { abort(); }

/* operator new / new[] / delete / delete[]（含 sized delete）。 */
BSH_SYM void* _Znwm(unsigned long n) {
    void* p = malloc(n);
    if (p == NULL) abort();
    return p;
}

BSH_SYM void* _Znam(unsigned long n) {
    void* p = malloc(n);
    if (p == NULL) abort();
    return p;
}

BSH_SYM void _ZdlPv(void* p) { free(p); }
BSH_SYM void _ZdaPv(void* p) { free(p); }
BSH_SYM void _ZdlPvm(void* p, unsigned long n) { (void)n; free(p); }
BSH_SYM void _ZdaPvm(void* p, unsigned long n) { (void)n; free(p); }
