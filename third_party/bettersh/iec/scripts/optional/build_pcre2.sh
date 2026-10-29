#!/bin/bash
# build_pcre2.sh — static pcre2 (8-bit) for the IEC git build.
#
# The source is cloned into IEC_THIRDPARTY/pcre2 and ignored by git. The
# build uses the OHOS CMake toolchain and installs libpcre2-8.a into the same
# prefix as zlib.
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

SRC="$IEC_THIRDPARTY/pcre2"
BUILD="$IEC_ROOT/build/pcre2"
LIB="$IEC_DEPS_LIB/libpcre2-8.a"

if [ -f "$LIB" ]; then
	iec_log "pcre2 already built: $LIB"
	exit 0
fi

[ -f "$SRC/CMakeLists.txt" ] || \
	iec_clone_if_missing "$SRC" "${IEC_PCRE2_REPO:-}"

case "$NATIVE_ARCH" in
	arm64-v8a) OHOS_ARCH_NAME="arm64-v8a" ;;
	x86_64)    OHOS_ARCH_NAME="x86_64" ;;
	*) iec_err "unsupported NATIVE_ARCH=$NATIVE_ARCH" ;;
esac

mkdir -p "$IEC_DEPS_LIB" "$IEC_DEPS_INC"
rm -rf "$BUILD"
mkdir -p "$BUILD"

iec_log "configure pcre2"
cmake -G Ninja -S "$SRC" -B "$BUILD" \
	-DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake" \
	-DOHOS_ARCH="$OHOS_ARCH_NAME" \
	-DCMAKE_INSTALL_PREFIX="$IEC_DEPS_DIR/usr" \
	-DCMAKE_INSTALL_LIBDIR="lib/$TARGET" \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
	-DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_32=OFF \
	-DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF \
	-DPCRE2_SUPPORT_JIT=OFF \
	> "$BUILD/configure.log" 2>&1 \
	|| { tail -25 "$BUILD/configure.log" >&2; iec_err "pcre2 configure failed"; }

iec_log "build pcre2"
ninja -C "$BUILD" > "$BUILD/build.log" 2>&1 \
	|| { tail -25 "$BUILD/build.log" >&2; iec_err "pcre2 build failed"; }
ninja -C "$BUILD" install > "$BUILD/install.log" 2>&1 \
	|| { tail -25 "$BUILD/install.log" >&2; iec_err "pcre2 install failed"; }

[ -f "$LIB" ] || iec_err "libpcre2-8.a was not installed"
iec_log "pcre2 ready: $LIB"
