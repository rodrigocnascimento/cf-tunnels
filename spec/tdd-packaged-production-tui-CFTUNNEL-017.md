# Technical Design Document — CFTUNNEL-017

> **Issue:** CFTUNNEL-017
> **Title:** Packaged Production TUI Artifact and Launcher
> **Status:** Approved for future implementation
> **Date:** 2026-09-25

---

## Decision

`cftunnel tui` will launch a release-built, platform-specific Bun executable;
it must never silently run the development TypeScript source. Until that
artifact exists, the command remains an explicit unavailable-production
message and `cftunnel tui-dev` remains the source-checkout launcher.

The production release pipeline will build the Ink entry point with Bun's
compiled executable mode and ship both the executable and a detached JSON
manifest in the release archive and installer payload. Generated artifacts do
not belong in the source repository.

## Artifact layout

For a target `linux-x64`, a release contains:

```text
packages/tui/dist/
  cftunnel-tui-linux-x64
  cftunnel-tui-linux-x64.manifest.json
```

The manifest is public metadata only:

```json
{
  "schema_version": 1,
  "tui_version": "0.11.0",
  "cftunnel_contract_schema": 1,
  "platform": "linux",
  "arch": "x64",
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

The release workflow creates the artifact only after typecheck and Bun/Ink
tests pass. It computes the manifest after compiling, packages the matching
artifact with `install.sh`, and verifies it in a clean install test. The
installer copies no build toolchain; it only installs the verified release
payload. Cross-platform artifacts are built separately and never selected by
extension or an unvalidated filename.

## Acceptance criteria for the future implementation

- [ ] A production build produces a deterministic executable/manifest pair per
  supported platform and architecture.
- [ ] `cftunnel tui` verifies the pair and refuses mismatch/tampering.
- [ ] Production launch works without Bun on `PATH`.
- [ ] `tui-dev` remains explicitly source/dependency/TTY checked.
- [ ] The release workflow and a clean-install check exercise both launchers.
