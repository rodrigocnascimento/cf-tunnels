[[ -z "${_CFTUNNEL_TUNNEL_LOADED:-}" ]] || return 0
_CFTUNNEL_TUNNEL_LOADED=1

ensure_template() {
	[[ -f "$SYSTEMD_TPL" ]] || die "systemd template not found: $SYSTEMD_TPL
Create it as configured (ExecStart=/usr/local/bin/cloudflared tunnel --config $HOME/.cloudflared/%i.yml run; User=$RUN_USER).

Tip: If using --zone, the template is still the single global one (cloudflared@.service)."
}

instance_unit() {
	local name="$1"
	if [[ -n "$ZONE" ]]; then
		echo "cloudflared@${ZONE}_${name}.service"
	else
		echo "cloudflared@${name}.service"
	fi
}

yaml_path_for() {
	local dir
	dir="$(zone_base_dir)"
	echo "${dir}/${1}.yml"
}

json_path_for_uuid() {
	local dir
	dir="$(zone_base_dir)"
	echo "${dir}/${1}.json"
}

validate_add_input() {
	[[ -n "${TUNNEL_HOSTNAME:-}" ]] || die "--hostname is required"
	[[ -n "${TYPE:-}" ]] || die "--type ssh|http|tcp is required"
	[[ -n "${SERVICE:-}" ]] || die "--service is required (e.g.: ssh://localhost:22, http://localhost:4000, tcp://localhost:6379)"
	if [[ -n "${ZONE:-}" ]] && ! hostname_belongs_to_zone "$TUNNEL_HOSTNAME" "$ZONE"; then
		die "hostname '$TUNNEL_HOSTNAME' does not belong to zone '$ZONE'"
	fi
	case "$TYPE" in
	ssh | http | tcp) : ;;
	*) die "--type invalid: $TYPE (use ssh|http|tcp)" ;;
	esac

	if [[ -n "${ORIGIN_SERVER_NAME:-}" || "${TLS_VERIFY_SET:-false}" == true ]]; then
		[[ "$TYPE" == "http" && "$SERVICE" == https://* ]] || die "--origin-server-name and TLS verification options require an HTTPS HTTP origin"
	fi
	if [[ -n "${ORIGIN_SERVER_NAME:-}" ]]; then
		ORIGIN_SERVER_NAME="$(validate_zone_name "$ORIGIN_SERVER_NAME")" || return 1
	fi

	case "$TYPE" in
	ssh)
		[[ "$SERVICE" == ssh://* ]] || die "--type ssh requires --service ssh://... (e.g.: ssh://localhost:22)"
		;;
	http)
		[[ "$SERVICE" == http://* || "$SERVICE" == https://* ]] || die "--type http requires --service http://... or https://... (e.g.: http://localhost:4000)"
		;;
	tcp)
		[[ "$SERVICE" == tcp://* ]] || die "--type tcp requires --service tcp://... (e.g.: tcp://localhost:6379)"
		;;
	esac
}

validate_flags_add() {
	validate_add_input
}

prepare_add_target() {
	local base_domain default_name
	base_domain="$(echo "$TUNNEL_HOSTNAME" | rev | cut -d. -f1-2 | rev)"
	default_name="${base_domain}-${TYPE}"
	default_name="$(echo "$default_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/\./-/g')"
	NAME="${NAME:-$default_name}"
	NAME="$(slugify "$NAME")"
	[[ -n "$NAME" ]] || die "tunnel name is empty after sanitization"
}

op_add_plan() {
	validate_flags_add
	prepare_add_target
	need jq
	local unit yaml existing_yaml existing_hostname data tls_server_name
	unit="$(instance_unit "$NAME")"
	yaml="$(yaml_path_for "$NAME")"
	existing_yaml=false
	existing_hostname=false
	if [[ -f "$yaml" ]]; then
		existing_yaml=true
		if grep -qF "hostname: \"${TUNNEL_HOSTNAME}\"" "$yaml" 2>/dev/null; then
			existing_hostname=true
		fi
	fi
	if json_enabled; then
		data="$(jq -cn \
			--arg zone "${ZONE:-}" \
			--arg hostname "$TUNNEL_HOSTNAME" \
			--arg type "$TYPE" \
			--arg service "$SERVICE" \
			--arg name "$NAME" \
			--arg unit "$unit" \
			--arg yaml "$yaml" \
			--arg origin_server_name "${ORIGIN_SERVER_NAME:-}" \
			--argjson tls_verify "${TLS_VERIFY:-true}" \
			--argjson existing_yaml "$existing_yaml" \
			--argjson existing_hostname "$existing_hostname" \
			'{zone: (if $zone == "" then null else $zone end), hostname: $hostname, type: $type, service: $service, tunnel_name: $name, unit: $unit, yaml: $yaml, existing_tunnel: $existing_yaml, existing_hostname: $existing_hostname, restart_required: $existing_yaml, origin_tls: {server_name: (if $origin_server_name == "" then null else $origin_server_name end), verify: $tls_verify, configured: ($origin_server_name != "" or $tls_verify == false)}, dns: {mode: "automatic"}, privilege: {sudo_required: true}}')"
		json_success "hostname.add.plan" "$data"
		return
	fi
	echo "Hostname plan: $TUNNEL_HOSTNAME → $SERVICE ($TYPE)"
	if [[ "$existing_yaml" == true ]]; then
		echo "Tunnel: $NAME (existing)"
		echo "Effects: validate ingress, create/update DNS, and restart the service."
	else
		echo "Tunnel: $NAME (new)"
		echo "Effects: validate ingress, create/update DNS, and start the service."
	fi
	echo "Unit: $unit"
	if [[ -n "${ORIGIN_SERVER_NAME:-}" || "${TLS_VERIFY_SET:-false}" == true ]]; then
		echo "Origin TLS: SNI ${ORIGIN_SERVER_NAME:-service URL hostname}; certificate verification ${TLS_VERIFY}"
	fi
}

write_entry_origin_tls() {
	[[ -n "${ORIGIN_SERVER_NAME:-}" || "${TLS_VERIFY_SET:-false}" == true ]] || return 0
	echo "    originRequest:"
	[[ -z "${ORIGIN_SERVER_NAME:-}" ]] || echo "      originServerName: \"${ORIGIN_SERVER_NAME}\""
	echo "      noTLSVerify: $([[ "${TLS_VERIFY:-true}" == true ]] && echo false || echo true)"
}

rewrite_ingress_entry_tls() {
	local entries="$1" target="$2"
	awk -v target="$target" -v origin="${ORIGIN_SERVER_NAME:-}" -v verify="${TLS_VERIFY:-true}" '
	function tls() {
		print "    originRequest:"
		if (origin != "") print "      originServerName: \"" origin "\""
		print "      noTLSVerify: " (verify == "true" ? "false" : "true")
	}
	/^  - / {
		if (selected && !emitted) { tls(); emitted=1 }
		selected = ($0 == "  - hostname: \"" target "\"")
		skipping=0; emitted=0
		print
		next
	}
	selected && /^    originRequest:/ { skipping=1; next }
	selected && skipping {
		if ($0 ~ /^      / || $0 ~ /^$/) next
		tls(); emitted=1; skipping=0
	}
	{ print }
	END { if (selected && !emitted) tls() }
	' <<< "$entries"
}

find_hostname_yaml() {
	local hostname="$1" yaml matches=()
	while IFS= read -r -d '' yaml; do
		grep -qF "hostname: \"${hostname}\"" "$yaml" 2>/dev/null && matches+=("$yaml")
	done < <(find "$(zone_base_dir)" -maxdepth 1 -type f -name '*.yml' -print0 2>/dev/null)
	[[ ${#matches[@]} -eq 1 ]] || {
		if [[ ${#matches[@]} -eq 0 ]]; then die "hostname '$hostname' is not configured in zone '$ZONE'"; fi
		die "hostname '$hostname' is configured by multiple local tunnels; resolve the ambiguity manually"
	}
	printf '%s\n' "${matches[0]}"
}

remove_ingress_entry() {
	local yaml="$1" hostname="$2" temporary
	temporary="$(mktemp "${yaml}.remove.XXXXXX")"
	awk -v target="$hostname" '
	/^  - / {
		if ($0 == "  - hostname: \"" target "\"") { skip=1; next }
		skip=0
	}
	!skip { print }
	' "$yaml" > "$temporary"
	chmod 600 "$temporary"
	printf '%s\n' "$temporary"
}

op_hostname_remove() {
	local hostname="${REMOVE_HOSTNAME:-}" yaml tunnel_name route_count data temporary backup
	[[ -n "$hostname" ]] || die "hostname remove requires --hostname"
	if ! hostname_belongs_to_zone "$hostname" "$ZONE"; then
		die "hostname '$hostname' does not belong to zone '$ZONE'"
	fi
	yaml="$(find_hostname_yaml "$hostname")" || return 1
	tunnel_name="$(basename "${yaml%.yml}")"
	route_count="$(grep -cE '^  - hostname: ' "$yaml" || true)"
	if [[ "$REMOVE_PLAN" == true ]]; then
		need jq
		if json_enabled; then
			data="$(jq -cn --arg zone "$ZONE" --arg hostname "$hostname" --arg tunnel "$tunnel_name" --arg yaml "$yaml" --argjson remaining "$((route_count - 1))" '{zone: $zone, hostname: $hostname, tunnel_name: $tunnel, yaml: $yaml, remaining_hostname_count: $remaining, dns: {action: "unchanged", reason: "DNS deletion requires a separate explicit operation"}, privilege: {sudo_required: true}}')"
			json_success "hostname.remove.plan" "$data"
			return
		fi
		echo "Remove hostname: $hostname"
		echo "Tunnel: $tunnel_name"
		echo "Effects: remove this ingress rule, validate the YAML, and restart the service."
		echo "DNS: unchanged (record deletion is a separate explicit operation)."
		return
	fi

	echo
	echo ">>> About to remove hostname '$hostname' from tunnel '$tunnel_name'"
	echo "    YAML file    : $yaml"
	echo "    DNS         : unchanged"
	if [[ "$REMOVE_YES" != true ]]; then
		read -p "Continue? [y/N] " -n 1 -r || true
		echo
		[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted by user."; return 0; }
	else
		echo "[=] --yes: applying previously reviewed hostname removal plan"
	fi

	need cloudflared
	ensure_template
	temporary="$(remove_ingress_entry "$yaml" "$hostname")"
	cloudflared tunnel --config "$temporary" ingress validate || { rm -f "$temporary"; die "removed hostname would produce an invalid ingress configuration"; }
	if [[ $EUID -ne 0 ]]; then sudo -v || { rm -f "$temporary"; die "needs sudo permission"; }; fi
	backup="$(mktemp "${yaml}.backup.XXXXXX")"
	cp -p -- "$yaml" "$backup"
	mv "$temporary" "$yaml"
	chmod 600 "$yaml"
	if ! sudo systemctl restart "$(instance_unit "$tunnel_name")"; then
		mv "$backup" "$yaml"
		sudo systemctl restart "$(instance_unit "$tunnel_name")" || true
		die "service restart failed; restored the previous hostname configuration"
	fi
	rm -f "$backup"
	echo "[+] Removed hostname '$hostname'. DNS was left unchanged."
}

validate_tunnel_uuid() {
	local uuid="${1:-}"
	local LC_ALL=C
	local uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
	[[ "$uuid" =~ $uuid_pattern ]] || return 1
	[[ "$uuid" != "00000000-0000-0000-0000-000000000000" ]] || return 1
	printf '%s\n' "${uuid,,}"
}

tunnel_discovery_error() {
	local reason="${1:-unexpected response}"
	local explanation
	case "$reason" in
	"invalid JSON") explanation="Cloudflare returned malformed JSON" ;;
	"unexpected JSON shape") explanation="Cloudflare returned JSON in an unexpected shape" ;;
	"no exact-name match") explanation="Cloudflare returned tunnel entries, but none matched the requested name exactly" ;;
	"ambiguous exact-name matches") explanation="Cloudflare returned more than one tunnel with the requested name" ;;
	"missing tunnel UUID") explanation="Cloudflare returned the requested tunnel without a UUID" ;;
	"invalid tunnel UUID") explanation="Cloudflare returned an invalid tunnel UUID" ;;
	*) explanation="Cloudflare returned an unusable discovery response" ;;
	esac
	echo "error: Cannot safely determine whether the requested tunnel exists: $explanation." >&2
	echo "No tunnel, DNS record, YAML file, or systemd unit was changed." >&2
	echo "Check the Activity diagnostic below, or re-run the command in a terminal for complete output." >&2
	return 1
}

tunnel_creation_error() {
	echo "error: tunnel creation did not return a usable UUID; remote state may have changed." >&2
	echo "Retry the same cftunnel add command to discover and resume safely." >&2
	return 1
}

extract_and_validate_uuid() {
	local json="$1" error_fn="$2"
	shift 2
	local uuid
	uuid="$(jq -er "$@" <<< "$json" 2>/dev/null)" || {
		"$error_fn"
		return 1
	}
	uuid="$(validate_tunnel_uuid "$uuid")" || {
		"$error_fn"
		return 1
	}
	printf '%s\n' "$uuid"
}

discover_tunnel_uuid() {
	local name="${1:-}"
	local tunnels_json
	if ! tunnels_json="$(cloudflared tunnel list --name "$name" --output json)"; then
		echo "error: could not query Cloudflare tunnels for '$name'; no tunnel was created" >&2
		echo "Check DNS/network connectivity and the active zone credential, then retry." >&2
		return 1
	fi

	local summary
	summary="$(jq -r --arg name "$name" '
		if . == null then
			["empty", ""] | @tsv
		elif type != "array" then
			["unexpected JSON shape", ""] | @tsv
		else
			(map(select(type == "object" and .name == $name))) as $matches
			| if length == 0 then ["empty", ""]
			  elif ($matches | length) == 0 then ["no exact-name match", ""]
			  elif ($matches | length) > 1 then ["ambiguous exact-name matches", ""]
			  elif ($matches[0].id | type) != "string" then ["missing tunnel UUID", ""]
			  else ["found", $matches[0].id]
			  end
			| @tsv
		end
	' <<< "$tunnels_json" 2>/dev/null)" || {
		tunnel_discovery_error "invalid JSON"
		return 1
	}

	local status id
	IFS=$'\t' read -r status id <<< "$summary"
	case "$status" in
	empty) return 0 ;;
	found) : ;;
	*)
		tunnel_discovery_error "$status"
		return 1
		;;
	esac

	local uuid
	uuid="$(validate_tunnel_uuid "$id")" || {
		tunnel_discovery_error "invalid tunnel UUID"
		return 1
	}
	printf '%s\n' "$uuid"
}

