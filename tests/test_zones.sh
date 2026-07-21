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
	assert_dir_exists "$HOME/.cloudflared/zones/homelaberson.space"

	local content
	content="$(cat "$HOME/.cloudflared/.default_zone")"
	assert_eq "homelaberson.space" "$content" "zone content should be canonical"
	assert_eq "600" "$(stat -c '%a' "$HOME/.cloudflared/.default_zone")" "default zone mode"

	teardown_mock_home
}

test_zone_use_normalizes_and_is_idempotent() {
	setup_mock_home

	op_zone use "Example.COM."
	assert_dir_exists "$HOME/.cloudflared/zones/example.com"
	assert_eq "example.com" "$(cat "$HOME/.cloudflared/.default_zone")" "normalized default"

	echo "preserve" > "$HOME/.cloudflared/zones/example.com/marker"
	op_zone use "EXAMPLE.com"
	assert_eq "preserve" "$(cat "$HOME/.cloudflared/zones/example.com/marker")" "repeat registration preserves contents"
	assert_dir_not_exists "$HOME/.cloudflared/zones/Example.COM."

	teardown_mock_home
}

test_zone_use_is_local_and_does_not_require_cloudflared() {
	setup_mock_home
	local fake_bin="$HOME/fake-bin"
	local call_log="$HOME/cloudflared-calls.log"
	mkdir -p "$fake_bin"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'printf "%s\\n" "$*" >> "$CFTUNNEL_OFFLINE_LOG"' \
		'exit 99' > "$fake_bin/cloudflared"
	chmod +x "$fake_bin/cloudflared"

	local output
	output="$(
		PATH="$fake_bin:$PATH" CFTUNNEL_OFFLINE_LOG="$call_log" CFTUNNEL_SKIP_MAIN="" \
			RUN_USER="cftunnel-test-user-that-does-not-exist" \
			"$PROJECT_DIR/run.sh" zone use "Example.COM." 2>&1
	)"
	assert_contains "$output" "Zone 'example.com' registered and set as default" "zone use output"
	assert_dir_exists "$HOME/.cloudflared/zones/example.com"
	assert_file_not_exists "$call_log" "zone use must never invoke cloudflared"

	teardown_mock_home
}

test_default_zone_write_failures_preserve_previous_value() {
	local failure output rc
	for failure in write chmod rename; do
		(
			setup_mock_home
			printf '%s\n' 'old.example' > "$HOME/.cloudflared/.default_zone"
			chmod 600 "$HOME/.cloudflared/.default_zone"

			case "$failure" in
				write) write_default_zone_file() { return 1; } ;;
				chmod)
					chmod() {
						local args=("$@") target="${args[${#args[@]}-1]}"
						[[ "$target" == */.default_zone.tmp.* ]] && return 1
						command chmod "$@"
					}
					;;
				rename)
					mv() {
						local args=("$@") source_path="${args[${#args[@]}-2]}"
						[[ "$source_path" == */.default_zone.tmp.* ]] && return 1
						command mv "$@"
					}
					;;
			esac

			rc=0
			output="$(save_default_zone "new.example" 2>&1)" || rc=$?
			assert_ne "0" "$rc" "default persistence failure: $failure"
			assert_eq "old.example" "$(cat "$HOME/.cloudflared/.default_zone")" "preserve default: $failure"
			assert_eq "" "$(find "$HOME/.cloudflared" -maxdepth 1 -name '.default_zone.tmp.*' -print)" "temporary default cleanup: $failure"
			teardown_mock_home
		)
	done
}

test_zone_use_rejects_invalid_name_without_artifacts() {
	setup_mock_home

	local output rc=0
	output="$(op_zone use "../../outside" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "unsafe zone should fail"
	assert_contains "$output" "Invalid zone name" "invalid zone error"
	assert_file_not_exists "$HOME/.cloudflared/.default_zone"
	assert_dir_not_exists "$HOME/outside"

	teardown_mock_home
}

