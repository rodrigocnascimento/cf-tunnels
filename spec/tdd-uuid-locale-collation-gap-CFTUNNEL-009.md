# Technical Design Document — CFTUNNEL-009

> **Issue:** CFTUNNEL-009
> **Title:** Close Locale-Collation Validation Gap in `validate_tunnel_uuid()`
> **Version:** 0.5.3 → 0.5.4 (proposed)
> **Status:** CP-01 implemented and verified; CP-02/CP-03 remain optional and unimplemented
> **Date:** 2026-08-06
> **Updated:** 2026-08-06
> **Author:** Rodrigo Nascimento (drafted from a `/code-review high` finding against `main`)

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Code Review Findings](#code-review-findings)
4. [Change Proposals](#change-proposals)
5. [Risk Assessment](#risk-assessment)
6. [Test Plan](#test-plan)
7. [Out of Scope](#out-of-scope)
8. [Rollback Plan](#rollback-plan)
9. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

Commit `d17f2a8` (branch `fix/cftunnel-008-fail-closed-api-probes`) locked
`LC_ALL=C` around every bracket-range regex and case-folding operation that
validates untrusted input, after confirming that bash/glibc bracket ranges
like `[a-z]` and `[A-Za-z]` are locale-collation dependent: under a common
locale such as `en_US.UTF-8`, accented Latin letters can sort inside the
`a-z`/`A-Z` range and incorrectly pass validation meant to enforce ASCII-only
input.

That fix touched `validate_zone_name`, `hostname_belongs_to_zone`,
`validate_tunnel_token_file`, `print_cftunnel_version`, and `slugify` — but it
predates `validate_tunnel_uuid()`, which was introduced by the sibling
CFTUNNEL-008 work in the same branch and uses the exact same vulnerable
pattern. This TDD proposes closing that one remaining gap and adding
regression coverage for it, consistent with `d17f2a8`.

This review also surfaced two low-severity simplification/efficiency
observations in the surrounding discovery code. They are recorded here for
visibility but are not required to close the correctness gap and can be
picked up independently.

### Files expected to change during implementation

| File | Proposed change |
|------|-----------------|
| `lib/tunnel.sh` | Lock `LC_ALL=C` in `validate_tunnel_uuid()` |
| `tests/test_functions.sh` or a new `tests/test_tunnel_uuid.sh` | Add a regression test with an accented-Latin UUID-shaped string |
| `CHANGELOG.md` | Record the fix under `Unreleased` / `Fixed` |

No other files are expected to change.

---

## Problem Statement

### BUG-01 (Confirmed, High): `validate_tunnel_uuid()` is missing the `LC_ALL=C` lock applied everywhere else

**File:** `lib/tunnel.sh:61-67`

```bash
validate_tunnel_uuid() {
	local uuid="${1:-}"
	local uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
	[[ "$uuid" =~ $uuid_pattern ]] || return 1
	[[ "$uuid" != "00000000-0000-0000-0000-000000000000" ]] || return 1
	printf '%s\n' "${uuid,,}"
}
```

**Reproduced under `en_US.UTF-8`:**

```bash
$ bash -c '
uuid="1234567é-1234-1234-1234-123456789012"
[[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  && echo VULNERABLE || echo safe'
VULNERABLE
```

`é` (the accented form of `e`, which is inside the `a-f`/`A-F` range) collates
within the bracket range under `en_US.UTF-8` and is accepted where it must be
rejected. This is not hypothetical for this function specifically: `e` and
`a`-`f` are exactly the letters used by hexadecimal, so any accented variant
of those six base letters (`é`, `à`, `â`, `ç`-adjacent forms depending on
locale, etc.) is a candidate bypass, not just an unrelated Unicode character
like `ü` that falls outside the vulnerable sub-range.

**Why this matters more than a generic string bug:** `validate_tunnel_uuid()`
is the last gate before an identifier taken directly from Cloudflare API/
`cloudflared` JSON is used to build:

- `<UUID>.json` credential file paths (`discover_tunnel_uuid` /
  `create_tunnel_uuid` callers in `op_add`);
- the YAML `tunnel:` and `credentials-file:` lines; and
- the `<UUID>.cfargotunnel.com` DNS target.

This is exactly the class of unsafe value CFTUNNEL-008 introduced this
validator to stop — its own test suite already rejects a malicious value like
`../credential` — but the locale gap means an ASCII-hostile value with the
right accented byte sequence, appearing in a compromised or malformed
Cloudflare response, is not reliably rejected on a non-`C` locale host. Most
Linux hosts (including the environment this project targets) default to a
UTF-8 locale, so this is not an edge case.

**Impact if unaddressed:** Consistency and defense-in-depth regression. The
happy path (real Cloudflare-issued hex UUIDs) is unaffected; the gap only
matters for malformed/adversarial input, which is precisely the threat model
`d17f2a8` and CFTUNNEL-008 were written to close.

---

## Code Review Findings

Two additional low-severity findings from the same review are recorded for
completeness. Neither is a correctness bug and neither blocks BUG-01.

### OBS-01 (Low, simplification): `discover_tunnel_uuid` and `create_tunnel_uuid` duplicate their extract-validate-error block

**File:** `lib/tunnel.sh:80-138` (`discover_tunnel_uuid`) and
`lib/tunnel.sh:142-162` (`create_tunnel_uuid`)

Both functions end with the identical shape — extract a `.id` field with
`jq -er`, call `validate_tunnel_uuid`, and call a dedicated error function on
either failure — differing only in the `jq` filter and which error function
(`tunnel_discovery_error` vs. `tunnel_creation_error`) is invoked. A shared
helper taking the `jq` filter and error function as parameters would remove
the duplication and guarantee both callers stay in sync on future validator
changes (such as this TDD's fix).

### OBS-02 (Low, efficiency): `discover_tunnel_uuid` spawns five separate `jq` processes over the same payload

**File:** `lib/tunnel.sh:80-138`

The function forks `jq` five times (type check, `length` on the raw list,
name-filtered `matches_json`, `length` on the filtered list, then `.id`
extraction) to validate and read one response. A single combined `jq`
program producing an object like `{type, length, matches}` in one pass would
do the same validation with one process spawn and one JSON parse. This is a
performance/readability nit on the `cftunnel add` hot path, not a
correctness issue — CFTUNNEL-008 already reduced the *number of network
calls*; this observation is about *local* process-spawn overhead layered on
top of that single network call.

---

## Change Proposals

### CP-01: Lock `LC_ALL=C` in `validate_tunnel_uuid()`

- **File:** `lib/tunnel.sh`
- **Line:** 61-67
- **Action:** Add `local LC_ALL=C` immediately after the function's existing
  `local uuid=...` declaration, matching the pattern already used in
  `validate_zone_name` (`lib/zone.sh`) and `hostname_belongs_to_zone`
  (`lib/zone.sh`).

```bash
validate_tunnel_uuid() {
	local uuid="${1:-}"
	local LC_ALL=C
	local uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
	[[ "$uuid" =~ $uuid_pattern ]] || return 1
	[[ "$uuid" != "00000000-0000-0000-0000-000000000000" ]] || return 1
	printf '%s\n' "${uuid,,}"
}
```

**Rationale:** `[[ =~ ]]` is a bash builtin evaluated in-process, so a plain
`local LC_ALL=C` (no `-x`/export needed) is sufficient — this function does
not shell out to any external command. This mirrors `validate_zone_name`
exactly and keeps the fix's blast radius confined to this function's own
call stack, consistent with the reasoning already agreed for `d17f2a8`.

### CP-02 (optional, not required to close BUG-01): Extract a shared UUID-from-JSON helper

- **Files:** `lib/tunnel.sh`
- **Action:** Introduce `extract_and_validate_uuid(json, jq_filter, error_fn)`
  and have `discover_tunnel_uuid` / `create_tunnel_uuid` call it, removing
  the duplicated block described in OBS-01.
- **Sequencing:** Land after CP-01 and its tests are merged, as a separate
  refactor commit, so the correctness fix is not entangled with a structural
  change.

### CP-03 (optional, not required to close BUG-01): Combine `discover_tunnel_uuid`'s five `jq` calls into one

- **Files:** `lib/tunnel.sh`
- **Action:** Replace the five sequential `jq` invocations in
  `discover_tunnel_uuid` with a single `jq --arg name "$name"` program that
  emits one JSON object carrying type, total length, and the name-filtered
  matches, then branch in bash on that one parsed result.
- **Sequencing:** Independent of CP-01/CP-02; lowest priority of the three.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `LC_ALL=C` changes the accepted UUID charset for a legitimate non-ASCII Cloudflare identifier | Very Low | Low | Cloudflare tunnel UUIDs are documented as lowercase hex UUIDv4; `C` locale does not change ASCII hex-digit matching, only removes the accented-character bypass |
| CP-02/CP-03 refactors introduce a regression in the fail-closed discovery/create paths hardened by CFTUNNEL-008 | Low | High | Keep CP-02/CP-03 as separate, optional follow-up commits gated by the full `tests/test_add_remote_failures.sh` suite (22 tests); do not bundle with CP-01 |
| Fix is applied but no regression test locks it in | Medium | Medium | CP-01 ships with a dedicated test (see Test Plan) using the same accented-UUID string reproduced in this document |

### Breaking changes

None. CP-01 only rejects input that was already supposed to be rejected;
real Cloudflare-issued UUIDs (lowercase ASCII hex) are unaffected.

---

## Test Plan

### New regression test

Add to `tests/test_functions.sh` (co-located with the other `validate_*`
unit tests) or a new `tests/test_tunnel_uuid.sh`:

```bash
test_validate_tunnel_uuid_rejects_locale_collation_bypass() {
	local rc=0
	validate_tunnel_uuid "1234567é-1234-1234-1234-123456789012" >/dev/null 2>&1 || rc=$?
	assert_ne "0" "$rc" "reject accented-Latin UUID (locale collation bypass)"
}
```

This mirrors the pattern already established by
`test_slugify_strips_non_ascii_letters` and the `bücher.example.com` case
added to `test_hostname_belongs_to_zone_rejects_cross_zone_names` in
`d17f2a8`.

### Verification

```bash
bash -n lib/tunnel.sh
cd tests && ./run.sh --verbose
```

Confirm the new test fails against the current `main`/pre-fix code for the
documented reason (`en_US.UTF-8` accepts the accented UUID) before applying
CP-01, then passes after.

### Out of scope for this test plan

CP-02 and CP-03, if picked up, require their own test changes (verifying the
combined `jq` output shape and that `discover_tunnel_uuid`/
`create_tunnel_uuid` still produce identical behavior) and are not covered
here.

---

## Out of Scope

| Item | Reason |
|------|--------|
| Auditing other repositories/scripts for the same locale-collation class of bug | Outside this project's boundary |
| CP-02 (shared UUID helper) and CP-03 (single-`jq` discovery) implementation | Low-severity, non-blocking; tracked here for visibility only, not required to close BUG-01 |
| Re-auditing the five functions already fixed in `d17f2a8` | Already fixed and covered by existing regression tests |
| Changing the UUID format Cloudflare is expected to return | Cloudflare's contract is external; this fix only tightens local validation |

---

## Rollback Plan

CP-01 is a single-line, function-local addition with no persistent-format or
API impact. Rollback is reverting the one line in `validate_tunnel_uuid()`
and its accompanying test. No data migration is involved.

---

## Acceptance Criteria

- [x] `validate_tunnel_uuid()` locks `LC_ALL=C` before its regex check, matching
      the pattern used by `validate_zone_name` and `hostname_belongs_to_zone`.
      (`lib/tunnel.sh:63`)
- [x] A regression test reproduces the accented-UUID bypass, fails before the
      fix, and passes after. (`tests/test_add_remote_failures.sh`, extended
      `test_tunnel_uuid_validation_rejects_unsafe_values`; verified by
      stashing the fix and re-running the suite: 1 failure without it, 0 with it)
- [x] `bash -n lib/tunnel.sh` passes.
- [x] `cd tests && ./run.sh --verbose` passes with the new test included
      (105 passed, 0 failed).
- [x] `CHANGELOG.md` records the fix under `Unreleased` / `Fixed`.
- [x] No behavior change for legitimate lowercase-hex Cloudflare UUIDs
      (`test_tunnel_uuid_validation_accepts_and_normalizes_uuid` still passes).

CP-02 (shared UUID helper) and CP-03 (single-`jq` discovery) remain
unimplemented — they were recorded as optional and non-blocking and are not
required to close BUG-01.
