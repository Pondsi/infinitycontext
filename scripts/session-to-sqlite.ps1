# session-to-sqlite.ps1 - PowerShell 包装器，调用 session_to_sqlite.py
# 避免 PS5.1 here-string GBK 编码问题

param(
    [Parameter(Mandatory=$true)]
    [string]$SessionKey,
    [Parameter(Mandatory=$true)]
    [string]$SessionFile,
    [string]$OutputDir = "$env:USERPROFILE\.openclaw\sqlite-data",
    [switch]$AppendMode
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
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
            $t = & $c -c "print(1)" 2>$null
            if ("$t" -match '1') { return $c }
        }
    }
    return $null
}
$PyExe = Get-PythonExe
# =================================================================


$pythonExe = $PyExe

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pyScript = Join-Path $scriptDir "session_to_sqlite.py"

$argsList = @($pyScript, '--session-key', $SessionKey, '--session-file', $SessionFile, '--output-dir', $OutputDir)
if ($AppendMode) { $argsList += '--append' }

$result = & $pythonExe @argsList 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Output ($result | Out-String)
} else {
    Write-Error "SQLite conversion failed: $result"
}
