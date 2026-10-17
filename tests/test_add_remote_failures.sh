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
		"12345678-1234-1234-1234-123456789012.json" \
		"1234567é-1234-1234-1234-123456789012"; do
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
	for fixture in 'not-json' '{}'; do
		cloudflared() { printf '%s\n' "$fixture"; }
		rc=0
		output="$(discover_tunnel_uuid "example-http" 2>&1)" || rc=$?
		assert_ne "0" "$rc" "invalid discovery response: $fixture"
		assert_contains "$output" "Cannot safely determine" "invalid JSON context"
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

test_discovery_treats_successful_null_as_empty_current_cloudflared_result() {
	cloudflared() {
		printf '%s\n' 'null'
	}

	local result
	result="$(discover_tunnel_uuid "example-http")"
	assert_eq "" "$result" "successful null absence"
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
		assert_contains "$output" "Cannot safely determine" "ambiguous response context"
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
	assert_contains "$output" "none matched the requested name exactly" "unexpected result context"
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

test_op_add_reuses_discovered_tunnel_when_local_credential_exists() {
	set_valid_add_input
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	hostname() { printf '%s\n' 'server-b'; }
	mkdir -p "$BASE_DIR"
	: > "$BASE_DIR/$TEST_TUNNEL_UUID.json"
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		case "$*" in
		"tunnel list --name example-http --output json")
			printf '%s\n' \
				'[{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}]'
			;;
		esac
	}

	local output rc=0 log
	output="$(printf 'y' | op_add 2>&1)" || rc=$?
	assert_eq "0" "$rc" "local credential reuse must succeed"
	assert_contains "$output" "already exists (ok)" "existing tunnel reuse"
	assert_not_contains "$output" "this host needs its own tunnel" "no cross-host conflict notice"
	log="$(cat "$side_effect_log")"
	assert_contains "$log" "tunnel list --name example-http --output json" "single exact-name discovery"
	assert_not_contains "$log" "example-http-server-b" "no host-scoped probe when the credential is local"
}

test_op_add_cross_host_conflict_uses_host_scoped_name() {
	set_valid_add_input
	ADD_YES=true
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	hostname() { printf '%s\n' 'Server-B'; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		case "$*" in
		"tunnel list --name example-http --output json")
			printf '%s\n' \
				'[{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}]'
			;;
		"tunnel list --name example-http-server-b --output json")
			printf '%s\n' '[]'
			;;
		"tunnel create --output json example-http-server-b")
			printf '%s\n' \
				'{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"example-http-server-b"}'
			;;
		esac
	}

	local output rc=0
	output="$(op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "fixture intentionally stops at missing credentials"
	assert_contains "$output" "already exists in this Cloudflare account" "cross-host notice"
	assert_contains "$output" "separate tunnel for this host: 'example-http-server-b'" "automatic host-scoped name"
	assert_eq \
		$'cloudflared tunnel list --name example-http --output json\ncloudflared tunnel list --name example-http-server-b --output json\nsudo -v\ncloudflared tunnel create --output json example-http-server-b\nensure-zone' \
		"$(cat "$side_effect_log")" \
		"host-scoped discovery/create order"
}

test_op_add_reports_explicit_command_when_host_scoped_name_is_taken() {
	set_valid_add_input
	ADD_YES=true
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	hostname() { printf '%s\n' 'server-b'; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		case "$*" in
		"tunnel list --name example-http --output json")
			printf '%s\n' \
				'[{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}]'
			;;
		"tunnel list --name example-http-server-b --output json")
			printf '%s\n' \
				'[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"example-http-server-b"}]'
			;;
		esac
	}

	local output rc=0
	output="$(op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "must fail closed when the host-scoped name is taken"
	assert_contains "$output" "'example-http-server-b', is also already taken" "host-scoped collision report"
	assert_contains "$output" "add --hostname app.example.com --type http --service http://localhost:8080 --no-dns --name <choose-a-name>" "explicit re-run command"
	assert_not_contains "$output" "[+] creating tunnel" "no tunnel created"
	assert_eq \
		$'cloudflared tunnel list --name example-http --output json\ncloudflared tunnel list --name example-http-server-b --output json' \
		"$(cat "$side_effect_log")" \
		"host-scoped collision must stop before sudo or create"
}

