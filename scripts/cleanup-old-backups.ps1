# cleanup-old-backups.ps1 - 清理旧备份文件（安全审计修复）
# 保留最近 30 天的备份，删除更旧的

param(
    [int]$RetentionDays = 30,
    [string]$BackupDir = "$env:LOCALAPPDATA\.openclaw\backups"
)

if (-not (Test-Path $BackupDir)) { exit 0 }

$cutoff = (Get-Date).AddDays(-$RetentionDays)
$deleted = 0

Get-ChildItem $BackupDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.LastWriteTime -lt $cutoff
} | ForEach-Object {
    try {
        Remove-Item $_.FullName -Force
        $deleted++
    } catch {}
}

Write-Output "Cleanup: deleted $deleted old backups (retention: $RetentionDays days)"
