[[ -z "${_CFTUNNEL_ZONE_REMOVE_LOADED:-}" ]] || return 0
_CFTUNNEL_ZONE_REMOVE_LOADED=1

# zone remove — complete teardown of one registered zone.
# Design record: spec/tdd-zone-removal-CFTUNNEL-024.md
#
# Every destructive decision is derived from local files. Remote listings only
# answer "does this tunnel still exist?" before it is deleted, and DNS records
# are deleted only when they point at a tunnel UUID owned by this zone.

ZONE_REMOVE_TARGET=""
ZONE_REMOVE_PLAN=false
ZONE_REMOVE_YES=false
ZONE_REMOVE_ABORTED=false
ZONE_REMOVE_PROGRESS=()
ZONE_REMOVE_DELETED_DNS='[]'

# Progress goes to stdout in text mode and to stderr in JSON mode, so the
# envelope stays the only thing a JSON consumer ever parses.
zone_remove_note() {
	if json_enabled; then
		printf '%s\n' "$*" >&2
	else
		printf '%s\n' "$*"
	fi
}

zone_remove_parse_args() {
	ZONE_REMOVE_TARGET=""
	ZONE_REMOVE_PLAN=false
	ZONE_REMOVE_YES=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--plan) ZONE_REMOVE_PLAN=true; shift ;;
		--yes) ZONE_REMOVE_YES=true; shift ;;
		-h | --help) print_usage; exit 0 ;;
		-*) die "unknown zone remove flag: $1" ;;
		*)
			[[ -z "$ZONE_REMOVE_TARGET" ]] || die "Usage: cftunnel zone remove <domain> [--plan|--yes]"
			ZONE_REMOVE_TARGET="$1"
			shift
			;;
		esac
	done

	[[ "$ZONE_REMOVE_PLAN" == false || "$ZONE_REMOVE_YES" == false ]] || die "choose only one of --plan or --yes"
	[[ -n "$ZONE_REMOVE_TARGET" ]] || die "Usage: cftunnel zone remove <domain> [--plan|--yes]"
}

zone_remove_resolve_target() {
	local raw="${ZONE_REMOVE_TARGET:-}"
	[[ -n "$raw" ]] || die "Usage: cftunnel zone remove <domain> [--plan|--yes]"
	local canonical
	canonical="$(validate_zone_name "$raw")" || return 1
	printf '%s\n' "$canonical"
}

# The target must be a real directory directly inside the canonical zones
# root. A symlink, a path that resolves elsewhere, or an unregistered zone
# stops the command before anything is listed or removed.
zone_remove_assert_dir() {
	local canonical="${1:-}"
	[[ -n "$canonical" ]] || return 1
	local dir parent real parent_real
	dir="$(zone_dir_for "$canonical")"
	if [[ ! -d "$dir" ]]; then
		echo "error: zone '$canonical' is not registered (no local directory at $dir)" >&2
		return 1
	fi
	if [[ -L "$dir" ]]; then
		echo "error: refusing to remove a symlinked zone directory: $dir" >&2
		return 1
	fi
	parent="$(dirname "$dir")"
	real="$(readlink -f -- "$dir" 2>/dev/null)" || return 1
	parent_real="$(readlink -f -- "$parent" 2>/dev/null)" || return 1
	if [[ "$real" != "$parent_real/$canonical" ]]; then
		echo "error: zone directory resolves outside the zones root: $real" >&2
		return 1
	fi
	printf '%s\n' "$dir"
}

zone_remove_unit_name() {
	printf 'cloudflared@%s_%s.service\n' "${1:-}" "${2:-}"
}

