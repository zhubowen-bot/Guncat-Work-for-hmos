#!/bin/bash
# build_zlib.sh — static zlib for the IEC git build.
#
# Installs libz.a and the headers under IEC_DEPS_DIR. The source tarball is
# downloaded into IEC_THIRDPARTY and kept out of git.
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

VER="$IEC_ZLIB_VER"
TAR="$IEC_THIRDPARTY/zlib-$VER.tar.gz"
SRC="$IEC_THIRDPARTY/zlib-$VER"
BUILD="$IEC_ROOT/build/zlib"
LIB="$IEC_DEPS_LIB/libz.a"

if [ -f "$LIB" ]; then
	iec_log "zlib already built: $LIB"
	exit 0
fi

if [ ! -f "$SRC/configure" ]; then
	if [ ! -s "$TAR" ]; then
		iec_log "download $IEC_ZLIB_URL"
		curl -L --retry 3 -m 300 -o "$TAR.part" "$IEC_ZLIB_URL" \
			|| iec_err "zlib download failed"
		mv "$TAR.part" "$TAR"
	fi
	mkdir -p "$IEC_THIRDPARTY"
	tar xzf "$TAR" -C "$IEC_THIRDPARTY"
fi
[ -f "$SRC/configure" ] || iec_err "unexpected zlib source layout: $SRC"

mkdir -p "$IEC_DEPS_LIB" "$IEC_DEPS_INC"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

iec_log "configure zlib"
CC="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld" \
CFLAGS="-O2 -fPIC -D__MUSL__ -DOHOS_NDK -I$IEC_DEPS_INC" \
LDFLAGS="-fuse-ld=lld --target=$TARGET --sysroot=$SYSROOT -L$IEC_DEPS_LIB" \
AR="$CLANG_DIR/llvm-ar" RANLIB="$CLANG_DIR/llvm-ranlib" \
"$SRC/configure" \
	--prefix="$IEC_DEPS_DIR/usr" \
	--libdir="$IEC_DEPS_LIB" \
	--includedir="$IEC_DEPS_INC" \
	--static > "$BUILD/configure.log" 2>&1 \
	|| { tail -20 "$BUILD/configure.log" >&2; iec_err "zlib configure failed"; }

iec_log "build zlib"
make -j"$JOBS" > "$BUILD/make.log" 2>&1 \
	|| { tail -20 "$BUILD/make.log" >&2; iec_err "zlib make failed"; }
make install > "$BUILD/install.log" 2>&1 \
	|| { tail -20 "$BUILD/install.log" >&2; iec_err "zlib install failed"; }

[ -f "$LIB" ] || iec_err "libz.a was not installed"
iec_log "zlib ready: $LIB"
