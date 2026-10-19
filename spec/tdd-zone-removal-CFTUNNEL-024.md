# Technical Design Document — CFTUNNEL-024

> **Issue:** CFTUNNEL-024
> **Title:** Complete Zone Removal (CLI and TUI)
> **Version:** 0.19.1 → 0.20.0
> **Status:** Implemented
> **Date:** 2026-10-19
> **Author:** Rodrigo Nascimento

## Decision

A zone is a self-contained operational unit: one directory, one credential,
one or more tunnel YAML/credential pairs, one systemd unit per tunnel, and the
Cloudflare tunnels and DNS records those YAMLs describe. Removing a zone must
therefore remove all of it, or stop and leave the remaining state recoverable.

The command is:

```text
cftunnel zone remove <domain> [--plan|--yes] [--output json]
```

`<domain>` is mandatory. The command never infers its target from the active
`--zone` or the persisted default zone. `zone remove` stops being an alias of
`zone unset`; `zone unset` and `zone clear` keep their current meaning
(clear the default pointer, delete nothing).

The TUI exposes the same operation on the active Scope. It follows the
established plan → explicit confirmation → real-terminal handoff pattern; it
never mutates Cloudflare or local state itself.

## Inventory

Everything removed is discovered from local state only. Remote account-wide
listings are never used to decide what to delete.

From `~/.cloudflared/zones/<domain>/`:

- `*.yml` — one file per tunnel; yields the tunnel name, `tunnel:` UUID,
  credential path, and ingress hostname/service routes;
- `<UUID>.json` — the per-tunnel credential;
- `cert.pem` — the zone-scoped Cloudflare credential;
- `zone.json` — credential metadata and fingerprint;
- credential-transaction artifacts (`.credential-transaction*`,
  `.cert.pem.commit.*`, `.zone.json.commit.*`, `*.recover.*`);
- any remaining files in the directory, reported in the plan as `other`.

Derived, outside the directory:

- `cloudflared@<domain>_<name>.service` for every local tunnel;
- `~/.cloudflared/.default_zone` when it names this zone.

The shared `cloudflared@.service` template, the root
`~/.cloudflared/cert.pem`, other zones, and root-level legacy YAML files are
never touched.

## Plan contract

```text
cftunnel zone remove Z --plan --output json
```

returns `zone.remove.plan` with:

- `zone` — canonical domain;
- `zone_dir` — canonical local directory;
- `tunnels[]` — `{name, uuid, unit, yaml, credential, routes[]}`;
- `files` — `{known, other, total}` counts;
- `credential` — `{state}` for the zone credential;
- `default_zone` — `{current, will_clear}`;
- `dns` — `{mode: "automatic" | "manual", token_present, records[]}`, where
  `records[]` entries are `{hostname, content}` derived locally from the
  routes and UUIDs;
- `privilege` — `{sudo_required}`;
- `warnings[]` — non-fatal inventory gaps.

The plan is local-only: no sudo, no Cloudflare call, no DNS lookup, no file
mutation. JSON mode requires `jq`, as with every other contract.

The plan fails closed before reporting success when:

- the domain is not canonical, or the zone directory does not exist;
- any YAML names a tunnel UUID that is missing, duplicated, or invalid;
- the zone directory is a symlink or resolves outside
  `~/.cloudflared/zones/`;
- `~/.cloudflared/.default_zone` cannot be read or validated.

## Apply flow

1. Build and validate the plan.
2. Print the plan in text mode (tunnels, units, routes, DNS mode, files,
   default-pointer effect).
3. Without `--yes`, require the operator to type the exact canonical zone
   name. Any other input aborts with exit 0 and no mutation. `--yes` skips
   only this typing step; it never skips validation or fail-closed checks.
4. Verify the zone credential binding before any remote call. If the zone has
   local tunnels but no valid credential, fail without deleting anything.
5. Query remote tunnels once with the zone credential
   (`cloudflared --origincert <zone>/cert.pem tunnel list --output json`).
   A failed, malformed, or ambiguous response stops the run before any
   deletion.
6. Obtain sudo authorization and disable/stop each recorded unit. Unit
   failures are reported but do not abort, matching `tunnel remove`.
7. For each tunnel in deterministic (sorted) order:
   1. skip the remote delete when the UUID is absent from the verified
      remote list (already removed by an earlier partial run);
   2. otherwise `cloudflared --origincert <zone>/cert.pem tunnel delete
      <UUID>`;
   3. delete matching DNS records (see below);
   4. remove that tunnel's YAML and `<UUID>.json`.
