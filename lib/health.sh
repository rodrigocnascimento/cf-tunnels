[[ -z "${_CFTUNNEL_HEALTH_LOADED:-}" ]] || return 0
_CFTUNNEL_HEALTH_LOADED=1

credentials_file_from_yaml() {
	local yaml="${1:-}"
	awk '
		function trim(value) {
			sub(/^[[:space:]]+/, "", value)
			sub(/[[:space:]]+$/, "", value)
			return value
		}
		function unquote(value, quote) {
			value = trim(value)
			quote = substr(value, 1, 1)
			if (length(value) >= 2 && (quote == "\"" || quote == "\047") && substr(value, length(value), 1) == quote) {
				return substr(value, 2, length(value) - 2)
			}
			return value
		}
		/^credentials-file:[[:space:]]*/ {
			value = $0
			sub(/^credentials-file:[[:space:]]*/, "", value)
			print unquote(value)
			exit
		}
	' "$yaml"
}

file_mode_or_null() {
	local path="${1:-}"
	if [[ -f "$path" && ! -L "$path" ]]; then
		stat -c '%a' -- "$path" 2>/dev/null || true
	fi
}

health_entry_json() {
	local yaml="${1:-}"
	local zone_name name raw_uuid uuid unit status config_mode credential_path credential_mode
	zone_name="$(basename "$(dirname "$yaml")")"
	name="$(basename "$yaml" .yml)"
	raw_uuid="$(tunnel_uuid_from_yaml "$yaml")"
	uuid="$(validate_tunnel_uuid "$raw_uuid" 2>/dev/null || true)"
	unit="cloudflared@${zone_name}_${name}.service"
	status="$(systemd_unit_status "$unit")"
	config_mode="$(file_mode_or_null "$yaml")"
	credential_path="$(credentials_file_from_yaml "$yaml")"
	credential_mode="$(file_mode_or_null "$credential_path")"

	local routes='[]'
	local hostname service dns_result cname_check dns_checked route
	while IFS=$'\t' read -r hostname service; do
		[[ -n "$hostname" && -n "$service" ]] || continue
		dns_result="$(resolve_hostname "$hostname" | head -1 || true)"
		if has_cname_lookup; then
			cname_check=true
		else
			cname_check=false
		fi
		dns_checked="$(utc_now)"
		route="$(jq -cn \
			--arg hostname "$hostname" \
			--arg service "$service" \
			--arg result "$dns_result" \
			--arg checked_at "$dns_checked" \
			--argjson cname_check_available "$cname_check" \
			'{hostname: $hostname, service: $service, dns: {source: "dns", result: (if $result == "" then null else $result end), cname_check_available: $cname_check_available, checked_at: $checked_at}}')"
		routes="$(jq -cn --argjson routes "$routes" --argjson route "$route" '$routes + [$route]')"
	done < <(ingress_routes_from_yaml "$yaml")

	jq -cn \
		--arg zone "$zone_name" \
		--arg name "$name" \
		--arg unit "$unit" \
		--arg status "$status" \
		--arg uuid "$uuid" \
		--arg config_mode "$config_mode" \
		--arg credential_mode "$credential_mode" \
		--argjson routes "$routes" \
		'{
			zone: $zone,
			name: $name,
			unit: $unit,
			config: {
				mode: (if $config_mode == "" then null else $config_mode end),
				uuid: (if $uuid == "" then null else $uuid end),
				credential: {
					present: ($credential_mode != ""),
					mode: (if $credential_mode == "" then null else $credential_mode end)
				}
			},
			systemd: {source: "systemd", status: $status},
			routes: $routes
		}'
}

op_health() {
	need jq
	local entries=()
	local yaml
	while IFS= read -r -d '' yaml; do
		if [[ -n "${NAME:-}" && "$(basename "$yaml" .yml)" != "$NAME" ]]; then
			continue
		fi
		entries+=("$(health_entry_json "$yaml")")
	done < <(list_yaml_files)

	if [[ -n "${NAME:-}" && ${#entries[@]} -eq 0 ]]; then
		die "no local tunnel configuration found for '$NAME'"
	fi

	local tunnels scope_zone data
	if [[ ${#entries[@]} -eq 0 ]]; then
		tunnels='[]'
	else
		tunnels="$(printf '%s\n' "${entries[@]}" | jq -cs '.')"
	fi
	scope_zone="$(json_nullable_string "${ZONE:-}")"
	data="$(jq -cn \
		--arg checked_at "$(utc_now)" \
		--argjson scope_zone "$scope_zone" \
		--argjson tunnels "$tunnels" \
		'{scope_zone: $scope_zone, checked_at: $checked_at, tunnels: $tunnels}')"
	json_success "tunnel.health" "$data"
}
