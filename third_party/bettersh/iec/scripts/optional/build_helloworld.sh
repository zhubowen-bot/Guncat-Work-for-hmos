#!/bin/bash
# scripts/optional/build_helloworld.sh — build the shared-object example and the
# launcher that starts it.
#
# Usage:
#   scripts/optional/build_helloworld.sh [-o <output dir>] [-n <name>]
#
# Two files come out, both build outputs and neither of them part of `make` (this
# directory is the optional half of the tree):
#
#   <dir>/<name>.so       the example program, built -shared
#   <dir>/<name>.launch   the four lines that name it, for a client to exec
#
# The launcher's second line is an absolute path, because that is what the format asks
# for: keep the two files together, or edit that line after moving them.
#
# To try it, with the server already running:
#   LD_PRELOAD=dist/libiec.so bash -c "exec dist/hello.launch one two"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/thirdparty/helloworld/main.cpp"
OUT_DIR="$ROOT/dist"
NAME="hello"
ENTRY="main"
ARITY=2   # 2 is int entry(int argc, char **argv); 3 also passes char **envp

while [ $# -gt 0 ]; do
	case "$1" in
		-o) OUT_DIR="${2:-}"; shift 2 ;;
		-n) NAME="${2:-}"; shift 2 ;;
		*)  echo "usage: $0 [-o <output dir>] [-n <name>]" >&2; exit 1 ;;
	esac
done

CXX="${CXX:-g++}"
[ -f "$SRC" ] || { echo "example source not found: $SRC" >&2; exit 1; }
command -v "$CXX" >/dev/null || { echo "$CXX not found" >&2; exit 1; }

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
SO="$OUT_DIR/$NAME.so"
LAUNCHER="$OUT_DIR/$NAME.launch"

echo "=== building $SO ===" >&2
"$CXX" -shared -fPIC -O2 -Wall -o "$SO" "$SRC"

# The launcher is four lines: the magic, the object, the entry point in it, and the
# shape that entry takes. A name that is not in the object is not found until the
# program is started, where it ends as exit status 126 (see exec/exec_so.h).
echo "=== writing $LAUNCHER ===" >&2
printf '#IECSO\n%s\n%s\n%d\n' "$SO" "$ENTRY" "$ARITY" > "$LAUNCHER"

echo "=== artifacts: $SO $LAUNCHER ===" >&2
