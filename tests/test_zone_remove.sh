#!/usr/bin/env bash
# tests/test_zone_remove.sh — Complete zone removal (plan, confirm, teardown)
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

mock_main

readonly ZR_UUID_A="12345678-1234-1234-1234-123456789012"
readonly ZR_UUID_B="87654321-4321-4321-4321-210987654321"
readonly ZR_ZONE_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly ZR_RECORD_ID="$(printf 'b%.0s' {1..32})"

seed_zone_credential() {
	local zone="$1"
	local dir="$HOME/.cloudflared/zones/$zone"
	mkdir -p "$dir"
	printf '%s\n' '-----BEGIN ARGO TUNNEL TOKEN-----' 'VEVTVA==' '-----END ARGO TUNNEL TOKEN-----' > "$dir/cert.pem"
	chmod 600 "$dir/cert.pem"
	local fingerprint
	fingerprint="$(sha256sum "$dir/cert.pem" | awk '{print $1}')"
	write_zone_credential_metadata "$dir/zone.json" "$zone" "$fingerprint" "2026-10-19T00:00:00Z"
	chmod 600 "$dir/zone.json"
}

seed_tunnel() {
	local zone="$1" name="$2" uuid="$3" hostname="$4"
	local dir="$HOME/.cloudflared/zones/$zone"
	printf '%s\n' 'credential-placeholder' > "$dir/$uuid.json"
	chmod 600 "$dir/$uuid.json"
	printf '%s\n' \
		"tunnel: $uuid" \
		"credentials-file: $dir/$uuid.json" \
		"" \
		"ingress:" \
		"  - hostname: \"$hostname\"" \
		"    service: \"http://localhost:3000\"" \
		"  - service: http_status:404" > "$dir/$name.yml"
	chmod 600 "$dir/$name.yml"
}

seed_default_zone() {
	printf '%s\n' "$1" > "$DEFAULT_ZONE_FILE"
	chmod 600 "$DEFAULT_ZONE_FILE"
}

# ── Plan ──

