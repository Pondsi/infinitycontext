# cleanup-old-backups.ps1 - 清理过期备份文件（T09 安全硬化版）
#
# 安全设计（默认拒绝 / Deny by Default）：
#   1. $RetentionDays 强约束为 1..3650，拒绝 0 与负数（防越期误删）
#   2. $BackupDir 经 [System.IO.Path]::GetFullPath 规范化后，必须位于
#      %LOCALAPPDATA%\.openclaw\backups 之内，否则直接抛出安全异常退出
#      （防路径穿越、防 C:\Windows 等任意目录被递归清空）
#   3. 仅删除白名单扩展名的备份文件，禁止 *.* 全通配符递归删除
#   4. 跳过 ReparsePoint（符号链接 / Junction），防链接逃逸
#   5. 支持 -WhatIf / -Confirm（SupportsShouldProcess），便于审计与演练
#
# 用法：
#   powershell -NoProfile -File cleanup-old-backups.ps1
#   powershell -NoProfile -File cleanup-old-backups.ps1 -RetentionDays 7 -WhatIf

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    # 保留天数：必须是 1..3650 的正整数
    [ValidateRange(1, 3650)]
    [int]$RetentionDays = 30,

    # 备份根目录：默认固定为安全根目录，可指向其子目录
    [string]$BackupDir = "$env:LOCALAPPDATA\.openclaw\backups"
)

$ErrorActionPreference = 'Stop'

# ---------- 1. 路径规范化 + 越权校验（Canonical 锚定） ----------
$CanonicalRoot = [System.IO.Path]::GetFullPath("$env:LOCALAPPDATA\.openclaw\backups").TrimEnd('\', '/')

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    Write-Error 'SECURITY_VIOLATION: BackupDir 为空，操作已中止。'
    exit 1
}

try {
    $ResolvedTarget = [System.IO.Path]::GetFullPath($BackupDir).TrimEnd('\', '/')
} catch {
    Write-Error "SECURITY_VIOLATION: 无法解析目标路径 [$BackupDir]，操作已中止。"
    exit 1
}

# 必须是 CanonicalRoot 本身，或 CanonicalRoot 的绝对子目录
# 注意：必须补上目录分隔符再比较，否则 ...\backups-evil 会误通过前缀匹配
$IsRoot   = $ResolvedTarget.Equals($CanonicalRoot, [System.StringComparison]::OrdinalIgnoreCase)
$IsChild  = $ResolvedTarget.StartsWith($CanonicalRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)

if (-not ($IsRoot -or $IsChild)) {
    Write-Error "SECURITY_VIOLATION: 目标路径 [$ResolvedTarget] 超出法定备份目录范围 [$CanonicalRoot]，操作已中止！"
    exit 1
}

if (-not (Test-Path -LiteralPath $ResolvedTarget)) {
    Write-Output "清理完成，共安全清除 0 个过期备份文件（目标目录不存在：$ResolvedTarget）。"
    exit 0
}

# ---------- 2. 过期时间线 ----------
$cutoff  = (Get-Date).AddDays(-$RetentionDays)
$deleted = 0

# ---------- 3. 仅允许清理项目专属备份后缀 ----------
$AllowedExtensions = @('.jsonl', '.db', '.db-wal', '.db-shm', '.bak', '.tmp', '.json')

Get-ChildItem -LiteralPath $ResolvedTarget -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.LastWriteTime -lt $cutoff -and
        $AllowedExtensions -contains $_.Extension.ToLowerInvariant() -and
        -not ($_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))
    } |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, "删除超过 $RetentionDays 天的历史备份文件")) {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                $deleted++
            } catch {
                Write-Warning "无法删除文件: $($_.FullName) - $_"
            }
        }
    }

# ---------- 4. SQLite 空间回收（VACUUM，避免长期会话 DB 只膨胀不缩小）----------
$VacuumMinMB = 10

function Get-PythonExe {
    $cands = New-Object System.Collections.ArrayList
    foreach ($n in @('python3','python','py')) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and $cmd.Source -notmatch 'WindowsApps') { [void]$cands.Add($cmd.Source) }
    }
    foreach ($pat in @("$env:ProgramFiles\Python3*\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", 'C:\Python3*\python.exe')) {
        Get-ChildItem $pat -ErrorAction SilentlyContinue | ForEach-Object { [void]$cands.Add($_.FullName) }
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) {
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
$vacuumed = 0
if ($PyExe) {
    $pyVacuum = @'
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    c.execute('PRAGMA busy_timeout=5000')
    c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    c.execute('VACUUM')
    c.close()
    print('OK')
except Exception as e:
    print('ERR:' + str(e))
'@
    $pyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ic-vacuum-" + [guid]::NewGuid().ToString('N') + ".py")
    Set-Content -LiteralPath $pyFile -Value $pyVacuum -Encoding UTF8
    try {
        Get-ChildItem -LiteralPath $ResolvedTarget -Recurse -File -Filter *.db -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt ($VacuumMinMB * 1MB) -and -not ($_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) } |
            ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, "VACUUM 回收 SQLite 磁盘碎片")) {
                    $r = & $PyExe $pyFile $_.FullName 2>&1 | Out-String
                    if ($r -match 'OK') { $vacuumed++ } else { Write-Warning "VACUUM 失败: $($_.Name) $($r.Trim())" }
                }
            }
    } finally {
        Remove-Item -LiteralPath $pyFile -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Warning 'VACUUM 跳过：未找到可用的 Python 解释器'
}

Write-Output "清理完成，共安全清除 $deleted 个过期备份文件（保留期：$RetentionDays 天，范围：$ResolvedTarget），VACUUM 整理 $vacuumed 个 SQLite 数据库。"
