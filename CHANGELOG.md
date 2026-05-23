# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