test_op_add_cross_host_conflict_declined_stops_before_sudo() {
	set_valid_add_input
	ADD_YES=false
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	hostname() { printf '%s\n' 'server-b'; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		case "$*" in
		"tunnel list --name example-http --output json")
			printf '%s\n' \
				'[{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}]'
			;;
		"tunnel list --name example-http-server-b --output json")
			printf '%s\n' '[]'
			;;
		esac
	}

	local output rc=0
	output="$(printf 'yn' | op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "declining the host-scoped name must stop add"
	assert_contains "$output" "Aborted. Choose an explicit name and re-run:" "decline guidance"
	assert_contains "$output" "--name example-http-server-b" "suggested name in the re-run command"
	assert_not_contains "$output" "[+] creating tunnel" "no tunnel created after decline"
}

test_op_add_cross_host_conflict_accepted_creates_host_scoped_tunnel() {
	set_valid_add_input
	ADD_YES=false
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf '%s\n' ensure-zone >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	hostname() { printf '%s\n' 'server-b'; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		case "$*" in
		"tunnel list --name example-http --output json")
			printf '%s\n' \
				'[{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}]'
			;;
		"tunnel list --name example-http-server-b --output json")
			printf '%s\n' '[]'
			;;
		"tunnel create --output json example-http-server-b")
			printf '%s\n' \
				'{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"example-http-server-b"}'
			;;
		esac
	}

	local output rc=0
	output="$(printf 'yy' | op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "fixture intentionally stops at missing credentials"
	assert_contains "$output" "using tunnel name 'example-http-server-b'" "accepted host-scoped name"
	assert_eq \
		$'cloudflared tunnel list --name example-http --output json\ncloudflared tunnel list --name example-http-server-b --output json\nsudo -v\ncloudflared tunnel create --output json example-http-server-b\nensure-zone' \
		"$(cat "$side_effect_log")" \
		"accepted conflict order"
}

test_dns_preflight_skips_without_no_dns_or_lookup_tooling() {
	TUNNEL_HOSTNAME="app.example.com"
	UUID=""
	NO_DNS=true
	local rc=0
	op_add_dns_preflight || rc=$?
	assert_eq 0 "$rc" "NO_DNS must skip the preflight"

	NO_DNS=false
	has_cname_lookup() { return 1; }
	resolve_hostname() { printf '%s\n' 'should-not-be-called'; }
	local output
	output="$(op_add_dns_preflight 2>&1)" || rc=$?
	assert_eq 0 "$rc" "missing dig/host must not block add"
	assert_contains "$output" "skipping the pre-create DNS ownership check" "missing-tool note"
	assert_not_contains "$output" "should-not-be-called" "no lookup without a CNAME tool"
}

