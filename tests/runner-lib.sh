#!/usr/bin/env bash
# tests/runner-lib.sh — Shared helpers for all test files
# =============================================================================

# ── Assert helpers ──

assert_eq() {
	local expected="$1"
	local actual="$2"
	local msg="${3:-}"
	if [[ "$expected" != "$actual" ]]; then
		echo "ASSERT FAIL${msg:+ [$msg]}: expected '$expected', got '$actual'" >&2
		exit 1
	fi
}

assert_ne() {
	local not_expected="$1"
	local actual="$2"
	local msg="${3:-}"
	if [[ "$not_expected" == "$actual" ]]; then
		echo "ASSERT FAIL${msg:+ [$msg]}: expected not '$not_expected', got '$actual'" >&2
		exit 1
	fi
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local msg="${3:-}"
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "ASSERT FAIL${msg:+ [$msg]}: string does not contain '$needle'" >&2
		exit 1
	fi
}

assert_file_exists() {
	local path="$1"
	local msg="${2:-}"
	if [[ ! -f "$path" ]]; then
		echo "ASSERT FAIL${msg:+ [$msg]}: file does not exist: $path" >&2
		exit 1
	fi
}

assert_file_not_exists() {
	local path="$1"
	local msg="${2:-}"
	if [[ -f "$path" ]]; then
		echo "ASSERT FAIL${msg:+ [$msg]}: file exists but should not: $path" >&2
		exit 1
	fi
}

assert_true() {
	local condition="$1"
	local msg="${2:-}"
	if [[ "$condition" != "true" && "$condition" != "0" && -z "$condition" ]]; then
		echo "ASSERT FAIL${msg:+ [$msg]}: expected true, got '$condition'" >&2
		exit 1
	fi
}

# ── Mock helpers ──

setup_mock_home() {
	mkdir -p "$HOME/.cloudflared/profiles"
	# Create a fake cert.pem to bypass auth checks
	touch "$HOME/.cloudflared/cert.pem"
	# Override HOME_DIR so run.sh functions use the temp HOME
	HOME_DIR="$HOME"
	BASE_DIR="$HOME/.cloudflared"
	DEFAULT_PROFILE_FILE="$HOME/.cloudflared/.default_profile"
}

teardown_mock_home() {
	rm -rf "$HOME/.cloudflared"
}

# Prevent run.sh from exiting during source (it calls check_cloudflared_version which calls exit)
mock_main() {
	# Override check_cloudflared_version to no-op
	check_cloudflared_version() { return 0; }
	# Ensure functions use the temp HOME
	HOME_DIR="$HOME"
	BASE_DIR="$HOME/.cloudflared"
	DEFAULT_PROFILE_FILE="$HOME/.cloudflared/.default_profile"
}
