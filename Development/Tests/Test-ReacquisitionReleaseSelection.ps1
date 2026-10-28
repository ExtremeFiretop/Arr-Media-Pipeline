[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$IntegrationRoot = Join-Path $Root "Integration"

. (Join-Path $IntegrationRoot "ReacquisitionChainCommon.ps1")
. (Join-Path $IntegrationRoot "ReacquisitionReleaseSelector.ps1")

Write-Host ""
Write-Host "Reqestra Reacquisition Release Selection Contract Test"
Write-Host "======================================================"
Write-Host ""

function New-TestRelease {
    param(
        [string]$Title,
        [string]$Group = "GROUP",
        [int]$Score = 100,
        [bool]$Approved = $true,
        [object[]]$Rejections = @()
    )

    return [pscustomobject]@{
        title = $Title
        releaseGroup = $Group
        customFormatScore = $Score
        indexer = "test"
        protocol = "usenet"
        size = 10000000000
        approved = $Approved
        rejections = @($Rejections)
        indexerId = 1
        guid = [guid]::NewGuid().ToString("N")
    }
}

$chain = [pscustomobject]@{
    attempts = @(
        [pscustomobject]@{ releaseTitle = "Movie.2026.2160p.UHD.BluRay.x265-OLDGROUP"; releaseGroup = "OLDGROUP" }
    )
}

$dv = New-TestRelease "Movie.2026.2160p.WEB-DL.DV.HDR.H265-BAD" "BAD"
$hdr10 = New-TestRelease "Movie.2026.2160p.WEB-DL.HDR10.H265-GOOD" "GOOD"
$sdr = New-TestRelease "Movie.2026.2160p.WEB-DL.SDR.H265-SDRGROUP" "SDRGROUP"
$hdr = New-TestRelease "Movie.2026.2160p.WEB-DL.HDR.H265-HDRGROUP" "HDRGROUP"
$web = New-TestRelease "Movie.2026.2160p.WEB-DL.H265-WEBGROUP" "WEBGROUP"
$other = New-TestRelease "Movie.2026.2160p.H265-OTHER" "OTHER"
$uhd = New-TestRelease "Movie.2026.2160p.UHD.BluRay.x265-UHDGROUP" "UHDGROUP"
$failedGroupUnknown = New-TestRelease "Movie.2026.2160p.WEB-DL.H265-OLDGROUP" "OLDGROUP"
$failedGroupHdr10 = New-TestRelease "Movie.2026.2160p.WEB-DL.HDR10.H265-OLDGROUP" "OLDGROUP"
$failedExact = New-TestRelease "Movie.2026.2160p.UHD.BluRay.x265-OLDGROUP" "OLDGROUP"

$selection = Select-ReacquisitionRelease -Releases @($uhd,$web,$hdr,$sdr,$hdr10,$dv) -TriggerFindingCodes @("video.dolby_vision") -Chain $chain
$groupSelection = Select-ReacquisitionRelease -Releases @($failedGroupUnknown,$web) -TriggerFindingCodes @("video.dolby_vision") -Chain $chain
$explicitSameGroup = Select-ReacquisitionRelease -Releases @($web,$failedGroupHdr10) -TriggerFindingCodes @("video.dolby_vision") -Chain $chain
$exactFailedSelection = Select-ReacquisitionRelease -Releases @($failedExact,$uhd) -TriggerFindingCodes @("video.dolby_vision") -Chain $chain
$sameTierA = New-TestRelease "Movie.2026.2160p.WEB-DL.HDR10.H265-A" "A"
$sameTierB = New-TestRelease "Movie.2026.2160p.WEB-DL.HDR10.H265-B" "B"
$sameTierSelection = Select-ReacquisitionRelease -Releases @($sameTierA,$sameTierB) -TriggerFindingCodes @("video.dolby_vision") -Chain $null
$nativeSelection = Select-ReacquisitionRelease -Releases @($uhd,$hdr10) -TriggerFindingCodes @("video.av1") -Chain $chain

$currentApprovedUnknown = New-TestRelease "Movie.2026.2160p.UHD.BluRay.x265-CURRENT" "CURRENT" 100 $true
$diskBlockedHdr10 = New-TestRelease `
    "Movie.2026.2160p.WEB-DL.HDR10.H265-PREDICTED" `
    "PREDICTED" `
    100 `
    $false `
    @("Existing file meets cutoff: WEB 2160p")
$predictedPool = @(Get-ReacquisitionPredictedCandidatePool -Releases @($currentApprovedUnknown,$diskBlockedHdr10))
$predictedSelection = Select-ReacquisitionRelease -Releases $predictedPool -TriggerFindingCodes @("video.dolby_vision") -Chain $null

$rankOrder = @($selection.ranked | ForEach-Object { $_.evidence })

$tests = @(
    [pscustomobject]@{
        Test = "Explicit Dolby Vision title is excluded"
        Passed = (@($selection.ranked | Where-Object { $_.title -eq $dv.title }).Count -eq 0 -and $selection.excludedCount -ge 1)
    },
    [pscustomobject]@{
        Test = "Explicit HDR10 outranks SDR, generic HDR, unknown WEB and UHD BluRay"
        Passed = ($selection.selected.title -eq $hdr10.title -and $rankOrder[0] -eq "EXPLICIT_HDR10")
    },
    [pscustomobject]@{
        Test = "Explicit SDR outranks generic HDR"
        Passed = ([array]::IndexOf($rankOrder, "EXPLICIT_SDR") -lt [array]::IndexOf($rankOrder, "EXPLICIT_HDR_GENERIC"))
    },
    [pscustomobject]@{
        Test = "Unknown WEB outranks unknown UHD BluRay for DV replacement"
        Passed = ([array]::IndexOf($rankOrder, "UNKNOWN_WEB") -lt [array]::IndexOf($rankOrder, "UNKNOWN_UHD_BLURAY"))
    },
    [pscustomobject]@{
        Test = "Previously failed group is penalized for unknown releases"
        Passed = ($groupSelection.selected.releaseGroup -eq "WEBGROUP")
    },
    [pscustomobject]@{
        Test = "Explicit HDR10 evidence can override prior-group penalty"
        Passed = ($explicitSameGroup.selected.releaseGroup -eq "OLDGROUP" -and $explicitSameGroup.selected.evidence -eq "EXPLICIT_HDR10")
    },
    [pscustomobject]@{
        Test = "Previously failed exact release title is excluded"
        Passed = ($exactFailedSelection.selected.title -eq $uhd.title -and $exactFailedSelection.excludedCount -eq 1)
    },
    [pscustomobject]@{
        Test = "Radarr ordering is preserved inside the same safety tier"
        Passed = ($sameTierSelection.selected.title -eq $sameTierA.title)
    },
    [pscustomobject]@{
        Test = "Non-DV reacquisition retains native Radarr selection behavior"
        Passed = ($nativeSelection.strategy -eq "RADARR_NATIVE" -and $null -eq $nativeSelection.selected)
    },
    [pscustomobject]@{
        Test = "Predicted pool includes approved and disk-only candidates and lets HDR10 outrank current approved unknown"
        Passed = ($predictedPool.Count -eq 2 -and $predictedSelection.selected.title -eq $diskBlockedHdr10.title -and $predictedSelection.selected.evidence -eq "EXPLICIT_HDR10")
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition release-selection contract tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition release-selection contract tests failed." -f $failed.Count, $tests.Count)
exit 1
