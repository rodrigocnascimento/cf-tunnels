[[ -z "${_CFTUNNEL_ZONE_LOADED:-}" ]] || return 0
_CFTUNNEL_ZONE_LOADED=1

zone_base_dir() {
	if [[ -n "$ZONE" ]]; then
		echo "$HOME_DIR/.cloudflared/zones/${ZONE}"
	else
		echo "$HOME_DIR/.cloudflared"
	fi
}

load_default_zone() {
	local target_file="$HOME_DIR/.cloudflared/.default_zone"

	if [[ ! -f "$target_file" ]]; then
		return 0
	fi

	local raw
	raw="$(cat "$target_file" 2>/dev/null | tr -d '\n\r' | head -1)"

	if [[ -z "$raw" ]]; then
		rm -f "$target_file"
		return 0
	fi

	DEFAULT_ZONE_FILE="$target_file"

	echo "$raw"
}

save_default_zone() {
	local zone_name="$1"

	if [[ -z "$zone_name" ]]; then
		die "Invalid zone name: '$zone_name'"
	fi

	local target_file="$HOME_DIR/.cloudflared/.default_zone"

	mkdir -p "$(dirname "$target_file")"
	echo "$zone_name" > "$target_file"
	chmod 600 "$target_file"

	DEFAULT_ZONE_FILE="$target_file"
}

unset_default_zone() {
	rm -f "$DEFAULT_ZONE_FILE"
}

validate_zone_name() {
	local name="$1"

	if [[ -z "$name" ]]; then
		die "Invalid zone name: '$name' (must contain at least one valid character)"
	fi

	echo "$name"
}

zone_metadata_file() {
	echo "$(zone_base_dir)/zone.json"
}

ensure_zone_dir() {
	local dir
	dir="$(zone_base_dir)"
	mkdir -p "$dir"
}

op_zone() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
		use|set|switch)
			local target="$1"
			if [[ -z "$target" ]]; then
				die "Usage: cftunnel zone use <zone-name>"
			fi
			local cleaned
			cleaned="$(validate_zone_name "$target")"
			save_default_zone "$cleaned"
			echo "✅ Default zone set to '$cleaned'."
			;;
		current|show)
			local current
			current="$(load_default_zone)"
			if [[ -n "$current" ]]; then
				echo "Current default (persistent) zone: $current"
				echo "All commands without --zone will use this one."
			else
				echo "No default zone is set."
				echo "Use: cftunnel zone use <name>   or   cftunnel --zone <name> --persist"
			fi
			;;
		unset|clear|remove)
			unset_default_zone
			echo "Default zone has been cleared."
			;;
		login)
			local active_zone="$ZONE"
			if [[ -z "$active_zone" ]]; then
				local zones=()
				if [[ -d "$HOME_DIR/.cloudflared/zones" ]]; then
					while IFS= read -r -d '' zone_dir; do
						zones+=("$(basename "$zone_dir")")
					done < <(find "$HOME_DIR/.cloudflared/zones" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
				fi
				if [[ ${#zones[@]} -eq 0 ]]; then
					echo "No zones found. Create one first with:"
					echo "  cftunnel zone use <domain>"
					exit 1
				fi
				echo "Available zones:"
				local i=1
				for z in "${zones[@]}"; do
					echo "  $i) $z"
					((i++)) || true
				done
				read -p "Select zone number (or type name): " choice
				if [[ "$choice" =~ ^[0-9]+$ ]]; then
					active_zone="${zones[$((choice-1))]}"
				else
					active_zone="$choice"
				fi
				if [[ -z "$active_zone" ]]; then
					die "No zone selected."
				fi
			fi

			echo "Authenticating with Cloudflare..."
			"$CLOUDFLARED_BIN" tunnel login || die "Authentication failed."

			local cert_src="$HOME_DIR/.cloudflared/cert.pem"
			if [[ ! -f "$cert_src" ]]; then
				die "cert.pem not found after login."
			fi

			local cert_dst_dir="$HOME_DIR/.cloudflared/zones/$active_zone"
			mkdir -p "$cert_dst_dir"
			mv "$cert_src" "$cert_dst_dir/cert.pem"
			echo "✅ Certificate saved to zones/$active_zone/cert.pem"
			;;
		*)
			echo "Usage:"
			echo "  cftunnel zone use <name>     Set default/persistent zone"
			echo "  cftunnel zone current        Show current default zone"
			echo "  cftunnel zone unset          Clear the default zone"
			echo "  cftunnel zone login          Authenticate and save cert to active zone"
			exit 1
			;;
	esac
}
