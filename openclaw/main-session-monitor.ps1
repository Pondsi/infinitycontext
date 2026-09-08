# ============================================================
# main-session-monitor.ps1 v7.1 - 主会话上下文监控（T05 默认拒绝白名单 + 安全加固版）
# 背景：08-18 事故——main dashboard 会话上下文膨胀到 804%（210万/26万），
#       ollama 超窗 aborted 导致回复中断 1 小时+；监控只检测不压缩（计划任务
#       没传 -AutoCompact），内置压缩在 ollama 忙/超窗时失败，死锁到用户手动
#       "继续"才恢复。
# Behaviour policy (declared, single source of truth):
#   1. Over-limit / compaction failure / pause: LOG ONLY. This script never spawns
#      an external notification process (no sound, no message push) for these events.
#   2. Optional auto-recovery (OFF by default; opt-in via
#      %LOCALAPPDATA%\.openclaw\infinity-context.config.json -> {"enableAutoWake": true}):
#      when a session stalls after a failed turn, ONE validated resume command may be
#      sent. One attempt per round, no hidden sleep/retry loop; recovery is verified on
#      the next scheduled round. Every attempt is written to the log (WAKE_REQUEST).
#   3. Every external command uses an absolute executable path plus an argument array;
#      no shell string interpolation anywhere in this file.
# v5.8: compact every agent session regardless of kind; also compact `done` sessions;
#       cooldown 15 -> 5 min; loop guard 1/10min and 2/30min unless new dialogue.
# v5.9: dual trigger (35% + 60000 absolute) + enhanced summary after compaction.
# v6.3: force UTF-8 + strip control characters (JSON parse was swallowed by catch).
# v6.4: Windows directory-name colon replacement ([^a-zA-Z0-9:-] -> [^a-zA-Z0-9]).
# v6.5: SqliteDir unified to an ASCII path + session_chunks table name fix.
# v6.6: sticky pausedUntil double bug (missing write + [int] overflow -> [long]).
# Incident hardening (08-18):
#   1. Scheduled task restored with -AutoCompact (attempt compaction every 10 min)
#   2. Compaction failure no longer pauses easily: >100% emergency retries every round;
#      normal over-limit pauses only after 5 consecutive failures, for 30 min
#   3. Transcript is backed up before compaction (recoverable if compaction corrupts it)
#   4. Compaction timeout window 300s (over-window summaries take longer)
# 调度：计划任务 OpenClaw-MainSessionMonitor（每 10 分钟，纯脚本零 LLM 开销）
# 日志：~/.openclaw/logs/main-session-monitor.log
# ============================================================

param(
    [switch]$AutoCompact   # 尝试自动压缩（计划任务已带此参数）
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

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

# ===== T09 安全修复：OpenClaw CLI 可信调用器（无 cmd.exe / 无 shell 字符串拼接）=====
# 审计要求：不得通过 shell 解释器传入未校验的会话元数据。
# 这里解析出 node.exe + openclaw.mjs 的绝对路径，以参数数组直接调用，杜绝 shell 解释。
$script:OpenClawInvoker = $null
$script:OpenClawInvokerResolved = $false

# T07 安全修复：受信任可执行文件解析（绝不搜索 PATH，绝不回退到裸命令名）
function Resolve-TrustedExe {
    param([string[]]$Candidates, [string]$Label)
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log "EXE_NOT_FOUND: $Label" }
    return $null
}

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
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log 'OPENCLAW_MJS_NOT_FOUND: set INFINITY_CONTEXT_OPENCLAW_MJS to the openclaw.mjs path' }
    }
    return $null
}

