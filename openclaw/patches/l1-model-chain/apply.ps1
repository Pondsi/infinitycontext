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

$py = "C:\Python313\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

$script = Join-Path $PSScriptRoot "patch_l1_model_chain.py"
if (-not (Test-Path $script)) { throw "缺少 patch_l1_model_chain.py（应与本脚本同目录）" }

$extra = @()
if ($Check)   { $extra += "--check" }
if ($Restore) { $extra += "--restore" }

& $py $script @extra
exit $LASTEXITCODE