test_zone_remove_plan_is_local_only() {
	setup_mock_home
	local side_effect_log="$HOME/side-effects.log"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com
	cloudflared_for_zone() { printf 'cloudflared %s\n' "$*" >> "$side_effect_log"; return 99; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	zone_remove_systemctl() { printf 'systemctl %s\n' "$*" >> "$side_effect_log"; return 0; }
	zone_remove_cf_api() { printf 'api %s\n' "$*" >> "$side_effect_log"; return 1; }

	local output rc=0
	output="$(op_zone remove Example.COM. --plan 2>&1)" || rc=$?
	assert_eq "0" "$rc" "plan must succeed"
	assert_file_not_exists "$side_effect_log" "plan must not touch sudo, cloudflared, systemd, or the API"
	assert_contains "$output" "Zone removal plan: example.com" "canonical plan header"
	assert_contains "$output" "cloudflared@example.com_api.service" "unit listed"
	assert_contains "$output" "api.example.com → http://localhost:3000" "route listed"
	assert_contains "$output" "will be cleared" "default pointer effect listed"
	assert_contains "$output" "No changes have been made." "plan is side-effect free"
	assert_contains "$output" "manual (no usable CF_API_TOKEN)" "DNS downgraded without a token"
	assert_dir_exists "$HOME/.cloudflared/zones/example.com" "zone preserved by plan"
	assert_file_exists "$DEFAULT_ZONE_FILE" "default pointer preserved by plan"

	teardown_mock_home
}

test_zone_remove_plan_json_contract() {
	setup_mock_home
	OUTPUT_FORMAT=json
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com
	cloudflared_for_zone() { echo "must not run" >&2; return 99; }
	sudo() { echo "must not run" >&2; return 1; }

	local output rc=0
	output="$(op_zone remove example.com --plan)" || rc=$?
	assert_eq "0" "$rc" "json plan must succeed"
	assert_eq "1" "$(jq -r '.schema_version' <<< "$output")" "schema version"
	assert_eq "zone.remove.plan" "$(jq -r '.operation' <<< "$output")" "operation"
	assert_eq "true" "$(jq -r '.ok' <<< "$output")" "ok"
	assert_eq "example.com" "$(jq -r '.data.zone' <<< "$output")" "canonical zone"
	assert_eq "1" "$(jq -r '.data.tunnels | length' <<< "$output")" "tunnel inventory"
	assert_eq "$ZR_UUID_A" "$(jq -r '.data.tunnels[0].uuid' <<< "$output")" "tunnel uuid"
	assert_eq "$HOME/.cloudflared/zones/example.com" "$(jq -r '.data.zone_dir' <<< "$output")" "zone directory"
	assert_eq "ready" "$(jq -r '.data.credential.state' <<< "$output")" "credential state"
	assert_eq "true" "$(jq -r '.data.default_zone.will_clear' <<< "$output")" "default pointer effect"
	assert_eq "manual" "$(jq -r '.data.dns.mode' <<< "$output")" "dns mode without token"
	assert_eq "api.example.com" "$(jq -r '.data.dns.records[0].hostname' <<< "$output")" "dns record hostname"
	assert_eq "${ZR_UUID_A}.cfargotunnel.com" "$(jq -r '.data.dns.records[0].content' <<< "$output")" "dns record content"
	assert_eq "true" "$(jq -r '.data.privilege.sudo_required' <<< "$output")" "privilege requirement"
	assert_dir_exists "$HOME/.cloudflared/zones/example.com" "zone preserved by json plan"

	teardown_mock_home
}

# ── Target validation ──

test_zone_remove_requires_an_explicit_target() {
	setup_mock_home
	seed_zone_credential example.com
	seed_default_zone example.com

	local output rc=0
	output="$(op_zone remove 2>&1)" || rc=$?
	assert_ne "0" "$rc" "missing target must fail"
	assert_contains "$output" "Usage: cftunnel zone remove <domain>" "usage guidance"
	assert_file_exists "$DEFAULT_ZONE_FILE" "must not clear the default pointer implicitly"
	assert_dir_exists "$HOME/.cloudflared/zones/example.com" "must not delete anything implicitly"

	teardown_mock_home
}

test_zone_remove_rejects_unknown_or_conflicting_flags() {
	setup_mock_home
	seed_zone_credential example.com

	local output rc
	rc=0
	output="$(op_zone remove example.com --bogus 2>&1)" || rc=$?
	assert_ne "0" "$rc" "unknown flag must fail"
	assert_contains "$output" "unknown zone remove flag: --bogus" "unknown flag message"

	rc=0
	output="$(op_zone remove example.com --plan --yes 2>&1)" || rc=$?
	assert_ne "0" "$rc" "--plan with --yes must fail"
	assert_contains "$output" "choose only one of --plan or --yes" "conflicting flags message"

	teardown_mock_home
}

test_zone_remove_rejects_unregistered_and_bad_targets() {
	setup_mock_home
	local output rc

	rc=0
	output="$(op_zone remove other.example --plan 2>&1)" || rc=$?
	assert_ne "0" "$rc" "unregistered zone must fail"
	assert_contains "$output" "is not registered" "unregistered zone message"

	mkdir -p "$HOME/elsewhere/example.com"
	ln -s "$HOME/elsewhere/example.com" "$HOME/.cloudflared/zones/linked.example"
	rc=0
	output="$(op_zone remove linked.example --plan 2>&1)" || rc=$?
	assert_ne "0" "$rc" "symlinked zone directory must fail"
	assert_contains "$output" "refusing to remove a symlinked zone directory" "symlink message"

	teardown_mock_home
}

test_zone_remove_refuses_invalid_local_tunnel_state() {
	setup_mock_home
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	printf '%s\n' 'tunnel: not-a-uuid' 'credentials-file: /tmp/nope.json' > "$zone_dir/broken.yml"

	local output rc=0
	output="$(op_zone remove example.com --plan 2>&1)" || rc=$?
	assert_ne "0" "$rc" "invalid tunnel UUID must fail closed"
	assert_contains "$output" "no valid tunnel UUID" "invalid uuid message"
	assert_contains "$output" "no zone state was changed" "fail-closed message"
	assert_dir_exists "$zone_dir" "nothing removed"

	teardown_mock_home
}

# ── Confirmation ──

test_zone_remove_confirmation_requires_the_exact_zone_name() {
	setup_mock_home
	local side_effect_log="$HOME/side-effects.log"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com
	cloudflared_for_zone() { printf 'cloudflared %s\n' "$*" >> "$side_effect_log"; return 0; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	zone_remove_systemctl() { printf 'systemctl %s\n' "$*" >> "$side_effect_log"; return 0; }

	local output rc=0
	output="$(printf 'Example.com\n' | op_zone remove example.com 2>&1)" || rc=$?
	assert_eq "0" "$rc" "wrong confirmation aborts without error"
	assert_contains "$output" "Aborted by user: confirmation did not match 'example.com'" "abort message"
	assert_file_not_exists "$side_effect_log" "abort must have no side effects"
	assert_dir_exists "$HOME/.cloudflared/zones/example.com" "zone preserved after abort"
	assert_file_exists "$HOME/.cloudflared/zones/example.com/api.yml" "yaml preserved after abort"
	assert_file_exists "$DEFAULT_ZONE_FILE" "default pointer preserved after abort"

	# EOF without any input must abort too.
	rc=0
	output="$(op_zone remove example.com < /dev/null 2>&1)" || rc=$?
	assert_eq "0" "$rc" "empty confirmation aborts without error"
	assert_contains "$output" "Aborted by user." "empty input abort message"
	assert_file_not_exists "$side_effect_log" "empty confirmation has no side effects"

	teardown_mock_home
}

# ── Full teardown ──

test_zone_remove_performs_the_complete_teardown() {
	setup_mock_home
	local side_effect_log="$HOME/side-effects.log"
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com
	touch "$HOME/.cloudflared/cert.pem"
	echo "other-zone" > "$HOME/.cloudflared/.other"

	cloudflared_for_zone() {
		printf 'cloudflared %s\n' "$*" >> "$side_effect_log"
		shift
		case "$*" in
		"tunnel list --output json")
			printf '[{"id":"%s","name":"api"}]\n' "$ZR_UUID_A"
			;;
		"tunnel delete $ZR_UUID_A") printf 'deleted\n' ;;
		*) printf 'unexpected cloudflared call\n' >&2; return 2 ;;
		esac
	}
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	zone_remove_systemctl() { printf 'systemctl %s\n' "$*" >> "$side_effect_log"; return 0; }
	zone_remove_cf_api() {
		printf 'api %s %s\n' "$1" "$2" >> "$side_effect_log"
		case "$1 $2" in
		GET*"/zones?name="*)
			printf '{"success":true,"result":[{"id":"%s"}]}\n' "$ZR_ZONE_ID"
			;;
		GET*"/dns_records?name="*)
			printf '{"success":true,"result":[{"id":"%s","type":"CNAME","name":"api.example.com","content":"%s.cfargotunnel.com"}]}\n' "$ZR_RECORD_ID" "$ZR_UUID_A"
			;;
		DELETE*)
			printf '{"success":true,"result":{}}\n'
			;;
		*)
			printf '{"success":false,"errors":[{"message":"unexpected url"}]}\n'
			return 0
			;;
		esac
	}
	export CF_API_TOKEN="test-token"

	local output rc=0
	output="$(printf 'example.com\n' | op_zone remove example.com 2>&1)" || rc=$?
	assert_eq "0" "$rc" "teardown must succeed: $output"
	assert_contains "$output" "✅ zone 'example.com' removed" "success summary"

	assert_dir_not_exists "$zone_dir" "zone directory removed"
	assert_file_not_exists "$DEFAULT_ZONE_FILE" "default pointer cleared"
	assert_file_exists "$HOME/.cloudflared/cert.pem" "root credential untouched"
	assert_file_exists "$HOME/.cloudflared/.other" "unrelated file untouched"

	local order
	order="$(cat "$side_effect_log")"
	assert_contains "$order" "cloudflared example.com tunnel list --output json" "remote verification first"
	assert_contains "$order" "sudo -v" "sudo authorized"
	assert_contains "$order" "systemctl disable --now cloudflared@example.com_api.service" "unit stopped"
	assert_contains "$order" "cloudflared example.com tunnel delete $ZR_UUID_A" "tunnel deleted by uuid"
	assert_contains "$order" "api DELETE https://api.cloudflare.com/client/v4/zones/$ZR_ZONE_ID/dns_records/$ZR_RECORD_ID" "matching DNS record deleted"
	local list_line delete_line dns_line
	list_line="$(grep -n 'tunnel list' "$side_effect_log" | head -1 | cut -d: -f1)"
	delete_line="$(grep -n 'tunnel delete' "$side_effect_log" | head -1 | cut -d: -f1)"
	dns_line="$(grep -n 'api DELETE' "$side_effect_log" | head -1 | cut -d: -f1)"
	if [[ -z "$list_line" || -z "$delete_line" || -z "$dns_line" || "$list_line" -ge "$delete_line" || "$delete_line" -ge "$dns_line" ]]; then
		echo "ASSERT FAIL [teardown order]: list=$list_line delete=$delete_line dns=$dns_line" >&2
		exit 1
	fi

	unset CF_API_TOKEN
	teardown_mock_home
}

