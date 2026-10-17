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

It also guarantees the failure modes around DNS never leave an orphan: `add`
performs a best-effort DNS ownership check before creating anything and rolls
back the tunnel and local files it created when configuration fails.

### Files in scope

| File | Change |
|------|--------|
| `lib/tunnel.sh` | Cross-host detection, host-scoped name resolution, DNS preflight and rollback in `op_add` |
| `tests/test_add_remote_failures.sh` | Replace the obsolete reuse test; add conflict, preflight and rollback coverage |
| `install.sh` | Non-fatal `check_dns_tools` hint |
| `AGENTS.md` | Document the new `op_add` steps |
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

### CP-04: Best-effort DNS ownership preflight

Before `sudo` and before creating anything, `op_add_dns_preflight` reads the
public hostname with `resolve_hostname` (only when `dig`/`host` are available)
and fails closed when it positively resolves to a *different* tunnel's
`<uuid>.cfargotunnel.com` CNAME:

```
error: 'ollama.homelaberson.space' is already served by another tunnel (<uuid>).
```

This is deliberately best-effort and never a false positive:

- A hostname owned by the tunnel being reused passes.
- `--no-dns`, missing `dig`/`host`, an empty answer, or a non-tunnel record all
  fall through without blocking. Proxied records are not visible to a public
  resolver, so they also fall through.

The preflight is an optimization; CP-05 is the guarantee.

### CP-05: Roll back artifacts created by the failed run

`op_add` splits DNS work into `op_add_route_dns` (ingress validation + CNAME
creation) and `op_add_verify_dns` (propagation wait). When `op_add_route_dns`
fails and **this run created the tunnel**, `rollback_created_add` deletes the
remote tunnel and removes the YAML and `<UUID>.json` written by this run.

- Only artifacts created by this run are touched. A tunnel that already existed
  (local credential reuse) is never deleted.
- `op_add_verify_dns` runs after the CNAME exists, so a propagation timeout or
  declining "continue anyway" is reported **without** rollback — the record may
  simply be slow to propagate.
- If remote deletion fails, the local files are still removed and the exact
  `cloudflared tunnel delete <uuid>` command is printed.

### Ordering, secrecy and fail-closed properties

- Conflict resolution runs **before** `sudo` and before any create/YAML/DNS
  side effect. A refused or unresolvable conflict touches nothing.
- The DNS ownership preflight (`op_add_dns_preflight`) also runs before `sudo`
  and before any side effect.
- The existing tunnel is never reused, renamed, or deleted.
- An uncertain candidate discovery (exit code 2) is never treated as "free".
- Rollback only removes artifacts created by the failing run; a tunnel that
  pre-existed is never deleted by a rollback.
- No token/PEM/remote-account output is printed; only names and paths.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `--yes` renames the tunnel relative to the reviewed plan | Low | Medium | The plan is offline by design and cannot know remote state; the deviation is announced on stderr and is additive/reversible via `remove` |
| Extra discovery call on the collision path | Low | Low | Only triggered when a credential is missing; one bounded query per candidate |
| Hostname-derived suffix collides again | Low | Low | Fails closed with an explicit command; no name is invented |
| Local credential reuse regressed | Low | High | Dedicated regression test asserts reuse with no host-scoped probe |
| Preflight blocks a legitimate re-add | Low | Medium | Only positive evidence of a *different* tunnel's CNAME blocks; missing tooling, `--no-dns` and non-tunnel records fall through |
| Rollback deletes a pre-existing tunnel | Low | High | Rollback is armed only when this run created the tunnel; a dedicated test asserts no deletion on reuse |
| Rollback leaves a dangling CNAME | Low | Low | Rollback only triggers before the CNAME is created (`op_add_route_dns`); post-route timeouts never roll back |

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
6. Preflight → blocks a hostname owned by a different tunnel before `sudo` and
   before create; passes when owned by this tunnel; falls through without
   tooling, without `--no-dns`, and for non-tunnel records.
7. Rollback → deletes the remote tunnel and removes the YAML/credential created
   by this run when the DNS step fails; reports a manual command when deletion
   fails.
8. Reuse → a failure after `op_add_route_dns` does not delete a pre-existing
   tunnel or its credential.
9. `install.sh` → `check_dns_tools` warns without failing when `dig`/`host` are
   missing.

Regression: `bash -n lib/tunnel.sh install.sh` and the full `cd tests && ./run.sh`
suite.

---

## Out of Scope

| Item | Reason |
|------|--------|
| Adopting/copying a foreign tunnel credential | Requires operator-supplied secrets; different feature |
| Predicting the collision in `--plan` | Would make the plan network-dependent and side-effecting |
| Token-based (remotely managed) tunnels | Tracked separately |
| Cleaning up tunnels orphaned by earlier failed runs | Outside the preflight/rollback window; manual `remove` |
| DNS ownership check via the Cloudflare API | Would add a `CF_API_TOKEN` dependency; the resolver preflight plus rollback suffices |

---

## Rollback Plan

1. `git checkout <base> -- lib/tunnel.sh` — removes detection and helpers.
2. `git checkout <base> -- tests/test_add_remote_failures.sh` — restores prior test.

No state migration; nothing is written outside the normal `add` artifacts.

---

## Acceptance Criteria

- [x] `bash -n lib/tunnel.sh` and `bash -n install.sh` pass.
- [x] `cd tests && ./run.sh` passes (145 tests).
- [x] An existing tunnel without a local credential never triggers creation
      under its own name.
- [x] Interactive runs ask before using a host-scoped name; decline/uncertain
      paths touch no remote or local state.
- [x] `--yes` uses the host-scoped name automatically and announces it.
- [x] A second collision prints a copy-pasteable command with `--name`.
- [x] A hostname already served by a different tunnel is refused before `sudo`
      and before any create, when `dig`/`host` can prove it.
- [x] A failure while creating the DNS route removes the tunnel and local files
      created by that run, and never a pre-existing tunnel.
- [x] `install.sh` warns (without failing) when `dig`/`host` are unavailable.

(End of file)
