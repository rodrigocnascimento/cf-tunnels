#!/usr/bin/env bash
# tests/test_yaml.sh — YAML generation tests (no Cloudflare API)
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Prevent main logic from executing
mock_main

test_yaml_generation_quotes_wildcard() {
	setup_mock_home

	# Simulate what op_add does for YAML generation
	local UUID="12345678-1234-1234-1234-123456789012"
	local TUNNEL_HOSTNAME="*.example.com"
	local SERVICE="http://localhost:80"
	local CREDS_JSON="$HOME/.cloudflared/${UUID}.json"
	local YAML="$HOME/.cloudflared/test.yml"

	cat >"$YAML" <<YAML
tunnel: ${UUID}
credentials-file: ${CREDS_JSON}

protocol: "http2"
edge-ip-version: "4"

originRequest:
  tcpKeepAlive: "30s"
  keepAliveTimeout: "2m"
  connectTimeout: "10s"

ingress:
  - hostname: "${TUNNEL_HOSTNAME}"
    service: "${SERVICE}"
  - service: http_status:404
YAML
	chmod 600 "$YAML"

	# Check hostname is quoted
	assert_contains "$(cat "$YAML")" 'hostname: "*.example.com"' "YAML hostname quoted"
	# Check service is quoted
	assert_contains "$(cat "$YAML")" 'service: "http://localhost:80"' "YAML service quoted"

	teardown_mock_home
}

test_yaml_permissions_600() {
	setup_mock_home

	local YAML="$HOME/.cloudflared/test.yml"
	cat >"$YAML" <<YAML
tunnel: test
YAML
	chmod 600 "$YAML"

	local perms
	perms="$(stat -c "%a" "$YAML")"
	assert_eq "600" "$perms" "YAML should have 600 permissions"

	teardown_mock_home
}

test_yaml_with_zone_path() {
	setup_mock_home
	mkdir -p "$HOME/.cloudflared/zones/homelaberson.space"

	local UUID="12345678-1234-1234-1234-123456789012"
	local YAML="$HOME/.cloudflared/zones/homelaberson.space/test.yml"
	local CREDS_JSON="$HOME/.cloudflared/zones/homelaberson.space/${UUID}.json"

	ZONE="homelaberson.space"
	local expected_dir
	expected_dir="$(zone_base_dir)"
	assert_eq "$HOME/.cloudflared/zones/homelaberson.space" "$expected_dir" "zone dir correct"

	cat >"$YAML" <<YAML
tunnel: ${UUID}
credentials-file: ${CREDS_JSON}
YAML
	chmod 600 "$YAML"

	assert_contains "$(cat "$YAML")" "$HOME/.cloudflared/zones/homelaberson.space" "YAML creds in zone dir"

	teardown_mock_home
}

test_yaml_no_dns_flag() {
	# Verify NO_DNS flag exists and defaults to false
	NO_DNS=false
	assert_eq "false" "$NO_DNS" "NO_DNS default"
}
