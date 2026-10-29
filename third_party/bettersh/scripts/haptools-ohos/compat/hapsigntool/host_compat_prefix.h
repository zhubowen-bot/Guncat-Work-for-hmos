/*
 * Host-build compatibility prefix, force-included (-include) into every C++ TU of the
 * hapsigntool_cpp manual build.
 *
 * The GN/ohos-sdk build compiles a handful of headers that rely on transitive standard
 * library includes (e.g. utils/include/byte_array_utils.h uses std::vector while pulling
 * in a bogus "memory.h"; hap/verify/src/verify_hap.cpp calls std::filesystem::file_size
 * without including <filesystem>). The OHOS toolchain's include graph happens to provide
 * those. Rather than patching the checkout, the host build injects this small prefix.
 */
#ifndef HAPSIGNTOOL_HOST_COMPAT_PREFIX_H
#define HAPSIGNTOOL_HOST_COMPAT_PREFIX_H

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <memory>
#include <algorithm>
#include <filesystem>

#endif /* HAPSIGNTOOL_HOST_COMPAT_PREFIX_H */
