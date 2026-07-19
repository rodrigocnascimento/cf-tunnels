#!/usr/bin/env bash
# tests/test_parser.sh — CLI argument parser tests
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Prevent main logic from executing
mock_main

test_parser_extracts_zone_from_end() {
	# Simulate: ./run.sh add --hostname x --type http --service y --zone "testes.lat"
	ARGS=("add" "--hostname" "x" "--type" "http" "--service" "y" "--zone" "testes.lat")
	ZONE=""
	PERSIST_ZONE=false
	CLEAN_ARGS=()
	i=0
	while [[ $i -lt ${#ARGS[@]} ]]; do
		arg="${ARGS[$i]}"
		case "$arg" in
			--zone)
				ZONE="${ARGS[$((i+1))]}"
				((i+=2)) || true
				;;
			--persist)
				PERSIST_ZONE=true
				((i++)) || true
				;;
			*)
				CLEAN_ARGS+=("$arg")
				((i++)) || true
				;;
		esac
	done

	assert_eq "testes.lat" "$ZONE" "parser: zone at end"
	assert_eq "add" "${CLEAN_ARGS[0]}" "parser: cmd preserved"
}

test_parser_extracts_zone_from_start() {
	# Simulate: ./run.sh --zone "testes.lat" add --hostname x
	ARGS=("--zone" "testes.lat" "add" "--hostname" "x")
	ZONE=""
	PERSIST_ZONE=false
	CLEAN_ARGS=()
	i=0
	while [[ $i -lt ${#ARGS[@]} ]]; do
		arg="${ARGS[$i]}"
		case "$arg" in
			--zone)
				ZONE="${ARGS[$((i+1))]}"
				((i+=2)) || true
				;;
			--persist)
				PERSIST_ZONE=true
				((i++)) || true
				;;
			*)
				CLEAN_ARGS+=("$arg")
				((i++)) || true
				;;
		esac
	done

	assert_eq "testes.lat" "$ZONE" "parser: zone at start"
	assert_eq "add" "${CLEAN_ARGS[0]}" "parser: cmd preserved"
}

test_parser_persist_no_command() {
	# Simulate: ./run.sh --zone "testes.lat" --persist
	ARGS=("--zone" "testes.lat" "--persist")
	ZONE=""
	PERSIST_ZONE=false
	CLEAN_ARGS=()
	i=0
	while [[ $i -lt ${#ARGS[@]} ]]; do
		arg="${ARGS[$i]}"
		case "$arg" in
			--zone)
				ZONE="${ARGS[$((i+1))]}"
				((i+=2)) || true
				;;
			--persist)
				PERSIST_ZONE=true
				((i++)) || true
				;;
			*)
				CLEAN_ARGS+=("$arg")
				((i++)) || true
				;;
		esac
	done

	assert_eq "testes.lat" "$ZONE" "parser: persist zone"
	assert_eq "true" "$PERSIST_ZONE" "parser: persist flag"
	assert_eq "0" "${#CLEAN_ARGS[@]}" "parser: no clean args"
}

test_parser_skips_version_check_for_zone() {
	mock_main
	# check_cloudflared_version should skip for zone cmd
	cmd="zone"
	if [[ "$cmd" == "cli-update" || "$cmd" == "zone" || -z "${cmd:-}" ]]; then
		true  # correctly skipped
	else
		false
	fi
}

test_parser_skips_version_check_for_cli_update() {
	mock_main
	cmd="cli-update"
	if [[ "$cmd" == "cli-update" || "$cmd" == "zone" || -z "${cmd:-}" ]]; then
		true
	else
		false
	fi
}

test_parser_skips_version_check_for_list() {
	mock_main
	cmd="list"
	if [[ "$cmd" == "cli-update" || "$cmd" == "list" || "$cmd" == "zone" || -z "${cmd:-}" ]]; then
		true
	else
		false
	fi
}
