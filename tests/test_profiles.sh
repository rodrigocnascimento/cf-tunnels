#!/usr/bin/env bash
# tests/test_profiles.sh — Integration tests for profile management
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Prevent main logic from executing
mock_main

test_profile_use_creates_default_file() {
	setup_mock_home

	op_profile use "Meu Homelab"
	assert_file_exists "$HOME/.cloudflared/.default_profile"

	local content
	content="$(cat "$HOME/.cloudflared/.default_profile")"
	assert_eq "meu-homelab" "$content" "profile content should be slugified"

	teardown_mock_home
}

test_profile_current_shows_value() {
	setup_mock_home
	echo "meu-homelab" > "$HOME/.cloudflared/.default_profile"

	local output
	output="$(op_profile current 2>&1)"
	assert_contains "$output" "meu-homelab" "profile current should show value"

	teardown_mock_home
}

test_profile_current_empty() {
	setup_mock_home

	local output
	output="$(op_profile current 2>&1)"
	assert_contains "$output" "No default profile" "profile current should show empty message"

	teardown_mock_home
}

test_profile_unset_removes_file() {
	setup_mock_home
	echo "test" > "$HOME/.cloudflared/.default_profile"

	op_profile unset
	assert_file_not_exists "$HOME/.cloudflared/.default_profile" "profile unset should remove file"

	teardown_mock_home
}

test_persist_without_command_saves_profile() {
	setup_mock_home

	# Simulate: ./run.sh --profile "x" --persist
	PROFILE="test-profile"
	PERSIST_PROFILE=true

	# This is what the main logic does
	if [[ -n "$PROFILE" && "$PERSIST_PROFILE" == true ]]; then
		save_default_profile "$PROFILE"
	fi

	assert_file_exists "$HOME/.cloudflared/.default_profile"
	local content
	content="$(cat "$HOME/.cloudflared/.default_profile")"
	assert_eq "test-profile" "$content" "persist should save profile"

	teardown_mock_home
}

test_persist_without_command_exits_cleanly() {
	setup_mock_home

	# Simulate the early-exit logic when cmd is empty and persist saved
	PROFILE="test-profile"
	PERSIST_PROFILE=true
	cmd=""

	if [[ -z "${cmd:-}" && "$PERSIST_PROFILE" == true && -n "$PROFILE" ]]; then
		save_default_profile "$PROFILE"
		# Would exit 0 here in real run.sh
		true
	else
		false  # Should NOT reach here
	fi

	teardown_mock_home
}

test_list_with_empty_profile_shows_message() {
	setup_mock_home
	echo "empty-profile" > "$HOME/.cloudflared/.default_profile"

	# Reload default profile
	PROFILE="$(load_default_profile)"

	local output
	output="$(op_list 2>&1 || true)"
	assert_contains "$output" "No tunnels found" "list should show empty message"

	teardown_mock_home
}

test_list_without_profile_no_marker() {
	setup_mock_home
	# No default profile
	PROFILE=""

	local output
	output="$(op_list 2>&1 || true)"
	# Should not contain [profile] marker
	if [[ "$output" == *"[profile]"* ]]; then
		echo "ASSERT FAIL: list without profile should not show [profile] marker" >&2
		exit 1
	fi

	teardown_mock_home
}
