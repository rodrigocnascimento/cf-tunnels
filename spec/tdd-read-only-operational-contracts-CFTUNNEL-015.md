# Technical Design Document — CFTUNNEL-015

> **Issue:** CFTUNNEL-015
> **Title:** Read-Only Operational Contracts — First TUI Foundation
> **Version:** 0.5.4 → 0.6.0
> **Status:** Approved for implementation
> **Date:** 2026-09-24

---

## Decision

Implement the first, read-only slice of CFTUNNEL-014 before any TUI or
mutating non-interactive command. The slice adds JSON contracts and local
observability without changing the default human CLI output.

## Commands

| Command | JSON operation | Side effects | Sudo |
|---|---|---|---|
| `capabilities --output json` | `capabilities` | none | no |
| `zone list --output json` | `zone.list` | none | no |
| `zone current --output json` | `zone.current` | none | no |
| `zone use NAME --output json` | `zone.use` | create/register selected zone | no |
| `zone unset --output json` | `zone.unset` | clear default-zone file | no |
| `list --output json` | `tunnel.list` | none | no |
| `status --name NAME --output json` | `tunnel.status` | none | no |
| `health [--name NAME] --output json` | `tunnel.health` | DNS reads only | no |
| `privilege check --output json` | `privilege.check` | none | no |

All successful JSON responses have `schema_version: 1`, `operation`,
`ok: true`, `data`, and `warnings`. Errors write no stdout and exit non-zero.
The default output for pre-existing commands is unchanged.

`health` is an explicit live local check: it examines readable local YAML and
credential paths, queries systemd without sudo, and resolves configured
hostnames through the established DNS fallback. It never calls Cloudflare.

`status` becomes genuinely no-sudo: the redundant `sudo -v` preceding an
unprivileged `systemctl status` call is removed.

`privilege check` performs `sudo -n -v`; success means the normal sudo cache
is usable, failure returns `available: false` as a successful probe instead
of prompting. The interactive `privilege authenticate` command and any
`sudo -n` mutation conversion are deferred to the next slice.

## Schemas

### Common response

```json
{
  "schema_version": 1,
  "operation": "tunnel.status",
  "ok": true,
  "data": {},
  "warnings": []
}
```

### `tunnel.list`

`data` contains `scope_zone` (`string` or `null`) and `tunnels`. Every
tunnel has `zone`, `name`, `uuid` (`string` or `null`), `unit`, `status`
(`active`, `enabled`, or `inactive`), `routes` (`hostname`, `service`), and
`config`, which reports non-secret YAML and tunnel credential-file
presence/mode.
`--all-zones` is a read-only explicit scope for `list` and `health`; it cannot
be combined with `--zone` and prevents loading the persistent default zone.

### `zone.list`

`data` contains `default_zone` and every valid local directory under
`~/.cloudflared/zones`. Each zone reports `name`, `is_default`, local
`tunnel_count` and `route_count`, and a non-secret credential summary. The
summary reports presence/mode for `cert.pem` and `zone.json`, plus `state`:
`ready` when the local token and binding metadata validate without mutation,
`missing` when either file is absent/unreadable, or `invalid` otherwise.

### `tunnel.status`

`data` contains `zone`, `name`, `unit`, `status`, `source: "systemd"`, and
an RFC 3339 UTC `checked_at` field.

### `tunnel.health`

`data` contains `scope_zone`, RFC 3339 UTC `checked_at`, and `tunnels`.
Each item contains identity plus `config` (`mode`, `uuid`, credential
presence/mode), `systemd` (`status`, `source`), and per-route `dns`
observations (`hostname`, `result`, `cname_check_available`, `checked_at`).

### `privilege.check`

`data` contains `available` and `reason` (`cached` or `sudo_auth_required`).
It does not expose sudo diagnostics.

## Parsing

`--output text|json` is a global option accepted anywhere. It defaults to
`text`. `--zone` selects only the current invocation. It no longer prompts to
persist a different default zone; only `--persist` persists it. `--all-zones`
is limited to the read-only inventory commands described above.

## Verification

Add fixtures for JSON schema/empty output, local-only behavior, no-sudo
status and health, zone-context no-prompt behavior, DNS health output, and
non-interactive privilege probing. Preserve the full legacy suite.
