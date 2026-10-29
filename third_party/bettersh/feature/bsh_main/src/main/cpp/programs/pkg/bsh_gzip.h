// bsh_gzip.h — 解 gzip 流（apt 读 Packages.gz 用）
//
// 为什么要有它：Ubuntu 的包索引 dists/<suite>/<component>/binary-arm64/Packages.gz
// 是 gzip。我们已经在编 zstd 了，但索引没有 zstd 版本（只有 .gz 与 .xz），而 .gz
// 用 zlib 就能解 —— 比引一套 liblzma 便宜得多（zlib 编译快、体积小，thirdparty/zlib
// 本来就在仓库里，别的脚本也在用）。
#pragma once

#include <stddef.h>

/* 解 src 里 [off, off+len) 这一段 gzip 流，写到 dst（先截断）。
 * len < 0 表示"从 off 一直读到文件尾"。成功返回 0，失败返回负值并写 err。 */
int bsh_gzip_decompress_range(const char* src, long long off, long long len,
                              const char* dst, char* err, size_t errlen);
