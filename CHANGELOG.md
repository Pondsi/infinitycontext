# Changelog

All notable changes to InfinityContext are documented here.
Format: version — date — summary.

## 1.3.0 — 2026-09-09

Structural release: the portable core and the OpenClaw/Windows integration are now
separate, so the audit findings T07 and T08 cannot recur by construction.

### Changed
- **Package split.** The published artifact contains the portable Python core only
  (`SKILL.md`, `scripts/*.py`, `references/`, docs, sponsors). All PowerShell and the
  OpenClaw hook moved to `openclaw/`, which is outside the published package.
- **T07 (tool hijacking) removed at the root.** The published package invokes no external
  command at all. In the integration folder every external binary is resolved to an
  absolute path from `System32` or a known install directory (`Resolve-TrustedExe`);
  `Get-Command`/`npm root -g` PATH lookups are gone, the process `PATH` is narrowed at
  entry, and a regex self-check confirms zero bare calls.
- **T08 (insecure dependencies) removed at the root.** The package is self-contained and
  installs nothing from the network. The optional integration is documented in
  `openclaw/README.md` with a pinned revision, `openclaw/checksums.txt` verification and
  an explicit file-by-file copy (no wildcards).

### Added
- `scripts/cleanup.py` — portable retention cleanup with canonical path anchoring,
  extension allowlist, symlink refusal, dry-run by default and `VACUUM`.
- `scripts/search.py` — read-only FTS5 retrieval with a `LIKE` fallback for short CJK
  queries.
- `references/architecture.md`, `openclaw/README.md`, `openclaw/checksums.txt`.

### DeepSeek Harness (dsh)
- Documented as a first-class host: `~/.agents/skills/infinity-context/` (rank 500) or
  `<project>/.agents/skills/infinity-context/` (rank 200), directory name must equal the
  frontmatter `name`, and dsh does not support recursive discovery.
- Frontmatter reduced to the Agent Skills fields; `version` moved into `metadata`.

## 1.2.1 — 2026-09-09

Registry-compliance release. ClawHub's static analysis rejects any package containing
self-executing JavaScript (`suspicious.dangerous_exec` on `child_process`), and there is
no suppression mechanism. The published package therefore ships **no `.js` files**.

### Changed
- The optional OpenClaw compaction hook (`src/handler.js`, `src/HOOK.md`,
  `src/integrity.json`) is now distributed **in the GitHub repository only**; it is not
  part of the registry package. `README.md`, `SKILL.md` and `说明.md` state this
  explicitly.
- Everything in the registry package runs as scripts the agent invokes through its
  declared tools — no hidden execution path.
- Verification extended to 3 rounds / 192 checks against the installed copy.

## 1.2.0 — 2026-09-09

Security & compliance hardening round (external audit findings).

### Fixed
- **Fail-closed redaction (T09)**: `pipeline.ps1` now destroys the trajectory artifact
  and aborts the backup whenever redaction is unavailable, exits non-zero, or throws.
  Plaintext retention requires an explicit opt-in (`$AllowUnredactedBackup = $true`).
- **Redactor resolution**: the redaction engine is now located in the script directory
  *or* `~/.openclaw/scripts/`, so the hook copy no longer silently skips redaction.
- **Intent/code divergence**: removed the external notification process
  (the external notification script) from the watchdog. Behaviour now matches the documented policy:
  over-limit, compaction failure and wake failure are **log-only**.

### Changed
- **Auto-recovery is declared, not hidden**: documented as an opt-in capability in the
  skill description, README, `说明.md` and the security notice. It is controlled by
  `enableAutoWake` in `infinity-context.config.json` (default: off).
- **Single attempt, no hidden loop**: replaced the 3 × 10 s blocking retry with one
  validated attempt per monitor round; verification happens on the next round.
- **Hardened entry point**: `Invoke-WakeSession` uses `[CmdletBinding()]` +
  `[ValidatePattern]`, and re-validates the session key before any process boundary.
- **Absolute executable paths**: `powershell.exe` and `taskkill.exe` are resolved from
  `%SystemRoot%\System32` instead of `PATH`.
- **Hook integrity**: `handler.js` verifies `pipeline.ps1` against `integrity.json`
  (SHA-256), rejects symlinks/empty files, requires the script marker, and refuses to
  execute on mismatch. `scripts/update-integrity.ps1` regenerates the manifest.
- **No redundant subprocess**: `pipeline.ps1` calls the Python engine directly instead
  of spawning a nested `powershell.exe`.
- **Host compatibility**: the skill is documented as a standard Agent Skills skill with
  first-class support for DeepSeek Harness (dsh); OpenClaw is optional. Frontmatter now
  declares `license`, `compatibility` and `metadata`.
- **Image metadata**: sponsor QR images had EXIF (including an embedded thumbnail and
  camera model) stripped losslessly — pixel data untouched, codes still scannable.

## 1.1.0 — 2026-09-08

Privacy & compliance hardening.

- Removed the shell-interpreter invocation; direct CLI launch with argument arrays and validation.
- Trajectory backups: ACL restricted to current user + SYSTEM, redacted before landing,
  30-day retention, partial destinations removed on failure.
- Redaction expanded (JWT, AWS, Google, Slack, PEM keys, connection strings, cookies,
  webhooks, phone numbers, emails) and applied **before** metadata derivation.
- Data minimization via `MAX_ARCHIVE_LENGTH` truncation; high-entropy candidates
  excluded from the keyword index.
- Declared `allowed-tools` scope; privacy notice added to README/SKILL/说明.
- `cleanup-old-backups.ps1` adds SQLite `VACUUM`.

## 1.0.0 — 2026-09-08

First public release.

- Deny-by-default agent allowlist (fail-closed; no allow-all fallback).
- No agents-directory enumeration; agent derived from the session key.
- `cleanup-old-backups.ps1` hardening: `ValidateRange(1..3650)`, canonical path
  anchoring, extension allowlist, reparse-point skip, `-WhatIf` support.
- `compaction-pipeline` hook: backup + SQLite + enhanced summary on every compaction path.

## Earlier (0.1.x)

Internal iterations: dual-condition trigger, `session_chunks` table fix, UTF-8 forcing,
Windows path fixes, sticky-state fixes, hook wiring, temp-file Python invocation.
