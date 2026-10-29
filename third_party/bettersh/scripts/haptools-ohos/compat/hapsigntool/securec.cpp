#include "securec.h"

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

errno_t memset_s(void *dest, rsize_t destMax, int c, rsize_t count)
{
    if (dest == NULL || destMax > RSIZE_MAX || destMax == 0) {
        return EINVAL;
    }
    if (count > destMax) {
        (void)memset(dest, (int)c, destMax);
        return EINVAL;
    }
    (void)memset(dest, (int)c, count);
    return EOK;
}

errno_t memcpy_s(void *dest, rsize_t destMax, const void *src, rsize_t count)
{
    if (dest == NULL || src == NULL || destMax > RSIZE_MAX) {
        return EINVAL;
    }
    if (count > destMax) {
        (void)memset(dest, 0, destMax);
        return EINVAL;
    }
    if (count == 0) {
        return EOK;
    }
    if (dest == src) {
        return EOK;
    }
    (void)memcpy(dest, src, count);
    return EOK;
}

errno_t memmove_s(void *dest, rsize_t destMax, const void *src, rsize_t count)
{
    if (dest == NULL || src == NULL || destMax > RSIZE_MAX) {
        return EINVAL;
    }
    if (count > destMax) {
        (void)memset(dest, 0, destMax);
        return EINVAL;
    }
    (void)memmove(dest, src, count);
    return EOK;
}

int vsnprintf_s(char *strDest, rsize_t destMax, rsize_t count, const char *format, va_list argList)
{
    if (strDest == NULL || format == NULL || destMax == 0 || destMax > RSIZE_MAX ||
        count > destMax || count == 0) {
        if (strDest != NULL && destMax > 0 && destMax <= RSIZE_MAX) {
            strDest[0] = '\0';
        }
        return -1;
    }
    int ret = vsnprintf(strDest, (size_t)count, format, argList);
    if (ret < 0) {
        strDest[0] = '\0';
    }
    return ret;
}

int snprintf_s(char *strDest, rsize_t destMax, rsize_t count, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int ret = vsnprintf_s(strDest, destMax, count, format, args);
    va_end(args);
    return ret;
}

int sprintf_s(char *strDest, rsize_t destMax, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int ret = vsnprintf_s(strDest, destMax, destMax, format, args);
    va_end(args);
    return ret;
}

errno_t strcpy_s(char *strDest, rsize_t destMax, const char *strSrc)
{
    if (strDest == NULL || strSrc == NULL || destMax == 0 || destMax > RSIZE_MAX) {
        return EINVAL;
    }
    size_t len = strlen(strSrc);
    if (len >= destMax) {
        strDest[0] = '\0';
        return EINVAL;
    }
    (void)memcpy(strDest, strSrc, len + 1);
    return EOK;
}

errno_t strncpy_s(char *strDest, rsize_t destMax, const char *strSrc, rsize_t count)
{
    if (strDest == NULL || strSrc == NULL || destMax == 0 || destMax > RSIZE_MAX) {
        return EINVAL;
    }
    size_t srclen = strnlen(strSrc, count);
    if (srclen >= destMax) {
        strDest[0] = '\0';
        return EINVAL;
    }
    (void)memcpy(strDest, strSrc, srclen);
    strDest[srclen] = '\0';
    return EOK;
}

errno_t strcat_s(char *strDest, rsize_t destMax, const char *strSrc)
{
    if (strDest == NULL || strSrc == NULL || destMax == 0 || destMax > RSIZE_MAX) {
        return EINVAL;
    }
    size_t destlen = strnlen(strDest, destMax);
    if (destlen >= destMax) {
        strDest[0] = '\0';
        return EINVAL;
    }
    size_t srclen = strlen(strSrc);
    if (destlen + srclen >= destMax) {
        strDest[0] = '\0';
        return EINVAL;
    }
    (void)memcpy(strDest + destlen, strSrc, srclen + 1);
    return EOK;
}

#ifdef __cplusplus
}
#endif
