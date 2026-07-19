#!/usr/bin/env bash
# tests/test_version.sh — cftunnel application version reporting tests
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

expected_version_output() {
	printf 'cftunnel %s' "$(<"$PROJECT_DIR/VERSION")"
}

test_version_flag_matches_version_file() {
	local output rc=0
	output="$("$PROJECT_DIR/run.sh" --version 2>/dev/null)" || rc=$?

	assert_eq "0" "$rc" "--version exit code"
	assert_eq "$(expected_version_output)" "$output" "--version output"
}

test_version_subcommand_matches_version_file() {
	local output rc=0
	output="$("$PROJECT_DIR/run.sh" version 2>/dev/null)" || rc=$?

	assert_eq "0" "$rc" "version subcommand exit code"
	assert_eq "$(expected_version_output)" "$output" "version subcommand output"
}

test_version_is_silent_and_never_calls_dependencies() {
	local fake_bin="$HOME/fake-bin"
	local call_log="$HOME/dependency.calls"
	local stdout_file="$HOME/version.stdout"
	local stderr_file="$HOME/version.stderr"
	mkdir -p "$fake_bin"

	for dependency in cloudflared systemctl; do
		printf '%s\n' \
			'#!/usr/bin/env bash' \
			'printf "%s: %s\n" "${0##*/}" "$*" >> "$CFTUNNEL_DEPENDENCY_CALL_LOG"' \
			'exit 99' > "$fake_bin/$dependency"
		chmod +x "$fake_bin/$dependency"
	done

	for command in --version version; do
		rm -f "$call_log" "$stdout_file" "$stderr_file"
		PATH="$fake_bin:$PATH" \
			CFTUNNEL_DEPENDENCY_CALL_LOG="$call_log" \
			"$PROJECT_DIR/run.sh" "$command" > "$stdout_file" 2> "$stderr_file"

		assert_eq "$(expected_version_output)" "$(<"$stdout_file")" "$command offline output"
		assert_eq "" "$(<"$stderr_file")" "$command successful stderr"
		assert_file_not_exists "$call_log" "$command must not invoke cloudflared or systemctl"
	done
}

test_version_does_not_touch_zone_state() {
	local config_dir="$HOME/.cloudflared"
	local default_zone="$config_dir/.default_zone"
	mkdir -p "$config_dir"
	touch "$default_zone"

	local output
	output="$(RUN_USER="cftunnel-version-test-user" "$PROJECT_DIR/run.sh" --version 2>/dev/null)"

	assert_eq "$(expected_version_output)" "$output" "version with empty default zone"
	assert_file_exists "$default_zone" "version must not remove an empty default zone file"
	assert_eq "" "$(<"$default_zone")" "version must not modify default zone content"
}

test_version_works_through_symlink() {
	local bin_dir="$HOME/bin"
	mkdir -p "$bin_dir"
	ln -s "$PROJECT_DIR/run.sh" "$bin_dir/cftunnel"

	local output
	output="$("$bin_dir/cftunnel" version 2>/dev/null)"
	assert_eq "$(expected_version_output)" "$output" "symlink version output"
}

test_version_rejects_extra_arguments() {
	local command output rc
	for command in --version version; do
		rc=0
		output="$("$PROJECT_DIR/run.sh" "$command" unexpected 2>&1)" || rc=$?

		assert_ne "0" "$rc" "$command extra argument exit code"
		assert_contains "$output" "does not accept arguments" "$command extra argument error"
	done
}

test_version_helper_validates_version_file() {
	local fixture="$HOME/test-version"
	local output rc

	printf '%s\n' '0.4.0-rc.1+build.7' > "$fixture"
	output="$(CFTUNNEL_VERSION_FILE="$fixture" print_cftunnel_version)"
	assert_eq "cftunnel 0.4.0-rc.1+build.7" "$output" "valid prerelease version"

	for invalid_case in missing empty multiline invalid whitespace; do
		rc=0
		case "$invalid_case" in
		missing)
			fixture="$HOME/missing-version"
			;;
		empty)
			fixture="$HOME/empty-version"
			: > "$fixture"
			;;
		multiline)
			fixture="$HOME/multiline-version"
			printf '%s\n' '0.4.0' 'unexpected' > "$fixture"
			;;
		invalid)
			fixture="$HOME/invalid-version"
			printf '%s\n' 'development' > "$fixture"
			;;
		whitespace)
			fixture="$HOME/whitespace-version"
			printf '%s\n' ' 0.4.0 ' > "$fixture"
			;;
		esac

		(CFTUNNEL_VERSION_FILE="$fixture" print_cftunnel_version) >/dev/null 2>&1 || rc=$?
		assert_ne "0" "$rc" "reject $invalid_case version file"
	done
}
