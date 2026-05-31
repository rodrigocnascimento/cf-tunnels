# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-05-31

### Added
- **Profile system** — isolate tunnels by workspace/context:
  - `--profile <name>` flag for all commands
  - `profile use <name>` — set persistent default profile
  - `profile current` — show active default profile
  - `profile unset` — clear default profile
  - `--persist` — save `--profile` as the new default in one command
  - Profile metadata (`profile.json`) stores primary domain for domain-guard warnings
- **Prompt hook** (`prompt-hook.sh`) — shows active profile in shell prompt like Python venv:
  - Auto-detects p10k / plain bash / plain zsh
  - With p10k: uses `POWERLEVEL9K_DIR_PREFIX` (non-destructive)
  - Without p10k: prefixes `PS1` with `🚇[profile-name]`
  - Override modes: `auto`, `prefix`, `none`, `dir_prefix`, `dir_suffix`
  - Installer adds source line to `~/.bashrc` and `~/.zshrc` (marker-wrapped for clean removal)
- **Test suite** — 43 tests covering functions, profiles, parser, YAML, prompt hook:
  - `tests/run.sh` — explicit test list, phases: smoke, unit, integration, cli
  - `tests/Makefile` — `make smoke`, `make unit`, `make integration`, `make cli`, `make all`
  - Mock `cloudflared` and `systemctl` for zero-API testing
- `install.sh` now installs prompt hook into `~/.bashrc` / `~/.zshrc` with `# >>> cftunnel installer <<<` / `# <<< cftunnel installer <<<` markers
- `uninstall.sh` now removes prompt hook blocks from rc files using those markers

### Changed
- **Breaking:** `cftunnel list` now filters by the active profile when a default profile is set. Use `cftunnel profile unset` to see all tunnels again.
- **Breaking:** `op_list` output now includes a `PROFILE` column and shows `[profile] <name>` header when filtering
- `(( i++ ))` loops changed to `(( i++ )) || true` everywhere to prevent `set -e` from killing the script on arithmetic with falsy result
- `check_cloudflared_version()` now also skips when `cmd` is empty (avoids version check during pure config operations like `--persist`)
- `--profile <name> --persist` without a command now exits cleanly with a confirmation message instead of falling through to `print_usage`
- `resolve_effective_profile()` function removed (logic was already inline; dead code cleanup)
- `AGENTS.md` updated with prompt hook, test suite, and `(( i++ ))` pitfall

### Fixed
- `(( found++ ))` in `op_list` loop was killing the script under `set -e` when `found` was 0, causing empty list output
- YAML service quotes not being stripped in `op_list`, showing `"http` instead of `http` in the SERVICE column
- `DEFAULT_PROFILE_FILE` path inconsistency: now always uses `$HOME/.cloudflared/.default_profile` to avoid ordering issues with `HOME_DIR`
- `op_profile` (`set`/`use`/`switch`) not working due to `(( i++ ))` triggering `set -e` in the argument parser loop
- `save_default_profile` now creates parent directory with `mkdir -p` to prevent errors on first run

### Removed
- Dead function `resolve_effective_profile()` (unused, logic inline since v0.2.0)

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
