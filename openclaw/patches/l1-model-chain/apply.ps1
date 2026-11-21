# apply.ps1 - memory-tencentdb L1/L2/L3 模型降级链补丁：应用 / 体检 / 还原
#
#   .\apply.ps1            # 应用补丁（幂等；已应用的步骤自动跳过）
#   .\apply.ps1 -Check     # 只体检，不修改
#   .\apply.ps1 -Restore   # 从最近备份还原
#
# 打完补丁后需要重启网关才生效（ESM 模块在进程内缓存）。

param(
    [switch]$Check,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# B4/T07: python 解析器采用可信根目录扫描（与 cleanup-old-backups.ps1 一致），不依赖 PATH
$ov = $env:INFINITY_CONTEXT_PYTHON
if ($ov -and (Test-Path -LiteralPath $ov) -and ([System.IO.Path]::GetFileName($ov) -ieq 'python.exe')) {
    $py = (Resolve-Path -LiteralPath $ov).Path
} else {
    $py = $null
    foreach ($pat in @("$env:ProgramFiles\Python3*\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", 'C:\Python3*\python.exe')) {
        $hit = Get-ChildItem -Path $pat -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $py = $hit.FullName; break }
    }
}
if (-not $py) { throw "未找到 python.exe；用 INFINITY_CONTEXT_PYTHON 环境变量指定绝对路径" }

$script = Join-Path $PSScriptRoot "patch_l1_model_chain.py"
if (-not (Test-Path $script)) { throw "缺少 patch_l1_model_chain.py（应与本脚本同目录）" }

$extra = @()
if ($Check)   { $extra += "--check" }
if ($Restore) { $extra += "--restore" }

& $py $script @extra
exit $LASTEXITCODE