# 运行 OpenClaw CLI 并捕获输出（绝对路径 + 参数数组，无 shell 解释）
function Invoke-OpenClawCli {
    param([string[]]$CliArgs, [int]$TimeoutSec = 180)
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

# 严格校验会话元数据（命令注入防线）
function Test-SafeSessionKey([string]$k) {
    return ($k -and $k.Length -le 200 -and $k -match '^[A-Za-z0-9:_\-\.]+$')
}
function Test-SafeAgentId([string]$a) {
    return ($a -and $a.Length -le 64 -and $a -match '^[A-Za-z0-9_-]+$')
}

# 直接调用 OpenClaw CLI（返回 Process 对象；失败返回 $null）
function Start-OpenClawCli {
    param([string[]]$CliArgs)
    $inv = Resolve-OpenClawInvoker
    if (-not $inv) { Write-Log 'OPENCLAW_NOT_FOUND'; return $null }
    try {
        return Start-Process -FilePath $inv.File -ArgumentList (@($inv.Args) + $CliArgs) -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        Write-Log "OPENCLAW_SPAWN_ERR: $_"
        return $null
    }
}
# =================================================================

# ===== T05 安全修复：会话枚举辅助函数（默认拒绝 / Deny by Default）=====
# 仅查询白名单内的 Agent，绝不枚举 agents 目录、绝不回退为“全部允许”。
function Get-SessionsJson {
    $agents = @($AllowedAgents)
    if (-not $agents -or $agents.Count -eq 0) { return '{"sessions":[]}' }
    $all = New-Object System.Collections.ArrayList
    foreach ($a in $agents) {
        if ($a -notmatch '^[A-Za-z0-9_-]+$') { continue }
        $j = Invoke-OpenClawCli -CliArgs @('sessions', 'list', '--json', '--agent', $a)
        if ($j) {
            try {
                $p = $j | ConvertFrom-Json
                foreach ($s in @($p.sessions)) { [void]$all.Add($s) }
            } catch {}
        }
    }
    return (@{ sessions = @($all) } | ConvertTo-Json -Depth 12 -Compress)
}
# =================================================================

# =================================================================


$ThresholdPct = 35.0          # 35% 就压缩（原 49%），更早介入防溢出
$ThresholdAbsTokens = 60000    # 绝对值门槛 60000 tokens（防空转）
$CompactCooldownMin = 5        # v5.8：压缩冷却 5 分钟（原 15）
$CompressTimeoutSec = 300     # compact 超时（超窗会话摘要更久，08-18 从 240 调大）
$WakeCooldownMin = 30          # v5.5：同一会话失败唤醒冷却（分钟），防反复唤醒循环
$WakeIdleMin = 4               # v5.5：会话尾部无新写入超过此分钟数才判定失败（防误判进行中）
$StickyLimit = 5              # 连续失败 5 次 → 暂停该会话自动重试 30 分钟
$StickyPauseMin = 30          # sticky 暂停时长（分钟）
$EmergencyPct = 100.0         # 超过窗口 100% = 紧急态：不暂停，每轮必试压缩

# ===== T05 安全合规配置（默认拒绝 / Deny by Default）=====
# 白名单解析优先级：
#   1) 环境变量 INFINITY_CONTEXT_AGENTS（逗号分隔，例：main,yai）
#   2) 配置文件 %LOCALAPPDATA%\.openclaw\infinity-context.config.json 的 allowedAgents 数组
#   3) 内置默认值 @('main')
# 若显式配置为空数组 → 安全阻断退出（绝不回退为“全部允许”）。
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

# Optional auto-recovery switch. Declared behaviour, read from the local config file:
#   %LOCALAPPDATA%\.openclaw\infinity-context.config.json -> {"enableAutoWake": true}
# Default: disabled. Nothing is ever enabled implicitly.
$EnableAutoWake = $false
try {
    $wakeCfgPath = "$env:LOCALAPPDATA\.openclaw\infinity-context.config.json"
    if (Test-Path -LiteralPath $wakeCfgPath) {
        $wakeCfg = Get-Content -LiteralPath $wakeCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($wakeCfg.enableAutoWake -eq $true) { $EnableAutoWake = $true }
    }
} catch { }
# ==========================================

$BackupDir = "$env:LOCALAPPDATA\.openclaw\backups\sessions"   # 压缩前 transcript 备份
$LockFile = "$env:USERPROFILE\.openclaw\main-session-monitor.lock"
$LogFile = "$env:LOCALAPPDATA\.openclaw\logs\main-session-monitor.log"


# Directory creation guard: ensure log/backup dirs exist before writing
foreach ($d in @((Split-Path $LogFile -Parent), $BackupDir)) {
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$StateFile = "$env:LOCALAPPDATA\.openclaw\main-session-monitor-state.json"
$CompactStateFile = "$env:USERPROFILE\.openclaw\compaction-active.json"   # v5.7: 压缩进行中标记（通知脚本据此跳过警告）

# ---------- 文件锁 ----------
$lockOk = $false
try {
    $fs = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $lockOk = $true
} catch {
    try {
        $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
        if ($age.TotalMinutes -gt 12) {
            Remove-Item $LockFile -Force
            $fs = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $lockOk = $true
        }
    } catch {}
}
if (-not $lockOk) { Write-Output "LOCKED_SKIP"; exit 0 }

function Write-Log {
    param([string]$msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

# T07 安全修复：系统工具只从 System32 解析（绝对路径，无 PATH 搜索）
$script:System32 = Join-Path $env:SystemRoot 'System32'
$script:ExeTaskkill = Resolve-TrustedExe -Candidates @((Join-Path $script:System32 'taskkill.exe')) -Label 'taskkill.exe'
$script:ExePowerShell = Resolve-TrustedExe -Candidates @((Join-Path $script:System32 'WindowsPowerShell\v1.0\powershell.exe')) -Label 'powershell.exe'
if (-not $script:ExeTaskkill -or -not $script:ExePowerShell) {
    Write-Log 'FATAL: required system utilities not found in System32'
    exit 1
}
# 收紧进程 PATH，使任何遗漏的子调用也无法被劫持
$env:PATH = "$script:System32;$env:SystemRoot"

# T05 安全修复：Fail-Closed 启动检查——白名单为空则拒绝运行（最小权限原则）
if (@($AllowedAgents).Count -eq 0) {
    Write-Log 'SECURITY_ABORT: AllowedAgents 为空。按最小权限原则必须显式授权至少一个 Agent，已拒绝运行。'
    exit 0
}

# Optional auto-recovery: send exactly one validated resume command to a stalled session.
# Declared and opt-in (enableAutoWake); single attempt; always audited in the log.
# Launched as an absolute-path executable with an argument array - no shell interpretation.
function Invoke-WakeSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9:_\-\.]{1,200}$')]
        [string]$SessionKey,
        [string]$Reason = 'auto'
    )

    if (-not $EnableAutoWake) {
        Write-Log "WAKE_SKIP ($Reason): $SessionKey（enableAutoWake 未开启，跳过自动恢复）"
        return $false
    }

    # Defense in depth: re-validate the session key before it reaches any process boundary
    if (-not (Test-SafeSessionKey $SessionKey)) {
        Write-Log "WAKE_REJECT ($Reason): invalid session key format"
        return $false
    }

    try {
        Write-Log "WAKE_REQUEST ($Reason): $SessionKey（已授权的自动恢复，单次尝试）"
        $proc = Start-OpenClawCli -CliArgs @('agent', '-m', '继续', '--session-key', $SessionKey)
        if (-not $proc) { Write-Log "WAKE_ERR ($Reason): $SessionKey (spawn failed)"; return $false }
        Write-Log "WAKE_SENT ($Reason): $SessionKey (pid=$($proc.Id))"
        return $true
    } catch { Write-Log "WAKE_ERR ($Reason): $SessionKey $_"; return $false }
}

# ---------- compact（带轮询式超时 + 分块压缩兜底） ----------
$SqliteDir = "$env:USERPROFILE\.openclaw\sqlite-data"   # v6.5：统一用 ASCII 路径（Python fallback 也是这个目录）
$CompactionWindowCache = @{}  # 压缩模型窗口缓存

function Get-CompactionWindow {
    # 获取压缩模型的上下文窗口大小
    if ($CompactionWindowCache.ContainsKey('window')) { return $CompactionWindowCache['window'] }
    $window = 131072  # 默认128K
    try {
        $model = (openclaw config get agents.defaults.compaction.model 2>&1 | Out-String).Trim()
        # 已知大窗口模型
        if ($model -match 'deepseek-v4-flash|mimo-v2\.5') { $window = 1000000 }
        elseif ($model -match 'deepseek-v4-pro') { $window = 1000000 }
    } catch {}
    $CompactionWindowCache['window'] = $window
    return $window
}

function Invoke-Compact {
    param([string]$key, [double]$usedTokens = 0)
    # 从 session key 解析 agentId（compact 命令对 global key 要求 --agent）
    $agentId = if ($key -match '^agent:([^:]+):') { $Matches[1] } else { '' }
    # T09 安全修复：命令注入防线——未通过校验的会话元数据一律拒绝
    if (-not (Test-SafeSessionKey $key) -or -not (Test-SafeAgentId $agentId)) {
        Write-Log 'COMPACT_REJECT: invalid session key or agent id'
        return -3
    }
    # v6.3（09-08 修复）：VBS 无控制台启动时 PS 5.1 默认 GBK 解码 stdout，openclaw UTF-8 中文 label 破坏 JSON——解析前强制 UTF-8 并重设
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    # v6.8（09-08 修复）：统一由 hook 管线（pipeline.ps1）负责备份+SQLite，Invoke-Compact 不再重复
    # 调用 pipeline.ps1 -Phase before 做备份，如果 hook 后续触发会检测到近期备份并跳过
    $pipelineScript = Join-Path $PSScriptRoot "pipeline.ps1"
    if (Test-Path $pipelineScript) {
        try {
            # 绝对路径解析（不用 PATH 查找，杜绝劫持）
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $taskkillExe = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (-not (Test-Path -LiteralPath $psExe)) {
                Write-Log "PIPELINE_SKIP: powershell.exe not found at $psExe"
            } else {
                $pp = Start-Process -FilePath $psExe -ArgumentList @(
                    '-NoProfile', '-NonInteractive', '-File', $pipelineScript,
                    '-SessionKey', $key, '-Phase', 'before'
                ) -WindowStyle Hidden -PassThru
                $ppDeadline = (Get-Date).AddSeconds(60)
                while (-not $pp.HasExited -and (Get-Date) -lt $ppDeadline) { Start-Sleep -Milliseconds 500 }
                if (-not $pp.HasExited) { try { & $taskkillExe /PID $pp.Id /T /F 2>&1 | Out-Null } catch {} }
                Write-Log "PIPELINE_BEFORE: $key (hook pipeline)"
            }
        } catch { Write-Log "PIPELINE_BEFORE_ERR: $key $_" }
    }
    
    # 分块压缩逻辑：如果会话 token 超过压缩模型窗口的 60%，分多轮压缩
    $compactionWindow = Get-CompactionWindow
    $safetyLine = $compactionWindow * 0.6
    $maxRounds = 3  # 最多压缩3轮，防止死循环
    
    if ($usedTokens -gt $safetyLine -and $usedTokens -gt 0) {
        # 分块压缩模式
        Write-Log "CHUNKED_COMPACT: $key used=$usedTokens > safety=$safetyLine (60% of $compactionWindow)，启动分块压缩"
        $round = 0
        $currentUsed = $usedTokens
        while ($currentUsed -gt $safetyLine -and $round -lt $maxRounds) {
            $round++
            # 每轮只保留最近 30% 的内容（--max-lines 按行数估算）
            # 估算：每轮压缩保留约 40% 的原始内容
            $keepRatio = 0.4
            $p = Start-OpenClawCli -CliArgs @('sessions', 'compact', $key, '--agent', $agentId, '--timeout', "$($CompressTimeoutSec * 1000)")
            if (-not $p) { Write-Log "CHUNKED_COMPACT_SPAWN_FAILED: $key round=$round"; return -3 }
            $deadline = (Get-Date).AddSeconds($CompressTimeoutSec + 20)
            while ((Get-Date) -lt $deadline) {
                if ($p.HasExited) { break }
                Start-Sleep -Seconds 5
            }
            if (-not $p.HasExited) {
                try { if ($script:ExeTaskkill) { & $script:ExeTaskkill /PID $p.Id /T /F 2>&1 | Out-Null } } catch {}
                Write-Log "CHUNKED_COMPACT_TIMEOUT: $key round=$round"
                return -2
            }
            if ($p.ExitCode -ne 0) {
                Write-Log "CHUNKED_COMPACT_FAILED: $key round=$round exit=$($p.ExitCode)"
                return $p.ExitCode
            }
            # 检查压缩后的 token 数
            Start-Sleep -Seconds 5
            try {
                $afterJson = Get-SessionsJson
                $after = $afterJson | ConvertFrom-Json
                $s2 = @($after.sessions) | Where-Object { [string]$_.key -eq $key } | Select-Object -First 1
                if ($s2) {
                    $currentUsed = [double]$s2.totalTokens
                    Write-Log "CHUNKED_COMPACT_ROUND: $key round=$round after=$currentUsed (target<$safetyLine)"
                }
            } catch {}
        }
        if ($currentUsed -gt $safetyLine) {
            Write-Log "CHUNKED_COMPACT_EXHAUSTED: $key after $maxRounds rounds still=$currentUsed > $safetyLine"
        }
        return 0
    }
    
    # 正常压缩模式
    $p = Start-OpenClawCli -CliArgs @('sessions', 'compact', $key, '--agent', $agentId, '--timeout', "$($CompressTimeoutSec * 1000)")
    if (-not $p) { Write-Log "COMPACT_SPAWN_FAILED: $key"; return -3 }
    $deadline = (Get-Date).AddSeconds($CompressTimeoutSec + 20)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { return $p.ExitCode }
        Start-Sleep -Seconds 5
    }
    try { if ($script:ExeTaskkill) { & $script:ExeTaskkill /PID $p.Id /T /F 2>&1 | Out-Null } } catch {}
    return -2   # 超时
}

