#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cloudflare Tunnel Manager - Installer
# =============================================================================
# This script sets up everything needed to use the Cloudflare Tunnel Manager.
#
# Usage:
#   ./install.sh [OPTIONS]
#
# Options:
#   --skip-cloudflared    Skip cloudflared installation
#   --skip-auth           Skip Cloudflare authentication
#   --skip-symlink        Skip creating /usr/local/bin symlink
#   --force               Overwrite existing files
#   --help                Show this help message
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDFLARED_DIR="$HOME/.cloudflared"
SYSTEMD_TEMPLATE="/etc/systemd/system/cloudflared@.service"

# Flags
SKIP_CLOUDFLARED=false
SKIP_AUTH=false
SKIP_SYMLINK=false
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

need() {
	command -v "$1" >/dev/null 2>&1 || die "comando obrigatório não encontrado: $1"
}

# =============================================================================
# Parse Arguments
# =============================================================================

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--skip-cloudflared)
			SKIP_CLOUDFLARED=true
			shift
			;;
		--skip-auth)
			SKIP_AUTH=true
			shift
			;;
		--skip-symlink)
			SKIP_SYMLINK=true
			shift
			;;
		--force)
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
Cloudflare Tunnel Manager - Installer

Usage:
    ./install.sh [OPTIONS]

Options:
    --skip-cloudflared    Skip cloudflared installation
    --skip-auth           Skip Cloudflare authentication
    --skip-symlink        Skip creating /usr/local/bin symlink
    --force               Overwrite existing files
    --help, -h            Show this help message

Examples:
    ./install.sh                    # Full installation
    ./install.sh --skip-auth       # Skip authentication (already done)
    ./install.sh --skip-symlink   # Skip symlink (use PATH export instead)

HELP
}

# =============================================================================
# Pre-installation Checks
# =============================================================================

check_permissions() {
	log_info "Verificando permissões..."

	if [[ $EUID -eq 0 ]]; then
		log_warning "Executando como root. Isso pode não ser necessário para a maioria das operações."
	fi

	# Check if we can create systemd service (needs sudo for /etc/systemd)
	if [[ ! -w /etc/systemd/system ]] && [[ $EUID -ne 0 ]]; then
		log_warning "Sem permissão para criar serviços systemd."
		log_warning "Você precisará executar com sudo para criar o template systemd."
	fi
}

# =============================================================================
# Cloudflared Installation
# =============================================================================

install_cloudflared() {
	if [[ "$SKIP_CLOUDFLARED" == true ]]; then
		log_info "Pulando instalação do cloudflared (--skip-cloudflared)"
		return 0
	fi

	if command -v cloudflared >/dev/null 2>&1; then
		local version
		version=$(cloudflared --version 2>/dev/null | head -1 || echo "unknown")
		log_success "cloudflared já instalado: $version"
		return 0
	fi

	log_info "Instalando cloudflared..."

	local temp_dir
	temp_dir=$(mktemp -d)
	local arch
	arch=$(uname -m)

	case "$arch" in
	x86_64)
		arch="amd64"
		;;
	aarch64 | arm64)
		arch="arm64"
		;;
	*)
		die "Arquitetura não suportada: $arch"
		;;
	esac

	local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"

	log_info "Baixando cloudflared para linux-${arch}..."

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$download_url" -o "${temp_dir}/cloudflared" || die "Falha ao baixar cloudflared"
	elif command -v wget >/dev/null 2>&1; then
		wget -q "$download_url" -O "${temp_dir}/cloudflared" || die "Falha ao baixar cloudflared"
	else
		die "Nem curl nem wget estão disponíveis"
	fi

	chmod +x "${temp_dir}/cloudflared"

	# Try to install system-wide first
	if [[ -w /usr/local/bin ]] || [[ $EUID -eq 0 ]]; then
		sudo mv "${temp_dir}/cloudflared" /usr/local/bin/cloudflared ||
			mv "${temp_dir}/cloudflared" /usr/local/bin/cloudflared
		sudo chmod +x /usr/local/bin/cloudflared
		log_success "cloudflared instalado em /usr/local/bin/cloudflared"
	else
		# Install to user's local bin
		mkdir -p "$HOME/.local/bin"
		mv "${temp_dir}/cloudflared" "$HOME/.local/bin/cloudflared"
		chmod +x "$HOME/.local/bin/cloudflared"
		log_success "cloudflared instalado em $HOME/.local/bin/cloudflared"
		log_warning "Adicione $HOME/.local/bin ao seu PATH se ainda não estiver"
	fi

	rm -rf "$temp_dir"

	# Ensure ~/.local/bin is in PATH for verification
	export PATH="$HOME/.local/bin:$PATH"

	# Verify installation
	cloudflared --version | head -1 || die "Falha ao verificar instalação"
	log_success "cloudflared instalado com sucesso!"
}

