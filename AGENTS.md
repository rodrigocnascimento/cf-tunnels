# AGENTS.md — cf-tunnels

> Compact guidance for OpenCode sessions working in this repo.

## What This Is

Pure-shell CLI for managing Cloudflare Tunnels with per-tunnel systemd services.
- **Entry point:** `run.sh` (symlinked as `cftunnel` after `./install.sh`)
- **Installer:** `install.sh`
- **Uninstaller:** `uninstall.sh`
- **SSH diagnostics:** `cf-ssh-diagnose.zsh`
- **Docs:** `README.md`, `docs/DOCS.md`, `docs/CLOUDFLARE.md`
- **Design spec:** `spec/tdd-tunnel-hardening-code-quality-CFTUNNEL-001.md`

## Project Type

No build system, no package manager, no test runner, no CI. Verification is manual + `bash -n`.

## Verification & Testing

- Syntax check: `bash -n run.sh`
- Test suite: `cd tests && ./run.sh` (43 tests covering functions, profiles, parser, YAML, prompt hook)
- Test suite with full output: `./run.sh --verbose`
- Makefile phases: `make smoke`, `make unit`, `make integration`, `make cli`, `make all`
- Validate by running `./run.sh list` or creating a test tunnel.
- If modifying scripts, always run `bash -n <file>` before executing.

## Architecture

- **One tunnel = one YAML** in `~/.cloudflared/<name>.yml`
- **Systemd template:** `/etc/systemd/system/cloudflared@.service` (created by `install.sh`)
- **Profile isolation:** `--profile <name>` stores configs under `~/.cloudflared/profiles/<slug>/`
- **Persistent default profile:** stored in `~/.cloudflared/.default_profile`
- **Unit naming:** `cloudflared@${profile}_${name}.service` (or `cloudflared@${name}.service` without profile). `_` is the profile separator to avoid parsing conflicts with hyphens in names.

## Critical Conventions (Easy to Miss)

- **`TUNNEL_HOSTNAME`** — the variable is named `TUNNEL_HOSTNAME`, not `HOSTNAME`. Do not use `HOSTNAME`; it's a bash built-in and was intentionally renamed in v0.2.0.
- **`CLOUDFLARED_BIN`** — always use this variable instead of bare `cloudflared` (captured at startup from PATH).
- **Quote YAML values** — `hostname` and `service` in the YAML heredoc must be quoted: `"${TUNNEL_HOSTNAME}"` and `"${SERVICE}"`. Unquoted wildcards (e.g., `*.domain.com`) break YAML parsing because `*` is a YAML alias indicator.
- **`chmod 600` on generated YAMLs** — after writing the heredoc, always `chmod 600 "$YAML"`.
- **`slugify()`** — transforms names for systemd unit compatibility (lowercase, special chars → hyphens, no leading/trailing hyphens).

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
- `--profile <name>` — operates inside an isolated profile directory.
- `--persist` — combined with `--profile`, saves it as the default persistent profile.
- `cli-update` — self-updates the `cloudflared` binary; skips version check.

## Version Check Behavior

`check_cloudflared_version()` runs on **every** command except `cli-update` and `profile`. It probes `cloudflared tunnel list`, filters the "outdated" JSON warning via a wrapper function, and interactively prompts to update if outdated.

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
4. Preserve slugify logic for profile and unit names.
5. If adding new flags, mirror them in the argument parser's `while/case` blocks for all affected commands.
6. If touching DNS logic, respect the 3-tier fallback and the `has_cname_lookup()` guard.

## Prompt Hook (Optional)

`prompt-hook.sh` shows the active cftunnel profile in your shell prompt — like Python venv's `(venv)` prefix.

- **Auto-detects** p10k / plain bash / plain zsh and adapts without breaking anything.
- **Usage:** `source /path/to/cf-tunnels/prompt-hook.sh` in `~/.bashrc` or `~/.zshrc`.
- **Without p10k:** prefixes `PS1` with `🚇[profile-name]`.
- **With p10k:** updates `POWERLEVEL9K_DIR_PREFIX` so the indicator appears before the directory segment.
- **Override modes** (set BEFORE sourcing):
  - `CFTUNNEL_PROMPT_MODE=auto` — default: detects p10k and adapts.
  - `CFTUNNEL_PROMPT_MODE=prefix` — always prefix `PS1`/`PROMPT` directly.
  - `CFTUNNEL_PROMPT_MODE=none` — only set `CFTUNNEL_PROFILE` variable (for custom themes).
  - `CFTUNNEL_PROMPT_MODE=dir_prefix` / `dir_suffix` — force p10k `DIR_PREFIX` / `DIR_SUFFIX`.
- **Installer integration:** `install.sh` automatically adds the source line to `~/.bashrc` and `~/.zshrc` (wrapped by `# >>> cftunnel installer <<<` / `# <<< cftunnel installer <<<` markers).
- **Uninstaller integration:** `uninstall.sh` removes the prompt hook block from rc files using those markers.

## Common Pitfalls

- Do not assume `dig` is installed — the fallback chain must remain intact.
- Do not unquote YAML heredoc values — any YAML special char (`*`, `&`, `!`, `{`, `[`) will break parsing.
- `uninstall.sh` must stop `cloudflared@*` services **before** removing the systemd template (v0.2.0 fix).
- The `--profile` flag can appear anywhere in the command line; the parser extracts it in a first pass before the main `case` logic.
- **`(( i++ ))` + `set -e`** — bash arithmetic `(( 0 ))` returns exit code 1 (falsy), which triggers `set -e` and kills the script. Always use `(( i++ )) || true` in loops when `errexit` is active.
