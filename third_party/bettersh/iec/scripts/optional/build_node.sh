#!/bin/bash
# build_node.sh — build Node.js as an IEC command object (libnode.so).
#
# The result has the same shape as the other IEC command objects: one shared
# object, one C entry point, and the IEC fs/tty/exec shims linked in. It is
# started by the exec service with dlopen(), not by execve().
#
# Version: v22.19.0. That is the lower bound declared by the current agent
# tooling (kimi-code and @deepseek-harness-tui/dsh-tui require >=22.19), and
# it still builds with the OHOS SDK's clang. Node 24 needs C++20 features the
# SDK compiler does not implement.
#
# What it does:
#   1. download and verify the source tarball;
#   2. configure with the OHOS toolchain (shared library, full ICU, no npm
#      bundled into the binary);
#   3. build the `libnode` ninja target;
#   4. re-link the result with:
#        - the entry wrapper (iec_node_main / iec_npm_main / iec_npx_main),
#        - the IEC fs/tty/exec shims,
#        - exit() and uname() wrappers,
#        - the in-memory dlopen fallback (loader/elf_dl.cpp + loader/wrap.c),
#   5. pack deps/npm as <resource-dir>/npm.tar.
#
# Usage:
#   scripts/optional/build_node.sh [src|configure|build|all]
#
# Environment:
#   IEC_NODE_BUILD   build/log tree (default: $IEC_ROOT/build/node)
#   IEC_NODE_SRC     source tree (default: <source cache>/node-$NODE_VER)
#   IEC_SOURCE_CACHE source/tarball cache (default: $IEC_ROOT/thirdparty)
#   OUTDIR           output directory (default: IEC HAR libs/arm64-v8a)
#   RESDIR           rawfile directory (default: IEC HAR rawfile/tools)
#   IEC_MUSL_TOOLCHAIN  optional GNU musl toolchain providing libatomic.a
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libnode.so
#   platform/ohos/har/src/main/resources/rawfile/tools/npm.tar
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

PHASE="${1:-all}"
NODE_VER="v22.19.0"
NODE_SHA256="4cea680423f98abc6a2a5ca127fb34c5f6586c24217f57749be6ea886c9be9a6"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}.tar.gz"

SOURCE_CACHE="${IEC_SOURCE_CACHE:-$IEC_ROOT/thirdparty}"
BUILD="${IEC_NODE_BUILD:-$IEC_ROOT/build/node}"
SRC_TGZ="${IEC_NODE_TARBALL:-$SOURCE_CACHE/node-${NODE_VER}.tar.gz}"
SRC="${IEC_NODE_SRC:-$SOURCE_CACHE/node-${NODE_VER}}"
WRAPPERS="$BUILD/wrappers"
PATCH_DIR="$IEC_ROOT/scripts/optional/node-ohos/patches"
ENTRY_SRC="$IEC_ROOT/scripts/optional/node-ohos/iec_node_entry.cc"
OUTDIR="${OUTDIR:-$IEC_ROOT/platform/ohos/har/libs/arm64-v8a}"
OUT="$OUTDIR/libnode.so"
RESDIR="${RESDIR:-$IEC_ROOT/platform/ohos/har/src/main/resources/rawfile/tools}"

CLANGXX="${CLANGXX:-$CLANG_DIR/clang++}"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT"
CXX_TARGET="$CLANGXX --target=$TARGET --sysroot=$SYSROOT"
AR="${AR:-$CLANG_DIR/llvm-ar}"
RANLIB="${RANLIB:-$CLANG_DIR/llvm-ranlib}"
NM="${NM:-$CLANG_DIR/llvm-nm}"
READELF="${READELF:-$CLANG_DIR/llvm-readelf}"
OBJCOPY="${OBJCOPY:-$CLANG_DIR/llvm-objcopy}"
SDK_NINJA="$OHOS_SDK/native/build-tools/cmake/bin/ninja"

mkdir -p "$BUILD" "$WRAPPERS" "$OUTDIR" "$RESDIR"

