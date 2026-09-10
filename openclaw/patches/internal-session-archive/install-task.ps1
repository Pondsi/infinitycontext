# install-task.ps1 - 注册/更新「内部会话静默化」计划任务
#
#   .\install-task.ps1           # 注册（幂等，已存在则覆盖）
#   .\install-task.ps1 -Remove   # 移除任务
#
# ⚠️ 本文件含中文，必须存为 UTF-8 with BOM（PS 5.1 否则按 GBK 解码致乱码/语法错误）。

param([switch]$Remove)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$TaskName = "OpenClaw-InternalSessionArchive"

# 自动定位 RunHidden.vbs 和 python
$Vbs = "$env:USERPROFILE\.openclaw\workspace\scripts\RunHidden.vbs"
$PyCandidates = @("C:\Python313\python.exe")
$cmd = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if ($cmd) { $PyCandidates += $cmd }
$Py = $PyCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$Script = Join-Path $PSScriptRoot "archive-internal-sessions.py"

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "已移除计划任务: $TaskName"
    exit 0
}

foreach ($f in @($Vbs, $Py, $Script)) {
    if (-not (Test-Path $f)) { throw "缺失: $f" }
}

$arg = '//nologo "' + $Vbs + '" "' + $Py + '" "' + $Script + '" --loop 55 --interval 5'
$action   = New-ScheduledTaskAction -Execute "wscript.exe" -Argument $arg
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 1000)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "归档插件内部工作会话（memory-*）中已完成的条目；失败条目保持可见。" -Force | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName
Write-Host "已注册: $TaskName   State=$($t.State)"
Write-Host "  重复间隔: $($t.Triggers[0].Repetition.Interval)"
Write-Host "  命令    : $arg"
