# update-integrity.ps1 - regenerate the integrity manifest for the compaction-pipeline hook.
#
# handler.js refuses to execute pipeline.ps1 unless its SHA-256 matches integrity.json.
# Run this after ANY edit to pipeline.ps1, then reinstall/copy the manifest next to the hook.
#
# Usage (from the repository root):
#   powershell -NoProfile -File scripts\update-integrity.ps1 `
#       -PipelineScript scripts\pipeline.ps1 -ManifestPath src\integrity.json
#
# Usage (installed hook directory):
#   powershell -NoProfile -File update-integrity.ps1
param(
    [string]$PipelineScript = (Join-Path $PSScriptRoot 'pipeline.ps1'),
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'integrity.json')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PipelineScript)) {
    Write-Error "pipeline script not found: $PipelineScript"
    exit 1
}

$hash = (Get-FileHash -LiteralPath $PipelineScript -Algorithm SHA256).Hash.ToLower()
$manifest = [ordered]@{ 'pipeline.ps1' = "sha256:$hash" }
$json = ($manifest | ConvertTo-Json -Depth 4) + "`n"

$dir = Split-Path -Parent $ManifestPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllText($ManifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Output "INTEGRITY WRITTEN: $ManifestPath"
Write-Output "  pipeline.ps1 -> sha256:$hash"
