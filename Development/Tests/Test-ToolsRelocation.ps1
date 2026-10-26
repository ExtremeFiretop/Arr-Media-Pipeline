[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ToolsRoot = Join-Path $ProjectRoot "Integration\Tools"

if (-not (Test-Path -LiteralPath $ToolsRoot -PathType Container)) {
    throw "Tools directory not found: $ToolsRoot"
}

$tests = @()
function Add-Test { param([string]$Name,[bool]$Passed) $script:tests += [pscustomobject]@{ Test=$Name; Passed=$Passed } }

$files = @(Get-ChildItem -LiteralPath $ToolsRoot -Filter "*.ps1" -File)
$combined = ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"

Add-Test "Tools no longer use PSScriptRoot directly as IntegrationRoot" ($combined -notmatch '(?im)^\s*\$IntegrationRoot\s*=\s*\$PSScriptRoot\s*$')
Add-Test "Tools do not dot-source ReacquisitionQueueCommon from Tools directory" ($combined -notmatch 'Join-Path\s+\$PSScriptRoot\s+["'']ReacquisitionQueueCommon\.ps1')
Add-Test "Tools do not dot-source QueueCommon from Tools directory" ($combined -notmatch 'Join-Path\s+\$PSScriptRoot\s+["'']QueueCommon\.ps1')
Add-Test "Worker mode tools write configs in Integration rather than Tools" ($combined -notmatch 'Join-Path\s+\$PSScriptRoot\s+["''](?:normalization|reacquisition)-worker-config\.json')
Add-Test "Moved tools derive Integration as parent of Tools" (($combined -match 'Split-Path -Parent \$ToolsRoot') -or ($combined -match 'Split-Path -Parent \$PSScriptRoot'))

Write-Host ""
Write-Host "Integration Tools Relocation Contract Test"
Write-Host "=========================================="
Write-Host ""
$tests | Format-Table -AutoSize
$failed = @($tests | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count,$tests.Count)
    exit 1
}
Write-Host ""
Write-Host ("PASS: {0}/{0} tools relocation tests passed." -f $tests.Count)
exit 0
