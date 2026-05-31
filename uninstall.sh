#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cloudflare Tunnel Manager - Uninstaller
# =============================================================================
# This script removes the Cloudflare Tunnel Manager installation.
#
# WARNING: This will NOT remove:
#   - cloudflared binary
#   - Cloudflare authentication (cert.pem)
#   - Your tunnel configurations in ~/.cloudflared/
#
# Usage:
#   ./uninstall.sh [OPTIONS]
#
# Options:
#   --remove-cloudflared    Also remove cloudflared binary
#   --remove-auth          Also remove Cloudflare authentication
#   --remove-configs       Also remove tunnel configurations
#   --force                Skip confirmation
#   --help                 Show this help message
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDFLARED_DIR="$HOME/.cloudflared"
SYSTEMD_TEMPLATE="/etc/systemd/system/cloudflared@.service"
SYMLINK_PATH="/usr/local/bin/cftunnel"

# Flags
REMOVE_CLOUDFLARED=false
REMOVE_AUTH=false
REMOVE_CONFIGS=false
FORCE=false

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
	echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
	echo -e "${GREEN}[✓]${NC} $*"
}

log_warning() {
	echo -e "${YELLOW}[!]${NC} $*"
}

log_error() {
	echo -e "${RED}[✗]${NC} $*" >&2
}

die() {
	log_error "$*"
	exit 1
}

# =============================================================================
# Parse Arguments
# =============================================================================

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remove-cloudflared)
			REMOVE_CLOUDFLARED=true
			shift
			;;
		--remove-auth)
			REMOVE_AUTH=true
			shift
			;;
		--remove-configs)
			REMOVE_CONFIGS=true
			shift
			;;
		--force | -y)
			FORCE=true
			shift
			;;
		--help | -h)
			show_help
			exit 0
			;;
		*)
			log_error "Unknown option: $1"
			show_help
			exit 1
			;;
		esac
	done
}

show_help() {
	cat <<HELP
Cloudflare Tunnel Manager - Uninstaller

Usage:
    ./uninstall.sh [OPTIONS]

Options:
    --remove-cloudflared    Also remove cloudflared binary
    --remove-auth          Also remove Cloudflare authentication (cert.pem)
    --remove-configs       Also remove ~/.cloudflared/ configurations
    --force, -y            Skip confirmation prompts
    --help, -h             Show this help message

WARNING: This will NOT automatically remove cloudflared, authentication,
or tunnel configurations. Use the flags above to remove them.

Examples:
    ./uninstall.sh                     # Remove only the manager
    ./uninstall.sh --remove-cloudflared   # Also remove cloudflared
    ./uninstall.sh --remove-configs     # Also remove tunnel configs

HELP
}

# =============================================================================
# Confirmation
# =============================================================================

confirm() {
	if [[ "$FORCE" == true ]]; then
		return 0
	fi

	local prompt="${1:-Continue?}"
	read -p "$prompt [y/N] " -n 1 -r
	echo
	[[ $REPLY =~ ^[Yy]$ ]]
}

# =============================================================================
# Remove Symlink
# =============================================================================

remove_symlink() {
	if [[ ! -L "$SYMLINK_PATH" ]] && [[ ! -f "$SYMLINK_PATH" ]]; then
		log_info "Symlink not found (already removed or never created): $SYMLINK_PATH"
		return 0
	fi

	log_info "Removing symlink: $SYMLINK_PATH"

	if [[ $EUID -eq 0 ]]; then
		rm -f "$SYMLINK_PATH"
	else
		sudo rm -f "$SYMLINK_PATH"
	fi

	log_success "Symlink removed"
}

# =============================================================================
# Remove Systemd Template
# =============================================================================

remove_systemd_template() {
	if [[ ! -f "$SYSTEMD_TEMPLATE" ]]; then
		log_info "Systemd template not found (already removed): $SYSTEMD_TEMPLATE"
		return 0
	fi

	log_info "Removing systemd template: $SYSTEMD_TEMPLATE"

	if confirm "This will also stop all running tunnels. Continue?"; then
		if [[ $EUID -eq 0 ]]; then
			systemctl stop 'cloudflared@*' 2>/dev/null || true
			rm -f "$SYSTEMD_TEMPLATE"
			systemctl daemon-reload
		else
			sudo systemctl stop 'cloudflared@*' 2>/dev/null || true
			sudo rm -f "$SYSTEMD_TEMPLATE"
			sudo systemctl daemon-reload
		fi
		log_success "Systemd template removed"
	else
		log_warning "Keeping systemd template"
	fi
}

