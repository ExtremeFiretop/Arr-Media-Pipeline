[CmdletBinding()]
param([string]$ReleaseRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$validator=Get-Content -LiteralPath (Join-Path $ReleaseRoot "MediaValidator.ps1") -Raw -Encoding UTF8
$planner=Get-Content -LiteralPath (Join-Path $ReleaseRoot "Integration\ReacquisitionPlanner.ps1") -Raw -Encoding UTF8
$checks=@(
    [pscustomobject]@{Test="ffprobe is restricted to error diagnostics";Passed=($validator -match '"-v",\s*"error"')},
    [pscustomobject]@{Test="probe.diagnostic_error is REACQUIRE";Passed=($validator -match 'New-Finding\s+-Severity\s+"REACQUIRE"\s+-Code\s+"probe\.diagnostic_error"')},
    [pscustomobject]@{Test="reacquisition planner accepts probe diagnostic trigger";Passed=($planner -match '"probe\.diagnostic_error"')}
)
$checks|Format-Table -AutoSize
$failed=@($checks|Where-Object{-not $_.Passed})
if($failed.Count){throw "$($failed.Count) probe diagnostic reacquisition check(s) failed."}
Write-Host "PASS: $($checks.Count)/$($checks.Count) probe diagnostic reacquisition checks passed." -ForegroundColor Green
