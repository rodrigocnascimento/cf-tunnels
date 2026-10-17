#!/usr/bin/env bash
# lib/upgrade.sh — `cftunnel upgrade`: update the application itself.
#
# `install-cftunnel.sh` already performs every step of a verified update: it
# downloads the latest release bundle, verifies its SHA-256 and archive members,
# installs it under a content-addressed release directory and publishes it with
# the bundled `install.sh`. Re-running it *is* the supported update path, so
# `upgrade` reuses that script instead of duplicating the download and
# verification logic. This module only adds the operator-facing framing
# (current version, result) and forces the replacement of the current
# installation, which the release installer otherwise only does when it detects
# an existing release link.

[[ -z "${_CFTUNNEL_UPGRADE_LOADED:-}" ]] || return 0
_CFTUNNEL_UPGRADE_LOADED=1

# Entry link created by install.sh; resolved to learn the selected version.
CFTUNNEL_UPGRADE_LINK="${CFTUNNEL_UPGRADE_LINK:-/usr/local/bin/cftunnel}"

# The release installer ships inside every bundle, next to run.sh. Overridable
# seam for tests.
cftunnel_upgrade_installer() {
	printf '%s\n' "${CFTUNNEL_UPGRADE_INSTALLER:-$SCRIPT_DIR/install-cftunnel.sh}"
}

cftunnel_upgrade_version() {
	local version_file="$SCRIPT_DIR/VERSION"
	[[ -f "$version_file" ]] || die "version file is missing: $version_file"
	tr -d '[:space:]' <"$version_file"
}

# Version selected by the entry link when it points at an installation, falling
# back to the running installation. After an upgrade the link already points at
# the new release, so this reports the version that is now installed.
cftunnel_upgrade_active_version() {
	local target="$CFTUNNEL_UPGRADE_LINK" version_file=""
	target="$(readlink -f "$CFTUNNEL_UPGRADE_LINK" 2>/dev/null || true)"
	if [[ "$target" == */run.sh ]]; then
		version_file="${target%/run.sh}/VERSION"
		if [[ -f "$version_file" ]]; then
			tr -d '[:space:]' <"$version_file"
			return 0
		fi
	fi
	cftunnel_upgrade_version
}

op_upgrade() {
	[[ $# -eq 0 ]] || die "'upgrade' does not accept arguments"
	[[ $EUID -ne 0 ]] || die "run upgrade as your regular user, never as root or through sudo"

	local installer
	installer="$(cftunnel_upgrade_installer)"
	[[ -f "$installer" ]] || die "install-cftunnel.sh is missing from this installation; reinstall cftunnel from the release archive"

	local before after rc=0
	before="$(cftunnel_upgrade_active_version)"

	printf '[+] current cftunnel version: %s\n' "$before"
	printf '[+] fetching and installing the latest cftunnel release\n'

	bash "$installer" --force || rc=$?
	((rc == 0)) || die "the cftunnel upgrade failed (release installer exit $rc)"

	after="$(cftunnel_upgrade_active_version)"

	if [[ "$after" == "$before" ]]; then
		printf '[✓] cftunnel is already up to date (%s)\n' "$after"
	else
		printf '[✓] cftunnel upgraded %s -> %s\n' "$before" "$after"
	fi
}