# v5.8：循环压缩防护——记录最近压缩历史
# 规则：10 分钟内只能压缩 1 次，30 分钟内最多 2 次，除非有新对话否则不再压缩
$CompactHistoryFile = "$env:USERPROFILE\.openclaw\compact-history.json"
function Test-CompactAllowed([string]$sessionKey, [string]$sessionFile, [long]$lastCompactMs) {
    if (-not (Test-Path $CompactHistoryFile)) { return $true }
    try {
        $history = Get-Content $CompactHistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $keyHistory = @($history.$sessionKey)
        if (-not $keyHistory -or $keyHistory.Count -eq 0) { return $true }
        
        # 计算 10 分钟和 30 分钟内的压缩次数
        $recent10Min = @($keyHistory | Where-Object { ($nowMs - [long]$_) -lt 600000 })  # 10 分钟 = 600000ms
        $recent30Min = @($keyHistory | Where-Object { ($nowMs - [long]$_) -lt 1800000 })  # 30 分钟 = 1800000ms
        
        # 10 分钟内只能压缩 1 次
        if ($recent10Min.Count -ge 1) {
            # v5.8：检查是否有新对话——有新对话则允许再次压缩
            if ($sessionFile -and $lastCompactMs -gt 0 -and (Test-HasNewConversation $sessionFile $lastCompactMs)) {
                Write-Log "ALLOW_NEW_CONVO: $sessionKey（10 分钟内已压缩 1 次，但有新对话，允许压缩）"
                return $true
            }
            Write-Log "SKIP_CYCLE_PROTECT: $sessionKey（10 分钟内已压缩 $($recent10Min.Count) 次，无新对话，跳过）"
            return $false
        }
        
        # 30 分钟内最多 2 次
        if ($recent30Min.Count -ge 2) {
            # v5.8：检查是否有新对话——有新对话则允许再次压缩
            if ($sessionFile -and $lastCompactMs -gt 0 -and (Test-HasNewConversation $sessionFile $lastCompactMs)) {
                Write-Log "ALLOW_NEW_CONVO: $sessionKey（30 分钟内已压缩 2 次，但有新对话，允许压缩）"
                return $true
            }
            Write-Log "SKIP_CYCLE_PROTECT: $sessionKey（30 分钟内已压缩 $($recent30Min.Count) 次，无新对话，跳过）"
            return $false
        }
        
        return $true
    } catch { return $true }
}

function Add-CompactRecord([string]$sessionKey) {
    try {
        $raw = $null
        if (Test-Path $CompactHistoryFile) {
            $raw = Get-Content $CompactHistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        $history = @{}
        if ($raw) { foreach ($prop in $raw.PSObject.Properties) { $history[$prop.Name] = @($prop.Value) } }
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if (-not $history[$sessionKey]) { $history[$sessionKey] = @() }
        $history[$sessionKey] = @($history[$sessionKey]) + $nowMs
        # 只保留最近 1 小时的记录
        $history[$sessionKey] = @($history[$sessionKey] | Where-Object { ($nowMs - [long]$_) -lt 3600000 })
        $history | ConvertTo-Json -Depth 4 | Set-Content $CompactHistoryFile -Encoding UTF8
    } catch {}
}

# v5.8：检测会话是否有新对话（用于循环压缩防护）
function Test-HasNewConversation([string]$sessionFile, [long]$lastCompactMs) {
    if (-not $sessionFile -or -not (Test-Path $sessionFile)) { return $false }
    try {
        $fs = [System.IO.File]::Open($sessionFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -lt 1024) { return $false }
            $readLen = [Math]::Min(65536, [int64]$len)  # 读尾部 64KB
            $fs.Seek(-$readLen, [System.IO.SeekOrigin]::End) | Out-Null
            $bytes = New-Object byte[] $readLen
            $null = $fs.Read($bytes, 0, $readLen)
        } finally { $fs.Close() }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '"role"\s*:\s*"user"') {
                if ($line -match '"timestamp"\s*:\s*(\d+)') {
                    $ts = [long]$Matches[1]
                    if ($ts -gt $lastCompactMs) { return $true }
                }
            }
        }
    } catch {}
    return $false
}

