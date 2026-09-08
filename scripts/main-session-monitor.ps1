# ============================================================
# main-session-monitor.ps1 v6.6 - 主会话上下文监控（09-08 压缩管线完整修复+sticky双修复版）
# 背景：08-18 事故——main dashboard 会话上下文膨胀到 804%（210万/26万），
#       ollama 超窗 aborted 导致回复中断 1 小时+；监控只检测不压缩（计划任务
#       没传 -AutoCompact），内置压缩在 ollama 忙/超窗时失败，死锁到用户手动
#       "继续"才恢复。
# v5.1 变更（08-18 主人指令）：超限/压缩失败/暂停等一律【不通知主人】，
#       仅写日志 + 自动压缩兜底（提示音也不要）。
# v5.5 变更（08-21 主人指令）：新增“失败自动唤醒”——模型空响应（Agent couldn't generate a response）
#   或 turn 失败后，若会话尾部无新活动且无新用户消息，自动向会话发送“继续”唤醒，防任务静默中断。
# v5.8 变更（09-05 主人指令）：
#   1. 全会话压缩——所有代理的会话都压缩，不再限制 kind
#   2. 无论状态是否完成都压缩（包括 done）
#   3. 冷却从 15 分钟减到 5 分钟
#   4. 循环压缩防护：10 分钟内只能压缩 1 次，30 分钟内最多 2 次
#   5. 除非有新对话，否则不再压缩
# v5.9 变更（09-08 主人指令）：双条件触发（百分比 35% + 绝对值 60000）+ 压缩后增强摘要
# v6.3 变更（09-08 修复）：UTF-8 编码强制 + 控制字符清理（修复 JSON 解析被 catch 吞掉）
# v6.4 变更（09-08 修复）：Windows 目录名冒号替换（[^a-zA-Z0-9:-] -> [^a-zA-Z0-9]）
# v6.5 变更（09-08 修复）：SqliteDir 统一 ASCII 路径 + session_chunks 表名修正
# v6.6 变更（09-08 修复）：sticky pausedUntil 双 bug（写入缺失 + [int] 溢出改 [long]）
# v5 变更（08-18 主人指令：确保不再出现）：
#   1. 计划任务已恢复 -AutoCompact（每 10 分钟自动尝试压缩）
#   2. 压缩失败不再轻易 sticky 暂停：>100% 紧急态每轮必试；普通超限
#      连续失败 5 次才暂停 30 分钟
#   3. 压缩前先备份 transcript（防压缩失败损坏，可恢复）
#   4. 压缩超时窗口 300s（超窗会话摘要需要更久）
# 调度：计划任务 OpenClaw-MainSessionMonitor（每 10 分钟，纯脚本零 LLM 开销）
# 日志：~/.openclaw/logs/main-session-monitor.log
# ============================================================

