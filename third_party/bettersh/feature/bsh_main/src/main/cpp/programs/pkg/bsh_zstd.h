// bsh_zstd.h — pkg 用的 zstd **解压**（不带压缩）
//
// 为什么要有它：包现在按 `tar.zst` 发。一个 1.8 GiB 的 SDK 树：未压缩 1.8 GiB、
// gzip 约 560 MiB、zstd -19 只有 242 MiB（还能把 clang/clang++ 这种真副本去重）。
// 而 `bsh_tar.c` 只认**未压缩** tar，所以下载 + 校验 sha256 之后，先把 zstd 解成一个
// 普通 .tar，再交给它去解包。
//
// 只编 zstd 的**解压半边**（lib/decompress + 少数 lib/common，见 CMakeLists）：
// 不编 compress / dictBuilder / legacy / 多线程，libpkg.so 不会因此变胖多少。
#pragma once

#include <stddef.h>

/* src(.tar.zst) → dst(裸 .tar)。成功返回 0；失败返回负值并把原因写进 err。 */
int bsh_zstd_decompress_file(const char* src, const char* dst,
                             char* err, size_t errlen);

/* 同一件事，但只解 src 里 [off, off+len) 这一段 —— apt 解 .deb 内部的 ar 成员要用
 * （成员夹在文件中间，不是独立文件）。len < 0 表示"从 off 一直读到文件尾"。 */
int bsh_zstd_decompress_range(const char* src, long long off, long long len,
                              const char* dst, char* err, size_t errlen);
