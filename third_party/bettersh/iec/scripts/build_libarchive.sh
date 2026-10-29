#!/bin/bash
# build_libarchive.sh — libarchive for IEC.
#
# libarchive is a core IEC dependency, not an optional command. It is built as
# both a static library and a shared object:
#
#   * the static archive is what a component links directly (for example a
#     native unpacker for the node/python tarballs), so it adds no runtime
#     dependency;
#   * the shared object is copied into the IEC HAR libs/ directory, where it can
#     be loaded by soname or linked by a command object.
#
# The build is deliberately small:
#   * zlib is enabled (plain tar needs no compression, but gzip archives are
#     common and zlib is already in IEC_DEPS_DIR);
#   * bzip2, xz, lz4, zstd, OpenSSL, libxml2, expat and iconv are disabled;
#   * the bsdtar/bsdcpio/bsdcat/bsdunzip front ends are disabled (library only);
#   * ACL and xattr support is disabled (the OHOS sysroot does not provide the
#     interfaces libarchive expects).
#
# Usage:
#   scripts/build_libarchive.sh
#   IEC_LIBARCHIVE_VER=3.7.7 scripts/build_libarchive.sh
#   LIBARCHIVE_SHARED=0 scripts/build_libarchive.sh   # static only
#
# Output:
#   $IEC_DEPS_DIR/usr/lib/$TARGET/libarchive.a
#   $IEC_DEPS_DIR/usr/lib/$TARGET/libarchive.so*
#   platform/ohos/har/libs/arm64-v8a/libarchive.so*   (when LIBARCHIVE_SHARED=1)
#   platform/ohos/har/libs/arm64-v8a/libbsdtar.so     (when LIBARCHIVE_CLI=1)
#   platform/ohos/har/libs/arm64-v8a/libbsdunzip.so
#   platform/ohos/har/libs/arm64-v8a/libbsdcpio.so
#   $IEC_DEPS_INC/archive.h
#   $IEC_DEPS_INC/archive_entry.h
#
# The command objects are linked with the IEC fs/tty/exec shims, so libarchive's
# own open/stat/symlink calls use the sandbox semantics (including .IEC_SYMLINK
# markers) instead of the raw syscalls.
#
# Link with:
#   -L$IEC_DEPS_LIB -larchive -lz
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

VER="${IEC_LIBARCHIVE_VER:-3.7.7}"
URL="${IEC_LIBARCHIVE_URL:-https://libarchive.org/downloads/libarchive-$VER.tar.xz}"

SOURCE_CACHE="${IEC_SOURCE_CACHE:-$IEC_ROOT/thirdparty}"
[ -d "$SOURCE_CACHE" ] || SOURCE_CACHE="$IEC_THIRDPARTY"
TARBALL="$SOURCE_CACHE/libarchive-$VER.tar.xz"
SRC="${IEC_LIBARCHIVE_SRC:-$SOURCE_CACHE/libarchive-$VER}"
BUILD="${LIBARCHIVE_BUILD:-$IEC_ROOT/build/libarchive}"
LIB="$IEC_DEPS_LIB/libarchive.a"
INCF="$IEC_DEPS_INC/archive.h"
SHARED="${LIBARCHIVE_SHARED:-1}"
CLI="${LIBARCHIVE_CLI:-1}"
HAR_LIBS="${LIBARCHIVE_HAR_LIBS:-$IEC_ROOT/platform/ohos/har/libs/arm64-v8a}"

CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld"
AR="${AR:-$CLANG_DIR/llvm-ar}"
RANLIB="${RANLIB:-$CLANG_DIR/llvm-ranlib}"
NM="${NM:-$CLANG_DIR/llvm-nm}"
READELF="${READELF:-$CLANG_DIR/llvm-readelf}"

[ -f "$IEC_DEPS_LIB/libz.a" ] || "$IEC_ROOT/scripts/optional/build_zlib.sh"

