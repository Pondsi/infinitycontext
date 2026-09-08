# session-to-sqlite.ps1 - PowerShell 包装器，调用 session_to_sqlite.py
# 避免 PS5.1 here-string GBK 编码问题

param(
    [Parameter(Mandatory=$true)]
    [string]$SessionKey,
    [Parameter(Mandatory=$true)]
    [string]$SessionFile,
    [string]$OutputDir = "$env:USERPROFILE\.openclaw\压缩会话临时文件",
    [switch]$AppendMode
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$pythonExe = "C:\Python313\python.exe"
if (-not (Test-Path $pythonExe)) { $pythonExe = "python" }

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
