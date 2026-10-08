#!/usr/bin/env bash
# tests/test_contracts.sh — Read-only machine contract tests

source "$PROJECT_DIR/tests/runner-lib.sh"

mock_main

write_contract_fixture() {
	local zone="$1" name="$2" uuid="$3" hostname="$4" service="$5"
	local dir="$HOME/.cloudflared/zones/$zone"
	mkdir -p "$dir"
	printf '%s\n' \
		"tunnel: $uuid" \
		"credentials-file: $dir/$uuid.json" \
		"ingress:" \
		"  - hostname: \"$hostname\"" \
		"    service: \"$service\"" \
		"  - service: http_status:404" > "$dir/$name.yml"
}

test_capabilities_json_is_offline_and_versioned() {
	local output
	output="$(CFTUNNEL_SKIP_MAIN="" "$PROJECT_DIR/run.sh" capabilities --output json)"
	assert_eq "1" "$(jq -r '.schema_version' <<< "$output")" "schema version"
	assert_eq "capabilities" "$(jq -r '.operation' <<< "$output")" "operation"
	assert_eq "true" "$(jq -r '.data.operations["tunnel.health"].json' <<< "$output")" "health capability"
	assert_eq "true" "$(jq -r '.data.operations["zone.list"].json' <<< "$output")" "zone list capability"
}

test_zone_json_contracts_preserve_machine_output() {
	setup_mock_home
	OUTPUT_FORMAT=json

	local use_output current_output unset_output
	use_output="$(op_zone use "Example.COM.")"
	assert_eq "zone.use" "$(jq -r '.operation' <<< "$use_output")" "zone use operation"
	assert_eq "example.com" "$(jq -r '.data.zone' <<< "$use_output")" "canonical zone"

	current_output="$(op_zone current)"
	assert_eq "example.com" "$(jq -r '.data.default_zone' <<< "$current_output")" "current default"

	unset_output="$(op_zone unset)"
	assert_eq "example.com" "$(jq -r '.data.previous_default_zone' <<< "$unset_output")" "previous default"
	assert_eq "null" "$(jq -r '.data.default_zone' <<< "$unset_output")" "unset default"

	teardown_mock_home
}

test_list_json_contract_is_local_and_groups_routes_by_tunnel() {
	setup_mock_home
	OUTPUT_FORMAT=json
	ZONE="example.com"
	write_contract_fixture "example.com" "api" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "api.example.com" "http://localhost:8080"
	cloudflared() { return 99; }
	systemctl() { return 1; }

	local output
	output="$(op_list)"
	assert_eq "tunnel.list" "$(jq -r '.operation' <<< "$output")" "list operation"
	assert_eq "example.com" "$(jq -r '.data.scope_zone' <<< "$output")" "list scope"
	assert_eq "1" "$(jq -r '.data.tunnels | length' <<< "$output")" "one tunnel"
	assert_eq "api.example.com" "$(jq -r '.data.tunnels[0].routes[0].hostname' <<< "$output")" "route hostname"
	assert_eq "true" "$(jq -r '.data.tunnels[0].config.yaml.present' <<< "$output")" "yaml presence"
	assert_eq "false" "$(jq -r '.data.tunnels[0].config.credential.present' <<< "$output")" "credential absence"
	assert_eq "true" "$(jq -r '.data.tunnels[0].config.issues | length > 0' <<< "$output")" "configuration issue is surfaced"
	assert_contains "$(jq -r '.data.listed_at' <<< "$output")" "T" "inventory timestamp"

	teardown_mock_home
}

test_zone_list_json_discovers_empty_registered_zones() {
	setup_mock_home
	OUTPUT_FORMAT=json
	ZONE=""
	write_contract_fixture "example.com" "api" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "api.example.com" "http://localhost:8080"
	mkdir -p "$HOME/.cloudflared/zones/empty.example"
	printf '%s\n' "example.com" > "$HOME/.cloudflared/.default_zone"
	chmod 600 "$HOME/.cloudflared/.default_zone"
	cloudflared() { return 99; }
	systemctl() { return 1; }

	local output
	output="$(op_zone list)"
	assert_eq "zone.list" "$(jq -r '.operation' <<< "$output")" "zone list operation"
	assert_eq "2" "$(jq -r '.data.zones | length' <<< "$output")" "registered zones include empty zone"
	assert_eq "0" "$(jq -r '.data.zones[] | select(.name == "empty.example") | .tunnel_count' <<< "$output")" "empty zone tunnel count"
	assert_eq "missing" "$(jq -r '.data.zones[] | select(.name == "empty.example") | .credential.state' <<< "$output")" "missing credential state"
	assert_eq "true" "$(jq -r '.data.zones[] | select(.name == "example.com") | .is_default' <<< "$output")" "default marker"

	teardown_mock_home
}

