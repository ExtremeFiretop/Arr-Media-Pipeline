[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ExecutorPath = Join-Path $Root "Integration\Invoke-Reacquisition.ps1"
$Source = Get-Content -LiteralPath $ExecutorPath -Raw -Encoding UTF8

function Normalize-Expected {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[\s\.\-_]+', ' ')
    $normalized = [regex]::Replace($normalized, '[^a-z0-9+ ]', '')
    $normalized = [regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim()
}

$releaseTitle = "American.Pie.1999.THEATRiCAL.2160p.UHD.BluRay.x265-4KDVS"
$historyVariant = "American Pie 1999 THEATRiCAL 2160p UHD BluRay x265 4KDVS"
$other = "American.Pie.2.2001.2160p.UHD.BluRay.x265-OTHER"

$records = @(
    [pscustomobject]@{ sourceTitle = $historyVariant },
    [pscustomobject]@{ sourceTitle = $other }
)

$expectedNormalized = Normalize-Expected $releaseTitle
$logicalMatches = @(
    $records | Where-Object {
        (Normalize-Expected ([string]$_.sourceTitle)) -eq $expectedNormalized
    }
)

$ambiguousRecords = @(
    [pscustomobject]@{ sourceTitle = $historyVariant },
    [pscustomobject]@{ sourceTitle = "American_Pie_1999_THEATRiCAL_2160p_UHD_BluRay_x265_4KDVS" }
)
$ambiguousMatches = @(
    $ambiguousRecords | Where-Object {
        (Normalize-Expected ([string]$_.sourceTitle)) -eq $expectedNormalized
    }
)

$tests = @(
    [pscustomobject]@{
        Test = "executor defines normalized import-history identity helper"
        Passed = ($Source -match 'function\s+Normalize-ReacquisitionIdentityTitle')
    },
    [pscustomobject]@{
        Test = "executor includes normalized sourceTitle fallback"
        Passed = ($Source -match 'matchMethod\s*=\s*"sourceTitleNormalized"')
    },
    [pscustomobject]@{
        Test = "separator differences normalize to one logical source title"
        Passed = ($logicalMatches.Count -eq 1)
    },
    [pscustomobject]@{
        Test = "normalization does not collapse a different movie title"
        Passed = ((Normalize-Expected $other) -ne $expectedNormalized)
    },
    [pscustomobject]@{
        Test = "ambiguous normalized source titles remain detectable as ambiguous"
        Passed = ($ambiguousMatches.Count -eq 2)
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} normalized import-history identity tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} normalized import-history identity tests failed." -f $failed.Count, $tests.Count)
exit 1
