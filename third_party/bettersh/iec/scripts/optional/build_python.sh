#!/bin/bash
# build_python.sh — build CPython 3.12 as an IEC command object (libpython.so).
#
# Shape:
#   * the launchers python/python3 call Py_BytesMain in libpython.so;
#   * all extension modules are static (MODULE_BUILDTYPE=static), because a
#     command object is dlopen()ed locally and dynamic modules would not see
#     the Py* symbols;
#   * tty/shim.c makes isatty/tcgetattr/ioctl answer for the fake pty, so an
#     interactive python still enters the REPL and readline can get the size;
#   * the stdlib is packed as <resource-dir>/python-stdlib.tar (top-level
#     python/), and PYTHONHOME points at the unpacked directory at runtime;
#   * a python-headers package is produced separately for on-device extension
#     builds.
#
# Dependencies:
#   * a host python3.12 (CPython's --with-build-python requires the same
#     major.minor);
#   * ncurses source (default: $PARENT/thirdparty/ncurses, otherwise cloned);
#   * static zlib, OpenSSL and libffi;
#   * the OHOS SDK clang/sysroot from scripts/env.sh.
#
# Usage:
#   scripts/optional/build_python.sh
#
# Environment:
#   IEC_PYTHON_BUILD  build tree (default: $IEC_ROOT/build/python)
#   IEC_PYTHON_SRC    source tree (default: <source cache>/Python-$PY_VER)
#   IEC_SOURCE_CACHE  source/tarball cache (default: $IEC_ROOT/thirdparty)
#   IEC_PYTHON_PREFIX install prefix compiled into the interpreter
#                     (default: /data/storage/el2/base/files/python)
#   RESDIR            rawfile output directory
#   PYHDR_PKG         python-headers package output
#   PY_RECONFIGURE=1  discard the CPython build directory and configure again
#
# Output:
#   platform/ohos/har/libs/arm64-v8a/libpython.so
#   platform/ohos/har/src/main/resources/rawfile/tools/python-stdlib.tar
#   dist/pkgs/python-headers.tar.zst
set -euo pipefail

IEC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$IEC_ROOT/scripts/env.sh"
[ -f "$ENV_FILE" ] || ENV_FILE="$IEC_ROOT/scripts/env.sh.example"
# shellcheck disable=SC1090
source "$ENV_FILE"
# shellcheck disable=SC1091
source "$IEC_ROOT/scripts/lib/common.sh"

PY_VER="${PY_VER:-3.12.14}"
PY_SERIES="${PY_VER%.*}"
RL_VER="${RL_VER:-8.2}"
PY_URL="https://www.python.org/ftp/python/$PY_VER/Python-$PY_VER.tar.xz"
RL_URLS=(
	"https://ftp.gnu.org/gnu/readline/readline-$RL_VER.tar.gz"
	"https://mirrors.tuna.tsinghua.edu.cn/gnu/readline/readline-$RL_VER.tar.gz"
)

SOURCE_CACHE="${IEC_SOURCE_CACHE:-$IEC_ROOT/thirdparty}"
BUILD="${IEC_PYTHON_BUILD:-$IEC_ROOT/build/python}"
PY_TARBALL="${IEC_PYTHON_TARBALL:-$SOURCE_CACHE/Python-$PY_VER.tar.xz}"
PY_SRC="${IEC_PYTHON_SRC:-$SOURCE_CACHE/Python-$PY_VER}"
PY_DEPS="$BUILD/deps"
BLD="$BUILD/cpython-build"
STAGE="$BUILD/stage"
RT_ROOT="$BUILD/rt"
OUTDIR="${OUTDIR:-$IEC_ROOT/platform/ohos/har/libs/arm64-v8a}"
OUT="$OUTDIR/libpython.so"
RESDIR="${RESDIR:-$IEC_ROOT/platform/ohos/har/src/main/resources/rawfile/tools}"
RTAR="$RESDIR/python-stdlib.tar"
PYHDR_PKG="${PYHDR_PKG:-$IEC_ROOT/dist/pkgs/python-headers.tar.zst}"
PREFIX="${IEC_PYTHON_PREFIX:-/data/storage/el2/base/files/python}"