# =============================================================================
# Cloudflare Authentication
# =============================================================================

authenticate_cloudflared() {
	if [[ "$SKIP_AUTH" == true ]]; then
		log_info "Pulando autenticação (--skip-auth)"
		return 0
	fi

	if [[ -f "$CLOUDFLARED_DIR/cert.pem" ]]; then
		log_success "Cloudflare já autenticado (cert.pem encontrado)"
		return 0
	fi

	log_info "Iniciando autenticação com Cloudflare..."
	log_info "Um navegador será aberto para você fazer login."
	log_info "Após o login, esta janela will mostrar a confirmação."
	echo

	if command -v cloudflared >/dev/null 2>&1; then
		cloudflared tunnel login || die "Falha na autenticação. Por favor, tente novamente."
		log_success "Autenticação concluída!"
	else
		die "cloudflared não está instalado. Execute ./install.sh primeiro ou use --skip-cloudflared"
	fi
}

# =============================================================================
# Systemd Template
# =============================================================================

create_systemd_template() {
	log_info "Verificando template systemd..."

	if [[ -f "$SYSTEMD_TEMPLATE" ]] && [[ "$FORCE" == false ]]; then
		log_success "Template systemd já existe: $SYSTEMD_TEMPLATE"
		return 0
	fi

	# Detect user
	local run_user="${SUDO_USER:-$USER}"
	local user_home
	user_home="$(getent passwd "$run_user" | cut -d: -f6 2>/dev/null || echo "$HOME")"

	log_info "Criando template systemd em $SYSTEMD_TEMPLATE..."

	if [[ $EUID -ne 0 ]]; then
		log_warning "Criando template systemd requer permissões sudo..."
		sudo tee "$SYSTEMD_TEMPLATE" >/dev/null <<TEMPLATE || die "Falha ao criar template systemd"
[Unit]
Description=Cloudflare Tunnel (%i)
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${user_home}
ExecStart=/usr/local/bin/cloudflared tunnel --config ${user_home}/.cloudflared/%i.yml run
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

# Reduce logging verbosity
Environment="CLOUDFLARED_LOGLEVEL=info"

[Install]
WantedBy=multi-user.target
TEMPLATE
	else
		tee "$SYSTEMD_TEMPLATE" >/dev/null <<TEMPLATE || die "Falha ao criar template systemd"
[Unit]
Description=Cloudflare Tunnel (%i)
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${user_home}
ExecStart=/usr/local/bin/cloudflared tunnel --config ${user_home}/.cloudflared/%i.yml run
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

# Reduce logging verbosity
Environment="CLOUDFLARED_LOGLEVEL=info"

[Install]
WantedBy=multi-user.target
TEMPLATE
	fi

	sudo systemctl daemon-reload
	log_success "Template systemd criado: $SYSTEMD_TEMPLATE"
}

# =============================================================================
# Cloudflared Directory
# =============================================================================

setup_cloudflared_dir() {
	log_info "Verificando diretório ~/.cloudflared..."

	if [[ ! -d "$CLOUDFLARED_DIR" ]]; then
		mkdir -p "$CLOUDFLARED_DIR"
		log_success "Diretório criado: $CLOUDFLARED_DIR"
	else
		log_success "Diretório já existe: $CLOUDFLARED_DIR"
	fi
}

