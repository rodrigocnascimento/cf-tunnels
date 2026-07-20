#!/usr/bin/env bash
# tests/test_zone_credentials.sh — Zone token isolation and binding tests
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

mock_main

write_test_token() {
	local path="$1"
	local payload="${2:-VEVTVA==}"
	printf '%s\n' \
		'-----BEGIN ARGO TUNNEL TOKEN-----' \
		"$payload" \
		'-----END ARGO TUNNEL TOKEN-----' > "$path"
}

make_fake_cloudflared() {
	local fake_dir="$HOME/fake-bin"
	mkdir -p "$fake_dir"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'set -u' \
		'printf "HOME=%s ARGS=%s\\n" "$HOME" "$*" >> "$CFTUNNEL_TEST_LOG"' \
		'if [[ "$*" == "tunnel login" ]]; then' \
		'  mkdir -p "$HOME/.cloudflared"' \
		'  printf "LOGIN_HOME_MODE=%s\\n" "$(stat -c "%a" "$HOME")" >> "$CFTUNNEL_TEST_LOG"' \
		'  case "${CFTUNNEL_TEST_MODE:-ok}" in' \
		'    malformed) printf "%s\\n" "not a token" > "$HOME/.cloudflared/cert.pem" ;;' \
		'    missing) : ;;' \
		'    login_fail) exit 10 ;;' \
		'    signal_clean) kill -TERM "$PPID" ;;' \
		'    signal_root_change) printf "%s\\n" "CHANGED-ROOT" > "$CFTUNNEL_REAL_ROOT_CERT"; kill -TERM "$PPID" ;;' \
		'    root_create) printf "%s\\n" "UNEXPECTED-ROOT" > "$CFTUNNEL_REAL_ROOT_CERT" ;;' \
		'    root_change) printf "%s\\n" "CHANGED-ROOT" > "$CFTUNNEL_REAL_ROOT_CERT" ;;' \
		'    root_remove) rm -f -- "$CFTUNNEL_REAL_ROOT_CERT" ;;' \
		'    *) printf "%s\\n" "-----BEGIN ARGO TUNNEL TOKEN-----" "VEVTVA==" "-----END ARGO TUNNEL TOKEN-----" > "$HOME/.cloudflared/cert.pem" ;;' \
		'  esac' \
		'  case "${CFTUNNEL_TEST_MODE:-ok}" in root_create|root_change|root_remove) printf "%s\\n" "-----BEGIN ARGO TUNNEL TOKEN-----" "VEVTVA==" "-----END ARGO TUNNEL TOKEN-----" > "$HOME/.cloudflared/cert.pem" ;; esac' \
		'  exit 0' \
		'fi' \
		'if [[ "$*" == *"tunnel delete"* ]]; then' \
		'  [[ "${CFTUNNEL_TEST_MODE:-ok}" != "delete_fail" ]] || exit 30' \
		'  exit 0' \
		'fi' \
		'if [[ "$*" == *"tunnel list --output json"* ]]; then' \
		'  [[ "${CFTUNNEL_TEST_MODE:-ok}" != "auth_fail" ]] || exit 20' \
		'  printf "%s\\n" "REMOTE_ACCOUNT_OUTPUT"' \
		'fi' \
		'exit 0' > "$fake_dir/cloudflared"
	chmod +x "$fake_dir/cloudflared"
	CLOUDFLARED_BIN="$fake_dir/cloudflared"
	export CFTUNNEL_TEST_LOG="$HOME/cloudflared.log"
	export CFTUNNEL_REAL_ROOT_CERT="$HOME/.cloudflared/cert.pem"
	: > "$CFTUNNEL_TEST_LOG"
}

seed_existing_zone_pair() {
	local zone="${1:-example.com}"
	mkdir -p "$HOME/.cloudflared/zones/$zone"
	printf '%s\n' 'OLD-CREDENTIAL' > "$HOME/.cloudflared/zones/$zone/cert.pem"
	printf '%s\n' 'OLD-METADATA' > "$HOME/.cloudflared/zones/$zone/zone.json"
}

assert_existing_zone_pair_preserved() {
	local context="${1:-failure}"
	assert_eq "OLD-CREDENTIAL" "$(cat "$HOME/.cloudflared/zones/example.com/cert.pem")" "preserve credential: $context"
	assert_eq "OLD-METADATA" "$(cat "$HOME/.cloudflared/zones/example.com/zone.json")" "preserve metadata: $context"
}

