# Technical Design Document — CFTUNNEL-007

> **Issue:** CFTUNNEL-007
> **Title:** Safe Zone Registration and Credential Binding
> **Version:** 0.4.0 → 0.5.0
> **Status:** Implemented — acceptance criteria verified
> **Date:** 2026-07-18
> **Updated:** 2026-07-19
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Current Behavior and Root Causes](#current-behavior-and-root-causes)
4. [Trust Boundaries](#trust-boundaries)
5. [CLI Contract](#cli-contract)
6. [Zone Name Contract](#zone-name-contract)
7. [Registration Architecture](#registration-architecture)
8. [Credential Binding Architecture](#credential-binding-architecture)
9. [Implementation Proposal](#implementation-proposal)
10. [Test-Driven Delivery Plan](#test-driven-delivery-plan)
11. [Documentation and Release Plan](#documentation-and-release-plan)
12. [Security and Risk Assessment](#security-and-risk-assessment)
13. [Out of Scope](#out-of-scope)
14. [Rollback Plan](#rollback-plan)
15. [Decision Gates](#decision-gates)
16. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

Make zone registration match the documented CLI contract and safely associate
each zone-specific `cert.pem` management token with the selected local zone.

The feature has two distinct responsibilities:

1. `cftunnel zone use <domain>` safely validates and normalizes a DNS zone,
   creates `~/.cloudflared/zones/<domain>/`, and persists it as the default.
2. `cftunnel zone login` validates the token-only credential produced by
   current `cloudflared tunnel login`, verifies that Cloudflare accepts it, and
   records its fingerprint before placing it in the active zone directory.

These operations do not claim to prove legal ownership of a domain. Cloudflare
establishes domain control through zone activation, normally by authenticating
nameserver delegation or a verification record. This CLI verifies only local
syntax, safe filesystem mapping, credential freshness, local zone association,
and hostname containment.

The feature is additive but strengthens previously permissive input handling.
Following Semantic Versioning, it targets the next minor release, `0.5.0`.
The feature branch continues to use `VERSION=0.4.0`; the release workflow owns
the eventual changelog promotion, version bump, and annotated tag.

### Files expected to change during implementation

| File | Proposed change |
|------|-----------------|
| `lib/zone.sh` | Normalize/validate zones, add explicit path and registration helpers, validate persisted state, and bind token credentials through metadata |
| `lib/cloudflared.sh` | Verify zone credential fingerprints before using zone-specific credentials |
| `lib/tunnel.sh` | Require add hostnames to equal or be contained by the active zone |
| `run.sh` | Route every persistent-zone write through the shared registration path |
| `tests/test_zones.sh` | Add zone syntax, registration, persisted-state, and failure-atomicity tests |
| `tests/test_zone_credentials.sh` | Add token framing, isolated-login, fingerprint, metadata, and installation tests |
| `tests/run.sh` | Register any new credential test file and update phase execution |
| `README.md`, `docs/DOCS.md` | Document the precise local registration and authentication contracts |
| `docs/SETUP-NEW-DOMAIN.md` | Correct the workflow and distinguish registration, certificate binding, Cloudflare activation, and DNS authorization |
| `AGENTS.md`, `CHANGELOG.md` | Record security conventions, dependencies, test count, and the unreleased feature |

`install.sh`, tunnel YAML formats, service units, and `VERSION` are not expected
to change during feature implementation.

---

## Problem Statement

The new-domain guide says that:

```bash
cftunnel zone use mynewdomain.com
```

creates `~/.cloudflared/zones/mynewdomain.com/` and sets the persistent default.
The implementation currently performs only the second operation. This leaves
the filesystem without the registered zone until a later `zone login` or
`add` command happens to create it.

The mismatch has user-visible consequences:

- users cannot distinguish a successful registration from a partial failure;
- `zone login` tells users to create a zone with `zone use`, but its zone picker
  discovers directories that `zone use` does not create;
- documentation and runtime behavior disagree about when a zone exists;
- tests verify `.default_zone` but not the promised directory;
- arbitrary non-empty text is accepted as a zone and later interpolated into
  filesystem paths;
- a tampered `.default_zone` is loaded without validation;
- `zone login` moves any generated `cert.pem` into the active zone without
  confirming that it was freshly generated, accepted by Cloudflare, or locally
  fingerprint-bound to that zone.
- `add --hostname` does not ensure that the hostname equals or is a subdomain
  of the active zone.

The intended workflow needs one consistent definition of a locally registered
zone and one explicit boundary between local registration and Cloudflare
authorization.

---

## Current Behavior and Root Causes

### Existing `zone use` path

The current `op_zone use` flow is effectively:

```text
read target
  ↓
validate_zone_name(target)  # non-empty only
  ↓
save_default_zone(target)
  ↓
print success
```

`save_default_zone()` creates only the parent of `.default_zone`, which is
`~/.cloudflared/`. It never creates `~/.cloudflared/zones/<target>/`.

### Existing validation

`validate_zone_name()` currently rejects only an empty string and echoes every
other value unchanged. Values such as the following can therefore become path
components:

```text
../../outside
example.com/child
https://example.com
*.example.com
example..com
```

The `--zone` parser calls this validator, but `load_default_zone()` does not.
Persisted state therefore has a separate, less restrictive path into the global
`ZONE` variable.

### Existing credential installation

The current `zone login` flow is:

```text
determine active zone
  ↓
cloudflared tunnel login
  ↓
check that ~/.cloudflared/cert.pem exists
  ↓
mkdir zones/<active-zone>
  ↓
move cert.pem without inspecting it
```

Current `cloudflared 2026.7.2` login output contains one `ARGO TUNNEL TOKEN`
PEM block and no X.509 certificate. No check currently confirms that the token
is structurally framed, freshly generated, or accepted by Cloudflare. No local
metadata records which zone was selected when the token was installed. The
destination permission is also not explicitly reset to `600` after the move.

### Root causes

| ID | Cause | Effect |
|----|-------|--------|
| RC-01 | `zone use` calls `save_default_zone()` but not a zone registration helper | The documented directory is absent after success |
| RC-02 | `ensure_zone_dir()` derives its path from global `ZONE` | Calling it from `zone use` could create the previous default zone rather than the requested target |
| RC-03 | Zone validation checks only for non-empty input | Unsafe or malformed values can reach filesystem paths |
| RC-04 | Persisted default-zone content bypasses validation | Manual corruption or tampering can reintroduce unsafe values |
| RC-05 | Registration behavior is duplicated across `zone use`, `--persist`, and interactive persistence | Different entry paths can create different states |
| RC-06 | `zone login` trusts the existence of `cert.pem` | A stale or malformed credential can be installed without a stable local association |
| RC-07 | `add` does not compare hostname boundaries with the active zone | An obvious cross-zone hostname can reach DNS routing |
| RC-08 | Tests reflect the implementation rather than the documented contract | The missing directory and credential gaps were not detected |

---

## Trust Boundaries

The implementation and documentation must distinguish four separate claims.

| Step | What it proves | What it does not prove |
|------|----------------|------------------------|
| `zone use` | The name is syntactically safe and local state was created | The domain exists or belongs to the user |
| Cloudflare zone activation | Cloudflare authenticated the configured nameserver delegation or verification record | This machine has a valid tunnel credential |
| `zone login` credential validation | The token was freshly generated, has expected PEM framing, is accepted by Cloudflare, and is locally fingerprint-associated with the selected zone | The token cryptographically contains the zone hostname |
| `add` hostname containment | The requested hostname equals or is below the active canonical zone | Cloudflare will accept the DNS write |
| `cftunnel add` DNS route creation | Cloudflare accepted a DNS write using the selected credential | Continued future ownership or tunnel health |

### Explicit non-goal: ownership claims

DNS resolution, WHOIS output, or Cloudflare nameservers alone do not prove that
the current user controls a domain. `zone use` must therefore stay local and
offline.

This feature does not query the account-wide Cloudflare API and does not reuse
`CF_TOKEN`. An optional zone-status or API-token workflow can be designed
separately if automated `Active`-status verification is later required.

---

## CLI Contract

### Register and select a zone

Input:

```bash
cftunnel zone use Example.COM.
```

Normalized state:

```text
~/.cloudflared/zones/example.com/
~/.cloudflared/.default_zone  # contains exactly: example.com\n
```

Proposed success output:

```text
✅ Zone 'example.com' registered and set as default.
```

The command must:

- validate and normalize the input before any write;
- create only the exact expected directory below `zones/`;
- create the zone directory before changing the default;
- leave the previous default unchanged if directory creation fails;
- be idempotent when the directory already exists;
- avoid `cloudflared`, DNS, API, browser, and systemd operations;
- exit non-zero with a concise reason when validation or persistence fails.

### Select an existing or new zone with `--persist`

These forms use the same registration operation:

```bash
cftunnel --zone example.com --persist
cftunnel --zone example.com --persist list
```

No path that persists a default zone should be able to create `.default_zone`
without also ensuring the matching zone directory exists.

### Authenticate a zone

Input:

```bash
cftunnel zone login
```

The command must identify and print the active normalized zone before launching
the Cloudflare browser flow:

```text
Authenticating zone 'example.com' with Cloudflare.
In the browser, select exactly: example.com
```

`cftunnel` runs `cloudflared tunnel login` with an isolated temporary home and
validates the candidate `cert.pem` created there. Only a freshly generated,
well-framed token that Cloudflare accepts is installed as:

```text
~/.cloudflared/zones/example.com/cert.pem  # mode 600
```

On missing, malformed, rejected, or stale input, the command must exit non-zero,
must not replace the destination certificate, and must leave any existing root
or zone certificate untouched. The temporary login workspace is cleaned after
success or failure.

Successful installation also writes mode-`600` `zone.json` metadata containing
the canonical zone, credential type, SHA-256 fingerprint, and authentication
timestamp. The fingerprint detects later credential swaps or corruption; it is
a local association, not a cryptographic hostname claim.

---

## Zone Name Contract

### Normalization

The canonical local zone name is:

- ASCII lowercase;
- without one optional terminal DNS root dot;
- otherwise unchanged.

Examples:

| Input | Canonical result |
|-------|------------------|
| `example.com` | `example.com` |
| `Example.COM` | `example.com` |
| `example.com.` | `example.com` |
| `Sub.Example.COM.` | `sub.example.com` |
| `xn--bcher-kva.de` | `xn--bcher-kva.de` |

Whitespace is rejected rather than trimmed. Rejecting it makes copy/paste
errors visible and prevents multiple textual inputs from being silently
interpreted as the same directory.

### Syntax rules

A valid local zone must satisfy all of the following:

1. Non-empty after optional trailing-dot removal.
2. At most 253 ASCII characters.
3. At least two dot-separated labels.
4. Every label is between 1 and 63 characters.
5. Labels contain only `a-z`, `0-9`, and `-` after normalization.
6. No label starts or ends with `-`.
7. No empty labels or repeated dots exist.
8. The entire value is safe as one directory component.

Punycode A-labels such as `xn--bcher-kva.de` satisfy these rules. Native
Unicode input is rejected with guidance to provide its punycode form. This
avoids introducing an `idn2` runtime dependency or implementing IDNA rules in
shell.

The validator intentionally does not maintain a public-suffix list and does not
require the final label to be alphabetic. Public suffix data changes over time,
and Cloudflare remains authoritative for whether a zone can be activated.

### Rejected examples

| Input | Reason |
|-------|--------|
| empty string | Missing zone |
| `localhost` | Fewer than two labels |
| `.example.com` | Empty leading label |
| `example..com` | Empty label |
| `example.com..` | More than one trailing dot / empty label |
| `-example.com` | Label starts with hyphen |
| `example-.com` | Label ends with hyphen |
| `*.example.com` | Wildcards are host patterns, not zones |
| `example_com` | Underscore is not valid in a DNS hostname label |
| `https://example.com` | Scheme and path separators are forbidden |
| `example.com:443` | Ports are forbidden |
| `example.com/path` | Path separator is forbidden |
| `../../outside` | Traversal and empty labels are forbidden |
| ` example.com` | Whitespace is forbidden |
| `bücher.de` | Native Unicode is unsupported; use punycode |

### Persisted-state validation

`load_default_zone()` must read exactly one non-empty line and pass it through
the same normalization and validation function used for CLI input.

Invalid persisted state must fail clearly before it is assigned to `ZONE` or
used to form a path. It must not be automatically concatenated, repaired, or
deleted. A user can then inspect and correct `.default_zone` without losing
forensic evidence of accidental corruption or tampering.

Persisted state is canonical-only. If the stored value differs from its
canonical representation, loading fails with a correction message. No legacy
directory migration or automatic rename is supported.

---

## Registration Architecture

### Explicit zone path

Filesystem helpers must accept the zone they operate on instead of temporarily
depending on global `ZONE`.

Proposed data flow:

```text
raw input
  ↓
normalize_and_validate_zone()
  ↓ canonical zone
zone_dir_for(canonical zone)
  ↓ exact path
register_zone(canonical zone)
  ├─ create zones/<zone>/
  └─ atomically persist .default_zone
```

Proposed helper responsibilities:

| Helper | Responsibility |
|--------|----------------|
| `validate_zone_name <raw>` | Return one canonical zone or fail without writes |
| `zone_dir_for <zone>` | Return the exact directory for a validated explicit zone |
| `ensure_zone_dir [zone]` | Preserve existing no-zone behavior while allowing an explicit zone |
| `save_default_zone <zone>` | Atomically store one already validated canonical value with mode `600` |
| `register_zone <raw>` | Validate, create the directory, persist it, and return the canonical value |

### Write ordering and failure behavior

The registration sequence is:

1. Validate and canonicalize in memory.
2. Resolve the explicit path below `$HOME_DIR/.cloudflared/zones/`.
3. Create the zone directory.
4. Write the default value to a temporary file in `~/.cloudflared/`.
5. Set the temporary file to mode `600`.
6. Atomically rename it to `.default_zone`.
7. Print success.

If step 3 fails, the old default remains untouched. If steps 4–6 fail, the
zone may exist as an empty directory, but the old default remains intact. An
empty zone directory is safe, visible, and recoverable; a half-written default
is not.

`zone unset` continues to remove only `.default_zone`. It must never delete a
zone directory, certificate, tunnel credential, or YAML.

### Existing directories

Registering an already existing canonical zone is successful. The operation
must not change existing YAML, JSON, certificate, ownership, or permissions
inside that directory.

---

## Credential Binding Architecture

### Supported credential format

The DG-01 compatibility check found that `cloudflared 2026.7.2` produces a
token-only `cert.pem` containing one `ARGO TUNNEL TOKEN` PEM block and no X.509
certificate. There is no Subject Alternative Name or hostname to compare.

The validator therefore checks the supported outer credential contract without
decoding, printing, or parsing token internals:

- one regular, non-empty, readable file;
- exactly one begin marker and one matching end marker;
- non-empty base64-shaped payload lines between those markers;
- no additional PEM blocks or non-whitespace material;
- acceptance by a read-only authenticated `cloudflared tunnel list` call.

The authenticated validation call occurs only during `zone login`, which is
already an online operation. It does not change the local/offline behavior of
`list`, `zone use`, or `version`, and its remote output is discarded.

### Login and validation sequence

1. Create a temporary login home with mode `700` below `.cloudflared`.
2. Run `cloudflared tunnel login` with `HOME` set only for that process.
3. Require a newly created candidate `cert.pem` in the isolated home.
4. Validate the `ARGO TUNNEL TOKEN` PEM framing without decoding its payload.
5. Ask `cloudflared` to authenticate a read-only tunnel-list request using the
   candidate, suppressing all remote account output.
6. Calculate the candidate SHA-256 fingerprint without printing credential
   contents.
7. Stage the candidate and `zone.json` metadata inside the destination zone.
8. Atomically replace the previous credential and metadata as one recoverable
   transaction.
9. Enforce mode `600` on both files and clean the temporary workspace.

### Local association and hostname containment

The token is a Cloudflare management credential rather than a hostname
certificate. The CLI must not claim that it cryptographically proves the zone
name selected in the browser.

Instead, cftunnel records a trust-on-first-use local association in `zone.json`:

```json
{
  "zone": "example.com",
  "credential_type": "argo_tunnel_token",
  "certificate_sha256": "<64 lowercase hex characters>",
  "authenticated_at": "<UTC timestamp>"
}
```

Before the zone credential is used, cftunnel verifies that the metadata zone is
canonical and equal to active `ZONE`, and that the current credential hash
matches the stored fingerprint. Missing or mismatched metadata fails closed
with guidance to run `cftunnel zone login` again.

For DNS safety, `cftunnel add` also requires `TUNNEL_HOSTNAME` to be either the
active zone or a real subdomain boundary of it. Wildcard hostnames remain valid:

```text
example.com        ∈ example.com
app.example.com    ∈ example.com
*.example.com      ∈ example.com
evil-example.com   ∉ example.com
app.other.com      ∉ example.com
```

This containment check prevents obvious cross-zone routing but does not replace
Cloudflare authorization. Successful DNS route creation remains the definitive
permission check.

### Credential safety

The credential workflow must never:

- print the PEM body, embedded token, or authenticated account output;
- copy a credential into a zone before validation succeeds;
- modify or delete an existing root certificate;
- overwrite a known-good destination before the replacement is fully
  validated and secured;
- relax permissions beyond `600`.

The candidate credential exists only inside a mode-`700` temporary login home.
It is cleaned with that workspace after installation or rejection. This cleanup
must never target the user's real home, root certificate, or zone directory.

### Existing root credential

`zone login` must not refuse a new-domain login merely because
`~/.cloudflared/cert.pem` already exists. Instead, `cloudflared` receives an
isolated temporary `HOME`, so its default `.cloudflared/cert.pem` path cannot
collide with the user's real root credential.

The existing root certificate remains byte-for-byte unchanged on success and
failure. The implementation must verify with the installed `cloudflared`
version that the login command honors the process-scoped `HOME`. If it does
not, implementation pauses for design review; moving or deleting the existing
root credential is not an approved fallback.

### Existing destination credential

Running `zone login` is an explicit request to refresh authentication. A valid
new token and its metadata may atomically replace the existing zone pair. Until
the transaction succeeds, the existing destination must remain usable.

---

## Implementation Proposal

### CP-01: Strengthen `validate_zone_name()`

- **File:** `lib/zone.sh`
- Normalize case and one trailing root dot.
- Enforce the zone name contract label by label.
- Return the canonical value using `printf`.
- Fail before any filesystem operation.

The implementation should prefer simple Bash checks over one opaque regular
expression so each rejection can produce a useful error.

### CP-02: Validate loaded defaults

- **File:** `lib/zone.sh`
- Read `.default_zone` as exactly one line.
- Reject empty, multiline, or invalid content.
- Require the persisted value to already equal its canonical representation.
- Provide a manual correction message for noncanonical state; do not migrate it.
- Never use invalid content as part of a directory path.

### CP-03: Add explicit directory helpers

- **File:** `lib/zone.sh`
- Introduce `zone_dir_for <zone>` or extend `ensure_zone_dir` with an explicit
  argument.
- Keep any legacy no-zone behavior needed by `op_add` explicit.
- Quote every path and use `--` where supported by the invoked utility.

### CP-04: Add `register_zone()`

- **File:** `lib/zone.sh`
- Validate once, create the exact directory, and atomically save the canonical
  default.
- Make `op_zone use|set|switch` call this helper.
- Return or expose the canonical zone for the success message.

### CP-05: Unify persistence entry points

- **Files:** `run.sh`, `lib/zone.sh`
- Route `--persist` and the interactive “make default” path through
  `register_zone()`.
- Ensure no command can persist a zone name that bypasses validation or lacks a
  corresponding zone directory.

### CP-06: Add token and metadata helpers

- **File:** `lib/zone.sh`
- Validate exactly one `ARGO TUNNEL TOKEN` PEM block without decoding it.
- Authenticate the candidate through a suppressed read-only cloudflared call.
- Calculate SHA-256 fingerprints without printing credential contents.
- Atomically write stable `zone.json` metadata with mode `600`.
- Verify metadata zone/fingerprint before a zone credential is used.

Proposed high-level interface:

```bash
validate_tunnel_token_file "$candidate"
install_zone_credential "$candidate" "$active_zone"
verify_zone_credential_binding "$active_zone" "$cert_path"
```

The helper returns `0` without output on success and returns non-zero with a
non-secret error on failure.

### CP-07: Make certificate installation transactional

- **File:** `lib/zone.sh`
- Create a private temporary login home and run `cloudflared tunnel login` with
  a process-scoped `HOME`.
- Read the candidate only from that isolated workspace.
- Prove that the real root certificate is unchanged.
- Validate and remotely authenticate before copying into the zone.
- Stage the credential and metadata inside the destination directory with mode
  `600`.
- Atomically replace both files with rollback on partial failure.
- Clean the temporary login workspace on success, login failure, validation
  failure, and interrupted execution.
- Preserve the previous destination on all earlier failures.

### CP-08: Improve `zone login` guidance

- **File:** `lib/zone.sh`
- Print the exact canonical zone the user must select in Cloudflare.
- Explain token/authentication failure remediation without printing credentials.
- Ensure a zone selected interactively is passed through validation before it
  forms a path.

### CP-09: Enforce credential binding and hostname containment

- **Files:** `lib/cloudflared.sh`, `lib/tunnel.sh`, `lib/zone.sh`
- Verify the zone metadata and credential fingerprint before the wrapper uses a
  zone-specific `cert.pem`.
- Require `add --hostname` to equal or end at a dot boundary below active
  `ZONE`, while preserving wildcard hostnames.
- Fail before tunnel creation, YAML writes, or DNS operations.

### CP-10: Update documentation and operational guidance

- Correct the new-domain setup flow.
- Explain token-only credentials, local fingerprint association, hostname
  containment, and the trust boundaries.
- Update tests and AGENTS conventions.

---

## Test-Driven Delivery Plan

Implementation follows a red/green/refactor sequence. Production code must not
be changed until the proposed tests demonstrate the current failures.

### Phase 1: Zone-validation tests

| Test | Expected behavior |
|------|-------------------|
| `test_zone_validation_accepts_dns_names` | Standard apex and delegated subdomain zones pass |
| `test_zone_validation_normalizes_case_and_root_dot` | `Example.COM.` returns `example.com` |
| `test_zone_validation_accepts_punycode` | A valid `xn--` A-label passes |
| `test_zone_validation_rejects_single_label` | `localhost` fails |
| `test_zone_validation_rejects_empty_labels` | Leading dots, repeated dots, and extra trailing dots fail |
| `test_zone_validation_rejects_bad_hyphens` | Labels beginning or ending with `-` fail |
| `test_zone_validation_rejects_non_dns_characters` | Wildcards, underscores, whitespace, Unicode, schemes, ports, slashes, and backslashes fail |
| `test_zone_validation_rejects_traversal` | Relative and absolute path attempts fail without writes |
| `test_zone_validation_enforces_label_length` | 63-character labels pass and 64-character labels fail |
| `test_zone_validation_enforces_total_length` | The 253-character boundary passes and longer input fails |

### Phase 2: Registration and persisted-state tests

| Test | Expected behavior |
|------|-------------------|
| `test_zone_use_creates_directory_and_default` | Both promised artifacts exist after success |
| `test_zone_use_persists_canonical_name` | Directory and file use the normalized value |
| `test_zone_use_is_idempotent` | Re-registering a zone preserves existing contents |
| `test_zone_use_never_calls_cloudflared` | Registration remains local and offline |
| `test_zone_use_directory_failure_preserves_default` | A failed directory create does not change the old default |
| `test_default_zone_is_written_atomically_and_0600` | The file is complete and has mode `600` |
| `test_load_default_zone_validates_content` | Valid canonical state loads successfully |
| `test_load_default_zone_rejects_invalid_or_multiline_state` | Corrupt/tampered state fails before path construction |
| `test_zone_unset_preserves_registered_directory` | Clearing selection does not delete zone data |
| `test_persist_uses_registration_contract` | `--persist` also creates the directory through the shared helper |

### Phase 3: Credential-validation tests

Credential tests must use temporary token fixtures or controlled command
mocks. They must never read a developer’s real `~/.cloudflared/cert.pem`.

| Test | Expected behavior |
|------|-------------------|
| `test_zone_token_accepts_single_argo_block` | One non-empty, correctly framed token block passes |
| `test_zone_token_rejects_missing_or_empty_file` | Missing and empty candidates fail without leaks |
| `test_zone_token_rejects_malformed_framing` | Missing markers, empty payloads, extra blocks, and surrounding material fail |
| `test_zone_login_authenticates_candidate` | The isolated candidate is passed to a suppressed read-only cloudflared call |
| `test_zone_login_rejects_remote_auth_failure` | Rejected credentials never reach the destination |
| `test_zone_login_uses_isolated_home` | The login candidate is created outside the user's real home |
| `test_zone_login_preserves_preexisting_root_cert` | A real root certificate remains byte-for-byte unchanged |
| `test_zone_login_failure_preserves_destination` | Existing credential and metadata remain byte-for-byte unchanged |
| `test_zone_login_installs_token_and_metadata_0600` | Credential, fingerprint, canonical zone, and permissions are correct |
| `test_zone_login_replacement_is_atomic` | A failed staged replacement preserves the existing certificate |
| `test_zone_login_cleans_temporary_workspace` | Success and every failure path remove only the isolated login workspace |
| `test_zone_login_never_logs_credentials` | Error and success output contain no PEM/token material |
| `test_zone_login_validates_interactive_selection` | Typed zone names pass through the same validator |
| `test_zone_binding_detects_swapped_credential` | Fingerprint mismatch fails before cloudflared executes |
| `test_hostname_containment_accepts_zone_and_subdomains` | Apex, normal subdomains, and wildcard subdomains pass |
| `test_hostname_containment_rejects_cross_zone_names` | Suffix lookalikes and unrelated zones fail before side effects |

The mock cloudflared executable may write a non-secret fixture token to its
process-scoped home and record invocation arguments. Tests assert that neither
the fixture payload nor remote list output appears in command output.

### Phase 4: Regression verification

1. `bash -n run.sh install.sh uninstall.sh lib/*.sh tests/*.sh`
2. `make -C tests smoke`
3. `cd tests && ./run.sh --verbose`
4. Run `cftunnel zone use` with a temporary test home and confirm exact paths.
5. Confirm an invalid traversal input creates nothing outside the test home.
6. Confirm local registration succeeds with no network and no `cloudflared`.
7. Exercise credential validation only with non-production fixtures.
8. Confirm `cftunnel list`, `version`, and existing tunnel YAML behavior remain
   unchanged.

### Manual Cloudflare verification

After automated tests pass, an optional controlled manual check may authenticate
a non-production zone. It must not be part of the automated suite and must not
record or print the resulting credential.

---

## Documentation and Release Plan

### Feature implementation

- Update `docs/SETUP-NEW-DOMAIN.md` so `zone use` and `zone login` describe the
  implemented behavior precisely.
- Clarify that local registration is not ownership verification.
- Document that Cloudflare `Active` status represents external domain-control
  validation.
- Document token framing, read-only authentication, local fingerprint metadata,
  and hostname-containment guarantees.
- Add troubleshooting for malformed, rejected, swapped, and isolated-login
  credential failures.
- Update README and technical CLI reference.
- Add the feature under `CHANGELOG.md` → `Unreleased`.
- Update `AGENTS.md` with canonical-zone, persisted-state, path-safety, and
  credential-handling conventions.
- Update the documented test count after the final test list is known.
- Mark this TDD approved/implemented only after all acceptance criteria pass.

### Release

The implementation branch must not change `VERSION`. During the release:

1. Move the changelog entry from `Unreleased` to `0.5.0` with the release date.
2. Change `VERSION` from `0.4.0` to `0.5.0`.
3. Commit the release metadata.
4. Create annotated tag `v0.5.0` on that commit.
5. Push the release commit and tag only after verification passes.

---

## Security and Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Path traversal through a CLI zone | Medium | High | Canonical DNS validation before any path construction |
| Path traversal through tampered `.default_zone` | Medium | High | Validate persisted state with the same function |
| `ensure_zone_dir` creates the previous global zone | Medium | Medium | Pass the intended zone explicitly |
| Directory creation succeeds but default is partially written | Low | Medium | Same-directory temporary file and atomic rename |
| Noncanonical persisted state is encountered | Low | Medium | Fail clearly with manual correction guidance; no legacy migration |
| Management token is described as a hostname certificate | Medium | Medium | Document that association is local and not cryptographic |
| Cloudflare changes the token envelope | Medium | High | Validate only the observed outer PEM contract and fail closed |
| Credential fingerprint metadata is missing or altered | Medium | High | Fail before cloudflared use and require `zone login` |
| Rejected credential leaks through logs | Low | Critical | Never print PEM payloads or remote account output; assert output safety |
| Failed refresh destroys a working zone certificate | Low | High | Validate and stage before atomic replacement |
| A stale root certificate is mistaken for fresh login output | Medium | High | Generate the candidate under an isolated process-scoped `HOME` |
| `cloudflared` ignores the isolated `HOME` | Low | High | Compatibility-test the installed version and fail closed; never touch the real root credential |
| Local credential association is described as domain ownership | Medium | Medium | Document trust boundaries and Cloudflare activation separately |
| Cross-zone hostname reaches route creation | Medium | High | Enforce exact apex/dot-boundary containment before side effects |
| New strict validation breaks unconventional local zone names | Medium | Medium | Treat zones as Cloudflare DNS zones; document punycode and out-of-scope aliases |

---

## Out of Scope

| Item | Reason |
|------|--------|
| Querying Cloudflare zone ownership or `Active` status | Requires a network/API authentication design separate from local registration |
| Reusing account-wide `CF_TOKEN` | This feature intentionally avoids coupling zone registration to account-wide API data |
| Parsing the embedded token or private key in `cert.pem` | Undocumented credential formats are unstable and sensitive |
| Public-suffix-list validation | Requires regularly updated external data and does not prove Cloudflare ownership |
| Automatic Unicode-to-punycode conversion | Would require a new IDNA dependency and policy |
| Automatically deleting or backing up a root certificate | Credential destruction/recovery requires an explicit separate workflow |
| A `zone verify` network subcommand | Can be proposed independently after registration and binding are reliable |
| Migrating or renaming existing noncanonical directories automatically | Canonical-only state is required; correction remains manual |
| Removing legacy root-level tunnel behavior | Unrelated to safe zone registration |
| Changing tunnel YAML, DNS fallback, or systemd unit naming | Unrelated operational paths |
| Bumping `VERSION` in the feature commit | Release metadata remains a separate workflow |

---

## Rollback Plan

The feature creates only an empty zone directory during `zone use` and installs
a certificate only after an explicit `zone login` succeeds.

Code rollback consists of reverting validation, registration, certificate
inspection, tests, and documentation. Existing valid zone directories and
credentials remain compatible with the previous layout.

Rollback must never remove directories or credentials created while the feature
was active. Persisted state remains canonical and requires no legacy migration.

---

## Decision Gates

The design decisions below were resolved during review.

### DG-01: Token-only credential contract

**Status:** Resolved after compatibility inspection.

The installed `cloudflared 2026.7.2` credential contains only:

```text
-----BEGIN ARGO TUNNEL TOKEN-----
...
-----END ARGO TUNNEL TOKEN-----
```

There is no X.509 certificate or SAN. Validate outer token framing, candidate
freshness, read-only Cloudflare acceptance, and local SHA-256 association. Do
not decode or parse token internals and do not claim cryptographic hostname
binding.

### DG-02: Legacy normalization

**Status:** Resolved — no legacy migration support.

New CLI input is normalized before persistence. Loaded `.default_zone` content
must already be canonical; uppercase, terminal-dot, or otherwise noncanonical
state fails with manual correction guidance. Never automatically rename a
populated directory.

### DG-03: `--persist` registration

**Status:** Resolved — yes.

Route `zone use`, `--persist`, and interactive default changes through one
registration helper so the invariant remains true:

```text
default zone exists ⇒ matching zone directory exists
```

### DG-04: Isolated certificate login

**Status:** Resolved — do not refuse new-domain login and do not touch the
existing root certificate.

Run `cloudflared tunnel login` with a private temporary `HOME`, validate and
authenticate the candidate token there, and atomically install it with metadata
into the selected zone.
Clean only the temporary workspace afterward. If `cloudflared` does not honor
the isolated home, fail closed and return to design review.

---

## Acceptance Criteria

- [x] `cftunnel zone use example.com` creates `~/.cloudflared/zones/example.com/`.
- [x] The same command stores exactly `example.com` in `.default_zone` with mode `600`.
- [x] Registration is local, offline, idempotent, and does not invoke `cloudflared`.
- [x] Case and one terminal root dot normalize to one canonical directory and default value.
- [x] Valid apex, delegated-subdomain, and punycode zone names are accepted.
- [x] Invalid DNS syntax, path traversal, schemes, ports, wildcards, whitespace, Unicode, and unsafe characters are rejected before writes.
- [x] DNS label and total-length boundaries are enforced.
- [x] Invalid or multiline `.default_zone` content is rejected before path construction.
- [x] Directory-creation failure preserves the previous default.
- [x] Default-zone persistence is atomic and cannot leave partial content.
- [x] `zone unset` never deletes registered zone data.
- [x] All approved persistent-selection paths preserve the default-directory invariant.
- [x] `zone login` clearly identifies the exact zone to select in Cloudflare.
- [x] `zone login` rejects missing, empty, malformed, extra-block, and remotely rejected token credentials.
- [x] Token validation checks the outer `ARGO TUNNEL TOKEN` contract without decoding or parsing token internals.
- [x] The candidate is accepted by a suppressed read-only Cloudflare authentication call before installation.
- [x] `zone login` generates and validates candidates in a private isolated home.
- [x] A pre-existing root certificate remains byte-for-byte unchanged on success and failure.
- [x] Temporary login state is cleaned without targeting the user's real home or zone data.
- [x] A rejected certificate does not replace the existing zone certificate.
- [x] A valid token and matching `zone.json` metadata are atomically installed with mode `600`.
- [x] Zone metadata records the canonical zone, credential type, SHA-256 fingerprint, and authentication timestamp.
- [x] A missing or mismatched fingerprint fails before the wrapper invokes cloudflared.
- [x] `add --hostname` accepts the active zone, subdomains, and wildcard subdomains.
- [x] `add --hostname` rejects unrelated zones and suffix lookalikes before side effects.
- [x] No success or error path prints private keys, PEM bodies, or embedded tokens.
- [x] Local token association is not documented as proof of legal ownership or current Cloudflare zone activation.
- [x] New tests fail against `v0.4.0` before production implementation and pass afterward.
- [x] `bash -n run.sh install.sh uninstall.sh lib/*.sh tests/*.sh` reports zero syntax errors.
- [x] The full existing and new test suite passes.
- [x] README, setup guide, technical docs, changelog, and AGENTS guidance are updated.
- [x] `VERSION` remains `0.4.0` during feature implementation.

(End of file)
