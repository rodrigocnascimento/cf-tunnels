# Technical Design Document — CFTUNNEL-013

> **Issue:** CFTUNNEL-013
> **Title:** Remotely-Managed Tunnels — Deferred Implementation Contract and TUI Maturity Gates
> **Version:** N/A — deferred design record
> **Status:** Deferred — no implementation authorized
> **Date:** 2026-09-24

---

## Decision

`cftunnel` will remain local-managed by default. A remotely-managed tunnel
mode is an intended future capability, but it must not be implemented until
the TUI has a mature, tested command contract and has been used operationally
as the primary observability surface.

This document turns the exploration in CFTUNNEL-011 into an explicit future
implementation boundary. It authorizes no code, dependency, credential, API,
or documentation change by itself.

## Why defer it

Remote management improves host-loss recovery: a connector can be recovered
with a rotatable tunnel token instead of an irrecoverable local tunnel
credential. It also moves ingress configuration into Cloudflare's control
plane. That trade introduces a second management model, direct API contracts,
API-token authorization, token rotation, and a non-local source of truth.

The project must first have a stable way to present local state, failures,
logs, DNS checks, and command outcomes consistently. The TUI is not merely a
convenience feature in this decision: it is the operating surface through
which a future dual-mode model must remain understandable.

## Scope of the eventual feature

The eventual implementation may add an explicit per-tunnel mode such as:

```text
cftunnel add ... --managed local|remote
```

`local` remains the default. A remote tunnel must never be inferred from the
absence of a local YAML or selected implicitly by zone, account, or TUI.

The remote implementation must preserve the established properties wherever
they apply:

- explicit destructive confirmation;
- fail-closed remote discovery, create, update, and delete behavior;
- non-secret output and private local file permissions;
- one tunnel per supervised service instance unless a later design explicitly
  changes that isolation model;
- a clear indication of management mode in every human and machine-readable
  list/detail response.

## Required decisions before an implementation TDD

The following remain unresolved and must be proven with current Cloudflare
documentation and a disposable account/zone before code is planned:

1. The exact API endpoints, request bodies, response schemas, pagination, and
   error semantics for creating a remote tunnel, configuring ingress, reading
   configuration, obtaining/rotating connector tokens, and deleting it.
2. The least-privilege API-token model, including whether it can preserve the
   present zone-isolation guarantee and how account identifiers are obtained
   without unsafe discovery.
3. How connector tokens are stored locally, installed into systemd without
   appearing in process listings or logs, rotated, and removed.
4. Whether an existing locally-managed tunnel can migrate without a new UUID
   and DNS target. If not, migration is an explicit recreate-and-cutover flow,
   not a hidden conversion.
5. How local offline inventory and remote control-plane inventory coexist.
   `cftunnel list` must never silently change from offline local inspection to
   an uncertain network call. Separate commands or explicit freshness states
   are required.
6. How Cloudflare-side configuration is exported or snapshotted. Remote
   management removes host-state loss as the primary recovery risk; it does
   not protect against accidental tunnel/configuration deletion or account
   loss.

## TUI maturity gates

Do not begin the remote-mode implementation until all gates hold:

1. **Stable CLI contract.** Every public management command has documented
   input validation, exit states, stdout/stderr discipline, side effects, and
   a machine-readable result where the TUI needs structured state.
2. **Contract conformance tests.** Tests cover valid and invalid inputs,
   permission failures, dependency failures, uncertain Cloudflare responses,
   and no-partial-output behavior.
3. **Operational TUI.** The TUI can show local tunnel inventory, unit health,
   recent logs, route/service configuration, zone context, and clear command
   failures without parsing presentation tables.
4. **Observed operational use.** The TUI has been used during normal changes
   and at least one incident or recovery exercise, yielding concrete evidence
   about missing health/freshness/error states.
5. **Recovery baseline.** CFTUNNEL-012 backup and a documented restoration
   drill exist for locally-managed tunnels. Remote mode is not an excuse to
   leave the local model unrecoverable.

## Future implementation phases

When the gates pass, implementation must be proposed in a new, detailed TDD
and delivered in small phases:

1. Read-only remote inventory/detail with explicit network/freshness status.
2. API-token enrollment and secure secret storage, with token rotation tested.
3. Remote tunnel creation plus remote ingress configuration, fail-closed.
4. Per-tunnel systemd lifecycle and TUI presentation.
5. Explicit removal and a separately designed migration/cutover workflow.

No phase may make remote management the default or deprecate locally-managed
tunnels without a separate project decision.

## Out of scope

- Implementing remotely-managed tunnels.
- Adding `curl`, Cloudflare API tokens, or remote credential files.
- Changing the current local `list` offline guarantee.
- Building the TUI itself.
- Migrating current tunnels.

## Relationship to existing records

- CFTUNNEL-010 supplies the initial TUI/CLI subprocess and JSON boundary.
- CFTUNNEL-011 records the original exploration and its open technical facts.
- CFTUNNEL-012 provides the recovery baseline for locally-managed tunnels.

This document supersedes none of them. It is the explicit gate between the
exploration and any future implementation proposal.
