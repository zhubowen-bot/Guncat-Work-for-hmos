#!/bin/bash
# scripts/build_qemu.sh — build qemu-user as the shared objects the kQemu routes load.
#
# Usage:
#   scripts/build_qemu.sh [deps|so|all]
#
# Why this shape (the same job, and the same tricks, as BetterSH's build_qemu.sh):
#
#   * qemu-user comes out as a .so with an entry symbol rather than as a program. A host
#     where execve is not how programs start can still dlopen one and call it, which is
#     the door the kSo route already uses; see exec/exec_qemu.cpp for the call.
#   * The entry is qemu_entry(argc, argv), installed by renaming qemu's own linux-user
#     main to qemu_main3 and wrapping it, because a .so cannot have a main of its own and
#     linux-user does read the environment.
#   * IEC's exec shim is linked into the object, so a program the guest starts goes to
#     the exec service like any other. This is not optional decoration: qemu's usual way
#     of implementing a guest execve is to execute itself again, and there is no qemu
#     program here to execute.
#   * --enable-tcg-interpreter turns the TCG backend into a C interpreter loop, so no
#     writable-executable memory is ever asked for. It is much slower, and it is the only
#     execution path left on a host where the JIT capability probe comes back zero.
#
# Two targets, because the server is built two ways:
#
#   TARGET_OS=host   (default) x86_64 Linux, the host's glib, no patches. This is what
#                    the server built by the Makefile can load today, so the route can be
#                    brought up without a device.
#   TARGET_OS=ohos   aarch64 OHOS: the cross compiler from the SDK, pcre2 and glib built
#                    here, the qemu-ohos patch set applied in order, glib and intl
#                    bundled next to the objects. This is the device.
#
# Environment (everything overridable):
#   TARGET_OS=host|ohos         default host
#   QEMU_GUESTS=<target-list>   default aarch64-linux-user,x86_64-linux-user
#   TCI=1|0                     default 1 for ohos, 0 for host -- see above
#   QEMU_SRC, GLIB_SRC, PCRE2_SRC, QEMU_PATCH_DIR
#                               default to the copies BetterSH vendors (qemu 10.1.5 and
#                               its patch set); point them at IEC's own once they exist.
#   QEMU_OUT_DIR                where the objects are written (default dist/qemu).
#   QEMU_HAR_LIBS               also copy them (with glib/intl/libffi) into this
#                               libs/arm64-v8a directory, which is what the packaging
#                               step needs on device. Empty by default.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
log()  { echo "=== $* ===" >&2; }
warn() { echo "!!! $*" >&2; }
err()  { echo "ERROR: $*" >&2; exit 1; }

TARGET_OS="${TARGET_OS:-host}"
QEMU_GUESTS="${QEMU_GUESTS:-aarch64-linux-user,x86_64-linux-user}"
JOBS="${JOBS:-$(nproc)}"
BUILD="$ROOT/build/qemu"
OUT="${QEMU_OUT_DIR:-$ROOT/dist/qemu}"
HAR_LIBS="${QEMU_HAR_LIBS:-}"
DEPS_PREFIX="$BUILD/deps"

BETSH="${BETSH:-/workspace/dev/BetterSH}"
QEMU_SRC="${QEMU_SRC:-$BETSH/thirdparty/qemu}"
GLIB_SRC="${GLIB_SRC:-$BETSH/thirdparty/glib}"
PCRE2_SRC="${PCRE2_SRC:-$BETSH/thirdparty/pcre2}"
QEMU_PATCH_DIR="${QEMU_PATCH_DIR:-$BETSH/scripts/qemu-ohos-patches}"

