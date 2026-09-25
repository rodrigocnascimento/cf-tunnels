# Technical Design Document — CFTUNNEL-016

> **Issue:** CFTUNNEL-016
> **Title:** Ink + Bun Operational TUI
> **Version:** 0.6.0 → 0.13.0
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

## Operational dashboard

- Capability negotiation on startup; fail clearly on an unknown/missing
  contract.
- Discovery of every registered local zone, including zones without routes,
  with non-secret credential-binding state.
- The dashboard begins at the first registered local zone; its Scope is always
  a real zone, never an all-zones virtual selection.
- Switching Scope renders an explicit confirmation. On confirmation the Bun
  adapter invokes `zone use <zone> --output json`, so the displayed Scope and
  the CLI default zone remain synchronized. A user may disable this prompt for
  the current TUI session only; no preference is persisted before the future
  settings screen exists.
- `a` begins an add-zone flow: collect a Cloudflare zone, render the help and
  effects of `zone use` and `zone login`, then register it and begin login.
  `l` independently begins login for the current Scope. Before browser auth,
  Ink unmounts and the regular CLI owns the terminal; the TUI restarts after
  that command exits and refreshes credential state.
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

- Create, remove, start, stop, zone login, `zone unset`, or any sudo-bearing
  action other than the explicitly confirmed zone registration/scope change.
  Zone login remains the regular CLI browser-auth process, temporarily handed
  the terminal by the TUI rather than implemented inside Ink.
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
- [ ] The UI never invokes sudo, Cloudflare, or systemd directly. It can only
  invoke the local, non-privileged `zone use` JSON contract after explicit
  confirmation.
- [ ] The adapter uses only CFTUNNEL-015 JSON commands and validates results.
- [ ] Missing capabilities and subprocess failures are actionable in the UI.
- [ ] The dashboard presents the selected tunnel's routes and explicit health
  result without requiring the Cloudflare Dashboard.
- [ ] Registered zones without local tunnels are visible with an actionable
  empty state; initial Scope is the first registered zone.
- [ ] Scope changes are explicit, persist through `zone use`, and can be
  cancelled without changing the default zone. Confirmation suppression ends
  when the TUI process exits.
- [ ] Adding a zone and standalone current-Scope login both show their command
  help/effects before confirmation. Browser login receives the real terminal,
  and the restarted TUI reports the resulting credential state.
- [ ] Health can be checked per tunnel or per selected scope, and its timestamp
  and partial operational observations remain visible in the dashboard.
- [ ] Narrow terminals expose navigation and detail through Tab-switchable
  panels without clipping critical content; partial local failures are shown
  on their affected zone/tunnel while other inventory remains visible.
- [ ] `tui-dev` fails before Ink rendering with actionable setup guidance when
  its runtime, source package, CLI contract, or terminal is unsuitable.
- [ ] `bun test` passes, including an Ink rendering smoke test.
- [ ] Bash tests remain green.
