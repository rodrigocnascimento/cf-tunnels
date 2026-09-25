[[ -z "${_CFTUNNEL_CONTRACTS_LOADED:-}" ]] || return 0
_CFTUNNEL_CONTRACTS_LOADED=1

json_enabled() {
	[[ "${OUTPUT_FORMAT:-text}" == "json" ]]
}

utc_now() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

json_success() {
	local operation="${1:-}"
	local data="${2:-}"
	local warnings="${3:-}"
	[[ -n "$data" ]] || data='{}'
	[[ -n "$warnings" ]] || warnings='[]'
	need jq
	jq -cn \
		--arg operation "$operation" \
		--argjson data "$data" \
		--argjson warnings "$warnings" \
		'{schema_version: 1, operation: $operation, ok: true, data: $data, warnings: $warnings}'
}

systemd_unit_status() {
	local unit="${1:-}"
	if ! command -v systemctl >/dev/null 2>&1; then
		printf '%s\n' unavailable
		return
	fi
	if systemctl is-active --quiet "$unit" 2>/dev/null; then
		printf '%s\n' active
	elif systemctl is-failed --quiet "$unit" 2>/dev/null; then
		printf '%s\n' failed
	elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
		printf '%s\n' enabled
	else
		printf '%s\n' inactive
	fi
}

json_nullable_string() {
	local value="${1:-}"
	need jq
	if [[ -n "$value" ]]; then
		jq -cn --arg value "$value" '$value'
	else
		printf '%s\n' null
	fi
}

op_capabilities() {
	if ! json_enabled; then
		echo "cftunnel contract schema 1"
		echo "Use: cftunnel capabilities --output json"
		return
	fi
	local version data
	need jq
	version="$(print_cftunnel_version | awk '{print $2}')" || return 1
	data="$(jq -cn --arg version "$version" '
		{
			application_version: $version,
			operations: {
				"zone.list": {json: true},
				"zone.current": {json: true},
				"zone.use": {json: true},
				"zone.unset": {json: true},
				"tunnel.list": {json: true},
				"tunnel.status": {json: true},
				"tunnel.health": {json: true},
				"privilege.check": {json: true}
			}
		}')"
	json_success "capabilities" "$data"
}

op_privilege_check() {
	if ! json_enabled; then
		die "privilege check requires --output json"
	fi
	need jq
	local available=false reason="sudo_auth_required"
	if [[ $EUID -eq 0 ]] || sudo -n -v >/dev/null 2>&1; then
		available=true
		reason="cached"
	fi
	local data
	data="$(jq -cn --arg reason "$reason" --argjson available "$available" '{available: $available, reason: $reason}')"
	json_success "privilege.check" "$data"
}
