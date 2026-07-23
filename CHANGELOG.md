# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.3] - 2026-07-23

### Changed
- Removed the automatic `cloudflared` version probe from normal command startup. Dependency updates remain explicit through `cftunnel cli-update`.
- `cftunnel add` now performs one exact-name tunnel discovery after confirmation, requests sudo only after successful read-only discovery, and reuses structured discovery/create output instead of listing all tunnels again for the UUID.

### Fixed
- `cftunnel add` no longer interprets DNS, network, authentication, Cloudflare API, or JSON parsing failures as evidence that a tunnel does not exist.
- Malformed, ambiguous, mismatched, or invalid-UUID Cloudflare responses now stop before tunnel creation, local YAML changes, DNS routing, or systemd operations.
- Uncertain tunnel-creation results now stop with safe retry guidance instead of continuing with partially known remote state.

### Security
- Tunnel UUIDs are validated and normalized before they are used in credential paths, YAML, or DNS targets.
- Captured tunnel-list and tunnel-create JSON remains suppressed on success and failure paths.

### Tests
- Expanded the suite to 104 tests, including focused coverage for failed and malformed discovery, unexpected response shapes, structured creation, UUID validation, response secrecy, safe retry behavior, sudo ordering, and prevention of downstream side effects.

### Documentation
- Added the CFTUNNEL-008 technical design record for fail-closed Cloudflare API probes and tunnel discovery.

## [0.5.2] - 2026-07-21

### Documentation
- Replaced the large in-repository documentation set with a focused GitHub Wiki organized by setup, concepts, reference, operations, security, and development topics.
- Rewrote `README.md` as a concise project visitor card and removed the obsolete `docs/` directory.
- Added repository guidance requiring future long-form documentation to be maintained in the Wiki with matching sidebar navigation.

## [0.5.1] - 2026-07-21

### Documentation
- Standardized user-facing CLI examples and installer guidance on the installed `cftunnel` command. Direct `run.sh` references remain only where documentation intentionally discusses the entry-point file or the separate test runner.

## [0.5.0] - 2026-07-21

### Added
- Added safe canonical zone registration shared by `zone use`, `--persist`, and the interactive default-change flow. Registration creates the matching zone directory, writes `.default_zone` atomically with mode `600`, and remains fully local and offline.
- Added token-only zone authentication in an isolated mode-`700` login home, including strict `ARGO TUNNEL TOKEN` framing, a suppressed read-only Cloudflare authentication probe, SHA-256 fingerprinting, and mode-`600` `zone.json` binding metadata.
- Added active-zone hostname containment for the apex, valid DNS subdomains, and complete leftmost-label wildcards.

### Changed
- Zone input is now lowercase canonicalized, permits one terminal DNS root dot, and enforces DNS label/path-safety boundaries. Persisted default state is revalidated and must already be canonical.
- Zone credential refresh now publishes a durable private transaction before changing either live file. The transaction retains complete previous and candidate pairs, commits only after both replacements succeed, and restores the previous pair on the next binding check after `SIGKILL` or a host crash.
- The zone credential wrapper now fails closed for missing, malformed, unsupported, fingerprint-mismatched, or non-mode-`600` credential bindings instead of falling back to an unrelated root credential.

### Security
- Zone login verifies that the real root `~/.cloudflared/cert.pem` was not created, removed, or changed after every login result, including failures and interrupted login processes.
- Credential/token contents and authenticated account output are suppressed on success and error paths; temporary artifacts are cleaned after handled outcomes, while an incomplete durable transaction is retained until recovery succeeds.
- Cross-zone, suffix-lookalike, and malformed hostnames are rejected before zone persistence/prompts, the global cloudflared version probe, sudo, tunnel creation, YAML writes, or DNS activity.
- Zone removal now validates credential binding before service changes and preserves local YAML/UUID files whenever remote tunnel deletion fails.

### Tests
- Expanded the suite to 91 tests, including deterministic DNS fixtures; registration write/chmod/rename failures; isolated-login cleanup; root-integrity checks during normal and interrupted login; token framing and secrecy; credential staging, rename, permission, rollback, `SIGKILL` crash recovery, strict mode enforcement, pre-probe hostname rejection, binding and fail-closed removal failures, interactive selection, and strict hostname containment.

### Documentation
- Documented local registration versus Cloudflare `Active` ownership checks, token-only credentials, local fingerprint association, durable crash recovery, strict credential modes, pre-probe hostname containment, remediation, trust boundaries, and the supported headless login workflow.

## [0.4.0] - 2026-07-18

