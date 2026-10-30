// common/archive_extract.h — tar 解包核心，与 OHOS rawfile 无关。
//
// 设备上的 unpackResource(name, dest) 做两件事：先用 rawfile 管理器把
// resources/rawfile/<name> 读成内存，再把内存里的 tar 解到 dest。后者只依赖
// libarchive 的 read/write-disk 两组入口，和平台无关，所以单独放在这里：
// NAPI 侧只保留"读 rawfile + 参数转换"，宿主测试
// （tests/npm_unpack/harness.cpp）可以直接编译这份实现，跑真实的 npm.tar.gz。
#pragma once

// 这里用 <stddef.h> 而不是 <cstddef>：函数声明是 extern "C" 的，头文件也要能被
// 纯 C 的 harness 直接包含。
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 把 data 里的 tar（可带压缩，filter 全开）解到 dest。
//
// 返回值：0 = 全包解完；非 0 = 失败。
// dest 必须已经存在（调用方负责 mkdir -p，设备上是 napi_init.cpp 的 EnsureDirs）。
// 失败语义与设备一致：条目路径含 ".."、libarchive 报 FATAL、写盘失败都返回非 0；
// 已经写出的条目不会回滚，调用方（IecRuntime）靠 .unpack-complete 标记区分半棵树。
int IecExtractTar(const void* data, size_t size, const char* dest);

#ifdef __cplusplus
}
#endif