assert_no_credential_transaction_artifacts() {
	local dir="$HOME/.cloudflared/zones/example.com"
	local artifacts
	artifacts="$(find "$dir" -maxdepth 1 -type f \( -name '.*.new.*' -o -name '.*.backup.*' \) -print 2>/dev/null || true)"
	assert_eq "" "$artifacts" "credential transaction artifacts"
}

test_zone_token_accepts_single_argo_block() {
	setup_mock_home
	local token="$HOME/token.pem"
	write_test_token "$token"
	validate_tunnel_token_file "$token" || exit 1
	teardown_mock_home
}

test_zone_token_rejects_missing_empty_and_malformed_files() {
	setup_mock_home
	local token="$HOME/token.pem" output rc
	local fixture
	for fixture in empty missing_begin missing_end empty_payload wrong_type duplicate trailing_text; do
		: > "$token"
		case "$fixture" in
			empty) : ;;
			missing_begin) printf '%s\n' 'VEVTVA==' '-----END ARGO TUNNEL TOKEN-----' > "$token" ;;
			missing_end) printf '%s\n' '-----BEGIN ARGO TUNNEL TOKEN-----' 'VEVTVA==' > "$token" ;;
			empty_payload) printf '%s\n' '-----BEGIN ARGO TUNNEL TOKEN-----' '-----END ARGO TUNNEL TOKEN-----' > "$token" ;;
			wrong_type) printf '%s\n' '-----BEGIN CERTIFICATE-----' 'VEVTVA==' '-----END CERTIFICATE-----' > "$token" ;;
			duplicate)
				write_test_token "$token"
				write_test_token "$HOME/second.pem"
				printf '%s\n' "$(cat "$HOME/second.pem")" >> "$token"
				;;
			trailing_text)
				write_test_token "$token"
				printf '%s\n' 'unexpected' >> "$token"
				;;
		esac
		rc=0
		output="$(validate_tunnel_token_file "$token" 2>&1)" || rc=$?
		assert_ne "0" "$rc" "reject token fixture: $fixture"
	done

	rc=0
	output="$(validate_tunnel_token_file "$HOME/missing.pem" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "reject missing token"
	write_test_token "$HOME/real-token.pem"
	ln -s "$HOME/real-token.pem" "$HOME/token-link.pem"
	rc=0
	output="$(validate_tunnel_token_file "$HOME/token-link.pem" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "reject symlinked token"
	teardown_mock_home
}

test_zone_login_uses_isolated_home_and_preserves_root_credential() {
	setup_mock_home
	make_fake_cloudflared
	printf '%s\n' 'ROOT-ORIGINAL' > "$HOME/.cloudflared/cert.pem"
	ZONE="example.com"

	op_zone login >/dev/null

	assert_eq "ROOT-ORIGINAL" "$(cat "$HOME/.cloudflared/cert.pem")" "root credential preserved"
	local login_home
	login_home="$(sed -n 's/^HOME=\([^ ]*\) ARGS=tunnel login$/\1/p' "$CFTUNNEL_TEST_LOG")"
	assert_ne "" "$login_home" "isolated login HOME recorded"
	assert_ne "$HOME" "$login_home" "login must not use the real HOME"
	assert_contains "$(cat "$CFTUNNEL_TEST_LOG")" "LOGIN_HOME_MODE=700" "isolated login HOME mode"
	teardown_mock_home
}

test_zone_login_installs_token_and_metadata_with_private_modes() {
	setup_mock_home
	make_fake_cloudflared
	ZONE="example.com"

	op_zone login >/dev/null

	local cert="$HOME/.cloudflared/zones/example.com/cert.pem"
	local metadata="$HOME/.cloudflared/zones/example.com/zone.json"
	assert_file_exists "$cert"
	assert_file_exists "$metadata"
	assert_eq "600" "$(stat -c '%a' "$cert")" "zone credential mode"
	assert_eq "600" "$(stat -c '%a' "$metadata")" "zone metadata mode"
	assert_contains "$(cat "$metadata")" '"zone": "example.com"' "metadata zone"
	assert_contains "$(cat "$metadata")" '"credential_type": "argo_tunnel_token"' "metadata credential type"
	grep -Eq '"certificate_sha256": "[0-9a-f]{64}"' "$metadata"
	validate_tunnel_token_file "$cert"
	teardown_mock_home
}

