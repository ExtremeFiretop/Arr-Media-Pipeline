[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RetryPath = Join-Path $Root "Integration\Invoke-ReacquisitionRetry.ps1"
$Source = Get-Content -LiteralPath $RetryPath -Raw -Encoding UTF8

$emptySearch = [pscustomobject]@{
    predicted = @()
    diskOnly = @()
}

$emptyNonDvPool = @(
    if ($false) {
        $emptySearch.predicted
    }
    else {
        $emptySearch.diskOnly
    }
)

$emptyDvPool = @(
    if ($true) {
        $emptySearch.predicted
    }
    else {
        $emptySearch.diskOnly
    }
)

$singleSearch = [pscustomobject]@{
    predicted = @([pscustomobject]@{ guid = "one" })
    diskOnly = @()
}

$singlePool = @(
    if ($true) {
        $singleSearch.predicted
    }
    else {
        $singleSearch.diskOnly
    }
)

$tests = @(
    [pscustomobject]@{
        Test = "retry executor wraps the whole prePool conditional in array syntax"
        Passed = ($Source -match '(?s)\$prePool\s*=\s*@\(\s*if\s*\(\$isDolbyVisionReacquisition\)')
    },
    [pscustomobject]@{
        Test = "empty non-DV branch remains an array with Count 0"
        Passed = ($emptyNonDvPool.Count -eq 0)
    },
    [pscustomobject]@{
        Test = "empty DV branch remains an array with Count 0"
        Passed = ($emptyDvPool.Count -eq 0)
    },
    [pscustomobject]@{
        Test = "single candidate branch remains an array with Count 1"
        Passed = ($singlePool.Count -eq 1)
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
