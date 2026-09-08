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
    # T07：不做 PATH 搜索，只扫标准安装位置与注册表
    $cands = New-Object System.Collections.ArrayList
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

# ===== T07 安全修复：受信任可执行文件解析（绝不搜索 PATH）=====
function Resolve-TrustedExe {
    param([string[]]$Candidates, [string]$Label)
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    Write-Log "EXE_NOT_FOUND: $Label"
    return $null
}
$script:System32 = Join-Path $env:SystemRoot 'System32'
$script:ExeIcacls = Resolve-TrustedExe -Candidates @((Join-Path $script:System32 'icacls.exe')) -Label 'icacls.exe'
$script:ExeTaskkill = Resolve-TrustedExe -Candidates @((Join-Path $script:System32 'taskkill.exe')) -Label 'taskkill.exe'
# 收紧进程 PATH，使任何遗漏的子调用也无法被劫持
$env:PATH = "$script:System32;$env:SystemRoot"

function Resolve-OpenClawInvoker {
    if ($script:OpenClawInvokerResolved) { return $script:OpenClawInvoker }
    $script:OpenClawInvokerResolved = $true
    $nodeCandidates = @(
        (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    )
    $mjsCandidates = @(
        $env:INFINITY_CONTEXT_OPENCLAW_MJS,
        (Join-Path $env:APPDATA 'npm\node_modules\openclaw\openclaw.mjs'),
        (Join-Path $env:ProgramFiles 'nodejs\node_modules\openclaw\openclaw.mjs'),
        (Join-Path $env:LOCALAPPDATA 'npm-global\node_modules\openclaw\openclaw.mjs'),
        'C:\npm-global\node_modules\openclaw\openclaw.mjs'
    )
    $nodeExe = Resolve-TrustedExe -Candidates $nodeCandidates -Label 'node.exe'
    if ($nodeExe) {
        foreach ($c in $mjsCandidates) {
            if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
                $script:OpenClawInvoker = @{ File = $nodeExe; Args = @((Resolve-Path -LiteralPath $c).Path) }
                return $script:OpenClawInvoker
            }
        }
        Write-Log 'OPENCLAW_MJS_NOT_FOUND: set INFINITY_CONTEXT_OPENCLAW_MJS'
    }
    return $null
}

# 运行 OpenClaw CLI 并捕获输出（绝对路径 + 参数数组，无 shell 解释）
function Invoke-OpenClawCli {
    param([string[]]$CliArgs, [int]$TimeoutSec = 300)
    $inv = Resolve-OpenClawInvoker
    if (-not $inv) { Write-Log 'OPENCLAW_NOT_FOUND'; return '' }
    $outFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $inv.File -ArgumentList (@($inv.Args) + $CliArgs) -WindowStyle Hidden -PassThru `
             -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err" -ErrorAction Stop
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            if ($script:ExeTaskkill) { & $script:ExeTaskkill /PID $p.Id /T /F 2>&1 | Out-Null }
        }
        return (Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
    } catch { Write-Log "OPENCLAW_CLI_ERR: $_"; return '' }
    finally {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$outFile.err" -Force -ErrorAction SilentlyContinue
    }
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
        if (-not $script:ExeIcacls) { Write-Log 'ACL_SKIP: icacls not found in System32'; return }
        $me = "$env:USERDOMAIN\$env:USERNAME"
        & $script:ExeIcacls $Path /inheritance:r /grant:r "${me}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' 2>&1 | Out-Null
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

# 定位脱敏引擎：脚本同目录优先，其次用户 scripts 目录（hook 目录可能只有 hook 文件）
function Resolve-RedactorScript {
    $cands = @(
        (Join-Path $ScriptDir 'session_to_sqlite.py'),
        (Join-Path $ScriptDir '..\scripts\session_to_sqlite.py'),
        (Join-Path $env:USERPROFILE '.openclaw\scripts\session_to_sqlite.py')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# 对轨迹文件原地脱敏（复用 Python 脱敏引擎，避免规则重复维护）
# Fail-Closed：脱敏不可用/失败时【销毁产物】并返回 $false，绝不保留未脱敏明文。
function Redact-TrajectoryFile([string]$EventsPath) {
    # 显式 opt-in 的完整备份：不做脱敏，但必须由用户主动开启
    if ($AllowUnredactedBackup) {
        Write-Log 'REDACT_BYPASS: unredacted backup explicitly opted in'
        return $true
    }
    if (-not $RedactTrajectoryBackup) {
        Write-Log 'REDACT_DISABLED: redaction is mandatory - destroying artifact'
        Remove-Item -LiteralPath $EventsPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    $pyScript = Resolve-RedactorScript
    if (-not $PyExe -or -not $pyScript) {
        Write-Log 'REDACT_FAIL_CLOSED: redactor unavailable - destroying artifact'
        Remove-Item -LiteralPath $EventsPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    try {
        $out = & $PyExe $pyScript '--redact-file' $EventsPath '--allow-dir' $BackupDir 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "REDACT_FAIL_CLOSED: exit=$LASTEXITCODE - destroying artifact"
            Remove-Item -LiteralPath $EventsPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        Write-Log "REDACT_TRAJECTORY: $(Split-Path $EventsPath -Leaf) -> $($out.Trim())"
        return $true
    } catch {
        Write-Log "REDACT_FAIL_CLOSED: $_ - destroying artifact"
        Remove-Item -LiteralPath $EventsPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}
# ================================================

function Export-Trajectory($key) {
    # Get session metadata for agentId
    try {
        $metaRaw = ''
        # T05 安全修复：仅查询已授权的 Agent（不再枚举 agents 目录）
        $metaAll = New-Object System.Collections.ArrayList
        $mj = Invoke-OpenClawCli -CliArgs @('sessions', 'list', '--json', '--agent', $AgentId)
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

        $exportResult = Invoke-OpenClawCli -CliArgs @('sessions', 'export-trajectory', '--session-key', $key, '--agent', $sess.agentId, '--json', '--output', $relativeOutput)
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
                    # T09 安全修复：脱敏为强制且 Fail-Closed——失败即销毁产物，绝不保留明文
                    if (-not (Redact-TrajectoryFile $eventsPath)) {
                        try { if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
                        Write-Log "HOOK_BEFORE: BACKUP_ABORTED: redaction failed, no backup retained ($key)"
                        return $null
                    }
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
        # 审计整改：直接调用 Python 引擎（不再 spawn powershell.exe 子进程，无 shell 解释）
        $pyScript = Resolve-RedactorScript
        if (-not $PyExe -or -not $pyScript) {
            Write-Log "HOOK_BEFORE: SQLITE_SKIPPED: python or session_to_sqlite.py not found"
            return
        }
        $result = & $PyExe $pyScript '--session-key' $key '--session-file' $eventsPath '--output-dir' $SqliteDir '--append' 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "HOOK_BEFORE: SQLITE_FAIL: $key exit=$LASTEXITCODE $($result.Trim())"
            return
        }
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
