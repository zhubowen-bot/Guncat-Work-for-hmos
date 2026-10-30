# shellcheck shell=bash
# iec/scripts/lib/common.sh — helpers shared by the IEC build scripts.

iec_log() { echo "=== $* ===" >&2; }
iec_err() { echo "ERROR: $*" >&2; exit 1; }

# Clone a source tree the first time a build needs it.
#
#   iec_clone_if_missing <dir> <url> [ref]
#
# A directory that already exists but is not a git checkout is left alone and
# reported: silently deleting it could destroy a user's work.
iec_clone_if_missing() {
	local dir="$1"
	local url="$2"
	local ref="${3:-}"

	if [ -e "$dir/.git" ]; then
		return 0
	fi
	if [ -e "$dir" ]; then
		iec_err "$dir exists but is not a git checkout"
	fi
	[ -n "$url" ] || iec_err "no repository URL configured for $dir"
	command -v git >/dev/null 2>&1 || iec_err "git is not installed"

	mkdir -p "$(dirname "$dir")"
	if [ -n "$ref" ]; then
		iec_log "clone $url ($ref) -> $dir"
		git clone --depth 1 --branch "$ref" "$url" "$dir" \
			|| iec_err "git clone failed: $url ($ref)"
	else
		iec_log "clone $url -> $dir"
		git clone --depth 1 "$url" "$dir" \
			|| iec_err "git clone failed: $url"
	fi
}