test_zone_login_authenticates_candidate_without_exposing_remote_output() {
	setup_mock_home
	make_fake_cloudflared
	ZONE="example.com"

	local output
	output="$(op_zone login 2>&1)"
	assert_contains "$(cat "$CFTUNNEL_TEST_LOG")" "tunnel list --output json" "candidate auth probe"
	assert_not_contains "$output" "REMOTE_ACCOUNT_OUTPUT" "remote output must be suppressed"
	assert_not_contains "$output" "VEVTVA==" "token payload must not be printed"
	teardown_mock_home
}

test_zone_login_failure_preserves_existing_zone_files() {
	setup_mock_home
	make_fake_cloudflared
	ZONE="example.com"
	seed_existing_zone_pair

	local mode output rc
	for mode in login_fail missing malformed auth_fail; do
		export CFTUNNEL_TEST_MODE="$mode"
		rc=0
		output="$(op_zone login 2>&1)" || rc=$?
		assert_ne "0" "$rc" "zone login should fail: $mode"
		assert_existing_zone_pair_preserved "$mode"
		assert_not_contains "$output" "VEVTVA==" "failure must not expose token: $mode"
		assert_not_contains "$output" "REMOTE_ACCOUNT_OUTPUT" "failure must not expose remote output: $mode"
		if find "$HOME/.cloudflared" -maxdepth 1 -type d -name '.zone-login.*' | grep -q .; then
			echo "ASSERT FAIL: login workspace remains after failure: $mode" >&2
			exit 1
		fi
	done
	unset CFTUNNEL_TEST_MODE
	teardown_mock_home
}

test_zone_login_cleans_temporary_workspace() {
	setup_mock_home
	make_fake_cloudflared
	ZONE="example.com"

	op_zone login >/dev/null
	if find "$HOME/.cloudflared" -maxdepth 1 -type d -name '.zone-login.*' | grep -q .; then
		echo "ASSERT FAIL: login workspace remains after success" >&2
		exit 1
	fi

	export CFTUNNEL_TEST_MODE="malformed"
	local output rc=0
	output="$(op_zone login 2>&1)" || rc=$?
	assert_ne "0" "$rc" "malformed login should fail"
	if find "$HOME/.cloudflared" -maxdepth 1 -type d -name '.zone-login.*' | grep -q .; then
		echo "ASSERT FAIL: login workspace remains after failure" >&2
		exit 1
	fi
	unset CFTUNNEL_TEST_MODE
	teardown_mock_home
}

test_zone_login_failure_preserves_root_credential() {
	setup_mock_home
	make_fake_cloudflared
	printf '%s\n' 'ROOT-ORIGINAL' > "$HOME/.cloudflared/cert.pem"
	seed_existing_zone_pair
	ZONE="example.com"
	export CFTUNNEL_TEST_MODE="login_fail"

	local output rc=0
	output="$(op_zone login 2>&1)" || rc=$?
	assert_ne "0" "$rc" "login failure should fail"
	assert_eq "ROOT-ORIGINAL" "$(cat "$HOME/.cloudflared/cert.pem")" "root credential on login failure"
	assert_existing_zone_pair_preserved "login failure"
	unset CFTUNNEL_TEST_MODE
	teardown_mock_home
}

test_zone_login_detects_root_credential_integrity_violations() {
	local mode output rc
	for mode in root_create root_change root_remove; do
		setup_mock_home
		make_fake_cloudflared
		if [[ "$mode" == root_create ]]; then
			rm -f -- "$HOME/.cloudflared/cert.pem"
		else
			printf '%s\n' 'ROOT-ORIGINAL' > "$HOME/.cloudflared/cert.pem"
		fi
		seed_existing_zone_pair
		ZONE="example.com"
		export CFTUNNEL_TEST_MODE="$mode"

		rc=0
		output="$(op_zone login 2>&1)" || rc=$?
		assert_ne "0" "$rc" "root integrity violation should fail: $mode"
		assert_contains "$output" "root credential" "root integrity error: $mode"
		assert_existing_zone_pair_preserved "$mode"
		if find "$HOME/.cloudflared" -maxdepth 1 -type d -name '.zone-login.*' | grep -q .; then
			echo "ASSERT FAIL: login workspace remains after root integrity failure: $mode" >&2
			exit 1
		fi
		unset CFTUNNEL_TEST_MODE
		teardown_mock_home
	done
}