CLANGXX="${CLANGXX:-$CLANG_DIR/clang++}"
CC_TARGET="$CLANG --target=$TARGET --sysroot=$SYSROOT"
CXX_TARGET="$CLANGXX --target=$TARGET --sysroot=$SYSROOT"
AR="${AR:-$CLANG_DIR/llvm-ar}"
RANLIB="${RANLIB:-$CLANG_DIR/llvm-ranlib}"
NM="${NM:-$CLANG_DIR/llvm-nm}"
READELF="${READELF:-$CLANG_DIR/llvm-readelf}"
AT_HOST="aarch64-linux-musl"

NC_SRC="${IEC_NCURSES_SRC:-}"
if [ -z "$NC_SRC" ]; then
	if [ -f "$PARENT/thirdparty/ncurses/configure" ]; then
		NC_SRC="$PARENT/thirdparty/ncurses"
	else
		iec_clone_if_missing "$IEC_THIRDPARTY/ncurses" "https://github.com/mirror/ncurses.git"
		NC_SRC="$IEC_THIRDPARTY/ncurses"
	fi
fi
RL_SRC="$BUILD/readline-src"
RL_BUILD="$BUILD/readline"
NC_BUILD="$BUILD/ncurses"

mkdir -p "$BUILD" "$PY_DEPS" "$OUTDIR" "$RESDIR" "$(dirname "$PYHDR_PKG")"

fetch() {
	local out="$1"; shift
	[ -s "$out" ] && return 0
	local u
	for u in "$@"; do
		iec_log "download $u"
		if curl -sL --retry 2 -m 900 -o "$out" "$u"; then
			[ -s "$out" ] && return 0
		fi
	done
	iec_err "download failed: $*"
}

# ── 0. host python ─────────────────────────────────────────────────────────
HOST_PY="${HOST_PYTHON:-}"
if [ -z "$HOST_PY" ]; then
	for cand in "python$PY_SERIES" python3; do
		command -v "$cand" >/dev/null 2>&1 || continue
		v="$("$cand" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)"
		if [ "$v" = "$PY_SERIES" ]; then
			HOST_PY="$(command -v "$cand")"
			break
		fi
	done
fi
[ -n "$HOST_PY" ] || iec_err "host python$PY_SERIES is required by --with-build-python"
iec_log "host python = $HOST_PY ($("$HOST_PY" -V 2>&1))"

# ── 1. static dependencies ────────────────────────────────────────────────
[ -f "$IEC_DEPS_LIB/libz.a" ] || "$IEC_ROOT/scripts/optional/build_zlib.sh"
OPENSSL_DIR="${OPENSSL_DIR:-$IEC_OPENSSL_DIR}"
[ -f "$OPENSSL_DIR/lib/libssl.a" ] || "$IEC_ROOT/scripts/optional/build_openssl.sh"

