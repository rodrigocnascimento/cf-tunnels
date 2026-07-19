# AGENTS.md — cf-tunnels

> Compact guidance for OpenCode sessions working in this repo.

## What This Is

Pure-shell CLI for managing Cloudflare Tunnels with per-tunnel systemd services.
- **Entry point:** `run.sh` (symlinked as `cftunnel` after `./install.sh`)
- **Installer:** `install.sh`
- **Uninstaller:** `uninstall.sh`
- **SSH diagnostics:** `cf-ssh-diagnose.zsh`
- **Docs:** `README.md`, `docs/DOCS.md`, `docs/CLOUDFLARE.md`
- **Design specs:** `spec/tdd-tunnel-hardening-code-quality-CFTUNNEL-001.md`, `spec/tdd-zone-isolation-CFTUNNEL-002.md`, `spec/tdd-modular-refactor-CFTUNNEL-003.md`, `spec/tdd-critical-bug-fixes-CFTUNNEL-004.md`, `spec/tdd-local-zone-ingress-listing-CFTUNNEL-005.md`

## Project Type

No build system, no package manager, no test runner, no CI. Verification is manual + `bash -n`.

## Verification & Testing

- Syntax check: `bash -n run.sh`
- Test suite: `cd tests && ./run.sh` (44 tests covering functions, zones, local listing, parser, YAML)
- Test suite with full output: `./run.sh --verbose`
- Makefile phases: `make smoke`, `make unit`, `make integration`, `make cli`, `make all`
- Validate by running `./run.sh list` or creating a test tunnel.
- If modifying scripts, always run `bash -n <file>` before executing.

## Architecture

- **One tunnel = one YAML** in `~/.cloudflared/zones/<domain>/<name>.yml`
- **Systemd template:** `/etc/systemd/system/cloudflared@.service` (created by `install.sh`)
- **Zone isolation:** `--zone <name>` stores configs under `~/.cloudflared/zones/<domain>/`
- **Persistent default zone:** stored in `~/.cloudflared/.default_zone`
- **Unit naming:** `cloudflared@${zone-slug}_${name}.service` (or `cloudflared@${name}.service` without zone). `_` is the zone separator to avoid parsing conflicts with hyphens in names.

## Critical Conventions (Easy to Miss)

- **`TUNNEL_HOSTNAME`** — the variable is named `TUNNEL_HOSTNAME`, not `HOSTNAME`. Do not use `HOSTNAME`; it's a bash built-in and was intentionally renamed in v0.2.0.
- **`CLOUDFLARED_BIN`** — always use this variable instead of bare `cloudflared` (captured at startup from PATH).
- **Quote YAML values** — `hostname` and `service` in the YAML heredoc must be quoted: `"${TUNNEL_HOSTNAME}"` and `"${SERVICE}"`. Unquoted wildcards (e.g., `*.domain.com`) break YAML parsing because `*` is a YAML alias indicator.
- **`chmod 600` on generated YAMLs** — after writing the heredoc, always `chmod 600 "$YAML"`.
- **`slugify()`** — transforms names for systemd unit compatibility (lowercase, special chars → hyphens, no leading/trailing hyphens). Zone directory names use the raw domain; slugify is only for systemd unit names.

## DNS Resolution (3-Tier Fallback)

Implemented in `resolve_hostname()`:
1. `dig @1.1.1.1 +short` (best — shows CNAME, validates `cfargotunnel.com`)
2. `host` (CNAME-capable, same package as dig)
3. `getent ahosts` (glibc built-in, IP only — cannot verify CNAME)

If no `dig`/`host`, the `cfargotunnel.com` check is skipped gracefully; DNS still resolves but warns that CNAME verification is unavailable.

## Command Flow (`op_add`)

1. Validate flags (`--hostname`, `--type`, `--service`, type/protocol match)
2. Derive tunnel name from domain+type if `--name` not given
3. Create tunnel (if new) → capture UUID
4. Write YAML (quoted values, `chmod 600`)
5. Validate ingress via `cloudflared tunnel --config $YAML ingress validate`
6. DNS check → create CNAME route → wait up to 30s for propagation (`--no-dns` skips all DNS steps)
7. Enable & start systemd service

## Flags & Behavior

- `--no-dns` — skips DNS creation/propagation. User must create CNAME manually in Cloudflare dashboard.
- `--zone <name>` — operates inside an isolated zone directory.
- `--persist` — combined with `--zone`, saves it as the default persistent zone.
- `zone login` — authenticates with Cloudflare and saves `cert.pem` to the active zone directory.
- `cli-update` — self-updates the `cloudflared` binary; skips version check.
- `list` — reads hostname routes only from zone YAML files. An active zone scans that zone; no active zone scans all `zones/*/*.yml`. Root-level YAML and the Cloudflare API are not used.

## Version Check Behavior

`check_cloudflared_version()` runs on **every** command except `cli-update`, `list`, and `zone`. It probes `cloudflared tunnel list`, filters the "outdated" JSON warning via a wrapper function, and interactively prompts to update if outdated. `list` is exempt so it remains fully local and offline-capable.

## Security Hardening in Systemd Template

The `install.sh` template includes these directives (do not remove):
- `NoNewPrivileges=true`, `PrivateTmp=true`
- `RestrictAddressFamilies=AF_INET AF_INET6`
- `RestrictRealtime=true`
- `MemoryMax=256M`, `LimitNOFILE=65536`
- `Restart=on-failure` with `StartLimitIntervalSec=30` / `StartLimitBurst=5`

## When Modifying Scripts

1. Keep `set -euo pipefail` at the top.
2. Use `die()` and `need()` for errors/dependency checks.
3. Maintain the `cloudflared()` wrapper (filters outdated-version JSON warning from stderr).
4. Preserve slugify logic for zone and unit names.
5. If adding new flags, mirror them in the argument parser's `while/case` blocks for all affected commands.
6. If touching DNS logic, respect the 3-tier fallback and the `has_cname_lookup()` guard.
7. The `cloudflared()` wrapper automatically injects `--origincert` based on active zone.

## Common Pitfalls

- Do not assume `dig` is installed — the fallback chain must remain intact.
- Do not unquote YAML heredoc values — any YAML special char (`*`, `&`, `!`, `{`, `[`) will break parsing.
- `uninstall.sh` must stop `cloudflared@*` services **before** removing the systemd template (v0.2.0 fix).
- The `--zone` flag can appear anywhere in the command line; the parser extracts it in a first pass before the main `case` logic.
- **`(( i++ ))` + `set -e`** — bash arithmetic `(( 0 ))` returns exit code 1 (falsy), which triggers `set -e` and kills the script. Always use `(( i++ )) || true` in loops when `errexit` is active.
- `cftunnel list` is route-centric: parse every hostname/service pair under `ingress:` and ignore hostname-less fallback rules such as `http_status:404`.
