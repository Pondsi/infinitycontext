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
git checkout --detach v1.8.9

# 2. the pinned tag must equal the version in SKILL.md frontmatter
if (-not (Select-String -Path SKILL.md -Pattern '^version: "1\.8\.8"' -Quiet)) {
    throw "tag/version mismatch - stop"
}

# 3. verify every file against the published digests
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

# 4b. the memory-flush-dedup hook (separate hook, its own directory)
$dedup = "$env:USERPROFILE\.openclaw\hooks\memory-flush-dedup"
New-Item -ItemType Directory -Path $dedup -Force | Out-Null
Copy-Item openclaw\memory-flush-dedup\HOOK.md    $dedup
Copy-Item openclaw\memory-flush-dedup\handler.js $dedup

# 5. restart the gateway
openclaw gateway restart
```

## Memory-flush dedup hook

After every compaction, `compaction.memoryFlush` may append the same `## ` section to the
daily memory file more than once (a flush that writes to disk but fails the compaction main
step is retried wholesale). The `memory-flush-dedup` hook runs on `session:compact:after`
and removes byte-identical duplicate sections from recent daily memory files.

- Conservative matching: two sections are duplicates only when their non-blank line content
  is fully identical (blank-line count, trailing whitespace and standalone HTML-comment
  marker lines are ignored *for comparison only*).
- Backups: before any write it copies the file to `memory/.bak/<name>.<stamp>.dedup.bak` and
  removes backups older than 14 days.
- Fail-open: every error is logged to `memory-flush-dedup.log` and never thrown, so the hook
  cannot break the compaction flow.
- CLI for a one-off sweep: `node handler.js --scan [--dry-run] | --file <path>`.

## No-window scheduling (Windows)

The hook itself never flashes: OpenClaw starts `handler.js`, which spawns PowerShell with
`windowsHide: true` and `stdio: 'ignore'`, and every child process it starts now uses
`Start-HiddenProcess` (`.NET ProcessStartInfo.CreateNoWindow = $true` — the managed form of
`CREATE_NO_WINDOW`). A child created that way has **no console at all**.

If you also register the watchdog or the cleanup as a scheduled task, do **not** point the
task straight at `powershell.exe`:

```text
# BAD - Task Scheduler creates a visible console, PowerShell hides it afterwards -> one black flash
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File ...\main-session-monitor.ps1
```

`-WindowStyle Hidden` is parsed *by PowerShell*, so the window already exists by then. Wrap
the command in a `.vbs` launcher instead, so the task host never creates a console:

```vbs
' RunHidden.vbs - run a command with no console window
Set sh = CreateObject("WScript.Shell")
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    If InStr(a, " ") > 0 Then a =  & a & 
    cmd = cmd & " " & a
Next
sh.Run Trim(cmd), 0, False
```

```powershell
# GOOD - wscript owns the process; no console is ever created
$vbs = "$env:USERPROFILE\.openclaw\workspace\scripts\RunHidden.vbs"
$sc  = "$env:USERPROFILE\.openclaw\scripts"
$tr  = "wscript.exe //nologo `"$vbs`" powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sc\main-session-monitor.ps1`" -AutoCompact"
schtasks /Create /TN "OpenClaw-MainSessionMonitor" /TR $tr /SC MINUTE /MO 10 /F

$tr2 = "wscript.exe //nologo `"$vbs`" powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sc\cleanup-old-backups.ps1`""
schtasks /Create /TN "OpenClaw-CleanupOldBackups" /TR $tr2 /SC DAILY /ST 04:10 /F
```

Verify with `Get-ScheduledTask -TaskName OpenClaw-MainSessionMonitor | Select -Expand Actions`
— `Execute` must be `wscript.exe`, never `powershell.exe`.

## Security properties

| Property | How it is enforced |
|----------|--------------------|
| No PATH hijacking (T07) | every external command is resolved to an absolute path from `System32` or a known install directory; the process `PATH` is narrowed at entry; `Resolve-TrustedExe` never falls back to a bare command name |
| No shell string interpolation | commands run as executable + argument array; no shell interpreter, no `-Command` |
| Fail-closed redaction | a trajectory backup is destroyed and the export aborted if redaction cannot run |
| Fail-closed archive permissions | `session_to_sqlite.py` aborts, closes the SQLite handle and destroys the half-written database when owner-only permissions cannot be enforced; the wrapper passes `--allow-dir` so in-place redaction refuses any path outside the backup root |
| Hook integrity | `handler.js` verifies `pipeline.ps1` against `integrity.json` (SHA-256), rejects symlinks/empty files, requires the script marker, and refuses to execute on mismatch |
| Deny-by-default agents | the allowlist is fail-closed; an empty allowlist aborts, an unlisted agent is denied |
| Declared auto-recovery | off unless `enableAutoWake` is set; one validated attempt per round; `WAKE_REQUEST` is logged before acting; no hidden retry loop |
| No unsolicited notifications | over-limit, compaction failure and wake failure are log-only |
| Bounded archive retention | the engine purges chunks older than `--retention-days` (default 30) on every run; the wrapper passes the flag through, and `INFINITY_CONTEXT_NO_ARCHIVE=1` in the environment stops the archiver before it writes anything |
| Fail-open dedup | `memory-flush-dedup` backs up before writing, rotates old backups, and logs all errors without throwing |

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
| `memory-flush-dedup/HOOK.md` | manifest for the memory-flush-dedup hook |
| `memory-flush-dedup/handler.js` | dedup handler: removes duplicate `## ` sections after compaction |
| `scripts/session_to_sqlite.py` | shared Python engine, copied next to the PowerShell wrapper |
| `scripts/secure_fs.py` | owner-only permission helper imported by the engine |

The published package has its own manifest at the repository root (`checksums.txt`).
That file covers the portable core; `openclaw/checksums.txt` covers this folder.