FFI_LIB_DIR="$IEC_DEPS_LIB"
FFI_INC_DIR="$IEC_DEPS_INC"
ensure_libffi() {
	[ -f "$FFI_LIB_DIR/libffi.a" ] && return 0

	# Reuse the static libffi the parent tree already built, if present.
	local parent_ext="$PARENT/build/sysroot-ext-$NATIVE_ARCH/usr/lib/$TARGET"
	local parent_inc="$PARENT/build/sysroot-ext-$NATIVE_ARCH/usr/include"
	if [ -f "$parent_ext/libffi.a" ]; then
		mkdir -p "$FFI_LIB_DIR" "$FFI_INC_DIR"
		cp -f "$parent_ext/libffi.a" "$FFI_LIB_DIR/"
		cp -f "$parent_inc/ffi.h" "$parent_inc/ffitarget.h" "$FFI_INC_DIR/" 2>/dev/null || true
		return 0
	fi

	local src="${IEC_LIBFFI_SRC:-$PARENT/thirdparty/libffi}"
	[ -f "$src/configure" ] || src="$IEC_THIRDPARTY/libffi"
	if [ ! -f "$src/configure" ]; then
		iec_clone_if_missing "$IEC_THIRDPARTY/libffi" "https://github.com/libffi/libffi.git"
		src="$IEC_THIRDPARTY/libffi"
		( cd "$src" && ./autogen.sh >/dev/null 2>&1 ) \
			|| iec_err "libffi autogen.sh failed"
	fi
	[ -f "$src/configure" ] || iec_err "libffi source not found: $src"

	local bld="$BUILD/libffi"
	rm -rf "$bld"
	mkdir -p "$bld" "$FFI_LIB_DIR" "$FFI_INC_DIR"
	( cd "$bld" && \
		"$src/configure" --host="$AT_HOST" --build=x86_64-pc-linux-gnu \
			--prefix="$IEC_DEPS_DIR/usr" --libdir="$FFI_LIB_DIR" \
			--includedir="$FFI_INC_DIR" --enable-static --disable-shared \
			CC="$CC_TARGET" AR="$AR" RANLIB="$RANLIB" CFLAGS="-O2 -fPIC" \
			> configure.log 2>&1 ) \
		|| iec_err "libffi configure failed"
	make -C "$bld" -j"$JOBS" > "$BUILD/libffi-make.log" 2>&1 \
		|| iec_err "libffi make failed"
	make -C "$bld" install > "$BUILD/libffi-install.log" 2>&1 \
		|| iec_err "libffi install failed"
}
if ! ensure_libffi; then
	iec_err "libffi is required: $FFI_LIB_DIR/libffi.a and $FFI_INC_DIR/ffi.h"
fi
[ -f "$FFI_LIB_DIR/libffi.a" ] && [ -f "$FFI_INC_DIR/ffi.h" ] \
	|| iec_err "libffi is incomplete: $FFI_LIB_DIR/libffi.a / $FFI_INC_DIR/ffi.h"

[ -f "$NC_SRC/configure" ] || iec_err "ncurses source not found: $NC_SRC"

# ── 2. ncurses and readline (static) ──────────────────────────────────────
if [ ! -f "$PY_DEPS/lib/libncursesw.a" ]; then
	iec_log "build ncursesw -> $PY_DEPS"
	if [ ! -f "$NC_BUILD/config.status" ]; then
		mkdir -p "$NC_BUILD"
		( cd "$NC_BUILD" && PATH="/usr/bin:$PATH" CC="$CC_TARGET" AR="$AR" RANLIB="$RANLIB" \
			CFLAGS="-O2 -fPIC" CPPFLAGS="-P" "$NC_SRC/configure" \
			--host="$AT_HOST" --build=x86_64-pc-linux-gnu \
			--prefix="$PY_DEPS" --with-build-cc=/usr/bin/gcc \
			--without-shared --with-normal --without-debug \
			--without-cxx --without-cxx-binding --without-ada \
			--without-manpages --without-progs --without-tests \
			--with-panel --with-menu --with-form --enable-widec \
			--enable-pc-files --with-pkg-config-libdir="$PY_DEPS/lib/pkgconfig" \
			--with-fallbacks=xterm-256color --disable-stripping \
			> configure.log 2>&1 ) || iec_err "ncurses configure failed"
	fi
	PATH="/usr/bin:$PATH" make -C "$NC_BUILD" -j"$JOBS" > "$BUILD/ncurses-make.log" 2>&1 \
		|| iec_err "ncurses make failed"
	make -C "$NC_BUILD" install > "$BUILD/ncurses-install.log" 2>&1 \
		|| iec_err "ncurses install failed"
	ln -sf ncursesw "$PY_DEPS/include/ncurses" 2>/dev/null || true
	for h in curses.h ncurses.h term.h termcap.h unctrl.h; do
		[ -f "$PY_DEPS/include/ncursesw/$h" ] && \
			ln -sf "ncursesw/$h" "$PY_DEPS/include/$h" || true
	done
