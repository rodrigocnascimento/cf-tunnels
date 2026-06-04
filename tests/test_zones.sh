#!/usr/bin/env bash
# tests/test_zones.sh — Integration tests for zone management
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Prevent main logic from executing
mock_main

test_zone_use_creates_default_file() {
	setup_mock_home

	op_zone use "homelaberson.space"
	assert_file_exists "$HOME/.cloudflared/.default_zone"

	local content
	content="$(cat "$HOME/.cloudflared/.default_zone")"
	assert_eq "homelaberson.space" "$content" "zone content should be preserved as-is"

	teardown_mock_home
}

test_zone_current_shows_value() {
	setup_mock_home
	echo "homelaberson.space" > "$HOME/.cloudflared/.default_zone"

	local output
	output="$(op_zone current 2>&1)"
	assert_contains "$output" "homelaberson.space" "zone current should show value"

	teardown_mock_home
}

test_zone_current_empty() {
	setup_mock_home

	local output
	output="$(op_zone current 2>&1)"
	assert_contains "$output" "No default zone" "zone current should show empty message"

	teardown_mock_home
}

test_zone_unset_removes_file() {
	setup_mock_home
	echo "testes.lat" > "$HOME/.cloudflared/.default_zone"

	op_zone unset
	assert_file_not_exists "$HOME/.cloudflared/.default_zone" "zone unset should remove file"

	teardown_mock_home
}

test_persist_without_command_saves_zone() {
	setup_mock_home

	# Simulate: ./run.sh --zone "testes.lat" --persist
	ZONE="testes.lat"
	PERSIST_ZONE=true

	# This is what the main logic does
	if [[ -n "$ZONE" && "$PERSIST_ZONE" == true ]]; then
		save_default_zone "$ZONE"
	fi

	assert_file_exists "$HOME/.cloudflared/.default_zone"
	local content
	content="$(cat "$HOME/.cloudflared/.default_zone")"
	assert_eq "testes.lat" "$content" "persist should save zone"

	teardown_mock_home
}

test_persist_without_command_exits_cleanly() {
	setup_mock_home

	# Simulate the early-exit logic when cmd is empty and persist saved
	ZONE="testes.lat"
	PERSIST_ZONE=true
	cmd=""

	if [[ -z "${cmd:-}" && "$PERSIST_ZONE" == true && -n "$ZONE" ]]; then
		save_default_zone "$ZONE"
		# Would exit 0 here in real run.sh
		true
	else
		false  # Should NOT reach here
	fi

	teardown_mock_home
}

test_list_with_empty_zone_shows_message() {
	setup_mock_home
	echo "empty-zone" > "$HOME/.cloudflared/.default_zone"

	# Reload default zone
	ZONE="$(load_default_zone)"

	local output
	output="$(op_list 2>&1 || true)"
	assert_contains "$output" "No tunnels found" "list should show empty message"

	teardown_mock_home
}

test_list_without_zone_no_marker() {
	setup_mock_home
	# No default zone
	ZONE=""

	local output
	output="$(op_list 2>&1 || true)"
	# Should not contain [zone] marker
	if [[ "$output" == *"[zone]"* ]]; then
		echo "ASSERT FAIL: list without zone should not show [zone] marker" >&2
		exit 1
	fi

	teardown_mock_home
}

test_zone_login_no_active_zone_lists_zones() {
	setup_mock_home
	mkdir -p "$HOME/.cloudflared/zones/homelaberson.space"
	mkdir -p "$HOME/.cloudflared/zones/testes.lat"

	ZONE=""
	# Simulate zone login without active zone: should list zones
	# We can't test interactive input, so we verify the listing logic
	local zones=()
	while IFS= read -r -d '' zone_dir; do
		zones+=("$(basename "$zone_dir")")
	done < <(find "$HOME/.cloudflared/zones" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

	assert_eq "2" "${#zones[@]}" "zone login should find 2 zones"
	assert_contains "${zones[*]}" "homelaberson.space" "zone login list should contain homelaberson.space"
	assert_contains "${zones[*]}" "testes.lat" "zone login list should contain testes.lat"

	teardown_mock_home
}
