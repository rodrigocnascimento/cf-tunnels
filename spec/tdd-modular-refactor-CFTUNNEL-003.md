# Technical Design Document — CFTUNNEL-003

> **Issue:** CFTUNNEL-003
> **Title:** Refactor monolithic run.sh into modular library files
> **Version:** 0.3.0 (no bump — structural only)
> **Status:** Draft
> **Date:** 2026-06-02
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Design Goals](#design-goals)
3. [Module Architecture](#module-architecture)
4. [Function Migration Map](#function-migration-map)
5. [Variable Scope Strategy](#variable-scope-strategy)
6. [Sourcing Guard](#sourcing-guard)
7. [Edge Cases](#edge-cases)
8. [Execution Plan](#execution-plan)
9. [Test Plan](#test-plan)
10. [Acceptance Criteria](#acceptance-criteria)

---

## 1. Problem Statement

`run.sh` grew to ~1100 lines containing all logic: CLI parsing, Cloudflare wrappers,
DNS resolution, systemd management, YAML generation, zone state, and validation.
This monolithic structure creates:

| Problem | Impact |
|---------|--------|
| Single file, no module boundaries | Impossible to reason about dependencies |
| Mixed concerns | DNS helpers interleaved with `op_add` business logic |
| Test fragility | All 44 tests source the entire `run.sh` — any change risks side effects |
| Onboarding friction | New contributor must grok 1100 contiguous lines |
| No isolation | Editing `slugify()` could theoretically break `op_zone()` via shared scope |
| Diff noise | A fix in one area touches the same file as unrelated features |

### Root Cause

The project started as a single-script CLI and grew organically. Each new feature
(`add`, `remove`, `list`, `zone`, `dns`) was appended to the same file. No
refactoring was done because the project was in active feature development with
frequent pivots.

---

## 2. Design Goals

1. **Zero API change** — every `cftunnel <subcommand>` flag and behavior is identical
2. **Zero install change** — `./install.sh` continues to symlink `run.sh`; no new dependencies
3. **Backward-compatible sourcing** — `run.sh` sources libs; tests sourcing `run.sh` still work
4. **Each module < 300 lines** — focused, testable, replaceable
5. **Explicit dependency graph** — functions only access their own module + direct deps
6. **Sourcing guards** — each module can be sourced multiple times safely

---

## 3. Module Architecture

```
run.sh (entry point — ~200 lines: parser + dispatcher)
├── lib/common.sh          (~20 lines)  — die, need, slugify
├── lib/cloudflared.sh     (~70 lines)  — cloudflared() wrapper, version check, update
├── lib/dns.sh             (~35 lines)  — resolve_hostname, has_cname_lookup
├── lib/zone.sh            (~140 lines) — zone state, zone_base_dir, op_zone
└── lib/tunnel.sh          (~440 lines) — op_add, op_remove, op_list, YAML, systemd ops, flags
```

### Dependency Graph

```
common.sh (no deps)
├── dns.sh         (common)
├── cloudflared.sh (common)
│   ├── zone.sh    (common, cloudflared)
│   └── tunnel.sh  (common, cloudflared, zone)
└── run.sh (parser) sources all of the above
```

### Directory Layout After Refactor

```
~/.cloudflared/                      (unchanged)
├── run.sh                           (dispatcher — sources lib/*)
├── lib/
│   ├── common.sh
│   ├── cloudflared.sh
│   ├── dns.sh
│   ├── zone.sh
│   └── tunnel.sh
├── install.sh                       (unchanged)
├── uninstall.sh                     (unchanged)
├── prompt-hook.sh                   (unchanged)
├── tests/                           (unchanged)
└── spec/                            (unchanged)
```

---

## 4. Function Migration Map

### `lib/common.sh`

| Function | Source Lines | Notes |
|----------|-------------|-------|
| `die()` | 55-58 | Error + exit |
| `need()` | 59 | Dependency check |
| `slugify()` | 64-66 | Normalize names for systemd |

### `lib/cloudflared.sh`

| Function | Source Lines | Notes |
|----------|-------------|-------|
| `cloudflared()` | 43-49 | Wrapper with `--origincert` + outdated JSON filter |
| `check_cloudflared_version()` | 419-446 | Version probe + interactive update prompt |
| `update_cloudflared()` | 371-417 | Self-update (download, install, verify) |

### `lib/dns.sh`

| Function | Source Lines | Notes |
|----------|-------------|-------|
| `resolve_hostname()` | 186-205 | 3-tier DNS resolution (dig → host → getent) |
| `has_cname_lookup()` | 209-211 | Guard for `cfargotunnel.com` CNAME validation |

### `lib/zone.sh`

| Function | Source Lines | Notes |
|----------|-------------|-------|
| `zone_base_dir()` | 71-77 | Base path for current zone |
| `load_default_zone()` | 84-104 | Read `.default_zone` |
| `save_default_zone()` | 107-123 | Write `.default_zone` |
| `unset_default_zone()` | 126-128 | Remove `.default_zone` |
| `validate_zone_name()` | 131-139 | Sanitize zone name |
| `zone_metadata_file()` | 142-144 | Zone metadata path |
| `ensure_zone_dir()` | 147-151 | Create zone directory |
| `op_zone()` | 283-367 | `zone use/current/unset/login/list` |

### `lib/tunnel.sh`

| Function | Source Lines | Notes |
|----------|-------------|-------|
| `ensure_template()` | 153-158 | Check systemd template exists |
| `instance_unit()` | 160-167 | Systemd unit name with zone |
| `yaml_path()` | 169-173 | YAML file path |
| `json_path_for_uuid()` | 175-179 | Credentials file path |
| `validate_flags_add()` | 252-277 | Flag validation for `add` |
| `op_add()` | 449-661 | Full tunnel creation flow (~210 lines) |
| `op_remove()` | 664-713 | Tunnel removal |
| `op_start()` | 715-719 | systemctl enable --now |
| `op_stop()` | 721-725 | systemctl disable --now |
| `op_status()` | 727-731 | systemctl status |
| `op_logs()` | 733-737 | journalctl follow |
| `op_list()` | 740-861 | Tunnel listing with zone filtering |

### `run.sh` (dispatcher — ~200 lines)

The entry point retains:
- Shebang + `set -euo pipefail`
- Default config vars (`RUN_USER`, `HOME_DIR`, `CLOUDFLARED_BIN`, `BASE_DIR`, `SYSTEMD_TPL`, `DEFAULT_ZONE_FILE`)
- Module sourcing (in dependency order)
- `ZONE=""` initialization
- 2-pass argument parser (first pass: `--zone`/`--persist`; second pass: command flags)
- Default zone loading
- `--persist` and zone-change prompt logic
- Version check gate
- Main `case` dispatch block (untouched)
- `CFTUNNEL_SKIP_MAIN=1` guard for test sourcing

---

## 5. Variable Scope Strategy

### Global Variables (set in `run.sh`)

| Variable | Purpose | Set Where |
|----------|---------|-----------|
| `CLOUDFLARED_BIN` | cloudflared path | `run.sh` (`command -v`) |
| `HOME_DIR` | User home | `run.sh` (`getent passwd`) |
| `RUN_USER` | Effective user | `run.sh` |
| `BASE_DIR` | `~/.cloudflared` | `run.sh` |
| `SYSTEMD_TPL` | Template path | `run.sh` |
| `DEFAULT_ZONE_FILE` | `.default_zone` path | `run.sh` |
| `ZONE` | Active zone | Parser (first pass) |
| `PERSIST_ZONE` | Persist flag | Parser (first pass) |
| `NAME`, `TUNNEL_HOSTNAME`, `TYPE`, `SERVICE`, `NO_DNS` | Command flags | Parser (second pass) |

### Module State

All module-internal state uses `local` variables. No module exports globals.
The cloudflared wrapper reads `$ZONE` (global) to select `--origincert` path.

---

## 6. Sourcing Guard

Each module file starts with a guard to prevent double sourcing:

```bash
# lib/common.sh
[[ -z "${_CFTUNNEL_COMMON_LOADED:-}" ]] || return 0
_CFTUNNEL_COMMON_LOADED=1
```

This allows:
- Tests to source individual modules without conflict
- `run.sh` to source all modules safely
- Modules that depend on other modules to import their deps explicitly

### Guard Names

| Module | Guard Variable |
|--------|---------------|
| `common.sh` | `_CFTUNNEL_COMMON_LOADED` |
| `cloudflared.sh` | `_CFTUNNEL_CLOUDFLARED_LOADED` |
| `dns.sh` | `_CFTUNNEL_DNS_LOADED` |
| `zone.sh` | `_CFTUNNEL_ZONE_LOADED` |
| `tunnel.sh` | `_CFTUNNEL_TUNNEL_LOADED` |

---

## 7. Edge Cases

| Case | Handling |
|------|----------|
| `lib/` directory missing | `source` fails with clear bash error |
| Old `run.sh` symlinked as `cftunnel` | No change — symlink resolution is unchanged |
| User sources `run.sh` directly (e.g., `source run.sh`) | Works — `run.sh` now sources libs + dispatches |
| Module loads in wrong order | Guard prevents re-source; but `cloudflared.sh` depends on `$CLOUDFLARED_BIN` being set (by `run.sh`) |
| Existing tests source `run.sh` with `CFTUNNEL_SKIP_MAIN=1` | Works — libs are sourced, functions defined, main skipped |
| `set -euo pipefail` in sourced libs | NOT included in lib files to avoid re-applying; caller is responsible |
| Backward compat with no-zone mode | All modules handle empty `$ZONE` gracefully |

---

## 8. Execution Plan

1. Create `lib/` directory
2. Create `lib/common.sh` — extract `die()`, `need()`, `slugify()`
3. Create `lib/dns.sh` — extract `resolve_hostname()`, `has_cname_lookup()`
4. Create `lib/cloudflared.sh` — extract `cloudflared()`, `check_cloudflared_version()`, `update_cloudflared()`
5. Create `lib/zone.sh` — extract zone state functions + `op_zone()`
6. Create `lib/tunnel.sh` — extract all tunnel operations + helpers
7. Rewrite `run.sh` — keep only config vars, module sourcing, parser, and dispatcher
8. Syntax check: `bash -n run.sh lib/*.sh`
9. Test suite: `cd tests && ./run.sh` (expect 44/44)
10. Manual smoke test: `cftunnel list`

### Function Extraction Method

For each function, I will:
1. Copy the exact function body from `run.sh` to the target module file
2. Remove the function from `run.sh`
3. Add sourcing guard to module

This ensures zero logic changes — pure structural refactoring.

---

## 9. Test Plan

### Pre-existing Tests (must pass with no changes)

| File | Tests | What It Covers |
|------|-------|----------------|
| `tests/test_functions.sh` | 11 | `die()`, `need()`, `cloudflared()` wrapper, `resolve_hostname()`, `has_cname_lookup()`, `slugify()`, `instance_unit()`, `yaml_path_for()`, `json_path_for_uuid()`, `zone_base_dir()` |
| `tests/test_zones.sh` | 12 | Zone state: default zone file, `validate_zone_name()`, `zone login` listing |
| `tests/test_parser.sh` | 12 | Argument parsing: `--zone` extraction, zone persistence, flag validation |
| `tests/test_yaml.sh` | 5 | YAML generation with zone paths, credentials path |
| `tests/test_prompt.sh` | 4 | Prompt hook sourcing behavior |

**Verification:** `cd tests && ./run.sh` — all 44 must pass.

### Post-Refactor Testing Strategy

- Existing tests continue to source `run.sh` (backward compatible)
- New tests may source individual lib modules for isolation
- **No new tests required** for this refactor — zero API/behavior change

---

## 10. Acceptance Criteria

- [ ] `bash -n run.sh lib/*.sh` — zero syntax errors
- [ ] `cd tests && ./run.sh` — all 44 tests pass
- [ ] `cftunnel --help` shows correct usage
- [ ] `cftunnel list` shows the same output as before (same data, same formatting)
- [ ] Each module has sourcing guard
- [ ] No duplicate function definitions (`grep -c '^[a-z_]*()'` check)
- [ ] `run.sh` < 250 lines (was 1120)
- [ ] All lib modules combined preserve all original functions
- [ ] `install.sh` and `uninstall.sh` unchanged
- [ ] `prompt-hook.sh` unchanged
- [ ] `tests/` directory and test helpers unchanged
