# Technical Design Document — CFTUNNEL-002

> **Issue:** CFTUNNEL-002
> **Title:** Profile → Zone Pivot
> **Version:** 0.3.0-rc → 0.3.0
> **Status:** Draft (awaiting review)
> **Date:** 2026-06-01
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Root Cause Analysis](#root-cause-analysis)
4. [Architecture Changes](#architecture-changes)
5. [Code Changes](#code-changes)
6. [CLI Changes](#cli-changes)
7. [Test Plan](#test-plan)
8. [Migration Guide](#migration-guide)
9. [Risk Assessment](#risk-assessment)
10. [Out of Scope](#out-of-scope)
11. [Rollback Plan](#rollback-plan)
12. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

Pivot the existing profile isolation feature from an abstract "profile" concept to a concrete **"zone"** concept that mirrors Cloudflare's zone structure. This resolves the multi-zone `cert.pem` problem naturally by binding each zone to its own certificate, directory, and tunnels.

### Files in scope

| File | Changes | Category |
|------|---------|----------|
| `run.sh` | Rename profile→zone, add `zone login`, `--origincert` wrapper | Core refactor |
| `install.sh` | Update systemd template: `profiles/` → `zones/` | Template update |
| `uninstall.sh` | No structural changes (markers remain generic) | — |
| `prompt-hook.sh` | `CFTUNNEL_PROFILE` → `CFTUNNEL_ZONE`, `.default_profile` → `.default_zone` | Rename |
| `tests/` | Rename all profile tests to zone tests, add `zone login` tests | Test suite |
| `README.md` | Update all profile references to zone | Documentation |
| `docs/DOCS.md` | Update architecture, CLI reference, examples | Documentation |
| `docs/MIGRATION.md` | Profile → Zone migration guide | Documentation |
| `CHANGELOG.md` | Add zone pivot entry | Documentation |
| `AGENTS.md` | Update conventions and architecture | Documentation |

---

## Problem Statement

The profile system (v0.3.0-rc) uses abstract names like `homelab` that have no relationship to Cloudflare zones. When a user has multiple zones (`homelaberson.space`, `testes.lat`) in the same Cloudflare account, `cloudflared tunnel route dns` uses the `cert.pem`'s implicit zone context, resulting in incorrect DNS records like `hostname.testes.lat` appended to `homelaberson.space` hostnames.

### Bugs discovered

| ID | Severity | Description |
|----|----------|-------------|
| BUG-01 | High | `cert.pem` is global — all tunnels share the same zone context, causing DNS routes to be created in the wrong zone |
| BUG-02 | Medium | Abstract profiles (`homelab`, `work`) are decoupled from DNS zones — no validation that hostname belongs to profile's domain |

### Why "Zone" is better than "Profile"

| Aspect | Profile (old) | Zone (new) |
|--------|---------------|------------|
| Concept | Local abstraction | Real Cloudflare entity |
| `cert.pem` | Global, disconnected | Bound per zone directory |
| DNS | Wrong zone suffix bug | Resolved naturally |
| Directory | `profiles/<slug>/` | `zones/<domain>/` |
| Comandos | `profile use` | `zone use`, `zone login` |

---

## Root Cause Analysis

### Multi-zone `cert.pem` conflict

`cloudflared` uses `~/.cloudflared/cert.pem` for both authentication **and** zone context. The `tunnel route dns` command creates CNAMEs in the zone authenticated by `cert.pem`. When a user has authenticated against `testes.lat` but wants to create a tunnel for `homelaberson.space`, the DNS record gets created as `hostname.homelaberson.space.testes.lat`.

### Fix

Bind each directory to a **real Cloudflare zone**:
- Directory name = zone name (e.g., `zones/homelaberson.space/`, `zones/testes.lat/`)
- Each zone has its own `cert.pem`
- The `cloudflared` wrapper automatically selects `--origincert` based on active zone
- New command: `cftunnel zone login` — authenticates and saves `cert.pem` to the active zone directory

---

## Architecture Changes

### Directory Structure

```
~/.cloudflared/
├── cert.pem                              # Fallback/default cert
├── .default_zone                          # Stores active zone name
├── zones/
│   ├── homelaberson.space/
│   │   ├── cert.pem                       # Zone-specific cert
│   │   ├── <uuid>.json
│   │   ├── <tunnel>.yml
│   │   └── zone.json                      # Metadata (optional)
│   └── testes.lat/
│       ├── cert.pem
│       ├── <uuid>.json
│       ├── <tunnel>.yml
│       └── zone.json
```

### Unit Naming

```bash
# Without zone:
cloudflared@<tunnel>.service

# With zone:
cloudflared@<zone-slug>_<tunnel>.service
```

Example:
- Zone: `homelaberson.space` → slug: `homelaberson-space`
- Tunnel: `nas`
- Unit: `cloudflared@homelaberson-space_nas.service`

### Systemd Template

The template detects `_` and resolves:
```bash
NAME=homelaberson-space_nas
ZONE=${NAME%%_*}      # homelaberson-space
TUNNEL=${NAME#*_}     # nas
CONFIG="$HOME/.cloudflared/zones/${ZONE}/${TUNNEL}.yml"
```

---

## Code Changes

### Variable/Function Renames

| Old (Profile) | New (Zone) |
|---------------|------------|
| `PROFILE` | `ZONE` |
| `PERSIST_PROFILE` | `PERSIST_ZONE` |
| `profile_base_dir()` | `zone_base_dir()` |
| `load_default_profile()` | `load_default_zone()` |
| `save_default_profile()` | `save_default_zone()` |
| `unset_default_profile()` | `unset_default_zone()` |
| `validate_profile_name()` | `validate_zone_name()` |
| `profile_metadata_file()` | `zone_metadata_file()` |
| `ensure_profile_dir()` | `ensure_zone_dir()` |
| `load_profile_primary_domain()` | *(removed)* |
| `save_profile_primary_domain()` | *(removed)* |
| `op_profile()` | `op_zone()` |
| `--profile` | `--zone` |
| `--persist` | (unchanged) |
| `.default_profile` | `.default_zone` |
| `profiles/` | `zones/` |

### Wrapper `cloudflared()`

```bash
cloudflared() {
    local cert_path="$HOME/.cloudflared/cert.pem"
    if [[ -n "$ZONE" && -f "$HOME/.cloudflared/zones/$ZONE/cert.pem" ]]; then
        cert_path="$HOME/.cloudflared/zones/$ZONE/cert.pem"
    fi
    "$CLOUDFLARED_BIN" --origincert "$cert_path" "$@" 2>&1 | grep -v -i '"outdated"' || true
}
```

### New Command: `zone login`

```bash
cftunnel zone login
```

Behavior:
1. Calls `cloudflared tunnel login` (opens browser for Cloudflare auth)
2. After login, `cert.pem` is created in `~/.cloudflared/`
3. If `ZONE` is active: moves `cert.pem` → `zones/$ZONE/cert.pem`
4. If no zone active: lists existing zones and asks user to choose

---

## CLI Changes

### Commands

| Old | New |
|-----|-----|
| `profile use <name>` | `zone use <name>` |
| `profile current` | `zone current` |
| `profile unset` | `zone unset` |
| *(new)* | `zone login` |
| `--profile <name>` | `--zone <name>` |

### Examples

```bash
# Set default zone
cftunnel zone use homelaberson.space

# Login (saves cert to zone directory)
cftunnel zone login

# Create tunnel in zone (auto-detects cert)
cftunnel add --hostname nas.homelaberson.space --type http --service http://localhost:5000

# Create tunnel in different zone
cftunnel --zone testes.lat add --hostname app.testes.lat --type http --service http://localhost:3000
```

---

## Test Plan

### Pre-deployment tests

1. **Zone base dir** — `zone_base_dir` returns correct path for zone and no-zone
2. **Instance unit** — `instance_unit` returns correct systemd name with `_` separator
3. **Cloudflared wrapper** — `--origincert` points to zone cert when zone is active
4. **Zone login** — Simulates auth and moves cert to correct zone directory
5. **Parser** — `--zone` extracted correctly from any position in arg list
6. **YAML generation** — Credentials path uses `zones/<domain>/` instead of `profiles/<slug>/`
7. **Prompt hook** — Reads `.default_zone` and sets `CFTUNNEL_ZONE`

### Regression tests

1. `bash -n run.sh install.sh uninstall.sh prompt-hook.sh`
2. All 43+ tests pass after rename
3. Legacy mode (no zone) still works — uses `~/.cloudflared/cert.pem`
4. Systemd template resolves both `zone_tunnel` and `tunnel` names

---

## Migration Guide

Since the profile feature branch has **not been merged to main**, this is a pivot, not a breaking change:

1. Rename `profiles/` directories to `zones/` with zone names
2. Rename `.default_profile` to `.default_zone`
3. Update all internal variables `PROFILE` → `ZONE`
4. Re-run tests

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `cloudflared --origincert` not supported in all commands | Low | High | Test each management command before release |
| Zone name with dots in directory name | Low | Low | Use raw domain name; dots are valid in paths |
| User confusion: "Is zone the same as domain?" | Medium | Low | Document clearly: zone = Cloudflare zone = domain name |
| Breaking existing systemd units | Low | High | Template supports both old (`tunnel`) and new (`zone_tunnel`) naming |

---

## Out of Scope

| Item | Reason |
|------|--------|
| Multiple projects within same zone | Overkill — user confirmed |
| Automatic zone detection from hostname | Future enhancement |
| `CF_API_TOKEN` per zone | Future enhancement |
| Migration tool for existing `profiles/` dirs | Branch not merged; manual rename sufficient |

---

## Rollback Plan

Since this is a development-branch pivot:

1. `git checkout HEAD~1 -- run.sh` (restore previous profile version)
2. Or: revert the commit that introduced the pivot
3. No external state to roll back (branch not merged)

---

## Acceptance Criteria

- [ ] `cftunnel zone use homelaberson.space` sets `.default_zone`
- [ ] `cftunnel zone login` authenticates and saves `cert.pem` to `zones/<zone>/`
- [ ] `cftunnel add` with active zone uses `zones/<zone>/cert.pem` via `--origincert`
- [ ] DNS CNAME is created in the correct zone (no `.testes.lat` suffix)
- [ ] `cftunnel list` filters by active zone
- [ ] `cftunnel --zone <name> add ...` works without setting default
- [ ] Without zone (legacy), uses `~/.cloudflared/cert.pem` (backward compatible)
- [ ] All 43+ tests updated and passing
- [ ] `AGENTS.md`, `README.md`, `docs/DOCS.md`, `CHANGELOG.md` updated
- [ ] Systemd template resolves config from `zones/` directory
- [ ] Prompt hook shows zone name instead of profile name
