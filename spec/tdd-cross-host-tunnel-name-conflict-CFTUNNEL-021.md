# Technical Design Document — CFTUNNEL-021

> **Issue:** CFTUNNEL-021
> **Title:** Cross-host tunnel name conflict resolution
> **Version:** 0.18.0 → 0.18.1
> **Status:** Implemented
> **Date:** 2026-10-17
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Change Proposal](#change-proposal)
4. [Risk Assessment](#risk-assessment)
5. [Test Plan](#test-plan)
6. [Out of Scope](#out-of-scope)
7. [Rollback Plan](#rollback-plan)
8. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

`cftunnel add` derives the tunnel name from the hostname's base domain and the
origin type (`<base-domain>-<type>`). That name is therefore identical on every
host that manages the same Cloudflare zone. When a second host adds a hostname
in a zone that already has that derived tunnel, discovery finds the existing
tunnel, `add` reuses it, and the run then dies on a missing tunnel credential.

This TDD makes that situation detectable and recoverable: instead of reusing a
tunnel whose credential lives on another machine, `add` offers a host-scoped
name (`<derived>-<server-hostname>`) and, when even that is taken, prints an
explicit command so the operator can choose a name.

### Files in scope

| File | Change |
|------|--------|
| `lib/tunnel.sh` | Cross-host detection + host-scoped name resolution in `op_add` |
| `tests/test_add_remote_failures.sh` | Replace the obsolete reuse test; add conflict coverage |
| `AGENTS.md` | Document the new `op_add` step |
| `CHANGELOG.md` | Unreleased entry |

### Files NOT in scope

- `run.sh` — no new flags; the resolution reuses `--name`, `--yes`, `--no-dns`, TLS flags.
- `packages/tui/` — the TUI keeps calling `add --yes`; it benefits transparently.
- Installer/router/launcher code.

---

## Problem Statement

For `ollama.homelaberson.space` with `--type http` on a second host:

```
derived tunnel name: homelaberson-space-http
```

Sequence that produced the failure:

1. `op_add` performs exact-name discovery (`cloudflared tunnel list --name ...`).
2. The tunnel already exists because another host created it in the same account.
3. `op_add` prints `[=] tunnel '...' already exists (ok)` and skips creation.
4. `cloudflared tunnel create` never runs, so no `<UUID>.json` is written locally.
5. `op_add` dies at the credential check:

   ```
   credentials not found: .../zones/homelaberson.space/<UUID>.json
   (run 'cloudflared tunnel login' and recreate the tunnel)
   ```

The trailing guidance is wrong: `cloudflared tunnel login` obtains the *account*
certificate, not the tunnel credential. Cloudflare writes the tunnel credential
only on the host that created the tunnel and never exposes it again, so the two
hosts cannot share a name this way. The zone credential (`cert.pem`,
`zone.json`) is present and correct — the missing artifact is the tunnel
credential keyed by UUID.

### Why the current failure is not enough

- The message recommends an action that cannot fix it.
- It does not name the conflicting tunnel or explain the cross-host origin.
- It leaves the operator to hand-craft a `--name`, which the CLI could suggest.

---

## Change Proposal

### CP-01: Detect a credential-less discovered tunnel

In `op_add`, right after discovery, treat a found UUID as a cross-host collision
when no local credential exists for it:

```bash
if [[ -n "$UUID" ]] && ! tunnel_credential_present "$UUID"; then
    ...
fi
```

`tunnel_credential_present` checks the active zone directory and the legacy root
location that `op_add` migrates from. When the credential *is* local (the normal
same-host reuse), nothing changes.

### CP-02: Suggest a host-scoped name

`resolve_tunnel_name_conflict` derives `<derived>-<server-hostname>` via
`server_hostname_slug` (`hostname -s`, then `uname -n`, slugified) and verifies
the candidate is free with `tunnel_name_available` (no remote tunnel with that
exact name and no local YAML already owning it).

- **Interactive:** asks `Create a separate tunnel '<candidate>' for this host instead? [y/N]`.
- **`--yes` / non-interactive (the TUI path):** uses the candidate automatically
  and announces it. This keeps `add --yes` working instead of failing on a plan
  step (`hostname.add.plan` is offline and cannot predict the collision).
- **Candidate also taken, or hostname unavailable:** fails closed and prints a
  copy-pasteable command via `add_manual_command_hint`:

  ```
  cftunnel --zone homelaberson.space add --hostname ollama.homelaberson.space \
    --type http --service http://localhost:11434 --name <choose-a-name>
  ```

### CP-03: Actionable conflict notice

```
[!] A tunnel named 'homelaberson-space-http' already exists in this Cloudflare account, but this host has no credential for it.
    cloudflared writes a tunnel credential only on the machine that created the tunnel, and it cannot be downloaded again.
    The existing tunnel is left untouched; this host needs its own tunnel.
```

The generic post-create `credentials not found` message is also corrected to
point at `--name` instead of `cloudflared tunnel login`.

### Ordering, secrecy and fail-closed properties

- Conflict resolution runs **before** `sudo` and before any create/YAML/DNS
  side effect. A refused or unresolvable conflict touches nothing.
- The existing tunnel is never reused, renamed, or deleted.
- An uncertain candidate discovery (exit code 2) is never treated as "free".
- No token/PEM/remote-account output is printed; only names and paths.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `--yes` renames the tunnel relative to the reviewed plan | Low | Medium | The plan is offline by design and cannot know remote state; the deviation is announced on stderr and is additive/reversible via `remove` |
| Extra discovery call on the collision path | Low | Low | Only triggered when a credential is missing; one bounded query per candidate |
| Hostname-derived suffix collides again | Low | Low | Fails closed with an explicit command; no name is invented |
| Local credential reuse regressed | Low | High | Dedicated regression test asserts reuse with no host-scoped probe |

### Breaking changes

None for the CLI surface. `--name`, `--yes`, `--no-dns` and TLS flags are
unchanged. Behavior only differs where the previous outcome was a hard failure.

---

## Test Plan

`tests/test_add_remote_failures.sh`:

1. Local credential present → discovered tunnel is reused, no host-scoped probe.
2. Cross-host collision + `--yes` → host-scoped discovery then create, in order.
3. Host-scoped name also taken → fails closed before `sudo`, prints the explicit
   re-run command with `--name <choose-a-name>`.
4. Interactive decline → aborts before `sudo`, no tunnel created.
5. Interactive accept → uses the host-scoped name.

Regression: `bash -n lib/tunnel.sh` and the full `cd tests && ./run.sh` suite.

---

## Out of Scope

| Item | Reason |
|------|--------|
| Adopting/copying a foreign tunnel credential | Requires operator-supplied secrets; different feature |
| Predicting the collision in `--plan` | Would make the plan network-dependent and side-effecting |
| Token-based (remotely managed) tunnels | Tracked separately |
| Cleaning up orphaned suffix tunnels | Manual `remove` |

---

## Rollback Plan

1. `git checkout <base> -- lib/tunnel.sh` — removes detection and helpers.
2. `git checkout <base> -- tests/test_add_remote_failures.sh` — restores prior test.

No state migration; nothing is written outside the normal `add` artifacts.

---

## Acceptance Criteria

- [x] `bash -n lib/tunnel.sh` passes.
- [x] `cd tests && ./run.sh` passes (133 tests).
- [x] An existing tunnel without a local credential never triggers creation
      under its own name.
- [x] Interactive runs ask before using a host-scoped name; decline/uncertain
      paths touch no remote or local state.
- [x] `--yes` uses the host-scoped name automatically and announces it.
- [x] A second collision prints a copy-pasteable command with `--name`.

(End of file)
