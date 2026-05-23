#!/usr/bin/env bash
set -euo pipefail

# cftunnel — per-subdomain tunnel manager (one YAML per tunnel)
#
# "add" command flow:
#   1. validate flags (hostname, type, service)
#   2. create Cloudflare tunnel (if it doesn't exist yet)
#   3. generate YAML with ingress rules (hostname → local origin)
#   4. validate ingress via cloudflared
#   5. check existing DNS and create CNAME route (--no-dns skips this step)
#   6. wait for DNS propagation and verify resolution
#   7. enable and start systemd service (cloudflared@NAME)
#
# basic usage:
#   cftunnel add --hostname ssh.example.com --type ssh --service ssh://localhost:22 --name ssh-config
#   cftunnel add --hostname api.example.com --type http --service http://localhost:4000
#   cftunnel add --hostname redis.example.com --type tcp --service tcp://localhost:6379 --no-dns
#   cftunnel remove --name ssh-config
#   cftunnel start|stop|status|logs --name ssh-config
#   cftunnel list
#
# IMPORTANT: For TCP/UDP tunnels (Redis, databases, etc.):
#   1. The tunnel is created on the server with this script
#   2. On the client machine THAT WILL ACCESS the service, run:
#      cloudflared access tcp --hostname <HOSTNAME> --url localhost:<PORT>
#   3. Then connect your application to localhost:<PORT> (not the public hostname)
#   4. Traffic will flow encrypted through the Cloudflare tunnel
#
# Example for Redis access from another machine:
#   On server: cftunnel add --hostname redis.example.com --type tcp --service tcp://localhost:6379
#   On client: cloudflared access tcp --hostname redis.example.com --url localhost:6379
#   Then:      redis-cli -h localhost -p 6379

# ===== Default config ======================================================
RUN_USER="${RUN_USER:-$USER}"
HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")"
CLOUDFLARED_BIN="$(command -v cloudflared || true)"
BASE_DIR="$HOME_DIR/.cloudflared"
SYSTEMD_TPL="/etc/systemd/system/cloudflared@.service"

# ===== Utilities ===========================================================
die() {
	echo "error: $*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Generate a safe name for a systemd instance from a hostname or custom name.
# Sanitizes special characters so the name is valid as a systemd unit
# (only [a-z0-9] and hyphens, no leading or trailing hyphens).
slugify() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

ensure_template() {
	[[ -f "$SYSTEMD_TPL" ]] || die "systemd template not found: $SYSTEMD_TPL
Create it as configured (ExecStart=/usr/local/bin/cloudflared tunnel --config $HOME/.cloudflared/%i.yml run; User=$RUN_USER)."
}

instance_unit() { echo "cloudflared@${1}.service"; }

yaml_path_for() { echo "$BASE_DIR/${1}.yml"; }

json_path_for_uuid() { echo "$BASE_DIR/${1}.json"; }

# Resolve hostname via DNS with 3-tier fallback (no external dependencies):
#   Tier 1: dig @1.1.1.1 (Cloudflare DNS — shows CNAME, ideal for validating cfargotunnel.com)
#   Tier 2: host           (alternative with CNAME support, same package as dig)
#   Tier 3: getent ahosts  (glibc built-in — returns IP only, no CNAME)
# If no tool is available, returns an empty string.
resolve_hostname() {
	local hostname="$1"

	if command -v dig >/dev/null 2>&1; then
		dig @1.1.1.1 +short "$hostname" 2>/dev/null
		return
	fi

	if command -v host >/dev/null 2>&1; then
		host "$hostname" 2>/dev/null | awk '/has address|is an alias/{print $NF}' | head -1
		return
	fi

	if command -v getent >/dev/null 2>&1; then
		getent ahosts "$hostname" 2>/dev/null | awk '{print $1; exit}'
		return
	fi

	echo ""
}

# Check whether a CNAME-capable lookup tool is available (dig or host).
# getent ahosts only returns IPs — without CNAME, the cfargotunnel.com pattern cannot be validated.
has_cname_lookup() {
	command -v dig >/dev/null 2>&1 || command -v host >/dev/null 2>&1
}

print_usage() {
	cat <<USAGE
Usage:
  $0 add --hostname FQDN --type (ssh|http|tcp) --service URL [--name NAME] [--no-dns]
  $0 remove --name NAME
  $0 start|stop|status|logs --name NAME
  $0 list

Examples:
  $0 add --hostname ssh.example.com  --type ssh  --service ssh://localhost:22  --name ssh-config
  $0 add --hostname api.example.com  --type http --service http://localhost:4000
  $0 add --hostname redis.example.com --type tcp --service tcp://localhost:6379 --no-dns
  $0 logs --name ssh-config
USAGE
}

validate_flags_add() {
	[[ -n "${TUNNEL_HOSTNAME:-}" ]] || die "--hostname is required"
	[[ -n "${TYPE:-}" ]] || die "--type ssh|http|tcp is required"
	[[ -n "${SERVICE:-}" ]] || die "--service is required (e.g.: ssh://localhost:22, http://localhost:4000, tcp://localhost:6379)"
	case "$TYPE" in
	ssh | http | tcp) : ;;
	*) die "--type invalid: $TYPE (use ssh|http|tcp)" ;;
	esac

	# Validate that TYPE matches the SERVICE scheme
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

