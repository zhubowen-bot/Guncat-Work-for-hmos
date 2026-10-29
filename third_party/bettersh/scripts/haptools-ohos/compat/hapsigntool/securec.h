/*
 * Minimal host-side stand-in for OpenHarmony's third_party/bounds_checking_function
 * <securec.h>. Only the subset actually referenced by hapsigntool_cpp is provided
 * (memset_s / memcpy_s / snprintf_s / sprintf_s), with the same bounds-checking
 * semantics: a call whose `count` exceeds `destMax` fails with EINVAL and zeroes
 * as much of the destination as it safely can.
 */
#ifndef HAPSIGNTOOL_HOST_COMPAT_SECUREC_H
#define HAPSIGNTOOL_HOST_COMPAT_SECUREC_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>

#ifndef EOK
#define EOK 0
#endif

#ifndef EINVAL
#define EINVAL 22
#endif

#ifndef RSIZE_MAX
#define RSIZE_MAX (SIZE_MAX >> 1)
#endif

typedef int errno_t;
typedef size_t rsize_t;

#ifdef __cplusplus
extern "C" {
#endif

errno_t memset_s(void *dest, rsize_t destMax, int c, rsize_t count);
errno_t memcpy_s(void *dest, rsize_t destMax, const void *src, rsize_t count);
errno_t memmove_s(void *dest, rsize_t destMax, const void *src, rsize_t count);
int snprintf_s(char *strDest, rsize_t destMax, rsize_t count, const char *format, ...);
int vsnprintf_s(char *strDest, rsize_t destMax, rsize_t count, const char *format, va_list argList);
int sprintf_s(char *strDest, rsize_t destMax, const char *format, ...);
errno_t strcpy_s(char *strDest, rsize_t destMax, const char *strSrc);
errno_t strncpy_s(char *strDest, rsize_t destMax, const char *strSrc, rsize_t count);
errno_t strcat_s(char *strDest, rsize_t destMax, const char *strSrc);

#ifdef __cplusplus
}
#endif

#endif /* HAPSIGNTOOL_HOST_COMPAT_SECUREC_H */