# ── cross-link extras ──────────────────────────────────────────────────────
# node.gyp adds -latomic on linux/aarch64 when llvm_version is set, while the
# OHOS sysroot has no libatomic. Borrow a static one from a GNU musl toolchain
# if available; do not add the whole musl lib directory to the search path
# (that could shadow the OHOS libc).
EXTRA_LIB_DIR="$BUILD/extra-libs"
mkdir -p "$EXTRA_LIB_DIR"
if [ ! -f "$EXTRA_LIB_DIR/libatomic.a" ]; then
	MUSL_TC="${IEC_MUSL_TOOLCHAIN:-${MUSL_TOOLCHAIN:-}}"
	cand_atomic=""
	for cand in \
		"$MUSL_TC/aarch64-linux-musl/lib/libatomic.a" \
		"$PARENT/build/node/extra-libs/libatomic.a" \
		/usr/lib/gcc-cross/aarch64-linux-gnu/*/libatomic.a; do
		[ -f "$cand" ] && { cand_atomic="$cand"; break; }
	done
	if [ -n "$cand_atomic" ]; then
		cp -f "$cand_atomic" "$EXTRA_LIB_DIR/"
		iec_log "libatomic.a <- $cand_atomic"
	else
		iec_log "warning: libatomic.a not found; the final link may fail with -latomic"
	fi
fi

command -v python3 >/dev/null 2>&1 || iec_err "python3 is required by node's build"
[ -x "$SDK_NINJA" ] || iec_err "ninja not found: $SDK_NINJA"
[ -f "$ENTRY_SRC" ] || iec_err "entry source not found: $ENTRY_SRC"

# ── toolchain wrappers ─────────────────────────────────────────────────────
# node's configure treats CC/CXX as commands but also builds cc_host/cxx_host.
# A wrapper supplies the target triple and sysroot while keeping the command
# a single executable path.
make_wrappers() {
	cat > "$WRAPPERS/cc" <<EOF
#!/bin/sh
exec "$CLANG_DIR/clang" --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld -L"$EXTRA_LIB_DIR" "\$@"
EOF
	cat > "$WRAPPERS/cxx" <<EOF
#!/bin/sh
exec "$CLANG_DIR/clang++" --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld -L"$EXTRA_LIB_DIR" "\$@"
EOF
	cat > "$WRAPPERS/ar" <<EOF
#!/bin/sh
exec "$CLANG_DIR/llvm-ar" "\$@"
EOF
	cat > "$WRAPPERS/ranlib" <<EOF
#!/bin/sh
exec "$CLANG_DIR/llvm-ranlib" "\$@"
EOF
	cat > "$WRAPPERS/strip" <<EOF
#!/bin/sh
exec "$CLANG_DIR/llvm-strip" "\$@"
EOF
	cat > "$WRAPPERS/nm" <<EOF
#!/bin/sh
exec "$CLANG_DIR/llvm-nm" "\$@"
EOF
	cat > "$WRAPPERS/objcopy" <<EOF
#!/bin/sh
exec "$CLANG_DIR/llvm-objcopy" "\$@"
EOF
	chmod +x "$WRAPPERS"/*
}

make_wrappers

# ── 1. source ──────────────────────────────────────────────────────────────
fetch_src() {
	if [ ! -f "$SRC_TGZ" ] || ! echo "$NODE_SHA256  $SRC_TGZ" | sha256sum -c - >/dev/null 2>&1; then
		iec_log "download node $NODE_VER (about 85 MB, resumed on interruption)"
		mkdir -p "$(dirname "$SRC_TGZ")"
		local n=0
		while :; do
			n=$((n + 1))
			if curl -L -C - --connect-timeout 20 --max-time 2400 -sS "$NODE_URL" -o "$SRC_TGZ"; then
				break
			fi
			[ "$n" -ge 8 ] && iec_err "download failed after $n attempts (delete $SRC_TGZ)"
			iec_log "download interrupted; resuming ($n)"
			sleep 3
		done
		echo "$NODE_SHA256  $SRC_TGZ" | sha256sum -c - || iec_err "sha256 mismatch: $SRC_TGZ"
	fi
	if [ ! -f "$SRC/src/node.cc" ]; then
		iec_log "extract -> $SRC"
		mkdir -p "$SOURCE_CACHE"
		tar -xzf "$SRC_TGZ" -C "$SOURCE_CACHE"
	fi
	[ -f "$SRC/src/node.cc" ] || iec_err "incomplete source tree: $SRC"
	make_wrappers
}

# ── 2. configure ───────────────────────────────────────────────────────────
do_configure() {
	fetch_src
	cd "$SRC" || iec_err "cd $SRC failed"

	if [ -d "$PATCH_DIR" ] && compgen -G "$PATCH_DIR/*.patch" >/dev/null; then
		for p in "$PATCH_DIR"/*.patch; do
			if patch -p1 --dry-run -s -i "$p" >/dev/null 2>&1; then
				patch -p1 -i "$p" >> "$BUILD/patch.log" 2>&1 \
					|| iec_err "patch failed: $(basename "$p")"
				iec_log "applied $(basename "$p")"
			else
				iec_log "skipped $(basename "$p") (already applied or not applicable)"
			fi
		done
	fi

	iec_log "configure node $NODE_VER (target=$TARGET)"
	# --shared       produce libnode.so, not an executable
	# --with-intl=full-icu
	#                V8's Unicode property escapes and Intl.Segmenter need the
	#                full data; small-icu crashes on Intl.Segmenter.
	# --cross-compiling
	#                makes gyp build host tools with the host compiler.
	# CC_host/... are mandatory: without them gyp falls back to CC, producing
	# an aarch64 host tool that cannot run on the build machine.
	CC="$WRAPPERS/cc" CXX="$WRAPPERS/cxx" \
	AR="$WRAPPERS/ar" RANLIB="$WRAPPERS/ranlib" \
	CC_host="${HOST_CC:-$CLANG_DIR/clang}" \
	CXX_host="${HOST_CXX:-$CLANG_DIR/clang++}" \
	AR_host="${HOST_AR:-$CLANG_DIR/llvm-ar}" \
	NM_host="${HOST_NM:-$CLANG_DIR/llvm-nm}" \
	READELF_host="${HOST_READELF:-$CLANG_DIR/llvm-readelf}" \
		./configure \
			--prefix="$BUILD/install" \
			--dest-cpu=arm64 --dest-os=linux --cross-compiling \
			--shared --ninja \
			--with-intl=full-icu --openssl-no-asm \
			--without-npm \
			> "$BUILD/configure.log" 2>&1 \
		|| { tail -30 "$BUILD/configure.log" >&2; iec_err "configure failed"; }
	grep -E "^(INFO|WARNING)" "$BUILD/configure.log" | tail -8 >&2 || true
	iec_log "configure complete"
}

# ── 3. build and re-link ───────────────────────────────────────────────────
do_build() {
	[ -f "$SRC/config.gypi" ] || do_configure
	cd "$SRC" || iec_err "cd $SRC failed"

	[ -f "$SRC/out/Release/build.ninja" ] \
		|| iec_err "missing $SRC/out/Release/build.ninja; run the configure phase"

	iec_log "remove duplicate host/target rules"
	python3 "$IEC_ROOT/scripts/optional/ninja_dedup.py" "$SRC/out/Release" >&2

	iec_log "build libnode (-j$JOBS)"
	"$SDK_NINJA" -C out/Release libnode -j"$JOBS" > "$BUILD/make.log" 2>&1 \
		|| { tail -40 "$BUILD/make.log" >&2; iec_err "build failed"; }

	local so
	so="$(ls -1 "$SRC"/out/Release/lib/libnode.so* 2>/dev/null | head -1)"
	[ -n "$so" ] || so="$(ls -1 "$SRC"/out/Release/libnode.so* 2>/dev/null | head -1)"
	[ -n "$so" ] || so="$(find "$SRC/out" -maxdepth 3 -name 'libnode.so*' 2>/dev/null | head -1)"
	[ -n "$so" ] && [ -f "$so" ] || iec_err "libnode.so was not produced"

	iec_log "build the entry wrapper and IEC shims"
	$CXX_TARGET -O2 -fPIC -c "$ENTRY_SRC" -o "$BUILD/iec_node_entry.o"

	local SHIM_CFLAGS=(-O2 -fPIC -DINT_WARP -D_GNU_SOURCE
		-I "$IEC_ROOT" -I "$IEC_ROOT/common")
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/tty/shim.c" -o "$BUILD/iec_tty_shim.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -DIEC_SHIM_MERGED_OPEN \
		-c "$IEC_ROOT/fs/shim.c" -o "$BUILD/iec_fs_shim.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/exec/shim.c" -o "$BUILD/iec_exec_shim.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/rpc.c" -o "$BUILD/iec_rpc.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/sock_client.c" -o "$BUILD/iec_sock_client.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/compat/exit_wrap.c" -o "$BUILD/iec_exit_wrap.o"
	$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/misc/uname.c" -o "$BUILD/iec_uname.o"

	iec_log "build the in-memory dlopen fallback"
	local LOADER_CXXFLAGS=(-O2 -fPIC -fno-exceptions -fno-rtti
		-fno-threadsafe-statics -I "$IEC_ROOT" -I "$IEC_ROOT/loader")
	$CXX_TARGET "${LOADER_CXXFLAGS[@]}" -c "$IEC_ROOT/loader/elf_dl.cpp" -o "$BUILD/iec_elf_dl.o"
	$CXX_TARGET "${LOADER_CXXFLAGS[@]}" -c "$IEC_ROOT/loader/loader.cpp" -o "$BUILD/iec_loader.o"
	$CC_TARGET -c "$IEC_ROOT/loader/guest_switch_aarch64.S" -o "$BUILD/iec_guest_switch.o"
	$CC_TARGET -c "$IEC_ROOT/loader/tlsdesc.S" -o "$BUILD/iec_tlsdesc.o"
	$CC_TARGET -O2 -fPIC -I "$IEC_ROOT/loader" -I "$IEC_ROOT" \
		-c "$IEC_ROOT/loader/wrap.c" -o "$BUILD/iec_dlopen_wrap.o"

	local WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
		chmod fchmod fchmodat
		open openat unlink unlinkat rename renameat access faccessat realpath
		link linkat opendir readdir scandir fopen freopen syscall
		close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
		tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
		openpty login_tty forkpty
		execve execv execvp execvpe execl execlp execle
		exit)
	local WRAP_FLAGS=()
	for name in "${WRAPS[@]}"; do
		WRAP_FLAGS+=("-Wl,--wrap=$name")
	done

	local REL_SO
	REL_SO="$(cd "$SRC/out/Release" && ls -1 lib/libnode.so.* 2>/dev/null \
		| grep -v '\.rsp$' | grep -v '\.TOC$' | head -1)"
	[ -n "$REL_SO" ] || iec_err "out/Release/lib has no libnode.so.*"

	local LINK_CMD
	LINK_CMD="$(python3 "$IEC_ROOT/scripts/optional/node_relink.py" \
		"$SRC/out/Release" "$REL_SO" "$OUT" "$WRAPPERS/cxx")" \
		|| iec_err "could not recover the libnode link command"

	iec_log "re-link $OUT"
	( cd "$SRC/out/Release" && eval "$LINK_CMD \
		\"$BUILD/iec_node_entry.o\" \
		\"$BUILD/iec_tty_shim.o\" \"$BUILD/iec_fs_shim.o\" \
		\"$BUILD/iec_exec_shim.o\" \"$BUILD/iec_rpc.o\" \"$BUILD/iec_sock_client.o\" \
		\"$BUILD/iec_exit_wrap.o\" \"$BUILD/iec_uname.o\" \
		\"$BUILD/iec_elf_dl.o\" \"$BUILD/iec_loader.o\" \
		\"$BUILD/iec_guest_switch.o\" \"$BUILD/iec_tlsdesc.o\" \"$BUILD/iec_dlopen_wrap.o\" \
		-Wl,--wrap=uname \
		-Wl,--wrap=dlopen -Wl,--wrap=dlsym -Wl,--wrap=dlclose \
		${WRAP_FLAGS[*]}" ) \
		|| iec_err "re-link failed"

	[ -f "$OUT" ] || iec_err "no output at $OUT"
	"$NM" -D --defined-only "$OUT" | grep ' iec_node_main$' >/dev/null \
		|| iec_err "iec_node_main is not exported"
	if "$NM" -D -u "$OUT" | grep -E ' U (__wrap_|__real_)[A-Za-z0-9_]+$' >/dev/null; then
		iec_err "unresolved __wrap_/__real_ symbols"
	fi
	"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME' >&2 || true
	iec_log "done: $OUT ($(du -h "$OUT" | cut -f1))"

	# ── npm: pure JavaScript, packed as a rawfile tar ─────────────────────
	local npm_src="$SRC/deps/npm"
	[ -f "$npm_src/bin/npm-cli.js" ] || iec_err "missing npm source: $npm_src"
	iec_log "pack npm.tar"
	( cd "$SRC/deps" && tar --format=ustar \
		--exclude='npm/docs' --exclude='npm/man' --exclude='npm/tap-snapshots' \
		-cf "$RESDIR/npm.tar" npm ) || iec_err "could not pack npm.tar"
	iec_log "done: $RESDIR/npm.tar ($(du -h "$RESDIR/npm.tar" | cut -f1))"
}

case "$PHASE" in
	src)       fetch_src ;;
	configure) do_configure ;;
	build)     do_build ;;
	all)       do_configure; do_build ;;
	*)         iec_err "usage: $0 [src|configure|build|all]" ;;
esac
iec_log "build_node.sh complete (phase $PHASE)"
