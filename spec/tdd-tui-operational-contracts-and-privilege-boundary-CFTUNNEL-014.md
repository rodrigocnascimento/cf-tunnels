# Technical Design Document — CFTUNNEL-014

> **Issue:** CFTUNNEL-014
> **Title:** TUI Operational Contracts — Zone, Route, Health, and Privilege Boundary
> **Version:** N/A — proposed design only
> **Status:** Proposed — no implementation authorized
> **Date:** 2026-09-24

---

## 1. Decision

The existing Bash CLI remains the single authority for validation, state
changes, Cloudflare interaction, credential handling, and systemd lifecycle.
The future Ink/React application, running on Bun, consumes a documented
command-level contract through its Bun operational layer. It does not parse
human tables, reimplement validation, access credentials, or call
systemd/Cloudflare directly.

CFTUNNEL-010 remains the architectural decision for the subprocess boundary.
This record expands the required contract from `list` and confirmation flags
to every *public zone and route management operation* needed for operational
TUI use. It does not freeze private shell helpers as public API.

No code, TUI, sudoers rule, user/group membership, timer, or dependency is
introduced by this document.

## 2. Goals

1. Give the TUI a safe, machine-readable operational boundary.
2. Make zone context and persistence explicit; a subprocess must never stop
   on an unexpected prompt to persist a selected zone.
3. Separate local/offline facts from live/remote observations and always
   expose freshness.
4. Make privilege requirements visible before a mutating operation begins.
5. Preserve fail-closed behavior and the current order of safety checks:
   validation and read-only discovery precede privileged or remote mutation.
6. Support a read-only operational TUI first, then explicit user-approved
   mutations.

## 3. Scope and non-goals

### In scope

- Public command contracts for zone context/authentication, inventory, route
  lifecycle, systemd status/logs, and health diagnostics.
- JSON response schemas, exit behavior, interaction modes, and capability
  discovery.
- A temporary, interactive sudo-cache boundary suitable for a TUI.
- Contract conformance tests and fixture expectations.

### Out of scope

- A TypeScript port, daemon, privileged root helper, PolicyKit integration,
  or systemd user-unit migration.
- A permanent broad `NOPASSWD` rule for mutations.
- Direct Cloudflare REST API use or remotely-managed tunnels.
- Backup implementation and systemd timer implementation (CFTUNNEL-012).
- TUI code, package layout, visual design, or release plan.

## 4. Contract principles

### 4.1 Public commands, not private functions

The contracts apply to commands a user or TUI invokes: `zone`, `list`,
`add`, `remove`, `start`, `stop`, `status`, `logs`, and the proposed `health`
and privilege-preflight commands. Helpers such as `slugify`, path builders,
and credential transaction functions remain implementation details, covered
by unit tests rather than compatibility commitments.

### 4.2 Explicit interaction mode

Every command must have a defined interaction class:

| Class | Meaning | TUI behavior |
|---|---|---|
| non-interactive | Never reads stdin or opens a browser | Invoke directly |
| confirmation-gated | Human confirmation is required by default | TUI renders approval, then uses an explicit apply flag |
| browser-auth | Requires Cloudflare login in a browser | TUI shows the target zone and progress; no hidden zone picker |
| privileged | Requires an already-authorized sudo cache for mutation | TUI asks the operator to authenticate first |
| stream | Runs until cancelled and emits an ordered stream | TUI owns cancellation and rendering |

`--output json` must never trigger an interactive prompt. A command that
needs input but did not receive an explicit non-interactive instruction fails
with a defined error rather than waiting on stdin.

### 4.3 Output and exit discipline

For a JSON-capable command, successful stdout contains exactly one JSON
document and nothing else. Diagnostics go to stderr. On failure stdout is
empty and stderr contains a non-secret diagnostic; a non-zero exit code is
mandatory.

Every JSON response includes at least:

```json
{
  "schema_version": 1,
  "operation": "zone.current",
  "ok": true,
  "data": {},
  "warnings": []
}
```

`warnings` are non-fatal, user-actionable conditions. No credential, token,
certificate, private key, or raw Cloudflare account response may appear in a
response, warning, or diagnostic.

`logs` is the exception: its stream remains opaque text by default. A future
structured log mode, if needed, uses explicit JSON Lines and must not alter
the default stream.

### 4.4 Fact provenance and freshness

Every status/health field is marked by source:

- `local`: YAML, credential metadata, persisted zone state, or local unit
  definition;
