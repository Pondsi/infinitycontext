# OpenClaw integration (not part of the published skill package)

This folder is **deliberately outside the published artifact**. The ClawHub/registry
package contains only the portable Python core (`SKILL.md`, `scripts/`, `references/`).
Everything here is OpenClaw- and Windows-specific automation for the maintainer's own
machine and for users who explicitly opt in.

> **Trust boundary**: installing this folder extends the audited code boundary. It
> contains JavaScript (an OpenClaw hook handler) and PowerShell. Nothing here is fetched
> at install time by the skill itself; you copy the files deliberately.

## Requirements

- Windows with PowerShell 5.1+
- OpenClaw with the internal hook system (`hooks.internal`)
- Python 3.9+ (the redaction/SQLite engine, shared with the portable core)

## Install (pinned, verified, explicit)

Use a pinned revision and verify every digest before copying. Never copy with a wildcard.

```powershell
# 1. pinned checkout (audited release tag, never the mutable default branch)
git clone https://github.com/Pondsi/infinitycontext.git
cd infinitycontext
git checkout --detach v1.3.1

# 2. verify every file against the published digests
$expected = Get-Content openclaw\checksums.txt
# checksums.txt lines look like:  <sha256>  <path>
foreach ($line in $expected) {
    $hash, $path = $line -split '\s+', 2
    $actual = (Get-FileHash (Join-Path 'openclaw' $path) -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $hash) { throw "CHECKSUM MISMATCH: $path" }
}

# 3. explicit, file-by-file copy (no wildcards)
$hook = "$env:USERPROFILE\.openclaw\hooks\compaction-pipeline"
$sc   = "$env:USERPROFILE\.openclaw\scripts"
New-Item -ItemType Directory -Path $hook, $sc -Force | Out-Null
Copy-Item openclaw\handler.js       $hook
Copy-Item openclaw\HOOK.md          $hook
Copy-Item openclaw\pipeline.ps1     $hook
Copy-Item openclaw\pipeline.ps1     $sc
Copy-Item openclaw\main-session-monitor.ps1 $sc
Copy-Item openclaw\cleanup-old-backups.ps1  $sc
Copy-Item openclaw\session-to-sqlite.ps1    $sc
Copy-Item openclaw\update-integrity.ps1     $sc

# the PowerShell wrapper calls the shared Python engine; copy it and its helper too
Copy-Item scripts\session_to_sqlite.py      $sc
Copy-Item scripts\secure_fs.py              $sc

# 4. regenerate the hook integrity manifest for the copied pipeline.ps1
& "$sc\update-integrity.ps1" -PipelineScript "$hook\pipeline.ps1" -ManifestPath "$hook\integrity.json"

# 5. restart the gateway
openclaw gateway restart
```

## Security properties

| Property | How it is enforced |
|----------|--------------------|
| No PATH hijacking (T07) | every external command is resolved to an absolute path from `System32` or a known install directory; the process `PATH` is narrowed at entry; `Resolve-TrustedExe` never falls back to a bare command name |
| No shell string interpolation | commands run as executable + argument array; no shell interpreter, no `-Command` |
| Fail-closed redaction | a trajectory backup is destroyed and the export aborted if redaction cannot run |
| Hook integrity | `handler.js` verifies `pipeline.ps1` against `integrity.json` (SHA-256), rejects symlinks/empty files, requires the script marker, and refuses to execute on mismatch |
| Deny-by-default agents | the allowlist is fail-closed; an empty allowlist aborts, an unlisted agent is denied |
| Declared auto-recovery | off unless `enableAutoWake` is set; one validated attempt per round; `WAKE_REQUEST` is logged before acting; no hidden retry loop |
| No unsolicited notifications | over-limit, compaction failure and wake failure are log-only |

## Files

| File | Role |
|------|------|
| `handler.js` | OpenClaw internal hook: runs the pipeline around `compact:before` / `compact:after` |
| `HOOK.md` | hook manifest |
| `pipeline.ps1` | export → redact → SQLite → summary |
| `main-session-monitor.ps1` | watchdog: over-limit detection, compaction, optional auto-recovery |
| `session-to-sqlite.ps1` | CLI wrapper for the Python engine |
| `cleanup-old-backups.ps1` | retention cleanup with canonical path anchoring and `VACUUM` |
| `update-integrity.ps1` | regenerates `integrity.json` after a pipeline edit |
| `integrity.json` | SHA-256 manifest consumed by `handler.js` |
| `checksums.txt` | install-time digests for every file in this folder |
| `scripts/session_to_sqlite.py` | shared Python engine, copied next to the PowerShell wrapper |
| `scripts/secure_fs.py` | owner-only permission helper imported by the engine |

The published package has its own manifest at the repository root (`checksums.txt`).
That file covers the portable core; `openclaw/checksums.txt` covers this folder.
