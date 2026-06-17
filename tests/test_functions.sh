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

test_zone_base_dir_no_zone() {
	ZONE=""
	local result
	result="$(zone_base_dir)"
	assert_eq "$HOME/.cloudflared" "$result" "zone_base_dir no zone"
}

test_zone_base_dir_with_zone() {
	ZONE="homelaberson.space"
	local result
	result="$(zone_base_dir)"
	assert_eq "$HOME/.cloudflared/zones/homelaberson.space" "$result" "zone_base_dir with zone"
}

test_yaml_path_for_no_zone() {
	ZONE=""
	local result
	result="$(yaml_path_for "api")"
	assert_eq "$HOME/.cloudflared/api.yml" "$result" "yaml_path_for no zone"
}

test_yaml_path_for_with_zone() {
	ZONE="homelaberson.space"
	local result
	result="$(yaml_path_for "api")"
	assert_eq "$HOME/.cloudflared/zones/homelaberson.space/api.yml" "$result" "yaml_path_for with zone"
}

test_instance_unit_no_zone() {
	ZONE=""
	local result
	result="$(instance_unit "api")"
	assert_eq "cloudflared@api.service" "$result" "instance_unit no zone"
}

test_instance_unit_with_zone() {
	ZONE="homelaberson.space"
	local result
	result="$(instance_unit "api")"
	assert_eq "cloudflared@homelaberson.space_api.service" "$result" "instance_unit with zone"
}

test_validate_zone_name_ok() {
	local result
	result="$(validate_zone_name "homelaberson.space")"
	assert_eq "homelaberson.space" "$result" "validate_zone_name ok"
}

test_validate_zone_name_invalid() {
	local result exitcode=0
	result="$(validate_zone_name "" 2>/dev/null)" || exitcode=$?
	# validate_zone_name calls die on invalid input, so it should fail
	assert_ne 0 "$exitcode" "validate_zone_name invalid should fail"
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
