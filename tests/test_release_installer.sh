#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFTUNNEL_INSTALLER_LIBRARY_ONLY=true source "$PROJECT_DIR/install-cftunnel.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

archive="$test_dir/cftunnel-linux-x64.tar.gz"
checksum="$archive.sha256"
mkdir -p "$test_dir/cf-tunnels"
printf 'release payload\n' > "$test_dir/cf-tunnels/VERSION"
tar -czf "$archive" -C "$test_dir" cf-tunnels
(cd "$test_dir" && sha256sum "$(basename "$archive")") > "$checksum"

verify_release_checksum "$archive" "$checksum" "cftunnel-linux-x64.tar.gz"
verify_archive_members "$archive"

if verify_release_checksum "$archive" "$checksum" "unexpected-name.tar.gz" >/dev/null 2>&1; then
	echo "checksum accepted an unexpected asset name" >&2
	exit 1
fi

printf 'tampered\n' >> "$archive"
if verify_release_checksum "$archive" "$checksum" "cftunnel-linux-x64.tar.gz" >/dev/null 2>&1; then
	echo "checksum accepted a modified release archive" >&2
	exit 1
fi

echo "release installer checksum and archive checks passed"

# EXIT must work after main's local variables leave scope, preserve failures,
# and quote temporary paths rather than evaluate them.
for expected_status in 0 7; do
	cleanup_target="$test_dir/download directory 'quoted' $expected_status"
	mkdir -p "$cleanup_target"
	actual_status=0
	CFTUNNEL_INSTALLER_LIBRARY_ONLY=true bash -c '
		set -euo pipefail
		source "$1"
		setup() { local temp_dir="$2"; register_download_cleanup "$temp_dir"; }
		setup "$@"
		exit "$3"
	' bash "$PROJECT_DIR/install-cftunnel.sh" "$cleanup_target" "$expected_status" || actual_status=$?
	[[ "$actual_status" -eq "$expected_status" ]] || { echo "download cleanup changed the installer exit status" >&2; exit 1; }
	[[ ! -e "$cleanup_target" ]] || { echo "download cleanup left its temporary directory behind" >&2; exit 1; }
done
echo "release installer cleanup preserves status after function return"
