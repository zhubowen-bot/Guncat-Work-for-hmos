#!/bin/bash
# build_openssl.sh — static OpenSSL for the IEC git build.
#
# Installs libssl.a, libcrypto.a and the headers under IEC_OPENSSL_DIR. The
# source tarball is downloaded into IEC_THIRDPARTY and ignored by git.
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

VER="$IEC_OPENSSL_VER"
TAR="$IEC_THIRDPARTY/openssl-$VER.tar.gz"
SRC="$IEC_THIRDPARTY/openssl-$VER"
OUT="$IEC_OPENSSL_DIR"
BLD="$IEC_ROOT/build/openssl-build"

if [ -f "$OUT/lib/libssl.a" ] && [ -f "$OUT/lib/libcrypto.a" ]; then
	iec_log "openssl already built: $OUT"
	exit 0
fi

command -v perl >/dev/null 2>&1 || iec_err "perl is required by OpenSSL's Configure"

if [ ! -f "$SRC/Configure" ]; then
	if [ ! -s "$TAR" ]; then
		iec_log "download $IEC_OPENSSL_URL"
		curl -L --retry 3 -m 600 -o "$TAR.part" "$IEC_OPENSSL_URL" \
			|| iec_err "openssl download failed"
		mv "$TAR.part" "$TAR"
	fi
	tmp="$IEC_ROOT/build/openssl-x"
	rm -rf "$tmp"
	mkdir -p "$tmp"
	tar xzf "$TAR" -C "$tmp"
	inner="$(ls "$tmp")"
	[ -n "$inner" ] || iec_err "empty openssl tarball"
	mv "$tmp/$inner" "$SRC"
	rmdir "$tmp"
fi
[ -f "$SRC/Configure" ] || iec_err "unexpected openssl source layout: $SRC"

case "$NATIVE_ARCH" in
	arm64-v8a) OSSL_TARGET="linux-aarch64" ;;
	x86_64)    OSSL_TARGET="linux-x86_64" ;;
	*) iec_err "unsupported NATIVE_ARCH=$NATIVE_ARCH" ;;
esac

rm -rf "$BLD"
mkdir -p "$BLD"

iec_log "configure openssl ($OSSL_TARGET, static)"
( cd "$BLD" && \
  CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
  AR="$CLANG_DIR/llvm-ar" RANLIB="$CLANG_DIR/llvm-ranlib" \
  CROSS_COMPILE= \
  perl "$SRC/Configure" "$OSSL_TARGET" \
	--prefix="$OUT" --openssldir="$OUT/ssl" --libdir=lib \
	no-shared no-module no-tests -fPIC \
	> "$BLD/configure.log" 2>&1 ) \
	|| { tail -30 "$BLD/configure.log" >&2; iec_err "openssl Configure failed"; }

iec_log "build openssl (this takes a few minutes)"
make -C "$BLD" -j"$JOBS" > "$BLD/make.log" 2>&1 \
	|| { tail -40 "$BLD/make.log" >&2; iec_err "openssl make failed"; }
make -C "$BLD" install_sw > "$BLD/install.log" 2>&1 \
	|| { tail -30 "$BLD/install.log" >&2; iec_err "openssl install failed"; }

for f in lib/libssl.a lib/libcrypto.a include/openssl/ssl.h; do
	[ -e "$OUT/$f" ] || iec_err "missing $OUT/$f"
done
iec_log "openssl ready: $OUT"
