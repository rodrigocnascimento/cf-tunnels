# Technical Design Document — CFTUNNEL-010

> **Issue:** CFTUNNEL-010
> **Title:** TUI Integration Contract — Non-Interactive JSON Boundary for `cftunnel` (Option A), with a TypeScript Core Port (Option B) as a Documented Future Path
> **Version:** 0.5.3 → unscheduled (design only)
> **Status:** Proposed — design only, not started
> **Date:** 2026-08-06
> **Author:** Rodrigo Nascimento (drafted from a design conversation, not from an incident)

---

## Table of Contents

1. [Overview](#overview)
2. [Motivation and Context](#motivation-and-context)
3. [Design Goals and Non-Goals](#design-goals-and-non-goals)
4. [Decision: Option A Now, Option B Deferred](#decision-option-a-now-option-b-deferred)
5. [Architecture](#architecture)
6. [Command Contract](#command-contract)
7. [Privilege and Sudo Design](#privilege-and-sudo-design)
8. [Output Channel Discipline](#output-channel-discipline)
9. [Version and Capability Negotiation](#version-and-capability-negotiation)
10. [Shared Data Model](#shared-data-model)
11. [Implementation Proposal (Future Work)](#implementation-proposal-future-work)
12. [Test Plan (Future Work)](#test-plan-future-work)
13. [Risk Assessment](#risk-assessment)
14. [Out of Scope](#out-of-scope)
15. [Migration Path to Option B](#migration-path-to-option-b)
16. [Decision Gates](#decision-gates)
17. [Acceptance Criteria (For Future Implementation)](#acceptance-criteria-for-future-implementation)

---

## Overview

A TUI is planned for `cftunnel`, built with [OpenTUI](https://github.com/anomalyco/opentui)
(a Zig-core, TypeScript-bound terminal UI library requiring Bun) instead of a
pure-JS framework like Ink. This TDD is the outcome of a design discussion
about how that TUI should talk to the existing bash `cftunnel` core, held
**before any implementation work started**. Nothing in this document has been
built. It exists so the decision and its reasoning are not lost between now
and whenever the TUI work actually begins.

Two architectural options were discussed:

- **Option A** — the TUI runs as a separate Bun process and drives `cftunnel`
  as a subprocess, the same way `cftunnel` itself already drives `cloudflared`
  and `systemctl`. `cftunnel` remains the single, already-hardened
  implementation; the TUI is a thin view + orchestration layer.
- **Option B** — port the core logic (`lib/tunnel.sh`, `lib/zone.sh`,
  `lib/cloudflared.sh`) to TypeScript/Bun so the TUI calls functions directly,
  in-process, with no subprocess boundary to `cftunnel` itself.

This document specifies Option A in enough detail to implement later, and
records Option B as a deliberate, deferred alternative — including what
Option A needs to produce so that a future Option B port has a tested
contract to build against instead of starting from nothing.

### Files expected to change if this is implemented

| File | Proposed change |
|------|-----------------|
| `lib/tunnel.sh` | Add `--output json` to `op_list`; add `--yes` to `op_add`/`op_remove` |
| `run.sh` | Wire the new flags through the first-pass and per-command arg parsers |
| `tests/test_list.sh` | Add JSON-output schema/shape tests |
| `tests/test_add_remote_failures.sh`, a new `tests/test_remove.sh` (if it does not already cover this) | Add `--yes` non-interactive coverage |
| `AGENTS.md` | Document the JSON contract and the non-interactive flags as a stable interface |
| `CHANGELOG.md` | Record the new flags under `Unreleased` |
| A new deployment doc (sudoers snippet) | Document the scoped `NOPASSWD` rule from [Privilege and Sudo Design](#privilege-and-sudo-design) |

No TUI code, no Bun code, and no `packages/` directory are in scope for this
document. Those belong to a separate TDD once TUI work actually starts.

---

## Motivation and Context

`cftunnel` today is a mature, tested bash CLI: 105 tests, a TDD-driven spec
for every prior change, and a fail-closed security posture reconfirmed as
recently as `d17f2a8` (locale-collation lock) and the pending CFTUNNEL-009
fix. None of that maturity is in question here.

What triggered this design conversation is that `cftunnel` currently exposes
**no machine-readable interface at all**:

- `op_list` (`lib/tunnel.sh:528`) builds a fixed-width text table with
  `printf` for human eyes. Column widths, truncation, and ordering are
  presentation choices, not a contract — parsing this table from a TUI would
  be scraping, not integrating.
- `op_status` and `op_logs` (`lib/tunnel.sh:430-441`) exec `systemctl status`
  and `sudo journalctl -fu` directly, inheriting stdout to the terminal.
  These are already naturally stream-friendly for a subprocess-based TUI
  (a "tail logs" panel is exactly a line-stream), but they are interactive
  and privileged today (`sudo -v` inline), which a TUI cannot satisfy the
  same way an interactive shell user does.
- `op_add` and `op_remove` require an interactive `[y/N]` confirmation
  keystroke — there is currently no way to drive them non-interactively at
  all, from a TUI or from any other automation.

A TUI cannot be built against this surface without either (a) parsing
human-formatted text, which breaks the moment the table layout changes for
purely cosmetic reasons, or (b) `cftunnel` gaining an explicit, versioned,
machine-readable contract. This document specifies (b).

---

## Design Goals and Non-Goals

### Goals

1. **One source of truth stays one source of truth.** All tunnel-safety
   logic (fail-closed discovery, UUID validation, zone containment, credential
   handling) continues to live only in `lib/*.sh`. The TUI must not
   reimplement any of it.
2. **The contract is additive, not a rewrite.** Existing human-facing output
   of `cftunnel list`, `cftunnel add`, `cftunnel remove` is unchanged by
   default. New behavior is opt-in via explicit flags.
3. **The contract is a real interface, not an implementation detail.** It
   gets its own tests, its own versioning story, and its own documentation,
   because a TUI (or any future consumer) depends on it not changing silently.
4. **The contract is designed to double as Option B's target spec.** If the
   core is ever ported to TypeScript, the JSON shapes and command semantics
   defined here are what the port implements natively — this document is
   written so that migration, not another design conversation, is the next
   step if that day comes.
5. **No new runtime dependency for the bash core.** `cftunnel` itself keeps
   requiring only bash, `jq`, and `cloudflared` — it does not gain a Bun or
   Node dependency merely to support a TUI that talks to it externally.

### Non-Goals

- Building the TUI itself.
- Deciding OpenTUI vs. any alternative TUI framework (already decided:
  OpenTUI).
- Implementing Option B.
- Changing any existing fail-closed validation behavior from CFTUNNEL-004,
  -007, -008, or the locale fixes in `d17f2a8`/CFTUNNEL-009.
- Adding a daemon, socket, or long-running server mode to `cftunnel`. Every
  interaction remains a discrete process invocation, matching how `cftunnel`
  already treats `cloudflared` and `systemctl`.

---

## Decision: Option A Now, Option B Deferred

**Recommendation:** implement Option A when TUI work starts. Treat Option B
as a possible future migration, not a parallel track.

### Comparison

| | Option A (subprocess boundary) | Option B (in-process TS core) |
|---|---|---|
| What changes in `cftunnel` | Additive flags (`--output json`, `--yes`) | Full rewrite of `lib/*.sh` logic in TypeScript |
| Risk to existing 105 tests / fail-closed guarantees | None — existing code paths untouched | High — every hardened behavior (CFTUNNEL-004, -007, -008, locale fixes) must be reproduced and re-verified in a new language |
| New runtime dependency for the CLI itself | None (still pure bash + jq + cloudflared) | Bun/Node required even for headless/non-TUI use (systemd, cron, plain SSH sessions) |
| Data flow | fork+exec, parse stdout (JSON or line-stream) | direct function call, no serialization |
| Live/reactive UI | Polling (`cftunnel list --output json` on an interval) | Possible push model (`fs.watch` on the YAML directory) |
| Subprocess orchestration of `cloudflared`/`systemctl` | Stays in bash, already handled | Moves to TypeScript — not eliminated, just relocated |
| Effort to start | Small, incremental, per-command | Large, up-front, all-or-nothing to reach parity |

The deciding factor is risk placement. Option A's entire cost is additive
surface area on a system that already works. Option B's cost is re-proving
correctness properties that took three TDDs and a same-day locale-bug hunt to
establish, before the TUI has rendered a single frame. Nothing about
`cftunnel`'s current maturity justifies paying that cost up front.

---

## Architecture

```text
┌─────────────────────────────┐
│   TUI process (Bun/OpenTUI) │
│                              │
│  - renders panels            │
│  - polls / re-invokes        │
│  - owns no tunnel state      │
└──────────────┬───────────────┘
               │ spawn (Bun.spawn / Bun.$)
               ▼
┌─────────────────────────────┐
│   cftunnel (bash, unchanged  │
│   core, additive flags only) │
│                              │
│  - all validation/fail-closed│
│    logic lives here           │
│  - talks to cloudflared,     │
│    systemctl, filesystem      │
└──────────────┬───────────────┘
               │ subprocess
               ▼
      cloudflared / systemctl / journalctl
```

The TUI never talks to Cloudflare, `cloudflared`, or systemd directly. Every
interaction is mediated by `cftunnel`, which is the only place credential
paths, zone containment, and UUID validation are enforced. This preserves the
security boundary this project has spent multiple TDDs building, without the
TUI needing to know any of it exists.

---

## Command Contract

### `cftunnel list --output json`

**New flag.** Mirrors the `--output json` convention `cftunnel` already
consumes from `cloudflared` — this keeps the naming idiomatic rather than
inventing a new flag shape.

Default (no flag): existing fixed-width table, byte-for-byte unchanged.

With `--output json`: a single JSON array on stdout, one object per tunnel
row currently produced by `op_list`, using the same underlying data
(`lib/tunnel.sh:528-...`, `tunnel_uuid_from_yaml`, `ingress_routes_from_yaml`).
See [Shared Data Model](#shared-data-model) for the exact shape.

Constraints:
- Emits nothing on stdout except the JSON array. Any warning/diagnostic goes
  to stderr (see [Output Channel Discipline](#output-channel-discipline)).
- If zero tunnels are found, emits `[]`, not an error and not empty stdout —
  the TUI must be able to tell "no tunnels" from "command failed" purely from
  exit code + stdout shape, the same fail-closed distinction CFTUNNEL-008
  already insists on for Cloudflare's own API responses.
- `$ZONE` filtering behaves identically to the existing table output.

### `cftunnel status --name X` / `cftunnel logs --name X`

**No new flag proposed.** These already stream naturally:
`systemctl status` output and `journalctl -f` lines are exactly the shape a
TUI log/detail panel wants — read line by line, render as they arrive. The
contract here is behavioral, not a new flag: these commands must continue to
write only to stdout/stderr with no other side channel, and the TUI is
expected to treat their output as opaque text, not parse it.

### `cftunnel add ... --yes` / `cftunnel remove ... --yes`

**New flag on each.** Skips the interactive `[y/N]` confirmation prompt and
proceeds as if the user answered yes. Default behavior (no `--yes`) is
unchanged — interactive users and existing scripts are unaffected.

Constraints:
- `--yes` does not skip or weaken any validation, discovery, or fail-closed
  behavior from CFTUNNEL-008 — it only removes the confirmation prompt itself.
- The TUI is responsible for rendering its own confirmation UI before
  invoking `add`/`remove --yes`; `cftunnel` does not need to know it is being
  driven by a TUI versus a script.
- `--yes` must be spelled the same way a human would expect from other CLIs
  (`apt-get -y`, `rm -f` precedent considered but rejected as too silent;
  `--yes` was chosen for explicitness over a short flag).

---

## Privilege and Sudo Design

`op_status` and `op_logs` call `sudo -v` inline today, which assumes an
interactive TTY or already-cached credentials. A TUI-spawned subprocess may
not have a usable TTY for a password prompt.

**Recommendation:** a narrowly scoped `NOPASSWD` sudoers rule for exactly the
commands `cftunnel` invokes under `sudo`, not a blanket rule:

```text
# /etc/sudoers.d/cftunnel-tui — scope to the exact commands cftunnel runs.
# Do not grant broader sudo access than this.
<run-user> ALL=(root) NOPASSWD: /usr/bin/systemctl status cloudflared@*, \
                                 /usr/bin/journalctl -fu cloudflared@*
```

This is deliberately conservative: it grants passwordless access only to the
two read-only operations (`status`, log tailing) that block on a TTY, not to
anything that mutates state (`add`/`remove` still authorize via a normal
`sudo -v`, which the TUI must be run in a context where that succeeds —
e.g., a cached credential from the same login session, not a fully detached
process). The exact wildcard pattern must be validated against the real unit
naming scheme (`instance_unit()` in `lib/tunnel.sh`) before being deployed,
and should be scoped per-host, not shipped as a default file the installer
writes automatically.

---

## Output Channel Discipline

For `--output json` to be reliable, stdout must carry **only** the JSON
payload on success. This is already mostly true — CFTUNNEL-008 established
that captured Cloudflare JSON is never echoed, and errors already go through
`die()`/direct `>&2` writes in `lib/common.sh` and throughout `lib/tunnel.sh`
and `lib/zone.sh`. This section exists to make that property an explicit,
tested requirement for `--output json` mode specifically, not just an
observed side effect of unrelated hardening.

Requirement: with `--output json`, every code path either writes a single
valid JSON value to stdout and exits 0, or writes nothing to stdout, writes a
diagnostic to stderr, and exits non-zero. No partial JSON, no mixed
human-text-plus-JSON, ever.

---

## Version and Capability Negotiation

The TUI must not assume the `cftunnel` it finds on `$PATH` supports
`--output json` — a homelab host may be running an older installed version.

**Recommendation:** the TUI calls `cftunnel --version` (already implemented
per CFTUNNEL-006) before relying on any new flag, parses the semver, and
fails with a clear "upgrade cftunnel to at least 0.X.Y" message rather than
attempting to parse table output as JSON. This mirrors the same fail-closed
instinct already applied to Cloudflare API responses in CFTUNNEL-008: an
unexpected shape must produce a clear error, not a best-effort guess.

The minimum version gate is set once `--output json` actually ships, as part
of that implementation's own version bump.

---

## Shared Data Model

Draft shape for `cftunnel list --output json`, derived directly from the
fields `op_list` already computes (`lib/tunnel.sh:528-...`):

```typescript
interface TunnelListEntry {
  zone: string | null;       // null when not zone-scoped
  name: string;               // slugified tunnel name
  uuid: string | null;        // null when unresolved from YAML
  unit: string;                // full systemd unit name
  status: "active" | "enabled" | "inactive";
  routes: Array<{
    hostname: string;
    service: string;
  }>;
}
```

This interface is intentionally written in TypeScript even though nothing TS
exists yet in this repository: it is the artifact a future Option A
implementation's tests validate against, and the same artifact a future
Option B port would implement natively instead of re-deriving from scratch.
Keeping it here, versioned alongside the bash contract it describes, is the
mechanism by which Option A's work is not wasted if Option B ever happens.

---

## Implementation Proposal (Future Work)

Not authorized by this document. Recorded here only so a future
implementer does not have to redesign this from the discussion notes.

### CP-01: `cftunnel list --output json`

- **File:** `lib/tunnel.sh` (`op_list`), `run.sh` (arg parsing)
- Add `--output json` recognized only by the `list` subcommand parser.
- Refactor `op_list`'s existing per-tunnel data gathering loop to build a
  `jq`-constructed JSON array when the flag is set, instead of `printf`
  table rows. Reuse `tunnel_uuid_from_yaml` and `ingress_routes_from_yaml`
  unchanged — only the output formatting branches.

### CP-02: `--yes` for `add`/`remove`

- **File:** `lib/tunnel.sh` (`op_add`, `op_remove`), `run.sh` (arg parsing)
- Add `--yes` to both parsers; short-circuit the existing confirmation
  prompt when set, leaving every downstream validation call untouched.

### CP-03: Sudoers documentation

- **File:** a new `docs/` or Wiki page (not `spec/`) documenting the scoped
  `NOPASSWD` rule from [Privilege and Sudo Design](#privilege-and-sudo-design)
  as an opt-in deployment step, not something the installer applies
  automatically.

### CP-04: Version gate documentation

- **File:** `AGENTS.md`, Wiki `CLI-Reference.md`
- Document the minimum `cftunnel` version required for `--output json` and
  `--yes` once CP-01/CP-02 ship, for the TUI (or any consumer) to check
  against.

---

## Test Plan (Future Work)

Not authorized by this document. Recorded for the future implementer.

1. **JSON shape conformance** — `cftunnel list --output json` output
   validates against the `TunnelListEntry[]` shape for: zero tunnels, one
   tunnel, multiple tunnels across multiple zones, a tunnel with an
   unresolved UUID, a tunnel with zero ingress routes.
2. **Output channel discipline** — for every existing `tests/test_*.sh`
   failure fixture that currently asserts a non-zero exit code, add or reuse
   an assertion that stdout is empty (or valid JSON) when `--output json` is
   set, matching the requirement in
   [Output Channel Discipline](#output-channel-discipline).
3. **`--yes` non-interactive coverage** — `add`/`remove --yes` produce the
   same end state as the interactive path answering `y`, without reading
   stdin; omitting `--yes` still prompts exactly as today.
4. **Version gate** — a fixture `cftunnel` binary reporting an old version
   is rejected by the capability-negotiation logic once that logic exists on
   the TUI side (cross-referenced here, implemented in the TUI's own test
   suite when that repository exists).

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `--output json` and the existing table output drift in what data they expose | Medium | Medium | Generate both from the same per-tunnel loop; do not maintain two independent data-gathering code paths |
| `--yes` is later reused as a way to silently bypass a future confirmation-worthy check | Low | High | `--yes` is documented and code-reviewed as "skips the prompt only," never as a general bypass flag; any new dangerous operation gets its own explicit gate |
| Scoped sudoers rule is copy-pasted broader than intended | Medium | High | Ship the rule as documentation with an explicit "validate the wildcard against your unit names" warning, not as an automatic installer step |
| This document is stale by the time TUI work actually starts (Cloudflare API changes, `cloudflared` version bumps) | Medium | Low | Contract is versioned and gated by `cftunnel --version`; revisit this TDD before implementation, do not implement blindly from a possibly-stale design |
| Option B is attempted later without reusing this contract | Low | Medium | The `TunnelListEntry` interface and command semantics defined here are the intended migration target; a future Option B TDD should reference this document rather than redesign the shape |

---

## Out of Scope

| Item | Reason |
|------|--------|
| Any TUI/OpenTUI/Bun code | Belongs to a separate TDD once TUI implementation starts |
| Implementing Option B | Explicitly deferred; this document only records it as a future path |
| A daemon/socket/long-running `cftunnel` server mode | Every interaction remains a discrete process invocation, consistent with the rest of the project |
| Changing any fail-closed validation behavior | Out of scope by design goal 1 — this is a surface-area addition, not a logic change |
| Choosing between OpenTUI and alternatives | Already decided outside this document |
| Automatic installer changes for the sudoers rule | Deployment step is documented, not automated, given the security sensitivity of sudoers files |
| Implementing CP-01 through CP-04 | Explicitly not started per this conversation — "não vamos começar nada agora" |

---

## Migration Path to Option B

If Option B is ever pursued, the recommended sequence is:

1. Confirm the JSON contract in this document is still accurate against the
   then-current `cftunnel` behavior (re-verify, do not assume).
2. Port one module at a time (`lib/zone.sh` validators first — they are the
   most self-contained and the most recently hardened), each with its own
   TDD, each required to pass a parity test suite that feeds it the same
   fixtures `tests/test_functions.sh` and friends already use.
3. Keep the bash `cftunnel` CLI as the shipped artifact for non-TUI use
   (systemd, cron, plain SSH) until the TypeScript core has full parity and
   its own equivalent of the 105-test suite — do not cut over the CLI
   surface until the replacement is proven, not merely feature-complete.
4. Only after full parity is proven should `cftunnel` itself be re-pointed to
   call into the TypeScript core instead of bash — at which point the
   subprocess boundary this document specifies (Option A) collapses
   naturally, without ever having been a wasted investment: the TUI's
   integration code does not change, because the contract it depends on
   (`TunnelListEntry`, `--yes` semantics, exit-code discipline) is exactly
   what the new core implements.

---

## Decision Gates

### DG-01: Subprocess boundary vs. in-process core

**Recommendation:** subprocess boundary (Option A), as argued in
[Decision: Option A Now, Option B Deferred](#decision-option-a-now-option-b-deferred).

**Resolution:** Recorded as the intended direction from this design
conversation. Not yet implemented; not yet formally approved for a specific
implementation date. Revisit if new information changes the risk calculus
(e.g., `cftunnel`'s bash implementation becomes a demonstrated bottleneck, or
Option B gains a concrete forcing function this document did not anticipate).

### DG-02: `--yes` naming and scope

**Recommendation:** `--yes`, confirmation-skip only, no broader semantics.

**Resolution:** Recorded as the intended design. Open for reconsideration at
implementation time if a differently-named flag better matches whatever
other automation (non-TUI) ends up wanting the same capability first.

### DG-03: Sudo handling

**Recommendation:** scoped `NOPASSWD` sudoers rule, documented and manually
applied, not installer-managed.

**Resolution:** Recorded as the intended design. The exact command wildcard
must be validated against `instance_unit()`'s real output before any
implementation ships this as documentation.

---

## Acceptance Criteria (For Future Implementation)

None of the following are done. They are the bar a future implementation of
this document must clear before it is considered complete — recorded now so
the goalposts do not drift between this conversation and that work.

- [ ] `cftunnel list --output json` emits a single JSON array matching
      `TunnelListEntry[]`, with no other stdout content, for zero, one, and
      multiple tunnels across zones.
- [ ] Default `cftunnel list` output (no flag) is byte-for-byte unchanged.
- [ ] `cftunnel add --yes` and `cftunnel remove --yes` skip only the
      confirmation prompt; every other validation, discovery, and fail-closed
      path from CFTUNNEL-008 still runs unmodified.
- [ ] Omitting `--yes` preserves today's interactive behavior exactly.
- [ ] No code path under `--output json` writes partial or mixed
      JSON/human-text to stdout on any failure.
- [ ] A documented, scoped `NOPASSWD` sudoers snippet exists for the exact
      `systemctl status`/`journalctl -fu` invocations `cftunnel` makes, with
      an explicit warning against broadening it.
- [ ] `AGENTS.md`, `CHANGELOG.md`, and the relevant Wiki page document the new
      flags and the minimum version required to rely on them.
- [ ] `cd tests && ./run.sh --verbose` passes, including new JSON-shape and
      `--yes` coverage.
- [ ] This document's `TunnelListEntry` interface, or its documented
      successor, is what any future Option B port implements — no
      independent redesign of the data shape without updating this TDD first.
