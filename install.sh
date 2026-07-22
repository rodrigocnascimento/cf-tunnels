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
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
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
	log_info "Checking permissions..."

	if [[ $EUID -eq 0 ]]; then
		log_warning "Running as root. This may not be necessary for most operations."
	fi

	# Check if we can create systemd service (needs sudo for /etc/systemd)
	if [[ ! -w /etc/systemd/system ]] && [[ $EUID -ne 0 ]]; then
		log_warning "No permission to create systemd services."
		log_warning "You will need to run with sudo to create the systemd template."
	fi
}

# =============================================================================
# Cloudflared Installation
# =============================================================================

install_cloudflared() {
	if [[ "$SKIP_CLOUDFLARED" == true ]]; then
		log_info "Skipping cloudflared installation (--skip-cloudflared)"
		return 0
	fi

	if command -v cloudflared >/dev/null 2>&1; then
		local version
		version=$(cloudflared --version 2>/dev/null | head -1 || echo "unknown")
		log_success "cloudflared already installed: $version"
		return 0
	fi

	log_info "Installing cloudflared..."

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
		die "Unsupported architecture: $arch"
		;;
	esac

	local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"

	# Determine final location
	local bin_dir="$HOME/.local/bin"
	local final_bin="$bin_dir/cloudflared"
	local system_bin="/usr/local/bin/cloudflared"

	log_info "Downloading cloudflared for linux-${arch}..."

	if command -v curl >/dev/null 2>&1; then
		mkdir -p "$bin_dir"
		local attempt=0
		while [ $attempt -lt 5 ]; do
			attempt=$((attempt + 1))
			curl -fSL --http1.1 --retry 3 --retry-delay 10 "$download_url" -o "$final_bin" && break
			log_warning "Attempt $attempt/5 failed. Retrying in 10s..."
			sleep 10
		done
		if [ $attempt -ge 5 ] && [ ! -f "$final_bin" ]; then
			die "Failed to download cloudflared after 5 attempts"
		fi
	elif command -v wget >/dev/null 2>&1; then
		mkdir -p "$bin_dir"
		wget -q "$download_url" -O "$final_bin" || die "Failed to download cloudflared"
	else
		die "Neither curl nor wget is available"
	fi

	chmod +x "$final_bin"

	# Attempt system-wide install if writable
	if [[ -w /usr/local/bin ]] || [[ $EUID -eq 0 ]]; then
		sudo mv "$final_bin" "$system_bin" || mv "$final_bin" "$system_bin"
		sudo chmod +x "$system_bin"
		log_success "cloudflared installed at $system_bin"
	else
		log_success "cloudflared installed at $final_bin"
		log_warning "Add $bin_dir to your PATH if not already present"
	fi

	# Ensure ~/.local/bin is in PATH for verification
	export PATH="$HOME/.local/bin:$PATH"

	# Verify installation
	cloudflared --version | head -1 || die "Failed to verify installation"
	log_success "cloudflared installed successfully!"
}

# =============================================================================
# Cloudflare Authentication
# =============================================================================

authenticate_cloudflared() {
	if [[ "$SKIP_AUTH" == true ]]; then
		log_info "Skipping authentication (--skip-auth)"
		return 0
	fi

	if [[ -f "$CLOUDFLARED_DIR/cert.pem" ]]; then
		log_success "Cloudflare already authenticated (cert.pem found)"
		return 0
	fi

	log_info "Starting Cloudflare authentication..."
	log_info "A browser will open for you to log in."
	log_info "After logging in, this window will show the confirmation."
	echo

	if command -v cloudflared >/dev/null 2>&1; then
		cloudflared tunnel login || die "Authentication failed. Please try again."
		log_success "Authentication complete!"
	else
		die "cloudflared is not installed. Run ./install.sh first or use --skip-cloudflared"
	fi
}

# =============================================================================
# Systemd Template
# =============================================================================