if [ ! -f "$SRC/configure" ]; then
	if [ ! -s "$TARBALL" ]; then
		mkdir -p "$SOURCE_CACHE"
		iec_log "download $URL"
		curl -L --retry 3 -m 600 -o "$TARBALL.part" "$URL" \
			|| iec_err "libarchive download failed: $URL"
		mv "$TARBALL.part" "$TARBALL"
	fi
	iec_log "extract libarchive $VER -> $SOURCE_CACHE"
	mkdir -p "$SOURCE_CACHE"
	tar -xJf "$TARBALL" -C "$SOURCE_CACHE"
fi
[ -f "$SRC/configure" ] || iec_err "unexpected libarchive source layout: $SRC"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$IEC_DEPS_LIB" "$IEC_DEPS_INC"

SHARED_FLAG=(--disable-shared)
[ "$SHARED" = "1" ] && SHARED_FLAG=(--enable-shared)

iec_log "configure libarchive $VER (static, zlib only, shared=$SHARED)"
( cd "$BUILD" && \
	CC="$CC_TARGET" AR="$AR" RANLIB="$RANLIB" \
	CFLAGS="-O2 -fPIC -D__MUSL__ -DOHOS_NDK -I$IEC_DEPS_INC" \
	CPPFLAGS="-I$IEC_DEPS_INC" \
	LDFLAGS="-fuse-ld=lld --target=$TARGET --sysroot=$SYSROOT -L$IEC_DEPS_LIB" \
	PKG_CONFIG_LIBDIR="$IEC_DEPS_LIB/pkgconfig:$IEC_DEPS_DIR/usr/lib/pkgconfig" \
	PKG_CONFIG_PATH="" \
	"$SRC/configure" \
		--host=aarch64-linux-musl --build=x86_64-pc-linux-gnu \
		--prefix="$IEC_DEPS_DIR/usr" \
		--libdir="$IEC_DEPS_LIB" \
		--includedir="$IEC_DEPS_INC" \
		--enable-static "${SHARED_FLAG[@]}" \
		--with-zlib \
		--without-bz2lib --without-lzma --without-lz4 --without-zstd \
		--without-openssl --without-xml2 --without-expat --without-nettle \
		--without-iconv \
		--disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
		--disable-acl --disable-xattr \
		> "$BUILD/configure.log" 2>&1 ) \
	|| { tail -30 "$BUILD/configure.log" >&2; iec_err "libarchive configure failed"; }

iec_log "build libarchive"
make -C "$BUILD" -j"$JOBS" > "$BUILD/make.log" 2>&1 \
	|| { tail -40 "$BUILD/make.log" >&2; iec_err "libarchive make failed"; }
make -C "$BUILD" install > "$BUILD/install.log" 2>&1 \
	|| { tail -30 "$BUILD/install.log" >&2; iec_err "libarchive install failed"; }

[ -f "$LIB" ] || iec_err "missing $LIB"
[ -f "$INCF" ] || iec_err "missing $INCF"
"$NM" "$LIB" >/dev/null 2>&1 || iec_err "libarchive.a is not readable"

# The shared object is built again from the static archive so that its own
# open/stat/symlink calls are rewritten to the IEC fs shim. A plain libtool
# libarchive.so would call the real symlink(2), which the sandbox refuses.
FS_WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
          chmod fchmod fchmodat
          open openat unlink unlinkat rename renameat access faccessat realpath
          link linkat opendir readdir scandir fopen freopen utimensat syscall)
FS_WRAP_FLAGS=()
for name in "${FS_WRAPS[@]}"; do
	FS_WRAP_FLAGS+=("-Wl,--wrap=$name")
done

FS_SO_OBJ="$BUILD/fs_shim_so.o"
$CC_TARGET -O2 -fPIC -DINT_WARP -D_GNU_SOURCE \
	-I "$IEC_ROOT" -I "$IEC_ROOT/common" \
	-c "$IEC_ROOT/fs/shim.c" -o "$FS_SO_OBJ" \
	|| iec_err "fs shim for libarchive.so failed to compile"

