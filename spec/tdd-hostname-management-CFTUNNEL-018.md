# Technical Design Document — CFTUNNEL-018

> **Title:** Hostname Management Through Planned Tunnel Updates
> **Version:** 0.16.0
> **Status:** Approved for implementation
> **Date:** 2026-09-25

## Decision

Hostname is the primary operational resource inside a selected zone. A hostname
maps to a type (`http`, `ssh`, or `tcp`), a local origin service, and a local
tunnel ingress rule. The TUI uses the existing zone-and-type tunnel name as its
recommended target, thereby reusing a tunnel where possible.

The `http` type accepts both `http://` and `https://` local origins.

The CLI owns validation, Cloudflare mutation, credential use, DNS, sudo, YAML,
and systemd. The TUI never reconstructs those rules. It requests a JSON plan,
shows all effects, obtains explicit approval, then hands the real terminal to
the regular CLI apply command.

## Contract

```text
cftunnel --zone Z add --hostname H --type T --service S --plan --output json
```

returns `hostname.add.plan` without Cloudflare, sudo, DNS, YAML, or systemd
side effects. It includes the canonical invocation inputs, recommended tunnel,
unit, YAML path, whether the tunnel/hostname already exists, restart impact,
automatic DNS, and sudo requirement.

The approved apply form is:

```text
cftunnel --zone Z add --hostname H --type T --service S --yes
```

`--yes` skips only the legacy confirmation prompts. It does not skip
validation, fail-closed discovery, credential checks, ingress validation, DNS,
or systemd verification.

Exact-name discovery accepts either an empty array or the current cloudflared
`null` no-match representation only when the command exits successfully. Any
other shape remains an uncertain discovery and blocks mutation.

## TUI flow

`n` is available only when the selected Scope has a `bound` credential:

1. collect hostname label (`@`, `*`, a relative label, or an FQDN in Scope);
2. select HTTP, SSH, or TCP;
3. collect the origin service URL;
4. display the plan, including a warning when an existing tunnel must restart;
5. on Enter, unmount Ink and run the normal CLI apply in the real terminal;
6. restart the TUI after apply and refresh inventory.

SSH and TCP plans state their client-side Cloudflare Access requirement.

For an HTTPS origin, the TUI presents an Origin TLS step before planning. The
operator may send the public hostname as SNI and independently decide whether
to verify the origin certificate. The CLI also accepts an explicit custom
`--origin-server-name`. `--no-tls-verify` is visibly unsafe and is never the
implicit default.

The controller retains a bounded in-session Activity log across the temporary
unmount. It records the invocation and exit outcome plus a bounded, redacted
copy of stderr. This preserves actionable errors after the dashboard redraws
without retaining tokens, Bearer credentials, or PEM blocks.

## Safety requirements

- The CLI remains the hostname containment authority.
- An unverified zone cannot begin the TUI hostname flow.
- A plan has no side effects.
- Reusing a tunnel is visible before approval. Existing services are restarted
  after their YAML changes so the updated ingress is actually loaded.
- TLS choices are scoped to the hostname ingress rule. Updating one rule never
  removes nested origin settings from another hostname rule.
- Origin service editing and DNS deletion are deferred; no unsafe partial CRUD
  is implied by the add workflow.

## Hostname removal

`cftunnel hostname remove --hostname H --plan --output json` resolves `H` to
exactly one tunnel YAML within the active zone. Its plan identifies the tunnel,
the remaining local hostname count, the required service restart, and the DNS
boundary. Apply with `--yes` removes only that hostname's ingress block after
validating a staged YAML file. It preserves other hostnames, does not delete
the Cloudflare DNS record, and never deletes the tunnel itself.

## Acceptance criteria

- [ ] Plan contract is machine-readable and local-only.
- [ ] TUI does not apply before an explicit plan confirmation.
- [ ] The recommended zone/type tunnel is visible in the plan.
- [ ] Existing tunnel configuration changes restart the relevant service.
- [ ] SSH/TCP client guidance is visible.