# The guest arches have to be the ones the server knows how to name: ResolveKind() in
# exec_server.cpp matches on e_machine, and the object it loads is libqemu-<guest>.so.
GUEST_ARCHES=""
for g in ${QEMU_GUESTS//,/ }; do
	GUEST_ARCHES="$GUEST_ARCHES ${g%-linux-user}"
done

if [ "$TARGET_OS" = "ohos" ]; then
	TCI="${TCI:-1}"
	OHOS_SDK="${OHOS_SDK:-/apps/harmony/sdk/default/openharmony}"
	CROSS_CC="$OHOS_SDK/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
	CROSS_CXX="$OHOS_SDK/native/llvm/bin/aarch64-unknown-linux-ohos-clang++"
	CROSS_AR="$OHOS_SDK/native/llvm/bin/llvm-ar"
	CROSS_STRIP="$OHOS_SDK/native/llvm/bin/llvm-strip"
	CROSS_RANLIB="$OHOS_SDK/native/llvm/bin/llvm-ranlib"
	CROSS_OBJCOPY="$OHOS_SDK/native/llvm/bin/llvm-objcopy"
	CROSS_TARGET="aarch64-linux-ohos"
	[ -x "$CROSS_CC" ] || err "cross compiler not found: $CROSS_CC (set OHOS_SDK=)"
	export PKG_CONFIG="pkg-config"
	export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig"
	export AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" STRIP="$CROSS_STRIP"
else
	TCI="${TCI:-0}"
	CROSS_TARGET=""
fi

[ "$TARGET_OS" = "host" ] || [ "$TARGET_OS" = "ohos" ] || err "TARGET_OS must be host or ohos"
[ -d "$QEMU_SRC" ] || err "qemu source not found: $QEMU_SRC (set QEMU_SRC=)"
mkdir -p "$BUILD" "$OUT"

# ---------------------------------------------------------------- dependencies
#
# Only the OHOS target needs them: qemu wants glib, glib wants pcre2, and the target
# sysroot has neither. Both are installed straight into $DEPS_PREFIX with an absolute
# prefix, which is what a cross build has to do to keep pkg-config honest.
build_deps() {
	if [ "$TARGET_OS" = "host" ]; then
		log "host target: pcre2 and glib come from the system, nothing to build"
		return
	fi
	[ -d "$PCRE2_SRC" ] || err "pcre2 source not found: $PCRE2_SRC"
	[ -d "$GLIB_SRC" ] || err "glib source not found: $GLIB_SRC"
	command -v meson >/dev/null || err "meson not found (glib builds with it)"

	if [ ! -f "$DEPS_PREFIX/lib/libpcre2-8.a" ]; then
		log "building pcre2 (its own JIT stays off: a no-JIT host cannot use it)"
		rm -rf "$BUILD/pcre2"
		cmake -G Ninja -S "$PCRE2_SRC" -B "$BUILD/pcre2" \
			-DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake" \
			-DOHOS_ARCH=arm64-v8a \
			-DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
			-DCMAKE_BUILD_TYPE=Release \
			-DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
			-DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_32=OFF \
			-DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF \
			-DPCRE2_SUPPORT_JIT=OFF \
			> "$BUILD/pcre2-configure.log" 2>&1 \
			|| { tail -25 "$BUILD/pcre2-configure.log" >&2; err "pcre2 configure failed"; }
		ninja -C "$BUILD/pcre2" install > "$BUILD/pcre2-install.log" 2>&1 \
			|| { tail -25 "$BUILD/pcre2-install.log" >&2; err "pcre2 build failed"; }
	fi

	if [ ! -f "$DEPS_PREFIX/lib/libglib-2.0.so" ]; then
		log "building glib (the pieces qemu does not need are switched off)"
		rm -rf "$BUILD/glib"
		cat > "$BUILD/glib-cross.txt" <<EOF
[binaries]
c = '$CROSS_CC'
cpp = '$CROSS_CXX'
ar = '$CROSS_AR'
strip = '$CROSS_STRIP'
pkgconfig = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
		meson setup "$BUILD/glib" "$GLIB_SRC" --cross-file "$BUILD/glib-cross.txt" \
			--prefix="$DEPS_PREFIX" --default-library=both \
			-Dselinux=disabled -Dinstalled_tests=false -Ddtrace=disabled \
			-Dsystemtap=disabled -Dlibelf=disabled -Dlibmount=disabled \
			-Dsysprof=disabled -Dman-pages=disabled -Dtests=false \
			> "$BUILD/glib-configure.log" 2>&1 \
			|| { tail -30 "$BUILD/glib-configure.log" >&2; err "glib configure failed"; }
		ninja -C "$BUILD/glib" install > "$BUILD/glib-install.log" 2>&1 \
			|| { tail -30 "$BUILD/glib-install.log" >&2; err "glib build failed"; }
	fi
	log "dependency prefix: $DEPS_PREFIX"
}

# ------------------------------------------------------------------- qemu itself
#
# qemu is built twice over: once as it wants to be, which is how the objects and the real
# link command are obtained, and then re-linked by hand as a shared object with the entry
# wrapper and the shim added. Rewriting the link command ninja would have used is the
# part that keeps this from having to know qemu's object list.
build_qemu_so() {
	local src="$BUILD/so-src"
	log "copying $QEMU_SRC to $src"
	rm -rf "$src"
	mkdir -p "$src"
	( cd "$QEMU_SRC" && tar -cf - --exclude=.git . ) | ( cd "$src" && tar -xf - )

	if [ "$TARGET_OS" = "ohos" ]; then
		[ -d "$QEMU_PATCH_DIR" ] || err "patch directory not found: $QEMU_PATCH_DIR"
		log "applying the qemu-ohos patch set (in order: they depend on each other)"
		for p in "$QEMU_PATCH_DIR"/[0-9][0-9][0-9][0-9]-*.patch; do
			patch -p1 -d "$src" -i "$p" >> "$BUILD/patch.log" 2>&1 \
				|| { tail -20 "$BUILD/patch.log" >&2; err "patch failed: $(basename "$p")"; }
		done
	else
		# The set is a port to OHOS and cannot be split (its own README says the first
		# nine depend on each other), so a host build gets none of it. What that costs
		# is worth knowing: patch 0010 is what makes a guest execve call libc execve,
		# so here a guest's exec goes through qemu's raw syscall and the shim linked
		# below never sees it. Everything else about the object works the same.
		warn "host target: no patches, so a guest's execve bypasses the shim"
	fi

	local configure_args=(
		"--target-list=$QEMU_GUESTS"
		--disable-system --disable-tools --disable-docs
		--without-default-features
		--disable-libusb --disable-seccomp --disable-debug-info
		-Db_staticpic=true
	)
	[ "$TCI" = "1" ] && configure_args+=(--enable-tcg-interpreter)
	if [ "$TARGET_OS" = "ohos" ]; then
		configure_args+=(--cc="$CROSS_CC" --cxx="$CROSS_CXX" --cross-prefix= --host-cc=cc)
		# The OHOS sysroot carries a partial set of Linux headers and qemu includes
		# several of them. These are the same workarounds upstream's OHOS build passes:
		# the headers that collide are named so their real versions are not reached, and
		# the kernel's __user/__force annotations are emptied.
		configure_args+=(--extra-cflags="-O2 -fPIC -D_UAPI_LINUX_VIRTIO_VSOCK_H -D_UAPI_LINUX_VIRTIO_TYPES_H -D_UAPI_LINUX_VIRTIO_RING_H -D_UAPI_LINUX_VIRTIO_PMEM_H -D_UAPI_LINUX_VIRTIO_NET_H -D_UAPI_LINUX_VIRTIO_IOMMU_H -D_UAPI_LINUX_VIRTIO_FS_H -D_UAPI_LINUX_VIRTIO_CONSOLE_H -D_UAPI_LINUX_VIRTIO_CONFIG_H -D_LINUX_SYSINFO_H -D__user= -D__force=")
	fi

	log "configure (TCI=$TCI, guests=$QEMU_GUESTS)"
	( cd "$src" && ./configure "${configure_args[@]}" > "$BUILD/so-configure.log" 2>&1 ) \
		|| { tail -35 "$BUILD/so-configure.log" >&2; err "configure failed"; }

	log "building qemu-<guest> (for the objects and the real link line)"
	local targets=""
	for a in $GUEST_ARCHES; do targets="$targets qemu-$a"; done
	( cd "$src" && make -j"$JOBS" $targets > "$BUILD/so-make.log" 2>&1 ) \
		|| { tail -40 "$BUILD/so-make.log" >&2; err "build failed"; }

	# qemu's linux-user main takes (argc, argv, envp) and a .so has no main, so it is
	# renamed and wrapped. The entry the server calls is the two-argument one, and its
	# name comes out of common/constant.h: the server dlsym()s that same name, so the two
	# have to come from one place -- a mismatch would be silent until something was
	# started with it.
	local entry_name
	entry_name=$(sed -n 's/^#define[[:space:]][[:space:]]*QEMU_ENTRY[[:space:]][[:space:]]*"\([^"]*\)".*/\1/p' \
		"$ROOT/common/constant.h")
	[ -n "$entry_name" ] || err "QEMU_ENTRY not found in common/constant.h"
	local wrap_c="$BUILD/${entry_name}_wrapper.c"
	cat > "$wrap_c" <<EOF
/* The entry the server calls is int (*)(int, char **), which is what main looks like
 * without its third argument. linux-user does read the environment, so it is put back
 * here rather than left to chance. The name below is $entry_name, taken from
 * common/constant.h by the script that generated this file. */
extern char **environ;
extern int qemu_main3(int argc, char **argv, char **envp);
int $entry_name(int argc, char **argv) {
	return qemu_main3(argc, argv, environ);
}
EOF
	local WRAP_OBJ="$BUILD/qemu_entry_wrapper.o"
	( cd "$src" && "${CROSS_CC:-cc}" -O2 -fPIC -c "$wrap_c" -o "$WRAP_OBJ" )

	# IEC's exec shim, built by the Makefile as WARP objects so that every hook is a
	# __wrap_* symbol -- which is what --wrap wants. Only the exec half is linked: the
	# tty shim interposes open/close/dup, and interposing those is not something qemu's
	# own syscall traffic should have to survive.
	#
	# The wrap list has to stay in step with SHIM_WRAPS in the Makefile; a call left out
	# here is a call in the guest that never reaches the service.
	log "building the exec shim objects"
	# A separate BUILD directory, and the target compiler: the Makefile's own
	# objects are host objects, and linking those into an aarch64 .so fails.
	local shim_build="$BUILD/shim"
	local shim_cc="${CROSS_CC:-cc}"
	( cd "$ROOT" && make MODE=warp BUILD="$shim_build" CC="$shim_cc" \
		"$shim_build/exec_shim.o" "$shim_build/sock_client.o" "$shim_build/rpc.o" \
		> "$BUILD/shim.log" 2>&1 ) \
		|| { tail -20 "$BUILD/shim.log" >&2; err "shim objects failed to build"; }
	local SHIM_OBJS="$shim_build/exec_shim.o $shim_build/sock_client.o $shim_build/rpc.o"
	local EXEC_WRAP=""
	for s in execve execv execvp execvpe execl execlp execle; do
		EXEC_WRAP="$EXEC_WRAP -Wl,--wrap=$s"
	done

	for a in $GUEST_ARCHES; do
		local mainobj="libqemu-$a-linux-user.a.p/linux-user_main.c.o"
		[ -f "$src/build/$mainobj" ] || err "entry object not where it was expected: $mainobj"
		local renamed="$BUILD/qemu_${a}_main.o"
		cp "$src/build/$mainobj" "$renamed"
		# The host binutils on Ubuntu is built for x86-64 only, so it cannot read
		# the guest's aarch64 object; the SDK's llvm-objcopy can.
		"${CROSS_OBJCOPY:-objcopy}" --redefine-sym main=qemu_main3 "$renamed" \
			|| err "could not rename main in $mainobj"

		# The link command ninja would have used, turned into a shared object: its own
		# output is replaced, --no-undefined/-pie/--as-needed come out (a .so is all
		# three of those things), and the main object is swapped for the renamed one
		# plus the wrapper.
		local cmd newcmd
		cmd=$(ninja -C "$src/build" -t commands "qemu-$a" | tail -1)
		[ -n "$cmd" ] || err "no link command for qemu-$a"
		newcmd=$(printf '%s' "$cmd" | sed \
			-e "s| -o qemu-$a | -shared -Wl,-soname,libqemu-$a.so -o $OUT/libqemu-$a.so |" \
			-e 's|-Wl,--no-undefined||g' -e 's| -pie ||g' -e 's|-Wl,--as-needed||g' \
			-e "s|$mainobj|$renamed $WRAP_OBJ|")
		newcmd="$newcmd $SHIM_OBJS $EXEC_WRAP"
		log "re-linking libqemu-$a.so (with the exec shim)"
		( cd "$src/build" && eval "$newcmd" ) >> "$BUILD/so-link.log" 2>&1 \
			|| { tail -30 "$BUILD/so-link.log" >&2; err "re-linking libqemu-$a.so failed"; }
	done

	# What the objects need at run time: glib, intl and libffi (the TCI backend).
	# They have to sit next to the qemu objects so dlopen finds them by SONAME.
	local glib_so="" ffi_so=""
	if [ "$TARGET_OS" = "ohos" ]; then
		glib_so=$(cd "$DEPS_PREFIX/lib" && ls libglib-2.0.so.0.* 2>/dev/null | head -1 || true)
		[ -n "$glib_so" ] || err "libglib-2.0.so.0.* not found in $DEPS_PREFIX/lib"
		cp -f "$DEPS_PREFIX/lib/$glib_so" "$OUT/"
		( cd "$OUT" && ln -sf "$glib_so" libglib-2.0.so.0 )
		[ -f "$DEPS_PREFIX/lib/libintl.so.8" ] && cp -f "$DEPS_PREFIX/lib/libintl.so.8" "$OUT/" || true

		ffi_so=$(cd "$DEPS_PREFIX/lib" && ls libffi.so.7.* 2>/dev/null | head -1 || true)
		if [ -n "$ffi_so" ]; then
			cp -f "$DEPS_PREFIX/lib/$ffi_so" "$OUT/"
			( cd "$OUT" && ln -sf "$ffi_so" libffi.so.7 )
		fi
	fi

	# The HAP does not see dist/qemu: the bundle's libs/arm64 directory is the
	# runtime search path on device. QEMU_HAR_LIBS points this step at it.
	if [ -n "$HAR_LIBS" ]; then
		log "copying runtime objects to $HAR_LIBS"
		mkdir -p "$HAR_LIBS"
		cp -f "$OUT"/libqemu-*.so "$HAR_LIBS"/
		if [ "$TARGET_OS" = "ohos" ]; then
			cp -f "$OUT/$glib_so" "$HAR_LIBS"/
			( cd "$HAR_LIBS" && ln -sf "$glib_so" libglib-2.0.so.0 )
			[ -f "$OUT/libintl.so.8" ] && cp -f "$OUT/libintl.so.8" "$HAR_LIBS"/
			if [ -n "$ffi_so" ]; then
				cp -f "$OUT/$ffi_so" "$HAR_LIBS"/
				( cd "$HAR_LIBS" && ln -sf "$ffi_so" libffi.so.7 )
			fi
		fi
	fi

	log "artifacts:"
	ls -l "$OUT"/*.so >&2
	cat >&2 <<EOF

A host build reads these from the absolute paths in common/constant.h's host defaults,
which point at this directory. On OHOS the server looks in the bundle's libs/arm64
directory instead: pass QEMU_HAR_LIBS=<har>/libs/arm64-v8a (or copy the files there
yourself) before packaging.
EOF
}

case "${1:-all}" in
	deps) build_deps ;;
	so)   build_qemu_so ;;
	all)  build_deps; build_qemu_so ;;
	*)    err "usage: $0 [deps|so|all]" ;;
esac
log "done (target $TARGET_OS, TCI=$TCI)"