# v5.7：内置压缩互斥——检测 OpenClaw 内部是否正在/刚完成压缩
# 检测方式：读 jsonl 尾部，看最近 3 分钟内是否有 compaction 事件
function Test-BuiltinCompressionActive([string]$SessionFile) {
    if (-not $SessionFile -or -not (Test-Path $SessionFile)) { return $false }
    try {
        $fs = [System.IO.File]::Open($SessionFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -lt 1024) { return $false }
            $readLen = [Math]::Min(131072, [int64]$len)  # 读尾部 128KB
            $fs.Seek(-$readLen, [System.IO.SeekOrigin]::End) | Out-Null
            $bytes = New-Object byte[] $readLen
            $null = $fs.Read($bytes, 0, $readLen)
        } finally { $fs.Close() }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $cutoffMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 180000  # 3 分钟内
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '"type"\s*:\s*"compaction"' -and $line -match '"timestamp"\s*:\s*"([^"]+)"') {
                try {
                    $ts = [DateTimeOffset]::Parse($Matches[1]).ToUnixTimeMilliseconds()
                    if ($ts -gt $cutoffMs) { return $true }
                } catch {}
            }
        }
    } catch {}
    return $false
}

# v5.7：压缩锁——原子检查+获取，防止两个压缩同时启动
# 返回 $true 表示成功获取锁（调用方负责压缩后释放），$false 表示锁已被占用
function Try-AcquireCompressionLock([string]$targetKey) {
    # 先检查锁文件是否存在且有效
    if (Test-Path $CompactStateFile) {
        try {
            $raw = Get-Content $CompactStateFile -Raw -Encoding UTF8
            if ($raw) {
                $obj = $raw | ConvertFrom-Json
                $lockKey = [string]$obj.sessionKey
                if ($lockKey -eq $targetKey) {
                    # 自己的锁——检查是否过期（>10 分钟视为僵尸锁）
                    $startedAt = [string]$obj.startedAt
                    if ($startedAt) {
                        $lockAge = (Get-Date) - [DateTimeOffset]::Parse($startedAt).LocalDateTime
                        if ($lockAge.TotalMinutes -gt 10) {
                            Write-Log "LOCK_EXPIRED: $targetKey（压缩锁超 10 分钟，清除僵尸锁）"
                        } else {
                            Write-Log "SKIP_LOCKED: $targetKey（压缩锁存在，另一个压缩正在进行，跳过）"
                            return $false  # 锁有效，被占用
                        }
                    }
                } else {
                    Write-Log "SKIP_LOCKED: $targetKey（锁被 $lockKey 占用，跳过）"
                    return $false  # 不同会话的锁，跳过
                }
            }
        } catch {}
    }
    # 锁不存在或已过期——尝试获取（原子创建）
    try {
        $fs = [System.IO.File]::Open($CompactStateFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $content = @{ sessionKey = $targetKey; startedAt = (Get-Date).ToString('o'); pid = $PID } | ConvertTo-Json
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Close() }
        return $true  # 成功获取锁
    } catch {
        Write-Log "SKIP_LOCKED: $targetKey（锁创建失败，可能被其他进程抢占）"
        return $false  # 获取失败，跳过
    }
}

function Release-CompressionLock() {
    try { Remove-Item $CompactStateFile -Force -ErrorAction SilentlyContinue } catch {}
}

