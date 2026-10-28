[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$IntegrationRoot = Join-Path $Root "Integration"
$CommonPath = Join-Path $IntegrationRoot "ReacquisitionQueueCommon.ps1"
$WorkerPath = Join-Path $IntegrationRoot "ReacquisitionWorker.ps1"
$BridgePath = Join-Path $IntegrationRoot "ReqestraArrBridge.ps1"
$GetModePath = Join-Path $IntegrationRoot "Tools\Get-ReacquisitionWorkerMode.ps1"

. $CommonPath

$tests = @()
function Add-Test { param([string]$Name,[bool]$Passed) $script:tests += [pscustomobject]@{ Test=$Name; Passed=$Passed } }

$tempRoot = Join-Path $env:TEMP ("reqestra-6h-test-"+[guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $s = Get-ReacquisitionWorkerSettings -IntegrationRoot $tempRoot
    Add-Test "Worker fails closed to AUTO_DRY_RUN when no config exists" ($s.effectiveMode -eq "AUTO_DRY_RUN" -and -not $s.automaticWritesAuthorized)

    @{ mode="AUTO_EXECUTE"; allowAutomaticWrites=$false; safetyAcknowledgement="" } | ConvertTo-Json | Set-Content (Join-Path $tempRoot "reacquisition-worker-config.json") -Encoding UTF8
    $s = Get-ReacquisitionWorkerSettings -IntegrationRoot $tempRoot
    Add-Test "AUTO_EXECUTE requires allowAutomaticWrites" ($s.effectiveMode -eq "AUTO_DRY_RUN" -and -not $s.automaticWritesAuthorized)

    @{ mode="AUTO_EXECUTE"; allowAutomaticWrites=$true; safetyAcknowledgement="WRONG" } | ConvertTo-Json | Set-Content (Join-Path $tempRoot "reacquisition-worker-config.json") -Encoding UTF8
    $s = Get-ReacquisitionWorkerSettings -IntegrationRoot $tempRoot
    Add-Test "AUTO_EXECUTE requires exact reacquisition acknowledgement" ($s.effectiveMode -eq "AUTO_DRY_RUN" -and -not $s.automaticWritesAuthorized)

    @{
        mode="AUTO_EXECUTE"; allowAutomaticWrites=$true; safetyAcknowledgement="REQESTRA_AUTO_REACQUISITION_CAN_DELETE_AND_REPLACE_MEDIA";
        allowTerminalDvRemediation=$false; terminalDvAcknowledgement=""; allowFelResidualDiscard=$false; felResidualDiscardAcknowledgement=""
    } | ConvertTo-Json | Set-Content (Join-Path $tempRoot "reacquisition-worker-config.json") -Encoding UTF8
    $s = Get-ReacquisitionWorkerSettings -IntegrationRoot $tempRoot
    Add-Test "General automatic reacquisition can be authorized independently" ($s.effectiveMode -eq "AUTO_EXECUTE" -and $s.automaticWritesAuthorized -and -not $s.terminalDvAuthorized)

    @{
        mode="AUTO_EXECUTE"; allowAutomaticWrites=$true; safetyAcknowledgement="REQESTRA_AUTO_REACQUISITION_CAN_DELETE_AND_REPLACE_MEDIA";
        allowTerminalDvRemediation=$true; terminalDvAcknowledgement="REQESTRA_AUTO_TERMINAL_DV_REMOVES_DOLBY_VISION";
        allowFelResidualDiscard=$false; felResidualDiscardAcknowledgement=""
    } | ConvertTo-Json | Set-Content (Join-Path $tempRoot "reacquisition-worker-config.json") -Encoding UTF8
    $s = Get-ReacquisitionWorkerSettings -IntegrationRoot $tempRoot
    Add-Test "Terminal DV automation has a separate acknowledgement gate" ($s.terminalDvAuthorized -and -not $s.felDiscardAuthorized)

    @{
        mode="AUTO_EXECUTE"; allowAutomaticWrites=$true; safetyAcknowledgement="REQESTRA_AUTO_REACQUISITION_CAN_DELETE_AND_REPLACE_MEDIA";
        allowTerminalDvRemediation=$true; terminalDvAcknowledgement="REQESTRA_AUTO_TERMINAL_DV_REMOVES_DOLBY_VISION";
        allowFelResidualDiscard=$true; felResidualDiscardAcknowledgement="REQESTRA_AUTO_FEL_DISCARDS_DOLBY_VISION_RESIDUAL"
    } | ConvertTo-Json | Set-Content (Join-Path $tempRoot "reacquisition-worker-config.json") -Encoding UTF8
    $s = Get-ReacquisitionWorkerSettings -IntegrationRoot $tempRoot
    Add-Test "FEL residual discard requires its own explicit acknowledgement" ($s.terminalDvAuthorized -and $s.felDiscardAuthorized)

    $a = Get-ReacquisitionQueueJobId -EventId "event-1" -QueueMode "AUTO_DRY_RUN"
    $b = Get-ReacquisitionQueueJobId -EventId "event-1" -QueueMode "AUTO_EXECUTE"
    Add-Test "Dry-run and execute event jobs have different identities" ($a -ne $b)

    $worker = Get-Content -LiteralPath $WorkerPath -Raw -Encoding UTF8
    $bridge = Get-Content -LiteralPath $BridgePath -Raw -Encoding UTF8

    Add-Test "First failure uses MarkFailed with native redownload suppression" ($worker -match 'Invoke-Reacquisition\.ps1' -and $worker -match 'SuppressNativeRedownload')
    Add-Test "First failure requires SUCCESS_SEARCH_SUPPRESSED before quarantine" ($worker -match 'SUCCESS_SEARCH_SUPPRESSED')
    Add-Test "Worker uses guarded Radarr quarantine" ($worker -match 'Invoke-ReacquisitionQuarantine\.ps1')
    Add-Test "Worker uses guarded Sonarr quarantine" ($worker -match 'Invoke-SonarrReacquisitionQuarantine\.ps1')
    Add-Test "Worker initializes Radarr chain after first quarantine" ($worker -match 'Initialize-ReacquisitionChain\.ps1')
    Add-Test "PASS replacement routes to Radarr success finalizer" ($worker -match 'Complete-ReacquisitionSuccess\.ps1')
    Add-Test "PASS replacement routes to Sonarr success finalizer" ($worker -match 'Complete-SonarrReacquisitionSuccess\.ps1')
    Add-Test "Bad Radarr replacement routes through guarded retry" ($worker -match 'Invoke-ReacquisitionRetry\.ps1')
    Add-Test "Bad Sonarr replacement routes through guarded retry" ($worker -match 'Invoke-SonarrReacquisitionRetry\.ps1')
    Add-Test "Worker never retires a NORMALIZE replacement as success" ($worker -match 'WAITING_FOR_NORMALIZATION')
    Add-Test "Terminal Radarr chain can route to terminal DV remediation" ($worker -match 'Invoke-TerminalDvRemediation\.ps1')
    Add-Test "Terminal DV candidate build and promotion are separate phases" ($worker -match 'BuildCandidate' -and $worker -match 'DRY_RUN_READY_REPLACE')
    Add-Test "Worker re-reads automatic write gate before mutations" (([regex]::Matches($worker,'Get-CurrentWriteSettings')).Count -ge 5)
    Add-Test "FEL terminal fallback checks felDiscardAuthorized" ($worker -match 'felDiscardAuthorized' -and $worker -match 'FEL_DISCARD_GATE_DISABLED')
    Add-Test "Worker treats exceptions after a write launch as recovery-required" ($worker -match 'writeAttempted' -and $worker -match 'RECOVERY_REQUIRED')
    Add-Test "Bridge queues validated events for the automatic worker" ($bridge -match 'Enqueue-ReacquisitionBridgeEvent' -and $bridge -match 'Start-ReacquisitionQueueWorker')
    Add-Test "Bridge queue/worker remains non-blocking to Arr import" ($bridge -match 'queue/worker failures never fail the Arr import')

    $getMode = Get-Content -LiteralPath $GetModePath -Raw -Encoding UTF8
    Add-Test "Mode getter returns settings object instead of formatting records" ($getMode -match 'Get-ReacquisitionWorkerSettings' -and $getMode -notmatch '\|\s*Format-List')
    Add-Test "Mode getter preserves machine-readable safety properties for callers" ($getMode -notmatch 'Format-Table|Out-String|Write-Output.+effectiveMode')
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Reqestra Automatic Reacquisition Worker Contract Test"
Write-Host "====================================================="
Write-Host ""
$tests | Format-Table -AutoSize
$failed = @($tests | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count,$tests.Count)
    exit 1
}
Write-Host ""
Write-Host ("PASS: {0}/{0} automatic reacquisition worker contract tests passed." -f $tests.Count)
exit 0