fi
[ -f "$PY_DEPS/lib/libncursesw.a" ] || iec_err "missing $PY_DEPS/lib/libncursesw.a"

if [ ! -f "$PY_DEPS/lib/libreadline.a" ]; then
	iec_log "build readline $RL_VER -> $PY_DEPS"
	fetch "$BUILD/readline-$RL_VER.tar.gz" "${RL_URLS[@]}"
	rm -rf "$RL_SRC" "$RL_BUILD"
	mkdir -p "$RL_SRC" "$RL_BUILD"
	tar -xzf "$BUILD/readline-$RL_VER.tar.gz" -C "$RL_SRC" --strip-components=1
	( cd "$RL_BUILD" && PATH="/usr/bin:$PATH" "$RL_SRC/configure" \
		--host="$AT_HOST" --build=x86_64-pc-linux-gnu --prefix="$PY_DEPS" \
		--disable-shared --enable-static --with-curses \
		CC="$CC_TARGET" AR="$AR" RANLIB="$RANLIB" \
		CFLAGS="-O2 -fPIC -I$PY_DEPS/include" LDFLAGS="-L$PY_DEPS/lib" \
		bash_cv_wcwidth_broken=no bash_cv_func_sigsetjmp=present \
		> configure.log 2>&1 ) || iec_err "readline configure failed"
	make -C "$RL_BUILD" -j1 > "$BUILD/readline-make.log" 2>&1 || true
	make -C "$RL_BUILD" -j"$JOBS" >> "$BUILD/readline-make.log" 2>&1 \
		|| iec_err "readline make failed"
	make -C "$RL_BUILD" install > "$BUILD/readline-install.log" 2>&1 \
		|| iec_err "readline install failed"
fi
[ -f "$PY_DEPS/lib/libreadline.a" ] || iec_err "missing $PY_DEPS/lib/libreadline.a"

# ── 3. CPython source, configure, build ───────────────────────────────────
if [ ! -f "$PY_SRC/configure" ]; then
	iec_log "extract CPython $PY_VER"
	fetch "$PY_TARBALL" "$PY_URL"
	mkdir -p "$SOURCE_CACHE"
	tar -xJf "$PY_TARBALL" -C "$SOURCE_CACHE"
fi

mkdir -p "$BLD"
# A reused build tree was configured with its own --prefix. make install will
# write there, so use that value when copying the stdlib out of DESTDIR.
if [ -f "$BLD/Makefile" ]; then
	configured_prefix="$(sed -n 's/^prefix[[:space:]]*=[[:space:]]*//p' "$BLD/Makefile" | head -1)"
	[ -n "$configured_prefix" ] && PREFIX="$configured_prefix"
fi
PY_CFLAGS="-fPIC -D__MUSL__=1 -O2 -Wno-unknown-warning-option \
-Wno-unused-result -Wno-deprecated-declarations -Wno-sign-compare \
-Wno-int-conversion -Wno-incompatible-pointer-types -Wno-unreachable-code \
-Wno-implicit-function-declaration -Wno-error=implicit-function-declaration"
PY_CPPFLAGS="-I$PY_DEPS/include -I$PY_DEPS/include/ncursesw -I$IEC_DEPS_INC -I$FFI_INC_DIR"
PY_LDFLAGS="-L$PY_DEPS/lib -L$IEC_DEPS_LIB -L$FFI_LIB_DIR"

CC_WRAP="$BUILD/cc-wrap.sh"
cat > "$CC_WRAP" <<EOF
#!/bin/sh
for a in "\$@"; do
    [ "\$a" = "--print-multiarch" ] && { echo aarch64-linux-gnu; exit 0; }
done
exec $CC_TARGET "\$@"
EOF
chmod +x "$CC_WRAP"