test_zone_use_directory_failure_preserves_existing_default() {
	setup_mock_home
	echo "old.example" > "$HOME/.cloudflared/.default_zone"
	rm -rf "$HOME/.cloudflared/zones"
	echo "blocks directory creation" > "$HOME/.cloudflared/zones"

	local output rc=0
	output="$(op_zone use "new.example" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "directory creation failure should fail"
	assert_eq "old.example" "$(cat "$HOME/.cloudflared/.default_zone")" "default must remain unchanged"

	teardown_mock_home
}

test_load_default_zone_requires_one_canonical_line() {
	setup_mock_home

	echo "example.com" > "$HOME/.cloudflared/.default_zone"
	assert_eq "example.com" "$(load_default_zone)" "canonical default loads"

	local invalid output rc
	for invalid in "Example.COM" "../../outside" $'example.com\nother.example'; do
		printf '%s\n' "$invalid" > "$HOME/.cloudflared/.default_zone"
		rc=0
		output="$(load_default_zone 2>&1)" || rc=$?
		assert_ne "0" "$rc" "invalid persisted default should fail: $invalid"
		assert_eq "$invalid" "$(cat "$HOME/.cloudflared/.default_zone")" "invalid default must not be rewritten"
	done

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
	mkdir -p "$HOME/.cloudflared/zones/testes.lat"
	echo "keep" > "$HOME/.cloudflared/zones/testes.lat/marker"

	op_zone unset
	assert_file_not_exists "$HOME/.cloudflared/.default_zone" "zone unset should remove file"
	assert_file_exists "$HOME/.cloudflared/zones/testes.lat/marker" "zone unset should preserve registration"

	teardown_mock_home
}

test_persist_without_command_saves_zone() {
	setup_mock_home

	# Simulate: ./run.sh --zone "testes.lat" --persist
	ZONE="testes.lat"
	PERSIST_ZONE=true

	# This is what the main logic does
	if [[ -n "$ZONE" && "$PERSIST_ZONE" == true ]]; then
		register_zone "$ZONE" >/dev/null
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
		register_zone "$ZONE" >/dev/null
		# Would exit 0 here in real run.sh
		true
	else
		false  # Should NOT reach here
	fi

	teardown_mock_home
}

test_cli_persist_registers_zone_directory() {
	setup_mock_home

	local output
	output="$(
		CFTUNNEL_SKIP_MAIN="" RUN_USER="cftunnel-test-user-that-does-not-exist" \
			"$PROJECT_DIR/run.sh" --zone "Example.COM." --persist 2>&1
	)"
	assert_contains "$output" "Zone 'example.com' is now the default" "persist output"
	assert_dir_exists "$HOME/.cloudflared/zones/example.com"
	assert_eq "example.com" "$(cat "$HOME/.cloudflared/.default_zone")" "persisted canonical zone"

	teardown_mock_home
}

test_cli_interactive_default_change_registers_zone_directory() {
	setup_mock_home
	printf '%s\n' 'old.example' > "$HOME/.cloudflared/.default_zone"
	mkdir -p "$HOME/.cloudflared/zones/old.example"

	local output
	output="$(
		printf '%s\n' y | CFTUNNEL_SKIP_MAIN="" RUN_USER="cftunnel-test-user-that-does-not-exist" \
			"$PROJECT_DIR/run.sh" --zone "New.Example." list 2>&1
	)"
	assert_contains "$output" "Default zone changed to 'new.example'" "interactive persistence output"
	assert_dir_exists "$HOME/.cloudflared/zones/new.example"
	assert_eq "new.example" "$(cat "$HOME/.cloudflared/.default_zone")" "interactive canonical default"

	teardown_mock_home
}

test_list_with_empty_zone_shows_message() {
	setup_mock_home
	echo "empty.zone" > "$HOME/.cloudflared/.default_zone"

	# Reload default zone
	ZONE="$(load_default_zone)"

	local output
	output="$(op_list 2>&1 || true)"
	assert_contains "$output" "No hostname routes found" "list should show empty message"

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
