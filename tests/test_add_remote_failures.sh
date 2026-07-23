#!/usr/bin/env bash
# tests/test_add_remote_failures.sh — Fail-closed add/discovery coverage
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

mock_main

readonly TEST_TUNNEL_UUID="12345678-1234-1234-1234-123456789012"

set_valid_add_input() {
	ZONE=""
	NAME="example-http"
	TUNNEL_HOSTNAME="app.example.com"
	TYPE="http"
	SERVICE="http://localhost:8080"
	NO_DNS=true
}

test_tunnel_uuid_validation_accepts_and_normalizes_uuid() {
	local result
	result="$(validate_tunnel_uuid "12345678-ABCD-4321-ABCD-1234567890AB")"
	assert_eq "12345678-abcd-4321-abcd-1234567890ab" "$result" "normalized tunnel UUID"
}

test_tunnel_uuid_validation_rejects_unsafe_values() {
	local value result rc
	for value in "" "null" "12345678" "../credential" \
		"00000000-0000-0000-0000-000000000000" \
		"12345678-1234-1234-1234-12345678901g" \
		"12345678-1234-1234-1234-123456789012.json"; do
		rc=0
		result="$(validate_tunnel_uuid "$value" 2>&1)" || rc=$?
		assert_ne "0" "$rc" "invalid tunnel UUID: $value"
	done
}

test_discovery_failure_does_not_become_not_found() {
	cloudflared() {
		printf '%s\n' 'resolver failure from cloudflared' >&2
		return 42
	}

	local output rc=0
	output="$(discover_tunnel_uuid "example-http" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "discovery request must fail"
	assert_contains "$output" "resolver failure from cloudflared" "dependency diagnostic"
	assert_contains "$output" "could not query Cloudflare tunnels" "contextual discovery error"
}

test_discovery_nonzero_with_empty_array_still_fails() {
	cloudflared() {
		printf '%s\n' '[]'
		return 42
	}

	local output rc=0
	output="$(discover_tunnel_uuid "example-http" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "non-zero status must override plausible stdout"
	assert_contains "$output" "could not query Cloudflare tunnels" "non-zero status context"
}

test_discovery_rejects_malformed_and_wrong_type_json() {
	local fixture output rc
	for fixture in 'not-json' '{}' 'null'; do
		cloudflared() { printf '%s\n' "$fixture"; }
		rc=0
		output="$(discover_tunnel_uuid "example-http" 2>&1)" || rc=$?
		assert_ne "0" "$rc" "invalid discovery response: $fixture"
		assert_contains "$output" "invalid or ambiguous response" "invalid JSON context"
		assert_not_contains "$output" "$fixture" "remote response secrecy"
	done
}

test_discovery_returns_empty_only_for_successful_empty_result() {
	cloudflared() {
		assert_eq "tunnel list --name example-http --output json" "$*" "exact-name discovery args"
		printf '%s\n' '[]'
	}

	local result
	result="$(discover_tunnel_uuid "example-http")"
	assert_eq "" "$result" "successful absence"
}

test_discovery_reuses_exact_match_and_ignores_unrelated_objects() {
	cloudflared() {
		printf '%s\n' \
			'[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"other"},' \
			' {"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}]'
	}

	local result
	result="$(discover_tunnel_uuid "example-http")"
	assert_eq "$TEST_TUNNEL_UUID" "$result" "existing exact-match UUID"
}

test_discovery_rejects_duplicate_match_and_invalid_uuid() {
	local fixture output rc
	for fixture in \
		'[{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"},{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"example-http"}]' \
		'[{"id":"../credential","name":"example-http"}]'; do
		cloudflared() { printf '%s\n' "$fixture"; }
		rc=0
		output="$(discover_tunnel_uuid "example-http" 2>&1)" || rc=$?
		assert_ne "0" "$rc" "ambiguous or invalid discovery response"
		assert_contains "$output" "invalid or ambiguous response" "ambiguous response context"
		assert_not_contains "$output" "$fixture" "discovery response secrecy"
	done
}

test_discovery_rejects_nonempty_result_without_exact_match() {
	cloudflared() {
		printf '%s\n' \
			'[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"other"}]'
	}

	local output rc=0
	output="$(discover_tunnel_uuid "example-http" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "unexpected filtered result must fail closed"
	assert_contains "$output" "invalid or ambiguous response" "unexpected result context"
}

test_create_uses_structured_output_and_returns_uuid() {
	local call_log="$HOME/cloudflared.calls"
	cloudflared() {
		printf '%s\n' "$*" >> "$call_log"
		printf '%s\n' \
			'{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}'
	}

	local result
	result="$(create_tunnel_uuid "example-http")"
	assert_eq "$TEST_TUNNEL_UUID" "$result" "created tunnel UUID"
	assert_eq "tunnel create --output json example-http" "$(cat "$call_log")" "structured create args"
}

