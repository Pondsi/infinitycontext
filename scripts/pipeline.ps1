# compaction-pipeline.ps1 — Hook handler: runs backup + SQLite before compaction, enhanced summary after
# Called by the compaction-pipeline hook (OpenClaw internal hook system)
param(
    [Parameter(Mandatory=$true)]
    [string]$SessionKey,
    [Parameter(Mandatory=$true)]
    [string]$Phase,  # "before" or "after"
    [string]$AgentId = ''  # 可选：显式指定 Agent；留空时从 SessionKey 推导
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
# ===== 可移植性修复：通用 Python 探测器（扫描标准安装位置，不硬编码用户路径）=====
function Get-PythonExe {
    $cands = New-Object System.Collections.ArrayList
    foreach ($n in @('python3','python','py')) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and $cmd.Source -notmatch 'WindowsApps') { [void]$cands.Add($cmd.Source) }
    }
    foreach ($pat in @("$env:ProgramFiles\Python3*\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", 'C:\Python3*\python.exe')) {
        Get-ChildItem $pat -ErrorAction SilentlyContinue | ForEach-Object { [void]$cands.Add($_.FullName) }
    }
    foreach ($root in @('HKLM:\SOFTWARE\Python\PythonCore','HKCU:\SOFTWARE\Python\PythonCore')) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $ip = (Get-ItemProperty "$($_.PSPath)\InstallPath" -ErrorAction SilentlyContinue).'(default)'
            if ($ip) { [void]$cands.Add((Join-Path $ip 'python.exe')) }
        }
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path $c)) {
            $ok = $false
            try {
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $t = & $c -c "print(1)" 2>$null
                if ("$t" -match '1') { $ok = $true }
            } catch {} finally { $ErrorActionPreference = $prevEap }
            if ($ok) { return $c }
        }
    }
    return $null
}
$PyExe = Get-PythonExe
# =================================================================


$ScriptDir = $PSScriptRoot
$BackupDir = "$env:LOCALAPPDATA\.openclaw\backups\trajectory-exports"
$SqliteDir = "$env:USERPROFILE\.openclaw\sqlite-data"
$LogFile = "$env:LOCALAPPDATA\.openclaw\logs\compaction-pipeline.log"

# Directory creation guard: ensure log/backup/sqlite dirs exist before writing
foreach ($d in @((Split-Path $LogFile -Parent), "$env:LOCALAPPDATA\.openclaw\backups\trajectory-exports", "$env:USERPROFILE\.openclaw\sqlite-data")) {
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}


function Write-Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts $msg" | Out-File -Append -FilePath $LogFile -Encoding UTF8
}

# ===== T05 安全合规：默认拒绝（Deny by Default）=====
# 白名单解析优先级：环境变量 INFINITY_CONTEXT_AGENTS > 配置文件 > 内置默认 @('main')
# 显式配置为空数组 → 安全阻断；解析结果为空 → 拒绝执行
function Get-AllowedAgents {
    $list = @()
    $explicitEmpty = $false
    if ($env:INFINITY_CONTEXT_AGENTS -and $env:INFINITY_CONTEXT_AGENTS.Trim()) {
        $list = @($env:INFINITY_CONTEXT_AGENTS -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else {
        $cfg = "$env:LOCALAPPDATA\.openclaw\infinity-context.config.json"
        if (Test-Path -LiteralPath $cfg) {
            try {
                $c = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $c.allowedAgents) {
                    $list = @($c.allowedAgents | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
                    if ($list.Count -eq 0) { $explicitEmpty = $true }
                }
            } catch {}
        }
    }
    if ($list.Count -eq 0 -and -not $explicitEmpty) { $list = @('main') }
    return @($list | Where-Object { $_ -match '^[A-Za-z0-9_-]+$' } | Select-Object -Unique)
}
$AllowedAgents = Get-AllowedAgents

# AgentId 缺失时从 session key（agent:<id>:...）推导
if (-not $AgentId -and $SessionKey -match '^agent:([^:]+):') { $AgentId = $Matches[1] }

if (@($AllowedAgents).Count -eq 0) {
    Write-Log 'SECURITY_ABORT: AllowedAgents 为空，按最小权限原则拒绝执行。'
    exit 0
}
if (-not $AgentId -or $AgentId -notin $AllowedAgents) {
    Write-Log "SECURITY_DENY: Agent '$AgentId' 未在授权白名单内，拒绝导出/压缩。"
    exit 1
}
# ================================================

# ===== T09 安全修复（v7.2）：轨迹备份安全策略 =====
$TrajectoryRetentionDays = 30       # 轨迹备份保留天数（超期自动清理）
$RedactTrajectoryBackup = $true     # 备份落地前脱敏（数据最小化，默认开启）
$AllowUnredactedBackup = $false     # 显式 opt-in：仅在需要完整灾难恢复时开启

# 仅授权 当前用户 + SYSTEM 访问备份目录（移除继承 ACL）
function Protect-BackupAcl([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $me = "$env:USERDOMAIN\$env:USERNAME"
        & icacls $Path /inheritance:r /grant:r "${me}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' 2>&1 | Out-Null
    } catch { Write-Log "ACL_ERR: $Path $_" }
}

# 保留期清理：删除超期轨迹备份
function Remove-ExpiredBackups {
    try {
        if (-not (Test-Path -LiteralPath $BackupDir)) { return }
        $cutoff = (Get-Date).AddDays(-$TrajectoryRetentionDays)
        Get-ChildItem -LiteralPath $BackupDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; Write-Log "RETENTION_PURGE: $($_.Name)" } catch {}
            }
    } catch { Write-Log "RETENTION_ERR: $_" }
}

