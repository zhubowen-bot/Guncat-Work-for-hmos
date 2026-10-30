#!/usr/bin/env bash
# scripts/stress_exec_session.sh — host-side stress/lifetime test for exec_session.
#
# Builds the exec service with the same capability word as test_exec_session.sh,
# then builds tools/exec_session_stress.cpp against it and runs the stress phases:
# eight concurrent capped streams, two mid-stream cancellations, fifty
# start/release rounds watching fds and RSS, two hundred short sessions, and the
# 0/1/50 ms deadline edges.
#
#   ./scripts/stress_exec_session.sh
#
# Set IEC_STRESS_SANITIZE="" to build without ASan/UBSan (the default is
# "address,undefined": leaks and use-after-free are half of what this test is
# for). Set IEC_STRESS_SANITIZE=thread to look for races instead, one sanitizer at
# a time.
#
# The capability word 0x11202 means chmod=1, fork=1, exec=2, jit=0, path=2: fork is
# available, execve() works everywhere, and absolute paths are not rewritten into
# a fake root (there is no sandbox on a build host).
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=build-cmake
CAPS=0x11202
SAN="${IEC_STRESS_SANITIZE-address,undefined}"

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

CXXFLAGS=(-std=c++17 -O1 -g -Wall -Wextra -I. -Icommon -D_GNU_SOURCE -pthread)
if [[ -n "$SAN" ]]; then
    CXXFLAGS+=("-fsanitize=$SAN" -fno-omit-frame-pointer)
fi

c++ "${CXXFLAGS[@]}" \
    tools/exec_session_stress.cpp exec/exec_session.cpp \
    "$BUILD/test/rpc.o" "$BUILD/test/sock_client.o" \
    -o "$BUILD/test/exec_session_stress"

# halt_on_error: a sanitizer finding is a test failure, not a line in the log.
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=1:abort_on_error=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"

exec "$BUILD/test/exec_session_stress" "$BUILD/dist/iec_server"
