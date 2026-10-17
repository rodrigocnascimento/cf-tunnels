#!/usr/bin/env bash
# tests/test_upgrade.sh — `cftunnel upgrade` and the cloudflared update command
# =============================================================================
# `cftunnel upgrade` updates the application itself. It deliberately delegates
# the download/verification/publication to the release installer
# (install-cftunnel.sh), so these tests use that script as an injected seam and
# never touch the network, GitHub or the real /usr/local/bin link.
# =============================================================================

source "$PROJECT_DIR/tests/runner-lib.sh"

# Creates a fake release installer that records its arguments and, optionally,
# repoints the entry link at a different installation. Environment contract:
#   CFTUNNEL_TEST_INSTALLER_LOG   file that receives the arguments
#   CFTUNNEL_TEST_NEW_TARGET      new link target (optional)
#   CFTUNNEL_TEST_INSTALLER_EXIT  exit status (optional, default 0)
write_fake_installer() {
	local path="$1"
	cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CFTUNNEL_TEST_INSTALLER_LOG"
if [[ -n "${CFTUNNEL_TEST_NEW_TARGET:-}" ]]; then
	ln -sf "$CFTUNNEL_TEST_NEW_TARGET" "$CFTUNNEL_UPGRADE_LINK"
fi
exit "${CFTUNNEL_TEST_INSTALLER_EXIT:-0}"
SCRIPT
	chmod +x "$path"
}

# Builds a fake installation with a run.sh and VERSION so the entry link
# resolves to a version.
write_fake_installation() {
	local dir="$1" version="$2"
	mkdir -p "$dir"
	printf '%s\n' "$version" > "$dir/VERSION"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/run.sh"
	chmod +x "$dir/run.sh"
}

test_upgrade_rejects_arguments() {
	local output rc=0
	output="$(op_upgrade unexpected 2>&1)" || rc=$?

	assert_ne "0" "$rc" "upgrade with an argument must fail"
	assert_contains "$output" "'upgrade' does not accept arguments" "argument error message"
}

test_upgrade_requires_the_release_installer() {
	local output rc=0
	output="$(CFTUNNEL_UPGRADE_INSTALLER="$HOME/missing-install-cftunnel.sh" op_upgrade 2>&1)" || rc=$?

	assert_ne "0" "$rc" "a missing release installer must fail"
	assert_contains "$output" "install-cftunnel.sh is missing" "missing installer message"
}

test_upgrade_forces_the_release_installer_and_reports_the_new_version() {
	local fake="$HOME/fake-installer.sh" log="$HOME/installer.args"
	local old_dir="$HOME/releases/0.18.1-aaaa" new_dir="$HOME/releases/0.18.2-bbbb"
	local link="$HOME/bin/cftunnel"
	write_fake_installer "$fake"
	write_fake_installation "$old_dir" "0.18.1"
	write_fake_installation "$new_dir" "0.18.2"
	mkdir -p "$(dirname "$link")"
	ln -s "$old_dir/run.sh" "$link"

	local output rc=0
	output="$(
		CFTUNNEL_UPGRADE_INSTALLER="$fake" \
			CFTUNNEL_UPGRADE_LINK="$link" \
			CFTUNNEL_TEST_INSTALLER_LOG="$log" \
			CFTUNNEL_TEST_NEW_TARGET="$new_dir/run.sh" \
			op_upgrade 2>&1
	)" || rc=$?

	assert_eq "0" "$rc" "upgrade exit code"
	assert_eq "--force" "$(<"$log")" "the installer must be asked to replace the current installation"
	assert_contains "$output" "current cftunnel version: 0.18.1" "reports the previous version"
	assert_contains "$output" "cftunnel upgraded 0.18.1 -> 0.18.2" "reports the installed version"
}

