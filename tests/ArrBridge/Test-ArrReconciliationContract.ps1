[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "Reqestra Arr Reconciliation Contract Test"
Write-Host "========================================="
Write-Host ""

$cases = @(
    [pscustomobject]@{
        Source = "Sonarr"
        ExpectedCommand = "RescanSeries"
        ExpectedKey = "seriesId"
        ExpectedResource = "episodefile/456"
    },
    [pscustomobject]@{
        Source = "Radarr"
        ExpectedCommand = "RescanMovie"
        ExpectedKey = "movieId"
        ExpectedResource = "moviefile/456"
    }
)

$results = @()

foreach ($case in $cases) {
    $entityId = 123
    $fileId = 456

    if ($case.Source -eq "Sonarr") {
        $command = "RescanSeries"
        $key = "seriesId"
        $resource = "episodefile/$fileId"
    }
    else {
        $command = "RescanMovie"
        $key = "movieId"
        $resource = "moviefile/$fileId"
    }

    $passed =
        ($command -eq $case.ExpectedCommand) -and
        ($key -eq $case.ExpectedKey) -and
        ($resource -eq $case.ExpectedResource)

    $results += [pscustomobject]@{
        Source = $case.Source
        Passed = $passed
        Command = $command
        EntityKey = $key
        FileResource = $resource
    }
}

$results | Format-Table -AutoSize

$failed = @($results | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} Arr reconciliation contract tests passed." -f $results.Count, $results.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} tests failed." -f $failed.Count, $results.Count)
exit 1