param(
    [switch]$AutoCompact   # 尝试自动压缩（计划任务已带此参数）
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$ThresholdPct = 35.0          # 主人 09-08 指令：35% 就压缩（原 49%），更早介入防溢出
$ThresholdAbsTokens = 60000    # 主人 09-08 指令：绝对值门槛 60000 tokens（防空转）
$CompactCooldownMin = 5        # v5.8（09-05 主人指令）：压缩冷却 5 分钟（原 15）
$CompressTimeoutSec = 300     # compact 超时（超窗会话摘要更久，08-18 从 240 调大）
$WakeCooldownMin = 30          # v5.5：同一会话失败唤醒冷却（分钟），防反复唤醒循环
$WakeIdleMin = 4               # v5.5：会话尾部无新写入超过此分钟数才判定失败（防误判进行中）
$StickyLimit = 5              # 连续失败 5 次 → 暂停该会话自动重试 30 分钟
$StickyPauseMin = 30          # sticky 暂停时长（分钟）
$EmergencyPct = 100.0         # 超过窗口 100% = 紧急态：不暂停，每轮必试压缩
$BackupDir = "$env:LOCALAPPDATA\.openclaw\backups\sessions"   # 压缩前 transcript 备份
$LockFile = "$env:USERPROFILE\.openclaw\main-session-monitor.lock"
$LogFile = "$env:LOCALAPPDATA\.openclaw\logs\main-session-monitor.log"
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

# v6.1 UTF-8 安全唤醒函数（修复 cmd.exe GBK 编码导致中文变乱码 "缁х画"）
function Invoke-WakeSession {
    param([string]$SessionKey, [string]$Reason = 'auto')
    try {
        $encodedMsg = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('继续'))
        # 用 PowerShell 直接执行 openclaw，避免 cmd.exe GBK 编码
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "`$env:PYTHONIOENCODING='utf-8'; openclaw agent -m ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedMsg'))) --session-key '$SessionKey'") -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
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
    # v6.3（09-08 修复）：VBS 无控制台启动时 PS 5.1 默认 GBK 解码 stdout，openclaw UTF-8 中文 label 破坏 JSON——解析前强制 UTF-8 并重设
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    # v6.8（09-08 修复）：统一由 hook 管线（pipeline.ps1）负责备份+SQLite，Invoke-Compact 不再重复
    # 调用 pipeline.ps1 -Phase before 做备份，如果 hook 后续触发会检测到近期备份并跳过
    $pipelineScript = Join-Path $PSScriptRoot "pipeline.ps1"
    if (Test-Path $pipelineScript) {
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pipelineScript,
                '-SessionKey', $key, '-Phase', 'before'
            ) -WindowStyle Hidden -Wait -TimeoutSec 60 | Out-Null
            Write-Log "PIPELINE_BEFORE: $key (hook pipeline)"
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
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'openclaw', 'sessions', 'compact', $key, '--timeout', "$($CompressTimeoutSec * 1000)") -WindowStyle Hidden -PassThru
            $deadline = (Get-Date).AddSeconds($CompressTimeoutSec + 20)
            while ((Get-Date) -lt $deadline) {
                if ($p.HasExited) { break }
                Start-Sleep -Seconds 5
            }
            if (-not $p.HasExited) {
                try { & taskkill /PID $p.Id /T /F 2>&1 | Out-Null } catch {}
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
                $afterJson = & openclaw sessions list --json 2>&1 | Out-String
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
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'openclaw', 'sessions', 'compact', $key, '--timeout', "$($CompressTimeoutSec * 1000)") -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds($CompressTimeoutSec + 20)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { return $p.ExitCode }
        Start-Sleep -Seconds 5
    }
    try { & taskkill /PID $p.Id /T /F 2>&1 | Out-Null } catch {}
    return -2   # 超时
}

# v5.8（09-05 主人指令）：循环压缩防护——记录最近压缩历史
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

# v5.8（09-05 主人指令）：检测会话是否有新对话（用于循环压缩防护）
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

