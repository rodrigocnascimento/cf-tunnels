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
source "$SCRIPT_DIR/lib/contracts.sh"
source "$SCRIPT_DIR/lib/health.sh"

# ===== Help text =============================================================
print_usage() {
	cat <<USAGE
Usage:
  $0 [global options] <command> [command options]

Global options:
  --zone NAME     Operate within a specific zone (can appear anywhere)
  --all-zones     Read local inventory across every registered zone (list/health only)
  --output FORMAT  Output format: text (default) or json
  --version       Show the cftunnel version and exit

Commands:
  add           --hostname FQDN --type (ssh|http|tcp) --service URL [--name NAME] [--no-dns]
  remove        --name NAME
  start|stop|status|logs   --name NAME
  list          List local hostname routes in the active zone (or all zones if none)
  health        Check local tunnel configuration, systemd, and DNS state
  capabilities  Show supported machine-readable contract operations
  privilege     Check cached sudo availability for future TUI mutations
  tui-dev       Launch the checkout's read-only Ink/Bun TUI
  tui           Reserved for the future installed production TUI
  version       Show the cftunnel version and exit
  cli-update    Update the cloudflared dependency to the latest version
  zone          Manage persistent default zone and authentication

Zone commands:
	zone list             List registered local zones and their contract state
  zone use <name>     Register a zone and set it as the default (persistent)
  zone current        Show the current default zone
  zone unset          Clear the default zone
  zone login          Authenticate and bind a credential to the active zone

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

tui_dev_preflight() {
	command -v bun >/dev/null 2>&1 || die "TUI development requires Bun 1.3.0 or newer; install Bun and run 'bun install' in packages/tui"
	local bun_version
	bun_version="$(bun --version 2>/dev/null || true)"
	if [[ -z "$bun_version" || "$(printf '%s\n%s\n' "1.3.0" "$bun_version" | sort -V | head -n1)" != "1.3.0" ]]; then
		die "TUI development requires Bun 1.3.0 or newer (found '${bun_version:-unknown}')"
	fi

	local tui_dir="$SCRIPT_DIR/packages/tui" tui_entry="$SCRIPT_DIR/packages/tui/src/index.tsx"
	[[ -f "$tui_entry" && -f "$tui_dir/package.json" && -f "$tui_dir/bun.lock" ]] || die "TUI source package is incomplete; use a complete source checkout"
	[[ -f "$tui_dir/node_modules/ink/package.json" && -f "$tui_dir/node_modules/react/package.json" ]] || die "TUI dependencies are missing; run 'cd $tui_dir && bun install'"

	local cli_version tui_version
	cli_version="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
	tui_version="$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$tui_dir/package.json" | head -n1)"
	[[ -n "$cli_version" && "$cli_version" == "$tui_version" ]] || die "TUI package version '${tui_version:-unknown}' does not match cftunnel '$cli_version'; update or reinstall the checkout"
	"$SCRIPT_DIR/run.sh" capabilities --output json >/dev/null 2>&1 || die "this cftunnel checkout does not provide a usable JSON contract for the TUI"

	if [[ "${CFTUNNEL_TUI_TEST_MODE:-}" != "1" ]]; then
		[[ -t 0 && -t 1 ]] || die "TUI development requires an interactive terminal; run 'cftunnel tui-dev' directly in a terminal"
		[[ "${TERM:-}" != "dumb" ]] || die "TUI development requires a terminal with ANSI screen support (TERM must not be dumb)"
		local columns
		columns="$(tput cols 2>/dev/null || printf 0)"
		if [[ "$columns" =~ ^[0-9]+$ && "$columns" -gt 0 && "$columns" -lt 60 ]]; then
			die "TUI development needs at least 60 terminal columns (found $columns)"
		fi
	fi
}

# ===== Argument parser =======================================================

# First pass: extract global options from anywhere in the command line.
ARGS=("$@")
PERSIST_ZONE=false
ALL_ZONES=false
OUTPUT_FORMAT="text"
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
		--all-zones)
			ALL_ZONES=true
			((i++)) || true
			;;
        --output)
            if [[ $((i+1)) -lt ${#ARGS[@]} ]]; then
                OUTPUT_FORMAT="${ARGS[$((i+1))]}"
                ((i+=2)) || true
            else
                die "--output requires a value"
            fi
            ;;
        *)
            CLEAN_ARGS+=("$arg")
            ((i++)) || true
            ;;
    esac
done

set -- "${CLEAN_ARGS[@]}"

case "$OUTPUT_FORMAT" in
text|json) ;;
*) die "--output must be 'text' or 'json'" ;;
esac

