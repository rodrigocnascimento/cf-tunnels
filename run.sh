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

# Wrapper to call cloudflared while suppressing the ugly "outdated version" JSON warning
# that cloudflared prints on every invocation when it's old.
cloudflared() {
	"$CLOUDFLARED_BIN" "$@" 2>&1 | grep -v -i '"outdated"' || true
}
PROFILE=""
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

# Returns the base directory for the current (slugified) profile.
# No profile  -> ~/.cloudflared/
# With profile -> ~/.cloudflared/profiles/<slug-profile>/
profile_base_dir() {
	if [[ -n "$PROFILE" ]]; then
		local p
		p="$(slugify "$PROFILE")"
		echo "$HOME_DIR/.cloudflared/profiles/${p}"
	else
		echo "$HOME_DIR/.cloudflared"
	fi
}

# Path to the file that stores the user's "default/persistent" profile
DEFAULT_PROFILE_FILE="$HOME_DIR/.cloudflared/.default_profile"

# Load the persisted default profile (if any)
# Returns the slugified name or empty string if invalid/missing
load_default_profile() {
	local target_file="$HOME/.cloudflared/.default_profile"

	if [[ ! -f "$target_file" ]]; then
		return 0
	fi

	local raw
	raw="$(cat "$target_file" 2>/dev/null | tr -d '\n\r' | head -1)"

	# Validate content
	if [[ -z "$raw" ]]; then
		rm -f "$target_file"
		return 0
	fi

	local cleaned
	cleaned="$(slugify "$raw")"

	if [[ -z "$cleaned" ]]; then
		rm -f "$target_file"
		return 0
	fi

	# Keep variable in sync
	DEFAULT_PROFILE_FILE="$target_file"

	echo "$cleaned"
}

# Save a profile as the new default/persistent one (always saves slugified name)
save_default_profile() {
	local prof="$1"
	local cleaned
	cleaned="$(slugify "$prof")"

	if [[ -z "$cleaned" ]]; then
		die "Invalid profile name: '$prof'"
	fi

	# Use $HOME directly to avoid any ordering/definition issues with $HOME_DIR or $DEFAULT_PROFILE_FILE
	local target_file="$HOME/.cloudflared/.default_profile"

	mkdir -p "$(dirname "$target_file")"
	echo "$cleaned" > "$target_file"
	chmod 600 "$target_file"

	# Also keep the variable in sync in case other code uses it later
	DEFAULT_PROFILE_FILE="$target_file"
}

# Clear the current default profile
unset_default_profile() {
	rm -f "$DEFAULT_PROFILE_FILE"
}

# Valida se um nome de perfil é aceitável (não vazio e produz algo após slugify)
validate_profile_name() {
	local name="$1"
	local cleaned
	cleaned="$(slugify "$name")"

	if [[ -z "$cleaned" ]]; then
		die "Invalid profile name: '$name' (must contain at least one valid character)"
	fi

	echo "$cleaned"
}

# Path to the profile metadata file (stores primary domain, etc.)
profile_metadata_file() {
	echo "$(profile_base_dir)/profile.json"
}

# Ensure the directory for the current profile exists
ensure_profile_dir() {
	local dir
	dir="$(profile_base_dir)"
	mkdir -p "$dir"
}

# Load primary domain for the current profile (if any)
load_profile_primary_domain() {
	local meta_file
	meta_file="$(profile_metadata_file)"
	if [[ -f "$meta_file" ]]; then
		jq -r '.primary_domain // empty' "$meta_file" 2>/dev/null || echo ""
	else
		echo ""
	fi
}

# Save primary domain for the current profile
save_profile_primary_domain() {
	local domain="$1"
	local meta_file
	meta_file="$(profile_metadata_file)"
	mkdir -p "$(dirname "$meta_file")"
	if [[ -f "$meta_file" ]]; then
		jq --arg d "$domain" '.primary_domain = $d' "$meta_file" > "${meta_file}.tmp" && mv "${meta_file}.tmp" "$meta_file"
	else
		echo "{\"primary_domain\": \"$domain\"}" > "$meta_file"
	fi
}

ensure_template() {
	[[ -f "$SYSTEMD_TPL" ]] || die "systemd template not found: $SYSTEMD_TPL
Create it as configured (ExecStart=/usr/local/bin/cloudflared tunnel --config $HOME/.cloudflared/%i.yml run; User=$RUN_USER).

Tip: If using --profile, the template is still the single global one (cloudflared@.service)."
}