- `systemd`: local system manager query;
- `dns`: resolver observation, with resolver/check time;
- `cloudflare`: an explicit remote query, with check time.

The CLI must not silently turn an offline local listing into a network query.
A networked check is opt-in and reports `checked_at`; unavailable or stale
remote information remains distinguishable from a healthy result.

## 5. Zone and route command inventory

The following table is the required public surface. Exact flag spelling and
JSON field names are finalized in the implementation TDD, but the behavior
and interaction boundaries are contractual.

| Operation | Interaction | Privilege | Required result |
|---|---|---|---|
| `zone use <zone>` | non-interactive | none | canonical zone, directory created, default persisted |
| `zone current` | non-interactive | none | active/default zone or explicit unset state |
| `zone unset` | confirmation-gated only if it would alter active TUI context; otherwise explicit non-interactive apply | none | previous/default state and resulting unset state |
| `--zone X` on another command | non-interactive | depends on command | selected zone only; never asks to persist it |
| `--zone X --persist` | confirmation-gated/apply | none | selected zone and explicit default-zone change |
| `zone login --zone X` | browser-auth | none | target canonical zone, auth progress, binding-install result; no zone picker |
| `list` | non-interactive | none | local route inventory and zone scope, including empty result |
| `add` plan | non-interactive | none | normalized inputs, target unit/YAML, intended DNS/systemd/Cloudflare effects and required privilege |
| `add` apply | confirmation-gated | cached sudo | final route/tunnel/unit state and DNS result; fail closed on uncertainty |
| `remove` plan | non-interactive | none | target route/unit/files and destructive effects |
| `remove` apply | confirmation-gated | cached sudo | final result or explicit preservation of local files after remote-delete failure |
| `start` / `stop` | confirmation-gated for stop if policy requires; explicit apply otherwise | cached sudo | unit and resulting service state |
| `status` | non-interactive | none by default | local unit state, unit identifier, source and checked time |
| `logs` | stream | none if journal access exists; cached sudo otherwise | stream metadata before/alongside opaque log content |
| `health` | non-interactive | none by default | component results for local config, systemd, DNS, and explicit optional remote checks |

### 5.1 Zone-context correction

The current behavior can ask whether `--zone` should replace the persisted
default zone. That behavior is incompatible with a non-interactive contract.
The future contract must make persistence explicit: `--zone` selects only for
the invocation; `--persist` is the only route to changing the default.

### 5.2 Plans before mutations

`add` and `remove` require a read-only plan form, such as `--dry-run` or a
dedicated `plan` verb. It validates inputs and reports intended effects, but
does not obtain sudo, create a Cloudflare resource, write a YAML, alter DNS,
or touch systemd. The TUI displays this plan and receives explicit user
approval before applying it.

The apply form receives a confirmation-skip flag only after the TUI has
rendered the plan. `--yes` means exactly “approval was already obtained”; it
never weakens validation, credential binding, discovery, or fail-closed
semantics.

## 6. Privilege boundary

### 6.1 Required model

The TUI must never collect, transmit, or write a sudo password. It must not
let a subprocess hang on a hidden password prompt.

The proposed model is an explicit two-step temporary authorization flow:

1. A TUI action, for example `cftunnel privilege authenticate`, invokes
   `sudo -v` attached to the user's real terminal. It is the only operation
   allowed to prompt for a password.
2. Mutating commands invoke `sudo -n`. They either proceed with the normal
   sudo timestamp/cache or fail before mutation with a machine-readable
   `sudo_auth_required` condition. The TUI then returns to step 1.

The TUI may show cache availability through a non-interactive preflight, such
as `cftunnel privilege check --output json`, but it must not infer it from a
failed mutation.

### 6.2 Command classification

| Class | Commands | Rule |
|---|---|---|
| no sudo | zone context, zone login, list, plans, local validation, DNS resolution, status, health | Must not call `sudo -v` as a side effect |
| cached sudo required | add apply, remove apply, start, stop | Validate and complete read-only discovery first; then use `sudo -n` before the first mutation |
| conditional cached sudo | logs | Prefer ordinary journal access; otherwise report that cached sudo is required before starting the stream |
| installation/admin only | install, uninstall, `cli-update` | Outside the TUI management surface; retain their separately explicit privilege model |

`status` is specifically a no-sudo operation in this contract. The current
implementation asks `sudo -v` and then calls unprivileged `systemctl status`;
this is an inconsistency that must be removed or deliberately redesigned,
not copied into the TUI.