zone_remove_url_encode() {
	local LC_ALL=C
	local value="${1:-}" out="" char i
	for ((i = 0; i < ${#value}; i++)); do
		char="${value:i:1}"
		case "$char" in
		[a-zA-Z0-9.~_-]) out+="$char" ;;
		*)
			printf -v char '%%%02X' "'$char"
			out+="$char"
			;;
		esac
	done
	printf '%s\n' "$out"
}

# DNS deletion is optional: it is offered only when every piece it needs is
# present. A missing capability downgrades the plan to "manual", never to a
# failure, so a zone can always be removed locally.
zone_remove_dns_mode() {
	if [[ -n "${CF_API_TOKEN:-}" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
		printf '%s\n' automatic
	else
		printf '%s\n' manual
	fi
}

zone_remove_progress_note() {
	ZONE_REMOVE_PROGRESS+=("$1")
}

zone_remove_progress_report() {
	[[ ${#ZONE_REMOVE_PROGRESS[@]} -gt 0 ]] || return 0
	echo "Progress already made:" >&2
	local line
	for line in "${ZONE_REMOVE_PROGRESS[@]}"; do
		echo "  - $line" >&2
	done
}

zone_remove_fail() {
	zone_remove_progress_report
	die "$*"
}

zone_remove_systemctl() {
	if [[ $EUID -eq 0 ]]; then
		systemctl "$@"
	else
		sudo systemctl "$@"
	fi
}

# Build the complete removal inventory as JSON. Read-only: no sudo, no
# network, no file mutation.
zone_remove_inventory() {
	local canonical="${1:-}"
	local dir="${2:-}"
	need jq

	local default_zone credential_state dns_mode token_present
	local tunnels_json='[]' records_json='[]' warnings_json='[]'
	local known_count=0 other_count=0 total_count=0
	local -A seen_uuids=()
	local yaml name raw uuid cred unit routes_json entry base
	local hostname service tunnel_count will_clear=false

	while IFS= read -r -d '' yaml; do
		name="$(basename "$yaml" .yml)"
		raw="$(tunnel_uuid_from_yaml "$yaml")"
		uuid="$(validate_tunnel_uuid "${raw:-}" 2>/dev/null || true)"
		if [[ -z "$uuid" ]]; then
			echo "error: tunnel '${name}' declares no valid tunnel UUID in $yaml" >&2
			echo "       correct that file first; no zone state was changed" >&2
			return 1
		fi
		if [[ -n "${seen_uuids[$uuid]:-}" ]]; then
			echo "error: tunnels '${seen_uuids[$uuid]}' and '${name}' claim the same tunnel UUID" >&2
			echo "       resolve the duplicate first; no zone state was changed" >&2
			return 1
		fi
		seen_uuids[$uuid]="$name"

		cred="$(credentials_file_from_yaml "$yaml")"
		unit="$(zone_remove_unit_name "$canonical" "$name")"
		routes_json='[]'
		while IFS=$'\t' read -r hostname service; do
			[[ -n "$hostname" && -n "$service" ]] || continue
			routes_json="$(jq -cn --argjson routes "$routes_json" --arg hostname "$hostname" --arg service "$service" '$routes + [{hostname: $hostname, service: $service}]')"
			records_json="$(jq -cn --argjson records "$records_json" --arg hostname "$hostname" --arg content "${uuid}.cfargotunnel.com" '$records + [{hostname: $hostname, content: $content}]')"
		done < <(ingress_routes_from_yaml "$yaml")

		tunnels_json="$(jq -cn \
			--argjson tunnels "$tunnels_json" \
			--arg name "$name" \
			--arg uuid "$uuid" \
			--arg unit "$unit" \
			--arg yaml "$yaml" \
			--arg credential "$cred" \
			--argjson routes "$routes_json" \
			'$tunnels + [{name: $name, uuid: $uuid, unit: $unit, yaml: $yaml, credential: $credential, routes: $routes}]')"

		if [[ -n "$cred" && ! -f "$cred" ]]; then
			warnings_json="$(jq -cn --argjson warnings "$warnings_json" --arg message "tunnel '${name}' credential file is missing: $cred" '$warnings + [$message]')"
		fi
	done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*.yml' -print0 | sort -z)

	while IFS= read -r -d '' entry; do
		base="$(basename "$entry")"
		case "$base" in
		cert.pem | *.yml | *.json) known_count=$((known_count + 1)) ;;
		*) other_count=$((other_count + 1)) ;;
		esac
	done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 | sort -z)
	total_count=$((known_count + other_count))

	records_json="$(jq -c 'unique_by([.hostname, .content])' <<< "$records_json")"
	credential_state="$(zone_credential_state "$canonical")"
	default_zone="$(load_default_zone)" || return 1
	dns_mode="$(zone_remove_dns_mode)"
	token_present=false
	if [[ -n "${CF_API_TOKEN:-}" ]]; then
		token_present=true
	fi

	tunnel_count="$(jq -r 'length' <<< "$tunnels_json")"
	if [[ "$tunnel_count" -gt 0 && "$credential_state" != ready ]]; then
		warnings_json="$(jq -cn --argjson warnings "$warnings_json" --arg message "zone credential state is '$credential_state'; remote deletion will be refused" '$warnings + [$message]')"
	fi
	if [[ "$tunnel_count" -gt 0 && "$dns_mode" == manual ]]; then
		warnings_json="$(jq -cn --argjson warnings "$warnings_json" --arg message "CF_API_TOKEN is not available; DNS records must be removed manually" '$warnings + [$message]')"
	fi
	if [[ "$default_zone" == "$canonical" ]]; then
		will_clear=true
	fi

	jq -cn \
		--arg zone "$canonical" \
		--arg zone_dir "$dir" \
		--argjson tunnels "$tunnels_json" \
		--argjson known "$known_count" \
		--argjson other "$other_count" \
		--argjson total "$total_count" \
		--arg credential_state "$credential_state" \
		--arg default_zone "$default_zone" \
		--argjson will_clear "$will_clear" \
		--arg dns_mode "$dns_mode" \
		--argjson token_present "$token_present" \
		--argjson records "$records_json" \
		--argjson euid "$EUID" \
		--argjson tunnel_count "$tunnel_count" \
		--argjson warnings "$warnings_json" \
		'{
			zone: $zone,
			zone_dir: $zone_dir,
			tunnels: $tunnels,
			files: {known: $known, other: $other, total: $total},
			credential: {state: $credential_state},
			default_zone: {current: (if $default_zone == "" then null else $default_zone end), will_clear: $will_clear},
			dns: {mode: $dns_mode, token_present: $token_present, records: $records},
			privilege: {sudo_required: (($euid != 0) and ($tunnel_count > 0))},
			warnings: $warnings
		}'
}

zone_remove_print_plan_text() {
	local plan_json="${1:-}"
	local zone dir credential_state default_zone will_clear dns_mode known other total records_count
	zone="$(jq -r '.zone' <<< "$plan_json")"
	dir="$(jq -r '.zone_dir' <<< "$plan_json")"
	credential_state="$(jq -r '.credential.state' <<< "$plan_json")"
	default_zone="$(jq -r '.default_zone.current // ""' <<< "$plan_json")"
	will_clear="$(jq -r '.default_zone.will_clear' <<< "$plan_json")"
	dns_mode="$(jq -r '.dns.mode' <<< "$plan_json")"
	known="$(jq -r '.files.known' <<< "$plan_json")"
	other="$(jq -r '.files.other' <<< "$plan_json")"
	total="$(jq -r '.files.total' <<< "$plan_json")"
	records_count="$(jq -r '.dns.records | length' <<< "$plan_json")"

	echo "Zone removal plan: $zone"
	echo "  Directory : $dir"
	echo "  Credential: $credential_state"
	echo "  Tunnels   : $(jq -r '.tunnels | length' <<< "$plan_json")"
	while IFS= read -r line; do
		echo "$line"
	done < <(jq -r '.tunnels[] | "    - \(.name)  (unit \(.unit))"' <<< "$plan_json")
	while IFS= read -r line; do
		echo "        $line"
	done < <(jq -r '.tunnels[] | .routes[] | "\(.hostname) → \(.service)"' <<< "$plan_json")
	echo "  Files     : $known known, $other other, $total total"
	if [[ "$will_clear" == true ]]; then
		echo "  Default   : '$default_zone' is the persisted default and will be cleared"
	else
		echo "  Default   : '$default_zone' is unaffected"
	fi
	if [[ "$dns_mode" == automatic ]]; then
		echo "  DNS       : automatic (CF_API_TOKEN present) — $records_count record(s) will be deleted"
	else
		echo "  DNS       : manual (no usable CF_API_TOKEN) — remove these by hand:"
		while IFS= read -r line; do
			echo "        $line"
		done < <(jq -r '.dns.records[] | "\(.hostname) → \(.content)"' <<< "$plan_json")
	fi
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		echo "  Warning   : $line"
	done < <(jq -r '.warnings[]' <<< "$plan_json")
	echo "No changes have been made."
}

# Typed confirmation. Only an exact match of the canonical zone name
# continues; --yes skips the typing step and nothing else.
zone_remove_confirm() {
	local canonical="${1:-}"
	if [[ "$ZONE_REMOVE_YES" == true ]]; then
		zone_remove_note "[=] --yes: applying previously reviewed zone removal plan"
		return 0
	fi
	echo >&2
	printf "Type the zone name exactly as '%s' to confirm removal: " "$canonical" >&2
	local answer=""
	if ! read -r answer; then
		echo "Aborted by user."
		ZONE_REMOVE_ABORTED=true
		exit 0
	fi
	if [[ "$answer" != "$canonical" ]]; then
		echo "Aborted by user: confirmation did not match '$canonical'."
		ZONE_REMOVE_ABORTED=true
		exit 0
	fi
	echo >&2
}

# Single Cloudflare API seam. Never logs the token or the Authorization
# header; capability checks happen before this is reached.
zone_remove_cf_api() {
	local method="${1:-}"
	local url="${2:-}"
	command -v curl >/dev/null 2>&1 || return 1
	[[ -n "$method" && -n "$url" ]] || return 1
	[[ -n "${CF_API_TOKEN:-}" ]] || return 1
	curl --silent --show-error --max-time 30 \
		-H "Authorization: Bearer ${CF_API_TOKEN}" \
		-H "Content-Type: application/json" \
		--request "$method" \
		"$url"
}

zone_remove_api_success() {
	local body="${1:-}"
	local message=""
	message="$(jq -r 'if (.success // false) == true then "" else ([.errors[]?.message // empty] | if length == 0 then "unexpected response" else join("; ") end) end' <<< "$body" 2>/dev/null)" || message=""
	if [[ -z "$message" ]]; then
		if jq -e 'type == "object"' <<< "$body" >/dev/null 2>&1; then
			return 0
		fi
		message="unexpected response"
	fi
	echo "error: Cloudflare API request failed: $message" >&2
	return 1
}

zone_remove_resolve_zone_id() {
	local canonical="${1:-}"
	if [[ -n "${CF_ZONE_ID:-}" ]]; then
		[[ "$CF_ZONE_ID" =~ ^[0-9a-fA-F]{32}$ ]] || {
			echo "error: CF_ZONE_ID is not a valid Cloudflare zone id" >&2
			return 1
		}
		printf '%s\n' "${CF_ZONE_ID,,}"
		return 0
	fi

	local body count id
	body="$(zone_remove_cf_api GET "https://api.cloudflare.com/client/v4/zones?name=$(zone_remove_url_encode "$canonical")")" || {
		echo "error: could not query the Cloudflare zone id for '$canonical'" >&2
		return 1
	}
	zone_remove_api_success "$body" || return 1
	count="$(jq -r '.result | length' <<< "$body" 2>/dev/null)" || count=0
	if [[ "$count" != 1 ]]; then
		echo "error: Cloudflare returned ${count} zones named '$canonical'; expected exactly one" >&2
		return 1
	fi
	id="$(jq -r '.result[0].id // ""' <<< "$body" 2>/dev/null)" || id=""
	[[ "$id" =~ ^[0-9a-fA-F]{32}$ ]] || {
		echo "error: Cloudflare returned an unusable zone id for '$canonical'" >&2
		return 1
	}
	printf '%s\n' "${id,,}"
}

# Delete only CNAME records whose name matches this hostname and whose
# content points at this tunnel UUID. Anything else is reported and left
# alone, so an unrelated or manually re-pointed record is never destroyed.
zone_remove_delete_records() {
	local zone_id="${1:-}"
	local hostname="${2:-}"
	local uuid="${3:-}"
	[[ -n "$zone_id" && -n "$hostname" && -n "$uuid" ]] || return 1

	local target_host expected base query body id rtype rname rcontent delete_body
	target_host="${hostname,,}"
	target_host="${target_host%.}"
	expected="${uuid,,}.cfargotunnel.com"
	base="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"
	query="${base}?name=$(zone_remove_url_encode "$hostname")&per_page=100"

	body="$(zone_remove_cf_api GET "$query")" || {
		echo "error: could not list Cloudflare DNS records for '$hostname'" >&2
		return 1
	}
	zone_remove_api_success "$body" || return 1

	while IFS=$'\t' read -r id rtype rname rcontent; do
		[[ -n "$id" && -n "$rtype" && -n "$rname" ]] || continue
		rname="${rname,,}"
		rname="${rname%.}"
		rcontent="${rcontent,,}"
		rcontent="${rcontent%.}"
		[[ "$rtype" == "CNAME" && "$rname" == "$target_host" ]] || continue
		if [[ "$rcontent" != "$expected" ]]; then
			zone_remove_note "[!] DNS record '$rname' points to '$rcontent', not this tunnel; left untouched"
			continue
		fi
		delete_body="$(zone_remove_cf_api DELETE "${base}/${id}")" || {
			echo "error: could not delete Cloudflare DNS record '$rname'" >&2
			return 1
		}
		zone_remove_api_success "$delete_body" || {
			echo "error: could not delete Cloudflare DNS record '$rname'" >&2
			return 1
		}
		ZONE_REMOVE_DELETED_DNS="$(jq -cn --argjson records "$ZONE_REMOVE_DELETED_DNS" --arg name "$rname" '$records + [$name]')"
		zone_remove_note "[+] deleted DNS record '$rname'"
	done < <(jq -r '.result[]? | [.id, .type, .name, (.content // "")] | @tsv' <<< "$body")
	return 0
}

# Executes the confirmed plan. Stops at the first remote failure and keeps
# that tunnel's local files, so a re-run can finish the job: an already
# deleted tunnel is detected before it is deleted again.
zone_remove_apply() {
	local canonical="${1:-}"
	local dir="${2:-}"
	local plan_json="${3:-}"

	local default_zone tunnel_count plan_dns_mode dns_mode remote_json="" zone_id=""
	local removed_tunnels='[]' manual_records='[]' default_cleared=false
	local unit name uuid yaml credential row hostname data
	ZONE_REMOVE_PROGRESS=()
	ZONE_REMOVE_DELETED_DNS='[]'

	default_zone="$(jq -r '.default_zone.current // ""' <<< "$plan_json")"
	tunnel_count="$(jq -r '.tunnels | length' <<< "$plan_json")"
	plan_dns_mode="$(jq -r '.dns.mode' <<< "$plan_json")"
	dns_mode="$(zone_remove_dns_mode)"
	if [[ "$plan_dns_mode" != "$dns_mode" ]]; then
		zone_remove_note "[=] DNS mode is now '$dns_mode' (the plan reported '$plan_dns_mode')"
	fi

	if [[ "$tunnel_count" -gt 0 ]]; then
		local cert="$HOME_DIR/.cloudflared/zones/$canonical/cert.pem"
		verify_zone_credential_binding "$canonical" "$cert" || zone_remove_fail "zone credential binding is invalid; removal was not started"

		zone_remove_note "[+] verifying remote tunnels for '$canonical'"
		remote_json="$(cloudflared_for_zone "$canonical" tunnel list --output json)" || zone_remove_fail "could not query Cloudflare tunnels; no zone state was changed"
		if ! jq -e 'type == "array" and all(.[]; (type == "object") and ((.id | type) == "string"))' <<< "$remote_json" >/dev/null 2>&1; then
			zone_remove_fail "Cloudflare returned an unusable tunnel list; no zone state was changed"
		fi
		while IFS= read -r uuid; do
			[[ -n "$uuid" ]] || zone_remove_fail "Cloudflare returned a tunnel without an id; no zone state was changed"
			validate_tunnel_uuid "$uuid" >/dev/null 2>&1 || zone_remove_fail "Cloudflare returned an unusable tunnel id; no zone state was changed"
		done < <(jq -r '.[].id' <<< "$remote_json")

		if [[ "$dns_mode" == automatic ]]; then
			zone_id="$(zone_remove_resolve_zone_id "$canonical")" || zone_remove_fail "could not resolve the Cloudflare zone id for '$canonical'; no zone state was changed"
		fi

		if [[ $EUID -ne 0 ]]; then
			sudo -v || zone_remove_fail "needs sudo permission; no zone state was changed"
		fi

		while IFS= read -r unit; do
			[[ -n "$unit" ]] || continue
			zone_remove_note "[+] stopping and disabling ${unit}"
			if ! zone_remove_systemctl disable --now "$unit"; then
				echo "[!] warning: could not stop or disable ${unit}" >&2
			fi
		done < <(jq -r '.tunnels[].unit' <<< "$plan_json")
	fi

	while IFS= read -r row; do
		name="$(jq -r '.name' <<< "$row")"
		uuid="$(jq -r '.uuid' <<< "$row")"
		yaml="$(jq -r '.yaml' <<< "$row")"
		credential="$(jq -r '.credential' <<< "$row")"
		zone_remove_progress_note "teardown started for tunnel '${name}'"

		zone_remove_note "[+] removing tunnel '${name}' (${uuid})"
		if jq -e --arg uuid "$uuid" '[.[].id] | index($uuid) != null' <<< "$remote_json" >/dev/null 2>&1; then
			if ! cloudflared_for_zone "$canonical" tunnel delete "$uuid" >/dev/null 2>&1; then
				zone_remove_fail "Cloudflare tunnel deletion failed for '${name}'; its local files were preserved"
			fi
			zone_remove_progress_note "tunnel '${name}' deleted from Cloudflare"
		else
			zone_remove_note "[=] tunnel '${name}' is already absent from Cloudflare"
		fi

		if [[ -n "$zone_id" ]]; then
			while IFS= read -r hostname; do
				[[ -n "$hostname" ]] || continue
				if ! zone_remove_delete_records "$zone_id" "$hostname" "$uuid"; then
					zone_remove_fail "DNS removal failed for '${hostname}'; tunnel '${name}' local files were preserved"
				fi
			done < <(jq -r '.routes[].hostname' <<< "$row")
		fi

		rm -f -- "$yaml" || zone_remove_fail "could not remove $yaml"
		if [[ -n "$credential" && "$credential" != "null" ]]; then
			rm -f -- "$credential" || zone_remove_fail "could not remove $credential"
		fi
		zone_remove_progress_note "tunnel '${name}' local files removed"
		removed_tunnels="$(jq -cn --argjson removed "$removed_tunnels" --arg name "$name" '$removed + [$name]')"
	done < <(jq -c '.tunnels[]' <<< "$plan_json")

	# Nothing else is removed: re-validate the canonical path first, so a
	# directory that appeared or changed since the plan is never deleted.
	dir="$(zone_remove_assert_dir "$canonical")" || zone_remove_fail "the zone directory could not be re-validated; remaining local files were preserved"
	rm -rf -- "$dir" || zone_remove_fail "could not remove the zone directory $dir"
	zone_remove_progress_note "zone directory removed"

	if [[ "$default_zone" == "$canonical" ]]; then
		unset_default_zone
		if [[ -e "$DEFAULT_ZONE_FILE" ]]; then
			zone_remove_fail "could not clear the persisted default zone pointer"
		fi
		default_cleared=true
		zone_remove_progress_note "persisted default zone cleared"
	fi

	local warnings_json
	warnings_json="$(jq -c '.warnings' <<< "$plan_json")"
	if [[ "$dns_mode" == manual ]]; then
		manual_records="$(jq -c '[.dns.records[].hostname] | unique' <<< "$plan_json")"
	fi

	data="$(jq -cn \
		--arg zone "$canonical" \
		--argjson tunnels "$removed_tunnels" \
		--argjson files "$(jq -r '.files.total' <<< "$plan_json")" \
		--argjson cleared "$default_cleared" \
		--arg dns_mode "$dns_mode" \
		--argjson deleted "$ZONE_REMOVE_DELETED_DNS" \
		--argjson manual "$manual_records" \
		'{
			zone: $zone,
			removed: {tunnels: $tunnels, files: $files, default_zone_cleared: $cleared},
			dns: {mode: $dns_mode, records_deleted: $deleted, records_manual: $manual}
		}')"

	if json_enabled; then
		json_success "zone.remove" "$data" "$warnings_json"
		return 0
	fi

	echo
	echo "✅ zone '$canonical' removed"
	echo "    tunnels   : $(jq -r '.removed.tunnels | if length == 0 then "(none)" else join(", ") end' <<< "$data")"
	echo "    files     : $(jq -r '.removed.files' <<< "$data") removed"
	if [[ "$default_cleared" == true ]]; then
		echo "    default   : persisted default zone cleared"
	else
		echo "    default   : unchanged"
	fi
	if [[ "$dns_mode" == automatic ]]; then
		echo "    DNS       : $(jq -r '.dns.records_deleted | length' <<< "$data") record(s) deleted"
	else
		while IFS= read -r hostname; do
			[[ -n "$hostname" ]] || continue
			echo "    DNS left  : $hostname (remove it manually)"
		done < <(jq -r '.dns.records_manual[]?' <<< "$data")
	fi
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		echo "    warning   : $line"
	done < <(jq -r '.[]?' <<< "$warnings_json")
	return 0
}

op_zone_remove() {
	zone_remove_parse_args "$@"
	need jq

	local canonical dir plan_json
	canonical="$(zone_remove_resolve_target)" || return 1
	ZONE_REMOVE_TARGET="$canonical"
	dir="$(zone_remove_assert_dir "$canonical")" || return 1
	if ! plan_json="$(zone_remove_inventory "$canonical" "$dir")"; then
		return 1
	fi

	if [[ "$ZONE_REMOVE_PLAN" == true ]]; then
		if json_enabled; then
			json_success "zone.remove.plan" "$plan_json"
		else
			zone_remove_print_plan_text "$plan_json"
		fi
		return 0
	fi

	if ! json_enabled; then
		zone_remove_print_plan_text "$plan_json"
		echo
	fi
	zone_remove_confirm "$canonical"
	zone_remove_apply "$canonical" "$dir" "$plan_json"
}