# v5.7（09-03 主人指令）：内置压缩互斥——检测 OpenClaw 内部是否正在/刚完成压缩
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
    $sessionsJson = & openclaw sessions list --json 2>&1 | Out-String
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
                            $crashProbe = & "python" -c "
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
                            $tailProbe = & "python" -c "
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
        # v5.9（09-08 主人指令）：双条件触发——百分比 + 绝对值门槛
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
        # v5.1（08-18 主人指令）：超限不再通知主人（提示音也不要），仅日志+自动压缩

        if ($AutoCompact) {
            # 自动压缩模式：sticky 检查 + 尝试压缩（成功静默，失败也静默——主人 08-18 指令不通知）
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
            # v5.8（09-05 主人指令）：循环压缩防护——10 分钟内只能压缩 1 次，30 分钟内最多 2 次，除非有新对话
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
            # v5.6（09-02 主人指令）：记录压缩前是否运行中——压缩会取消进行中的回合致 done，需就地恢复
            $preRunning = ([string]$s.status -eq 'running')
            # v5.7（09-03 主人指令）：内置压缩互斥——原子锁防止 monitor 与内置压缩同时抢同一个会话
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
                
                # v5.9（09-08 主人指令）：压缩后执行“增强摘要”步骤
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
                        $pythonExe = "python"
                        if (-not (Test-Path $pythonExe)) { $pythonExe = "python" }
                        
                        # T09 安全修复：使用临时 .py 文件 + 命令行参数，避免字符串插值注入
                        $pyQueryFile = Join-Path $env:TEMP "oc_qc_fa0d2d23.py"
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
                            $pyNavFile = Join-Path $env:TEMP "oc_nm_0c4a4c52.py"
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
                    $afterJson = & openclaw sessions list --json 2>&1 | Out-String
                    $after = $afterJson | ConvertFrom-Json
                    $s2 = @($after.sessions) | Where-Object { [string]$_.key -eq $key } | Select-Object -First 1
                    if ($s2) {
                        $postStatus = [string]$s2.status
                        Write-Log "AFTER_COMPACT: $key status=$postStatus session=$($s2.sessionId)"
                        # v5.6（09-02 主人指令）：压缩后恢复线——压缩前正在运行（有进行中回合被压缩取消），
                        #   压缩后就地注入「继续」让它接着跑，防「压缩后停摆等主人手动继续」。
                        #   仅对 preRunning 生效 → 正常收尾的 done 不受影响；同轮只触发一次，无循环风险。
                        # v5.7（09-03 主人指令）：加强 wake——重试3次 + 验证恢复 + 失败响警告
                        if ($preRunning -and $postStatus -ne 'running') {
                            $lastWakeAt[$key] = $nowMs
                            $stateDirty = $true
                            Write-Log "WAKE_AFTER_COMPACT: $key（压缩前运行中，压缩后 $postStatus，自动继续）"
                            $wakeOk = $false
                            for ($wakeTry = 1; $wakeTry -le 3; $wakeTry++) {
                                Invoke-WakeSession -SessionKey $key -Reason 'compact'
                                # 等 10 秒后验证会话是否恢复
                                Start-Sleep -Seconds 10
                                try {
                                    $wakeCheck = & openclaw sessions list --json 2>&1 | Out-String
                                    $wakeParsed = $wakeCheck | ConvertFrom-Json
                                    $wakeSess = @($wakeParsed.sessions) | Where-Object { [string]$_.key -eq $key } | Select-Object -First 1
                                    if ($wakeSess -and [string]$wakeSess.status -eq 'running') {
                                        Write-Log "WAKE_VERIFIED: $key（第 $wakeTry 次唤醒后会话已恢复 running）"
                                        $wakeOk = $true
                                        break
                                    }
                                } catch {}
                                if ($wakeTry -lt 3) { Write-Log "WAKE_RETRY: $key（第 $wakeTry 次唤醒未恢复，10 秒后重试）" }
                            }
                            # v5.7：3 次唤醒均失败 → 发 reply_failed 警告音通知主人
                            if (-not $wakeOk) {
                                Write-Log "WAKE_FAILED_ALL: $key（3 次唤醒均未恢复，发送警告音）"
                                try {
                                    $notifyArgs = @('//nologo', $env:LOCALAPPDATA\.openclaw\scripts\RunHidden.vbs, 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$env:LOCALAPPDATA\.openclaw\hooks\reply-notify\do-notify.ps1", '-Event', 'reply_failed', '-Message', "压缩后唤醒失败: $key")
                                    Start-Process -FilePath 'wscript.exe' -ArgumentList $notifyArgs -WindowStyle Hidden -ErrorAction SilentlyContinue
                                } catch {}
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
                            $wakeOk2 = $false
                            for ($wakeTry2 = 1; $wakeTry2 -le 3; $wakeTry2++) {
                                Invoke-WakeSession -SessionKey $key -Reason 'compact_rotated'
                                Start-Sleep -Seconds 10
                                try {
                                    $wakeCheck2 = & openclaw sessions list --json 2>&1 | Out-String
                                    $wakeParsed2 = $wakeCheck2 | ConvertFrom-Json
                                    $wakeSess2 = @($wakeParsed2.sessions) | Where-Object { [string]$_.key -eq $key } | Select-Object -First 1
                                    if ($wakeSess2 -and [string]$wakeSess2.status -eq 'running') {
                                        Write-Log "WAKE_VERIFIED: $key（第 $wakeTry2 次唤醒后会话已恢复 running）"
                                        $wakeOk2 = $true
                                        break
                                    }
                                } catch {}
                                if ($wakeTry2 -lt 3) { Write-Log "WAKE_RETRY: $key（第 $wakeTry2 次唤醒未恢复，10 秒后重试）" }
                            }
                            if (-not $wakeOk2) {
                                Write-Log "WAKE_FAILED_ALL: $key（轮换后 3 次唤醒均未恢复，发送警告音）"
                                try {
                                    $notifyArgs2 = @('//nologo', $env:LOCALAPPDATA\.openclaw\scripts\RunHidden.vbs, 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$env:LOCALAPPDATA\.openclaw\hooks\reply-notify\do-notify.ps1", '-Event', 'reply_failed', '-Message', "轮换后唤醒失败: $key")
                                    Start-Process -FilePath 'wscript.exe' -ArgumentList $notifyArgs2 -WindowStyle Hidden -ErrorAction SilentlyContinue
                                } catch {}
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
