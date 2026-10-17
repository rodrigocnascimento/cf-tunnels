#!/usr/bin/env bash
set -euo pipefail

test_cloudflared_failed_download_rejects_partial_file() {
	local output rc=0
	output="$(
		exec 2>&1
		CFTUNNEL_INSTALLER_LIBRARY_ONLY=true source "$PROJECT_DIR/install.sh"
		CLOUDFLARED_BIN=""
		curl() {
			while [[ $# -gt 0 ]]; do
				if [[ "$1" == -o ]]; then printf 'partial download\n' > "$2"; return 1; fi
				shift
			done
			return 1
		}
		sleep() { :; }
		install_cloudflared_system_binary() { echo 'UNEXPECTED_INSTALL_ATTEMPT'; }
		install_cloudflared
	)" || rc=$?
	assert_ne 0 "$rc" "failed downloads must fail even with a partial file"
	assert_contains "$output" "Failed to download cloudflared after 5 attempts"
	assert_not_contains "$output" "UNEXPECTED_INSTALL_ATTEMPT"
}

test_check_dns_tools_warns_when_dig_and_host_are_missing() {
	local output rc=0
	output="$(
		exec 2>&1
		CFTUNNEL_INSTALLER_LIBRARY_ONLY=true source "$PROJECT_DIR/install.sh"
		PATH="/nonexistent-bin"
		check_dns_tools
	)" || rc=$?
	assert_eq 0 "$rc" "the DNS tool hint must not fail the installation"
	assert_contains "$output" "dig/host not found" "missing DNS tooling is reported"
	assert_contains "$output" "Install the '" "a package suggestion is printed"
}