### Added
- Added `cftunnel version` and `cftunnel --version` to report the application version from `VERSION` without requiring a zone, Cloudflare credentials, `cloudflared`, or network access.

## [0.3.2] - 2026-07-18

### Changed
- `cftunnel list` is now fully local and reads only `~/.cloudflared/zones/<zone>/*.yml`.
- An active zone lists its ingress hostname routes; no active zone lists routes from every local zone.
- Multi-hostname tunnel YAMLs now print one row per hostname/service pair.
- Root-level legacy YAML files and account-wide Cloudflare tunnels are intentionally excluded.
- The remote-only `CREATED` column was removed, and exact hostnames are no longer truncated.

### Fixed
- `list` no longer calls `cloudflared tunnel list`, including through the startup version check.
- Each hostname is paired with its own ingress service protocol instead of always using the first service.
- The test runner no longer leaks its own flags into `run.sh` and accidentally triggers Cloudflare API calls.
- The Makefile smoke target no longer checks the previously removed `prompt-hook.sh`.

### Tests
- Added six local-listing tests covering multiple ingress routes, zone isolation, all-zone aggregation, root exclusion, offline operation, and removal of the `jq` dependency.

## [0.3.1] - 2026-06-08

### Fixed
- **Critical:** `cloudflared()` wrapper in `lib/cloudflared.sh` now correctly preserves exit codes:
  - Previously: `"$CLOUDFLARED_BIN" ... 2>&1 | grep -v ... || true` swallowed **all** failures, making `op_add` believe DNS routes and tunnel creation succeeded when they failed
  - Now: stderr is captured to a temp file, filtered, and written back to stderr; the real exit code is returned via `return $rc`
- **Critical:** `op_add()` YAML rewrite no longer uses unquoted heredoc (`<<YAML`), eliminating command injection risk when re-writing existing tunnel configs:
  - Previously: `${existing_entries}` expanded inside the heredoc body, allowing execution of shell code if the existing YAML was tampered with
  - Now: uses `printf '%s\n'` to write each line explicitly, with zero expansion of file contents
- **High:** `cloudflared()` wrapper no longer mixes stderr into stdout (`2>&1` removed):
  - Previously: JSON warnings on stderr were injected into `cloudflared tunnel list --output json`, corrupting output consumed by `jq`
  - Now: stdout and stderr are fully separated
- **High:** `lib/zone.sh` now uses `$HOME_DIR` consistently instead of hardcoded `$HOME`:
  - Fixes mismatch when `RUN_USER` overrides the effective home directory
  - Affects `load_default_zone()`, `save_default_zone()`, and `op_zone login`
- **High:** `lib/cloudflared.sh` now uses `$HOME_DIR` for `--origincert` path instead of `$HOME`
- **Medium:** Removed dead `--zone)` cases from individual command parsers in `run.sh` (already consumed by the global first-pass parser)
- **Medium:** Empty tunnel name after `slugify()` is now validated with `[[ -n "$NAME" ]] || die` in both `op_add` and `op_remove`
- `local existing_entries` declaration added in `op_add()` to prevent global scope pollution

### Removed
- **Prompt hook (`prompt-hook.sh`)** — removed entirely:
  - Was never auto-installed (manual source only); added maintenance surface without enough usage
  - Users who relied on it can replicate behavior in 2 lines of shell config
  - `tests/test_prompt.sh` removed; test suite adjusted (38 tests)
- `install.sh` no longer references prompt hook installation
- `uninstall.sh` no longer references prompt hook removal

## [0.3.0] - 2026-06-01

### Added
- **Zone system** — isolate tunnels by Cloudflare zone:
  - `--zone <name>` flag for all commands
  - `zone use <name>` — set persistent default zone
  - `zone current` — show active default zone
  - `zone unset` — clear default zone
  - `zone login` — authenticate and save `cert.pem` to the active zone directory
  - `--persist` — save `--zone` as the new default in one command
- **Test suite** — 43+ tests covering functions, zones, parser, YAML:
  - `tests/run.sh` — explicit test list, phases: smoke, unit, integration, cli
  - `tests/Makefile` — `make smoke`, `make unit`, `make integration`, `make cli`, `make all`
  - Mock `cloudflared` and `systemctl` for zero-API testing
- `cloudflared()` wrapper now automatically injects `--origincert` based on active zone

### Changed
- **Pivot:** Abstract "profile" concept replaced by concrete "zone" concept:
  - `profiles/<slug>/` → `zones/<domain>/`
  - `.default_profile` → `.default_zone`
  - `CFTUNNEL_PROFILE` → `CFTUNNEL_ZONE`