cmd="${1:-}"
shift || true

case "$cmd" in
version | --version)
	[[ $# -eq 0 ]] || die "'$cmd' does not accept arguments"
	print_cftunnel_version
	exit 0
	;;
	esac

case "$cmd" in
capabilities)
	[[ $# -eq 0 ]] || die "'capabilities' does not accept arguments"
	op_capabilities
	exit 0
	;;
privilege)
	[[ "${1:-}" == "check" && $# -eq 1 ]] || die "Usage: cftunnel privilege check --output json"
	op_privilege_check
	exit 0
	;;
tui-dev)
	[[ $# -eq 0 ]] || die "'tui-dev' does not accept arguments"
	tui_dev_preflight
	tui_entry="$SCRIPT_DIR/packages/tui/src/index.tsx"
	[[ -f "$tui_entry" ]] || die "TUI development entry point is missing: $tui_entry"
	CFTUNNEL_BIN="$SCRIPT_DIR/run.sh" exec bun run "$tui_entry"
	;;
tui)
	[[ $# -eq 0 ]] || die "'tui' does not accept arguments"
	die "the production TUI is not packaged yet; use 'cftunnel tui-dev' from a source checkout"
	;;
esac

NAME=""
TUNNEL_HOSTNAME=""
TYPE=""
SERVICE=""
NO_DNS=false

parse_add_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--hostname | --type | --service | --name)
			[[ $# -ge 2 ]] || die "$1 requires a value"
			case "$1" in
			--hostname) TUNNEL_HOSTNAME="$2" ;;
			--type) TYPE="$2" ;;
			--service) SERVICE="$2" ;;
			--name) NAME="$2" ;;
			esac
			shift 2
			;;
		--no-dns) NO_DNS=true; shift ;;
		-h | --help) print_usage; exit 0 ;;
		*) echo "unknown flag: $1"; print_usage; exit 1 ;;
		esac
	done
}

if [[ -n "$ZONE" ]]; then
	ZONE="$(validate_zone_name "$ZONE")" || exit 1
fi

if [[ "$ALL_ZONES" == true && -n "$ZONE" ]]; then
	die "--all-zones cannot be combined with --zone"
fi
if [[ "$ALL_ZONES" == true && "$cmd" != list && "$cmd" != health ]]; then
	die "--all-zones is only supported by list and health"
fi

# Load default/persistent zone
if [[ -z "$ZONE" && "$ALL_ZONES" == false ]]; then
	DEFAULT="$(load_default_zone)" || exit 1
	if [[ -n "$DEFAULT" ]]; then
		ZONE="$DEFAULT"
	fi
fi

# Parse and validate add input before persistence prompts or any other
# external/privileged side effect.
if [[ "$cmd" == "add" ]]; then
	parse_add_args "$@"
	validate_add_input
fi

if [[ -n "$ZONE" && "$PERSIST_ZONE" == true ]]; then
	current_default="$(load_default_zone)" || exit 1
	ZONE="$(register_zone "$ZONE")" || exit 1
	if [[ "$ZONE" != "$current_default" ]]; then
		echo "[+] Zone '$ZONE' is now the default (persistent)."
	fi
fi

if [[ -z "${cmd:-}" && "$PERSIST_ZONE" == true && -n "$ZONE" ]]; then
	echo "[+] Zone '$ZONE' is now the default (persistent)."
	echo "    All future commands without --zone will use this zone."
	exit 0
fi

[[ "${CFTUNNEL_SKIP_MAIN:-}" == "1" ]] && return 0

case "${cmd:-}" in
add)
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
health)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name) NAME="${2:-}"; [[ -n "$NAME" ]] || die "--name requires a value"; shift 2 ;;
		-h | --help) print_usage; exit 0 ;;
		*) echo "unknown flag: $1"; print_usage; exit 1 ;;
		esac
	done
	json_enabled || die "health requires --output json"
	op_health
	;;
cli-update) update_cloudflared ;;
zone) op_zone "$@" ;;
-h | --help | "") print_usage ;;
*)
	echo "unknown command: $cmd"
	print_usage
	exit 1
	;;
esac
