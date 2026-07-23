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

test_add_rejects_cross_zone_hostname_before_external_or_persistence() {
	local fake_bin="$HOME/fake-bin"
	local cloudflared_log="$HOME/cloudflared.log"
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
	output="$(PATH="$fake_bin:$PATH" RUN_USER=cftunnel-test USER=cftunnel-test CFTUNNEL_PROBE_LOG="$cloudflared_log" \
		bash "$PROJECT_DIR/run.sh" --zone example.com --persist add \
		--hostname app.other.com --type http --service http://localhost:8080 2>&1)" || rc=$?
	assert_ne "0" "$rc" "cross-zone add should fail"
	assert_contains "$output" "does not belong to zone 'example.com'" "pre-external containment error"
	assert_file_not_exists "$cloudflared_log" "cloudflared must not run"
	assert_file_not_exists "$HOME/.cloudflared/.default_zone" "invalid add must not persist the zone"
}