create_systemd_template() {
	log_info "Checking systemd template..."

	if [[ -f "$SYSTEMD_TEMPLATE" ]] && [[ "$FORCE" == false ]]; then
		log_success "Systemd template already exists: $SYSTEMD_TEMPLATE"
		return 0
	fi

	# Detect user
	local run_user="${SUDO_USER:-$USER}"
	local user_home
	user_home="$(getent passwd "$run_user" | cut -d: -f6 2>/dev/null || echo "$HOME")"

	log_info "Creating systemd template at $SYSTEMD_TEMPLATE..."

	if [[ $EUID -ne 0 ]]; then
		log_warning "Creating systemd template requires sudo permissions..."
		sudo tee "$SYSTEMD_TEMPLATE" >/dev/null <<TEMPLATE || die "Failed to create systemd template"
[Unit]
Description=Cloudflare Tunnel (%i)
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=5

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${user_home}
# Support both old flat structure and new zone structure.
# Zoned tunnels use underscore: cloudflared@<zone-slug>_<tunnel>.service
ExecStart=/bin/sh -c '\
  NAME=%i; \
  if echo "\$NAME" | grep -q "_"; then \
    ZONE=\$(echo "\$NAME" | sed "s/_[^_]*\$//"); \
    TUNNEL=\$(echo "\$NAME" | sed "s/^[^_]*_//"); \
    CONFIG="${user_home}/.cloudflared/zones/\$ZONE/\$TUNNEL.yml"; \
    if [ ! -f "\$CONFIG" ]; then CONFIG="${user_home}/.cloudflared/\$NAME.yml"; fi; \
  else \
    CONFIG="${user_home}/.cloudflared/\$NAME.yml"; \
  fi; \
  exec /usr/local/bin/cloudflared tunnel --config "\$CONFIG" run'
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

# Reduce logging verbosity
Environment="CLOUDFLARED_LOGLEVEL=info"

# Security: systemd sandbox
NoNewPrivileges=true
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictRealtime=true
MemoryMax=256M
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
TEMPLATE
	else
		tee "$SYSTEMD_TEMPLATE" >/dev/null <<TEMPLATE || die "Failed to create systemd template"
[Unit]
Description=Cloudflare Tunnel (%i)
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=5

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${user_home}

# Support both old flat structure and new zone structure.
# Zoned tunnels use underscore: cloudflared@<zone-slug>_<tunnel>.service
ExecStart=/bin/sh -c '\
  NAME=%i; \
  if echo "\$NAME" | grep -q "_"; then \
    ZONE=\$(echo "\$NAME" | sed "s/_[^_]*\$//"); \
    TUNNEL=\$(echo "\$NAME" | sed "s/^[^_]*_//"); \
    CONFIG="${user_home}/.cloudflared/zones/\$ZONE/\$TUNNEL.yml"; \
    if [ ! -f "\$CONFIG" ]; then CONFIG="${user_home}/.cloudflared/\$NAME.yml"; fi; \
  else \
    CONFIG="${user_home}/.cloudflared/\$NAME.yml"; \
  fi; \
  exec /usr/local/bin/cloudflared tunnel --config "\$CONFIG" run'
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

# Reduce logging verbosity
Environment="CLOUDFLARED_LOGLEVEL=info"

# Security: systemd sandbox
NoNewPrivileges=true
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictRealtime=true
MemoryMax=256M
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
TEMPLATE
	fi

	sudo systemctl daemon-reload
	log_success "Systemd template created: $SYSTEMD_TEMPLATE"
}

# =============================================================================
# Cloudflared Directory
# =============================================================================

setup_cloudflared_dir() {
	log_info "Checking ~/.cloudflared directory..."

	if [[ ! -d "$CLOUDFLARED_DIR" ]]; then
		mkdir -p "$CLOUDFLARED_DIR"
		log_success "Directory created: $CLOUDFLARED_DIR"
	else
		log_success "Directory already exists: $CLOUDFLARED_DIR"
	fi
}

# =============================================================================
# Make run.sh Executable
# =============================================================================

make_executable() {
	log_info "Configuring run.sh..."

	if [[ ! -f "$SCRIPT_DIR/run.sh" ]]; then
		die "run.sh not found in $SCRIPT_DIR"
	fi

	chmod +x "$SCRIPT_DIR/run.sh"
	log_success "run.sh is now executable"
}

# =============================================================================
# Create Symlink
# =============================================================================

create_symlink() {
	if [[ "$SKIP_SYMLINK" == true ]]; then
		log_info "Skipping symlink creation (--skip-symlink)"
		return 0
	fi

	local symlink_path="/usr/local/bin/cftunnel"

	log_info "Creating symlink at $symlink_path..."

	# Check if already exists
	if [[ -L "$symlink_path" ]] || [[ -f "$symlink_path" ]]; then
		if [[ "$FORCE" == true ]]; then
			sudo rm -f "$symlink_path"
		else
			log_success "Symlink already exists: $symlink_path"
			return 0
		fi
	fi

	# Create symlink
	if [[ $EUID -eq 0 ]]; then
		ln -sf "$SCRIPT_DIR/run.sh" "$symlink_path" || die "Failed to create symlink"
	else
		sudo ln -sf "$SCRIPT_DIR/run.sh" "$symlink_path" || die "Failed to create symlink (needs sudo)"
	fi

	log_success "Symlink created: $symlink_path -> $SCRIPT_DIR/run.sh"
}

# =============================================================================
# Reload Systemd
# =============================================================================

reload_systemd() {
	log_info "Reloading systemd..."

	if [[ $EUID -eq 0 ]]; then
		systemctl daemon-reload
	else
		sudo systemctl daemon-reload
	fi

	log_success "systemd reloaded"
}

# =============================================================================
# Final Summary
# =============================================================================

show_summary() {
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo -e "                    ${GREEN}INSTALLATION COMPLETE!${NC}"
	echo "════════════════════════════════════════════════════════════════"
	echo
	echo "Next steps:"
	echo
	echo "  1. Create your first tunnel:"
	echo
	echo "     cftunnel add --hostname api.yourdomain.com --type http --service http://localhost:3000"
	echo
	echo "  2. For TCP/UDP tunnels (Redis, PostgreSQL, etc.):"
	echo
	echo "     # On the server:"
	echo "     cftunnel add --hostname redis.yourdomain.com --type tcp --service tcp://localhost:6379"
	echo
	echo "     # On the client (to access):"
	echo "     cloudflared access tcp --hostname redis.yourdomain.com --url localhost:6379"
	echo
	echo "  3. List all tunnels:"
	echo
	echo "     cftunnel list"
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo
	echo -e "${BLUE}Documentation:${NC} https://github.com/rodrigocnascimento/cf-tunnels/wiki"
	echo -e "${BLUE}Changelog:${NC} $SCRIPT_DIR/CHANGELOG.md"
	echo
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo -e "       ${BLUE}Cloudflare Tunnel Manager - Installer${NC}"
	echo "════════════════════════════════════════════════════════════════"
	echo

	parse_args "$@"
	check_permissions

	echo
	echo "Selected options:"
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
