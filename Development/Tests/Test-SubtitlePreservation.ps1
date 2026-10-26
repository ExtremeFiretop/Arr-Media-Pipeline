[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PlannerPath = Join-Path $PSScriptRoot "NormalizationPlanner.ps1"
$ExecutorPath = Join-Path $PSScriptRoot "Invoke-Normalization.ps1"
$PowerShellExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    $PowerShellExe = "powershell.exe"
}

function New-ValidatorResult {
    param(
        [bool]$SubtitleDefault,
        [bool]$SubtitleForced,
        [bool]$SubtitleHearingImpaired
    )

    return [pscustomobject][ordered]@{
        validatorVersion = "subtitle-preservation-self-test"
        outcome = "NORMALIZE"
        video = @(
            [pscustomobject][ordered]@{
                index = 0
                codec = "hevc"
                width = 1920
                height = 1080
                pixFmt = "yuv420p10le"
                language = "und"
                title = ""
            }
        )
        auxiliaryVideo = @()
        audio = @(
            [pscustomobject][ordered]@{
                index = 1
                codec = "aac"
                language = "eng"
                title = "Main"
                channels = 2
                default = $false
                commentary = $false
            }
        )
        subtitles = @(
            [pscustomobject][ordered]@{
                index = 2
                codec = "subrip"
                language = "eng"
                title = "English"
                default = $SubtitleDefault
                forced = $SubtitleForced
                hearingImpaired = $SubtitleHearingImpaired
            }
        )
        findings = @(
            [pscustomobject][ordered]@{
                severity = "NORMALIZE"
                code = "audio.no_default"
                message = "No audio track is marked as default."
            }
        )
    }
}

function Get-PlannerFingerprint {
    param(
        [string]$CaseRoot,
        $ValidatorResult
    )

    New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null
    $mediaPath = Join-Path $CaseRoot "sample.mkv"
    [System.IO.File]::WriteAllBytes($mediaPath, [byte[]](1,2,3,4))

    $context = [pscustomobject][ordered]@{
        source = "Radarr"
        file = [ordered]@{ path = $mediaPath }
    }

    $contextual = [pscustomobject][ordered]@{
        status = "SKIPPED"
        preferredLanguage = $null
        findings = @()
    }

    $contextPath = Join-Path $CaseRoot "context.json"
    $validatorPath = Join-Path $CaseRoot "validator.json"
    $contextualPath = Join-Path $CaseRoot "contextual.json"
    $planPath = Join-Path $CaseRoot "plan.json"

    $context | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $contextPath -Encoding UTF8
    $ValidatorResult | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $validatorPath -Encoding UTF8
    $contextual | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $contextualPath -Encoding UTF8

    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $PlannerPath `
        -ContextPath $contextPath `
        -ValidatorResultPath $validatorPath `
        -ContextualResultPath $contextualPath `
        -JsonOut $planPath

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        throw "NormalizationPlanner self-test invocation failed."
    }

    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$plan.status -ne "PLANNED") {
        throw "Expected PLANNED result, got '$($plan.status)' / '$($plan.reason)'."
    }

    return [string]$plan.sourceSnapshot.streamFingerprint
}

$results = @()
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ReqestraSubtitlePreservation-" + [guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $baseline = Get-PlannerFingerprint -CaseRoot (Join-Path $tempRoot "baseline") `
        -ValidatorResult (New-ValidatorResult -SubtitleDefault $false -SubtitleForced $false -SubtitleHearingImpaired $false)

    $defaultChanged = Get-PlannerFingerprint -CaseRoot (Join-Path $tempRoot "default") `
        -ValidatorResult (New-ValidatorResult -SubtitleDefault $true -SubtitleForced $false -SubtitleHearingImpaired $false)

    $forcedChanged = Get-PlannerFingerprint -CaseRoot (Join-Path $tempRoot "forced") `
        -ValidatorResult (New-ValidatorResult -SubtitleDefault $false -SubtitleForced $true -SubtitleHearingImpaired $false)

    $sdhChanged = Get-PlannerFingerprint -CaseRoot (Join-Path $tempRoot "sdh") `
        -ValidatorResult (New-ValidatorResult -SubtitleDefault $false -SubtitleForced $false -SubtitleHearingImpaired $true)

    $results += [pscustomobject]@{ Test = "Planner fingerprint protects subtitle default flag"; Passed = ($baseline -ne $defaultChanged) }
    $results += [pscustomobject]@{ Test = "Planner fingerprint protects subtitle forced flag"; Passed = ($baseline -ne $forcedChanged) }
    $results += [pscustomobject]@{ Test = "Planner fingerprint protects subtitle SDH/hearing-impaired flag"; Passed = ($baseline -ne $sdhChanged) }

    $plannerText = Get-Content -LiteralPath $PlannerPath -Raw -Encoding UTF8
    $executorText = Get-Content -LiteralPath $ExecutorPath -Raw -Encoding UTF8

    foreach ($pair in @(
        [pscustomobject]@{ Name = "Planner"; Text = $plannerText },
        [pscustomobject]@{ Name = "Executor"; Text = $executorText }
    )) {
        foreach ($field in @("codec", "language", "title", "default", "forced", "hearingImpaired")) {
            $results += [pscustomobject]@{
                Test = "$($pair.Name) subtitle fingerprint includes $field"
                Passed = ($pair.Text -match ("(?s)subtitles\s*=.*?" + [regex]::Escape($field) + "\s*="))
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Reqestra Subtitle Preservation Contract Test"
Write-Host "============================================"
Write-Host ""
$results | Format-Table -AutoSize -Wrap

$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} subtitle preservation contracts passed." -f $results.Count, $results.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} subtitle preservation contracts failed." -f $failed.Count, $results.Count)
$failed | Format-List *
exit 1
