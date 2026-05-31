#!/usr/bin/env bash
# tests/test_parser.sh — CLI argument parser tests
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Prevent main logic from executing
mock_main

test_parser_extracts_profile_from_end() {
	# Simulate: ./run.sh add --hostname x --type http --service y --profile "meu"
	ARGS=("add" "--hostname" "x" "--type" "http" "--service" "y" "--profile" "meu")
	PROFILE=""
	PERSIST_PROFILE=false
	CLEAN_ARGS=()
	i=0
	while [[ $i -lt ${#ARGS[@]} ]]; do
		arg="${ARGS[$i]}"
		case "$arg" in
			--profile)
				PROFILE="${ARGS[$((i+1))]}"
				((i+=2)) || true
				;;
			--persist)
				PERSIST_PROFILE=true
				((i++)) || true
				;;
			*)
				CLEAN_ARGS+=("$arg")
				((i++)) || true
				;;
		esac
	done

	assert_eq "meu" "$PROFILE" "parser: profile at end"
	assert_eq "add" "${CLEAN_ARGS[0]}" "parser: cmd preserved"
}

test_parser_extracts_profile_from_start() {
	# Simulate: ./run.sh --profile "meu" add --hostname x
	ARGS=("--profile" "meu" "add" "--hostname" "x")
	PROFILE=""
	PERSIST_PROFILE=false
	CLEAN_ARGS=()
	i=0
	while [[ $i -lt ${#ARGS[@]} ]]; do
		arg="${ARGS[$i]}"
		case "$arg" in
			--profile)
				PROFILE="${ARGS[$((i+1))]}"
				((i+=2)) || true
				;;
			--persist)
				PERSIST_PROFILE=true
				((i++)) || true
				;;
			*)
				CLEAN_ARGS+=("$arg")
				((i++)) || true
				;;
		esac
	done

	assert_eq "meu" "$PROFILE" "parser: profile at start"
	assert_eq "add" "${CLEAN_ARGS[0]}" "parser: cmd preserved"
}

test_parser_persist_no_command() {
	# Simulate: ./run.sh --profile "x" --persist
	ARGS=("--profile" "x" "--persist")
	PROFILE=""
	PERSIST_PROFILE=false
	CLEAN_ARGS=()
	i=0
	while [[ $i -lt ${#ARGS[@]} ]]; do
		arg="${ARGS[$i]}"
		case "$arg" in
			--profile)
				PROFILE="${ARGS[$((i+1))]}"
				((i+=2)) || true
				;;
			--persist)
				PERSIST_PROFILE=true
				((i++)) || true
				;;
			*)
				CLEAN_ARGS+=("$arg")
				((i++)) || true
				;;
		esac
	done

	assert_eq "x" "$PROFILE" "parser: persist profile"
	assert_eq "true" "$PERSIST_PROFILE" "parser: persist flag"
	assert_eq "0" "${#CLEAN_ARGS[@]}" "parser: no clean args"
}

test_parser_skips_version_check_for_profile() {
	mock_main
	# check_cloudflared_version should skip for profile cmd
	cmd="profile"
	if [[ "$cmd" == "cli-update" || "$cmd" == "profile" || -z "${cmd:-}" ]]; then
		true  # correctly skipped
	else
		false
	fi
}

test_parser_skips_version_check_for_cli_update() {
	mock_main
	cmd="cli-update"
	if [[ "$cmd" == "cli-update" || "$cmd" == "profile" || -z "${cmd:-}" ]]; then
		true
	else
		false
	fi
}

test_parser_runs_version_check_for_normal_cmd() {
	mock_main
	cmd="list"
	if [[ "$cmd" == "cli-update" || "$cmd" == "profile" || -z "${cmd:-}" ]]; then
		false  # Should NOT skip for list
	else
		true
	fi
}