test_all_zones_list_json_aggregates_local_routes() {
	setup_mock_home
	OUTPUT_FORMAT=json
	ZONE=""
	write_contract_fixture "one.example" "api" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "api.one.example" "http://localhost:8080"
	write_contract_fixture "two.example" "web" "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" "web.two.example" "http://localhost:8081"
	cloudflared() { return 99; }
	systemctl() { return 1; }

	local output
	output="$(op_list)"
	assert_eq "null" "$(jq -r '.data.scope_zone' <<< "$output")" "aggregate scope"
	assert_eq "2" "$(jq -r '.data.tunnels | length' <<< "$output")" "aggregate tunnel count"

	teardown_mock_home
}

test_status_json_never_requests_sudo() {
	OUTPUT_FORMAT=json
	ZONE="example.com"
	NAME="api"
	local sudo_log="$HOME/sudo.log"
	sudo() { printf '%s\n' "$*" >> "$sudo_log"; return 0; }
	systemctl() {
		[[ "${1:-}" == "is-active" ]] && return 0
		return 1
	}

	local output
	output="$(op_status)"
	assert_eq "active" "$(jq -r '.data.status' <<< "$output")" "active status"
	assert_file_not_exists "$sudo_log" "status must not invoke sudo"
}

test_health_json_uses_local_systemd_and_dns_without_cloudflare() {
	setup_mock_home
	OUTPUT_FORMAT=json
	ZONE="example.com"
	write_contract_fixture "example.com" "api" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "api.example.com" "http://localhost:8080"
	cloudflared() { printf '%s\n' called >&2; return 99; }
	systemctl() { return 1; }
	resolve_hostname() { printf '%s\n' '198.51.100.7'; }
	has_cname_lookup() { return 1; }

	local output
	output="$(op_health)"
	assert_eq "tunnel.health" "$(jq -r '.operation' <<< "$output")" "health operation"
	assert_eq "198.51.100.7" "$(jq -r '.data.tunnels[0].routes[0].dns.result' <<< "$output")" "dns observation"
	assert_eq "false" "$(jq -r '.data.tunnels[0].routes[0].dns.cname_check_available' <<< "$output")" "cname availability"

	teardown_mock_home
}

test_privilege_check_is_non_interactive() {
	OUTPUT_FORMAT=json
	sudo() { return 1; }

	local output
	output="$(op_privilege_check)"
	assert_eq "false" "$(jq -r '.data.available' <<< "$output")" "unavailable sudo cache"
	assert_eq "sudo_auth_required" "$(jq -r '.data.reason' <<< "$output")" "sudo reason"
}

test_hostname_add_plan_is_local_and_identifies_reused_tunnel_restart() {
	setup_mock_home
	OUTPUT_FORMAT=json
	ZONE="example.com"
	NAME="example-http"
	TUNNEL_HOSTNAME="app.example.com"
	TYPE="http"
	SERVICE="http://localhost:8080"
	write_contract_fixture "example.com" "example-http" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "old.example.com" "http://localhost:8000"
	cloudflared() { printf '%s\n' called >&2; return 99; }

	local output
	output="$(op_add_plan)"
	assert_eq "hostname.add.plan" "$(jq -r '.operation' <<< "$output")" "hostname plan operation"
	assert_eq "example-http" "$(jq -r '.data.tunnel_name' <<< "$output")" "recommended tunnel name"
	assert_eq "true" "$(jq -r '.data.existing_tunnel' <<< "$output")" "existing tunnel is detected"
	assert_eq "true" "$(jq -r '.data.restart_required' <<< "$output")" "existing tunnel requires restart"
	assert_eq "true" "$(jq -r '.data.privilege.sudo_required' <<< "$output")" "plan exposes sudo requirement"

	teardown_mock_home
}

test_hostname_plan_accepts_https_origins_for_http_type() {
	ZONE="example.com"
	NAME=""
	TUNNEL_HOSTNAME="secure.example.com"
	TYPE="http"
	SERVICE="https://localhost:8443"
	OUTPUT_FORMAT=json
	local output
	output="$(op_add_plan)"
	assert_eq "https://localhost:8443" "$(jq -r '.data.service' <<< "$output")" "https origin is preserved"
}