instance_unit() {
	local name="$1"
	if [[ -n "$PROFILE" ]]; then
		local p
		p="$(slugify "$PROFILE")"
		echo "cloudflared@${p}_${name}.service"
	else
		echo "cloudflared@${name}.service"
	fi
}

yaml_path_for() {
	local dir
	dir="$(profile_base_dir)"
	echo "${dir}/${1}.yml"
}

json_path_for_uuid() {
	local dir
	dir="$(profile_base_dir)"
	echo "${dir}/${1}.json"
}

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
  $0 [global options] <command> [command options]

Global options:
  --profile NAME     Operate within a specific profile (can appear anywhere)

Commands:
  add           --hostname FQDN --type (ssh|http|tcp) --service URL [--name NAME] [--no-dns]
  remove        --name NAME
  start|stop|status|logs   --name NAME
  list
  cli-update    Update the cloudflared binary to the latest version
  profile       Manage persistent default profile (workspace-like)

Profile commands:
  profile use <name>     Set a profile as the default (persistent)
  profile current        Show the current default profile
  profile unset          Clear the default profile

  You can also use: cftunnel --profile <name> --persist

Examples:
  cftunnel --profile homelab start --name login
  cftunnel start --name api --profile work
  cftunnel --profile homelab list
  cftunnel add --hostname ssh.example.com --type ssh --service ssh://localhost:22 --name ssh-config --profile homelab
  cftunnel cli-update

  # Workspace / persistent profile
  cftunnel profile use homelab
  cftunnel list                    # will use homelab by default
  cftunnel --profile work list     # temporary override + offer to switch default
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

# ===== Cloudflared CLI Management ==========================================

# ===== Profile Management (persistent default) =============================

op_profile() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
		use|set|switch)
			local target="$1"
			if [[ -z "$target" ]]; then
				die "Usage: cftunnel profile use <profile-name>"
			fi
			local cleaned
			cleaned="$(validate_profile_name "$target")"
			save_default_profile "$cleaned"
			echo "✅ Default profile set to '$cleaned'."
			;;
		current|show)
			local current
			current="$(load_default_profile)"
			if [[ -n "$current" ]]; then
				echo "Current default (persistent) profile: $current"
				echo "All commands without --profile will use this one."
			else
				echo "No default profile is set."
				echo "Use: cftunnel profile use <name>   or   cftunnel --profile <name> --persist"
			fi
			;;
		unset|clear|remove)
			unset_default_profile
			echo "Default profile has been cleared."
			;;
		*)
			echo "Usage:"
			echo "  cftunnel profile use <name>     Set default/persistent profile"
			echo "  cftunnel profile current        Show current default profile"
			echo "  cftunnel profile unset          Clear the default profile"
			exit 1
			;;
	esac
}

# ===== Cloudflared CLI Management ==========================================

update_cloudflared() {
	echo "[+] Checking current cloudflared version..."
	local current_version=""
	if command -v cloudflared >/dev/null 2>&1; then
		current_version=$(cloudflared --version 2>/dev/null | awk '{print $3}' | head -1 || echo "unknown")
		echo "    Current version: $current_version"
	fi

	echo "[+] Downloading latest cloudflared..."

	local arch
	arch=$(uname -m)
	case "$arch" in
		x86_64)  arch="amd64" ;;
		aarch64|arm64) arch="arm64" ;;
		*) die "Unsupported architecture: $arch" ;;
	esac

	local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
	local bin_path="/usr/local/bin/cloudflared"

	echo "    Downloading from: $download_url"

	local tmp_file
	tmp_file=$(mktemp)

	if command -v curl >/dev/null 2>&1; then
		curl -fSL --retry 3 --retry-delay 2 "$download_url" -o "$tmp_file" || die "Failed to download cloudflared"
	elif command -v wget >/dev/null 2>&1; then
		wget -q "$download_url" -O "$tmp_file" || die "Failed to download cloudflared"
	else
		die "Neither curl nor wget is available"
	fi

	chmod +x "$tmp_file"

	echo "[+] Installing to $bin_path (requires sudo)..."
	if sudo mv "$tmp_file" "$bin_path"; then
		sudo chmod +x "$bin_path"
		local new_version
		new_version=$($bin_path --version 2>/dev/null | awk '{print $3}' | head -1 || echo "unknown")
		echo "✅ Successfully updated cloudflared to version: $new_version"
	else
		rm -f "$tmp_file"
		die "Failed to install cloudflared (permission issue?)"
	fi
}