if [ -n "${PY_RECONFIGURE:-}" ]; then
	iec_log "PY_RECONFIGURE=1: recreating $BLD"
	rm -rf "$BLD"
	mkdir -p "$BLD"
fi

if [ ! -f "$BLD/Makefile" ]; then
	iec_log "configure CPython (static modules)"
	( cd "$BLD" && \
		PATH="/usr/bin:$PATH" \
		PKG_CONFIG_LIBDIR="$PY_DEPS/lib/pkgconfig:$IEC_DEPS_LIB/pkgconfig:$IEC_DEPS_DIR/usr/lib/pkgconfig" \
		PKG_CONFIG_PATH="" \
		PY_UNSUPPORTED_OPENSSL_BUILD=static \
		"$PY_SRC/configure" \
		MODULE_BUILDTYPE=static \
		--host="$AT_HOST" --build=x86_64-pc-linux-gnu --prefix="$PREFIX" \
		--with-build-python="$HOST_PY" \
		--disable-ipv6 --without-ensurepip --disable-test-modules \
		--with-system-ffi --with-readline \
		--with-openssl="$OPENSSL_DIR" \
		ac_cv_file__dev_ptmx=no ac_cv_file__dev_ptc=no \
		ac_cv_header_linux_qrtr_h=no \
		ac_cv_header_libintl_h=no \
		CC="$CC_WRAP" CXX="$CXX_TARGET" AR="$AR" RANLIB="$RANLIB" \
		CFLAGS="$PY_CFLAGS" CPPFLAGS="$PY_CPPFLAGS" LDFLAGS="$PY_LDFLAGS" \
		LIBFFI_CFLAGS="-I$FFI_INC_DIR" \
		LIBFFI_LIBS="-L$FFI_LIB_DIR -lffi" \
		LIBREADLINE_CFLAGS="-I$PY_DEPS/include" \
		LIBREADLINE_LIBS="-L$PY_DEPS/lib -lreadline -lncursesw" \
		CURSES_CFLAGS="-I$PY_DEPS/include -I$PY_DEPS/include/ncursesw" \
		CURSES_LIBS="-L$PY_DEPS/lib -lncursesw" \
		> configure.log 2>&1 ) || {
			tail -30 "$BLD/config.log" >&2 || true
			iec_err "CPython configure failed"
		}
	iec_log "static module count: $(grep -c '^[a-zA-Z_]' "$BLD/Modules/Setup.stdlib" 2>/dev/null || echo '?')"
	for m in readline _curses _ctypes pyexpat zlib _decimal _ssl _hashlib; do
		if grep -qE "^$m " "$BLD/Modules/Setup.stdlib"; then
			iec_log "  $m"
		else
			iec_log "  warning: $m was not detected"
		fi
	done
fi

grep -q '^\*static\*' "$BLD/Modules/Setup.stdlib" \
	|| iec_err "Setup.stdlib is not *static*; rerun with PY_RECONFIGURE=1"

iec_log "build CPython"
make -C "$BLD" -j1 Makefile > "$BUILD/py-makefile.log" 2>&1 || true
make -C "$BLD" -j"$JOBS" > "$BUILD/py-make.log" 2>&1 \
	|| { tail -30 "$BUILD/py-make.log" >&2; iec_err "CPython make failed"; }
# Force the link line to reappear in the log; step 4 parses it.
rm -f "$BLD/python"
make -C "$BLD" -j"$JOBS" python >> "$BUILD/py-make.log" 2>&1 \
	|| iec_err "CPython re-link failed"
[ -x "$BLD/python" ] || iec_err "missing $BLD/python"

# ── 4. assemble libpython.so ──────────────────────────────────────────────
iec_log "assemble $OUT"
LINK_CMD="$(awk '
    { while (sub(/\\$/, "")) { if ((getline nxt) > 0) $0 = $0 " " nxt; else break }
      if ($0 ~ /-o (\.\/)?python( |$)/) last = $0 }
    END { print last }' "$BUILD/py-make.log")"
