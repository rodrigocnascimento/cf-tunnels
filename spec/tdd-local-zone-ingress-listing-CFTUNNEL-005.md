# Technical Design Document — CFTUNNEL-005

> **Issue:** CFTUNNEL-005
> **Title:** Local Zone Ingress Listing
> **Version:** 0.3.1 → 0.3.2
> **Status:** Approved (implemented)
> **Date:** 2026-07-18
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Design Goals](#design-goals)
4. [Source of Truth](#source-of-truth)
5. [Proposed Behavior](#proposed-behavior)
6. [Implementation Proposal](#implementation-proposal)
7. [Output Contract](#output-contract)
8. [Test-Driven Delivery Plan](#test-driven-delivery-plan)
9. [Risk Assessment](#risk-assessment)
10. [Out of Scope](#out-of-scope)
11. [Rollback Plan](#rollback-plan)
12. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

`cftunnel list` must report the hostname routes configured locally for the
selected Cloudflare zone. It must not use the account-scoped
`cloudflared tunnel list` command, because Cloudflare tunnels do not carry the
local zone association modeled by this CLI.

The command will use only YAML files under:

```text
~/.cloudflared/zones/<zone>/*.yml
```

When a zone is active, `list` will show that zone. When no zone is active, it
will scan every directory directly below `~/.cloudflared/zones/` and show all
locally configured zone routes. Root-level `~/.cloudflared/*.yml` files are
intentionally excluded.

One tunnel YAML can contain multiple `ingress` hostname rules. The output will
therefore contain one row per hostname/service pair rather than one row per
Cloudflare tunnel object.

### Files expected to change during implementation

| File | Proposed change |
|------|-----------------|
| `lib/tunnel.sh` | Replace the remote, tunnel-centric `op_list()` with local zone YAML enumeration and ingress parsing |
| `lib/cloudflared.sh` | Skip the startup version/API probe for the local-only `list` command |
| `tests/test_list.sh` | Add focused local listing and ingress parsing coverage |
| `tests/run.sh` | Register the new list integration tests |
| `tests/test_parser.sh`, `tests/test_zones.sh` | Update version-check and empty-list expectations |
| `tests/Makefile` | Remove a stale smoke check for the deleted prompt hook |
| `run.sh` | Clarify the `list` help text |
| `README.md`, `docs/DOCS.md`, `docs/MIGRATION.md` | Document local-only route listing and no-zone behavior |
| `docs/SETUP-NEW-DOMAIN.md`, `AGENTS.md`, `CHANGELOG.md` | Update setup examples, repository guidance, and release notes |

Implementation was completed on the CFTUNNEL-005 feature branch after this
proposal was approved.

---

## Problem Statement

The current `op_list()` implementation conflates three different concepts:

1. Cloudflare account tunnels returned by `cloudflared tunnel list`.
2. Local zone membership represented by the YAML directory path.
3. Hostname routes represented by entries under `ingress:`.

These concepts do not have a one-to-one relationship. A single tunnel YAML can
contain many hostname routes, and the Cloudflare tunnel listing is account-wide
rather than zone-aware.

### Confirmed defects

| ID | Severity | Current behavior | Impact |
|----|----------|------------------|--------|
| BUG-01 | High | `op_list()` starts from `cloudflared tunnel list --output json` | Listing depends on Cloudflare credentials/network and receives unrelated account tunnels |
| BUG-02 | High | Hostname parsing executes `exit` after the first `hostname:` | A YAML with five ingress hostnames displays only one |
| BUG-03 | High | With no active zone, `op_list()` searches only `~/.cloudflared/<name>.yml` | It does not implement the documented “all zones” behavior |
| BUG-04 | Medium | `check_cloudflared_version()` probes `cloudflared tunnel list` before dispatching `list` | Removing the API call only from `op_list()` would still leave a hidden remote query |
| BUG-05 | Medium | The `CREATED` column comes from the remote tunnel response | It prevents `list` from being a fully local command |
| BUG-06 | Medium | Hostnames are truncated to fit a fixed-width column | The command can hide the exact route identifier the user asked to list |

### Example of the cardinality problem

```yaml
tunnel: 00000000-0000-0000-0000-000000000000
credentials-file: /home/user/.cloudflared/zones/example.com/tunnel.json

ingress:
  - hostname: "api.example.com"
    service: "http://localhost:9004"
  - hostname: "git.example.com"
    service: "https://127.0.0.1:443"
  - hostname: "*.example.com"
    service: "https://127.0.0.1:443"
  - service: http_status:404
```

This is one tunnel configuration with three hostname routes. `cftunnel list`
must print three rows. The hostname-less `http_status:404` fallback is not a
public hostname route and must not be printed.

---

## Design Goals

1. **Local-only operation** — `cftunnel list` performs no Cloudflare command or
   API request.
2. **Zone-correct results** — an active zone restricts the scan to its directory.
3. **All-zone fallback** — no active zone scans every local zone directory.
4. **Route-correct cardinality** — every ingress hostname/service pair is listed.
5. **No legacy root scan** — `~/.cloudflared/*.yml` is outside the listing model.
6. **No new dependency** — keep the implementation in Bash plus standard tools;
   do not add `yq`.
7. **Safe parsing** — YAML content is treated as data and is never sourced or
   evaluated by the shell.
8. **Useful offline behavior** — listing continues to work without a token,
   certificate, DNS, or network access.
9. **Deterministic output** — zone/config traversal is lexicographically stable.

---

## Source of Truth

The list command will derive each field from local state:

| Output value | Local source |
|--------------|--------------|
| Zone | Parent directory name below `~/.cloudflared/zones/` |
| Tunnel name | YAML filename without `.yml` |
| Hostname | `hostname:` value in an `ingress` rule |
| Service | The `service:` associated with that hostname rule |
| UUID | Top-level `tunnel:` value in the same YAML |
| Unit | `cloudflared@<zone>_<tunnel-name>.service` using the existing convention |
| Status | Local `systemctl is-active` / `is-enabled` result for the unit |

The Cloudflare API, DNS records, `cert.pem`, credential JSON content, and
root-level YAML files are not sources for `cftunnel list`.

This defines the command as: **show routes configured on this host**, not
“discover every route that might exist in the Cloudflare account.”

---

## Proposed Behavior

### Scope selection

| Active `ZONE` value | Files scanned |
|---------------------|---------------|
| Non-empty | `~/.cloudflared/zones/$ZONE/*.yml` |
| Empty | `~/.cloudflared/zones/*/*.yml` |

An empty active zone is already a supported state. It occurs on a fresh setup
without `.default_zone`, or after `cftunnel zone unset` removes that file.

An explicit `--zone <name>` continues to take precedence over the persistent
default loaded from `.default_zone`.

### Exclusion rules

The implementation must not scan:

- `~/.cloudflared/*.yml`
- nested directories deeper than `zones/<zone>/`
- `cert.pem`, credential JSON, or `zone.json`
- YAML ingress rules without a `hostname:`

### Empty results

- Active zone with no hostname routes:
  `No hostname routes found in zone '<zone>'.`
- No active zone and no hostname routes in any zone:
  `No hostname routes found in configured zones.`
- A missing `~/.cloudflared/zones/` directory is treated as an empty result, not
  as a fatal error.

---

## Implementation Proposal

### CP-01: Make startup skip the remote probe for `list`

- **File:** `lib/cloudflared.sh`
- **Function:** `check_cloudflared_version()`
- **Action:** Add `list` to the commands that return before running
  `cloudflared tunnel list --output json`.

This change is required for the “local-only” guarantee. Rewriting `op_list()`
alone is insufficient because `run.sh` invokes `check_cloudflared_version()`
before command dispatch.

### CP-02: Enumerate YAML files from zone directories

- **File:** `lib/tunnel.sh`
- **Function:** `op_list()` and small private helpers if needed
- **Action:** Replace remote tunnel enumeration with NUL-delimited local file
  discovery.

Conceptual discovery logic:

```bash
if [[ -n "$ZONE" ]]; then
    # Only zones/$ZONE/*.yml
else
    # Every zones/*/*.yml, exactly two levels below zones/
fi
```

Use NUL-delimited paths and process substitution so filenames are not split and
the route counter remains in the current shell. Sort paths before display for
stable output.

### CP-03: Parse every ingress hostname/service pair

- **File:** `lib/tunnel.sh`
- **Action:** Add a non-evaluating parser for the generated YAML schema.

Parser rules:

1. Ignore content before the top-level `ingress:` key when extracting routes.
2. Capture each list item’s `hostname:` value.
3. Associate it with the following `service:` in that ingress item.
4. Remove only surrounding YAML quotes from generated scalar values.
5. Preserve wildcard hostnames such as `*.example.com` literally.
6. Ignore service-only rules, including `http_status:404`.
7. Never use `source`, `eval`, or shell interpolation on YAML content.

An `awk` state machine is sufficient for the YAML subset generated by
`op_add()` and avoids introducing `yq`. Service parsing must remove the
`service:` prefix rather than split blindly on `:`, because service URLs contain
colons.

### CP-04: Print one row per route

For each YAML file:

1. Derive zone and tunnel name from its path.
2. Read the top-level tunnel UUID.
3. Derive the systemd unit and calculate its status once.
4. Parse all hostname/service pairs.
5. Print one row for every pair, reusing the tunnel metadata.

`found` counts hostname routes, not YAML files or Cloudflare tunnel objects.

### CP-05: Remove remote-only output and dependencies

- Remove the `CREATED` column because no local creation timestamp is defined.
- Remove `need jq` from `op_list()`.
- Do not require `cloudflared` for the list operation itself.
- Preserve the existing service-column behavior by showing the protocol derived
  from the matching service (`http`, `https`, `ssh`, or `tcp`).
- Do not truncate hostnames. Exact hostnames are operational identifiers and
  must remain visible.

---

## Output Contract

Proposed columns:

```text
ZONE  NAME  HOSTNAME  STATUS  SERVICE  UNIT  UUID
```

Example with one tunnel and three routes:

```text
ZONE         NAME              HOSTNAME             STATUS  SERVICE  UNIT                                      UUID
example.com  example-com-http  api.example.com      active  http     @example.com_example-com-http.service     00000000-0000-0000-0000-000000000000
example.com  example-com-http  git.example.com      active  https    @example.com_example-com-http.service     00000000-0000-0000-0000-000000000000
example.com  example-com-http  *.example.com        active  https    @example.com_example-com-http.service     00000000-0000-0000-0000-000000000000
```

The exact spacing may remain fixed-width, but hostname values must not be
shortened with `...`.

---

## Test-Driven Delivery Plan

Implementation follows a red/green/refactor sequence.

### Phase 1: Add failing tests

Create `tests/test_list.sh`, register it in `tests/run.sh`, and add fixtures for:

1. **Multiple routes in one YAML** — one config with five hostnames produces five
   rows and includes every hostname.
2. **Correct service association** — each hostname reports the protocol from its
   own service, not always the first service in the file.
3. **Catch-all exclusion** — `http_status:404` does not produce a row.
4. **Active-zone isolation** — with two zone directories, a non-empty `ZONE`
   prints only routes from the selected zone.
5. **No-zone aggregation** — with `ZONE=""`, routes from both zone directories
   are printed.
6. **Root YAML exclusion** — a YAML at `~/.cloudflared/ignored.yml` is never
   printed.
7. **Long/wildcard hostname preservation** — exact values are visible without
   truncation or wildcard expansion.
8. **Empty active zone** — prints the zone-specific empty message and exits zero.
9. **No configured zones** — prints the all-zone empty message and exits zero.
10. **No Cloudflare invocation** — the full `cftunnel list` path succeeds with an
    instrumented `cloudflared` mock that fails the test if called.
11. **No `jq` dependency for list** — direct list behavior succeeds when `jq` is
    unavailable to `op_list()`.
12. **Deterministic ordering** — output is ordered by zone, YAML name, then ingress
    order within the YAML.

These tests must fail against the current implementation for the expected
reasons before production code is changed.

### Phase 2: Minimal implementation

1. Skip `list` in `check_cloudflared_version()`.
2. Add zone YAML discovery.
3. Add safe ingress pair parsing.
4. Render the local-only table and empty messages.
5. Remove remote-only list dependencies and columns.

### Phase 3: Refactor and regression verification

1. Keep file discovery and parsing helpers small and independently testable.
2. Run `bash -n run.sh lib/*.sh tests/*.sh`.
3. Run `cd tests && ./run.sh --verbose`.
4. Run Makefile smoke/unit/integration/CLI phases.
5. Manually compare active-zone and no-zone output using non-sensitive test
   fixtures; no Cloudflare connectivity is required.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Hand-written YAML parsing mishandles unsupported YAML syntax | Medium | Medium | Parse only the stable schema generated by `op_add()`; cover quoted values, wildcards, URLs, and catch-all rules |
| A local YAML is stale relative to Cloudflare | Medium | Low | Document that `list` reports local configuration by design |
| All-zone scanning assigns the wrong systemd unit | Low | High | Derive the zone from each YAML parent directory rather than the global `ZONE` during aggregation |
| Status checks repeat unnecessarily for multi-route tunnels | Medium | Low | Calculate unit status once per YAML and reuse it for every route row |
| Malformed YAML prevents other zones from listing | Low | Medium | Skip malformed route pairs, continue scanning other files, and keep the command non-destructive |
| Output consumers depend on the `CREATED` column | Low | Medium | Document the intentional output change in the changelog and user docs |

### Intentional behavior changes

- `list` no longer displays account tunnels that lack a local zone YAML.
- `list` no longer reads legacy root-level YAML files.
- `list` prints multiple rows for a multi-hostname tunnel.
- `list` no longer includes the remote `CREATED` column.
- `list` works without Cloudflare connectivity or `jq`.

---

## Out of Scope

| Item | Reason |
|------|--------|
| Account-wide or remote tunnel listing | Explicitly rejected; it does not model local zone membership |
| Cloudflare DNS/public-hostname discovery | Requires API semantics and credentials unrelated to local ingress listing |
| Root-level `~/.cloudflared/*.yml` compatibility | Zone directories are mandatory for the supported configuration model |
| Migration of root YAML files into zones | Separate operational concern |
| Enforcing mandatory zones in `add`, `remove`, `start`, `stop`, `status`, or `logs` | This change is limited to `list` behavior |
| Adding `--all`, `--account`, or `--remote` flags | No new listing mode is required; no active zone already means all local zones |
| Replacing the project’s generated YAML format | Existing configs remain valid |
| Installing `yq` or another YAML dependency | The generated YAML subset can be parsed safely with existing tools |

---

## Rollback Plan

The implementation is stateless and changes no tunnel, DNS, YAML, credential,
or systemd data. Rollback consists of reverting the `lib/tunnel.sh`,
`lib/cloudflared.sh`, test, and documentation commits.

No data migration or external cleanup is required.

---

## Acceptance Criteria

- [x] `cftunnel list` makes zero calls to `cloudflared`, including startup version checks.
- [x] `cftunnel list` does not require `jq`.
- [x] With an active zone, only `~/.cloudflared/zones/<active-zone>/*.yml` is scanned.
- [x] With no active zone, `~/.cloudflared/zones/*/*.yml` is scanned across all zones.
- [x] Root-level `~/.cloudflared/*.yml` files are always ignored.
- [x] One output row is printed for every valid ingress hostname/service pair.
- [x] A YAML containing five hostname routes prints all five exact hostnames.
- [x] Each hostname is paired with its own service protocol.
- [x] Hostname-less fallback rules are not printed.
- [x] Wildcard and long hostnames are not expanded or truncated.
- [x] Zone, tunnel name, UUID, unit, and status are derived from local state.
- [x] The `CREATED` column is removed.
- [x] Missing or empty zone directories produce a clear message and exit zero.
- [x] All-zone output is deterministic by zone and YAML filename while preserving ingress order.
- [x] `bash -n run.sh lib/*.sh tests/*.sh` reports zero syntax errors.
- [x] `cd tests && ./run.sh` passes all existing and new tests.
- [x] User documentation describes `list` as local zone ingress listing.

(End of file)
