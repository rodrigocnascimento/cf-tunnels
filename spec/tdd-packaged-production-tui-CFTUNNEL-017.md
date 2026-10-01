# Technical Design Document — CFTUNNEL-017

> **Issue:** CFTUNNEL-017
> **Title:** Packaged Production TUI Artifact and Launcher
> **Status:** Implemented for Linux x64/arm64 release bundles; release workflow pending first tagged run
> **Date:** 2026-09-25

---

## Decision

`cftunnel tui` launches a release-built, platform-specific Bun executable;
it must never silently run the development TypeScript source. If the artifact
is absent or invalid, the command reports a precise unavailable-production
message. `cftunnel tui-dev` remains the source-checkout launcher.

The production release pipeline will build the Ink entry point with Bun's
compiled executable mode and ship both the executable and a detached JSON
manifest in the release archive and installer payload. The same executable
also dispatches `cftunnel log` subcommands, so the installed runtime is shared
by the TUI and event logger. A source checkout may build the artifact during
installation when Bun is present; a release package already includes it and
must install without Bun. Generated artifacts do not belong in the source
repository.

## Artifact layout

Inside each release bundle, a target such as `linux-x64` contains:

```text
packages/tui/dist/
  cftunnel-runtime
  cftunnel-runtime.manifest.json
```

The manifest is public metadata only:

```json
{
  "schema_version": 1,
  "tui_version": "0.17.0",
  "cftunnel_contract_schema": 1,
  "platform": "linux",
  "arch": "x64",
  "target": "bun-linux-x64",
  "sha256": "..."
}
```

`tui_version` must exactly equal the root `VERSION` file for its release.
The SHA-256 covers the executable bytes. The embedded runtime is Bun; the
end-user production command must not require a separately installed Bun or
Node runtime.

## `cftunnel tui` launch contract

Before executing an artifact, the Bash launcher must verify, without sudo:

1. its own resolved installation directory and target platform/architecture;
2. a regular executable artifact and a regular manifest at the expected path;
3. manifest schema, platform, architecture, TUI version, and contract schema;
4. the artifact SHA-256 against the manifest; and
5. the local CLI capability contract before handing control to the TUI.

On any failure, it exits without launching the artifact and gives a precise
reinstall/upgrade action. It sets `CFTUNNEL_BIN` to the resolved installed
`run.sh` before `exec`, preserving the established architecture:

```text
Ink executable → Bun adapter → installed cftunnel JSON subprocess API
```

## Release and install boundary

The release workflow builds Linux x64 and arm64 bundles only after shell, type,
and Bun/Ink tests pass. Each archive contains the CLI source and its matching
runtime/manifest pair. `install.sh` verifies a bundled runtime before use; a
source checkout can build one when Bun is installed, after installing the
locked package dependencies. Generated artifacts do not belong in the source
repository.

## Acceptance criteria for the future implementation

- [x] A production build produces an executable/manifest pair per
  supported platform and architecture.
- [x] `cftunnel tui` verifies the pair and refuses mismatch/tampering.
- [x] Production launch works without Bun on `PATH` when using a release bundle.
- [x] `tui-dev` remains explicitly source/dependency/TTY checked.
- [ ] Run the release workflow and a clean install against the first published tag.