test_zone_remove_summary_json_contract() {
	setup_mock_home
	OUTPUT_FORMAT=json
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com
	cloudflared_for_zone() {
		shift
		case "$*" in
		"tunnel list --output json") printf '[{"id":"%s","name":"api"}]\n' "$ZR_UUID_A" ;;
		"tunnel delete $ZR_UUID_A") printf 'deleted\n' ;;
		esac
	}
	sudo() { return 0; }
	zone_remove_systemctl() { return 0; }

	local output rc=0
	output="$(op_zone remove example.com --yes)" || rc=$?
	assert_eq "0" "$rc" "json teardown must succeed: $output"
	assert_eq "zone.remove" "$(jq -r '.operation' <<< "$output")" "operation"
	assert_eq "example.com" "$(jq -r '.data.zone' <<< "$output")" "zone"
	assert_eq "api" "$(jq -r '.data.removed.tunnels[0]' <<< "$output")" "removed tunnel"
	assert_eq "true" "$(jq -r '.data.removed.default_zone_cleared' <<< "$output")" "default cleared flag"
	assert_eq "manual" "$(jq -r '.data.dns.mode' <<< "$output")" "dns mode without token"
	assert_dir_not_exists "$zone_dir" "zone directory removed"

	teardown_mock_home
}

test_zone_remove_without_token_keeps_dns_for_manual_removal() {
	setup_mock_home
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	cloudflared_for_zone() {
		shift
		case "$*" in
		"tunnel list --output json") printf '[{"id":"%s","name":"api"}]\n' "$ZR_UUID_A" ;;
		"tunnel delete $ZR_UUID_A") printf 'deleted\n' ;;
		esac
	}
	sudo() { return 0; }
	zone_remove_systemctl() { return 0; }
	zone_remove_cf_api() { echo "api must not run without a token" >&2; return 1; }

	local output rc=0
	output="$(op_zone remove example.com --yes 2>&1)" || rc=$?
	assert_eq "0" "$rc" "teardown without a token must succeed: $output"
	assert_contains "$output" "DNS left  : api.example.com (remove it manually)" "manual DNS record listed"
	assert_contains "$output" "CF_API_TOKEN is not available" "manual DNS warning"
	assert_dir_not_exists "$zone_dir" "zone directory removed anyway"

	teardown_mock_home
}

