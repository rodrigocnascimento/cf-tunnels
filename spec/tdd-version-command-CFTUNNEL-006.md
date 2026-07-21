# Technical Design Document — CFTUNNEL-006

> **Issue:** CFTUNNEL-006
> **Title:** Add CLI Version Reporting
> **Version:** 0.3.2 → 0.4.0
> **Status:** Approved and implemented
> **Date:** 2026-07-18
> **Author:** Rodrigo Nascimento

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Design Goals](#design-goals)
4. [CLI Contract](#cli-contract)
5. [Version Source of Truth](#version-source-of-truth)
6. [Proposed Architecture](#proposed-architecture)
7. [Implementation Proposal](#implementation-proposal)
8. [Test-Driven Delivery Plan](#test-driven-delivery-plan)
9. [Documentation and Release Plan](#documentation-and-release-plan)
10. [Risk Assessment](#risk-assessment)
11. [Out of Scope](#out-of-scope)
12. [Rollback Plan](#rollback-plan)
13. [Acceptance Criteria](#acceptance-criteria)

---

## Overview

Add two equivalent, side-effect-free ways to report the installed `cftunnel`
version:

```bash
cftunnel --version
cftunnel version
```

Both forms will print the version stored in the repository's existing `VERSION`
file. They must work without Cloudflare credentials, `cloudflared`, `jq`,
systemd, network access, or a configured zone.

The expected output format is one stable line:

```text
cftunnel 0.3.2
```

The feature is additive and backward-compatible. Following Semantic Versioning,
it targets the next minor release, `0.4.0`. The feature branch will continue to
read the current `VERSION` value; the file is promoted to `0.4.0` only during
the release/tag workflow.

### Files changed during implementation

| File | Implemented change |
|------|-----------------|
| `run.sh` | Recognize `version` and `--version`, dispatch before zone or remote logic, and update help text |
| `lib/common.sh` | Add a focused helper that reads and prints the application version |
| `lib/cloudflared.sh` | Explicitly exempt version requests from the cloudflared update probe as defense in depth |
| `tests/test_version.sh` | Add command/output/offline/error-path coverage |
| `tests/run.sh` | Register version tests in the CLI phase |
| `README.md`, `docs/DOCS.md` | Document both version forms and their output |
| `AGENTS.md`, `CHANGELOG.md` | Record the new command conventions, test count, and unreleased feature |

`install.sh` and `VERSION` are not expected to change during feature
implementation. The installer already creates a symlink to `run.sh`, and the
release process owns the eventual version bump.

---

## Problem Statement

The repository has maintained a root-level `VERSION` file since its first
release, but the CLI cannot display it. Users currently have to locate and read
the repository file manually or infer the cftunnel version from Git tags.

The only version-related CLI command is `cli-update`, which checks and updates
the separate Cloudflare `cloudflared` binary. This creates ambiguity:

- `cloudflared --version` reports the dependency version, not cftunnel.
- `cftunnel cli-update` manages that dependency, not the shell CLI itself.
- `cftunnel --version` currently falls through to normal startup logic and is
  ultimately treated as an unknown command.
- Normal startup can probe the Cloudflare API through
  `check_cloudflared_version()`, which is inappropriate for local version
  reporting.

### Root causes

| ID | Cause | Effect |
|----|-------|--------|
| RC-01 | No dispatcher case exists for `version` or `--version` | Users cannot query the CLI version |
| RC-02 | No helper reads the existing `VERSION` file | Version output has no defined source or format |
| RC-03 | Zone/default and cloudflared checks occur before command dispatch | A simple informational request can read configuration or contact Cloudflare |
| RC-04 | Help and docs mention only the cloudflared updater | The distinction between cftunnel and cloudflared versions is unclear |

---

## Design Goals

1. **Two standard entry forms** — support both `cftunnel --version` and
   `cftunnel version`.
2. **Single source of truth** — read the root `VERSION` file; do not duplicate a
   version literal in shell code.
3. **Exact stable output** — print `cftunnel <version>` followed by one newline.
4. **Early terminal behavior** — return before zone loading, prompts, version
   probes, API calls, or command-specific dependencies.
5. **Offline operation** — work without `cloudflared`, `jq`, systemd, DNS, or a
   network connection.
6. **Installed-command compatibility** — work through the `/usr/local/bin/cftunnel`
   symlink created by `install.sh`.
7. **Clear failure behavior** — a missing, unreadable, empty, or invalid version
   file produces a concise error on stderr and exits non-zero.
8. **No release-process duplication** — the established `VERSION`, changelog,
   commit, and annotated-tag workflow remains authoritative.

---

## CLI Contract

### Supported forms

```bash
cftunnel --version
cftunnel version
```

Both commands:

- print exactly one line to stdout;
- print nothing to stderr on success;
- exit with status `0`;
- return the same value;
- do not require an active zone;
- do not invoke `cloudflared` or `systemctl`;
- do not modify files or persistent state.

### Output

Given:

```text
VERSION = 0.3.2
```

Expected:

```text
cftunnel 0.3.2
```

The `cftunnel` prefix distinguishes the application version from output such as
`cloudflared version 2026.x.y`.

### Additional arguments

The supported contract is limited to the two standalone forms above. Extra
positional arguments after `version` or `--version` should fail with a usage
error rather than being silently ignored.

`-v` is not introduced because it is commonly associated with verbose output.
`-V` can be considered separately if a short alias becomes desirable.

---

## Version Source of Truth

### Existing layout

```text
cf-tunnels/
├── VERSION
├── run.sh
└── lib/
```

`VERSION` contains one newline-terminated Semantic Version value:

```text
0.3.2
```

### Installed symlink behavior

`install.sh` creates:

```text
/usr/local/bin/cftunnel -> <repository>/run.sh
```

`run.sh` already resolves its real source location with:

```bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
```

Therefore `$SCRIPT_DIR/VERSION` resolves to the repository version file whether
the script is invoked as `./run.sh`, through a relative symlink, or through the
installed `/usr/local/bin/cftunnel` symlink. No installer copy step or embedded
version constant is required.

Copying `run.sh` by itself without `VERSION` is not a supported installation.
The command must nevertheless fail clearly if that state is encountered.

### Accepted version format

The reader should accept Semantic Version values with optional prerelease and
build metadata, including:

```text
0.4.0
0.4.0-rc.1
0.4.0+build.7
0.4.0-rc.1+build.7
```

Leading/trailing horizontal whitespace, multiple lines, and arbitrary strings
must not be accepted.

---

## Proposed Architecture

### Command sequence

```text
run.sh starts
  ↓
resolve SCRIPT_DIR and source libraries
  ↓
extract global options and determine cmd
  ↓
cmd is version or --version?
  ├─ yes → reject extra args → print_cftunnel_version() → exit
  └─ no  → continue existing zone/version-check/dispatch flow
```

The version terminal must occur after argument extraction—so both command forms
are recognized—but before:

- `load_default_zone()`;
- persistent-zone prompts or writes;
- `check_cloudflared_version()`;
- the main operational command dispatcher.

This ordering makes version reporting side-effect-free even if an empty or
malformed `.default_zone` file exists.

### Helper ownership

`print_cftunnel_version()` belongs in `lib/common.sh` because it is application
metadata handling with no Cloudflare, DNS, zone, tunnel, or systemd dependency.

The helper uses the already initialized `$SCRIPT_DIR` and `die()` for errors.

---

## Implementation Proposal

### CP-01: Add `print_cftunnel_version()`

- **File:** `lib/common.sh`
- **Action:** Read and validate `$SCRIPT_DIR/VERSION`, then print the stable
  output format.

Implemented shape:

```bash
print_cftunnel_version() {
    local version_file="${CFTUNNEL_VERSION_FILE:-$SCRIPT_DIR/VERSION}"
    [[ -f "$version_file" && -r "$version_file" ]] ||
        die "version file is missing or unreadable: $version_file"

    local lines=()
    mapfile -t lines < "$version_file"
    [[ ${#lines[@]} -eq 1 ]] || die "invalid version file: $version_file"

    local version="${lines[0]}"
    [[ "$version" =~ <semver-pattern> ]] || die "invalid version: $version"

    printf 'cftunnel %s\n' "$version"
}
```

The Semantic Version pattern must accept optional prerelease and build metadata
while rejecting whitespace and partial versions.

The function must never use `eval`, `source`, command interpolation from file
contents, or a hardcoded version.

### CP-02: Dispatch version requests before zone logic

- **File:** `run.sh`
- **Action:** After first-pass argument parsing and `cmd` extraction, recognize
  `version` and `--version`, validate that no positional arguments remain, call
  `print_cftunnel_version()`, and exit `0`.

The early path must also precede the `CFTUNNEL_SKIP_MAIN` test hook only if CLI
subprocess tests require normal dispatch. Sourced unit tests continue to set an
empty argument list and are unaffected.

### CP-03: Exempt version commands from remote version checks

- **File:** `lib/cloudflared.sh`
- **Function:** `check_cloudflared_version()`
- **Action:** Add `version` and `--version` to its early-return command set.

The early dispatcher should make this path unreachable during normal version
execution. The exemption remains valuable defense in depth against future
dispatcher reordering.

### CP-04: Update help text

- **File:** `run.sh`
- Add `version` to the Commands section.
- Add `--version` to Global options.
- Make clear that `cli-update` applies to `cloudflared`, while `version` reports
  cftunnel itself.

### CP-05: Preserve release ownership of `VERSION`

The feature implementation reads but does not change `VERSION`. At release:

1. Move changelog entries from `Unreleased` to `0.4.0` with the release date.
2. Change `VERSION` from `0.3.2` to `0.4.0`.
3. Commit release metadata.
4. Create annotated tag `v0.4.0` on that commit.

Because the CLI reads the file dynamically, the tagged command will
automatically print `cftunnel 0.4.0` without a code edit.

---

## Test-Driven Delivery Plan

Implementation follows a red/green/refactor sequence.

### Phase 1: Add failing tests

Create `tests/test_version.sh` and register it in the CLI test phase.

| Test | Expected behavior |
|------|-------------------|
| `test_version_flag_matches_version_file` | `./run.sh --version` prints `cftunnel $(<VERSION)` |
| `test_version_subcommand_matches_version_file` | `./run.sh version` prints the identical line |
| `test_version_is_silent_and_never_calls_dependencies` | Both forms keep stderr empty and never invoke `cloudflared` or `systemctl` |
| `test_version_does_not_touch_zone_state` | Version succeeds with no default zone and does not create or remove config files |
| `test_version_works_through_symlink` | A temporary symlink to `run.sh` still locates the repository `VERSION` file |
| `test_version_rejects_extra_arguments` | Both forms reject unexpected positional arguments |
| `test_version_helper_validates_version_file` | A valid prerelease is accepted; missing, empty, multiline, whitespace-padded, and non-SemVer files are rejected |

For error-path tests, the helper may accept an internal
`CFTUNNEL_VERSION_FILE` override that defaults to `$SCRIPT_DIR/VERSION`. The
override is not a documented user-facing option; it exists only to test missing
and malformed fixtures without modifying the real release file.

The new tests must fail against `v0.3.2` before production code is changed.

### Phase 2: Minimal implementation

1. Add version-file reading and validation.
2. Add early terminal dispatch for both forms.
3. Add the version-check exemption.
4. Update help text.
5. Make all new tests pass.

### Phase 3: Regression verification

1. `bash -n run.sh lib/*.sh tests/*.sh`
2. `make -C tests smoke`
3. `cd tests && ./run.sh --verbose`
4. `cftunnel --version`
5. `cftunnel version`
6. Invoke the command through a temporary symlink.
7. Confirm neither successful form writes to stderr or calls Cloudflare.

---

## Documentation and Release Plan

### Feature implementation

- Add both forms to `README.md` and `docs/DOCS.md`.
- Add the feature under `CHANGELOG.md` → `Unreleased` → `Added`.
- Update `AGENTS.md` with the version source-of-truth and early-dispatch
  convention.
- Update the documented test count after the final test list is known.
- Mark this TDD `Approved (implemented)` only after all acceptance criteria pass.

### Release

The implementation PR must not claim it already reports `0.4.0`; it reports the
current contents of `VERSION`. The separate release commit promotes the
changelog, updates `VERSION`, and creates `v0.4.0`.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Version output accidentally triggers Cloudflare startup logic | Medium | Medium | Dispatch before zone/version checks and add an explicit check exemption |
| Installed symlink cannot find `VERSION` | Low | High | Use the existing resolved `SCRIPT_DIR`; add a symlink integration test |
| Shell code and `VERSION` drift apart | Low | Medium | Never embed a version literal; test output directly against the file |
| Malformed release file produces misleading output | Low | Medium | Validate one-line Semantic Version syntax and fail non-zero |
| Tests alter the real `VERSION` file | Low | High | Use an internal test-only file override and temporary fixtures |
| `--version` is confused with cloudflared version/update behavior | Medium | Low | Prefix output with `cftunnel` and clarify `cli-update` in help/docs |
| Early exit bypasses test sourcing controls | Low | Medium | Run version CLI tests in subprocesses and keep sourced tests argument-free |

---

## Out of Scope

| Item | Reason |
|------|--------|
| Automatically checking for newer cftunnel releases | Requires network/release API behavior separate from local reporting |
| Self-updating the cftunnel repository | `cli-update` remains scoped to the cloudflared dependency |
| Printing Git commit SHA, build timestamp, branch, or dirty state | Not stable for symlinked source installs and unnecessary for the basic command |
| JSON or machine-selectable output formats | The one-line format is already script-friendly |
| Short aliases `-v` or `-V` | Avoid ambiguity; can be proposed independently |
| Changing the `cloudflared --version` output or updater | Dependency behavior is unrelated |
| Copying `VERSION` during installation | The supported installer symlinks to the repository and already preserves adjacency |
| Bumping `VERSION` inside the feature implementation | Version promotion belongs to the release/tag workflow |

---

## Rollback Plan

The feature is stateless. Rollback consists of reverting the version helper,
early dispatcher, check exemption, tests, and documentation changes.

No Cloudflare, DNS, systemd, YAML, credential, or user configuration state is
created or migrated.

---

## Acceptance Criteria

- [x] `cftunnel --version` prints exactly `cftunnel <VERSION>` and exits `0`.
- [x] `cftunnel version` prints the identical line and exits `0`.
- [x] Successful version output writes nothing to stderr.
- [x] Both forms read the root `VERSION` file instead of a shell constant.
- [x] Both forms work through the symlink created by `install.sh`.
- [x] Both forms work without an active zone, Cloudflare credentials, network access, `cloudflared`, `jq`, or systemd.
- [x] Version requests do not invoke `check_cloudflared_version()`, `cloudflared`, or `systemctl`.
- [x] Version requests do not read, create, update, or remove zone configuration.
- [x] Missing, unreadable, empty, multiline, and non-SemVer version files fail clearly and non-zero.
- [x] Extra positional arguments are rejected.
- [x] `run.sh --help` documents `version` and `--version` and distinguishes cftunnel from cloudflared.
- [x] `VERSION` remains unchanged during feature implementation.
- [x] New tests fail before implementation and pass afterward.
- [x] `bash -n run.sh lib/*.sh tests/*.sh` reports zero syntax errors.
- [x] The full existing and new test suite passes.
- [x] README, technical docs, changelog, and AGENTS guidance are updated.

(End of file)
