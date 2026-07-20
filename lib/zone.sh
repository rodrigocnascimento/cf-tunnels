[[ -z "${_CFTUNNEL_ZONE_LOADED:-}" ]] || return 0
_CFTUNNEL_ZONE_LOADED=1

validate_zone_name() {
	local raw="${1:-}"
	[[ -n "$raw" ]] || die "Invalid zone name: zone is required"

	local name="${raw,,}"
	if [[ "$name" == *. ]]; then
		name="${name%.}"
	fi

	[[ -n "$name" ]] || die "Invalid zone name: zone is required"
	[[ "$name" =~ ^[a-z0-9.-]+$ ]] || die "Invalid zone name: '$raw' contains unsupported characters (use ASCII or punycode)"
	[[ ${#name} -le 253 ]] || die "Invalid zone name: '$raw' exceeds 253 characters"
	[[ "$name" == *.* ]] || die "Invalid zone name: '$raw' must contain at least two labels"
	[[ "$name" != .* && "$name" != *. && "$name" != *..* ]] || die "Invalid zone name: '$raw' contains an empty label"

	local labels=()
	local label
	IFS='.' read -r -a labels <<< "$name"
	for label in "${labels[@]}"; do
		[[ ${#label} -le 63 ]] || die "Invalid zone name: label '$label' exceeds 63 characters"
		[[ "$label" != -* && "$label" != *- ]] || die "Invalid zone name: label '$label' cannot start or end with '-'"
	done

	printf '%s\n' "$name"
}

zone_dir_for() {
	local zone_name="${1:-}"
	[[ -n "$zone_name" ]] || die "Cannot resolve an empty zone directory"
	printf '%s\n' "$HOME_DIR/.cloudflared/zones/$zone_name"
}

zone_base_dir() {
	if [[ -n "$ZONE" ]]; then
		zone_dir_for "$ZONE"
	else
		printf '%s\n' "$HOME_DIR/.cloudflared"
	fi
}

load_default_zone() {
	local target_file="$HOME_DIR/.cloudflared/.default_zone"
	[[ -f "$target_file" ]] || return 0

	local lines=()
	mapfile -t lines < "$target_file"
	[[ ${#lines[@]} -eq 1 && -n "${lines[0]}" ]] || die "Invalid persisted default zone in $target_file: expected exactly one non-empty line"

	local raw="${lines[0]}"
	local canonical
	if ! canonical="$(validate_zone_name "$raw" 2>/dev/null)"; then
		die "Invalid persisted default zone '$raw' in $target_file; correct the file manually"
	fi
	[[ "$raw" == "$canonical" ]] || die "Noncanonical persisted default zone '$raw' in $target_file; change it manually to '$canonical'"

	DEFAULT_ZONE_FILE="$target_file"
	printf '%s\n' "$canonical"
}

write_default_zone_file() {
	local path="${1:-}"
	local zone_name="${2:-}"
	printf '%s\n' "$zone_name" > "$path"
}

save_default_zone() {
	local zone_name="${1:-}"
	local canonical
	canonical="$(validate_zone_name "$zone_name")" || return 1
	[[ "$zone_name" == "$canonical" ]] || die "Refusing to persist noncanonical zone '$zone_name'; use '$canonical'"

	local target_file="$HOME_DIR/.cloudflared/.default_zone"
	local target_dir
	target_dir="$(dirname "$target_file")"
	mkdir -p -- "$target_dir" || die "Could not create Cloudflare config directory: $target_dir"

	local temporary
	temporary="$(mktemp "$target_dir/.default_zone.tmp.XXXXXX")" || die "Could not stage the default zone"
	if ! write_default_zone_file "$temporary" "$canonical"; then
		rm -f -- "$temporary" || true
		die "Could not write the default zone"
	fi
	if ! chmod 600 "$temporary"; then
		rm -f -- "$temporary" || true
		die "Could not secure the default zone file"
	fi
	if ! mv -f -- "$temporary" "$target_file"; then
		rm -f -- "$temporary" || true
		die "Could not replace the default zone file"
	fi

	DEFAULT_ZONE_FILE="$target_file"
}

register_zone() {
	local raw="${1:-}"
	local canonical
	canonical="$(validate_zone_name "$raw")" || return 1

	local dir
	dir="$(zone_dir_for "$canonical")"
	mkdir -p -- "$dir" || die "Could not create zone directory: $dir"
	save_default_zone "$canonical" || return 1
	printf '%s\n' "$canonical"
}

unset_default_zone() {
	rm -f -- "$DEFAULT_ZONE_FILE"
}

zone_metadata_file() {
	local zone_name="${1:-${ZONE:-}}"
	if [[ -n "$zone_name" ]]; then
		printf '%s/zone.json\n' "$(zone_dir_for "$zone_name")"
	else
		printf '%s/zone.json\n' "$HOME_DIR/.cloudflared"
	fi
}

ensure_zone_dir() {
	local zone_name="${1:-${ZONE:-}}"
	local dir
	if [[ -n "$zone_name" ]]; then
		dir="$(zone_dir_for "$zone_name")"
	else
		dir="$HOME_DIR/.cloudflared"
	fi
	mkdir -p -- "$dir"
}

hostname_belongs_to_zone() {
	local hostname="${1:-}"
	local zone_name="${2:-}"
	[[ -n "$hostname" && -n "$zone_name" ]] || return 1

	hostname="${hostname,,}"
	zone_name="${zone_name,,}"
	if [[ "$hostname" == *. ]]; then
		hostname="${hostname%.}"
	fi
	if [[ "$zone_name" == *. ]]; then
		zone_name="${zone_name%.}"
	fi

	local canonical_zone
	canonical_zone="$(validate_zone_name "$zone_name" 2>/dev/null)" || return 1
	[[ "$canonical_zone" == "$zone_name" ]] || return 1
	[[ -n "$hostname" && ${#hostname} -le 253 ]] || return 1
	[[ "$hostname" =~ ^[a-z0-9.*-]+$ ]] || return 1

	local dns_name="$hostname"
	if [[ "$dns_name" == \*.* ]]; then
		dns_name="${dns_name#*.}"
	elif [[ "$dns_name" == *\** ]]; then
		return 1
	fi
	[[ -n "$dns_name" && "$dns_name" != .* && "$dns_name" != *. && "$dns_name" != *..* ]] || return 1

	local labels=()
	local label
	IFS='.' read -r -a labels <<< "$dns_name"
	for label in "${labels[@]}"; do
		[[ -n "$label" && ${#label} -le 63 ]] || return 1
		[[ "$label" =~ ^[a-z0-9-]+$ ]] || return 1
		[[ "$label" != -* && "$label" != *- ]] || return 1
	done

	[[ "$dns_name" == "$canonical_zone" || "$dns_name" == *."$canonical_zone" ]]
}

validate_tunnel_token_file() {
	local candidate="${1:-}"
	if [[ -z "$candidate" || ! -f "$candidate" || -L "$candidate" || ! -r "$candidate" || ! -s "$candidate" ]]; then
		echo "error: tunnel credential is missing, empty, or unreadable" >&2
		return 1
	fi

	if ! awk '
		BEGIN { state = 0; blocks = 0; payload_lines = 0 }
		$0 == "-----BEGIN ARGO TUNNEL TOKEN-----" {
			if (state != 0 || blocks != 0) exit 1
			state = 1
			blocks++
			next
		}
		$0 == "-----END ARGO TUNNEL TOKEN-----" {
			if (state != 1 || payload_lines == 0) exit 1
			state = 2
			next
		}
		state == 1 {
			if ($0 !~ /^[A-Za-z0-9+\/=]+$/) exit 1
			payload_lines++
			next
		}
		$0 !~ /^[[:space:]]*$/ { exit 1 }
		END {
			if (state != 2 || blocks != 1 || payload_lines == 0) exit 1
		}
	' "$candidate"; then
		echo "error: tunnel credential does not contain one valid ARGO TUNNEL TOKEN block" >&2
		return 1
	fi
}

credential_sha256() {
	local credential="${1:-}"
	command -v sha256sum >/dev/null 2>&1 || {
		echo "error: required command not found: sha256sum" >&2
		return 1
	}
	sha256sum -- "$credential" | awk '{print $1}'
}

write_zone_credential_metadata() {
	local path="${1:-}"
	local zone_name="${2:-}"
	local fingerprint="${3:-}"
	local authenticated_at="${4:-}"
	printf '%s\n' \
		'{' \
		"  \"zone\": \"$zone_name\"," \
		'  "credential_type": "argo_tunnel_token",' \
		"  \"certificate_sha256\": \"$fingerprint\"," \
		"  \"authenticated_at\": \"$authenticated_at\"" \
		'}' > "$path"
}

install_zone_credential() {
	local candidate="${1:-}"
	local zone_name="${2:-}"
	local canonical
	canonical="$(validate_zone_name "$zone_name")" || return 1
	[[ "$zone_name" == "$canonical" ]] || {
		echo "error: refusing credential installation for noncanonical zone '$zone_name'" >&2
		return 1
	}
	validate_tunnel_token_file "$candidate" || return 1

	local dir cert metadata fingerprint authenticated_at
	dir="$(zone_dir_for "$canonical")"
	ensure_zone_dir "$canonical" || {
		echo "error: could not create credential destination for zone '$canonical'" >&2
		return 1
	}
	fingerprint="$(credential_sha256 "$candidate")" || return 1
	authenticated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	cert="$dir/cert.pem"
	metadata="$dir/zone.json"

	(
		local staged_cert="" staged_metadata="" backup_cert="" backup_metadata=""
		local had_cert=false had_metadata=false rollback_required=false

		_finish_zone_credential_install() {
			local rc=$?
			local rollback_ok=true cleanup_ok=true
			trap - EXIT HUP INT TERM

			if [[ "$rollback_required" == true ]]; then
				if [[ "$had_cert" == true ]]; then
					if [[ -n "$backup_cert" && -f "$backup_cert" ]]; then
						if ! mv -f -- "$backup_cert" "$cert"; then
							echo "error: credential rollback failed while restoring cert.pem" >&2
							rollback_ok=false
						fi
					else
						echo "error: credential rollback failed because the cert.pem backup is unavailable" >&2
						rollback_ok=false
					fi
				elif ! rm -f -- "$cert"; then
					echo "error: credential rollback failed while removing the new cert.pem" >&2
					rollback_ok=false
				fi

				if [[ "$had_metadata" == true ]]; then
					if [[ -n "$backup_metadata" && -f "$backup_metadata" ]]; then
						if ! mv -f -- "$backup_metadata" "$metadata"; then
							echo "error: credential rollback failed while restoring zone.json" >&2
							rollback_ok=false
						fi
					else
						echo "error: credential rollback failed because the zone.json backup is unavailable" >&2
						rollback_ok=false
					fi
				elif ! rm -f -- "$metadata"; then
					echo "error: credential rollback failed while removing the new zone.json" >&2
					rollback_ok=false
				fi

				if [[ "$rollback_ok" == true ]]; then
					echo "error: credential installation failed; previous zone credential state restored" >&2
				else
					echo "error: credential installation failed and rollback was incomplete" >&2
				fi
				rc=1
			fi

			local artifact
			for artifact in "$staged_cert" "$staged_metadata" "$backup_cert" "$backup_metadata"; do
				[[ -n "$artifact" && -e "$artifact" ]] || continue
				if ! rm -f -- "$artifact"; then
					echo "error: could not remove credential transaction artifact: $artifact" >&2
					cleanup_ok=false
				fi
			done
			[[ "$cleanup_ok" == true ]] || rc=1
			exit "$rc"
		}

		trap _finish_zone_credential_install EXIT
		trap 'exit 130' HUP INT TERM

		staged_cert="$(mktemp "$dir/.cert.pem.new.XXXXXX")" || {
			echo "error: could not create a staged zone credential" >&2
			exit 1
		}
		staged_metadata="$(mktemp "$dir/.zone.json.new.XXXXXX")" || {
			echo "error: could not create staged zone credential metadata" >&2
			exit 1
		}

		if ! cp -- "$candidate" "$staged_cert" || ! chmod 600 "$staged_cert"; then
			echo "error: could not stage the zone credential" >&2
			exit 1
		fi
		if ! write_zone_credential_metadata "$staged_metadata" "$canonical" "$fingerprint" "$authenticated_at" || ! chmod 600 "$staged_metadata"; then
			echo "error: could not stage zone credential metadata" >&2
			exit 1
		fi

		if [[ -e "$cert" || -L "$cert" ]]; then
			[[ -f "$cert" && ! -L "$cert" ]] || {
				echo "error: refusing to replace a non-regular zone cert.pem" >&2
				exit 1
			}
			had_cert=true
			backup_cert="$(mktemp "$dir/.cert.pem.backup.XXXXXX")" || exit 1
			cp -p -- "$cert" "$backup_cert" || exit 1
		fi
		if [[ -e "$metadata" || -L "$metadata" ]]; then
			[[ -f "$metadata" && ! -L "$metadata" ]] || {
				echo "error: refusing to replace a non-regular zone.json" >&2
				exit 1
			}
			had_metadata=true
			backup_metadata="$(mktemp "$dir/.zone.json.backup.XXXXXX")" || exit 1
			cp -p -- "$metadata" "$backup_metadata" || exit 1
		fi

		rollback_required=true
		if ! mv -f -- "$staged_cert" "$cert"; then
			echo "error: could not install the zone credential" >&2
			exit 1
		fi
		staged_cert=""
		if ! mv -f -- "$staged_metadata" "$metadata"; then
			echo "error: could not install zone credential metadata" >&2
			exit 1
		fi
		staged_metadata=""

		if ! chmod 600 "$cert"; then
			echo "error: could not enforce private permissions on the zone credential" >&2
			exit 1
		fi
		if ! chmod 600 "$metadata"; then
			echo "error: could not enforce private permissions on zone credential metadata" >&2
			exit 1
		fi

		rollback_required=false
		exit 0
	)
}

zone_metadata_value() {
	local metadata="${1:-}"
	local key="${2:-}"
	sed -nE "s/^[[:space:]]*\"${key}\": \"([^\"]*)\",?[[:space:]]*$/\\1/p" "$metadata"
}

zone_binding_error() {
	local zone_name="${1:-unknown}"
	local reason="${2:-invalid metadata}"
	echo "error: zone credential binding check failed for '$zone_name': $reason" >&2
	echo "Run 'cftunnel --zone $zone_name zone login' to authenticate it again." >&2
	return 1
}

verify_zone_credential_binding() {
	local zone_name="${1:-}"
	local credential="${2:-}"
	local canonical
	if ! canonical="$(validate_zone_name "$zone_name" 2>/dev/null)" || [[ "$canonical" != "$zone_name" ]]; then
		zone_binding_error "$zone_name" "the active zone is not canonical"
		return 1
	fi

	local metadata
	metadata="$(zone_metadata_file "$canonical")"
	[[ -f "$metadata" && ! -L "$metadata" && -r "$metadata" ]] || {
		zone_binding_error "$canonical" "zone.json is missing or unreadable"
		return 1
	}
	validate_tunnel_token_file "$credential" >/dev/null 2>&1 || {
		zone_binding_error "$canonical" "cert.pem is missing or malformed"
		return 1
	}

	local metadata_zone credential_type expected_hash actual_hash
	metadata_zone="$(zone_metadata_value "$metadata" zone)"
	credential_type="$(zone_metadata_value "$metadata" credential_type)"
	expected_hash="$(zone_metadata_value "$metadata" certificate_sha256)"
	[[ "$metadata_zone" == "$canonical" ]] || {
		zone_binding_error "$canonical" "metadata names zone '$metadata_zone'"
		return 1
	}
	[[ "$credential_type" == "argo_tunnel_token" ]] || {
		zone_binding_error "$canonical" "unsupported credential type"
		return 1
	}
	[[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || {
		zone_binding_error "$canonical" "metadata fingerprint is invalid"
		return 1
	}
	actual_hash="$(credential_sha256 "$credential")" || return 1
	[[ "$actual_hash" == "$expected_hash" ]] || {
		zone_binding_error "$canonical" "cert.pem fingerprint does not match zone.json"
		return 1
	}
}

cleanup_zone_login_workspace() {
	local workspace="${1:-}"
	local prefix="$HOME_DIR/.cloudflared/.zone-login."
	[[ "$workspace" == "$prefix"* && -n "$workspace" ]] || return 1
	rm -rf -- "$workspace"
}

root_credential_state() {
	local credential="${1:-}"
	[[ -n "$credential" ]] || return 1
	if [[ ! -e "$credential" && ! -L "$credential" ]]; then
		printf '%s\n' absent
		return 0
	fi
	[[ -f "$credential" && ! -L "$credential" && -r "$credential" ]] || return 1
	printf 'regular:%s\n' "$(credential_sha256 "$credential")"
}

verify_root_credential_unchanged() {
	local credential="${1:-}"
	local expected_state="${2:-}"
	local current_state
	current_state="$(root_credential_state "$credential")" || {
		echo "error: cloudflared left the root credential in an unsafe state; zone credential was not installed" >&2
		return 1
	}
	[[ "$current_state" == "$expected_state" ]] || {
		echo "error: cloudflared created, removed, or modified the root credential; zone credential was not installed" >&2
		return 1
	}
}

exit_interrupted_zone_login() {
	local exit_code="${1:-130}"
	local credential="${2:-}"
	local expected_state="${3:-}"
	trap - HUP INT TERM
	if ! verify_root_credential_unchanged "$credential" "$expected_state"; then
		exit 1
	fi
	echo "error: Cloudflare authentication was interrupted; zone credential was not installed" >&2
	exit "$exit_code"
}

op_zone() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
		use|set|switch)
			local target="${1:-}"
			[[ -n "$target" ]] || die "Usage: cftunnel zone use <zone-name>"
			local cleaned
			if ! cleaned="$(register_zone "$target")"; then
				return 1
			fi
			echo "✅ Zone '$cleaned' registered and set as default."
			;;
		current|show)
			local current
			current="$(load_default_zone)" || return 1
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
			local active_zone="${ZONE:-}"
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
				local z
				for z in "${zones[@]}"; do
					echo "  $i) $z"
					((i++)) || true
				done
				local choice
				read -r -p "Select zone number (or type name): " choice
				if [[ "$choice" =~ ^[0-9]+$ ]]; then
					[[ "$choice" -ge 1 && "$choice" -le ${#zones[@]} ]] || die "Invalid zone selection: $choice"
					active_zone="${zones[$((choice-1))]}"
				else
					active_zone="$choice"
				fi
			fi
			local canonical_active_zone
			canonical_active_zone="$(validate_zone_name "$active_zone")" || return 1
			active_zone="$canonical_active_zone"
			ensure_zone_dir "$active_zone" || die "Could not create the zone directory"

			[[ -n "$CLOUDFLARED_BIN" && -x "$CLOUDFLARED_BIN" ]] || die "required command not found: cloudflared"
			command -v sha256sum >/dev/null 2>&1 || die "required command not found: sha256sum"

			local login_home
			login_home="$(mktemp -d "$HOME_DIR/.cloudflared/.zone-login.XXXXXX")" || die "Could not create an isolated login workspace"
			case "$login_home" in
				"$HOME_DIR/.cloudflared/.zone-login."*) : ;;
				*) die "Refusing unsafe login workspace: $login_home" ;;
			esac
			local cleanup_command
			printf -v cleanup_command 'cleanup_zone_login_workspace %q' "$login_home"
			trap "$cleanup_command" EXIT

			local root_cert="$HOME_DIR/.cloudflared/cert.pem"
			local root_state_before login_rc=0
			root_state_before="$(root_credential_state "$root_cert")" || die "Could not inspect the existing root credential safely"
			local hup_command int_command term_command
			printf -v hup_command 'exit_interrupted_zone_login 129 %q %q' "$root_cert" "$root_state_before"
			printf -v int_command 'exit_interrupted_zone_login 130 %q %q' "$root_cert" "$root_state_before"
			printf -v term_command 'exit_interrupted_zone_login 143 %q %q' "$root_cert" "$root_state_before"
			trap "$hup_command" HUP
			trap "$int_command" INT
			trap "$term_command" TERM

			echo "Authenticating zone '$active_zone' with Cloudflare."
			echo "In the browser, select exactly: $active_zone"
			HOME="$login_home" "$CLOUDFLARED_BIN" tunnel login || login_rc=$?

			verify_root_credential_unchanged "$root_cert" "$root_state_before" || exit 1
			trap 'exit 129' HUP
			trap 'exit 130' INT
			trap 'exit 143' TERM
			[[ $login_rc -eq 0 ]] || die "Authentication failed for zone '$active_zone'."

			local candidate="$login_home/.cloudflared/cert.pem"
			if ! validate_tunnel_token_file "$candidate"; then
				die "Cloudflare login did not produce a supported tunnel credential"
			fi
			if ! "$CLOUDFLARED_BIN" --origincert "$candidate" tunnel list --output json >/dev/null 2>&1; then
				die "Cloudflare rejected the new credential for zone '$active_zone'"
			fi
			if ! install_zone_credential "$candidate" "$active_zone"; then
				die "Could not install the credential for zone '$active_zone'"
			fi

			cleanup_zone_login_workspace "$login_home" || die "Could not clean the isolated login workspace"
			trap - EXIT HUP INT TERM
			echo "✅ Credential saved to zones/$active_zone/cert.pem"
			;;
		*)
			echo "Usage:"
			echo "  cftunnel zone use <name>     Register and set the default zone"
			echo "  cftunnel zone current        Show current default zone"
			echo "  cftunnel zone unset          Clear the default zone"
			echo "  cftunnel zone login          Authenticate and save a credential to the active zone"
			exit 1
			;;
	esac
}
