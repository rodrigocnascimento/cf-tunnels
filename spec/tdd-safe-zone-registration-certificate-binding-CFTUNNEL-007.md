# Technical Design Document — CFTUNNEL-007

> **Issue:** CFTUNNEL-007
> **Title:** Safe Zone Registration and Certificate Binding
> **Version:** 0.4.0 → 0.5.0
> **Status:** Proposed — design decisions resolved; awaiting implementation approval
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
8. [Certificate Binding Architecture](#certificate-binding-architecture)
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

Make zone registration match the documented CLI contract and bind each
zone-specific `cert.pem` to the zone selected by the user.

The feature has two distinct responsibilities:

1. `cftunnel zone use <domain>` safely validates and normalizes a DNS zone,
   creates `~/.cloudflared/zones/<domain>/`, and persists it as the default.
2. `cftunnel zone login` validates the X.509 certificate produced by
   `cloudflared tunnel login` before placing it in the active zone directory.

These operations do not claim to prove legal ownership of a domain. Cloudflare
establishes domain control through zone activation, normally by authenticating
nameserver delegation or a verification record. This CLI verifies only local
syntax, safe filesystem mapping, and certificate-to-zone binding.

The feature is additive but strengthens previously permissive input handling.
Following Semantic Versioning, it targets the next minor release, `0.5.0`.
The feature branch continues to use `VERSION=0.4.0`; the release workflow owns
the eventual changelog promotion, version bump, and annotated tag.

### Files expected to change during implementation

| File | Proposed change |
|------|-----------------|
| `lib/zone.sh` | Normalize/validate zones, add explicit path and registration helpers, validate persisted state, and verify certificates before installation |
| `run.sh` | Route every persistent-zone write through the shared registration path |
| `tests/test_zones.sh` | Add zone syntax, registration, persisted-state, and failure-atomicity tests |
| `tests/test_zone_certificates.sh` | Add certificate format, validity, exact-match, mismatch, and installation tests |
| `tests/run.sh` | Register any new certificate test file and update phase execution |
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
  confirming that the certificate covers that zone.

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

### Existing certificate installation

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

No check currently confirms that the PEM contains a readable certificate, that
the certificate is unexpired, or that it was issued for the active zone. The
destination permission is also not explicitly reset to `600` after the move.

### Root causes

| ID | Cause | Effect |
|----|-------|--------|
| RC-01 | `zone use` calls `save_default_zone()` but not a zone registration helper | The documented directory is absent after success |
| RC-02 | `ensure_zone_dir()` derives its path from global `ZONE` | Calling it from `zone use` could create the previous default zone rather than the requested target |
| RC-03 | Zone validation checks only for non-empty input | Unsafe or malformed values can reach filesystem paths |
| RC-04 | Persisted default-zone content bypasses validation | Manual corruption or tampering can reintroduce unsafe values |
| RC-05 | Registration behavior is duplicated across `zone use`, `--persist`, and interactive persistence | Different entry paths can create different states |
| RC-06 | `zone login` trusts the existence of `cert.pem` | A stale, malformed, expired, or wrong-zone certificate can be installed |
| RC-07 | Tests reflect the implementation rather than the documented contract | The missing directory and certificate gap were not detected |

---

## Trust Boundaries

The implementation and documentation must distinguish four separate claims.

| Step | What it proves | What it does not prove |
|------|----------------|------------------------|
| `zone use` | The name is syntactically safe and local state was created | The domain exists or belongs to the user |
| Cloudflare zone activation | Cloudflare authenticated the configured nameserver delegation or verification record | This machine has a valid tunnel certificate |
| `zone login` certificate validation | The generated certificate is structurally valid, unexpired, and bound to the selected zone | The embedded authorization has not later been revoked |
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
validates the candidate `cert.pem` created there. Only a valid matching
certificate is installed as:

```text
~/.cloudflared/zones/example.com/cert.pem  # mode 600
```

On malformed, expired, or mismatched input, the command must exit non-zero,
must not replace the destination certificate, and must leave any existing root
or zone certificate untouched. The temporary login workspace is cleaned after
success or failure.

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

## Certificate Binding Architecture

### Supported inspection mechanism

The installed `cloudflared` CLI has no supported certificate-inspection
subcommand. The proposed local validator therefore uses the X.509 portion of
`cert.pem` through `openssl x509` and never decodes or prints the embedded API
token or private key.

`openssl` becomes a command-specific dependency of `zone login`, not of local
commands such as `list`, `zone use`, or `version`.

### Validation sequence

The certificate login and validation sequence is:

1. Create a temporary login home with mode `700`.
2. Run `cloudflared tunnel login` with `HOME` set only for that process.
3. Require a regular, readable candidate `cert.pem` in the isolated home.
4. Parse an X.509 certificate with `openssl x509 -noout`.
5. Reject a certificate that fails `openssl x509 -checkend 0 -noout`.
6. Confirm hostname coverage with `openssl x509 -checkhost <zone> -noout`.
7. Extract Subject Alternative Name DNS entries without printing other
   certificate material.
8. Require a non-wildcard DNS SAN exactly equal to the canonical zone.
9. Atomically replace the destination certificate only after all checks pass.
10. Enforce destination mode `600` and clean the temporary workspace.

Coverage and exact identity are intentionally separate. A parent-zone
certificate containing `*.example.com` can cover `app.example.com`, but that
wildcard alone must not prove that the selected Cloudflare zone was
`app.example.com`.

### Exact-match compatibility check

Before implementation, DG-01 performs a read-only check against a current
zone-specific certificate. The check prints only Subject Alternative Names and
must confirm that supported Cloudflare login certificates include a literal
DNS SAN for the selected zone. It must never print the private key, PEM body, or
embedded token.

If an exact SAN is not available, implementation stops for design review rather
than silently downgrading to wildcard coverage.

Potential alternatives at that point are:

- coverage-only validation with an explicit weaker guarantee;
- a zone-scoped Cloudflare `Zone:Read` API check;
- a supported `cloudflared` inspection interface if one becomes available.

Parsing undocumented token fields from `cert.pem` is not an approved fallback.

### Credential safety

The validator must never:

- print the PEM, private key, embedded token, or full OpenSSL dump;
- copy a certificate into a zone before validation succeeds;
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
new matching certificate may atomically replace an existing zone certificate.
Until the final rename succeeds, the existing destination must remain usable.

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

### CP-06: Add certificate inspection helpers

- **File:** `lib/zone.sh`
- Add focused helpers for X.509 parsing, expiry, hostname coverage, and literal
  SAN matching.
- Use `need openssl` only within certificate-dependent operations.
- Suppress successful OpenSSL output and convert failures into concise cftunnel
  errors.

Proposed high-level interface:

```bash
validate_zone_certificate "$cert_src" "$active_zone"
```

The helper returns `0` without output on success and returns non-zero with a
non-secret error on failure.

### CP-07: Make certificate installation transactional

- **File:** `lib/zone.sh`
- Create a private temporary login home and run `cloudflared tunnel login` with
  a process-scoped `HOME`.
- Read the candidate only from that isolated workspace.
- Prove that the real root certificate is unchanged.
- Validate before copying or moving into the zone.
- Stage the replacement inside the destination directory with mode `600`.
- Atomically rename it over the destination.
- Clean the temporary login workspace on success, login failure, validation
  failure, and interrupted execution.
- Preserve the previous destination on all earlier failures.

### CP-08: Improve `zone login` guidance

- **File:** `lib/zone.sh`
- Print the exact canonical zone the user must select in Cloudflare.
- Explain mismatch remediation without printing credentials.
- Ensure a zone selected interactively is passed through validation before it
  forms a path.

### CP-09: Update documentation and operational guidance

- Correct the new-domain setup flow.
- Add `openssl` to the `zone login` dependency documentation.
- Explain the four trust boundaries.
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

### Phase 3: Certificate-validation tests

Certificate tests must use temporary generated fixtures or controlled command
mocks. They must never read a developer’s real `~/.cloudflared/cert.pem`.

| Test | Expected behavior |
|------|-------------------|
| `test_zone_certificate_accepts_exact_san` | A valid unexpired certificate with literal `DNS:example.com` passes |
| `test_zone_certificate_rejects_malformed_pem` | Non-certificate content fails without leaking it |
| `test_zone_certificate_rejects_expired_cert` | An expired certificate fails |
| `test_zone_certificate_rejects_other_zone` | A valid certificate for another zone fails |
| `test_zone_certificate_rejects_wildcard_only_identity` | `DNS:*.example.com` alone does not identify `app.example.com` as its own zone |
| `test_zone_login_requires_openssl` | Missing OpenSSL produces a clear dependency error only for login |
| `test_zone_login_uses_isolated_home` | The login candidate is created outside the user's real home |
| `test_zone_login_preserves_preexisting_root_cert` | A real root certificate remains byte-for-byte unchanged |
| `test_zone_login_mismatch_preserves_destination` | Existing valid destination remains byte-for-byte unchanged |
| `test_zone_login_installs_matching_cert_0600` | A matching certificate is installed with mode `600` |
| `test_zone_login_replacement_is_atomic` | A failed staged replacement preserves the existing certificate |
| `test_zone_login_cleans_temporary_workspace` | Success and every failure path remove only the isolated login workspace |
| `test_zone_login_never_logs_credentials` | Error and success output contain no PEM/token material |
| `test_zone_login_validates_interactive_selection` | Typed zone names pass through the same validator |

At least one integration test should exercise a real temporary X.509 fixture
with Subject Alternative Names. Expiry and command-error branches may use a
mocked `openssl` executable to remain deterministic across supported OpenSSL
versions.

### Phase 4: Regression verification

1. `bash -n run.sh install.sh uninstall.sh lib/*.sh tests/*.sh`
2. `make -C tests smoke`
3. `cd tests && ./run.sh --verbose`
4. Run `cftunnel zone use` with a temporary test home and confirm exact paths.
5. Confirm an invalid traversal input creates nothing outside the test home.
6. Confirm local registration succeeds with no network and no `cloudflared`.
7. Exercise certificate validation only with non-production fixtures.
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
- Document exact-zone certificate checks and `openssl` requirements.
- Add troubleshooting for mismatched, expired, malformed, and isolated-login
  certificate failures.
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
| Parent wildcard is mistaken for exact zone identity | Medium | High | Require a literal non-wildcard SAN after coverage check |
| Cloudflare changes the certificate format | Medium | High | DG-01 compatibility gate; fail closed rather than parse token internals |
| Missing OpenSSL breaks unrelated commands | Low | Medium | Require it only inside `zone login` |
| Rejected credential leaks through logs | Low | Critical | Never print PEM/OpenSSL dumps; assert output safety |
| Failed refresh destroys a working zone certificate | Low | High | Validate and stage before atomic replacement |
| A stale root certificate is mistaken for fresh login output | Medium | High | Generate the candidate under an isolated process-scoped `HOME` |
| `cloudflared` ignores the isolated `HOME` | Low | High | Compatibility-test the installed version and fail closed; never touch the real root credential |
| Certificate match is described as domain ownership | Medium | Medium | Document trust boundaries and Cloudflare activation separately |
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
| Validating that every `add --hostname` belongs to the active zone | Related but separate tunnel-input behavior with its own compatibility impact |
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

The design decisions below were resolved during review. DG-01 remains a
read-only compatibility check that must pass before production implementation.

### DG-01: Exact SAN availability

**Status:** Accepted as a pre-implementation compatibility check.

Inspect an existing zone certificate without recording secrets:

```bash
openssl x509 -in "$cert" -noout -ext subjectAltName
openssl x509 -in "$cert" -noout -checkhost "$zone"
```

The first command must show a literal `DNS:<zone>` entry; wildcard coverage
alone is insufficient. If the X.509 certificate or exact SAN is unavailable,
pause and revise the certificate-binding contract. Do not parse token internals
or silently accept wildcard-only identity.

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

Run `cloudflared tunnel login` with a private temporary `HOME`, validate the
candidate certificate there, and atomically install it into the selected zone.
Clean only the temporary workspace afterward. If `cloudflared` does not honor
the isolated home, fail closed and return to design review.

---

## Acceptance Criteria

- [ ] `cftunnel zone use example.com` creates `~/.cloudflared/zones/example.com/`.
- [ ] The same command stores exactly `example.com` in `.default_zone` with mode `600`.
- [ ] Registration is local, offline, idempotent, and does not invoke `cloudflared`.
- [ ] Case and one terminal root dot normalize to one canonical directory and default value.
- [ ] Valid apex, delegated-subdomain, and punycode zone names are accepted.
- [ ] Invalid DNS syntax, path traversal, schemes, ports, wildcards, whitespace, Unicode, and unsafe characters are rejected before writes.
- [ ] DNS label and total-length boundaries are enforced.
- [ ] Invalid or multiline `.default_zone` content is rejected before path construction.
- [ ] Directory-creation failure preserves the previous default.
- [ ] Default-zone persistence is atomic and cannot leave partial content.
- [ ] `zone unset` never deletes registered zone data.
- [ ] All approved persistent-selection paths preserve the default-directory invariant.
- [ ] `zone login` clearly identifies the exact zone to select in Cloudflare.
- [ ] `zone login` rejects missing, malformed, expired, wrong-zone, and wildcard-only certificates.
- [ ] Exact certificate binding uses supported X.509 fields and never parses embedded credential tokens.
- [ ] `zone login` generates and validates candidates in a private isolated home.
- [ ] A pre-existing root certificate remains byte-for-byte unchanged on success and failure.
- [ ] Temporary login state is cleaned without targeting the user's real home or zone data.
- [ ] A rejected certificate does not replace the existing zone certificate.
- [ ] A valid matching certificate is atomically installed with mode `600`.
- [ ] No success or error path prints private keys, PEM bodies, or embedded tokens.
- [ ] Missing OpenSSL affects only certificate-dependent commands.
- [ ] Certificate matching is not documented as proof of legal ownership or current Cloudflare zone activation.
- [ ] New tests fail against `v0.4.0` before production implementation and pass afterward.
- [ ] `bash -n run.sh install.sh uninstall.sh lib/*.sh tests/*.sh` reports zero syntax errors.
- [ ] The full existing and new test suite passes.
- [ ] README, setup guide, technical docs, changelog, and AGENTS guidance are updated.
- [ ] `VERSION` remains `0.4.0` during feature implementation.

(End of file)
