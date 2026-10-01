#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="rodrigocnascimento/cf-tunnels"

die() {
	echo "cftunnel installer: $*" >&2
	exit 1
}

show_help() {
	cat <<'HELP'
Install the latest cftunnel release bundle for Linux x64 or ARM64.

Usage:
  curl -fsSL https://raw.githubusercontent.com/rodrigocnascimento/cf-tunnels/main/install-cftunnel.sh | bash
  curl -fsSL https://raw.githubusercontent.com/rodrigocnascimento/cf-tunnels/main/install-cftunnel.sh | bash -s -- [install.sh options]

Options are passed to the bundled install.sh, for example:
  --skip-cloudflared  Do not install cloudflared
  --skip-symlink      Do not create /usr/local/bin/cftunnel
  --force             Replace the current cftunnel link/file

Run as your regular user. The installer requests sudo only for system files.
Zone authentication is performed later with `cftunnel zone login`.
HELP
}

verify_release_checksum() {
	local archive="$1" checksum_file="$2" expected_asset="$3"
	local expected_hash asset_name actual_hash

	[[ -s "$checksum_file" ]] || { echo "release checksum file is empty" >&2; return 1; }
	read -r expected_hash asset_name < "$checksum_file" || return 1
	[[ "$asset_name" == "$expected_asset" ]] || { echo "release checksum names an unexpected asset" >&2; return 1; }
	[[ "$expected_hash" =~ ^[A-Fa-f0-9]{64}$ ]] || { echo "release checksum is malformed" >&2; return 1; }
	actual_hash="$(sha256sum "$archive" | awk '{print $1}')" || return 1
	[[ "$actual_hash" == "$expected_hash" ]] || { echo "release archive failed SHA-256 verification" >&2; return 1; }
}

verify_archive_members() {
	local archive="$1" entries listing entry
	entries="$(tar -tzf "$archive")" || { echo "release archive is invalid" >&2; return 1; }
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		case "$entry" in
		cf-tunnels | cf-tunnels/*) ;;
		*) echo "release archive contains an unexpected path" >&2; return 1 ;;
		esac
		[[ "$entry" != /* ]] || { echo "release archive contains an absolute path" >&2; return 1; }
		case "/$entry/" in
		*/../*) echo "release archive contains a parent-directory path" >&2; return 1 ;;
		esac
	done <<< "$entries"
	listing="$(tar -tvzf "$archive")" || { echo "release archive is invalid" >&2; return 1; }
	while IFS= read -r entry; do
		case "${entry:0:1}" in
		l | h) echo "release archive must not contain symbolic or hard links" >&2; return 1 ;;
		esac
	done <<< "$listing"
}

download_asset() {
	local url="$1" destination="$2"
	if command -v curl >/dev/null 2>&1; then
		curl --fail --location --silent --show-error "$url" --output "$destination" || die "download failed: $url"
	elif command -v wget >/dev/null 2>&1; then
		wget --quiet "$url" --output-document "$destination" || die "download failed: $url"
	else
		die "curl or wget is required to download the release bundle"
	fi
}

main() {
	if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
		show_help
		return 0
	fi
	[[ $EUID -ne 0 ]] || die "run as your regular user, not through sudo; install.sh will request sudo only where needed"

	local arch asset checksum_asset base_url temp_dir archive checksum_file expected_version actual_hash
	case "$(uname -s)" in Linux) : ;; *) die "supported platforms are Linux x64 and Linux ARM64" ;; esac
	case "$(uname -m)" in
	x86_64 | amd64) arch="x64" ;;
	aarch64 | arm64) arch="arm64" ;;
	*) die "unsupported architecture: $(uname -m) (supported: x64, arm64)" ;;
	esac
	command -v tar >/dev/null 2>&1 || die "required command not found: tar"
	command -v sha256sum >/dev/null 2>&1 || die "required command not found: sha256sum"
	command -v mktemp >/dev/null 2>&1 || die "required command not found: mktemp"

	asset="cftunnel-linux-$arch.tar.gz"
	checksum_asset="$asset.sha256"
	base_url="https://github.com/$REPOSITORY/releases/latest/download"
	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cftunnel-install.XXXXXX")" || die "could not create a temporary download directory"
	trap 'rm -rf -- "$temp_dir"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	archive="$temp_dir/$asset"
	checksum_file="$temp_dir/$checksum_asset"

	echo "Downloading latest cftunnel release for Linux $arch..."
	download_asset "$base_url/$asset" "$archive"
	download_asset "$base_url/$checksum_asset" "$checksum_file"
	verify_release_checksum "$archive" "$checksum_file" "$asset" || die "release checksum verification failed"
	verify_archive_members "$archive" || die "release archive contents failed validation"

	tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$temp_dir" || die "could not extract the verified release bundle"
	local package="$temp_dir/cf-tunnels"
	[[ -f "$package/install.sh" && -f "$package/VERSION" && -f "$package/lib/tui-runtime.sh" ]] || die "release bundle is missing required cftunnel files"
	expected_version="$(tr -d '[:space:]' < "$package/VERSION")"
	[[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "release bundle contains an invalid application version"
	source "$package/lib/tui-runtime.sh"
	verify_cftunnel_runtime "$package" "$expected_version" || die "bundled TUI/log runtime verification failed"

	actual_hash="$(sha256sum "$archive" | awk '{print $1}')"
	local install_root="$HOME/.local/share/cftunnel/releases"
	mkdir -p "$install_root" || die "could not create the user install directory"
	install_root="$(cd "$install_root" && pwd -P)"
	local install_dir="$install_root/$expected_version-${actual_hash:0:12}"
	if [[ -e "$install_dir" || -L "$install_dir" ]]; then
		[[ -d "$install_dir" && ! -L "$install_dir" ]] || die "release install target is not a real directory: $install_dir"
		verify_cftunnel_runtime "$install_dir" "$expected_version" || die "existing release installation failed verification; remove it manually before retrying"
		echo "Using already installed cftunnel $expected_version."
	else
		mv -- "$package" "$install_dir" || die "could not install the verified release bundle"
	fi

	local install_args=("$@") symlink_path="/usr/local/bin/cftunnel" linked_target
	if [[ -L "$symlink_path" ]]; then
		linked_target="$(readlink -f "$symlink_path" 2>/dev/null || true)"
		case "$linked_target" in
		"$install_root"/*/run.sh)
			[[ " ${install_args[*]} " == *" --force "* ]] || install_args+=(--force)
			;;
		esac
	fi

	echo "Installing cftunnel $expected_version from $install_dir..."
	bash "$install_dir/install.sh" "${install_args[@]}"
}

if [[ "${CFTUNNEL_INSTALLER_LIBRARY_ONLY:-false}" != "true" ]]; then
	main "$@"
fi
