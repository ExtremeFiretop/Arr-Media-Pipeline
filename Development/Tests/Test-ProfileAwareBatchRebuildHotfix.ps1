[CmdletBinding()]
param(
    [string]$IntegrationRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Runner = Join-Path $IntegrationRoot "Tools\Invoke-NormalizationPlannedBatch.ps1"
$Planner = Join-Path $IntegrationRoot "NormalizationPlanner.ps1"

foreach ($Required in @($Runner, $Planner)) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Required file not found: $Required"
    }
}

$RunnerText = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
$PlannerText = Get-Content -LiteralPath $Planner -Raw -Encoding UTF8

$Tests = @(
    [pscustomobject]@{ Test = "Batch runner version is 0.1.1"; Passed = ($RunnerText -match '\$BatchVersion\s*=\s*"0\.1\.1"') },
    [pscustomobject]@{ Test = "Current Radarr quality profiles are queried during rebuild"; Passed = ($RunnerText -match '/api/v3/qualityprofile') },
    [pscustomobject]@{ Test = "Profile-aware rows compare planned and current preferred language"; Passed = ($RunnerText -match 'CurrentPreferredLanguage\s+-ne\s+\$PlannedPreferredLanguage') },
    [pscustomobject]@{ Test = "Profile change fails closed"; Passed = ($RunnerText -match 'Radarr preferred-language context changed since planning') },
    [pscustomobject]@{ Test = "Fresh contextual result is passed into planner"; Passed = ($RunnerText -match 'ContextualResultPath.*ContextualPath') },
    [pscustomobject]@{ Test = "Live rebuild contextual status is APPLIED"; Passed = ($RunnerText -match 'radarr_quality_profile_live_rebuild' -and $RunnerText -match 'status\s*=\s*"APPLIED"') },
    [pscustomobject]@{ Test = "Planner remains profile-safe 0.2.3"; Passed = ($PlannerText -match '\$PlannerVersion\s*=\s*"0\.2\.3"') },
    [pscustomobject]@{ Test = "No codec/bitrate ranking was introduced in runner"; Passed = ($RunnerText -notmatch '(?i)codecRank|bitrateRank|qualityRank|truehd.*prefer|dts.*prefer') }
)

Write-Host "Profile-Aware Batch Rebuild Hotfix Test"
Write-Host "========================================"
Write-Host ""
$Tests | Format-Table Test,Passed -AutoSize -Wrap

$Passed = @($Tests | Where-Object { $_.Passed }).Count
$Total = $Tests.Count
Write-Host ""
if ($Passed -eq $Total) {
    Write-Host ("PASS: {0}/{1} batch rebuild hotfix checks passed." -f $Passed, $Total) -ForegroundColor Green
    exit 0
}

Write-Host ("FAIL: {0}/{1} batch rebuild hotfix checks passed." -f $Passed, $Total) -ForegroundColor Red
exit 1
