# AGENTS.md — cf-tunnels

> Compact guidance for OpenCode sessions working in this repo.

## What This Is

Bash CLI for managing Cloudflare Tunnels with per-tunnel systemd services and a bundled operational terminal dashboard.
- **Entry point:** `run.sh` (symlinked as `cftunnel` after `./install.sh`)
- **Installer:** `install.sh`
- **Uninstaller:** `uninstall.sh`
- **SSH diagnostics:** `cf-ssh-diagnose.zsh`
- **User documentation:** [GitHub Wiki](https://github.com/rodrigocnascimento/cf-tunnels/wiki)
- **Repository overview:** `README.md` (visitor card only; keep it concise)
- **Design specs:** `spec/tdd-tunnel-hardening-code-quality-CFTUNNEL-001.md`, `spec/tdd-zone-isolation-CFTUNNEL-002.md`, `spec/tdd-modular-refactor-CFTUNNEL-003.md`, `spec/tdd-critical-bug-fixes-CFTUNNEL-004.md`, `spec/tdd-local-zone-ingress-listing-CFTUNNEL-005.md`, `spec/tdd-version-command-CFTUNNEL-006.md`, `spec/tdd-safe-zone-registration-certificate-binding-CFTUNNEL-007.md`, `spec/tdd-fail-closed-cloudflare-api-probes-CFTUNNEL-008.md`, `spec/tdd-uuid-locale-collation-gap-CFTUNNEL-009.md`, `spec/tdd-tui-integration-contract-CFTUNNEL-010.md` (design only, not implemented), `spec/tdd-remotely-managed-tunnels-exploration-CFTUNNEL-011.md` (exploratory, not decided), `spec/tdd-cftunnel-backup-CFTUNNEL-012.md` (proposed, not started), `spec/tdd-cross-host-tunnel-name-conflict-CFTUNNEL-021.md`, `spec/tdd-upgrade-and-cloudflared-update-CFTUNNEL-022.md`

## Project Type

The hardened management core is Bash. The operational TUI lives in
`packages/tui/` and uses Ink + React/TypeScript on Bun; it is a separate
subprocess client of cftunnel's JSON contracts. Explicitly confirmed changes
hand off to the hardened CLI; the TUI does not own Cloudflare credentials or
invoke systemd directly. Core verification is manual +
`bash -n`; TUI verification uses `cd packages/tui && bun run typecheck && bun test`.

## Documentation Policy

- All new long-form user, operator, installation, configuration, security, troubleshooting, and contributor documentation belongs in the separate GitHub Wiki repository: `git@github.com:rodrigocnascimento/cf-tunnels.wiki.git`.
- Do not recreate `docs/` in this repository.
- Keep `README.md` as a short visitor card: explain the project's purpose, mental model, key differentiators, minimal first look, requirements, and links into the Wiki. Do not turn it into a CLI reference or operations manual.
- When adding or renaming a Wiki page, update the Wiki's `_Sidebar.md` in the same documentation change.
- Use GitHub-Wiki-safe Markdown filenames, such as `Getting-Started.md`, and link pages with their canonical `https://github.com/rodrigocnascimento/cf-tunnels/wiki/...` URLs.
- `spec/` remains the home for technical design records, `CHANGELOG.md` remains the release history, and `AGENTS.md` remains agent maintenance guidance. These are engineering records, not substitutes for Wiki user documentation.
- Documentation changes that alter behavior descriptions must update the relevant Wiki pages together with the code change; do not defer them to an in-repository Markdown guide.

## Verification & Testing

- Syntax check: `bash -n run.sh`
- Test suite: `cd tests && ./run.sh` (functions, zones, credential transactions and binding, safe removal, fail-closed remote discovery, local listing, parser, version reporting, YAML, logging, and installer regressions)
- Test suite with full output: `cd tests && ./run.sh --verbose`
- Makefile phases: `make smoke`, `make unit`, `make integration`, `make cli`, `make all`
- Validate by running `cftunnel list` or creating a test tunnel with `cftunnel add`.
- If modifying scripts, always run `bash -n <file>` before executing.
- Rebuild ignored TUI runtime artifacts after changing the application version;
  their manifest must match `VERSION`, the package version, target, and hash.
- Optional release verification: `bash tests/release-smoke.sh` tests the public
  release in a fresh rootless systemd container; `--candidate` tests a locally
  built runtime/bundle. It never mounts the host home or creates remote tunnels.
- Keep sample-data labels on dashboard media. Media-generation utilities are
  local-only and excluded from version control; only the finished assets are
  tracked. Demo fixtures must never call cftunnel, Cloudflare, sudo, or systemd.

## Architecture

- **One tunnel = one YAML** in `~/.cloudflared/zones/<domain>/<name>.yml`
- **Systemd template:** `/etc/systemd/system/cloudflared@.service` (created by `install.sh`)
- **Zone isolation:** `--zone <name>` stores configs under `~/.cloudflared/zones/<domain>/`
- **Persistent default zone:** stored canonically in mode-`600` `~/.cloudflared/.default_zone`; every persistence path first creates the matching zone directory
- **Unit naming:** `cloudflared@${zone-slug}_${name}.service` (or `cloudflared@${name}.service` without zone). `_` is the zone separator to avoid parsing conflicts with hyphens in names.

## Critical Conventions (Easy to Miss)

- **`TUNNEL_HOSTNAME`** — the variable is named `TUNNEL_HOSTNAME`, not `HOSTNAME`. Do not use `HOSTNAME`; it's a bash built-in and was intentionally renamed in v0.2.0.
- **`CLOUDFLARED_BIN`** — always use this variable instead of bare `cloudflared` (captured at startup from PATH).
- **Quote YAML values** — `hostname` and `service` in the YAML heredoc must be quoted: `"${TUNNEL_HOSTNAME}"` and `"${SERVICE}"`. Unquoted wildcards (e.g., `*.domain.com`) break YAML parsing because `*` is a YAML alias indicator.
- **`chmod 600` on generated YAMLs** — after writing the heredoc, always `chmod 600 "$YAML"`.
- **Canonical zone paths** — zone input is lowercase-normalized, one terminal root dot is removed, and DNS syntax is validated before any path is formed. Zone directories use the canonical validated domain; never use raw input or `slugify()` for zone paths.
- **Persisted state** — load `.default_zone` as exactly one non-empty canonical line and validate it before assigning `ZONE`. Do not silently repair, delete, or migrate invalid state.
- **Explicit zone helpers** — pass the intended canonical zone to path/directory helpers. Do not temporarily rely on a previous global `ZONE` while registering another zone.
- **Credential secrecy and binding** — never print token/PEM contents or remote account output. Zone `cert.pem` and `zone.json` must both be mode `600`; verify canonical metadata and the SHA-256 fingerprint before invoking `cloudflared`.
- **Isolated login and root preservation** — run `cloudflared tunnel login` with a mode-`700` temporary `HOME`, clean it on every exit/signal path, and verify the real root `~/.cloudflared/cert.pem` was not created, removed, or changed even when login returns non-zero.
- **Recoverable credential replacement** — stage and secure both credential files, publish a durable private transaction containing the previous pair before changing either live file, and retire it only after both replacements succeed. Recover a published transaction before credential use; retain it if recovery is incomplete so the next command can retry. Never replace only one side intentionally.
- **Hostname containment** — with an active zone, accept only the apex, valid DNS subdomains, or `*` as the complete leftmost label. Reject malformed and cross-zone hostnames before sudo or external/file side effects.
- **Fail-closed tunnel discovery** — `add` must distinguish a successful empty exact-name response from DNS, network, authentication, API, or JSON failure. Validate remote UUIDs before forming paths; never create on uncertain discovery, and never continue to YAML/DNS/systemd after an uncertain create result. A discovered tunnel with no local credential belongs to another host: never reuse it, offer a host-scoped name (`<derived>-<server-hostname>`), and fail closed if that name is also taken.
- **Fail-closed hostname ownership and rollback** — before `sudo` and before any create, `op_add_dns_preflight` fails closed only when `dig`/`host` positively prove the hostname resolves to a *different* tunnel's `<uuid>.cfargotunnel.com`; missing tooling, `--no-dns` and non-tunnel/ proxied records fall through. When the ingress/DNS step fails after this run created the tunnel, `rollback_created_add` deletes that tunnel and removes the YAML and `<UUID>.json` written by the run, and never touches a pre-existing tunnel. A propagation timeout or decline after the CNAME exists is reported without rollback.
- **`dig`/`host` are optional** — they power DNS verification in `add` and `health` only. `install.sh` warns (never fails) when both are missing, naming the distro package.
- **Fail-closed removal** — verify active-zone credential binding before stopping a service, and never delete local YAML/UUID credentials when Cloudflare tunnel deletion fails.
- **`slugify()`** — transforms names only for systemd unit compatibility (lowercase, special chars → hyphens, no leading/trailing hyphens).
- **Application version** — `cftunnel version` and `cftunnel --version` read the root `VERSION` file. Keep their dispatch before zone loading and dependency checks so they remain offline and side-effect-free.

## DNS Resolution (3-Tier Fallback)

Implemented in `resolve_hostname()`:
1. `dig @1.1.1.1 +short` (best — shows CNAME, validates `cfargotunnel.com`)
2. `host` (CNAME-capable, same package as dig)
3. `getent ahosts` (glibc built-in, IP only — cannot verify CNAME)

If no `dig`/`host`, the `cfargotunnel.com` check is skipped gracefully; DNS still resolves but warns that CNAME verification is unavailable.

## Command Flow (`op_add`)

1. Validate flags (`--hostname`, `--type`, `--service`, type/protocol match)
2. Derive tunnel name from domain+type if `--name` not given and show the confirmation preview
3. Perform a read-only exact-name discovery; stop on request, JSON, ambiguity, or UUID failure
4. If discovery finds a tunnel whose credential is not local (created on another host), offer a host-scoped name `<derived>-<server-hostname>`; never reuse the foreign tunnel. `--yes` uses the suggested name automatically and announces it; an unresolvable conflict fails closed with an explicit `--name` command. This runs before sudo.
5. Best-effort DNS ownership preflight (before sudo): refuse to continue when `dig`/`host` prove the hostname already points to a different tunnel; otherwise fall through.
6. Obtain sudo authorization, then create only after a successful empty discovery
7. Reuse the validated discovery/create UUID and locate its credential JSON
8. Write YAML (quoted values, `chmod 600`)
9. Validate ingress, then create the CNAME route. If this fails and this run created the tunnel, roll back that tunnel plus the YAML/credential the run wrote; a pre-existing tunnel is never deleted.
10. Wait up to 30s for propagation (no rollback here: the route already exists). `--no-dns` skips all DNS steps.
11. Enable & start systemd service

## Flags & Behavior

- `--no-dns` — skips DNS creation/propagation. User must create CNAME manually in Cloudflare dashboard.
- `--zone <name>` — operates inside an isolated zone directory.
- `--persist` — combined with `--zone`, saves it as the default persistent zone.
- `zone login` — authenticates in an isolated home, validates the token, performs a suppressed read-only authentication probe, and transactionally installs `cert.pem` plus `zone.json`.
- `cloudflared-update` — explicitly updates the `cloudflared` binary to the latest release (renamed from `cli-update`, which no longer exists).
- `upgrade` — updates cftunnel itself. It reuses `install-cftunnel.sh` to download, verify and install the latest release and replace the current installation, then reports the version now in use. It is dispatched before zone loading and dependency checks, so it stays usable with a broken local state.
- `version` / `--version` — reports the cftunnel application version from `VERSION`; it does not report or update `cloudflared`.
- `list` — reads hostname routes only from zone YAML files. An active zone scans that zone; no active zone scans all `zones/*/*.yml`. Root-level YAML and the Cloudflare API are not used.

## Dependency Update Behavior

Normal commands do not perform an automatic dependency-version probe. The old probe used an authenticated account tunnel listing, discarded failures, and could duplicate operational API errors. Use `cftunnel cloudflared-update` explicitly to update the `cloudflared` dependency, and `cftunnel upgrade` to update cftunnel itself. `list` and application version reporting remain fully local and offline-capable.

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
- **`die()` inside `$(...)`** — command substitutions run in a subshell, and `errexit` may be disabled when the caller is tested by `if`/`||`. Always propagate validator assignments explicitly, for example `value="$(validate ...)" || return 1`, so failure cannot continue with an empty value.
- `cftunnel list` is route-centric: parse every hostname/service pair under `ingress:` and ignore hostname-less fallback rules such as `http_status:404`.
