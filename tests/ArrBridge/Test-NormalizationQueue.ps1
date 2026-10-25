[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$QueueCommonPath = Join-Path $PSScriptRoot "QueueCommon.ps1"
. $QueueCommonPath

Write-Host ""
Write-Host "Reqestra Normalization Queue Self-Test"
Write-Host "======================================"
Write-Host ""

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ReqestraQueueSelfTest-" + [guid]::NewGuid().ToString("N"))
$fakeIntegration = Join-Path $tempRoot "Integration"
New-Item -ItemType Directory -Path $fakeIntegration -Force | Out-Null

try {
    $plan1Path = Join-Path $tempRoot "plan-1.json"
    $plan2Path = Join-Path $tempRoot "plan-2.json"

    $plan = [pscustomobject][ordered]@{
        schemaVersion = "1.0"
        plannerVersion = "0.2.0"
        status = "PLANNED"
        mediaPath = "V:\TV Shows\Test\Test S01E01.mkv"
        plannedFindingCodes = @("language.preferred_not_default")
        sourceSnapshot = [ordered]@{
            lengthBytes = 123456789
            lastWriteTimeUtc = "2026-10-25T00:00:00.0000000Z"
            streamFingerprint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }
        actions = @(
            [ordered]@{
                action = "set_audio_default_flag"
                audioOrdinal = 1
                ffprobeStreamIndex = 1
                language = "fre"
                commentary = $false
                from = $true
                to = $false
            },
            [ordered]@{
                action = "set_audio_default_flag"
                audioOrdinal = 2
                ffprobeStreamIndex = 2
                language = "eng"
                commentary = $false
                from = $false
                to = $true
            }
        )
    }

    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $plan1Path -Encoding UTF8
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $plan2Path -Encoding UTF8

    $first = Enqueue-NormalizationPlan `
        -IntegrationRoot $fakeIntegration `
        -PlanPath $plan1Path `
        -Source "Sonarr" `
        -EventId "self-test-1"

    $second = Enqueue-NormalizationPlan `
        -IntegrationRoot $fakeIntegration `
        -PlanPath $plan2Path `
        -Source "Sonarr" `
        -EventId "self-test-2"

    $summary = Get-NormalizationQueueSummary -IntegrationRoot $fakeIntegration

    $results = @(
        [pscustomobject]@{
            Test = "First equivalent plan enqueues"
            Passed = ($first.status -eq "ENQUEUED")
            Actual = $first.status
            Expected = "ENQUEUED"
        },
        [pscustomobject]@{
            Test = "Second equivalent plan is suppressed"
            Passed = ($second.status -eq "DUPLICATE")
            Actual = $second.status
            Expected = "DUPLICATE"
        },
        [pscustomobject]@{
            Test = "Equivalent plans share deterministic job id"
            Passed = ($first.jobId -eq $second.jobId)
            Actual = ($first.jobId -eq $second.jobId)
            Expected = $true
        },
        [pscustomobject]@{
            Test = "Only one pending job exists"
            Passed = ($summary.pending -eq 1)
            Actual = $summary.pending
            Expected = 1
        },
        [pscustomobject]@{
            Test = "Queue mode is hard-coded dry run"
            Passed = ($summary.effectiveMode -eq "AUTO_DRY_RUN")
            Actual = $summary.effectiveMode
            Expected = "AUTO_DRY_RUN"
        }
    )

    $results | Format-Table -AutoSize -Wrap

    $failed = @($results | Where-Object { -not $_.Passed })

    Write-Host ""
    if ($failed.Count -eq 0) {
        Write-Host ("PASS: {0}/{1} normalization queue tests passed." -f $results.Count, $results.Count)
        exit 0
    }

    Write-Host ("FAIL: {0}/{1} normalization queue tests failed." -f $failed.Count, $results.Count)
    exit 1
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
