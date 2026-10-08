#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "run the release check as the container's regular user" >&2; exit 1; }
if command -v bun >/dev/null 2>&1; then
	echo "the release smoke environment must not contain Bun" >&2
	exit 1
fi

task_installer="$(mktemp)"
task_transcript="$(mktemp)"
trap 'rm -f -- "$task_installer" "$task_transcript"' EXIT
if [[ -d /opt/cftunnel-candidate ]]; then
	# Exercise the candidate bootstrap and archive unchanged. Only its release
	# download transport is replaced with the mounted, checksumed public bundle.
	bash -c '
		set -euo pipefail
		CFTUNNEL_INSTALLER_LIBRARY_ONLY=true source /opt/cftunnel-candidate/install-cftunnel.sh
		unset CFTUNNEL_INSTALLER_LIBRARY_ONLY
		download_asset() {
			local asset="${1##*/}"
			case "$asset" in cftunnel-linux-*.tar.gz | cftunnel-linux-*.tar.gz.sha256) ;; *) die "unexpected candidate asset" ;; esac
			cp "/opt/cftunnel-candidate/$asset" "$2"
		}
		main
	'
else
	curl --fail --silent --show-error --location \
		https://raw.githubusercontent.com/rodrigocnascimento/cf-tunnels/main/install-cftunnel.sh \
		--output "$task_installer"
	bash -n "$task_installer"
	bash "$task_installer"
fi

cftunnel --version
[[ -x /usr/local/bin/cloudflared ]]
command -v cloudflared
cftunnel capabilities --output json | jq -e '.ok and .data.operations["tunnel.list"].json' >/dev/null
cftunnel zone list --output json | jq -e '.data.zones == []' >/dev/null
cftunnel --all-zones list --output json | jq -e '.data.tunnels == []' >/dev/null

# Registration and planning remain local; no Cloudflare login or tunnel is made.
cftunnel zone use example.com
cftunnel zone list --output json | jq -e '.data.zones[0].credential.state == "missing"' >/dev/null
cftunnel add --hostname app.example.com --type http --service http://localhost:3000 --plan --output json \
	| jq -e '.operation == "hostname.add.plan" and .data.hostname == "app.example.com" and .data.existing_tunnel == false' >/dev/null
[[ ! -e "$HOME/.cloudflared/cert.pem" && ! -e "$HOME/.cloudflared/zones/example.com/cert.pem" ]]

cftunnel log write --type system --level info --message "Release smoke check"
cftunnel log query --output json | jq -e 'any(.data.events[]; .message == "Release smoke check")' >/dev/null
cftunnel log write --zone example.com --type system --level info --message 'Scoped smoke check'
cftunnel log query --zone example.com --output text | grep -q 'Scoped smoke check'
sudo systemctl daemon-reload
systemctl cat cloudflared@.service >/dev/null
sudo systemd-analyze verify /etc/systemd/system/cloudflared@.service

# The released, compiled TUI runs in a pseudo-terminal, with no Bun installation.
(sleep 2; printf 'q') | timeout 15 script --quiet --return --command 'cftunnel tui' "$task_transcript" >/dev/null
grep -q CFTUNNEL "$task_transcript"
echo "Release smoke passed: installer, CLI contracts, local plan, log runtime, systemd template, and production TUI (no Bun)."
