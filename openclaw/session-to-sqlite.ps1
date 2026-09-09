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
    # 1.8.8: no PATH lookup and no execution probe (T07). A PATH hit can be the
    # zero-byte Microsoft Store app-alias stub, which pops a window when run.
    # Candidates come only from explicit trusted roots or INFINITY_CONTEXT_PYTHON.
    if ($env:INFINITY_CONTEXT_PYTHON) {
        $ov = $env:INFINITY_CONTEXT_PYTHON
        if ([System.IO.Path]::IsPathRooted($ov) -and
            (Test-Path -LiteralPath $ov -PathType Leaf) -and
            ([System.IO.Path]::GetFileName($ov) -ieq 'python.exe')) {
            return $ov
        }
        Write-Warning "INFINITY_CONTEXT_PYTHON is not an absolute python.exe path, ignored: $ov"
    }
    $roots = @(
        "$env:ProgramFiles\Python3*",
        "${env:ProgramFiles(x86)}\Python3*",
        "$env:LOCALAPPDATA\Programs\Python\Python3*",
        'C:\Python3*'
    )
    # 1.8.8: match the FILE, not the directory. -Path 'C:\Python3*' -Filter 'python.exe'
    # returns nothing because the wildcard matches the directory itself; join the
    # file name into the pattern instead.
    foreach ($root in $roots) {
        $hit = Get-ChildItem -Path (Join-Path $root 'python.exe') -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit -and (Test-Path -LiteralPath $hit.FullName -PathType Leaf)) { return $hit.FullName }
    }
    return $null
}
$PyExe = Get-PythonExe
# =================================================================


$pythonExe = $PyExe

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# T07/重构修复：按候选位置解析引擎（脚本同目录 / 仓库 scripts / 安装目录），绝不搜索 PATH
$pyCandidates = @(
    (Join-Path $scriptDir 'session_to_sqlite.py'),
    (Join-Path $scriptDir '..\scripts\session_to_sqlite.py'),
    (Join-Path $env:USERPROFILE '.openclaw\scripts\session_to_sqlite.py')
)
$pyScript = $null
foreach ($c in $pyCandidates) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $pyScript = (Resolve-Path -LiteralPath $c).Path; break }
}
if (-not $pyScript) { Write-Error 'ENGINE_NOT_FOUND: session_to_sqlite.py'; exit 1 }

$argsList = @($pyScript, '--session-key', $SessionKey, '--session-file', $SessionFile, '--output-dir', $OutputDir)
if ($AppendMode) { $argsList += '--append' }

$result = & $pythonExe @argsList 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Output ($result | Out-String)
} else {
    Write-Error "SQLite conversion failed: $result"
}