[ -n "$LINK_CMD" ] || iec_err "no python link command in $BUILD/py-make.log"
case "$LINK_CMD" in
	*"-o python"*|*"-o ./python"*) ;;
	*) iec_err "link command does not use -o python" ;;
esac
LINK_CMD="$(printf '%s' "$LINK_CMD" | sed -E "s#-o (\./)?python#-shared -o \"$OUT\"#")"

SHIM_CFLAGS=(-O2 -fPIC -DINT_WARP -D_GNU_SOURCE
	-I "$IEC_ROOT" -I "$IEC_ROOT/common")
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/tty/shim.c" -o "$BUILD/iec_tty_shim.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -DIEC_SHIM_MERGED_OPEN \
	-c "$IEC_ROOT/fs/shim.c" -o "$BUILD/iec_fs_shim.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/exec/shim.c" -o "$BUILD/iec_exec_shim.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/rpc.c" -o "$BUILD/iec_rpc.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/common/sock_client.c" -o "$BUILD/iec_sock_client.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/compat/exit_wrap.c" -o "$BUILD/iec_exit_wrap.o"
$CC_TARGET "${SHIM_CFLAGS[@]}" -c "$IEC_ROOT/scripts/optional/python-ohos/iec_pip_entry.c" \
	-o "$BUILD/iec_pip_entry.o"

LOADER_CXXFLAGS=(-O2 -fPIC -fno-exceptions -fno-rtti -fno-threadsafe-statics
	-I "$IEC_ROOT" -I "$IEC_ROOT/loader")
$CXX_TARGET "${LOADER_CXXFLAGS[@]}" -c "$IEC_ROOT/loader/elf_dl.cpp" -o "$BUILD/iec_elf_dl.o"
$CXX_TARGET "${LOADER_CXXFLAGS[@]}" -c "$IEC_ROOT/loader/loader.cpp" -o "$BUILD/iec_loader.o"
$CC_TARGET -c "$IEC_ROOT/loader/guest_switch_aarch64.S" -o "$BUILD/iec_guest_switch.o"
$CC_TARGET -c "$IEC_ROOT/loader/tlsdesc.S" -o "$BUILD/iec_tlsdesc.o"
$CC_TARGET -O2 -fPIC -I "$IEC_ROOT/loader" -I "$IEC_ROOT" \
	-c "$IEC_ROOT/loader/wrap.c" -o "$BUILD/iec_dlopen_wrap.o"

WRAPS=(symlink symlinkat readlink readlinkat lstat stat fstatat fstat
	chmod fchmod fchmodat
	open openat unlink unlinkat rename renameat access faccessat realpath
	link linkat opendir readdir scandir fopen freopen syscall
	close dup dup2 dup3 fcntl ioctl isatty ttyname ttyname_r
	tcgetattr tcsetattr tcgetpgrp tcsetpgrp getpt grantpt unlockpt ptsname
	openpty login_tty forkpty
	execve execv execvp execvpe execl execlp execle
	exit)
WRAP_FLAGS=()
for name in "${WRAPS[@]}"; do
	WRAP_FLAGS+=("-Wl,--wrap=$name")
done

( cd "$BLD" && eval "$LINK_CMD \
	\"$BUILD/iec_tty_shim.o\" \"$BUILD/iec_fs_shim.o\" \
	\"$BUILD/iec_exec_shim.o\" \"$BUILD/iec_rpc.o\" \"$BUILD/iec_sock_client.o\" \
	\"$BUILD/iec_exit_wrap.o\" \"$BUILD/iec_pip_entry.o\" \
	\"$BUILD/iec_elf_dl.o\" \"$BUILD/iec_loader.o\" \
	\"$BUILD/iec_guest_switch.o\" \"$BUILD/iec_tlsdesc.o\" \"$BUILD/iec_dlopen_wrap.o\" \
	-Wl,-soname,libpython.so -Wl,-Bsymbolic-functions -Wl,-z,now \
	-Wl,--wrap=dlopen -Wl,--wrap=dlsym -Wl,--wrap=dlclose \
	${WRAP_FLAGS[*]}" ) || iec_err "libpython.so link failed"
