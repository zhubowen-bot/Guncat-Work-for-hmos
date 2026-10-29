#!/bin/sh
# Compatibility wrapper: the node build implementation lives in the IEC tree.
exec "$(cd "$(dirname "$0")/.." && pwd)/iec/scripts/optional/build_node.sh" "$@"