### 6.3 What is not approved

No global `NOPASSWD` rule is approved for `systemctl daemon-reload`,
`enable`, `disable`, or arbitrary `cloudflared@*` management. A future
least-privilege sudoers design may be evaluated separately, but it requires
argument-level validation against the real unit naming and threat model.

## 7. Health and operational observability

The first TUI release is read-only but operational, not merely a prettier
`list`. It needs a local health contract able to surface:

- YAML existence, parse/ingress validation, permissions, and referenced
  credential availability without exposing credential content;
- systemd enabled/active/failed state and recent failure indication;
- DNS resolution and, when available, CNAME expectation;
- latest explicit Cloudflare probe only when requested;
- backup recency once CFTUNNEL-012 exists;
- source and check time for every result.

Opening a TUI cannot by itself prevent a future failure. Preventive alerting
is a separate scheduled health-check concern, likely provisioned by Ansible.
That future timer must consume the same health contract and report failure;
the TUI presents its last result rather than inventing a separate health
model.

## 8. Capability negotiation

Version string comparison alone is insufficient as the interface expands.
Before using optional behavior, a consumer requests a machine-readable
capability document containing schema version and supported operations/output
modes, for example:

```json
{
  "schema_version": 1,
  "operation": "capabilities",
  "ok": true,
  "data": {
    "application_version": "0.x.y",
    "operations": {
      "zone.current": { "json": true },
      "list": { "json": true },
      "health": { "json": true },
      "logs": { "stream": true },
      "add": { "plan": true, "apply": true, "cached_sudo": true }
    }
  },
  "warnings": []
}
```

An unknown schema, missing operation, malformed response, or non-zero exit is
a fail-closed incompatibility. The TUI reports an upgrade requirement; it
never scrapes human output as a fallback.

## 9. Implementation sequence

This document authorizes no implementation. When approved, work must be
sequenced to keep the TUI useful while protecting current behavior:

1. Specify exact schemas and error identifiers from this inventory.
2. Implement and test capability discovery, zone context, local list, status,
   and health read-only contracts.
3. Implement explicit plan/apply contracts and the sudo preflight/cache
   behavior, with no TUI mutation yet.
4. Build the read-only TUI against those contracts.
5. Add TUI mutations only after plan/apply and privilege failure paths have
   conformance coverage.
6. Add Ansible-provisioned scheduled backup and health checks after their
   underlying contracts are stable.

## 10. Contract conformance requirements

For every public operation, tests must cover:

1. valid input and canonical output;
2. malformed/cross-zone input before external or privileged side effects;
3. no selected zone, selected temporary zone, and explicit persistence;
4. JSON stdout exclusivity and empty stdout on errors;
5. stable non-zero error classification without secrets;
6. dependency, network, Cloudflare, systemd, and permission failures;
7. absence of sudo invocation for no-sudo commands;
8. `sudo -n` failure before mutating effects for privileged commands;
9. plan paths with zero remote, filesystem, DNS, and systemd mutations;
10. cancellation and stream cleanup for logs/browser-auth flows.

## 11. Acceptance criteria for future implementation

- [ ] A TUI can manage zone context without stdin prompts or human-output
      parsing.
- [ ] Every zone/route management operation needed by the TUI has a documented
      machine-readable success and failure contract.
- [ ] Local/offline and live/remote observations are visibly distinct.
- [ ] TUI mutations never prompt for sudo; expired authorization becomes a
      recoverable `sudo_auth_required` result before mutation.
- [ ] No broad permanent `NOPASSWD` rule is necessary for the TUI.
- [ ] `add` and `remove` present a no-side-effect plan before applying.
- [ ] Read-only health information can power both the TUI and a future
      Ansible-provisioned scheduled check.
- [ ] Existing human CLI output remains backward compatible unless an explicit
      new output mode is requested.

## 12. Relationship to other design records

- CFTUNNEL-010: TUI subprocess architecture and initial JSON/`--yes` design.
- CFTUNNEL-011 and CFTUNNEL-013: deferred remotely-managed tunnel direction.
- CFTUNNEL-012: encrypted backup and manual restoration baseline.

This TDD refines the contract scope CFTUNNEL-010 anticipated. In any conflict
about public TUI operational contracts or sudo behavior, CFTUNNEL-014 takes
precedence; CFTUNNEL-010 continues to govern the choice of subprocess
boundary over a TypeScript core rewrite.