# ── Fail-closed behaviour ──

test_zone_remove_remote_list_failure_changes_nothing() {
	setup_mock_home
	local side_effect_log="$HOME/side-effects.log"
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com
	cloudflared_for_zone() { printf 'cloudflared %s\n' "$*" >> "$side_effect_log"; return 42; }
	sudo() { printf 'sudo %s\n' "$*" >> "$side_effect_log"; return 0; }
	zone_remove_systemctl() { printf 'systemctl %s\n' "$*" >> "$side_effect_log"; return 0; }

	local output rc=0
	output="$(op_zone remove example.com --yes 2>&1)" || rc=$?
	assert_ne "0" "$rc" "remote list failure must stop the teardown"
	assert_contains "$output" "could not query Cloudflare tunnels" "list failure message"
	assert_contains "$output" "no zone state was changed" "fail-closed guarantee"
	assert_dir_exists "$zone_dir" "zone directory preserved"
	assert_file_exists "$zone_dir/api.yml" "yaml preserved"
	assert_file_exists "$zone_dir/cert.pem" "zone credential preserved"
	assert_file_exists "$DEFAULT_ZONE_FILE" "default pointer preserved"
	assert_eq "cloudflared example.com tunnel list --output json" "$(cat "$side_effect_log")" "nothing after the failed list"

	teardown_mock_home
}

