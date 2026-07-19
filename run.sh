#!/usr/bin/env bash
set -euo pipefail

# cftunnel — per-subdomain tunnel manager (one YAML per tunnel)
# Source code lives in lib/*.sh — this file is the entry-point dispatcher.

# ===== Config ================================================================
RUN_USER="${RUN_USER:-$USER}"
HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")"
CLOUDFLARED_BIN="$(command -v cloudflared || true)"
ZONE=""
BASE_DIR="$HOME_DIR/.cloudflared"
SYSTEMD_TPL="/etc/systemd/system/cloudflared@.service"
DEFAULT_ZONE_FILE="$HOME_DIR/.cloudflared/.default_zone"

# ===== Source modules (dependency order) =====================================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/dns.sh"
source "$SCRIPT_DIR/lib/cloudflared.sh"
source "$SCRIPT_DIR/lib/zone.sh"
source "$SCRIPT_DIR/lib/tunnel.sh"

# ===== Help text =============================================================
print_usage() {
	cat <<USAGE
Usage:
  $0 [global options] <command> [command options]

Global options:
  --zone NAME     Operate within a specific zone (can appear anywhere)
  --version       Show the cftunnel version and exit

Commands:
  add           --hostname FQDN --type (ssh|http|tcp) --service URL [--name NAME] [--no-dns]
  remove        --name NAME
  start|stop|status|logs   --name NAME
  list          List local hostname routes in the active zone (or all zones if none)
  version       Show the cftunnel version and exit
  cli-update    Update the cloudflared dependency to the latest version
  zone          Manage persistent default zone and authentication

Zone commands:
  zone use <name>     Set a zone as the default (persistent)
  zone current        Show the current default zone
  zone unset          Clear the default zone
  zone login          Authenticate and save cert.pem to the active zone

  You can also use: cftunnel --zone <name> --persist

Examples:
  cftunnel --zone homelaberson.space start --name login
  cftunnel start --name api --zone testes.lat
  cftunnel --zone homelaberson.space list
  cftunnel add --hostname ssh.example.com --type ssh --service ssh://localhost:22 --name ssh-config --zone homelaberson.space
  cftunnel --version
  cftunnel cli-update

  # Zone workflow
  cftunnel zone use homelaberson.space
  cftunnel zone login              # saves cert to zones/homelaberson.space/
  cftunnel list                    # will use homelaberson.space by default
  cftunnel --zone testes.lat list  # temporary override
USAGE
}

# ===== Argument parser =======================================================

# First pass: extract global options from anywhere in the command line.
ARGS=("$@")
PERSIST_ZONE=false
current_default=""

declare -a CLEAN_ARGS=()
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    arg="${ARGS[$i]}"
    case "$arg" in
        --zone)
            if [[ $((i+1)) -lt ${#ARGS[@]} ]]; then
                ZONE="${ARGS[$((i+1))]}"
                ((i+=2)) || true
            else
                die "--zone requires a value"
            fi
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

set -- "${CLEAN_ARGS[@]}"

cmd="${1:-}"
shift || true

case "$cmd" in
version | --version)
	[[ $# -eq 0 ]] || die "'$cmd' does not accept arguments"
	print_cftunnel_version
	exit 0
	;;
esac

NAME=""
TUNNEL_HOSTNAME=""
TYPE=""
SERVICE=""
NO_DNS=false

if [[ -n "$ZONE" ]]; then
	ZONE="$(validate_zone_name "$ZONE")"
fi

# Load default/persistent zone
if [[ -z "$ZONE" ]]; then
	DEFAULT="$(load_default_zone)"
	if [[ -n "$DEFAULT" ]]; then
		ZONE="$DEFAULT"
	fi
fi

if [[ "$cmd" != "zone" ]]; then
	if [[ -n "$ZONE" && "$PERSIST_ZONE" == true ]]; then
		current_default="$(load_default_zone)"
		if [[ "$ZONE" != "$current_default" ]]; then
			save_default_zone "$ZONE"
			echo "[+] Zone '$ZONE' is now the default (persistent)."
		fi
	fi

	if [[ -n "$ZONE" && "$PERSIST_ZONE" != true ]]; then
		current_default="$(load_default_zone)"
		if [[ -n "$current_default" && "$ZONE" != "$current_default" ]]; then
			echo
			echo ">>> You are using zone '$ZONE', but your current default is '$current_default'."
			read -p "Do you want to make '$ZONE' your new default zone? [y/N] " -n 1 -r || true
			echo
			if [[ "$REPLY" =~ ^[Yy]$ ]]; then
				save_default_zone "$ZONE"
				echo "[+] Default zone changed to '$ZONE'."
			fi
		fi
	fi
fi

# Hard Gate: Version check for cloudflared
check_cloudflared_version

if [[ -z "${cmd:-}" && "$PERSIST_ZONE" == true && -n "$ZONE" ]]; then
	echo "[+] Zone '$ZONE' is now the default (persistent)."
	echo "    All future commands without --zone will use this zone."
	exit 0
fi

[[ "${CFTUNNEL_SKIP_MAIN:-}" == "1" ]] && return 0

case "${cmd:-}" in
add)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--hostname) TUNNEL_HOSTNAME="${2:-}"; shift 2 ;;
		--type)     TYPE="${2:-}"; shift 2 ;;
		--service)  SERVICE="${2:-}"; shift 2 ;;
		--name) NAME="${2:-}"; shift 2 ;;
		--no-dns)   NO_DNS=true; shift ;;
		-h | --help) print_usage; exit 0 ;;
		*) echo "unknown flag: $1"; print_usage; exit 1 ;;
		esac
	done
	op_add
	;;
remove)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name) NAME="${2:-}"; shift 2 ;;
		-h | --help) print_usage; exit 0 ;;
		*) echo "unknown flag: $1"; print_usage; exit 1 ;;
		esac
	done
	op_remove
	;;
start)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name) NAME="${2:-}"; shift 2 ;;
		*) print_usage; exit 1 ;;
		esac
	done
	op_start
	;;
stop)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name) NAME="${2:-}"; shift 2 ;;
		*) print_usage; exit 1 ;;
		esac
	done
	op_stop
	;;
status)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name) NAME="${2:-}"; shift 2 ;;
		*) print_usage; exit 1 ;;
		esac
	done
	op_status
	;;
logs)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name) NAME="${2:-}"; shift 2 ;;
		*) print_usage; exit 1 ;;
		esac
	done
	op_logs
	;;
list) op_list ;;
cli-update) update_cloudflared ;;
zone) op_zone "$@" ;;
-h | --help | "") print_usage ;;
*)
	echo "unknown command: $cmd"
	print_usage
	exit 1
	;;
esac