[ -f "$OUT" ] || iec_err "no output at $OUT"

"$NM" -D "$OUT" | grep -E ' (T|W) Py_BytesMain$' >/dev/null \
	|| iec_err "Py_BytesMain is not exported"
if "$NM" -D -u "$OUT" | grep -E ' U (__wrap_|__real_)[A-Za-z0-9_]+$' >/dev/null; then
	iec_err "unresolved __wrap_/__real_ symbols"
fi
"$READELF" -d "$OUT" | grep -E 'NEEDED|SONAME' >&2 || true

# ── 5. stdlib tar ──────────────────────────────────────────────────────────
iec_log "pack python-stdlib.tar"
rm -rf "$STAGE" "$RT_ROOT"
mkdir -p "$STAGE" "$RT_ROOT"
make -C "$BLD" install DESTDIR="$STAGE" > "$BUILD/py-install.log" 2>&1 \
	|| iec_err "make install failed"

SLIB="$STAGE$PREFIX/lib/python$PY_SERIES"
[ -f "$SLIB/os.py" ] || iec_err "install tree has no os.py: $SLIB"
mkdir -p "$RT_ROOT/python/lib"
cp -a "$SLIB" "$RT_ROOT/python/lib/"
( cd "$RT_ROOT/python/lib/python$PY_SERIES" && \
	rm -rf test idlelib tkinter ensurepip lib2to3 config-* ) || true

DYN_OTHER="$(find "$RT_ROOT/python/lib/python$PY_SERIES/lib-dynload" \
	-name '*.so' 2>/dev/null | awk '/xxlimited/{next} {n++} END{print n+0}')"
[ "$DYN_OTHER" = "0" ] \
	|| iec_err "lib-dynload contains $DYN_OTHER non-xxlimited modules"
rm -rf "$RT_ROOT/python/lib/python$PY_SERIES/lib-dynload"
mkdir -p "$RT_ROOT/python/lib/python$PY_SERIES/site-packages"
find "$RT_ROOT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
tar -C "$RT_ROOT" -cf "$RTAR" python
[ -f "$RT_ROOT/python/lib/python$PY_SERIES/encodings/__init__.py" ] \
	|| iec_err "stdlib has no encodings package"

# ── 5.5 python-headers package ────────────────────────────────────────────
iec_log "pack python-headers"
HRT="$BUILD/pyheaders-rt"
rm -rf "$HRT"
mkdir -p "$HRT/python-headers"
cp -a "$PY_SRC/Include/." "$HRT/python-headers/"
cp -f "$BLD/pyconfig.h" "$HRT/python-headers/"
[ -f "$HRT/python-headers/Python.h" ] || iec_err "python-headers has no Python.h"
if command -v zstd >/dev/null 2>&1; then
	mkdir -p "$(dirname "$PYHDR_PKG")"
	tar -C "$HRT" -cf - python-headers \
		| zstd -q -f -19 -T"$(nproc)" -o "$PYHDR_PKG"
else
	iec_log "warning: zstd not found; skipping $PYHDR_PKG"
fi

iec_log "done:"
iec_log "  $OUT ($(du -h "$OUT" | cut -f1))"
iec_log "  $RTAR ($(du -h "$RTAR" | cut -f1), $(tar -tf "$RTAR" | wc -l) entries)"
if [ -f "$PYHDR_PKG" ]; then
	iec_log "  $PYHDR_PKG"
fi
cat >&2 <<EOF

Launchers the application bootstrap should write:
  python, python3 -> libpython.so:Py_BytesMain
  pip             -> libpython.so:iec_pip_main

Runtime environment:
  PYTHONHOME=<sysroot>/python
  (configured prefix: $PREFIX)
EOF
