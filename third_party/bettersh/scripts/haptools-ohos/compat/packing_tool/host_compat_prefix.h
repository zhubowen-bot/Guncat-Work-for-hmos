/*
 * compat/host_compat_prefix.h — 构建时强制 -include 进去的标准库包含前缀
 *
 * 症状：用 aarch64-linux-musl-g++ 编 packing_tool/frameworks，几个 TU 报
 *         constants.h:172: error: 'vector' in namespace 'std' does not name a template type
 *         utils.cpp:531:  error: 'PATH_MAX' was not declared in this scope
 * 根因：上游这些头文件依赖 **OHOS 工具链的传递包含图**恰好把 <vector>/<limits.h> 带进来：
 *       constants.h 只用 std::vector<std::string> 却只 include 了 <string>；
 *       utils.cpp 用了 PATH_MAX 却没 include <limits.h>。GN 构建下 clang 的
 *       <getopt.h> / <string> 会顺带带上它们，musl-gcc 的图谱里没有。
 * 修法：不改上游源码（那是"这个仓库以外的工程事实"），照 hapsigntool_cpp/compat/
 *       host_compat_prefix.h 的老办法，用 `-include` 在**每个 TU 最前面**补上这层包含。
 *       只补声明，不补行为：任何一处真实的语义差异仍然会被编译器抓到。
 */
#ifndef PACKING_TOOL_OHOS_COMPAT_HOST_COMPAT_PREFIX_H
#define PACKING_TOOL_OHOS_COMPAT_HOST_COMPAT_PREFIX_H

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <limits.h>   /* PATH_MAX（Linux glibc/OHOS 都在这里；musl 亦同） */
#include <map>
#include <memory>
#include <string>
#include <vector>

#endif /* PACKING_TOOL_OHOS_COMPAT_HOST_COMPAT_PREFIX_H */