if [ "$SHARED" = "1" ]; then
	mkdir -p "$HAR_LIBS"
	rm -f "$HAR_LIBS"/libarchive.so*

	SO13="$HAR_LIBS/libarchive.so.13"
	iec_log "link shimmed libarchive.so.13"
	$CC_TARGET -shared -o "$SO13" \
		-Wl,--whole-archive "$LIB" -Wl,--no-whole-archive \
		"$FS_SO_OBJ" "$IEC_DEPS_LIB/libz.a" \
		-Wl,-soname,libarchive.so.13 -Wl,-Bsymbolic-functions \
		"${FS_WRAP_FLAGS[@]}" -lpthread -lm \
		|| iec_err "libarchive.so link failed"
	ln -sf "libarchive.so.13" "$HAR_LIBS/libarchive.so"

	iec_log "shared object: $HAR_LIBS/libarchive.so"
	"$READELF" -d "$HAR_LIBS/libarchive.so" | grep -E 'NEEDED|SONAME' >&2 || true
	"$NM" -D --defined-only "$HAR_LIBS/libarchive.so" \
		| grep -E ' (T|W) archive_read_new$' >/dev/null \
		|| iec_err "archive_read_new is not exported"
	if "$READELF" -d "$HAR_LIBS/libarchive.so" | grep -q 'NEEDED.*libz'; then
		iec_err "libarchive.so depends on a shared zlib; the HAR has only static libz.a"
	fi
fi

