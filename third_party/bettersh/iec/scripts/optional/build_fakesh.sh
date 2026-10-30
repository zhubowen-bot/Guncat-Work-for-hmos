#!/bin/bash
# scripts/optional/build_fakesh.sh — build the fake shell and put it where a fake root
# expects it.
#
# Usage:
#   scripts/optional/build_fakesh.sh
#
# The fake shell (thirdparty/fakesh/main.cpp) prints a banner, then reads lines and echoes
# them back, so a terminal that starts it makes the interception visible: what you type
# comes back, and it says plainly that it is not the real sh.
#
# It is installed under FAKE_SYSROOT, the root absolute paths are rewritten into when the
# capabilities say only the app sandbox is reachable (see ResolveFilePath and
# common/constant.h). Two names, because two things ask for a shell by different ones:
#
#   bin/sh     what /bin/sh is rewritten to, and what a terminal falls back on
#   bin/bash   what a terminal asks for when the environment names it, which is what an
#              interactive one does
#
# It is linked statically on purpose. Where nothing may be exec'd a program is entered
# through an emulator object, and a dynamic guest would need its own loader to be reachable
# from inside the emulated root; nothing else is.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/thirdparty/fakesh/main.cpp"

log() { echo "=== $* ===" >&2; }
err() { echo "ERROR: $*" >&2; exit 1; }

CXX="${CXX:-g++}"
[ -f "$SRC" ] || err "fake shell source not found: $SRC"
command -v "$CXX" >/dev/null || err "$CXX not found"

# The root is read out of common/constant.h, the way the qemu script reads the entry name
# from it: the server rewrites paths into this directory, so the two have to agree and the
# header is where that agreement is written down.
FAKE_SYSROOT=$(sed -n 's/^#define[[:space:]][[:space:]]*FAKE_SYSROOT[[:space:]][[:space:]]*"\([^"]*\)".*/\1/p' \
	"$ROOT/common/constant.h")
[ -n "$FAKE_SYSROOT" ] || err "FAKE_SYSROOT not found in common/constant.h"

BINDIR="$FAKE_SYSROOT/bin"
mkdir -p "$BINDIR"

for name in sh bash; do
	log "building $BINDIR/$name"
	"$CXX" -static -O2 -Wall -o "$BINDIR/$name" "$SRC" \
		|| err "building the fake $name failed (a static link needs this host's static libstdc++)"
done

# One script to go with it, which is what the interpreter route is for: inside the root
# /bin/sh is the fake shell above, so running this prints its banner and echoes what is
# typed. The -e after the interpreter is there on purpose, being the single argument a
# shebang line may carry between the interpreter and the script.
SAMPLE="$BINDIR/hello.sh"
log "writing $SAMPLE"
cat > "$SAMPLE" <<'EOF'
#!/bin/sh -e
echo "this line comes from the script, read by whatever /bin/sh is"
EOF
chmod +x "$SAMPLE"

log "artifacts: $BINDIR/sh $BINDIR/bash $SAMPLE"
cat >&2 <<EOF

To land in it: with the server running, start a terminal -- or any pty client -- with
  SHELL=$BINDIR/sh
What comes up prints "Hello, this is not real sh!" and echoes every line back, and it also
prints the arguments it was started with, being the only place a script's own name shows
up once its interpreter line has been followed -- the shell itself never reads the script.

The other way in is the fake root itself: with the capabilities saying the app sandbox is
all there is (PATH_PROBE = 0), an absolute path is rewritten into $FAKE_SYSROOT, so
/bin/sh and /bin/hello.sh mean the two files built here. Starting the second one is what
the interpreter route is for: /bin/sh is read out of the script's first line, the script's
own name follows it as the argument to run, and that is why the block above shows
$FAKE_SYSROOT/bin/sh and then $FAKE_SYSROOT/bin/hello.sh.
EOF
