[[ -z "${_CFTUNNEL_COMMON_LOADED:-}" ]] || return 0
_CFTUNNEL_COMMON_LOADED=1

die() {
	echo "error: $*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

print_cftunnel_version() {
	local version_file="${CFTUNNEL_VERSION_FILE:-$SCRIPT_DIR/VERSION}"
	[[ -f "$version_file" && -r "$version_file" ]] || die "version file is missing or unreadable: $version_file"

	local lines=()
	mapfile -t lines < "$version_file"
	[[ ${#lines[@]} -eq 1 ]] || die "invalid version file: $version_file"

	local version="${lines[0]}"
	local semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
	[[ "$version" =~ $semver_pattern ]] || die "invalid version: $version"

	printf 'cftunnel %s\n' "$version"
}

slugify() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}
