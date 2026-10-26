[CmdletBinding()]
param([string]$ReleaseRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$integration=Join-Path $ReleaseRoot "Integration"
$checks=@(
    @{Name="Bridge auto escalation"; Path="ReqestraArrBridge.ps1"; Marker="AUTOMATIC_NORMALIZE_TO_REACQUIRE"},
    @{Name="Bridge active-chain normalization ownership"; Path="ReqestraArrBridge.ps1"; Marker="DEFERRED_TO_REACQUISITION_WORKER"},
    @{Name="Reacquisition planner escalation metadata"; Path="ReacquisitionPlanner.ps1"; Marker="NORMALIZATION_NOT_SAFELY_ACTIONABLE"},
    @{Name="Reacquisition executor accepts bound automatic escalation"; Path="Invoke-Reacquisition.ps1"; Marker="automatic_escalation_source_outcome_changed"},
    @{Name="Reacquisition worker normalizes replacement"; Path="ReacquisitionWorker.ps1"; Marker="Invoke-ActiveChainNormalization"},
    @{Name="Reacquisition worker post-normalization completion"; Path="ReacquisitionWorker.ps1"; Marker="success-after-normalization-execute"},
    @{Name="Unified existing-library remediation entry exists"; Path="Tools\Invoke-LibraryRemediation.ps1"; Marker="LibraryRemediation"},
    @{Name="Queue draining enabled"; Path="ReacquisitionWorker.ps1"; Marker='while ($MaxJobs -eq 0 -or $processed -lt $MaxJobs)'},
    @{Name="Normalization queue draining enabled"; Path="NormalizationWorker.ps1"; Marker='while ($MaxJobs -eq 0 -or $processed -lt $MaxJobs)'},
    @{Name="mkvpropedit fast path retained"; Path="Invoke-Normalization.ps1"; Marker="mkvpropedit"}
)
$results=@()
foreach($c in $checks){$p=Join-Path $integration $c.Path;$text=if(Test-Path $p){Get-Content $p -Raw -Encoding UTF8}else{""};$results+=[pscustomobject]@{Test=$c.Name;Passed=$text.Contains($c.Marker)}}
$results|Format-Table -AutoSize
$failed=@($results|Where-Object{-not $_.Passed})
if($failed.Count){throw "$($failed.Count) automatic remediation release check(s) failed."}
Write-Host "PASS: $($results.Count)/$($results.Count) automatic remediation release checks passed." -ForegroundColor Green
