[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "QueueCommon.ps1")

Write-Host ""
Write-Host "Reqestra Automatic Normalization Gate Self-Test"
Write-Host "================================================"
Write-Host ""

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ReqestraAutoGate-" + [guid]::NewGuid().ToString("N"))
$integration = Join-Path $tempRoot "Integration"
New-Item -ItemType Directory -Path $integration -Force | Out-Null
$configPath = Join-Path $integration "normalization-worker-config.json"

function Save-TestConfig {
    param($Object)
    $Object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

$tests = @()

$s = Get-NormalizationWorkerSettings -IntegrationRoot $integration
$tests += [pscustomobject]@{
    Test = "Missing config fails closed to dry run"
    Passed = ($s.effectiveMode -eq "AUTO_DRY_RUN" -and -not $s.automaticWritesAuthorized)
}

Save-TestConfig ([ordered]@{
    mode = "AUTO_DRY_RUN"
    allowAutomaticWrites = $false
    safetyAcknowledgement = $null
})
$s = Get-NormalizationWorkerSettings -IntegrationRoot $integration
$tests += [pscustomobject]@{
    Test = "Configured dry run remains dry run"
    Passed = ($s.effectiveMode -eq "AUTO_DRY_RUN" -and $s.configStatus -eq "CONFIGURED_DRY_RUN")
}

Save-TestConfig ([ordered]@{
    mode = "AUTO_EXECUTE"
    allowAutomaticWrites = $false
    safetyAcknowledgement = $script:AutomaticWriteAcknowledgement
})
$s = Get-NormalizationWorkerSettings -IntegrationRoot $integration
$tests += [pscustomobject]@{
    Test = "Execute mode without write permission fails closed"
    Passed = ($s.effectiveMode -eq "AUTO_DRY_RUN" -and -not $s.automaticWritesAuthorized)
}

Save-TestConfig ([ordered]@{
    mode = "AUTO_EXECUTE"
    allowAutomaticWrites = $true
    safetyAcknowledgement = "WRONG"
})
$s = Get-NormalizationWorkerSettings -IntegrationRoot $integration
$tests += [pscustomobject]@{
    Test = "Execute mode with bad acknowledgement fails closed"
    Passed = ($s.effectiveMode -eq "AUTO_DRY_RUN" -and -not $s.automaticWritesAuthorized)
}

Save-TestConfig ([ordered]@{
    mode = "AUTO_EXECUTE"
    allowAutomaticWrites = $true
    safetyAcknowledgement = $script:AutomaticWriteAcknowledgement
})
$s = Get-NormalizationWorkerSettings -IntegrationRoot $integration
$tests += [pscustomobject]@{
    Test = "All execute gates authorize writes"
    Passed = ($s.effectiveMode -eq "AUTO_EXECUTE" -and $s.automaticWritesAuthorized -and $s.configStatus -eq "AUTO_EXECUTE_AUTHORIZED")
}

$planPath = Join-Path $tempRoot "plan.json"
[pscustomobject][ordered]@{
    status = "PLANNED"
    mediaPath = "V:\TV Shows\Test\Test S01E01.mkv"
    sourceSnapshot = [ordered]@{
        lengthBytes = 1000
        lastWriteTimeUtc = "2026-10-25T00:00:00.0000000Z"
        streamFingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    plannedFindingCodes = @("audio.no_default")
    actions = @(
        [ordered]@{
            action = "set_audio_default_flag"
            audioOrdinal = 1
            ffprobeStreamIndex = 1
            language = "eng"
            commentary = $false
            from = $false
            to = $true
        }
    )
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding UTF8

$dryId = Get-NormalizationQueueJobId -PlanPath $planPath -QueueMode "AUTO_DRY_RUN"
$executeId = Get-NormalizationQueueJobId -PlanPath $planPath -QueueMode "AUTO_EXECUTE"
$tests += [pscustomobject]@{
    Test = "Dry-run and execute jobs have different identities"
    Passed = ($dryId -ne $executeId)
}

$tests | Format-Table -AutoSize -Wrap

$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} automatic normalization gate tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count, $tests.Count)
exit 1

trap {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    break
}
