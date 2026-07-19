[[ -z "${_CFTUNNEL_CLOUDFLARED_LOADED:-}" ]] || return 0
_CFTUNNEL_CLOUDFLARED_LOADED=1

cloudflared() {
	local cert_path="$HOME_DIR/.cloudflared/cert.pem"
	if [[ -n "$ZONE" && -f "$HOME_DIR/.cloudflared/zones/$ZONE/cert.pem" ]]; then
		cert_path="$HOME_DIR/.cloudflared/zones/$ZONE/cert.pem"
	fi
	local tmpout rc
	tmpout=$(mktemp)
	"$CLOUDFLARED_BIN" --origincert "$cert_path" "$@" 2>"$tmpout"
	rc=$?
	grep -v -i '"outdated"' "$tmpout" >&2 || true
	rm -f "$tmpout"
	return $rc
}

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
	case "${cmd:-}" in
	"" | cli-update | list | zone)
		return 0
		;;
	esac

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
