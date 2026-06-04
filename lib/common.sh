[[ -z "${_CFTUNNEL_COMMON_LOADED:-}" ]] || return 0
_CFTUNNEL_COMMON_LOADED=1

die() {
	echo "error: $*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

slugify() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}
