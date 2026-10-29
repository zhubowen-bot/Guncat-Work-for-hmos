// bsh_xz.h — xz 解压（见 bsh_xz.c 里对来源与用途的说明）
#pragma once

#include <stddef.h>

/* 解 src 里 [off, off+len) 这一段 xz 流，写到 dst（先截断）。
 * len < 0 表示"从 off 一直读到文件尾"。成功返回 0，失败返回负值并写 err。 */
int bsh_xz_decompress_range(const char* src, long long off, long long len,
                            const char* dst, char* err, size_t errlen);
