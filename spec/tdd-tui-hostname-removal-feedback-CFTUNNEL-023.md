# Technical Design Document — CFTUNNEL-023

> **Issue:** CFTUNNEL-023
> **Title:** Explain Hostname Removal in the Terminal Dashboard
> **Version:** 0.19.0 → 0.19.1
> **Status:** Implemented
> **Date:** 2026-10-17
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Root Cause](#root-cause)
4. [Design Goals](#design-goals)
5. [Behavior Contract](#behavior-contract)
6. [Implementation Proposal](#implementation-proposal)
7. [Test-Driven Delivery Plan](#test-driven-delivery-plan)
8. [Documentation and Release Plan](#documentation-and-release-plan)
9. [Risk Assessment](#risk-assessment)
10. [Out of Scope](#out-of-scope)
11. [Rollback Plan](#rollback-plan)
12. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

The terminal dashboard (`packages/tui/`) binds `x` to hostname removal. When the
selected tunnel has hostnames in its local YAML, `x` opens the removal flow.
When it has none — the normal state after every hostname was removed, or after a
partial failure — the key press did nothing at all.

This document records a small, additive fix: make the dashboard state *why*
removal cannot proceed, instead of leaving the operator with a frozen view.

The TUI remains a read-only observer plus an explicit-handoff client. This change
touches no command, no JSON contract, and no Cloudflare or systemd behavior. It
targets the next patch release, `0.19.1`.

### Files changed during implementation

| File | Implemented change |
|------|--------------------|
| `packages/tui/src/app.tsx` | Report the reason on `x`; hint in DETAILS when a tunnel has no local hostnames |
| `packages/tui/src/app.test.tsx` | Cover both new messages and the unchanged removal path |
| `spec/tdd-tui-hostname-removal-feedback-CFTUNNEL-023.md` | This record |
| `AGENTS.md`, `CHANGELOG.md`, `VERSION`, `packages/tui/package.json` | Record the convention, the fix, and the release version |

---

## Problem Statement

An operator that has just removed the last hostname of a tunnel sees an empty
`Routes` list and `0 routes`. Pressing `x` again produces no visible response:
the screen does not move, no sudo prompt appears, and no error is reported. From
the operator's perspective the dashboard is hung or broken.

The same silence applies when no tunnel is selected at all.

### Reported symptom

> "não consigo remover um hostname" — the removal key appears to do nothing,
> and no credential prompt is ever shown.

The underlying data was correct: the tunnel's ingress held only
`- service: http_status:404`, `cftunnel list` reported `rotas=0`, and the CLI
`hostname remove` path works correctly for tunnels that do have hostnames. The
dashboard simply never said anything.

---

## Root Cause

| ID | Cause | Effect |
|----|-------|--------|
| RC-01 | The `x` handler is `if (input === "x" && active && active.routes.length)` with no `else` | The key is a silent no-op whenever there is no selected tunnel or no local hostname |
| RC-02 | The guard exists for a good reason (there is nothing to select from) but its failure mode is invisible | Operators read silence as a hang and retry, or reach for the CLI |
| RC-03 | The DETAILS pane renders an empty `Routes` section without comment | Nothing in the view explains why the section is empty |

---

## Design Goals

1. **Never silent** — every `x` press ends in either the removal flow or a
   visible explanation.
2. **Explain the state, not the key** — say that the tunnel has no local
   hostnames, rather than leaking "the guard rejected this".
3. **Name the tunnel** — the message identifies the selected tunnel so the
   operator can tell which entry is empty.
4. **Explain the empty pane** — DETAILS states that the local configuration has
   no hostnames for this tunnel.
5. **No behavior change for tunnels with hostnames** — the existing removal
   sequence (selection, plan, explicit confirmation, handoff) is untouched.
6. **No new surface** — no new key, flag, JSON field, command, or DNS action.
7. **Contract stability** — `packages/tui/src/operations.ts` and every cftunnel
   JSON contract are unchanged.

---

## Behavior Contract

| State when `x` is pressed | Dashboard behavior |
|---------------------------|--------------------|
| No tunnel selected in the current Scope | Banner: `Select a tunnel before removing a hostname`; no handoff |
| Selected tunnel has 0 local hostnames | Banner: `<tunnel> has no hostnames in the local configuration; nothing to remove`; no handoff |
| Selected tunnel has ≥1 local hostname | Unchanged: removal selection → plan → confirmation → handoff |

The message uses the error banner already present in the view, so it follows the
existing render path and clears on the next successful action exactly as other
messages do.

DETAILS additionally shows, under an empty `Routes` heading:

```text
No hostnames in the local configuration for this tunnel.
```

Only local YAML ingress hostnames count. DNS records that no longer have a local
ingress rule are deliberately invisible to the dashboard, and this change does
not introduce any DNS deletion path.

---

## Implementation Proposal

### CP-01: Replace the silent guard with an explicit handler

- **File:** `packages/tui/src/app.tsx`
- **Action:** Turn the compound `x` condition into a handler with two early
  branches that set an explanatory message, followed by the existing removal
  sequence.

### CP-02: Explain an empty Routes section

- **File:** `packages/tui/src/app.tsx`
- **Function:** `TunnelDetail`
- **Action:** When `tunnel.routes.length === 0`, render one dim hint line before
  the (empty) route list.

---

## Test-Driven Delivery Plan

Tests use `ink-testing-library` through the existing `App` harness, matching the
style of `packages/tui/src/app.test.tsx`.

| Test | Expected behavior |
|------|-------------------|
| `explains why a tunnel with no local hostnames has nothing to remove` | `x` on a tunnel with `routes: []` shows the message, does not open `REMOVE HOSTNAME`, and DETAILS shows the empty-routes hint |
| `asks for a selected tunnel before offering hostname removal` | `x` with an empty Scope shows the selection message and never opens `REMOVE HOSTNAME` |

The existing four dashboard tests must keep passing unchanged, proving the
confirmation and handoff paths were not disturbed.

Verification commands:

1. `cd packages/tui && bun run typecheck`
2. `cd packages/tui && bun test`
3. `bash -n run.sh install.sh uninstall.sh lib/*.sh packages/tui/scripts/*.sh`
4. `cd tests && ./run.sh`

---

## Documentation and Release Plan

- The Wiki does not document dashboard key bindings, so no Wiki page describes
  this behavior and none is changed.
- `CHANGELOG.md` records the fix under `0.19.1` → `Fixed`.
- `AGENTS.md` lists this record.
- `VERSION` and `packages/tui/package.json` move to `0.19.1` together, because
  the TUI runtime build fails when the two disagree.
- Tag `v0.19.1` publishes Linux x64/arm64 bundles through the existing release
  workflow.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| The new message is mistaken for a CLI failure | Low | Low | Phrase it as state ("has no hostnames"), not as an error code |
| The message wraps and truncates on narrow terminals | Medium | Low | Keep it to one short sentence; the existing banner already wraps |
| The `!` prefix implies something is broken | Low | Low | Acceptable: the action genuinely cannot proceed, and the reason is stated |
| Operators expect `x` to also delete orphaned DNS | Medium | Low | Out of scope and documented as such; the CLI/dashboard never delete DNS |
| Version and TUI package version drift | Low | High | Both are bumped in the release commit; the runtime build enforces equality |

---

## Out of Scope

| Item | Reason |
|------|--------|
| Deleting Cloudflare DNS records (including orphaned ones) | cftunnel deliberately leaves DNS to the operator; needs its own contract, plan, and confirmation |
| Auto-selecting a tunnel when none is selected | Would change navigation semantics silently |
| Removing a tunnel (as opposed to a hostname) from the dashboard | Separate operation with its own blast radius |
| Warning during `add` about shadowed DNS records | Unrelated to this defect |
| Changing `hostname remove` CLI output | The CLI already reports its own failures |

---

## Rollback Plan

Revert the two `app.tsx` hunks and the two tests. The change is stateless: it
adds no persistence, no contract field, and no external side effect.

---

## Acceptance Criteria

- [x] Pressing `x` with no selected tunnel shows `Select a tunnel before removing a hostname`.
- [x] Pressing `x` on a tunnel with no local hostnames names the tunnel and says there is nothing to remove.
- [x] Neither new path opens the `REMOVE HOSTNAME` overlay or hands off to the CLI.
- [x] DETAILS shows a hint when a tunnel has no local hostnames.
- [x] The removal flow for tunnels that do have hostnames is unchanged.
- [x] No command, JSON contract, DNS action, or persistent state is added.
- [x] `bun run typecheck` and `bun test` pass, including the pre-existing dashboard tests.
- [x] The shell suite (`cd tests && ./run.sh`) still passes.
- [x] `CHANGELOG.md`, `AGENTS.md`, `VERSION`, and `packages/tui/package.json` are updated.

(End of file)
