# compaction-pipeline.ps1 — Hook handler: runs backup + SQLite before compaction, enhanced summary after
# Called by the compaction-pipeline hook (OpenClaw internal hook system)
param(
    [Parameter(Mandatory=$true)]
    [string]$SessionKey,
    [Parameter(Mandatory=$true)]
    [string]$Phase  # "before" or "after"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
$BackupDir = "$env:LOCALAPPDATA\.openclaw\backups\trajectory-exports"
$SqliteDir = "$env:USERPROFILE\.openclaw\sqlite-data"
$LogFile = "$env:LOCALAPPDATA\.openclaw\logs\compaction-pipeline.log"

function Write-Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts $msg" | Out-File -Append -FilePath $LogFile -Encoding UTF8
}

function Export-Trajectory($key) {
    # Get session metadata for agentId
    try {
        $metaRaw = (& openclaw sessions list --json --all-agents 2>&1 | Out-String) -replace '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', ''
        $meta = $metaRaw | ConvertFrom-Json
        $sess = @($meta.sessions) | Where-Object { [string]$_.key -eq $key } | Select-Object -First 1
        if (-not $sess -or -not $sess.sessionId) {
            Write-Log "HOOK_BEFORE: session not found: $key"
            return $null
        }

        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
        $safe = ($key -replace '[^a-zA-Z0-9]', '_')
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $relativeOutput = "hook-backup-$safe-$stamp"

        $exportResult = & openclaw sessions export-trajectory --session-key $key --agent $sess.agentId --json --output $relativeOutput 2>&1 | Out-String
        $exportData = $exportResult | ConvertFrom-Json

        if ($exportData -and $exportData.outputDir) {
            $eventsPath = Join-Path $exportData.outputDir 'events.jsonl'
            if (Test-Path $eventsPath) {
                Write-Log "HOOK_BEFORE: BACKUP OK: $key -> $($exportData.outputDir) (events=$($exportData.transcriptEventCount))"
                return @{ ExportDir = $exportData.outputDir; EventsPath = $eventsPath; AgentId = $sess.agentId }
            }
        }
        Write-Log "HOOK_BEFORE: EXPORT_EMPTY: $key"
        return $null
    } catch {
        Write-Log "HOOK_BEFORE: EXPORT_ERR: $key $_"
        return $null
    }
}

function Convert-ToSqlite($key, $eventsPath) {
    try {
        if (-not (Test-Path $SqliteDir)) { New-Item -ItemType Directory -Path $SqliteDir -Force | Out-Null }
        $sqliteScript = "$ScriptDir\session-to-sqlite.ps1"
        if (-not (Test-Path $sqliteScript)) {
            Write-Log "HOOK_BEFORE: SQLITE_SKIPPED: session-to-sqlite.ps1 not found"
            return
        }
        $sqliteOutFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sqliteScript,
            '-SessionKey', $key, '-SessionFile', $eventsPath,
            '-OutputDir', $SqliteDir, '-AppendMode'
        ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $sqliteOutFile -RedirectStandardError "${sqliteOutFile}.err"
        $proc.WaitForExit(60000) | Out-Null
        $result = if (Test-Path $sqliteOutFile) { Get-Content $sqliteOutFile -Raw } else { $null }
        Remove-Item $sqliteOutFile -Force -ErrorAction SilentlyContinue
        Remove-Item "${sqliteOutFile}.err" -Force -ErrorAction SilentlyContinue
        if ($result) {
            $json = $result | ConvertFrom-Json
            if ($json.status -eq 'ok') {
                Write-Log "HOOK_BEFORE: SQLITE OK: $key -> $($json.db_path) (chunks=$($json.total_chunks))"
            } else {
                Write-Log "HOOK_BEFORE: SQLITE_FAIL: $key $($result.Substring(0, [Math]::Min(200, $result.Length)))"
            }
        }
    } catch {
        Write-Log "HOOK_BEFORE: SQLITE_ERR: $key $_"
    }
}

function Run-EnhancedSummary($key) {
    try {
        # Find the SQLite DB for this session
        $safe = ($key -replace '[^a-zA-Z0-9]', '_')
        $dbs = Get-ChildItem $SqliteDir -Filter "*.db" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $safe.Substring(0, [Math]::Min(20, $safe.Length)) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $dbs) {
            Write-Log "HOOK_AFTER: SUMMARY_SKIPPED: no SQLite DB for $key"
            return
        }

        # Write Python script to temp file (avoids PowerShell string escaping issues)
        $pyFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.py'
        @"
import sqlite3, json, sys
db_path = sys.argv[1]
session_key = sys.argv[2]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='session_chunks'")
if not cur.fetchone():
    print(json.dumps({'status':'no_table'}))
    sys.exit(0)
cur.execute('SELECT COUNT(*) FROM session_chunks WHERE session_key = ?', (session_key,))
count = cur.fetchone()[0]
conn.close()
print(json.dumps({'status':'ok', 'chunks': count, 'db': db_path}))
"@ | Out-File -FilePath $pyFile -Encoding UTF8 -Force

        $result = & "python" $pyFile $dbs.FullName $key 2>&1 | Out-String
        Remove-Item $pyFile -Force -ErrorAction SilentlyContinue
        Write-Log "HOOK_AFTER: SUMMARY: $key -> $($result.Trim())"
    } catch {
        Write-Log "HOOK_AFTER: SUMMARY_ERR: $key $_"
    }
}

# === MAIN ===
Write-Log "HOOK_$($Phase.ToUpper()): $SessionKey"

if ($Phase -eq 'before') {
    # v6.8: 检查是否有近期备份（5分钟内），避免与看门狗 Invoke-Compact 重复
    $safe = ($SessionKey -replace '[^a-zA-Z0-9]', '_')
    $recentBackup = Get-ChildItem $BackupDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^hook-backup-$safe" -or $_.Name -match "^backup-$safe" } |
        Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 5 } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($recentBackup) {
        Write-Log "HOOK_BEFORE: SKIPPED (recent backup exists: $($recentBackup.Name))"
    } else {
        # Step 1: Export trajectory (backup before compaction destroys it)
        $export = Export-Trajectory $SessionKey
        if ($export) {
            # Step 2: Convert to SQLite (while full trajectory is available)
            Convert-ToSqlite $SessionKey $export.EventsPath
        }
    }
} elseif ($Phase -eq 'after') {
    # Step 3: Enhanced summary (after compaction completed)
    Run-EnhancedSummary $SessionKey
}
