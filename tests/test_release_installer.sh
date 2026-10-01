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