test_zone_login_install_failure_preserves_destination_and_cleans_workspace() {
	setup_mock_home
	make_fake_cloudflared
	seed_existing_zone_pair
	ZONE="example.com"
	install_zone_credential() { return 1; }

	local output rc=0
	output="$(op_zone login 2>&1)" || rc=$?
	assert_ne "0" "$rc" "installation failure should fail login"
	assert_existing_zone_pair_preserved "installation failure"
	assert_not_contains "$output" "VEVTVA==" "installation failure token secrecy"
	if find "$HOME/.cloudflared" -maxdepth 1 -type d -name '.zone-login.*' | grep -q .; then
		echo "ASSERT FAIL: login workspace remains after installation failure" >&2
		exit 1
	fi
	teardown_mock_home
}

test_zone_login_interruption_preserves_destination_and_cleans_workspace() {
	setup_mock_home
	make_fake_cloudflared
	seed_existing_zone_pair
	ZONE="example.com"
	install_zone_credential() { kill -TERM "$BASHPID"; }

	local output rc=0
	output="$(op_zone login 2>&1)" || rc=$?
	assert_ne "0" "$rc" "interrupted login should fail"
	assert_existing_zone_pair_preserved "login interruption"
	assert_not_contains "$output" "VEVTVA==" "interrupted login token secrecy"
	if find "$HOME/.cloudflared" -maxdepth 1 -type d -name '.zone-login.*' | grep -q .; then
		echo "ASSERT FAIL: login workspace remains after interruption" >&2
		exit 1
	fi
	teardown_mock_home
}

test_zone_login_signal_checks_root_integrity_before_exit() {
	local mode output rc
	for mode in signal_clean signal_root_change; do
		(
			setup_mock_home
			make_fake_cloudflared
			printf '%s\n' 'ROOT-ORIGINAL' > "$HOME/.cloudflared/cert.pem"
			seed_existing_zone_pair
			ZONE="example.com"
			export CFTUNNEL_TEST_MODE="$mode"

			rc=0
			output="$(op_zone login 2>&1)" || rc=$?
			assert_ne "0" "$rc" "signaled login should fail: $mode"
			assert_existing_zone_pair_preserved "$mode"
			if [[ "$mode" == signal_clean ]]; then
				assert_contains "$output" "authentication was interrupted" "clean interruption error"
				assert_eq "ROOT-ORIGINAL" "$(cat "$HOME/.cloudflared/cert.pem")" "clean interruption root credential"
			else
				assert_contains "$output" "created, removed, or modified the root credential" "interrupted root integrity error"
				assert_not_contains "$output" "authentication was interrupted" "integrity error takes precedence"
			fi
			if find "$HOME/.cloudflared" -maxdepth 1 -type d -name '.zone-login.*' | grep -q .; then
				echo "ASSERT FAIL: login workspace remains after signal: $mode" >&2
				exit 1
			fi
			teardown_mock_home
		)
	done
}

test_zone_login_validates_typed_interactive_selection() {
	setup_mock_home
	make_fake_cloudflared
	mkdir -p "$HOME/.cloudflared/zones/registered.example"
	ZONE=""

	local output
	output="$(printf '%s\n' 'Example.COM.' | op_zone login 2>&1)"
	assert_contains "$output" "Authenticating zone 'example.com'" "canonical interactive zone"
	assert_file_exists "$HOME/.cloudflared/zones/example.com/cert.pem"

	local log_before
	log_before="$(cat "$CFTUNNEL_TEST_LOG")"
	local rc=0
	ZONE=""
	output="$(printf '%s\n' '../../outside' | op_zone login 2>&1)" || rc=$?
	assert_ne "0" "$rc" "unsafe interactive zone should fail"
	assert_contains "$output" "Invalid zone name" "unsafe interactive zone error"
	assert_eq "$log_before" "$(cat "$CFTUNNEL_TEST_LOG")" "unsafe zone must fail before cloudflared"
	teardown_mock_home
}