test_dns_preflight_blocks_hostname_owned_by_another_tunnel() {
	TUNNEL_HOSTNAME="app.example.com"
	UUID=""
	NO_DNS=false
	has_cname_lookup() { return 0; }
	resolve_hostname() { printf '%s\n' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.cfargotunnel.com.'; }

	local output rc=0
	output="$(op_add_dns_preflight 2>&1)" || rc=$?
	assert_ne 0 "$rc" "a foreign tunnel owner must block the preflight"
	assert_contains "$output" "already served by another tunnel (aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)" "owner reported"
}

test_dns_preflight_allows_hostname_owned_by_this_tunnel() {
	TUNNEL_HOSTNAME="app.example.com"
	UUID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
	NO_DNS=false
	has_cname_lookup() { return 0; }
	resolve_hostname() { printf '%s\n' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.cfargotunnel.com.'; }

	local rc=0
	op_add_dns_preflight || rc=$?
	assert_eq 0 "$rc" "the tunnel that owns the hostname must pass the preflight"
}

test_dns_preflight_ignores_non_tunnel_records() {
	TUNNEL_HOSTNAME="app.example.com"
	UUID=""
	NO_DNS=false
	has_cname_lookup() { return 0; }
	resolve_hostname() { printf '%s\n' '198.51.100.7'; }

	local rc=0
	op_add_dns_preflight || rc=$?
	assert_eq 0 "$rc" "a non-tunnel record must not be treated as a conflict"
}

test_rollback_created_add_removes_remote_and_local_artifacts() {
	local log="$HOME/rollback.log"
	cloudflared() { printf 'cloudflared %s\n' "$*" >> "$log"; return 0; }
	local yaml="$HOME/example-http.yml" creds="$HOME/$TEST_TUNNEL_UUID.json"
	: > "$yaml"
	: > "$creds"

	local rc=0
	rollback_created_add "$TEST_TUNNEL_UUID" "$yaml" "$creds" false || rc=$?
	assert_eq 0 "$rc" "rollback must not report failure on success"
	assert_file_not_exists "$yaml" "rollback removes the YAML"
	assert_file_not_exists "$creds" "rollback removes the credential"
	assert_contains "$(cat "$log")" "cloudflared tunnel delete $TEST_TUNNEL_UUID" "remote tunnel deletion"
}

test_rollback_created_add_reports_manual_cleanup_when_delete_fails() {
	cloudflared() { return 1; }
	local yaml="$HOME/example-http.yml" creds="$HOME/$TEST_TUNNEL_UUID.json"
	: > "$yaml"
	: > "$creds"

	local output rc=0
	output="$(rollback_created_add "$TEST_TUNNEL_UUID" "$yaml" "$creds" false 2>&1)" || rc=$?
	assert_eq 0 "$rc" "rollback still completes after reporting"
	assert_contains "$output" "could not delete tunnel" "manual cleanup guidance"
	assert_contains "$output" "cloudflared tunnel delete $TEST_TUNNEL_UUID" "manual cleanup command"
	assert_file_not_exists "$creds" "credential is removed locally even when deletion fails"
}

test_op_add_rolls_back_created_tunnel_when_dns_step_fails() {
	set_valid_add_input
	ADD_YES=true
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { mkdir -p "$(zone_base_dir)"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	op_add_route_dns() { return 1; }
	mkdir -p "$HOME/.cloudflared"
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		case "$*" in
		"tunnel list --name example-http --output json")
			printf '%s\n' '[]'
			;;
		"tunnel create --output json example-http")
			: > "$HOME/.cloudflared/$TEST_TUNNEL_UUID.json"
			printf '%s\n' \
				'{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}'
			;;
		esac
	}

	local output rc=0
	output="$(op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "DNS failure must fail the add"
	assert_contains "$output" "rolling back this run's changes" "rollback notice"
	assert_file_not_exists "$HOME/.cloudflared/$TEST_TUNNEL_UUID.json" "created credential removed"
	assert_file_not_exists "$HOME/.cloudflared/example-http.yml" "created YAML removed"
	assert_contains "$(cat "$side_effect_log")" "cloudflared tunnel delete $TEST_TUNNEL_UUID" "remote rollback"
}

test_op_add_keeps_preexisting_tunnel_when_dns_step_fails() {
	set_valid_add_input
	ADD_YES=true
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { mkdir -p "$(zone_base_dir)"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	op_add_route_dns() { return 1; }
	mkdir -p "$HOME/.cloudflared"
	: > "$HOME/.cloudflared/$TEST_TUNNEL_UUID.json"
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		case "$*" in
		"tunnel list --name example-http --output json")
			printf '%s\n' \
				'[{"id":"12345678-1234-1234-1234-123456789012","name":"example-http"}]'
			;;
		esac
	}

	local output rc=0
	output="$(op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "DNS failure must fail the add"
	assert_not_contains "$output" "rolling back this run's changes" "no rollback for a pre-existing tunnel"
	assert_file_exists "$HOME/.cloudflared/$TEST_TUNNEL_UUID.json" "existing credential preserved"
	assert_not_contains "$(cat "$side_effect_log")" "tunnel delete" "no remote deletion for a pre-existing tunnel"
}

test_op_add_preflight_blocks_before_sudo() {
	set_valid_add_input
	NO_DNS=false
	ADD_YES=true
	local side_effect_log="$HOME/side-effects.log"
	need() { return 0; }
	ensure_template() { return 0; }
	ensure_zone_dir() { printf 'ensure-zone\n' >> "$side_effect_log"; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	has_cname_lookup() { return 0; }
	resolve_hostname() { printf '%s\n' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.cfargotunnel.com.'; }
	cloudflared() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		printf '%s\n' '[]'
	}

	local output rc=0
	output="$(op_add 2>&1)" || rc=$?
	assert_ne "0" "$rc" "a foreign hostname owner must stop add"
	assert_contains "$output" "already served by another tunnel" "preflight message"
	assert_eq \
		"cloudflared tunnel list --name example-http --output json" \
		"$(cat "$side_effect_log")" \
		"preflight must run before sudo and create"
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