test_zone_remove_tunnel_delete_failure_preserves_that_tunnel() {
	setup_mock_home
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_tunnel example.com web "$ZR_UUID_B" web.example.com
	seed_default_zone example.com
	cloudflared_for_zone() {
		shift
		case "$*" in
		"tunnel list --output json")
			printf '[{"id":"%s","name":"api"},{"id":"%s","name":"web"}]\n' "$ZR_UUID_A" "$ZR_UUID_B"
			;;
		"tunnel delete $ZR_UUID_A") printf 'deleted\n' ;;
		"tunnel delete $ZR_UUID_B") printf 'nope\n' >&2; return 42 ;;
		esac
	}
	sudo() { return 0; }
	zone_remove_systemctl() { return 0; }

	local output rc=0
	output="$(op_zone remove example.com --yes 2>&1)" || rc=$?
	assert_ne "0" "$rc" "delete failure must stop the teardown"
	assert_contains "$output" "Cloudflare tunnel deletion failed for 'web'" "delete failure message"
	assert_contains "$output" "its local files were preserved" "preservation guarantee"
	assert_contains "$output" "tunnel 'api' deleted from Cloudflare" "progress report"
	assert_file_not_exists "$zone_dir/api.yml" "first tunnel yaml removed"
	assert_file_exists "$zone_dir/web.yml" "failed tunnel yaml preserved"
	assert_file_exists "$zone_dir/$ZR_UUID_B.json" "failed tunnel credential preserved"
	assert_file_exists "$zone_dir/cert.pem" "zone credential preserved"
	assert_file_exists "$DEFAULT_ZONE_FILE" "default pointer preserved"
	assert_dir_exists "$zone_dir" "zone directory preserved"

	teardown_mock_home
}

test_zone_remove_dns_failure_preserves_remaining_local_files() {
	setup_mock_home
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com
	cloudflared_for_zone() {
		shift
		case "$*" in
		"tunnel list --output json") printf '[{"id":"%s","name":"api"}]\n' "$ZR_UUID_A" ;;
		"tunnel delete $ZR_UUID_A") printf 'deleted\n' ;;
		esac
	}
	sudo() { return 0; }
	zone_remove_systemctl() { return 0; }
	zone_remove_cf_api() {
		case "$1 $2" in
		GET*"/zones?name="*)
			printf '{"success":true,"result":[{"id":"%s"}]}\n' "$ZR_ZONE_ID"
			;;
		GET*"/dns_records?name="*)
			printf '{"success":true,"result":[{"id":"%s","type":"CNAME","name":"api.example.com","content":"%s.cfargotunnel.com"}]}\n' "$ZR_RECORD_ID" "$ZR_UUID_A"
			;;
		DELETE*)
			printf '{"success":false,"errors":[{"message":"rate limited"}]}\n'
			;;
		esac
	}
	export CF_API_TOKEN="test-token"

	local output rc=0
	output="$(op_zone remove example.com --yes 2>&1)" || rc=$?
	assert_ne "0" "$rc" "DNS failure must stop the teardown"
	assert_contains "$output" "DNS removal failed for 'api.example.com'" "dns failure message"
	assert_contains "$output" "local files were preserved" "preservation guarantee"
	assert_file_exists "$zone_dir/api.yml" "yaml preserved for a safe re-run"
	assert_file_exists "$zone_dir/$ZR_UUID_A.json" "credential preserved for a safe re-run"
	assert_file_exists "$zone_dir/cert.pem" "zone credential preserved"
	assert_file_exists "$DEFAULT_ZONE_FILE" "default pointer preserved"
	assert_dir_exists "$zone_dir" "zone directory preserved"

	unset CF_API_TOKEN
	teardown_mock_home
}