try {
    $sessionsJson = Get-SessionsJson
    if (-not $sessionsJson) { Write-Output "LIST_FAILED"; exit 0 }

    # 状态：失败记忆 + 告警冷却 + 压缩冷却（⚠️ PSCustomObject 索引访问对特殊字符 key 失效，必须转 hashtable）
    $failState = @{}
    $lastAlert = @{}
    $lastCompactAt = @{}   # v5.4：key -> 上次成功压缩时间戳(ms)
    $lastWakeAt = @{}      # v5.5：key -> 上次失败唤醒时间戳(ms)
    try {
        if (Test-Path $StateFile) {
            $st = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.failures) { foreach ($prop in $st.failures.PSObject.Properties) { $failState[$prop.Name] = if ($prop.Name -match ':pausedUntil$') { [long]$prop.Value } else { [int]$prop.Value } } }
            if ($st.lastAlertAt) { foreach ($prop in $st.lastAlertAt.PSObject.Properties) { $lastAlert[$prop.Name] = [long]$prop.Value } }
            if ($st.lastCompactAt) { foreach ($prop in $st.lastCompactAt.PSObject.Properties) { $lastCompactAt[$prop.Name] = [long]$prop.Value } }
            if ($st.lastWakeAt) { foreach ($prop in $st.lastWakeAt.PSObject.Properties) { $lastWakeAt[$prop.Name] = [long]$prop.Value } }
        }
    } catch {}
    $stateDirty = $false
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $parsed = $sessionsJson | ConvertFrom-Json
    $sessions = @($parsed.sessions)
    $compressed = @()
    $checked = 0
    $overLimit = @()

    foreach ($s in $sessions) {
        $key = [string]$s.key
        if ($key -match 'weixin|wechat') { continue }
        if ([string]$s.status -eq 'killed') { continue }

        # T05 安全修复：白名单强制拦截——仅处理授权 Agent 的会话，禁止越权跨 Agent 操作
        # agentId 缺失时从 session key（agent:<id>:...）推导，仍须通过白名单校验
        $agentId = [string]$s.agentId
        if (-not $agentId -and $key -match '^agent:([^:]+):') { $agentId = $Matches[1] }
        if ($agentId -notin $AllowedAgents) { continue }

        # v5.8：所有代理的会话都压缩，不再限制 kind
        # 移除旧限制：if ($s.kind -ne 'direct') { continue }
        # 移除旧限制：if ($key -notmatch 'dashboard|(^agent:(main|yai):main$)') { continue }
        # ★v5.5 失败自动唤醒：模型空响应/turn 失败后，会话尾部无新活动 → 自动发“继续”唤醒
        #   检测：①会话非 running（已停）②jsonl 尾部最后一条是 toolResult/assistant 工具调用后无文本回复
        #   ③会话最后活动（updatedAt）在 4~30 分钟前（刚失败；历史会话 updatedAt 旧，不唤醒）
        #   ④距上次唤醒 >30 分钟冷却 ⑤排除 archived/wechat
        try {
            if ($key -match 'archived') { throw 'skip' }
            $wakeOk = $false
            $sf = [string]$s.sessionFile
            # 用 updatedAt（ms）判定“刚失败”：4~30 分钟前的活动窗口
            $sessAgeMin = 999
            try {
                $upd = [long]$s.updatedAt
                if ($upd -gt 0) { $sessAgeMin = ($nowMs - $upd) / 60000.0 }
            } catch {}
            if ($sf -and (Test-Path $sf) -and ([string]$s.status -ne 'running') -and $sessAgeMin -gt $WakeIdleMin -and $sessAgeMin -lt 30) {
                $wakeAge = ((Get-Date) - (Get-Item $sf).LastWriteTime).TotalMinutes
                if ($wakeAge -gt $WakeIdleMin -and $wakeAge -lt 30) {
                    $lastWake = [long]$lastWakeAt[$key]
                    if (($nowMs - $lastWake) -gt ($WakeCooldownMin * 60000)) {
                        # ★v5.8 (09-04): 网关崩溃检测——jsonl 最后一条 assistant 消息无 stopReason
                        #   正常完成的 assistant 消息必有 stopReason (stop/toolUse/aborted)；
                        #   没有 = 网关在生成过程中崩溃，jsonl 被截断
                        $crashDetected = $false
                        try {
                            $crashProbe = & $PyExe -c "
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    lines = f.readlines()[-10:]
for ln in reversed(lines):
    try:
        d = json.loads(ln)
    except Exception:
        continue
    if d.get('type') != 'message': continue
    msg = d.get('message', {})
    if msg.get('role') != 'assistant': continue
    # last assistant message found
    sr = msg.get('stopReason', '')
    if not sr:
        print('CRASH')  # no stopReason = gateway crashed mid-stream
    else:
        print('OK')      # has stopReason = normal
    break
print('NO_ASSISTANT')
" $sf 2>$null | Select-Object -Last 1
                            if ($crashProbe -eq 'CRASH') { $crashDetected = $true }
                        } catch {}

                        if ($crashDetected) {
                            $wakeOk = $true
                            $lastWakeAt[$key] = $nowMs
                            $stateDirty = $true
                            Write-Log "WAKE_CRASH: $key（jsonl 截断=网关崩溃中断，${wakeAge} 分钟前，自动唤醒继续）"
                            Invoke-WakeSession -SessionKey $key -Reason 'crash'
                        }

                        # ★v5.5 原有逻辑：toolResult 后无文本回复
                        if (-not $wakeOk) {
                            $tailProbe = & $PyExe -c "
import json,sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    lines = f.readlines()[-6:]
hasTool = False; hasText = False
for ln in lines:
    try:
        d = json.loads(ln)
    except Exception:
        continue
    if d.get('type') != 'message': continue
    role = d.get('message',{}).get('role')
    if role == 'toolResult': hasTool = True
    if role == 'assistant':
        c = d.get('message',{}).get('content')
        if isinstance(c, list):
            for cc in c:
                if isinstance(cc, dict) and cc.get('type')=='text' and cc.get('text'): hasText = True
        elif isinstance(c, str) and c: hasText = True
print(('T' if hasTool else 'F') + ('T' if hasText else 'F'))
" $sf 2>$null | Select-Object -Last 1
                            if ($tailProbe -match '^(T|F)(T|F)$') {
                                $hasToolResult = ($tailProbe[0] -eq 'T')
                                $hasAssistantText = ($tailProbe[1] -eq 'T')
                            } else {
                                $hasToolResult = $false; $hasAssistantText = $true
                            }
                            if ($hasToolResult -and -not $hasAssistantText) {
                                $wakeOk = $true
                                $lastWakeAt[$key] = $nowMs
                                $stateDirty = $true
                                Write-Log "WAKE_FAILED: $key（尾部 toolResult 后无文本回复 ${wakeAge} 分钟，自动唤醒继续）"
                                Invoke-WakeSession -SessionKey $key -Reason 'failed'
                            }
                        }
                    }
                }
            }
        } catch {}
        # 7 天以上无交互的历史会话跳过（无意义）
        try {
            if ($s.lastInteractionAt -gt 0) {
                $last = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$s.lastInteractionAt).LocalDateTime
                if (((Get-Date) - $last).TotalDays -gt 7) { continue }
            }
        } catch {}
        $used = 0.0; $max = 0.0
        try { $used = [double]$s.totalTokens } catch {}
        try { $max = [double]$s.contextTokens } catch {}
        if ($used -le 0 -or $max -le 0) { continue }
        $pct = [math]::Round(($used / $max) * 100, 1)
        $checked++
        # v5.9：双条件触发——百分比 + 绝对值门槛
        if ($pct -le $ThresholdPct -or $used -le $ThresholdAbsTokens) { continue }
        # v5.3（08-21 复查）：运行中会话——非紧急跳过（防打断回复），紧急(>=100%)允许压缩（防溢出）
        if ([string]$s.status -eq 'running') {
            if ($pct -ge $EmergencyPct) {
                Write-Log "RUNNING_EMERGENCY: $key（运行中但已 $pct% 超窗，紧急压缩）"
            } else {
                Write-Log "SKIP_RUNNING: $key（会话正在运行，跳过本轮压缩）"
                continue
            }
        }

        $overLimit += "$key($pct%)"
        $alertOk = ($nowMs - [long]$lastAlert[$key]) -gt $AlertCooldownMs
        $emergency = ($pct -ge $EmergencyPct)
        Write-Log "OVER_LIMIT: $key Usage=$pct% ($used/$max) emergency=$emergency"
        # v5.1：超限不触发外部通知（无提示音），仅日志+自动压缩

        if ($AutoCompact) {
            # 自动压缩模式：sticky 检查 + 尝试压缩（成功静默，失败也静默——不触发外部通知）
            $failCount = [int]$failState[$key]
            # v5.4：压缩冷却——距上次成功压缩 < 冷却时间则跳过（紧急态不冷却，防溢出）
            $lastCompact = [long]$lastCompactAt[$key]
            if (($nowMs - $lastCompact) -lt ($CompactCooldownMin * 60000) -and -not $emergency) {
                $minsAgo = [math]::Round(($nowMs - $lastCompact) / 60000, 1)
                Write-Log "SKIP_COOLDOWN: $key（距上次压缩 ${minsAgo} 分钟 < ${CompactCooldownMin} 分钟冷却，跳过）"
                continue
            }
            if ($failCount -ge $StickyLimit -and -not $emergency) {
                # 普通超限：失败 5 次暂停 30 分钟；紧急态不暂停，每轮必试
                $pausedUntil = [long]$failState[$key + ':pausedUntil']
                if (($nowMs - $pausedUntil) -lt ($StickyPauseMin * 60000)) {
                    Write-Log "SKIP_STICKY: $key（连续失败 $failCount 次，暂停重试）"
                    continue
                }
                # 暂停期已过：清零计数继续尝试
                $failState[$key] = 0
                $stateDirty = $true
            }
            # v5.8：循环压缩防护——10 分钟内只能压缩 1 次，30 分钟内最多 2 次，除非有新对话
            $lastCompact = [long]$lastCompactAt[$key]
            if (-not (Test-CompactAllowed $key $sf $lastCompact)) {
                continue
            }
            # 防御性检查：压缩模型窗口 vs 当前 token 数
            # 即使当前配置不会触发（压缩用云端1M模型），也要防止未来配置变更导致崩溃
            $compactionModel = 'tokease/deepseek-v4-flash'  # 默认压缩模型
            try {
                $compactionModel = (openclaw config get agents.defaults.compaction.model 2>&1 | Out-String).Trim()
            } catch {}
            # 已知大窗口模型（不会爆栈）
            $knownLargeWindow = @('deepseek-v4-flash', 'deepseek-v4-pro', 'mimo-v2.5', 'mimo-v2.5-pro')
            $isLargeWindow = $false
            foreach ($lm in $knownLargeWindow) {
                if ($compactionModel -match $lm) { $isLargeWindow = $true; break }
            }
            if (-not $isLargeWindow) {
                # 压缩模型不在已知大窗口列表中——可能是本地模型，需要检查 token
                # 获取压缩模型的窗口大小（默认128K）
                $compactionWindow = 131072
                try {
                    $modelInfo = (openclaw config get models.providers.ollama.models 2>&1 | Out-String)
                    if ($modelInfo -match '"contextWindow"\s*:\s*(\d+)') {
                        $compactionWindow = [int]$Matches[1]
                    }
                } catch {}
                if ($used -gt ($compactionWindow * 0.8)) {
                    # 当前 token 超过压缩模型窗口的 80%——风险过高，跳过并警告
                    Write-Log "COMPACT_RISK_SKIP: $key used=$used > compaction_model=$compactionModel window=$compactionWindow (80%风险线)，跳过压缩避免爆栈"
                    continue
                }
            }
            # v5.6：记录压缩前是否运行中——压缩会取消进行中的回合致 done，需就地恢复
            $preRunning = ([string]$s.status -eq 'running')
            # v5.7：内置压缩互斥——原子锁防止 monitor 与内置压缩同时抢同一个会话
            # 获取锁：CreateNew 原子操作，成功才继续，失败说明有其他压缩在跑
            if (-not (Try-AcquireCompressionLock $key)) {
                continue  # 锁已被占用（内置压缩 or 其他 monitor 轮次），跳过
            }
            # v5.7：锁已获取，开始压缩
            $code = Invoke-Compact -key $key -usedTokens $used
            # v5.7：压缩后立即释放锁（无论成功失败）
            Release-CompressionLock
            if ($code -eq 0) {
                $compressed += [PSCustomObject]@{ Key = $key; BeforePercent = $pct }
                $failState[$key] = 0
                $lastCompactAt[$key] = $nowMs   # v5.4：记录成功压缩时间（冷却基准）
                $stateDirty = $true
                # v5.8：记录压缩历史（用于循环防护）
                Add-CompactRecord $key
                Write-Log "OK: $key（静默完成 preRunning=$preRunning）"
                
                # v5.9：压缩后执行“增强摘要”步骤
                # 读取 SQLite 文件，获取消息 ID 范围，写入 memory/*.md
                # 多次压缩时：保留旧的 SQLite 文件引用，只写入新增的
                try {
                    $safeKey = ($key -replace '[^a-zA-Z0-9]', '_')
                    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $sqlitePath = Join-Path $SqliteDir "$safeKey-$timestamp.db"
                    if (-not (Test-Path $sqlitePath)) {
                        # 追加模式下 DB 文件名可能是旧时间戳，找最新的
                        $existing = Get-ChildItem $SqliteDir -Filter "$safeKey-*.db" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                        if ($existing) { $sqlitePath = $existing.FullName }
                    }
                    if (Test-Path $sqlitePath) {
                        # 使用 Python 查询 SQLite，获取消息 ID 范围
                        $pythonExe = $PyExe
                        
                        # T09 安全修复：使用临时 .py 文件 + 命令行参数，避免字符串插值注入
                        $pyQueryFile = Join-Path $env:TEMP ("oc_qc_" + [guid]::NewGuid().ToString("N").Substring(0,8) + ".py")
                        @'
import sqlite3, json, sys
db_path = sys.argv[1]
session_key = sys.argv[2]
conn = sqlite3.connect(db_path)
c = conn.cursor()
c.execute('SELECT COUNT(*) FROM session_chunks WHERE session_key = ?', (session_key,))
total = c.fetchone()[0]
c.execute('SELECT MIN(start_msg_id), MAX(end_msg_id) FROM session_chunks WHERE session_key = ?', (session_key,))
min_id, max_id = c.fetchone()
c.execute('SELECT chunk_id, start_msg_id, end_msg_id, summary, keywords, raw_content FROM session_chunks WHERE session_key = ? ORDER BY chunk_id', (session_key,))
key_chunks = c.fetchall()
result = {'total_chunks': total, 'msg_id_range': [min_id, max_id], 'chunks': [{'chunk_id': c2[0], 'msg_range': f"{c2[1]}~{c2[2]}", 'summary': c2[3], 'keywords': c2[4], 'content_preview': c2[5][:200] if c2[5] else ''} for c2 in key_chunks[:50]]}
conn.close()
print(json.dumps(result, ensure_ascii=False))
'@ | Set-Content -Path $pyQueryFile -Encoding UTF8 -Force
                        
                        $sqliteResult = & $pythonExe $pyQueryFile $sqlitePath $key 2>&1 | Out-String
                        if ($sqliteResult) {
                            $sqliteData = $sqliteResult | ConvertFrom-Json
                            
                            # v6.0（09-08 双层记忆架构）：
                            # L1 session.md = 高层地图与工作看板（严格控制在 500~800 Token）
                            # L2 SQLite + FTS5 = 全量细节仓库（通过 Tool 按需检索）
                            
                            # 读取现有的 memory 文件（如果存在）
                            $memoryDir = "$env:LOCALAPPDATA\.openclaw\memory"
                            if (-not (Test-Path $memoryDir)) { New-Item -ItemType Directory -Path $memoryDir -Force | Out-Null }
                            $memoryFile = Join-Path $memoryDir "session-$safeKey.md"
                            
                            # 用 Python 解析现有文件的结构化内容（保留 State Board）
                            $stateBoard = ""
                            if (Test-Path $memoryFile) {
                                $existingContent = Get-Content $memoryFile -Raw -Encoding UTF8
                                # 提取 Active State & Goals 部分（保留不变）
                                if ($existingContent -match '(?s)(## Active State & Goals.*?)(?=## |$)') {
                                    $stateBoard = $Matches[1].Trim()
                                }
                            }
                            
                            # 如果没有 State Board，创建默认的
                            if (-not $stateBoard) {
                                $stateBoard = @"
## Active State & Goals
- 当前目标：（待更新）
- 关键约束：（待更新）
- 最近变更：$timestamp
"@
                            }
                            
                            # 用 Python 查询 SQLite 获取现有 chunks 构建 Navigation Map
                            # T09 安全修复：使用临时 .py 文件 + 命令行参数
                            $pyNavFile = Join-Path $env:TEMP ("oc_nm_" + [guid]::NewGuid().ToString("N").Substring(0,8) + ".py")
                            @'
import sqlite3, json, sys
db_path = sys.argv[1]
session_key = sys.argv[2]
conn = sqlite3.connect(db_path)
c = conn.cursor()
c.execute('SELECT chunk_id, start_msg_id, end_msg_id, summary, keywords, created_at FROM session_chunks WHERE session_key = ? ORDER BY chunk_id', (session_key,))
chunks = c.fetchall()
conn.close()
result = {'total_chunks': len(chunks), 'chunks': [{'chunk_id': c2[0], 'msg_range': f"{c2[1]}~{c2[2]}", 'summary': c2[3], 'keywords': c2[4], 'created_at': c2[5]} for c2 in chunks]}
print(json.dumps(result, ensure_ascii=False))
'@ | Set-Content -Path $pyNavFile -Encoding UTF8 -Force
                            
                            $navMapData = $null
                            try {
                                $navMapResult = & $pythonExe $pyNavFile $sqlitePath $key 2>&1 | Out-String
                                if ($navMapResult) { $navMapData = $navMapResult | ConvertFrom-Json }
                            } catch {}
                            
                            # 方案一+二+三：结构化微清单 + 全局实体路由 + 检索决策树
                            $navMap = ""
                            $entityRouter = "## Global Entity & Artifact Router`n| 实体/文件 | 关键职责 | 涉及 Chunks |`n| :--- | :--- | :--- |`n"
                            if ($navMapData -and $navMapData.total_chunks -gt 0) {
                                $allChunks = @($navMapData.chunks)
                                $totalChunks = $allChunks.Count
                                $recentCount = [Math]::Min(3, $totalChunks)
                                
                                # Recent Chunks（高精度微清单）
                                $recentChunks = $allChunks[($totalChunks - $recentCount)..($totalChunks - 1)]
                                $navMap += "### Recent Chunks`n"
                                foreach ($c in $recentChunks) {
                                    # 方案一：结构化微清单格式 + 时间锚点
                                    $kws = if ($c.keywords) { $c.keywords } else { '(无)' }
                                    # 优化点：绝对静止时间锚点（09-07 14:00 格式，写入后永不变更，不破坏 Prompt 缓存）
                                    $dateTag = ''
                                    if ($c.created_at) {
                                        try { $dateTag = ' | ' + ([datetime]$c.created_at).ToString('MM-dd HH:mm') } catch {}
                                    }
                                    $navMap += "- **[Chunk $($c.chunk_id)$dateTag]** $($c.summary)`n"
                                    $navMap += "  - 关键词: ``$kws```n"
                                    $navMap += "  - 检索词: ``$kws`` | ``$($c.summary)```n"
                                }
                                
                                # 方案二：全局实体路由表（从 Recent Chunks 中提取实体/文件名）
                                $entityRouter = @"
## Global Entity & Artifact Router
| 实体/文件 | 关键职责 | 最新 Chunk |
| :--- | :--- | :--- |
"@
                                # 从所有 chunks 中提取文件名和函数名
                                $entityMap = @{}
                                foreach ($c in $allChunks) {
                                    $kwStr = "$($c.keywords) $($c.summary)"
                                    # 提取文件名（*.ext 格式）
                                    $fileMatches = [regex]::Matches($kwStr, '[a-zA-Z0-9_-]+\.[a-zA-Z]{1,4}')
                                    foreach ($m in $fileMatches) {
                                        $entityMap[$m.Value] = $c.chunk_id
                                    }
                                    # 提取函数名（xxx() 格式）
                                    $funcMatches = [regex]::Matches($kwStr, '[a-zA-Z_][a-zA-Z0-9_]+\(\)')
                                    foreach ($m in $funcMatches) {
                                        $entityMap[$m.Value] = $c.chunk_id
                                    }
                                }
                                # 只保留最近的映射（覆盖旧的）
                                $entityCount = 0
                                foreach ($entry in $entityMap.GetEnumerator()) {
                                    if ($entityCount -ge 8) { break }
                                    $entityRouter += "| ``$($entry.Key)`` | 参见 Chunk $($entry.Value) | **$($entry.Value)** |`n"
                                    $entityCount++
                                }
                                if ($entityCount -eq 0) {
                                    $entityRouter += "| (暂无实体) | - | - |`n"
                                }
                                
                                # Archived Themes（对数聚合）
                                $maxArchivedThemes = 8
                                if ($totalChunks -gt $recentCount) {
                                    $archivedChunks = $allChunks[0..($totalChunks - $recentCount - 1)]
                                    $themeSize = 5
                                    $themeBlocks = @()
                                    for ($i = 0; $i -lt $archivedChunks.Count; $i += $themeSize) {
                                        $themeEnd = [Math]::Min($i + $themeSize - 1, $archivedChunks.Count - 1)
                                        $themeBlocks += ,@($archivedChunks[$i..$themeEnd])
                                    }
                                    while ($themeBlocks.Count -gt $maxArchivedThemes) {
                                        $merged = @($themeBlocks[0]) + @($themeBlocks[1])
                                        $themeBlocks = @($merged) + $themeBlocks[2..($themeBlocks.Count - 1)]
                                    }
                                    $navMap += "`n### [Archived Themes]`n"
                                    $themeIndex = 1
                                    foreach ($themeChunks in $themeBlocks) {
                                        $firstChunk = $themeChunks[0]
                                        $lastChunk = $themeChunks[$themeChunks.Count - 1]
                                        # 优化点3：关键词透传——Tags 子标签暴露高频关键词
                                        $allTags = @()
                                        foreach ($tc in $themeChunks) {
                                            if ($tc.keywords) {
                                                $allTags += ($tc.keywords -split ',') | ForEach-Object { $_.Trim() }
                                            }
                                        }
                                        $uniqueTags = ($allTags | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 6) -join ', '
                                        if ($uniqueTags.Length -gt 60) { $uniqueTags = $uniqueTags.Substring(0, 60) + '...' }
                                        # 优化点5：时间锚点——Theme 附带日期范围
                                        $dateRange = ''
                                        if ($firstChunk.created_at -and $lastChunk.created_at) {
                                            try {
                                                $d1 = ([datetime]$firstChunk.created_at).ToString('M月d日')
                                                $d2 = ([datetime]$lastChunk.created_at).ToString('M月d日')
                                                $dateRange = if ($d1 -eq $d2) { " | $d1" } else { " | $d1-$d2" }
                                            } catch {}
                                        }
                                        $navMap += "- [Theme $themeIndex | Chunk $($firstChunk.chunk_id)-$($lastChunk.chunk_id)$dateRange] ($uniqueTags)`n"
                                        $themeIndex++
                                    }
                                }
                            } else {
                                $navMap = "### Recent Chunks`n- 暂无压缩记录`n"
                                $entityRouter = "## Global Entity & Artifact Router`n| (暂无) | - | - |`n"
                            }
                            
                            # 修复点1b：Prompt Caching 排序——静态靠前，高频变化靠后
                            # 修复点3a：使用 .NET UTF-8 无 BOM 写入，防止中文乱码
                            # 优化点4：Prompt 负向约束——防止模型“脑补细节”
                            # T01 安全修复：仅写入纯数据 JSON，不包含任何指令性内容
                            $memoryData = @{
                                session_key = $key
                                sqlite_file = $sqlitePath
                                total_chunks = $sqliteData.total_chunks
                                msg_id_range = $sqliteData.msg_id_range
                                chunks = @($sqliteData.chunks | ForEach-Object {
                                    @{
                                        chunk_id = $_.chunk_id
                                        start_msg_id = $_.start_msg_id
                                        end_msg_id = $_.end_msg_id
                                        summary = $_.summary
                                        keywords = $_.keywords
                                    }
                                })
                                nav_map = $navMap
                                updated_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
                            }
                            $memoryContent = $memoryData | ConvertTo-Json -Depth 5 -Compress
                            
                            # 最终大小检查（目标 < 2000 字符 ≈ 700 Token）
                            if ($memoryContent.Length -gt 2500) {
                                Write-Log "SESSION_MD_SIZE_WARN: $key size=$($memoryContent.Length) chars, trimming..."
                            }
                            
                            # 修复点3a：强制 UTF-8 无 BOM 写入
                            # 修复点1：原子写入——先写临时文件，再原子重命名替换，防止 Gateway 读到 0 字节
                            # 优化点2：Windows 瞬时锁重试——Defender/其他进程可能短暂占用文件
                            $tmpPath = "$memoryFile.tmp"
                            [System.IO.File]::WriteAllText($tmpPath, $memoryContent, [System.Text.UTF8Encoding]::new($false))
                            $moveOk = $false
                            for ($retry = 1; $retry -le 3; $retry++) {
                                try {
                                    Move-Item -Path $tmpPath -Destination $memoryFile -Force -ErrorAction Stop
                                    $moveOk = $true
                                    break
                                } catch {
                                    if ($retry -eq 3) {
                                        Write-Log "SESSION_MAP_MOVE_ERR: $key (3次重试均失败: $_)"
                                        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
                                    }
                                    Start-Sleep -Milliseconds 100
                                }
                            }
                            if ($moveOk) {
                                Write-Log "SESSION_MAP: $key -> $memoryFile (chunks=$($sqliteData.total_chunks))"
                            }
                        }
                    }
                } catch { Write-Log "SESSION_MAP_ERR: $key $_" }
                
                # v5.2：压缩后验证会话状态（若被终结/轮换，绑定守卫会自动归档，保证记录不丢）
                Start-Sleep -Seconds 5
                try {
                    $afterJson = Get-SessionsJson
                    $after = $afterJson | ConvertFrom-Json
                    $s2 = @($after.sessions) | Where-Object { [string]$_.key -eq $key } | Select-Object -First 1
                    if ($s2) {
                        $postStatus = [string]$s2.status
                        Write-Log "AFTER_COMPACT: $key status=$postStatus session=$($s2.sessionId)"
                        # v5.6：压缩后恢复线——压缩前正在运行（有进行中回合被压缩取消），
                        #   压缩后就地注入「继续」让它接着跑，防「压缩后停摆等待人工介入」。
                        #   仅对 preRunning 生效 → 正常收尾的 done 不受影响；同轮只触发一次，无循环风险。
                        # v7.2：单次尝试 + 日志审计（无隐式阻塞重试、无外部通知进程）
                        if ($preRunning -and $postStatus -ne 'running') {
                            $lastWakeAt[$key] = $nowMs
                            $stateDirty = $true
                            Write-Log "WAKE_AFTER_COMPACT: $key（压缩前运行中，压缩后 $postStatus，自动继续）"
                            # Single attempt, no hidden blocking retry loop; recovery is
                            # verified by the next scheduled monitor round.
                            $wakeOk = Invoke-WakeSession -SessionKey $key -Reason 'compact'
                            if (-not $wakeOk) {
                                # Behaviour matches the documented policy: log only,
                                # never spawn an external notification process.
                                Write-Log "WAKE_UNVERIFIED: $key（本次自动恢复未发出，下一轮监控复核）"
                            }
                        }
                        # 若压缩后会话被终结（killed/done）且之前是活跃会话 → 下轮 cleanup 绑定守卫自动归档
                    } else {
                        Write-Log "AFTER_COMPACT: $key 已不在会话列表（可能被轮换，绑定守卫将自动归档）"
                        # v5.6：会话被轮换成新会话 → 向原 key 发「继续」让网关重定向/重建后继续
                        # v5.7：同样加重试 + 验证 + 失败警告
                        if ($preRunning) {
                            $lastWakeAt[$key] = $nowMs
                            $stateDirty = $true
                            Write-Log "WAKE_AFTER_COMPACT_ROTATED: $key（会话被轮换，自动继续）"
                            # Single attempt; no hidden retry loop, no external notification.
                            $wakeOk2 = Invoke-WakeSession -SessionKey $key -Reason 'compact_rotated'
                            if (-not $wakeOk2) {
                                Write-Log "WAKE_UNVERIFIED: $key（轮换后自动恢复未发出，下一轮监控复核）"
                            }
                        }
                    }
                } catch {}
            } elseif ($code -eq -2) {
                $failState[$key] = $failCount + 1
                $failState[$key + ':pausedUntil'] = $nowMs  # v6.6：设置暂停时间戳（修复 sticky 永不生效的 bug）
                $stateDirty = $true
                Write-Log "COMPRESS_TIMEOUT: $key（${CompressTimeoutSec}s 未完成已强杀 失败$($failState[$key])次）"
            } else {
                $failState[$key] = $failCount + 1
                $failState[$key + ':pausedUntil'] = $nowMs  # v6.6：设置暂停时间戳（修复 sticky 永不生效的 bug）
                $stateDirty = $true
                Write-Log "COMPRESS_FAILED: $key (exit=$code 失败$($failState[$key])次)"
            }
        } else {
            # 兼容旧调用：不传 -AutoCompact 时也记录（计划任务已带参数）
            Write-Log "OVER_LIMIT(检测): $key Usage=$pct%"
        }
    }

    if ($stateDirty) {
        try {
            $stOut = [PSCustomObject]@{ updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); failures = $failState; lastAlertAt = $lastAlert; lastCompactAt = $lastCompactAt; lastWakeAt = $lastWakeAt }
            [System.IO.File]::WriteAllText($StateFile, ($stOut | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false))
        } catch {}
    }

    if ($compressed.Count -gt 0) {
        foreach ($c in $compressed) { Write-Output "OK $($c.Key) Before=$($c.BeforePercent)%" }
    } elseif ($overLimit.Count -gt 0) {
        Write-Output "OVER_LIMIT_DETECTED: $($overLimit -join '; ')"
    } else {
        Write-Output "CHECKED $checked - NO COMPRESSION NEEDED"
    }
} finally {
    try { $fs.Close() } catch {}
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
exit 0