# ===== Operations ==========================================================
op_add() {
	need cloudflared
	need jq
	ensure_template

	validate_flags_add

	# Derive NAME if not provided: uses base-domain + type (e.g.: example.com + http → example-com-http)
	local BASE_DOMAIN
	BASE_DOMAIN="$(echo "$TUNNEL_HOSTNAME" | rev | cut -d. -f1-2 | rev)"
	local DEFAULT_NAME
	DEFAULT_NAME="${BASE_DOMAIN}-${TYPE}"
	DEFAULT_NAME="$(echo "$DEFAULT_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/\./-/g')"
	NAME="${NAME:-$DEFAULT_NAME}"
	NAME="$(slugify "$NAME")"
	local UNIT
	UNIT="$(instance_unit "$NAME")"
	local YAML
	YAML="$(yaml_path_for "$NAME")"

	mkdir -p "$BASE_DIR"

	# 1) Create tunnel (if it doesn't already exist with this name)
	if ! $CLOUDFLARED_BIN tunnel list --output json | jq -er ".[] | select(.name==\"$NAME\")" >/dev/null 2>&1; then
		echo "[+] creating tunnel: $NAME"
		$CLOUDFLARED_BIN tunnel create "$NAME" >/dev/null
	else
		echo "[=] tunnel '$NAME' already exists (ok)"
	fi

	# 2) Capture UUID and credentials
	local UUID
	UUID="$($CLOUDFLARED_BIN tunnel list --output json | jq -r ".[] | select(.name==\"$NAME\") | .id")"
	[[ -n "$UUID" && "$UUID" != "null" ]] || die "could not get UUID for tunnel '$NAME'"
	local CREDS_JSON="$BASE_DIR/${UUID}.json"
	[[ -f "$CREDS_JSON" ]] || die "credentials not found: $CREDS_JSON (run 'cloudflared tunnel login' and recreate the tunnel)"

	# 3) Write YAML with:
	#    tunnel:         Cloudflare tunnel UUID
	#    credentials:    tunnel authentication key (JSON file)
	#    protocol:       http2 (recommended; h2mux is legacy)
	#    edge-ip-version: 4 (IPv4 only; use "6" or "auto" for dual-stack)
	#    originRequest:  timeouts and keepalive for the connection to the local service
	#    ingress:        hostname → local service routing (last rule is the catch-all 404)
	echo "[+] writing YAML: $YAML"
	cat >"$YAML" <<YAML
tunnel: ${UUID}
credentials-file: ${CREDS_JSON}

protocol: "http2"
edge-ip-version: "4"

originRequest:
  tcpKeepAlive: "30s"
  keepAliveTimeout: "2m"
  connectTimeout: "10s"

ingress:
  - hostname: "${TUNNEL_HOSTNAME}"
    service: "${SERVICE}"
  - service: http_status:404
YAML
	chmod 600 "$YAML"

	# 4) Validate ingress
	echo "[+] validating ingress"
	$CLOUDFLARED_BIN tunnel --config "$YAML" ingress validate

	# 5) DNS: check existing records, create CNAME route, wait for propagation
	if [[ "${NO_DNS:-false}" == true ]]; then
		echo "[=] --no-dns: skipping DNS creation"
		echo "[=] Create the CNAME record manually in the Cloudflare dashboard:"
		echo "    ${TUNNEL_HOSTNAME} → ${UUID}.cfargotunnel.com"
	else
		# 5.1) Check existing DNS before creating route
		echo "[+] checking existing DNS for ${TUNNEL_HOSTNAME}..."
		local EXISTING_DNS
		EXISTING_DNS="$(resolve_hostname "$TUNNEL_HOSTNAME")"
		if [[ -n "$EXISTING_DNS" ]]; then
			if has_cname_lookup && [[ "$EXISTING_DNS" == *".cfargotunnel.com"* ]]; then
				echo "[=] DNS already points to cfargotunnel (ok)"
			elif ! has_cname_lookup; then
				echo "[=] DNS resolves: $EXISTING_DNS (CNAME verification unavailable without dig/host)"
			else
				echo "[!] WARNING: ${TUNNEL_HOSTNAME} already has DNS: $EXISTING_DNS"
				echo "[!] This may cause error 1003 when creating the CNAME route."
				echo "[!] Recommendation: remove the existing DNS record (A/CNAME) in the Cloudflare dashboard before continuing."
				read -p "Continue anyway? (y/N) " -n 1 -r || true
				echo
				if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
					die "Operation cancelled by user. Remove the DNS record and try again."
				fi
			fi
		fi

		# 5.2) Create/update DNS (CNAME to cfargotunnel) — with fail-fast
		echo "[+] creating/updating DNS for ${TUNNEL_HOSTNAME}"
		local DNS_OUTPUT
		if ! DNS_OUTPUT="$($CLOUDFLARED_BIN tunnel route dns "$NAME" "$TUNNEL_HOSTNAME" 2>&1)"; then
			echo "[!] cloudflared error: $DNS_OUTPUT"
			die "failed to create DNS for ${TUNNEL_HOSTNAME}. Check: (1) API token configured? (2) zone in the account? (3) record already exists?"
		fi
		echo "$DNS_OUTPUT"

		# 5.3) Validate DNS was created correctly (waits up to 30s for propagation)
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

	# 6) Start systemd instance
	echo "[+] enabling and starting service: $UNIT"
	sudo systemctl daemon-reload
	sudo systemctl enable --now "$UNIT"
	sudo systemctl is-active --quiet "$UNIT" || {
		sudo systemctl status "$UNIT" || true
		die "service did not become active"
	}

	echo
	echo "✅ ready! Tunnel '${NAME}' active for '${TUNNEL_HOSTNAME}' → ${SERVICE}"
	echo "   - YAML: ${YAML}"
	echo "   - Unit: ${UNIT}"
	echo "   - Logs: sudo journalctl -fu ${UNIT}"
	echo
	# Specific info for TCP/UDP tunnels
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

	if [[ $EUID -ne 0 ]]; then
		sudo -v || die "needs sudo permission"
	fi

	local UNIT
	UNIT="$(instance_unit "$NAME")"
	local YAML
	YAML="$(yaml_path_for "$NAME")"

	echo "[+] stopping and disabling ${UNIT}"
	sudo systemctl disable --now "$UNIT" || true

	# locate UUID from YAML (if it exists)
	local UUID=""
	if [[ -f "$YAML" ]]; then
		UUID="$(grep -E '^tunnel:' "$YAML" | awk '{print $2}')"
	fi

	echo "[+] removing tunnel '${NAME}' (if it exists)"
	$CLOUDFLARED_BIN tunnel delete "$NAME" >/dev/null 2>&1 || true

	echo "[+] cleaning up local files"
	rm -f "$YAML"
	[[ -n "$UUID" ]] && rm -f "$BASE_DIR/${UUID}.json"

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

op_list() {
	need jq
	printf "%-18s %-38s %-5s %-10s %-30s %s\n" "NAME" "UUID" "UP" "SERVICE" "UNIT" "HOSTNAME → SERVICE"
	local arr
	arr="$($CLOUDFLARED_BIN tunnel list --output json | jq -rc '.[] | [.name,.id] | @tsv')"
	while IFS=$'\t' read -r n id; do
		[[ -z "$n" ]] && continue
		local yml="$BASE_DIR/${n}.yml"
		local up="no" svc_state="inactive" unit="cloudflared@${n}.service" host="-" svc="-"
		if systemctl is-active --quiet "$unit" 2>/dev/null; then
			up="yes"
			svc_state="active"
		elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
			svc_state="enabled"
		fi
		if [[ -f "$yml" ]]; then
			host="$(awk '/hostname:/{print $2; exit}' "$yml" || echo "-")"
			svc="$(awk '/service:/{print $2; exit}' "$yml" || echo "-")"
		fi
		printf "%-18s %-38s %-5s %-10s %-30s %s → %s\n" "$n" "$id" "$up" "$svc_state" "$unit" "$host" "$svc"
	done <<<"$arr"
}

# ===== Argument parser =====================================================
cmd="${1:-}"
shift || true
NAME=""
TUNNEL_HOSTNAME=""
TYPE=""
SERVICE=""
NO_DNS=false

case "${cmd:-}" in
add)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--hostname)
			TUNNEL_HOSTNAME="${2:-}"
			shift 2
			;;
		--type)
			TYPE="${2:-}"
			shift 2
			;;
		--service)
			SERVICE="${2:-}"
			shift 2
			;;
		--name)
			NAME="${2:-}"
			shift 2
			;;
		--no-dns)
			NO_DNS=true
			shift
			;;
		-h | --help)
			print_usage
			exit 0
			;;
		*)
			echo "unknown flag: $1"
			print_usage
			exit 1
			;;
		esac
	done
	op_add
	;;
remove)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		-h | --help)
			print_usage
			exit 0
			;;
		*)
			echo "unknown flag: $1"
			print_usage
			exit 1
			;;
		esac
	done
	op_remove
	;;
start)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		*)
			print_usage
			exit 1
			;;
		esac
	done
	op_start
	;;
stop)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		*)
			print_usage
			exit 1
			;;
		esac
	done
	op_stop
	;;
status)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		*)
			print_usage
			exit 1
			;;
		esac
	done
	op_status
	;;
logs)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		*)
			print_usage
			exit 1
			;;
		esac
	done
	op_logs
	;;
list) op_list ;;
-h | --help | "") print_usage ;;
*)
	echo "unknown command: $cmd"
	print_usage
	exit 1
	;;
esac
