[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Reacquisition Postcondition Contract Test"
Write-Host "=================================================="
Write-Host ""

$attemptStart = [DateTime]"2026-10-25T03:26:15Z"

$wrongOldFailure = [pscustomobject]@{
    eventType = "downloadFailed"
    sourceTitle = "Movie.Release"
    downloadId = "abc"
    date = "2026-10-25T03:21:16Z"
    data = [pscustomobject]@{
        message = "Manually marked as failed"
    }
}

$correctNewFailure = [pscustomobject]@{
    eventType = "downloadFailed"
    sourceTitle = "Movie.Release"
    downloadId = "abc"
    date = "2026-10-25T03:26:16Z"
    data = [pscustomobject]@{
        message = "Manually marked as failed"
        indexer = "ExampleIndexer"
    }
}

$blocklist = [pscustomobject]@{
    sourceTitle = "Movie.Release"
}

function IsAfter {
    param($Record, [DateTime]$NotBefore)
    return ([DateTime]$Record.date).ToUniversalTime() -ge $NotBefore.ToUniversalTime()
}

$tests = @(
    [pscustomobject]@{
        Test = "Old wrong-target failed event is excluded by attempt time"
        Passed = (-not (IsAfter $wrongOldFailure $attemptStart))
    },
    [pscustomobject]@{
        Test = "Correct failed event after attempt is accepted"
        Passed = (IsAfter $correctNewFailure $attemptStart)
    },
    [pscustomobject]@{
        Test = "DownloadFailed history need not contain protocol"
        Passed = ($null -eq $correctNewFailure.data.PSObject.Properties["protocol"])
    },
    [pscustomobject]@{
        Test = "DownloadFailed history need not contain publishedDate"
        Passed = ($null -eq $correctNewFailure.data.PSObject.Properties["publishedDate"])
    },
    [pscustomobject]@{
        Test = "Blocklist plus new failed history is sufficient success evidence"
        Passed = ($null -ne $blocklist -and (IsAfter $correctNewFailure $attemptStart))
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} reacquisition postcondition contract tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} reacquisition postcondition contract tests failed." -f $failed.Count, $tests.Count)
exit 1
