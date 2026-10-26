[CmdletBinding()]
param([string]$ReleaseRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$bridgePath=Join-Path $ReleaseRoot "Integration\ReqestraArrBridge.ps1"
$plannerPath=Join-Path $ReleaseRoot "Integration\ReacquisitionPlanner.ps1"
$bridge=Get-Content -LiteralPath $bridgePath -Raw -Encoding UTF8
$planner=Get-Content -LiteralPath $plannerPath -Raw -Encoding UTF8

$checks=@(
    [pscustomobject]@{Test="Reacquisition launcher accepts escalation reason";Passed=($bridge -match 'function\s+Invoke-ReacquisitionPlannerProcess[\s\S]*?\[string\]\$AutomaticEscalationReason\s*=\s*""')},
    [pscustomobject]@{Test="Reacquisition launcher forwards escalation reason";Passed=($bridge -match '\$arguments\s*\+=\s*@\("-AutomaticEscalationReason",\s*\$AutomaticEscalationReason\)')},
    [pscustomobject]@{Test="Bridge calls reacquisition launcher with escalation reason";Passed=($bridge -match 'Invoke-ReacquisitionPlannerProcess[\s\S]*?-AutomaticEscalationReason\s+\$automaticEscalationReason')},
    [pscustomobject]@{Test="Reacquisition planner accepts escalation reason";Passed=($planner -match '\[string\]\$AutomaticEscalationReason\s*=\s*""')},
    [pscustomobject]@{Test="Reacquisition planner supports probe diagnostics";Passed=($planner -match '"probe\.diagnostic_error"')},
    [pscustomobject]@{Test="Bridge filters non-actionable reacquisition queue events";Passed=($bridge -match 'no_reacquisition_outcome_or_active_chain')}
)
$checks|Format-Table -AutoSize
$failed=@($checks|Where-Object{-not $_.Passed})
if($failed.Count){throw "$($failed.Count) reacquisition handoff regression check(s) failed."}
Write-Host "PASS: $($checks.Count)/$($checks.Count) reacquisition handoff regression checks passed." -ForegroundColor Green
