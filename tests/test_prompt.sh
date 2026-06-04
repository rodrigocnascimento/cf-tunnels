#!/usr/bin/env bash
# tests/test_prompt.sh — Prompt hook tests
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Prevent main logic from executing
mock_main

test_prompt_sets_cftunnel_zone() {
	setup_mock_home
	echo "homelaberson.space" > "$HOME/.cloudflared/.default_zone"

	local zone_file="$HOME/.cloudflared/.default_zone"
	local z
	z="$(cat "$zone_file" 2>/dev/null | tr -d '\n\r' | head -1)"
	CFTUNNEL_ZONE="$z"

	assert_eq "homelaberson.space" "${CFTUNNEL_ZONE:-}" "CFTUNNEL_ZONE set correctly"

	teardown_mock_home
}

test_prompt_clears_cftunnel_zone_when_empty() {
	setup_mock_home

	local zone_file="$HOME/.cloudflared/.default_zone"
	if [[ -f "$zone_file" ]]; then
		local z
		z="$(cat "$zone_file" 2>/dev/null | tr -d '\n\r' | head -1)"
		CFTUNNEL_ZONE="$z"
	else
		CFTUNNEL_ZONE=""
	fi

	assert_eq "" "${CFTUNNEL_ZONE:-}" "CFTUNNEL_ZONE cleared when empty"

	teardown_mock_home
}