# =============================================================================
# Remove cloudflared
# =============================================================================

remove_cloudflared() {
	if ! command -v cloudflared >/dev/null 2>&1; then
		log_info "cloudflared not found (already removed or not installed)"
		return 0
	fi

	log_info "Removing cloudflared..."

	if [[ $EUID -eq 0 ]]; then
		rm -f /usr/local/bin/cloudflared
		rm -f /usr/bin/cloudflared
	else
		sudo rm -f /usr/local/bin/cloudflared
		sudo rm -f /usr/bin/cloudflared
	fi

	# Also check in ~/.local/bin
	rm -f "$HOME/.local/bin/cloudflared"

	log_success "cloudflared removed"
}

# =============================================================================
# Remove Authentication
# =============================================================================

remove_auth() {
	if [[ ! -f "$CLOUDFLARED_DIR/cert.pem" ]]; then
		log_info "Authentication certificate not found: $CLOUDFLARED_DIR/cert.pem"
		return 0
	fi

	log_info "Removing Cloudflare authentication..."

	if confirm "This will remove: $CLOUDFLARED_DIR/cert.pem. You will need to log in again. Continue?"; then
		rm -f "$CLOUDFLARED_DIR/cert.pem"
		log_success "Authentication removed"
	else
		log_warning "Keeping authentication"
	fi
}

# =============================================================================
# Remove Prompt Hook
# =============================================================================

remove_prompt_hook() {
	local marker_start="# >>> cftunnel installer <<<"
	local marker_end="# <<< cftunnel installer <<<"

	for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
		if [[ ! -f "$rc_file" ]]; then
			continue
		fi

		if grep -qF "$marker_start" "$rc_file" 2>/dev/null; then
			log_info "Removing prompt hook from $rc_file..."
			# Create a temp file without the block (markers + content between them)
			awk -v start="$marker_start" -v end="$marker_end" '
				BEGIN { in_block=0 }
				$0 == start { in_block=1; next }
				$0 == end   { in_block=0; next }
				!in_block  { print }
			' "$rc_file" >"${rc_file}.tmp" && mv "${rc_file}.tmp" "$rc_file"
			log_success "Prompt hook removed from $rc_file"
		fi
	done
}

# =============================================================================
# Remove Configurations
# =============================================================================

remove_configs() {
	if [[ ! -d "$CLOUDFLARED_DIR" ]]; then
		log_info "Config directory not found: $CLOUDFLARED_DIR"
		return 0
	fi

	log_info "Removing configurations: $CLOUDFLARED_DIR"

	if confirm "This will remove ALL tunnels and configurations. THIS ACTION CANNOT BE UNDONE. Continue?"; then
		rm -rf "$CLOUDFLARED_DIR"
		log_success "Configurations removed"
	else
		log_warning "Keeping configurations"
	fi
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo -e "       ${YELLOW}Cloudflare Tunnel Manager - Uninstaller${NC}"
	echo "════════════════════════════════════════════════════════════════"
	echo

	parse_args "$@"

	echo "Selected options:"
	echo "  Remove cloudflared: $REMOVE_CLOUDFLARED"
	echo "  Remove auth:        $REMOVE_AUTH"
	echo "  Remove configs:     $REMOVE_CONFIGS"
	echo "  Force:             $FORCE"
	echo

	if [[ "$REMOVE_CLOUDFLARED" == false ]] &&
		[[ "$REMOVE_AUTH" == false ]] &&
		[[ "$REMOVE_CONFIGS" == false ]]; then
		log_info "Removing only the manager (keeping cloudflared and configurations)"
	fi

	# Removal steps
	remove_symlink
	remove_systemd_template
	remove_prompt_hook

	if [[ "$REMOVE_CLOUDFLARED" == true ]]; then
		remove_cloudflared
	fi

	if [[ "$REMOVE_AUTH" == true ]]; then
		remove_auth
	fi

	if [[ "$REMOVE_CONFIGS" == true ]]; then
		remove_configs
	fi

	echo
	echo "════════════════════════════════════════════════════════════════"
	echo -e "              ${GREEN}UNINSTALL COMPLETE${NC}"
	echo "════════════════════════════════════════════════════════════════"
	echo
	log_info "The directory $SCRIPT_DIR still exists."
	log_info "You can remove it manually with: rm -rf $SCRIPT_DIR"
	echo
}

main "$@"
