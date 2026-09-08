# Changelog

All notable changes to InfinityContext are documented here.
Format: version — date — summary.

## 1.4.0 — 2026-09-09

Fail-closed release. The archive now refuses to store readable data when it cannot
prove owner-only access, and the in-place redactor no longer uses a predictable
temporary file name.

### Changed (breaking for filesystems that cannot enforce owner-only access)
- **T09-1 — fail-closed permissions.** `secure_fs` no longer returns a "best effort"
  success. Every hardening step either proves the owner-only result (POSIX mode is
  re-read with `lstat`, ownership is checked) or raises `UnsafeArchiveError`.
  `session_to_sqlite.py` reacts by closing the SQLite handle first, destroying the
  half-written database and its `-wal`/`-shm` sidecars, and exiting with code 3.
  The only opt-out is the explicit `--allow-insecure-storage` flag, which prints a
  warning and reports `insecure_storage: true` in the JSON result.
- Symbolic links on the target path (file or parent directory) are refused, and a
  newly created archive directory is removed again if it cannot be secured.

### Fixed
- **T09-2 — predictable temporary file.** `redact_file_in_place` wrote to
  `<name>.redact.tmp`, which an attacker could pre-create as a symlink. It now uses
  `tempfile.mkstemp` (kernel `O_EXCL`, 0600) in the target directory, refuses symlinks
  and foreign-owned parent directories, `fsync`s before the atomic replace, removes the
  temporary file on every failure path, and re-applies owner-only permissions to the
  final file. The OpenClaw integration passes `--allow-dir` so the engine refuses paths
  outside the backup root.

### License
- The MIT license now carries an explicit **mandatory attribution** clause: any use of
  the source, including modified variants, must credit Pondsi. The requirement is
  repeated in `SKILL.md`, `README.md` (all languages) and `说明.md`.

### Verified
- Three rounds: static/security, functional (including fail-closed abort, symlink
  refusal, temporary-file leftovers, BOM), and installed-copy end-to-end.

## 1.3.3 — 2026-09-09

Robustness fix found while validating the published package end to end.

### Fixed
- **BOM-prefixed transcripts were silently dropped.** A JSONL transcript that starts
  with a UTF-8 byte-order mark made `json.loads` fail on the first line, and the
  archiver skipped it without a word — so a single-line transcript produced zero
  chunks. The reader now opens transcripts as `utf-8-sig`, which transparently
  consumes a BOM and behaves like `utf-8` otherwise. Verified both ways: a BOM file
  and a plain file each archive exactly one chunk.

## 1.3.2 — 2026-09-09

Documentation correctness release. Two defects in the 1.3.1 instructions would have
broken the promised out-of-the-box experience.

### Fixed
- **Registry slug.** Every install command said `clawhub install infinity-context`,
  but the published slug is `infinitycontext` (no hyphen). The command returned
  "Skill not found". All quick-starts, in every language, now use the real slug and
  show a concrete command for dsh / Claude Code (`--workdir ~/.agents --dir skills`)
  and for OpenClaw (`--workdir ~/.openclaw --dir skills`, or the workspace `skills/`
  directory, which wins).
- **dsh skill-discovery rules.** The docs claimed "the directory name must equal the
  frontmatter `name`". The official DeepSeek Harness documentation and the
  `dsh-skill-filesystem` package state otherwise: a skill is a directory bundle one
  level deep (`<root>/<dir>/SKILL.md`) or a flat `<name>.md`, nested `**/SKILL.md`
  files are deliberately not discovered, `name` and `description` are required, and
  `name` must be kebab-case. The folder name is not part of the identity — dsh
  addresses the skill by the frontmatter `name` — so the registry bundle
  `infinitycontext/` works as installed.

## 1.3.1 — 2026-09-09

Security-hardening release. Closes the two remaining audit warnings (T09 archive
permissions, T08 unpinned install instructions) and makes the skill a first-class
citizen on both DeepSeek Harness (dsh) and OpenClaw.

### Added
- `scripts/secure_fs.py` — owner-only filesystem hardening. POSIX forces `0700` on the
  archive directory and `0600` on files; Windows replaces the DACL with a protected DACL
  granting only the current user and LOCAL SYSTEM. Database files are created atomically
  with `os.open(..., 0o600)`, so no file ever exists with wider permissions (TOCTOU
  removed). A pre-existing directory owned by another account is refused; a merely
  over-permissive one is tightened; an unenforceable filesystem produces a loud warning
  and `permissions_enforced: false` in the JSON result.
- `checksums.txt` at the repository root: SHA-256 of every published file (except
  itself), so a source install can be verified byte-for-byte.
- `.gitattributes` (`* -text`) so checkouts are byte-identical on every platform and the
  manifest stays valid.
- `references/languages.md` — the localised summaries moved out of `SKILL.md`.

### Changed
- **T09 (archive permissions).** The archive directory, the database and the `-wal`/`-shm`
  sidecars are owner-only. Windows ACLs are written with in-process Win32 security API
  calls (`ctypes`); the directory ACE uses `(OI)(CI)` inheritance while file ACEs use
  plain `F`, and no external tool is spawned.
- **T08 (unpinned install).** Every quick-start now leads with the registry install and
  uses `git checkout --detach v1.3.1` plus `sha256sum -c checksums.txt` for source
  installs. `cp -r` was replaced by explicit per-file copies in all languages.
- `SKILL.md` trimmed: the two canonical sections stay, long reference moved to
  `references/`. Frontmatter `description` now leads with the situations that should
  trigger the skill.
- `cleanup.py` and `search.py` refuse an archive directory owned by another account.

### DeepSeek Harness (dsh) and OpenClaw
- Both are documented as out-of-the-box hosts with an explicit install command for each.
- `openclaw/README.md` install steps now copy the shared Python engine and its helper.

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