test_create_failure_and_invalid_output_stop_as_uncertain() {
	local scenario output rc
	for scenario in nonzero malformed invalid_uuid wrong_name; do
		case "$scenario" in
		nonzero)
			cloudflared() { printf '%s\n' 'create failed' >&2; return 42; }
			;;
		malformed)
			cloudflared() { printf '%s\n' 'account-data-that-must-not-leak'; }
			;;
		invalid_uuid)
			cloudflared() { printf '%s\n' '{"id":"../credential","name":"example-http"}'; }
			;;
		wrong_name)
			cloudflared() {
				printf '%s\n' \
					'{"id":"12345678-1234-1234-1234-123456789012","name":"other"}'
			}
			;;
		esac

		rc=0
		output="$(create_tunnel_uuid "example-http" 2>&1)" || rc=$?
		assert_ne "0" "$rc" "uncertain create result: $scenario"
		assert_contains "$output" "remote state may have changed" "uncertain create guidance"
		assert_not_contains "$output" "account-data-that-must-not-leak" "create response secrecy"
		assert_not_contains "$output" '"id":"../credential"' "invalid create response secrecy"
	done
}

test_op_add_discovery_failure_has_no_sudo_or_tunnel_side_effects() {
	set_valid_add_input
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		return 42
	}

	local output rc=0
	output="$(printf 'y' | op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "add must stop on discovery failure"
	assert_contains "$output" "could not query Cloudflare tunnels" "add discovery error"
	assert_not_contains "$output" "[+] creating tunnel" "no create announcement"
	assert_eq \
		"cloudflared tunnel list --name example-http --output json" \
		"$(cat "$side_effect_log")" \
		"discovery must precede sudo and local setup"
}

test_op_add_orders_discovery_then_sudo_then_create() {
	set_valid_add_input
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		case "$*" in
		"tunnel list --name example-http --output json")
			printf '%s\n' '[]'
			;;
		"tunnel create --output json example-http")
			printf '%s\n' \
				'{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}'
			;;
		esac
	}

	local output rc=0
	output="$(printf 'y' | op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "fixture intentionally stops at missing credentials"
	assert_contains "$output" "credentials not found" "expected post-create stop"
	assert_eq \
		$'cloudflared tunnel list --name example-http --output json\nsudo -v\ncloudflared tunnel create --output json example-http\nensure-zone' \
		"$(cat "$side_effect_log")" \
		"safe add side-effect order"
}

test_op_add_sudo_failure_stops_before_create() {
	set_valid_add_input
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 1; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		printf '%s\n' '[]'
	}

	local output rc=0
	output="$(printf 'y' | op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "sudo failure must stop add"
	assert_contains "$output" "needs sudo permission" "sudo failure context"
	assert_eq \
		$'cloudflared tunnel list --name example-http --output json\nsudo -v' \
		"$(cat "$side_effect_log")" \
		"sudo failure must precede create and local setup"
}

test_op_add_existing_tunnel_uses_one_discovery_call() {
	set_valid_add_input
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		printf '%s\n' \
			'[{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}]'
	}

	local output rc=0
	output="$(printf 'y' | op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "fixture intentionally stops at missing credentials"
	assert_contains "$output" "already exists (ok)" "existing tunnel path"
	assert_contains "$output" "credentials not found" "expected post-discovery stop"
	assert_eq \
		$'cloudflared tunnel list --name example-http --output json\nsudo -v\nensure-zone' \
		"$(cat "$side_effect_log")" \
		"existing tunnel must not be listed twice or created"
}

test_help_does_not_probe_cloudflare() {
	local fake_bin="$HOME/fake-bin"
	local probe_log="$HOME/cloudflared-probe.log"
	mkdir -p "$fake_bin"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'if [[ "${1:-}" == "passwd" ]]; then' \
		'  printf "%s:x:1000:1000::%s:/bin/bash\\n" "$2" "$HOME"' \
		'fi' > "$fake_bin/getent"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'printf "%s\\n" "$*" >> "$CFTUNNEL_PROBE_LOG"' > "$fake_bin/cloudflared"
	chmod +x "$fake_bin/getent" "$fake_bin/cloudflared"

	local output rc=0
	output="$(PATH="$fake_bin:$PATH" RUN_USER=cftunnel-test USER=cftunnel-test \
		CFTUNNEL_SKIP_MAIN=0 CFTUNNEL_PROBE_LOG="$probe_log" \
		bash "$PROJECT_DIR/run.sh" --help 2>&1)" || rc=$?
	assert_eq "0" "$rc" "help exit status"
	assert_contains "$output" "Usage:" "help output"
	assert_file_not_exists "$probe_log" "help must not probe Cloudflare"
}
