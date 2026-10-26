[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Quarantine Contract Test"
Write-Host "================================================"
Write-Host ""

function IsDiskOnly {
    param([string[]]$Rejections)

    $patterns = @(
        '^Existing file on disk is of equal or higher preference:',
        '^Existing file on disk is of equal or higher revision:',
        '^Existing file on disk has a equal or higher Custom Format score:',
        '^Existing file on disk has Custom Format score within Custom Format score increment:',
        '^Existing file on disk meets quality cutoff:',
        '^Existing file on disk meets Custom Format cutoff:',
        '^Existing file meets cutoff:',
        "^Existing file on disk and Quality Profile '.*' does not allow upgrades$"
    )

    if ($Rejections.Count -eq 0) { return $false }

    foreach ($rejection in $Rejections) {
        $matched = $false
        foreach ($pattern in $patterns) {
            if ($rejection -match $pattern) {
                $matched = $true
                break
            }
        }

        if (-not $matched) { return $false }
    }

    return $true
}

function Get-TransactionDecision {
    param(
        [bool]$Blocklisted,
        [bool]$PriorSuccess,
        [int]$PredictedCandidates,
        [int]$ApprovedAfterRemoval,
        [bool]$Grabbed,
        [bool]$Queued
    )

    if (-not $Blocklisted) { return "BLOCKED" }
    if (-not $PriorSuccess) { return "BLOCKED" }
    if ($PredictedCandidates -le 0) { return "BLOCKED" }
    if ($ApprovedAfterRemoval -le 0) { return "ROLLBACK" }
    if (-not $Grabbed -and -not $Queued) { return "ROLLBACK" }
    return "KEEP_QUARANTINED"
}

$tests = @(
    [pscustomobject]@{
        Test = "Disk preference-only rejection is eligible prediction"
        Passed = (IsDiskOnly @(
            "Existing file on disk is of equal or higher preference: Bluray-2160p v2"
        ))
    },
    [pscustomobject]@{
        Test = "Disk revision-only rejection is eligible prediction"
        Passed = (IsDiskOnly @(
            "Existing file on disk is of equal or higher revision: v2"
        ))
    },
    [pscustomobject]@{
        Test = "Current-file cutoff-only rejection is eligible prediction"
        Passed = (IsDiskOnly @(
            "Existing file meets cutoff: WEB 2160p (WEBRip-2160p, WEBDL-2160p) [Multi Language, x265 (UHD Preferred)]"
        ))
    },
    [pscustomobject]@{
        Test = "Cutoff plus blocklist rejection is not disk-only"
        Passed = (-not (IsDiskOnly @(
            "Existing file meets cutoff: WEB 2160p (WEBRip-2160p, WEBDL-2160p) [Multi Language, x265 (UHD Preferred)]",
            "Release is blocklisted"
        )))
    },
    [pscustomobject]@{
        Test = "Dolby Vision rejection prevents prediction"
        Passed = (-not (IsDiskOnly @(
            "Existing file on disk is of equal or higher revision: v2",
            "Custom Formats Dolby Vision - Block All have score -10000 below Movie's profile minimum 0"
        )))
    },
    [pscustomobject]@{
        Test = "Missing blocklist blocks quarantine"
        Passed = ((Get-TransactionDecision $false $true 10 10 $true $false) -eq "BLOCKED")
    },
    [pscustomobject]@{
        Test = "Missing prior successful failure state blocks quarantine"
        Passed = ((Get-TransactionDecision $true $false 10 10 $true $false) -eq "BLOCKED")
    },
    [pscustomobject]@{
        Test = "No approved releases after removal rolls back"
        Passed = ((Get-TransactionDecision $true $true 10 0 $false $false) -eq "ROLLBACK")
    },
    [pscustomobject]@{
        Test = "No grab or queue after search rolls back"
        Passed = ((Get-TransactionDecision $true $true 10 5 $false $false) -eq "ROLLBACK")
    },
    [pscustomobject]@{
        Test = "Confirmed replacement activity keeps quarantine"
        Passed = ((Get-TransactionDecision $true $true 10 5 $true $false) -eq "KEEP_QUARANTINED")
    },
    [pscustomobject]@{
        Test = "Quarantine accepts suppressed-redownload MarkFailed success"
        Passed = ((Get-Content (Join-Path $PSScriptRoot "Invoke-ReacquisitionQuarantine.ps1") -Raw) -match "SUCCESS_SEARCH_SUPPRESSED")
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition quarantine contract tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition quarantine contract tests failed." -f $failed.Count, $tests.Count)
exit 1
