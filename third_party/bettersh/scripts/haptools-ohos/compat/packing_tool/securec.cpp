/*
 * compat/securec.cpp — securec.h 的实际范围（见该头文件的"症状/根因/修法"）。
 *
 * 语义对齐 OpenHarmony bounds_checking_function：
 *   - destMax == 0 或 dest 为空 → EINVAL；
 *   - count >= destMax（装不下结尾 '\0'）→ EINVAL，且把 dest 尽可能清空；
 *   - 正常路径等价 vsnprintf，返回值与 libc 一致（可为被截断的长度）。
 * 调用方 log.cpp 只在 snprintf 语义下用它（count = sizeof(buf)-1），所以正常路径
 * 与 libc 完全一致。
 */
#include "securec.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

int vsnprintf_s(char *strDest, rsize_t destMax, rsize_t count, const char *format,
                va_list argList)
{
    if (strDest == nullptr || destMax == 0 || destMax > (size_t)-1 / 2) {
        return -EINVAL;
    }
    if (count >= destMax) {
        strDest[0] = '\0';
        return -EINVAL;
    }
    int ret = vsnprintf(strDest, destMax, format, argList);
    if (ret < 0) {
        strDest[0] = '\0';
        return -EINVAL;
    }
    return ret;
}

int snprintf_s(char *strDest, rsize_t destMax, rsize_t count, const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int ret = vsnprintf_s(strDest, destMax, count, format, ap);
    va_end(ap);
    return ret;
}