create_tunnel_uuid() {
	local name="${1:-}"
	local create_json
	if ! create_json="$(cloudflared tunnel create --output json "$name")"; then
		tunnel_creation_error
		return 1
	fi

	extract_and_validate_uuid "$create_json" tunnel_creation_error \
		--arg name "$name" \
		'select(type == "object" and .name == $name) |
		.id | select(type == "string")'
}

ensure_unit_enabled() {
	local unit="$1"
	sudo systemctl enable "$unit"
}

op_add() {
	validate_flags_add
	if [[ "${ADD_PLAN:-false}" == true ]]; then
		op_add_plan
		return
	fi

	need cloudflared
	need jq
	ensure_template

	prepare_add_target
	local UNIT
	UNIT="$(instance_unit "$NAME")"
	local YAML
	YAML="$(yaml_path_for "$NAME")"

	local zone_display="${ZONE:-default}"
	echo
	echo ">>> About to perform the following actions:"
	echo "    Zone         : $zone_display"
	echo "    Tunnel name  : $NAME"
	echo "    Hostname     : $TUNNEL_HOSTNAME"
	echo "    Local service: $SERVICE"
	echo "    Systemd unit : $UNIT"
	echo "    YAML file    : $YAML"
	echo
	if [[ "${ADD_YES:-false}" != true ]]; then
		read -p "Continue? [y/N] " -n 1 -r || true
		echo
		if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
			echo "Aborted by user."
			exit 0
		fi
	else
		echo "[=] --yes: applying previously reviewed hostname plan"
	fi
	echo

	local UUID
	UUID="$(discover_tunnel_uuid "$NAME")" || return 1

	if [[ $EUID -ne 0 ]]; then
		sudo -v || die "needs sudo permission"
	fi

	if [[ -z "$UUID" ]]; then
		echo "[+] creating tunnel: $NAME"
		UUID="$(create_tunnel_uuid "$NAME")" || return 1
	else
		echo "[=] tunnel '$NAME' already exists (ok)"
	fi

	ensure_zone_dir

	local CREDS_JSON
	CREDS_JSON="$(zone_base_dir)/${UUID}.json"
	local created_json="$BASE_DIR/${UUID}.json"
	if [[ -n "$ZONE" && -f "$created_json" && ! -f "$CREDS_JSON" ]]; then
		mv "$created_json" "$CREDS_JSON"
		echo "[+] moved credentials to zone directory"
	fi

	[[ -f "$CREDS_JSON" ]] || die "credentials not found: $CREDS_JSON (run 'cloudflared tunnel login' and recreate the tunnel)"

	local existing_yaml=false
	if [[ -f "$YAML" ]]; then
		existing_yaml=true
		local existing_entries
		existing_entries=$(awk '/^ingress:/{flag=1; next} /  - service: http_status:404/{flag=0} flag' "$YAML" 2>/dev/null || true)
		if echo "$existing_entries" | grep -qF "hostname: \"${TUNNEL_HOSTNAME}\"" 2>/dev/null; then
			echo "[=] hostname '${TUNNEL_HOSTNAME}' already in ingress (ok)"
			if [[ -n "${ORIGIN_SERVER_NAME:-}" || "${TLS_VERIFY_SET:-false}" == true ]]; then
				echo "[+] updating origin TLS settings for '${TUNNEL_HOSTNAME}'"
				existing_entries="$(rewrite_ingress_entry_tls "$existing_entries" "$TUNNEL_HOSTNAME")"
				printf '%s\n' \
					"tunnel: ${UUID}" \
					"credentials-file: ${CREDS_JSON}" \
					"" \
					'protocol: "http2"' \
					'edge-ip-version: "4"' \
					"" \
					"originRequest:" \
					'  tcpKeepAlive: "30s"' \
					'  keepAliveTimeout: "2m"' \
					'  connectTimeout: "10s"' \
					"" \
					"ingress:" \
					"$existing_entries" \
					"  - service: http_status:404" > "$YAML"
				chmod 600 "$YAML"
			fi
		else
			echo "[+] appending hostname '${TUNNEL_HOSTNAME}' to existing ingress"
			printf '%s\n' \
				"tunnel: ${UUID}" \
				"credentials-file: ${CREDS_JSON}" \
				"" \
				'protocol: "http2"' \
				'edge-ip-version: "4"' \
				"" \
				"originRequest:" \
				'  tcpKeepAlive: "30s"' \
				'  keepAliveTimeout: "2m"' \
				'  connectTimeout: "10s"' \
				"" \
				"ingress:" \
				"$existing_entries" \
				"  - hostname: \"${TUNNEL_HOSTNAME}\"" \
				"    service: \"${SERVICE}\"" \
				"$(write_entry_origin_tls)" \
				"  - service: http_status:404" > "$YAML"
			chmod 600 "$YAML"
		fi
	else
		echo "[+] writing YAML: $YAML"
		printf '%s\n' \
			"tunnel: ${UUID}" \
			"credentials-file: ${CREDS_JSON}" \
			"" \
			'protocol: "http2"' \
			'edge-ip-version: "4"' \
			"" \
			"originRequest:" \
			'  tcpKeepAlive: "30s"' \
			'  keepAliveTimeout: "2m"' \
			'  connectTimeout: "10s"' \
			"" \
			"ingress:" \
			"  - hostname: \"${TUNNEL_HOSTNAME}\"" \
			"    service: \"${SERVICE}\"" \
			"$(write_entry_origin_tls)" \
			"  - service: http_status:404" > "$YAML"
		chmod 600 "$YAML"
	fi

	echo "[+] validating ingress"
	cloudflared tunnel --config "$YAML" ingress validate

	if [[ "${NO_DNS:-false}" == true ]]; then
		echo "[=] --no-dns: skipping DNS creation"
		echo "[=] Create the CNAME record manually in the Cloudflare dashboard:"
		echo "    ${TUNNEL_HOSTNAME} → ${UUID}.cfargotunnel.com"
	else
		echo "[+] creating/updating DNS for ${TUNNEL_HOSTNAME}"
		local max_attempts=3
		local attempt=0
		local DNS_OK=false
		while [[ $attempt -lt $max_attempts && "$DNS_OK" == false ]]; do
			((attempt++)) || true
			if [[ $attempt -gt 1 ]]; then
				local wait=$(( attempt * 5 ))
				echo "[!] retrying in ${wait}s... (attempt ${attempt}/${max_attempts})"
				sleep "$wait"
			fi
			local DNS_OUTPUT
			if DNS_OUTPUT="$(cloudflared tunnel route dns "$NAME" "$TUNNEL_HOSTNAME" 2>&1)"; then
				DNS_OK=true
				echo "$DNS_OUTPUT"
			else
				echo "[!] attempt ${attempt}/${max_attempts} failed: $DNS_OUTPUT"
			fi
		done
		if [[ "$DNS_OK" == false ]]; then
			die "failed to create DNS route after ${max_attempts} attempts.
Run manually: cloudflared tunnel route dns $NAME $TUNNEL_HOSTNAME
Or create a CNAME in the Cloudflare dashboard pointing to ${UUID}.cfargotunnel.com"
		fi

		echo "[+] verifying DNS for ${TUNNEL_HOSTNAME}..."
		echo "[!] waiting up to 30s for propagation (Ctrl+C to skip)..."
		local DNS_RESULT=""
		local WAITED=0
		while [[ -z "$DNS_RESULT" && $WAITED -lt 30 ]]; do
			sleep 5
			DNS_RESULT="$(resolve_hostname "$TUNNEL_HOSTNAME" | head -1 || echo "")"
			WAITED=$((WAITED + 5))
			echo "    [+] attempt ${WAITED}/30: ${DNS_RESULT:-"nothing yet..."}"
		done

		if [[ -z "$DNS_RESULT" ]]; then
			echo "[!] DNS still not resolving after 30s"
			echo "[!] The CNAME record may have been created in Cloudflare, but propagation takes time."
			echo "[!] You can check the dashboard: https://dash.cloudflare.com/"
			if [[ "${ADD_YES:-false}" != true ]]; then
				read -p "Continue anyway? (y/N) " -n 1 -r || true
				echo
				if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
					die "Operation cancelled."
				fi
			else
				echo "[=] --yes: continuing after the reviewed DNS propagation timeout"
			fi
		elif ! has_cname_lookup; then
			echo "[✓] DNS resolves: $DNS_RESULT (CNAME verification unavailable without dig/host)"
		elif [[ "$DNS_RESULT" == *".cfargotunnel.com"* || "$DNS_RESULT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "[✓] DNS OK: $DNS_RESULT"
		else
			echo "[!] warning: unexpected DNS result: $DNS_RESULT"
			echo "[!] expected: <uuid>.cfargotunnel.com or direct IP"
		fi
	fi

	if [[ "$existing_yaml" == true ]]; then
		# Adding a route must also guarantee boot-time startup for tunnels that
		# predate this behavior or were manually disabled. Enable before restart
		# so the boot configuration remains correct even if runtime start fails.
		echo "[+] ensuring service is enabled at boot: $UNIT"
		ensure_unit_enabled "$UNIT" || die "could not enable service at boot: $UNIT"
		echo "[+] restarting service to load updated ingress: $UNIT"
		sudo systemctl restart "$UNIT"
	else
		echo "[+] enabling and starting service: $UNIT"
		sudo systemctl daemon-reload
		sudo systemctl enable --now "$UNIT"
	fi
	sudo systemctl is-active --quiet "$UNIT" || {
		sudo systemctl status "$UNIT" || true
		die "service did not become active"
	}

	echo "✅ ready! Tunnel '${NAME}' active for '${TUNNEL_HOSTNAME}' → ${SERVICE}"
	echo "   - YAML: ${YAML}"
	echo "   - Unit: ${UNIT}"
	echo "   - Logs: sudo journalctl -fu ${UNIT}"
	echo
	if [[ "$TYPE" == "tcp" || "$TYPE" == "udp" ]]; then
		echo "⚠️  IMPORTANT: For TCP/UDP tunnels, connect locally:"
		echo "      On the client machine, run:"
		echo "      cloudflared access tcp --hostname ${TUNNEL_HOSTNAME} --url localhost:<local_port>"
		echo "      Then connect your application to localhost:<local_port>"
	fi
	echo "Tip: for protected apps, create an Access Policy for ${TUNNEL_HOSTNAME} in Zero Trust (or automate via API with CF_API_TOKEN/CF_ACCOUNT_ID)."
}

op_remove() {
	need cloudflared
	ensure_template
	[[ -n "${NAME:-}" ]] || die "--name is required"
	NAME="$(slugify "$NAME")"
	[[ -n "$NAME" ]] || die "tunnel name is empty after sanitization"
	if [[ -n "${ZONE:-}" ]]; then
		local zone_credential="$HOME_DIR/.cloudflared/zones/$ZONE/cert.pem"
		verify_zone_credential_binding "$ZONE" "$zone_credential" || die "zone credential binding is invalid; removal was not started"
	fi

	if [[ $EUID -ne 0 ]]; then
		sudo -v || die "needs sudo permission"
	fi

	local UNIT
	UNIT="$(instance_unit "$NAME")"
	local YAML
	YAML="$(yaml_path_for "$NAME")"

	local zone_display="${ZONE:-default}"
	echo
	echo ">>> About to REMOVE the following:"
	echo "    Zone    : $zone_display"
	echo "    Tunnel  : $NAME"
	echo "    Unit    : $UNIT"
	echo
	read -p "This will stop the service and delete the tunnel from Cloudflare. Continue? [y/N] " -n 1 -r || true
	echo
	if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
		echo "Aborted by user."
		exit 0
	fi
	echo

	echo "[+] stopping and disabling ${UNIT}"
	sudo systemctl disable --now "$UNIT" || true

	local UUID=""
	if [[ -f "$YAML" ]]; then
		UUID="$(grep -E '^tunnel:' "$YAML" | awk '{print $2}')"
	fi

	echo "[+] removing tunnel '${NAME}' (if it exists)"
	if ! cloudflared tunnel delete "$NAME" >/dev/null 2>&1; then
		die "Cloudflare tunnel deletion failed; local tunnel files were preserved"
	fi

	echo "[+] cleaning up local files"
	rm -f "$YAML"
	local creds_dir
	creds_dir="$(zone_base_dir)"
	[[ -n "$UUID" ]] && rm -f "${creds_dir}/${UUID}.json"

	echo "✅ removed: ${NAME}"
}

op_start() {
	[[ -n "${NAME:-}" ]] || die "--name is required"
	NAME="$(slugify "$NAME")"
	if [[ $EUID -ne 0 ]]; then sudo -v || die "needs sudo permission"; fi
	sudo systemctl enable --now "$(instance_unit "$NAME")"
}
op_stop() {
	[[ -n "${NAME:-}" ]] || die "--name is required"
	NAME="$(slugify "$NAME")"
	if [[ $EUID -ne 0 ]]; then sudo -v || die "needs sudo permission"; fi
	sudo systemctl disable --now "$(instance_unit "$NAME")" || true
}
op_status() {
	[[ -n "${NAME:-}" ]] || die "--name is required"
	NAME="$(slugify "$NAME")"
	local unit
	unit="$(instance_unit "$NAME")"
	if json_enabled; then
		need jq
		local status scope_zone data
		status="$(systemd_unit_status "$unit")"
		scope_zone="$(json_nullable_string "${ZONE:-}")"
		data="$(jq -cn \
			--arg name "$NAME" \
			--arg unit "$unit" \
			--arg status "$status" \
			--arg checked_at "$(utc_now)" \
			--argjson zone "$scope_zone" \
			'{zone: $zone, name: $name, unit: $unit, status: $status, source: "systemd", checked_at: $checked_at}')"
		json_success "tunnel.status" "$data"
		return
	fi
	systemctl status "$unit"
}
op_logs() {
	[[ -n "${NAME:-}" ]] || die "--name is required"
	NAME="$(slugify "$NAME")"
	if [[ $EUID -ne 0 ]]; then sudo -v || die "needs sudo permission"; fi
	sudo journalctl -fu "$(instance_unit "$NAME")"
}

list_yaml_files() {
	local zones_dir="$HOME_DIR/.cloudflared/zones"
	[[ -d "$zones_dir" ]] || return 0

	if [[ -n "$ZONE" ]]; then
		local zone_dir="$zones_dir/$ZONE"
		[[ -d "$zone_dir" ]] || return 0
		find "$zone_dir" -mindepth 1 -maxdepth 1 -type f -name '*.yml' -print0 2>/dev/null | sort -z
	else
		find "$zones_dir" -mindepth 2 -maxdepth 2 -type f -name '*.yml' -print0 2>/dev/null | sort -z
	fi
}

tunnel_uuid_from_yaml() {
	local yaml="$1"
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
		/^tunnel:[[:space:]]*/ {
			value = $0
			sub(/^tunnel:[[:space:]]*/, "", value)
			print unquote(value)
			exit
		}
	' "$yaml"
}

ingress_routes_from_yaml() {
	local yaml="$1"
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
		/^ingress:[[:space:]]*$/ {
			in_ingress = 1
			hostname = ""
			next
		}
		in_ingress && /^[^[:space:]#][^:]*:/ {
			in_ingress = 0
			hostname = ""
		}
		in_ingress && /^[[:space:]]*-[[:space:]]*hostname:[[:space:]]*/ {
			value = $0
			sub(/^[[:space:]]*-[[:space:]]*hostname:[[:space:]]*/, "", value)
			hostname = unquote(value)
			next
		}
		in_ingress && hostname != "" && /^[[:space:]]+service:[[:space:]]*/ {
			value = $0
			sub(/^[[:space:]]+service:[[:space:]]*/, "", value)
			service = unquote(value)
			if (service != "") {
				printf "%s\t%s\n", hostname, service
			}
			hostname = ""
			next
		}
		in_ingress && /^[[:space:]]*-[[:space:]]+/ {
			hostname = ""
		}
	' "$yaml"
}

op_list_json() {
	need jq
	local entries=()
	local yaml
	while IFS= read -r -d '' yaml; do
		local zone_name name raw_uuid uuid unit status routes config_mode credential_path credential_mode issues
		zone_name="$(basename "$(dirname "$yaml")")"
		name="$(basename "$yaml" .yml)"
		raw_uuid="$(tunnel_uuid_from_yaml "$yaml")"
		uuid="$(validate_tunnel_uuid "$raw_uuid" 2>/dev/null || true)"
		unit="cloudflared@${zone_name}_${name}.service"
		status="$(systemd_unit_status "$unit")"
		config_mode="$(file_mode_or_null "$yaml")"
		credential_path="$(credentials_file_from_yaml "$yaml")"
		credential_mode="$(file_mode_or_null "$credential_path")"
		routes='[]'

		local hostname service route
		while IFS=$'\t' read -r hostname service; do
			[[ -n "$hostname" && -n "$service" ]] || continue
			route="$(jq -cn --arg hostname "$hostname" --arg service "$service" '{hostname: $hostname, service: $service}')"
			routes="$(jq -cn --argjson routes "$routes" --argjson route "$route" '$routes + [$route]')"
		done < <(ingress_routes_from_yaml "$yaml")
		issues='[]'
		[[ -n "$uuid" ]] || issues="$(jq -cn --argjson issues "$issues" '$issues + ["tunnel UUID is missing or invalid"]')"
		[[ -n "$credential_mode" ]] || issues="$(jq -cn --argjson issues "$issues" '$issues + ["tunnel credential JSON is missing or unreadable"]')"
		[[ "$routes" != '[]' ]] || issues="$(jq -cn --argjson issues "$issues" '$issues + ["no hostname routes were found in the YAML"]')"

		entries+=("$(jq -cn \
			--arg zone "$zone_name" \
			--arg name "$name" \
			--arg uuid "$uuid" \
			--arg unit "$unit" \
			--arg status "$status" \
			--arg config_mode "$config_mode" \
			--arg credential_mode "$credential_mode" \
			--argjson issues "$issues" \
			--argjson routes "$routes" \
			'{zone: $zone, name: $name, uuid: (if $uuid == "" then null else $uuid end), unit: $unit, status: $status, config: {yaml: {present: ($config_mode != ""), mode: (if $config_mode == "" then null else $config_mode end)}, credential: {present: ($credential_mode != ""), mode: (if $credential_mode == "" then null else $credential_mode end)}, issues: $issues}, routes: $routes}')")
	done < <(list_yaml_files)

	local tunnels scope_zone data
	if [[ ${#entries[@]} -eq 0 ]]; then
		tunnels='[]'
	else
		tunnels="$(printf '%s\n' "${entries[@]}" | jq -cs '.')"
	fi
	scope_zone="$(json_nullable_string "${ZONE:-}")"
	data="$(jq -cn --arg checked_at "$(utc_now)" --argjson scope_zone "$scope_zone" --argjson tunnels "$tunnels" '{scope_zone: $scope_zone, listed_at: $checked_at, tunnels: $tunnels}')"
	json_success "tunnel.list" "$data"
}

op_list() {
	if json_enabled; then
		op_list_json
		return
	fi
	if [[ -n "$ZONE" ]]; then
		echo "[zone] $ZONE"
	fi

	printf "%-22s %-28s %-40s %-10s %-10s %-48s %s\n" \
		"ZONE" "NAME" "HOSTNAME" "STATUS" "SERVICE" "UNIT" "UUID"

	local found=0
	local yaml
	while IFS= read -r -d '' yaml; do
		local zone_name
		zone_name="$(basename "$(dirname "$yaml")")"

		local name
		name="$(basename "$yaml" .yml)"

		local uuid
		uuid="$(tunnel_uuid_from_yaml "$yaml")"
		[[ -n "$uuid" ]] || uuid="-"

		local unit="cloudflared@${zone_name}_${name}.service"

		local status
		status="$(systemd_unit_status "$unit")"

		local unit_display="@${unit#*@}"
		local hostname full_service
		while IFS=$'\t' read -r hostname full_service; do
			[[ -n "$hostname" && -n "$full_service" ]] || continue

			local service_protocol
			if [[ "$full_service" == *"://"* ]]; then
				service_protocol="${full_service%%://*}"
			else
				service_protocol="$full_service"
			fi

			((found++)) || true
			printf "%-22s %-28s %-40s %-10s %-10s %-48s %s\n" \
				"$zone_name" "$name" "$hostname" "$status" "$service_protocol" "$unit_display" "$uuid"
		done < <(ingress_routes_from_yaml "$yaml")
	done < <(list_yaml_files)

	if [[ $found -eq 0 ]]; then
		echo
		if [[ -n "$ZONE" ]]; then
			echo "[!] No hostname routes found in zone '$ZONE'."
		else
			echo "[!] No hostname routes found in configured zones."
		fi
	fi
}
