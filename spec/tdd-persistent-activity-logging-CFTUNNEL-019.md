# Technical Design Document — CFTUNNEL-019

> **Title:** Persistent Structured Activity and Diagnostics Log
> **Status:** Approved for implementation
> **Date:** 2026-09-29

## Goal

Replace the TUI's memory-only Activity history with a small Bun CLI that writes
and queries local structured events. Bun is a build-time dependency only. The
release package includes the Bash CLI and one compiled Bun runtime artifact
that serves both the production TUI and log commands; end users do not install
Bun separately. The Bash CLI invokes the bundled runtime for log writes, while
the TUI invokes the same `cftunnel log query` contract.

The log command is part of the complete installation and logging is required
instrumentation. A write failure never changes the outcome of the tunnel
operation. Outside a TUI-managed invocation that failure is silent; in a TUI
managed invocation cftunnel emits a safe observability warning on stderr, which
the TUI presents separately from the operation result. The runtime is invoked
for each write or query; no resident daemon is required for the first version.

The primary security requirement is that tokens, PEM blocks, certificates, and
other credentials never reach persistent logs or TUI output.

## Storage

Use a private per-user state directory:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/cftunnel/logs/YYYY-MM-DD.jsonl
```

The date and timestamp are UTC. Each file is append-only JSON Lines, with one
complete JSON object per event. Create directories with mode `700` and files
with mode `600`; enforce those modes on existing paths before use. Reject
symlinks and non-regular files in the log path. Writes must append one
sanitized serialized line and must not rewrite prior records.

## Event contract

Each event has this shape:

```json
{
  "schema_version": 1,
  "timestamp": "2026-09-29T14:32:10.123Z",
  "type": "activity",
  "level": "error",
  "message": "Failed to create DNS route",
  "context": {
    "zone": "example.com",
    "hostname": "app.example.com",
    "operation": "hostname.add"
  }
}
```

Allowed types: `activity`, `cloudflare`, `systemd`, `journal`, `system`.
Allowed levels: `debug`, `info`, `success`, `warning`, `error`.
`context` is optional structured metadata. Do not persist raw command output,
credential contents, environment variables, or full config files.

## Redaction boundary

Redaction is mandatory on both write and read, and runs before serialization
and before display. This provides defense in depth for newly written entries,
old entries, and manually modified log files.

1. Recursively redact values for case-insensitive sensitive keys, including
   token, access token, API key, authorization, cookie, secret, password,
   credential, certificate/cert, private key, and PEM variants. Match common
   key spelling variants (`snake_case`, kebab-case, and camelCase).
2. Scan every string, including `message`, context values, and diagnostics, for
   PEM begin/end blocks, Bearer credentials, Cloudflare tunnel tokens, private
   key material, and known certificate encodings. Replace the entire secret
   value/block with `[REDACTED]` while retaining safe surrounding text.
3. Apply size and line-count limits to messages, nested strings, and events so
   logs cannot grow without bound from a single input.
4. If a string resembles an unsupported credential format and cannot be
   safely redacted, omit that string and record a safe marker such as
   `[details omitted: possible credential]`. Never fall back to raw text.
5. The read/query command redacts records again before emitting JSON or text.
6. Tests must assert that secret fixtures are absent from both the on-disk
   bytes and every output mode, including malformed/partial PEM blocks and
   nested fields.

Redaction patterns are not a guarantee that arbitrary binary or novel secret
formats can be recognized. Therefore producers must use structured safe
messages and must never pass credential files or whole environments to the
logger.

## CLI contract

Initial interface:

```text
cftunnel log write --type TYPE --level LEVEL --message MESSAGE [--operation NAME] [--zone NAME] [--hostname NAME] [--timestamp RFC3339]
cftunnel log write --stdin-json
cftunnel log query [--since RFC3339] [--until RFC3339] [--type TYPE] [--level LEVEL] [--zone NAME] [--hostname NAME] [--limit N] [--order asc|desc] [--output json|text]
```

`write` validates the event, redacts it, and appends one JSONL line. The JSON
stdin form accepts the complete event shape for TUI-produced diagnostics. It returns
nonzero if it cannot safely persist the event. Logging failure must not hide
the original operation's error; callers report both the operation failure and
that the diagnostic could not be persisted, without printing unsafe data.

`query` reads only matching daily files, ignores no malformed line silently,
and reports a safe warning with file/line for malformed records. It redacts
again, filters, sorts by timestamp ascending by default, applies the limit, and
emits JSON or a stable text row. The TUI requests newest-first results with a
small limit appropriate to the Activity pane.

The CLI must never evaluate shell strings. Callers pass an argument array and
JSON context as a single argument. No shell command text is reconstructed for
execution. The launcher passes an explicit `CFTUNNEL_RUNTIME_MODE=log|tui`
value; runtime dispatch must not rely only on argv heuristics, to prevent a log
query from starting another TUI recursively. `run.sh` resolves the runtime
next to its own real path; in a source checkout it uses `bun run` for log
queries while that runtime is under development. The installed package must
contain a matching compiled runtime artifact and must not rely on that
development fallback.

## TUI integration

- Replace the process-local `ActivityEvent[]` as the source of history with
  `cftunnel log query` through the existing cftunnel JSON subprocess boundary.
- After login, hostname add/remove, scope changes, health checks, and other
  cftunnel operations, write an `activity` event with a safe summary and
  operation outcome.
- Add corresponding `cloudflare` or `systemd` events only where cftunnel has a
  structured result. Do not claim to ingest all `journalctl` events in this
  version.
- Refresh Activity after writes and on explicit TUI refresh. Query failure
  appears as a bounded UI error and does not make the operational dashboard
  unusable.
- Render `[HH:MM:SS][TYPE]` with a level marker (`✓`, `✗`, `·`, or warning
  marker) and the sanitized message. Keep the detail log read-only.

## Retention and performance

The first version groups by UTC day and supports a configurable retention
period with a conservative default. Cleanup only removes validated regular
files matching the logger's exact dated filename pattern, inside the log
directory, and only when older than retention. Do not recursively delete
unknown files. Query reads at most the date range requested and caps returned
events; document any maximum.

Concurrent append behavior must be tested with multiple writers. If Bun's
append primitive cannot guarantee a complete line under concurrent processes,
use an advisory lock around each append. A daemon is considered only if
measured write volume or journal streaming requires one.

## Acceptance criteria

- [ ] The release package contains `run.sh` and the matching compiled Bun
      runtime used by both `cftunnel tui` and `cftunnel log`.
- [ ] Installed use of CLI, TUI, and logging does not require Bun on PATH.
- [ ] Bun CLI has stable write/query JSON contracts and a versioned schema.
- [ ] Writes produce UTC daily JSONL with private directory/file permissions.
- [ ] Redaction occurs before disk write and before every output mode.
- [ ] Tests prove no token, PEM, certificate, or private-key fixture appears on
      disk or in query output.
- [ ] Event ordering and filtering work across multiple daily files and
      out-of-order timestamps.
- [ ] Concurrent writers never produce interleaved or invalid JSONL records.
- [ ] TUI Activity reads persistent records and clearly handles query failure.
- [ ] Logging failure never masks the primary cftunnel operation result.
- [ ] No daemon or raw journal ingestion is required for initial delivery.
- [ ] Missing/failed log writes are silent for normal CLI calls and visibly
      reported as observability warnings in TUI-managed calls; tunnel operation
      exit status remains authoritative.