test_zone_remove_rerun_after_partial_deletion_finishes_the_job() {
	setup_mock_home
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com
	cloudflared_for_zone() {
		shift
		case "$*" in
		"tunnel list --output json") printf '[]\n' ;;
		"tunnel delete "*) printf 'must not delete twice\n' >&2; return 9 ;;
		esac
	}
	sudo() { return 0; }
	zone_remove_systemctl() { return 0; }
	zone_remove_cf_api() {
		case "$1 $2" in
		GET*"/zones?name="*) printf '{"success":true,"result":[{"id":"%s"}]}\n' "$ZR_ZONE_ID" ;;
		GET*"/dns_records?name="*) printf '{"success":true,"result":[]}\n' ;;
		esac
	}
	export CF_API_TOKEN="test-token"

	local output rc=0
	output="$(op_zone remove example.com --yes 2>&1)" || rc=$?
	assert_eq "0" "$rc" "re-run after a partial teardown must succeed: $output"
	assert_contains "$output" "is already absent from Cloudflare" "idempotent remote deletion"
	assert_dir_not_exists "$zone_dir" "zone finally removed"
	assert_file_not_exists "$DEFAULT_ZONE_FILE" "default pointer finally cleared"

	unset CF_API_TOKEN
	teardown_mock_home
}

test_zone_remove_never_touches_records_owned_by_other_targets() {
	setup_mock_home
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	local side_effect_log="$HOME/api.log"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	cloudflared_for_zone() {
		shift
		case "$*" in
		"tunnel list --output json") printf '[{"id":"%s","name":"api"}]\n' "$ZR_UUID_A" ;;
		"tunnel delete $ZR_UUID_A") printf 'deleted\n' ;;
		esac
	}
	sudo() { return 0; }
	zone_remove_systemctl() { return 0; }
	zone_remove_cf_api() {
		printf '%s %s\n' "$1" "$2" >> "$side_effect_log"
		case "$1 $2" in
		GET*"/zones?name="*) printf '{"success":true,"result":[{"id":"%s"}]}\n' "$ZR_ZONE_ID" ;;
		GET*"/dns_records?name="*)
			printf '{"success":true,"result":['
			printf '{"id":"%s","type":"CNAME","name":"api.example.com","content":"%s.cfargotunnel.com"},' "$ZR_RECORD_ID" "$ZR_UUID_A"
			printf '{"id":"cccccccccccccccccccccccccccccccc","type":"CNAME","name":"api.example.com","content":"someone-elses.cfargotunnel.com"},'
			printf '{"id":"dddddddddddddddddddddddddddddddd","type":"A","name":"api.example.com","content":"203.0.113.10"}]}\n'
			;;
		DELETE*) printf '{"success":true,"result":{}}\n' ;;
		esac
	}
	export CF_API_TOKEN="test-token"

	local output rc=0
	output="$(op_zone remove example.com --yes 2>&1)" || rc=$?
	assert_eq "0" "$rc" "teardown must succeed: $output"
	assert_contains "$output" "left untouched" "foreign record reported"
	assert_contains "$output" "points to 'someone-elses.cfargotunnel.com'" "foreign content reported"
	local deletes
	deletes="$(grep -c '^DELETE ' "$side_effect_log")"
	assert_eq "1" "$deletes" "only the owned record may be deleted"
	assert_contains "$(grep '^DELETE ' "$side_effect_log")" "/dns_records/$ZR_RECORD_ID" "deleted record id"

	unset CF_API_TOKEN
	teardown_mock_home
}