test_install_zone_credential_rolls_back_stage_and_rename_failures() {
	local failure output rc candidate
	for failure in cert_stage metadata_stage cert_rename metadata_rename; do
		(
			setup_mock_home
			seed_existing_zone_pair
			candidate="$HOME/candidate.pem"
			write_test_token "$candidate"

			case "$failure" in
				cert_stage)
					cp() {
						local args=("$@") target="${args[${#args[@]}-1]}"
						[[ "$target" == */.cert.pem.new.* ]] && return 1
						command cp "$@"
					}
					;;
				metadata_stage) write_zone_credential_metadata() { return 1; } ;;
				cert_rename|metadata_rename)
					mv() {
						local args=("$@") source_path="${args[${#args[@]}-2]}" target="${args[${#args[@]}-1]}"
						if [[ "$failure" == cert_rename && "$source_path" == */.cert.pem.new.* && "$target" == */cert.pem ]]; then return 1; fi
						if [[ "$failure" == metadata_rename && "$source_path" == */.zone.json.new.* && "$target" == */zone.json ]]; then return 1; fi
						command mv "$@"
					}
					;;
			esac

			rc=0
			output="$(install_zone_credential "$candidate" "example.com" 2>&1)" || rc=$?
			assert_ne "0" "$rc" "injected installation failure: $failure"
			assert_existing_zone_pair_preserved "$failure"
			assert_no_credential_transaction_artifacts
			teardown_mock_home
		)
	done
}

test_install_zone_credential_rolls_back_permission_failure() {
	setup_mock_home
	seed_existing_zone_pair
	local candidate="$HOME/candidate.pem"
	write_test_token "$candidate"
	chmod() {
		local args=("$@") target="${args[${#args[@]}-1]}"
		[[ "$target" == "$HOME/.cloudflared/zones/example.com/zone.json" ]] && return 1
		command chmod "$@"
	}

	local output rc=0
	output="$(install_zone_credential "$candidate" "example.com" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "final permission failure should fail"
	assert_contains "$output" "previous zone credential state restored" "permission rollback report"
	assert_existing_zone_pair_preserved "permission failure"
	assert_no_credential_transaction_artifacts
	unset -f chmod
	teardown_mock_home
}

test_install_zone_credential_rolls_back_on_interruption() {
	setup_mock_home
	seed_existing_zone_pair
	local candidate="$HOME/candidate.pem"
	write_test_token "$candidate"
	mv() {
		local args=("$@") source_path="${args[${#args[@]}-2]}" target="${args[${#args[@]}-1]}"
		command mv "$@" || return 1
		if [[ "$source_path" == */.cert.pem.new.* && "$target" == */cert.pem ]]; then
			kill -TERM "$BASHPID"
		fi
	}

	local output rc=0
	output="$(install_zone_credential "$candidate" "example.com" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "interrupted installation should fail"
	assert_existing_zone_pair_preserved "interruption"
	assert_no_credential_transaction_artifacts
	unset -f mv
	teardown_mock_home
}

test_install_zone_credential_reports_rollback_failure_without_false_claim() {
	setup_mock_home
	seed_existing_zone_pair
	local candidate="$HOME/candidate.pem"
	write_test_token "$candidate"
	mv() {
		local args=("$@") source_path="${args[${#args[@]}-2]}" target="${args[${#args[@]}-1]}"
		if [[ "$source_path" == */.zone.json.new.* && "$target" == */zone.json ]]; then return 1; fi
		if [[ "$source_path" == */.cert.pem.backup.* && "$target" == */cert.pem ]]; then return 1; fi
		command mv "$@"
	}

	local output rc=0
	output="$(install_zone_credential "$candidate" "example.com" 2>&1)" || rc=$?
	assert_ne "0" "$rc" "rollback failure should fail"
	assert_contains "$output" "rollback was incomplete" "rollback failure report"
	assert_not_contains "$output" "previous zone credential state restored" "must not claim restoration"
	assert_no_credential_transaction_artifacts
	unset -f mv
	teardown_mock_home
}

test_zone_binding_blocks_swapped_credential_before_cloudflared() {
	setup_mock_home
	make_fake_cloudflared
	ZONE="example.com"
	op_zone login >/dev/null

	write_test_token "$HOME/.cloudflared/zones/example.com/cert.pem" "RElGRkVSRU5U"
	: > "$CFTUNNEL_TEST_LOG"
	local output rc=0
	output="$(cloudflared tunnel list --output json 2>&1)" || rc=$?
	assert_ne "0" "$rc" "swapped credential should be blocked"
	assert_contains "$output" "binding check failed" "binding error"
	assert_eq "" "$(cat "$CFTUNNEL_TEST_LOG")" "cloudflared must not execute"
	teardown_mock_home
}