test_upgrade_reports_when_already_up_to_date() {
	local fake="$HOME/fake-installer.sh" log="$HOME/installer.args"
	local dir="$HOME/releases/0.18.2-cccc" link="$HOME/bin/cftunnel"
	local running_version
	running_version="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
	write_fake_installer "$fake"
	write_fake_installation "$dir" "$running_version"
	mkdir -p "$(dirname "$link")"
	ln -s "$dir/run.sh" "$link"

	local output rc=0
	output="$(
		CFTUNNEL_UPGRADE_INSTALLER="$fake" \
			CFTUNNEL_UPGRADE_LINK="$link" \
			CFTUNNEL_TEST_INSTALLER_LOG="$log" \
			op_upgrade 2>&1
	)" || rc=$?

	assert_eq "0" "$rc" "no-op upgrade exit code"
	assert_contains "$output" "cftunnel is already up to date ($running_version)" "up-to-date report"
	assert_not_contains "$output" "upgraded" "an unchanged version is not reported as an upgrade"
}

test_upgrade_fails_when_the_release_installer_fails() {
	local fake="$HOME/fake-installer.sh" log="$HOME/installer.args"
	local link="$HOME/bin/cftunnel"
	write_fake_installer "$fake"
	write_fake_installation "$HOME/releases/0.18.1-aaaa" "0.18.1"
	mkdir -p "$(dirname "$link")"
	ln -s "$HOME/releases/0.18.1-aaaa/run.sh" "$link"

	local output rc=0
	output="$(
		CFTUNNEL_UPGRADE_INSTALLER="$fake" \
			CFTUNNEL_UPGRADE_LINK="$link" \
			CFTUNNEL_TEST_INSTALLER_LOG="$log" \
			CFTUNNEL_TEST_INSTALLER_EXIT=3 \
			op_upgrade 2>&1
	)" || rc=$?

	assert_ne "0" "$rc" "a failed installer must fail the upgrade"
	assert_contains "$output" "release installer exit 3" "propagates the installer failure"
}

test_cli_update_no_longer_exists() {
	local output rc=0
	# CFTUNNEL_SKIP_MAIN belongs to the test harness and would skip the dispatch
	# that reports the unknown command.
	output="$(CFTUNNEL_SKIP_MAIN= "$PROJECT_DIR/run.sh" cli-update 2>&1)" || rc=$?

	assert_ne "0" "$rc" "the removed name must not run"
	assert_contains "$output" "unknown command: cli-update" "the removed name is reported as unknown"
	assert_not_contains "$output" "renamed" "the removed name gets no special handling"
}

test_cli_dispatches_upgrade() {
	local fake="$HOME/fake-installer.sh" log="$HOME/installer.args"
	local old_dir="$HOME/releases/0.18.1-aaaa" new_dir="$HOME/releases/0.18.2-bbbb"
	local link="$HOME/bin/cftunnel"
	write_fake_installer "$fake"
	write_fake_installation "$old_dir" "0.18.1"
	write_fake_installation "$new_dir" "0.18.2"
	mkdir -p "$(dirname "$link")"
	ln -s "$old_dir/run.sh" "$link"

	local output rc=0
	output="$(
		CFTUNNEL_UPGRADE_INSTALLER="$fake" \
			CFTUNNEL_UPGRADE_LINK="$link" \
			CFTUNNEL_TEST_INSTALLER_LOG="$log" \
			CFTUNNEL_TEST_NEW_TARGET="$new_dir/run.sh" \
			"$PROJECT_DIR/run.sh" upgrade 2>&1
	)" || rc=$?

	assert_eq "0" "$rc" "upgrade dispatch exit code"
	assert_eq "--force" "$(<"$log")" "the dispatched upgrade runs the installer"
	assert_contains "$output" "cftunnel upgraded 0.18.1 -> 0.18.2" "dispatch reports the new version"
}

test_help_lists_upgrade_and_cloudflared_update() {
	local output
	# CFTUNNEL_SKIP_MAIN exists only for the test harness; the real CLI never
	# sets it, and it would skip usage printing.
	output="$(CFTUNNEL_SKIP_MAIN= "$PROJECT_DIR/run.sh" --help 2>&1)"

	assert_contains "$output" "cloudflared-update" "help names the cloudflared update command"
	assert_contains "$output" "upgrade" "help lists the application upgrade command"
	assert_not_contains "$output" "cli-update" "help no longer advertises the old name"
}
