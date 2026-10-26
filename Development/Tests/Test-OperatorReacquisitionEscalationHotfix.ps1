[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$IntegrationRoot = $PSScriptRoot
$PlannerPath = Join-Path $IntegrationRoot "ReacquisitionPlanner.ps1"
$ExecutorPath = Join-Path $IntegrationRoot "Invoke-Reacquisition.ps1"
$HelperPath = Join-Path $IntegrationRoot "New-OperatorReacquisitionPlan.ps1"

$tests = @()
function Add-Test {
    param([string]$Name, [bool]$Passed)
    $script:tests += [pscustomobject]@{ Test = $Name; Passed = $Passed }
}

Write-Host "Operator Reacquisition Escalation Hotfix Test"
Write-Host "=============================================="
Write-Host ""

foreach ($path in @($PlannerPath, $ExecutorPath, $HelperPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file missing: $path"
    }
}

$plannerText = Get-Content -LiteralPath $PlannerPath -Raw -Encoding UTF8
$executorText = Get-Content -LiteralPath $ExecutorPath -Raw -Encoding UTF8
$helperText = Get-Content -LiteralPath $HelperPath -Raw -Encoding UTF8

Add-Test "Planner version is 0.1.2" ($plannerText -match '\$PlannerVersion\s*=\s*"0\.1\.2"')
Add-Test "Executor version is 0.2.7" ($executorText -match '\$ExecutorVersion\s*=\s*"0\.2\.7"')
Add-Test "Planner exposes explicit operator escalation switch" ($plannerText -match 'OperatorEscalateNormalizeToReacquire')
Add-Test "Planner requires a disposition reason" ($plannerText -match 'operator_disposition_reason_required')
Add-Test "Plan records detected and effective outcomes separately" (($plannerText -match 'detectedEffectiveOutcome') -and ($plannerText -match 'operatorDisposition'))
Add-Test "Plan authorization key is source-snapshot bound" (($plannerText -match 'streamFingerprint') -and ($plannerText -match 'authorizationKey'))
Add-Test "Executor recalculates authorization key" ($executorText -match 'Get-OperatorDispositionAuthorizationKey')
Add-Test "Executor requires NORMALIZE to remain current" ($executorText -match 'current_media_no_longer_matches_operator_normalize_disposition')
Add-Test "Executor requires planned normalization findings to remain" ($executorText -match 'operator_normalize_finding_no_longer_present')
Add-Test "Execute requires second operator authorization key" (($executorText -match 'ConfirmOperatorAuthorizationKey') -and ($executorText -match 'execute_operator_authorization_confirmation_required'))
Add-Test "Existing loop-key execution gate remains" ($executorText -match 'execute_loop_key_confirmation_required')
Add-Test "Helper builds live Radarr context/history" (($helperText -match '/api/v3/history/movie') -and ($helperText -match '/api/v3/moviefile/'))
Add-Test "Helper refuses anything except current NORMALIZE" ($helperText -match 'current validator outcome is.*not NORMALIZE')

$tempRoot = Join-Path $env:TEMP ("operator-reacq-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $mediaPath = Join-Path $tempRoot "fixture.mkv"
    [System.IO.File]::WriteAllBytes($mediaPath, [byte[]](1,2,3,4,5,6,7,8))

    $contextPath = Join-Path $tempRoot "context.json"
    $validatorPath = Join-Path $tempRoot "validator.json"
    $normalPlanPath = Join-Path $tempRoot "normal-plan.json"
    $overridePlanPath = Join-Path $tempRoot "override-plan.json"
    $missingReasonPlanPath = Join-Path $tempRoot "missing-reason-plan.json"

    $context = [pscustomobject][ordered]@{
        source = "Radarr"
        libraryType = "Movie"
        entity = [ordered]@{ id = 123; title = "Fixture"; type = "movie" }
        file = [ordered]@{ id = 456; path = $mediaPath; quality = "Bluray-1080p"; sceneName = "Fixture.Release"; releaseGroup = "TEST" }
        release = [ordered]@{ title = "Fixture.Release"; downloadId = "abc123"; indexer = "fixture" }
    }
    $context | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $contextPath -Encoding UTF8

    $validator = [pscustomobject][ordered]@{
        outcome = "NORMALIZE"
        findings = @(
            [pscustomobject][ordered]@{ severity = "NORMALIZE"; code = "audio.multiple_defaults"; message = "fixture" }
        )
        video = @(
            [pscustomobject][ordered]@{ codec = "h264"; width = 1920; height = 1080; pixFmt = "yuv420p"; language = "und"; title = "" }
        )
        auxiliaryVideo = @()
        audio = @(
            [pscustomobject][ordered]@{ codec = "ac3"; language = "eng"; title = "Main"; channels = 6; commentary = $false }
        )
        subtitles = @()
    }
    $validator | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $validatorPath -Encoding UTF8

    & $PlannerPath -ContextPath $contextPath -ValidatorResultPath $validatorPath -JsonOut $normalPlanPath | Out-Null
    $normalPlan = Get-Content -LiteralPath $normalPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test "NORMALIZE remains NOT_NEEDED without explicit escalation" (
        [string]$normalPlan.status -eq "NOT_NEEDED" -and
        [string]$normalPlan.effectiveOutcome -eq "NORMALIZE"
    )

    & $PlannerPath `
        -ContextPath $contextPath `
        -ValidatorResultPath $validatorPath `
        -OperatorEscalateNormalizeToReacquire `
        -OperatorDispositionReason "fixture operator escalation" `
        -JsonOut $overridePlanPath | Out-Null

    $overridePlan = Get-Content -LiteralPath $overridePlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test "Authorized NORMALIZE escalation becomes PLANNED REACQUIRE" (
        [string]$overridePlan.status -eq "PLANNED" -and
        [string]$overridePlan.detectedEffectiveOutcome -eq "NORMALIZE" -and
        [string]$overridePlan.effectiveOutcome -eq "REACQUIRE" -and
        [bool]$overridePlan.operatorDisposition.authorized
    )
    Add-Test "Escalated plan binds normalization finding" (
        @($overridePlan.triggerFindingCodes) -contains "audio.multiple_defaults"
    )
    Add-Test "Escalated plan emits non-empty authorization key" (
        -not [string]::IsNullOrWhiteSpace([string]$overridePlan.operatorDisposition.authorizationKey)
    )

    & $PlannerPath `
        -ContextPath $contextPath `
        -ValidatorResultPath $validatorPath `
        -OperatorEscalateNormalizeToReacquire `
        -JsonOut $missingReasonPlanPath | Out-Null

    $missingReasonPlan = Get-Content -LiteralPath $missingReasonPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Test "Escalation without reason fails closed" (
        [string]$missingReasonPlan.status -eq "BLOCKED" -and
        [string]$missingReasonPlan.reason -eq "operator_disposition_reason_required"
    )
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$tests | Format-Table Test,Passed -AutoSize

$failed = @($tests | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{0} operator escalation checks passed." -f $tests.Count) -ForegroundColor Green
    exit 0
}

Write-Host ("FAIL: {0}/{1} checks failed." -f $failed.Count, $tests.Count) -ForegroundColor Red
exit 1
