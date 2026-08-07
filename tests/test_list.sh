#!/usr/bin/env bash
# tests/test_list.sh — Local zone ingress listing tests
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Listing status is local metadata. Keep it deterministic and independent of
# the host's systemd state for every test in this file.
systemctl() {
	case "${1:-}" in
	is-active) return 0 ;;
	is-enabled) return 1 ;;
	*) return 0 ;;
	esac
}

# The pre-change implementation calls this and receives no account tunnels.
# The dedicated local-only test below replaces it with a call-recording failure.
cloudflared() {
	printf '%s\n' '[]'
}

write_list_fixture() {
	local zone="$1"
	local name="$2"
	local uuid="$3"
	shift 3

	local dir="$HOME/.cloudflared/zones/$zone"
	local yaml="$dir/$name.yml"
	mkdir -p "$dir"

	printf '%s\n' \
		"tunnel: $uuid" \
		"credentials-file: $dir/$uuid.json" \
		"" \
		"ingress:" > "$yaml"

	while [[ $# -gt 0 ]]; do
		local hostname="$1"
		local service="$2"
		shift 2
		printf '%s\n' \
			"  - hostname: \"$hostname\"" \
			"    service: \"$service\"" >> "$yaml"
	done

	printf '%s\n' "  - service: http_status:404" >> "$yaml"
}

test_list_prints_every_ingress_route() {
	setup_mock_home
	ZONE="homelaberson.space"

	write_list_fixture \
		"homelaberson.space" \
		"homelaberson-space-http" \
		"11111111-1111-1111-1111-111111111111" \
		"api.homelaberson.space" "http://localhost:9004" \
		"webhook-asaas.homelaberson.space" "http://localhost:8089" \
		"git.homelaberson.space" "https://127.0.0.1:443" \
		"homelaberson.space" "https://127.0.0.1:443" \
		"*.homelaberson.space" "https://127.0.0.1:443"

	local output
	output="$(op_list 2>&1)"

	assert_contains "$output" "api.homelaberson.space" "list should include api hostname"
	assert_contains "$output" "webhook-asaas.homelaberson.space" "list should not truncate long hostnames"
	assert_contains "$output" "git.homelaberson.space" "list should include git hostname"
	assert_contains "$output" "homelaberson.space" "list should include apex hostname"
	assert_contains "$output" "*.homelaberson.space" "list should preserve wildcard hostname"

	local row_count
	row_count="$(printf '%s\n' "$output" | grep -c 'homelaberson-space-http')"
	assert_eq "5" "$row_count" "one tunnel with five routes should print five rows"

	local git_row
	git_row="$(printf '%s\n' "$output" | awk '$3 == "git.homelaberson.space" { print }')"
	assert_contains "$git_row" "https" "hostname should use its associated service protocol"

	if [[ "$output" == *"http_status:404"* ]]; then
		echo "ASSERT FAIL [catch-all]: fallback ingress must not be listed" >&2
		exit 1
	fi

	teardown_mock_home
}

test_list_active_zone_excludes_other_zones() {
	setup_mock_home
	ZONE="alpha.example"

	write_list_fixture \
		"alpha.example" "alpha-http" \
		"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
		"api.alpha.example" "http://localhost:8080"
	write_list_fixture \
		"beta.example" "beta-http" \
		"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" \
		"api.beta.example" "http://localhost:9090"

	local output
	output="$(op_list 2>&1)"

	assert_contains "$output" "api.alpha.example" "active zone route should be listed"
	if [[ "$output" == *"api.beta.example"* ]]; then
		echo "ASSERT FAIL [zone isolation]: inactive zone route was listed" >&2
		exit 1
	fi

	teardown_mock_home
}

test_list_without_zone_aggregates_zones_and_ignores_root() {
	setup_mock_home
	ZONE=""

	# Create in reverse lexical order to verify deterministic zone sorting.
	write_list_fixture \
		"zeta.example" "zeta-http" \
		"zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz" \
		"app.zeta.example" "http://localhost:9000"
	write_list_fixture \
		"alpha.example" "alpha-http" \
		"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
		"app.alpha.example" "tcp://localhost:6379"

	printf '%s\n' \
		"tunnel: ignored-root" \
		"ingress:" \
		'  - hostname: "ignored.root.example"' \
		'    service: "http://localhost:7000"' \
		"  - service: http_status:404" > "$HOME/.cloudflared/ignored.yml"

	local output
	output="$(op_list 2>&1)"

	assert_contains "$output" "app.alpha.example" "all-zone list should include alpha"
	assert_contains "$output" "app.zeta.example" "all-zone list should include zeta"
	assert_contains "$output" "@alpha.example_alpha-http.service" "unit should use YAML parent zone"
	assert_contains "$output" "@zeta.example_zeta-http.service" "unit should use YAML parent zone"
	if [[ "$output" == *"ignored.root.example"* ]]; then
		echo "ASSERT FAIL [root exclusion]: root-level YAML was listed" >&2
		exit 1
	fi

	local host_order
	host_order="$(printf '%s\n' "$output" | awk '$3 ~ /^app\.(alpha|zeta)\.example$/ { print $3 }')"
	assert_eq $'app.alpha.example\napp.zeta.example' "$host_order" "all-zone output should be sorted"

	teardown_mock_home
}

test_list_empty_scope_messages_exit_zero() {
	setup_mock_home
	ZONE="empty.example"

	local output
	output="$(op_list 2>&1)"
	assert_contains "$output" "No hostname routes found in zone 'empty.example'." "active empty zone message"

	ZONE=""
	output="$(op_list 2>&1)"
	assert_contains "$output" "No hostname routes found in configured zones." "all-zone empty message"

	teardown_mock_home
}

test_list_never_calls_cloudflared() {
	setup_mock_home
	ZONE="alpha.example"
	write_list_fixture \
		"alpha.example" "alpha-http" \
		"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
		"app.alpha.example" "http://localhost:8080"

	local call_log="$HOME/cloudflared.calls"
	cloudflared() {
		printf '%s\n' "$*" >> "$call_log"
		return 99
	}

	op_list >/dev/null

	if [[ -e "$call_log" ]]; then
		echo "ASSERT FAIL [local only]: cloudflared was called: $(<"$call_log")" >&2
		exit 1
	fi

	teardown_mock_home
}

test_list_does_not_require_jq() {
	setup_mock_home
	ZONE="alpha.example"
	write_list_fixture \
		"alpha.example" "alpha-http" \
		"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
		"app.alpha.example" "http://localhost:8080"

	need() {
		if [[ "${1:-}" == "jq" ]]; then
			return 99
		fi
		return 0
	}

	local output
	output="$(op_list 2>&1)"
	assert_contains "$output" "app.alpha.example" "list should work without jq"

	teardown_mock_home
}
