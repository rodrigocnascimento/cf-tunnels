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

	local prompt="${1:-Continuar?}"
	read -p "$prompt [y/N] " -n 1 -r
	echo
	[[ $REPLY =~ ^[Yy]$ ]]
}

# =============================================================================
# Remove Symlink
# =============================================================================

remove_symlink() {
	if [[ ! -L "$SYMLINK_PATH" ]] && [[ ! -f "$SYMLINK_PATH" ]]; then
		log_info "Symlink não encontrado (já removido ou nunca criado): $SYMLINK_PATH"
		return 0
	fi

	log_info "Removendo symlink: $SYMLINK_PATH"

	if [[ $EUID -eq 0 ]]; then
		rm -f "$SYMLINK_PATH"
	else
		sudo rm -f "$SYMLINK_PATH"
	fi

	log_success "Symlink removido"
}

# =============================================================================
# Remove Systemd Template
# =============================================================================

remove_systemd_template() {
	if [[ ! -f "$SYSTEMD_TEMPLATE" ]]; then
		log_info "Template systemd não encontrado (já removido): $SYSTEMD_TEMPLATE"
		return 0
	fi

	log_info "Removendo template systemd: $SYSTEMD_TEMPLATE"

	if confirm "Isso também parará todos os túneis em execução. Continuar?"; then
		if [[ $EUID -eq 0 ]]; then
			rm -f "$SYSTEMD_TEMPLATE"
			systemctl daemon-reload
		else
			sudo rm -f "$SYSTEMD_TEMPLATE"
			sudo systemctl daemon-reload
		fi
		log_success "Template systemd removido"
	else
		log_warning "Mantendo template systemd"
	fi
}

# =============================================================================
# Remove cloudflared
# =============================================================================

remove_cloudflared() {
	if ! command -v cloudflared >/dev/null 2>&1; then
		log_info "cloudflared não encontrado (já removido ou não instalado)"
		return 0
	fi

	log_info "Removendo cloudflared..."

	if [[ $EUID -eq 0 ]]; then
		rm -f /usr/local/bin/cloudflared
		rm -f /usr/bin/cloudflared
	else
		sudo rm -f /usr/local/bin/cloudflared
		sudo rm -f /usr/bin/cloudflared
	fi

	# Also check in ~/.local/bin
	rm -f "$HOME/.local/bin/cloudflared"

	log_success "cloudflared removido"
}

# =============================================================================
# Remove Authentication
# =============================================================================

remove_auth() {
	if [[ ! -f "$CLOUDFLARED_DIR/cert.pem" ]]; then
		log_info "Certificado de autenticação não encontrado: $CLOUDFLARED_DIR/cert.pem"
		return 0
	fi

	log_info "Removendo autenticação Cloudflare..."

	if confirm "Isso removerá: $CLOUDFLARED_DIR/cert.pem. Você precisará fazer login novamente. Continuar?"; then
		rm -f "$CLOUDFLARED_DIR/cert.pem"
		log_success "Autenticação removida"
	else
		log_warning "Mantendo autenticação"
	fi
}

# =============================================================================
# Remove Configurations
# =============================================================================

remove_configs() {
	if [[ ! -d "$CLOUDFLARED_DIR" ]]; then
		log_info "Diretório de configurações não encontrado: $CLOUDFLARED_DIR"
		return 0
	fi

	log_info "Removendo configurações: $CLOUDFLARED_DIR"

	if confirm "Isso removerá TODOS os túneis e configurações. ESSA AÇÃO NÃO PODE SER DESFEITA. Continuar?"; then
		rm -rf "$CLOUDFLARED_DIR"
		log_success "Configurações removidas"
	else
		log_warning "Mantendo configurações"
	fi
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo -e "       ${YELLOW}Cloudflare Tunnel Manager - Desinstalador${NC}"
	echo "════════════════════════════════════════════════════════════════"
	echo

	parse_args "$@"

	echo "Opções seleccionadas:"
	echo "  Remove cloudflared: $REMOVE_CLOUDFLARED"
	echo "  Remove auth:        $REMOVE_AUTH"
	echo "  Remove configs:     $REMOVE_CONFIGS"
	echo "  Force:             $FORCE"
	echo

	if [[ "$REMOVE_CLOUDFLARED" == false ]] &&
		[[ "$REMOVE_AUTH" == false ]] &&
		[[ "$REMOVE_CONFIGS" == false ]]; then
		log_info "Removendo apenas o gerenciador (manter cloudflared e configurações)"
	fi

	# Removal steps
	remove_symlink
	remove_systemd_template

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
	echo -e "              ${GREEN}DESINSTALAÇÃO CONCLUÍDA${NC}"
	echo "════════════════════════════════════════════════════════════════"
	echo
	log_info "O diretório $SCRIPT_DIR ainda existe."
	log_info "Você pode removê-lo manualmente com: rm -rf $SCRIPT_DIR"
	echo
}

main "$@"
