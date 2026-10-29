#!/bin/bash
# scripts/build_client.sh — build weston-terminal on the host (x86_64 Linux)
#
# Usage:
#   scripts/build_client.sh -o <output path> [extra link args...]
#
# The extra args are inserted after the source files and before the system libraries, to link the IEC shim into the client:
#   scripts/build_client.sh -o dist/weston-terminal-wrap -Wl,--wrap=forkpty build/shim_tty.o
#
# Why WARP mode cannot avoid this step: --wrap is a link-time behavior, and only applies to the input object files of this link;
# it has no effect on an already-built executable, so interception can only come from relinking the client, not from LD_PRELOAD.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WESTON_SRC="${WESTON_SRC:-/workspace/dev/weston}"
BUILD="$ROOT/build/weston-term"
PROTO_GEN="$BUILD/protocols"

OUT=""
EXTRA=()
while [ $# -gt 0 ]; do
	case "$1" in
		-o) OUT="${2:-}"; shift 2 ;;
		*)  EXTRA+=("$1"); shift ;;
	esac
done
if [ -z "$OUT" ]; then
	echo "usage: $0 -o <output path> [extra link args...]" >&2
	exit 1
fi

[ -f "$WESTON_SRC/clients/terminal.c" ] || {
	echo "weston source not found: $WESTON_SRC/clients/terminal.c (specify with WESTON_SRC=)" >&2
	exit 1
}
SCANNER="$(command -v wayland-scanner)" || {
	echo "wayland-scanner not found" >&2
	exit 1
}

mkdir -p "$PROTO_GEN" "$(dirname "$OUT")"

WPS=/usr/share/wayland-protocols
gen_proto() {
	local xml="$1" base="$2"
	[ -f "$xml" ] || { echo "missing protocol XML: $xml" >&2; exit 1; }
	"$SCANNER" client-header "$xml" "$PROTO_GEN/${base}-client-protocol.h"
	"$SCANNER" private-code  "$xml" "$PROTO_GEN/${base}-protocol.c"
}

echo "=== generating protocols ===" >&2
gen_proto "$WPS/stable/xdg-shell/xdg-shell.xml"                                   "xdg-shell"
gen_proto "$WPS/stable/viewporter/viewporter.xml"                                 "viewporter"
gen_proto "$WPS/unstable/relative-pointer/relative-pointer-unstable-v1.xml"       "relative-pointer-unstable-v1"
gen_proto "$WPS/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml" "pointer-constraints-unstable-v1"
gen_proto "$WPS/unstable/tablet/tablet-unstable-v2.xml"                           "tablet-unstable-v2"
gen_proto "$WPS/staging/color-management/color-management-v1.xml"                 "color-management-v1"
gen_proto "$WPS/staging/single-pixel-buffer/single-pixel-buffer-v1.xml"           "single-pixel-buffer-v1"
gen_proto "$WESTON_SRC/protocol/text-cursor-position.xml"                         "text-cursor-position"
gen_proto "$WESTON_SRC/protocol/ivi-application.xml"                              "ivi-application"

# file-util.c builds the theme PNG path with "%s/weston/%s", so DATADIR must be /usr/share,
# writing /usr/share/weston makes frame_create() get NULL, and then
# segfault inside widget_set_transparent().
cat > "$BUILD/config.h" <<'EOF'
#ifndef WESTON_TERMINAL_CONFIG_H
#define WESTON_TERMINAL_CONFIG_H
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include <stdlib.h>
#define PACKAGE_STRING  "weston-terminal"
#define PACKAGE_VERSION "16.0.90"
#define DATADIR         "/usr/share"
#define SYSCONFDIR      "/etc"
#define LIBEXECDIR      "/usr/libexec/weston"
#define BINDIR          "/usr/bin"
#define HAVE_MEMFD_CREATE 1
#define HAVE_MKOSTEMP 1
#define HAVE_POSIX_FALLOCATE 1
#define HAVE_STRCHRNUL 1
#define USE_RESIZE_POOL 1
#define HAVE_JPEG 1
#define HAVE_WEBP 1
#define HAVE_PANGO 1
#endif
EOF

PKGS="wayland-client wayland-cursor xkbcommon cairo fontconfig libpng libjpeg libwebp expat pixman-1 pango pangocairo glib-2.0 gobject-2.0"
INCLUDES="-I$BUILD -I$PROTO_GEN -I$WESTON_SRC -I$WESTON_SRC/include -I$WESTON_SRC/shared -I$WESTON_SRC/clients $(pkg-config --cflags $PKGS)"
LIBS="$(pkg-config --libs $PKGS) -lrt -lm"

SOURCES=(
	"$WESTON_SRC/clients/terminal.c"
	"$WESTON_SRC/clients/window.c"
	"$WESTON_SRC/shared/config-parser.c"
	"$WESTON_SRC/shared/option-parser.c"
	"$WESTON_SRC/shared/file-util.c"
	"$WESTON_SRC/shared/os-compatibility.c"
	"$WESTON_SRC/shared/process-util.c"
	"$WESTON_SRC/shared/hash.c"
	"$WESTON_SRC/shared/image-loader.c"
	"$WESTON_SRC/shared/cairo-util.c"
	"$WESTON_SRC/shared/frame.c"
	"$WESTON_SRC/shared/matrix.c"
	"$PROTO_GEN/xdg-shell-protocol.c"
	"$PROTO_GEN/viewporter-protocol.c"
	"$PROTO_GEN/relative-pointer-unstable-v1-protocol.c"
	"$PROTO_GEN/pointer-constraints-unstable-v1-protocol.c"
	"$PROTO_GEN/tablet-unstable-v2-protocol.c"
	"$PROTO_GEN/color-management-v1-protocol.c"
	"$PROTO_GEN/single-pixel-buffer-v1-protocol.c"
	"$PROTO_GEN/text-cursor-position-protocol.c"
	"$PROTO_GEN/ivi-application-protocol.c"
)

echo "=== building weston-terminal ===" >&2
gcc -O2 $INCLUDES "${SOURCES[@]}" "${EXTRA[@]}" $LIBS -o "$OUT"
chmod +x "$OUT"
echo "=== artifact: $OUT ===" >&2
