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

test_validate_zone_name_normalizes_canonical_form() {
	local result
	result="$(validate_zone_name "Sub.Example.COM.")"
	assert_eq "sub.example.com" "$result" "zone canonical form"
}

test_validate_zone_name_accepts_punycode_and_boundaries() {
	assert_eq "xn--bcher-kva.de" "$(validate_zone_name "xn--bcher-kva.de")" "punycode zone"

	local label63 total253
	printf -v label63 '%*s' 63 ''
	label63="${label63// /a}"
	total253="${label63}.${label63}.${label63}.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	assert_eq "${label63}.com" "$(validate_zone_name "${label63}.com")" "63-character label"
	assert_eq "$total253" "$(validate_zone_name "$total253")" "253-character zone"
}

test_validate_zone_name_rejects_unsafe_and_invalid_names() {
	local invalid result rc
	local invalid_names=(
		"localhost"
		".example.com"
		"example..com"
		"example.com.."
		"-example.com"
		"example-.com"
		"*.example.com"
		"example_com"
		"https://example.com"
		"example.com:443"
		"example.com/path"
		".."
		"../../outside"
		" example.com"
		"example.com "
		"bücher.de"
	)

	for invalid in "${invalid_names[@]}"; do
		rc=0
		result="$(validate_zone_name "$invalid" 2>&1)" || rc=$?
		assert_ne "0" "$rc" "reject invalid zone: $invalid"
	done
}

test_validate_zone_name_rejects_length_overflow() {
	local label64 label63 total254 result rc=0
	printf -v label64 '%*s' 64 ''
	label64="${label64// /a}"
	result="$(validate_zone_name "${label64}.com" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "reject 64-character label"

	printf -v label63 '%*s' 63 ''
	label63="${label63// /a}"
	total254="${label63}.${label63}.${label63}.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	rc=0
	result="$(validate_zone_name "$total254" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "reject 254-character zone"
}

test_validate_zone_name_invalid() {
	local result exitcode=0
	result="$(validate_zone_name "" 2>/dev/null)" || exitcode=$?
	# validate_zone_name calls die on invalid input, so it should fail
	assert_ne 0 "$exitcode" "validate_zone_name invalid should fail"
}

test_hostname_belongs_to_zone_accepts_apex_subdomains_and_wildcards() {
	hostname_belongs_to_zone "example.com" "example.com" || exit 1
	hostname_belongs_to_zone "app.example.com" "example.com" || exit 1
	hostname_belongs_to_zone "*.example.com" "example.com" || exit 1
	hostname_belongs_to_zone "APP.EXAMPLE.COM." "example.com" || exit 1
}

test_hostname_belongs_to_zone_rejects_cross_zone_names() {
	local hostname
	for hostname in evil-example.com app.other.com example.com.evil .example.com foo\*.example.com a..example.com \
		'*.*.example.com' '-app.example.com' 'app-.example.com' 'app_example.com' 'https://app.example.com'; do
		if hostname_belongs_to_zone "$hostname" "example.com"; then
			echo "ASSERT FAIL: invalid or cross-zone hostname accepted: $hostname" >&2
			exit 1
		fi
	done
}

test_validate_flags_add_accepts_valid_zone_hostnames() {
	sudo() { return 0; }
	ZONE="example.com"
	TYPE="http"
	SERVICE="http://localhost:8080"

	local hostname
	for hostname in example.com app.example.com '*.example.com' APP.EXAMPLE.COM.; do
		TUNNEL_HOSTNAME="$hostname"
		validate_flags_add
	done
}

test_validate_flags_add_rejects_malformed_zone_hostnames_before_any_side_effect() {
	local side_effect_log="$HOME/side-effects.log"
	sudo() { printf '%s\n' sudo >> "$side_effect_log"; }
	cloudflared() { printf '%s\n' cloudflared >> "$side_effect_log"; }
	ensure_template() { printf '%s\n' systemd >> "$side_effect_log"; }
	ensure_zone_dir() { printf '%s\n' yaml >> "$side_effect_log"; }
	resolve_hostname() { printf '%s\n' dns >> "$side_effect_log"; }

	ZONE="example.com"
	TYPE="http"
	SERVICE="http://localhost:8080"
	local hostname output rc
	for hostname in .example.com foo\*.example.com a..example.com '*.*.example.com' '-app.example.com' 'app-.example.com'; do
		TUNNEL_HOSTNAME="$hostname"
		rc=0
		output="$(op_add 2>&1)" || rc=$?
		assert_ne "0" "$rc" "malformed hostname should fail: $hostname"
		assert_contains "$output" "does not belong to zone" "malformed hostname error: $hostname"
		assert_file_not_exists "$side_effect_log" "hostname validation side effects: $hostname"
	done
}

test_validate_flags_add_rejects_cross_zone_hostname_before_sudo() {
	local sudo_log="$HOME/sudo.log"
	sudo() {
		echo called >> "$sudo_log"
		return 0
	}

	ZONE="example.com"
	TUNNEL_HOSTNAME="app.other.com"
	TYPE="http"
	SERVICE="http://localhost:8080"

	local output rc=0
	output="$(validate_flags_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "cross-zone hostname should fail validation"
	assert_contains "$output" "does not belong to zone 'example.com'" "containment error"
	assert_file_not_exists "$sudo_log" "containment must run before sudo"
}

test_resolve_hostname_with_dig() {
	local fixture_bin="$HOME/fixture-bin"
	local fixture_log="$HOME/dig.log"
	mkdir -p "$fixture_bin"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'printf "%s\\n" "$*" > "$CFTUNNEL_DIG_LOG"' \
		'printf "%s\\n" "fixture.example.com." "192.0.2.10"' > "$fixture_bin/dig"
	chmod +x "$fixture_bin/dig"

	local result
	result="$(PATH="$fixture_bin:$PATH" CFTUNNEL_DIG_LOG="$fixture_log" resolve_hostname "app.example.com")"
	assert_eq $'fixture.example.com.\n192.0.2.10' "$result" "resolve_hostname dig output"
	assert_eq "@1.1.1.1 +short app.example.com" "$(cat "$fixture_log")" "resolve_hostname dig arguments"
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