# =============================================================================
# Make run.sh Executable
# =============================================================================

make_executable() {
	log_info "Configurando run.sh..."

	if [[ ! -f "$SCRIPT_DIR/run.sh" ]]; then
		die "run.sh não encontrado em $SCRIPT_DIR"
	fi

	chmod +x "$SCRIPT_DIR/run.sh"
	log_success "run.sh é agora executável"
}

# =============================================================================
# Create Symlink
# =============================================================================

create_symlink() {
	if [[ "$SKIP_SYMLINK" == true ]]; then
		log_info "Pulando criação de symlink (--skip-symlink)"
		return 0
	fi

	local symlink_path="/usr/local/bin/cftunnel"

	log_info "Criando symlink em $symlink_path..."

	# Check if already exists
	if [[ -L "$symlink_path" ]] || [[ -f "$symlink_path" ]]; then
		if [[ "$FORCE" == true ]]; then
			sudo rm -f "$symlink_path"
		else
			log_success "Symlink já existe: $symlink_path"
			return 0
		fi
	fi

	# Create symlink
	if [[ $EUID -eq 0 ]]; then
		ln -sf "$SCRIPT_DIR/run.sh" "$symlink_path" || die "Falha ao criar symlink"
	else
		sudo ln -sf "$SCRIPT_DIR/run.sh" "$symlink_path" || die "Falha ao criar symlink (precisa de sudo)"
	fi

	log_success "Symlink criado: $symlink_path -> $SCRIPT_DIR/run.sh"
}

# =============================================================================
# Reload Systemd
# =============================================================================

reload_systemd() {
	log_info "Recarregando systemd..."

	if [[ $EUID -eq 0 ]]; then
		systemctl daemon-reload
	else
		sudo systemctl daemon-reload
	fi

	log_success "systemd recarregado"
}

# =============================================================================
# Final Summary
# =============================================================================

show_summary() {
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo -e "                    ${GREEN}INSTALAÇÃO CONCLUÍDA!${NC}"
	echo "════════════════════════════════════════════════════════════════"
	echo
	echo "Próximos passos:"
	echo
	echo "  1. Criar seu primeiro túnel:"
	echo
	if [[ -L "/usr/local/bin/cftunnel" ]]; then
		echo "     cftunnel add --hostname api.seudominio.com --type http --service http://localhost:3000"
	else
		echo "     cd $SCRIPT_DIR"
		echo "     ./run.sh add --hostname api.seudominio.com --type http --service http://localhost:3000"
	fi
	echo
	echo "  2. Para túneis TCP/UDP (Redis, PostgreSQL, etc.):"
	echo
	echo "     # No servidor:"
	echo "     cftunnel add --hostname redis.seudominio.com --type tcp --service tcp://localhost:6379"
	echo
	echo "     # No cliente (para acessar):"
	echo "     cloudflared access tcp --hostname redis.seudominio.com --url localhost:6379"
	echo
	echo "  3. Ver todos os túneis:"
	echo
	echo "     cftunnel list"
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo
	echo -e "${BLUE}Documentação:${NC} $SCRIPT_DIR/README.md"
	echo -e "${BLUE}Changelog:${NC} $SCRIPT_DIR/CHANGELOG.md"
	echo
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo -e "       ${BLUE}Cloudflare Tunnel Manager - Instalador${NC}"
	echo "════════════════════════════════════════════════════════════════"
	echo

	parse_args "$@"
	check_permissions

	echo
	echo "Opções seleccionadas:"
	echo "  Skip cloudflared: $SKIP_CLOUDFLARED"
	echo "  Skip auth:        $SKIP_AUTH"
	echo "  Skip symlink:     $SKIP_SYMLINK"
	echo "  Force:            $FORCE"
	echo

	# Installation steps
	install_cloudflared
	setup_cloudflared_dir
	create_systemd_template
	make_executable
	create_symlink
	reload_systemd
	authenticate_cloudflared

	show_summary
}

main "$@"