# ── command objects: tar / unzip / cpio ───────────────────────────────────
#
# The upstream front ends are compiled into shared objects and linked with the
# same fs/tty/exec shims as every other IEC command. That is what makes
# libarchive's internal symlink() calls produce .IEC_SYMLINK markers: the link
# rewrites them to fs/shim.c's __wrap_symlink.
if [ "$CLI" = "1" ]; then
	SHIM_BUILD="$BUILD/shims"
	mkdir -p "$SHIM_BUILD" "$HAR_LIBS"

	iec_log "build command shims for libarchive front ends"
	SHIM_CFLAGS=(-O2 -fPIC -DINT_WARP -D_GNU_SOURCE
		-I "$IEC_ROOT" -I "$IEC_ROOT/common")
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/tty/shim.c" -o "$SHIM_BUILD/tty.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -DIEC_SHIM_MERGED_OPEN \
		-c "$IEC_ROOT/fs/shim.c" -o "$SHIM_BUILD/fs.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/exec/shim.c" -o "$SHIM_BUILD/exec.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/rpc.c" -o "$SHIM_BUILD/rpc.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/sock_client.c" -o "$SHIM_BUILD/sock_client.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/compat/exit_wrap.c" -o "$SHIM_BUILD/exit_wrap.o"

	WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
	       chmod fchmod fchmodat
	       open openat unlink unlinkat rename renameat access faccessat realpath
	       link linkat opendir readdir scandir fopen freopen utimensat syscall
	       close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
	       tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
	       openpty login_tty forkpty
	       execve execv execvp execvpe execl execlp execle
	       exit)
	WRAP_FLAGS=()
	for name in "${WRAPS[@]}"; do
		WRAP_FLAGS+=("-Wl,--wrap=$name")
	done

	FRONT_CFLAGS=(-O2 -fPIC -DHAVE_CONFIG_H -DLIBARCHIVE_STATIC -D_GNU_SOURCE
		-I "$SRC" -I "$BUILD" -I "$SRC/libarchive" -I "$SRC/libarchive_fe"
		-I "$IEC_DEPS_INC")

	build_frontend() {
		local fname="$1" main_rel="$2" out_name="$3"
		shift 3
		local dir="$BUILD/$fname"
		local out="$HAR_LIBS/$out_name"
		local objs=()
		local rel obj

		mkdir -p "$dir"
		for rel in "$@"; do
			obj="$dir/$(printf '%s' "$rel" | tr '/' '_').o"
			local extra=()
			[ "$rel" = "$main_rel" ] && extra=("-Dmain=iec_${fname}_main")
			$CC_TARGET "${FRONT_CFLAGS[@]}" "${extra[@]}" \
				-c "$SRC/$rel" -o "$obj" \
				|| iec_err "$fname: compile $rel failed"
			objs+=("$obj")
		done

		iec_log "link $out"
		$CC_TARGET -shared -o "$out" "${objs[@]}" \
			"$IEC_DEPS_LIB/libarchive.a" "$IEC_DEPS_LIB/libz.a" \
			"$SHIM_BUILD"/*.o \
			-Wl,-soname,"$out_name" -Wl,-Bsymbolic-functions \
			"${WRAP_FLAGS[@]}" -lpthread -ldl -lm \
			|| iec_err "$fname: link failed"

		"$NM" -D --defined-only "$out" | grep " iec_${fname}_main$" >/dev/null \
			|| iec_err "$fname: entry iec_${fname}_main is not exported"
		if "$NM" -D -u "$out" | grep -E ' U (__wrap_|__real_)[A-Za-z0-9_]+$' >/dev/null; then
			iec_err "$fname: unresolved __wrap_/__real_ symbols"
		fi
		"$READELF" -d "$out" | grep -E 'NEEDED|SONAME' >&2 || true
		iec_log "done: $out ($(du -h "$out" | cut -f1))"
	}

	build_frontend bsdtar tar/bsdtar.c libbsdtar.so \
		tar/bsdtar.c tar/cmdline.c tar/creation_set.c tar/read.c \
		tar/subst.c tar/util.c tar/write.c \
		libarchive_fe/err.c libarchive_fe/line_reader.c \
		libarchive_fe/passphrase.c

	build_frontend bsdunzip unzip/bsdunzip.c libbsdunzip.so \
		unzip/bsdunzip.c unzip/cmdline.c unzip/la_getline.c \
		libarchive_fe/err.c libarchive_fe/passphrase.c

	build_frontend bsdcpio cpio/cpio.c libbsdcpio.so \
		cpio/cpio.c cpio/cmdline.c \
		libarchive_fe/err.c libarchive_fe/line_reader.c \
		libarchive_fe/passphrase.c

	# A small `zip` front end. libarchive has no upstream zip-style CLI; this
	# covers the common create/list use (-r, -q, -0, -j).
	iec_log "build zip command"
	ZIP_ENTRY="$BUILD/zip_entry.o"
	OUT_ZIP="$HAR_LIBS/libzipcmd.so"
	$CC_TARGET "${FRONT_CFLAGS[@]}" -Dmain=iec_zip_main \
		-c "$IEC_ROOT/scripts/libarchive-ohos/zip_entry.c" -o "$ZIP_ENTRY" \
		|| iec_err "zip: compile failed"
	$CC_TARGET -shared -o "$OUT_ZIP" "$ZIP_ENTRY" \
		"$IEC_DEPS_LIB/libarchive.a" "$IEC_DEPS_LIB/libz.a" \
		"$SHIM_BUILD"/*.o \
		-Wl,-soname,libzipcmd.so -Wl,-Bsymbolic-functions \
		"${WRAP_FLAGS[@]}" -lpthread -ldl -lm \
		|| iec_err "zip: link failed"
	"$NM" -D --defined-only "$OUT_ZIP" | grep ' iec_zip_main$' >/dev/null \
		|| iec_err "zip: entry iec_zip_main is not exported"
	if "$NM" -D -u "$OUT_ZIP" | grep -E ' U (__wrap_|__real_)[A-Za-z0-9_]+$' >/dev/null; then
		iec_err "zip: unresolved __wrap_/__real_ symbols"
	fi
	"$READELF" -d "$OUT_ZIP" | grep -E 'NEEDED|SONAME' >&2 || true
	iec_log "done: $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
fi

iec_log "libarchive ready: $LIB"
iec_log "headers: $IEC_DEPS_INC/archive.h"
iec_log "link with: -L$IEC_DEPS_LIB -larchive -lz"
