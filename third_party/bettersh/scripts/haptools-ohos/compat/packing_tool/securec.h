/*
 * compat/securec.h — OpenHarmony third_party/bounds_checking_function 的极小替身
 *
 * 症状：packing_tool 的 src/log.cpp 直接 `#include <securec.h>`，而 securec 是 OHOS
 *       源码树里的 third_party（GN 里写的是 external_deps
 *       "bounds_checking_function:libsec_static"），我们的交叉工具链里没有。
 * 根因：整棵 packing_tool 只用到一个安全函数 —— log.cpp:49 的 vsnprintf_s。
 * 修法：只补这一个（语义照抄 bounds_checking_function：count 超 destMax 记 EINVAL，
 *       能写多少写多少并补 '\0'），不引入整个 securec 库。
 *       与 hapsigntool_cpp/compat/securec.h 同一个套路，只是按实际用量缩到最小。
 */
#ifndef PACKING_TOOL_OHOS_COMPAT_SECUREC_H
#define PACKING_TOOL_OHOS_COMPAT_SECUREC_H

#include <stdarg.h>
#include <stddef.h>

#ifndef EOK
#define EOK 0
#endif

#ifndef EINVAL
#define EINVAL 22
#endif

typedef int errno_t;
typedef size_t rsize_t;

#ifdef __cplusplus
extern "C" {
#endif

int vsnprintf_s(char *strDest, rsize_t destMax, rsize_t count, const char *format,
                va_list argList);
int snprintf_s(char *strDest, rsize_t destMax, rsize_t count, const char *format, ...);

#ifdef __cplusplus
}
#endif

#endif /* PACKING_TOOL_OHOS_COMPAT_SECUREC_H */
