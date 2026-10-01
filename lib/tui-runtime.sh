#!/usr/bin/env bash

verify_cftunnel_runtime() {
	local install_root="$1" expected_version="$2"
	local runtime="$install_root/packages/tui/dist/cftunnel-runtime"
	local manifest="$runtime.manifest.json"
	local platform arch expected_target actual_hash manifest_hash

	case "$(uname -s)" in
	Linux) platform="linux" ;;
	*) echo "cftunnel TUI runtime is not available for $(uname -s)" >&2; return 1 ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch="x64" ;;
	aarch64 | arm64) arch="arm64" ;;
	*) echo "cftunnel TUI runtime is not available for architecture $(uname -m)" >&2; return 1 ;;
	esac
	expected_target="bun-$platform-$arch"

	[[ -f "$runtime" && ! -L "$runtime" && -x "$runtime" ]] || {
		echo "the production TUI runtime is missing or not executable; reinstall the complete cftunnel package" >&2
		return 1
	}
	[[ -f "$manifest" && ! -L "$manifest" ]] || {
		echo "the production TUI runtime manifest is missing; reinstall the complete cftunnel package" >&2
		return 1
	}
	command -v jq >/dev/null 2>&1 || { echo "required command not found: jq" >&2; return 1; }
	command -v sha256sum >/dev/null 2>&1 || { echo "required command not found: sha256sum" >&2; return 1; }

	if ! jq -e \
		--arg version "$expected_version" \
		--arg platform "$platform" \
		--arg arch "$arch" \
		--arg target "$expected_target" \
		'.schema_version == 1 and .tui_version == $version and .platform == $platform and .arch == $arch and .target == $target and .cftunnel_contract_schema == 1 and (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))' \
		"$manifest" >/dev/null; then
		echo "the production TUI runtime manifest does not match this cftunnel version/platform; reinstall the complete cftunnel package" >&2
		return 1
	fi

	actual_hash="$(sha256sum "$runtime" | awk '{print $1}')" || return 1
	manifest_hash="$(jq -r '.sha256' "$manifest")" || return 1
	[[ "$actual_hash" == "$manifest_hash" ]] || {
		echo "the production TUI runtime failed SHA-256 verification; reinstall the complete cftunnel package" >&2
		return 1
	}
}
