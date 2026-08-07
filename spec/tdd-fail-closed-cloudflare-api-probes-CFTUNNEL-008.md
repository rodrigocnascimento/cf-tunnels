# Technical Design Document — CFTUNNEL-008

> **Issue:** CFTUNNEL-008
> **Title:** Fail-Closed Cloudflare API Probes and Tunnel Discovery
> **Version:** 0.5.2 → 0.5.3
> **Status:** Implemented — acceptance criteria verified
> **Date:** 2026-07-23
> **Updated:** 2026-07-23
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Incident and Problem Statement](#incident-and-problem-statement)
3. [Current Behavior and Root Causes](#current-behavior-and-root-causes)
4. [Design Goals](#design-goals)
5. [Proposed Command Flow](#proposed-command-flow)
6. [Implementation Proposal](#implementation-proposal)
7. [Error and Output Contract](#error-and-output-contract)
8. [Test-Driven Delivery Plan](#test-driven-delivery-plan)
9. [Documentation and Release Plan](#documentation-and-release-plan)
10. [Risk Assessment](#risk-assessment)
11. [Out of Scope](#out-of-scope)
12. [Rollback Plan](#rollback-plan)
13. [Decision Gates](#decision-gates)
14. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

`cftunnel add` currently treats a failed Cloudflare tunnel-list request as
evidence that the requested tunnel does not exist. A transient DNS, network,
authentication, API, or response-parsing failure can therefore send the command
down the tunnel-creation path even though remote state is unknown.

The same invocation performs an earlier account-wide tunnel-list request inside
`check_cloudflared_version()`. That best-effort probe discards its failure
status, prints the raw `cloudflared` error, and then allows `add` to make another
request after confirmation. Users see the same API error twice with no
explanation of which operation failed.

This TDD proposes a patch-level fix that:

1. removes the unrelated automatic version probe from normal command startup;
2. makes tunnel discovery distinguish “not found” from “request failed”;
3. uses one exact-name discovery response as the source of an existing UUID;
4. uses structured `tunnel create --output json` output as the source of a new
   UUID;
5. validates all remote JSON and UUIDs before forming paths or changing local
   tunnel state; and
6. stops before tunnel creation, YAML, DNS, or systemd work when discovery is
   uncertain.

The supported installed dependency, `cloudflared 2026.7.2`, exposes both
`tunnel list --name NAME --output json` and
`tunnel create --output json NAME`. Implementation must still cover their
response contracts with fixtures rather than trusting unvalidated output.

Implementation was completed on the
`fix/cftunnel-008-fail-closed-api-probes` branch. The final suite contains 104
passing tests, including 16 focused fail-closed discovery and creation tests.

### Files expected to change during implementation

| File | Proposed change |
|------|-----------------|
| `run.sh` | Remove the automatic startup version probe and keep command dispatch otherwise unchanged |
| `lib/cloudflared.sh` | Remove the obsolete `check_cloudflared_version()` function; preserve the wrapper and explicit `cli-update` behavior |
| `lib/tunnel.sh` | Add fail-closed exact-name discovery, structured UUID extraction, and revised `op_add()` ordering |
| `tests/test_add_remote_failures.sh` | Add focused discovery, creation, malformed-response, and side-effect-ordering tests |
| `tests/run.sh` | Register the new integration tests |
| `tests/runner-lib.sh`, `tests/test_parser.sh`, `tests/test_list.sh` | Remove stale version-probe test scaffolding and expectations if no longer needed |
| `AGENTS.md` | Record the new `op_add()` remote-discovery and fail-closed conventions |
| `CHANGELOG.md` | Record the bug fix, tests, and intentional removal of the automatic probe |
| GitHub Wiki | Update `CLI-Reference.md` and `Operations-and-Troubleshooting.md` with failure and retry behavior |

No new Wiki page is proposed, so `_Sidebar.md` does not need to change.
`README.md` remains a concise visitor card and is not expected to change.

---

## Incident and Problem Statement

The motivating invocation was:

```bash
cftunnel add \
  --hostname example.shop \
  --type http \
  --service http://localhost:30418
```

During a transient resolver failure, `cloudflared` reported:

```text
Error Parsing page 1: REST request failed:
Get "https://api.cloudflare.com/client/v4/accounts/<account-id>/cfd_tunnel?...":
dial tcp: lookup api.cloudflare.com on <resolver>:53: server misbehaving
```

The message appeared once before the preview and again after confirmation.
After the second failure, `cftunnel` printed:

```text
[+] creating tunnel: example-shop-http
```

DNS resolution later recovered without any configuration change. A transient
external failure is expected in an online CLI; incorrectly classifying that
failure as an absent tunnel is the defect.

### Safety impact

The current flow creates several risks:

| ID | Severity | Current behavior | Impact |
|----|----------|------------------|--------|
| BUG-01 | High | Any failed discovery pipeline enters the create branch | Remote state is treated as known when it is unknown |
| BUG-02 | High | API failure and an empty successful list have the same control-flow result | A duplicate or conflicting create can be attempted |
| BUG-03 | Medium | The startup version probe ignores request failure | Users see an unexplained duplicate error and the command continues |
| BUG-04 | Medium | UUID lookup performs another account-wide list after creation | More latency and another failure point after a remote mutation |
| BUG-05 | Medium | Remote JSON shape and UUID format are not validated explicitly | Unexpected data can reach path and credential-file construction |
| BUG-06 | Low | `sudo -v` runs before the action preview and before useful remote preflight | Users may authenticate for an operation that cannot reach Cloudflare |

No credential contents were exposed in the observed error. The account-scoped
API URL is emitted by `cloudflared`, not constructed by cftunnel, but error
handling must never echo captured JSON account data or credential material.

---

## Current Behavior and Root Causes

### RC-01: The version probe deliberately erases failure

Current code in `check_cloudflared_version()`:

```bash
local output
output=$(cloudflared tunnel list --output json | cat || true)
```

The trailing `|| true` makes DNS, transport, authentication, API, and JSON
failures non-fatal. The wrapper preserves the real `cloudflared` exit code, but
this caller intentionally discards it.

The probe is also not a sound update mechanism:

- it uses an authenticated, account-scoped tunnel operation to infer dependency
  freshness;
- it searches captured stdout for `outdated`;
- the wrapper filters the known `"outdated"` warning from stderr; and
- `cftunnel cli-update` already provides an explicit update workflow.

The probe therefore adds a remote dependency and user-visible errors without a
reliable version-check result.

### RC-02: Discovery collapses every failure into “not found”

Current code in `op_add()`:

```bash
if ! cloudflared tunnel list --output json |
  jq -er ".[] | select(.name==\"$NAME\")" >/dev/null 2>&1; then
    echo "[+] creating tunnel: $NAME"
    cloudflared tunnel create "$NAME" >/dev/null
fi
```

With `set -o pipefail`, the condition is false when:

- Cloudflare successfully returns an empty array;
- DNS resolution fails;
- the TCP/TLS/API request fails;
- credentials are rejected;
- `cloudflared` returns non-zero for another reason;
- stdout is empty or malformed;
- `jq` cannot parse the response; or
- the expected object shape changes.

Only the first case means that the tunnel is absent. The other cases require the
operation to stop.

### RC-03: Discovery output is thrown away

Even when the first list succeeds and finds an existing tunnel, its UUID is
discarded. `op_add()` issues another account-wide list request:

```bash
UUID="$(cloudflared tunnel list --output json |
  jq -r ".[] | select(.name==\"$NAME\") | .id")"
```

For a new tunnel, this second request happens after `tunnel create`, when a
failure can leave a valid remote tunnel and credential file but no YAML or
service configuration.

### RC-04: Side-effect ordering does not match failure cost

`validate_flags_add()` currently calls `sudo -v` before the preview. The zone
directory is also ensured before confirmation and remote discovery.

The command can perform privileged authentication and local directory work
before learning that Cloudflare is unreachable. Conversely, moving sudo until
after remote creation would be unsafe because a sudo failure could strand a new
remote tunnel. The proposed sequence separates read-only discovery from remote
creation so both concerns can be satisfied.

---

## Design Goals

1. **Fail closed on uncertainty** — only a successful, valid empty exact-name
   response authorizes tunnel creation.
2. **No duplicate startup probe** — `add` must not list account tunnels merely
   to check the dependency version.
3. **One source per UUID** — reuse discovery JSON for an existing tunnel and
   create JSON for a new tunnel.
4. **Validate before path use** — require a canonical UUID before constructing
   credential or YAML paths.
5. **No downstream side effects after remote failure** — do not create or
   rewrite YAML, modify DNS, or change systemd state after an uncertain remote
   result.
6. **Preserve retry safety** — rerunning the same `add` command after a transient
   failure must discover and reuse a tunnel that was created remotely.
7. **Keep secrets and account data private** — do not print captured JSON,
   certificate contents, token contents, or full account listings.
8. **Keep explicit updates** — `cftunnel cli-update` remains the supported
   dependency-update command.
9. **No new runtime dependencies** — Bash and the existing `jq` dependency are
   sufficient.

---

## Proposed Command Flow

The revised `op_add()` sequence is:

```text
parse and validate add arguments
  ↓
verify local dependencies and systemd template exist
  ↓
derive canonical tunnel name, unit, and YAML path
  ↓
show action preview and obtain confirmation
  ↓
exact-name Cloudflare discovery (read-only)
  ├─ request failure ───────────────→ stop
  ├─ malformed/ambiguous response ─→ stop
  └─ valid result
       ↓
obtain sudo authorization
  ├─ failure ───────────────────────→ stop before remote creation
  └─ success
       ↓
existing tunnel?
  ├─ yes → validate/reuse discovered UUID
  └─ no  → create with JSON output → validate new UUID
       ↓
ensure zone directory and locate/move UUID credentials
  ↓
write or update private YAML
  ↓
validate ingress
  ↓
create DNS route unless --no-dns
  ↓
enable and verify systemd service
```

This ordering intentionally performs the read-only Cloudflare discovery before
`sudo -v`, but obtains sudo authorization before a possible remote create.

The discovery result can become stale between the list and create calls. That
race is safe: a concurrent creator causes `tunnel create` to fail, and cftunnel
stops without YAML, DNS, or systemd work. It must not silently reinterpret the
create failure as success.

---

## Implementation Proposal

### CP-01: Remove automatic startup version probing

- **Files:** `run.sh`, `lib/cloudflared.sh`
- **Action:** Remove the unconditional `check_cloudflared_version` call and the
  function itself.
- **Preserve:** `cloudflared()`, `update_cloudflared()`, and the `cli-update`
  dispatch.

Normal commands already execute the dependency when they need it. An unrelated
account tunnel listing should not be a startup gate or update detector.

The wrapper continues filtering only the known outdated-warning line from
stderr and continues returning the exact dependency exit code. Changing that
filter is separate from this fix.

### CP-02: Make add validation pure

- **File:** `lib/tunnel.sh`
- **Function:** `validate_flags_add()`
- **Action:** Remove `sudo -v` from validation. Keep required-field, type,
  protocol, and zone-containment checks.

Sudo authorization moves into `op_add()` after successful discovery and before
any possible `tunnel create`.

### CP-03: Add exact-name discovery

Add a small helper or an explicitly bounded block in `op_add()` that:

1. calls:

   ```bash
   cloudflared tunnel list --name "$NAME" --output json
   ```

2. captures stdout only when the command succeeds;
3. stops immediately on a non-zero dependency status;
4. requires the response to be a JSON array;
5. filters again with `jq --arg name "$NAME"` so client behavior never depends
   solely on the server-side name filter;
6. accepts exactly zero or one active exact-name match; and
7. treats multiple exact matches as ambiguous and stops.

The helper must not use `|| true`, a pipeline inside an `if ! ...` existence
test, or a command form that loses the original `cloudflared` status.

Conceptual control flow:

```bash
local tunnels_json
if ! tunnels_json="$(cloudflared tunnel list \
    --name "$NAME" --output json)"; then
    die "could not query Cloudflare tunnels; no tunnel was created"
fi

jq -e 'type == "array"' >/dev/null <<<"$tunnels_json" ||
    die "Cloudflare tunnel discovery returned an invalid response"
```

The implementation may use a temporary file instead of an in-memory variable
if that makes separate status and parsing tests clearer. Any temporary artifact
must be private and removed on every handled outcome.

### CP-04: Validate UUIDs explicitly

Add a focused validator for IDs consumed as tunnel UUIDs.

Required form:

```text
8-4-4-4-12 hexadecimal characters
```

Example:

```text
01234567-89ab-cdef-0123-456789abcdef
```

Validation happens before:

- constructing `<UUID>.json`;
- moving a credential file;
- writing `tunnel:` into YAML;
- constructing a `cfargotunnel.com` DNS target; or
- invoking a route command with the UUID.

An invalid UUID response fails without printing the remote JSON.

### CP-05: Reuse discovery data for existing tunnels

When one exact-name match exists:

1. extract `.id` with `jq -er --arg name "$NAME"`;
2. validate the UUID;
3. assign it directly to `UUID`; and
4. do not issue another tunnel-list request.

If the matching object lacks a usable ID, stop with an invalid-response error.
Do not fall back to tunnel creation because the name is known to exist.

### CP-06: Use structured creation output for new tunnels

When discovery succeeds with zero exact matches:

1. ensure sudo authorization is available;
2. print `[+] creating tunnel: $NAME`;
3. invoke:

   ```bash
   cloudflared tunnel create --output json "$NAME"
   ```

4. capture stdout without printing it;
5. require a successful dependency exit status;
6. extract the documented ID field from the JSON object;
7. validate it as a UUID; and
8. continue with the existing credential move and YAML flow.

Implementation must first add a fixture matching the JSON emitted by the
minimum supported `cloudflared` version. If supported versions do not share a
stable JSON ID field, the fallback is one exact-name list after successful
creation. That fallback must still fail closed and explicitly report that the
remote tunnel may already exist if UUID lookup fails.

On a non-zero create result, or success with unusable structured output,
cftunnel must not create YAML, DNS, or systemd state. It must not automatically
delete by name: the create request may have reached Cloudflare even when the
client did not receive a complete response.

### CP-07: Move local setup after confirmed remote state

Move `ensure_zone_dir` until after:

- confirmation;
- successful discovery;
- sudo authorization; and
- successful creation when creation is required.

Path derivation for the preview remains side-effect-free. Existing credential
transaction recovery performed by zone binding remains an allowed security
precondition and is not considered tunnel configuration.

### CP-08: Preserve downstream safeguards

The following existing behavior remains mandatory:

- `cloudflared()` selects and verifies the active zone credential;
- generated YAML values remain quoted;
- generated YAML mode remains `600`;
- ingress validation must succeed;
- DNS creation retains its retry behavior and `--no-dns` escape hatch;
- systemd starts only after YAML and DNS handling succeed; and
- no token, PEM, credential JSON, or captured account response is printed.

---

## Error and Output Contract

### Discovery request failure

The original filtered `cloudflared` diagnostic remains on stderr, followed by
one cftunnel summary:

```text
error: could not query Cloudflare tunnels for '<name>'; no tunnel was created
Check DNS/network connectivity and the active zone credential, then retry.
```

There must be no preceding automatic version-probe error and no
`[+] creating tunnel` line.

### Successful empty discovery

Only a valid empty array authorizes:

```text
[+] creating tunnel: <name>
```

### Malformed or ambiguous discovery

```text
error: Cloudflare tunnel discovery returned an invalid or ambiguous response;
no tunnel was created
```

The captured response is not printed.

### Uncertain creation outcome

```text
error: tunnel creation did not return a usable UUID; remote state may have
changed. Retry the same cftunnel add command to discover and resume safely.
```

No automatic delete or local YAML/DNS/systemd continuation occurs.

### Exit status

Every discovery, parsing, UUID, or creation failure exits non-zero. Cancellation
at the confirmation prompt continues to exit zero with `Aborted by user.`

---

## Test-Driven Delivery Plan

Implementation follows red/green/refactor. Tests use instrumented
`cloudflared`, `sudo`, filesystem, DNS, and `systemctl` fixtures; they must not
contact Cloudflare.

### Phase 1: Add failing tests

Create `tests/test_add_remote_failures.sh` with coverage for:

1. **No automatic startup probe** — a normal command does not perform an
   unscoped `tunnel list --output json` before dispatch.
2. **Transient discovery failure** — non-zero `cloudflared` status stops
   `op_add()` and does not invoke create, YAML writes, DNS, or systemd.
3. **Failure with empty stdout** — empty output plus non-zero status is not
   treated as an empty successful list.
4. **Failure with plausible stdout** — `[]` plus non-zero status still stops.
5. **Malformed JSON** — zero status with invalid JSON stops before create.
6. **Wrong JSON type** — zero status with `{}` or `null` stops before create.
7. **Empty array** — zero status with `[]` invokes create exactly once.
8. **Existing exact match** — one matching object reuses its UUID and never
   invokes create.
9. **No second list for existing tunnel** — the discovery response is reused.
10. **No second list for created tunnel** — create JSON supplies the UUID.
11. **Server-filter defense** — unrelated objects returned despite `--name`
    are ignored client-side.
12. **Duplicate exact matches** — two exact matches stop as ambiguous.
13. **Missing or invalid existing UUID** — stops before path construction and
    local changes.
14. **Create failure** — non-zero create status prevents YAML, DNS, and systemd.
15. **Malformed create JSON** — success without a usable ID reports uncertain
    remote state and prevents downstream changes.
16. **Invalid created UUID** — path construction and downstream work do not run.
17. **Sudo ordering on discovery failure** — failed discovery does not call
    `sudo`.
18. **Sudo ordering before create** — successful empty discovery calls `sudo -v`
    before `tunnel create`.
19. **Sudo failure** — failure stops before create and local tunnel changes.
20. **Retry after uncertain create** — a later existing-tunnel response resumes
    with the discovered UUID without attempting another create.
21. **Remote output secrecy** — captured list/create JSON is absent from both
    success and error output.
22. **Existing add regression** — valid existing and new tunnel paths still
    produce mode-`600` YAML and preserve the expected UUID credential path.

At least the failure-classification tests must fail against the current
implementation for the expected reason before production code changes.

### Phase 2: Minimal implementation

1. Remove the startup version probe and obsolete test scaffolding.
2. Make add validation pure.
3. Implement exact-name discovery and response validation.
4. Add UUID validation.
5. Reuse discovery JSON for existing tunnels.
6. consume structured create JSON for new tunnels.
7. Move sudo and zone-directory setup to the proposed positions.

### Phase 3: Refactor and regression verification

Run:

```bash
bash -n run.sh
bash -n lib/cloudflared.sh
bash -n lib/tunnel.sh
bash -n tests/test_add_remote_failures.sh
cd tests && ./run.sh --verbose
```

Then run the repository phases:

```bash
make smoke
make unit
make integration
make cli
make all
```

Manual verification must use a disposable tunnel name:

1. simulate offline DNS or a failing fixture and confirm no create line appears;
2. create a test tunnel through the normal flow;
3. rerun the same add command and confirm it reuses the existing UUID; and
4. remove the disposable tunnel through the supported fail-closed removal flow.

Do not induce DNS failure by modifying production resolver configuration as
part of the test.

---

## Documentation and Release Plan

The implementation change must update behavior descriptions in the GitHub Wiki
in the same documentation change:

| Wiki page | Required update |
|-----------|-----------------|
| `CLI-Reference.md` | State that `add` performs exact-name remote discovery and creates only after a successful empty response |
| `Operations-and-Troubleshooting.md` | Explain transient API/DNS failures, safe retry, and uncertain create outcomes |

No page is added or renamed, so the Wiki `_Sidebar.md` remains unchanged.

Repository engineering records:

- update `AGENTS.md` to remove the automatic version-check behavior and document
  fail-closed discovery;
- add an Unreleased `Fixed` entry to `CHANGELOG.md`;
- update the test count only after implementation determines the final total;
- keep `README.md` concise; and
- change `VERSION` only as part of the `0.5.3` release workflow.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `cloudflared create --output json` schema differs across supported versions | Medium | High | Establish the minimum supported fixture before implementation; retain a fail-closed exact-name lookup fallback if required |
| Removing the automatic probe eliminates an expected update prompt | Low | Low | The current wrapper removes the warning before the probe can reliably inspect it; retain explicit `cli-update` and document the decision |
| Exact-name server filtering returns unrelated records | Low | Medium | Re-filter locally with `jq --arg` and reject ambiguity |
| A concurrent process creates the name after discovery | Low | Medium | Let create fail and stop; retry discovers the resulting tunnel |
| Create reaches Cloudflare but the response is lost | Low | High | Report uncertain remote state, perform no downstream changes, and make same-command retry safe |
| Moving sudo later permits more work before privilege validation | Low | Medium | Perform only read-only remote discovery before sudo; obtain sudo before remote creation |
| UUID validation rejects a future non-UUID Cloudflare identifier | Low | Medium | Treat identifier-format changes as an explicit compatibility event rather than unsafe path input |
| Captured JSON leaks account metadata through debug output | Low | High | Never echo response variables; test stdout and stderr secrecy |
| Removing the probe leaves stale test assumptions | Medium | Low | Remove obsolete mocks and run every Makefile phase |

### Intentional behavior changes

- Normal commands no longer perform an automatic account tunnel listing for
  dependency-version detection.
- `add` no longer attempts creation when tunnel discovery fails.
- `add` uses exact-name discovery instead of retrieving the full active tunnel
  list for its existence check.
- Existing tunnel UUIDs come from the first discovery response.
- Newly created tunnel UUIDs come from structured creation output when the
  supported dependency contract permits it.
- Sudo is requested only after confirmation and successful read-only discovery,
  but before remote creation.

---

## Out of Scope

| Item | Reason |
|------|--------|
| Retrying Cloudflare tunnel discovery automatically | Retry policy can multiply latency and hide persistent authentication errors; explicit retry is safe |
| Changing the DNS propagation fallback chain | The incident concerns resolution of the Cloudflare API during management, not hostname propagation after route creation |
| Repairing Tailscale, systemd-resolved, NetworkManager, or `/etc/resolv.conf` | Host resolver administration is outside cftunnel's responsibility |
| Adding a general `--offline` mode to `add` | Tunnel discovery and creation are inherently remote |
| Automatically deleting a tunnel after uncertain creation | Remote outcome may be unknown; deletion by name could remove valid state |
| Reworking DNS-route retries or rollback | Separate post-creation lifecycle concern |
| Changing zone credential binding or transaction recovery | Existing CFTUNNEL-007 guarantees remain in force |
| Adding a remote `list` command | `cftunnel list` intentionally remains local and route-centric |
| Replacing `jq` | It is already a required dependency for remote JSON handling |
| Changing the explicit `cli-update` download/install workflow | Only the unrelated automatic probe is in scope |

---

## Rollback Plan

The code change does not migrate persistent formats. Rollback consists of
reverting:

- exact-name discovery and structured create parsing;
- revised sudo/directory ordering;
- removal of the startup probe; and
- associated tests and documentation.

Existing YAML, UUID credential JSON, zone credentials, metadata, DNS routes, and
systemd unit names remain compatible. No data rollback is required.

Re-enabling the previous “list failure means absent” branch is not recommended.
If structured create output proves incompatible, roll back only CP-06 to the
documented fail-closed post-create exact-name lookup fallback.

---

## Decision Gates

### DG-01: Automatic dependency version policy

**Recommendation:** Remove `check_cloudflared_version()` entirely. Keep
`cftunnel cli-update` explicit.

Alternatives considered:

| Option | Result |
|--------|--------|
| Keep the current probe but suppress failures | Retains an unnecessary authenticated account request and hides useful failure state |
| Query GitHub releases on normal startup | Adds a new network/API dependency and does not belong in tunnel operations |
| Compare only `cloudflared --version` locally | Cannot determine freshness without a remote source |

Approval of this TDD approves the recommended removal unless this gate is
reopened.

**Resolution:** Approved and implemented. Normal commands no longer perform an
automatic dependency-version probe; `cli-update` remains explicit.

### DG-02: UUID source after create

**Recommendation:** Parse `cloudflared tunnel create --output json`.

Before implementation, capture the non-sensitive output shape from the minimum
supported version in a fixture. If the JSON contract is not stable across the
supported range, use one exact-name list after creation and retain the uncertain
state error contract.

**Resolution:** The installed supported version and Cloudflare's implementation
confirm that structured create output contains the created tunnel object. The
implementation consumes and validates its exact-name `.id` without a second
list request.

### DG-03: Sudo ordering

**Recommendation:** preview → confirm → read-only discovery → sudo → optional
create.

This avoids a sudo prompt when Cloudflare is already known to be unreachable
while still preventing a new remote tunnel from being created before privilege
availability is established.

**Resolution:** Approved and implemented in the recommended order.

---

## Acceptance Criteria

- [x] A non-zero tunnel-list request can never authorize tunnel creation.
- [x] Only a successful, valid, empty exact-name response authorizes creation.
- [x] Malformed, wrong-type, missing-ID, invalid-UUID, and ambiguous discovery
      responses fail closed.
- [x] Discovery failure produces one contextual cftunnel error and does not
      produce `[+] creating tunnel`.
- [x] Normal command startup no longer performs the automatic account-wide
      version probe.
- [x] `cftunnel cli-update` remains functional.
- [x] Existing tunnels reuse the UUID from the first discovery response.
- [x] New tunnels use a validated UUID from structured create output or the
      approved fail-closed compatibility fallback.
- [x] No redundant tunnel-list call occurs on the supported happy paths.
- [x] Sudo is not requested before preview, confirmation, or a successful
      read-only discovery.
- [x] Sudo succeeds before any new remote tunnel is requested.
- [x] Discovery, create, parsing, or UUID failures do not write/rewrite YAML,
      create DNS routes, or modify systemd state.
- [x] Uncertain create outcomes are reported as uncertain and never trigger
      automatic deletion.
- [x] Retrying the same add command safely resumes when the tunnel now exists.
- [x] Captured remote JSON and credential contents never appear in output.
- [x] Generated YAML remains quoted and mode `600`.
- [x] Zone credential binding and recovery checks remain enforced.
- [x] `bash -n` passes for every modified shell file.
- [x] `cd tests && ./run.sh --verbose` passes.
- [x] `make smoke`, `make unit`, `make integration`, `make cli`, and `make all`
      pass.
- [x] `AGENTS.md`, `CHANGELOG.md`, and the affected Wiki pages are updated with
      the implementation.
- [x] `README.md` remains a concise visitor card.