test_zone_remove_preserves_the_default_pointer_when_it_points_elsewhere() {
	setup_mock_home
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	local other_dir="$HOME/.cloudflared/zones/other.example"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	mkdir -p "$other_dir"
	seed_default_zone other.example
	cloudflared_for_zone() {
		shift
		case "$*" in
		"tunnel list --output json") printf '[{"id":"%s","name":"api"}]\n' "$ZR_UUID_A" ;;
		"tunnel delete $ZR_UUID_A") printf 'deleted\n' ;;
		esac
	}
	sudo() { return 0; }
	zone_remove_systemctl() { return 0; }

	local output rc=0
	output="$(op_zone remove example.com --yes 2>&1)" || rc=$?
	assert_eq "0" "$rc" "teardown must succeed: $output"
	assert_contains "$output" "default   : unchanged" "default untouched summary"
	assert_dir_not_exists "$zone_dir" "target zone removed"
	assert_dir_exists "$other_dir" "other zone preserved"
	assert_eq "other.example" "$(cat "$DEFAULT_ZONE_FILE")" "default pointer preserved"

	teardown_mock_home
}

test_zone_unset_keeps_only_the_pointer_and_is_no_longer_zone_removal() {
	setup_mock_home
	local zone_dir="$HOME/.cloudflared/zones/example.com"
	seed_zone_credential example.com
	seed_default_zone example.com

	op_zone unset
	assert_file_not_exists "$DEFAULT_ZONE_FILE" "zone unset clears the pointer"
	assert_dir_exists "$zone_dir" "zone unset preserves the zone"

	local output rc=0
	output="$(op_zone remove 2>&1)" || rc=$?
	assert_ne "0" "$rc" "zone remove without a target fails"
	assert_contains "$output" "Usage: cftunnel zone remove <domain>" "zone remove is the destructive command now"
	assert_dir_exists "$zone_dir" "zone remove never falls back to the active zone"

	teardown_mock_home
}

# ── CLI dispatch ──

test_zone_remove_cli_dispatch_is_local_and_json_capable() {
	setup_mock_home
	local fake_bin="$HOME/fake-bin"
	local call_log="$HOME/cli-side-effects.log"
	mkdir -p "$fake_bin"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'printf "%s\n" "$*" >> "'"$call_log"'"' \
		'exit 99' > "$fake_bin/cloudflared"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "'"$call_log"'"' 'exit 99' > "$fake_bin/sudo"
	chmod +x "$fake_bin/cloudflared" "$fake_bin/sudo"
	seed_zone_credential example.com
	seed_tunnel example.com api "$ZR_UUID_A" api.example.com
	seed_default_zone example.com

	local output rc=0
	output="$(
		PATH="$fake_bin:$PATH" RUN_USER="cftunnel-test-user-that-does-not-exist" \
			CFTUNNEL_SKIP_MAIN="" "$PROJECT_DIR/run.sh" zone remove Example.COM. --plan --output json 2>&1
	)" || rc=$?
	assert_eq "0" "$rc" "cli plan dispatch must succeed: $output"
	assert_contains "$output" '"operation":"zone.remove.plan"' "cli plan operation"
	assert_contains "$output" '"zone":"example.com"' "cli plan canonical zone"
	assert_file_not_exists "$call_log" "plan must not invoke sudo or cloudflared"
	assert_dir_exists "$HOME/.cloudflared/zones/example.com" "zone preserved"

	rc=0
	output="$(
		PATH="$fake_bin:$PATH" RUN_USER="cftunnel-test-user-that-does-not-exist" \
			CFTUNNEL_SKIP_MAIN="" "$PROJECT_DIR/run.sh" zone remove other.example --plan 2>&1
	)" || rc=$?
	assert_ne "0" "$rc" "cli rejects an unregistered zone"
	assert_contains "$output" "is not registered" "cli unregistered message"

	teardown_mock_home
}