test_hostname_remove_plan_is_local_and_leaves_dns_unchanged() {
	setup_mock_home
	OUTPUT_FORMAT=json
	ZONE="example.com"
	REMOVE_HOSTNAME="remove.example.com"
	REMOVE_PLAN=true
	mkdir -p "$HOME/.cloudflared/zones/example.com"
	printf '%s\n' \
		'ingress:' \
		'  - hostname: "remove.example.com"' \
		'    service: "http://localhost:8080"' \
		'  - hostname: "keep.example.com"' \
		'    service: "http://localhost:8081"' \
		'  - service: http_status:404' > "$HOME/.cloudflared/zones/example.com/example-http.yml"
	local output
	output="$(op_hostname_remove)"
	assert_eq "hostname.remove.plan" "$(jq -r '.operation' <<< "$output")" "hostname removal operation"
	assert_eq "remove.example.com" "$(jq -r '.data.hostname' <<< "$output")" "hostname removal target"
	assert_eq "unchanged" "$(jq -r '.data.dns.action' <<< "$output")" "DNS is explicitly unchanged"
	assert_eq "1" "$(jq -r '.data.remaining_hostname_count' <<< "$output")" "one route remains"
	teardown_mock_home
}

test_tui_dev_launches_checkout_tui_with_source_cli() {
	local fake_bin="$HOME/fake-bin" launch_log="$HOME/tui-launch.log"
	mkdir -p "$fake_bin"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'if [[ "$1" == "--version" ]]; then printf "%s\\n" "1.3.14"; exit 0; fi' \
		'printf "%s|%s\n" "$CFTUNNEL_BIN" "$*" > "$CFTUNNEL_TUI_LAUNCH_LOG"' > "$fake_bin/bun"
	chmod +x "$fake_bin/bun"

	PATH="$fake_bin:$PATH" CFTUNNEL_TUI_TEST_MODE=1 CFTUNNEL_TUI_LAUNCH_LOG="$launch_log" RUN_USER="cftunnel-test-user-that-does-not-exist" \
		"$PROJECT_DIR/run.sh" tui-dev
	assert_eq "$PROJECT_DIR/run.sh|run $PROJECT_DIR/packages/tui/src/index.tsx" "$(cat "$launch_log")" "tui-dev command boundary"
}

test_log_zone_filter_and_text_output() {
	if [[ ! -x "$PROJECT_DIR/packages/tui/dist/cftunnel-runtime" ]] && ! command -v bun >/dev/null 2>&1; then
		echo "log runtime integration requires Bun or a compiled release runtime; skipped"
		return
	fi
	local output
	RUN_USER="cftunnel-test-user-that-does-not-exist" "$PROJECT_DIR/run.sh" log write --zone example.com --type system --level info --message 'example.com event'
	RUN_USER="cftunnel-test-user-that-does-not-exist" "$PROJECT_DIR/run.sh" log write --zone example.net --type system --level info --message 'example.net event'
	output="$(RUN_USER="cftunnel-test-user-that-does-not-exist" "$PROJECT_DIR/run.sh" log query --zone example.com --output json)"
	jq -e '[.data.events[].message] == ["example.com event"]' <<< "$output" >/dev/null
	output="$(RUN_USER="cftunnel-test-user-that-does-not-exist" "$PROJECT_DIR/run.sh" log query --zone example.net --output text)"
	assert_contains "$output" 'example.net event'
	assert_not_contains "$output" 'example.com event'
	assert_not_contains "$output" '"schema_version"'
}

test_tui_production_command_reports_missing_runtime_in_source_checkout() {
	local runtime="$PROJECT_DIR/packages/tui/dist/cftunnel-runtime"
	if [[ -e "$runtime" ]]; then
		verify_cftunnel_runtime "$PROJECT_DIR" "$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")" >/dev/null
		return
	fi
	local output rc=0
	output="$(RUN_USER="cftunnel-test-user-that-does-not-exist" "$PROJECT_DIR/run.sh" tui 2>&1)" || rc=$?
	assert_ne "0" "$rc" "production TUI must fail when bundled runtime is absent"
	assert_contains "$output" "production TUI runtime is missing" "production TUI installation guidance"
}