- **Breaking:** `cftunnel list` now filters by the active zone when a default zone is set. Use `cftunnel zone unset` to see all tunnels again.
- `(( i++ ))` loops changed to `(( i++ )) || true` everywhere to prevent `set -e` from killing the script on arithmetic with falsy result
- `check_cloudflared_version()` now also skips when `cmd` is empty (avoids version check during pure config operations like `--persist`)
- `--zone <name> --persist` without a command now exits cleanly with a confirmation message instead of falling through to `print_usage`
- `AGENTS.md` updated with zone conventions, test suite, and `(( i++ ))` pitfall

### Fixed
- `(( found++ ))` in `op_list` loop was killing the script under `set -e` when `found` was 0, causing empty list output
- YAML service quotes not being stripped in `op_list`, showing `"http` instead of `http` in the SERVICE column
- `DEFAULT_ZONE_FILE` path consistency: now always uses `$HOME/.cloudflared/.default_zone` to avoid ordering issues with `HOME_DIR`
- `op_zone` (`set`/`use`/`switch`) not working due to `(( i++ ))` triggering `set -e` in the argument parser loop
- `save_default_zone` now creates parent directory with `mkdir -p` to prevent errors on first run

### Removed
- Dead function `resolve_effective_profile()` (unused, logic inline since v0.2.0)
- Profile metadata (`profile.json`, primary domain) — no longer needed with zone-based organization

## [0.2.0] - 2026-05-23

### Added
- `--no-dns` flag to skip automatic DNS CNAME record creation (for external DNS management via Terraform, etc.)
- DNS resolution fallback: `dig @1.1.1.1` → `host` → `getent ahosts` (built-in glibc, zero dependencies)
- `connectTimeout: "10s"` to originRequest in generated YAML for faster failure feedback
- Systemd sandbox hardening directives in `cloudflared@.service` template:
  - `NoNewPrivileges`, `PrivateTmp`, `RestrictAddressFamilies`, `RestrictRealtime`
  - `MemoryMax=256M`, `LimitNOFILE=65536`
  - `Restart=on-failure` with `StartLimitIntervalSec` / `StartLimitBurst` restart storm prevention
- `resolve_hostname()` and `has_cname_lookup()` helper functions for DNS operations
- Strategic comments throughout `run.sh`: pipeline flow, YAML field rationale, DNS fallback tiers
- Systemd Sandbox section in `docs/DOCS.md` with directive reference table

### Changed
- **Breaking:** `HOSTNAME` variable renamed to `TUNNEL_HOSTNAME` to avoid collision with bash built-in
- `$CLOUDFLARED_BIN` used consistently instead of bare `cloudflared` calls relying on PATH
- `dig` marked as optional in prerequisites documentation (fallback to `getent ahosts`)
- `README.md`, `docs/DOCS.md`, `docs/CLOUDFLARE.md` updated to reflect all v0.2.0 changes
- `cftunnel` command used consistently in `docs/CLOUDFLARE.md` (was `./run.sh`)

### Fixed
- YAML heredoc now quotes `hostname` and `service` values, preventing parse errors when values contain YAML special characters (`*`, `&`, `!`, etc.)
- `uninstall.sh` now stops running `cloudflared@*` services before removing the systemd template (previously only removed the file, leaving processes orphaned)
- YAML config files now created with `chmod 600` (was 664 group-readable)
- Duplicated TCP/UDP comment blocks removed from `run.sh` header
- Typo in credential redaction function: `REDAED` → `REDACTED` (`cf-ssh-diagnose.zsh`)

### Removed
- Duplicated TCP/UDP tunnel documentation block in `run.sh` header (13 lines)
- `Restart=always` replaced by `Restart=on-failure` in systemd template

## [0.1.0] - 2026-04-04

### Added
- DNS propagation check now uses Cloudflare DNS resolver (1.1.1.1) to avoid false negatives from local cache
- Comprehensive documentation for TCP/UDP tunnels explaining client connection requirements
- MIT LICENSE file added to the repository
- Example for Redis access via cloudflared access tcp command
- `install.sh` - One-command installer that sets up everything automatically
- `uninstall.sh` - Clean removal script with multiple options
- Custom logo header in `assets/logo-cf-tunnel.png`
- Complete README rewrite with Mermaid diagrams and comprehensive examples
- Technical documentation in `docs/DOCS.md` with placeholder examples

### Changed
- README.md updated with TCP/UDP tunnel usage instructions
- run.sh script header updated with TCP/UDP tunnel documentation

### Fixed
- All sensitive data (personal domains, UUIDs) replaced with placeholder examples
