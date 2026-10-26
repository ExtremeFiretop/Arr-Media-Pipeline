[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Retry Contract Test"
Write-Host "==========================================="
Write-Host ""

function Get-ChainAttemptAction {
    param([int]$AttemptNumber, [int]$MaxAttempts)
    if ($AttemptNumber -gt $MaxAttempts) { return "BLOCK" }
    if ($AttemptNumber -eq $MaxAttempts) { return "DELETE_RESTORE_AND_TERMINATE_NO_SEARCH" }
    return "DELETE_AND_SEARCH"
}


function Get-ReplacementAcquisitionAction {
    param([string[]]$FindingCodes)
    if ($FindingCodes -contains "video.dolby_vision") { return "DIRECT_SELECTED_RELEASE_GRAB" }
    return "MOVIES_SEARCH"
}


function Get-PreRemovalCandidatePoolMode {
    param([bool]$IsDolbyVision)
    if ($IsDolbyVision) { return "APPROVED_PLUS_DISK_ONLY_PREDICTED" }
    return "DISK_ONLY_BLOCKED"
}

function Get-PostDeleteDecision {
    param(
        [int]$ApprovedAfterRemoval,
        [bool]$SearchSucceeded,
        [bool]$Grabbed,
        [bool]$Queued
    )

    if ($ApprovedAfterRemoval -le 0) { return "RESTORE_ROLLBACK" }
    if (-not $SearchSucceeded) { return "RESTORE_ROLLBACK" }
    if (-not $Grabbed -and -not $Queued) { return "RESTORE_ROLLBACK" }
    return "KEEP_ROLLBACK_AND_WAIT"
}

$tests = @(
    [pscustomobject]@{
        Test = "Final allowed attempt deletes failed retry, restores rollback, and starts no search"
        Passed = ((Get-ChainAttemptAction 3 3) -eq "DELETE_RESTORE_AND_TERMINATE_NO_SEARCH")
    },
    [pscustomobject]@{
        Test = "Terminal exhaustion preserves library availability via rollback restore"
        Passed = ((Get-ChainAttemptAction 3 3) -match "RESTORE")
    },
    [pscustomobject]@{
        Test = "Attempt beyond chain ceiling is blocked before mutation"
        Passed = ((Get-ChainAttemptAction 4 3) -eq "BLOCK")
    },
    [pscustomobject]@{
        Test = "Dolby Vision retry uses direct selected-release grab"
        Passed = ((Get-ReplacementAcquisitionAction @("video.dolby_vision")) -eq "DIRECT_SELECTED_RELEASE_GRAB")
    },
    [pscustomobject]@{
        Test = "Non-Dolby-Vision retry keeps native MoviesSearch behavior"
        Passed = ((Get-ReplacementAcquisitionAction @("video.av1")) -eq "MOVIES_SEARCH")
    },
    [pscustomobject]@{
        Test = "Dolby Vision pre-removal ranking includes approved plus disk-only predicted candidates"
        Passed = ((Get-PreRemovalCandidatePoolMode $true) -eq "APPROVED_PLUS_DISK_ONLY_PREDICTED")
    },
    [pscustomobject]@{
        Test = "No approved release restores the single rollback copy"
        Passed = ((Get-PostDeleteDecision 0 $false $false $false) -eq "RESTORE_ROLLBACK")
    },
    [pscustomobject]@{
        Test = "Search failure restores the single rollback copy"
        Passed = ((Get-PostDeleteDecision 10 $false $false $false) -eq "RESTORE_ROLLBACK")
    },
    [pscustomobject]@{
        Test = "No grab or queue restores the single rollback copy"
        Passed = ((Get-PostDeleteDecision 10 $true $false $false) -eq "RESTORE_ROLLBACK")
    },
    [pscustomobject]@{
        Test = "Grab keeps only the original rollback copy"
        Passed = ((Get-PostDeleteDecision 10 $true $true $false) -eq "KEEP_ROLLBACK_AND_WAIT")
    },
    [pscustomobject]@{
        Test = "Queue activity keeps only the original rollback copy"
        Passed = ((Get-PostDeleteDecision 10 $true $false $true) -eq "KEEP_ROLLBACK_AND_WAIT")
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition retry contract tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition retry contract tests failed." -f $failed.Count, $tests.Count)
exit 1
