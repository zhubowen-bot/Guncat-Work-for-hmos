#!/bin/bash
# build_curl.sh — static libcurl for the IEC git build.
#
# Requires zlib and OpenSSL in the IEC dependency prefix. Installs libcurl.a
# and a curl-config stub under IEC_CURL_DIR; the source tarball lives in
# IEC_THIRDPARTY and is ignored by git.
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

VER="$IEC_CURL_VER"
TAR="$IEC_THIRDPARTY/curl-$VER.tar.gz"
SRC="$IEC_THIRDPARTY/curl-$VER"
BLD="$IEC_ROOT/build/curl-build"
PREFIX="$IEC_CURL_DIR"

if [ -f "$PREFIX/lib/libcurl.a" ]; then
	iec_log "curl already built: $PREFIX"
	exit 0
fi
[ -f "$IEC_DEPS_LIB/libz.a" ] || iec_err "zlib is missing (run build_zlib.sh first)"
[ -f "$IEC_OPENSSL_DIR/lib/libssl.a" ] || iec_err "openssl is missing (run build_openssl.sh first)"

if [ ! -f "$SRC/configure" ]; then
	if [ ! -s "$TAR" ]; then
		iec_log "download $IEC_CURL_URL"
		curl -L --retry 3 -m 600 -o "$TAR.part" "$IEC_CURL_URL" \
			|| iec_err "curl download failed"
		mv "$TAR.part" "$TAR"
	fi
	mkdir -p "$IEC_THIRDPARTY"
	tar xzf "$TAR" -C "$IEC_THIRDPARTY"
fi
[ -f "$SRC/configure" ] || iec_err "unexpected curl source layout: $SRC"

NO_FORTIFY="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
rm -rf "$BLD"
mkdir -p "$BLD"

iec_log "configure curl (static, openssl + zlib)"
( cd "$BLD" && \
  "$SRC/configure" \
	--host=aarch64-unknown-linux-musl --build=x86_64-pc-linux-gnu \
	--prefix="$PREFIX" --libdir="$PREFIX/lib" \
	--disable-shared --enable-static \
	--with-openssl="$IEC_OPENSSL_DIR" \
	--with-zlib="$IEC_DEPS_DIR/usr" \
	--without-libpsl --without-libidn2 --without-brotli --without-zstd \
	--without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-quiche \
	--without-librtmp --without-libssh2 \
	--disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
	--disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher \
	--disable-mqtt --disable-smb --disable-ftp --disable-file --disable-docs \
	--disable-manual --disable-libcurl-option --disable-versioned-symbols \
	CC="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld $NO_FORTIFY" \
	AR="$CLANG_DIR/llvm-ar" RANLIB="$CLANG_DIR/llvm-ranlib" \
	CFLAGS="-O2 -fPIC" \
	LDFLAGS="-fuse-ld=lld --target=$TARGET --sysroot=$SYSROOT" \
	> "$BLD/configure.log" 2>&1 ) \
	|| { tail -30 "$BLD/configure.log" >&2; iec_err "curl configure failed"; }

iec_log "build curl"
make -C "$BLD" -j"$JOBS" > "$BLD/make.log" 2>&1 \
	|| { tail -30 "$BLD/make.log" >&2; iec_err "curl make failed"; }
make -C "$BLD" install-exec install-data install-pkgconfigDATA \
	> "$BLD/install.log" 2>&1 || true
rm -f "$PREFIX/bin/curl"

[ -f "$PREFIX/lib/libcurl.a" ] || {
	tail -30 "$BLD/install.log" >&2
	iec_err "libcurl.a was not installed"
}

# git's Makefile asks curl-config only for --vernum; the real flags are given
# on the make command line.
major="${VER%%.*}"
rest="${VER#*.}"
minor="${rest%%.*}"
patch="${rest#*.}"
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/curl-config" <<EOF
#!/bin/sh
case "\$1" in
  --vernum) printf '%02d%02d%02d\n' "$major" "$minor" "${patch%%[!0-9]*}" ;;
  --version) echo "$VER" ;;
  --cflags) echo "-I$PREFIX/include" ;;
  --libs)   echo "-L$PREFIX/lib -lcurl -lssl -lcrypto -lz" ;;
  --static-libs) echo "-L$PREFIX/lib -lcurl -lssl -lcrypto -lz" ;;
  --ssl-backends) echo "OpenSSL" ;;
  --protocols) echo "http https" ;;
  *) ;;
esac
EOF
chmod 0755 "$PREFIX/bin/curl-config"

iec_log "curl ready: $PREFIX/lib/libcurl.a"
