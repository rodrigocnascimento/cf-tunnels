# Technical Design Document — CFTUNNEL-022

> **Issue:** CFTUNNEL-022
> **Title:** Application upgrade command and explicit cloudflared update name
> **Version:** 0.18.1 → 0.19.0
> **Status:** Implemented
> **Date:** 2026-10-17
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Change Proposal](#change-proposal)
4. [Risk Assessment](#risk-assessment)
5. [Test Plan](#test-plan)
6. [Out of Scope](#out-of-scope)
7. [Rollback Plan](#rollback-plan)
8. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

`cftunnel` had no way to update itself: the only update command was
`cli-update`, whose name says nothing about *what* it updates, and which in fact
updates the `cloudflared` **dependency**, never cftunnel.

This TDD makes the surface explicit and complete:

- `cli-update` becomes `cloudflared-update` (the name states the target); the old
  name is not kept as an alias and now simply does not exist.
- A new `cftunnel upgrade` updates the **application** by reusing the release
  installer (`install-cftunnel.sh`), which already performs a verified download
  and a publication of the latest release.

### Files in scope

| File | Change |
|------|--------|
| `run.sh` | Source `lib/upgrade.sh`; dispatch `upgrade` before zone loading; rename the dependency command to `cloudflared-update` (the old name is removed); help text and examples |
| `lib/upgrade.sh` | New `op_upgrade` and its version/installer helpers |
| `tests/test_upgrade.sh` | New regression suite for `upgrade` and the rename |
| `tests/run.sh` | Register `test_upgrade.sh` (integration) and `lib/upgrade.sh` (syntax) |
| `AGENTS.md` | Document both commands and the update behavior |
| `CHANGELOG.md` | Unreleased entry |
| `VERSION`, `packages/tui/package.json` | `0.19.0` |

### Files NOT in scope

- `lib/cloudflared.sh` — `update_cloudflared` keeps its behavior and messages; only
  the command that reaches it is renamed.
- `install-cftunnel.sh` — unchanged. It stays the single source of truth for
  downloading, verifying and installing a release.
- `packages/tui/` — the TUI never exposed either command.

---

## Problem Statement

1. `cftunnel cli-update` reads as "update the CLI", but it downloads
   `cloudflared-linux-<arch>` and installs it at `/usr/local/bin/cloudflared`. The
   component and the name disagree, which is a real trap for an operator
   troubleshooting an outdated connector.
2. There is no command to update cftunnel itself. The supported path is re-running
   the README one-liner, which fetches an **unpinned script from `main`** and
   executes it. Nothing in the CLI names, verifies or reports that operation.

---

## Change Proposal

### CP-01 — Rename the dependency command

`run.sh` dispatches `cloudflared-update) update_cloudflared ;;`. The work it
performs, its messages and the sudo requirement are unchanged.

### CP-02 — Do not keep the old name

`cli-update` is removed, not aliased: it now reaches the generic unknown-command
handler (`unknown command: cli-update`, usage, exit 1). A working alias would
keep the misleading name alive, and a bespoke "renamed" message would be extra
surface for a project with a single operator who already knows the rename.

### CP-03 — `cftunnel upgrade` delegates to the release installer

`op_upgrade` (in `lib/upgrade.sh`):

1. rejects arguments and root (`EUID 0`);
2. resolves the release installer as `CFTUNNEL_UPGRADE_INSTALLER` (default
   `$SCRIPT_DIR/install-cftunnel.sh`) and requires it to exist — every release
   bundle ships it next to `run.sh`;
3. reads the version currently selected by the entry link
   (`CFTUNNEL_UPGRADE_LINK`, default `/usr/local/bin/cftunnel`) when it points at
   an installation, falling back to the running `VERSION`;
4. runs `bash "$installer" --force`;
5. re-reads the selected version and reports either the upgrade
   (`cftunnel upgraded A -> B`) or that it was already current.

Delegation was chosen over a second download/verify implementation because
`install-cftunnel.sh` already owns checksum verification, archive-member
validation, version and runtime verification, the content-addressed release
directory and the call into the bundled `install.sh`. Duplicating that logic
would create a second, drifting verification path.

### CP-04 — Force the replacement

`--force` is passed explicitly. Without it the release installer only replaces a
link that already points inside `~/.local/share/cftunnel/releases/`, so an
`upgrade` from any other layout (for example a source checkout linked into
`/usr/local/bin`) would fail with the *installer's* instruction to "rerun with
--force" — advice the operator cannot act on from an `upgrade` command. Passing it
makes the command's meaning ("replace the current installation with the latest
release") true in every layout, and it is what recreates the systemd template
when it changed.

### CP-05 — Offline, side-effect-free dispatch

`upgrade` is handled in the early dispatch block, before zone loading, the
default-zone file and the `add` parser. A broken `.default_zone` or an unrelated
zone problem must not prevent recovering the installation.

### CP-06 — Version bump

`VERSION` and `packages/tui/package.json` move to `0.18.2` together; the TUI
preflight requires the two to match.

---

## Risk Assessment

| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| `--force` overwrites a user-managed `/usr/local/bin/cftunnel` | Medium | Low | The command is explicitly an upgrade; the link is cftunnel's own artifact and install.sh only replaces it via sudo |
| `upgrade` re-runs `install.sh`, re-downloading cloudflared | Low | Low | `install.sh` reuses the binary already on PATH and only copies it to the system path |
| Removing `cli-update` breaks a script that used it | Low | Low | Deliberate: the old name is gone rather than aliased; `--help` and this spec name the replacement |
| `upgrade` depends on `install-cftunnel.sh` existing | Low | Low | It ships in every release bundle; the check fails closed with a reinstall instruction |
| A future rewrite of the download logic drifts from the installer | Low | Medium | Deliberate: the installer remains the only implementation; `upgrade` adds framing, not a second verifier |

---

## Test Plan

`tests/test_upgrade.sh` (integration phase), all with an injected fake installer —
no network, no GitHub, no real `/usr/local/bin`:

- `upgrade` rejects extra arguments.
- `upgrade` fails closed when the release installer is missing.
- `upgrade` invokes the installer with `--force` and reports `A -> B`.
- `upgrade` reports "already up to date" when the version did not change.
- `upgrade` propagates a non-zero installer exit.
- `cftunnel cli-update` is reported as an unknown command.
- `cftunnel upgrade` is dispatched and reports the new version.
- `--help` lists `upgrade` and `cloudflared-update`, and no longer advertises
  `cli-update`.

`tests/run.sh` gains `lib/upgrade.sh` in the syntax phase.

---

## Out of Scope

- Pinned or downgraded upgrades (`--version`), and a check-only mode.
- Updating cftunnel from the TUI.
- Changing how `cloudflared` itself is downloaded or installed.
- Unifying main's legacy system installation with the per-user installation
  boundary tracked separately.

---

## Rollback Plan

Revert the commit. `upgrade` disappears, `cli-update` becomes the working command
again, and no persisted state, credential, tunnel or unit is changed by either
command — the only filesystem effect of `upgrade` is the release installation the
shared installer already performs.

---

## Acceptance Criteria

- [x] `cftunnel cloudflared-update` performs the previous `cli-update` work.
- [x] `cftunnel cli-update` is an unknown command and changes nothing.
- [x] `cftunnel upgrade` installs the latest release and reports the versions.
- [x] `cftunnel upgrade` works with damaged local zone state (dispatched before zone loading).
- [x] `cftunnel upgrade` fails closed without `install-cftunnel.sh` or when the installer fails.
- [x] `--help` documents both commands without the old name.
- [x] Full shell suite passes (`cd tests && ./run.sh`).
