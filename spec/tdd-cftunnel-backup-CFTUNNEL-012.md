# Technical Design Document — CFTUNNEL-012

> **Issue:** CFTUNNEL-012
> **Title:** `cftunnel backup` — git + age Encrypted Credential Backup
> **Version:** N/A — proposed, not scheduled
> **Status:** Proposed — for evaluation, not started
> **Date:** 2026-08-07
> **Author:** Rodrigo Nascimento (drafted from a design conversation, written for evaluation before any commitment to build)

---

## Table of Contents

1. [Overview](#overview)
2. [Motivation](#motivation)
3. [Design Goals and Non-Goals](#design-goals-and-non-goals)
4. [Why Not the Alternatives](#why-not-the-alternatives)
5. [Key Custody Model](#key-custody-model)
6. [Data Model — What Gets Backed Up and How](#data-model--what-gets-backed-up-and-how)
7. [Command Contract](#command-contract)
8. [Interactive Setup Flow (`cftunnel backup configure`)](#interactive-setup-flow-cftunnel-backup-configure)
9. [Backup Flow (`cftunnel backup`)](#backup-flow-cftunnel-backup)
10. [Restore: Deliberately Not a Command Yet](#restore-deliberately-not-a-command-yet)
11. [Error and Output Contract](#error-and-output-contract)
12. [Files Expected to Change](#files-expected-to-change)
13. [Risk Assessment](#risk-assessment)
14. [Test Plan (Future Work)](#test-plan-future-work)
15. [Out of Scope](#out-of-scope)
16. [Open Questions and Decision Gates](#open-questions-and-decision-gates)
17. [Acceptance Criteria (For Future Implementation)](#acceptance-criteria-for-future-implementation)

---

## Overview

`cftunnel`'s per-tunnel credential file (`<UUID>.json`, generated once by
`cloudflared tunnel create`) is not recoverable if lost — the only remedy
today is deleting and recreating the tunnel, which changes its UUID and
therefore its DNS target. This document proposes `cftunnel backup`: a new
subcommand that encrypts zone credentials and tunnel YAML with
[`age`](https://github.com/FiloSottile/age) and commits them to a
git repository the user already controls, automating the mechanics of a
manual "encrypt and push" routine without introducing any new
infrastructure, service, or paid dependency.

This is written for evaluation, not commitment. Nothing here has been
built, and the interactive-setup shape in particular should be read
critically before it's treated as settled — it's the part of this document
most likely to need revision once someone tries to actually use it.

### Why git + age, not a hosted service

This was an explicit fork in the design conversation. A hosted, potentially
paid "encrypted vault as a service" was considered and rejected: it would
turn a homelab CLI tool into an operator of multi-tenant secret storage,
with all the ongoing obligations that implies (uptime, key-loss liability,
abuse handling, billing, a privacy posture) — a different business than
"write a good bash tool," not a bigger version of the same one. `git` +
`age` gets nearly the same outcome (encrypted, versioned, off-host copies)
using infrastructure the user already has (a git remote they control) and a
single small, well-audited static binary (`age`), with zero new services to
build or operate.

### Files expected to change if this is implemented

| File | Proposed change |
|---|---|
| `lib/backup.sh` (new) | `op_backup`, `op_backup_configure`, supporting helpers |
| `run.sh` | Dispatch `backup` and `backup configure` subcommands |
| `AGENTS.md` | Document the new persisted config file and its conventions |
| `CHANGELOG.md` | Record the feature |
| Wiki (`Operations-and-Troubleshooting.md` or a new page) | Setup and restore runbook |

---

## Motivation

Recap of the precise, verified gap (see CFTUNNEL-011 for the full
investigation): of the three files involved in a tunnel's credentials —
`cert.pem` (zone origin cert, recoverable via `zone login`), `zone.json`
(zone metadata, regenerable alongside it), and `<UUID>.json` (tunnel
credential) — only the last is genuinely irrecoverable. Everything this
document proposes exists to make that one file (and, for convenience, its
siblings) recoverable without asking the user to remember a manual
procedure at exactly the moment they're least likely to remember it: after
already having lost a machine.

---

## Design Goals and Non-Goals

### Goals

1. **Automate the mechanics, not the judgment.** Encryption, staging, commit,
   and push should be one command. Deciding *where* the backup goes and
   *which* key protects it stays an explicit, deliberate setup step — never
   silently defaulted.
2. **cftunnel must never possess the means to decrypt its own backups.**
   See [Key Custody Model](#key-custody-model). This is the single
   non-negotiable security property of this whole design.
3. **No new infrastructure.** The destination is a git remote the user
   already has push access to (GitHub, a self-hosted Gitea instance — this
   project's own homelab already runs one — or anything else `git push`
   reaches). No cftunnel-operated storage, ever.
4. **Safe to fail loudly.** A backup that silently "succeeds" without
   actually reaching the remote is worse than no backup — it creates false
   confidence. Every failure mode must be as fail-closed as the rest of
   this project's error handling.
5. **Consistent with existing conventions.** Reuse the interactive-prompt
   style, canonical persisted-config pattern (`.default_zone` →
   `.backup_config`), and mode-`600` secrecy discipline already established
   by `lib/zone.sh`.

### Non-Goals (for this document)

- A hosted backup service of any kind — explicitly rejected, see
  [Why Not the Alternatives](#why-not-the-alternatives).
- Automated, unattended restore — see
  [Restore: Deliberately Not a Command Yet](#restore-deliberately-not-a-command-yet).
- Scheduling (a systemd timer running `cftunnel backup` automatically) —
  worth doing eventually, but this document specifies the command itself
  first; scheduling is a thin wrapper once the command is trusted.
- Multi-recipient / key-rotation support — v1 assumes one `age` recipient.

---

## Why Not the Alternatives

Recap from the conversation, recorded so this doesn't get re-litigated from
scratch:

| Alternative | Why not |
|---|---|
| Terraform | Adds a heavy external tool dependency for a problem solvable without one; rejected explicitly by the project owner as inefficient for this project's scope |
| Hosted encrypted backup service (even if paid) | Turns a CLI tool into a secrets-hosting operator; ongoing operational/legal/security liability disproportionate to the problem; existing services (a private git remote, Backblaze B2, Cloudflare R2, a second VPS) already solve "off-host encrypted storage" without cftunnel building or running anything |
| Plaintext credentials in git | The original, correctly-identified risk this document exists to avoid — a public repo (or a private one that becomes public, or has broader access than assumed) would leak tunnel private key material directly |
| Do nothing, document a manual procedure only | Real — this is the status quo. The gap identified in this conversation is specifically that manual procedures don't get done; automating the mechanics while keeping the setup step deliberate is the proposed middle ground |

---

## Key Custody Model

This is the part of the design most likely to cause real harm if gotten
wrong, so it is specified before anything else.

**cftunnel handles only the `age` public key, never the private key.** The
private key is what decrypts backups; if cftunnel ever wrote it to disk on
the same host it's backing up, a host failure would take the backup and its
only key together — defeating the entire point.

Setup must support exactly two paths, both keeping the private key outside
cftunnel's custody:

1. **Bring your own key.** The user runs `age-keygen` themselves (or already
   has a keypair), stores the private key wherever they already store
   secrets (a password manager, a hardware key, a printed copy in a safe —
   cftunnel does not care and must not ask), and gives `cftunnel backup
   configure` only the **public** key (`age1...`).
2. **Generate here, export now, forget immediately.** If the user has no
   existing key, `cftunnel backup configure` may offer to run `age-keygen`
   on their behalf — but the private key must be printed to the terminal
   exactly once, with an explicit, blocking confirmation
   ("type CONFIRMED once you have saved this private key somewhere other
   than this machine"), and must **not** be written to any file cftunnel
   controls. If the user closes the terminal before confirming, the key is
   gone and they start over — that failure mode is correct and intentional,
   not a bug to smooth over.

The persisted config file (`~/.cloudflared/.backup_config`, mode `600`,
canonical — same discipline as `.default_zone`) stores only: the git remote
URL, the local clone path, and the `age` **public** recipient key. None of
these are secret; the file's mode `600` is precautionary consistency with
the rest of the project, not protecting a secret.

---

## Data Model — What Gets Backed Up and How

Mirrors the existing `~/.cloudflared/zones/<domain>/` structure so the
backup repository's layout is legible without decrypting anything:

```text
<backup-repo>/
  zones/
    <domain>/
      *.yml                 # plaintext — not secret, diffable in git history
      credentials.tar.age   # cert.pem + zone.json + all <UUID>.json for this zone, age-encrypted
  root/
    *.yml                   # no-zone tunnels, plaintext
    credentials.tar.age     # no-zone credentials, age-encrypted (if any exist)
```

**YAML stays plaintext, credentials are encrypted, and they're split per
zone** — three deliberate choices:

- Plaintext YAML gives a genuinely useful `git log`/`git diff` history of
  ingress-configuration changes over time, at no secrecy cost (YAML has no
  key material — see `AGENTS.md`'s existing "Quote YAML values" convention;
  it's routing config, not a secret).
- Encrypting credentials per zone (one `credentials.tar.age` per zone,
  bundling that zone's `cert.pem`, `zone.json`, and every tunnel's
  `<UUID>.json` under it) means a git-history entry tells you *which zone*
  changed without decrypting anything — a smaller, more legible blast
  radius than one repo-wide encrypted blob, and consistent with this
  project's existing per-zone isolation philosophy (CFTUNNEL-002).
- A private repository is still recommended even though only the YAML is
  plaintext: hostname/service topology is not a credential, but it is
  reconnaissance-useful information about what's running where.

---

## Command Contract

```bash
cftunnel backup configure   # interactive one-time setup
cftunnel backup             # run a backup now
```

No flags beyond standard global ones (`--zone` is not applicable — a backup
always covers every zone plus the root scope, since the whole point is
disaster recovery, not a partial snapshot).

---

## Interactive Setup Flow (`cftunnel backup configure`)

Modeled on the existing `zone login` interactive pattern
(`lib/zone.sh:569+`: numbered prompts, `read -r -p`, explicit confirmation
before any write) — this is a prompt-driven flow, not a batch of flags,
because every value it collects is security-relevant enough to deserve a
human looking at it as they type it, not a one-liner someone copy-pastes
from a wiki without reading.

Sketch of the flow:

1. **Git remote.** `read -r -p "Git remote URL for backups (e.g. git@github.com:you/cftunnel-backup.git): "`.
   Validate it looks like a plausible git URL; do not attempt to guess
   whether it's public or private (cftunnel has no reliable way to know this
   for an arbitrary git host) — instead, print an explicit, unmissable
   warning recommending a private repository and explaining why (topology
   exposure, not credential exposure, since credentials are encrypted).
2. **Clone destination.** Fixed, not prompted: `~/.cloudflared/.backup/repo`
   (mirrors the fixed, canonical nature of zone directories — no
   configurability here reduces the chance of a confused, half-set-up
   state). `git clone` the remote there; if the remote is empty, `git init`
   and set the remote instead.
3. **Recipient key.** Offer a choice: "(1) I already have an age public key"
   or "(2) generate a new keypair now". Path (1) prompts for the `age1...`
   string and validates its format. Path (2) runs the generate-export-confirm
   flow from [Key Custody Model](#key-custody-model).
4. **Write `~/.cloudflared/.backup_config`** (mode `600`): remote URL, local
   clone path, public recipient key. Canonical, single-purpose, following
   `load_default_zone`/`save_default_zone`'s existing validate-before-persist
   discipline.
5. **Confirm, don't auto-run.** Print what was configured and tell the user
   to run `cftunnel backup` when ready — configure and backup stay separate
   commands so a first backup is always a deliberate, observable action,
   not a side effect of setup.

---

## Backup Flow (`cftunnel backup`)

1. Load `.backup_config`; `die()` with guidance to run `configure` first if
   it doesn't exist or fails validation (same pattern as
   `load_default_zone`'s existing failure handling).
2. `need age`, `need git` (new dependency checks, alongside the existing
   `need cloudflared`/`need jq`).
3. `git -C <clone-path> pull --ff-only` — fail closed if this doesn't
   fast-forward cleanly (a diverged local backup clone is a sign something
   is wrong; do not force-push over it silently).
4. For each zone directory and the root scope: copy `*.yml` files into the
   corresponding backup-repo path as-is; tar the credential files
   (`cert.pem`, `zone.json`, `*.json`) and encrypt with
   `age -r <recipient-public-key>` into `credentials.tar.age`.
5. `git add`, and skip the commit entirely (not an error) if there is
   nothing staged — repeated backups with no changes must be silent
   no-ops, not noisy failures or empty commits.
6. `git commit` with a timestamped message, then `git push`. A push failure
   is a hard error — the command must not report success if the remote
   copy wasn't actually updated.

---

## Restore: Deliberately Not a Command Yet

Restore writes over live credential files — the highest blast-radius
operation this document could specify, on par with the credential-transaction
machinery CFTUNNEL-007 built with real care. Rather than sketch an
automated `cftunnel backup restore` under-specified, this document proposes
v1 ship **backup only**, with a documented manual runbook:

```bash
git clone <remote> && cd <remote>
age -d -i <private-key-file> zones/<domain>/credentials.tar.age | tar xf -
# place cert.pem, zone.json, <UUID>.json at the correct zone paths, chmod 600
```

An automated restore command is a legitimate future addition, but deserves
its own decision gate and its own TDD once `cftunnel backup` itself has been
used in practice — restoring safely needs to answer questions (overwrite
confirmation per file? dry-run mode? what if local and backed-up state have
both diverged?) that are easier to answer with real usage experience than
speculatively.

---

## Error and Output Contract

- `cftunnel backup` never prints credential file contents, `age`-encrypted
  blob contents, or the private key (which it never has access to in the
  first place).
- Every failure (missing `age`/`git`, failed pull, failed push, invalid
  `.backup_config`) exits non-zero with a clear diagnostic on stderr,
  consistent with `die()` conventions elsewhere in this project.
- A successful backup with no changes to commit prints a clear "nothing
  changed" message and exits 0 — distinct from a successful backup that did
  commit and push something, so the user can tell the difference from
  output alone.

---

## Files Expected to Change

Already listed in [Overview](#overview); repeated here for the future
implementer's convenience: `lib/backup.sh` (new), `run.sh`, `AGENTS.md`,
`CHANGELOG.md`, and a Wiki runbook page covering both setup and the manual
restore procedure.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| User loses the `age` private key (never stored by cftunnel by design) | Medium | High | Explicit, blocking export-and-confirm flow at generation time; document prominently that cftunnel cannot help recover a lost key, by design |
| Git repository set to public by mistake, or access broader than assumed | Medium | Medium | Credentials are encrypted regardless; explicit warning at setup time about YAML topology exposure even for "just" a plaintext-YAML leak |
| Git history grows unbounded over many backups (each run adds a new encrypted blob) | Medium | Low | Out of scope for v1; a future `backup` mode could squash/prune history periodically |
| Push fails silently perceived as success | Low | High | Explicit non-zero exit and clear stderr message on any push failure — no partial-success reporting |
| `.backup_config` accidentally shared/copied to another host with a different intended repo | Low | Medium | File is host-local and mode `600` like other persisted state; no code path syncs it automatically |
| Automated restore built later without enough care | N/A (out of scope for v1) | High | Explicitly deferred to its own future decision gate rather than rushed into this document |

---

## Test Plan (Future Work)

Not authorized by this document. For the future implementer:

1. **Configure flow** — valid/invalid git URL formats, both recipient-key
   paths, `.backup_config` written correctly and only after full validation.
2. **Backup flow** — first backup (repo empty), subsequent backup with no
   changes (no-op, no empty commit), subsequent backup with real changes,
   pull-diverged failure, push failure, missing `age`/`git` dependency.
3. **Encryption correctness** — round-trip test: encrypt with the
   configured public key in a test fixture, decrypt with the matching
   private key in the test harness (never a real key), verify contents
   match the source files.
4. **Secrecy** — assert no test's captured stdout/stderr ever contains
   plaintext credential content or the private key.
5. All new tests integrate into the existing `tests/run.sh` phased suite,
   following the fixture-based `cloudflared`/`sudo` mocking pattern already
   used throughout `tests/test_zone_credentials.sh` and
   `tests/test_add_remote_failures.sh`, with `git` and `age` similarly
   mocked or run against disposable temp repositories.

---

## Out of Scope

| Item | Reason |
|---|---|
| Hosted backup service | Rejected — see [Why Not the Alternatives](#why-not-the-alternatives) |
| Terraform | Rejected — see [Why Not the Alternatives](#why-not-the-alternatives) |
| Automated restore | Deliberately deferred — see [Restore](#restore-deliberately-not-a-command-yet) |
| Scheduling / systemd timer integration | Natural follow-up once the command is trusted; not part of this document |
| Multi-recipient encryption / key rotation | v1 assumes a single `age` recipient |
| Any relationship to CFTUNNEL-011 (remotely-managed tunnels) | Independent proposals addressing the same gap from different angles; see CFTUNNEL-011's "Relationship to Other Design Records" |

---

## Open Questions and Decision Gates

### DG-01: Interactive-only, or also flag-driven for scripting?

The interactive flow is deliberately the primary design (per the project
owner's request) because setup values are security-relevant. Whether
`configure` should also accept flags for scripted/non-interactive setup
(e.g., provisioning a new homelab host from a script) is open — leaning
toward "interactive only for now," consistent with the "no batch flags for
security-relevant setup" reasoning above, but not decided.

### DG-02: Is per-zone credential bundling the right granularity?

Proposed above as consistent with existing zone isolation, but a single
repo-wide encrypted blob would be simpler to implement. Worth revisiting
once there's a real multi-zone user to validate the per-zone git-history
legibility argument actually matters in practice.

### DG-03: Should `cftunnel add`/`remove` trigger a backup reminder?

Not proposed here, but raised as a question: should the tool ever nudge
("you've created 3 tunnels since your last backup — run `cftunnel backup`?")
rather than relying entirely on the user or a future scheduled timer to
remember? Deferred — could be presumptuous or noisy; needs real usage
experience first.

---

## Acceptance Criteria (For Future Implementation)

None of the following are done. Recorded as the bar a future
implementation of this document must clear.

- [ ] `cftunnel backup configure` never writes an `age` private key to any
      file; the generate-new-key path requires explicit confirmation after
      the user has copied it elsewhere.
- [ ] `.backup_config` is written only after full validation, mode `600`,
      canonical, following `load_default_zone`/`save_default_zone`
      conventions.
- [ ] `cftunnel backup` fails closed (non-zero exit, clear stderr) on: missing
      `age`/`git`, unconfigured backup, failed pull, failed push.
- [ ] A backup run with no changes is a silent no-op (exit 0, clear
      "nothing changed" message, no empty commit).
- [ ] Credential files are encrypted per zone; YAML files are plaintext and
      diffable in git history.
- [ ] No command output ever contains plaintext credential content or an
      `age` private key.
- [ ] A documented manual restore procedure exists in the Wiki before this
      ships, even though automated restore is out of scope for v1.
- [ ] New tests integrate into `cd tests && ./run.sh --verbose` following
      this project's existing fixture-mocking conventions.
- [ ] `AGENTS.md` and `CHANGELOG.md` are updated with the new command and
      persisted-config file.
