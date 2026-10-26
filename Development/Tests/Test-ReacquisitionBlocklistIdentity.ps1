[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Blocklist Identity Test"
Write-Host "=============================================="
Write-Host ""

function Normalize-ReleaseTitle {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[\s\.\-_]+', ' ')
    $normalized = [regex]::Replace($normalized, '[^a-z0-9 ]', '')
    $normalized = [regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim()
}

function Get-RecordArray {
    param($Response)

    if ($null -eq $Response) { return @() }

    $recordsProperty = $Response.PSObject.Properties["records"]
    if ($null -ne $recordsProperty) {
        return @($recordsProperty.Value)
    }

    if ($Response -is [System.Array]) {
        return @($Response)
    }

    return @($Response)
}

function Match-Blocklist {
    param(
        [object[]]$Records,
        [int]$MovieId,
        [string]$SourceTitle
    )

    $expected = Normalize-ReleaseTitle $SourceTitle

    return @(
        $Records |
            Where-Object {
                $recordMovieId = [int]$_.movieId
                $recordTitle = Normalize-ReleaseTitle ([string]$_.sourceTitle

                )
                ($recordMovieId -eq $MovieId) -and
                ($recordTitle -eq $expected)
            }
    )
}

$title = "The.Fantastic.Four.First.Steps.2025.PROPER.German.DL.2160p.UHD.BluRay.x265-ENDSTATiON"

$rawArray = @(
    [pscustomobject]@{
        id = 12
        movieId = 1458
        sourceTitle = $title
        protocol = "usenet"
        indexer = "nzbfinder.ws"
    }
)

$normalized = @(Get-RecordArray -Response $rawArray)
$matching = @(Match-Blocklist -Records $normalized -MovieId 1458 -SourceTitle $title)

$tests = @(
    [pscustomobject]@{
        Test = "Raw blocklist array normalizes to one record"
        Passed = ($normalized.Count -eq 1)
    },
    [pscustomobject]@{
        Test = "Movie-scoped source title matches blocklist row"
        Passed = ($matching.Count -eq 1)
    },
    [pscustomobject]@{
        Test = "Blocklist matching does not require downloadId"
        Passed = ($null -eq $rawArray[0].PSObject.Properties["downloadId"])
    },
    [pscustomobject]@{
        Test = "Equivalent separator variants normalize identically"
        Passed = (
            (Normalize-ReleaseTitle "The.Fantastic-Four_First.Steps") -eq
            (Normalize-ReleaseTitle "The Fantastic Four First Steps")
        )
    },
    [pscustomobject]@{
        Test = "Different movie id does not match"
        Passed = (
            @(Match-Blocklist -Records $normalized -MovieId 999 -SourceTitle $title).Count -eq 0
        )
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition blocklist identity tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition blocklist identity tests failed." -f $failed.Count, $tests.Count)
exit 1
