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

validate_flags_add() {
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

	case "$TYPE" in
	ssh)
		[[ "$SERVICE" == ssh://* ]] || die "--type ssh requires --service ssh://... (e.g.: ssh://localhost:22)"
		;;
	http)
		[[ "$SERVICE" == http://* ]] || die "--type http requires --service http://... (e.g.: http://localhost:4000)"
		;;
	tcp)
		[[ "$SERVICE" == tcp://* ]] || die "--type tcp requires --service tcp://... (e.g.: tcp://localhost:6379)"
		;;
	esac

	if [[ $EUID -ne 0 ]]; then
		sudo -v || die "needs sudo permission"
	fi
}

op_add() {
	validate_flags_add

	need cloudflared
	need jq
	ensure_template

	local BASE_DOMAIN
	BASE_DOMAIN="$(echo "$TUNNEL_HOSTNAME" | rev | cut -d. -f1-2 | rev)"
	local DEFAULT_NAME
	DEFAULT_NAME="${BASE_DOMAIN}-${TYPE}"
	DEFAULT_NAME="$(echo "$DEFAULT_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/\./-/g')"
	NAME="${NAME:-$DEFAULT_NAME}"
	NAME="$(slugify "$NAME")"
	[[ -n "$NAME" ]] || die "tunnel name is empty after sanitization"
	local UNIT
	UNIT="$(instance_unit "$NAME")"
	local YAML
	YAML="$(yaml_path_for "$NAME")"

	ensure_zone_dir

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
	read -p "Continue? [y/N] " -n 1 -r || true
	echo
	if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
		echo "Aborted by user."
		exit 0
	fi
	echo

	if ! cloudflared tunnel list --output json | jq -er ".[] | select(.name==\"$NAME\")" >/dev/null 2>&1; then
		echo "[+] creating tunnel: $NAME"
		cloudflared tunnel create "$NAME" >/dev/null
	else
		echo "[=] tunnel '$NAME' already exists (ok)"
	fi

	local UUID
	UUID="$(cloudflared tunnel list --output json | jq -r ".[] | select(.name==\"$NAME\") | .id")"
	[[ -n "$UUID" && "$UUID" != "null" ]] || die "could not get UUID for tunnel '$NAME'"

	local CREDS_JSON="$(zone_base_dir)/${UUID}.json"
	local created_json="$BASE_DIR/${UUID}.json"
	if [[ -n "$ZONE" && -f "$created_json" && ! -f "$CREDS_JSON" ]]; then
		mv "$created_json" "$CREDS_JSON"
		echo "[+] moved credentials to zone directory"
	fi

	[[ -f "$CREDS_JSON" ]] || die "credentials not found: $CREDS_JSON (run 'cloudflared tunnel login' and recreate the tunnel)"

	if [[ -f "$YAML" ]]; then
		local existing_entries
		existing_entries=$(awk '/^ingress:/{flag=1; next} /  - service: http_status:404/{flag=0} flag' "$YAML" 2>/dev/null || true)
		if echo "$existing_entries" | grep -qF "hostname: \"${TUNNEL_HOSTNAME}\"" 2>/dev/null; then
			echo "[=] hostname '${TUNNEL_HOSTNAME}' already in ingress (ok)"
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
			read -p "Continue anyway? (y/N) " -n 1 -r || true
			echo
			if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
				die "Operation cancelled."
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

	echo "[+] enabling and starting service: $UNIT"
	sudo systemctl daemon-reload
	sudo systemctl enable --now "$UNIT"
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
	if [[ $EUID -ne 0 ]]; then sudo -v || die "needs sudo permission"; fi
	systemctl status "$(instance_unit "$NAME")"
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

op_list() {
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

		local status="inactive"
		if systemctl is-active --quiet "$unit" 2>/dev/null; then
			status="active"
		elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
			status="enabled"
		fi

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
