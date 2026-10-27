[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ExecutorPath = Join-Path $Root "Integration\Invoke-Reacquisition.ps1"
$Source = Get-Content -LiteralPath $ExecutorPath -Raw -Encoding UTF8

function Get-TestPropertyValue {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }

    return $property.Value
}

function Get-TestHistoryFileId {
    param($Record)

    $data = Get-TestPropertyValue -Object $Record -Name "data" -Default $null
    if ($null -eq $data) { return 0 }

    $raw = Get-TestPropertyValue -Object $data -Name "fileId" -Default $null
    if ($null -eq $raw) { $raw = Get-TestPropertyValue -Object $data -Name "FileId" -Default $null }
    if ($null -eq $raw) { $raw = Get-TestPropertyValue -Object $data -Name "movieFileId" -Default $null }
    if ($null -eq $raw) { $raw = Get-TestPropertyValue -Object $data -Name "episodeFileId" -Default $null }

    $n = 0
    if ([int]::TryParse([string]$raw,[ref]$n)) { return $n }
    return 0
}

function Resolve-TestMatch {
    param(
        [object[]]$Records,
        [int]$FileId,
        [string]$DownloadId
    )

    $imports = @(
        @($Records) |
            Where-Object {
                [string]$_.eventType -eq "downloadFolderImported"
            }
    )

    $matches = @(
        $imports |
            Where-Object {
                (Get-TestHistoryFileId $_) -eq $FileId
            }
    )

    if ($matches.Count -ne 1) {
        $matches = @(
            $imports |
                Where-Object {
                    [string]::Equals(
                        [string](Get-TestPropertyValue -Object $_ -Name "downloadId" -Default ""),
                        $DownloadId,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
    }

    return @($matches)
}

$oldImport = [pscustomobject]@{
    id = 100
    eventType = "downloadFolderImported"
    downloadId = "old-download"
    sourceTitle = "Old.Release"
    data = [pscustomobject]@{
        movieFileId = 7000
        importedPath = "M:\Movies\Example\Old.mkv"
    }
}

$currentGrab = [pscustomobject]@{
    id = 101
    eventType = "grabbed"
    downloadId = "current-download"
    sourceTitle = "Example.Release.2160p"
    data = [pscustomobject]@{}
}

$currentImport = [pscustomobject]@{
    id = 102
    eventType = "downloadFolderImported"
    downloadId = "current-download"
    sourceTitle = "Example.Release.2160p"
    data = [pscustomobject]@{
        movieFileId = 8422
        importedPath = "M:\Movies\Example\Example.mkv"
    }
}

$beforeCommit = @(Resolve-TestMatch -Records @($oldImport,$currentGrab) -FileId 8422 -DownloadId "current-download")
$afterCommit = @(Resolve-TestMatch -Records @($oldImport,$currentGrab,$currentImport) -FileId 8422 -DownloadId "current-download")

$tests = @(
    [pscustomobject]@{
        Test = "pre-commit history can contain older imports but no current exact match"
        Passed = ($beforeCommit.Count -eq 0)
    },
    [pscustomobject]@{
        Test = "post-commit history resolves the exact current import"
        Passed = ($afterCommit.Count -eq 1 -and [int]$afterCommit[0].id -eq 102)
    },
    [pscustomobject]@{
        Test = "executor recognizes Radarr movieFileId history data"
        Passed = ($Source -match 'movieFileId')
    },
    [pscustomobject]@{
        Test = "executor recognizes Sonarr episodeFileId history data"
        Passed = ($Source -match 'episodeFileId')
    },
    [pscustomobject]@{
        Test = "executor contains bounded downloadId consistency refresh"
        Passed = (
            $Source -match 'historyConsistencyMaxChecks\s*=\s*7' -and
            $Source -match 'historyConsistencyDelaySeconds\s*=\s*2' -and
            $Source -match 'global_history_downloadId_consistency_refresh'
        )
    },
    [pscustomobject]@{
        Test = "consistency refresh preserves strong downloadId identity"
        Passed = (
            $Source -match '\$matches\.Count\s*-eq\s*0\s*-and\s*-not\s+\[string\]::IsNullOrWhiteSpace\(\$downloadId\)' -and
            $Source -match 'downloadId=\$encodedRefreshDownloadId'
        )
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} history consistency tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} history consistency tests failed." -f $failed.Count, $tests.Count)
exit 1
