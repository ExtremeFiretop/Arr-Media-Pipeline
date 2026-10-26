[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Planner Contract Test"
Write-Host "============================================"
Write-Host ""

function Get-PlanDecision {
    param(
        [string]$EffectiveOutcome,
        [string[]]$FindingCodes,
        [string]$Source = "Radarr",
        [int]$EntityId = 1,
        [int]$FileId = 2,
        [string]$ReleaseIdentityStrength = "STRONG",
        [bool]$SnapshotAvailable = $true
    )

    $supported = @(
        "video.dolby_vision",
        "video.codec_prohibited",
        "audio.missing",
        "language.preferred_missing"
    )

    if ($EffectiveOutcome -ne "REACQUIRE") { return "NOT_NEEDED" }
    if ($Source -notin @("Radarr","Sonarr")) { return "BLOCKED" }
    if ($EntityId -le 0 -or $FileId -le 0) { return "BLOCKED" }
    if (-not $SnapshotAvailable) { return "BLOCKED" }
    if (@($FindingCodes | Where-Object { $supported -contains $_ }).Count -eq 0) { return "BLOCKED" }
    if ($ReleaseIdentityStrength -in @("NONE","WEAK")) { return "BLOCKED" }

    return "PLANNED"
}

$tests = @(
    [pscustomobject]@{ Test = "PASS does not plan reacquisition"; Passed = ((Get-PlanDecision "PASS" @()) -eq "NOT_NEEDED") },
    [pscustomobject]@{ Test = "Dolby Vision is supported"; Passed = ((Get-PlanDecision "REACQUIRE" @("video.dolby_vision")) -eq "PLANNED") },
    [pscustomobject]@{ Test = "Prohibited codec is supported"; Passed = ((Get-PlanDecision "REACQUIRE" @("video.codec_prohibited")) -eq "PLANNED") },
    [pscustomobject]@{ Test = "Missing audio is supported"; Passed = ((Get-PlanDecision "REACQUIRE" @("audio.missing")) -eq "PLANNED") },
    [pscustomobject]@{ Test = "Missing preferred language is supported"; Passed = ((Get-PlanDecision "REACQUIRE" @("language.preferred_missing") -Source "Sonarr") -eq "PLANNED") },
    [pscustomobject]@{ Test = "Unsupported reacquire finding blocks"; Passed = ((Get-PlanDecision "REACQUIRE" @("future.unknown")) -eq "BLOCKED") },
    [pscustomobject]@{ Test = "Weak release identity blocks"; Passed = ((Get-PlanDecision "REACQUIRE" @("video.dolby_vision") -ReleaseIdentityStrength "WEAK") -eq "BLOCKED") },
    [pscustomobject]@{ Test = "Missing snapshot blocks"; Passed = ((Get-PlanDecision "REACQUIRE" @("video.dolby_vision") -SnapshotAvailable $false) -eq "BLOCKED") }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition planner contract tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition planner tests failed." -f $failed.Count, $tests.Count)
exit 1
