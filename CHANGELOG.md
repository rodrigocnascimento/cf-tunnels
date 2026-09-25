# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.13.0] - 2026-09-25

### Added
- Added TUI zone registration through `a`: it collects a Cloudflare zone,
  displays the `zone use` and `zone login` command help/effects for explicit
  approval, then registers the zone and begins browser authentication.
- Added `l` to explicitly authenticate the current Scope. Ink unmounts before
  the interactive CLI login owns the terminal and is started again after it
  exits, so browser authentication remains visible and credential output is
  never parsed by the dashboard.

### Tests
- Added Ink coverage for registration-before-login and standalone Scope login.

## [0.12.0] - 2026-09-25

### Changed
- The TUI now begins at the first registered local zone rather than an
  all-zones virtual scope. Its scope is always a real local zone.
- Changing the TUI scope requires explicit confirmation and invokes
  `zone use` only after approval, synchronizing the CLI default zone with the
  displayed scope. The optional confirmation bypass lasts only for the current
  TUI session.
- The dashboard header displays the negotiated cftunnel application version.

### Tests
- Added adapter coverage for the `zone.use` JSON contract and updated the Ink
  rendering test for a real-zone initial scope.

## [0.11.0] - 2026-09-25

### Added
- `cftunnel tui-dev` now performs actionable preflight checks for Bun version,
  source package/dependencies, matching cftunnel/TUI versions, local JSON
  contract availability, interactive ANSI terminal support, and minimum width.
- Added CFTUNNEL-017, defining the future compiled Bun artifact, detached
  manifest, version/contract/hash verification, and installer boundary for
  `cftunnel tui` production launch.

## [0.10.0] - 2026-09-25

### Added
- On narrow terminals, the dashboard now presents navigation and tunnel detail
  as sequential Tab-switchable panels, avoiding a vertically clipped detail
  pane while preserving all controls.
- Added a state/data-source legend and explicit local inventory timestamp;
  systemd state is identified as a current local query and health remains a
  separate explicit timestamped observation.
- Per-tunnel inventory now surfaces local configuration issues without
  suppressing other zones or tunnels. Failed systemd units and unavailable
  systemd are distinguished from ordinary inactive units.

## [0.9.0] - 2026-09-25

### Added
- The dashboard can now run an explicit health check for the selected tunnel
  (`h`) or the current zone/all-zones scope (`H`), with visible in-progress
  and completion timestamps.
- Tunnel details now expose local YAML and credential-file presence/modes,
  expected systemd unit, route count, and actionable diagnostics for missing
  credentials, inactive units, and unresolved DNS observations.
- Added interactive `/` filtering over zone, tunnel name, hostname, and
  systemd state. Refresh preserves the selected tunnel when it remains in the
  current scope.

### Changed
- `tunnel.list` JSON now includes non-secret local configuration presence/mode
  data for each tunnel.

## [0.8.0] - 2026-09-25

### Added
- Added `zone list --output json`, a local-only zone inventory that discovers
  registered zones even when they have no tunnel YAMLs. It reports the default
  marker, tunnel/route totals, and non-secret credential-binding state.
- Added `--all-zones` for read-only `list` and `health` inventory requests.
  It explicitly bypasses the persistent default-zone scope and cannot be used
  with mutation commands or `--zone`.
- The Ink dashboard now starts in an all-local-zones view, displays registered
  zones and their credential state, supports temporary zone selection with
  left/right arrows, and gives an explicit empty state for zones without local
  tunnels.

### Tests
- Added contract coverage for zone discovery, empty registered zones, and
  aggregated local tunnel inventory; added adapter coverage for scoped calls.

## [0.7.0] - 2026-09-25

### Added
- Added the read-only Ink + React operational TUI in `packages/tui/`, executed
  and tested by Bun. Its operational adapter uses only the versioned JSON
  contracts from cftunnel; it never calls Cloudflare, systemd, or sudo itself.
- The first view supports capability negotiation, zone context, local tunnel
  inventory, selection, explicit per-tunnel health checks, refresh, and quit.
- Added `cftunnel tui-dev`, which launches the checkout's TUI and automatically
  binds it to the same source `run.sh`. Reserved `cftunnel tui` for the future
  packaged production artifact.

### Tests
- Added Bun tests for the Ink render under Bun and the subprocess adapter's
  malformed-response rejection and argument-array boundary.

## [0.6.0] - 2026-09-25

### Added
- Added the first read-only TUI integration contracts: `capabilities`, JSON
  output for zone context, local route inventory, tunnel status, and health,
  plus non-interactive `privilege check` for cached sudo availability.
- Added `health --output json`, which reports local configuration and
  credential presence, systemd state, and explicit DNS observations without
  querying Cloudflare.

### Changed
- `--output text|json` is now a global option. Existing human output remains
  the default; JSON operations emit one versioned document on stdout.
- `--zone` now selects a zone only for the current invocation. It never asks
  to persist or changes the default implicitly; `--persist` is the explicit
  persistence path.
- `status` no longer requests sudo before its unprivileged systemd query.

### Tests
- Added contract coverage for capabilities, JSON zone operations, local JSON
  inventory, no-sudo status/health, and non-interactive sudo-cache probing.

## [0.5.4] - 2026-08-07

### Fixed
- `validate_zone_name`, `hostname_belongs_to_zone`, `validate_tunnel_token_file`, `print_cftunnel_version`, `slugify`, and `validate_tunnel_uuid` now lock `LC_ALL=C` around their character-range validation, closing a locale-collation bypass where accented Latin letters (e.g. `é`, `ü`) could pass ASCII-only checks under common UTF-8 locales such as `en_US.UTF-8`. `slugify` was silently letting the resulting non-ASCII bytes into tunnel names, YAML paths, and systemd unit names instead of stripping them; `validate_tunnel_uuid` was accepting malformed identifiers into credential paths and DNS targets. See `spec/tdd-uuid-locale-collation-gap-CFTUNNEL-009.md`.

### Changed
- `discover_tunnel_uuid` and `create_tunnel_uuid` now share a single `extract_and_validate_uuid()` helper instead of duplicating extraction/validation/error logic.
- `discover_tunnel_uuid` collapsed its four sequential `jq` calls into one combined program, preserving the exact-match-vs-total distinction and non-string-`id` rejection.

### Tests
- Added regression coverage for the locale-collation bypass across `slugify`, `hostname_belongs_to_zone`, `validate_tunnel_token_file`, and `validate_tunnel_uuid`.

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