8. Remove the remaining zone directory after re-validating its canonical
   path, then clear `~/.cloudflared/.default_zone` when it names this zone.
9. Emit the summary (`zone.remove` in JSON mode).

A remote failure at steps 5–7 stops the run. Everything already deleted is
reported; local files for the failed tunnel, the zone credential, and the
default pointer are preserved so a re-run can finish. Because step 7.1
tolerates already-deleted tunnels, the re-run is safe.

## DNS deletion

DNS deletion is optional and never weakens the tunnel deletion.

- Token source: `CF_API_TOKEN` from the environment only. Nothing is written
  to disk.
- Zone id: `CF_ZONE_ID` when set, otherwise resolved once through
  `GET /client/v4/zones?name=<domain>` before any deletion.
- Only records that match **both** `name == <hostname>` and `type == CNAME`
  and `content == <UUID>.cfargotunnel.com` are deleted. Comparison is
  case-insensitive and ignores one trailing dot. A record with different
  content is reported as `skipped` and left alone; wildcards are matched
  literally.
- No token, no `curl`, or no `jq`: `dns.mode = "manual"`. Apply proceeds and
  prints the records to remove manually. DNS absence is not a tunnel-deletion
  failure.
- Token present but authentication, zone lookup, record listing, or deletion
  fails: the run stops fail-closed at that tunnel. The tunnel and its local
  files stay recorded so a re-run can retry DNS.
- Tokens and `Authorization` headers are never printed, logged, or stored in
  the activity event.

## TUI flow

`D` acts on the active Scope:

1. with no Scope, report "Select a zone before removing it" and do nothing;
2. request `zone remove <scope> --plan --output json` and render the returned
   inventory (tunnels, hostnames, units, DNS mode, default-pointer effect);
3. require the operator to type the exact zone name; while the input differs,
   Enter explains the mismatch and does not proceed, and Esc cancels without
   side effects;
4. on confirm, unmount Ink and run `cftunnel zone remove <scope> --yes` in the
   real terminal, then restart the dashboard and refresh;
5. report plan and apply failures in the view; never leave the operator with
   an unchanged screen.

The footer advertises `[D] remove zone`. `zoneRemovePlan` is an optional
operation so an older TUI keeps working against a newer CLI and vice versa;
when the capability is absent the TUI explains that the installed cftunnel
cannot plan zone removal.

## Activity logging

A successful apply logs `zone.remove` once. A plan logs nothing. Aborted
confirmations log nothing. Failure details are persisted through the existing
redacted `runExternal` diagnostic path when the TUI performs the handoff.

## Verification

CLI (`tests/test_zone_remove.sh`, wired into `tests/run.sh`):

- plan is local-only and rejects noncanonical, missing, symlinked, and
  invalid-UUID zones;
- typed confirmation mismatch and Esc abort without mutation;
- full teardown removes tunnels, units, YAML/JSON files, the directory, and
  the default pointer;
- remote list/delete failure preserves the failed tunnel and zone credential;
- a re-run after partial deletion finishes cleanly;
- DNS: absent token → manual warning; matching CNAME deleted; different
  content untouched; API failure fails closed;
- other zones, the root credential, and the shared template are untouched;
- `--output json` envelopes validate and `zone remove` no longer aliases
  `zone unset`.

TUI (`bun run typecheck && bun test`):

- `zone remove --plan --output json` argument shape;
- no-Scope message, plan overlay, typing requirement, Esc cancel, and
  confirm handoff;
- missing capability produces an explanation instead of a silent no-op.

## Documentation

Update the usage text, `CHANGELOG.md` under `[Unreleased]`, and the Wiki
`Zone-Isolation`/`Command-Reference` pages plus `_Sidebar.md` when the page
set changes. `AGENTS.md` gains the `zone remove` behavior note and this spec
reference.

## Acceptance criteria

- [x] `zone remove <domain>` is the only destructive zone command and demands
      an explicit target.
- [x] Planned output is complete, machine-readable, and side-effect free.
- [x] Typed confirmation is required unless `--yes` is passed.
- [x] Tunnel, DNS, unit, file, and default-pointer removal are all reported.
- [x] Any remote failure preserves enough local state for a safe re-run.
- [x] DNS deletion is scoped to records owned by the zone's tunnels.
- [x] The TUI never applies without its own explicit confirmation.
- [x] Existing zones, root credentials, and the systemd template are intact
      after any failure.
- [x] `tests/test_zone_remove.sh`, `bun run typecheck`, and `bun test` pass.
- [x] `CHANGELOG.md`, `AGENTS.md`, `VERSION`, and `packages/tui/package.json`
      are updated.

(End of file)
