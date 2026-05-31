#!/usr/bin/env bash
# tests/test_functions.sh — Unit tests for pure functions in run.sh
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Prevent main logic from executing when run.sh is sourced
mock_main

test_slugify_lowercase() {
	local result
	result="$(slugify "Meu Profile")"
	assert_eq "meu-profile" "$result" "slugify lowercase"
}

test_slugify_special_chars() {
	local result
	result="$(slugify "My!@#Profile")"
	assert_eq "my-profile" "$result" "slugify special chars"
}

test_slugify_empty_result() {
	local result
	result="$(slugify "!!!")"
	assert_eq "" "$result" "slugify empty result"
}

test_profile_base_dir_no_profile() {
	PROFILE=""
	local result
	result="$(profile_base_dir)"
	assert_eq "$HOME/.cloudflared" "$result" "profile_base_dir no profile"
}

test_profile_base_dir_with_profile() {
	PROFILE="My Profile"
	local result
	result="$(profile_base_dir)"
	assert_eq "$HOME/.cloudflared/profiles/my-profile" "$result" "profile_base_dir with profile"
}

test_yaml_path_for_no_profile() {
	PROFILE=""
	local result
	result="$(yaml_path_for "api")"
	assert_eq "$HOME/.cloudflared/api.yml" "$result" "yaml_path_for no profile"
}

test_yaml_path_for_with_profile() {
	PROFILE="homelab"
	local result
	result="$(yaml_path_for "api")"
	assert_eq "$HOME/.cloudflared/profiles/homelab/api.yml" "$result" "yaml_path_for with profile"
}

test_instance_unit_no_profile() {
	PROFILE=""
	local result
	result="$(instance_unit "api")"
	assert_eq "cloudflared@api.service" "$result" "instance_unit no profile"
}

test_instance_unit_with_profile() {
	PROFILE="homelab"
	local result
	result="$(instance_unit "api")"
	assert_eq "cloudflared@homelab-api.service" "$result" "instance_unit with profile"
}

test_validate_profile_name_ok() {
	local result
	result="$(validate_profile_name "ok")"
	assert_eq "ok" "$result" "validate_profile_name ok"
}

test_validate_profile_name_invalid() {
	local result exitcode=0
	result="$(validate_profile_name "!!!" 2>/dev/null)" || exitcode=$?
	# validate_profile_name calls die on invalid input, so it should fail
	assert_ne 0 "$exitcode" "validate_profile_name invalid should fail"
}

test_resolve_hostname_with_dig() {
	# If dig is available, test it resolves something
	if command -v dig >/dev/null 2>&1; then
		local result
		result="$(resolve_hostname "cloudflare.com")"
		assert_ne "" "$result" "resolve_hostname dig fallback"
	fi
}

test_resolve_hostname_no_tools() {
	# Temporarily hide dig/host/getent to test fallback
	(
		PATH="/bin:/usr/bin"
		command -v dig >/dev/null 2>&1 && exit 0  # skip if dig is in /bin
		command -v host >/dev/null 2>&1 && exit 0  # skip if host is in /bin
		local result
		result="$(resolve_hostname "nonexistent.local")"
		assert_eq "" "$result" "resolve_hostname no tools should return empty"
	)
}
