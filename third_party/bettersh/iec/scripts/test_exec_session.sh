#!/usr/bin/env bash
# scripts/test_exec_session.sh — host acceptance for exec/exec_session.cpp.
#
# Builds the exec service with the capability word the test needs, then builds and
# runs tools/exec_session_selftest.cpp against it. Everything runs on the build
# host: no device and no OHOS SDK are involved, which is the point -- the engine
# (pipes, deadline, cancellation, cap) is ordinary POSIX and can be exercised
# here.
#
#   ./scripts/test_exec_session.sh
#
# The capability word 0x11202 means chmod=1, fork=1, exec=2, jit=0, path=2:
# fork is available, execve() works everywhere, and absolute paths are not
# rewritten into a fake root (there is no sandbox on a build host).
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=build-cmake
CAPS=0x11202

cmake -S . -B "$BUILD" \
    -DIEC_FAKE_SYSROOT=/ \
    -DIEC_PINNED_CAPS="$CAPS" \
    -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD" -j"$(nproc 2>/dev/null || echo 4)" --target iec_server >/dev/null

mkdir -p "$BUILD/test"

cc -std=gnu11 -I. -Icommon -D_GNU_SOURCE -c common/rpc.c \
    -o "$BUILD/test/rpc.o"
cc -std=gnu11 -I. -Icommon -D_GNU_SOURCE -c common/sock_client.c \
    -o "$BUILD/test/sock_client.o"

c++ -std=c++17 -Wall -Wextra -I. -Icommon -D_GNU_SOURCE -pthread \
    tools/exec_session_selftest.cpp exec/exec_session.cpp \
    "$BUILD/test/rpc.o" "$BUILD/test/sock_client.o" \
    -o "$BUILD/test/exec_session_selftest"

exec "$BUILD/test/exec_session_selftest" "$BUILD/dist/iec_server"