# 对轨迹文件原地脱敏（复用 Python 脱敏引擎，避免规则重复维护）
function Redact-TrajectoryFile([string]$EventsPath) {
    if (-not $RedactTrajectoryBackup -or $AllowUnredactedBackup) { return }
    if (-not $PyExe) { Write-Log 'REDACT_SKIP: python not found'; return }
    $pyScript = Join-Path $ScriptDir 'session_to_sqlite.py'
    if (-not (Test-Path -LiteralPath $pyScript)) { Write-Log 'REDACT_SKIP: redactor not found'; return }
    try {
        $out = & $PyExe $pyScript '--redact-file' $EventsPath 2>&1 | Out-String
        Write-Log "REDACT_TRAJECTORY: $(Split-Path $EventsPath -Leaf) -> $($out.Trim())"
    } catch { Write-Log "REDACT_ERR: $_" }
}
# ================================================

function Export-Trajectory($key) {
    # Get session metadata for agentId
    try {
        $metaRaw = ''
        # T05 安全修复：仅查询已授权的 Agent（不再枚举 agents 目录）
        $metaAll = New-Object System.Collections.ArrayList
        $mj = & openclaw sessions list --json --agent $AgentId 2>&1 | Out-String
        if ($mj) { try { $mp = $mj | ConvertFrom-Json; foreach ($ms in @($mp.sessions)) { [void]$metaAll.Add($ms) } } catch {} }
        $metaRaw = (@{ sessions = @($metaAll) } | ConvertTo-Json -Depth 12 -Compress) -replace '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', ''
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
            $srcDir = $exportData.outputDir
            $eventsPath = Join-Path $srcDir 'events.jsonl'
            if (Test-Path $eventsPath) {
                # Portability fix: CLI requires a relative --output (resolved under the agent workspace).
                # Move the export into our canonical LOCALAPPDATA backup dir so nothing is left in the workspace.
                $destDir = Join-Path $BackupDir (Split-Path $srcDir -Leaf)
                try {
                    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                    Move-Item -Path (Join-Path $srcDir '*') -Destination $destDir -Force -ErrorAction Stop
                    Remove-Item -Path $srcDir -Recurse -Force -ErrorAction SilentlyContinue
                    $eventsPath = Join-Path $destDir 'events.jsonl'
                    # T09 安全修复：目录 ACL 收紧到 当前用户 + SYSTEM
                    Protect-BackupAcl $destDir
                    Protect-BackupAcl $BackupDir
                    # T09 安全修复：落地前脱敏（数据最小化）
                    Redact-TrajectoryFile $eventsPath
                    Write-Log "HOOK_BEFORE: BACKUP MOVED: $key -> $destDir (events=$($exportData.transcriptEventCount))"
                    return @{ ExportDir = $destDir; EventsPath = $eventsPath; AgentId = $sess.agentId }
                } catch {
                    # T09 安全修复：移动失败时清除不完整的副本，避免残留半份数据
                    try { if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
                    Write-Log "HOOK_BEFORE: BACKUP MOVE FAILED: $key ($_) - partial destination removed"
                    Write-Log "HOOK_BEFORE: BACKUP OK: $key -> $srcDir (events=$($exportData.transcriptEventCount))"
                    return @{ ExportDir = $srcDir; EventsPath = $eventsPath; AgentId = $sess.agentId; SourceDirToClean = $srcDir }
                }
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
            '-NoProfile', '-File', $sqliteScript,
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

        $result = & $PyExe $pyFile $dbs.FullName $key 2>&1 | Out-String
        Remove-Item $pyFile -Force -ErrorAction SilentlyContinue
        Write-Log "HOOK_AFTER: SUMMARY: $key -> $($result.Trim())"
    } catch {
        Write-Log "HOOK_AFTER: SUMMARY_ERR: $key $_"
    }
}

# === MAIN ===
Write-Log "HOOK_$($Phase.ToUpper()): $SessionKey"
Remove-ExpiredBackups

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
            # T09 安全修复：若移动失败，转换完成后清除工作区内的原始导出副本
            if ($export.SourceDirToClean -and (Test-Path -LiteralPath $export.SourceDirToClean)) {
                Remove-Item -LiteralPath $export.SourceDirToClean -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "HOOK_BEFORE: SOURCE_CLEANED: $($export.SourceDirToClean)"
            }
        }
    }
} elseif ($Phase -eq 'after') {
    # Step 3: Enhanced summary (after compaction completed)
    Run-EnhancedSummary $SessionKey
}
