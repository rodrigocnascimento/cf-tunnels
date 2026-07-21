# Technical Design Document — CFTUNNEL-001

> **Issue:** CFTUNNEL-001
> **Title:** Tunnel Hardening & Code Quality Improvements
> **Version:** 0.1.0 → 0.1.1
> **Status:** Draft (awaiting review)
> **Date:** 2026-05-23
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Root Cause Analysis: YAML `*` wildcard](#root-cause-analysis-yaml--wildcard)
4. [Code Review Findings](#code-review-findings)
5. [Change Proposals](#change-proposals)
6. [Risk Assessment](#risk-assessment)
7. [Test Plan](#test-plan)
8. [Out of Scope](#out-of-scope)
9. [Rollback Plan](#rollback-plan)

---

## Overview

This TDD documents all improvements identified during a comprehensive code review of the `cf-tunnels` project (v0.1.0). Changes span 5 files across 14 discrete modifications, covering security hardening, bug fixes, shell script best practices, and feature additions.

### Files in scope

| File | Changes | Category |
|------|---------|----------|
| `run.sh` | 11 items | Security, fixes, feature, cosmetic |
| `install.sh` | 1 item | Security hardening |
| `uninstall.sh` | 1 item | Bug fix |
| `cf-ssh-diagnose.zsh` | 1 item | Typo fix |
| `README.md` | Refresh to reflect changes | Documentation |
| `docs/DOCS.md` | Refresh to reflect changes | Documentation |
| `docs/CLOUDFLARE.md` | Refresh to reflect changes | Documentation |

### Files NOT in scope

- `assets/logo-cf-tunnel.png` — compression deferred
- No new files created (shared library deferred to architectural refactor)

---

## Problem Statement

The project was reviewed across three axes:

1. **Security of generated tunnels** — Are configs, credentials, and runtime behavior secure?
2. **Tunnel hardening** — What runtime protections and stability measures can be added?
3. **Code quality** — Shell script correctness, maintainability, and dependency management.

### Bugs discovered during review

| ID | Severity | Description | File |
|----|----------|-------------|------|
| BUG-01 | High | `${HOSTNAME}` starts with `*` (wildcard hostname) breaks YAML parsing — `*` is the YAML alias node indicator | `run.sh:163` |
| BUG-02 | Medium | `${SERVICE}` unquoted in YAML heredoc — same class as BUG-01; special YAML chars in the service URL could corrupt config or cause injection | `run.sh:164` |
| BUG-03 | High | `uninstall.sh` claims it stops running tunnels when removing the systemd template, but only removes the file — running tunnels continue orphaned | `uninstall.sh:178` |
| BUG-04 | Low | Typo in `redact()` function: `REDAED` instead of `REDACTED` | `cf-ssh-diagnose.zsh:74` |

### Security findings

| ID | Severity | Description | File |
|----|----------|-------------|------|
| SEC-01 | Medium | Generated YAML files have `664` (group-readable) permissions. Should be `600` | `run.sh` |
| SEC-02 | Medium | systemd template has no sandboxing directives — cloudflared runs with full user privileges and filesystem access | `install.sh` |
| SEC-03 | Low | `HOSTNAME` is a reserved bash built-in variable — local override works in the current shell but is fragile if any subshell references it before the override | `run.sh` |
| SEC-04 | Info | `CLOUDFLARED_BIN` is captured at startup (line 40) but never used — commands call `cloudflared` directly via PATH | `run.sh` |

### Feature gaps

| ID | Description |
|----|-------------|
| FEAT-01 | `--no-dns` flag: user cannot create a tunnel without automatic DNS CNAME record creation |
| FEAT-02 | `--protected` flag: no programmatic way to enable Cloudflare Access (Zero Trust) — DEFERRED to future release |
| FEAT-03 | `dig` is hard-required but may not exist in minimal containers (Alpine, Distroless) — no fallback |

---

## Root Cause Analysis: YAML `*` wildcard

### Context

Running `cftunnel add --hostname *.homelaberson.space --type http --service http://localhost:80` produced:

```
error parsing YAML ... yaml: line 12: did not find expected alphabetic or numeric character
```

### Generated YAML (broken)

```yaml
ingress:
  - hostname: *.homelaberson.space    # ← line 12
    service: http://localhost:80
```

### Root cause

In YAML, `*` is a reserved indicator character for **alias nodes** (references to previously defined anchors, e.g., `*my_alias`). The YAML parser interprets `*` as the start of an alias reference and expects an alphabetic/numeric identifier immediately after it. The `.` (dot) in `*.homelaberson.space` is not valid, hence the parse error.

### Fix

Any YAML scalar starting with `*`, `&`, `!`, `{`, `[`, `>`, `|`, `%`, `@`, `` ` `` must be quoted to be treated as a literal string:

```yaml
ingress:
  - hostname: "*.homelaberson.space"  # quoted → literal string
    service: "http://localhost:80"    # quoted defensively (same class)
```

### Affected code

- `run.sh:163` — `${HOSTNAME}` → `"${HOSTNAME}"` ✅ already fixed in-session
- `run.sh:164` — `${SERVICE}` → `"${SERVICE}"` — to be fixed in this change set

---

## Code Review Findings

> Full code review is documented in the session log. This section extracts actionable items only.

### `run.sh`

#### 1. Duplicated comment blocks (lines 13-35)
Lines 13-23 and 25-35 contain near-identical blocks explaining TCP/UDP tunnel behavior. Keep one, remove the other.

#### 2. `HOSTNAME` is a reserved bash variable
`$HOSTNAME` is a bash built-in (contains the system hostname). The script overwrites it with the `--hostname` argument, but any subshell or sourced script that references `HOSTNAME` before the local override will get the system value. Rename to `TUNNEL_HOSTNAME`.

#### 3. `CLOUDFLARED_BIN` captured but never used
Line 40 captures `$(command -v cloudflared || true)` into `CLOUDFLARED_BIN`, but all subsequent calls use bare `cloudflared` (relying on PATH). Either use the variable consistently or remove the capture.

#### 4. Unquoted `${SERVICE}` in heredoc (BUG-02)
See root cause analysis above. Same class as the HOSTNAME YAML bug.

#### 5. Missing `connectTimeout` in originRequest
The YAML template does not set `connectTimeout`. Cloudflared defaults to 30s. An explicit `10s` provides faster failure feedback for local services and documents intent.

#### 6. YAML files not permission-locked (SEC-01)
After `cat > "$YAML" <<YAML`, the file gets default umask permissions (`664` on this system). Should be `chmod 600` to match the security docs recommendation.

#### 7. `dig` dependency without fallback (FEAT-03)
`op_add` calls `dig @1.1.1.1 +short` at lines 175 and 208 without checking availability. In minimal environments (Alpine containers, Distroless), `dig` is not installed.

#### 8. Missing `--no-dns` feature flag (FEAT-01)
Users managing DNS via infrastructure-as-code (Terraform, Pulumi, Ansible) cannot use `op_add` without the script touching DNS.

#### 9. Poorly formatted `while/case` one-liners (lines 397-443)
The `start|stop|status|logs` argument parsers compress `while; do case; ... esac; done` into 1-2 lines with no indentation. Functionally correct, unmaintainable.

#### 10. Missing strategic comments
The script has comments describing *what* ("1) Criar túnel") but not *why*. A header documenting the `op_add` pipeline flow, YAML field rationale, and fallback logic improves maintainability.

### `install.sh`

#### 11. Systemd template has no sandbox directives (SEC-02)
The generated `cloudflared@.service` is minimal. Cloudflared runs with full user privileges — can write anywhere in the home directory, create network sockets of any family, and escalate privileges. systemd provides directives to restrict this without affecting cloudflared functionality.

### `uninstall.sh`

#### 12. Does not stop tunnels before removing template (BUG-03)
`remove_systemd_template()` says "Isso também parará todos os túneis em execução" but only removes the template file via `sudo rm -f`. Running `cloudflared@*` instances are unaffected. The template removal prevents future starts but leaves current processes orphaned. User sees "removido" but tunnels are still running.

### `cf-ssh-diagnose.zsh`

#### 13. Typo in redact function (BUG-04)
Line 74: `REDAED` → should be `REDACTED`. Affects only the dump file annotation, not security.

---

## Change Proposals

### CP-01: Remove duplicated TCP/UDP comment block
- **File:** `run.sh`
- **Lines:** 13-35
- **Action:** Keep lines 13-23 (first block), delete lines 25-35 (duplicate). Re-number remaining lines.

### CP-02: Rename `HOSTNAME` → `TUNNEL_HOSTNAME`
- **File:** `run.sh`
- **Lines:** All references to the `HOSTNAME` variable (declaration, assignment, comparison, heredoc interpolation)
- **Action:** Rename to `TUNNEL_HOSTNAME` to avoid collision with bash built-in. Affects:
  - Variable declarations: `HOSTNAME=""` and `HOSTNAME="${2:-}"`
  - Flag parsing: `--hostname) HOSTNAME=...`
  - All `${HOSTNAME}` expansions in `op_add`, heredoc, `validate_flags_add`
  - Note: `-n "${HOSTNAME:-}"` checks remain structurally identical with new name

### CP-03: Quote `${SERVICE}` in YAML heredoc
- **File:** `run.sh:164`
- **Change:** `service: ${SERVICE}` → `service: "${SERVICE}"`
- **Rationale:** Prevents YAML parse errors when SERVICE contains special characters (`: `, `#`, `&`, etc.)

### CP-04: Add `connectTimeout` to originRequest
- **File:** `run.sh:158-160` (heredoc block)
- **Change:** Insert `  connectTimeout: "10s"` after `keepAliveTimeout: "2m"`
- **Rationale:** Explicit timeout; faster fail on unreachable origin; documented intent

### CP-05: `chmod 600` on generated YAML
- **File:** `run.sh:166` (after heredoc)
- **Change:** Add `chmod 600 "$YAML"` after the `cat > "$YAML" <<YAML` block
- **Rationale:** Matches security docs recommendation; prevents group read

### CP-06: DNS resolution with fallback
- **File:** `run.sh`
- **New function:** `resolve_hostname()` — three-tier resolution:
  1. `dig @1.1.1.1 +short` (best — shows CNAME, validates cfargotunnel.com)
  2. `host` (shows CNAME, same package as dig)
  3. `getent ahosts` (fallback — returns IPs only, no CNAME info)
- **Replacements:**
  - Line 175: `dig @1.1.1.1 +short "$HOSTNAME"` → `resolve_hostname "$TUNNEL_HOSTNAME"`
  - Line 208: `dig @1.1.1.1 +short "$HOSTNAME"` → `resolve_hostname "$TUNNEL_HOSTNAME"`
- **Behavior:** When `getent` is the fallback, emit a warning that CNAME verification is unavailable but DNS resolved correctly. The `cfargotunnel.com` check is skipped gracefully (no false negatives).

### CP-07: `--no-dns` flag
- **File:** `run.sh`
- **Scope:** `op_add` function, argument parser
- **Behavior:**
  - When `--no-dns` is passed, skip:
    1. DNS existence check (lines 173-189)
    2. `cloudflared tunnel route dns` (lines 191-198)
    3. DNS propagation wait (lines 200-227)
  - Tunnel, YAML, systemd are created normally.
  - Emit an informational message: "DNS não foi configurado. Crie o registro CNAME manualmente: <uuid>.cfargotunnel.com → ${TUNNEL_HOSTNAME}"
- **Flag declaration:** `NO_DNS=false`
- **Parser addition:** `--no-dns) NO_DNS=true; shift;;`

### CP-08: Add strategic comments
- **File:** `run.sh`
- **Header block (after set -euo pipefail):** Document the `op_add` pipeline flow
- **Heredoc block:** Annotate YAML fields with rationale
- **`slugify()`:** Document that it sanitizes for systemd unit name constraints
- **`resolve_hostname()`:** Document the three-tier strategy and limitations

### CP-09: Reformat `while/case` one-liners
- **File:** `run.sh:397-443`
- **Action:** Reformat `start|stop|status|logs` handlers to use proper multi-line indentation:
  ```bash
  start)
      while [[ $# -gt 0 ]]; do
          case "$1" in
              --name) NAME="${2:-}"; shift 2 ;;
              *) print_usage; exit 1 ;;
          esac
      done
      op_start
      ;;
  ```

### CP-10: Use `CLOUDFLARED_BIN` consistently
- **File:** `run.sh`
- **Action:** Replace bare `cloudflared` calls in `op_add`, `op_remove`, `op_list` with `$CLOUDFLARED_BIN`
- **Lines affected:** 135, 137, 144, 170, 279, 317

### CP-11: Systemd hardening directives (tier 1)
- **File:** `install.sh` (and the installed template at `/etc/systemd/system/cloudflared@.service`)
- **Additions to `[Service]` section:**
  ```ini
  NoNewPrivileges=true
  PrivateTmp=true
  RestrictAddressFamilies=AF_INET AF_INET6
  RestrictRealtime=true
  MemoryMax=256M
  LimitNOFILE=65536
  Restart=on-failure
  RestartSec=2
  StartLimitIntervalSec=30
  StartLimitBurst=5
  ```
- **Rationale per directive:**
  - `NoNewPrivileges=true` — prevents setuid/setgid/capability escalation
  - `PrivateTmp=true` — isolates /tmp per service instance
  - `RestrictAddressFamilies=AF_INET AF_INET6` — cloudflared only needs IP sockets (no UNIX, NETLINK, etc.)
  - `RestrictRealtime=true` — prevents realtime scheduling abuse
  - `MemoryMax=256M` — hard ceiling; cloudflared idles at ~30-50 MB
  - `LimitNOFILE=65536` — file descriptor ceiling for concurrent connections
  - `Restart=on-failure` — only restart on crash, not on clean stop (vs. `always`)
  - `StartLimitIntervalSec=30` + `StartLimitBurst=5` — cap restart storm at 5 failures in 30s
- **Impact:** Zero functional change for normal operation. Only restricts abnormal/compromised behavior.

### CP-12: Stop tunnels before removing systemd template
- **File:** `uninstall.sh:170-190`
- **Change:** Add `sudo systemctl stop 'cloudflared@*' 2>/dev/null || true` before `sudo rm -f "$SYSTEMD_TEMPLATE"`
- **Rationale:** Ensures running tunnels are actually terminated when the user agrees to removal

### CP-13: Fix typo in `redact()` function
- **File:** `cf-ssh-diagnose.zsh:74`
- **Change:** `REDAED` → `REDACTED`
- **Impact:** Cosmetic only; affects dump file annotation

### CP-14: Refresh documentation to reflect all changes
- **Files:** `README.md`, `docs/DOCS.md`, `docs/CLOUDFLARE.md`
- **Scope:** Update all three docs so they accurately describe the tool as it stands after CFTUNNEL-001 — no "before/after" annotations, just correct current state
- **Changes per file:**

  **`README.md`:**
  - Update YAML example to include `connectTimeout` and quoted hostname
  - Add `--no-dns` to the flags table and examples
  - Update the systemd service example to include hardening directives
  - Update the prerequisites section to note that `dig` is optional (fallback to `getent` built-in)
  - Update the security section to mention `chmod 600` enforcement and systemd sandboxing

  **`docs/DOCS.md`:**
  - Update YAML config example with `connectTimeout: "10s"` in the originRequest block
  - Quote hostname in the ingress example: `"*.example.com"`
  - Add `--no-dns` to CLI Reference table
  - Update systemd service section to reflect hardening directives (`NoNewPrivileges`, `PrivateTmp`, `Restart=on-failure`, etc.)
  - Update the Security section to mention `chmod 600` auto-applied and systemd sandboxing
  - Update troubleshooting: add note that `dig` is optional; `getent ahosts` works as fallback
  - Update the prerequisites table: mark `dig` as optional

  **`docs/CLOUDFLARE.md`:**
  - Fix example commands from `./run.sh` to `cftunnel` (consistent with install.sh symlink)
  - Update the DNS section to mention Cloudflare resolver (`@1.1.1.1`) is used for verification by default

- **Impact:** Documentation stays truthful. No functional changes.

---

## Risk Assessment

### Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Systemd hardening breaks cloudflared startup | Low | High | Directives selected are conservative (tier 1 only). Tested common path: cloudflared needs IP sockets (AF_INET/AF_INET6) and reads files from home dir. Does not need setuid, realtime, or temp file sharing. |
| `${TUNNEL_HOSTNAME}` rename misses a reference | Medium | Medium | Grep for all `HOSTNAME` occurrences in `run.sh` before and after. The rename is exact-string — no substring collisions possible. |
| `getent ahosts` fails in musl-based distros | Low | Low | `getent ahosts` is POSIX and glibc/musl both implement it. The function wraps in `2>/dev/null || echo ""` — graceful degradation. |
| `Restart=on-failure` changes expected behavior | Low | Low | `always` restarts even on `systemctl stop` (the stop is overridden by restart). `on-failure` is the correct semantic: stop stays stopped, crash recovers. |
| `--no-dns` flag breaks tunnel routing | None | N/A | Tunnel + YAML + systemd are created normally. Without DNS, the tunnel simply has no public route — intentional and documented. |

### Breaking Changes

**None.** All changes are additive or modify internal behavior without changing the CLI interface:
- `--no-dns` is a new optional flag (absent → existing behavior)
- Systemd hardening does not change the service API (`systemctl start/stop` still works)
- YAML changes (quotes, connectTimeout) are backward-compatible with cloudflared
- Variable rename is internal

---

## Test Plan

### Pre-deployment tests

1. **YAML validity** — Run `cloudflared tunnel --config $YAML ingress validate` on:
   - Hostname: `*.example.com` (wildcard → quoted)
   - Hostname: `example.com` (normal → still works)
   - Service: `http://localhost:80` (simple)
   - Service: `ssh://localhost:2222` (colon in URL)
   - Service: `tcp://localhost:6379` (colon in URL)

2. **systemd hardening** — After installing new template:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl cat cloudflared@test-tunnel  # verify directives present
   ```

3. **DNS fallback** — Simulate absence of `dig`:
   ```bash
   # Verify resolve_hostname() works without dig
   PATH=/usr/bin:/bin resolve_hostname "example.com"
   ```

4. **`--no-dns` flag** — Create tunnel with `--no-dns`, verify:
   - Tunnel UUID + YAML created ✓
   - No DNS record created ✓
   - Systemd service running ✓
   - Warning message displayed ✓

5. **`chmod 600`** — Verify generated YAML:
   ```bash
   stat -c "%a" ~/.cloudflared/*.yml  # should all be 600 or 400
   ```

6. **uninstall with running tunnels** — 
   ```bash
   sudo systemctl start cloudflared@test-tunnel
   ./uninstall.sh --force
   # Verify: systemctl is-active cloudflared@test-tunnel → inactive
   ```

### Regression tests

1. `bash -n run.sh` — syntax check
2. `cftunnel list` — still works
3. `cftunnel add --hostname test.example.com --type http --service http://localhost:9999` — full happy path
4. `cftunnel remove --name test-example-com-http` — cleanup works
5. Existing tunnels (`homelab-proxy`, `testes-lat-http`) unaffected — no config migration needed

---

## Out of Scope

| Item | Reason |
|------|--------|
| `--protected` / Cloudflare Access integration | Requires API token architecture, Account ID management, policy modeling. Scoped for CFTUNNEL-002. |
| `noTLSVerify: false` explicit in YAML | Already the default; explicit declaration adds documentation value only. |
| Systemd tier 2 hardening (`ProtectSystem=strict`, `ProtectHome=read-only`) | Requires real-world testing to confirm cloudflared doesn't write to unexpected paths. Deferred to CFTUNNEL-003. |
| Shared library `lib/common.sh` | Architectural refactor — extract common functions from 3 scripts. Separate issue. |
| GPG/checksum verification on download | Requires parsing GitHub release assets. Complex, high effort, low immediate risk. |
| Logo compression (6.3 MB → <500 KB) | No functional impact. |
| CHANGELOG.md update | Will be updated in the release commit, not as part of this implementation pass. |

---

## Rollback Plan

All changes are reversible:

1. **Systemd template:** Reinstall old template via `install.sh` from the previous git commit
2. **`run.sh`:** `git checkout HEAD~1 -- run.sh`
3. **`uninstall.sh`:** `git checkout HEAD~1 -- uninstall.sh`
4. **`cf-ssh-diagnose.zsh`:** `git checkout HEAD~1 -- cf-ssh-diagnose.zsh`
5. **Docs:** `git checkout HEAD~1 -- README.md docs/DOCS.md docs/CLOUDFLARE.md`

No database migrations, no API changes, no external state to roll back.

---

## Acceptance Criteria

- [ ] `run.sh` generates valid YAML for wildcard hostnames (`*.domain.com`)
- [ ] `run.sh` generates valid YAML for services with colons (`ssh://localhost:22`)
- [ ] `resolve_hostname()` works with `dig` present (full CNAME verification)
- [ ] `resolve_hostname()` works with `host` present (fallback CNAME verification)
- [ ] `resolve_hostname()` works with only `getent ahosts` (graceful degradation)
- [ ] `--no-dns` flag skips DNS creation and propagation, tunnel still works
- [ ] `chmod 600` applied to generated YAML files
- [ ] `bash -n run.sh` passes (no syntax errors)
- [ ] `cloudflared tunnel --config <test>.yml ingress validate` passes for all tunnel types
- [ ] `uninstall.sh --force` stops running tunnels before removing template
- [ ] Systemd template includes all tier 1 hardening directives
- [ ] Existing tunnels (`homelab-proxy`, `testes-lat-http`) continue to function
- [ ] `cftunnel list` output unchanged
- [ ] All comments removed lines 13-35 (duplicate block) removed
- [ ] Strategic comments added: `op_add` flow, YAML fields, `slugify`, `resolve_hostname`
- [ ] No remaining references to bare `HOSTNAME` variable (all renamed to `TUNNEL_HOSTNAME`)
- [ ] Typo `REDAED` fixed in `cf-ssh-diagnose.zsh`
- [ ] `README.md` — YAML example includes `connectTimeout`, quoted hostname, hardening directives; `--no-dns` in flag table; `dig` marked optional
- [ ] `docs/DOCS.md` — YAML config, CLI reference, systemd section, security section updated; troubleshooting updated for `getent` fallback
- [ ] `docs/CLOUDFLARE.md` — example commands use `cftunnel` consistently; DNS section mentions Cloudflare resolver
