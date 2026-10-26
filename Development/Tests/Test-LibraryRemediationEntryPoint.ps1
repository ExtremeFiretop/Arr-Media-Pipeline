[CmdletBinding()]
param([string]$ReleaseRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$integration=Join-Path $ReleaseRoot "Integration"
$tool=Join-Path $integration "Tools\Invoke-LibraryRemediation.ps1"
$bridge=Join-Path $integration "ReqestraArrBridge.ps1"
$legacy=Join-Path $integration "Invoke-RadarrRemediationSweep.ps1"

$toolText=if(Test-Path -LiteralPath $tool){Get-Content -LiteralPath $tool -Raw -Encoding UTF8}else{""}
$bridgeText=if(Test-Path -LiteralPath $bridge){Get-Content -LiteralPath $bridge -Raw -Encoding UTF8}else{""}

$checks=@(
    [pscustomobject]@{Test="Unified library remediation tool exists";Passed=(Test-Path -LiteralPath $tool -PathType Leaf)},
    [pscustomobject]@{Test="Movies TV Both selector";Passed=$toolText.Contains('[ValidateSet("Movies","TV","Both")]')},
    [pscustomobject]@{Test="Radarr feeds same bridge";Passed=$toolText.Contains('Invoke-BridgeSubmission -Source "Radarr"')},
    [pscustomobject]@{Test="Sonarr feeds same bridge";Passed=$toolText.Contains('Invoke-BridgeSubmission -Source "Sonarr"')},
    [pscustomobject]@{Test="Resume checkpoint exists";Passed=$toolText.Contains('checkpoint.jsonl')},
    [pscustomobject]@{Test="Fresh override exists";Passed=$toolText.Contains('[switch]$Fresh')},
    [pscustomobject]@{Test="Workers kicked during long sweep";Passed=$toolText.Contains('$WorkerKickInterval = 250')},
    [pscustomobject]@{Test="Workers drained after sweep";Passed=$toolText.Contains('$lastWorkerStart = Start-RemediationWorkers')},
    [pscustomobject]@{Test="Profile cache prevents per-file profile API churn";Passed=$toolText.Contains('Get-ProfileCache')},
    [pscustomobject]@{Test="Bridge accepts cached profile override";Passed=$bridgeText.Contains('$ProfileOverride = $null')},
    [pscustomobject]@{Test="Bridge remains callable in-process";Passed=(-not $bridgeText.Contains('exit 0'))},
    [pscustomobject]@{Test="Legacy Radarr-only sweep removed";Passed=(-not (Test-Path -LiteralPath $legacy))}
)

$checks | Format-Table -AutoSize
$failed=@($checks | Where-Object {-not $_.Passed})
if($failed.Count){throw "$($failed.Count) library remediation entry-point check(s) failed."}
Write-Host "PASS: $($checks.Count)/$($checks.Count) library remediation entry-point checks passed." -ForegroundColor Green