test_zone_binding_rejects_missing_and_invalid_components_before_cloudflared() {
	local scenario output rc metadata cert hash
	for scenario in missing_metadata symlink_metadata wrong_zone unsupported_type missing_fingerprint invalid_fingerprint missing_credential symlink_credential; do
		setup_mock_home
		make_fake_cloudflared
		ZONE="example.com"
		mkdir -p "$HOME/.cloudflared/zones/example.com"
		cert="$HOME/.cloudflared/zones/example.com/cert.pem"
		metadata="$HOME/.cloudflared/zones/example.com/zone.json"
		write_test_token "$cert"
		hash="$(credential_sha256 "$cert")"
		write_zone_credential_metadata "$metadata" "example.com" "$hash" "2026-07-19T00:00:00Z"

		case "$scenario" in
			missing_metadata) rm -f -- "$metadata" ;;
			symlink_metadata) mv -- "$metadata" "$HOME/metadata-target"; ln -s "$HOME/metadata-target" "$metadata" ;;
			wrong_zone) sed -i 's/"zone": "example.com"/"zone": "other.example"/' "$metadata" ;;
			unsupported_type) sed -i 's/argo_tunnel_token/x509/' "$metadata" ;;
			missing_fingerprint) sed -i '/certificate_sha256/d' "$metadata" ;;
			invalid_fingerprint) sed -i 's/"certificate_sha256": "[^"]*"/"certificate_sha256": "not-a-hash"/' "$metadata" ;;
			missing_credential) rm -f -- "$cert" ;;
			symlink_credential) mv -- "$cert" "$HOME/credential-target"; ln -s "$HOME/credential-target" "$cert" ;;
		esac

		: > "$CFTUNNEL_TEST_LOG"
		rc=0
		output="$(cloudflared tunnel list --output json 2>&1)" || rc=$?
		assert_ne "0" "$rc" "binding should fail: $scenario"
		assert_contains "$output" "binding check failed" "binding error: $scenario"
		assert_eq "" "$(cat "$CFTUNNEL_TEST_LOG")" "cloudflared must not execute: $scenario"
		teardown_mock_home
	done
}

test_zone_remove_preserves_local_files_when_binding_or_remote_delete_fails() {
	local scenario output rc yaml uuid_file sudo_log
	for scenario in binding_failure remote_failure; do
		(
			setup_mock_home
			make_fake_cloudflared
			ZONE="example.com"
			NAME="demo"
			ensure_template() { return 0; }
			sudo_log="$HOME/sudo.log"
			sudo() { printf '%s\n' "$*" >> "$sudo_log"; return 0; }

			mkdir -p "$HOME/.cloudflared/zones/example.com"
			write_test_token "$HOME/.cloudflared/zones/example.com/cert.pem"
			local hash
			hash="$(credential_sha256 "$HOME/.cloudflared/zones/example.com/cert.pem")"
			write_zone_credential_metadata "$HOME/.cloudflared/zones/example.com/zone.json" "example.com" "$hash" "2026-07-19T00:00:00Z"
			if [[ "$scenario" == binding_failure ]]; then
				rm -f -- "$HOME/.cloudflared/zones/example.com/zone.json"
			else
				export CFTUNNEL_TEST_MODE="delete_fail"
			fi

			yaml="$HOME/.cloudflared/zones/example.com/demo.yml"
			uuid_file="$HOME/.cloudflared/zones/example.com/12345678.json"
			printf '%s\n' 'tunnel: 12345678' > "$yaml"
			printf '%s\n' '{}' > "$uuid_file"
			: > "$CFTUNNEL_TEST_LOG"

			rc=0
			output="$(printf '%s' y | op_remove 2>&1)" || rc=$?
			assert_ne "0" "$rc" "remove should fail closed: $scenario"
			assert_file_exists "$yaml" "YAML preserved: $scenario"
			assert_file_exists "$uuid_file" "UUID credential preserved: $scenario"
			if [[ "$scenario" == binding_failure ]]; then
				assert_contains "$output" "removal was not started" "binding failure removal error"
				assert_file_not_exists "$sudo_log" "binding failure must precede service changes"
				assert_eq "" "$(cat "$CFTUNNEL_TEST_LOG")" "binding failure must precede cloudflared"
			else
				assert_contains "$output" "local tunnel files were preserved" "remote deletion failure error"
				assert_contains "$(cat "$CFTUNNEL_TEST_LOG")" "tunnel delete demo" "remote delete attempted"
			fi
			teardown_mock_home
		)
	done
}
