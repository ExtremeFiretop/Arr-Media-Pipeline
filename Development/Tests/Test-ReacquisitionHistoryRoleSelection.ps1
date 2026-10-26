[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition History Role Selection Test"
Write-Host "=================================================="
Write-Host ""

$downloadId = "abc123"
$sourceTitle = "Movie.2026.2160p-GROUP"

$records = @(
    [pscustomobject]@{
        id = 100
        eventType = "downloadFolderImported"
        sourceTitle = $sourceTitle
        downloadId = $downloadId
        data = [pscustomobject]@{
            fileId = 8129
            importedPath = "M:\Movies\Movie.mkv"
            size = 1000
        }
    },
    [pscustomobject]@{
        id = 90
        eventType = "grabbed"
        sourceTitle = $sourceTitle
        downloadId = $downloadId
        data = [pscustomobject]@{
            protocol = 1
            publishedDate = "2026-01-01T00:00:00Z"
            indexer = "ExampleIndexer"
            size = 1200
        }
    }
)

$import = @(
    $records |
        Where-Object {
            $_.eventType -eq "downloadFolderImported" -and
            [int]$_.data.fileId -eq 8129
        }
)

$grabbed = @(
    $records |
        Where-Object {
            $_.eventType -eq "grabbed" -and
            $_.downloadId -eq $import[0].downloadId
        }
)

$tests = @(
    [pscustomobject]@{
        Test = "Imported record proves file identity"
        Passed = ($import.Count -eq 1 -and $import[0].id -eq 100)
    },
    [pscustomobject]@{
        Test = "Grabbed record selected by same downloadId"
        Passed = ($grabbed.Count -eq 1 -and $grabbed[0].id -eq 90)
    },
    [pscustomobject]@{
        Test = "Failure target is grabbed, not imported"
        Passed = ($grabbed[0].id -ne $import[0].id)
    },
    [pscustomobject]@{
        Test = "Grabbed target contains protocol"
        Passed = (-not [string]::IsNullOrWhiteSpace([string]$grabbed[0].data.protocol))
    },
    [pscustomobject]@{
        Test = "Grabbed target contains publishedDate"
        Passed = (-not [string]::IsNullOrWhiteSpace([string]$grabbed[0].data.publishedDate))
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition history role-selection tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition history role-selection tests failed." -f $failed.Count, $tests.Count)
exit 1
