# Technical Design Document — CFTUNNEL-016

> **Issue:** CFTUNNEL-016
> **Title:** Ink + Bun Read-Only Operational TUI
> **Version:** 0.6.0 → 0.11.0
> **Status:** Approved for implementation
> **Date:** 2026-09-25

---

## Decision

Build the first cftunnel TUI as a React application using Ink and TypeScript,
executed by Bun. It is a separate process and a read-only client of the
versioned CFTUNNEL-015 JSON contract.

The TUI has three layers:

```text
Ink/React presentation → Bun operational adapter → cftunnel subprocess API
```

Only the Bun adapter spawns `cftunnel`. The UI does not execute shell strings,
call Cloudflare/systemd directly, parse human output, or read credentials.

## Package

The implementation lives in `packages/tui/` and has its own Bun package,
TypeScript configuration, and tests. The existing Bash CLI remains usable
without Bun, React, or Ink.

`cftunnel tui-dev` is the development launcher. It starts the checkout's Bun
entry point with `CFTUNNEL_BIN` bound to that same checkout's `run.sh`.
`cftunnel tui` is reserved for a future packaged production artifact and must
not silently fall back to development code.

## Read-only MVP

- Capability negotiation on startup; fail clearly on an unknown/missing
  contract.
- Discovery of every registered local zone, including zones without routes,
  with non-secret credential-binding state.
- An all-zones aggregate view and temporary dashboard zone selector. Selection
  never changes the persistent default zone.
- A dashboard layout with summary metrics, a tunnel navigator, and a selected
  tunnel detail panel with routes, unit, UUID, and local systemd status.
- Explicit selected-tunnel health check, including DNS observations.
- Explicit health check for the selected tunnel or the currently selected zone
  (including all zones), with visible in-progress and checked-at state.
- Per-tunnel local configuration indicators and actionable diagnosis for
  missing credentials, systemd state, and observed DNS failures.
- Interactive filtering by zone, tunnel name, hostname, and systemd state;
  refresh retains the selected tunnel when it remains available.
- Responsive navigation/detail panels for narrow terminals, plus explicit
  legend, inventory timestamp, and per-item issue presentation so partial
  local failures do not hide healthy inventory.
- A `tui-dev` preflight validates the local Bun runtime, source dependencies,
  package/CLI version parity, JSON capability contract, and terminal support.
- Keyboard actions: change zone scope, refresh inventory, request health, and
  quit.
- Refresh/error/freshness state visible without a Cloudflare Dashboard.

## Non-goals

- Create, remove, start, stop, zone login, or any sudo-bearing action.
- Password prompting, sudo authentication, direct API access, remote-managed
  tunnels, persistence, background monitoring, or alerts.
- Replacing the human CLI.

## Operational adapter

The adapter invokes an argument array, never a shell command string. It calls
`cftunnel capabilities --output json` before any other operation, validates
the common response envelope, validates the expected operation name, and
rejects malformed/non-zero responses without attempting presentation-output
fallbacks. `CFTUNNEL_BIN` optionally overrides the executable for development
and tests; the default is `cftunnel` on `PATH`.

## Bun + Ink compatibility gate

The implementation is accepted only if `bun test` covers a rendered Ink
component and a mocked subprocess adapter. If Ink behavior under Bun is not
usable for render/input/cleanup, this TDD must be revised before adding a
Node runtime fallback or selecting another UI framework.

## Acceptance criteria

- [ ] `bun run src/index.tsx` launches an Ink TUI under Bun.
- [ ] The UI is read-only and never invokes sudo, Cloudflare, or systemd.
- [ ] The adapter uses only CFTUNNEL-015 JSON commands and validates results.
- [ ] Missing capabilities and subprocess failures are actionable in the UI.
- [ ] The dashboard presents the selected tunnel's routes and explicit health
  result without requiring the Cloudflare Dashboard.
- [ ] Registered zones without local tunnels are visible with an actionable
  empty state; the all-zones view is available without mutating persistence.
- [ ] Health can be checked per tunnel or per selected scope, and its timestamp
  and partial operational observations remain visible in the dashboard.
- [ ] Narrow terminals expose navigation and detail through Tab-switchable
  panels without clipping critical content; partial local failures are shown
  on their affected zone/tunnel while other inventory remains visible.
- [ ] `tui-dev` fails before Ink rendering with actionable setup guidance when
  its runtime, source package, CLI contract, or terminal is unsuitable.
- [ ] `bun test` passes, including an Ink rendering smoke test.
- [ ] Bash tests remain green.
