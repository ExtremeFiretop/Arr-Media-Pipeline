[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SelectorPath = Join-Path $Root "Integration\ReacquisitionReleaseSelector.ps1"

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

. $SelectorPath

$nullNative = Select-ReacquisitionRelease -Releases $null
$emptyNative = Select-ReacquisitionRelease -Releases @()
$nullDv = Select-ReacquisitionRelease -Releases $null -TriggerFindingCodes @("video.dolby_vision")
$emptyPool = @(Get-ReacquisitionPredictedCandidatePool -Releases $null)

$tests = @(
    [pscustomobject]@{
        Test = "native selector accepts null release collection"
        Passed = ($nullNative.strategy -eq "RADARR_NATIVE" -and [int]$nullNative.eligibleCount -eq 0)
    },
    [pscustomobject]@{
        Test = "native selector accepts empty release collection"
        Passed = ($emptyNative.strategy -eq "RADARR_NATIVE" -and [int]$emptyNative.eligibleCount -eq 0)
    },
    [pscustomobject]@{
        Test = "DV selector accepts null release collection"
        Passed = ($nullDv.strategy -eq "DOLBY_VISION_SAFE_EVIDENCE_V1" -and [int]$nullDv.eligibleCount -eq 0 -and $null -eq $nullDv.selected)
    },
    [pscustomobject]@{
        Test = "predicted candidate pool accepts null collection"
        Passed = ($emptyPool.Count -eq 0)
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} empty-release selection tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} empty-release selection tests failed." -f $failed.Count, $tests.Count)
exit 1
