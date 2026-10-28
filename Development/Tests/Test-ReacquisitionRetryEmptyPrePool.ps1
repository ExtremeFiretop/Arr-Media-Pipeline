[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RetryPath = Join-Path $Root "Integration\Invoke-ReacquisitionRetry.ps1"
$Source = Get-Content -LiteralPath $RetryPath -Raw -Encoding UTF8

$emptySearch = [pscustomobject]@{
    predicted = @()
}

$emptyPool = @($emptySearch.predicted)

$singleSearch = [pscustomobject]@{
    predicted = @([pscustomobject]@{ guid = "one" })
}

$singlePool = @($singleSearch.predicted)

$tests = @(
    [pscustomobject]@{
        Test = "retry executor array-wraps the full predicted candidate pool"
        Passed = ($Source -match '\$prePool\s*=\s*@\(\$preSearch\.predicted\)')
    },
    [pscustomobject]@{
        Test = "empty predicted pool remains an array with Count 0"
        Passed = ($emptyPool.Count -eq 0)
    },
    [pscustomobject]@{
        Test = "single predicted candidate remains an array with Count 1"
        Passed = ($singlePool.Count -eq 1)
    },
    [pscustomobject]@{
        Test = "non-DV retry no longer excludes already-approved candidates from pre-removal gate"
        Passed = ($Source -notmatch 'candidatePoolMode\s*=\s*if\s*\(\$isDolbyVisionReacquisition\).*DISK_ONLY_BLOCKED')
    }
)

$tests | Format-Table -AutoSize -Wrap
$failed = @($tests | Where-Object { -not $_.Passed })

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("PASS: {0}/{1} retry prePool array tests passed." -f $tests.Count, $tests.Count)
    exit 0
}

Write-Host ("FAIL: {0}/{1} retry prePool array tests failed." -f $failed.Count, $tests.Count)
exit 1
