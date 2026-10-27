[CmdletBinding()]
param([string]$ReleaseRoot=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$planner = Join-Path $ReleaseRoot "Integration\ReacquisitionPlanner.ps1"
if (-not (Test-Path -LiteralPath $planner -PathType Leaf)) { throw "Planner missing: $planner" }

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("Reqestra-ReacqPlannerSingle-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    $media = Join-Path $temp "fixture.mkv"
    [System.IO.File]::WriteAllBytes($media, [byte[]](1,2,3,4))

    $contextPath = Join-Path $temp "context.json"
    $context = [pscustomobject][ordered]@{
        source = "Radarr"
        libraryType = "Movie"
        entity = [ordered]@{ id=123; title="Fixture"; type="movie" }
        file = [ordered]@{ id=456; path=$media; quality="Bluray-1080p"; sceneName="Fixture.Release"; releaseGroup="TEST" }
        release = [ordered]@{ title="Fixture.Release.1080p.TEST"; downloadId="fixture-download-id"; indexer="fixture" }
    }
    $context | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $contextPath -Encoding UTF8

    $cases = @(
        [pscustomobject]@{
            Name = "native single REACQUIRE finding"
            Outcome = "REACQUIRE"
            Severity = "REACQUIRE"
            Code = "video.dolby_vision"
            EscalationReason = ""
            ExpectedDetected = "REACQUIRE"
        },
        [pscustomobject]@{
            Name = "single NORMALIZE finding escalates"
            Outcome = "NORMALIZE"
            Severity = "NORMALIZE"
            Code = "audio.multiple_defaults"
            EscalationReason = "ambiguous_default_audio_target"
            ExpectedDetected = "NORMALIZE"
        }
    )

    $results = @()

    foreach ($case in $cases) {
        $validatorPath = Join-Path $temp (([guid]::NewGuid().ToString("N")) + "-validator.json")
        $outPath = Join-Path $temp (([guid]::NewGuid().ToString("N")) + "-plan.json")

        $validator = [pscustomobject][ordered]@{
            outcome = $case.Outcome
            findings = @([pscustomobject][ordered]@{ severity=$case.Severity; code=$case.Code; message="fixture" })
            video = @()
            auxiliaryVideo = @()
            audio = @()
            subtitles = @()
        }
        $validator | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $validatorPath -Encoding UTF8

        $powershell = Join-Path $PSHOME "powershell.exe"
        if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { $powershell = "powershell.exe" }

        if ([string]::IsNullOrWhiteSpace($case.EscalationReason)) {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $planner `
                -ContextPath $contextPath `
                -ValidatorResultPath $validatorPath `
                -JsonOut $outPath | Out-Null
        }
        else {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $planner `
                -ContextPath $contextPath `
                -ValidatorResultPath $validatorPath `
                -AutomaticEscalationReason $case.EscalationReason `
                -JsonOut $outPath | Out-Null
        }
        $exitCode = $LASTEXITCODE

        $plan = if (Test-Path -LiteralPath $outPath -PathType Leaf) {
            Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } else { $null }

        $triggers = @(if ($null -ne $plan) { $plan.triggerFindingCodes } else { @() })
        $loopKey = if ($null -ne $plan -and $null -ne $plan.loopPrevention) { [string]$plan.loopPrevention.loopKey } else { "" }

        $passed = (
            $exitCode -eq 0 -and
            $null -ne $plan -and
            [string]$plan.status -eq "PLANNED" -and
            [string]$plan.detectedEffectiveOutcome -eq $case.ExpectedDetected -and
            [string]$plan.effectiveOutcome -eq "REACQUIRE" -and
            $triggers.Count -eq 1 -and
            [string]$triggers[0] -eq $case.Code -and
            -not [string]::IsNullOrWhiteSpace($loopKey)
        )

        $results += [pscustomobject]@{
            Test = $case.Name
            Passed = $passed
            ExitCode = $exitCode
            Status = if ($null -ne $plan) { [string]$plan.status } else { "NO_RESULT" }
            TriggerCount = $triggers.Count
        }
    }

    $results | Format-Table -AutoSize
    $failed = @($results | Where-Object { -not $_.Passed })
    if ($failed.Count -gt 0) { throw "$($failed.Count) single-finding planner regression test(s) failed." }
    Write-Host "PASS: $($results.Count)/$($results.Count) single-finding planner regression tests passed." -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
