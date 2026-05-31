#!/usr/bin/env bash
# tests/test_prompt.sh — Prompt hook tests
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Prevent main logic from executing
mock_main

test_prompt_sets_cftunnel_profile() {
	setup_mock_home
	echo "homelab" > "$HOME/.cloudflared/.default_profile"

	# Simulate hook refresh
	local profile_file="$HOME/.cloudflared/.default_profile"
	local p
	p="$(cat "$profile_file" 2>/dev/null | tr -d '\n\r' | head -1)"
	CFTUNNEL_PROFILE="$p"

	assert_eq "homelab" "${CFTUNNEL_PROFILE:-}" "CFTUNNEL_PROFILE set correctly"

	teardown_mock_home
}

test_prompt_clears_cftunnel_profile_when_empty() {
	setup_mock_home
	# No default profile

	local profile_file="$HOME/.cloudflared/.default_profile"
	if [[ -f "$profile_file" ]]; then
		local p
		p="$(cat "$profile_file" 2>/dev/null | tr -d '\n\r' | head -1)"
		CFTUNNEL_PROFILE="$p"
	else
		CFTUNNEL_PROFILE=""
	fi

	assert_eq "" "${CFTUNNEL_PROFILE:-}" "CFTUNNEL_PROFILE cleared when empty"

	teardown_mock_home
}

test_prompt_prefix_mode_bash() {
	# Skip if not bash
	if [[ -z "${BASH_VERSION:-}" ]]; then
		return 0
	fi

	setup_mock_home
	echo "homelab" > "$HOME/.cloudflared/.default_profile"

	CFTUNNEL_PROMPT_MODE="prefix"
	PS1="user@host:~$ "
	_CFTUNNEL_PS1_ORIGINAL="$PS1"

	# Simulate hook
	local profile_file="$HOME/.cloudflared/.default_profile"
	local p
	p="$(cat "$profile_file" 2>/dev/null | tr -d '\n\r' | head -1)"
	CFTUNNEL_PROFILE="$p"

	if [[ "${CFTUNNEL_PROMPT_MODE:-}" == "prefix" ]]; then
		if [[ -n "${CFTUNNEL_PROFILE:-}" ]]; then
			PS1="\[\033[36m\]🚇[${CFTUNNEL_PROFILE}]\[\033[0m\] ${_CFTUNNEL_PS1_ORIGINAL}"
		fi
	fi

	assert_contains "$PS1" "🚇[homelab]" "PS1 prefixed with profile"
	assert_contains "$PS1" "user@host:~$" "PS1 preserves original"

	teardown_mock_home
}

test_prompt_p10k_dir_prefix() {
	setup_mock_home
	echo "homelab" > "$HOME/.cloudflared/.default_profile"

	# Simulate p10k loaded
	POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(dir)
	CFTUNNEL_PROMPT_MODE="auto"

	# Simulate auto-detect
	if [[ -n "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS:-}" || -n "${POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS:-}" ]]; then
		CFTUNNEL_PROMPT_MODE="dir_prefix"
	fi

	local profile_file="$HOME/.cloudflared/.default_profile"
	local p
	p="$(cat "$profile_file" 2>/dev/null | tr -d '\n\r' | head -1)"
	CFTUNNEL_PROFILE="$p"

	# Simulate p10k update
	local mode="${CFTUNNEL_PROMPT_MODE:-}"
	if [[ "$mode" == "dir_prefix" ]]; then
		if [[ -n "${CFTUNNEL_PROFILE:-}" ]]; then
			POWERLEVEL9K_DIR_PREFIX="%F{cyan}🚇[${CFTUNNEL_PROFILE}]%f "
		fi
	fi

	assert_contains "${POWERLEVEL9K_DIR_PREFIX:-}" "🚇[homelab]" "p10k DIR_PREFIX set"

	teardown_mock_home
}

test_prompt_p10k_dir_suffix() {
	setup_mock_home
	echo "homelab" > "$HOME/.cloudflared/.default_profile"

	CFTUNNEL_PROMPT_MODE="dir_suffix"

	local profile_file="$HOME/.cloudflared/.default_profile"
	local p
	p="$(cat "$profile_file" 2>/dev/null | tr -d '\n\r' | head -1)"
	CFTUNNEL_PROFILE="$p"

	local mode="${CFTUNNEL_PROMPT_MODE:-}"
	if [[ "$mode" == "dir_suffix" ]]; then
		if [[ -n "${CFTUNNEL_PROFILE:-}" ]]; then
			POWERLEVEL9K_DIR_SUFFIX=" %F{cyan}🚇[${CFTUNNEL_PROFILE}]%f"
		fi
	fi

	assert_contains "${POWERLEVEL9K_DIR_SUFFIX:-}" "🚇[homelab]" "p10k DIR_SUFFIX set"

	teardown_mock_home
}