check_cloudflared_version() {
	# Don't check when the user is explicitly trying to update
	# Also skip for the 'profile' subcommand so it doesn't interfere while setting up workspaces
	if [[ "$cmd" == "cli-update" || "$cmd" == "profile" || -z "${cmd:-}" ]]; then
		return 0
	fi

	# Run a silent probe to detect if cloudflared is complaining about being outdated.
	# Using the wrapper ensures the ugly warning is filtered.
	local output
	output=$(cloudflared tunnel list --output json | cat || true)

	if echo "$output" | grep -qi "outdated"; then
		echo
		echo "⚠️  Seu cloudflared está desatualizado."
		echo "    Versão atual:  $(cloudflared --version 2>/dev/null | awk '{print $3}' | head -1)"
		echo "    Recomendado: atualizar para a versão mais recente."
		echo
		read -p "Deseja atualizar o cloudflared agora? [y/N] " -n 1 -r || true
		echo
		if [[ "$REPLY" =~ ^[Yy]$ ]]; then
			update_cloudflared
		else
			echo "Atualização cancelada. Você pode rodar manualmente depois com: cftunnel cli-update"
		fi
		echo
	fi
}

# ===== Operations ==========================================================
op_add() {
	need cloudflared
	need jq
	ensure_template

	validate_flags_add

	# Derive NAME if not provided
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

	ensure_profile_dir

	# === Confirmation before destructive actions ===
	local prof_display="${PROFILE:-default}"
	echo
	echo ">>> About to perform the following actions:"
	echo "    Profile      : $prof_display"
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

	# === Domain validation for the profile ===
	local primary_domain
	primary_domain="$(load_profile_primary_domain)"

	if [[ -n "$primary_domain" ]]; then
		if [[ "$TUNNEL_HOSTNAME" != *".$primary_domain" && "$TUNNEL_HOSTNAME" != "$primary_domain" ]]; then
			echo ">>> WARNING: This profile is associated with domain '$primary_domain'"
			echo "    You are trying to add: $TUNNEL_HOSTNAME"
			echo
			read -p "Are you sure you want to continue? [y/N] " -n 1 -r || true
			echo
			if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
				echo "Aborted by user."
				exit 0
			fi
		fi
	fi

	# 1) Create tunnel (if it doesn't already exist with this name)
	if ! cloudflared tunnel list --output json | jq -er ".[] | select(.name==\"$NAME\")" >/dev/null 2>&1; then
		echo "[+] creating tunnel: $NAME"
		cloudflared tunnel create "$NAME" >/dev/null
	else
		echo "[=] tunnel '$NAME' already exists (ok)"
	fi

	# 2) Capture UUID and credentials
	local UUID
	UUID="$(cloudflared tunnel list --output json | jq -r ".[] | select(.name==\"$NAME\") | .id")"
	[[ -n "$UUID" && "$UUID" != "null" ]] || die "could not get UUID for tunnel '$NAME'"

	# Move credentials to profile directory if using profiles
	local CREDS_JSON="$(profile_base_dir)/${UUID}.json"
	local created_json="$BASE_DIR/${UUID}.json"
	if [[ -n "$PROFILE" && -f "$created_json" && ! -f "$CREDS_JSON" ]]; then
		mv "$created_json" "$CREDS_JSON"
		echo "[+] moved credentials to profile directory"
	fi

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
	cloudflared tunnel --config "$YAML" ingress validate

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
		if ! DNS_OUTPUT="$(cloudflared tunnel route dns "$NAME" "$TUNNEL_HOSTNAME" 2>&1)"; then
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
	# Offer to save primary domain for the profile if not set yet
	if [[ -n "$PROFILE" ]]; then
		local current_primary
		current_primary="$(load_profile_primary_domain)"
		if [[ -z "$current_primary" ]]; then
			local base_dom
			base_dom="$(echo "$TUNNEL_HOSTNAME" | rev | cut -d. -f1-2 | rev)"
			echo
			read -p "Save '$base_dom' as the primary domain for profile '$PROFILE'? [Y/n] " -n 1 -r || true
			echo
			if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
				save_profile_primary_domain "$base_dom"
				echo "[+] Primary domain for profile '$PROFILE' set to: $base_dom"
			fi
		fi
	fi

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

	local prof_display="${PROFILE:-default}"
	echo
	echo ">>> About to REMOVE the following:"
	echo "    Profile : $prof_display"
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

	# locate UUID from YAML (if it exists)
	local UUID=""
	if [[ -f "$YAML" ]]; then
		UUID="$(grep -E '^tunnel:' "$YAML" | awk '{print $2}')"
	fi

	echo "[+] removing tunnel '${NAME}' (if it exists)"
	cloudflared tunnel delete "$NAME" >/dev/null 2>&1 || true

	echo "[+] cleaning up local files"
	rm -f "$YAML"
	local creds_dir
	creds_dir="$(profile_base_dir)"
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

op_list() {
	need jq

	# Show which profile is active (helps debug default vs explicit)
	if [[ -n "$PROFILE" ]]; then
		echo "[profile] $PROFILE"
	fi

	local profile_filter=""
	if [[ -n "$PROFILE" ]]; then
		profile_filter="$(slugify "$PROFILE")"
	fi

	# Get tunnels with creation date from Cloudflare API
	# The cloudflared() wrapper automatically filters the ugly "outdated" JSON warning.
	local arr
	arr="$(cloudflared tunnel list --output json | jq -rc '.[] | [.name, .id, (.created_at // "unknown")] | @tsv')"

	# Header - more spaced table
	printf "%-14s %-22s %-28s %-10s %-10s %-30s %-38s %s\n" \
		"PROFILE" "NAME" "HOSTNAME" "STATUS" "SERVICE" "UNIT" "UUID" "CREATED"

	local found=0
	while IFS=$'\t' read -r n id created_at; do
		[[ -z "$n" ]] && continue

		# Determine which profile directory to look in
		local search_dir
		if [[ -n "$profile_filter" ]]; then
			search_dir="$HOME_DIR/.cloudflared/profiles/$profile_filter"
			# If the profile directory doesn't exist yet, we still want to show tunnels from Cloudflare
			if [[ ! -d "$search_dir" ]]; then
				search_dir=""
			fi
		else
			search_dir="$HOME_DIR/.cloudflared"
		fi

		local yml=""
		[[ -n "$search_dir" ]] && yml="$search_dir/${n}.yml"

		# When filtering by profile, skip any tunnel that doesn't have its YAML in that profile's directory
		if [[ -n "$profile_filter" ]]; then
			if [[ -z "$yml" || ! -f "$yml" ]]; then
				continue
			fi
		fi

		# Build the correct unit name for current context
		local unit
		unit="$(instance_unit "$n")"

		local status="inactive"
		if systemctl is-active --quiet "$unit" 2>/dev/null; then
			status="active"
		elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
			status="enabled"
		fi

		local host="-" svc_proto="-" prof="-"

		if [[ -n "$yml" && -f "$yml" ]]; then
			# Improved hostname extraction (strip quotes and leading dash if present)
			host="$(awk -F: '/^[[:space:]]*-?[[:space:]]*hostname:/ {gsub(/"/, "", $2); gsub(/^[ \t]+/, "", $2); print $2; exit}' "$yml" || echo "-")"

			# Extract only the protocol/scheme from the service line (http, tcp, ssh, etc.)
			local full_service
			full_service="$(awk '/service:/{print $2; exit}' "$yml" || echo "-")"
			full_service="${full_service//\"/}"  # strip YAML quotes
			if [[ "$full_service" == *"://"* ]]; then
				svc_proto="${full_service%%://*}"
			else
				svc_proto="$full_service"
			fi

			# Infer profile
			if [[ -z "$profile_filter" ]]; then
				if [[ "$yml" == */profiles/* ]]; then
					prof="$(basename "$(dirname "$yml")")"
				else
					prof="default"
				fi
			else
				prof="$profile_filter"
			fi
		else
			if [[ -z "$profile_filter" ]]; then
				prof="?"
			fi
		fi

		# Format creation date (take only date part if possible)
		local created_display="$created_at"
		if [[ "$created_at" == *"T"* ]]; then
			created_display="${created_at%%T*}"
		fi

		# Show unit starting from @ (cleaner) and allow truncation
		local unit_short="${unit#*@}"
		local unit_display="@${unit_short}"

		if [[ ${#unit_display} -gt 28 ]]; then
			unit_display="${unit_display:0:25}..."
		fi

		local host_display="$host"
		if [[ ${#host} -gt 26 ]]; then
			host_display="${host:0:24}..."
		fi

		((found++)) || true
		printf "%-14s %-22s %-28s %-10s %-10s %-30s %-38s %s\n" \
			"$prof" "$n" "$host_display" "$status" "$svc_proto" "$unit_display" "$id" "$created_display"
	done <<<"$arr"

	if [[ -n "$profile_filter" && $found -eq 0 ]]; then
		echo
		echo "[!] No tunnels found in profile '$profile_filter'."
		echo "    Use 'cftunnel profile unset' to clear the default, or create a tunnel with:"
		echo "    cftunnel add ... --profile $profile_filter"
	fi
}

# ===== Argument parser =====================================================

# First pass: extract global options from anywhere in the command line.
# This makes the position of flags like --profile irrelevant.
ARGS=("$@")
PROFILE=""
PERSIST_PROFILE=false
current_default=""          # used in default profile persistence logic (top-level)

declare -a CLEAN_ARGS=()
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    arg="${ARGS[$i]}"
    case "$arg" in
        --profile)
            if [[ $((i+1)) -lt ${#ARGS[@]} ]]; then
                PROFILE="${ARGS[$((i+1))]}"
                ((i+=2)) || true
            else
                die "--profile requires a value"
            fi
            ;;
        --persist)
            PERSIST_PROFILE=true
            ((i++)) || true
            ;;
        *)
            CLEAN_ARGS+=("$arg")
            ((i++)) || true
            ;;
    esac
done

# Replace the argument list with the cleaned version (without global flags)
set -- "${CLEAN_ARGS[@]}"

cmd="${1:-}"
shift || true
NAME=""
TUNNEL_HOSTNAME=""
TYPE=""
SERVICE=""
NO_DNS=false

# Normalize any explicitly passed --profile name immediately
if [[ -n "$PROFILE" ]]; then
	PROFILE="$(slugify "$PROFILE")"
fi

# === Load default/persistent profile as early as possible ===
# This is the key part that makes "cftunnel list" work without --profile
if [[ -z "$PROFILE" ]]; then
	DEFAULT="$(load_default_profile)"
	if [[ -n "$DEFAULT" ]]; then
		PROFILE="$DEFAULT"
	fi
fi

# Special case: if the command is "profile", skip the rest of the default profile logic
# so it doesn't interfere with profile management subcommands.
if [[ "$cmd" != "profile" ]]; then
	# Handle --persist logic
	if [[ -n "$PROFILE" && "$PERSIST_PROFILE" == true ]]; then
		current_default="$(load_default_profile)"

		if [[ "$PROFILE" != "$current_default" ]]; then
			save_default_profile "$PROFILE"
			echo "[+] Profile '$PROFILE' is now the default (persistent)."
		fi
	fi

	# If user explicitly passed a different profile than the current default (without --persist),
	# offer to make it the new default (workspace-like behavior).
	if [[ -n "$PROFILE" && "$PERSIST_PROFILE" != true ]]; then
		current_default="$(load_default_profile)"

		if [[ -n "$current_default" && "$PROFILE" != "$current_default" ]]; then
			echo
			echo ">>> You are using profile '$PROFILE', but your current default is '$current_default'."
			read -p "Do you want to make '$PROFILE' your new default profile? [y/N] " -n 1 -r || true
			echo
			if [[ "$REPLY" =~ ^[Yy]$ ]]; then
				save_default_profile "$PROFILE"
				echo "[+] Default profile changed to '$PROFILE'."
			fi
		fi
	fi
fi

# === Hard Gate: Version check for cloudflared ===
# This runs for EVERY command (except cli-update itself) as the first thing.
check_cloudflared_version

# If --persist already did its job and no command remains, exit cleanly with a friendly message
if [[ -z "${cmd:-}" && "$PERSIST_PROFILE" == true && -n "$PROFILE" ]]; then
	echo "[+] Profile '$PROFILE' is now the default (persistent)."
	echo "    All future commands without --profile will use this profile."
	exit 0
fi

# Skip main execution when sourced for testing (tests set CFTUNNEL_SKIP_MAIN=1)
[[ "${CFTUNNEL_SKIP_MAIN:-}" == "1" ]] && return 0

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
		--profile)
			PROFILE="${2:-}"
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
	op_add
	;;
remove)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		--profile)
			PROFILE="${2:-}"
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
		--profile)
			PROFILE="${2:-}"
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
		--profile)
			PROFILE="${2:-}"
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
		--profile)
			PROFILE="${2:-}"
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
		--profile)
			PROFILE="${2:-}"
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
cli-update)
	update_cloudflared
	;;
profile)
	op_profile "$@"
	;;
-h | --help | "") print_usage ;;
*)
	echo "unknown command: $cmd"
	print_usage
	exit 1
	;;
esac
