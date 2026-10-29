#!/usr/bin/env bash
# scripts/test_iec_native_host.sh — 宿主回归测试（不需要设备、不需要 OHOS SDK）。
#
# 覆盖本轮改动过的原生代码里能在宿主机验证的判据：
#   exec/exec_route.cpp      ResolveKind 对 launcher / ELF / shebang 的分类
#   exec/exec_server.cpp     cwd 存在但无搜索(x)权限时必须拒绝
#   exec/exec_ncp_refusal.h  NCP 平台级拒绝的分类（不能把请求级错误也熔断）
#   fs/shim.c                kPathMap 绝对路径映射、IEC_SHIM_LINK_STRICT 语义
#
# 构建方式沿用 scripts/test_exec_session.sh：用 cmake 在宿主编出 iec_server（能力字
# 0x11202 表示 chmod=1 fork=1 exec=2 path=2），再用 cc/c++ 单独编测试程序。
# 测试自身会打印每条断言，失败行以 FAIL 开头，整体退出码非 0。
#
#   ./scripts/test_iec_native_host.sh
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=build-cmake
CAPS=0x11202
JOBS=$(nproc 2>/dev/null || echo 4)

cmake -S . -B "$BUILD" \
    -DIEC_FAKE_SYSROOT=/ \
    -DIEC_PINNED_CAPS="$CAPS" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD" -j"$JOBS" --target iec_server iec_preload >/dev/null

mkdir -p "$BUILD/test"

# 服务端与 shim 共用的传输层，编法与 test_exec_session.sh 相同。
cc -std=gnu11 -I. -Icommon -D_GNU_SOURCE -c common/rpc.c \
    -o "$BUILD/test/rpc.o"
cc -std=gnu11 -I. -Icommon -D_GNU_SOURCE -c common/sock_client.c \
    -o "$BUILD/test/sock_client.o"
cc -std=gnu11 -I. -Icommon -D_GNU_SOURCE -c fs/resolver.c \
    -o "$BUILD/test/resolver.o"

# 测试程序直接链生产源文件：ResolveKind / ReadShebang / IsSoLauncher / 路径解析都用
# 真实现。--gc-sections 会丢掉测试没引用到的函数（例如 SpawnShebang 引用的
# StartByKind），所以不必把整个服务端拖进来。
c++ -std=c++17 -Wall -Wextra -ffunction-sections -fdata-sections \
    -I. -Icommon -D_GNU_SOURCE -DFAKE_SYSROOT='"/"' -pthread \
    tools/iec_native_host_selftest.cpp \
    exec/exec_session.cpp exec/exec_route.cpp exec/exec_shebang.cpp \
    exec/exec_so.cpp exec/path_resolver.cpp exec/elf.cpp exec/caps.cpp \
    logger/logger.cpp \
    "$BUILD/test/rpc.o" "$BUILD/test/sock_client.o" "$BUILD/test/resolver.o" \
    -Wl,--gc-sections \
    -o "$BUILD/test/iec_native_host_selftest"

echo "== 路由 / NCP 分类 / cwd 校验 =="
"$BUILD/test/iec_native_host_selftest" "$BUILD/dist/iec_server"

# fs shim 用生产同款的 LD_PRELOAD 形态（cmake 目标 iec_preload）。
echo
echo "== fs shim 路径映射 =="
cc -std=gnu11 -Wall -Wextra -I. -Icommon -D_GNU_SOURCE \
    tools/iec_fs_shim_host_test.c -o "$BUILD/test/iec_fs_shim_host_test"

# 临时根放在 /var/tmp：/tmp 本身会被 kPathMap 命中，根若在 /tmp 下，“已映射路径”
# 也会被再次匹配，测不出“不重复加前缀”。
FS_ROOT=$(mktemp -d /var/tmp/iec-fsroot.XXXXXX)
cleanup() { rm -rf "$FS_ROOT"; }
trap cleanup EXIT

IEC_SYSROOT="$FS_ROOT" \
LD_PRELOAD="$PWD/$BUILD/dist/libiec_preload.so" \
    "$BUILD/test/iec_fs_shim_host_test" "$FS_ROOT"
